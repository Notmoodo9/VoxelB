; =============================================================================
; ui_draw.asm — the menus' and HUD's renderer (milestone 17, design/ui/
; menus.md, DECISIONS D89).
;
; Everything is drawn in "UI units": a 1280 x 720 design canvas scaled to
; the window (g_ui_scale; the canvas grows with the window's aspect:
; g_ui_vw x g_ui_vh). One batch of 64-byte quads per frame (ui.vert /
; ui.frag, vertex pulling): rounded rectangles with a vertical gradient or a
; border, glass panels (the finished frame, downsampled and blurred, behind
; a tint), soft glows and shadows, and text in our signed-distance-field
; font (assets/fonts/ui_sdf.png + ui_sdf.cfg from tools/make_sdf_font.py:
; Inter SemiBold), crisp at any size.
; g_ui_alpha (0..1) fades and g_ui_oy (units) moves everything queued
; after it is set (screen transitions).
;
; Public API:
;   ui_draw_init() -> eax 1/0           after the GL context
;   ui_draw_begin(ecx = w, edx = h)     start a frame's batch
;   ui_rect(x, y, w, h, color, color2, radius, border)   (ints, units;
;       border 0: color -> color2 top to bottom; else a border in color2)
;   ui_glass(x, y, w, h, radius, tint, border color)
;   ui_glow(x, y, w, h, radius, size, color)
;   ui_image(x, y, w, h, u0, v0, u1, v1 (floats as dword bits), color)
;   ui_icon_quad(...)                   the same from the item icon atlas
;   ui_text(str, x, y, size, color, color2, flags) -> eax width (units)
;       y = top of the line; size = em in units; flags UI_CENTER / UI_RIGHT
;       (x is the centre / right edge), UI_SHADOW, UI_BOLD
;   ui_text_width(str, size) -> eax (units)
;   ui_draw_flush(ecx = w, edx = h)     capture the backdrop, draw the batch
;   g_ui_scale (f32), g_ui_vw, g_ui_vh (units), g_ui_alpha (f32), g_ui_oy
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "file.inc"
%include "cfg.inc"
%include "shader.inc"
%include "memory.inc"
%include "ui.inc"

global ui_draw_init, ui_draw_begin, ui_rect, ui_glass, ui_glow, ui_image
global ui_icon_quad
global ui_text, ui_text_width, ui_draw_flush, ui_draw_shutdown
global g_ui_scale, g_ui_vw, g_ui_vh, g_ui_alpha, g_ui_oy, g_ui_images_tex

extern png_decode, str_ieq, str_parse_float, str_parse_u64, g_icon_tex

%define MAX_QUADS       16384
%define QUAD_SIZE       64
%define MAX_GLYPHS_FONT 96

struc QUAD
    .x      resd 1
    .y      resd 1
    .w      resd 1
    .h      resd 1
    .u0     resd 1
    .v0     resd 1
    .u1     resd 1
    .v1     resd 1
    .p0     resd 1                      ; radius
    .p1     resd 1                      ; glow size / glyph softness
    .p2     resd 1                      ; border width
    .p3     resd 1                      ; glyph weight
    .color  resd 1
    .color2 resd 1
    .kind   resd 1
    .pad    resd 1
endstruc

section .rdata
str_atlas:      db "assets/fonts/ui_sdf.png", 0
str_metrics:    db "assets/fonts/ui_sdf.cfg", 0
str_metrics_lbl: db "ui_sdf.cfg", 0
str_vs:         db "shaders/ui.vert", 0
str_fs:         db "shaders/ui.frag", 0
k_cell:         db "cell", 0
k_em:           db "em", 0
k_ascent:       db "ascent", 0
k_descent:      db "descent", 0
k_columns:      db "columns", 0
k_first:        db "first", 0
k_pen:          db "pen", 0
k_glyph:        db "glyph_", 0
align 4
c_1280:         dd 1280.0
c_720:          dd 720.0
c_min_scale:    dd 0.5
c_max_scale:    dd 4.0
c_one:          dd 1.0
c_half:         dd 0.5
c_zero:         dd 0.0
c_shadow_dy:    dd 0.06                 ; shadow offset (share of the size)
c_shadow_soft:  dd 0.18
c_bold:         dd 0.06

section .data
align 4
g_ui_scale:     dd 1.0
g_ui_alpha:     dd 1.0
g_ui_oy:        dd 0

section .bss
alignb 8
g_quads:        resq 1                  ; MAX_QUADS records (perm arena)
g_quad_count:   resd 1
g_ui_vw:        resd 1
g_ui_vh:        resd 1
g_ui_buf:       resd 1
g_ui_vao:       resd 1
g_ui_prog:      resd 1
g_font_tex:     resd 1
g_ui_images_tex: resd 1                 ; (milestone 17 part 2: thumbnails)
g_back_fbo:     resd 2                  ; 1/4 and 1/16 of the window
g_back_tex:     resd 2
g_back_w:       resd 1                  ; window size they were made for
g_back_h:       resd 1
g_glass_used:   resd 1                  ; a glass quad this frame
; font metrics
g_f_cell:       resd 1                  ; atlas cell (pixels)
g_f_em:         resd 1                  ; f32 em in atlas pixels
g_f_ascent:     resd 1                  ; f32
g_f_descent:    resd 1                  ; f32
g_f_cols:       resd 1
g_f_first:      resd 1
g_f_pen_x:      resd 1                  ; f32 pen inside a cell
g_f_pen_y:      resd 1                  ; f32 baseline inside a cell
g_f_atlas_w:    resd 1                  ; f32
g_f_atlas_h:    resd 1                  ; f32
g_f_adv:        resd MAX_GLYPHS_FONT    ; f32 advance per glyph (atlas pixels)
alignb 16
g_q:            resb QUAD_SIZE          ; the quad being built
g_png_info:     resd 4
g_path:         resb PATH_CAP
g_mark:         resq 1
g_uni:          resd 4

section .text

; -----------------------------------------------------------------------------
; metrics_pair — cfg callback for ui_sdf.cfg.
; -----------------------------------------------------------------------------
PROC metrics_pair, 0, rbx, rsi
    mov rbx, rcx
    mov rsi, rdx
%macro METRIC_F 2                       ; key, destination (f32)
    lea rdx, [rel %1]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz %%no
    mov rcx, rsi
    call str_parse_float
    movss [rel %2], xmm0
    RETURN
%%no:
%endmacro
%macro METRIC_I 2                       ; key, destination (u32)
    lea rdx, [rel %1]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz %%no
    mov rcx, rsi
    call str_parse_u64
    mov [rel %2], eax
    RETURN
%%no:
%endmacro
    METRIC_I k_cell, g_f_cell
    METRIC_F k_em, g_f_em
    METRIC_F k_ascent, g_f_ascent
    METRIC_F k_descent, g_f_descent
    METRIC_I k_columns, g_f_cols
    METRIC_I k_first, g_f_first
    lea rdx, [rel k_pen]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_pen
    mov rcx, rsi
    call str_parse_float
    movss [rel g_f_pen_x], xmm0
    lea rcx, [rdx + 1]
    call str_parse_float
    movss [rel g_f_pen_y], xmm0
    RETURN
.not_pen:
    ; glyph_<code> = advance, ...
    mov eax, [rbx]
    cmp eax, 'glyp'
    jne .done
    cmp word [rbx + 4], 'h_'
    jne .done
    lea rcx, [rbx + 6]
    call str_parse_u64
    sub eax, 32
    cmp eax, MAX_GLYPHS_FONT
    jae .done
    mov ebx, eax
    mov rcx, rsi
    call str_parse_float
    lea rax, [rel g_f_adv]
    movss [rax + rbx * 4], xmm0
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_draw_init — font atlas + metrics, quad buffer, program.
;   out: eax = 1 / 0 (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_draw_init, 32, rbx, rsi
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, MAX_QUADS * QUAD_SIZE, 64
    mov [rel g_quads], rax
    test rax, rax
    jz .fail
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [rel g_mark], rax
    ; metrics
    lea rcx, [rel g_path]
    lea rdx, [rel str_metrics]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .missing
    lea rdx, [rel metrics_pair]
    lea r9, [rel str_metrics_lbl]
    INVOKE cfg_parse, rax, rdx, 0, r9
    cmp dword [rel g_f_cell], 0
    je .missing
    ; atlas
    lea rcx, [rel g_path]
    lea rdx, [rel str_atlas]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .missing
    lea r8, [rel g_png_info]
    lea r9, [rel g_arena_scratch]
    INVOKE png_decode, rax, rdx, r8, r9
    test rax, rax
    jz .missing
    mov rsi, rax                        ; RGBA8
    ; keep the red channel (in place)
    mov ecx, [rel g_png_info]
    imul ecx, [rel g_png_info + 4]
    xor edx, edx
.red:
    mov al, [rsi + rdx * 4]
    mov [rsi + rdx], al
    inc edx
    cmp edx, ecx
    jb .red
    cvtsi2ss xmm0, dword [rel g_png_info]
    movss [rel g_f_atlas_w], xmm0
    cvtsi2ss xmm0, dword [rel g_png_info + 4]
    movss [rel g_f_atlas_h], xmm0
    lea r8, [rel g_font_tex]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    mov eax, [rel g_png_info]
    mov [LOCAL(0)], rax
    mov eax, [rel g_png_info + 4]
    mov [LOCAL(8)], rax
    GL glTextureStorage2D, [rel g_font_tex], 1, GL_R8, [LOCAL(0)], [LOCAL(8)]
    GL glPixelStorei, GL_UNPACK_ALIGNMENT, 1
    mov r11, [LOCAL(0)]
    mov [rsp + 32], r11
    mov r11, [LOCAL(8)]
    mov [rsp + 40], r11
    mov qword [rsp + 48], GL_RED
    mov qword [rsp + 56], GL_UNSIGNED_BYTE
    mov [rsp + 64], rsi
    mov ecx, [rel g_font_tex]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [rel glTextureSubImage2D]
    GL glPixelStorei, GL_UNPACK_ALIGNMENT, 4
    GL glTextureParameteri, [rel g_font_tex], GL_TEXTURE_MIN_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_font_tex], GL_TEXTURE_MAG_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_font_tex], GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, [rel g_font_tex], GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [rel g_mark]
    ; buffer, VAO, program
    lea rdx, [rel g_ui_buf]
    GL glCreateBuffers, 1, rdx
    GL glNamedBufferStorage, [rel g_ui_buf], MAX_QUADS * QUAD_SIZE, 0, GL_DYNAMIC_STORAGE_BIT
    lea rdx, [rel g_ui_vao]
    GL glCreateVertexArrays, 1, rdx
    lea rcx, [rel str_vs]
    lea rdx, [rel str_fs]
    call shader_create
    cmp eax, -1
    je .fail
    mov [rel g_ui_prog], eax
    LOG_INFO "ui: renderer ready (SDF font, glass panels)"
    mov eax, 1
    RETURN
.missing:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [rel g_mark]
    LOG_ERROR "ui: could not read assets/fonts/ui_sdf.png / ui_sdf.cfg"
.fail:
    xor eax, eax
    RETURN
ENDPROC

; ui_draw_shutdown — free GL objects.  clobbers: volatile registers
PROC ui_draw_shutdown, 0
    lea rdx, [rel g_font_tex]
    GL glDeleteTextures, 1, rdx
    lea rdx, [rel g_ui_buf]
    GL glDeleteBuffers, 1, rdx
    lea rdx, [rel g_ui_vao]
    GL glDeleteVertexArrays, 1, rdx
    call back_free
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_draw_begin — start the batch; the scale for this window size.
;   in:  ecx = width, edx = height (pixels)
;   clobbers: rax, xmm0, xmm1
; -----------------------------------------------------------------------------
ui_draw_begin:
    mov dword [rel g_quad_count], 0
    mov dword [rel g_glass_used], 0
    mov dword [rel g_ui_alpha], 0x3F800000      ; 1.0
    mov dword [rel g_ui_oy], 0
    cvtsi2ss xmm0, ecx
    divss xmm0, [rel c_1280]
    cvtsi2ss xmm1, edx
    divss xmm1, [rel c_720]
    minss xmm0, xmm1
    maxss xmm0, [rel c_min_scale]
    minss xmm0, [rel c_max_scale]
    movss [rel g_ui_scale], xmm0
    cvtsi2ss xmm1, ecx
    divss xmm1, xmm0
    cvttss2si eax, xmm1
    mov [rel g_ui_vw], eax
    cvtsi2ss xmm1, edx
    divss xmm1, xmm0
    cvttss2si eax, xmm1
    mov [rel g_ui_vh], eax
    ret

; -----------------------------------------------------------------------------
; push_quad — append g_q (rect in units) as pixels, with the global alpha
; and offset applied.
;   clobbers: rax, rcx, rdx, xmm0, xmm1
; -----------------------------------------------------------------------------
push_quad:
    mov eax, [rel g_quad_count]
    cmp eax, MAX_QUADS
    jae .full
    inc dword [rel g_quad_count]
    shl rax, 6
    add rax, [rel g_quads]
    movss xmm1, [rel g_ui_scale]
    ; rect
    movss xmm0, [rel g_q + QUAD.x]
    mulss xmm0, xmm1
    movss [rax + QUAD.x], xmm0
    cvtsi2ss xmm0, dword [rel g_ui_oy]
    addss xmm0, [rel g_q + QUAD.y]
    mulss xmm0, xmm1
    movss [rax + QUAD.y], xmm0
    movss xmm0, [rel g_q + QUAD.w]
    mulss xmm0, xmm1
    movss [rax + QUAD.w], xmm0
    movss xmm0, [rel g_q + QUAD.h]
    mulss xmm0, xmm1
    movss [rax + QUAD.h], xmm0
    ; uv, params (radius, glow and border are in units too)
    mov ecx, [rel g_q + QUAD.u0]
    mov [rax + QUAD.u0], ecx
    mov ecx, [rel g_q + QUAD.v0]
    mov [rax + QUAD.v0], ecx
    mov ecx, [rel g_q + QUAD.u1]
    mov [rax + QUAD.u1], ecx
    mov ecx, [rel g_q + QUAD.v1]
    mov [rax + QUAD.v1], ecx
    movss xmm0, [rel g_q + QUAD.p0]
    mulss xmm0, xmm1
    movss [rax + QUAD.p0], xmm0
    movss xmm0, [rel g_q + QUAD.p1]
    cmp dword [rel g_q + QUAD.kind], UIK_GLYPH
    je .soft
    mulss xmm0, xmm1                    ; (glyph softness is in SDF units)
.soft:
    movss [rax + QUAD.p1], xmm0
    movss xmm0, [rel g_q + QUAD.p2]
    mulss xmm0, xmm1
    movss [rax + QUAD.p2], xmm0
    mov ecx, [rel g_q + QUAD.p3]
    mov [rax + QUAD.p3], ecx
    ; colours: alpha times g_ui_alpha
    mov ecx, [rel g_q + QUAD.color]
    call fade
    mov [rax + QUAD.color], ecx
    mov ecx, [rel g_q + QUAD.color2]
    call fade
    mov [rax + QUAD.color2], ecx
    mov ecx, [rel g_q + QUAD.kind]
    mov [rax + QUAD.kind], ecx
.full:
    ret

; fade — ecx colour's alpha *= g_ui_alpha   clobbers: rdx, xmm0
fade:
    mov edx, ecx
    shr edx, 24
    cvtsi2ss xmm0, edx
    mulss xmm0, [rel g_ui_alpha]
    cvttss2si edx, xmm0
    and ecx, 0x00FFFFFF
    shl edx, 24
    or ecx, edx
    ret

; set_rect — g_q rect from ints (ecx, edx, r8d, r9d), the rest cleared
set_rect:
    lea rax, [rel g_q]
    cvtsi2ss xmm0, ecx
    movss [rax + QUAD.x], xmm0
    cvtsi2ss xmm0, edx
    movss [rax + QUAD.y], xmm0
    cvtsi2ss xmm0, r8d
    movss [rax + QUAD.w], xmm0
    cvtsi2ss xmm0, r9d
    movss [rax + QUAD.h], xmm0
    xor ecx, ecx
    mov [rax + QUAD.u0], ecx
    mov [rax + QUAD.v0], ecx
    mov [rax + QUAD.u1], ecx
    mov [rax + QUAD.v1], ecx
    mov [rax + QUAD.p0], ecx
    mov [rax + QUAD.p1], ecx
    mov [rax + QUAD.p2], ecx
    mov [rax + QUAD.p3], ecx
    ret

; -----------------------------------------------------------------------------
; ui_rect — rounded rectangle.
;   in:  ecx = x, edx = y, r8d = w, r9d = h, ARG5 = color, ARG6 = color2,
;        ARG7 = radius, ARG8 = border width (0: color2 is the gradient's bottom)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_rect, 0
    call set_rect
    mov eax, [ARG(5)]
    mov [rel g_q + QUAD.color], eax
    mov eax, [ARG(6)]
    mov [rel g_q + QUAD.color2], eax
    cvtsi2ss xmm0, dword [ARG(7)]
    movss [rel g_q + QUAD.p0], xmm0
    cvtsi2ss xmm0, dword [ARG(8)]
    movss [rel g_q + QUAD.p2], xmm0
    mov dword [rel g_q + QUAD.kind], UIK_RECT
    call push_quad
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_glass — a glass panel.
;   in:  ecx = x, edx = y, r8d = w, r9d = h, ARG5 = radius, ARG6 = tint
;        (alpha = how much tint over the blurred world), ARG7 = border colour
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_glass, 0
    call set_rect
    cvtsi2ss xmm0, dword [ARG(5)]
    movss [rel g_q + QUAD.p0], xmm0
    mov eax, [ARG(6)]
    mov [rel g_q + QUAD.color], eax
    mov eax, [ARG(7)]
    mov [rel g_q + QUAD.color2], eax
    mov dword [rel g_q + QUAD.p2], 0x3FC00000   ; 1.5 units of border
    mov dword [rel g_q + QUAD.kind], UIK_GLASS
    mov dword [rel g_glass_used], 1
    ; (the glass shows the frame without the UI: its alpha stays whole)
    mov r8d, [rel g_ui_alpha]
    mov dword [rel g_ui_alpha], 0x3F800000
    call push_quad                      ; (keeps r8)
    mov [rel g_ui_alpha], r8d
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_glow — a soft glow (or shadow) around a rounded rectangle.
;   in:  ecx = x, edx = y, r8d = w, r9d = h, ARG5 = radius, ARG6 = size,
;        ARG7 = colour
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_glow, 0
    call set_rect
    cvtsi2ss xmm0, dword [ARG(5)]
    movss [rel g_q + QUAD.p0], xmm0
    cvtsi2ss xmm0, dword [ARG(6)]
    movss [rel g_q + QUAD.p1], xmm0
    mov eax, [ARG(7)]
    mov [rel g_q + QUAD.color], eax
    mov [rel g_q + QUAD.color2], eax
    mov dword [rel g_q + QUAD.kind], UIK_GLOW
    call push_quad
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_image — a part of the image texture (u_images).
;   in:  ecx = x, edx = y, r8d = w, r9d = h, ARG5..8 = u0, v0, u1, v1 (f32
;        bits), ARG9 = colour (multiplied)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_image, 0
    call set_rect
    mov eax, [ARG(5)]
    mov [rel g_q + QUAD.u0], eax
    mov eax, [ARG(6)]
    mov [rel g_q + QUAD.v0], eax
    mov eax, [ARG(7)]
    mov [rel g_q + QUAD.u1], eax
    mov eax, [ARG(8)]
    mov [rel g_q + QUAD.v1], eax
    mov eax, [ARG(9)]
    mov [rel g_q + QUAD.color], eax
    mov [rel g_q + QUAD.color2], eax
    mov dword [rel g_q + QUAD.kind], UIK_IMAGE
    call push_quad
    RETURN
ENDPROC

; ui_icon_quad — like ui_image, from the item icon atlas (item_icons.asm)
PROC ui_icon_quad, 0
    call set_rect
    mov eax, [ARG(5)]
    mov [rel g_q + QUAD.u0], eax
    mov eax, [ARG(6)]
    mov [rel g_q + QUAD.v0], eax
    mov eax, [ARG(7)]
    mov [rel g_q + QUAD.u1], eax
    mov eax, [ARG(8)]
    mov [rel g_q + QUAD.v1], eax
    mov eax, [ARG(9)]
    mov [rel g_q + QUAD.color], eax
    mov [rel g_q + QUAD.color2], eax
    mov dword [rel g_q + QUAD.kind], UIK_ICON
    call push_quad
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_text_width — width of a string at a size.
;   in:  rcx = string, edx = size (units)
;   out: eax = width (units, rounded up)
;   clobbers: rax, rcx, r8, xmm0, xmm1
; -----------------------------------------------------------------------------
ui_text_width:
    xorps xmm0, xmm0
.next:
    movzx eax, byte [rcx]
    inc rcx
    test eax, eax
    jz .done
    sub eax, 32
    cmp eax, MAX_GLYPHS_FONT
    jae .next
    lea r8, [rel g_f_adv]
    addss xmm0, [r8 + rax * 4]
    jmp .next
.done:
    cvtsi2ss xmm1, edx
    mulss xmm0, xmm1
    divss xmm0, [rel g_f_em]
    roundss xmm0, xmm0, 10              ; ceil
    cvttss2si eax, xmm0
    ret

; -----------------------------------------------------------------------------
; ui_text — queue a string.
;   in:  rcx = string, edx = x, r8d = y (top of the line), r9d = size (em,
;        units), ARG5 = colour (top), ARG6 = colour2 (bottom of the glyphs),
;        ARG7 = flags (UI_CENTER, UI_RIGHT, UI_SHADOW, UI_BOLD)
;   out: eax = width (units)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define T_PEN       0                   ; f32 pen x (units)
%define T_BASE      4                   ; f32 baseline y (units)
%define T_S         8                   ; f32 units per atlas pixel
%define T_W         12                  ; width (units)
%define T_PASS      16
%define T_CELL      20                  ; f32 cell size (units)
PROC ui_text, 32, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    mov r12d, edx                       ; x
    mov r13d, r8d                       ; y
    mov edi, r9d                        ; size
    mov rcx, rbx
    mov edx, edi
    call ui_text_width
    mov [LOCAL(T_W)], eax
    ; alignment
    test dword [ARG(7)], UI_CENTER
    jz .not_center
    mov ecx, eax
    shr ecx, 1
    sub r12d, ecx
.not_center:
    test dword [ARG(7)], UI_RIGHT
    jz .aligned
    sub r12d, eax
.aligned:
    cvtsi2ss xmm0, edi
    divss xmm0, [rel g_f_em]
    movss [LOCAL(T_S)], xmm0
    cvtsi2ss xmm1, dword [rel g_f_cell]
    mulss xmm1, xmm0
    movss [LOCAL(T_CELL)], xmm1
    ; passes: the shadow (if asked), then the text
    mov dword [LOCAL(T_PASS)], 0
    test dword [ARG(7)], UI_SHADOW
    jnz .pass
    mov dword [LOCAL(T_PASS)], 1
.pass:
    cvtsi2ss xmm0, r12d
    movss [LOCAL(T_PEN)], xmm0
    movss xmm0, [rel g_f_ascent]
    mulss xmm0, [LOCAL(T_S)]
    cvtsi2ss xmm1, r13d
    addss xmm0, xmm1
    movss [LOCAL(T_BASE)], xmm0
    cmp dword [LOCAL(T_PASS)], 0
    jne .colours
    ; shadow: a little lower, soft and dark
    cvtsi2ss xmm1, edi
    mulss xmm1, [rel c_shadow_dy]
    addss xmm0, xmm1
    movss [LOCAL(T_BASE)], xmm0
    movss xmm1, [LOCAL(T_PEN)]
    cvtsi2ss xmm0, edi
    mulss xmm0, [rel c_shadow_dy]
    mulss xmm0, [rel c_half]
    addss xmm1, xmm0
    movss [LOCAL(T_PEN)], xmm1
    mov eax, [ARG(5)]
    shr eax, 24
    shr eax, 1                          ; half the text's alpha
    shl eax, 24
    mov [rel g_q + QUAD.color], eax
    mov [rel g_q + QUAD.color2], eax
    mov eax, [rel c_shadow_soft]
    mov [rel g_q + QUAD.p1], eax
    jmp .weight
.colours:
    mov eax, [ARG(5)]
    mov [rel g_q + QUAD.color], eax
    mov eax, [ARG(6)]
    mov [rel g_q + QUAD.color2], eax
    mov dword [rel g_q + QUAD.p1], 0
.weight:
    mov dword [rel g_q + QUAD.p3], 0
    test dword [ARG(7)], UI_BOLD
    jz .chars_start
    mov eax, [rel c_bold]
    mov [rel g_q + QUAD.p3], eax
.chars_start:
    mov dword [rel g_q + QUAD.kind], UIK_GLYPH
    mov dword [rel g_q + QUAD.p0], 0
    mov dword [rel g_q + QUAD.p2], 0
    mov rsi, rbx
.char:
    movzx eax, byte [rsi]
    inc rsi
    test eax, eax
    jz .pass_done
    sub eax, [rel g_f_first]
    cmp eax, MAX_GLYPHS_FONT
    jae .char
    mov r8d, eax                        ; glyph index
    cmp eax, 0
    je .advance                         ; (space)
    ; quad: pen - pen_x * s, baseline - pen_y * s, cell * s square
    movss xmm0, [rel g_f_pen_x]
    mulss xmm0, [LOCAL(T_S)]
    movss xmm1, [LOCAL(T_PEN)]
    subss xmm1, xmm0
    movss [rel g_q + QUAD.x], xmm1
    movss xmm0, [rel g_f_pen_y]
    mulss xmm0, [LOCAL(T_S)]
    movss xmm1, [LOCAL(T_BASE)]
    subss xmm1, xmm0
    movss [rel g_q + QUAD.y], xmm1
    movss xmm0, [LOCAL(T_CELL)]
    movss [rel g_q + QUAD.w], xmm0
    movss [rel g_q + QUAD.h], xmm0
    ; uv of the cell
    mov eax, r8d
    xor edx, edx
    div dword [rel g_f_cols]            ; eax = row, edx = column
    imul edx, [rel g_f_cell]
    imul eax, [rel g_f_cell]
    cvtsi2ss xmm0, edx
    divss xmm0, [rel g_f_atlas_w]
    movss [rel g_q + QUAD.u0], xmm0
    cvtsi2ss xmm0, eax
    divss xmm0, [rel g_f_atlas_h]
    movss [rel g_q + QUAD.v0], xmm0
    add edx, [rel g_f_cell]
    add eax, [rel g_f_cell]
    cvtsi2ss xmm0, edx
    divss xmm0, [rel g_f_atlas_w]
    movss [rel g_q + QUAD.u1], xmm0
    cvtsi2ss xmm0, eax
    divss xmm0, [rel g_f_atlas_h]
    movss [rel g_q + QUAD.v1], xmm0
    call push_quad                      ; (keeps r8)
.advance:
    lea rax, [rel g_f_adv]
    movss xmm0, [rax + r8 * 4]
    mulss xmm0, [LOCAL(T_S)]
    addss xmm0, [LOCAL(T_PEN)]
    movss [LOCAL(T_PEN)], xmm0
    jmp .char
.pass_done:
    inc dword [LOCAL(T_PASS)]
    cmp dword [LOCAL(T_PASS)], 2
    jb .pass
    mov eax, [LOCAL(T_W)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; back_free / back_make — the backdrop targets (1/4 and 1/16 of the window).
; -----------------------------------------------------------------------------
PROC back_free, 0
    cmp dword [rel g_back_fbo], 0
    je .done
    lea rdx, [rel g_back_fbo]
    GL glDeleteFramebuffers, 2, rdx
    lea rdx, [rel g_back_tex]
    GL glDeleteTextures, 2, rdx
    mov dword [rel g_back_fbo], 0
.done:
    RETURN
ENDPROC

PROC back_make, 16, rbx, rsi
    call back_free
    lea rdx, [rel g_back_fbo]
    GL glCreateFramebuffers, 2, rdx
    lea r8, [rel g_back_tex]
    GL glCreateTextures, GL_TEXTURE_2D, 2, r8
    xor ebx, ebx
.t:
    ; 1/4, then 1/16 (at least 1 pixel)
    mov eax, [rel g_back_w]
    mov ecx, [rel g_back_h]
    lea edx, [ebx * 2 + 2]
    xchg ecx, edx
    shr eax, cl
    shr edx, cl
    mov ecx, 1
    cmp eax, ecx
    cmovb eax, ecx
    cmp edx, ecx
    cmovb edx, ecx
    mov [LOCAL(0)], rax
    mov [LOCAL(8)], rdx
    lea rax, [rel g_back_tex]
    mov esi, [rax + rbx * 4]
    GL glTextureStorage2D, rsi, 1, GL_RGBA8, [LOCAL(0)], [LOCAL(8)]
    GL glTextureParameteri, rsi, GL_TEXTURE_MIN_FILTER, GL_LINEAR
    GL glTextureParameteri, rsi, GL_TEXTURE_MAG_FILTER, GL_LINEAR
    GL glTextureParameteri, rsi, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, rsi, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE
    lea rax, [rel g_back_fbo]
    mov eax, [rax + rbx * 4]
    GL glNamedFramebufferTexture, rax, GL_COLOR_ATTACHMENT0, rsi, 0
    inc ebx
    cmp ebx, 2
    jb .t
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ui_draw_flush — capture the backdrop (if glass is used), draw the batch.
;   in:  ecx = width, edx = height
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_draw_flush, 16, rbx, rsi, rdi
    mov esi, ecx
    mov edi, edx
    cmp dword [rel g_quad_count], 0
    je .done
    cmp dword [rel g_glass_used], 0
    je .draw
    ; the finished frame -> 1/4 -> 1/16 (linear filtering: a cheap blur)
    cmp esi, [rel g_back_w]
    jne .remake
    cmp edi, [rel g_back_h]
    jne .remake
    cmp dword [rel g_back_fbo], 0
    jne .blit
.remake:
    mov [rel g_back_w], esi
    mov [rel g_back_h], edi
    call back_make
.blit:
    mov eax, esi
    shr eax, 2
    mov ecx, edi
    shr ecx, 2
    mov [LOCAL(0)], eax
    mov [LOCAL(4)], ecx
    xor ecx, ecx                        ; read: the window
    mov edx, [rel g_back_fbo]
    xor r8d, r8d
    xor r9d, r9d
    ; (src x0, y0, x1, y1 = 0, 0, w, h; dst = 0, 0, w/4, h/4)
    mov [rsp + 32], rsi                 ; srcX1
    mov [rsp + 40], rdi                 ; srcY1
    mov qword [rsp + 48], 0             ; dstX0
    mov qword [rsp + 56], 0             ; dstY0
    mov eax, [LOCAL(0)]
    mov [rsp + 64], rax                 ; dstX1
    mov eax, [LOCAL(4)]
    mov [rsp + 72], rax                 ; dstY1
    mov qword [rsp + 80], GL_COLOR_BUFFER_BIT
    mov qword [rsp + 88], GL_LINEAR
    call [rel glBlitNamedFramebuffer]
    ; 1/4 -> 1/16
    mov eax, [LOCAL(0)]
    mov [rsp + 32], rax
    mov eax, [LOCAL(4)]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov eax, [LOCAL(0)]
    shr eax, 2
    mov ecx, 1
    cmp eax, ecx
    cmovb eax, ecx
    mov [rsp + 64], rax
    mov eax, [LOCAL(4)]
    shr eax, 2
    cmp eax, ecx
    cmovb eax, ecx
    mov [rsp + 72], rax
    mov qword [rsp + 80], GL_COLOR_BUFFER_BIT
    mov qword [rsp + 88], GL_LINEAR
    mov ecx, [rel g_back_fbo]
    mov edx, [rel g_back_fbo + 4]
    xor r8d, r8d
    xor r9d, r9d
    call [rel glBlitNamedFramebuffer]
    GL glBindFramebuffer, GL_FRAMEBUFFER, 0
.draw:
    mov r8d, [rel g_quad_count]
    shl r8d, 6
    mov r9, [rel g_quads]
    GL glNamedBufferSubData, [rel g_ui_buf], 0, r8, r9
    mov ecx, [rel g_ui_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    cvtsi2ss xmm0, esi
    movss [rel g_uni], xmm0
    cvtsi2ss xmm0, edi
    movss [rel g_uni + 4], xmm0
    lea r9, [rel g_uni]
    GL glProgramUniform2fv, rbx, 0, 1, r9
    GL glViewport, 0, 0, rsi, rdi
    GL glDisable, GL_DEPTH_TEST
    GL glDisable, GL_CULL_FACE
    GL glEnable, GL_BLEND
    GL glBlendFunc, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA
    GL glBindVertexArray, [rel g_ui_vao]
    GL glBindTextureUnit, 0, [rel g_font_tex]
    GL glBindTextureUnit, 1, [rel g_back_tex + 4]
    mov eax, [rel g_ui_images_tex]
    test eax, eax
    jnz .images
    mov eax, [rel g_font_tex]           ; (nothing yet: any texture)
.images:
    GL glBindTextureUnit, 2, rax
    mov eax, [rel g_icon_tex]
    test eax, eax
    jnz .icons
    mov eax, [rel g_font_tex]
.icons:
    GL glBindTextureUnit, 3, rax
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 0, [rel g_ui_buf]
    mov r8d, [rel g_quad_count]
    imul r8d, r8d, 6
    GL glDrawArrays, GL_TRIANGLES, 0, r8
    GL glDisable, GL_BLEND
    GL glEnable, GL_CULL_FACE
    GL glEnable, GL_DEPTH_TEST
.done:
    RETURN
ENDPROC
