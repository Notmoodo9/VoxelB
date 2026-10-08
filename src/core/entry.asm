; =============================================================================
; entry.asm — process entry point and main loop.
;
; Command line options:
;   --autoclose <ms>   close the window automatically after <ms> milliseconds
;                      (used by automated test runs; exit code stays 0)
; =============================================================================
%include "macros.inc"
%include "win32.inc"
%include "log.inc"
%include "window.inc"

global main_entry

extern str_find, str_parse_u64

IMPORT GetCommandLineA, Sleep, ExitProcess
IMPORT QueryPerformanceFrequency, QueryPerformanceCounter

%define DEFAULT_CLIENT_W    1280
%define DEFAULT_CLIENT_H    720

section .rdata
window_title:       db "VoxelB", 0
opt_autoclose:      db "--autoclose", 0
opt_autoclose_len   equ $ - opt_autoclose - 1
str_cmdline:        db "command line: ", 0
str_window_fail:    db "Failed to create the main window. See voxel.log for details.", 0
%if BUILD_DEBUG
str_build:          db "VoxelB starting (debug build)", 0
%else
str_build:          db "VoxelB starting (release build)", 0
%endif

section .text

; -----------------------------------------------------------------------------
; main_entry — process entry point (linker /entry). Initializes logging and
; the window, runs the main loop until the window closes, shuts down cleanly
; and exits the process with the WM_QUIT exit code.
;   in:  none (Windows entry point)
;   out: does not return (ExitProcess)
; -----------------------------------------------------------------------------
PROC main_entry, 32, rbx, rsi, rdi, r12
    call log_init
    mov ebx, eax
    lea rdx, [rel str_build]
    INVOKE log_msg, LOG_LEVEL_INFO, rdx
    test ebx, ebx
    jnz .log_ok
    LOG_WARN "could not open voxel.log; logging to console/debugger only"
.log_ok:

    ; ---- command line ------------------------------------------------------
    API GetCommandLineA
    mov rbx, rax                        ; rbx = command line
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_cmdline]
    call log_append_str
    mov rcx, rbx
    call log_append_str
    call log_end

    xor r12d, r12d                      ; r12 = autoclose ms
    lea rdx, [rel opt_autoclose]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_autoclose
    lea rcx, [rax + opt_autoclose_len]
    call str_parse_u64
    test r8, r8
    jnz .autoclose_parsed
    LOG_WARN "--autoclose needs a millisecond value; ignored"
    jmp .no_autoclose
.autoclose_parsed:
    mov r12, rax
.no_autoclose:

    ; ---- window ------------------------------------------------------------
    lea r8, [rel window_title]
    INVOKE window_init, DEFAULT_CLIENT_W, DEFAULT_CLIENT_H, r8, r12
    test eax, eax
    jnz .window_ok
    lea rcx, [rel str_window_fail]
    call log_fatal
.window_ok:

    ; ---- main loop ---------------------------------------------------------
    lea rcx, [LOCAL(0)]
    API QueryPerformanceFrequency, rcx
    lea rcx, [LOCAL(8)]
    API QueryPerformanceCounter, rcx
    xor esi, esi                        ; rsi = loop iterations
    LOG_INFO "entering main loop"
.loop:
    call window_pump
    test eax, eax
    jz .loop_done
    inc rsi
    ; Nothing to simulate or render yet (Milestone 1): yield the CPU instead
    ; of spinning. Milestone 2 replaces this with rendering + vsync.
    API Sleep, 1
    jmp .loop
.loop_done:
    lea rcx, [LOCAL(16)]
    API QueryPerformanceCounter, rcx
    mov rax, [LOCAL(16)]
    sub rax, [LOCAL(8)]
    mov rcx, 1000
    mul rcx
    mov rcx, [LOCAL(0)]
    div rcx
    mov rdi, rax                        ; rdi = loop time in ms
    LOG_VAL LOG_LEVEL_INFO, "main loop finished, iterations =", rsi
    LOG_VAL LOG_LEVEL_INFO, "main loop run time ms =", rdi

    ; ---- shutdown ------------------------------------------------------------
    call window_shutdown
    mov eax, [rel g_exit_code]
    LOG_VAL LOG_LEVEL_INFO, "clean exit, code =", rax
    call log_shutdown
    mov ecx, [rel g_exit_code]
    API ExitProcess, rcx
    RETURN
ENDPROC
