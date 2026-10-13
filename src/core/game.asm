; =============================================================================
; game.asm — the game's states: menus over a flyover world, playing, paused
; (milestone 17, design/ui/menus.md, DECISIONS D89).
;
;   GS_MENU     the main menu and its screens (menu.asm) over a world from
;               data/ui/menu.cfg, seen from a camera gliding along a path;
;               nothing is simulated or saved
;   GS_PLAYING  a saved world: input -> simulation -> view, autosave;
;               Esc pauses (the pause menu), Esc again resumes
; Switching worlds tears the current one down (save, unload every column
; and LOD tile, empty the simulation's queues) and starts the next with its
; own seed, player and time.
;
; Public API:
;   game_init(ecx = 1: a world was started by the command line, 0: menus)
;   game_frame(ecx = w, edx = h) -> eax 1 to quit
;   game_begin_world(rcx = name, edx = 1 new world with seed r8d / 0 load)
;   game_enter_menu()
;   g_game_state (GS_*), g_game_paused
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "input.inc"
%include "packet.inc"
%include "file.inc"
%include "cfg.inc"
%include "memory.inc"

global game_init, game_frame, game_begin_world, game_enter_menu
global g_game_state, g_game_paused, g_menu_fade

extern camera_update, client_init, client_input, client_view
extern sim_init, sim_update, save_update, save_all, save_open, save_load_player
extern stream_update, stream_reset, lod_update, lod_reset, fluid_reset, edit_reset
extern thumb_update, thumb_reset, menu_screen, g_show_hud
extern inv_screen_open, inv_screen_close, inv_screen_frame, inv_screen_typing
extern client_input_idle, held_draw
extern g_world_mode, g_world_difficulty, g_world_hardcore
extern g_new_mode, g_new_difficulty, g_new_hardcore
extern renderer_frame, hud_draw, overlay_draw, menu_frame, menu_open, menu_back
extern daycycle_init, daycycle_set, world_spawn
extern pkt_recv, g_to_sim, g_to_client
extern g_cam_pos, g_cam_yaw, g_cam_pitch, g_world_seed, g_seed_override
extern g_seed_override_set, g_time_override, g_save_enabled, g_save_exists
extern g_save_player_flags, g_save_held, g_held_block, g_window_active
extern g_frame_us, str_ieq, str_parse_float, str_parse_u64

%define GS_MENU         0
%define GS_PLAYING      1
%define MAX_POINTS      16
%define SCREEN_MAIN     0
%define SCREEN_PAUSE    3

section .rdata
str_menu_cfg:   db "data/ui/menu.cfg", 0
str_menu_lbl:   db "menu.cfg", 0
k_seed:         db "seed", 0
k_time:         db "time", 0
k_speed:        db "speed", 0
k_look_at:      db "look_at", 0
k_point:        db "point", 0
align 4
c_us:           dd 0.000001
c_24:           dd 24.0
c_max_dt:       dd 0.1
c_start_pitch:  dd -0.35
c_fade_s:       dd 1.5                  ; flyover fade at each end (seconds)
c_one:          dd 1.0
c_minus_one:    dd -1.0

section .data
align 4
g_fly_speed_m:  dd 7.0
g_fly_time:     dd 17.4
g_fly_seed:     dd 20261009
g_menu_fade:    dd 1.0                  ; black over the flyover (0..1)

section .bss
alignb 4
g_game_state:   resd 1
g_game_paused:  resd 1
g_save_allowed: resd 1                  ; not --nosave
g_inv_open:     resd 1                  ; the inventory screen is open
g_default_seed: resd 1
g_menu_loaded:  resd 1
g_fly_n:        resd 1
g_fly_points:   resd MAX_POINTS * 3     ; f32 x, y, z
g_fly_len:      resd MAX_POINTS         ; f32 segment lengths
g_fly_total:    resd 1
g_fly_s:        resd 1                  ; f32 distance along the path
g_fly_look:     resd 3
g_fly_tmp:      resd 2
alignb 16
g_pkt_tmp:      resb PKT_SIZE
g_path:         resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; game_init — remember the start-up settings; open the menus unless the
; command line already started a world.
;   in:  ecx = 1 a world is running (GS_PLAYING), 0 menus
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC game_init, 0, rbx
    mov ebx, ecx
    mov eax, [rel g_save_enabled]
    mov [rel g_save_allowed], eax
    mov eax, [rel g_world_seed]
    mov [rel g_default_seed], eax
    test ebx, ebx
    jz .menu
    mov dword [rel g_game_state], GS_PLAYING
    RETURN
.menu:
    call game_enter_menu
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; menu_pair — menu.cfg callback.
; -----------------------------------------------------------------------------
PROC menu_pair, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    lea rdx, [rel k_seed]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_seed
    mov rcx, rsi
    call str_parse_u64
    mov [rel g_fly_seed], eax
    RETURN
.not_seed:
    lea rdx, [rel k_time]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_time
    mov rcx, rsi
    call str_parse_float
    movss [rel g_fly_time], xmm0
    RETURN
.not_time:
    lea rdx, [rel k_speed]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_speed
    mov rcx, rsi
    call str_parse_float
    movss [rel g_fly_speed_m], xmm0
    RETURN
.not_speed:
    lea rdi, [rel g_fly_look]
    lea rdx, [rel k_look_at]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .three
    lea rdx, [rel k_point]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .done
    mov eax, [rel g_fly_n]
    cmp eax, MAX_POINTS
    jae .done
    inc dword [rel g_fly_n]
    imul eax, eax, 12
    lea rdi, [rel g_fly_points]
    add rdi, rax
.three:
    mov rcx, rsi
    call str_parse_float
    movss [rdi], xmm0
    lea rcx, [rdx + 1]
    call str_parse_float
    movss [rdi + 4], xmm0
    lea rcx, [rdx + 1]
    call str_parse_float
    movss [rdi + 8], xmm0
.done:
    RETURN
ENDPROC

; load_menu_cfg — data/ui/menu.cfg once; segment lengths
PROC load_menu_cfg, 16, rbx
    cmp dword [rel g_menu_loaded], 0
    jne .done
    mov dword [rel g_menu_loaded], 1
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rcx, [rel g_path]
    lea rdx, [rel str_menu_cfg]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .missing
    lea rdx, [rel menu_pair]
    lea r9, [rel str_menu_lbl]
    INVOKE cfg_parse, rax, rdx, 0, r9
    jmp .loaded
.missing:
    LOG_WARN "data/ui/menu.cfg not found: the menu shows a still view"
.loaded:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    ; at least one point (the origin, high up)
    cmp dword [rel g_fly_n], 0
    jne .lengths
    mov dword [rel g_fly_n], 1
    mov dword [rel g_fly_points + 4], 0x43480000    ; 200.0
.lengths:
    xorps xmm3, xmm3                    ; total
    xor ebx, ebx
.seg:
    lea eax, [ebx + 1]
    cmp eax, [rel g_fly_n]
    jae .segs_done
    imul ecx, ebx, 12
    lea rdx, [rel g_fly_points]
    movss xmm0, [rdx + rcx + 12]
    subss xmm0, [rdx + rcx]
    mulss xmm0, xmm0
    movss xmm1, [rdx + rcx + 16]
    subss xmm1, [rdx + rcx + 4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [rdx + rcx + 20]
    subss xmm1, [rdx + rcx + 8]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    lea rdx, [rel g_fly_len]
    movss [rdx + rbx * 4], xmm0
    addss xmm3, xmm0
    inc ebx
    jmp .seg
.segs_done:
    movss [rel g_fly_total], xmm3
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; atan2f — xmm0 = atan2(xmm0 = y, xmm1 = x) (x87).   clobbers: x87
; -----------------------------------------------------------------------------
atan2f:
    movss [rel g_fly_tmp], xmm0
    movss [rel g_fly_tmp + 4], xmm1
    fld dword [rel g_fly_tmp]           ; y
    fld dword [rel g_fly_tmp + 4]       ; x
    fpatan                              ; atan(y / x), quadrant-correct
    fstp dword [rel g_fly_tmp]
    movss xmm0, [rel g_fly_tmp]
    ret

; -----------------------------------------------------------------------------
; flyover_update — move the menu camera along the path (dt seconds in
; xmm0), facing look_at; set the fade.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC flyover_update, 16, rbx
    mulss xmm0, [rel g_fly_speed_m]
    addss xmm0, [rel g_fly_s]
    comiss xmm0, [rel g_fly_total]
    jb .on_path
    xorps xmm0, xmm0                    ; the end: start again
.on_path:
    movss [rel g_fly_s], xmm0
    ; which segment
    xor ebx, ebx
    lea rax, [rel g_fly_len]
.find:
    lea ecx, [ebx + 1]
    cmp ecx, [rel g_fly_n]
    jae .at_end
    comiss xmm0, [rax + rbx * 4]
    jbe .in_seg
    subss xmm0, [rax + rbx * 4]
    inc ebx
    jmp .find
.in_seg:
    movss xmm1, [rax + rbx * 4]
    xorps xmm2, xmm2
    comiss xmm1, xmm2
    je .at_end
    divss xmm0, xmm1                    ; t in the segment
    imul ecx, ebx, 12
    lea rdx, [rel g_fly_points]
%assign i 0
%rep 3
    movss xmm1, [rdx + rcx + 12 + i * 4]
    subss xmm1, [rdx + rcx + i * 4]
    mulss xmm1, xmm0
    addss xmm1, [rdx + rcx + i * 4]
    cvtss2sd xmm1, xmm1
    movsd [rel g_cam_pos + i * 8], xmm1
%assign i i + 1
%endrep
    jmp .look
.at_end:
    imul ecx, ebx, 12
    lea rdx, [rel g_fly_points]
%assign i 0
%rep 3
    cvtss2sd xmm1, [rdx + rcx + i * 4]
    movsd [rel g_cam_pos + i * 8], xmm1
%assign i i + 1
%endrep
.look:
    ; yaw = atan2(dx, -dz), pitch = atan2(dy, horizontal distance)
    cvtsd2ss xmm2, [rel g_cam_pos]
    movss xmm0, [rel g_fly_look]
    subss xmm0, xmm2                    ; dx
    movss [LOCAL(0)], xmm0
    cvtsd2ss xmm2, [rel g_cam_pos + 16]
    movss xmm1, [rel g_fly_look + 8]
    subss xmm1, xmm2                    ; dz
    movss [LOCAL(4)], xmm1
    xorps xmm3, xmm3
    subss xmm3, xmm1
    movss xmm1, xmm3                    ; -dz
    call atan2f
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jae .yaw_pos
    addss xmm0, [rel c_two_pi]
.yaw_pos:
    movss [rel g_cam_yaw], xmm0
    movss xmm1, [LOCAL(0)]
    mulss xmm1, xmm1
    movss xmm2, [LOCAL(4)]
    mulss xmm2, xmm2
    addss xmm1, xmm2
    sqrtss xmm1, xmm1
    cvtsd2ss xmm2, [rel g_cam_pos + 8]
    movss xmm0, [rel g_fly_look + 4]
    subss xmm0, xmm2                    ; dy
    call atan2f
    movss [rel g_cam_pitch], xmm0
    ; fade near both ends of the path
    movss xmm0, [rel g_fly_s]
    movss xmm1, [rel g_fly_total]
    subss xmm1, xmm0
    minss xmm0, xmm1
    movss xmm1, [rel g_fly_speed_m]
    mulss xmm1, [rel c_fade_s]
    divss xmm0, xmm1
    minss xmm0, [rel c_one]
    movss xmm1, [rel c_one]
    subss xmm1, xmm0
    movss [rel g_menu_fade], xmm1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; world_teardown — save (if playing) and unload the current world.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_teardown, 0
    mov dword [rel g_inv_open], 0
    cmp dword [rel g_game_state], GS_PLAYING
    jne .unload
    call save_all                       ; (no-op when saving is off)
.unload:
    call stream_reset
    call lod_reset
    call fluid_reset
    call edit_reset
.drain_sim:
    lea rcx, [rel g_to_sim]
    lea rdx, [rel g_pkt_tmp]
    call pkt_recv
    test eax, eax
    jnz .drain_sim
.drain_client:
    lea rcx, [rel g_to_client]
    lea rdx, [rel g_pkt_tmp]
    call pkt_recv
    test eax, eax
    jnz .drain_client
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; game_enter_menu — the flyover world and the main menu.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC game_enter_menu, 0
    call world_teardown
    mov dword [rel g_save_enabled], 0   ; (the menu world is never saved)
    call load_menu_cfg
    mov eax, [rel g_fly_seed]
    mov [rel g_world_seed], eax
    mov dword [rel g_fly_s], 0
    xorps xmm0, xmm0
    call flyover_update
    mov dword [rel g_menu_fade], 0x3F800000
    movss xmm0, [rel g_fly_time]
    divss xmm0, [rel c_24]
    call daycycle_set
    mov dword [rel g_game_state], GS_MENU
    mov dword [rel g_game_paused], 0
    xor ecx, ecx
    call input_set_capture
    mov ecx, SCREEN_MAIN
    call menu_open
    LOG_INFO "game: main menu"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; game_begin_world — play a world (load it, or create it with a seed).
;   in:  rcx = world name, edx = 1 new world with seed r8d, 0 load
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC game_begin_world, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov esi, edx
    mov edi, r8d
    call world_teardown
    mov eax, [rel g_save_allowed]
    mov [rel g_save_enabled], eax
    mov [rel g_seed_override_set], esi
    mov [rel g_seed_override], edi
    mov dword [rel g_time_override], 0xBF800000     ; -1: world.dat / world.cfg
    mov rcx, rbx
    call save_open
    call thumb_reset
    test esi, esi
    jz .rules                           ; (a loaded world: from world.dat)
    mov eax, [rel g_new_mode]
    mov [rel g_world_mode], eax
    mov eax, [rel g_new_difficulty]
    mov [rel g_world_difficulty], eax
    mov eax, [rel g_new_hardcore]
    mov [rel g_world_hardcore], eax
.rules:
    mov eax, [rel g_default_seed]
    cmp dword [rel g_seed_override_set], 0
    je .seed
    mov eax, [rel g_seed_override]
.seed:
    mov [rel g_world_seed], eax
    ; the player: the saved one, or the world's spawn
    mov dword [rel g_cam_yaw], 0
    mov eax, [rel c_start_pitch]
    mov [rel g_cam_pitch], eax
    lea rcx, [rel g_cam_pos]
    call world_spawn
    xor edi, edi                        ; flags
    call save_load_player
    test eax, eax
    jz .spawned
    mov edi, [rel g_save_player_flags]
.spawned:
    call daycycle_init
    xor ecx, ecx
    call client_init
    mov eax, [rel g_save_held]
    test eax, eax
    jz .held
    mov [rel g_held_block], eax
.held:
    lea rcx, [rel g_cam_pos]
    mov edx, edi
    call sim_init
    call client_view
    mov dword [rel g_game_state], GS_PLAYING
    mov dword [rel g_game_paused], 0
    ; a new world is on disk right away (it shows in the list)
    cmp dword [rel g_save_exists], 0
    jne .exists
    call save_all
.exists:
    cmp dword [rel g_window_active], 0
    je .done
    mov ecx, 1
    call input_set_capture
.done:
    LOG_INFO "game: playing"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; game_frame — one frame of the current state: input, simulation or
; flyover, streaming, rendering, HUD / menus, debug overlay.
;   in:  ecx = width, edx = height
;   out: eax = 1 to quit
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC game_frame, 16, rbx, rsi, rdi
    mov esi, ecx
    mov edi, edx
    xor ebx, ebx                        ; quit
    ; ---- Esc and the mouse ----
    mov ecx, ACT_MENU
    call input_pressed
    mov [LOCAL(0)], eax
    cmp dword [rel g_game_state], GS_PLAYING
    jne .menu_keys
    cmp dword [rel g_game_paused], 0
    jne .paused_keys
    cmp dword [rel g_inv_open], 0
    jne .inv_keys
    cmp dword [LOCAL(0)], 0
    je .inv_open_key
    call pause_game
    jmp .keys_done
.inv_open_key:
    mov ecx, ACT_INVENTORY
    call input_pressed
    test eax, eax
    jz .click_capture
    call open_inventory
    jmp .keys_done
.inv_keys:
    ; Esc, or the inventory key (unless typing a search), closes it
    cmp dword [LOCAL(0)], 0
    jne .inv_close
    call inv_screen_typing
    test eax, eax
    jnz .keys_done
    mov ecx, ACT_INVENTORY
    call input_pressed
    test eax, eax
    jz .keys_done
.inv_close:
    call close_inventory
    jmp .keys_done
.click_capture:
    cmp dword [rel g_mouse_captured], 0
    jne .keys_done
    cmp dword [rel g_window_active], 0
    je .keys_done
    mov ecx, VK_LBUTTON
    call input_vk_pressed
    test eax, eax
    jz .keys_done
    mov ecx, 1
    call input_set_capture
    jmp .keys_done
.paused_keys:
    cmp dword [LOCAL(0)], 0
    je .keys_done
    call menu_screen
    cmp eax, SCREEN_PAUSE
    je .resume
    call menu_back                      ; (settings over the pause menu)
    jmp .keys_done
.resume:
    call resume_game
    jmp .keys_done
.menu_keys:
    cmp dword [LOCAL(0)], 0
    je .keys_done
    call menu_back
.keys_done:
    call input_update_capture

    ; ---- the world ----
    mov ecx, esi
    mov edx, edi
    call camera_update
    cmp dword [rel g_game_state], GS_PLAYING
    je .playing
    ; menus: the flyover (time stands still)
    mov rax, [rel g_frame_us]
    cvtsi2ss xmm0, rax
    mulss xmm0, [rel c_us]
    minss xmm0, [rel c_max_dt]
    call flyover_update
    movss xmm0, [rel g_fly_time]
    divss xmm0, [rel c_24]
    call daycycle_set
    jmp .stream
.playing:
    cmp dword [rel g_game_paused], 0
    jne .stream
    cmp dword [rel g_inv_open], 0
    je .live_input
    call client_input_idle              ; (the inventory is open: stand still)
    jmp .sim
.live_input:
    call client_input
.sim:
    call sim_update
    call client_view
    call save_update
.stream:
    call stream_update
    call lod_update
    mov ecx, esi
    mov edx, edi
    call renderer_frame

    ; ---- on top ----
    cmp dword [rel g_game_state], GS_PLAYING
    jne .menus
    cmp dword [rel g_game_paused], 0
    jne .menus
    call thumb_update                   ; (the world list's picture, no HUD)
    cmp dword [rel g_show_hud], 0
    je .inventory
    mov ecx, esi
    mov edx, edi
    call held_draw                      ; the item in hand
    cmp dword [rel g_inv_open], 0
    jne .inventory                      ; (the inventory screen shows the hotbar)
    mov ecx, esi
    mov edx, edi
    call hud_draw
.inventory:
    cmp dword [rel g_inv_open], 0
    je .overlay
    mov ecx, esi
    mov edx, edi
    call inv_screen_frame
    jmp .overlay
.menus:
    mov ecx, esi
    mov edx, edi
    call menu_frame                     ; eax = MA_* action, edx = argument
    call do_action
    mov ebx, eax
.overlay:
    mov ecx, esi
    mov edx, edi
    call overlay_draw
    mov eax, ebx
    RETURN
ENDPROC

; open_inventory / close_inventory (milestone 18)
PROC open_inventory, 0
    mov dword [rel g_inv_open], 1
    xor ecx, ecx
    call input_set_capture
    call inv_screen_open
    RETURN
ENDPROC

PROC close_inventory, 0
    call inv_screen_close
    mov dword [rel g_inv_open], 0
    cmp dword [rel g_window_active], 0
    je .done
    mov ecx, 1
    call input_set_capture
.done:
    RETURN
ENDPROC

; pause_game / resume_game
PROC pause_game, 0
    mov dword [rel g_game_paused], 1
    xor ecx, ecx
    call input_set_capture
    mov ecx, SCREEN_PAUSE
    call menu_open
    RETURN
ENDPROC

PROC resume_game, 0
    mov dword [rel g_game_paused], 0
    mov ecx, 1
    call input_set_capture
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; do_action — carry out what the menus asked for.
;   in:  eax = MA_* (menu.asm), rdx = argument (world name, ...), r8d = seed
;   out: eax = 1 to quit the game
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%include "menu.inc"
PROC do_action, 0
    cmp eax, MA_NONE
    je .none
    cmp eax, MA_QUIT
    je .quit
    cmp eax, MA_RESUME
    je .resume
    cmp eax, MA_PLAY
    je .play
    cmp eax, MA_CREATE
    je .create
    cmp eax, MA_TO_MENU
    je .to_menu
    cmp eax, MA_SAVE_QUIT
    je .quit                            ; (the exit saves)
.none:
    xor eax, eax
    RETURN
.quit:
    mov eax, 1
    RETURN
.resume:
    call resume_game
    xor eax, eax
    RETURN
.play:
    mov rcx, rdx
    xor edx, edx
    xor r8d, r8d
    call game_begin_world
    xor eax, eax
    RETURN
.create:
    mov rcx, rdx
    mov edx, 1
    call game_begin_world
    xor eax, eax
    RETURN
.to_menu:
    call game_enter_menu
    xor eax, eax
    RETURN
ENDPROC

section .rdata
align 4
c_two_pi:       dd 6.28318530718
