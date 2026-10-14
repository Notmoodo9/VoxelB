; =============================================================================
; client.asm — the client's side of the simulation link (milestone 16, D85).
;
; Every frame, before the simulation runs, client_input turns the movement
; actions and the camera's view direction into a PKT_C_INPUT packet (and a
; double tap of move_up into PKT_C_TOGGLE_FLY). After it, client_view
; reads the simulation's packets and places the camera at the player's
; eyes, interpolated between the last two ticks so motion is smooth at any
; frame rate (it trails the simulation by up to one tick, 50 ms), and sets
; the time of day the same way.
;
; Public API:
;   client_init(ecx = 1 for --flytest: always move forward)
;   client_input()                      before sim_update (also targeting and
;                                       block editing: interact.asm)
;   client_view()                       after sim_update: g_cam_pos, time
;   g_cl_player                         the latest PLAYER_PKT (overlay)
;   g_dig_pos, g_dig_progress           the block being mined and how far
;                                       (f32; < 0: none), for the cracks —
;                                       carried on between ticks at the
;                                       last tick's rate, so the cracks
;                                       reach the end as the block breaks
;   g_cinv (37 x {u16 item, u16 count, u16 durability, u16 spare}: the
;   hotbar 0-8, the inventory 9-35, the carried stack 36), g_csel (the
;   hotbar slot in hand): the client's copy of the simulation's inventory
;   (milestone 18). The hotbar keys and the mouse wheel select; the held
;   block (g_held_block) follows the item in hand. g_cinv holds the open
;   window's slots too (INV_GRID ... INV_ALL - 1).
;   g_cwin (WIN_PKT): the open window; g_cwin_event = 1 when the simulation
;   opened or closed one (game.asm opens / closes the screen).
; =============================================================================
%include "macros.inc"
%include "input.inc"
%include "packet.inc"

global client_init, client_input, client_view, g_cl_player, g_cinv, g_csel
global client_select, client_input_idle, g_dig_pos, g_dig_progress
global g_cwin, g_cwin_event, g_cinv_ver, g_cfurnace, g_off_block, g_fov_scale

extern g_cam_yaw, g_cam_pitch, g_cam_pos, g_sim_alpha
extern daycycle_set, timer_elapsed_us, g_frame_us
extern interact_init, interact_update, stream_block_changed
extern g_held_block, g_item_block, g_dig_want, g_target_valid, g_target
extern drops_view_packet, drops_view_reset, ents_view_packet, ents_view_reset

%define DOUBLE_TAP_US   300000          ; move_up twice within this: fly

section .bss
alignb 16
g_cl_player:    resb PLAYER_PKT_size    ; latest state
g_cl_prev:      resb PLAYER_PKT_size    ; the one before
g_cl_pkt:       resb PKT_SIZE
g_cl_input:     resb INPUT_PKT_size
g_cl_have:      resd 1                  ; a state has arrived
g_cl_time:      resd 1                  ; latest time of day
g_cl_time_prev: resd 1
g_cl_time_have: resd 1
g_cl_flytest:   resd 1
g_cl_seq:       resd 1
alignb 8
g_cl_last_jump: resq 1                  ; time of the last move_up press (us)
g_cl_last_fwd:  resq 1                  ; time of the last move_forward press (us)
g_cl_sprint:    resd 1                  ; sprinting: stays on while forward is held
g_fov_scale:    resd 1                  ; f32 the camera's FOV x this (sprinting widens it)
g_cinv:         resq INV_ALL
g_cwin:         resb WIN_PKT_size
g_cwin_event:   resd 1
g_cinv_ver:     resd 1                  ; counts slot changes
g_cfurnace:     resb FURNACE_PKT_size   ; the open furnace's progress
g_off_block:    resd 1                  ; the off hand's block (0: none)
g_csel:         resd 1
g_dig_pos:      resd 3
g_dig_progress: resd 1
g_dig_last:     resd 1                  ; the tick's reported progress
g_dig_before:   resd 1                  ; the tick before's (same block)
g_cl_sel_pkt:   resb INV_PKT_size

section .rdata
align 16
c_half_f:       dd -0.5
c_one_f:        dd 1.0
c_sprint_fov:   dd 1.12                 ; FOV x this while sprinting
c_fov_rate:     dd 0.0000067            ; per microsecond (about 0.15 s)

section .text

; -----------------------------------------------------------------------------
; client_init — reset the link state.
;   in:  ecx = 1: always move forward (--flytest)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC client_init, 0
    mov [rel g_cl_flytest], ecx
    xor eax, eax
    mov [rel g_cl_have], eax
    mov [rel g_cl_time_have], eax
    mov [rel g_cl_seq], eax
    mov [rel g_cl_last_jump], rax
    mov [rel g_csel], eax
    mov dword [rel g_dig_progress], 0xBF800000   ; -1: not mining
    mov dword [rel g_dig_last], 0xBF800000
    mov dword [rel g_dig_before], 0xBF800000
    call drops_view_reset
    call ents_view_reset                ; animals (milestone 19)
    xor eax, eax
    mov [rel g_cwin + WIN_PKT.kind], eax
    mov [rel g_cwin_event], eax
    lea rcx, [rel g_cinv]
    mov edx, INV_ALL
.clear:
    mov [rcx], rax
    add rcx, 8
    dec edx
    jnz .clear
    call interact_init
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; client_select — put hotbar slot ecx in hand (shown at once; the
; simulation is told).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC client_select, 0
    mov [rel g_csel], ecx
    mov [rel g_cl_sel_pkt + INV_PKT.slot], ecx
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_cl_sel_pkt]
    INVOKE pkt_send, rcx, PKT_C_SELECT, r8, INV_PKT_size
    call held_follows
    RETURN
ENDPROC

; held_follows — g_held_block = the block of the item in hand, g_off_block
; the off hand's (0: none)   clobbers: rax, rcx
held_follows:
    lea rcx, [rel g_cinv]
    movzx ecx, word [rcx + INV_OFFHAND * 8]
    xor eax, eax
    test ecx, ecx
    jz .off
    lea rax, [rel g_item_block]
    movzx eax, word [rax + rcx * 2]
.off:
    mov [rel g_off_block], eax
    mov eax, [rel g_csel]
    lea rcx, [rel g_cinv]
    movzx ecx, word [rcx + rax * 8]
    xor eax, eax
    test ecx, ecx
    jz .set
    lea rax, [rel g_item_block]
    movzx eax, word [rax + rcx * 2]
.set:
    mov [rel g_held_block], eax
    ret

; hotbar_input — the hotbar keys and the mouse wheel; swap_hands (F) trades
; the main and the off hand's items   clobbers: volatile
PROC hotbar_input, 0, rbx
    mov ecx, ACT_SWAP_HANDS
    call input_pressed
    test eax, eax
    jz .no_swap
    lea rcx, [rel g_to_sim]
    INVOKE pkt_send, rcx, PKT_C_SWAP_HANDS, 0, 0
.no_swap:
    xor ebx, ebx
.key:
    lea ecx, [ebx + ACT_HOTBAR_1]
    call input_pressed
    test eax, eax
    jnz .pick
    inc ebx
    cmp ebx, INV_HOTBAR
    jb .key
    ; the wheel: up = the slot to the left
    mov eax, [rel g_mouse_wheel]
    test eax, eax
    jz .done
    cmp dword [rel g_mouse_captured], 0
    je .done
    mov ebx, [rel g_csel]
    cmp eax, 0
    jg .left
    inc ebx
    cmp ebx, INV_HOTBAR
    jb .pick
    xor ebx, ebx
    jmp .pick
.left:
    dec ebx
    jns .pick
    mov ebx, INV_HOTBAR - 1
.pick:
    mov ecx, ebx
    call client_select
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; axis — +1 / -1 / 0 from two actions.
;   in:  ecx = positive action, edx = negative action
;   out: xmm0 = 1.0, -1.0 or 0.0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC axis, 0, rbx, rsi
    mov esi, edx
    call input_down
    mov ebx, eax
    mov ecx, esi
    call input_down
    sub ebx, eax
    cvtsi2ss xmm0, ebx
    RETURN
ENDPROC

; button — eax = bit if the action is held, else 0.   ecx = action, edx = bit
PROC button, 0, rbx
    mov ebx, edx
    call input_down
    neg eax
    sbb eax, eax
    and eax, ebx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; client_input — send this frame's input to the simulation.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC client_input, 0, rbx
    call hotbar_input
    call interact_update                ; target, break / place / pick
    INVOKE axis, ACT_MOVE_FORWARD, ACT_MOVE_BACK
    cmp dword [rel g_cl_flytest], 0
    je .fwd
    movss xmm0, [rel c_one_f]
.fwd:
    movss [rel g_cl_input + INPUT_PKT.forward], xmm0
    INVOKE axis, ACT_MOVE_RIGHT, ACT_MOVE_LEFT
    movss [rel g_cl_input + INPUT_PKT.strafe], xmm0
    mov eax, [rel g_cam_yaw]
    mov [rel g_cl_input + INPUT_PKT.yaw], eax
    mov eax, [rel g_cam_pitch]
    mov [rel g_cl_input + INPUT_PKT.pitch], eax
    INVOKE button, ACT_MOVE_UP, INB_JUMP
    mov ebx, eax
    INVOKE button, ACT_MOVE_DOWN, INB_SNEAK
    or ebx, eax
    ; sprint like Minecraft: hold the sprint key or double-tap forward; it
    ; stays on while forward is held (until sneaking)
    mov ecx, ACT_MOVE_FORWARD
    call input_pressed
    test eax, eax
    jz .no_tap
    call timer_elapsed_us
    mov rcx, rax
    sub rcx, [rel g_cl_last_fwd]
    mov [rel g_cl_last_fwd], rax
    cmp rcx, DOUBLE_TAP_US
    jae .no_tap
    mov qword [rel g_cl_last_fwd], 0    ; (a third tap starts a new pair)
    mov dword [rel g_cl_sprint], 1
.no_tap:
    mov ecx, ACT_SPRINT
    call input_down
    test eax, eax
    jz .sprint_key_up
    mov dword [rel g_cl_sprint], 1
.sprint_key_up:
    mov ecx, ACT_MOVE_FORWARD
    call input_down
    test eax, eax
    jnz .fwd_held
    mov dword [rel g_cl_sprint], 0
.fwd_held:
    test ebx, INB_SNEAK
    jz .not_sneaking
    mov dword [rel g_cl_sprint], 0
.not_sneaking:
    cmp dword [rel g_cl_sprint], 0
    je .no_sprint
    or ebx, INB_SPRINT
.no_sprint:
    INVOKE button, ACT_TIME_FORWARD, INB_TIME_FORWARD
    or ebx, eax
    ; Survival mining: the block being dug
    cmp dword [rel g_dig_want], 0
    je .no_dig
    cmp dword [rel g_target_valid], 0
    je .no_dig
    or ebx, INB_DIG
    mov eax, [rel g_target]
    mov [rel g_cl_input + INPUT_PKT.dig], eax
    mov eax, [rel g_target + 4]
    mov [rel g_cl_input + INPUT_PKT.dig + 4], eax
    mov eax, [rel g_target + 8]
    mov [rel g_cl_input + INPUT_PKT.dig + 8], eax
.no_dig:
    mov [rel g_cl_input + INPUT_PKT.buttons], ebx
    inc dword [rel g_cl_seq]
    mov eax, [rel g_cl_seq]
    mov [rel g_cl_input + INPUT_PKT.seq], eax
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_cl_input]
    INVOKE pkt_send, rcx, PKT_C_INPUT, r8, INPUT_PKT_size

    ; double tap of move_up: start / stop flying
    mov ecx, ACT_MOVE_UP
    call input_pressed
    test eax, eax
    jz .done
    call timer_elapsed_us
    mov rcx, rax
    sub rcx, [rel g_cl_last_jump]
    mov [rel g_cl_last_jump], rax
    cmp rcx, DOUBLE_TAP_US
    jae .done
    mov qword [rel g_cl_last_jump], 0   ; (a third tap starts a new pair)
    lea rcx, [rel g_to_sim]
    INVOKE pkt_send, rcx, PKT_C_TOGGLE_FLY, 0, 0
.done:
    RETURN
ENDPROC

; client_input_idle — standing still (a screen is open): no movement, the
; same view   clobbers: volatile registers
PROC client_input_idle, 0
    xor eax, eax
    mov [rel g_cl_input + INPUT_PKT.forward], eax
    mov [rel g_cl_input + INPUT_PKT.strafe], eax
    mov [rel g_cl_input + INPUT_PKT.buttons], eax
    inc dword [rel g_cl_seq]
    mov eax, [rel g_cl_seq]
    mov [rel g_cl_input + INPUT_PKT.seq], eax
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_cl_input]
    INVOKE pkt_send, rcx, PKT_C_INPUT, r8, INPUT_PKT_size
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; client_view — read the simulation's packets; camera and clock between the
; last two ticks.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC client_view, 0, rsi, rdi
.packet:
    lea rcx, [rel g_to_client]
    lea rdx, [rel g_cl_pkt]
    call pkt_recv
    test eax, eax
    jz .packets_done
    cmp eax, PKT_S_PLAYER
    jne .not_player
    ; prev = latest (or the new one, the first time); latest = new
    lea rsi, [rel g_cl_player]
    cmp dword [rel g_cl_have], 0
    jne .shift
    lea rsi, [rel g_cl_pkt + PKT.data]
.shift:
    lea rdi, [rel g_cl_prev]
    mov ecx, PLAYER_PKT_size
    rep movsb
    lea rsi, [rel g_cl_pkt + PKT.data]
    lea rdi, [rel g_cl_player]
    mov ecx, PLAYER_PKT_size
    rep movsb
    mov dword [rel g_cl_have], 1
    jmp .packet
.not_player:
    cmp eax, PKT_S_BLOCK
    jne .not_block
    ; a block changed: its column (and neighbours in light range) mesh again
    mov ecx, [rel g_cl_pkt + PKT.data + BLOCK_PKT.x]
    mov edx, [rel g_cl_pkt + PKT.data + BLOCK_PKT.y]
    mov r8d, [rel g_cl_pkt + PKT.data + BLOCK_PKT.z]
    call stream_block_changed
    jmp .packet
.not_block:
    cmp eax, PKT_S_SLOT
    jne .not_slot
    mov ecx, [rel g_cl_pkt + PKT.data + INV_PKT.slot]
    cmp ecx, INV_ALL
    jae .packet
    lea rdx, [rel g_cinv]
    lea rdx, [rdx + rcx * 8]
    mov eax, [rel g_cl_pkt + PKT.data + INV_PKT.item]
    mov [rdx], ax
    mov eax, [rel g_cl_pkt + PKT.data + INV_PKT.count]
    mov [rdx + 2], ax
    mov eax, [rel g_cl_pkt + PKT.data + INV_PKT.arg]
    mov [rdx + 4], ax
    inc dword [rel g_cinv_ver]          ; (the recipe book looks again)
    call held_follows
    jmp .packet
.not_slot:
    cmp eax, PKT_S_SELECT
    jne .not_select
    mov eax, [rel g_cl_pkt + PKT.data + INV_PKT.slot]
    mov [rel g_csel], eax
    call held_follows
    jmp .packet
.not_select:
    cmp eax, PKT_S_DIG
    jne .not_dig
    mov eax, [rel g_cl_pkt + PKT.data + DIG_PKT.pos]
    mov [rel g_dig_pos], eax
    mov eax, [rel g_cl_pkt + PKT.data + DIG_PKT.pos + 4]
    mov [rel g_dig_pos + 4], eax
    mov eax, [rel g_cl_pkt + PKT.data + DIG_PKT.pos + 8]
    mov [rel g_dig_pos + 8], eax
    ; the progress of the last two ticks (the same dig): the shown one is
    ; carried on between ticks (client_view)
    movss xmm0, [rel g_cl_pkt + PKT.data + DIG_PKT.progress]
    movss xmm1, [rel g_dig_last]
    comiss xmm0, xmm1
    jae .dig_on
    movss xmm1, xmm0                    ; (a new dig, or stopped)
.dig_on:
    movss [rel g_dig_before], xmm1
    movss [rel g_dig_last], xmm0
    jmp .packet
.not_dig:
    cmp eax, PKT_S_WINDOW
    jne .not_window
    lea rsi, [rel g_cl_pkt + PKT.data]
    lea rdi, [rel g_cwin]
    mov ecx, WIN_PKT_size
    rep movsb
    mov dword [rel g_cwin_event], 1
    jmp .packet
.not_window:
    cmp eax, PKT_S_FURNACE
    jne .not_furnace
    mov rax, [rel g_cl_pkt + PKT.data]
    mov [rel g_cfurnace], rax
    jmp .packet
.not_furnace:
    cmp eax, PKT_S_DROP
    je .drop
    cmp eax, PKT_S_DROP_GONE
    jne .not_drop
.drop:
    mov ecx, eax
    lea rdx, [rel g_cl_pkt + PKT.data]
    call drops_view_packet
    jmp .packet
.not_drop:
    cmp eax, PKT_S_ENTITY
    je .entity
    cmp eax, PKT_S_ENTITY_GONE
    jne .not_entity
.entity:
    mov ecx, eax
    lea rdx, [rel g_cl_pkt + PKT.data]
    call ents_view_packet               ; animals (milestone 19)
    jmp .packet
.not_entity:
    cmp eax, PKT_S_TIME
    jne .packet
    mov eax, [rel g_cl_pkt + PKT.data + TIME_PKT.time]
    mov ecx, [rel g_cl_time]
    cmp dword [rel g_cl_time_have], 0
    jne .time_shift
    mov ecx, eax
.time_shift:
    mov [rel g_cl_time_prev], ecx
    mov [rel g_cl_time], eax
    mov dword [rel g_cl_time_have], 1
    jmp .packet
.packets_done:

    cmp dword [rel g_cl_have], 0
    je .no_player
    ; eyes = feet + eye height, between the two ticks
    cvtss2sd xmm5, [rel g_sim_alpha]
%assign i 0
%rep 3
    movsd xmm0, [rel g_cl_prev + PLAYER_PKT.pos + i * 8]
    movsd xmm1, [rel g_cl_player + PLAYER_PKT.pos + i * 8]
    subsd xmm1, xmm0
    mulsd xmm1, xmm5
    addsd xmm0, xmm1
    movsd [rel g_cam_pos + i * 8], xmm0
%assign i i + 1
%endrep
    movss xmm0, [rel g_cl_prev + PLAYER_PKT.eye]
    movss xmm1, [rel g_cl_player + PLAYER_PKT.eye]
    subss xmm1, xmm0
    mulss xmm1, [rel g_sim_alpha]
    addss xmm0, xmm1
    cvtss2sd xmm0, xmm0
    addsd xmm0, [rel g_cam_pos + 8]
    movsd [rel g_cam_pos + 8], xmm0
    ; sprinting: the view widens a little (eased over ~0.15 s)
    movss xmm1, [rel c_one_f]
    test dword [rel g_cl_player + PLAYER_PKT.flags], PF_SPRINTING
    jz .fov_target
    movss xmm1, [rel c_sprint_fov]
.fov_target:
    cvtsi2ss xmm2, qword [rel g_frame_us]
    mulss xmm2, [rel c_fov_rate]
    minss xmm2, [rel c_one_f]
    movss xmm0, [rel g_fov_scale]
    xorps xmm3, xmm3
    comiss xmm0, xmm3
    ja .fov_have
    movss xmm0, [rel c_one_f]
.fov_have:
    subss xmm1, xmm0
    mulss xmm1, xmm2
    addss xmm0, xmm1
    movss [rel g_fov_scale], xmm0
.no_player:
    ; the cracks: last tick's progress + this frame's share of a tick's gain
    movss xmm0, [rel g_dig_last]
    xorps xmm2, xmm2
    comiss xmm0, xmm2
    jbe .dig_shown                      ; (not mining: as reported)
    movss xmm1, xmm0
    subss xmm1, [rel g_dig_before]
    mulss xmm1, [rel g_sim_alpha]
    addss xmm0, xmm1
    minss xmm0, [rel c_one_f]
.dig_shown:
    movss [rel g_dig_progress], xmm0

    cmp dword [rel g_cl_time_have], 0
    je .done
    ; time: the short way round midnight
    movss xmm0, [rel g_cl_time_prev]
    movss xmm1, [rel g_cl_time]
    subss xmm1, xmm0
    comiss xmm1, [rel c_half_f]
    jae .time_lerp
    addss xmm1, [rel c_one_f]
.time_lerp:
    mulss xmm1, [rel g_sim_alpha]
    addss xmm0, xmm1
    call daycycle_set
.done:
    RETURN
ENDPROC
