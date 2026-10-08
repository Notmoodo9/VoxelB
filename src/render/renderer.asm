; =============================================================================
; renderer.asm — per-frame rendering. Milestone 2: viewport tracking and
; clearing the back buffer to the clear colour.
;
; Public API:
;   renderer_init()                 one-time GL state setup
;   renderer_frame(ecx=w, edx=h)    render one frame into the back buffer
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"

global renderer_init, renderer_frame

section .rdata
align 4
; Clear colour (sRGB-encoded; the default framebuffer is not sRGB). A vivid
; sky blue so a working frame is obvious until the sky renderer (M14) exists.
clear_color:    dd 0.33, 0.62, 0.98, 1.0

section .bss
alignb 4
g_viewport_w:   resd 1
g_viewport_h:   resd 1

section .text

; -----------------------------------------------------------------------------
; renderer_init — set fixed GL state.
;   in/out: none
;   clobbers: volatile registers (incl. xmm0-xmm3)
; -----------------------------------------------------------------------------
PROC renderer_init, 0
    movss xmm0, [rel clear_color]
    movss xmm1, [rel clear_color + 4]
    movss xmm2, [rel clear_color + 8]
    movss xmm3, [rel clear_color + 12]
    GL glClearColor
    mov dword [rel g_viewport_w], 0
    mov dword [rel g_viewport_h], 0
    LOG_INFO "renderer initialised"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; renderer_frame — render one frame (caller presents it with gl_swap).
;   in:  ecx = framebuffer width, edx = framebuffer height (both > 0)
;   out: none
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
    RETURN
ENDPROC
