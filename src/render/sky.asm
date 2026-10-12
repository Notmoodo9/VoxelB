; =============================================================================
; sky.asm — draws the sky into the scene target before the world
; (milestone 14): one screen-covering triangle (shaders/fullscreen.vert +
; shaders/sky.frag) at the far plane, without depth test or depth writes;
; the world drawn afterwards covers it.
;
; Public API:
;   sky_init() -> eax 1/0      sky_draw()      sky_shutdown()
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "shader.inc"

global sky_init, sky_draw, sky_shutdown

extern g_cam_viewproj, g_sun_dir, timer_elapsed_us

%define U_VIEWPROJ      0
%define U_SUN_DIR       4
%define U_TIME          5

section .rdata
str_vs:         db "shaders/fullscreen.vert", 0
str_fs:         db "shaders/sky.frag", 0
align 8
c_wrap_us:      dq 3600000000
align 4
c_million:      dd 1000000.0

section .bss
alignb 4
g_sky_prog:     resd 1
g_sky_vao:      resd 1

section .text

; -----------------------------------------------------------------------------
; sky_init — the sky program and an empty vertex array.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC sky_init, 0
    lea rcx, [rel str_vs]
    lea rdx, [rel str_fs]
    call shader_create
    cmp eax, -1
    je .fail
    mov [rel g_sky_prog], eax
    lea rdx, [rel g_sky_vao]
    GL glCreateVertexArrays, 1, rdx
    mov eax, 1
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; sky_draw — the sky over the whole (bound) target.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC sky_draw, 0, rbx
    mov ecx, [rel g_sky_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    lea rax, [rel g_cam_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, rbx, U_VIEWPROJ, 1, GL_FALSE
    lea r9, [rel g_sun_dir]
    GL glProgramUniform3fv, rbx, U_SUN_DIR, 1, r9
    call timer_elapsed_us
    xor edx, edx
    div qword [rel c_wrap_us]
    cvtsi2ss xmm2, rdx
    divss xmm2, [rel c_million]
    GL glProgramUniform1f, rbx, U_TIME
    GL glDisable, GL_DEPTH_TEST
    GL glDepthMask, GL_FALSE
    GL glBindVertexArray, [rel g_sky_vao]
    GL glDrawArrays, GL_TRIANGLES, 0, 3
    GL glDepthMask, GL_TRUE
    GL glEnable, GL_DEPTH_TEST
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; sky_shutdown — free the vertex array.   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC sky_shutdown, 0
    lea rdx, [rel g_sky_vao]
    GL glDeleteVertexArrays, 1, rdx
    RETURN
ENDPROC
