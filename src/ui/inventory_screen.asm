; =============================================================================
; inventory_screen.asm — the inventory screen (milestone 18, design/items/
; items_inventory.md): E in a world. The world keeps running behind it.
;
;   Survival: the 27 inventory slots and the hotbar, the 2 x 2 crafting
;   grid with its result, and the recipe book.
;   A crafting station (a workbench, right click; part 3): its 3 x 3 grid,
;   the result and the recipe book, in either mode.
;   Creative: above them a catalog of every block and item in tabs (icon
;   buttons; data/items/00_tabs.items) with a search field; the wheel
;   scrolls. Left click on the catalog takes a full stack, right click one;
;   shift-click puts a stack straight into the inventory; a click on the
;   catalog (or outside the panel) with a stack in hand throws it away.
;
; Slots: left click takes / puts / swaps the stack, right click takes half
; or puts one, shift-click moves it between the hotbar and the inventory.
; Every change is asked of the simulation (inventory.asm); this screen only
; draws the client's copy (g_cinv) and the stack carried by the mouse.
;
; Public API:
;   inv_screen_open()
;   inv_screen_close()                  the carried stack goes back
;   inv_screen_frame(ecx = w, edx = h)
;   inv_screen_typing() -> eax 1        the search field has the keyboard
;   ui_wear_bar(ecx = x, edx = y, r8d = width, r9d = item, ARG5 = wear)
;                                       a worn tool's durability bar (also the
;                                       HUD's hotbar)
; The window shown is the client's g_cwin (client.asm). The recipe book lists
; the recipes the grid and station allow that can be made from what the
; player has (slots and grid); a click lays one out in the grid
; (PKT_C_RECIPE), shift-click as many as possible.
; =============================================================================
%include "macros.inc"
%include "input.inc"
%include "packet.inc"
%include "ui.inc"
%include "items.inc"
%include "save.inc"

global inv_screen_open, inv_screen_close, inv_screen_frame, inv_screen_typing
global ui_wear_bar

extern ui_frame, ui_end, ui_button, ui_panel, ui_label, ui_rect, ui_glass
extern ui_text, ui_text_width, ui_hover, ui_textfield, ui_focus, ui_focused
extern ui_icon, str_append_dec, pkt_send, g_to_sim, world_block_at
extern g_ui_vw, g_ui_vh, g_ui_mx, g_ui_my, g_ui_click, g_ui_rclick
extern g_cinv, g_world_mode, g_cwin, g_cinv_ver, g_cfurnace
extern recipe_cell_ok, g_recipe_count, g_rec_result, g_rec_amount
extern g_rec_station, g_rec_w, g_rec_h, g_rec_n, g_rec_ok, g_rec_cells

%define SLOT_PX         48              ; a slot (units)
%define STEP            52              ; slot + gap
%define ICON            38
%define CAT_COLS        12
%define CAT_ROWS        5
%define PAD             28
%define SEARCH_CAP      24
%define SEARCH_ID       60              ; text field id
%define TAB_ID0         120             ; tab button ids
%define BOOK_COLS       4               ; the recipe book
%define BOOK_W          (BOOK_COLS * STEP - 4)
%define BOOK_GAP        28
%define MAX_BOOK        512

section .rdata
s_inventory:    db "Inventory", 0
s_search:       db "Search", 0
s_found:        db "Search results", 0
s_none:         db "Nothing found", 0
s_crafting:     db "Crafting", 0
s_chest:        db "Chest", 0
s_large_chest:  db "Large chest", 0
s_furnace:      db "Furnace", 0
s_recipes:      db "Recipes", 0
s_no_recipes:   db "Nothing to make", 0
s_no_recipes2:  db "with what you have", 0

section .bss
alignb 4
g_tab:          resd 1
g_scroll:       resd 1
g_hover_item:   resd 1                  ; the item under the mouse (tooltip)
g_list_n:       resd 1
g_creative:     resd 1
g_px:           resd 1                  ; panel left / top / width / height
g_py:           resd 1
g_pw:           resd 1
g_ph:           resd 1
g_out:          resb INV_PKT_size
g_search:       resb SEARCH_CAP
g_count:        resb 16
alignb 2
g_list:         resw MAX_ITEMS          ; the catalog as shown (tab / search)
g_book:         resw MAX_BOOK           ; the recipe book's recipes
g_avail_item:   resw INV_SLOTS + 9      ; what the player has (slots, grid)
g_avail_n:      resw INV_SLOTS + 9
alignb 4
g_book_n:       resd 1
g_book_ver:     resd 1                  ; g_cinv_ver it was built for
g_book_scroll:  resd 1
g_book_win:     resd 1                  ; the window kind it was built for

section .text

; send — a packet to the simulation: ecx = type, edx = slot, r8d = item,
; r9d = count, ARG5 = arg
PROC send, 0
    mov [rel g_out + INV_PKT.slot], edx
    mov [rel g_out + INV_PKT.item], r8d
    mov [rel g_out + INV_PKT.count], r9d
    mov eax, [ARG(5)]
    mov [rel g_out + INV_PKT.arg], eax
    mov edx, ecx
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_out]
    mov r9d, INV_PKT_size
    call pkt_send
    RETURN
ENDPROC

; inv_screen_open — a fresh look (the tab and search are kept)
PROC inv_screen_open, 0
    mov dword [rel g_hover_item], 0
    mov dword [rel g_book_ver], -1
    mov dword [rel g_book_scroll], 0
    xor ecx, ecx
    call ui_focus
    RETURN
ENDPROC

; inv_screen_close — the window closes: the simulation puts the carried
; stack and the grid back into the inventory
PROC inv_screen_close, 0
    mov dword [rel g_close + WIN_PKT.kind], WIN_NONE
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_close]
    INVOKE pkt_send, rcx, PKT_C_WINDOW, r8, WIN_PKT_size
    xor ecx, ecx
    call ui_focus
    RETURN
ENDPROC

; inv_screen_typing — eax = 1 while the search field has the keyboard
inv_screen_typing:
    sub rsp, 40
    call ui_focused
    add rsp, 40
    cmp eax, SEARCH_ID + 1
    sete al
    movzx eax, al
    ret

; contains — eax = 1 if text rcx contains rdx (ASCII, ignoring case)
;   clobbers: rax, rcx, rdx, r8, r9, r10
contains:
    cmp byte [rdx], 0
    je .yes
.start:
    cmp byte [rcx], 0
    je .no
    mov r8, rcx
    mov r9, rdx
.cmp:
    movzx eax, byte [r9]
    test eax, eax
    jz .yes
    movzx r10d, byte [r8]
    test r10d, r10d
    jz .no
    or eax, 0x20
    or r10d, 0x20
    cmp eax, r10d
    jne .next
    inc r8
    inc r9
    jmp .cmp
.next:
    inc rcx
    jmp .start
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; build_list — the catalog's items: the current tab, or every item whose
; name contains the search text   clobbers: volatile registers
PROC build_list, 0, rbx, rsi
    xor esi, esi
    mov ebx, 1
.item:
    cmp ebx, [rel g_item_count]
    jae .done
    lea rax, [rel g_item_flags]
    test byte [rax + rbx], ITEMF_HIDDEN
    jnz .next
    cmp byte [rel g_search], 0
    je .by_tab
    lea rax, [rel g_item_titles]
    mov rcx, [rax + rbx * 8]
    lea rdx, [rel g_search]
    call contains
    test eax, eax
    jz .next
    jmp .add
.by_tab:
    lea rax, [rel g_item_tab]
    movzx eax, byte [rax + rbx]
    cmp eax, [rel g_tab]
    jne .next
.add:
    lea rax, [rel g_list]
    mov [rax + rsi * 2], bx
    inc esi
.next:
    inc ebx
    jmp .item
.done:
    mov [rel g_list_n], esi
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_wear_bar — see the header: nothing for an unworn item; else a dark
; bar with the durability left, green when new to red when nearly broken.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_wear_bar, 16, rbx, rsi, rdi, r12
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    mov eax, [ARG(5)]
    and eax, 0xFFFF
    jz .done
    lea rcx, [rel g_item_dur]
    movzx r12d, word [rcx + r9 * 2]
    test r12d, r12d
    jz .done
    ; left / durability
    mov ecx, r12d
    sub ecx, eax
    jg .left
    xor ecx, ecx
.left:
    cvtsi2ss xmm0, ecx
    cvtsi2ss xmm1, r12d
    divss xmm0, xmm1
    movss [LOCAL(0)], xmm0              ; f = 0..1
    mov dword [rsp + 32], 0xF0101010
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 2
    mov qword [rsp + 56], 0
    INVOKE ui_rect, rbx, rsi, rdi, 5
    ; the part left, coloured by it
    movss xmm0, [LOCAL(0)]
    cvtsi2ss xmm1, edi
    mulss xmm1, xmm0
    cvttss2si r9d, xmm1
    cmp r9d, 1
    jge .w
    mov r9d, 1
.w:
    movss xmm1, [rel c_255]
    mulss xmm1, xmm0
    cvttss2si eax, xmm1                 ; green
    mov ecx, 255
    sub ecx, eax                        ; red
    shl eax, 8
    or eax, ecx
    or eax, 0xFF000000
    mov [rsp + 32], eax
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 2
    mov qword [rsp + 56], 0
    INVOKE ui_rect, rbx, rsi, r9, 5
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; draw_slot — a slot with its item and count; the hovered one lights up.
;   in:  ecx = x, edx = y, r8d = item, r9d = count, ARG5 = 1 the slot in hand
;   out: eax = 1 if the mouse is over it
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC draw_slot, 16, rbx, rsi, rdi, r12, r13
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    mov r12d, r9d
    mov ecx, ebx
    mov edx, esi
    mov r8d, SLOT_PX
    mov r9d, SLOT_PX
    call ui_hover
    mov r13d, eax
    mov eax, 0x50000000                 ; fill
    mov ecx, 0x28FFFFFF                 ; border
    test r13d, r13d
    jz .look
    mov eax, 0x40FFFFFF
.look:
    cmp dword [ARG(5)], 0
    je .colours
    mov ecx, COL_ACCENT
.colours:
    mov [rsp + 32], rax
    mov [rsp + 40], rcx
    mov qword [rsp + 48], 8
    mov eax, 1
    cmp dword [ARG(5)], 0
    je .border
    mov eax, 2
.border:
    mov [rsp + 56], rax
    INVOKE ui_rect, rbx, rsi, SLOT_PX, SLOT_PX
    test edi, edi
    jz .done
    mov dword [rsp + 32], 0xFFFFFFFF
    lea edx, [ebx + (SLOT_PX - ICON) / 2]
    lea r8d, [esi + (SLOT_PX - ICON) / 2]
    mov ecx, edi
    mov r9d, ICON
    call ui_icon
    ; a worn tool's bar
    mov eax, [rel g_slot_wear]
    mov dword [rel g_slot_wear], 0
    mov [rsp + 32], rax
    lea ecx, [ebx + 6]
    lea edx, [esi + SLOT_PX - 9]
    mov r8d, SLOT_PX - 12
    mov r9d, edi
    call ui_wear_bar
    cmp r12d, 1
    jbe .done
    lea rcx, [rel g_count]
    mov edx, r12d
    xor r8d, r8d
    call str_append_dec
    lea edx, [ebx + SLOT_PX - 3]
    lea r8d, [esi + SLOT_PX - 20]
    mov dword [rsp + 32], COL_TEXT
    mov dword [rsp + 40], COL_TEXT
    mov qword [rsp + 48], UI_RIGHT | UI_SHADOW | UI_BOLD
    lea rcx, [rel g_count]
    mov r9d, 16
    call ui_text
.done:
    test r13d, r13d
    jz .out
    test edi, edi
    jz .out
    mov [rel g_hover_item], edi
.out:
    mov eax, r13d
    RETURN
ENDPROC

; click_buttons — eax = INVB_* for this frame's click (with shift), or -1
; if there was no click
click_buttons:
    sub rsp, 40
    mov eax, -1
    cmp dword [rel g_ui_rclick], 0
    je .left
    mov eax, INVB_RIGHT
    jmp .shift
.left:
    cmp dword [rel g_ui_click], 0
    je .done
    xor eax, eax
.shift:
    mov [rsp + 32], eax
    mov ecx, VK_SHIFT
    call input_vk_down
    mov ecx, [rsp + 32]
    test eax, eax
    jz .no_shift
    or ecx, INVB_SHIFT
.no_shift:
    mov eax, ecx
.done:
    add rsp, 40
    ret

; -----------------------------------------------------------------------------
; player_slots — the 27 inventory slots and, under them, the hotbar; clicks
; go to the simulation.
;   in:  ecx = left, edx = top
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC player_slots, 16, rbx, rsi, rdi, r12
    mov esi, ecx
    mov edi, edx
    xor ebx, ebx                        ; slot
.slot:
    cmp ebx, INV_SLOTS
    jae .done
    ; slots 9..35 in three rows; 0..8 below them after a small gap
    cmp ebx, INV_HOTBAR
    jb .hotbar
    lea eax, [ebx - INV_HOTBAR]
    xor edx, edx
    mov ecx, INV_HOTBAR
    div ecx                             ; eax = row, edx = column
    imul r8d, eax, STEP
    add r8d, edi
    jmp .pos
.hotbar:
    mov edx, ebx
    lea r8d, [edi + 3 * STEP + 10]
.pos:
    imul ecx, edx, STEP
    add ecx, esi
    mov edx, r8d
    lea rax, [rel g_cinv]
    movzx r8d, word [rax + rbx * 8]
    movzx r9d, word [rax + rbx * 8 + 2]
    movzx eax, word [rax + rbx * 8 + 4]
    mov [rel g_slot_wear], eax
    mov qword [rsp + 32], 0
    call draw_slot
    test eax, eax
    jz .next
    call click_buttons
    cmp eax, -1
    je .next
    mov [rsp + 32], rax
    INVOKE send, PKT_C_INV_CLICK, rbx, 0, 0
.next:
    inc ebx
    jmp .slot
.done:
    RETURN
ENDPROC

; first_free — eax = the first empty slot (hotbar first), -1 if none
first_free:
    xor eax, eax
    lea rcx, [rel g_cinv]
.s:
    cmp word [rcx + rax * 8], 0
    je .found
    inc eax
    cmp eax, INV_SLOTS
    jb .s
    mov eax, -1
.found:
    ret

; -----------------------------------------------------------------------------
; catalog — Creative: tabs, search, the item grid.
;   in:  ecx = left, edx = top (of the tab row)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define C_X     0
%define C_Y     4
%define C_GY    8                       ; grid top
PROC catalog, 16, rbx, rsi, rdi, r12, r13
    mov [LOCAL(C_X)], ecx
    mov [LOCAL(C_Y)], edx
    ; tabs: icon buttons
    xor ebx, ebx
.tab:
    cmp ebx, [rel g_tab_count]
    jae .tabs_done
    xor r10d, r10d
    cmp byte [rel g_search], 0
    jne .tab_flags                      ; (searching: no tab is chosen)
    cmp ebx, [rel g_tab]
    jne .tab_flags
    mov r10d, UIW_SELECTED
.tab_flags:
    mov [rsp + 48], r10
    lea rax, [rel s_empty]
    mov [rsp + 40], rax
    mov qword [rsp + 32], 44
    imul edx, ebx, 58
    add edx, [LOCAL(C_X)]
    lea ecx, [ebx + TAB_ID0]
    INVOKE ui_button, rcx, rdx, [LOCAL(C_Y)], 52
    test eax, eax
    jz .tab_icon
    mov [rel g_tab], ebx
    mov dword [rel g_scroll], 0
    mov byte [rel g_search], 0
.tab_icon:
    lea rax, [rel g_tab_icon]
    movzx ecx, word [rax + rbx * 2]
    imul edx, ebx, 58
    add edx, [LOCAL(C_X)]
    add edx, (52 - 32) / 2
    mov r8d, [LOCAL(C_Y)]
    add r8d, (44 - 32) / 2
    mov dword [rsp + 32], 0xFFFFFFFF
    mov r9d, 32
    call ui_icon
    ; the tab's name as its tooltip
    imul ecx, ebx, 58
    add ecx, [LOCAL(C_X)]
    mov edx, [LOCAL(C_Y)]
    mov r8d, 52
    mov r9d, 44
    call ui_hover
    test eax, eax
    jz .tab_next
    lea rax, [rel g_tab_titles]
    mov rax, [rax + rbx * 8]
    mov [rel g_tip_text], rax
.tab_next:
    inc ebx
    jmp .tab
.tabs_done:
    ; search field, right-aligned
    mov qword [rsp + 32], 44
    lea rax, [rel g_search]
    mov [rsp + 40], rax
    mov qword [rsp + 48], SEARCH_CAP
    lea rax, [rel s_search]
    mov [rsp + 56], rax
    ; (as wide as 214, but never over the tabs)
    imul r9d, [rel g_tab_count], 58
    neg r9d
    add r9d, CAT_COLS * STEP - 4 - 6
    cmp r9d, 214
    jle .field_w
    mov r9d, 214
.field_w:
    mov edx, [LOCAL(C_X)]
    add edx, CAT_COLS * STEP - 4
    sub edx, r9d
    INVOKE ui_textfield, SEARCH_ID, rdx, [LOCAL(C_Y)], r9
    test eax, eax
    jz .heading
    mov dword [rel g_scroll], 0
.heading:
    call build_list
    ; the heading: the tab's name or "Search results"
    lea rax, [rel s_found]
    cmp byte [rel g_search], 0
    jne .head
    mov eax, [rel g_tab]
    lea rcx, [rel g_tab_titles]
    mov rax, [rcx + rax * 8]
.head:
    mov r8d, [LOCAL(C_Y)]
    add r8d, 54
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], 0
    INVOKE ui_label, rax, [LOCAL(C_X)], r8, 18
    ; scroll
    mov eax, [rel g_mouse_wheel]
    test eax, eax
    jz .scrolled
    mov ecx, [rel g_scroll]
    cmp eax, 0
    jg .up
    inc ecx
    jmp .clamp
.up:
    dec ecx
.clamp:
    mov eax, [rel g_list_n]
    add eax, CAT_COLS - 1
    xor edx, edx
    mov r8d, CAT_COLS
    div r8d
    sub eax, CAT_ROWS                   ; last first-row
    cmp ecx, eax
    jle .c1
    mov ecx, eax
.c1:
    test ecx, ecx
    jns .c2
    xor ecx, ecx
.c2:
    mov [rel g_scroll], ecx
.scrolled:
    mov eax, [LOCAL(C_Y)]
    add eax, 80
    mov [LOCAL(C_GY)], eax
    cmp dword [rel g_list_n], 0
    jne .grid
    mov r8d, [LOCAL(C_GY)]
    add r8d, 100
    mov edx, [LOCAL(C_X)]
    add edx, CAT_COLS * STEP / 2
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel s_none]
    INVOKE ui_label, rcx, rdx, r8, 20
    jmp .done
.grid:
    imul ebx, [rel g_scroll], CAT_COLS  ; list index
    xor r12d, r12d                      ; cell
.cell:
    cmp r12d, CAT_COLS * CAT_ROWS
    jae .done
    cmp ebx, [rel g_list_n]
    jae .done
    lea rax, [rel g_list]
    movzx r13d, word [rax + rbx * 2]    ; item
    mov eax, r12d
    xor edx, edx
    mov ecx, CAT_COLS
    div ecx
    imul ecx, edx, STEP
    add ecx, [LOCAL(C_X)]
    imul edx, eax, STEP
    add edx, [LOCAL(C_GY)]
    mov r8d, r13d
    mov r9d, 1
    mov qword [rsp + 32], 0
    call draw_slot
    test eax, eax
    jz .cell_next
    call click_buttons
    cmp eax, -1
    je .cell_next
    call catalog_click
.cell_next:
    inc ebx
    inc r12d
    jmp .cell
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; catalog_click — a click on catalog item r13d with buttons eax.
;   clobbers: volatile registers (keeps rbx, r12, r13)
; -----------------------------------------------------------------------------
PROC catalog_click, 0, rbx
    mov ebx, eax
    lea rcx, [rel g_cinv]
    movzx edx, word [rcx + INV_CURSOR * 8]
    test ebx, INVB_SHIFT
    jnz .shift
    ; something in hand (and not more of the same with a right click): away
    test edx, edx
    jz .take
    test ebx, INVB_RIGHT
    jz .throw
    cmp edx, r13d
    jne .throw
    ; right click on the same item: one more
    movzx r9d, word [rcx + INV_CURSOR * 8 + 2]
    inc r9d
    mov qword [rsp + 32], 0
    INVOKE send, PKT_C_CREATIVE_SET, INV_CURSOR, r13, r9
    RETURN
.throw:
    mov qword [rsp + 32], 0
    INVOKE send, PKT_C_CREATIVE_SET, INV_CURSOR, 0, 0
    RETURN
.take:
    mov r9d, 64                         ; (the simulation caps it at the stack size)
    test ebx, INVB_RIGHT
    jz .set
    mov r9d, 1
.set:
    mov qword [rsp + 32], 0
    INVOKE send, PKT_C_CREATIVE_SET, INV_CURSOR, r13, r9
    RETURN
.shift:
    call first_free
    cmp eax, -1
    je .done
    mov qword [rsp + 32], 0
    INVOKE send, PKT_C_CREATIVE_SET, rax, r13, 64
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; craft_area — the crafting grid, an arrow and the result slot.
;   in:  ecx = left, edx = top, r8d = grid width (2 / 3)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define A_X     0
%define A_Y     4
%define A_G     8
%define A_GX    12                      ; the grid's left
PROC craft_area, 16, rbx, rsi, rdi
    mov [LOCAL(A_X)], ecx
    mov [LOCAL(A_Y)], edx
    mov [LOCAL(A_G)], r8d
    ; the grid one slot in (3 x 3) or two (2 x 2), the result at column 6
    mov eax, 3
    sub eax, r8d
    inc eax
    imul eax, eax, STEP
    add eax, ecx
    mov [LOCAL(A_GX)], eax
    xor ebx, ebx                        ; cell
.cell:
    cmp ebx, 9
    jae .arrow
    mov eax, ebx
    xor edx, edx
    mov ecx, 3
    div ecx                             ; eax = row, edx = column
    cmp eax, [LOCAL(A_G)]
    jae .next
    cmp edx, [LOCAL(A_G)]
    jae .next
    imul ecx, edx, STEP
    add ecx, [LOCAL(A_GX)]
    imul edx, eax, STEP
    add edx, [LOCAL(A_Y)]
    lea r8d, [ebx + INV_GRID]
    call slot_at
.next:
    inc ebx
    jmp .cell
.arrow:
    ; centred on the grid's height
    imul esi, [LOCAL(A_G)], STEP
    sub esi, 4
    shr esi, 1
    add esi, [LOCAL(A_Y)]               ; middle
    mov edi, [LOCAL(A_X)]
    add edi, 4 * STEP + 6
    mov dword [rsp + 32], 0xB0FFFFFF
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 3
    mov qword [rsp + 56], 0
    lea edx, [esi - 4]
    INVOKE ui_rect, rdi, rdx, 50, 8
    lea edx, [edi + 40]
    lea r8d, [esi - 22]
    mov dword [rsp + 32], 0xB0FFFFFF
    mov qword [rsp + 40], UI_BOLD
    lea rcx, [rel s_arrow]
    mov r9d, 36
    call ui_label
    ; the result
    mov ecx, [LOCAL(A_X)]
    add ecx, 6 * STEP
    lea edx, [esi - (SLOT_PX / 2)]
    mov r8d, INV_RESULT
    call slot_at
    RETURN
ENDPROC

; slot_at — draw inventory slot r8d at ecx, edx; a click on it goes to the
; simulation   clobbers: volatile registers
PROC slot_at, 0, rbx
    mov ebx, r8d
    lea rax, [rel g_cinv]
    movzx r8d, word [rax + rbx * 8]
    movzx r9d, word [rax + rbx * 8 + 2]
    movzx eax, word [rax + rbx * 8 + 4]
    mov [rel g_slot_wear], eax
    mov qword [rsp + 32], 0
    call draw_slot
    test eax, eax
    jz .done
    call click_buttons
    cmp eax, -1
    je .done
    mov [rsp + 32], rax
    INVOKE send, PKT_C_INV_CLICK, rbx, 0, 0
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; furnace_area — input over the flame over the fuel, an arrow that fills
; with the smelting, the output (g_cfurnace: the progress).
;   in:  ecx = left, edx = top
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC furnace_area, 0, rbx, rsi, rdi
    lea ebx, [ecx + 2 * STEP]           ; input / fuel column
    mov esi, edx
    mov ecx, ebx
    mov edx, esi
    mov r8d, INV_CONTAINER + 0
    call slot_at
    mov ecx, ebx
    lea edx, [esi + 2 * STEP]
    mov r8d, INV_CONTAINER + 1
    call slot_at
    ; the flame: a dark well, filled from the bottom by the fuel left
    lea edi, [esi + STEP + 6]
    mov dword [rsp + 32], 0x60000000
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 6
    mov qword [rsp + 56], 0
    lea ecx, [ebx + 14]
    INVOKE ui_rect, rcx, rdi, 20, 28
    movss xmm0, [rel g_cfurnace + FURNACE_PKT.burn]
    mulss xmm0, [rel c_28]
    cvttss2si r9d, xmm0
    test r9d, r9d
    jle .arrow
    lea edx, [edi + 28]
    sub edx, r9d
    mov dword [rsp + 32], 0xFF1E8CFF    ; warm orange
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 6
    mov qword [rsp + 56], 0
    lea ecx, [ebx + 14]
    INVOKE ui_rect, rcx, rdx, 20, r9
.arrow:
    ; the arrow: a bar that fills left to right
    lea ecx, [ebx + STEP + 14]
    lea edx, [esi + STEP + 18]
    mov dword [rsp + 32], 0x60000000
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 4
    mov qword [rsp + 56], 0
    INVOKE ui_rect, rcx, rdx, 2 * STEP - 28, 12
    movss xmm0, [rel g_cfurnace + FURNACE_PKT.cook]
    mulss xmm0, [rel c_arrow]
    cvttss2si r9d, xmm0
    test r9d, r9d
    jle .out
    lea ecx, [ebx + STEP + 14]
    lea edx, [esi + STEP + 18]
    mov dword [rsp + 32], 0xF0F0F0F0
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 4
    mov qword [rsp + 56], 0
    INVOKE ui_rect, rcx, rdx, r9, 12
.out:
    lea ecx, [ebx + 3 * STEP]
    lea edx, [esi + STEP]
    mov r8d, INV_CONTAINER + 2
    call slot_at
    RETURN
ENDPROC

; furnace_title — rax = the title of the furnace block being used
furnace_title:
    sub rsp, 40
    mov ecx, [rel g_cwin + WIN_PKT.pos]
    mov edx, [rel g_cwin + WIN_PKT.pos + 4]
    mov r8d, [rel g_cwin + WIN_PKT.pos + 8]
    call world_block_at
    lea rcx, [rel g_block_item]
    movzx eax, word [rcx + rax * 2]
    lea rcx, [rel g_item_titles]
    mov rax, [rcx + rax * 8]
    test rax, rax
    jnz .done
    lea rax, [rel s_furnace]
.done:
    add rsp, 40
    ret

; -----------------------------------------------------------------------------
; can_make — eax = 1 if recipe ebx can be made from g_avail_* (each cell
; takes one item from the first stack that fits; the counts are used up).
;   clobbers: volatile registers (keeps rbx)
; -----------------------------------------------------------------------------
PROC can_make, 0, rsi, rdi, r12, r13
    lea rax, [rel g_rec_w]
    movzx eax, byte [rax + rbx]
    mov r13d, 9
    test eax, eax
    jnz .cells
    lea rax, [rel g_rec_n]
    movzx r13d, byte [rax + rbx]
.cells:
    xor r12d, r12d
.cell:
    cmp r12d, r13d
    jae .yes
    imul eax, ebx, 9
    add eax, r12d
    lea rcx, [rel g_rec_cells]
    mov rdi, [rcx + rax * 8]
    test rdi, rdi
    jz .next
    xor esi, esi
.slot:
    cmp esi, INV_SLOTS + 9
    jae .no
    lea rax, [rel g_avail_n]
    cmp word [rax + rsi * 2], 0
    je .slot_next
    lea rax, [rel g_avail_item]
    movzx edx, word [rax + rsi * 2]
    mov rcx, rdi
    call recipe_cell_ok
    test eax, eax
    jnz .take
.slot_next:
    inc esi
    jmp .slot
.take:
    lea rax, [rel g_avail_n]
    dec word [rax + rsi * 2]
.next:
    inc r12d
    jmp .cell
.yes:
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; book_build — the recipes this window allows that can be made now.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC book_build, 0, rbx, rsi, rdi
    mov eax, [rel g_cinv_ver]
    mov [rel g_book_ver], eax
    xor edi, edi                        ; listed
    xor ebx, ebx
.recipe:
    cmp ebx, [rel g_recipe_count]
    jae .done
    cmp edi, MAX_BOOK
    jae .done
    lea rax, [rel g_rec_ok]
    cmp byte [rax + rbx], 0
    je .next
    lea rax, [rel g_rec_station]
    movzx eax, byte [rax + rbx]
    test eax, eax
    jz .fits
    cmp eax, [rel g_cwin + WIN_PKT.station]
    jne .next
.fits:
    mov ecx, [rel g_cwin + WIN_PKT.grid]
    lea rax, [rel g_rec_w]
    movzx eax, byte [rax + rbx]
    test eax, eax
    jz .shapeless
    cmp eax, ecx
    ja .next
    lea rax, [rel g_rec_h]
    movzx eax, byte [rax + rbx]
    cmp eax, ecx
    ja .next
    jmp .have
.shapeless:
    lea rax, [rel g_rec_n]
    movzx eax, byte [rax + rbx]
    imul ecx, ecx
    cmp eax, ecx
    ja .next
.have:
    ; what the player has: the slots and the grid
    xor esi, esi
.copy:
    mov eax, esi
    cmp eax, INV_SLOTS
    jb .from
    add eax, INV_GRID - INV_SLOTS
.from:
    lea rcx, [rel g_cinv]
    mov edx, [rcx + rax * 8]
    lea rcx, [rel g_avail_item]
    mov [rcx + rsi * 2], dx
    shr edx, 16
    lea rcx, [rel g_avail_n]
    mov [rcx + rsi * 2], dx
    inc esi
    cmp esi, INV_SLOTS + 9
    jb .copy
    call can_make
    test eax, eax
    jz .next
    lea rax, [rel g_book]
    mov [rax + rdi * 2], bx
    inc edi
.next:
    inc ebx
    jmp .recipe
.done:
    mov [rel g_book_n], edi
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; recipe_book — the recipe book column: what can be made, as result slots.
;   in:  ecx = left, edx = top, r8d = height
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define B_X     0
%define B_Y     4
%define B_ROWS  8
PROC recipe_book, 16, rbx, rsi, rdi, r12
    mov [LOCAL(B_X)], ecx
    mov [LOCAL(B_Y)], edx
    sub r8d, 34
    mov eax, r8d
    xor edx, edx
    mov ecx, STEP
    div ecx
    mov [LOCAL(B_ROWS)], eax
    mov eax, [rel g_cwin + WIN_PKT.kind]
    cmp eax, [rel g_book_win]
    jne .build
    mov eax, [rel g_cinv_ver]
    cmp eax, [rel g_book_ver]
    je .built
.build:
    mov eax, [rel g_cwin + WIN_PKT.kind]
    mov [rel g_book_win], eax
    call book_build
.built:
    ; a faint backing, the heading
    mov dword [rsp + 32], 0x30000000
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 10
    mov qword [rsp + 56], 0
    mov ecx, [LOCAL(B_X)]
    sub ecx, 8
    mov edx, [LOCAL(B_Y)]
    sub edx, 6
    imul r9d, [LOCAL(B_ROWS)], STEP
    add r9d, 34 + 12
    INVOKE ui_rect, rcx, rdx, BOOK_W + 16, r9
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], UI_BOLD
    lea rcx, [rel s_recipes]
    INVOKE ui_label, rcx, [LOCAL(B_X)], [LOCAL(B_Y)], 20
    add dword [LOCAL(B_Y)], 34
    cmp dword [rel g_book_n], 0
    jne .scroll
    mov edx, [LOCAL(B_X)]
    add edx, BOOK_W / 2
    mov r8d, [LOCAL(B_Y)]
    add r8d, 20
    mov dword [rsp + 32], COL_TEXT_OFF
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel s_no_recipes]
    INVOKE ui_label, rcx, rdx, r8, 16
    mov edx, [LOCAL(B_X)]
    add edx, BOOK_W / 2
    mov r8d, [LOCAL(B_Y)]
    add r8d, 40
    mov dword [rsp + 32], COL_TEXT_OFF
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel s_no_recipes2]
    INVOKE ui_label, rcx, rdx, r8, 16
    jmp .done
.scroll:
    ; the wheel over the book scrolls it
    mov eax, [rel g_mouse_wheel]
    test eax, eax
    jz .scrolled
    imul r9d, [LOCAL(B_ROWS)], STEP
    INVOKE ui_hover, [LOCAL(B_X)], [LOCAL(B_Y)], BOOK_W, r9
    test eax, eax
    jz .scrolled
    mov ecx, [rel g_book_scroll]
    cmp dword [rel g_mouse_wheel], 0
    jg .up
    inc ecx
    jmp .clamp
.up:
    dec ecx
.clamp:
    mov eax, [rel g_book_n]
    add eax, BOOK_COLS - 1
    xor edx, edx
    mov r8d, BOOK_COLS
    div r8d
    sub eax, [LOCAL(B_ROWS)]
    cmp ecx, eax
    jle .c1
    mov ecx, eax
.c1:
    test ecx, ecx
    jns .c2
    xor ecx, ecx
.c2:
    mov [rel g_book_scroll], ecx
.scrolled:
    ; (the list may have shrunk under the scroll)
    mov eax, [rel g_book_scroll]
    imul eax, eax, BOOK_COLS
    cmp eax, [rel g_book_n]
    jb .list
    mov dword [rel g_book_scroll], 0
.list:
    imul ebx, [rel g_book_scroll], BOOK_COLS
    xor r12d, r12d                      ; cell
.cell:
    imul eax, [LOCAL(B_ROWS)], BOOK_COLS
    cmp r12d, eax
    jae .done
    cmp ebx, [rel g_book_n]
    jae .done
    lea rax, [rel g_book]
    movzx esi, word [rax + rbx * 2]     ; recipe
    mov eax, r12d
    xor edx, edx
    mov ecx, BOOK_COLS
    div ecx
    imul ecx, edx, STEP
    add ecx, [LOCAL(B_X)]
    imul edx, eax, STEP
    add edx, [LOCAL(B_Y)]
    lea rax, [rel g_rec_result]
    movzx r8d, word [rax + rsi * 2]
    lea rax, [rel g_rec_amount]
    movzx r9d, byte [rax + rsi]
    mov qword [rsp + 32], 0
    call draw_slot
    test eax, eax
    jz .cell_next
    call click_buttons
    cmp eax, -1
    je .cell_next
    and eax, INVB_SHIFT
    mov [rsp + 32], rax
    INVOKE send, PKT_C_RECIPE, rsi, 0, 0
.cell_next:
    inc ebx
    inc r12d
    jmp .cell
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; inv_screen_frame — draw the screen and handle it.
;   in:  ecx = width, edx = height (pixels)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define F_W     0
%define F_H     4
%define F_IX    8                       ; player slots left / top
%define F_IY    12
%define F_GRID  16
%define F_ROWS  20                      ; a container's rows (0: none)
PROC inv_screen_frame, 24, rbx, rsi, rdi, r12
    mov [LOCAL(F_W)], ecx
    mov [LOCAL(F_H)], edx
    call ui_frame
    mov dword [rel g_hover_item], 0
    mov qword [rel g_tip_text], 0
    xor eax, eax
    cmp dword [rel g_world_mode], MODE_CREATIVE
    sete al
    mov [rel g_creative], eax
    ; the world dims a little behind
    mov dword [rsp + 32], 0x40000000
    mov dword [rsp + 40], 0x60000000
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov r8d, [rel g_ui_vw]
    add r8d, 16
    mov r9d, [rel g_ui_vh]
    add r9d, 16
    INVOKE ui_rect, -8, -8, r8, r9
    ; what the panel holds: the Creative catalog (E in Creative), or a
    ; crafting grid (2 x 2 by hand, a station's) with the recipe book
    mov eax, [rel g_cwin + WIN_PKT.grid]
    cmp dword [rel g_cwin + WIN_PKT.kind], WIN_CRAFTING
    je .grid
    cmp dword [rel g_creative], 0
    je .grid
    xor eax, eax                        ; (the catalog instead)
.grid:
    mov [LOCAL(F_GRID)], eax
    mov dword [LOCAL(F_ROWS)], 0
    cmp dword [rel g_cwin + WIN_PKT.kind], WIN_CHEST
    jb .not_chest
    ; a chest: its rows of 9 above the player's slots (a furnace: 3 rows'
    ; room for its slots)
    mov eax, [rel g_cwin + WIN_PKT.slots]
    add eax, INV_HOTBAR - 1
    xor edx, edx
    mov ecx, INV_HOTBAR
    div ecx
    cmp dword [rel g_cwin + WIN_PKT.kind], WIN_FURNACE
    jne .rows
    mov eax, 3
.rows:
    mov [LOCAL(F_ROWS)], eax
    mov dword [LOCAL(F_GRID)], 0
    mov dword [rel g_creative], 0
    mov eax, INV_HOTBAR * STEP - 4 + 2 * PAD
    imul ecx, [LOCAL(F_ROWS)], STEP
    add ecx, 18 + 34 + 16 + 3 * STEP + 10 + STEP - 4 + PAD
    jmp .size
.not_chest:
    cmp dword [rel g_cwin + WIN_PKT.kind], WIN_INVENTORY
    jne .not_catalog
    cmp dword [rel g_creative], 0
    jne .size_catalog
.not_catalog:
    mov dword [rel g_creative], 0       ; (from here: "the catalog is shown")
    mov eax, INV_HOTBAR * STEP - 4 + 2 * PAD + BOOK_W + BOOK_GAP
    imul ecx, [LOCAL(F_GRID)], STEP
    add ecx, 18 + 34 + 16 + 3 * STEP + 10 + STEP - 4 + PAD
    jmp .size
.size_catalog:
    mov eax, CAT_COLS * STEP - 4 + 2 * PAD
    mov ecx, 18 + 80 + CAT_ROWS * STEP + 16 + 3 * STEP + 10 + STEP - 4 + PAD
.size:
    mov [rel g_pw], eax
    mov [rel g_ph], ecx
    mov edx, [rel g_ui_vw]
    sub edx, eax
    sar edx, 1
    mov [rel g_px], edx
    mov edx, [rel g_ui_vh]
    sub edx, ecx
    sar edx, 1
    mov [rel g_py], edx
    INVOKE ui_panel, [rel g_px], [rel g_py], [rel g_pw], [rel g_ph]
    ; the player's slots at the bottom: centred (catalog), or right of the
    ; recipe book
    mov eax, [rel g_pw]
    sub eax, INV_HOTBAR * STEP - 4
    sar eax, 1
    add eax, [rel g_px]
    cmp dword [rel g_creative], 0
    jne .ix
    cmp dword [LOCAL(F_ROWS)], 0
    jne .ix
    mov eax, [rel g_px]
    add eax, PAD + BOOK_W + BOOK_GAP
.ix:
    mov [LOCAL(F_IX)], eax
    mov eax, [rel g_py]
    add eax, [rel g_ph]
    sub eax, PAD + STEP - 4 + 10 + 3 * STEP
    mov [LOCAL(F_IY)], eax
    cmp dword [rel g_creative], 0
    jne .creative
    ; the title, the grid and its result, the recipe book
    lea rcx, [rel s_inventory]
    cmp dword [rel g_cwin + WIN_PKT.kind], WIN_CRAFTING
    jne .title_chest
    lea rcx, [rel s_crafting]
.title_chest:
    cmp dword [LOCAL(F_ROWS)], 0
    je .title
    cmp dword [rel g_cwin + WIN_PKT.kind], WIN_FURNACE
    jne .chest_title
    ; a furnace: the name of its block
    call furnace_title
    mov rcx, rax
    jmp .title
.chest_title:
    lea rcx, [rel s_chest]
    cmp dword [LOCAL(F_ROWS)], 3
    jbe .title
    lea rcx, [rel s_large_chest]
.title:
    mov r8d, [rel g_py]
    add r8d, 18
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], UI_BOLD
    INVOKE ui_label, rcx, [LOCAL(F_IX)], r8, 24
    cmp dword [LOCAL(F_ROWS)], 0
    je .crafting
    cmp dword [rel g_cwin + WIN_PKT.kind], WIN_FURNACE
    jne .chest_slots
    mov edx, [rel g_py]
    add edx, 18 + 34
    INVOKE furnace_area, [LOCAL(F_IX)], rdx
    jmp .slots
.chest_slots:
    ; the container's slots
    xor ebx, ebx
.cslot:
    cmp ebx, [rel g_cwin + WIN_PKT.slots]
    jae .slots
    cmp ebx, INV_CONTAINER_MAX
    jae .slots
    mov eax, ebx
    xor edx, edx
    mov ecx, INV_HOTBAR
    div ecx                             ; eax = row, edx = column
    imul ecx, edx, STEP
    add ecx, [LOCAL(F_IX)]
    imul edx, eax, STEP
    add edx, [rel g_py]
    add edx, 18 + 34
    lea r8d, [ebx + INV_CONTAINER]
    call slot_at
    inc ebx
    jmp .cslot
.crafting:
    mov edx, [rel g_py]
    add edx, 18 + 34
    INVOKE craft_area, [LOCAL(F_IX)], rdx, [LOCAL(F_GRID)]
    mov ecx, [rel g_px]
    add ecx, PAD
    mov edx, [rel g_py]
    add edx, 18
    mov r8d, [rel g_ph]
    sub r8d, 18 + PAD
    call recipe_book
    jmp .slots
.creative:
    mov ecx, [rel g_px]
    add ecx, PAD
    mov edx, [rel g_py]
    add edx, 18
    call catalog
.slots:
    INVOKE player_slots, [LOCAL(F_IX)], [LOCAL(F_IY)]
    ; Creative: a click outside the panel throws away what is in hand
    cmp dword [rel g_creative], 0
    je .cursor
    cmp dword [rel g_ui_click], 0
    je .cursor
    INVOKE ui_hover, [rel g_px], [rel g_py], [rel g_pw], [rel g_ph]
    test eax, eax
    jnz .cursor
    mov qword [rsp + 32], 0
    INVOKE send, PKT_C_CREATIVE_SET, INV_CURSOR, 0, 0
.cursor:
    ; the stack carried by the mouse
    lea rax, [rel g_cinv]
    movzx ecx, word [rax + INV_CURSOR * 8]
    test ecx, ecx
    jz .tooltip
    movzx ebx, word [rax + INV_CURSOR * 8 + 2]
    mov edx, [rel g_ui_mx]
    sub edx, 22
    mov r8d, [rel g_ui_my]
    sub r8d, 22
    mov dword [rsp + 32], 0xFFFFFFFF
    mov r9d, 44
    call ui_icon
    cmp ebx, 1
    jbe .end
    lea rcx, [rel g_count]
    mov edx, ebx
    xor r8d, r8d
    call str_append_dec
    mov edx, [rel g_ui_mx]
    add edx, 22
    mov r8d, [rel g_ui_my]
    add r8d, 2
    mov dword [rsp + 32], COL_TEXT
    mov dword [rsp + 40], COL_TEXT
    mov qword [rsp + 48], UI_RIGHT | UI_SHADOW | UI_BOLD
    lea rcx, [rel g_count]
    mov r9d, 17
    call ui_text
    jmp .end                            ; (no tooltip while carrying)
.tooltip:
    ; the name of what the mouse is over
    mov rbx, [rel g_tip_text]
    mov eax, [rel g_hover_item]
    test eax, eax
    jz .tip
    lea rcx, [rel g_item_titles]
    mov rbx, [rcx + rax * 8]
.tip:
    test rbx, rbx
    jz .end
    mov rcx, rbx
    mov edx, 18
    call ui_text_width
    lea esi, [eax + 20]                 ; box width
    mov edi, [rel g_ui_mx]
    add edi, 16
    mov r12d, [rel g_ui_my]
    sub r12d, 34
    mov qword [rsp + 32], 8
    mov dword [rsp + 40], 0xE0141010
    mov dword [rsp + 48], COL_ACCENT & 0x00FFFFFF | 0x80000000
    INVOKE ui_glass, rdi, r12, rsi, 30
    lea edx, [edi + 10]
    lea r8d, [r12d + 4]
    mov dword [rsp + 32], COL_TEXT
    mov dword [rsp + 40], COL_TEXT
    mov qword [rsp + 48], 0
    mov r9d, 18
    mov rcx, rbx
    call ui_text
.end:
    mov ecx, [LOCAL(F_W)]
    mov edx, [LOCAL(F_H)]
    call ui_end
    RETURN
ENDPROC

section .rdata
s_empty:        db 0
align 4
c_255:          dd 255.0
c_28:           dd 28.0
c_arrow:        dd 76.0                 ; 2 * STEP - 28
s_arrow:        db ">", 0
section .bss
alignb 8
g_tip_text:     resq 1                  ; a tooltip that is not an item (tabs)
g_close:        resb WIN_PKT_size
alignb 4
g_slot_wear:    resd 1                  ; draw_slot: the next slot's wear
