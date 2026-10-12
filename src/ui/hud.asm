; =============================================================================
; hud.asm — the in-game HUD (milestone 16; the menus' look since milestone
; 17): a crosshair in the middle of the screen and the held block's name on
; a small glass pill at the bottom. The real HUD (health, hunger, hotbar)
; comes with items and survival (milestones 18, 20).
;
; Public API:
;   hud_draw(ecx = framebuffer width, edx = height)
; =============================================================================
%include "macros.inc"
%include "ui.inc"

global hud_draw

extern ui_draw_begin, ui_draw_flush, ui_rect, ui_glass, ui_text, ui_text_width
extern g_ui_vw, g_ui_vh, g_held_block, g_block_names

%define CROSS_ARM       10              ; half length (units)
%define NAME_SIZE       20
%define NAME_BOTTOM     56              ; the pill's top: this far above the bottom

section .text

; -----------------------------------------------------------------------------
; hud_draw — draw the HUD over the frame.
;   in:  ecx = framebuffer width, edx = framebuffer height
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC hud_draw, 16, rbx, rsi, rdi, r12, r13
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

    ; the held block's name on a glass pill
    mov eax, [rel g_held_block]
    lea rcx, [rel g_block_names]
    mov rbx, [rcx + rax * 8]
    test rbx, rbx
    jz .flush
    mov rcx, rbx
    mov edx, NAME_SIZE
    call ui_text_width
    lea r8d, [eax + 32]                 ; pill width
    mov ecx, r12d
    mov eax, r8d
    shr eax, 1
    sub ecx, eax
    mov edx, [rel g_ui_vh]
    sub edx, NAME_BOTTOM
    mov qword [rsp + 32], 17
    mov dword [rsp + 40], COL_GLASS
    mov dword [rsp + 48], COL_GLASS_EDGE
    INVOKE ui_glass, rcx, rdx, r8, 34
    mov r8d, [rel g_ui_vh]
    sub r8d, NAME_BOTTOM - 5
    mov dword [rsp + 32], COL_TEXT
    mov dword [rsp + 40], COL_TEXT
    mov qword [rsp + 48], UI_CENTER
    INVOKE ui_text, rbx, r12, r8, NAME_SIZE
.flush:
    mov ecx, esi
    mov edx, edi
    call ui_draw_flush
    RETURN
ENDPROC
