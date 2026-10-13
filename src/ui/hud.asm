; =============================================================================
; hud.asm — the in-game HUD (milestone 16; the menus' look since milestone
; 17): a crosshair in the middle and the hotbar at the bottom (milestone 18):
; nine slots on a glass strip, the slot in hand outlined in teal, stack
; counts, and the name of the item in hand shown for a moment when it
; changes. Health and hunger come with survival (milestone 20).
;
; Public API:
;   hud_draw(ecx = framebuffer width, edx = height)
; =============================================================================
%include "macros.inc"
%include "ui.inc"
%include "packet.inc"

global hud_draw

extern ui_draw_begin, ui_draw_flush, ui_rect, ui_glass, ui_glow, ui_text
extern ui_text_width, ui_icon, timer_elapsed_us, ui_wear_bar
extern g_ui_vw, g_ui_vh, g_cinv, g_csel, g_item_titles

%define CROSS_ARM       10              ; half length (units)
%define SLOT            50              ; hotbar slot (units)
%define GAP             4
%define PAD             8
%define BAR_W           (INV_HOTBAR * SLOT + (INV_HOTBAR - 1) * GAP + 2 * PAD)
%define BAR_H           (SLOT + 2 * PAD)
%define BAR_BOTTOM      14              ; gap under the bar
%define ICON            40
%define NAME_SIZE       20
%define NAME_SHOW_US    1600000         ; the name stays this long, then fades
%define NAME_FADE_US    400000

section .bss
alignb 8
g_name_since:   resq 1                  ; when the item in hand changed (us)
g_name_item:    resd 1                  ; the item it changed to
g_name_slot:    resd 1
g_count_text:   resb 16

section .text

; -----------------------------------------------------------------------------
; hud_draw — draw the HUD over the frame.
;   in:  ecx = framebuffer width, edx = framebuffer height
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define H_X0        0                   ; bar left
%define H_Y0        4                   ; bar top
%define H_NOW       8
PROC hud_draw, 32, rbx, rsi, rdi, r12, r13, r14
    mov esi, ecx
    mov edi, edx
    call ui_draw_begin
    mov r12d, [rel g_ui_vw]
    shr r12d, 1                         ; centre x
    mov r13d, [rel g_ui_vh]
    shr r13d, 1                         ; centre y
    ; crosshair: a soft dark outline, then the white cross
%macro CROSS 5                          ; dx, dy, w, h, colour
    mov dword [rsp + 32], %5
    mov dword [rsp + 40], %5
    mov qword [rsp + 48], 1
    mov qword [rsp + 56], 0
    lea ecx, [r12d + %1]
    lea edx, [r13d + %2]
    INVOKE ui_rect, rcx, rdx, %3, %4
%endmacro
    CROSS -(CROSS_ARM + 1), -2, 2 * CROSS_ARM + 2, 4, 0x80000000
    CROSS -2, -(CROSS_ARM + 1), 4, 2 * CROSS_ARM + 2, 0x80000000
    CROSS -CROSS_ARM, -1, 2 * CROSS_ARM, 2, 0xE8FFFFFF
    CROSS -1, -CROSS_ARM, 2, 2 * CROSS_ARM, 0xE8FFFFFF

    ; ---- the hotbar ----
    mov eax, r12d
    sub eax, BAR_W / 2
    mov [LOCAL(H_X0)], eax
    mov eax, [rel g_ui_vh]
    sub eax, BAR_H + BAR_BOTTOM
    mov [LOCAL(H_Y0)], eax
    mov qword [rsp + 32], 14
    mov dword [rsp + 40], COL_GLASS
    mov dword [rsp + 48], COL_GLASS_EDGE
    INVOKE ui_glass, [LOCAL(H_X0)], [LOCAL(H_Y0)], BAR_W, BAR_H
    xor ebx, ebx
.slot:
    cmp ebx, INV_HOTBAR
    jae .name
    imul r14d, ebx, SLOT + GAP
    add r14d, [LOCAL(H_X0)]
    add r14d, PAD                       ; slot left
    mov r13d, [LOCAL(H_Y0)]
    add r13d, PAD                       ; slot top
    ; the slot: dark, or teal-outlined and glowing when in hand
    cmp ebx, [rel g_csel]
    jne .plain
    mov dword [rsp + 48], COL_ACCENT & 0x00FFFFFF | 0x90000000
    mov qword [rsp + 40], 14
    mov qword [rsp + 32], 10
    INVOKE ui_glow, r14, r13, SLOT, SLOT
    mov dword [rsp + 32], COL_ACCENT2 & 0x00FFFFFF | 0x60000000
    mov dword [rsp + 40], COL_ACCENT
    mov qword [rsp + 48], 10
    mov qword [rsp + 56], 3
    INVOKE ui_rect, r14, r13, SLOT, SLOT
    jmp .icon
.plain:
    mov dword [rsp + 32], 0x50000000
    mov dword [rsp + 40], 0x28FFFFFF
    mov qword [rsp + 48], 10
    mov qword [rsp + 56], 1
    INVOKE ui_rect, r14, r13, SLOT, SLOT
.icon:
    lea rax, [rel g_cinv]
    movzx ecx, word [rax + rbx * 8]
    test ecx, ecx
    jz .next
    mov dword [rsp + 32], 0xFFFFFFFF
    lea edx, [r14d + (SLOT - ICON) / 2]
    lea r8d, [r13d + (SLOT - ICON) / 2]
    mov r9d, ICON
    call ui_icon
    ; a worn tool's durability bar
    lea rax, [rel g_cinv]
    movzx ecx, word [rax + rbx * 8 + 4]
    mov [rsp + 32], rcx
    movzx r9d, word [rax + rbx * 8]
    lea ecx, [r14d + 6]
    lea edx, [r13d + SLOT - 9]
    mov r8d, SLOT - 12
    call ui_wear_bar
    ; the count, when more than one
    lea rax, [rel g_cinv]
    movzx edx, word [rax + rbx * 8 + 2]
    cmp edx, 1
    jbe .next
    lea rcx, [rel g_count_text]
    xor r8d, r8d
    call str_append_dec
    lea edx, [r14d + SLOT - 4]
    lea r8d, [r13d + SLOT - 22]
    mov dword [rsp + 32], COL_TEXT
    mov dword [rsp + 40], COL_TEXT
    mov qword [rsp + 48], UI_RIGHT | UI_SHADOW | UI_BOLD
    lea rcx, [rel g_count_text]
    mov r9d, 17
    call ui_text
.next:
    inc ebx
    jmp .slot

    ; ---- the name of the item in hand, for a moment after it changes ----
.name:
    call timer_elapsed_us
    mov [LOCAL(H_NOW)], rax
    mov ecx, [rel g_csel]
    lea rax, [rel g_cinv]
    movzx edx, word [rax + rcx * 8]
    cmp edx, [rel g_name_item]
    jne .changed
    cmp ecx, [rel g_name_slot]
    je .show
.changed:
    mov [rel g_name_item], edx
    mov [rel g_name_slot], ecx
    mov rax, [LOCAL(H_NOW)]
    mov [rel g_name_since], rax
.show:
    mov ebx, [rel g_name_item]
    test ebx, ebx
    jz .flush
    mov rax, [LOCAL(H_NOW)]
    sub rax, [rel g_name_since]
    cmp rax, NAME_SHOW_US + NAME_FADE_US
    jae .flush
    ; alpha: 255, fading to 0 over the last NAME_FADE_US
    mov ecx, 255
    sub rax, NAME_SHOW_US
    jle .alpha
    imul rax, rax, 255
    xor edx, edx
    mov r8d, NAME_FADE_US
    div r8
    sub ecx, eax
.alpha:
    mov r14d, ecx                       ; 0..255
    lea rax, [rel g_item_titles]
    mov rbx, [rax + rbx * 8]
    mov rcx, rbx
    mov edx, NAME_SIZE
    call ui_text_width
    lea r8d, [eax + 32]                 ; pill width
    mov ecx, r12d
    mov eax, r8d
    shr eax, 1
    sub ecx, eax
    mov edx, [LOCAL(H_Y0)]
    sub edx, 44
    mov eax, r14d
    imul eax, 0x8C
    shr eax, 8
    shl eax, 24
    or eax, COL_GLASS & 0x00FFFFFF
    mov [rsp + 40], rax
    mov eax, r14d
    imul eax, 0x50
    shr eax, 8
    shl eax, 24
    or eax, 0x00FFFFFF
    mov [rsp + 48], rax
    mov qword [rsp + 32], 17
    INVOKE ui_glass, rcx, rdx, r8, 34
    mov r8d, [LOCAL(H_Y0)]
    sub r8d, 44 - 5
    mov eax, r14d
    shl eax, 24
    or eax, COL_TEXT & 0x00FFFFFF
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov qword [rsp + 48], UI_CENTER
    INVOKE ui_text, rbx, r12, r8, NAME_SIZE
.flush:
    mov ecx, esi
    mov edx, edi
    call ui_draw_flush
    RETURN
ENDPROC

extern str_append_dec
