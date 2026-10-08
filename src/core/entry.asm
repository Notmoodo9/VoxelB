; =============================================================================
; entry.asm — process entry point and main loop.
;
; Command line options:
;   --autoclose <ms>   close the window automatically after <ms> milliseconds
;                      (automated test runs; exit code stays 0)
;   --novsync          start with vsync off (toggle_vsync action at runtime)
;
; Startup: log -> paths (find data\) -> controls.cfg -> window -> OpenGL ->
; input -> renderer -> text -> camera -> timer.
; Frame loop: new input frame -> pump messages -> actions (menu, capture,
; vsync, overlay, shader reload) -> shader hot-reload poll -> camera ->
; render -> overlay -> swap -> timing.
; Every stats window (0.5 s) the title bar shows FPS and frame times; every
; PERF_LOG_EVERY windows the same line goes to the log.
; =============================================================================
%include "macros.inc"
%include "win32.inc"
%include "log.inc"
%include "window.inc"
%include "gl.inc"
%include "file.inc"
%include "input.inc"
%include "shader.inc"
%include "text.inc"

global main_entry

extern str_find, str_parse_u64, str_copy, str_append_dec
extern renderer_init, renderer_frame, renderer_shutdown
extern camera_init, camera_update
extern overlay_draw, overlay_toggle
extern timer_init, timer_frame, timer_reset, timer_elapsed_us
extern g_total_frames, g_stat_fps_x10, g_stat_avg_us, g_stat_min_us, g_stat_max_us

IMPORT GetCommandLineA, Sleep, ExitProcess, SetWindowTextA

%define DEFAULT_CLIENT_W    1280
%define DEFAULT_CLIENT_H    720
%define PERF_LOG_EVERY      4           ; stats windows between perf log lines
%define MINIMIZED_SLEEP_MS  16

section .rdata
window_title:       db "VoxelB", 0
opt_autoclose:      db "--autoclose", 0
opt_autoclose_len   equ $ - opt_autoclose - 1
opt_novsync:        db "--novsync", 0
str_cmdline:        db "command line: ", 0
str_paths_fail:     db "The data folder was not found next to voxelb.exe.", 13, 10
                    db "Keep voxelb.exe together with its data, shaders and assets folders.", 0
str_controls_fail:  db "Could not read data/config/controls.cfg. See voxel.log for details.", 0
str_init_fail:      db "Renderer start-up failed (shader or font). See voxel.log for details.", 0
str_window_fail:    db "Failed to create the main window. See voxel.log for details.", 0
str_gl_fail:        db "Could not start OpenGL 4.5+ (core profile).", 13, 10, 13, 10
                    db "Please update your graphics driver. See voxel.log for details.", 0
str_title_prefix:   db "VoxelB  |  ", 0
str_perf_prefix:    db "perf: ", 0
str_fps:            db " FPS  |  ", 0
str_ms:             db " ms (min ", 0
str_max:            db ", max ", 0
str_vsync_on:       db ")  |  vsync on  |  GL ", 0
str_vsync_off:      db ")  |  vsync off  |  GL ", 0
str_dot:            db ".", 0
str_avg_fps:        db "average FPS over run: ", 0
%if BUILD_DEBUG
str_build:          db "VoxelB starting (debug build)", 0
%else
str_build:          db "VoxelB starting (release build)", 0
%endif

section .bss
g_stats_text:       resb 256            ; "60.0 FPS | 16.667 ms (...) | ..."
g_title_text:       resb 300

section .text

; -----------------------------------------------------------------------------
; build_stats_text — format the latest timer stats into g_stats_text.
;   in/out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC build_stats_text, 0
    lea rcx, [rel g_stats_text]
    INVOKE str_append_dec, rcx, [rel g_stat_fps_x10], 1
    lea rdx, [rel str_fps]
    INVOKE str_copy, rax, rdx
    mov rdx, [rel g_stat_avg_us]
    INVOKE str_append_dec, rax, rdx, 3
    lea rdx, [rel str_ms]
    INVOKE str_copy, rax, rdx
    mov rdx, [rel g_stat_min_us]
    INVOKE str_append_dec, rax, rdx, 3
    lea rdx, [rel str_max]
    INVOKE str_copy, rax, rdx
    mov rdx, [rel g_stat_max_us]
    INVOKE str_append_dec, rax, rdx, 3
    lea rdx, [rel str_vsync_on]
    cmp dword [rel g_vsync_on], 0
    jne .vs
    lea rdx, [rel str_vsync_off]
.vs:
    INVOKE str_copy, rax, rdx
    mov edx, [rel g_gl_major]
    INVOKE str_append_dec, rax, rdx, 0
    lea rdx, [rel str_dot]
    INVOKE str_copy, rax, rdx
    mov edx, [rel g_gl_minor]
    INVOKE str_append_dec, rax, rdx, 0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; main_entry — process entry point (linker /entry). Initializes logging, the
; window and OpenGL, runs the frame loop until a close is requested, shuts
; down in reverse order and exits with g_exit_code.
;   in:  none (Windows entry point)
;   out: does not return (ExitProcess)
; -----------------------------------------------------------------------------
PROC main_entry, 32, rbx, rsi, rdi, r12, r13
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
    mov r13d, 1                         ; r13 = initial vsync
    lea rdx, [rel opt_novsync]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .vsync_opt_done
    xor r13d, r13d
.vsync_opt_done:

    ; ---- data -----------------------------------------------------------------------
    call paths_init
    test eax, eax
    jnz .paths_ok
    lea rcx, [rel str_paths_fail]
    call log_fatal
.paths_ok:
    call input_load_bindings
    test eax, eax
    jnz .controls_ok
    lea rcx, [rel str_controls_fail]
    call log_fatal
.controls_ok:

    ; ---- window + OpenGL ---------------------------------------------------------
    lea r8, [rel window_title]
    INVOKE window_init, DEFAULT_CLIENT_W, DEFAULT_CLIENT_H, r8, r12
    test eax, eax
    jnz .window_ok
    lea rcx, [rel str_window_fail]
    call log_fatal
.window_ok:
    call gl_init
    test eax, eax
    jnz .gl_ok
    lea rcx, [rel str_gl_fail]
    call log_fatal
.gl_ok:
    INVOKE gl_set_vsync, r13
    call input_init
    call renderer_init
    test eax, eax
    jz .init_fail
    call text_init
    test eax, eax
    jnz .init_ok
.init_fail:
    lea rcx, [rel str_init_fail]
    call log_fatal
.init_ok:
    call camera_init
    call timer_init
    cmp dword [rel g_window_active], 0
    je .no_initial_capture
    mov ecx, 1
    call input_set_capture
.no_initial_capture:

    ; ---- frame loop --------------------------------------------------------------
    xor edi, edi                        ; rdi = stats windows since last perf log
    LOG_INFO "entering main loop"
.loop:
    call input_new_frame
    call window_pump
    test eax, eax
    jz .loop_done

    ; ---- actions ---------------------------------------------------------------------
    mov ecx, ACT_MENU
    call input_pressed
    test eax, eax
    jz .no_menu
    cmp dword [rel g_mouse_captured], 0
    je .menu_quit
    xor ecx, ecx
    call input_set_capture
    jmp .no_menu
.menu_quit:
    LOG_INFO "menu key with the mouse free: quitting"
    jmp .loop_done
.no_menu:
    cmp dword [rel g_mouse_captured], 0
    jne .capture_ok
    cmp dword [rel g_window_active], 0
    je .capture_ok
    mov ecx, VK_LBUTTON
    call input_vk_pressed
    test eax, eax
    jz .capture_ok
    mov ecx, 1
    call input_set_capture
.capture_ok:
    call input_update_capture

    mov ecx, ACT_TOGGLE_VSYNC
    call input_pressed
    test eax, eax
    jz .no_vsync_toggle
    mov ecx, [rel g_vsync_on]
    xor ecx, 1
    call gl_set_vsync
.no_vsync_toggle:
    mov ecx, ACT_TOGGLE_OVERLAY
    call input_pressed
    test eax, eax
    jz .no_overlay_toggle
    call overlay_toggle
.no_overlay_toggle:
    mov ecx, ACT_RELOAD_SHADERS
    call input_pressed
    test eax, eax
    jz .no_reload
    call shader_reload_all
.no_reload:
    call shader_poll

    ; minimised (zero-sized client area): don't render, don't spin
    mov ecx, [rel g_client_w]
    mov edx, [rel g_client_h]
    test ecx, ecx
    jz .idle
    test edx, edx
    jz .idle

    mov ecx, [rel g_client_w]
    mov edx, [rel g_client_h]
    call camera_update
    mov ecx, [rel g_client_w]
    mov edx, [rel g_client_h]
    call renderer_frame
    mov ecx, [rel g_client_w]
    mov edx, [rel g_client_h]
    call overlay_draw
    call gl_swap
    call timer_frame
    test eax, eax
    jz .loop

    ; new stats window: title bar every time, log every PERF_LOG_EVERY
    call build_stats_text
    lea rcx, [rel g_title_text]
    lea rdx, [rel str_title_prefix]
    call str_copy
    lea rdx, [rel g_stats_text]
    INVOKE str_copy, rax, rdx
    lea rdx, [rel g_title_text]
    API SetWindowTextA, [rel g_hwnd], rdx
    inc edi
    cmp edi, PERF_LOG_EVERY
    jb .loop
    xor edi, edi
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_perf_prefix]
    call log_append_str
    lea rcx, [rel g_stats_text]
    call log_append_str
    call log_end
    jmp .loop

.idle:
    API Sleep, MINIMIZED_SLEEP_MS
    call timer_reset
    jmp .loop

.loop_done:
    call timer_elapsed_us
    mov rsi, rax                        ; rsi = run time us
    mov rbx, [rel g_total_frames]
    LOG_VAL LOG_LEVEL_INFO, "frames rendered:", rbx
    xor edx, edx
    mov rax, rsi
    mov ecx, 1000
    div rcx
    LOG_VAL LOG_LEVEL_INFO, "run time ms:", rax
    ; average fps over the whole run, one decimal
    test rsi, rsi
    jz .no_avg
    mov rax, rbx
    imul rax, rax, 10000000
    xor edx, edx
    div rsi
    lea rcx, [rel g_stats_text]
    INVOKE str_append_dec, rcx, rax, 1
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_avg_fps]
    call log_append_str
    lea rcx, [rel g_stats_text]
    call log_append_str
    call log_end
.no_avg:

    ; ---- shutdown (reverse order) ------------------------------------------------
    xor ecx, ecx
    call input_set_capture
    call text_shutdown
    call renderer_shutdown
    call shader_shutdown
    call gl_shutdown
    call window_shutdown
    mov eax, [rel g_exit_code]
    LOG_VAL LOG_LEVEL_INFO, "clean exit, code =", rax
    call log_shutdown
    mov ecx, [rel g_exit_code]
    API ExitProcess, rcx
    RETURN
ENDPROC
