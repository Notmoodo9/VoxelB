; =============================================================================
; entry.asm — process entry point and main loop.
;
; Command line options:
;   --autoclose <ms>   close the window automatically after <ms> milliseconds
;                      (automated test runs; exit code stays 0)
;   --novsync          start with vsync off (toggle_vsync action at runtime)
;   --workers <n>      number of job worker threads (default: CPUs - 1)
;   --flytest          fly north through everything at flytest_speed
;                      (data/entities/player.cfg; streaming test)
;   --pos <x> <y> <z>  start with the player's eyes here, flying (blocks)
;   --seed <n>         world seed (overrides data/world/world.cfg)
;   --flat             use the flat test world (block gallery)
;   --survey           log terrain statistics and places to visit
;   --held-light       start with the held light on (toggle_held_light)
;   --held <block>     start holding this block (placing tests; e.g. water)
;   --world <name>     play the world saved in saves/<name>/ (default "world";
;                      created if missing)
;   --nosave           neither load nor save anything (tests)
;   --time <0..24>     start at this hour (overrides world.cfg's start_time)
;   --daylight <0..100>  sky light strength in percent (preview of night
;                      lighting until the day/night cycle, milestone 14)
;   --look <yaw> <pitch>  start view direction in degrees (yaw 0 = north,
;                      90 = east; pitch > 0 looks up)
;   --selftest         run the arena/pool/job self test at start (always on
;                      in debug builds); a failure exits with code 4
;
; Startup: log -> CPU check -> memory arenas -> job workers -> self test ->
; paths (find data\) -> controls.cfg -> window -> OpenGL ->
; input -> renderer -> text -> camera -> world -> day cycle -> client +
; simulation -> timer.
; Frame loop: reset frame arena -> new input frame -> pump messages -> actions (menu, capture,
; vsync, overlay, shader reload) -> shader hot-reload poll -> camera (look)
; -> client input -> simulation ticks -> client view (camera position,
; time) -> streaming, LOD -> render -> overlay -> swap -> timing.
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
%include "jobs.inc"
%include "packet.inc"

global main_entry

extern str_find, str_parse_u64, str_copy, str_append_dec, str_parse_float
extern renderer_init, renderer_frame, renderer_shutdown
extern camera_init, camera_update
extern overlay_draw, overlay_toggle, hud_draw
extern cpu_detect, selftest_run
extern world_init, world_render_init, world_render_shutdown
extern terrain_survey
extern world_spawn, g_seed_override, g_seed_override_set, g_force_flat
extern stream_init, stream_update, stream_shutdown, settings_load
extern lod_init, lod_update, lod_shutdown, g_held_on, g_daylight
extern daycycle_init, g_time_override
extern sim_init, sim_update, client_init, client_input, client_view
extern block_find, g_held_block
extern save_open, save_load_player, save_update, save_all
extern g_save_enabled, g_save_player_flags, g_save_held
extern block_textures_poll
extern g_cam_pos, g_cam_yaw, g_cam_pitch
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
opt_workers:        db "--workers", 0
opt_workers_len     equ $ - opt_workers - 1
opt_selftest:       db "--selftest", 0
opt_flytest:        db "--flytest", 0
opt_pos:            db "--pos ", 0
opt_seed:           db "--seed ", 0
opt_flat:           db "--flat", 0
opt_survey:         db "--survey", 0
opt_look:           db "--look ", 0
opt_held:           db "--held-light", 0
opt_held_block:     db "--held ", 0
opt_world:          db "--world ", 0
opt_nosave:         db "--nosave", 0
opt_daylight:       db "--daylight ", 0
opt_time:           db "--time ", 0
align 4
c_deg_to_rad:       dd 0.0174532925
align 4
c_hundred:          dd 100.0
str_cpu_fail:       db "This CPU lacks SSE4.2, which VoxelB requires.", 0
str_mem_fail:       db "Could not reserve memory. See voxel.log for details.", 0
str_jobs_fail:      db "Could not start worker threads. See voxel.log for details.", 0
str_cmdline:        db "command line: ", 0
str_paths_fail:     db "The data folder was not found next to voxelb.exe.", 13, 10
                    db "Keep voxelb.exe together with its data, shaders and assets folders.", 0
str_controls_fail:  db "Could not read data/config/controls.cfg. See voxel.log for details.", 0
str_init_fail:      db "Renderer start-up failed (shader or font). See voxel.log for details.", 0
str_world_fail:     db "World start-up failed. See voxel.log for details.", 0
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
g_start_flags:      resd 1              ; PF_FLYING / PF_NOCLIP for the player
g_flytest:          resd 1
g_held_name:        resb 64
g_world_arg:        resb 64

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

    ; ---- CPU, memory, jobs, self test --------------------------------------------------
    call cpu_detect
    test eax, eax
    jnz .cpu_ok
    lea rcx, [rel str_cpu_fail]
    call log_fatal
.cpu_ok:
    call mem_init
    test eax, eax
    jnz .mem_ok
    lea rcx, [rel str_mem_fail]
    call log_fatal
.mem_ok:
    xor esi, esi                        ; requested workers (0 = auto)
    lea rdx, [rel opt_workers]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .workers_auto
    lea rcx, [rax + opt_workers_len]
    call str_parse_u64
    mov esi, eax
.workers_auto:
    INVOKE jobs_init, rsi
    test eax, eax
    jnz .jobs_ok
    lea rcx, [rel str_jobs_fail]
    call log_fatal
.jobs_ok:
    call timer_init                     ; the self test measures time
%if BUILD_DEBUG
    jmp .run_selftest
%endif
    lea rdx, [rel opt_selftest]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .selftest_done
.run_selftest:
    call selftest_run
    test eax, eax
    jnz .selftest_done
    mov dword [rel g_exit_code], 4
    jmp .shutdown_core
.selftest_done:

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
    call settings_load

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
    ; --seed n / --flat (read by world_init)
    lea rdx, [rel opt_seed]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_seed
    lea rcx, [rax + 7]
    call str_parse_u64
    test r8, r8
    jz .no_seed
    mov [rel g_seed_override], eax
    mov dword [rel g_seed_override_set], 1
.no_seed:
    lea rdx, [rel opt_flat]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_flat
    mov dword [rel g_force_flat], 1
.no_flat:
    ; the save (milestone 17): --nosave, --world <name>; world.dat may set
    ; the seed, generator and time
    lea rdx, [rel opt_nosave]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .save_on
    mov dword [rel g_save_enabled], 0
.save_on:
    xor esi, esi                        ; world name (0: default)
    lea rdx, [rel opt_world]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .world_named
    lea rdx, [rax + 8]
    lea rdi, [rel g_world_arg]
    xor ecx, ecx
.world_copy:
    mov al, [rdx + rcx]
    cmp al, ' '
    jbe .world_end
    cmp al, '\'
    je .world_end                       ; (a folder name, not a path)
    cmp al, '/'
    je .world_end
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 63
    jb .world_copy
.world_end:
    mov byte [rdi + rcx], 0
    test ecx, ecx
    jz .world_named
    mov rsi, rdi
.world_named:
    mov rcx, rsi
    call save_open
    call world_init
    test eax, eax
    jz .world_fail
    call world_render_init
    test eax, eax
    jz .world_fail
    call stream_init
    test eax, eax
    jz .world_fail
    call lod_init
    test eax, eax
    jnz .world_ok
.world_fail:
    lea rcx, [rel str_world_fail]
    call log_fatal
.world_ok:
    call camera_init
    lea rcx, [rel g_cam_pos]
    call world_spawn                    ; terrain: start above land
    test eax, eax
    jz .no_survey
    lea rdx, [rel opt_survey]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_survey
    call terrain_survey
.no_survey:
    ; a saved player: where they were, flying or not (--pos still wins)
    call save_load_player
    test eax, eax
    jz .no_saved_player
    mov eax, [rel g_save_player_flags]
    or [rel g_start_flags], eax
.no_saved_player:
    ; --pos x y z
    lea rdx, [rel opt_pos]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_pos
    lea rcx, [rax + 6]
    xor esi, esi
.pos_coord:
    call str_parse_float
    test eax, eax
    jz .no_pos
    cvtss2sd xmm0, xmm0
    lea rax, [rel g_cam_pos]
    movsd [rax + rsi * 8], xmm0
    mov rcx, rdx
    inc esi
    cmp esi, 3
    jb .pos_coord
    or dword [rel g_start_flags], PF_FLYING   ; (hover where --pos says)
    LOG_INFO "camera: start position from --pos"
.no_pos:
    ; --look yaw pitch (degrees)
    lea rdx, [rel opt_look]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_look
    lea rcx, [rax + 7]
    call str_parse_float
    test eax, eax
    jz .no_look
    mulss xmm0, [rel c_deg_to_rad]
    movss [rel g_cam_yaw], xmm0
    mov rcx, rdx
    call str_parse_float
    test eax, eax
    jz .no_look
    mulss xmm0, [rel c_deg_to_rad]
    movss [rel g_cam_pitch], xmm0
.no_look:
    lea rdx, [rel opt_daylight]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_daylight
    lea rcx, [rax + 11]
    call str_parse_u64
    test r8, r8
    jz .no_daylight
    cmp rax, 100
    ja .no_daylight
    cvtsi2ss xmm0, eax
    divss xmm0, [rel c_hundred]
    movss [rel g_daylight], xmm0
.no_daylight:
    lea rdx, [rel opt_time]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_time
    lea rcx, [rax + 7]
    call str_parse_float
    test eax, eax
    jz .no_time
    movss [rel g_time_override], xmm0
.no_time:
    lea rdx, [rel opt_held]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_held_opt
    mov dword [rel g_held_on], 1
.no_held_opt:
    call daycycle_init                  ; (after --time)
    lea rdx, [rel opt_flytest]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_flytest
    or dword [rel g_start_flags], PF_FLYING | PF_NOCLIP
    mov dword [rel g_flytest], 1
    LOG_INFO "flytest: flying north through everything"
.no_flytest:
    mov ecx, [rel g_flytest]
    call client_init
    mov eax, [rel g_save_held]
    test eax, eax
    jz .no_saved_held
    mov [rel g_held_block], eax
.no_saved_held:
    ; --held <block name>
    lea rdx, [rel opt_held_block]
    INVOKE str_find, rbx, rdx
    test rax, rax
    jz .no_held_block
    lea rsi, [rax + 7]                  ; the name: up to the next space
    lea rdi, [rel g_held_name]
    xor ecx, ecx
.held_copy:
    mov al, [rsi + rcx]
    cmp al, ' '
    jbe .held_end
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 63
    jb .held_copy
.held_end:
    mov byte [rdi + rcx], 0
    lea rcx, [rel g_held_name]
    call block_find
    cmp eax, 0
    jle .no_held_block
    mov [rel g_held_block], eax
.no_held_block:
    lea rcx, [rel g_cam_pos]
    mov edx, [rel g_start_flags]
    call sim_init
    call client_view                    ; (the spawn state)
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
    lea rcx, [rel g_arena_frame]
    call arena_reset
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
    mov ecx, ACT_TOGGLE_HELD_LIGHT
    call input_pressed
    test eax, eax
    jz .no_held
    xor dword [rel g_held_on], 1
.no_held:
    call shader_poll
    call block_textures_poll

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
    call client_input
    call sim_update
    call client_view
    call save_update                    ; autosave
    call stream_update
    call lod_update
    mov ecx, [rel g_client_w]
    mov edx, [rel g_client_h]
    call renderer_frame
    mov ecx, [rel g_client_w]
    mov edx, [rel g_client_h]
    call hud_draw
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
    call save_all                       ; (before the columns are freed)
    call text_shutdown
    call lod_shutdown
    call stream_shutdown
    call world_render_shutdown
    call renderer_shutdown
    call shader_shutdown
    call gl_shutdown
    call window_shutdown
.shutdown_core:
    call jobs_shutdown
    call mem_shutdown
    mov eax, [rel g_exit_code]
    LOG_VAL LOG_LEVEL_INFO, "clean exit, code =", rax
    call log_shutdown
    mov ecx, [rel g_exit_code]
    API ExitProcess, rcx
    RETURN
ENDPROC
