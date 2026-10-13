; =============================================================================
; interact.asm — the client's block targeting and editing (milestone 16,
; DECISIONS D86).
;
; Every frame a ray from the eyes along the view finds the first block
; within reach (any block but air and plain liquids; shaped blocks and
; plants count as their whole cell). break_block / place_block send
; requests to the simulation (PKT_C_BREAK / PKT_C_PLACE: the block next to
; the hit face); held down they repeat every REPEAT_US. pick_block makes
; the targeted block the held block. The simulation decides; the client
; only sees the result as PKT_S_BLOCK (client.asm).
; The held block is a stand-in for the hotbar until items (milestone 18):
; it starts as `stone`.
;
; Public API:
;   interact_init()                     after blocks_load
;   interact_update()                   once per frame (client_input)
;   g_target_valid, g_target (3 x i32), g_target_face (0..5: -X +X -Y +Y
;   -Z +Z), g_target_id, g_held_block
; =============================================================================
%include "macros.inc"
%include "input.inc"
%include "packet.inc"
%include "block.inc"
%include "world_api.inc"
%include "save.inc"

global interact_init, interact_update
extern held_swing
global g_dig_want
extern g_world_mode
global g_target_valid, g_target, g_target_face, g_target_id, g_held_block

extern g_cam_pos, g_cam_yaw, g_cam_pitch, g_mouse_captured, g_cl_player
extern sincosf, timer_elapsed_us, g_block_station, g_off_block

%define REPEAT_US       250000          ; holding a button: one action per this
%define MAX_STEPS       64

section .rdata
str_stone:      db "stone", 0
align 8
c_big:          dq 1.0e30
c_one_d:        dq 1.0
align 16
c_abs:          dq 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF
; the cell beside each hit face
face_dx:        dd -1, 1, 0, 0, 0, 0
face_dy:        dd 0, 0, -1, 1, 0, 0
face_dz:        dd 0, 0, 0, 0, -1, 1

section .bss
alignb 8
g_target:       resd 3
g_target_valid: resd 1
g_target_face:  resd 1
g_target_id:    resd 1
g_held_block:   resd 1
g_was_captured: resd 1
g_next_break:   resq 1
g_next_place:   resq 1
alignb 16
g_dir:          resq 3                  ; ray direction (doubles)
g_tmax:         resq 3
g_tdelta:       resq 3
g_cell:         resd 3
g_step:         resd 3
g_req:          resb BLOCK_PKT_size
g_pick:         resb INV_PKT_size
g_dig_want:     resd 1                  ; Survival: break held on the target
g_use:          resb WIN_PKT_size

section .text

; -----------------------------------------------------------------------------
; interact_init — the starting held block.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC interact_init, 0
    lea rcx, [rel str_stone]
    call block_find
    cmp eax, -1
    jne .found
    mov eax, 1                          ; (no stone: the first block)
.found:
    mov [rel g_held_block], eax
    mov dword [rel g_target_valid], 0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; raycast — the first targetable block along the view, within reach.
;   out: g_target_valid / g_target / g_target_face / g_target_id
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC raycast, 16, rbx, rsi, rdi
    mov dword [rel g_target_valid], 0
    movss xmm0, [rel g_cl_player + PLAYER_PKT.reach]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .done                           ; (no player state yet)
    cvtss2sd xmm0, xmm0
    movsd [LOCAL(0)], xmm0              ; reach
    ; direction: (sin yaw cos pitch, sin pitch, -cos yaw cos pitch)
    movss xmm0, [rel g_cam_pitch]
    call sincosf
    cvtss2sd xmm0, xmm0
    movsd [rel g_dir + 8], xmm0
    cvtss2sd xmm1, xmm1
    movsd [LOCAL(8)], xmm1              ; cos pitch
    movss xmm0, [rel g_cam_yaw]
    call sincosf
    cvtss2sd xmm0, xmm0
    mulsd xmm0, [LOCAL(8)]
    movsd [rel g_dir], xmm0
    cvtss2sd xmm1, xmm1
    mulsd xmm1, [LOCAL(8)]
    xorpd xmm2, xmm2
    subsd xmm2, xmm1
    movsd [rel g_dir + 16], xmm2
    ; per axis: cell, step, distance to the first border, distance per cell
    xor ebx, ebx                        ; axis
.axis_setup:
    lea rcx, [rel g_cam_pos]
    movsd xmm0, [rcx + rbx * 8]
    roundsd xmm1, xmm0, 9
    cvttsd2si eax, xmm1
    lea rcx, [rel g_cell]
    mov [rcx + rbx * 4], eax
    lea rcx, [rel g_dir]
    movsd xmm2, [rcx + rbx * 8]
    xorpd xmm3, xmm3
    comisd xmm2, xmm3
    je .flat
    movsd xmm4, [rel c_one_d]
    divsd xmm4, xmm2
    andpd xmm4, [rel c_abs]
    lea rcx, [rel g_tdelta]
    movsd [rcx + rbx * 8], xmm4
    lea rcx, [rel g_step]
    lea rdx, [rel g_tmax]
    comisd xmm2, xmm3
    jb .neg
    mov dword [rcx + rbx * 4], 1
    addsd xmm1, [rel c_one_d]           ; next border above
    subsd xmm1, xmm0
    divsd xmm1, xmm2
    movsd [rdx + rbx * 8], xmm1
    jmp .axis_next
.neg:
    mov dword [rcx + rbx * 4], -1
    subsd xmm1, xmm0                    ; border below (<= 0)
    divsd xmm1, xmm2
    movsd [rdx + rbx * 8], xmm1
    jmp .axis_next
.flat:
    lea rcx, [rel g_step]
    mov dword [rcx + rbx * 4], 0
    mov rax, [rel c_big]
    lea rcx, [rel g_tmax]
    mov [rcx + rbx * 8], rax
    lea rcx, [rel g_tdelta]
    mov [rcx + rbx * 8], rax
.axis_next:
    inc ebx
    cmp ebx, 3
    jb .axis_setup
    mov edi, -1                         ; face entered through (-1: start cell)
    xor esi, esi                        ; steps
.cell:
    mov ecx, [rel g_cell]
    mov edx, [rel g_cell + 4]
    mov r8d, [rel g_cell + 8]
    call world_block_at
    test eax, eax
    jz .advance
    lea rcx, [rel g_block_phys]
    test byte [rcx + rax], BPHYS_LIQUID_MASK
    jz .hit
    lea rcx, [rel g_block_flags]
    test byte [rcx + rax], BLOCKF_WATERLOGGED
    jz .advance                         ; plain liquid: look through
.hit:
    cmp edi, -1
    je .advance                         ; (inside a block: look past it)
    mov [rel g_target_id], eax
    mov eax, [rel g_cell]
    mov [rel g_target], eax
    mov eax, [rel g_cell + 4]
    mov [rel g_target + 4], eax
    mov eax, [rel g_cell + 8]
    mov [rel g_target + 8], eax
    mov [rel g_target_face], edi
    mov dword [rel g_target_valid], 1
    jmp .done
.advance:
    ; the axis whose border is nearest
    xor ebx, ebx
    movsd xmm0, [rel g_tmax]
    comisd xmm0, [rel g_tmax + 8]
    jbe .not_y
    mov ebx, 1
    movsd xmm0, [rel g_tmax + 8]
.not_y:
    comisd xmm0, [rel g_tmax + 16]
    jbe .axis
    mov ebx, 2
    movsd xmm0, [rel g_tmax + 16]
.axis:
    comisd xmm0, [LOCAL(0)]
    ja .done                            ; beyond reach
    lea rcx, [rel g_tdelta]
    addsd xmm0, [rcx + rbx * 8]
    lea rcx, [rel g_tmax]
    movsd [rcx + rbx * 8], xmm0
    lea rcx, [rel g_step]
    mov eax, [rcx + rbx * 4]
    lea rcx, [rel g_cell]
    add [rcx + rbx * 4], eax
    ; entered through the face pointing back along the step:
    ; stepping +x enters through the -X face (0), -x through +X (1)
    lea edi, [ebx * 2]
    cmp eax, 0
    jg .face_set
    inc edi
.face_set:
    inc esi
    cmp esi, MAX_STEPS
    jb .cell
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; send_edit — a break or place request.
;   in:  ecx = packet type, edx = 0 the target / 1 the cell beside its face,
;        r8d = id (place)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC send_edit, 0, rbx
    mov ebx, ecx
    mov [rel g_req + BLOCK_PKT.id], r8d
    mov eax, [rel g_target]
    mov ecx, [rel g_target + 4]
    mov r8d, [rel g_target + 8]
    test edx, edx
    jz .at
    mov r9d, [rel g_target_face]
    lea r10, [rel face_dx]
    add eax, [r10 + r9 * 4]
    lea r10, [rel face_dy]
    add ecx, [r10 + r9 * 4]
    lea r10, [rel face_dz]
    add r8d, [r10 + r9 * 4]
.at:
    mov [rel g_req + BLOCK_PKT.x], eax
    mov [rel g_req + BLOCK_PKT.y], ecx
    mov [rel g_req + BLOCK_PKT.z], r8d
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_req]
    INVOKE pkt_send, rcx, rbx, r8, BLOCK_PKT_size
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; action_due — the first press, or every REPEAT_US while held.
;   in:  ecx = action, rdx = the action's "next" timestamp (qword*)
;   out: eax = 1 to act now
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC action_due, 0, rbx, rsi
    mov ebx, ecx
    mov rsi, rdx
    call input_pressed
    test eax, eax
    jnz .act
    mov ecx, ebx
    call input_down
    test eax, eax
    jz .no
    call timer_elapsed_us
    cmp rax, [rsi]
    jb .no
.act:
    call timer_elapsed_us
    add rax, REPEAT_US
    mov [rsi], rax
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; interact_update — target, then break / place / pick.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC interact_update, 0, rbx
    mov dword [rel g_dig_want], 0
    call raycast
    ; only with the mouse captured, and not on the click that captured it
    mov ebx, [rel g_was_captured]
    mov eax, [rel g_mouse_captured]
    mov [rel g_was_captured], eax
    test eax, eax
    jz .done
    test ebx, ebx
    jz .done
    cmp dword [rel g_target_valid], 0
    je .done
    cmp dword [rel g_world_mode], MODE_CREATIVE
    je .creative_break
    ; Survival: hold to mine (the simulation counts the time; dig.asm)
    mov ecx, ACT_BREAK_BLOCK
    call input_down
    mov [rel g_dig_want], eax
    mov ecx, ACT_BREAK_BLOCK
    lea rdx, [rel g_next_break]
    call action_due
    test eax, eax
    jz .no_break
    call held_swing                     ; (swings on while mining)
    jmp .no_break
.creative_break:
    mov ecx, ACT_BREAK_BLOCK
    lea rdx, [rel g_next_break]
    call action_due
    test eax, eax
    jz .no_break
    mov ecx, PKT_C_BREAK
    xor edx, edx
    xor r8d, r8d
    call send_edit
    call held_swing
.no_break:
    mov ecx, ACT_PLACE_BLOCK
    lea rdx, [rel g_next_place]
    call action_due
    test eax, eax
    jz .no_place
    ; a crafting station (or later a chest): use it; sneaking places
    mov eax, [rel g_target_id]
    lea rcx, [rel g_block_station]
    cmp byte [rcx + rax], 0
    je .place
    mov ecx, ACT_MOVE_DOWN
    call input_down
    test eax, eax
    jnz .place
    mov dword [rel g_use + WIN_PKT.kind], WIN_USE
    mov eax, [rel g_target]
    mov [rel g_use + WIN_PKT.pos], eax
    mov eax, [rel g_target + 4]
    mov [rel g_use + WIN_PKT.pos + 4], eax
    mov eax, [rel g_target + 8]
    mov [rel g_use + WIN_PKT.pos + 8], eax
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_use]
    INVOKE pkt_send, rcx, PKT_C_WINDOW, r8, WIN_PKT_size
    jmp .no_place
.place:
    mov r8d, [rel g_held_block]
    test r8d, r8d
    jnz .placeable
    mov r8d, [rel g_off_block]          ; (else from the off hand)
    test r8d, r8d
    jz .no_place                        ; (nothing placeable in hand)
.placeable:
    mov ecx, PKT_C_PLACE
    mov edx, 1
    call send_edit
    call held_swing
.no_place:
    mov ecx, ACT_PICK_BLOCK
    call input_pressed
    test eax, eax
    jz .done
    ; the simulation brings the item to hand (milestone 18)
    mov eax, [rel g_target_id]
    mov [rel g_pick + INV_PKT.item], eax
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_pick]
    INVOKE pkt_send, rcx, PKT_C_PICK, r8, INV_PKT_size
.done:
    RETURN
ENDPROC
