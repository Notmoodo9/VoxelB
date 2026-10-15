; =============================================================================
; hud.asm — the in-game HUD (milestone 16; the menus' look since milestone
; 17): a crosshair in the middle and the hotbar at the bottom (milestone 18):
; nine parchment pockets on a stitched leather strip (the journal look,
; milestone 18 part 5), the slot in hand framed in brass, stack counts, and
; the name of the item in hand on a parchment slip for a moment when it
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
extern ui_text_width, ui_icon, timer_elapsed_us, ui_wear_bar, ui_skin
extern g_ui_vw, g_ui_vh, g_cinv, g_csel, g_item_titles
extern g_csv, g_csv_have, g_cl_hurt_flash, g_frame_us

%define CROSS_ARM       10              ; half length (units)
%define SLOT            50              ; hotbar slot (units)
%define GAP             4
%define PAD             12
%define BAR_W           (INV_HOTBAR * SLOT + (INV_HOTBAR - 1) * GAP + 2 * PAD)
%define BAR_H           (SLOT + 2 * PAD)
%define BAR_BOTTOM      14              ; gap under the bar
%define ICON            40
%define NAME_SIZE       20
%define NAME_SHOW_US    1600000         ; the name stays this long, then fades
%define NAME_FADE_US    400000
%define ROW_ICON        18              ; a heart / food icon (9 atlas pixels x 2)
%define ICON_STEP       17              ; icon to icon
%define ROW_H           20

section .rdata
align 4
c_flash_rate:   dd 0.000003             ; the flash fades out in 1/3 s (per microsecond)
c_flash_alpha:  dd 120.0
%define FLASH_RGB       0x001018B0      ; deep red, no alpha (ABGR)

section .bss
alignb 8
g_name_since:   resq 1                  ; when the item in hand changed (us)
g_name_item:    resd 1                  ; the item it changed to
g_name_slot:    resd 1
g_count_text:   resb 16
g_rows_h:       resd 1                  ; units the survival rows take above the strip

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
    ; a stitched leather strip with parchment pockets (the journal look,
    ; design/ui/journal_ui.md)
    mov dword [rsp + 48], 0x60000000
    mov qword [rsp + 40], 12
    mov qword [rsp + 32], 6
    mov edx, [LOCAL(H_Y0)]
    add edx, 4
    INVOKE ui_glow, [LOCAL(H_X0)], rdx, BAR_W, BAR_H
    mov dword [rsp + 40], 0xFFFFFFFF
    mov qword [rsp + 32], SKIN_STRIP
    INVOKE ui_skin, [LOCAL(H_X0)], [LOCAL(H_Y0)], BAR_W, BAR_H
    xor ebx, ebx
.slot:
    cmp ebx, INV_HOTBAR
    jae .name_pre
    imul r14d, ebx, SLOT + GAP
    add r14d, [LOCAL(H_X0)]
    add r14d, PAD                       ; slot left
    mov r13d, [LOCAL(H_Y0)]
    add r13d, PAD                       ; slot top
    ; a parchment pocket; the one in hand framed in brass with a warm glow
    mov dword [rsp + 40], 0xFFFFFFFF
    mov qword [rsp + 32], SKIN_STRIP_SLOT
    INVOKE ui_skin, r14, r13, SLOT, SLOT
    cmp ebx, [rel g_csel]
    jne .icon
    mov dword [rsp + 48], COL_BRASS & 0x00FFFFFF | 0xA0000000
    mov qword [rsp + 40], 10
    mov qword [rsp + 32], 4
    lea ecx, [r14d - 3]
    lea edx, [r13d - 3]
    INVOKE ui_glow, rcx, rdx, SLOT + 6, SLOT + 6
    mov dword [rsp + 32], 0
    mov dword [rsp + 40], COL_BRASS
    mov qword [rsp + 48], 4
    mov qword [rsp + 56], 4
    lea ecx, [r14d - 3]
    lea edx, [r13d - 3]
    INVOKE ui_rect, rcx, rdx, SLOT + 6, SLOT + 6
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
    mov dword [rsp + 32], COL_LIGHT
    mov dword [rsp + 40], COL_LIGHT
    mov qword [rsp + 48], UI_RIGHT | UI_SHADOW | UI_BOLD
    lea rcx, [rel g_count_text]
    mov r9d, 17
    call ui_text
.next:
    inc ebx
    jmp .slot

    ; ---- the off hand: its own pocket left of the strip ----
.name_pre:
    mov ecx, [LOCAL(H_X0)]
    sub ecx, SLOT + 2 * PAD + 10
    mov edx, [LOCAL(H_Y0)]
    call off_pocket
    ; ---- health, hunger and air above the strip (milestone 20) ----
    mov ecx, [LOCAL(H_X0)]
    mov edx, [LOCAL(H_Y0)]
    call survival_rows
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
    sub edx, [rel g_rows_h]             ; (above the hearts and food)
    mov eax, r14d
    shl eax, 24
    or eax, 0x00FFFFFF
    mov [rsp + 40], rax
    mov qword [rsp + 32], SKIN_TIP
    INVOKE ui_skin, rcx, rdx, r8, 34
    mov r8d, [LOCAL(H_Y0)]
    sub r8d, 44 - 5
    sub r8d, [rel g_rows_h]
    mov eax, r14d
    shl eax, 24
    or eax, COL_INK & 0x00FFFFFF
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

; -----------------------------------------------------------------------------
; survival_rows — ten hearts left and ten food icons right just above the
; strip at (ecx, edx), air bubbles over the food while under water, and
; the red flash after a hit (milestone 20, design/survival/survival.md),
; and a row of ten shields over the hearts while armor is worn (milestone
; 21: one shield = 2 protection points, so 20 points fill the row).
; Hearts shake when health is low, food icons jitter while starving and
; turn green with food poisoning. Nothing in Creative or Spectator.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define R_X0    0
%define R_Y     4
%define R_I     8
%define R_TICK  12
%define R_PIECE 16
%define R_X     20
%define R_BUBBLES 24
PROC survival_rows, 32, rbx, rsi, rdi
    mov dword [rel g_rows_h], 0
    cmp dword [rel g_csv_have], 0
    je .done
    test word [rel g_csv + SURV_PKT.flags], SVF_ACTIVE
    jz .flash
    mov dword [rel g_rows_h], ROW_H + 6
    mov [LOCAL(R_X0)], ecx
    sub edx, ROW_H + 4
    mov [LOCAL(R_Y)], edx
    ; a jitter clock: 12 steps a second
    call timer_elapsed_us
    xor edx, edx
    mov ecx, 83333
    div rcx
    mov [LOCAL(R_TICK)], eax
    ; ---- hearts, left to right ----
    mov dword [LOCAL(R_I)], 0
.heart:
    mov esi, [LOCAL(R_I)]
    cmp esi, 10
    jae .food_row
    movzx eax, word [rel g_csv + SURV_PKT.health]
    lea ecx, [esi * 2]
    mov ebx, SKIN_HEART_EMPTY
    cmp eax, ecx
    jle .heart_piece
    mov ebx, SKIN_HEART_HALF
    inc ecx
    cmp eax, ecx
    je .heart_piece
    mov ebx, SKIN_HEART
.heart_piece:
    imul edi, esi, ICON_STEP
    add edi, [LOCAL(R_X0)]
    add edi, PAD
    mov edx, [LOCAL(R_Y)]
    ; low health (2 hearts or less): they shake
    cmp word [rel g_csv + SURV_PKT.health], 4
    ja .heart_draw
    mov eax, [LOCAL(R_TICK)]
    imul ecx, esi, 7
    add eax, ecx
    xor ecx, ecx
    test eax, 1
    jz .shake_dn
    mov ecx, -2
    test eax, 2
    jz .shake_dn
    mov ecx, 2
.shake_dn:
    add edx, ecx
.heart_draw:
    mov dword [rsp + 40], 0xFFFFFFFF
    mov [rsp + 32], rbx
    INVOKE ui_skin, rdi, rdx, ROW_ICON, ROW_ICON
    inc dword [LOCAL(R_I)]
    jmp .heart
.food_row:
    ; ---- armor (milestone 21): ten shields over the hearts while worn ----
    movzx eax, word [rel g_csv + SURV_PKT.armor]
    test eax, eax
    jz .food_start
    add dword [rel g_rows_h], ROW_H
    mov dword [LOCAL(R_I)], 0
.shield:
    mov esi, [LOCAL(R_I)]
    cmp esi, 10
    jae .food_start
    ; 2 points a shield: armor is in half points, so 4 per icon
    movzx eax, word [rel g_csv + SURV_PKT.armor]
    lea ecx, [esi * 4]
    mov ebx, SKIN_ARMOR_EMPTY
    cmp eax, ecx
    jle .shield_draw
    mov ebx, SKIN_ARMOR_HALF
    add ecx, 2
    cmp eax, ecx
    jle .shield_draw
    mov ebx, SKIN_ARMOR
.shield_draw:
    imul edi, esi, ICON_STEP
    add edi, [LOCAL(R_X0)]
    add edi, PAD
    mov edx, [LOCAL(R_Y)]
    sub edx, ROW_H
    mov dword [rsp + 40], 0xFFFFFFFF
    mov [rsp + 32], rbx
    INVOKE ui_skin, rdi, rdx, ROW_ICON, ROW_ICON
    inc dword [LOCAL(R_I)]
    jmp .shield
.food_start:
    ; ---- food, right to left ----
    mov dword [LOCAL(R_I)], 0
.food:
    mov esi, [LOCAL(R_I)]
    cmp esi, 10
    jae .air_row
    movzx eax, word [rel g_csv + SURV_PKT.hunger]
    lea ecx, [esi * 2]
    mov ebx, SKIN_FOOD_EMPTY
    cmp eax, ecx
    jle .food_piece
    mov ebx, SKIN_FOOD_HALF
    inc ecx
    cmp eax, ecx
    je .food_full
    mov ebx, SKIN_FOOD
.food_full:
    test word [rel g_csv + SURV_PKT.flags], SVF_POISON
    jz .food_piece
    add ebx, SKIN_FOOD_SICK - SKIN_FOOD   ; (green: food poisoning)
.food_piece:
    mov edi, [LOCAL(R_X0)]
    add edi, BAR_W - PAD - ROW_ICON
    imul eax, esi, ICON_STEP
    sub edi, eax
    mov [LOCAL(R_X)], edi
    mov edx, [LOCAL(R_Y)]
    ; no saturation left and hungry: they jitter
    movss xmm0, [rel g_csv + SURV_PKT.sat]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    ja .food_draw
    cmp word [rel g_csv + SURV_PKT.hunger], 6
    ja .food_draw
    mov eax, [LOCAL(R_TICK)]
    imul ecx, esi, 5
    add eax, ecx
    and eax, 3
    cmp eax, 1
    jne .food_draw
    sub edx, 2
.food_draw:
    mov dword [rsp + 40], 0xFFFFFFFF
    mov [rsp + 32], rbx
    INVOKE ui_skin, [LOCAL(R_X)], rdx, ROW_ICON, ROW_ICON
    inc dword [LOCAL(R_I)]
    jmp .food
.air_row:
    ; ---- air bubbles while under water ----
    movzx eax, word [rel g_csv + SURV_PKT.air]
    movzx ecx, word [rel g_csv + SURV_PKT.air_max]
    test ecx, ecx
    jz .flash
    cmp eax, ecx
    jge .flash
    ; bubbles = ceil(air * 10 / max); the next one shown popping
    imul eax, eax, 10
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    mov [LOCAL(R_BUBBLES)], eax
    mov dword [LOCAL(R_I)], 0
.bubble:
    mov esi, [LOCAL(R_I)]
    cmp esi, 10
    jae .flash
    mov ebx, SKIN_BUBBLE
    cmp esi, [LOCAL(R_BUBBLES)]
    jb .bubble_draw
    jne .flash
    mov ebx, SKIN_BUBBLE_POP
.bubble_draw:
    mov edi, [LOCAL(R_X0)]
    add edi, BAR_W - PAD - ROW_ICON
    imul eax, esi, ICON_STEP
    sub edi, eax
    mov edx, [LOCAL(R_Y)]
    sub edx, ROW_H
    mov dword [rsp + 40], 0xFFFFFFFF
    mov [rsp + 32], rbx
    INVOKE ui_skin, rdi, rdx, ROW_ICON, ROW_ICON
    inc dword [LOCAL(R_I)]
    jmp .bubble
.flash:
    ; ---- the red flash after a hit, fading over a third of a second ----
    movss xmm0, [rel g_cl_hurt_flash]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .done
    mov rax, [rel g_frame_us]
    cvtsi2ss xmm1, rax
    mulss xmm1, [rel c_flash_rate]
    subss xmm0, xmm1
    xorps xmm1, xmm1
    maxss xmm0, xmm1
    movss [rel g_cl_hurt_flash], xmm0
    ; red at the top and bottom edges, clear toward the middle
    mulss xmm0, [rel c_flash_alpha]
    cvttss2si ebx, xmm0
    shl ebx, 24
    or ebx, FLASH_RGB                   ; (ABGR)
    mov dword [rsp + 32], ebx
    mov dword [rsp + 40], FLASH_RGB
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov r8d, [rel g_ui_vw]
    add r8d, 16
    mov r9d, [rel g_ui_vh]
    shr r9d, 2
    INVOKE ui_rect, -8, -8, r8, r9
    mov dword [rsp + 32], FLASH_RGB
    mov dword [rsp + 40], ebx
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov r8d, [rel g_ui_vw]
    add r8d, 16
    mov r9d, [rel g_ui_vh]
    shr r9d, 2
    mov edx, [rel g_ui_vh]
    sub edx, r9d
    add edx, 8
    INVOKE ui_rect, -8, rdx, r8, r9
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; off_pocket — the off hand's slot on a small leather piece at ecx, edx
; (the strip's height): its item, durability bar and count.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC off_pocket, 0, rbx, rsi, rdi
    mov ebx, ecx
    mov esi, edx
    mov dword [rsp + 48], 0x60000000
    mov qword [rsp + 40], 12
    mov qword [rsp + 32], 6
    lea edx, [esi + 4]
    INVOKE ui_glow, rbx, rdx, SLOT + 2 * PAD, BAR_H
    mov dword [rsp + 40], 0xFFFFFFFF
    mov qword [rsp + 32], SKIN_STRIP
    INVOKE ui_skin, rbx, rsi, SLOT + 2 * PAD, BAR_H
    add ebx, PAD
    add esi, PAD
    mov dword [rsp + 40], 0xFFFFFFFF
    mov qword [rsp + 32], SKIN_STRIP_SLOT
    INVOKE ui_skin, rbx, rsi, SLOT, SLOT
    lea rax, [rel g_cinv]
    movzx ecx, word [rax + INV_OFFHAND * 8]
    test ecx, ecx
    jz .done
    mov edi, ecx
    mov dword [rsp + 32], 0xFFFFFFFF
    lea edx, [ebx + (SLOT - ICON) / 2]
    lea r8d, [esi + (SLOT - ICON) / 2]
    mov r9d, ICON
    call ui_icon
    lea rax, [rel g_cinv]
    movzx ecx, word [rax + INV_OFFHAND * 8 + 4]
    mov [rsp + 32], rcx
    mov r9d, edi
    lea ecx, [ebx + 6]
    lea edx, [esi + SLOT - 9]
    mov r8d, SLOT - 12
    call ui_wear_bar
    lea rax, [rel g_cinv]
    movzx edx, word [rax + INV_OFFHAND * 8 + 2]
    cmp edx, 1
    jbe .done
    lea rcx, [rel g_count_text]
    xor r8d, r8d
    call str_append_dec
    lea edx, [ebx + SLOT - 4]
    lea r8d, [esi + SLOT - 22]
    mov dword [rsp + 32], COL_LIGHT
    mov dword [rsp + 40], COL_LIGHT
    mov qword [rsp + 48], UI_RIGHT | UI_SHADOW | UI_BOLD
    lea rcx, [rel g_count_text]
    mov r9d, 17
    call ui_text
.done:
    RETURN
ENDPROC
