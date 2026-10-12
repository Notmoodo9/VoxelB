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
; =============================================================================
%include "macros.inc"
%include "input.inc"
%include "packet.inc"

global client_init, client_input, client_view, g_cl_player

extern g_cam_yaw, g_cam_pitch, g_cam_pos, g_sim_alpha
extern daycycle_set, timer_elapsed_us
extern interact_init, interact_update, stream_block_changed

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

section .rdata
align 16
c_half_f:       dd -0.5
c_one_f:        dd 1.0

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
    call interact_init
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
    INVOKE button, ACT_SPRINT, INB_SPRINT
    or ebx, eax
    INVOKE button, ACT_TIME_FORWARD, INB_TIME_FORWARD
    or ebx, eax
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
    call interact_update                ; target, break / place / pick
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
.no_player:

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
