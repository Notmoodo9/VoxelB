; =============================================================================
; item_icons.asm — every item's icon in one atlas texture (milestone 18).
;
; At start-up (after the block textures) each block item is drawn with
; shaders/icon.* from the block texture array: cube-like shapes as small
; isometric cubes (slabs half height), plant-like shapes (plants, doors,
; fences, ladders, panes ...) as a flat picture. Items with a `texture`
; (data/items) use assets/textures/items/<name>.png (16 x 16) instead,
; scaled up with sharp pixels. Cells are ICON_PX square, ATLAS_COLS wide.
;
; Public API:
;   icons_init() -> eax 1/0             after block_textures_init, items_load
;   icon_uv(ecx = item, rdx = out f32[4] u0, v0, u1, v1 for ui_icon_quad)
;   ui_icon(ecx = item, edx = x, r8d = y, r9d = size, ARG5 = colour)
;   icon_kind(ecx = item) -> eax 0 cube, 1 slab, 2 flat picture
;   g_icon_tex                          the atlas (ui_draw binds it)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "memory.inc"
%include "file.inc"
%include "block.inc"
%include "items.inc"

global icons_init, icon_uv, ui_icon, icon_kind, g_icon_tex

extern shader_create, shader_program, block_textures_bind, png_decode
extern ui_icon_quad, str_copy

%define ICON_PX         64
%define ATLAS_COLS      32
%define ATLAS_W         (ICON_PX * ATLAS_COLS)
%define SPRITE_PX       16
%define KIND_CUBE       0
%define KIND_SLAB       1
%define KIND_FLAT       2

section .rdata
str_vs:         db "shaders/icon.vert", 0
str_fs:         db "shaders/icon.frag", 0
str_items_dir:  db "assets/textures/items/", 0
str_png:        db ".png", 0
str_bad_sprite: db "item texture missing or not 16 x 16: ", 0
str_done:       db "icons: atlas rows ", 0
str_done2:      db ", ms ", 0
; icon kind per block shape (SHAPE_* order, world.inc)
shape_kind:     db KIND_CUBE, KIND_SLAB, KIND_CUBE, KIND_FLAT, KIND_FLAT ; cube slab stairs fence gate
                db KIND_FLAT, KIND_SLAB, KIND_FLAT, KIND_FLAT, KIND_FLAT ; door trapdoor ladder sign wall_sign
                db KIND_SLAB, KIND_CUBE, KIND_CUBE, KIND_FLAT, KIND_FLAT ; plate wall pillar pane spike
                db KIND_FLAT, KIND_FLAT, KIND_FLAT, KIND_CUBE            ; plant tall_plant stalk fluid
align 4
c_one:          dd 1.0

section .bss
alignb 4
g_icon_tex:     resd 1
g_icon_fbo:     resd 1
g_atlas_h:      resd 1
g_prog:         resd 1
g_vao:          resd 1
g_sprite:       resd 1                  ; png info: w, h
g_sprite_h:     resd 1
alignb 16
g_big:          resb ICON_PX * ICON_PX * 4
g_path:         resb PATH_CAP
g_rel:          resb PATH_CAP

section .text

; cell_xy — ecx = item -> eax = x, edx = y (pixels; y from the bottom)
cell_xy:
    mov eax, ecx
    and eax, ATLAS_COLS - 1
    imul eax, eax, ICON_PX
    mov edx, ecx
    shr edx, 5                          ; / ATLAS_COLS
    imul edx, edx, ICON_PX
    ret

; -----------------------------------------------------------------------------
; draw_sprite — an item's own 16 x 16 picture into its cell, 4x, sharp.
;   in:  ecx = item, rdx = texture name
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC draw_sprite, 16, rbx, rsi, rdi, r12
    mov ebx, ecx
    mov rsi, rdx
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rcx, [rel g_rel]
    lea rdx, [rel str_items_dir]
    call str_copy
    mov rcx, rax
    mov rdx, rsi
    call str_copy
    mov rcx, rax
    lea rdx, [rel str_png]
    call str_copy
    lea rcx, [rel g_path]
    lea rdx, [rel g_rel]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .bad
    lea r8, [rel g_sprite]
    lea r9, [rel g_arena_scratch]
    mov rcx, rax
    call png_decode
    test rax, rax
    jz .bad
    cmp dword [rel g_sprite], SPRITE_PX
    jne .bad
    cmp dword [rel g_sprite_h], SPRITE_PX
    jne .bad
    ; scale up: big row y (bottom-up in the atlas) = sprite row 15 - y / 4
    mov r12, rax
    xor edi, edi                        ; big y
.row:
    cmp edi, ICON_PX
    jae .upload
    mov eax, ICON_PX - 1
    sub eax, edi
    shr eax, 2
    imul eax, eax, SPRITE_PX * 4
    lea r8, [r12 + rax]                 ; sprite row
    imul ecx, edi, ICON_PX * 4
    lea r9, [rel g_big]
    add r9, rcx
    xor ecx, ecx
.px:
    mov eax, ecx
    shr eax, 2
    mov eax, [r8 + rax * 4]
    mov [r9 + rcx * 4], eax
    inc ecx
    cmp ecx, ICON_PX
    jb .px
    inc edi
    jmp .row
.upload:
    mov ecx, ebx
    call cell_xy
    lea rcx, [rel g_big]
    mov [rsp + 64], rcx
    mov qword [rsp + 56], GL_UNSIGNED_BYTE
    mov qword [rsp + 48], GL_RGBA
    mov qword [rsp + 40], ICON_PX
    mov qword [rsp + 32], ICON_PX
    mov r8d, eax
    mov r9d, edx
    mov ecx, [rel g_icon_tex]
    xor edx, edx
    call [rel glTextureSubImage2D]
    jmp .done
.bad:
    mov ecx, LOG_LEVEL_WARN
    call log_begin
    lea rcx, [rel str_bad_sprite]
    call log_append_str
    mov rcx, rsi
    call log_append_str
    call log_end
.done:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; icons_init — see the header.
; -----------------------------------------------------------------------------
PROC icons_init, 16, rbx, rsi, rdi
    call timer_elapsed_us
    mov [LOCAL(0)], rax
    lea rcx, [rel str_vs]
    lea rdx, [rel str_fs]
    call shader_create
    cmp eax, -1
    je .fail
    mov ecx, eax
    call shader_program
    mov [rel g_prog], eax
    ; the atlas: enough rows for every item
    mov eax, [rel g_item_count]
    add eax, ATLAS_COLS - 1
    shr eax, 5
    imul eax, eax, ICON_PX
    mov [rel g_atlas_h], eax
    lea r8, [rel g_icon_tex]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    GL glTextureStorage2D, [rel g_icon_tex], 1, GL_RGBA8, ATLAS_W, [rel g_atlas_h]
    GL glTextureParameteri, [rel g_icon_tex], GL_TEXTURE_MIN_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_icon_tex], GL_TEXTURE_MAG_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_icon_tex], GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, [rel g_icon_tex], GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE
    GL glClearTexImage, [rel g_icon_tex], 0, GL_RGBA, GL_UNSIGNED_BYTE, 0
    lea rdx, [rel g_icon_fbo]
    GL glCreateFramebuffers, 1, rdx
    GL glNamedFramebufferTexture, [rel g_icon_fbo], GL_COLOR_ATTACHMENT0, [rel g_icon_tex], 0
    GL glBindFramebuffer, GL_FRAMEBUFFER, [rel g_icon_fbo]
    GL glDisable, GL_DEPTH_TEST
    GL glDisable, GL_CULL_FACE
    GL glDisable, GL_BLEND
    GL glUseProgram, [rel g_prog]
    lea rdx, [rel g_vao]
    GL glCreateVertexArrays, 1, rdx
    GL glBindVertexArray, [rel g_vao]   ; (vertex pulling: an empty VAO)
    call block_textures_bind
    mov ebx, 1
.item:
    cmp ebx, [rel g_item_count]
    jae .drawn
    lea rax, [rel g_item_tex]
    mov rdx, [rax + rbx * 8]
    test rdx, rdx
    jz .block
    mov ecx, ebx
    call draw_sprite
    GL glBindFramebuffer, GL_FRAMEBUFFER, [rel g_icon_fbo]
    GL glUseProgram, [rel g_prog]
    jmp .next
.block:
    lea rax, [rel g_item_block]
    movzx esi, word [rax + rbx * 2]
    test esi, esi
    jz .next
    lea rax, [rel g_block_shape]
    movzx eax, byte [rax + rsi]
    cmp eax, SHAPE_COUNT
    jb .shape_ok
    xor eax, eax
.shape_ok:
    lea rcx, [rel shape_kind]
    movzx edi, byte [rcx + rax]
    mov ecx, ebx
    call cell_xy
    GL glViewport, rax, rdx, ICON_PX, ICON_PX
    GL glProgramUniform1ui, [rel g_prog], 0, rsi
    GL glProgramUniform1i, [rel g_prog], 1, rdi
    GL glDrawArrays, GL_TRIANGLES, 0, 18
.next:
    inc ebx
    jmp .item
.drawn:
    GL glBindVertexArray, 0
    GL glBindFramebuffer, GL_FRAMEBUFFER, 0
    GL glEnable, GL_CULL_FACE
    GL glEnable, GL_DEPTH_TEST
    call timer_elapsed_us
    sub rax, [LOCAL(0)]
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [LOCAL(8)], rax
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_done]
    call log_append_str
    mov ecx, [rel g_atlas_h]
    shr ecx, 6
    call log_append_dec
    lea rcx, [rel str_done2]
    call log_append_str
    mov rcx, [LOCAL(8)]
    call log_append_dec
    call log_end
    mov eax, 1
    RETURN
.fail:
    LOG_WARN "icons: the icon shader failed; items show no icons"
    xor eax, eax
    RETURN
ENDPROC

; icon_kind — how an item is shown: eax = KIND_* (see the header)
;   in:  ecx = item   clobbers: rax, rcx
icon_kind:
    lea rax, [rel g_item_tex]
    cmp qword [rax + rcx * 8], 0
    jne .flat
    lea rax, [rel g_item_block]
    movzx ecx, word [rax + rcx * 2]
    test ecx, ecx
    jz .flat
    lea rax, [rel g_block_shape]
    movzx eax, byte [rax + rcx]
    cmp eax, SHAPE_COUNT
    jae .cube
    lea rcx, [rel shape_kind]
    movzx eax, byte [rcx + rax]
    ret
.cube:
    xor eax, eax
    ret
.flat:
    mov eax, KIND_FLAT
    ret

; -----------------------------------------------------------------------------
; icon_uv — an item's cell in the atlas as texture coordinates (top-left
; first, as ui_icon_quad wants them: v0 is the top).
;   in:  ecx = item, rdx = out f32[4]
;   clobbers: rax, rcx, rdx, r8, xmm0-xmm2
; -----------------------------------------------------------------------------
icon_uv:
    mov r8, rdx
    call cell_xy
    cvtsi2ss xmm0, eax
    mov eax, ATLAS_W
    cvtsi2ss xmm1, eax
    divss xmm0, xmm1
    movss [r8], xmm0                    ; u0
    mov eax, ICON_PX
    cvtsi2ss xmm2, eax
    divss xmm2, xmm1
    addss xmm0, xmm2
    movss [r8 + 8], xmm0                ; u1
    cvtsi2ss xmm0, edx
    cvtsi2ss xmm1, dword [rel g_atlas_h]
    divss xmm0, xmm1
    movss [r8 + 12], xmm0               ; v1 (bottom)
    mov eax, ICON_PX
    cvtsi2ss xmm2, eax
    divss xmm2, xmm1
    addss xmm0, xmm2
    movss [r8 + 4], xmm0                ; v0 (top)
    ret

; -----------------------------------------------------------------------------
; ui_icon — draw an item's icon (UI units).
;   in:  ecx = item (0: nothing), edx = x, r8d = y, r9d = size, ARG5 = colour
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ui_icon, 16, rbx, rsi, rdi, r12
    test ecx, ecx
    jz .done
    cmp dword [rel g_icon_tex], 0
    je .done
    mov esi, edx
    mov edi, r8d
    mov r12d, r9d
    lea rdx, [LOCAL(0)]
    call icon_uv
    mov eax, [ARG(5)]
    mov [rsp + 64], rax
    mov eax, [LOCAL(0)]
    mov [rsp + 32], rax
    mov eax, [LOCAL(4)]
    mov [rsp + 40], rax
    mov eax, [LOCAL(8)]
    mov [rsp + 48], rax
    mov eax, [LOCAL(12)]
    mov [rsp + 56], rax
    INVOKE ui_icon_quad, rsi, rdi, r12, r12
.done:
    RETURN
ENDPROC

extern timer_elapsed_us
