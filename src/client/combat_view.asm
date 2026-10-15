; =============================================================================
; combat_view.asm — how melee looks and feels on the client (milestone 21
; part 1, design/combat/combat.md).
;
; * The swing meter: the client's own copy of the simulation's (time since
;   the last swing over the item's swing time, combat_swing_ticks), shown
;   as a small ink bar under the crosshair while it fills. A swing at an
;   animal or at nothing starts it again, and so does a new item in hand.
; * PKT_S_HIT (a hit landed): a short hit pause (the animals and the arm
;   stop for hit_pause / crit_pause / heavy_pause seconds), a camera shake
;   (combat.cfg `shake`, stronger for crits and heavy weapons) and
;   particles: sparks for a critical hit, dust where the knock-back pushes,
;   a white puff for a sweep. Particles are little squares projected to the
;   screen and drawn with the UI (no depth test: they live a fraction of a
;   second at the animal).
;
; Public API:
;   combat_view_reset()                 a world starts
;   combat_view_swing()                 the player swung (interact.asm)
;   combat_view_hit(rcx = HIT_PKT*)     PKT_S_HIT
;   combat_view_update()                once a frame, after client_view: the
;                                       shake on g_cam_pos, particles, pause
;   combat_view_draw(ecx = w, edx = h)  the particles and the meter (HUD)
;   combat_view_dodge()                 once a frame while playing: a
;                                       double-tap of move_left / move_right /
;                                       move_back or the dodge key sends
;                                       PKT_C_DODGE (the sim decides)
;   g_cv_paused                         1 during a hit pause (ents_view)
;   combat_view_test()                  --attack-test: once a frame; whenever
;                                       the meter is full, the nearest grown-up
;                                       animal within 5.5 blocks is hit (up to
;                                       g_attack_test hits)
; =============================================================================
%include "macros.inc"
%include "ui.inc"
%include "packet.inc"
%include "save.inc"
%include "ents_view.inc"
%include "input.inc"

global combat_view_reset, combat_view_swing, combat_view_hit
global combat_view_update, combat_view_draw, g_cv_paused
global combat_view_test, g_attack_test, combat_view_dodge

extern ui_draw_begin, ui_draw_flush, ui_rect, timer_elapsed_us
extern combat_swing_ticks, g_cb_hit_pause, g_cb_crit_pause, g_cb_heavy_pause
extern g_cb_shake, g_cinv, g_csel, g_cam_pos, g_cam_viewproj, g_ui_vw, g_ui_vh
extern g_frame_us, g_swing_t0, g_world_mode, g_vlist, g_vents, g_ents_shown
extern pkt_send, g_to_sim, held_swing, input_pressed, input_down, sincosf
extern g_cam_yaw

%define SLOT_SIZE       8
%define DODGE_TAP_US    250000          ; two presses within this: a roll
%define MAX_PARTS       160
%define BAR_W           36
%define BAR_H           4

struc PART
    .pos    resq 3                      ; f64
    .vel    resd 3                      ; f32 blocks/s
    .life   resd 1                      ; f32 seconds left
    .max    resd 1                      ; f32 seconds it lives
    .size   resd 1                      ; f32 blocks
    .color  resd 1                      ; ABGR
    .grav   resd 1                      ; f32 blocks/s² (down)
    .pad    resb 8
endstruc

section .rdata
align 4
c_us:           dd 0.000001
c_one:          dd 1.0
c_half:         dd 0.5
c_zero:         dd 0.0
c_near_w:       dd 0.1
c_px_k:         dd 0.714                ; ~ (1 / tan 35°) / 2: blocks → screen at w 1
c_shake_decay:  dd 10.0                 ; per second
c_shake_size:   dd 0.06                 ; blocks of camera shake at strength 1
c_crit_shake:   dd 1.5
c_heavy_shake:  dd 1.3
c_r16:          dd 0.0000152587890625   ; 1 / 65536
; particle speeds (blocks/s; the rest: tbl_* below)
c_spark_speed:  dd 4.0
c_dust_speed:   dd 1.2
c_puff_speed:   dd 2.5

section .bss
alignb 8
g_parts:        resb MAX_PARTS * PART_size
g_swing_us:     resq 1                  ; when the meter started
g_pause_until:  resq 1                  ; the hit pause ends (us)
g_shake_off:    resq 3                  ; f64 the camera offset this frame
alignb 4
g_cv_paused:    resd 1
g_shake:        resd 1                  ; f32 strength
g_seen_item:    resd 1
g_seen_sel:     resd 1
g_rng:          resd 1
g_next_part:    resd 1
g_proj:         resd 4                  ; x, y, z, w (clip)
g_speed:        resd 1                  ; spawn: the particles' speed

section .text

; rnd — xmm0 = f32 in -1 .. 1   clobbers: rax, rcx, xmm0
rnd:
    mov eax, [rel g_rng]
    test eax, eax
    jnz .go
    mov eax, 0x1F2E3D4C
.go:
    mov ecx, eax
    shl ecx, 13
    xor eax, ecx
    mov ecx, eax
    shr ecx, 17
    xor eax, ecx
    mov ecx, eax
    shl ecx, 5
    xor eax, ecx
    mov [rel g_rng], eax
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_r16]
    addss xmm0, xmm0
    subss xmm0, [rel c_one]
    ret

; -----------------------------------------------------------------------------
; combat_view_reset — no particles, no pause, the meter full
;   clobbers: rax, rcx, rdi
; -----------------------------------------------------------------------------
PROC combat_view_reset, 0, rdi
    lea rdi, [rel g_parts]
    xor eax, eax
    mov ecx, MAX_PARTS * PART_size / 8
    rep stosq
    mov qword [rel g_swing_us], 0
    mov qword [rel g_pause_until], 0
    mov dword [rel g_cv_paused], 0
    mov dword [rel g_shake], 0
    mov dword [rel g_seen_item], -1
    mov dword [rel g_seen_sel], -1
    RETURN
ENDPROC

; combat_view_swing — a swing: the meter starts again   clobbers: volatile
PROC combat_view_swing, 0
    call timer_elapsed_us
    mov [rel g_swing_us], rax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; meter — xmm0 = f32 the meter (0 .. 1); a new item in hand starts it again
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC meter, 0, rbx
    mov eax, [rel g_csel]
    lea rdx, [rel g_cinv]
    movzx ebx, word [rdx + rax * SLOT_SIZE]
    cmp ebx, [rel g_seen_item]
    jne .changed
    cmp eax, [rel g_seen_sel]
    je .same
.changed:
    mov [rel g_seen_item], ebx
    mov [rel g_seen_sel], eax
    call timer_elapsed_us
    mov [rel g_swing_us], rax
.same:
    mov ecx, ebx
    call combat_swing_ticks
    imul ebx, eax, 50000                ; us a full swing takes
    call timer_elapsed_us
    sub rax, [rel g_swing_us]
    cvtsi2ss xmm0, rax
    cvtsi2ss xmm1, ebx
    divss xmm0, xmm1
    minss xmm0, [rel c_one]
    maxss xmm0, [rel c_zero]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; spawn — particles at rbx (f64 x 3): ecx of them; g_speed = speed, the life,
; size, gravity and color from the table at rsi (4 dwords: life, size,
; gravity, ABGR)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC spawn, 0, rdi, r12
    mov r12d, ecx
.one:
    test r12d, r12d
    jz .done
    dec r12d
    mov eax, [rel g_next_part]
    inc dword [rel g_next_part]
    cmp dword [rel g_next_part], MAX_PARTS
    jb .slot
    mov dword [rel g_next_part], 0
.slot:
    imul eax, eax, PART_size
    lea rdi, [rel g_parts]
    add rdi, rax
    mov rax, [rbx]
    mov [rdi + PART.pos], rax
    mov rax, [rbx + 8]
    mov [rdi + PART.pos + 8], rax
    mov rax, [rbx + 16]
    mov [rdi + PART.pos + 16], rax
    call rnd
    mulss xmm0, [rel g_speed]
    movss [rdi + PART.vel], xmm0
    call rnd
    mulss xmm0, [rel g_speed]
    mulss xmm0, [rel c_half]
    addss xmm0, [rel g_speed]
    mulss xmm0, [rel c_half]
    movss [rdi + PART.vel + 4], xmm0
    call rnd
    mulss xmm0, [rel g_speed]
    movss [rdi + PART.vel + 8], xmm0
    call rnd
    mulss xmm0, [rel c_half]
    mulss xmm0, [rel c_half]
    addss xmm0, [rel c_one]             ; 0.75 .. 1.25 of the life
    mulss xmm0, [rsi]
    movss [rdi + PART.life], xmm0
    movss [rdi + PART.max], xmm0
    mov eax, [rsi + 4]
    mov [rdi + PART.size], eax
    mov eax, [rsi + 8]
    mov [rdi + PART.grav], eax
    mov eax, [rsi + 12]
    mov [rdi + PART.color], eax
    jmp .one
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; combat_view_hit — see the header.
;   in:  rcx = HIT_PKT*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC combat_view_hit, 32, rbx, rsi, rdi
    mov rbx, rcx
    movzx edi, word [rbx + HIT_PKT.flags]
    ; the pause: the longest that applies
    movss xmm0, [rel g_cb_hit_pause]
    test edi, HITF_CRIT
    jz .p1
    maxss xmm0, [rel g_cb_crit_pause]
.p1:
    test edi, HITF_HEAVY
    jz .p2
    maxss xmm0, [rel g_cb_heavy_pause]
.p2:
    divss xmm0, [rel c_us]
    cvttss2si rsi, xmm0
    call timer_elapsed_us
    add rax, rsi
    mov [rel g_pause_until], rax
    ; the shake: × the meter, more for crits and heavy weapons
    movss xmm0, [rel g_cb_shake]
    mulss xmm0, [rbx + HIT_PKT.meter]
    test edi, HITF_CRIT
    jz .s1
    mulss xmm0, [rel c_crit_shake]
.s1:
    test edi, HITF_HEAVY
    jz .s2
    mulss xmm0, [rel c_heavy_shake]
.s2:
    maxss xmm0, [rel g_shake]
    movss [rel g_shake], xmm0
    ; particles: dust always, sparks on a crit, a puff for a sweep
    lea rcx, [rel tbl_dust]
    mov rsi, rcx
    movss xmm0, [rel c_dust_speed]
    movss [rel g_speed], xmm0
    mov ecx, 6
    call spawn
    test edi, HITF_CRIT
    jz .no_sparks
    lea rsi, [rel tbl_spark]
    movss xmm0, [rel c_spark_speed]
    movss [rel g_speed], xmm0
    mov ecx, 16
    call spawn
.no_sparks:
    test edi, HITF_SWEEP
    jz .done
    lea rsi, [rel tbl_puff]
    movss xmm0, [rel c_puff_speed]
    movss [rel g_speed], xmm0
    mov ecx, 10
    call spawn
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; combat_view_update — see the header.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC combat_view_update, 16, rbx, rsi
    mov rax, [rel g_frame_us]
    cvtsi2ss xmm0, rax
    mulss xmm0, [rel c_us]
    movss [LOCAL(0)], xmm0              ; dt
    ; the hit pause: the arm's swing holds still too
    mov dword [rel g_cv_paused], 0
    call timer_elapsed_us
    cmp rax, [rel g_pause_until]
    jae .no_pause
    mov dword [rel g_cv_paused], 1
    cmp qword [rel g_swing_t0], 0
    je .no_pause
    mov rax, [rel g_frame_us]
    add [rel g_swing_t0], rax
.no_pause:
    ; the shake: decays; a random offset on the camera this frame
    movss xmm0, [rel g_shake]
    movss xmm1, [LOCAL(0)]
    mulss xmm1, [rel c_shake_decay]
    movss xmm2, [rel c_one]
    subss xmm2, xmm1
    maxss xmm2, [rel c_zero]
    mulss xmm0, xmm2
    movss [rel g_shake], xmm0
    xor ebx, ebx
.axis:
    call rnd
    mulss xmm0, [rel g_shake]
    mulss xmm0, [rel c_shake_size]
    cvtss2sd xmm0, xmm0
    lea rax, [rel g_cam_pos]
    addsd xmm0, [rax + rbx * 8]
    movsd [rax + rbx * 8], xmm0
    inc ebx
    cmp ebx, 3
    jb .axis
    ; the particles
    lea rbx, [rel g_parts]
    xor esi, esi
.part:
    cmp esi, MAX_PARTS
    jae .done
    movss xmm0, [rbx + PART.life]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .next
    subss xmm0, [LOCAL(0)]
    movss [rbx + PART.life], xmm0
    ; velocity: gravity; position: + v dt
    movss xmm0, [rbx + PART.grav]
    mulss xmm0, [LOCAL(0)]
    movss xmm1, [rbx + PART.vel + 4]
    subss xmm1, xmm0
    movss [rbx + PART.vel + 4], xmm1
%assign i 0
%rep 3
    movss xmm0, [rbx + PART.vel + i * 4]
    mulss xmm0, [LOCAL(0)]
    cvtss2sd xmm0, xmm0
    addsd xmm0, [rbx + PART.pos + i * 8]
    movsd [rbx + PART.pos + i * 8], xmm0
%assign i i + 1
%endrep
.next:
    add rbx, PART_size
    inc esi
    jmp .part
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; project — the point g_proj_rel (f32 x 3, relative to the camera) on the
; screen: eax = x, edx = y (UI units), xmm0 = clip w; ecx = 0 behind the camera
;   clobbers: rax, rcx, rdx, r8, xmm0-xmm5
; -----------------------------------------------------------------------------
project:
    movss xmm0, [rel g_proj_rel]
    movss xmm1, [rel g_proj_rel + 4]
    movss xmm2, [rel g_proj_rel + 8]
    lea rcx, [rel g_cam_viewproj]
    xor edx, edx
.row:
    movss xmm5, [rcx + rdx * 4]
    mulss xmm5, xmm0
    movss xmm4, [rcx + rdx * 4 + 16]
    mulss xmm4, xmm1
    addss xmm5, xmm4
    movss xmm4, [rcx + rdx * 4 + 32]
    mulss xmm4, xmm2
    addss xmm5, xmm4
    addss xmm5, [rcx + rdx * 4 + 48]
    lea r8, [rel g_proj]
    movss [r8 + rdx * 4], xmm5
    inc edx
    cmp edx, 4
    jb .row
    movss xmm5, [rel g_proj + 12]       ; w
    comiss xmm5, [rel c_near_w]
    jb .behind
    movss xmm0, [rel g_proj]
    divss xmm0, xmm5
    mulss xmm0, [rel c_half]
    addss xmm0, [rel c_half]
    cvtsi2ss xmm1, dword [rel g_ui_vw]
    mulss xmm0, xmm1
    cvttss2si eax, xmm0
    movss xmm0, [rel g_proj + 4]
    divss xmm0, xmm5
    mulss xmm0, [rel c_half]
    movss xmm1, [rel c_half]
    subss xmm1, xmm0
    cvtsi2ss xmm0, dword [rel g_ui_vh]
    mulss xmm1, xmm0
    cvttss2si edx, xmm1
    movss xmm0, xmm5
    mov ecx, 1
    ret
.behind:
    xor ecx, ecx
    ret

; -----------------------------------------------------------------------------
; combat_view_draw — the particles, then the meter under the crosshair.
;   in:  ecx = w, edx = h
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define D_W     0
%define D_H     4
%define D_X     8
%define D_Y     12
%define D_S     16
PROC combat_view_draw, 32, rbx, rsi
    mov [LOCAL(D_W)], ecx
    mov [LOCAL(D_H)], edx
    call ui_draw_begin
    lea rbx, [rel g_parts]
    xor esi, esi
.part:
    cmp esi, MAX_PARTS
    jae .meter
    movss xmm0, [rbx + PART.life]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .next
%assign i 0
%rep 3
    movsd xmm0, [rbx + PART.pos + i * 8]
    subsd xmm0, [rel g_cam_pos + i * 8]
    cvtsd2ss xmm0, xmm0
    movss [rel g_proj_rel + i * 4], xmm0
%assign i i + 1
%endrep
    call project
    test ecx, ecx
    jz .next
    mov [LOCAL(D_X)], eax
    mov [LOCAL(D_Y)], edx
    ; its size on the screen; it shrinks and fades as it dies
    movss xmm1, [rbx + PART.life]
    divss xmm1, [rbx + PART.max]
    movss xmm2, [rbx + PART.size]
    mulss xmm2, [rel c_px_k]
    cvtsi2ss xmm3, dword [rel g_ui_vh]
    mulss xmm2, xmm3
    divss xmm2, xmm0
    mulss xmm2, xmm1
    cvttss2si eax, xmm2
    cmp eax, 1
    jge .sized
    mov eax, 1
.sized:
    cmp eax, 40
    jle .sized2
    mov eax, 40
.sized2:
    mov [LOCAL(D_S)], eax
    mov eax, [rbx + PART.color]
    mulss xmm1, [rel c_alpha]
    cvttss2si ecx, xmm1
    and eax, 0x00FFFFFF
    shl ecx, 24
    or eax, ecx
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov ecx, [LOCAL(D_X)]
    mov eax, [LOCAL(D_S)]
    shr eax, 1
    sub ecx, eax
    mov edx, [LOCAL(D_Y)]
    sub edx, eax
    mov r8d, [LOCAL(D_S)]
    mov r9d, r8d
    INVOKE ui_rect, rcx, rdx, r8, r9
.next:
    add rbx, PART_size
    inc esi
    jmp .part
.meter:
    ; the meter, only while it fills (not for a spectator or with a page open)
    cmp dword [rel g_world_mode], MODE_SPECTATOR
    je .flush
    call meter
    comiss xmm0, [rel c_one]
    jae .flush
    movss [LOCAL(D_S)], xmm0
    mov ecx, [rel g_ui_vw]
    shr ecx, 1
    sub ecx, BAR_W / 2 + 1
    mov [LOCAL(D_X)], ecx
    mov edx, [rel g_ui_vh]
    shr edx, 1
    add edx, 14
    mov [LOCAL(D_Y)], edx
    mov dword [rsp + 32], 0x90000000
    mov dword [rsp + 40], 0x90000000
    mov qword [rsp + 48], 1
    mov qword [rsp + 56], 0
    INVOKE ui_rect, rcx, rdx, BAR_W + 2, BAR_H + 2
    movss xmm0, [LOCAL(D_S)]
    mov eax, BAR_W
    cvtsi2ss xmm1, eax
    mulss xmm0, xmm1
    cvttss2si r8d, xmm0
    test r8d, r8d
    jz .flush
    mov dword [rsp + 32], 0xF0E8F4F8
    mov dword [rsp + 40], 0xF0B8C8D0
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov ecx, [LOCAL(D_X)]
    inc ecx
    mov edx, [LOCAL(D_Y)]
    inc edx
    INVOKE ui_rect, rcx, rdx, r8, BAR_H
.flush:
    mov ecx, [LOCAL(D_W)]
    mov edx, [LOCAL(D_H)]
    call ui_draw_flush
    RETURN
ENDPROC

section .rdata
align 4
c_alpha:        dd 255.0
; particle kinds: life, size, gravity, ABGR
tbl_spark:      dd 0.35, 0.07, 9.0, 0x0060E8FF   ; warm yellow-white sparks
tbl_dust:       dd 0.5, 0.16, -0.6, 0x00708898   ; grey-brown dust
tbl_puff:       dd 0.3, 0.12, 0.0, 0x00F0F0F0    ; a white sweep puff

section .bss
alignb 4
g_proj_rel:     resd 3

section .text

; -----------------------------------------------------------------------------
; combat_view_test — see the header (tests: hits without aiming).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC combat_view_test, 0, rbx, rsi, rdi
    cmp dword [rel g_attack_test], 0
    je .done
    call meter
    comiss xmm0, [rel c_one]
    jb .done
    mov edi, -1                         ; the nearest grown-up
    movsd xmm3, [rel c_test_r2]
    xor esi, esi
.ent:
    cmp esi, [rel g_ents_shown]
    jae .picked
    lea rax, [rel g_vlist]
    movzx ebx, word [rax + rsi * 2]
    inc esi
    imul eax, ebx, VENT_size
    lea rcx, [rel g_vents]
    add rcx, rax
    test word [rcx + VENT.flags], EPF_BABY | EPF_DYING
    jnz .ent
    movsd xmm0, [rcx + VENT.shown]
    subsd xmm0, [rel g_cam_pos]
    mulsd xmm0, xmm0
    movsd xmm1, [rcx + VENT.shown + 16]
    subsd xmm1, [rel g_cam_pos + 16]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    comisd xmm0, xmm3
    jae .ent
    movsd xmm3, xmm0
    mov edi, ebx
    jmp .ent
.picked:
    cmp edi, -1
    je .done
    dec dword [rel g_attack_test]
    mov [rel g_test_pkt + ENT_PKT.id], edi
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_test_pkt]
    INVOKE pkt_send, rcx, PKT_C_ATTACK, r8, ENT_PKT_size
    call held_swing
    call combat_view_swing
.done:
    RETURN
ENDPROC

section .rdata
align 8
c_test_r2:      dq 30.25                ; --attack-test: within 5.5 blocks

section .bss
alignb 4
g_attack_test:  resd 1                  ; --attack-test: hits left (0: off)
g_test_pkt:     resb ENT_PKT_size


section .bss
alignb 8
g_tap_us:       resq 4                  ; the last press of ACT_MOVE_BACK .. RIGHT (us; by action)
g_dodge:        resb DODGE_PKT_size

section .text
; -----------------------------------------------------------------------------
; combat_view_dodge — see the header. The way: (forward, strafe) in the
; view turned into the world: forward (sin yaw, -cos yaw), right (cos yaw,
; sin yaw), like player_tick.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define D_FWD   0                       ; f32
%define D_STR   4                       ; f32
%define D_ACT   8
PROC combat_view_dodge, 16, rbx
    ; double taps
    mov dword [LOCAL(D_ACT)], ACT_MOVE_BACK
.tap:
    mov ecx, [LOCAL(D_ACT)]
    call input_pressed
    test eax, eax
    jz .tap_next
    call timer_elapsed_us
    mov ecx, [LOCAL(D_ACT)]
    lea rdx, [rel g_tap_us]
    mov r8, rax
    sub r8, [rdx + rcx * 8]
    mov [rdx + rcx * 8], rax
    cmp r8, DODGE_TAP_US
    jae .tap_next
    mov qword [rdx + rcx * 8], 0        ; (a third tap starts a new pair)
    xorps xmm0, xmm0
    movss [LOCAL(D_FWD)], xmm0
    movss [LOCAL(D_STR)], xmm0
    movss xmm1, [rel c_one]
    cmp ecx, ACT_MOVE_BACK
    jne .tap_side
    xorps xmm1, [rel c_sign_f]
    movss [LOCAL(D_FWD)], xmm1
    jmp .send
.tap_side:
    cmp ecx, ACT_MOVE_LEFT
    jne .tap_right
    xorps xmm1, [rel c_sign_f]
.tap_right:
    movss [LOCAL(D_STR)], xmm1
    jmp .send
.tap_next:
    inc dword [LOCAL(D_ACT)]
    cmp dword [LOCAL(D_ACT)], ACT_MOVE_RIGHT
    jbe .tap
    ; the dodge key: the way the keys held point (back when none)
    mov ecx, ACT_DODGE
    call input_pressed
    test eax, eax
    jz .done
    mov ecx, ACT_MOVE_FORWARD
    call input_down
    neg eax
    sbb ebx, ebx
    neg ebx                             ; forward held: 1
    mov ecx, ACT_MOVE_BACK
    call input_down
    neg eax
    sbb eax, eax                        ; back held: -1
    add ebx, eax
    mov [LOCAL(D_ACT)], ebx
    cvtsi2ss xmm0, ebx
    movss [LOCAL(D_FWD)], xmm0
    mov ecx, ACT_MOVE_RIGHT
    call input_down
    neg eax
    sbb ebx, ebx
    neg ebx
    mov ecx, ACT_MOVE_LEFT
    call input_down
    neg eax
    sbb eax, eax
    add ebx, eax
    cvtsi2ss xmm0, ebx
    movss [LOCAL(D_STR)], xmm0
    or ebx, [LOCAL(D_ACT)]
    jnz .send
    mov dword [LOCAL(D_FWD)], 0xBF800000 ; (-1: back)
.send:
    movss xmm0, [rel g_cam_yaw]
    call sincosf                        ; xmm0 = sin, xmm1 = cos
    ; x = fwd sin + str cos, z = -fwd cos + str sin
    movss xmm2, [LOCAL(D_FWD)]
    mulss xmm2, xmm0
    movss xmm3, [LOCAL(D_STR)]
    mulss xmm3, xmm1
    addss xmm2, xmm3
    movss [rel g_dodge + DODGE_PKT.dx], xmm2
    movss xmm2, [LOCAL(D_STR)]
    mulss xmm2, xmm0
    movss xmm3, [LOCAL(D_FWD)]
    mulss xmm3, xmm1
    subss xmm2, xmm3
    movss [rel g_dodge + DODGE_PKT.dz], xmm2
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_dodge]
    INVOKE pkt_send, rcx, PKT_C_DODGE, r8, DODGE_PKT_size
.done:
    RETURN
ENDPROC

section .rdata
align 16
c_sign_f:       dd 0x80000000, 0, 0, 0
