; =============================================================================
; world_render.asm — draws the meshed world.
;
; All section quads live in one 128 MB shader storage buffer; the streamer
; (src/world/stream.asm) uploads into ranges handed out by the buddy
; allocator (gpu_alloc.asm). A section's quads are ordered by render layer
; (opaque, cutout, translucent; see mesher.asm), so each layer is one
; glDrawArrays of count*6 vertices; shaders/chunk.vert pulls its quad from
; the buffer (vertex pulling, no vertex buffers). Sections are frustum-culled
; on the CPU (5 planes, bounding sphere).
; Passes: 1 opaque (front to back as the columns come), 2 cutout (alpha
; test, leaves), 3 translucent (blended, depth writes off, sections sorted
; back to front). Milestone 11 moves this to persistent buffers +
; multi-draw-indirect + GPU culling.
;
; Public API:
;   world_render_init() -> eax 1/0      world_render_shutdown()
;   world_render_draw()                 (camera matrices must be current)
;   tint_upload(COLUMN*)                copy a column's biome colours into the
;                                       tint map (main thread, when it becomes ready)
;   g_world_visible, g_world_drawn_quads, g_world_gpu_bytes, g_world_draws
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "memory.inc"
%include "shader.inc"
%include "world_api.inc"

global world_render_init, world_render_draw, world_render_shutdown, tint_upload
global g_world_visible, g_world_drawn_quads, g_world_gpu_bytes, g_quad_buffer
global g_world_draws, g_vis_visited

extern g_cam_viewproj, g_cam_pos
extern g_loaded, g_loaded_count
extern block_textures_init, block_textures_bind, block_textures_shutdown
extern timer_elapsed_us, world_column, vis_pair_bit

%define QUAD_BUFFER_BYTES   (1 << 27)   ; 128 MB = gpu_alloc's 2^18 x 512 B
%define MAX_PASS_ENTRIES    65536       ; per pass and frame (frame arena)
%define ENTRY_SIZE          32          ; rel xyz, world xyz, SECT*
%define MAX_WALK            65536       ; sections the visibility walk visits
%define WALK_SIZE           16
struc WALK
    .col        resq 1
    .sy         resb 1
    .entry      resb 1                  ; faces it was entered through (mask;
                                        ; 0x40 = the start: every exit allowed)
    .dirs       resb 1                  ; directions taken on the way here
    .pad        resb 5
endstruc
; world_render_draw locals (LOCAL(0) is used by the translucent sort)
%define W_CX        8
%define W_CZ        12
%define W_ENTRY     16
%define W_DIRS      20
%define W_VIS       24
%define W_D         28
%define W_NSY       32
%define W_CSY       36                  ; camera section y

; uniform locations (shaders/chunk.vert / chunk.frag)
%define U_VIEWPROJ          0
%define U_ORIGIN_REL        1
%define U_QUAD_BASE         2
%define U_ORIGIN_WORLD      3
%define U_TIME              4
%define U_PASS              5
%define TINT_SIZE           1024        ; tint map texels per side (4 blocks each)

section .rdata
str_vs:         db "shaders/chunk.vert", 0
str_fs:         db "shaders/chunk.frag", 0
align 4
c_half:         dd 16.0                 ; section half size
c_radius:       dd 27.7128129           ; 16 * sqrt(3)
c_million:      dd 1000000.0
c_tint_default: dd 0xFF808080           ; factor 1.0
align 8
c_wrap_us:      dq 3600000000           ; animation clock wraps hourly

section .bss
alignb 4
g_world_prog:       resd 1
g_world_vao:        resd 1
g_quad_buffer:      resd 1
g_tint_tex:         resd 1              ; biome tint map (2D array, 2 layers)
alignb 8
g_world_visible:    resq 1
g_world_drawn_quads: resq 1
g_world_gpu_bytes:  resq 1
g_world_draws:      resq 1
g_vis_visited:      resq 1              ; sections the walk visited this frame
g_vis_stamp:        resw 1
g_cut_list:         resq 1              ; entries this frame
g_cut_count:        resq 1
g_trans_list:       resq 1
g_trans_count:      resq 1
alignb 16
g_planes:           resd 5 * 4          ; normalised frustum planes (xyz, 0)
g_vec_tmp:          resd 4
g_vec_tmp2:         resd 4

section .text

; -----------------------------------------------------------------------------
; world_render_init — create the program, the quad buffer and the textures.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_render_init, 0, rbx
    lea rcx, [rel str_vs]
    lea rdx, [rel str_fs]
    call shader_create
    cmp eax, -1
    je .fail
    mov [rel g_world_prog], eax
    lea rdx, [rel g_world_vao]
    GL glCreateVertexArrays, 1, rdx

    ; quads: one buffer for the whole streamed world
    mov qword [rel g_world_gpu_bytes], QUAD_BUFFER_BYTES
    lea rdx, [rel g_quad_buffer]
    GL glCreateBuffers, 1, rdx
    GL glNamedBufferStorage, [rel g_quad_buffer], QUAD_BUFFER_BYTES, 0, GL_DYNAMIC_STORAGE_BIT
    LOG_INFO "world: quad buffer created (128 MB)"

    call block_textures_init
    test eax, eax
    jz .fail

    ; biome tint map: 1024 x 1024 texels per layer, one per 4 x 4 blocks,
    ; repeating every 4096 blocks (the loaded world is always smaller);
    ; linear filtering blends neighbouring columns smoothly
    lea r8, [rel g_tint_tex]
    GL glCreateTextures, GL_TEXTURE_2D_ARRAY, 1, r8
    mov qword [rsp + 40], 2             ; depth: 2 layers
    GL glTextureStorage3D, [rel g_tint_tex], 1, GL_RGBA8, TINT_SIZE, TINT_SIZE
    GL glTextureParameteri, [rel g_tint_tex], GL_TEXTURE_MIN_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_tint_tex], GL_TEXTURE_MAG_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_tint_tex], GL_TEXTURE_WRAP_S, GL_REPEAT
    GL glTextureParameteri, [rel g_tint_tex], GL_TEXTURE_WRAP_T, GL_REPEAT
    lea rax, [rel c_tint_default]
    mov [rsp + 32], rax
    GL glClearTexImage, [rel g_tint_tex], 0, GL_RGBA, GL_UNSIGNED_BYTE

    GL glEnable, GL_CULL_FACE
    mov eax, 1
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; world_render_shutdown — free GL objects.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_render_shutdown, 0
    call block_textures_shutdown
    lea rdx, [rel g_tint_tex]
    GL glDeleteTextures, 1, rdx
    lea rdx, [rel g_quad_buffer]
    GL glDeleteBuffers, 1, rdx
    lea rdx, [rel g_world_vao]
    GL glDeleteVertexArrays, 1, rdx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; build_planes — extract and normalise 5 frustum planes (left, right,
; bottom, top, front) from the camera-relative view-projection matrix.
; All planes pass through the camera (w = 0 in camera-relative space).
;   clobbers: rax, rcx, rdx, xmm0-xmm4
; -----------------------------------------------------------------------------
build_planes:
    lea rax, [rel g_cam_viewproj]
    lea rcx, [rel g_vec_tmp]
%macro ROW_TO 2                         ; dst xmm, row
    mov edx, [rax + %2 * 4]
    mov [rcx], edx
    mov edx, [rax + 16 + %2 * 4]
    mov [rcx + 4], edx
    mov edx, [rax + 32 + %2 * 4]
    mov [rcx + 8], edx
    mov dword [rcx + 12], 0
    movaps %1, [rcx]
%endmacro
    ROW_TO xmm0, 0
    ROW_TO xmm1, 1
    ROW_TO xmm3, 3
    lea rcx, [rel g_planes]
    movaps xmm2, xmm3
    addps xmm2, xmm0
    movaps [rcx], xmm2                  ; left
    movaps xmm2, xmm3
    subps xmm2, xmm0
    movaps [rcx + 16], xmm2             ; right
    movaps xmm2, xmm3
    addps xmm2, xmm1
    movaps [rcx + 32], xmm2             ; bottom
    movaps xmm2, xmm3
    subps xmm2, xmm1
    movaps [rcx + 48], xmm2             ; top
    movaps [rcx + 64], xmm3             ; front
    xor eax, eax
.norm:
    movaps xmm0, [rcx + rax]
    movaps xmm1, xmm0
    mulps xmm1, xmm1
    movaps xmm2, xmm1
    shufps xmm2, xmm2, 0b01_01_01_01
    addss xmm1, xmm2
    movaps xmm2, [rcx + rax]
    mulps xmm2, xmm2
    shufps xmm2, xmm2, 0b10_10_10_10
    addss xmm1, xmm2
    sqrtss xmm1, xmm1
    shufps xmm1, xmm1, 0
    divps xmm0, xmm1
    movaps [rcx + rax], xmm0
    add eax, 16
    cmp eax, 80
    jb .norm
    ret

; -----------------------------------------------------------------------------
; xyz_origins — camera-relative origin (exact: computed in double) and
; wrapped world origin (mod 65536, for animation phases) of a section,
; into g_vec_tmp (rel xyz) and g_vec_tmp2 (world xyz).
;   in:  ecx = cx, edx = sy, r8d = cz
;   clobbers: rax, rcx, rdx, xmm0
; -----------------------------------------------------------------------------
xyz_origins:
    mov eax, ecx
    shl eax, 5
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos]
    cvtsd2ss xmm0, xmm0
    movss [rel g_vec_tmp], xmm0
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    movss [rel g_vec_tmp2], xmm0
    mov eax, edx
    shl eax, 5
    add eax, WORLD_MIN_Y
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos + 8]
    cvtsd2ss xmm0, xmm0
    movss [rel g_vec_tmp + 4], xmm0
    cvtsi2ss xmm0, eax
    movss [rel g_vec_tmp2 + 4], xmm0
    mov eax, r8d
    shl eax, 5
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos + 16]
    cvtsd2ss xmm0, xmm0
    movss [rel g_vec_tmp + 8], xmm0
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    movss [rel g_vec_tmp2 + 8], xmm0
    mov dword [rel g_vec_tmp + 12], 0
    ret

; -----------------------------------------------------------------------------
; sphere_in_frustum — is the section at g_vec_tmp (rel origin) inside the 5
; frustum planes (bounding sphere)?
;   out: eax = 1/0   clobbers: rax, rcx, xmm0-xmm3
; -----------------------------------------------------------------------------
sphere_in_frustum:
    lea rcx, [rel g_vec_tmp]
    movss xmm3, [rcx]
    movss xmm0, [rcx + 4]
    unpcklps xmm3, xmm0
    movss xmm0, [rcx + 8]
    movlhps xmm3, xmm0                  ; (x, y, z, 0)
    movss xmm0, [rel c_half]
    shufps xmm0, xmm0, 0
    addps xmm3, xmm0                    ; centre
    lea rax, [rel g_planes]
    xor ecx, ecx
.plane:
    movaps xmm0, [rax + rcx]
    mulps xmm0, xmm3
    movaps xmm1, xmm0
    shufps xmm1, xmm1, 0b01_01_01_01
    addss xmm0, xmm1
    movaps xmm1, [rax + rcx]
    mulps xmm1, xmm3
    shufps xmm1, xmm1, 0b10_10_10_10
    addss xmm0, xmm1                    ; signed distance
    addss xmm0, [rel c_radius]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jb .out
    add ecx, 16
    cmp ecx, 80
    jb .plane
    mov eax, 1
    ret
.out:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; tint_upload — copy a column's biome colours (COLUMN.tint, 8 x 8 texels per
; layer) into the tint map at its place (cx * 8, cz * 8, wrapped).
;   in:  rcx = COLUMN*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC tint_upload, 0, rbx
    mov rbx, rcx
    cmp dword [rbx + COLUMN.tint], 0
    je .done                            ; no biome data (flat world): default
    lea rax, [rbx + COLUMN.tint]
    mov [rsp + 80], rax                 ; pixels
    mov qword [rsp + 72], GL_UNSIGNED_BYTE
    mov qword [rsp + 64], GL_RGBA
    mov qword [rsp + 56], 2             ; depth (layers)
    mov qword [rsp + 48], 8
    mov qword [rsp + 40], 8
    mov qword [rsp + 32], 0             ; z offset
    mov r8d, [rbx + COLUMN.cx]
    shl r8d, 3
    and r8d, TINT_SIZE - 1
    mov r9d, [rbx + COLUMN.cz]
    shl r9d, 3
    and r9d, TINT_SIZE - 1
    GL glTextureSubImage3D, [rel g_tint_tex], 0, r8, r9
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; draw_range — draw `count` quads of a section starting at quad `first`.
;   in:  ecx = program, rdx = entry (rel xyz, world xyz), r8d = first,
;        r9d = count
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC draw_range, 0, rbx, rsi, rdi, r12
    mov ebx, ecx
    mov rsi, rdx
    mov edi, r8d
    mov r12d, r9d
    add [rel g_world_drawn_quads], r12
    inc qword [rel g_world_draws]
    GL glProgramUniform3fv, rbx, U_ORIGIN_REL, 1, rsi
    GL glProgramUniform1ui, rbx, U_QUAD_BASE, rdi
    lea r9, [rsi + 12]
    GL glProgramUniform3fv, rbx, U_ORIGIN_WORLD, 1, r9
    imul r8d, r12d, 6
    GL glDrawArrays, GL_TRIANGLES, 0, r8
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; world_render_draw — cull, then draw the opaque, cutout and translucent
; layers of every visible section.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_render_draw, 64, rbx, rsi, rdi, r12, r13, r14, r15
    xor eax, eax
    mov [rel g_world_visible], rax
    mov [rel g_world_drawn_quads], rax
    mov [rel g_world_draws], rax
    mov [rel g_cut_count], rax
    mov [rel g_trans_count], rax
    call build_planes
    lea rcx, [rel g_arena_frame]
    INVOKE arena_alloc, rcx, MAX_PASS_ENTRIES * ENTRY_SIZE, 16
    mov [rel g_cut_list], rax
    lea rcx, [rel g_arena_frame]
    INVOKE arena_alloc, rcx, MAX_PASS_ENTRIES * ENTRY_SIZE, 16
    mov [rel g_trans_list], rax
    test rax, rax
    jz .done
    cmp qword [rel g_cut_list], 0
    je .done

    mov ecx, [rel g_world_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    lea rax, [rel g_cam_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, rbx, U_VIEWPROJ, 1, GL_FALSE
    ; animation clock (seconds, wraps hourly)
    call timer_elapsed_us
    xor edx, edx
    div qword [rel c_wrap_us]
    cvtsi2ss xmm2, rdx
    divss xmm2, [rel c_million]
    GL glProgramUniform1f, rbx, U_TIME
    GL glProgramUniform1i, rbx, U_PASS, 0
    GL glBindVertexArray, [rel g_world_vao]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 0, [rel g_quad_buffer]
    call block_textures_bind
    GL glBindTextureUnit, 3, [rel g_tint_tex]

    ; ---- pass 1: visibility walk from the camera's section (cave culling) -------
    ; Breadth-first over sections (DECISIONS D51): leave a section through
    ; face d only if one of the faces it was entered through connects to d
    ; (SECT.vis, the mesher's flood fill), never turn back against a direction
    ; the path already took, and only go into sections inside the frustum.
    ; A section reached by several paths keeps all their entry faces and
    ; allowed directions. The camera's section and its 26 neighbours pass
    ; everything. Visited sections with geometry are drawn (opaque now,
    ; cutout / translucent collected for passes 2 and 3).
    inc word [rel g_vis_stamp]
    jnz .stamp_ok
    inc word [rel g_vis_stamp]
.stamp_ok:
    mov qword [rel g_vis_visited], 0
    lea rcx, [rel g_arena_frame]
    INVOKE arena_alloc, rcx, MAX_WALK * WALK_SIZE, 16
    test rax, rax
    jz .pass2
    mov r14, rax                        ; queue
    xor r12d, r12d                      ; head
    xor r13d, r13d                      ; tail
    ; camera section
    movsd xmm0, [rel g_cam_pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    mov [LOCAL(W_CX)], eax
    movsd xmm0, [rel g_cam_pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    mov [LOCAL(W_CZ)], eax
    movsd xmm0, [rel g_cam_pos + 8]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sub rax, WORLD_MIN_Y
    sar rax, 5
    cmp rax, 0
    jge .sy_lo
    xor eax, eax
.sy_lo:
    cmp rax, SECTIONS_PER_COLUMN - 1
    jle .sy_hi
    mov eax, SECTIONS_PER_COLUMN - 1
.sy_hi:
    mov esi, eax
    mov [LOCAL(W_CSY)], eax
    mov ecx, [LOCAL(W_CX)]
    mov edx, [LOCAL(W_CZ)]
    call world_column
    test rax, rax
    jz .pass2                           ; camera column not loaded yet
    mov [r14 + WALK.col], rax
    mov [r14 + WALK.sy], sil
    mov byte [r14 + WALK.entry], 0x40
    mov byte [r14 + WALK.dirs], 0
    mov cx, [rel g_vis_stamp]
    mov [rax + COLUMN.vstamp + rsi * 2], cx
    mov dword [rax + COLUMN.vqueue + rsi * 4], 0
    mov r13d, 1
.walk:
    cmp r12d, r13d
    jae .pass2
    mov rax, r12
    shl rax, 4
    add rax, r14                        ; entry
    inc r12d
    mov rsi, [rax + WALK.col]
    movzx edi, byte [rax + WALK.sy]
    movzx ecx, byte [rax + WALK.entry]
    mov [LOCAL(W_ENTRY)], ecx
    movzx ecx, byte [rax + WALK.dirs]
    mov [LOCAL(W_DIRS)], ecx
    inc qword [rel g_vis_visited]
    ; ---- draw it (if meshed with quads) ----
    cmp dword [rsi + COLUMN.state], COL_READY
    jne .expand
    bt qword [rsi + COLUMN.geo_mask], rdi
    jnc .expand
    mov r15, [rsi + COLUMN.sections + rdi * 8]   ; SECT*
    INVOKE xyz_origins, [rsi + COLUMN.cx], rdi, [rsi + COLUMN.cz]
    call sphere_in_frustum
    test eax, eax
    jz .expand                          ; (the start section can be outside)
    inc qword [rel g_world_visible]
    mov eax, [r15 + SECT.quad_cutout]
    test eax, eax
    jz .no_cut
    mov rax, [rel g_cut_count]
    cmp rax, MAX_PASS_ENTRIES
    jae .no_cut
    shl rax, 5
    add rax, [rel g_cut_list]
    lea rcx, [rel g_vec_tmp]
    movups xmm0, [rcx]
    movups [rax], xmm0
    movq xmm0, [rcx + 16]
    movq [rax + 16], xmm0
    mov [rax + 24], r15
    inc qword [rel g_cut_count]
.no_cut:
    mov eax, [r15 + SECT.quad_count]
    sub eax, [r15 + SECT.quad_opaque]
    sub eax, [r15 + SECT.quad_cutout]
    jz .no_trans
    mov rax, [rel g_trans_count]
    cmp rax, MAX_PASS_ENTRIES
    jae .no_trans
    shl rax, 5
    add rax, [rel g_trans_list]
    lea rcx, [rel g_vec_tmp]
    movups xmm0, [rcx]
    movups [rax], xmm0
    movq xmm0, [rcx + 16]
    movq [rax + 16], xmm0
    mov [rax + 24], r15
    inc qword [rel g_trans_count]
.no_trans:
    mov r9d, [r15 + SECT.quad_opaque]
    test r9d, r9d
    jz .expand
    mov r8d, [r15 + SECT.quad_first]
    lea rdx, [rel g_vec_tmp]
    mov ecx, ebx
    call draw_range
    ; ---- expand to the 6 neighbours ----
.expand:
    ; visibility bits of this section (unknown or empty: everything passes;
    ; also the sections right around the camera, where 32-block sections are
    ; too coarse for the walk's rules)
    mov eax, 0x7FFF
    mov ecx, [rsi + COLUMN.cx]
    sub ecx, [LOCAL(W_CX)]
    add ecx, 1
    cmp ecx, 2
    ja .far
    mov ecx, [rsi + COLUMN.cz]
    sub ecx, [LOCAL(W_CZ)]
    add ecx, 1
    cmp ecx, 2
    ja .far
    mov ecx, edi
    sub ecx, [LOCAL(W_CSY)]
    add ecx, 1
    cmp ecx, 2
    jbe .have_vis
.far:
    cmp dword [rsi + COLUMN.state], COL_MESHED
    jb .have_vis
    mov rcx, [rsi + COLUMN.sections + rdi * 8]
    test rcx, rcx
    jz .have_vis
    movzx eax, word [rcx + SECT.vis]
.have_vis:
    mov [LOCAL(W_VIS)], eax
    mov dword [LOCAL(W_D)], 0
.dir:
    mov ecx, [LOCAL(W_D)]
    cmp ecx, 6
    jae .walk
    ; never against a direction already taken
    mov eax, ecx
    xor eax, 1                          ; opposite face
    bt dword [LOCAL(W_DIRS)], eax
    jc .dir_next
    ; through this section from any entry face to face d?
    mov eax, [LOCAL(W_ENTRY)]
    test eax, 0x40
    jnz .passable                       ; the start section
    xor edx, edx                        ; faces connected to d
    xor r8d, r8d                        ; e
.conn:
    imul r9d, r8d, 6
    add r9d, ecx
    lea r10, [rel vis_pair_bit]
    movzx r9d, byte [r10 + r9]
    cmp r9d, 15
    jae .conn_next                      ; (e == d)
    bt dword [LOCAL(W_VIS)], r9d
    jnc .conn_next
    bts edx, r8d
.conn_next:
    inc r8d
    cmp r8d, 6
    jb .conn
    test eax, edx
    jnz .passable
    jmp .dir_next
.passable:
    ; neighbour section
    mov r8d, [rsi + COLUMN.cx]
    mov r9d, [rsi + COLUMN.cz]
    mov r10d, edi                       ; sy
    cmp ecx, 0
    jne .d1
    dec r8d
    jmp .lookup
.d1:
    cmp ecx, 1
    jne .d2
    inc r8d
    jmp .lookup
.d2:
    cmp ecx, 2
    jne .d3
    dec r10d
    js .dir_next
    mov r15, rsi
    jmp .have_col
.d3:
    cmp ecx, 3
    jne .d4
    inc r10d
    cmp r10d, SECTIONS_PER_COLUMN
    jae .dir_next
    mov r15, rsi
    jmp .have_col
.d4:
    cmp ecx, 4
    jne .d5
    dec r9d
    jmp .lookup
.d5:
    inc r9d
.lookup:
    mov [LOCAL(W_NSY)], r10d
    mov ecx, r8d
    mov edx, r9d
    call world_column
    test rax, rax
    jz .dir_next                        ; not loaded
    mov r15, rax
    mov r10d, [LOCAL(W_NSY)]
.have_col:
    mov [LOCAL(W_NSY)], r10d
    mov ax, [rel g_vis_stamp]
    cmp [r15 + COLUMN.vstamp + r10 * 2], ax
    jne .new_section
    ; reached again: if it is still waiting in the queue, remember this
    ; entry face too (a section can be seen through any of its entries)
    mov eax, [r15 + COLUMN.vqueue + r10 * 4]
    cmp eax, r12d
    jb .dir_next                        ; already processed
    shl rax, 4
    add rax, r14
    mov ecx, [LOCAL(W_D)]
    xor ecx, 1
    bts dword [rax + WALK.entry], ecx   ; (entry is the low byte)
    ; and allow what this path allows: every path to a section has the same
    ; length (no turning back), so all of them arrive while it is queued
    mov edx, [LOCAL(W_DIRS)]
    xor ecx, 1                          ; d
    bts edx, ecx
    and [rax + WALK.dirs], dl
    jmp .dir_next
.new_section:
    mov [r15 + COLUMN.vstamp + r10 * 2], ax
    mov dword [r15 + COLUMN.vqueue + r10 * 4], 0   ; (not queued)
    INVOKE xyz_origins, [r15 + COLUMN.cx], r10, [r15 + COLUMN.cz]
    call sphere_in_frustum
    test eax, eax
    jz .dir_next
    cmp r13d, MAX_WALK
    jae .dir_next
    mov r10d, [LOCAL(W_NSY)]
    mov [r15 + COLUMN.vqueue + r10 * 4], r13d
    mov rax, r13
    shl rax, 4
    add rax, r14
    inc r13d
    mov [rax + WALK.col], r15
    mov ecx, [LOCAL(W_NSY)]
    mov [rax + WALK.sy], cl
    mov ecx, [LOCAL(W_D)]
    xor ecx, 1
    mov r8d, 1
    shl r8d, cl                         ; entry face = opposite of d
    xor ecx, 1
    mov [rax + WALK.entry], r8b
    mov edx, [LOCAL(W_DIRS)]
    bts edx, ecx
    mov [rax + WALK.dirs], dl
.dir_next:
    inc dword [LOCAL(W_D)]
    jmp .dir

    ; ---- pass 2: cutout (alpha-tested) -----------------------------------------------------
.pass2:
    GL glProgramUniform1i, rbx, U_PASS, 1
    GL glDisable, GL_CULL_FACE          ; plants are single planes seen from both sides
    xor r12d, r12d
.cut:
    cmp r12, [rel g_cut_count]
    jae .pass3
    mov rdx, r12
    shl rdx, 5
    add rdx, [rel g_cut_list]
    mov rax, [rdx + 24]
    mov r8d, [rax + SECT.quad_first]
    add r8d, [rax + SECT.quad_opaque]
    mov r9d, [rax + SECT.quad_cutout]
    mov ecx, ebx
    call draw_range
    inc r12
    jmp .cut

    ; ---- pass 3: translucent, sorted back to front ------------------------------------
.pass3:
    GL glEnable, GL_CULL_FACE
    mov r15, [rel g_trans_count]
    test r15, r15
    jz .done
    ; insertion sort by distance to the section centre, far first
    mov r14, [rel g_trans_list]
    mov r12d, 1
.sort_outer:
    cmp r12, r15
    jae .sorted
    mov rax, r12
    shl rax, 5
    movups xmm4, [r14 + rax]            ; entry being inserted (32 bytes)
    movups xmm5, [r14 + rax + 16]
    lea rcx, [r14 + rax]
    call entry_dist
    movss [LOCAL(0)], xmm0              ; its distance
    mov r13, r12
.sort_inner:
    test r13, r13
    jz .sort_place
    lea rcx, [r13 - 1]
    shl rcx, 5
    add rcx, r14
    call entry_dist
    comiss xmm0, [LOCAL(0)]
    jae .sort_place                     ; previous is farther: stop
    lea rcx, [r13 - 1]
    shl rcx, 5
    add rcx, r14
    movups xmm0, [rcx]
    movups xmm1, [rcx + 16]
    movups [rcx + 32], xmm0
    movups [rcx + 48], xmm1
    dec r13
    jmp .sort_inner
.sort_place:
    mov rax, r13
    shl rax, 5
    movups [r14 + rax], xmm4
    movups [r14 + rax + 16], xmm5
    inc r12
    jmp .sort_outer
.sorted:
    GL glProgramUniform1i, rbx, U_PASS, 2
    GL glEnable, GL_BLEND
    GL glBlendFunc, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA
    GL glDepthMask, GL_FALSE
    xor r12d, r12d
.trans:
    cmp r12, r15
    jae .trans_done
    mov rdx, r12
    shl rdx, 5
    add rdx, r14
    mov rax, [rdx + 24]
    mov r8d, [rax + SECT.quad_first]
    add r8d, [rax + SECT.quad_opaque]
    add r8d, [rax + SECT.quad_cutout]
    mov r9d, [rax + SECT.quad_count]
    sub r9d, [rax + SECT.quad_opaque]
    sub r9d, [rax + SECT.quad_cutout]
    mov ecx, ebx
    call draw_range
    inc r12
    jmp .trans
.trans_done:
    GL glDepthMask, GL_TRUE
    GL glDisable, GL_BLEND
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; entry_dist — squared distance from the camera to a pass entry's section
; centre.
;   in:  rcx = entry (rel xyz first)    out: xmm0
;   clobbers: xmm0, xmm1, xmm2
; -----------------------------------------------------------------------------
entry_dist:
    movss xmm0, [rcx]
    addss xmm0, [rel c_half]
    mulss xmm0, xmm0
    movss xmm1, [rcx + 4]
    addss xmm1, [rel c_half]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [rcx + 8]
    addss xmm1, [rel c_half]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    ret
