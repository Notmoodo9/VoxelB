; =============================================================================
; world_render.asm — draws the meshed world.
;
; All section quads live in one 128 MB shader storage buffer; the streamer
; (src/world/stream.asm) uploads into ranges handed out by the buddy
; allocator (gpu_alloc.asm). Each visible section of a READY column is one
; glDrawArrays of quad_count*6 vertices; shaders/chunk.vert pulls its quad
; from the buffer (vertex pulling, no vertex buffers). Sections are
; frustum-culled on the CPU (5 planes, bounding sphere). Milestone 11 moves
; this to persistent buffers + multi-draw-indirect + GPU culling.
;
; Public API:
;   world_render_init() -> eax 1/0      world_render_shutdown()
;   world_render_draw()                 (camera matrices must be current)
;   g_world_visible, g_world_drawn_quads, g_world_gpu_bytes
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "memory.inc"
%include "shader.inc"
%include "world_api.inc"

global world_render_init, world_render_draw, world_render_shutdown
global g_world_visible, g_world_drawn_quads, g_world_gpu_bytes, g_quad_buffer

extern g_cam_viewproj, g_cam_pos
extern g_block_colors
extern g_loaded, g_loaded_count

%define QUAD_BUFFER_BYTES   (1 << 27)   ; 128 MB = gpu_alloc's 2^18 x 512 B

section .rdata
str_vs:         db "shaders/chunk.vert", 0
str_fs:         db "shaders/chunk.frag", 0
align 4
c_half:         dd 16.0                 ; section half size
c_radius:       dd 27.7128129           ; 16 * sqrt(3)
c_min_y:        dd -256.0
align 16
c_abs_mask:     dd 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF

section .bss
alignb 4
g_world_prog:       resd 1
g_world_vao:        resd 1
g_quad_buffer:      resd 1
g_color_buffer:     resd 1
alignb 8
g_world_visible:    resq 1
g_world_drawn_quads: resq 1
g_world_gpu_bytes:  resq 1
alignb 16
g_planes:           resd 5 * 4          ; normalised frustum planes (xyz, 0)
g_vec_tmp:          resd 4
g_vec_tmp2:         resd 4

section .text

; -----------------------------------------------------------------------------
; world_render_init — upload the meshes and create the program.
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

    ; block colours (debug table)
    lea rdx, [rel g_color_buffer]
    GL glCreateBuffers, 1, rdx
    lea r8, [rel g_block_colors]
    GL glNamedBufferStorage, [rel g_color_buffer], MAX_BLOCK_TYPES * 4, r8, 0

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
    lea rdx, [rel g_quad_buffer]
    GL glDeleteBuffers, 1, rdx
    lea rdx, [rel g_color_buffer]
    GL glDeleteBuffers, 1, rdx
    lea rdx, [rel g_world_vao]
    GL glDeleteVertexArrays, 1, rdx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; build_planes — extract and normalise 5 frustum planes (left, right,
; bottom, top, front) from the camera-relative view-projection matrix.
; All planes pass through the camera (w = 0 in camera-relative space).
;   clobbers: rax, rcx, xmm0-xmm4
; -----------------------------------------------------------------------------
build_planes:
    lea rax, [rel g_cam_viewproj]
    ; rows as xyz vectors: row r = (m[r], m[4+r], m[8+r])
    ; build row0, row1, row3 in xmm0, xmm1, xmm3 (x, y, z, 0)
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
    ; normalise each plane
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
; world_render_draw — cull and draw every section that has geometry.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_render_draw, 32, rbx, rsi, rdi, r12, r13
    xor eax, eax
    mov [rel g_world_visible], rax
    mov [rel g_world_drawn_quads], rax
    call build_planes

    mov ecx, [rel g_world_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    lea rax, [rel g_cam_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, rbx, 0, 1, GL_FALSE
    GL glBindVertexArray, [rel g_world_vao]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 0, [rel g_quad_buffer]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 1, [rel g_color_buffer]

    xor r12d, r12d                      ; loaded column index
.column:
    cmp r12, [rel g_loaded_count]
    jae .done
    mov rax, [rel g_loaded]
    mov rsi, [rax + r12 * 8]            ; COLUMN*
    inc r12
    cmp dword [rsi + COLUMN.state], COL_READY
    jne .column
    mov rdi, [rsi + COLUMN.geo_mask]    ; sections with quads
.next:
    test rdi, rdi
    jz .column
    bsf rax, rdi
    btr rdi, rax
    mov r13, [rsi + COLUMN.sections + rax * 8]   ; SECT*
    ; camera-relative origin (computed in double: exact far from the origin)
    ; and a wrapped world origin for the per-block patterns (mod 65536)
    lea rcx, [rel g_vec_tmp]            ; rel origin
    lea rdx, [rel g_vec_tmp2]           ; pattern origin
    mov eax, [r13 + SECT.cx]
    shl eax, 5
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos]
    cvtsd2ss xmm0, xmm0
    movss [rcx], xmm0
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    movss [rdx], xmm0
    mov eax, [r13 + SECT.sy]
    shl eax, 5
    add eax, WORLD_MIN_Y
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos + 8]
    cvtsd2ss xmm0, xmm0
    movss [rcx + 4], xmm0
    cvtsi2ss xmm0, eax
    movss [rdx + 4], xmm0
    mov eax, [r13 + SECT.cz]
    shl eax, 5
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos + 16]
    cvtsd2ss xmm0, xmm0
    movss [rcx + 8], xmm0
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    movss [rdx + 8], xmm0
    mov dword [rcx + 12], 0
    ; sphere centre = rel + 16
    movaps xmm3, [rcx]
    movss xmm0, [rel c_half]
    shufps xmm0, xmm0, 0
    addps xmm3, xmm0
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
    jb .skip                            ; completely outside this plane
    add ecx, 16
    cmp ecx, 80
    jb .plane

    inc qword [rel g_world_visible]
    mov eax, [r13 + SECT.quad_count]
    add [rel g_world_drawn_quads], rax
    lea r9, [rel g_vec_tmp]
    GL glProgramUniform3fv, rbx, 1, 1, r9               ; u_origin_rel
    mov r8d, [r13 + SECT.quad_first]
    GL glProgramUniform1ui, rbx, 2, r8                  ; u_quad_base
    lea r9, [rel g_vec_tmp2]
    GL glProgramUniform3fv, rbx, 3, 1, r9               ; u_origin_world
    mov r8d, [r13 + SECT.quad_count]
    imul r8d, r8d, 6
    GL glDrawArrays, GL_TRIANGLES, 0, r8
.skip:
    jmp .next
.done:
    RETURN
ENDPROC
