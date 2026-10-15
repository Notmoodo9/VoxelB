; =============================================================================
; crafting.asm — windows and crafting in the simulation (milestone 18 part 3,
; design/items/items_inventory.md).
;
; A window is what the inventory screen shows besides the player's slots:
; the 2 x 2 crafting grid by hand (E), a crafting station's grid (a block
; with a [station] in data/recipes: right click), later a chest. Its slots
; are part of the inventory (packet.inc: INV_GRID, INV_RESULT,
; INV_CONTAINER), so clicks work as on any slot (inventory.asm). The result
; slot shows what the grid makes (recipes.asm); taking it uses up one of
; each grid item; shift takes as many as fit. Closing the window puts the
; grid and the carried stack back into the slots (what does not fit is
; dropped at the player's feet). A station window closes by itself when
; the player walks away or the block is gone.
; A container block ([container] in data/recipes, a chest) opens its slots
; (containers.asm) as the window's container slots; two that join (side by
; side, the same facing) open as one of twice the size. Breaking a
; container drops what is in it.
;
; Public API:
;   craft_reset()
;   craft_window(rcx = WIN_PKT*)         PKT_C_WINDOW
;   craft_recipe(rcx = INV_PKT*)         PKT_C_RECIPE (the recipe book)
;   craft_update()                       the grid may have changed
;   craft_take(ecx = INVB_*)             a click on the result
;   craft_tick()                         once per tick
;   craft_block_broken(ecx = x, edx = y, r8d = z)   a block was broken
;   craft_sync()                         the open container's slots back into
;                                        its store (before a save)
;   g_win_kind (WIN_*), g_win_grid (0 / 2 / 3), g_win_slots (container),
;   g_win_station (0 by hand)
; =============================================================================
%include "macros.inc"
%include "packet.inc"
%include "items.inc"
%include "containers.inc"
%include "world.inc"

global craft_reset, craft_window, craft_recipe, craft_update, craft_take
global craft_close
global craft_tick, g_win_kind, g_win_grid, g_win_slots, g_win_station
global craft_block_broken, craft_sync, g_win_cont

extern racks_use, graves_use
extern g_inv, inv_mark, inv_stack_of, inv_room, inv_add, inv_add_dur, inv_cursor_back
extern recipe_match, recipe_cell_ok, g_recipe_count, g_rec_result
extern g_rec_amount, g_rec_station, g_rec_w, g_rec_h, g_rec_n, g_rec_ok
extern g_rec_cells, g_block_station, g_station_grid
extern phys_block, drops_spawn, drops_spawn_dur, pkt_send, g_to_client
extern g_pl_pos, g_pl_eye, g_station_slots, g_station_joins
extern g_block_state, g_block_flags, g_station_kind, g_station_repair
extern items_match_list

%define SLOT_SIZE       8
%define MAX_REACH_SQ    64.0            ; a station's window closes beyond 8 blocks
%define MAX_REPEAT      64              ; shift: crafts at most this many at once

section .rdata
align 8
c_half:         dq 0.5
c_reach_sq:     dq MAX_REACH_SQ

section .bss
alignb 8
g_win_kind:     resd 1
g_win_grid:     resd 1
g_win_slots:    resd 1
g_win_station:  resd 1
g_win_pos:      resd 3
g_recipe:       resd 1                  ; what the grid makes, -1 nothing
g_win_pos2:     resd 3                  ; a double container's other block
g_win_cont:     resd 2                  ; its container entries (second -1)
g_win_half:     resd 1                  ; slots per block
alignb 8
g_repaired:     resq 1                  ; try_repair: the tool as it comes out
g_items:        resw 9                  ; recipe_match's grid
alignb 8
g_at:           resq 3
g_out:          resb WIN_PKT_size
alignb 4
g_take:         resd 9                  ; craft_recipe: the slot each cell takes from
g_left:         resw INV_SLOTS          ; craft_recipe: counts while planning

section .text

; slot_ptr — %1 = &g_inv[%2]
%macro SLOT_PTR 2
    lea %1, [rel g_inv]
    lea %1, [%1 + %2 * SLOT_SIZE]
%endmacro

; craft_reset — no window
craft_reset:
    xor eax, eax
    mov [rel g_win_kind], eax
    mov [rel g_win_grid], eax
    mov [rel g_win_slots], eax
    mov [rel g_win_station], eax
    mov [rel g_win_half], eax
    mov dword [rel g_recipe], -1
    mov dword [rel g_win_cont], -1
    mov dword [rel g_win_cont + 4], -1
    ret

; cell_slot — eax = the inventory slot of grid cell ecx (0..8), or -1 if the
; open grid has no such cell
cell_slot:
    mov eax, ecx
    push rdx                            ; (not a PROC: no locals here)
    xor edx, edx
    push rcx
    mov ecx, 3
    div ecx
    pop rcx
    cmp eax, [rel g_win_grid]
    jae .none
    cmp edx, [rel g_win_grid]
    jae .none
    lea eax, [ecx + INV_GRID]
    pop rdx
    ret
.none:
    mov eax, -1
    pop rdx
    ret

; feet — g_at = the player's eyes   clobbers: xmm0
feet:
    movsd xmm0, [rel g_pl_pos]
    movsd [rel g_at], xmm0
    cvtss2sd xmm0, [rel g_pl_eye]
    addsd xmm0, [rel g_pl_pos + 8]
    movsd [rel g_at + 8], xmm0
    movsd xmm0, [rel g_pl_pos + 16]
    movsd [rel g_at + 16], xmm0
    ret

; -----------------------------------------------------------------------------
; give — item ecx x edx (wear r8d) into the player's slots; what does not
; fit is dropped at the player.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC give, 0, rbx, rsi
    mov ebx, ecx
    mov esi, r8d
    call inv_add_dur
    test eax, eax
    jz .done
    mov edx, eax
    mov ecx, ebx
    call feet
    lea r8, [rel g_at]
    mov r9d, esi
    call drops_spawn_dur
.done:
    RETURN
ENDPROC

; send_window — tell the client which window is open   clobbers: volatile
PROC send_window, 0
    mov eax, [rel g_win_kind]
    mov [rel g_out + WIN_PKT.kind], eax
    mov eax, [rel g_win_pos]
    mov [rel g_out + WIN_PKT.pos], eax
    mov eax, [rel g_win_pos + 4]
    mov [rel g_out + WIN_PKT.pos + 4], eax
    mov eax, [rel g_win_pos + 8]
    mov [rel g_out + WIN_PKT.pos + 8], eax
    mov eax, [rel g_win_grid]
    mov [rel g_out + WIN_PKT.grid], eax
    mov eax, [rel g_win_slots]
    mov [rel g_out + WIN_PKT.slots], eax
    mov eax, [rel g_win_station]
    mov [rel g_out + WIN_PKT.station], eax
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_WINDOW, r8, WIN_PKT_size
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; close_window — the carried stack and the grid back to the player.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
; craft_close — close the window and tell the client (survival.asm: the
; player died; the grid and a chest's slots go back first)
;   clobbers: volatile registers
PROC craft_close, 0
    call close_window
    call send_window
    RETURN
ENDPROC

PROC close_window, 0, rbx, rsi
    ; a container: its slots go back into its store and leave the window
    cmp dword [rel g_win_kind], WIN_CHEST
    jb .not_chest                       ; (a chest or a furnace)
    call craft_sync
    mov ebx, INV_CONTAINER
.clear:
    cmp ebx, INV_ALL
    jae .not_chest
    SLOT_PTR rsi, rbx
    cmp qword [rsi], 0
    je .clear_next
    mov qword [rsi], 0
    mov ecx, ebx
    call inv_mark
.clear_next:
    inc ebx
    jmp .clear
.not_chest:
    call inv_cursor_back
    ; (a full inventory: the carried stack is dropped)
    lea rsi, [rel g_inv + INV_CURSOR * SLOT_SIZE]
    movzx ecx, word [rsi]
    test ecx, ecx
    jz .grid
    movzx edx, word [rsi + 2]
    movzx r8d, word [rsi + 4]
    mov qword [rsi], 0
    call give
    mov ecx, INV_CURSOR
    call inv_mark
.grid:
    mov ebx, INV_GRID
.cell:
    cmp ebx, INV_RESULT
    ja .closed
    SLOT_PTR rsi, rbx
    movzx ecx, word [rsi]
    test ecx, ecx
    jz .next
    movzx edx, word [rsi + 2]
    movzx r8d, word [rsi + 4]
    mov qword [rsi], 0
    cmp ebx, INV_RESULT
    je .marked                          ; (the result is only a preview)
    call give
.marked:
    mov ecx, ebx
    call inv_mark
.next:
    inc ebx
    jmp .cell
.closed:
    call craft_reset
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; craft_window — open or close a window (PKT_C_WINDOW).
;   in:  rcx = WIN_PKT*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC craft_window, 16, rbx, rsi, rdi
    mov rbx, rcx
    mov eax, [rbx + WIN_PKT.kind]
    cmp eax, WIN_INVENTORY
    je .inventory
    cmp eax, WIN_USE
    je .use
    ; WIN_NONE (and anything else): close
    call close_window
    RETURN
.inventory:
    call close_window
    mov dword [rel g_win_kind], WIN_INVENTORY
    mov dword [rel g_win_grid], 2
    RETURN
.use:
    ; a station block, within reach
    mov esi, [rbx + WIN_PKT.pos]
    mov edi, [rbx + WIN_PKT.pos + 4]
    mov eax, [rbx + WIN_PKT.pos + 8]
    mov [LOCAL(0)], eax
    mov ecx, esi
    mov edx, edi
    mov r8d, eax
    call station_at
    test eax, eax
    jz .done
    mov [LOCAL(4)], eax
    ; a drying rack: right click hangs or takes a hide (racks.asm)
    lea rcx, [rel g_station_kind]
    cmp byte [rcx + rax - 1], STATION_RACK
    jne .not_rack
    mov ecx, esi
    mov edx, edi
    mov r8d, [LOCAL(0)]
    mov r9d, eax
    call racks_use
    RETURN
.not_rack:
    ; a gravestone: right click gives the items back (graves.asm)
    lea rcx, [rel g_station_kind]
    cmp byte [rcx + rax - 1], STATION_GRAVE
    jne .not_grave
    mov ecx, esi
    mov edx, edi
    mov r8d, [LOCAL(0)]
    call graves_use
    RETURN
.not_grave:
    lea rcx, [rel g_station_slots]
    cmp byte [rcx + rax - 1], 0
    je .station
    ; a container
    mov edx, eax
    mov ecx, [LOCAL(0)]
    mov [rel g_win_pos], esi
    mov [rel g_win_pos + 4], edi
    mov [rel g_win_pos + 8], ecx
    mov ecx, edx
    call open_container
    RETURN
.station:
    call close_window
    mov [rel g_win_pos], esi
    mov [rel g_win_pos + 4], edi
    mov eax, [LOCAL(0)]
    mov [rel g_win_pos + 8], eax
    call near_enough
    test eax, eax
    jz .done
    mov eax, [LOCAL(4)]
    mov [rel g_win_station], eax
    lea rcx, [rel g_station_grid]
    movzx ecx, byte [rcx + rax - 1]
    mov [rel g_win_grid], ecx
    mov dword [rel g_win_kind], WIN_CRAFTING
    call send_window
.done:
    RETURN
ENDPROC

; station_at — eax = the station of the block at ecx, edx, r8d (0 none)
;   clobbers: volatile registers
PROC station_at, 0
    call phys_block
    cmp eax, 0
    jle .none
    cmp eax, 0xFFFF
    ja .none
    lea rcx, [rel g_block_station]
    movzx eax, byte [rcx + rax]
    RETURN
.none:
    xor eax, eax
    RETURN
ENDPROC

; near_enough — eax = 1 if the player's eyes are near g_win_pos
;   clobbers: rax, rcx, xmm0-xmm2
near_enough:
    call feet
    xorpd xmm2, xmm2
    xor ecx, ecx
.axis:
    lea rax, [rel g_win_pos]
    cvtsi2sd xmm0, dword [rax + rcx * 4]
    addsd xmm0, [rel c_half]
    lea rax, [rel g_at]
    subsd xmm0, [rax + rcx * 8]
    mulsd xmm0, xmm0
    addsd xmm2, xmm0
    inc ecx
    cmp ecx, 3
    jb .axis
    xor eax, eax
    comisd xmm2, [rel c_reach_sq]
    setbe al
    ret

; -----------------------------------------------------------------------------
; craft_tick — a station's window closes when the player walks away or the
; block is gone.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC craft_tick, 0
    cmp dword [rel g_win_kind], WIN_CHEST
    jae .check
    cmp dword [rel g_win_kind], WIN_CRAFTING
    jne .done
.check:
    call near_enough
    test eax, eax
    jz .close
    mov ecx, [rel g_win_pos]
    mov edx, [rel g_win_pos + 4]
    mov r8d, [rel g_win_pos + 8]
    call station_at
    cmp eax, [rel g_win_station]
    jne .close
    cmp dword [rel g_win_cont + 4], -1
    je .done
    ; a double container: its other half too
    mov ecx, [rel g_win_pos2]
    mov edx, [rel g_win_pos2 + 4]
    mov r8d, [rel g_win_pos2 + 8]
    call station_at
    cmp eax, [rel g_win_station]
    je .done
.close:
    call close_window
    call send_window                    ; (WIN_NONE: the screen closes)
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; open_container — open the container block at g_win_pos (station ecx),
; joined with a neighbour when its [container] joins.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define O_ST    0
%define O_ID    4
PROC open_container, 16, rbx, rsi, rdi, r12
    mov [LOCAL(O_ST)], ecx
    ; (the old window closes first; g_win_pos is kept)
    mov ebx, [rel g_win_pos]
    mov esi, [rel g_win_pos + 4]
    mov edi, [rel g_win_pos + 8]
    call close_window
    mov [rel g_win_pos], ebx
    mov [rel g_win_pos + 4], esi
    mov [rel g_win_pos + 8], edi
    call near_enough
    test eax, eax
    jz .done
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    call phys_block
    mov [LOCAL(O_ID)], eax
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    call cont_get
    cmp eax, -1
    je .done
    mov [rel g_win_cont], eax
    mov dword [rel g_win_cont + 4], -1
    imul eax, eax, CONT_size
    lea rcx, [rel g_conts]
    mov edx, [LOCAL(O_ST)]
    mov [rcx + rax + CONT.station], dl  ; (the furnace tick needs it)
    mov eax, [LOCAL(O_ST)]
    lea rcx, [rel g_station_slots]
    movzx ecx, byte [rcx + rax - 1]
    mov [rel g_win_half], ecx
    mov [rel g_win_slots], ecx
    lea rcx, [rel g_station_joins]
    cmp byte [rcx + rax - 1], 0
    je .opened
    ; a neighbour of the same block and facing, beside it (a facing block:
    ; along the front's side; otherwise any of the four)
    xor r12d, r12d                      ; 0 -x, 1 +x, 2 -z, 3 +z
.side:
    cmp r12d, 4
    jae .opened
    mov eax, [LOCAL(O_ID)]
    lea rcx, [rel g_block_flags]
    test byte [rcx + rax], BLOCKF_FACING
    jz .any_side
    lea rcx, [rel g_block_state]
    movzx ecx, byte [rcx + rax]
    and ecx, 1                          ; front along z (0) or x (1)
    mov edx, r12d
    shr edx, 1                          ; this side along x (0) or z (1)
    cmp ecx, edx
    jne .next_side                      ; (in front or behind)
.any_side:
    mov ecx, ebx
    mov r8d, edi
    mov eax, r12d
    and eax, 1
    lea eax, [eax * 2 - 1]              ; -1 / +1
    cmp r12d, 2
    jae .z
    add ecx, eax
    jmp .look
.z:
    add r8d, eax
.look:
    mov [rel g_win_pos2], ecx
    mov [rel g_win_pos2 + 4], esi
    mov [rel g_win_pos2 + 8], r8d
    mov edx, esi
    call phys_block
    cmp eax, [LOCAL(O_ID)]
    je .join
.next_side:
    inc r12d
    jmp .side
.join:
    mov ecx, [rel g_win_pos2]
    mov edx, [rel g_win_pos2 + 4]
    mov r8d, [rel g_win_pos2 + 8]
    call cont_get
    cmp eax, -1
    je .opened
    ; the half with the lower x / z first, whichever was clicked
    mov ecx, [rel g_win_cont]
    test r12d, 1
    jnz .order
    xchg eax, ecx                       ; (the other one is lower)
.order:
    mov [rel g_win_cont], ecx
    mov [rel g_win_cont + 4], eax
    mov eax, [rel g_win_half]
    add eax, eax
    mov [rel g_win_slots], eax
.opened:
    ; the slots into the window
    xor r12d, r12d                      ; half
.half:
    cmp r12d, 2
    jae .shown
    lea rax, [rel g_win_cont]
    mov ecx, [rax + r12 * 4]
    cmp ecx, -1
    je .shown
    call cont_slots
    mov rsi, rax
    xor ebx, ebx
.slot:
    cmp ebx, [rel g_win_half]
    jae .half_next
    mov rax, [rsi + rbx * 8]
    mov edx, [rel g_win_half]
    imul edx, r12d
    lea ecx, [edx + ebx + INV_CONTAINER]
    SLOT_PTR rdx, rcx
    mov [rdx], rax
    call inv_mark
    inc ebx
    jmp .slot
.half_next:
    inc r12d
    jmp .half
.shown:
    mov eax, [LOCAL(O_ST)]
    mov [rel g_win_station], eax
    mov dword [rel g_win_kind], WIN_CHEST
    lea rcx, [rel g_station_kind]
    cmp byte [rcx + rax - 1], STATION_FURNACE
    jne .kind
    mov dword [rel g_win_kind], WIN_FURNACE
.kind:
    mov dword [rel g_win_grid], 0
    call send_window
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; craft_sync — the open container's window slots back into its store.
;   clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
PROC craft_sync, 0, rbx, rsi
    cmp dword [rel g_win_kind], WIN_CHEST
    jb .done
    xor esi, esi                        ; half
.half:
    cmp esi, 2
    jae .done
    lea rax, [rel g_win_cont]
    mov ecx, [rax + rsi * 4]
    cmp ecx, -1
    je .done
    call cont_slots
    mov r8, rax
    mov r9d, [rel g_win_half]
    imul r9d, esi
    xor ebx, ebx
.slot:
    cmp ebx, [rel g_win_half]
    jae .next
    lea ecx, [r9d + ebx + INV_CONTAINER]
    SLOT_PTR rdx, rcx
    mov rax, [rdx]
    mov [r8 + rbx * 8], rax
    inc ebx
    jmp .slot
.next:
    inc esi
    jmp .half
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; craft_block_broken — the block at ecx, edx, r8d was broken: a window on
; it closes; a container's items drop where it stood.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC craft_block_broken, 16, rbx, rsi, rdi, r12
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    cmp dword [rel g_win_kind], WIN_CRAFTING
    jb .store                           ; (no window, or the inventory)
    cmp ebx, [rel g_win_pos]
    jne .second
    cmp esi, [rel g_win_pos + 4]
    jne .second
    cmp edi, [rel g_win_pos + 8]
    je .close
.second:
    cmp dword [rel g_win_cont + 4], -1
    je .store
    cmp ebx, [rel g_win_pos2]
    jne .store
    cmp esi, [rel g_win_pos2 + 4]
    jne .store
    cmp edi, [rel g_win_pos2 + 8]
    jne .store
.close:
    call close_window
    call send_window
.store:
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    call cont_find
    cmp eax, -1
    je .done
    mov r12d, eax
    ; drop it all from the block's centre
    cvtsi2sd xmm0, ebx
    addsd xmm0, [rel c_half]
    movsd [rel g_at], xmm0
    cvtsi2sd xmm0, esi
    addsd xmm0, [rel c_half]
    movsd [rel g_at + 8], xmm0
    cvtsi2sd xmm0, edi
    addsd xmm0, [rel c_half]
    movsd [rel g_at + 16], xmm0
    mov ecx, r12d
    call cont_slots
    mov rsi, rax
    xor ebx, ebx
.slot:
    cmp ebx, CONT_SLOTS
    jae .removed
    movzx ecx, word [rsi + rbx * 8]
    test ecx, ecx
    jz .next
    movzx edx, word [rsi + rbx * 8 + 2]
    movzx r9d, word [rsi + rbx * 8 + 4]
    lea r8, [rel g_at]
    call drops_spawn_dur
.next:
    inc ebx
    jmp .slot
.removed:
    mov ecx, r12d
    call cont_remove
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; craft_update — the result slot shows what the grid makes.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC craft_update, 0, rbx
    mov ebx, -1
    cmp dword [rel g_win_grid], 0
    je .show
    ; the grid as recipe_match wants it (cells outside the open grid: empty)
    xor ecx, ecx
.cell:
    call cell_slot
    xor edx, edx
    cmp eax, -1
    je .put
    lea rdx, [rel g_inv]
    movzx edx, word [rdx + rax * SLOT_SIZE]
.put:
    lea rax, [rel g_items]
    mov [rax + rcx * 2], dx
    inc ecx
    cmp ecx, 9
    jb .cell
    lea rcx, [rel g_items]
    mov edx, [rel g_win_station]
    call recipe_match
    mov ebx, eax
    cmp ebx, -1
    jne .show
    ; a repairing station: a worn tool and its material + binding pairs
    mov eax, [rel g_win_station]
    test eax, eax
    jz .show
    lea rcx, [rel g_station_repair]
    cmp byte [rcx + rax - 1], 0
    je .show
    call try_repair
    test eax, eax
    jz .show
    mov dword [rel g_recipe], -2
    lea rcx, [rel g_inv + INV_RESULT * SLOT_SIZE]
    mov rax, [rel g_repaired]
    cmp [rcx], rax
    je .done
    mov [rcx], rax
    mov ecx, INV_RESULT
    call inv_mark
    jmp .done
.show:
    mov [rel g_recipe], ebx
    lea rcx, [rel g_inv + INV_RESULT * SLOT_SIZE]
    xor eax, eax                        ; the new contents
    cmp ebx, -1
    je .compare
    lea rdx, [rel g_rec_result]
    movzx eax, word [rdx + rbx * 2]
    lea rdx, [rel g_rec_amount]
    movzx edx, byte [rdx + rbx]
    shl edx, 16
    or eax, edx
.compare:
    cmp [rcx], rax
    je .done
    mov [rcx], rax
    mov ecx, INV_RESULT
    call inv_mark
.done:
    RETURN
ENDPROC

; use_grid — one of every grid item is used up   clobbers: volatile registers
PROC use_grid, 0, rbx
    xor ebx, ebx
.cell:
    mov ecx, ebx
    call cell_slot
    cmp eax, -1
    je .next
    SLOT_PTR rdx, rax
    cmp word [rdx + 2], 0
    je .next
    dec word [rdx + 2]
    jnz .mark
    mov qword [rdx], 0
.mark:
    mov ecx, eax
    call inv_mark
.next:
    inc ebx
    cmp ebx, 9
    jb .cell
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; craft_take — a click on the result: craft once into the carried stack
; (left or right), or with shift as many times as fit into the slots.
;   in:  ecx = INVB_*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC craft_take, 0, rbx, rsi, rdi, r12
    mov r12d, ecx
    mov ebx, [rel g_recipe]
    cmp ebx, -2
    je .repair
    cmp ebx, -1
    je .done
    lea rax, [rel g_rec_result]
    movzx esi, word [rax + rbx * 2]     ; item
    lea rax, [rel g_rec_amount]
    movzx edi, byte [rax + rbx]         ; amount
    test r12d, INVB_SHIFT
    jnz .shift
    ; into the carried stack
    lea rdx, [rel g_inv + INV_CURSOR * SLOT_SIZE]
    movzx eax, word [rdx]
    test eax, eax
    jz .new
    cmp eax, esi
    jne .done                           ; carrying something else
    mov ecx, esi
    call inv_stack_of
    lea rdx, [rel g_inv + INV_CURSOR * SLOT_SIZE]
    movzx ecx, word [rdx + 2]
    add ecx, edi
    cmp ecx, eax
    ja .done                            ; would not fit
    mov [rdx + 2], cx
    jmp .used
.new:
    mov [rdx], si
    mov [rdx + 2], di
    mov word [rdx + 4], 0
.used:
    mov ecx, INV_CURSOR
    call inv_mark
    call use_grid
    call craft_update
    jmp .done
.shift:
    mov r12d, MAX_REPEAT
.again:
    mov ecx, esi
    call inv_room
    cmp eax, edi
    jb .done
    mov ecx, esi
    mov edx, edi
    call inv_add
    call use_grid
    call craft_update
    cmp [rel g_recipe], ebx
    jne .done                           ; the grid ran out (or makes something else)
    dec r12d
    jnz .again
    jmp .done
.repair:
    ; the repaired tool: into the empty hand, or (shift) an empty slot
    mov rsi, [rel g_repaired]
    test r12d, INVB_SHIFT
    jnz .repair_slot
    lea rdx, [rel g_inv + INV_CURSOR * SLOT_SIZE]
    cmp word [rdx], 0
    jne .done
    mov [rdx], rsi
    mov ecx, INV_CURSOR
    jmp .repaired
.repair_slot:
    xor ecx, ecx
.free:
    cmp ecx, INV_SLOTS
    jae .done
    lea rdx, [rel g_inv]
    cmp word [rdx + rcx * SLOT_SIZE], 0
    je .put
    inc ecx
    jmp .free
.put:
    mov [rdx + rcx * SLOT_SIZE], rsi
.repaired:
    call inv_mark
    call use_grid
    call craft_update
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; try_repair — the grid holds one worn tool and as many pairs (1-3) of its
; repair material and binding (one item per cell): g_repaired = the tool
; with a third of its durability back per pair.
;   out: eax = 1 if so
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define T_TOOL      0                   ; grid slot of the tool, -1
%define T_MATS      4
%define T_BINDS     8
PROC try_repair, 16, rbx, rsi, rdi, r12
    mov dword [LOCAL(T_TOOL)], -1
    mov dword [LOCAL(T_MATS)], 0
    mov dword [LOCAL(T_BINDS)], 0
    ; the tool
    xor ebx, ebx
.find:
    cmp ebx, 9
    jae .found
    mov ecx, ebx
    call cell_slot
    cmp eax, -1
    je .find_next
    lea rdx, [rel g_inv]
    movzx ecx, word [rdx + rax * SLOT_SIZE]
    test ecx, ecx
    jz .find_next
    lea rdx, [rel g_item_repair]
    cmp qword [rdx + rcx * 8], 0
    je .find_next
    cmp dword [LOCAL(T_TOOL)], -1
    jne .no                             ; two tools
    mov [LOCAL(T_TOOL)], eax
.find_next:
    inc ebx
    jmp .find
.found:
    mov eax, [LOCAL(T_TOOL)]
    cmp eax, -1
    je .no
    lea rdx, [rel g_inv]
    lea rsi, [rdx + rax * SLOT_SIZE]    ; the tool's slot
    cmp word [rsi + 4], 0
    je .no                              ; not worn
    movzx edi, word [rsi]               ; the tool
    ; every other item: its material or its binding
    xor ebx, ebx
.cell:
    cmp ebx, 9
    jae .counted
    mov ecx, ebx
    call cell_slot
    cmp eax, -1
    je .cell_next
    cmp eax, [LOCAL(T_TOOL)]
    je .cell_next
    lea rdx, [rel g_inv]
    movzx r12d, word [rdx + rax * SLOT_SIZE]
    test r12d, r12d
    jz .cell_next
    lea rdx, [rel g_item_names]
    mov r12, [rdx + r12 * 8]            ; its name
    lea rdx, [rel g_item_repair]
    mov rcx, [rdx + rdi * 8]
    mov rdx, r12
    call items_match_list
    test eax, eax
    jz .binding
    inc dword [LOCAL(T_MATS)]
    jmp .cell_next
.binding:
    lea rdx, [rel g_item_binding]
    mov rcx, [rdx + rdi * 8]
    test rcx, rcx
    jz .no
    mov rdx, r12
    call items_match_list
    test eax, eax
    jz .no                              ; something else
    inc dword [LOCAL(T_BINDS)]
.cell_next:
    inc ebx
    jmp .cell
.counted:
    mov ecx, [LOCAL(T_MATS)]
    test ecx, ecx
    jz .no
    cmp ecx, 3
    ja .no
    cmp ecx, [LOCAL(T_BINDS)]
    jne .no
    ; back: pairs x durability / 3 (rounded up)
    lea rdx, [rel g_item_dur]
    movzx eax, word [rdx + rdi * 2]
    imul eax, ecx
    add eax, 2
    xor edx, edx
    mov ecx, 3
    div ecx
    movzx ecx, word [rsi + 4]           ; wear
    sub ecx, eax
    jns .wear
    xor ecx, ecx
.wear:
    mov rax, [rsi]
    mov [rel g_repaired], rax
    mov word [rel g_repaired + 2], 1
    mov [rel g_repaired + 4], cx
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; craft_recipe — the recipe book: lay a recipe's ingredients out in the grid
; from the player's slots (what was in the grid goes back first). Once, or
; with INVB_SHIFT as many times as the slots and stacks allow.
;   in:  rcx = INV_PKT* (.slot = recipe, .arg = INVB_*)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define R_TIMES     0
%define R_CELLS     4                   ; cells the recipe needs (grid cells)
PROC craft_recipe, 16, rbx, rsi, rdi, r12, r13, r14
    mov eax, [rcx + INV_PKT.arg]
    mov edx, 1
    test eax, INVB_SHIFT
    jz .times
    mov edx, MAX_REPEAT
.times:
    mov [LOCAL(R_TIMES)], edx
    mov ebx, [rcx + INV_PKT.slot]
    cmp ebx, [rel g_recipe_count]
    jae .done
    cmp dword [rel g_win_grid], 0
    je .done
    lea rax, [rel g_rec_ok]
    cmp byte [rax + rbx], 0
    je .done
    lea rax, [rel g_rec_station]
    movzx eax, byte [rax + rbx]
    test eax, eax
    jz .fits
    cmp eax, [rel g_win_station]
    jne .done
.fits:
    ; does it fit the grid?
    mov ecx, [rel g_win_grid]
    lea rax, [rel g_rec_w]
    movzx eax, byte [rax + rbx]
    test eax, eax
    jz .shapeless
    cmp eax, ecx
    ja .done
    lea rax, [rel g_rec_h]
    movzx eax, byte [rax + rbx]
    cmp eax, ecx
    ja .done
    jmp .clear
.shapeless:
    lea rax, [rel g_rec_n]
    movzx eax, byte [rax + rbx]
    imul ecx, ecx
    cmp eax, ecx
    ja .done
.clear:
    ; the grid back to the player first
    mov r12d, INV_GRID
.back:
    cmp r12d, INV_RESULT
    jae .laid
    SLOT_PTR rsi, r12
    movzx ecx, word [rsi]
    test ecx, ecx
    jz .back_next
    movzx edx, word [rsi + 2]
    movzx r8d, word [rsi + 4]
    mov qword [rsi], 0
    call give
    mov ecx, r12d
    call inv_mark
.back_next:
    inc r12d
    jmp .back
.laid:
    ; one set at a time: plan it on a copy of the counts, then move it
.set:
    lea rdi, [rel g_left]
    xor ecx, ecx
.copy:
    SLOT_PTR rax, rcx
    mov ax, [rax + 2]
    mov [rdi + rcx * 2], ax
    inc ecx
    cmp ecx, INV_SLOTS
    jb .copy
    xor r12d, r12d                      ; recipe cell
.plan:
    cmp r12d, 9
    jae .move
    lea rax, [rel g_take]
    mov dword [rax + r12 * 4], -1
    call cell_pattern                   ; rcx = pattern, eax = grid cell
    test rcx, rcx
    jz .plan_next
    mov r14, rcx
    mov r13d, eax
    ; the grid cell's item (a stack being added to must stay the same item,
    ; and not grow past its stack size)
    lea ecx, [r13d + INV_GRID]
    SLOT_PTR rax, rcx
    movzx edi, word [rax]
    test edi, edi
    jz .find
    mov ecx, edi
    call inv_stack_of
    lea ecx, [r13d + INV_GRID]
    SLOT_PTR rdx, rcx
    movzx ecx, word [rdx + 2]
    cmp ecx, eax
    jae .move_none
.find:
    xor esi, esi
.slot:
    cmp esi, INV_SLOTS
    jae .move_none                      ; nothing left for this cell
    lea rax, [rel g_left]
    cmp word [rax + rsi * 2], 0
    je .slot_next
    SLOT_PTR rax, rsi
    movzx edx, word [rax]
    test edi, edi
    jz .any
    cmp edx, edi
    jne .slot_next
.any:
    mov rcx, r14
    call recipe_cell_ok
    test eax, eax
    jnz .take
.slot_next:
    inc esi
    jmp .slot
.take:
    lea rax, [rel g_left]
    dec word [rax + rsi * 2]
    lea rax, [rel g_take]
    mov [rax + r12 * 4], esi
.plan_next:
    inc r12d
    jmp .plan
.move:
    ; the plan worked: move one item per cell
    xor r12d, r12d
.mv:
    cmp r12d, 9
    jae .moved
    lea rax, [rel g_take]
    mov esi, [rax + r12 * 4]
    cmp esi, -1
    je .mv_next
    call cell_pattern
    lea r13d, [eax + INV_GRID]
    SLOT_PTR rdx, rsi
    SLOT_PTR r8, r13
    mov ax, [rdx]
    mov [r8], ax
    inc word [r8 + 2]
    mov ax, [rdx + 4]
    mov [r8 + 4], ax
    dec word [rdx + 2]
    jnz .mv_mark
    mov qword [rdx], 0
.mv_mark:
    mov ecx, esi
    call inv_mark
    mov ecx, r13d
    call inv_mark
.mv_next:
    inc r12d
    jmp .mv
.moved:
    dec dword [LOCAL(R_TIMES)]
    jnz .set
.move_none:
    call craft_update
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; cell_pattern — recipe ebx's cell r12d: rcx = its item pattern (0 none),
; eax = the grid cell it goes to (shaped: same row and column; shapeless:
; the cells of the open grid in order).
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
cell_pattern:
    lea rax, [rel g_rec_w]
    movzx eax, byte [rax + rbx]
    test eax, eax
    jz .shapeless
    imul ecx, ebx, 9
    add ecx, r12d
    lea rax, [rel g_rec_cells]
    mov rcx, [rax + rcx * 8]
    mov eax, r12d
    ret
.shapeless:
    lea rax, [rel g_rec_n]
    movzx eax, byte [rax + rbx]
    xor ecx, ecx
    cmp r12d, eax
    jae .none
    imul ecx, ebx, 9
    add ecx, r12d
    lea rax, [rel g_rec_cells]
    mov rcx, [rax + rcx * 8]
    ; the r12d-th cell of the open grid
    mov eax, r12d
    xor edx, edx
    push rcx
    mov ecx, [rel g_win_grid]
    div ecx                             ; eax = row, edx = column
    pop rcx
    imul eax, eax, 3
    add eax, edx
    ret
.none:
    xor eax, eax
    ret
