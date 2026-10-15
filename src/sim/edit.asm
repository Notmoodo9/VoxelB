; =============================================================================
; edit.asm — block edits in the simulation (milestone 16, DECISIONS D86).
;
; The client asks (PKT_C_BREAK / PKT_C_PLACE); the simulation checks the
; request, queues the changes and applies them when the column is free (no
; mesh job reads it), then tells the client (PKT_S_BLOCK) so it can mesh
; again. Creative rules:
;   break: any block but air and liquids, instantly. The other half of a
;     door or tall plant goes with it, and so does a plant standing on top.
;   place: into air, a liquid or a plant, within reach, never inside the
;     player's body (blocks without collision may go anywhere).
; Requests farther than reach (+1 for rounding) from the eyes are ignored.
; A change that can't be applied yet waits (in order) up to RETRY_TICKS.
;
; Public API:
;   edit_request(rcx = BLOCK_PKT*, edx = 0 break / 1 place)
;   edit_tick()                         apply what can be applied
;   edit_apply(ecx=x, edx=y, r8d=z, r9d=id) -> eax as world_set_block:
;       change a block now, tell the client, and wake the liquids around it
;       (fluid.asm uses it too)
;   edit_queue(ecx=x, edx=y, r8d=z, r9d=id)   change a block as soon as its
;       column is free (retried up to RETRY_TICKS; graves.asm)
;   g_edit_applied, g_edit_rejected     counters (overlay)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "block.inc"
%include "world_api.inc"
%include "packet.inc"
%include "physics.inc"

global edit_reset, edit_request, edit_tick, edit_apply, edit_queue
global g_edit_applied, g_edit_rejected

extern g_pl_pos, g_pl_eye, g_pl_reach, g_pl_width, g_pl_height
extern fluid_schedule_around, craft_block_broken, graves_broken

%define QUEUE_SLOTS     64              ; power of two
%define RETRY_TICKS     100             ; 5 s
%define DEFAULT_FLOW_DELAY 5            ; liquids next to an edit look again after this
struc EDIT
    .x      resd 1
    .y      resd 1
    .z      resd 1
    .id     resd 1
    .left   resd 1                      ; ticks left to retry
    .pad    resd 3
endstruc

section .rdata
align 8
c_half_d:       dq 0.5
c_one_d:        dq 1.0
c_eps:          dq 1.0e-4

section .bss
alignb 16
g_edits:        resb QUEUE_SLOTS * EDIT_size
g_edit_head:    resd 1                  ; next to write
g_edit_tail:    resd 1                  ; next to apply
g_edit_applied: resq 1
g_edit_rejected: resq 1
g_edit_out:     resb BLOCK_PKT_size

section .text

; edit_reset — forget queued changes (another world comes next)
edit_reset:
    mov eax, [rel g_edit_head]
    mov [rel g_edit_tail], eax
    ret

; -----------------------------------------------------------------------------
; queue_edit — append a change (dropped if the queue is full).
;   in:  ecx = x, edx = y, r8d = z, r9d = id
;   clobbers: rax, r10, r11
; -----------------------------------------------------------------------------
edit_queue:
queue_edit:
    mov eax, [rel g_edit_head]
    mov r10d, eax
    sub r10d, [rel g_edit_tail]
    cmp r10d, QUEUE_SLOTS
    jae .full
    mov r10d, eax
    and r10d, QUEUE_SLOTS - 1
    shl r10d, 5                         ; * EDIT_size
    lea r11, [rel g_edits]
    add r11, r10
    mov [r11 + EDIT.x], ecx
    mov [r11 + EDIT.y], edx
    mov [r11 + EDIT.z], r8d
    mov [r11 + EDIT.id], r9d
    mov dword [r11 + EDIT.left], RETRY_TICKS
    inc dword [rel g_edit_head]
    ret
.full:
    inc qword [rel g_edit_rejected]
    ret

; -----------------------------------------------------------------------------
; in_reach — is the block's centre within reach (+1) of the player's eyes?
;   in:  ecx = x, edx = y, r8d = z
;   out: eax = 1 / 0
;   clobbers: rax, xmm0-xmm3
; -----------------------------------------------------------------------------
in_reach:
    cvtsi2sd xmm0, ecx
    addsd xmm0, [rel c_half_d]
    subsd xmm0, [rel g_pl_pos]
    mulsd xmm0, xmm0
    cvtsi2sd xmm1, edx
    addsd xmm1, [rel c_half_d]
    subsd xmm1, [rel g_pl_pos + 8]
    cvtss2sd xmm2, [rel g_pl_eye]
    subsd xmm1, xmm2
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    cvtsi2sd xmm1, r8d
    addsd xmm1, [rel c_half_d]
    subsd xmm1, [rel g_pl_pos + 16]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    cvtss2sd xmm3, [rel g_pl_reach]
    addsd xmm3, [rel c_one_d]
    mulsd xmm3, xmm3
    xor eax, eax
    comisd xmm0, xmm3
    ja .no
    mov eax, 1
.no:
    ret

; -----------------------------------------------------------------------------
; in_body — does the cell (x, y, z) overlap the player's body?
;   in:  ecx = x, edx = y, r8d = z
;   out: eax = 1 / 0
;   clobbers: rax, xmm0-xmm3
; -----------------------------------------------------------------------------
in_body:
    xor eax, eax
    cvtss2sd xmm3, [rel g_pl_width]
    mulsd xmm3, [rel c_half_d]
    subsd xmm3, [rel c_eps]             ; (touching is fine)
    ; x: |cell centre - pos| < 0.5 + half width
    cvtsi2sd xmm0, ecx
    addsd xmm0, [rel c_half_d]
    subsd xmm0, [rel g_pl_pos]
    movsd xmm1, xmm3
    addsd xmm1, [rel c_half_d]
    andpd xmm0, [rel c_abs]
    comisd xmm0, xmm1
    jae .no
    cvtsi2sd xmm0, r8d
    addsd xmm0, [rel c_half_d]
    subsd xmm0, [rel g_pl_pos + 16]
    andpd xmm0, [rel c_abs]
    comisd xmm0, xmm1
    jae .no
    ; y: cell [y, y+1] against [feet, feet + height]
    cvtsi2sd xmm0, edx
    addsd xmm0, [rel c_one_d]
    subsd xmm0, [rel c_eps]
    comisd xmm0, [rel g_pl_pos + 8]
    jbe .no
    cvtsi2sd xmm0, edx
    addsd xmm0, [rel c_eps]
    cvtss2sd xmm1, [rel g_pl_height]
    addsd xmm1, [rel g_pl_pos + 8]
    comisd xmm0, xmm1
    jae .no
    mov eax, 1
.no:
    ret

; -----------------------------------------------------------------------------
; two_high — the other half of a door or tall plant at (x, y, z), if any.
;   in:  ecx = x, edx = y, r8d = z, r9d = id there
;   out: eax = y of the other half, or 0x7FFFFFFF if none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC two_high, 16, rbx, rsi, rdi, r12, r13
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    lea rax, [rel g_block_shape]
    movzx r12d, byte [rax + r9]
    lea rax, [rel g_block_state]
    movzx r13d, byte [rax + r9]
    mov eax, r9d
    sub eax, r13d
    mov [LOCAL(0)], eax                 ; base id
    ; upper half? tall plant: state bit 0; door: bit 2
    mov ecx, 1
    cmp r12d, SHAPE_TALL_PLANT
    je .half
    mov ecx, 4
    cmp r12d, SHAPE_DOOR
    jne .none
.half:
    lea edx, [esi + 1]                  ; lower half: the other is above
    test r13d, ecx
    jz .look
    lea edx, [esi - 1]
.look:
    mov [LOCAL(4)], edx
    mov ecx, ebx
    mov r8d, edi
    call phys_block
    cmp eax, 0
    jle .none
    lea rcx, [rel g_block_state]
    movzx ecx, byte [rcx + rax]
    sub eax, ecx
    cmp eax, [LOCAL(0)]                 ; the same block?
    jne .none
    mov eax, [LOCAL(4)]
    RETURN
.none:
    mov eax, 0x7FFFFFFF
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; edit_request — check a client's request and queue its changes.
;   in:  rcx = BLOCK_PKT*, edx = 0 break, 1 place
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC edit_request, 16, rbx, rsi, rdi, r12, r13, r14
    mov ebx, [rcx + BLOCK_PKT.x]
    mov esi, [rcx + BLOCK_PKT.y]
    mov edi, [rcx + BLOCK_PKT.z]
    mov r12d, [rcx + BLOCK_PKT.id]
    mov r13d, edx
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    call in_reach
    test eax, eax
    jz .reject
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    call phys_block
    cmp eax, -1
    je .reject                          ; not generated
    mov r14d, eax                       ; the block there now
    test r13d, r13d
    jnz .place

    ; ---- break ----
    test r14d, r14d
    jz .reject
    lea rax, [rel g_block_move]
    test byte [rax + r14], MOVE_WATER | MOVE_LAVA
    jz .breakable
    lea rax, [rel g_block_flags]
    test byte [rax + r14], BLOCKF_WATERLOGGED
    jz .reject                          ; (liquids can't be broken)
.breakable:
    ; the other half of a door / tall plant
    INVOKE two_high, rbx, rsi, rdi, r14
    cmp eax, 0x7FFFFFFF
    je .no_half
    mov edx, eax
    mov ecx, ebx
    mov r8d, edi
    xor r9d, r9d
    call queue_edit
.no_half:
    ; a plant standing on it
    lea edx, [esi + 1]
    mov ecx, ebx
    mov r8d, edi
    call phys_block
    cmp eax, 0
    jle .no_plant
    lea rcx, [rel g_block_shape]
    movzx ecx, byte [rcx + rax]
    cmp ecx, SHAPE_PLANT
    je .plant
    cmp ecx, SHAPE_TALL_PLANT
    jne .no_plant
    lea rcx, [rel g_block_state]
    test byte [rcx + rax], 1
    jnz .no_plant                       ; (an upper half: its own lower is here)
    lea edx, [esi + 2]                  ; the tall plant's upper half too
    mov ecx, ebx
    mov r8d, edi
    xor r9d, r9d
    call queue_edit
.plant:
    lea edx, [esi + 1]
    mov ecx, ebx
    mov r8d, edi
    xor r9d, r9d
    call queue_edit
.no_plant:
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    xor r9d, r9d
    call queue_edit
    ; a window on it closes; a chest's items drop (milestone 18)
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    call craft_block_broken
    mov ecx, ebx                        ; a gravestone's items drop (milestone 20)
    mov edx, esi
    mov r8d, edi
    call graves_broken
    mov eax, 1
    RETURN

    ; ---- place ----
.place:
    test r12d, r12d
    jz .reject
    cmp r12d, [rel g_block_count]
    jae .reject
    ; the cell must take it: air, a liquid or a plant
    test r14d, r14d
    jz .free
    lea rax, [rel g_block_move]
    test byte [rax + r14], MOVE_WATER | MOVE_LAVA
    jnz .free
    lea rax, [rel g_block_shape]
    movzx eax, byte [rax + r14]
    cmp eax, SHAPE_PLANT
    je .free
    cmp eax, SHAPE_TALL_PLANT
    jne .reject
.free:
    lea rax, [rel g_block_coll]
    cmp byte [rax + r12], 0
    je .fits                            ; no collision: anywhere
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    call in_body
    test eax, eax
    jnz .reject
.fits:
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    mov r9d, r12d
    call queue_edit
    mov eax, 1
    RETURN
.reject:
    inc qword [rel g_edit_rejected]
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; edit_tick — apply queued changes in order; stop at the first one whose
; column is busy (so the order is kept), dropping it after RETRY_TICKS.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC edit_tick, 0, rbx
.next:
    mov eax, [rel g_edit_tail]
    cmp eax, [rel g_edit_head]
    je .done
    and eax, QUEUE_SLOTS - 1
    shl eax, 5
    lea rbx, [rel g_edits]
    add rbx, rax
    mov ecx, [rbx + EDIT.x]
    mov edx, [rbx + EDIT.y]
    mov r8d, [rbx + EDIT.z]
    mov r9d, [rbx + EDIT.id]
    call edit_apply
    test eax, eax
    jz .wait
    inc dword [rel g_edit_tail]         ; (done, or impossible: dropped)
    jmp .next
.wait:
    dec dword [rbx + EDIT.left]
    jnz .done
    inc dword [rel g_edit_tail]         ; waited too long: dropped
    inc qword [rel g_edit_rejected]
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; edit_apply — change a block now (if no job reads its column), announce it
; to the client and wake the liquids around it.
;   in:  ecx = x, edx = y, r8d = z, r9d = id
;   out: eax = 1 done, 0 not now (busy), -1 impossible
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC edit_apply, 0, rbx, rsi, rdi, r12, r13
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    mov r12d, r9d
    call world_set_block
    mov r13d, eax
    cmp eax, 1
    jne .done
    inc qword [rel g_edit_applied]
    mov [rel g_edit_out + BLOCK_PKT.x], ebx
    mov [rel g_edit_out + BLOCK_PKT.y], esi
    mov [rel g_edit_out + BLOCK_PKT.z], edi
    mov [rel g_edit_out + BLOCK_PKT.id], r12d
    lea rcx, [rel g_to_client]
    lea r8, [rel g_edit_out]
    INVOKE pkt_send, rcx, PKT_S_BLOCK, r8, BLOCK_PKT_size
    ; liquids around it look again after a step of the liquid involved
    mov r9d, DEFAULT_FLOW_DELAY
    lea rax, [rel g_block_shape]
    cmp byte [rax + r12], SHAPE_FLUID
    jne .schedule
    lea rax, [rel g_block_fdelay]
    movzx r9d, byte [rax + r12]
.schedule:
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    call fluid_schedule_around
.done:
    mov eax, r13d
    RETURN
ENDPROC

section .rdata
align 16
c_abs:          dq 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF
