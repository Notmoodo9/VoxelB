; =============================================================================
; thumb.asm — world thumbnails for the world list (milestone 17).
;
; While a world is played (not paused), every THUMB_EVERY_US the finished
; frame (before the HUD) is blitted into a small texture, so it always holds
; a recent view of the world. Saving writes it as thumb.png into the world's
; folder (png_write.asm).
;
; Public API:
;   thumb_update()                      after renderer_frame, when playing
;   thumb_reset()                       a new world: nothing captured yet
;   thumb_write(rcx = path) -> eax 1 if written
; =============================================================================
%include "macros.inc"
%include "gl.inc"
%include "memory.inc"

global thumb_update, thumb_reset, thumb_write

extern png_write, timer_elapsed_us, g_viewport_w, g_viewport_h

%define THUMB_W         256
%define THUMB_H         144
%define THUMB_EVERY_US  2000000

section .bss
alignb 8
g_last_us:      resq 1
g_thumb_fbo:    resd 1
g_thumb_tex:    resd 1
g_have:         resd 1                  ; something captured in this world

section .text

; thumb_reset — the next world starts without a picture
thumb_reset:
    mov dword [rel g_have], 0
    mov qword [rel g_last_us], 0
    ret

; -----------------------------------------------------------------------------
; thumb_update — refresh the picture now and then.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC thumb_update, 0, rbx
    call timer_elapsed_us
    mov rbx, rax
    cmp dword [rel g_have], 0
    je .capture                         ; (the first frame of a world: at once)
    mov rcx, rax
    sub rcx, [rel g_last_us]
    cmp rcx, THUMB_EVERY_US
    jb .done
.capture:
    mov [rel g_last_us], rbx
    cmp dword [rel g_thumb_fbo], 0
    jne .blit
    lea rdx, [rel g_thumb_fbo]
    GL glCreateFramebuffers, 1, rdx
    lea r8, [rel g_thumb_tex]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    GL glTextureStorage2D, [rel g_thumb_tex], 1, GL_RGBA8, THUMB_W, THUMB_H
    GL glNamedFramebufferTexture, [rel g_thumb_fbo], GL_COLOR_ATTACHMENT0, [rel g_thumb_tex], 0
.blit:
    ; the whole window frame, scaled to 256 x 144
    mov eax, [rel g_viewport_w]
    test eax, eax
    jz .done
    mov qword [rsp + 32], 0
    mov eax, [rel g_viewport_w]
    mov [rsp + 32], rax                 ; srcX1
    mov eax, [rel g_viewport_h]
    mov [rsp + 40], rax                 ; srcY1
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov qword [rsp + 64], THUMB_W
    mov qword [rsp + 72], THUMB_H
    mov qword [rsp + 80], GL_COLOR_BUFFER_BIT
    mov qword [rsp + 88], GL_LINEAR
    xor ecx, ecx
    mov edx, [rel g_thumb_fbo]
    xor r8d, r8d
    xor r9d, r9d
    call [rel glBlitNamedFramebuffer]
    GL glBindFramebuffer, GL_FRAMEBUFFER, 0
    mov dword [rel g_have], 1
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; thumb_write — the picture as a PNG file.
;   in:  rcx = path
;   out: eax = 1 written, 0 nothing captured / failed
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC thumb_write, 16, rbx, rsi
    mov rbx, rcx
    xor eax, eax
    cmp dword [rel g_have], 0
    je .done
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, THUMB_W * THUMB_H * 4, 16
    test rax, rax
    jz .reset
    mov rsi, rax
    GL glPixelStorei, GL_PACK_ALIGNMENT, 4
    mov qword [rsp + 32], THUMB_W * THUMB_H * 4
    mov [rsp + 40], rsi
    GL glGetTextureImage, [rel g_thumb_tex], 0, GL_RGBA, GL_UNSIGNED_BYTE
    lea rax, [rel g_arena_scratch]
    mov [rsp + 40], rax
    mov qword [rsp + 32], 1             ; bottom-up rows
    INVOKE png_write, rbx, rsi, THUMB_W, THUMB_H
.reset:
    mov rbx, rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    mov rax, rbx
.done:
    RETURN
ENDPROC
