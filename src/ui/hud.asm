; =============================================================================
; hud.asm — the in-game HUD (milestone 16): a crosshair in the middle of the
; screen and the name of the held block at the bottom. The real HUD (health,
; hunger, hotbar) comes with items and survival (milestones 18, 20).
;
; Public API:
;   hud_draw(ecx = framebuffer width, edx = height)   uses the text batch
; =============================================================================
%include "macros.inc"
%include "text.inc"

global hud_draw

extern g_held_block, g_block_names, str_len

%define COLOR_CROSS     0xD0FFFFFF      ; 0xAABBGGRR
%define COLOR_SHADOW    0x90000000
%define COLOR_NAME      0xFFFFFFFF
%define COLOR_PANEL     0x90101010
%define CROSS_ARM       9               ; half length (unscaled pixels)
%define NAME_BOTTOM     40              ; name: this far above the bottom
%define PAD             4

section .text

; -----------------------------------------------------------------------------
; hud_draw — draw the HUD over the frame.
;   in:  ecx = framebuffer width, edx = framebuffer height
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC hud_draw, 16, rbx, rsi, rdi, r12, r13
    mov esi, ecx
    mov edi, edx
    ; pixel scale like the debug overlay: 1 below 1000 px tall, then 2, ...
    mov eax, edi
    xor edx, edx
    mov ecx, 1000
    div ecx
    inc eax
    mov [rel g_text_scale], eax
    mov r12d, eax
    call text_begin

    ; crosshair: a dark outline, then the white cross
    mov r13d, esi
    shr r13d, 1                         ; centre x
    mov ebx, edi
    shr ebx, 1                          ; centre y
%macro CROSS_RECT 5                     ; x0, y0 offsets, w, h (unscaled), colour
    imul ecx, r12d, %1
    add ecx, r13d
    imul edx, r12d, %2
    add edx, ebx
    imul r8d, r12d, %3
    imul r9d, r12d, %4
    mov dword [rsp + 32], %5
    call text_rect
%endmacro
    CROSS_RECT -(CROSS_ARM + 1), -2, 2 * CROSS_ARM + 2, 4, COLOR_SHADOW
    CROSS_RECT -2, -(CROSS_ARM + 1), 4, 2 * CROSS_ARM + 2, COLOR_SHADOW
    CROSS_RECT -CROSS_ARM, -1, 2 * CROSS_ARM, 2, COLOR_CROSS
    CROSS_RECT -1, -CROSS_ARM, 2, 2 * CROSS_ARM, COLOR_CROSS

    ; the held block's name, centred near the bottom on a dark panel
    mov eax, [rel g_held_block]
    lea rcx, [rel g_block_names]
    mov rbx, [rcx + rax * 8]
    test rbx, rbx
    jz .flush
    mov rcx, rbx
    call str_len
    imul eax, [rel g_font_cell_w]
    imul eax, r12d                      ; text width
    mov [LOCAL(0)], eax
    mov ecx, esi
    sub ecx, eax
    sar ecx, 1                          ; text x
    mov [LOCAL(4)], ecx
    imul edx, r12d, NAME_BOTTOM
    mov eax, edi
    sub eax, edx                        ; text y
    mov [LOCAL(8)], eax
    ; panel
    imul eax, r12d, PAD
    sub ecx, eax
    mov edx, [LOCAL(8)]
    sub edx, eax
    mov r8d, [LOCAL(0)]
    lea r8d, [r8d + eax * 2]
    mov r9d, [rel g_font_cell_h]
    imul r9d, r12d
    lea r9d, [r9d + eax * 2]
    mov dword [rsp + 32], COLOR_PANEL
    call text_rect
    mov edx, [LOCAL(4)]
    mov r8d, [LOCAL(8)]
    INVOKE text_add, rbx, rdx, r8, COLOR_NAME
.flush:
    INVOKE text_flush, rsi, rdi
    RETURN
ENDPROC
