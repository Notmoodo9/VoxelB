; =============================================================================
; shader.asm — GLSL program loading from shaders/ with hot reload.
;
; Programs are registered once (vertex + fragment file, root-relative paths)
; and referred to by handle. shader_poll() checks the files' last-write times
; every POLL_MS; a changed program is rebuilt, and only swapped in if it
; compiles and links (otherwise the old program keeps running and the errors
; go to the log). shader_reload_all() forces a rebuild of everything.
;
; Public API (see include/shader.inc):
;   shader_create(vs_rel, fs_rel) -> eax handle, or -1 (errors logged)
;   shader_program(handle) -> eax GL program name
;   shader_poll()   shader_reload_all()   shader_shutdown()
;   g_shader_count, g_shader_reloads, g_shader_failures, g_shader_last_ok
; =============================================================================
%define SHADER_IMPL
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "file.inc"
%include "shader.inc"
%include "memory.inc"

global shader_create, shader_program, shader_poll, shader_reload_all, shader_shutdown
global g_shader_count, g_shader_reloads, g_shader_failures, g_shader_last_ok

IMPORT GetTickCount64

%define MAX_PROGRAMS    16
%define INFO_LOG_CAP    8192
%define POLL_MS         250

struc PROGRAM
    .vs_rel     resq 1
    .fs_rel     resq 1
    .vs_mtime   resq 1
    .fs_mtime   resq 1
    .gl_name    resd 1
    .pad        resd 1
endstruc

section .rdata
str_compile_fail:   db "shader compile failed: ", 0
str_link_fail:      db "program link failed: ", 0
str_read_fail:      db "cannot read shader: ", 0
str_loaded:         db "shader program ready: ", 0
str_reloaded:       db "shader program reloaded: ", 0
str_kept:           db "shader reload failed, keeping the previous version: ", 0
str_plus:           db " + ", 0
str_indent:         db "    ", 0

section .bss
alignb 8
g_programs:         resb MAX_PROGRAMS * PROGRAM_size
g_shader_count:     resd 1
g_shader_reloads:   resd 1
g_shader_failures:  resd 1
g_shader_last_ok:   resd 1
alignb 8
g_last_poll_ms:     resq 1
g_src_ptr:          resq 1
alignb 16
g_info_log:         resq 1                  ; INFO_LOG_CAP bytes in scratch
g_path_buf:         resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; log_text_lines — log every non-empty line of a multi-line text, indented.
;   in:  ecx = level, rdx = text (zero-terminated; modified in place)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_text_lines, 0, rbx, rsi, rdi
    mov edi, ecx
    mov rsi, rdx
.line:
    cmp byte [rsi], 0
    je .done
    mov rbx, rsi
.find:
    mov al, [rsi]
    test al, al
    jz .cut
    cmp al, 10
    je .cut
    inc rsi
    jmp .find
.cut:
    mov al, [rsi]
    mov byte [rsi], 0
    cmp al, 0
    je .emit
    inc rsi
.emit:
    cmp byte [rbx], 0
    je .line
    cmp byte [rbx], 13
    je .line
    mov ecx, edi
    call log_begin
    lea rcx, [rel str_indent]
    call log_append_str
    mov rcx, rbx
    call log_append_str
    call log_end
    jmp .line
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_pair — log "<prefix><a> + <b>" at the given level.
;   in:  ecx = level, rdx = prefix, r8 = a, r9 = b
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_pair, 0, rbx, rsi, rdi
    mov rbx, rdx
    mov rsi, r8
    mov rdi, r9
    call log_begin
    mov rcx, rbx
    call log_append_str
    mov rcx, rsi
    call log_append_str
    lea rcx, [rel str_plus]
    call log_append_str
    mov rcx, rdi
    call log_append_str
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; compile_shader — read and compile one shader stage.
;   in:  ecx = GL shader type, rdx = root-relative file path
;   out: eax = shader name, 0 on failure (errors logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC compile_shader, 16, rbx, rsi, rdi, r12
    mov edi, ecx
    mov rsi, rdx
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov r12, rax                        ; r12 = scratch mark (reset on exit)
    lea rcx, [rel g_path_buf]
    INVOKE path_make, rcx, rsi
    lea rcx, [rel g_path_buf]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jnz .read_ok
    mov ecx, LOG_LEVEL_ERROR
    call log_begin
    lea rcx, [rel str_read_fail]
    call log_append_str
    mov rcx, rsi
    call log_append_str
    call log_end
    xor eax, eax
    jmp .out
.read_ok:
    mov [rel g_src_ptr], rax
    GL glCreateShader, rdi
    mov ebx, eax
    lea r8, [rel g_src_ptr]
    GL glShaderSource, rbx, 1, r8, 0
    GL glCompileShader, rbx
    mov dword [LOCAL(0)], 0
    lea r8, [LOCAL(0)]
    GL glGetShaderiv, rbx, GL_COMPILE_STATUS, r8
    cmp dword [LOCAL(0)], 0
    jne .ok
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, INFO_LOG_CAP, 16
    mov [rel g_info_log], rax
    mov byte [rax], 0
    mov r9, rax
    GL glGetShaderInfoLog, rbx, INFO_LOG_CAP, 0, r9
    mov ecx, LOG_LEVEL_ERROR
    call log_begin
    lea rcx, [rel str_compile_fail]
    call log_append_str
    mov rcx, rsi
    call log_append_str
    call log_end
    mov rdx, [rel g_info_log]
    INVOKE log_text_lines, LOG_LEVEL_ERROR, rdx
    GL glDeleteShader, rbx
    xor eax, eax
    jmp .out
.ok:
    mov eax, ebx
.out:
    mov ebx, eax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, r12
    mov eax, ebx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; build_program — compile both stages and link.
;   in:  rcx = vertex shader path, rdx = fragment shader path (root-relative)
;   out: eax = program name, 0 on failure (errors logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC build_program, 16, rbx, rsi, rdi, r12, r13
    mov r12, rcx
    mov r13, rdx
    INVOKE compile_shader, GL_VERTEX_SHADER, r12
    mov ebx, eax
    test ebx, ebx
    jz .fail
    INVOKE compile_shader, GL_FRAGMENT_SHADER, r13
    mov esi, eax
    test esi, esi
    jz .fail_vs
    GL glCreateProgram
    mov edi, eax
    GL glAttachShader, rdi, rbx
    GL glAttachShader, rdi, rsi
    GL glLinkProgram, rdi
    GL glDeleteShader, rbx              ; flagged; freed with the program
    GL glDeleteShader, rsi
    mov dword [LOCAL(0)], 0
    lea r8, [LOCAL(0)]
    GL glGetProgramiv, rdi, GL_LINK_STATUS, r8
    cmp dword [LOCAL(0)], 0
    jne .linked
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov rbx, rax                        ; shaders are gone: reuse rbx as mark
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, INFO_LOG_CAP, 16
    mov [rel g_info_log], rax
    mov byte [rax], 0
    mov r9, rax
    GL glGetProgramInfoLog, rdi, INFO_LOG_CAP, 0, r9
    lea rdx, [rel str_link_fail]
    INVOKE log_pair, LOG_LEVEL_ERROR, rdx, r12, r13
    mov rdx, [rel g_info_log]
    INVOKE log_text_lines, LOG_LEVEL_ERROR, rdx
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, rbx
    GL glDeleteProgram, rdi
    xor eax, eax
    RETURN
.linked:
    mov eax, edi
    RETURN
.fail_vs:
    GL glDeleteShader, rbx
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; program_entry — address of a program slot.
;   in:  ecx = handle
;   out: rax = slot address
;   clobbers: rax, rcx
; -----------------------------------------------------------------------------
program_entry:
    imul ecx, ecx, PROGRAM_size
    lea rax, [rel g_programs]
    add rax, rcx
    ret

; -----------------------------------------------------------------------------
; refresh_mtimes — record the current file times of a program's sources.
;   in:  rcx = program slot
;   out: rax = 1 if either time differs from the stored one (then updated)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC refresh_mtimes, 0, rbx, rsi
    mov rbx, rcx
    xor esi, esi
    lea rcx, [rel g_path_buf]
    INVOKE path_make, rcx, [rbx + PROGRAM.vs_rel]
    lea rcx, [rel g_path_buf]
    call file_mtime
    test rax, rax
    jz .fs                              ; unreadable right now: try later
    cmp rax, [rbx + PROGRAM.vs_mtime]
    je .fs
    mov [rbx + PROGRAM.vs_mtime], rax
    mov esi, 1
.fs:
    lea rcx, [rel g_path_buf]
    INVOKE path_make, rcx, [rbx + PROGRAM.fs_rel]
    lea rcx, [rel g_path_buf]
    call file_mtime
    test rax, rax
    jz .done
    cmp rax, [rbx + PROGRAM.fs_mtime]
    je .done
    mov [rbx + PROGRAM.fs_mtime], rax
    mov esi, 1
.done:
    mov eax, esi
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; shader_create — register and build a program.
;   in:  rcx = vertex shader path, rdx = fragment shader path (root-relative,
;        static strings: the pointers are kept for reloading)
;   out: eax = handle (>= 0), or -1 if it failed to build (errors logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC shader_create, 0, rbx, rsi, rdi
    mov rsi, rcx
    mov rdi, rdx
    mov ecx, [rel g_shader_count]
    cmp ecx, MAX_PROGRAMS
    jb .room
    LOG_ERROR "too many shader programs (raise MAX_PROGRAMS)"
    mov eax, -1
    RETURN
.room:
    call program_entry
    mov rbx, rax
    mov [rbx + PROGRAM.vs_rel], rsi
    mov [rbx + PROGRAM.fs_rel], rdi
    mov rcx, rbx
    call refresh_mtimes
    INVOKE build_program, rsi, rdi
    test eax, eax
    jnz .built
    mov eax, -1
    RETURN
.built:
    mov [rbx + PROGRAM.gl_name], eax
    lea rdx, [rel str_loaded]
    INVOKE log_pair, LOG_LEVEL_INFO, rdx, rsi, rdi
    mov eax, [rel g_shader_count]
    inc dword [rel g_shader_count]
    mov dword [rel g_shader_last_ok], 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; shader_program — GL program name for a handle.
;   in:  ecx = handle
;   out: eax = program name
;   clobbers: rax, rcx
; -----------------------------------------------------------------------------
shader_program:
    call program_entry
    mov eax, [rax + PROGRAM.gl_name]
    ret

; -----------------------------------------------------------------------------
; reload_program — rebuild one program; swap only on success.
;   in:  rcx = program slot
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC reload_program, 0, rbx
    mov rbx, rcx
    INVOKE build_program, [rbx + PROGRAM.vs_rel], [rbx + PROGRAM.fs_rel]
    test eax, eax
    jz .failed
    mov ecx, [rbx + PROGRAM.gl_name]
    mov [rbx + PROGRAM.gl_name], eax
    GL glDeleteProgram, rcx
    inc dword [rel g_shader_reloads]
    mov dword [rel g_shader_last_ok], 1
    lea rdx, [rel str_reloaded]
    INVOKE log_pair, LOG_LEVEL_INFO, rdx, [rbx + PROGRAM.vs_rel], [rbx + PROGRAM.fs_rel]
    RETURN
.failed:
    inc dword [rel g_shader_failures]
    mov dword [rel g_shader_last_ok], 0
    lea rdx, [rel str_kept]
    INVOKE log_pair, LOG_LEVEL_WARN, rdx, [rbx + PROGRAM.vs_rel], [rbx + PROGRAM.fs_rel]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; shader_poll — rebuild programs whose source files changed (checked at most
; every POLL_MS milliseconds).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC shader_poll, 0, rbx, rsi
    API GetTickCount64
    mov rcx, rax
    sub rcx, [rel g_last_poll_ms]
    cmp rcx, POLL_MS
    jb .done
    mov [rel g_last_poll_ms], rax
    xor esi, esi
.next:
    cmp esi, [rel g_shader_count]
    jae .done
    mov ecx, esi
    call program_entry
    mov rbx, rax
    mov rcx, rbx
    call refresh_mtimes
    test eax, eax
    jz .skip
    mov rcx, rbx
    call reload_program
.skip:
    inc esi
    jmp .next
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; shader_reload_all — force a rebuild of every program.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC shader_reload_all, 0, rsi
    LOG_INFO "reloading all shaders"
    xor esi, esi
.next:
    cmp esi, [rel g_shader_count]
    jae .done
    mov ecx, esi
    call program_entry
    mov rcx, rax
    call reload_program
    inc esi
    jmp .next
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; shader_shutdown — delete every program.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC shader_shutdown, 0, rsi
    xor esi, esi
.next:
    cmp esi, [rel g_shader_count]
    jae .done
    mov ecx, esi
    call program_entry
    mov ecx, [rax + PROGRAM.gl_name]
    GL glDeleteProgram, rcx
    inc esi
    jmp .next
.done:
    mov dword [rel g_shader_count], 0
    RETURN
ENDPROC
