; =============================================================================
; use.asm — using the item in hand on what the player looks at, when that
; is not placing a block (milestone 19 part 3b): a container takes the
; first block along the view it has a `fill` line for — an empty bucket
; scoops a water or lava source (data/items: fill = water, water_bucket).
; The view is followed from the eyes in small steps up to the reach; air,
; plants and liquids the item does not take (flowing water) are looked
; through, anything else ends the look.
;
; Public API:
;   use_item(rcx = INPUT_PKT*)          PKT_C_USE: the item in hand
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "packet.inc"
%include "items.inc"
%include "block.inc"
%include "world.inc"

global use_item

extern phys_block, edit_apply, item_fill, inv_turn_slot, drops_spawn, sincosf
extern g_inv, g_inv_sel, g_pl_pos, g_pl_eye, g_pl_reach

%define SLOT_SIZE   8
%define STEP        0.05                ; blocks per look step

section .rdata
align 8
c_step:         dq STEP
c_half:         dq 0.5

section .bss
alignb 8
g_dir:          resq 3                  ; the view (unit)
g_at:           resq 3                  ; where a filled bucket that did not fit drops

section .text

; -----------------------------------------------------------------------------
; use_item — see the header.
;   in:  rcx = INPUT_PKT* (the view: yaw, pitch)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define U_ITEM  0
%define U_T     8                       ; f64 distance along the view
%define U_CX    16                      ; the cell looked at (i32 x 3)
%define U_LAST  28                      ; the last cell (i32 x 3)
%define U_END   40                      ; f64 the reach
PROC use_item, 64, rbx, rsi, rdi
    mov rbx, rcx
    mov eax, [rel g_inv_sel]
    lea rcx, [rel g_inv]
    movzx eax, word [rcx + rax * SLOT_SIZE]
    test eax, eax
    jz .done
    mov [LOCAL(U_ITEM)], eax
    ; the view: (sin yaw cos pitch, sin pitch, -cos yaw cos pitch)
    movss xmm0, [rbx + INPUT_PKT.pitch]
    call sincosf
    cvtss2sd xmm0, xmm0
    movsd [rel g_dir + 8], xmm0
    cvtss2sd xmm1, xmm1
    movsd [LOCAL(U_T)], xmm1            ; (cos pitch for a moment)
    movss xmm0, [rbx + INPUT_PKT.yaw]
    call sincosf
    cvtss2sd xmm0, xmm0
    mulsd xmm0, [LOCAL(U_T)]
    movsd [rel g_dir], xmm0
    cvtss2sd xmm1, xmm1
    mulsd xmm1, [LOCAL(U_T)]
    xorps xmm2, xmm2
    subsd xmm2, xmm1
    movsd [rel g_dir + 16], xmm2
    cvtss2sd xmm0, [rel g_pl_reach]
    movsd [LOCAL(U_END)], xmm0
    xorps xmm0, xmm0
    movsd [LOCAL(U_T)], xmm0
    mov dword [LOCAL(U_LAST)], 0x7FFFFFFF
.step:
    movsd xmm0, [LOCAL(U_T)]
    addsd xmm0, [rel c_step]
    movsd [LOCAL(U_T)], xmm0
    comisd xmm0, [LOCAL(U_END)]
    ja .done
    ; the cell at eyes + view * t
    xor esi, esi
.axis:
    lea rax, [rel g_dir]
    movsd xmm1, [rax + rsi * 8]
    mulsd xmm1, [LOCAL(U_T)]
    lea rax, [rel g_pl_pos]
    addsd xmm1, [rax + rsi * 8]
    cmp esi, 1
    jne .floor
    cvtss2sd xmm2, [rel g_pl_eye]
    addsd xmm1, xmm2
.floor:
    roundsd xmm1, xmm1, 9
    cvttsd2si eax, xmm1
    mov [LOCAL(U_CX) + rsi * 4], eax
    inc esi
    cmp esi, 3
    jb .axis
    ; a new cell?
    mov eax, [LOCAL(U_CX)]
    cmp eax, [LOCAL(U_LAST)]
    jne .new
    mov eax, [LOCAL(U_CX) + 4]
    cmp eax, [LOCAL(U_LAST) + 4]
    jne .new
    mov eax, [LOCAL(U_CX) + 8]
    cmp eax, [LOCAL(U_LAST) + 8]
    je .step
.new:
    mov eax, [LOCAL(U_CX)]
    mov [LOCAL(U_LAST)], eax
    mov eax, [LOCAL(U_CX) + 4]
    mov [LOCAL(U_LAST) + 4], eax
    mov eax, [LOCAL(U_CX) + 8]
    mov [LOCAL(U_LAST) + 8], eax
    mov ecx, [LOCAL(U_CX)]
    mov edx, [LOCAL(U_CX) + 4]
    mov r8d, [LOCAL(U_CX) + 8]
    call phys_block
    cmp eax, -1
    je .done                            ; (not generated)
    test eax, eax
    jz .step                            ; air: look on
    ; the first thing seen: does the item take it?
    mov [LOCAL(U_ITEM) + 4], eax
    mov edx, eax
    mov ecx, [LOCAL(U_ITEM)]
    call item_fill
    test eax, eax
    jnz .take
    ; not taken: plants and liquids are looked through, the rest stops it
    mov eax, [LOCAL(U_ITEM) + 4]
    lea rcx, [rel g_block_phys]
    test byte [rcx + rax], BPHYS_LIQUID_MASK
    jnz .step
    lea rcx, [rel g_block_shape]
    movzx ecx, byte [rcx + rax]
    cmp ecx, SHAPE_PLANT
    je .step
    cmp ecx, SHAPE_TALL_PLANT
    je .step
    jmp .done
.take:
    mov edi, eax                        ; what the item becomes
    mov ecx, [LOCAL(U_CX)]
    mov edx, [LOCAL(U_CX) + 4]
    mov r8d, [LOCAL(U_CX) + 8]
    xor r9d, r9d                        ; (air)
    call edit_apply
    cmp eax, 1
    jne .done
    mov ecx, [rel g_inv_sel]
    mov edx, edi
    call inv_turn_slot
    test eax, eax
    jz .taken
    ; no room: the full bucket drops at the player's feet
    mov rax, [rel g_pl_pos]
    mov [rel g_at], rax
    movsd xmm0, [rel g_pl_pos + 8]
    addsd xmm0, [rel c_half]
    movsd [rel g_at + 8], xmm0
    mov rax, [rel g_pl_pos + 16]
    mov [rel g_at + 16], rax
    mov ecx, edi
    mov edx, 1
    lea r8, [rel g_at]
    call drops_spawn
.taken:
    LOG_DEBUG "use: a container took a block"
.done:
    RETURN
ENDPROC
