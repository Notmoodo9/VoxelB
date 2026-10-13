; =============================================================================
; ents_view.asm — the client's view of the animals (milestone 19): the
; simulation's PKT_S_ENTITY / PKT_S_ENTITY_GONE kept in a table (same ids),
; glided to their latest state each frame and animated: legs swing with the
; walking speed, the head turns, a dying animal tips over, a hurt one
; flashes red. How much open sky an animal stands under is looked at now and
; then from the blocks above it (the world's light lives on the GPU), which
; darkens animals under trees and in caves.
; ents_pick finds the animal the player aims at (src/client/interact.asm).
;
; Public API (include/ents_view.inc):
;   ents_view_reset()
;   ents_view_packet(ecx = type, rdx = ENT_PKT*)
;   ents_view_update()                  once per frame (mob_render.asm)
;   ents_pick(rcx = f64[3] origin, rdx = f64[3] unit direction,
;             xmm2 = f64 reach) -> eax id / -1, xmm0 = f64 distance
;   g_vents, g_ents_shown, g_ent_target (the aimed-at animal, -1)
; =============================================================================
%define ENTS_VIEW_IMPL
%include "macros.inc"
%include "packet.inc"
%include "block.inc"
%include "mobs.inc"
%include "ents_view.inc"

global ents_view_reset, ents_view_packet, ents_view_update, ents_pick
global g_vents, g_ents_shown, g_ent_target, g_vlist

extern g_frame_us, world_block_at, sincosf

%define SKY_EVERY       16              ; frames between sky checks
%define SKY_UP          24              ; blocks looked at above the back

section .rdata
align 8
c_us:           dq 0.000001
c_follow:       dq 14.0                 ; glide rate (per second)
c_one:          dq 1.0
c_big:          dq 1.0e30
c_baby:         dq 0.5
c_half_d:       dq 0.5
align 4
c_one_f:        dd 1.0
c_zero_f:       dd 0.0
c_two_pi:       dd 6.28318531
c_stride:       dd 4.5                  ; leg phase per block walked
c_amp_speed:    dd 0.45                 ; walking speed (blocks/s) -> stride: / 2.2
c_amp_rate:     dd 8.0
c_roll_max:     dd 1.5707963
c_roll_rate:    dd 4.0                  ; radians per second
c_hurt_rate:    dd 6.0                  ; the red fades per second
c_sky_open:     dd 1.0
c_sky_leaves:   dd 0.72
c_sky_side:     dd 0.6                  ; under a roof, open sky beside it
c_sky_closed:   dd 0.08

section .bss
alignb 16
g_vents:        resb MAX_ENTITIES * VENT_size
g_vlist:        resw MAX_ENTITIES           ; the shown animals' ids (dense)
g_vslot:        resw MAX_ENTITIES           ; an id's place in g_vlist
g_ents_shown:   resd 1
g_ent_target:   resd 1
g_frame_n:      resd 1
g_sky_y:        resd 1                  ; sky_above: the block above the back
g_sky_leaf:     resd 1                  ; sky_above: leaves passed

section .text

; ents_view_reset — forget every animal
PROC ents_view_reset, 0, rdi
    lea rdi, [rel g_vents]
    xor eax, eax
    mov ecx, MAX_ENTITIES * VENT_size / 8
    rep stosq
    mov dword [rel g_ents_shown], 0
    mov dword [rel g_ent_target], -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ents_view_packet — an animal appeared / moved / changed, or is gone.
;   in:  ecx = PKT_S_ENTITY / PKT_S_ENTITY_GONE, rdx = ENT_PKT*
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
ents_view_packet:
    mov eax, [rdx + ENT_PKT.id]
    cmp eax, MAX_ENTITIES
    jae .done
    imul eax, eax, VENT_size
    lea r8, [rel g_vents]
    add r8, rax
    cmp ecx, PKT_S_ENTITY_GONE
    jne .update
    cmp dword [r8 + VENT.active], 0
    je .done
    mov dword [r8 + VENT.active], 0
    ; out of the list: the last one takes its place
    mov eax, [rdx + ENT_PKT.id]
    lea r9, [rel g_vslot]
    movzx ecx, word [r9 + rax * 2]
    dec dword [rel g_ents_shown]
    mov r10d, [rel g_ents_shown]
    lea r11, [rel g_vlist]
    movzx eax, word [r11 + r10 * 2]
    mov [r11 + rcx * 2], ax
    mov [r9 + rax * 2], cx
    ret
.update:
    mov rax, [rdx + ENT_PKT.pos]
    mov [r8 + VENT.target], rax
    mov rax, [rdx + ENT_PKT.pos + 8]
    mov [r8 + VENT.target + 8], rax
    mov rax, [rdx + ENT_PKT.pos + 16]
    mov [r8 + VENT.target + 16], rax
    mov eax, [rdx + ENT_PKT.yaw]
    mov [r8 + VENT.yaw_t], eax
    mov eax, [rdx + ENT_PKT.head_yaw]
    mov [r8 + VENT.head_t], eax
    mov eax, [rdx + ENT_PKT.head_pitch]
    mov [r8 + VENT.pitch_t], eax
    mov ax, [rdx + ENT_PKT.variant]
    mov [r8 + VENT.variant], ax
    mov ax, [rdx + ENT_PKT.flags]
    mov [r8 + VENT.flags], ax
    test ax, EPF_HURT
    jz .not_hurt
    mov eax, [rel c_one_f]
    mov [r8 + VENT.hurt], eax
.not_hurt:
    cmp dword [r8 + VENT.active], 0
    jne .done
    ; new: drawn where it is, as it is
    mov rax, [r8 + VENT.target]
    mov [r8 + VENT.shown], rax
    mov rax, [r8 + VENT.target + 8]
    mov [r8 + VENT.shown + 8], rax
    mov rax, [r8 + VENT.target + 16]
    mov [r8 + VENT.shown + 16], rax
    mov eax, [r8 + VENT.yaw_t]
    mov [r8 + VENT.yaw], eax
    mov eax, [r8 + VENT.head_t]
    mov [r8 + VENT.head], eax
    mov eax, [r8 + VENT.pitch_t]
    mov [r8 + VENT.pitch], eax
    xor eax, eax
    mov [r8 + VENT.phase], eax
    mov [r8 + VENT.amp], eax
    mov [r8 + VENT.roll], eax
    mov [r8 + VENT.sky_wait], eax       ; (look at the sky right away)
    mov eax, [rel c_sky_open]
    mov [r8 + VENT.sky], eax
    mov dword [r8 + VENT.active], 1
    mov eax, [rdx + ENT_PKT.id]
    mov ecx, [rel g_ents_shown]
    lea r9, [rel g_vlist]
    mov [r9 + rcx * 2], ax
    lea r9, [rel g_vslot]
    mov [r9 + rax * 2], cx
    inc dword [rel g_ents_shown]
.done:
    ret

; glide_angle — xmm0 (shown) towards xmm1 (latest) by factor xmm2 (floats,
; the short way round)   out: xmm0   clobbers: xmm0, xmm1, xmm3
glide_angle:
    subss xmm1, xmm0
    movss xmm3, xmm1
    divss xmm3, [rel c_two_pi]
    roundss xmm3, xmm3, 0
    mulss xmm3, [rel c_two_pi]
    subss xmm1, xmm3
    mulss xmm1, xmm2
    addss xmm0, xmm1
    ret

; -----------------------------------------------------------------------------
; ents_view_update — glide every animal towards its latest state; animate.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define U_K     0                       ; f64 glide factor this frame
%define U_DT    8                       ; f32 seconds
%define U_KF    12                      ; f32 glide factor
%define U_DX    16                      ; f64
%define U_DZ    24
PROC ents_view_update, 32, rbx, rsi, rdi
    inc dword [rel g_frame_n]
    cmp dword [rel g_ents_shown], 0
    je .done
    mov rax, [rel g_frame_us]
    cvtsi2sd xmm0, rax
    mulsd xmm0, [rel c_us]
    cvtsd2ss xmm1, xmm0
    movss [LOCAL(U_DT)], xmm1
    mulsd xmm0, [rel c_follow]
    minsd xmm0, [rel c_one]
    movsd [LOCAL(U_K)], xmm0
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(U_KF)], xmm0
    xor edi, edi                        ; place in the list
.ent:
    cmp edi, [rel g_ents_shown]
    jae .done
    lea rax, [rel g_vlist]
    movzx esi, word [rax + rdi * 2]     ; id
    imul eax, esi, VENT_size
    lea rbx, [rel g_vents]
    add rbx, rax
    ; ---- glide; the horizontal step walked this frame ----
    movsd xmm0, [rbx + VENT.target]
    subsd xmm0, [rbx + VENT.shown]
    mulsd xmm0, [LOCAL(U_K)]
    movsd [LOCAL(U_DX)], xmm0
    addsd xmm0, [rbx + VENT.shown]
    movsd [rbx + VENT.shown], xmm0
    movsd xmm0, [rbx + VENT.target + 8]
    subsd xmm0, [rbx + VENT.shown + 8]
    mulsd xmm0, [LOCAL(U_K)]
    addsd xmm0, [rbx + VENT.shown + 8]
    movsd [rbx + VENT.shown + 8], xmm0
    movsd xmm0, [rbx + VENT.target + 16]
    subsd xmm0, [rbx + VENT.shown + 16]
    mulsd xmm0, [LOCAL(U_K)]
    movsd [LOCAL(U_DZ)], xmm0
    addsd xmm0, [rbx + VENT.shown + 16]
    movsd [rbx + VENT.shown + 16], xmm0
    ; ---- angles ----
    movss xmm0, [rbx + VENT.yaw]
    movss xmm1, [rbx + VENT.yaw_t]
    movss xmm2, [LOCAL(U_KF)]
    call glide_angle
    movss [rbx + VENT.yaw], xmm0
    movss xmm0, [rbx + VENT.head]
    movss xmm1, [rbx + VENT.head_t]
    movss xmm2, [LOCAL(U_KF)]
    call glide_angle
    movss [rbx + VENT.head], xmm0
    movss xmm0, [rbx + VENT.pitch]
    movss xmm1, [rbx + VENT.pitch_t]
    movss xmm2, [LOCAL(U_KF)]
    call glide_angle
    movss [rbx + VENT.pitch], xmm0
    ; ---- walking: the stride follows the speed, the legs the distance ----
    movsd xmm0, [LOCAL(U_DX)]
    mulsd xmm0, xmm0
    movsd xmm1, [LOCAL(U_DZ)]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    sqrtsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0                 ; blocks this frame
    movss xmm1, xmm0
    mulss xmm1, [rel c_stride]
    addss xmm1, [rbx + VENT.phase]
    movss xmm2, xmm1
    divss xmm2, [rel c_two_pi]
    roundss xmm2, xmm2, 1               ; (keep the phase small)
    mulss xmm2, [rel c_two_pi]
    subss xmm1, xmm2
    movss [rbx + VENT.phase], xmm1
    movss xmm1, [LOCAL(U_DT)]
    maxss xmm1, [rel c_tiny_f]
    divss xmm0, xmm1                    ; blocks per second
    mulss xmm0, [rel c_amp_speed]
    minss xmm0, [rel c_one_f]
    subss xmm0, [rbx + VENT.amp]
    movss xmm1, [LOCAL(U_DT)]
    mulss xmm1, [rel c_amp_rate]
    minss xmm1, [rel c_one_f]
    mulss xmm0, xmm1
    addss xmm0, [rbx + VENT.amp]
    movss [rbx + VENT.amp], xmm0
    ; ---- dying: tips over; hurt: the red fades ----
    test word [rbx + VENT.flags], EPF_DYING
    jz .not_dying
    movss xmm0, [LOCAL(U_DT)]
    mulss xmm0, [rel c_roll_rate]
    addss xmm0, [rbx + VENT.roll]
    minss xmm0, [rel c_roll_max]
    movss [rbx + VENT.roll], xmm0
.not_dying:
    test word [rbx + VENT.flags], EPF_HURT
    jnz .tint
    movss xmm0, [rbx + VENT.hurt]
    movss xmm1, [LOCAL(U_DT)]
    mulss xmm1, [rel c_hurt_rate]
    subss xmm0, xmm1
    maxss xmm0, [rel c_zero_f]
    movss [rbx + VENT.hurt], xmm0
.tint:
    ; ---- the sky above, now and then ----
    dec dword [rbx + VENT.sky_wait]
    jns .next
    mov eax, esi
    and eax, 7
    add eax, SKY_EVERY
    mov [rbx + VENT.sky_wait], eax
    call sky_above
    movss [rbx + VENT.sky], xmm0
.next:
    inc edi
    jmp .ent
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; sky_above — how open the sky is over animal rbx: nothing above (1), only
; leaves (0.72), a roof but open sky 2 blocks beside it (0.6), closed (0.08).
;   out: xmm0 (float)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define SK_X    0
%define SK_Y    4
%define SK_Z    8
%define SK_LEAF 12
%define SK_DIR  16
PROC sky_above, 32, rsi, rdi
    movsd xmm0, [rbx + VENT.target]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [LOCAL(SK_X)], eax
    movsd xmm0, [rbx + VENT.target + 8]
    addsd xmm0, [rel c_one]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_sky_y], eax
    movsd xmm0, [rbx + VENT.target + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [LOCAL(SK_Z)], eax
    mov dword [rel g_sky_leaf], 0
    mov ecx, [LOCAL(SK_X)]
    mov edx, [LOCAL(SK_Z)]
    call column_open
    test eax, eax
    js .covered
    movss xmm0, [rel c_sky_open]
    cmp dword [rel g_sky_leaf], 0
    je .done
    movss xmm0, [rel c_sky_leaves]
    jmp .done
.covered:
    ; a roof: open sky 2 blocks to a side?
    mov dword [LOCAL(SK_DIR)], 0
.side:
    mov eax, [LOCAL(SK_DIR)]
    cmp eax, 4
    jae .closed
    lea rcx, [rel side_dx]
    mov ecx, [rcx + rax * 4]
    lea rdx, [rel side_dz]
    mov edx, [rdx + rax * 4]
    add ecx, [LOCAL(SK_X)]
    add edx, [LOCAL(SK_Z)]
    call column_open
    test eax, eax
    jns .side_open
    inc dword [LOCAL(SK_DIR)]
    jmp .side
.side_open:
    movss xmm0, [rel c_sky_side]
    jmp .done
.closed:
    movss xmm0, [rel c_sky_closed]
.done:
    RETURN
ENDPROC

; column_open — eax = 0 if nothing opaque is within SKY_UP blocks above
; (ecx, g_sky_y, edx), -1 if something is; sets g_sky_leaf when leaves were
; passed   clobbers: volatile registers
PROC column_open, 0, rsi, rdi, r12
    mov esi, ecx
    mov edi, edx
    xor r12d, r12d
.up:
    cmp r12d, SKY_UP
    jae .open
    mov ecx, esi
    mov edx, [rel g_sky_y]
    add edx, r12d
    mov r8d, edi
    call world_block_at
    inc r12d
    test eax, eax
    jz .up
    lea rcx, [rel g_block_opaque]
    cmp byte [rcx + rax], 0
    jne .closed
    lea rcx, [rel g_block_layer]
    cmp byte [rcx + rax], LAYER_CUTOUT
    jne .up
    mov dword [rel g_sky_leaf], 1
    jmp .up
.open:
    xor eax, eax
    RETURN
.closed:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ents_pick — the nearest animal whose box the ray enters within reach.
;   in:  rcx = f64[3] origin, rdx = f64[3] unit direction, xmm2 = f64 reach
;   out: eax = id (-1 none), xmm0 = f64 distance
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define PK_BEST     0                   ; f64
%define PK_ID       8
%define PK_TMIN     16                  ; f64
%define PK_TMAX     24
%define PK_LO       32                  ; f64[3] box
%define PK_HI       56
PROC ents_pick, 80, rbx, rsi, rdi, r12, r13
    mov r12, rcx
    mov rdi, rdx
    movsd [LOCAL(PK_BEST)], xmm2
    mov dword [LOCAL(PK_ID)], -1
    xor r13d, r13d                      ; place in the list
.ent:
    cmp r13d, [rel g_ents_shown]
    jae .done
    lea rax, [rel g_vlist]
    movzx esi, word [rax + r13 * 2]     ; id
    imul eax, esi, VENT_size
    lea rbx, [rel g_vents]
    add rbx, rax
    test word [rbx + VENT.flags], EPF_DYING
    jnz .next
    ; its box (the mob's size; babies half)
    movzx eax, word [rbx + VENT.variant]
    imul eax, eax, VARIANT_size
    lea rcx, [rel g_variants]
    mov eax, [rcx + rax + VARIANT.mob]
    imul eax, eax, MOB_size
    lea rcx, [rel g_mobs]
    add rcx, rax
    cvtss2sd xmm0, [rcx + MOB.width]
    mulsd xmm0, [rel c_half_d]
    cvtss2sd xmm1, [rcx + MOB.height]
    test word [rbx + VENT.flags], EPF_BABY
    jz .adult
    mulsd xmm0, [rel c_baby]
    mulsd xmm1, [rel c_baby]
.adult:
    movsd xmm2, [rbx + VENT.shown]
    movsd xmm3, xmm2
    subsd xmm2, xmm0
    addsd xmm3, xmm0
    movsd [LOCAL(PK_LO)], xmm2
    movsd [LOCAL(PK_HI)], xmm3
    movsd xmm2, [rbx + VENT.shown + 8]
    movsd [LOCAL(PK_LO + 8)], xmm2
    addsd xmm2, xmm1
    movsd [LOCAL(PK_HI + 8)], xmm2
    movsd xmm2, [rbx + VENT.shown + 16]
    movsd xmm3, xmm2
    subsd xmm2, xmm0
    addsd xmm3, xmm0
    movsd [LOCAL(PK_LO + 16)], xmm2
    movsd [LOCAL(PK_HI + 16)], xmm3
    ; slab test
    xorps xmm4, xmm4
    movsd [LOCAL(PK_TMIN)], xmm4
    movsd xmm4, [LOCAL(PK_BEST)]
    movsd [LOCAL(PK_TMAX)], xmm4
    xor ecx, ecx
.axis:
    movsd xmm0, [rdi + rcx * 8]         ; direction
    lea rax, [LOCAL(PK_LO)]
    movsd xmm1, [rax + rcx * 8]
    subsd xmm1, [r12 + rcx * 8]         ; lo - origin
    lea rax, [LOCAL(PK_HI)]
    movsd xmm2, [rax + rcx * 8]
    subsd xmm2, [r12 + rcx * 8]         ; hi - origin
    xorps xmm3, xmm3
    comisd xmm0, xmm3
    jne .slope
    ; parallel: inside the slab or missed
    comisd xmm1, xmm3
    ja .next
    comisd xmm2, xmm3
    jb .next
    jmp .axis_next
.slope:
    divsd xmm1, xmm0
    divsd xmm2, xmm0
    movsd xmm3, xmm1
    minsd xmm1, xmm2                    ; near
    maxsd xmm2, xmm3                    ; far
    maxsd xmm1, [LOCAL(PK_TMIN)]
    movsd [LOCAL(PK_TMIN)], xmm1
    minsd xmm2, [LOCAL(PK_TMAX)]
    movsd [LOCAL(PK_TMAX)], xmm2
    comisd xmm1, xmm2
    ja .next
.axis_next:
    inc ecx
    cmp ecx, 3
    jb .axis
    movsd xmm0, [LOCAL(PK_TMIN)]
    comisd xmm0, [LOCAL(PK_BEST)]
    jae .next
    movsd [LOCAL(PK_BEST)], xmm0
    mov [LOCAL(PK_ID)], esi
.next:
    inc r13d
    jmp .ent
.done:
    mov eax, [LOCAL(PK_ID)]
    movsd xmm0, [LOCAL(PK_BEST)]
    RETURN
ENDPROC

section .rdata
align 4
c_tiny_f:       dd 0.0001
side_dx:        dd 2, -2, 0, 0
side_dz:        dd 0, 0, 2, -2
