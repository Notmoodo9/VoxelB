; =============================================================================
; sim.asm — the simulation (server side): fixed 20 ticks per second
; (milestone 16, DECISIONS D85).
;
; The simulation owns the world's changing state: the player's body and the
; time of day. It talks to the client only through packets (packet.inc):
; each tick it reads every packet in g_to_sim (inputs, requests), moves
; the player, advances the clock, and sends the player's state and the time
; to g_to_client. It runs on the main thread for now, driven by sim_update
; from the frame loop with a fixed-step accumulator; the client draws the
; state interpolated between the last two ticks (g_sim_alpha).
;
; Public API:
;   sim_init(rcx = eye position 3 doubles, edx = PF_FLYING / PF_NOCLIP)
;                       after world_init and daycycle_init
;   sim_update()        once per frame: runs the ticks that are due (at most
;                       MAX_TICKS_PER_FRAME; a slower machine runs slow)
;   g_sim_alpha         f32 0..1: how far the frame is past the last tick
;   g_sim_tick          ticks run
;   g_sim_tps_x10, g_sim_tick_us, g_sim_tick_max_us   statistics (overlay)
; Block edits: edit.asm (PKT_C_BREAK / PKT_C_PLACE -> PKT_S_BLOCK).
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "packet.inc"
%include "save.inc"
%include "physics.inc"
%include "world.inc"

global sim_init, sim_update, g_sim_alpha, g_sim_tick
global g_sim_tps_x10, g_sim_tick_us, g_sim_tick_max_us, g_sim_time

extern player_load, player_spawn, player_tick, player_toggle_fly, player_fill
extern edit_request, edit_tick, fluid_tick
extern inv_init, inv_packet, inv_selected_block, inv_used_selected, inv_flush
extern use_item, lead_tie, behave_name, survival_spectate
extern survival_load, survival_reset, survival_tick, survival_respawn, survival_fill
extern g_sv_dead
extern inv_place_block, inv_used_slot, inv_swap_hands, inv_drag
extern dig_reset, dig_tick, drops_reset, drops_tick, g_world_mode, g_world_day
extern craft_reset, craft_window, craft_recipe, craft_tick, furnace_tick
extern cont_reset, save_load_containers, g_block_flags
extern combat_load, combat_reset, combat_tick, combat_attack
extern ents_reset, ents_tick, store_reset, store_open, store_update
extern behave_interact, racks_load, racks_tick, graves_load
extern timer_elapsed_us, g_frame_us, g_time_of_day, g_day_length

%define TICK_US             50000       ; 20 TPS
%define MAX_TICKS_PER_FRAME 10
%define MAX_FRAME_US        500000      ; (longer frames count as this)
%define STATS_US            1000000
%define FAST_FORWARD        240.0       ; time_forward: the clock's speed

section .rdata
align 8
c_tick_s:       dq 0.05
c_fast:         dq FAST_FORWARD
c_60:           dq 60.0
c_one_d:        dq 1.0
c_tick_us_f:    dd 50000.0
c_2_over_pi:    dd 0.63661977

section .bss
alignb 8
g_sim_time:         resq 1              ; f64 time of day 0..1
g_sim_acc:          resq 1              ; microseconds not yet simulated
g_sim_tick:         resq 1
g_sim_tick_us:      resq 1              ; average over the last second
g_sim_tick_max_us:  resq 1
g_stat_start:       resq 1
g_stat_ticks:       resq 1
g_stat_us:          resq 1
g_stat_max:         resq 1
g_sim_tps_x10:      resd 1
g_sim_alpha:        resd 1
g_pressed:          resd 1              ; buttons seen since the last tick
g_place_slot:       resd 1              ; the slot a placed block came from
alignb 16
g_input:            resb INPUT_PKT_size ; latest input
g_pkt:              resb PKT_SIZE
g_out:              resb PKT_PAYLOAD_MAX

section .text

; -----------------------------------------------------------------------------
; sim_init — start the simulation: physics tables, player, clock.
;   in:  rcx = eye position (3 doubles), edx = starting PF_FLYING / PF_NOCLIP
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC sim_init, 16, rbx, rsi
    mov rbx, rcx
    mov esi, edx
    call phys_init
    call player_load
    mov rcx, rbx
    mov edx, esi
    call player_spawn
    call craft_reset                    ; (milestone 18)
    call cont_reset
    call save_load_containers           ; what is in the chests
    call inv_init
    call dig_reset
    call drops_reset
    call ents_reset                     ; animals (milestone 19)
    call store_reset
    call store_open
    call racks_load                     ; hides drying on racks (part 3)
    call graves_load                    ; gravestones (milestone 20 part 2)
    call survival_load                  ; health and hunger (milestone 20)
    call combat_load                    ; melee (milestone 21)
    call combat_reset
    mov rcx, rbx
    call survival_reset
    cvtss2sd xmm0, [rel g_time_of_day]
    movsd [rel g_sim_time], xmm0
    mov qword [rel g_sim_acc], 0
    mov qword [rel g_sim_tick], 0
    call timer_elapsed_us
    mov [rel g_stat_start], rax
    call send_state                     ; the client starts from this
    LOG_INFO "simulation: 20 ticks per second, player spawned (Creative)"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; sim_update — run the ticks that are due by now.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC sim_update, 0, rbx
    mov rax, [rel g_frame_us]
    cmp rax, MAX_FRAME_US
    jbe .add
    mov eax, MAX_FRAME_US
.add:
    add rax, [rel g_sim_acc]
    mov [rel g_sim_acc], rax
    xor ebx, ebx
.tick:
    cmp qword [rel g_sim_acc], TICK_US
    jb .alpha
    cmp ebx, MAX_TICKS_PER_FRAME
    jae .behind
    call sim_tick
    sub qword [rel g_sim_acc], TICK_US
    inc ebx
    jmp .tick
.behind:
    mov qword [rel g_sim_acc], 0        ; too slow: drop the rest
.alpha:
    cvtsi2ss xmm0, qword [rel g_sim_acc]
    divss xmm0, [rel c_tick_us_f]
    movss [rel g_sim_alpha], xmm0
    call update_stats
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; sim_tick — one tick: packets in, player, clock, packets out.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC sim_tick, 16, rbx, rsi, rdi
    call timer_elapsed_us
    mov [LOCAL(0)], rax
    mov dword [rel g_pressed], 0
.packet:
    lea rcx, [rel g_to_sim]
    lea rdx, [rel g_pkt]
    call pkt_recv
    test eax, eax
    jz .packets_done
    cmp eax, PKT_C_INPUT
    jne .not_input
    lea rsi, [rel g_pkt + PKT.data]
    lea rdi, [rel g_input]
    mov ecx, INPUT_PKT_size
    rep movsb
    mov eax, [rel g_input + INPUT_PKT.buttons]
    or [rel g_pressed], eax
    jmp .packet
.not_input:
    cmp eax, PKT_C_SPECTATE
    jne .not_spectate
    call survival_spectate              ; (milestone 20: Hardcore)
    jmp .packet
.not_spectate:
    cmp dword [rel g_world_mode], MODE_SPECTATOR
    je .packet                          ; (a spectator only looks)
    cmp eax, PKT_C_BREAK
    je .break
    cmp eax, PKT_C_PLACE
    je .place
    cmp eax, PKT_C_SELECT
    jb .not_inv
    cmp eax, PKT_C_CREATIVE_SET
    ja .not_inv
    mov ecx, eax                        ; inventory (milestone 18)
    lea rdx, [rel g_pkt + PKT.data]
    call inv_packet
    jmp .packet
.not_inv:
    cmp eax, PKT_C_WINDOW
    jne .not_window
    lea rcx, [rel g_pkt + PKT.data]     ; windows and crafting (milestone 18)
    call craft_window
    jmp .packet
.not_window:
    cmp eax, PKT_C_RECIPE
    jne .not_recipe
    lea rcx, [rel g_pkt + PKT.data]
    call craft_recipe
    jmp .packet
.not_recipe:
    cmp eax, PKT_C_SWAP_HANDS
    jne .not_swap
    call inv_swap_hands                 ; (milestone 18 part 5)
    jmp .packet
.not_swap:
    cmp eax, PKT_C_INV_DRAG
    jne .not_drag
    lea rcx, [rel g_pkt + PKT.data]
    call inv_drag
    jmp .packet
.not_drag:
    cmp eax, PKT_C_ATTACK
    jne .not_attack
    lea rcx, [rel g_pkt + PKT.data]
    call combat_attack                  ; (milestone 19; damage: milestone 21)
    jmp .packet
.not_attack:
    cmp eax, PKT_C_INTERACT
    jne .not_interact
    lea rcx, [rel g_pkt + PKT.data]
    call behave_interact                ; (milestone 19 part 2: feeding)
    jmp .packet
.not_interact:
    cmp eax, PKT_C_USE
    jne .not_use
    lea rcx, [rel g_input]
    call use_item                       ; (part 3b: a bucket scoops a liquid)
    jmp .packet
.not_use:
    cmp eax, PKT_C_TIE
    jne .not_tie
    lea rcx, [rel g_pkt + PKT.data]
    call lead_tie                       ; (part 3b: led animals to a fence)
    jmp .packet
.not_tie:
    cmp eax, PKT_C_NAME
    jne .not_name
    lea rcx, [rel g_pkt + PKT.data]
    call behave_name                    ; (part 3b: a name tag)
    jmp .packet
.not_name:
    cmp eax, PKT_C_RESPAWN
    jne .not_respawn
    call survival_respawn               ; (milestone 20)
    jmp .packet
.not_respawn:
    cmp eax, PKT_C_TOGGLE_FLY
    jne .packet                         ; (unknown packets are ignored)
    call player_toggle_fly
    jmp .packet
.break:
    cmp dword [rel g_world_mode], MODE_CREATIVE
    jne .packet                         ; (Survival mines: dig.asm)
    xor edx, edx
    lea rcx, [rel g_pkt + PKT.data]
    call edit_request
    jmp .packet
.place:
    ; the block of the item in hand, else the off hand's (the client's id
    ; is not trusted)
    call inv_place_block
    test eax, eax
    jz .packet
    mov [rel g_place_slot], edx
    call facing_state                   ; (a chest faces the player)
    mov [rel g_pkt + PKT.data + BLOCK_PKT.id], eax
    mov edx, 1
    lea rcx, [rel g_pkt + PKT.data]
    call edit_request
    test eax, eax
    jz .packet
    mov ecx, [rel g_place_slot]
    call inv_used_slot
    jmp .packet
.packets_done:
    cmp dword [rel g_sv_dead], 0
    jne .dead                           ; (dead: the body waits for the respawn)
    lea rcx, [rel g_input]
    mov edx, [rel g_pressed]
    call player_tick
.dead:
    lea rcx, [rel g_input]
    mov edx, [rel g_pressed]
    call survival_tick                  ; health, hunger, damage (milestone 20)
    call combat_tick                    ; the swing meter (milestone 21)
    lea rcx, [rel g_input]
    call dig_tick                       ; Survival mining (milestone 18)
    call drops_tick                     ; dropped items
    call ents_tick                      ; animals (milestone 19)
    call store_update                   ; their regions, new herds
    call craft_tick                     ; a station's window closes far away
    call furnace_tick                   ; furnaces burn and smelt
    call racks_tick                     ; hides dry on racks
    call edit_tick                      ; block changes (they wait for busy columns)
    call inv_flush                      ; changed inventory slots to the client
    mov rcx, [rel g_sim_tick]
    call fluid_tick                     ; flowing liquids

    ; the clock: one tick of the day (faster while time_forward is held)
    cvtss2sd xmm1, [rel g_day_length]
    mulsd xmm1, [rel c_60]              ; seconds per day
    maxsd xmm1, [rel c_one_d]
    movsd xmm0, [rel c_tick_s]
    divsd xmm0, xmm1
    test dword [rel g_input + INPUT_PKT.buttons], INB_TIME_FORWARD
    jz .clock
    mulsd xmm0, [rel c_fast]
.clock:
    addsd xmm0, [rel g_sim_time]
    roundsd xmm1, xmm0, 9
    subsd xmm0, xmm1
    movsd [rel g_sim_time], xmm0
    xorps xmm0, xmm0
    comisd xmm1, xmm0
    jbe .same_day
    inc dword [rel g_world_day]         ; midnight: a new day (milestone 20)
.same_day:

    inc qword [rel g_sim_tick]
    call send_state
    call timer_elapsed_us
    sub rax, [LOCAL(0)]
    add [rel g_stat_us], rax
    inc qword [rel g_stat_ticks]
    cmp rax, [rel g_stat_max]
    jbe .done
    mov [rel g_stat_max], rax
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; facing_state — a block placed with shape = facing turns its front to the
; player (state 0-3: front north, east, south, west).
;   in:  eax = block id     out: eax = the state's id
;   clobbers: rcx, rdx, xmm0, xmm1
; -----------------------------------------------------------------------------
facing_state:
    lea rcx, [rel g_block_flags]
    test byte [rcx + rax], BLOCKF_FACING
    jz .done
    ; the quarter the player looks along (0 north, 1 east ...), turned around
    movss xmm0, [rel g_input + INPUT_PKT.yaw]
    mulss xmm0, [rel c_2_over_pi]
    roundss xmm0, xmm0, 0
    cvtss2si ecx, xmm0
    add ecx, 2
    and ecx, 3
    add eax, ecx
.done:
    ret

; send_state — PKT_S_PLAYER and PKT_S_TIME to the client.  clobbers: volatile
PROC send_state, 0
    lea rcx, [rel g_out]
    call player_fill
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_PLAYER, r8, PLAYER_PKT_size
    cvtsd2ss xmm0, [rel g_sim_time]
    movss [rel g_out + TIME_PKT.time], xmm0
    mov eax, [rel g_sim_tick]
    mov [rel g_out + TIME_PKT.tick], eax
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_TIME, r8, TIME_PKT_size
    lea rcx, [rel g_out]
    call survival_fill
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_SURVIVAL, r8, SURV_PKT_size
    RETURN
ENDPROC

; update_stats — ticks per second and tick times, once a second.
PROC update_stats, 0
    call timer_elapsed_us
    mov rcx, rax
    sub rcx, [rel g_stat_start]
    cmp rcx, STATS_US
    jb .done
    mov [rel g_stat_start], rax
    ; tps * 10 = ticks * 10^7 / us
    mov rax, [rel g_stat_ticks]
    imul rax, rax, 10000000
    xor edx, edx
    div rcx
    mov [rel g_sim_tps_x10], eax
    mov rax, [rel g_stat_us]
    mov rcx, [rel g_stat_ticks]
    test rcx, rcx
    jz .no_ticks
    xor edx, edx
    div rcx
.no_ticks:
    mov [rel g_sim_tick_us], rax
    mov rax, [rel g_stat_max]
    mov [rel g_sim_tick_max_us], rax
    mov qword [rel g_stat_ticks], 0
    mov qword [rel g_stat_us], 0
    mov qword [rel g_stat_max], 0
.done:
    RETURN
ENDPROC
