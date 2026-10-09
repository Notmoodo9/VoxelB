; =============================================================================
; block_textures.asm — block textures on the GPU.
;
; Every texture named by the block registry is loaded from
; assets/textures/blocks/<name>.png (16 pixels wide; an animated texture is
; a vertical strip of 16x16 frames) into one GL_TEXTURE_2D_ARRAY with
; mipmaps. Layer 0 is the built-in "missing" checkerboard, used for files
; that are absent or invalid (with a warning naming them).
; Two shader storage buffers describe them to shaders/chunk.*:
;   binding 1  block faces: u32 per (block, face) = texture | flags << 16
;              (flags: bit 0 sway, bits 1-2 render layer, bits 3-4 biome tint)
;   binding 2  textures: uvec4 per texture = (first layer,
;              frames | interpolate << 16, frame_ms, glow first layer + 1 |
;              glow frames << 16)
; PNG files are watched: a repainted texture is re-uploaded within a second
; (same frame count; a changed frame count needs a restart). 32 file times
; are checked per frame, so all ~300 files are covered every 10 frames.
;
; Public API:
;   block_textures_init() -> eax 1/0     after blocks_load, needs GL
;   block_textures_bind()                texture unit 0 + SSBO bindings 1, 2
;   block_textures_poll()                once per frame (hot reload)
;   block_textures_shutdown()
;   g_tex_layers                         layers in the array
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "block.inc"

global block_textures_init, block_textures_bind, block_textures_poll
global block_textures_shutdown, g_tex_layers

extern png_decode, str_copy

%define TEX_SIZE        16
%define TEX_LEVELS      5               ; 16, 8, 4, 2, 1
%define MAX_FRAMES      32
%define POLL_PER_FRAME  32              ; file-time checks per frame
%define FRAME_BYTES     (TEX_SIZE * TEX_SIZE * 4)

section .rdata
str_dir:        db "assets/textures/blocks/", 0
str_ext:        db ".png", 0
str_label:      db "textures", 0
str_missing:    db "missing file for texture: ", 0
str_invalid:    db "texture must be 16 pixels wide, 16 x frames (max 32) tall: ", 0
str_frames:     db "frame count changed (restart to apply): ", 0
str_reloaded:   db "textures: reloaded ", 0
str_summary:    db "textures: array layers ", 0
str_summary2:   db ", missing or invalid ", 0

section .bss
alignb 4
g_tex_layers:       resd 1
g_tex_array:        resd 1
g_face_buffer:      resd 1
g_info_buffer:      resd 1
g_poll_next:        resd 1
g_bad_count:        resd 1
alignb 8
g_tex_mtime:        resq MAX_TEXTURES
g_tex_pixels:       resq MAX_TEXTURES   ; during init only (scratch arena)
g_png_info:         resd 2
g_tex_layer:        resw MAX_TEXTURES
g_tex_frames:       resb MAX_TEXTURES

section .text

; -----------------------------------------------------------------------------
; texture_path — build the PNG path of a texture.
;   in:  rcx = destination (PATH_CAP), edx = texture index
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC texture_path, PATH_CAP, rbx, rsi
    mov rbx, rcx
    mov esi, edx
    lea rcx, [LOCAL(0)]
    lea rdx, [rel str_dir]
    call str_copy
    lea rcx, [rel g_tex_names]
    mov rdx, [rcx + rsi * 8]
    INVOKE str_copy, rax, rdx
    lea rdx, [rel str_ext]
    INVOKE str_copy, rax, rdx
    lea rdx, [LOCAL(0)]
    mov rcx, rbx
    call path_make
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; load_png — read and decode one texture into the scratch arena.
;   in:  ecx = texture index, rdx = path
;   out: rax = RGBA8 pixels or 0 (warned), edx = frames
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC load_png, 0, rbx, rsi
    mov ebx, ecx
    mov rsi, rdx
    lea rdx, [rel g_arena_scratch]
    mov rcx, rsi
    call file_load
    test rax, rax
    jz .missing
    lea r8, [rel g_png_info]
    lea r9, [rel g_arena_scratch]
    INVOKE png_decode, rax, rdx, r8, r9
    test rax, rax
    jz .invalid
    cmp dword [rel g_png_info], TEX_SIZE
    jne .invalid
    mov ecx, [rel g_png_info + 4]
    test ecx, 15
    jnz .invalid
    shr ecx, 4
    jz .invalid
    cmp ecx, MAX_FRAMES
    ja .invalid
    mov edx, ecx
    RETURN
.missing:
    lea rdx, [rel str_missing]
    jmp .warn
.invalid:
    lea rdx, [rel str_invalid]
.warn:
    inc dword [rel g_bad_count]
    lea rcx, [rel g_tex_names]
    mov r8, [rcx + rbx * 8]
    lea rcx, [rel str_label]
    call cfg_warn
    xor eax, eax
    xor edx, edx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; average_color — mean colour of the visible pixels of one 16x16 frame.
;   in:  rcx = RGBA8 pixels     out: eax = RGBA8 (alpha 255)
;   clobbers: rax, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
average_color:
    xor r8d, r8d                        ; r
    xor r9d, r9d                        ; g
    xor r10d, r10d                      ; b
    xor r11d, r11d                      ; count
    mov edx, TEX_SIZE * TEX_SIZE
.px:
    cmp byte [rcx + 3], 0
    je .skip
    movzx eax, byte [rcx]
    add r8d, eax
    movzx eax, byte [rcx + 1]
    add r9d, eax
    movzx eax, byte [rcx + 2]
    add r10d, eax
    inc r11d
.skip:
    add rcx, 4
    dec edx
    jnz .px
    test r11d, r11d
    jz .none
    mov eax, r8d
    xor edx, edx
    div r11d
    mov r8d, eax
    mov eax, r9d
    xor edx, edx
    div r11d
    mov r9d, eax
    mov eax, r10d
    xor edx, edx
    div r11d
    shl eax, 16
    shl r9d, 8
    or eax, r9d
    or eax, r8d
    or eax, 0xFF000000
    ret
.none:
    mov eax, 0xFF000000
    ret

; -----------------------------------------------------------------------------
; block_textures_init — load every texture and build the GPU tables.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC block_textures_init, PATH_CAP + 32, rbx, rsi, rdi, r12, r13
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(PATH_CAP)], rax
    mov dword [rel g_bad_count], 0

    ; ---- decode all PNGs, assign layers ------------------------------------------------
    mov r12d, 1                         ; next layer (0 = missing)
    mov ebx, 1                          ; texture index
    mov word [rel g_tex_layer], 0
    mov byte [rel g_tex_frames], 1
    mov qword [rel g_tex_pixels], 0
.load:
    cmp ebx, [rel g_tex_count]
    jae .loaded
    lea rcx, [LOCAL(0)]
    mov edx, ebx
    call texture_path
    lea rcx, [LOCAL(0)]
    call file_mtime
    lea rcx, [rel g_tex_mtime]
    mov [rcx + rbx * 8], rax
    lea rdx, [LOCAL(0)]
    mov ecx, ebx
    call load_png
    lea rcx, [rel g_tex_pixels]
    mov [rcx + rbx * 8], rax
    test rax, rax
    jz .use_missing
    lea rcx, [rel g_tex_layer]
    mov [rcx + rbx * 2], r12w
    lea rcx, [rel g_tex_frames]
    mov [rcx + rbx], dl
    add r12d, edx
    jmp .next
.use_missing:
    lea rcx, [rel g_tex_layer]
    mov word [rcx + rbx * 2], 0
    lea rcx, [rel g_tex_frames]
    mov byte [rcx + rbx], 1
.next:
    inc ebx
    jmp .load
.loaded:
    mov [rel g_tex_layers], r12d
    lea r8, [LOCAL(PATH_CAP + 8)]
    mov dword [r8], 0
    GL glGetIntegerv, GL_MAX_ARRAY_TEXTURE_LAYERS, r8
    mov eax, [LOCAL(PATH_CAP + 8)]
    cmp r12d, eax
    jbe .layers_ok
    LOG_VAL LOG_LEVEL_ERROR, "textures: too many layers for this GPU, max", rax
    jmp .fail

.layers_ok:
    ; ---- texture array -------------------------------------------------------------------------
    lea r8, [rel g_tex_array]
    GL glCreateTextures, GL_TEXTURE_2D_ARRAY, 1, r8
    GL glTextureStorage3D, [rel g_tex_array], TEX_LEVELS, GL_RGBA8, TEX_SIZE, TEX_SIZE, r12
    GL glPixelStorei, GL_UNPACK_ALIGNMENT, 4
    ; layer 0: magenta / black checkerboard (4x4 cells)
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, FRAME_BYTES, 16
    test rax, rax
    jz .fail
    mov rsi, rax
    xor ecx, ecx
.checker:
    mov eax, ecx
    shr eax, 2
    mov edx, ecx
    shr edx, 6
    xor eax, edx
    and eax, 1
    mov edx, 0xFFFF00FF                 ; magenta (A B G R)
    test eax, eax
    jnz .checker_store
    mov edx, 0xFF000000                 ; black
.checker_store:
    mov [rsi + rcx * 4], edx
    inc ecx
    cmp ecx, TEX_SIZE * TEX_SIZE
    jb .checker
    mov [rsp + 80], rsi
    mov dword [rsp + 72], GL_UNSIGNED_BYTE
    mov dword [rsp + 64], GL_RGBA
    mov qword [rsp + 56], 1
    mov qword [rsp + 48], TEX_SIZE
    mov qword [rsp + 40], TEX_SIZE
    mov qword [rsp + 32], 0
    GL glTextureSubImage3D, [rel g_tex_array], 0, 0, 0
    ; textures
    mov ebx, 1
.upload:
    cmp ebx, [rel g_tex_count]
    jae .uploaded
    lea rax, [rel g_tex_pixels]
    mov rsi, [rax + rbx * 8]
    test rsi, rsi
    jz .upload_next
    lea rax, [rel g_tex_layer]
    movzx edi, word [rax + rbx * 2]
    lea rax, [rel g_tex_frames]
    movzx eax, byte [rax + rbx]
    mov [rsp + 80], rsi
    mov dword [rsp + 72], GL_UNSIGNED_BYTE
    mov dword [rsp + 64], GL_RGBA
    mov [rsp + 56], rax
    mov qword [rsp + 48], TEX_SIZE
    mov qword [rsp + 40], TEX_SIZE
    mov [rsp + 32], rdi
    GL glTextureSubImage3D, [rel g_tex_array], 0, 0, 0
.upload_next:
    inc ebx
    jmp .upload
.uploaded:
    GL glGenerateTextureMipmap, [rel g_tex_array]
    GL glTextureParameteri, [rel g_tex_array], GL_TEXTURE_MIN_FILTER, GL_NEAREST_MIPMAP_LINEAR
    GL glTextureParameteri, [rel g_tex_array], GL_TEXTURE_MAG_FILTER, GL_NEAREST
    GL glTextureParameteri, [rel g_tex_array], GL_TEXTURE_WRAP_S, GL_REPEAT
    GL glTextureParameteri, [rel g_tex_array], GL_TEXTURE_WRAP_T, GL_REPEAT

    ; ---- block map colours: average of the top face's first frame ------------------
    mov ebx, 1
.colors:
    cmp ebx, [rel g_block_count]
    jae .colors_done
    lea rax, [rel g_block_tex]
    imul rcx, rbx, 12
    movzx eax, word [rax + rcx + 6]     ; +Y face
    lea rcx, [rel g_tex_pixels]
    mov rcx, [rcx + rax * 8]
    mov eax, 0xFFFF00FF
    test rcx, rcx
    jz .color_store
    call average_color
.color_store:
    lea rcx, [rel g_block_colors]
    mov [rcx + rbx * 4], eax
    inc ebx
    jmp .colors
.colors_done:

    ; ---- texture info buffer (uvec4 per texture) -----------------------------------------
    mov eax, [rel g_tex_count]
    shl eax, 4
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, rax, 16
    test rax, rax
    jz .fail
    mov rsi, rax
    xor ebx, ebx
.info:
    cmp ebx, [rel g_tex_count]
    jae .info_done
    mov rdi, rbx
    shl rdi, 4
    add rdi, rsi
    lea rax, [rel g_tex_layer]
    movzx eax, word [rax + rbx * 2]
    mov [rdi], eax
    lea rax, [rel g_tex_frames]
    movzx eax, byte [rax + rbx]
    lea rcx, [rel g_tex_interp]
    movzx ecx, byte [rcx + rbx]
    shl ecx, 16
    or eax, ecx
    mov [rdi + 4], eax
    lea rax, [rel g_tex_frame_ms]
    mov eax, [rax + rbx * 4]
    test eax, eax
    jnz .have_ms
    mov eax, 100
.have_ms:
    mov [rdi + 8], eax
    xor eax, eax
    lea rcx, [rel g_tex_glow]
    movzx ecx, word [rcx + rbx * 2]
    test ecx, ecx
    jz .no_glow
    dec ecx                             ; glow texture index
    lea rax, [rel g_tex_layer]
    movzx eax, word [rax + rcx * 2]
    inc eax
    lea rdx, [rel g_tex_frames]
    movzx edx, byte [rdx + rcx]
    shl edx, 16
    or eax, edx
.no_glow:
    mov [rdi + 12], eax
    inc ebx
    jmp .info
.info_done:
    lea rdx, [rel g_info_buffer]
    GL glCreateBuffers, 1, rdx
    mov edx, [rel g_tex_count]
    shl edx, 4
    GL glNamedBufferStorage, [rel g_info_buffer], rdx, rsi, 0

    ; ---- block face buffer (u32 per block face) ------------------------------------------------
    mov eax, [rel g_block_count]
    imul eax, eax, 24
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, rax, 16
    test rax, rax
    jz .fail
    mov rsi, rax
    xor ebx, ebx                        ; block
.faces:
    cmp ebx, [rel g_block_count]
    jae .faces_done
    lea rax, [rel g_block_flags]
    movzx r8d, byte [rax + rbx]
    and r8d, BLOCKF_SWAY
    lea rax, [rel g_block_layer]
    movzx eax, byte [rax + rbx]
    shl eax, 1
    or r8d, eax
    shl r8d, 16                         ; flags
    ; biome tint: mode (1 grass, 2 foliage) at bit 19 on the tinted faces
    lea rax, [rel g_block_flags]
    movzx r9d, byte [rax + rbx]
    shr r9d, 1
    and r9d, 3                          ; BLOCKF_TINT_GRASS -> 1, FOLIAGE -> 2
    shl r9d, 19
    lea rax, [rel g_block_tintmask]
    movzx r10d, byte [rax + rbx]
    xor ecx, ecx
.face:
    lea rax, [rel g_block_tex]
    imul rdx, rbx, 12
    add rax, rdx
    movzx eax, word [rax + rcx * 2]
    or eax, r8d
    bt r10d, ecx
    jnc .face_untinted
    or eax, r9d
.face_untinted:
    imul rdx, rbx, 24
    add rdx, rsi
    mov [rdx + rcx * 4], eax
    inc ecx
    cmp ecx, 6
    jb .face
    inc ebx
    jmp .faces
.faces_done:
    lea rdx, [rel g_face_buffer]
    GL glCreateBuffers, 1, rdx
    mov edx, [rel g_block_count]
    imul edx, edx, 24
    GL glNamedBufferStorage, [rel g_face_buffer], rdx, rsi, 0

    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(PATH_CAP)]
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_summary]
    call log_append_str
    mov ecx, [rel g_tex_layers]
    call log_append_dec
    lea rcx, [rel str_summary2]
    call log_append_str
    mov ecx, [rel g_bad_count]
    call log_append_dec
    call log_end
    mov eax, 1
    RETURN
.fail:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(PATH_CAP)]
    LOG_ERROR "textures: could not build the block texture array"
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; block_textures_bind — bind the array (unit 0) and the tables (SSBO 1, 2).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC block_textures_bind, 0
    GL glBindTextureUnit, 0, [rel g_tex_array]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 1, [rel g_face_buffer]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 2, [rel g_info_buffer]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; reload_texture — re-read one changed PNG and upload it in place.
;   in:  ecx = texture index, rdx = path
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC reload_texture, 16, rbx, rsi, rdi
    mov ebx, ecx
    mov rsi, rdx
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    mov ecx, ebx
    mov rdx, rsi
    call load_png
    test rax, rax
    jz .done
    mov rdi, rax
    lea rax, [rel g_tex_frames]
    movzx eax, byte [rax + rbx]
    lea rcx, [rel g_tex_layer]
    cmp word [rcx + rbx * 2], 0
    je .changed                         ; was missing: no layers reserved
    cmp eax, edx
    jne .changed
    lea rcx, [rel g_tex_layer]
    movzx ecx, word [rcx + rbx * 2]
    mov [rsp + 80], rdi
    mov dword [rsp + 72], GL_UNSIGNED_BYTE
    mov dword [rsp + 64], GL_RGBA
    mov [rsp + 56], rax
    mov qword [rsp + 48], TEX_SIZE
    mov qword [rsp + 40], TEX_SIZE
    mov [rsp + 32], rcx
    GL glTextureSubImage3D, [rel g_tex_array], 0, 0, 0
    GL glGenerateTextureMipmap, [rel g_tex_array]
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_reloaded]
    call log_append_str
    lea rcx, [rel g_tex_names]
    mov rcx, [rcx + rbx * 8]
    call log_append_str
    call log_end
    jmp .done
.changed:
    lea rcx, [rel g_tex_names]
    mov r8, [rcx + rbx * 8]
    lea rcx, [rel str_label]
    lea rdx, [rel str_frames]
    call cfg_warn
.done:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; block_textures_poll — check a few texture files for changes (round robin).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC block_textures_poll, PATH_CAP, rbx, rsi
    mov esi, POLL_PER_FRAME
.next:
    mov ebx, [rel g_poll_next]
    inc ebx
    cmp ebx, [rel g_tex_count]
    jb .in_range
    mov ebx, 1
    cmp ebx, [rel g_tex_count]
    jae .done                           ; no textures
.in_range:
    mov [rel g_poll_next], ebx
    lea rcx, [LOCAL(0)]
    mov edx, ebx
    call texture_path
    lea rcx, [LOCAL(0)]
    call file_mtime
    test rax, rax
    jz .step                            ; missing (or being written)
    lea rcx, [rel g_tex_mtime]
    cmp rax, [rcx + rbx * 8]
    je .step
    mov [rcx + rbx * 8], rax
    lea rdx, [LOCAL(0)]
    mov ecx, ebx
    call reload_texture
.step:
    dec esi
    jnz .next
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; block_textures_shutdown — free GL objects.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC block_textures_shutdown, 0
    lea rdx, [rel g_tex_array]
    GL glDeleteTextures, 1, rdx
    lea rdx, [rel g_face_buffer]
    GL glDeleteBuffers, 1, rdx
    lea rdx, [rel g_info_buffer]
    GL glDeleteBuffers, 1, rdx
    RETURN
ENDPROC
