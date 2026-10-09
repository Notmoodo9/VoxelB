; =============================================================================
; text.asm — bitmap-font text and solid rectangles for UI/debug overlays.
;
; Font: assets/fonts/debug_8x13.vxf (format in tools/make_font.py). The atlas
; is an R8 texture; every glyph or rectangle is one 32-byte record in a
; shader storage buffer, expanded to a quad in the vertex shader (vertex
; pulling, no vertex buffers). Records are collected on the CPU each frame
; and uploaded once in text_flush.
;
; Public API (see include/text.inc):
;   text_init() -> eax 1/0        text_shutdown()
;   text_begin()                  start a new batch
;   text_add(str, x, y, color)    -> eax = width in pixels of the longest line
;   text_rect(x, y, w, h, color)  solid rectangle (color in ARG 5)
;   text_flush(screen_w, screen_h)
;   g_text_scale (integer pixel scale), g_font_cell_w, g_font_cell_h
; Colors are 0xAABBGGRR (R in the low byte). Coordinates are pixels from the
; top-left corner.
; =============================================================================
%define TEXT_IMPL
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "file.inc"
%include "shader.inc"
%include "text.inc"
%include "memory.inc"

global text_init, text_shutdown, text_begin, text_add, text_rect, text_flush
global g_text_scale, g_font_cell_w, g_font_cell_h

%define MAX_GLYPHS      8192
%define GLYPH_SIZE      32

struc GLYPH
    .x      resd 1
    .y      resd 1
    .w      resd 1
    .h      resd 1
    .ch     resd 1                      ; 0 = solid rectangle
    .color  resd 1
    .pad    resd 2
endstruc

section .rdata
str_font_file:  db "assets/fonts/debug_8x13.vxf", 0
str_text_vs:    db "shaders/text.vert", 0
str_text_fs:    db "shaders/text.frag", 0

section .data
align 4
g_text_scale:   dd 1

section .bss
alignb 4
g_font_cell_w:  resd 1
g_font_cell_h:  resd 1
g_font_cols:    resd 1
g_font_first:   resd 1
g_font_count:   resd 1
g_text_tex:     resd 1
g_text_buf:     resd 1
g_text_vao:     resd 1
g_text_prog:    resd 1                  ; shader handle
g_glyph_count:  resd 1
alignb 16
g_uniform_tmp:  resd 4
alignb 8
g_glyphs:       resq 1                  ; MAX_GLYPHS records (perm arena)
g_font_path:    resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; text_init — load the font, create the atlas texture, glyph buffer and
; program.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC text_init, 16, rbx, rsi
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, MAX_GLYPHS * GLYPH_SIZE, 64
    mov [rel g_glyphs], rax
    test rax, rax
    jz .fail
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov rsi, rax                        ; scratch mark (font file is temporary)
    lea rcx, [rel g_font_path]
    lea rdx, [rel str_font_file]
    call path_make
    lea rcx, [rel g_font_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    cmp rdx, 16
    jae .read_ok
    LOG_ERROR "could not read assets/fonts/debug_8x13.vxf"
    jmp .fail_reset
.read_ok:
    mov rbx, rax
    cmp dword [rbx], 'VXF1'
    je .magic_ok
    LOG_ERROR "font file has a bad header (expected VXF1)"
    jmp .fail_reset
.magic_ok:
    movzx eax, word [rbx + 4]
    mov [rel g_font_cell_w], eax
    movzx eax, word [rbx + 6]
    mov [rel g_font_cell_h], eax
    movzx eax, word [rbx + 8]
    mov [rel g_font_cols], eax
    movzx eax, byte [rbx + 12]
    mov [rel g_font_first], eax
    movzx eax, byte [rbx + 13]
    mov [rel g_font_count], eax

    ; ---- atlas texture: (cols*cell_w) x (rows*cell_h), R8 -----------------------
    lea r8, [rel g_text_tex]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    mov eax, [rel g_font_cols]
    imul eax, [rel g_font_cell_w]
    mov [LOCAL(0)], rax                 ; atlas width (zero-extended qword)
    movzx eax, word [rbx + 10]
    imul eax, [rel g_font_cell_h]
    mov [LOCAL(8)], rax                 ; atlas height
    GL glTextureStorage2D, [rel g_text_tex], 1, GL_R8, [LOCAL(0)], [LOCAL(8)]
    GL glPixelStorei, GL_UNPACK_ALIGNMENT, 1
    ; glTextureSubImage2D(tex, level, x, y, w, h, format, type, pixels)
    mov r11, [LOCAL(0)]
    mov [rsp + 32], r11                 ; w
    mov r11, [LOCAL(8)]
    mov [rsp + 40], r11                 ; h
    mov qword [rsp + 48], GL_RED
    mov qword [rsp + 56], GL_UNSIGNED_BYTE
    lea rax, [rbx + 16]
    mov [rsp + 64], rax                 ; pixels
    mov ecx, [rel g_text_tex]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [rel glTextureSubImage2D]
    GL glTextureParameteri, [rel g_text_tex], GL_TEXTURE_MIN_FILTER, GL_NEAREST
    GL glTextureParameteri, [rel g_text_tex], GL_TEXTURE_MAG_FILTER, GL_NEAREST
    GL glTextureParameteri, [rel g_text_tex], GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, [rel g_text_tex], GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, rsi     ; font data is in the texture now

    ; ---- glyph storage buffer + empty VAO ----------------------------------------
    lea rdx, [rel g_text_buf]
    GL glCreateBuffers, 1, rdx
    GL glNamedBufferStorage, [rel g_text_buf], MAX_GLYPHS * GLYPH_SIZE, 0, GL_DYNAMIC_STORAGE_BIT
    lea rdx, [rel g_text_vao]
    GL glCreateVertexArrays, 1, rdx

    ; ---- program -------------------------------------------------------------------
    lea rcx, [rel str_text_vs]
    lea rdx, [rel str_text_fs]
    call shader_create
    cmp eax, -1
    jne .prog_ok
    xor eax, eax
    RETURN
.prog_ok:
    mov [rel g_text_prog], eax
    LOG_INFO "text renderer ready"
    mov eax, 1
    RETURN
.fail_reset:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, rsi
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; text_shutdown — free GL objects.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC text_shutdown, 0
    lea rdx, [rel g_text_tex]
    GL glDeleteTextures, 1, rdx
    lea rdx, [rel g_text_buf]
    GL glDeleteBuffers, 1, rdx
    lea rdx, [rel g_text_vao]
    GL glDeleteVertexArrays, 1, rdx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; text_begin — start a new batch.
;   clobbers: none
; -----------------------------------------------------------------------------
text_begin:
    mov dword [rel g_glyph_count], 0
    ret

; -----------------------------------------------------------------------------
; push_record — append one record (no-op when full).
;   in:  ecx = x, edx = y, r8d = w, r9d = h (pixels, integers),
;        r10d = ch (0 = rect), r11d = color
;   clobbers: rax, xmm0
; -----------------------------------------------------------------------------
push_record:
    mov eax, [rel g_glyph_count]
    cmp eax, MAX_GLYPHS
    jae .full
    inc dword [rel g_glyph_count]
    shl eax, 5
    push rbx
    mov rbx, [rel g_glyphs]
    add rbx, rax
    cvtsi2ss xmm0, ecx
    movss [rbx + GLYPH.x], xmm0
    cvtsi2ss xmm0, edx
    movss [rbx + GLYPH.y], xmm0
    cvtsi2ss xmm0, r8d
    movss [rbx + GLYPH.w], xmm0
    cvtsi2ss xmm0, r9d
    movss [rbx + GLYPH.h], xmm0
    mov [rbx + GLYPH.ch], r10d
    mov [rbx + GLYPH.color], r11d
    pop rbx
.full:
    ret

; -----------------------------------------------------------------------------
; text_rect — queue a solid rectangle.
;   in:  ecx = x, edx = y, r8d = w, r9d = h, ARG 5 = color (0xAABBGGRR)
;   clobbers: rax, r10, r11, xmm0
; -----------------------------------------------------------------------------
text_rect:
    mov r11d, [rsp + 40]                ; arg 5 (after return address + shadow)
    xor r10d, r10d
    jmp push_record

; -----------------------------------------------------------------------------
; text_add — queue a string ('\n' starts a new line at the original x).
;   in:  rcx = string, edx = x, r8d = y, r9d = color
;   out: eax = width in pixels of the widest line
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC text_add, 0, rbx, rsi, rdi, r12, r13, r14, r15
    mov rsi, rcx                        ; cursor
    mov r12d, edx                       ; line start x
    mov edi, edx                        ; pen x
    mov r13d, r8d                       ; pen y
    mov r14d, r9d                       ; color
    xor r15d, r15d                      ; widest line
    mov ebx, [rel g_font_cell_w]
    imul ebx, [rel g_text_scale]        ; advance
.next:
    movzx eax, byte [rsi]
    inc rsi
    test eax, eax
    jz .end
    cmp eax, 10
    jne .glyph
    mov eax, edi
    sub eax, r12d
    cmp eax, r15d
    jbe .nl
    mov r15d, eax
.nl:
    mov edi, r12d
    mov eax, [rel g_font_cell_h]
    imul eax, [rel g_text_scale]
    add r13d, eax
    jmp .next
.glyph:
    cmp eax, 32
    je .advance                         ; space: no record needed
    mov r10d, eax
    sub eax, [rel g_font_first]
    cmp eax, [rel g_font_count]
    jae .advance                        ; not in the font
    mov ecx, edi
    mov edx, r13d
    mov r8d, ebx
    mov r9d, [rel g_font_cell_h]
    imul r9d, [rel g_text_scale]
    mov r11d, r14d
    call push_record
.advance:
    add edi, ebx
    jmp .next
.end:
    mov eax, edi
    sub eax, r12d
    cmp eax, r15d
    jbe .done
    mov r15d, eax
.done:
    mov eax, r15d
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; text_flush — upload and draw the batch over the current framebuffer.
;   in:  ecx = screen width, edx = screen height (pixels)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC text_flush, 0, rbx, rsi
    mov esi, [rel g_glyph_count]
    test esi, esi
    jz .done
    lea rax, [rel g_uniform_tmp]
    cvtsi2ss xmm0, ecx
    movss [rax], xmm0
    cvtsi2ss xmm0, edx
    movss [rax + 4], xmm0

    mov r8d, esi
    shl r8d, 5
    mov r9, [rel g_glyphs]
    GL glNamedBufferSubData, [rel g_text_buf], 0, r8, r9

    mov ecx, [rel g_text_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    lea r9, [rel g_uniform_tmp]
    GL glProgramUniform2fv, rbx, 0, 1, r9          ; u_screen
    lea rax, [rel g_uniform_tmp]
    cvtsi2ss xmm0, dword [rel g_font_cell_w]
    movss [rax], xmm0
    cvtsi2ss xmm0, dword [rel g_font_cell_h]
    movss [rax + 4], xmm0
    cvtsi2ss xmm0, dword [rel g_font_cols]
    movss [rax + 8], xmm0
    cvtsi2ss xmm0, dword [rel g_font_first]
    movss [rax + 12], xmm0
    lea r9, [rel g_uniform_tmp]
    GL glProgramUniform4fv, rbx, 1, 1, r9          ; u_font

    GL glDisable, GL_DEPTH_TEST
    GL glDisable, GL_CULL_FACE          ; screen-space quads wind clockwise
    GL glEnable, GL_BLEND
    GL glBlendFunc, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA
    GL glBindVertexArray, [rel g_text_vao]
    GL glBindTextureUnit, 0, [rel g_text_tex]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 0, [rel g_text_buf]
    imul r8d, esi, 6
    GL glDrawArrays, GL_TRIANGLES, 0, r8
    GL glDisable, GL_BLEND
    GL glEnable, GL_CULL_FACE
    GL glEnable, GL_DEPTH_TEST
.done:
    RETURN
ENDPROC
