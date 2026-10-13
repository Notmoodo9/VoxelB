; =============================================================================
; inventory.asm — the player's inventory, owned by the simulation
; (milestone 18, design/items/items_inventory.md).
;
; 36 slots: 0-8 the hotbar, 9-35 the inventory, plus the stack carried by
; the mouse in the inventory screen (INV_CURSOR), and the open window's
; slots (packet.inc: the crafting grid, its result, a container; part 3,
; crafting.asm). A slot is {u16 item,
; u16 count, u16 durability, u16 spare}. The client asks with packets
; (select, pick, click, Creative set); every changed slot goes back as
; PKT_S_SLOT at the end of the tick, so the client's copy is only a view.
;
; Public API:
;   inv_init()                       start: player.dat's slots, else the
;                                    held block (g_held_block) in slot 0
;   inv_packet(ecx = type, rdx = INV_PKT*)   C_SELECT / C_PICK / C_INV_CLICK /
;                                    C_CREATIVE_SET
;   inv_selected_block() -> eax      the block the item in hand places (0)
;   inv_used_selected()              one placed: Survival uses up one
;   inv_wear_selected()              the tool in hand broke a block: Survival
;                                    wears it by one (slot durability field =
;                                    uses spent); worn out, it breaks
;   inv_add(ecx = item, edx = count) -> eax count that did not fit
;   inv_flush()                      send the changed slots (end of tick)
;   inv_mark(ecx = slot)             a slot changed (clobbers rax)
;   inv_stack_of(ecx = item) -> eax  its stack size (clobbers rax)
;   inv_room(ecx = item) -> eax      how many more fit in slots 0-35
;   inv_cursor_back()                the carried stack back into the slots
;   g_inv (SLOT[INV_ALL]), g_inv_sel
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "packet.inc"
%include "items.inc"
%include "save.inc"

global inv_init, inv_packet, inv_selected_block, inv_used_selected, inv_add
global inv_wear_selected
global inv_flush, g_inv, g_inv_sel, inv_mark, inv_stack_of, inv_room
global inv_cursor_back

extern craft_update, craft_take, g_win_grid, g_win_slots, g_win_kind
extern smelt_find, fuel_ticks, g_station_blast, g_win_station

extern pkt_send, g_world_mode, g_held_block
extern g_save_inv, g_save_inv_loaded, g_save_inv_sel

%define SLOT_ITEM       0
%define SLOT_COUNT      2
%define SLOT_DUR        4
%define SLOT_SIZE       8
%define ALL_SLOTS       INV_ALL         ; with the cursor and the window

section .bss
alignb 8
g_inv:          resb ALL_SLOTS * SLOT_SIZE
g_inv_sel:      resd 1
g_dirty:        resq 2                  ; bit per slot (INV_ALL bits)
g_sel_dirty:    resd 1
g_out:          resb INV_PKT_size

section .text

; slot_ptr — rax = &g_inv[ecx]
%macro SLOT_PTR 2                       ; out reg, slot reg (32-bit)
    lea %1, [rel g_inv]
    lea %1, [%1 + %2 * SLOT_SIZE]
%endmacro

; mark (inv_mark) — slot ecx changed   clobbers: rax
inv_mark:
mark:
    mov eax, ecx
    bts [rel g_dirty], rax
    ret

; stack_of (inv_stack_of) — eax = the stack size of item ecx (1..64)
inv_stack_of:
stack_of:
    lea rax, [rel g_item_stack]
    movzx eax, byte [rax + rcx]
    test eax, eax
    jnz .ok
    mov eax, 64
.ok:
    ret

; set_slot — slot ecx = item edx, count r8d (0 count: empty), durability r9d
;   clobbers: rax, rcx
set_slot:
    SLOT_PTR rax, rcx
    test r8d, r8d
    jz .empty
    test edx, edx
    jz .empty
    mov [rax + SLOT_ITEM], dx
    mov [rax + SLOT_COUNT], r8w
    mov [rax + SLOT_DUR], r9w
    jmp mark
.empty:
    mov qword [rax], 0
    jmp mark

; -----------------------------------------------------------------------------
; inv_init — see the header.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC inv_init, 0, rbx, rsi, rdi
    lea rcx, [rel g_inv]
    xor eax, eax
    mov edx, ALL_SLOTS
.clear:
    mov qword [rcx], 0
    add rcx, SLOT_SIZE
    dec edx
    jnz .clear
    mov dword [rel g_inv_sel], 0
    cmp dword [rel g_save_inv_loaded], 0
    je .held
    ; the saved inventory
    lea rsi, [rel g_save_inv]
    lea rdi, [rel g_inv]
    mov ecx, INV_SLOTS * SLOT_SIZE
    rep movsb
    mov eax, [rel g_save_inv_sel]
    cmp eax, INV_HOTBAR
    jb .sel
    xor eax, eax
.sel:
    mov [rel g_inv_sel], eax
    ; a carried stack or a crafting grid saved full: back into the slots
    mov ebx, INV_SLOTS
.back:
    cmp ebx, INV_SAVED
    jae .done
    lea rax, [rel g_save_inv]
    movzx ecx, word [rax + rbx * 8]
    movzx edx, word [rax + rbx * 8 + 2]
    test ecx, ecx
    jz .back_next
    call inv_add
.back_next:
    inc ebx
    jmp .back
.held:
    ; an older save or a new Creative world: the held block in slot 0
    ; (Survival starts empty-handed)
    cmp dword [rel g_world_mode], MODE_CREATIVE
    jne .done
    mov eax, [rel g_held_block]
    test eax, eax
    jz .done
    lea rcx, [rel g_block_item]
    movzx ebx, word [rcx + rax * 2]
    test ebx, ebx
    jz .done
    mov ecx, ebx
    call stack_of
    lea rcx, [rel g_inv]
    mov [rcx + SLOT_ITEM], bx
    mov [rcx + SLOT_COUNT], ax
.done:
    mov qword [rel g_dirty], -1         ; the client gets everything
    mov rax, (1 << (ALL_SLOTS - 64)) - 1
    mov [rel g_dirty + 8], rax
    mov dword [rel g_sel_dirty], 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; inv_add — put items in: onto stacks of the same item first, then into
; empty slots (hotbar first).
;   in:  ecx = item, edx = count
;   out: eax = how many did not fit
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC inv_add, 0, rbx, rsi, rdi, r12
    mov ebx, ecx
    mov esi, edx
    call stack_of
    mov r12d, eax                       ; stack size
    ; onto stacks
    xor edi, edi
.merge:
    test esi, esi
    jz .done
    cmp edi, INV_SLOTS
    jae .empties
    SLOT_PTR rax, rdi
    cmp [rax + SLOT_ITEM], bx
    jne .merge_next
    movzx ecx, word [rax + SLOT_COUNT]
    mov edx, r12d
    sub edx, ecx                        ; room
    jle .merge_next
    cmp edx, esi
    cmova edx, esi
    add [rax + SLOT_COUNT], dx
    sub esi, edx
    mov ecx, edi
    call mark
.merge_next:
    inc edi
    jmp .merge
.empties:
    xor edi, edi
.empty:
    test esi, esi
    jz .done
    cmp edi, INV_SLOTS
    jae .done
    SLOT_PTR rax, rdi
    cmp word [rax + SLOT_ITEM], 0
    jne .empty_next
    mov edx, r12d
    cmp edx, esi
    cmova edx, esi
    mov [rax + SLOT_ITEM], bx
    mov [rax + SLOT_COUNT], dx
    mov word [rax + SLOT_DUR], 0
    sub esi, edx
    mov ecx, edi
    call mark
.empty_next:
    inc edi
    jmp .empty
.done:
    mov eax, esi
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; inv_selected_block — the block placed by the item in hand.
;   out: eax = block id (0 = nothing to place)
;   clobbers: rax, rcx
; -----------------------------------------------------------------------------
inv_selected_block:
    mov ecx, [rel g_inv_sel]
    SLOT_PTR rax, rcx
    movzx ecx, word [rax + SLOT_ITEM]
    xor eax, eax
    test ecx, ecx
    jz .done
    lea rax, [rel g_item_block]
    movzx eax, word [rax + rcx * 2]
.done:
    ret

; inv_wear_selected — see the header   clobbers: rax, rcx, rdx, r8, r9
PROC inv_wear_selected, 0
    cmp dword [rel g_world_mode], MODE_CREATIVE
    je .done
    mov ecx, [rel g_inv_sel]
    SLOT_PTR rax, rcx
    movzx edx, word [rax + SLOT_ITEM]
    test edx, edx
    jz .done
    lea r9, [rel g_item_dur]
    movzx edx, word [r9 + rdx * 2]
    test edx, edx
    jz .done                            ; does not wear
    inc word [rax + SLOT_DUR]
    movzx r8d, word [rax + SLOT_DUR]
    cmp r8d, edx
    jb .marked
    mov qword [rax], 0                  ; worn out: it breaks
.marked:
    call mark
.done:
    RETURN
ENDPROC

; inv_used_selected — one block was placed: Survival uses one up
PROC inv_used_selected, 0
    cmp dword [rel g_world_mode], MODE_CREATIVE
    je .done
    mov ecx, [rel g_inv_sel]
    SLOT_PTR rax, rcx
    cmp word [rax + SLOT_COUNT], 0
    je .done
    dec word [rax + SLOT_COUNT]
    jnz .marked
    mov qword [rax], 0
.marked:
    call mark
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; inv_room — how many of item ecx still fit in slots 0-35.
;   out: eax
;   clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
inv_room:
    mov r8d, ecx
    call stack_of
    mov r9d, eax
    xor eax, eax
    xor ecx, ecx
.slot:
    lea rdx, [rel g_inv]
    lea rdx, [rdx + rcx * SLOT_SIZE]
    cmp word [rdx + SLOT_ITEM], 0
    je .empty
    cmp [rdx + SLOT_ITEM], r8w
    jne .next
    add eax, r9d
    movzx edx, word [rdx + SLOT_COUNT]
    sub eax, edx
    jmp .next
.empty:
    add eax, r9d
.next:
    inc ecx
    cmp ecx, INV_SLOTS
    jb .slot
    ret

; inv_cursor_back — the carried stack back into the slots (what does not fit
; stays carried)   clobbers: volatile registers
PROC inv_cursor_back, 0
    mov ecx, INV_CURSOR
    xor edx, edx
    call click
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; pick — bring a block's item to hand (middle click). In the hotbar: select
; it. In the inventory: swap it into the selected slot. Creative: otherwise
; a full stack into an empty hotbar slot (or the selected one).
;   in:  ecx = block id
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC pick, 0, rbx, rsi, rdi
    cmp ecx, 0
    jle .done
    cmp ecx, 0xFFFF
    ja .done
    lea rax, [rel g_block_item]
    movzx ebx, word [rax + rcx * 2]
    test ebx, ebx
    jz .done
    xor esi, esi
.find:
    cmp esi, INV_SLOTS
    jae .not_held
    SLOT_PTR rax, rsi
    cmp [rax + SLOT_ITEM], bx
    je .found
    inc esi
    jmp .find
.found:
    cmp esi, INV_HOTBAR
    jae .swap
    mov [rel g_inv_sel], esi
    mov dword [rel g_sel_dirty], 1
    RETURN
.swap:
    mov ecx, [rel g_inv_sel]
    SLOT_PTR rax, rcx
    SLOT_PTR rdx, rsi
    mov r8, [rax]
    mov r9, [rdx]
    mov [rax], r9
    mov [rdx], r8
    call mark
    mov ecx, esi
    call mark
    RETURN
.not_held:
    cmp dword [rel g_world_mode], MODE_CREATIVE
    jne .done
    ; the selected slot if empty, else the first empty hotbar slot, else
    ; the selected one is replaced
    mov edi, [rel g_inv_sel]
    SLOT_PTR rax, rdi
    cmp word [rax + SLOT_ITEM], 0
    je .put
    xor edi, edi
.empty:
    cmp edi, INV_HOTBAR
    jae .replace
    SLOT_PTR rax, rdi
    cmp word [rax + SLOT_ITEM], 0
    je .put
    inc edi
    jmp .empty
.replace:
    mov edi, [rel g_inv_sel]
.put:
    mov ecx, ebx
    call stack_of
    mov r8d, eax
    mov ecx, edi
    mov edx, ebx
    xor r9d, r9d
    call set_slot
    mov [rel g_inv_sel], edi
    mov dword [rel g_sel_dirty], 1
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; click — a click on a slot of the inventory screen (left: take / put /
; merge / swap the whole stack; right: take half / put one; shift: move the
; stack between the hotbar and the inventory). A click with slot
; INV_CURSOR puts the carried stack back (the screen closed).
;   in:  ecx = slot, edx = INVB_*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC click, 0, rbx, rsi, rdi, r12, r13
    mov ebx, ecx
    mov r12d, edx
    cmp ebx, INV_CURSOR
    je .put_back
    cmp ebx, INV_SLOTS
    jb .valid
    ; the open window's slots
    cmp ebx, INV_RESULT
    je .result
    cmp ebx, INV_CONTAINER
    jae .container
    cmp ebx, INV_GRID
    jb .done
    lea eax, [ebx - INV_GRID]           ; a grid cell: inside the grid?
    xor edx, edx
    mov ecx, 3
    div ecx                             ; eax = row, edx = column
    cmp eax, [rel g_win_grid]
    jae .done
    cmp edx, [rel g_win_grid]
    jae .done
    jmp .valid
.container:
    lea eax, [ebx - INV_CONTAINER]
    cmp eax, [rel g_win_slots]
    jae .done
    ; a furnace's output: only taken from
    cmp dword [rel g_win_kind], WIN_FURNACE
    jne .valid
    cmp eax, 2
    jne .valid
    test r12d, INVB_SHIFT
    jnz .valid                          ; (shift: into the slots)
    SLOT_PTR rsi, rbx
    lea rdi, [rel g_inv + INV_CURSOR * SLOT_SIZE]
    movzx ecx, word [rsi + SLOT_ITEM]
    test ecx, ecx
    jz .done
    movzx edx, word [rdi + SLOT_ITEM]
    test edx, edx
    jz .swap                            ; empty hand: take it all
    cmp edx, ecx
    jne .done
    call stack_of                       ; (ecx = the item)
    movzx ecx, word [rdi + SLOT_COUNT]
    sub eax, ecx                        ; room in the hand
    jle .done
    movzx ecx, word [rsi + SLOT_COUNT]
    cmp eax, ecx
    cmova eax, ecx
    add [rdi + SLOT_COUNT], ax
    sub [rsi + SLOT_COUNT], ax
    jnz .marks
    mov qword [rsi], 0
    jmp .marks
.valid:
    SLOT_PTR rsi, rbx                   ; the slot
    lea rdi, [rel g_inv + INV_CURSOR * SLOT_SIZE]   ; the cursor
    test r12d, INVB_SHIFT
    jnz .shift
    movzx ecx, word [rsi + SLOT_ITEM]
    movzx edx, word [rdi + SLOT_ITEM]
    test r12d, INVB_RIGHT
    jnz .right
    ; ---- left ----
    test edx, edx
    jz .swap                            ; nothing carried: take it all
    test ecx, ecx
    jz .swap                            ; empty slot: put it all
    cmp ecx, edx
    jne .swap
    ; same item: fill the slot
    mov ecx, edx
    call stack_of
    movzx ecx, word [rsi + SLOT_COUNT]
    sub eax, ecx                        ; room
    jle .marks
    movzx ecx, word [rdi + SLOT_COUNT]
    cmp eax, ecx
    cmova eax, ecx
    add [rsi + SLOT_COUNT], ax
    sub [rdi + SLOT_COUNT], ax
    jnz .marks
    mov qword [rdi], 0
    jmp .marks
.swap:
    mov rax, [rsi]
    mov rcx, [rdi]
    mov [rsi], rcx
    mov [rdi], rax
    jmp .marks
    ; ---- right ----
.right:
    test edx, edx
    jnz .right_put
    ; take half (rounded up)
    test ecx, ecx
    jz .done
    movzx eax, word [rsi + SLOT_COUNT]
    mov r8d, eax
    shr r8d, 1                          ; stays
    sub eax, r8d                        ; taken
    mov [rdi + SLOT_ITEM], cx
    mov [rdi + SLOT_COUNT], ax
    mov ax, [rsi + SLOT_DUR]
    mov [rdi + SLOT_DUR], ax
    mov [rsi + SLOT_COUNT], r8w
    test r8d, r8d
    jnz .marks
    mov qword [rsi], 0
    jmp .marks
.right_put:
    test ecx, ecx
    jz .one
    cmp ecx, edx
    jne .swap
    mov r13d, ecx
    mov ecx, edx
    call stack_of
    cmp [rsi + SLOT_COUNT], ax
    jae .done                           ; full
    inc word [rsi + SLOT_COUNT]
    jmp .one_taken
.one:
    mov [rsi + SLOT_ITEM], dx
    mov word [rsi + SLOT_COUNT], 1
    mov ax, [rdi + SLOT_DUR]
    mov [rsi + SLOT_DUR], ax
.one_taken:
    dec word [rdi + SLOT_COUNT]
    jnz .marks
    mov qword [rdi], 0
    jmp .marks
    ; ---- shift: to the other part ----
.shift:
    movzx ecx, word [rsi + SLOT_ITEM]
    test ecx, ecx
    jz .done
    mov r13, [rsi]                      ; the stack
    mov qword [rsi], 0
    mov ecx, ebx
    call mark
    ; target range: hotbar -> 9..35, inventory -> 0..8; a window's slot ->
    ; the player's slots; with a container open: the player's slots -> it
    xor r8d, r8d
    mov r9d, INV_SLOTS
    cmp ebx, INV_SLOTS
    jae .range
    cmp dword [rel g_win_slots], 0
    je .halves
    cmp dword [rel g_win_kind], WIN_FURNACE
    je .to_furnace
    mov r8d, INV_CONTAINER
    mov r9d, [rel g_win_slots]
    add r9d, INV_CONTAINER
    jmp .range
.to_furnace:
    ; something it smelts: the input; a fuel: the fuel slot; else as usual
    movzx ecx, r13w
    mov eax, [rel g_win_station]
    lea rdx, [rel g_station_blast]
    movzx edx, byte [rdx + rax - 1]
    call smelt_find
    mov r8d, INV_CONTAINER + 0
    mov r9d, INV_CONTAINER + 1
    cmp eax, -1
    jne .range
    movzx ecx, r13w
    call fuel_ticks
    mov r8d, INV_CONTAINER + 1
    mov r9d, INV_CONTAINER + 2
    test eax, eax
    jnz .range
.halves:
    xor r8d, r8d
    mov r9d, INV_HOTBAR
    cmp ebx, INV_HOTBAR
    jae .range
    mov r8d, INV_HOTBAR
    mov r9d, INV_SLOTS
.range:
    mov ecx, r8d
    mov edx, r9d
    call move_into                      ; r13 = stack in, leftover out
    test r13w, r13w
    jz .done
    mov [rsi], r13                      ; what did not fit stays
    jmp .done
.result:
    mov ecx, r12d
    call craft_take
    jmp .done
.put_back:
    lea rdi, [rel g_inv + INV_CURSOR * SLOT_SIZE]
    movzx ecx, word [rdi + SLOT_ITEM]
    test ecx, ecx
    jz .done
    movzx edx, word [rdi + SLOT_COUNT]
    call inv_add
    lea rdi, [rel g_inv + INV_CURSOR * SLOT_SIZE]
    mov [rdi + SLOT_COUNT], ax
    test eax, eax
    jnz .cursor_mark
    mov qword [rdi], 0
.cursor_mark:
    mov ecx, INV_CURSOR
    call mark
    jmp .done
.marks:
    mov ecx, ebx
    call mark
    mov ecx, INV_CURSOR
    call mark
.done:
    RETURN
ENDPROC

; move_into — merge the stack in r13 into slots [ecx, edx): same items
; first, then empty slots; r13's count is what is left.
;   clobbers: rax, rcx, rdx, r8-r11 (keeps rbx, rsi, rdi)
PROC move_into, 0, rbx, rsi, rdi, r12
    mov esi, ecx
    mov edi, edx
    movzx ecx, r13w                     ; item
    call stack_of
    mov r12d, eax
    mov ebx, esi
.merge:
    cmp ebx, edi
    jae .empties
    mov rax, r13
    shr rax, 16
    test ax, ax
    jz .done
    SLOT_PTR rax, rbx
    cmp [rax + SLOT_ITEM], r13w
    jne .merge_next
    movzx ecx, word [rax + SLOT_COUNT]
    mov edx, r12d
    sub edx, ecx
    jle .merge_next
    mov rcx, r13
    shr rcx, 16
    movzx ecx, cx
    cmp edx, ecx
    cmova edx, ecx
    add [rax + SLOT_COUNT], dx
    shl rdx, 16
    sub r13, rdx
    mov ecx, ebx
    call mark
.merge_next:
    inc ebx
    jmp .merge
.empties:
    mov ebx, esi
.empty:
    cmp ebx, edi
    jae .done
    mov rax, r13
    shr rax, 16
    test ax, ax
    jz .done
    SLOT_PTR rax, rbx
    cmp word [rax + SLOT_ITEM], 0
    jne .empty_next
    mov [rax], r13
    mov r13, 0
    mov ecx, ebx
    call mark
    jmp .done
.empty_next:
    inc ebx
    jmp .empty
.done:
    ; nothing left: an empty stack
    mov rax, r13
    shr rax, 16
    test ax, ax
    jnz .left
    xor r13d, r13d
.left:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; inv_packet — see the header.
;   in:  ecx = packet type, rdx = INV_PKT*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC inv_packet, 0, rbx
    mov rbx, rdx
    cmp ecx, PKT_C_SELECT
    jne .not_select
    mov eax, [rbx + INV_PKT.slot]
    cmp eax, INV_HOTBAR
    jae .done
    mov [rel g_inv_sel], eax
    mov dword [rel g_sel_dirty], 1
    RETURN
.not_select:
    cmp ecx, PKT_C_PICK
    jne .not_pick
    mov ecx, [rbx + INV_PKT.item]
    call pick
    RETURN
.not_pick:
    cmp ecx, PKT_C_INV_CLICK
    jne .not_click
    mov ecx, [rbx + INV_PKT.slot]
    mov edx, [rbx + INV_PKT.arg]
    call click
    call craft_update                   ; (the grid may have changed)
    RETURN
.not_click:
    cmp ecx, PKT_C_CREATIVE_SET
    jne .done
    cmp dword [rel g_world_mode], MODE_CREATIVE
    jne .done                           ; (Survival: no free items)
    mov ecx, [rbx + INV_PKT.slot]
    cmp ecx, INV_CURSOR
    ja .done
    mov edx, [rbx + INV_PKT.item]
    cmp edx, [rel g_item_count]
    jae .done
    mov r10d, ecx
    mov ecx, edx
    call stack_of                       ; (clobbers rax only)
    mov ecx, r10d
    mov r8d, [rbx + INV_PKT.count]
    cmp r8d, eax
    cmova r8d, eax
    xor r9d, r9d
    call set_slot
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; inv_flush — send the slots that changed this tick, and the selection.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC inv_flush, 0, rbx, rsi
    mov rax, [rel g_dirty]
    or rax, [rel g_dirty + 8]
    jz .sel
    xor ebx, ebx
.slot:
    cmp ebx, ALL_SLOTS
    jae .sel
    btr [rel g_dirty], rbx
    jnc .next
    SLOT_PTR rax, rbx
    mov [rel g_out + INV_PKT.slot], ebx
    movzx ecx, word [rax + SLOT_ITEM]
    mov [rel g_out + INV_PKT.item], ecx
    movzx ecx, word [rax + SLOT_COUNT]
    mov [rel g_out + INV_PKT.count], ecx
    movzx ecx, word [rax + SLOT_DUR]
    mov [rel g_out + INV_PKT.arg], ecx
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_SLOT, r8, INV_PKT_size
.next:
    inc ebx
    jmp .slot
.sel:
    cmp dword [rel g_sel_dirty], 0
    je .done
    mov dword [rel g_sel_dirty], 0
    mov eax, [rel g_inv_sel]
    mov [rel g_out + INV_PKT.slot], eax
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_SELECT, r8, INV_PKT_size
.done:
    RETURN
ENDPROC

extern g_to_client
