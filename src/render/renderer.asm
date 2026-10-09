; =============================================================================
; renderer.asm — per-frame rendering.
;
; Depth: reverse-Z (glClipControl ZERO_TO_ONE, clear depth 0, GL_GREATER)
; with the camera's infinite-far projection. Back faces are culled.
; Milestone 5 draws the meshed test world (world_render.asm).
;
; Public API:
;   renderer_init() -> eax 1/0      one-time GL state
;   renderer_frame(ecx=w, edx=h)    render one frame into the back buffer
;   renderer_shutdown()
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"

global renderer_init, renderer_frame, renderer_shutdown

extern world_render_draw

section .rdata
align 4
; Clear colour (sRGB-encoded; the default framebuffer is not sRGB). A vivid
; sky blue; the sky renderer (M14) replaces it.
clear_color:    dd 0.33, 0.62, 0.98, 1.0
c_zero:         dd 0.0

section .bss
alignb 4
g_viewport_w:   resd 1
g_viewport_h:   resd 1

section .text

; -----------------------------------------------------------------------------
; renderer_init — fixed GL state.
;   out: eax = 1
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
    mov dword [rel g_viewport_w], 0
    mov dword [rel g_viewport_h], 0
    LOG_INFO "renderer initialised (reverse-Z)"
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; renderer_frame — clear and draw the world (caller presents with gl_swap).
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
.draw:
    GL glClear, GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT
    call world_render_draw
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; renderer_shutdown — nothing to free yet (world_render owns its objects).
; -----------------------------------------------------------------------------
PROC renderer_shutdown, 0
    RETURN
ENDPROC
