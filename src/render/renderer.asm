; =============================================================================
; renderer.asm — frame setup: reverse-Z depth, the offscreen scene target.
;
; The world is drawn into an offscreen framebuffer (colour RGBA8 + a 32-bit
; float depth texture), so later passes can read the depth (Hi-Z occlusion
; culling, milestone 11; post-processing later). It is blitted to the window
; at the end of renderer_frame; the overlay then draws straight on the
; window.
;
; Public API:
;   renderer_init() -> eax 1/0     renderer_shutdown()
;   renderer_frame(ecx = width, edx = height)
;   g_scene_depth   GL texture name of the scene depth (valid after a frame)
;   g_viewport_w, g_viewport_h
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"

global renderer_init, renderer_frame, renderer_shutdown
global g_scene_depth, g_viewport_w, g_viewport_h

extern world_render_draw

section .rdata
align 4
clear_color:    dd 0.33, 0.62, 0.98, 1.0
c_zero:         dd 0.0

section .bss
alignb 4
g_viewport_w:   resd 1
g_viewport_h:   resd 1
g_scene_fbo:    resd 1
g_scene_color:  resd 1
g_scene_depth:  resd 1

section .text

; -----------------------------------------------------------------------------
; renderer_init — clear colour, reverse-Z depth state.
;   out: eax = 1
;   clobbers: volatile registers
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
    LOG_INFO "renderer initialised (reverse-Z, offscreen scene target)"
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; scene_target — (re)create the offscreen framebuffer for a size.
;   in:  ecx = width, edx = height
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC scene_target, 0, rbx, rsi
    mov ebx, ecx
    mov esi, edx
    call scene_free
    lea rdx, [rel g_scene_fbo]
    GL glCreateFramebuffers, 1, rdx
    lea r8, [rel g_scene_color]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    GL glTextureStorage2D, [rel g_scene_color], 1, GL_RGBA8, rbx, rsi
    lea r8, [rel g_scene_depth]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    GL glTextureStorage2D, [rel g_scene_depth], 1, GL_DEPTH_COMPONENT32F, rbx, rsi
    GL glTextureParameteri, [rel g_scene_depth], GL_TEXTURE_MIN_FILTER, GL_NEAREST
    GL glTextureParameteri, [rel g_scene_depth], GL_TEXTURE_MAG_FILTER, GL_NEAREST
    GL glNamedFramebufferTexture, [rel g_scene_fbo], GL_COLOR_ATTACHMENT0, [rel g_scene_color], 0
    GL glNamedFramebufferTexture, [rel g_scene_fbo], GL_DEPTH_ATTACHMENT, [rel g_scene_depth], 0
    GL glCheckNamedFramebufferStatus, [rel g_scene_fbo], GL_FRAMEBUFFER
    cmp eax, GL_FRAMEBUFFER_COMPLETE
    je .ok
    LOG_ERROR "renderer: the scene framebuffer is incomplete"
.ok:
    RETURN
ENDPROC

; scene_free — delete the offscreen framebuffer (if any).   clobbers: volatile
PROC scene_free, 0
    cmp dword [rel g_scene_fbo], 0
    je .done
    lea rdx, [rel g_scene_fbo]
    GL glDeleteFramebuffers, 1, rdx
    lea rdx, [rel g_scene_color]
    GL glDeleteTextures, 1, rdx
    lea rdx, [rel g_scene_depth]
    GL glDeleteTextures, 1, rdx
    mov dword [rel g_scene_fbo], 0
    mov dword [rel g_scene_color], 0
    mov dword [rel g_scene_depth], 0
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; renderer_frame — draw the world into the scene target, then show it.
;   in:  ecx = width, edx = height (client area)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC renderer_frame, 0, rbx, rsi
    mov ebx, ecx
    mov esi, edx
    test ebx, ebx
    jz .done
    test esi, esi
    jz .done                            ; (minimised)
    cmp ebx, [rel g_viewport_w]
    jne .resize
    cmp esi, [rel g_viewport_h]
    je .draw
.resize:
    mov [rel g_viewport_w], ebx
    mov [rel g_viewport_h], esi
    GL glViewport, 0, 0, rbx, rsi
    INVOKE scene_target, rbx, rsi
.draw:
    GL glBindFramebuffer, GL_FRAMEBUFFER, [rel g_scene_fbo]
    GL glClear, GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT
    call world_render_draw
    ; show it: the scene colour to the window
    GL glBindFramebuffer, GL_FRAMEBUFFER, 0
    GL glBlitNamedFramebuffer, [rel g_scene_fbo], 0, 0, 0, rbx, rsi, 0, 0, rbx, rsi, GL_COLOR_BUFFER_BIT, GL_NEAREST
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; renderer_shutdown — free the scene target.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC renderer_shutdown, 0
    call scene_free
    RETURN
ENDPROC
