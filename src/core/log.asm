; =============================================================================
; log.asm — thread-safe line logger.
;
; Every line is "[sssss.mmm] LEVEL message\r\n" (seconds since log_init) and is
; written to:
;   * voxel.log next to the executable (truncated on every start)
;   * the console, if stdout is redirected or a parent console exists
;   * the debugger (OutputDebugStringA)
;
; Public API (see include/log.inc for convenience macros):
;   log_init, log_shutdown
;   log_msg(level, str)  log_val(level, str, u64)  log_hex(level, str, u64)
;   log_begin(level) / log_append_str / log_append_dec / log_append_hex / log_end
;     — compose one line from several pieces; the log lock is held from
;       log_begin until log_end, so keep the sequence short.
;   log_fatal(str)       log an error, show a message box, ExitProcess(1)
;   assert_fail(file, line, msg)   target of the ASSERT macro
; =============================================================================
%define LOG_IMPL
%include "macros.inc"
%include "win32.inc"
%include "log.inc"

global log_init, log_shutdown
global log_msg, log_val, log_hex
global log_begin, log_append_str, log_append_dec, log_append_hex, log_end
global log_fatal, assert_fail

extern fmt_u64, fmt_hex64

IMPORT GetModuleFileNameA, CreateFileA, WriteFile, CloseHandle
IMPORT GetStdHandle, AttachConsole, OutputDebugStringA
IMPORT QueryPerformanceFrequency, QueryPerformanceCounter
IMPORT AcquireSRWLockExclusive, ReleaseSRWLockExclusive
IMPORT MessageBoxA, ExitProcess

%define LINE_CAP        1024            ; bytes in the line buffer
%define LINE_TEXT_MAX   (LINE_CAP - 3)  ; leave room for "\r\n\0"

section .rdata
log_file_name:      db "voxel.log", 0
level_names:        db "DEBUG ", "INFO  ", "WARN  ", "ERROR "
str_hex_prefix:     db "0x", 0
str_assert_title:   db "VoxelB - assertion failed", 0
str_fatal_title:    db "VoxelB - fatal error", 0
str_assert_head:    db "ASSERT FAILED: ", 0
str_assert_at:      db "  at ", 0
str_colon:          db ":", 0
str_space:          db " ", 0
str_log_closed:     db "log closed", 0

section .bss
alignb 8
g_log_file:         resq 1          ; file handle or 0
g_log_console:      resq 1          ; console/stdout handle or 0
g_log_lock:         resq 1          ; SRWLOCK (zero = unlocked)
g_qpc_freq:         resq 1
g_qpc_start:        resq 1
g_line_len:         resq 1
g_line:             resb LINE_CAP

section .text

; -----------------------------------------------------------------------------
; log_init — open the log file and console, start the log clock.
;   in:  none
;   out: eax = 1 if the log file was opened, 0 otherwise (logging to the
;        console/debugger still works)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_init, MAX_PATH + 16, rbx, rsi
    lea rbx, [LOCAL(0)]                 ; rbx = path buffer
    API GetModuleFileNameA, 0, rbx, MAX_PATH
    ; find the character after the last path separator
    mov rsi, rbx                        ; rsi = insertion point
    xor ecx, ecx
.scan:
    cmp ecx, eax
    jae .scan_done
    mov dl, [rbx + rcx]
    cmp dl, '\'
    je .sep
    cmp dl, '/'
    jne .scan_next
.sep:
    lea rsi, [rbx + rcx + 1]
.scan_next:
    inc ecx
    jmp .scan
.scan_done:
    ; append "voxel.log" (fits: MAX_PATH + 16 buffer, name is 10 bytes)
    lea rdx, [rel log_file_name]
.copy:
    mov al, [rdx]
    mov [rsi], al
    inc rdx
    inc rsi
    test al, al
    jnz .copy

    API CreateFileA, rbx, GENERIC_WRITE, FILE_SHARE_READ, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0
    cmp rax, INVALID_HANDLE_VALUE
    jne .file_ok
    xor eax, eax
.file_ok:
    mov [rel g_log_file], rax

    lea rcx, [rel g_qpc_freq]
    API QueryPerformanceFrequency, rcx
    lea rcx, [rel g_qpc_start]
    API QueryPerformanceCounter, rcx

    ; console: use redirected stdout if present, else attach to the parent's
    API GetStdHandle, STD_OUTPUT_HANDLE
    test rax, rax
    jz .attach
    cmp rax, INVALID_HANDLE_VALUE
    jne .console_ok
.attach:
    API AttachConsole, ATTACH_PARENT_PROCESS
    test eax, eax
    jz .no_console
    API GetStdHandle, STD_OUTPUT_HANDLE
    cmp rax, INVALID_HANDLE_VALUE
    jne .console_ok
.no_console:
    xor eax, eax
.console_ok:
    mov [rel g_log_console], rax

    xor eax, eax
    cmp qword [rel g_log_file], 0
    setne al
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_shutdown — write a final line and close the log file.
;   in/out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_shutdown, 0
    lea rdx, [rel str_log_closed]
    INVOKE log_msg, LOG_LEVEL_INFO, rdx
    mov rcx, [rel g_log_file]
    test rcx, rcx
    jz .done
    API CloseHandle, rcx
    mov qword [rel g_log_file], 0
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_begin — lock the log and start a line with timestamp and level.
;   in:  ecx = level (LOG_LEVEL_*; clamped to ERROR)
;   out: none (lock held until log_end)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_begin, 16, rbx, rsi
    mov ebx, ecx
    cmp ebx, LOG_LEVEL_ERROR
    jbe .lvl_ok
    mov ebx, LOG_LEVEL_ERROR
.lvl_ok:
    lea rcx, [rel g_log_lock]
    API AcquireSRWLockExclusive, rcx

    ; elapsed microseconds = (now - start) * 1e6 / freq
    lea rcx, [LOCAL(0)]
    API QueryPerformanceCounter, rcx
    mov rax, [LOCAL(0)]
    sub rax, [rel g_qpc_start]
    mov rcx, 1000000
    mul rcx
    mov rcx, [rel g_qpc_freq]
    test rcx, rcx
    jnz .freq_ok
    mov ecx, 1
.freq_ok:
    div rcx                             ; rax = microseconds
    xor edx, edx
    mov rcx, 1000
    div rcx                             ; rax = milliseconds
    xor edx, edx
    div rcx                             ; rax = seconds, rdx = ms part
    mov [LOCAL(8)], rdx

    lea rsi, [rel g_line]               ; rsi = write cursor
    mov byte [rsi], '['
    inc rsi
    INVOKE fmt_u64, rsi, rax, 5, ' '
    add rsi, rax
    mov byte [rsi], '.'
    inc rsi
    mov rdx, [LOCAL(8)]
    INVOKE fmt_u64, rsi, rdx, 3, '0'
    add rsi, rax
    mov word [rsi], '] '
    add rsi, 2
    ; level name, 6 chars
    lea rdx, [rel level_names]
    lea rdx, [rdx + rbx * 2]
    lea rdx, [rdx + rbx * 4]            ; rdx = names + level * 6
    mov eax, [rdx]
    mov [rsi], eax
    mov ax, [rdx + 4]
    mov [rsi + 4], ax
    add rsi, 6
    lea rcx, [rel g_line]
    sub rsi, rcx
    mov [rel g_line_len], rsi
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_append_str — append a zero-terminated string to the current line.
;   in:  rcx = string (may be 0, then nothing is appended)
;   out: none
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
log_append_str:
    test rcx, rcx
    jz .done
    mov rdx, [rel g_line_len]
    lea r8, [rel g_line]
.loop:
    cmp rdx, LINE_TEXT_MAX
    jae .store
    mov al, [rcx]
    test al, al
    jz .store
    mov [r8 + rdx], al
    inc rcx
    inc rdx
    jmp .loop
.store:
    mov [rel g_line_len], rdx
.done:
    ret

; -----------------------------------------------------------------------------
; log_append_dec — append an unsigned decimal number to the current line.
;   in:  rcx = value
;   out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_append_dec, 0
    mov rdx, rcx
    mov rax, [rel g_line_len]
    cmp rax, LINE_TEXT_MAX - 20
    ja .done
    lea rcx, [rel g_line]
    add rcx, rax
    INVOKE fmt_u64, rcx, rdx, 0, ' '
    add [rel g_line_len], rax
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_append_hex — append "0x" and 16 hex digits to the current line.
;   in:  rcx = value
;   out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_append_hex, 0, rbx
    mov rbx, rcx
    mov rax, [rel g_line_len]
    cmp rax, LINE_TEXT_MAX - 18
    ja .done
    lea rcx, [rel str_hex_prefix]
    call log_append_str
    lea rcx, [rel g_line]
    add rcx, [rel g_line_len]
    INVOKE fmt_hex64, rcx, rbx
    add [rel g_line_len], rax
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_end — terminate the current line, write it out, release the lock.
;   in/out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_end, 16, rbx
    lea rbx, [rel g_line]
    mov rax, [rel g_line_len]
    mov word [rbx + rax], 0x0A0D        ; "\r\n"
    mov byte [rbx + rax + 2], 0
    add rax, 2
    mov [rel g_line_len], rax

    mov rcx, [rel g_log_file]
    test rcx, rcx
    jz .no_file
    lea r9, [LOCAL(0)]
    API WriteFile, rcx, rbx, [rel g_line_len], r9, 0
.no_file:
    mov rcx, [rel g_log_console]
    test rcx, rcx
    jz .no_console
    lea r9, [LOCAL(0)]
    API WriteFile, rcx, rbx, [rel g_line_len], r9, 0
.no_console:
    API OutputDebugStringA, rbx

    mov qword [rel g_line_len], 0
    lea rcx, [rel g_log_lock]
    API ReleaseSRWLockExclusive, rcx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_msg — log one line "message".
;   in:  ecx = level, rdx = message (zero-terminated)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_msg, 0, rbx
    mov rbx, rdx
    call log_begin
    mov rcx, rbx
    call log_append_str
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_val — log one line "message <decimal value>" (a space is inserted).
;   in:  ecx = level, rdx = message, r8 = unsigned value
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_val, 0, rbx, rsi
    mov rbx, rdx
    mov rsi, r8
    call log_begin
    mov rcx, rbx
    call log_append_str
    lea rcx, [rel str_space]
    call log_append_str
    mov rcx, rsi
    call log_append_dec
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_hex — log one line "message 0x<hex value>" (a space is inserted).
;   in:  ecx = level, rdx = message, r8 = value
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_hex, 0, rbx, rsi
    mov rbx, rdx
    mov rsi, r8
    call log_begin
    mov rcx, rbx
    call log_append_str
    lea rcx, [rel str_space]
    call log_append_str
    mov rcx, rsi
    call log_append_hex
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_fatal — log an error, show it in a message box and exit with code 1.
;   in:  rcx = message
;   out: does not return
; -----------------------------------------------------------------------------
PROC log_fatal, 0, rbx
    mov rbx, rcx
    INVOKE log_msg, LOG_LEVEL_ERROR, rbx
    mov rcx, [rel g_log_file]
    test rcx, rcx
    jz .box
    API CloseHandle, rcx
    mov qword [rel g_log_file], 0
.box:
    lea r8, [rel str_fatal_title]
    API MessageBoxA, 0, rbx, r8, MB_OK | MB_ICONERROR
    API ExitProcess, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; assert_fail — report a failed ASSERT and exit with code 3.
;   in:  rcx = source file name, edx = line number, r8 = message
;   out: does not return
; -----------------------------------------------------------------------------
PROC assert_fail, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov esi, edx
    mov rdi, r8
    mov ecx, LOG_LEVEL_ERROR
    call log_begin
    lea rcx, [rel str_assert_head]
    call log_append_str
    mov rcx, rdi
    call log_append_str
    lea rcx, [rel str_assert_at]
    call log_append_str
    mov rcx, rbx
    call log_append_str
    lea rcx, [rel str_colon]
    call log_append_str
    mov ecx, esi
    call log_append_dec
    call log_end
    lea r8, [rel str_assert_title]
    API MessageBoxA, 0, rdi, r8, MB_OK | MB_ICONERROR
    API ExitProcess, 3
    RETURN
ENDPROC
