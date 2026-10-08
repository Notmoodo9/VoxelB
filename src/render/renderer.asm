; =============================================================================
; renderer.asm — per-frame world rendering.
;
; Depth: reverse-Z (glClipControl ZERO_TO_ONE, clear depth 0, GL_GREATER)
; with the camera's infinite-far projection.
; Milestone 3 draws a debug test scene (shaders/test_scene.*): a 32x32 field
; of coloured block columns on a checkered ground, generated entirely in the
; vertex shader. It exists to check the camera, depth and shaders; the flat
; test world of M5 replaces it.
;
; Public API:
;   renderer_init() -> eax 1/0      one-time GL state + programs
;   renderer_frame(ecx=w, edx=h)    render one frame into the back buffer
;   renderer_shutdown()
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "shader.inc"

global renderer_init, renderer_frame, renderer_shutdown

extern g_cam_viewproj, g_cam_pos

%define TEST_GRID       32
%define TEST_VERTICES   ((TEST_GRID * TEST_GRID + 1) * 36)

section .rdata
align 4
; Clear colour (sRGB-encoded; the default framebuffer is not sRGB). A vivid
; sky blue; the sky renderer (M14) replaces it.
clear_color:    dd 0.33, 0.62, 0.98, 1.0
c_zero:         dd 0.0
str_scene_vs:   db "shaders/test_scene.vert", 0
str_scene_fs:   db "shaders/test_scene.frag", 0

section .bss
alignb 4
g_viewport_w:   resd 1
g_viewport_h:   resd 1
g_scene_prog:   resd 1                  ; shader handle
g_scene_vao:    resd 1

section .text

; -----------------------------------------------------------------------------
; renderer_init — fixed GL state, VAO and the test-scene program.
;   out: eax = 1 on success, 0 if a program failed to build (logged)
;   clobbers: volatile registers (incl. xmm0-xmm3)
; -----------------------------------------------------------------------------
PROC renderer_init, 0
    movss xmm0, [rel clear_color]
    movss xmm1, [rel clear_color + 4]
    movss xmm2, [rel clear_color + 8]
    movss xmm3, [rel clear_color + 12]
    GL glClearColor
    GL glClipControl, GL_LOWER_LEFT, GL_ZERO_TO_ONE
    movss xmm0, [rel c_zero]
    GL glClearDepthf
    GL glDepthFunc, GL_GREATER
    GL glEnable, GL_DEPTH_TEST
    lea rdx, [rel g_scene_vao]
    GL glCreateVertexArrays, 1, rdx
    mov dword [rel g_viewport_w], 0
    mov dword [rel g_viewport_h], 0

    lea rcx, [rel str_scene_vs]
    lea rdx, [rel str_scene_fs]
    call shader_create
    cmp eax, -1
    jne .ok
    xor eax, eax
    RETURN
.ok:
    mov [rel g_scene_prog], eax
    LOG_INFO "renderer initialised (reverse-Z, test scene)"
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; renderer_frame — clear and draw the scene (caller presents with gl_swap).
;   in:  ecx = framebuffer width, edx = framebuffer height (both > 0)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC renderer_frame, 0, rbx, rsi
    mov ebx, ecx
    mov esi, edx
    cmp ebx, [rel g_viewport_w]
    jne .resize
    cmp esi, [rel g_viewport_h]
    je .draw
.resize:
    mov [rel g_viewport_w], ebx
    mov [rel g_viewport_h], esi
    GL glViewport, 0, 0, rbx, rsi
    LOG_VAL LOG_LEVEL_DEBUG, "viewport width", rbx
.draw:
    GL glClear, GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT

    mov ecx, [rel g_scene_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    lea rax, [rel g_cam_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, rbx, 0, 1, GL_FALSE    ; u_viewproj
    lea r9, [rel g_cam_pos]
    GL glProgramUniform3fv, rbx, 1, 1, r9                ; u_cam_pos
    GL glBindVertexArray, [rel g_scene_vao]
    GL glDrawArrays, GL_TRIANGLES, 0, TEST_VERTICES
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; renderer_shutdown — free renderer GL objects.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC renderer_shutdown, 0
    lea rdx, [rel g_scene_vao]
    GL glDeleteVertexArrays, 1, rdx
    RETURN
ENDPROC
