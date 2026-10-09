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
;   g_world_visible, g_world_drawn_quads, g_world_gpu_bytes, g_world_draws
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "memory.inc"
%include "shader.inc"
%include "world_api.inc"

global world_render_init, world_render_draw, world_render_shutdown
global g_world_visible, g_world_drawn_quads, g_world_gpu_bytes, g_quad_buffer
global g_world_draws

extern g_cam_viewproj, g_cam_pos
extern g_loaded, g_loaded_count
extern block_textures_init, block_textures_bind, block_textures_shutdown
extern timer_elapsed_us

%define QUAD_BUFFER_BYTES   (1 << 27)   ; 128 MB = gpu_alloc's 2^18 x 512 B
%define MAX_PASS_ENTRIES    65536       ; per pass and frame (frame arena)
%define ENTRY_SIZE          32          ; rel xyz, world xyz, SECT*

; uniform locations (shaders/chunk.vert / chunk.frag)
%define U_VIEWPROJ          0
%define U_ORIGIN_REL        1
%define U_QUAD_BASE         2
%define U_ORIGIN_WORLD      3
%define U_TIME              4
%define U_PASS              5

section .rdata
str_vs:         db "shaders/chunk.vert", 0
str_fs:         db "shaders/chunk.frag", 0
align 4
c_half:         dd 16.0                 ; section half size
c_radius:       dd 27.7128129           ; 16 * sqrt(3)
c_million:      dd 1000000.0
align 8
c_wrap_us:      dq 3600000000           ; animation clock wraps hourly

section .bss
alignb 4
g_world_prog:       resd 1
g_world_vao:        resd 1
g_quad_buffer:      resd 1
alignb 8
g_world_visible:    resq 1
g_world_drawn_quads: resq 1
g_world_gpu_bytes:  resq 1
g_world_draws:      resq 1
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
; section_origins — camera-relative origin (exact: computed in double) and
; wrapped world origin (mod 65536, for animation phases) of a section.
;   in:  rcx = SECT*, rdx = out (6 floats: rel xyz, world xyz)
;   clobbers: rax, xmm0
; -----------------------------------------------------------------------------
section_origins:
    mov eax, [rcx + SECT.cx]
    shl eax, 5
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos]
    cvtsd2ss xmm0, xmm0
    movss [rdx], xmm0
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    movss [rdx + 12], xmm0
    mov eax, [rcx + SECT.sy]
    shl eax, 5
    add eax, WORLD_MIN_Y
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos + 8]
    cvtsd2ss xmm0, xmm0
    movss [rdx + 4], xmm0
    cvtsi2ss xmm0, eax
    movss [rdx + 16], xmm0
    mov eax, [rcx + SECT.cz]
    shl eax, 5
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos + 16]
    cvtsd2ss xmm0, xmm0
    movss [rdx + 8], xmm0
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    movss [rdx + 20], xmm0
    ret

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
PROC world_render_draw, 32, rbx, rsi, rdi, r12, r13, r14, r15
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

    ; ---- pass 1: cull, draw opaque, collect cutout / translucent ---------------------
    xor r12d, r12d                      ; loaded column index
.column:
    cmp r12, [rel g_loaded_count]
    jae .pass2
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
    mov rcx, r13
    lea rdx, [rel g_vec_tmp]            ; rel xyz + world xyz (spills into tmp2)
    call section_origins
    ; sphere centre = rel + 16
    lea rcx, [rel g_vec_tmp]
    movss xmm3, [rcx]
    movss xmm0, [rcx + 4]
    unpcklps xmm3, xmm0
    movss xmm0, [rcx + 8]
    movlhps xmm3, xmm0                  ; (x, y, z, 0)
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
    jb .next                            ; completely outside this plane
    add ecx, 16
    cmp ecx, 80
    jb .plane

    inc qword [rel g_world_visible]
    ; remember the section for the later passes
    mov eax, [r13 + SECT.quad_cutout]
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
    mov [rax + 24], r13
    inc qword [rel g_cut_count]
.no_cut:
    mov eax, [r13 + SECT.quad_count]
    sub eax, [r13 + SECT.quad_opaque]
    sub eax, [r13 + SECT.quad_cutout]
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
    mov [rax + 24], r13
    inc qword [rel g_trans_count]
.no_trans:
    mov r9d, [r13 + SECT.quad_opaque]
    test r9d, r9d
    jz .next
    mov r8d, [r13 + SECT.quad_first]
    lea rdx, [rel g_vec_tmp]
    mov ecx, ebx
    call draw_range
    jmp .next

    ; ---- pass 2: cutout (alpha-tested) -----------------------------------------------------
.pass2:
    GL glProgramUniform1i, rbx, U_PASS, 1
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
