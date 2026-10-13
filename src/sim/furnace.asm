; =============================================================================
; furnace.asm — furnaces at work (milestone 18 part 4,
; design/items/items_inventory.md): every tick, every furnace the player has
; used (a container entry whose station is a [furnace] in data/recipes)
; burns its fuel and smelts its input, whether the player is near or not.
;
;   slots: FURNACE_IN, FURNACE_FUEL, FURNACE_OUT (containers.inc)
;   A new fuel item is taken when the furnace has something it can smelt
;   and room for the result; one item smelts in the [smelt]'s seconds,
;   divided by the furnace's speed (fuel burns that much faster too). The
;   cooking goes back while the fire is out. A burning furnace shows its
;   `lit` block (same facing), and goes back when the fire dies.
;   While its window is open, the window's slots are the furnace's slots
;   (so the player sees it work) and PKT_S_FURNACE tells the progress.
;
; Public API:
;   furnace_tick()                      once per simulation tick
; =============================================================================
%include "macros.inc"
%include "packet.inc"
%include "items.inc"
%include "containers.inc"

global furnace_tick

extern g_inv, inv_mark, inv_stack_of, smelt_find, fuel_ticks
extern g_smelt_result, g_smelt_amount, g_smelt_ticks
extern g_station_kind, g_station_speed, g_station_blast, g_station_lit
extern g_station_unlit, g_block_state, phys_block, edit_apply
extern g_win_kind, g_win_cont, pkt_send, g_to_client

%define SLOT_SIZE       8

section .bss
alignb 8
g_out:          resb FURNACE_PKT_size

section .text

; -----------------------------------------------------------------------------
; furnace_tick — see the header.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define F_ST        0                   ; station index
%define F_SPEED     4
%define F_SMELT     8                   ; -1: nothing to smelt
%define F_CAN       12                  ; room for the result
%define F_OPEN      16                  ; this is the open window's furnace
%define F_CHANGED   20
PROC furnace_tick, 32, rbx, rsi, rdi, r12
    lea rbx, [rel g_conts]
    xor r12d, r12d                      ; entry
.entry:
    cmp r12d, [rel g_cont_count]
    jae .done
    cmp dword [rbx + CONT.used], 0
    je .next
    movzx eax, byte [rbx + CONT.station]
    test eax, eax
    jz .next
    dec eax
    lea rcx, [rel g_station_kind]
    cmp byte [rcx + rax], STATION_FURNACE
    jne .next
    mov [LOCAL(F_ST)], eax
    lea rcx, [rel g_station_speed]
    movzx ecx, byte [rcx + rax]
    mov [LOCAL(F_SPEED)], ecx
    mov dword [LOCAL(F_CHANGED)], 0
    ; its slots: the window's while it is open
    lea rsi, [rbx + CONT.slots]
    mov dword [LOCAL(F_OPEN)], 0
    cmp dword [rel g_win_kind], WIN_FURNACE
    jne .slots
    cmp [rel g_win_cont], r12d
    jne .slots
    lea rsi, [rel g_inv + INV_CONTAINER * SLOT_SIZE]
    mov dword [LOCAL(F_OPEN)], 1
.slots:
    ; what the input smelts into, and is there room for it?
    mov dword [LOCAL(F_CAN)], 0
    movzx ecx, word [rsi + FURNACE_IN * SLOT_SIZE]
    mov eax, [LOCAL(F_ST)]
    lea rdx, [rel g_station_blast]
    movzx edx, byte [rdx + rax]
    call smelt_find
    mov [LOCAL(F_SMELT)], eax
    cmp eax, -1
    je .burn
    lea rcx, [rel g_smelt_result]
    movzx edi, word [rcx + rax * 2]     ; result item
    movzx ecx, word [rsi + FURNACE_OUT * SLOT_SIZE]
    test ecx, ecx
    jz .room
    cmp ecx, edi
    jne .burn
    mov ecx, edi
    call inv_stack_of
    movzx ecx, word [rsi + FURNACE_OUT * SLOT_SIZE + 2]
    mov edx, [LOCAL(F_SMELT)]
    lea r8, [rel g_smelt_amount]
    movzx edx, byte [r8 + rdx]
    add ecx, edx
    cmp ecx, eax
    ja .burn
.room:
    mov dword [LOCAL(F_CAN)], 1
.burn:
    ; the fire burns down
    mov eax, [rbx + CONT.burn]
    test eax, eax
    jz .fuel
    sub eax, [LOCAL(F_SPEED)]
    jns .burnt
    xor eax, eax
.burnt:
    mov [rbx + CONT.burn], eax
.fuel:
    ; out, with work to do: the next fuel item
    cmp dword [rbx + CONT.burn], 0
    jne .cook
    cmp dword [LOCAL(F_CAN)], 0
    je .cook
    movzx ecx, word [rsi + FURNACE_FUEL * SLOT_SIZE]
    call fuel_ticks
    test eax, eax
    jz .cook
    mov [rbx + CONT.burn], eax
    mov [rbx + CONT.burn_max], eax
    dec word [rsi + FURNACE_FUEL * SLOT_SIZE + 2]
    jnz .fuel_taken
    mov qword [rsi + FURNACE_FUEL * SLOT_SIZE], 0
.fuel_taken:
    mov dword [LOCAL(F_CHANGED)], 1
.cook:
    cmp dword [LOCAL(F_CAN)], 0
    je .no_cook
    cmp dword [rbx + CONT.burn], 0
    je .cooling
    mov eax, [rbx + CONT.cook]
    add eax, [LOCAL(F_SPEED)]
    mov [rbx + CONT.cook], eax
    mov ecx, [LOCAL(F_SMELT)]
    lea rdx, [rel g_smelt_ticks]
    cmp eax, [rdx + rcx * 4]
    jb .lit
    ; one done
    mov dword [rbx + CONT.cook], 0
    dec word [rsi + FURNACE_IN * SLOT_SIZE + 2]
    jnz .in_left
    mov qword [rsi + FURNACE_IN * SLOT_SIZE], 0
.in_left:
    lea rdx, [rel g_smelt_amount]
    movzx edx, byte [rdx + rcx]
    mov [rsi + FURNACE_OUT * SLOT_SIZE], di
    add [rsi + FURNACE_OUT * SLOT_SIZE + 2], dx
    mov dword [LOCAL(F_CHANGED)], 1
    jmp .lit
.cooling:
    ; the fire is out: the cooking goes back
    mov eax, [rbx + CONT.cook]
    mov ecx, [LOCAL(F_SPEED)]
    add ecx, ecx
    sub eax, ecx
    jns .cooled
    xor eax, eax
.cooled:
    mov [rbx + CONT.cook], eax
    jmp .lit
.no_cook:
    mov dword [rbx + CONT.cook], 0
.lit:
    ; burning: the lit block; out: the plain one
    xor eax, eax
    cmp dword [rbx + CONT.burn], 0
    setne al
    cmp al, [rbx + CONT.lit]
    je .shown
    call swap_block
.shown:
    cmp dword [LOCAL(F_OPEN)], 0
    je .next
    ; the window: changed slots and the progress
    cmp dword [LOCAL(F_CHANGED)], 0
    je .progress
    mov ecx, INV_CONTAINER + FURNACE_IN
    call inv_mark
    mov ecx, INV_CONTAINER + FURNACE_FUEL
    call inv_mark
    mov ecx, INV_CONTAINER + FURNACE_OUT
    call inv_mark
.progress:
    xorps xmm0, xmm0
    mov ecx, [LOCAL(F_SMELT)]
    cmp ecx, -1
    je .cook_f
    cvtsi2ss xmm0, dword [rbx + CONT.cook]
    lea rdx, [rel g_smelt_ticks]
    cvtsi2ss xmm1, dword [rdx + rcx * 4]
    divss xmm0, xmm1
.cook_f:
    movss [rel g_out + FURNACE_PKT.cook], xmm0
    xorps xmm0, xmm0
    mov eax, [rbx + CONT.burn_max]
    test eax, eax
    jz .burn_f
    cvtsi2ss xmm0, dword [rbx + CONT.burn]
    cvtsi2ss xmm1, eax
    divss xmm0, xmm1
.burn_f:
    movss [rel g_out + FURNACE_PKT.burn], xmm0
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_FURNACE, r8, FURNACE_PKT_size
.next:
    add rbx, CONT_size
    inc r12d
    jmp .entry
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; swap_block — show entry rbx burning (al = 1) or not: its station's lit or
; plain block in the same state; .lit is updated once the change is made
; (an unloaded or busy block is tried again next tick).
;   in:  rbx = CONT*, al = 1 burning
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC swap_block, 0, rsi, rdi
    movzx esi, al                       ; wanted lit state
    movzx edi, byte [rbx + CONT.station]
    dec edi
    lea rcx, [rel g_station_lit]
    movzx eax, word [rcx + rdi * 2]
    test esi, esi
    jnz .base
    lea rcx, [rel g_station_unlit]
    movzx eax, word [rcx + rdi * 2]
.base:
    test eax, eax
    jz .no_block                        ; (no lit block in the data)
    mov edi, eax                        ; the base id wanted
    mov ecx, [rbx + CONT.x]
    mov edx, [rbx + CONT.y]
    mov r8d, [rbx + CONT.z]
    call phys_block
    cmp eax, 0
    jle .done                           ; not loaded: later
    lea rcx, [rel g_block_state]
    movzx ecx, byte [rcx + rax]
    add edi, ecx                        ; the same facing
    cmp eax, edi
    je .set                             ; (already)
    mov ecx, [rbx + CONT.x]
    mov edx, [rbx + CONT.y]
    mov r8d, [rbx + CONT.z]
    mov r9d, edi
    call edit_apply
    test eax, eax
    jz .done                            ; busy: next tick
.set:
    mov [rbx + CONT.lit], sil
.done:
    RETURN
.no_block:
    mov [rbx + CONT.lit], sil
    RETURN
ENDPROC
