; =============================================================================
; ui.asm — immediate-mode widgets for the menus (milestone 17,
; design/ui/menus.md): each frame a screen calls the widget functions, which
; draw themselves (ui_draw.asm) and report clicks. Widgets have a small id
; (0..UI_IDS-1) that keeps their hover animation between frames.
;
; Public API (units: the 1280 x 720 design canvas, see ui_draw.asm):
;   ui_frame(ecx = w, edx = h)          start a UI frame (mouse, timing)
;   ui_end(ecx = w, edx = h)            draw it
;   ui_button(id, x, y, w, h, label, flags) -> eax 1 if clicked
;       flags: UIW_DISABLED, UIW_SELECTED, UIW_PRIMARY
;   ui_panel(x, y, w, h)                a glass panel with a soft shadow
;   ui_label(str, x, y, size, color, flags) -> eax width (text with shadow)
;   ui_hover(x, y, w, h) -> eax 1 if the mouse is over it
;   ui_textfield(id, x, y, w, h, buf, cap, placeholder) -> eax 1 if the text
;       changed, 2 if Enter was pressed in it (a click focuses it; typed
;       characters and Backspace edit it while it has the focus)
;   ui_focus(ecx = id + 1, 0 = none)    give a text field the keyboard
;   g_ui_mx, g_ui_my (units), g_ui_click (left button went down this
;   frame), g_ui_dt (f32 seconds), g_ui_time (f32 seconds, for effects)
; =============================================================================
%include "macros.inc"
%include "input.inc"
%include "ui.inc"

global ui_frame, ui_end, ui_button, ui_panel, ui_label, ui_hover
global ui_textfield, ui_focus
global g_ui_mx, g_ui_my, g_ui_click, g_ui_dt, g_ui_time, g_ui_rclick, ui_focused

extern ui_draw_begin, ui_draw_flush, ui_rect, ui_glass, ui_glow, ui_text
extern ui_text_width, str_len
extern g_ui_scale, g_frame_us, g_mouse_captured, g_chars, g_char_count

%define UI_IDS          256
%define HOVER_RATE      12.0            ; hover animation: per second

section .rdata
align 4
c_us:           dd 0.000001
c_rate:         dd HOVER_RATE
c_one:          dd 1.0
c_max_dt:       dd 0.1
c_255:          dd 255.0

section .bss
alignb 4
g_ui_mx:        resd 1
g_ui_my:        resd 1
g_ui_click:     resd 1
g_ui_rclick:    resd 1                  ; right button went down this frame
g_ui_dt:        resd 1
g_ui_time:      resd 1
g_anim:         resd UI_IDS             ; hover 0..1 per widget id
g_focus:        resd 1                  ; text field with the keyboard: id + 1

section .text

; -----------------------------------------------------------------------------
; ui_frame — start a UI frame.
;   in:  ecx = width, edx = height (pixels)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_frame, 0
    call ui_draw_begin
    ; mouse in units (only meaningful with the cursor free)
    cvtsi2ss xmm0, dword [rel g_mouse_x]
    divss xmm0, [rel g_ui_scale]
    cvttss2si eax, xmm0
    mov [rel g_ui_mx], eax
    cvtsi2ss xmm0, dword [rel g_mouse_y]
    divss xmm0, [rel g_ui_scale]
    cvttss2si eax, xmm0
    mov [rel g_ui_my], eax
    mov dword [rel g_ui_click], 0
    mov dword [rel g_ui_rclick], 0
    cmp dword [rel g_mouse_captured], 0
    jne .no_click
    mov ecx, VK_LBUTTON
    call input_vk_pressed
    mov [rel g_ui_click], eax
    mov ecx, VK_RBUTTON
    call input_vk_pressed
    mov [rel g_ui_rclick], eax
.no_click:
    mov rax, [rel g_frame_us]
    cvtsi2ss xmm0, rax
    mulss xmm0, [rel c_us]
    minss xmm0, [rel c_max_dt]
    movss [rel g_ui_dt], xmm0
    addss xmm0, [rel g_ui_time]
    movss [rel g_ui_time], xmm0
    RETURN
ENDPROC

; ui_end — draw the frame's widgets.  in: ecx = w, edx = h
PROC ui_end, 0
    call ui_draw_flush
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_hover — is the mouse over a rectangle (units)?
;   in:  ecx = x, edx = y, r8d = w, r9d = h
;   out: eax = 1 / 0
;   clobbers: rax
; -----------------------------------------------------------------------------
ui_hover:
    xor eax, eax
    cmp dword [rel g_mouse_captured], 0
    jne .no
    push rcx
    push rdx
    mov eax, [rel g_ui_mx]
    sub eax, ecx
    jl .out
    cmp eax, r8d
    jge .out
    mov eax, [rel g_ui_my]
    sub eax, edx
    jl .out
    cmp eax, r9d
    jge .out
    pop rdx
    pop rcx
    mov eax, 1
    ret
.out:
    pop rdx
    pop rcx
    xor eax, eax
.no:
    ret

; with_alpha — eax = colour ecx with its alpha scaled by xmm0 (0..1)
;   clobbers: rdx, xmm0
with_alpha:
    mov edx, ecx
    shr edx, 24
    cvtsi2ss xmm1, edx
    mulss xmm0, xmm1
    cvttss2si edx, xmm0
    mov eax, ecx
    and eax, 0x00FFFFFF
    shl edx, 24
    or eax, edx
    ret

; -----------------------------------------------------------------------------
; ui_button — a button: glass-dark fill, a teal border that lights up and
; glows on hover, the label centred.
;   in:  ecx = id, edx = x, r8d = y, r9d = w, ARG5 = h, ARG6 = label,
;        ARG7 = flags
;   out: eax = 1 if clicked this frame
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define B_HOVER     0
%define B_ANIM      4                   ; f32
%define B_FILL      8
%define B_BORDER    12
PROC ui_button, 32, rbx, rsi, rdi, r12, r13, r14
    mov ebx, ecx                        ; id
    and ebx, UI_IDS - 1
    mov esi, edx                        ; x
    mov edi, r8d                        ; y
    mov r12d, r9d                       ; w
    mov r13d, [ARG(5)]                  ; h
    mov r14d, [ARG(7)]                  ; flags
    ; hovered?
    xor eax, eax
    test r14d, UIW_DISABLED
    jnz .hover_set
    mov ecx, esi
    mov edx, edi
    mov r8d, r12d
    mov r9d, r13d
    call ui_hover
.hover_set:
    mov [LOCAL(B_HOVER)], eax
    ; animate towards it
    lea rcx, [rel g_anim]
    movss xmm0, [rcx + rbx * 4]
    cvtsi2ss xmm1, eax
    subss xmm1, xmm0
    movss xmm2, [rel g_ui_dt]
    mulss xmm2, [rel c_rate]
    minss xmm2, [rel c_one]
    mulss xmm1, xmm2
    addss xmm0, xmm1
    movss [rcx + rbx * 4], xmm0
    movss [LOCAL(B_ANIM)], xmm0
    ; glow under it
    test r14d, UIW_DISABLED
    jnz .no_glow
    mov ecx, COL_ACCENT & 0x00FFFFFF | 0x70000000
    movss xmm0, [LOCAL(B_ANIM)]
    call with_alpha
    mov [rsp + 48], rax
    mov qword [rsp + 40], 16
    mov qword [rsp + 32], 12
    INVOKE ui_glow, rsi, rdi, r12, r13
.no_glow:
    ; fill: dark glass, or teal when primary / selected
    mov eax, COL_DANGER
    test r14d, UIW_DANGER
    jnz .fill
    mov eax, COL_BUTTON
    test r14d, UIW_PRIMARY | UIW_SELECTED
    jz .fill
    mov eax, COL_ACCENT2 & 0x00FFFFFF | 0xC0000000
    test r14d, UIW_DISABLED
    jz .fill
    mov eax, COL_ACCENT2 & 0x00FFFFFF | 0x50000000  ; (chosen, but fixed)
.fill:
    mov [LOCAL(B_FILL)], eax
    ; border: teal, brighter on hover; grey when disabled
    mov ecx, COL_ACCENT & 0x00FFFFFF | 0xFF000000
    movss xmm0, [LOCAL(B_ANIM)]
    mulss xmm0, [rel c_border_k]
    addss xmm0, [rel c_border_base]
    call with_alpha
    test r14d, UIW_DISABLED
    jz .border_ok
    mov eax, 0x30FFFFFF
.border_ok:
    mov [rsp + 56], rax                 ; border colour (color2)
    mov qword [rsp + 64], 10            ; radius
    mov qword [rsp + 72], 2             ; border width
    mov eax, [LOCAL(B_FILL)]
    mov [rsp + 48], rax
    ; (ui_rect's args 5..8 sit at [rsp+32..56]: shift into place)
    mov rax, [rsp + 48]
    mov [rsp + 32], rax                 ; color
    mov rax, [rsp + 56]
    mov [rsp + 40], rax                 ; color2 (border)
    mov rax, [rsp + 64]
    mov [rsp + 48], rax                 ; radius
    mov rax, [rsp + 72]
    mov [rsp + 56], rax                 ; border
    mov ecx, esi
    mov edx, edi
    mov r8d, r12d
    mov r9d, r13d
    call ui_rect
    ; label: centred, a little lighter with the hover
    mov eax, COL_TEXT
    test r14d, UIW_DISABLED
    jz .label_col
    mov eax, COL_TEXT_OFF
.label_col:
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov qword [rsp + 48], UI_CENTER | UI_SHADOW
    mov eax, r12d
    shr eax, 1
    lea edx, [esi + eax]                ; centre x
    mov eax, r13d
    sub eax, 24
    sar eax, 1
    lea r8d, [edi + eax - 2]            ; text top: centred for size 22
    mov rcx, [ARG(6)]
    mov r9d, 22
    call ui_text
    ; clicked?
    xor eax, eax
    cmp dword [LOCAL(B_HOVER)], 0
    je .done
    mov eax, [rel g_ui_click]
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_panel — a glass panel with a soft shadow around it.
;   in:  ecx = x, edx = y, r8d = w, r9d = h
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_panel, 0, rbx, rsi, rdi, r12
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    mov r12d, r9d
    mov dword [rsp + 48], COL_SHADOW
    mov qword [rsp + 40], 28
    mov qword [rsp + 32], 18
    lea edx, [esi + 6]
    INVOKE ui_glow, rbx, rdx, rdi, r12
    mov dword [rsp + 48], COL_GLASS_EDGE
    mov dword [rsp + 40], COL_GLASS
    mov qword [rsp + 32], 18
    INVOKE ui_glass, rbx, rsi, rdi, r12
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_label — text with a soft shadow.
;   in:  rcx = string, edx = x, r8d = y, r9d = size, ARG5 = colour,
;        ARG6 = flags (UI_CENTER / UI_RIGHT / UI_BOLD)
;   out: eax = width
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_label, 0
    mov eax, [ARG(5)]
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov eax, [ARG(6)]
    or eax, UI_SHADOW
    mov [rsp + 48], rax
    call ui_text
    RETURN
ENDPROC

; ui_focused — eax = the text field with the keyboard (id + 1, 0 none)
ui_focused:
    mov eax, [rel g_focus]
    ret

; ui_focus — ecx = text field id + 1 (0: none) gets the keyboard
ui_focus:
    mov [rel g_focus], ecx
    ret

; -----------------------------------------------------------------------------
; ui_textfield — a one-line text field.
;   in:  ecx = id, edx = x, r8d = y, r9d = w, ARG5 = h, ARG6 = buffer
;        (zero-terminated), ARG7 = capacity (bytes incl. terminator),
;        ARG8 = placeholder shown while empty (0: none)
;   out: eax = 0, 1 the text changed, 2 Enter was pressed in the field
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define T_RESULT    0
%define T_LEN       4
%define T_FOCUSED   8
PROC ui_textfield, 16, rbx, rsi, rdi, r12, r13, r14
    lea ebx, [ecx + 1]                  ; id + 1
    mov esi, edx
    mov edi, r8d
    mov r12d, r9d
    mov r13d, [ARG(5)]
    mov r14, [ARG(6)]
    mov dword [LOCAL(T_RESULT)], 0
    ; a click focuses it (or takes the focus away)
    cmp dword [rel g_ui_click], 0
    je .focus_known
    mov ecx, esi
    mov edx, edi
    mov r8d, r12d
    mov r9d, r13d
    call ui_hover
    test eax, eax
    jz .clicked_off
    mov [rel g_focus], ebx
    jmp .focus_known
.clicked_off:
    cmp [rel g_focus], ebx
    jne .focus_known
    mov dword [rel g_focus], 0
.focus_known:
    xor eax, eax
    cmp [rel g_focus], ebx
    sete al
    mov [LOCAL(T_FOCUSED)], eax
    mov rcx, r14
    call str_len
    mov [LOCAL(T_LEN)], eax
    ; typing
    cmp dword [LOCAL(T_FOCUSED)], 0
    je .draw
    xor ecx, ecx
.char:
    cmp ecx, [rel g_char_count]
    jae .draw
    lea rax, [rel g_chars]
    movzx eax, byte [rax + rcx]
    mov edx, [LOCAL(T_LEN)]
    cmp eax, 8
    jne .not_bs
    test edx, edx
    jz .char_next
    dec edx
    mov byte [r14 + rdx], 0
    mov [LOCAL(T_LEN)], edx
    mov dword [LOCAL(T_RESULT)], 1
    jmp .char_next
.not_bs:
    cmp eax, 13
    jne .not_enter
    mov dword [LOCAL(T_RESULT)], 2
    jmp .char_next
.not_enter:
    cmp eax, 32
    jb .char_next
    cmp eax, 126                        ; (the font has printable ASCII)
    ja .char_next
    lea r8d, [edx + 1]
    cmp r8d, [ARG(7)]
    jae .char_next
    mov [r14 + rdx], al
    mov byte [r14 + rdx + 1], 0
    mov [LOCAL(T_LEN)], r8d
    cmp dword [LOCAL(T_RESULT)], 0
    jne .char_next
    mov dword [LOCAL(T_RESULT)], 1
.char_next:
    inc ecx
    jmp .char
.draw:
    ; the box: dark, a teal border while it has the focus
    mov eax, 0x40FFFFFF
    cmp dword [LOCAL(T_FOCUSED)], 0
    je .border
    mov eax, COL_ACCENT
.border:
    mov [rsp + 40], rax
    mov dword [rsp + 32], COL_FIELD
    mov qword [rsp + 48], 10
    mov qword [rsp + 56], 2
    INVOKE ui_rect, rsi, rdi, r12, r13
    ; the text (or the placeholder)
    mov eax, r13d
    sub eax, 24
    sar eax, 1
    lea r8d, [edi + eax - 2]
    lea edx, [esi + 16]
    mov rcx, r14
    mov eax, COL_TEXT
    cmp dword [LOCAL(T_LEN)], 0
    jne .text
    mov rcx, [ARG(8)]
    mov eax, COL_TEXT_OFF
    test rcx, rcx
    jz .caret
    cmp dword [LOCAL(T_FOCUSED)], 0
    jne .caret                          ; (typing: no placeholder)
.text:
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    mov r9d, 22
    call ui_text
.caret:
    ; a blinking caret after the text
    cmp dword [LOCAL(T_FOCUSED)], 0
    je .done
    movss xmm0, [rel g_ui_time]
    addss xmm0, xmm0
    cvttss2si eax, xmm0
    test eax, 1
    jnz .done
    mov rcx, r14
    mov edx, 22
    call ui_text_width
    lea ecx, [esi + eax + 18]
    mov eax, r13d
    sub eax, 28
    sar eax, 1
    lea edx, [edi + eax]
    mov dword [rsp + 32], COL_ACCENT
    mov dword [rsp + 40], COL_ACCENT
    mov qword [rsp + 48], 1
    mov qword [rsp + 56], 0
    INVOKE ui_rect, rcx, rdx, 2, 28
.done:
    mov eax, [LOCAL(T_RESULT)]
    RETURN
ENDPROC

section .rdata
align 4
c_border_base:  dd 0.35
c_border_k:     dd 0.65
