; =============================================================================
; post.asm — post-processing (milestone 14): bloom and the final pass from
; the HDR scene target to the window.
;
; Bloom (shaders/bloom.comp) works on one RGBA16F texture with a mip chain
; at half the scene's size: the scene's highlights into level 0, a chain of
; 2 x 2 downsamples, then back up adding each smaller level into the next
; larger one. The final pass (shaders/fullscreen.vert + post.frag) adds the
; bloom, applies exposure, ACES tonemapping, the colour grade and gamma.
; Part 2: it also marches the cloud layer per pixel up to the scene depth
; (world.cfg's cloud_cover and cloud_height, graphics.cfg's clouds).
;
; Public API:
;   post_init() -> eax 1/0     post_frame(ecx = width, edx = height)
;   post_shutdown()
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "shader.inc"

global post_init, post_frame, post_shutdown

extern g_scene_color, g_scene_depth, g_bloom, g_clouds
extern g_cam_viewproj, g_cam_pos, g_sun_dir, g_cloud_cover, g_cloud_height
extern timer_elapsed_us

%define BLOOM_LEVELS    6
%define B_MODE          0               ; bloom.comp uniforms
%define B_SRC_SIZE      1
%define B_DST_SIZE      2
%define B_THRESHOLD     3
%define P_FLAGS         1               ; post.frag uniforms
%define P_EXPOSURE      2
%define P_VIEWPROJ      0
%define P_SUN           3
%define P_TIME          4
%define P_CAM           5
%define P_CLOUD         6
%define CLOUD_THICKNESS 48.0

section .rdata
str_vs:         db "shaders/fullscreen.vert", 0
str_fs:         db "shaders/post.frag", 0
str_bloom:      db "shaders/bloom.comp", 0
align 4
c_threshold:    dd 1.0                  ; bloom: only what is brighter than white
c_exposure:     dd 1.0
c_thickness:    dd CLOUD_THICKNESS
c_million:      dd 1000000.0
align 8
c_wrap_us:      dq 3600000000

section .bss
alignb 4
g_post_prog:    resd 1
g_bloom_prog:   resd 1
g_post_vao:     resd 1
g_bloom_tex:    resd 1
g_bloom_w:      resd 1                  ; level 0 size
g_bloom_h:      resd 1
g_bloom_levels: resd 1
alignb 16
g_post_tmp:     resd 4

section .text

; -----------------------------------------------------------------------------
; post_init — the programs and an empty vertex array.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC post_init, 0
    lea rcx, [rel str_vs]
    lea rdx, [rel str_fs]
    call shader_create
    cmp eax, -1
    je .fail
    mov [rel g_post_prog], eax
    lea rcx, [rel str_bloom]
    call shader_create_compute
    cmp eax, -1
    je .fail
    mov [rel g_bloom_prog], eax
    lea rdx, [rel g_post_vao]
    GL glCreateVertexArrays, 1, rdx
    LOG_INFO "post: HDR, bloom, tonemapping ready"
    mov eax, 1
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; bloom_target — (re)create the bloom chain for a scene size.
;   in:  ecx = width, edx = height
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC bloom_target, 0, rbx, rsi
    inc ecx
    shr ecx, 1
    inc edx
    shr edx, 1
    cmp ecx, [rel g_bloom_w]
    jne .create
    cmp edx, [rel g_bloom_h]
    jne .create
    cmp dword [rel g_bloom_tex], 0
    jne .done
.create:
    mov ebx, ecx
    mov esi, edx
    mov [rel g_bloom_w], ebx
    mov [rel g_bloom_h], esi
    ; levels: up to BLOOM_LEVELS, while the smaller side stays >= 4
    mov eax, ebx
    cmp eax, esi
    cmova eax, esi
    xor ecx, ecx
.lv:
    cmp ecx, BLOOM_LEVELS
    jae .lv_done
    cmp eax, 4
    jb .lv_done
    inc ecx
    shr eax, 1
    jmp .lv
.lv_done:
    test ecx, ecx
    jnz .have_levels
    mov ecx, 1
.have_levels:
    mov [rel g_bloom_levels], ecx
    cmp dword [rel g_bloom_tex], 0
    je .new
    lea rdx, [rel g_bloom_tex]
    GL glDeleteTextures, 1, rdx
.new:
    lea r8, [rel g_bloom_tex]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    GL glTextureStorage2D, [rel g_bloom_tex], [rel g_bloom_levels], GL_RGBA16F, rbx, rsi
    GL glTextureParameteri, [rel g_bloom_tex], GL_TEXTURE_MIN_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_bloom_tex], GL_TEXTURE_MAG_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_bloom_tex], GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, [rel g_bloom_tex], GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; post_frame — bloom, then the scene to the window (framebuffer 0).
;   in:  ecx = width, edx = height (the scene's size)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define PF_W        0
%define PF_H        4
%define PF_L        8                   ; level
%define PF_SW       12                  ; source size
%define PF_SH       16
%define PF_DW       20                  ; destination size
%define PF_DH       24
PROC post_frame, 32, rbx
    mov [LOCAL(PF_W)], ecx
    mov [LOCAL(PF_H)], edx
    cmp dword [rel g_bloom], 0
    je .final
    call bloom_target
    mov ecx, [rel g_bloom_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    movss xmm2, [rel c_threshold]
    GL glProgramUniform1f, rbx, B_THRESHOLD
    GL glBindTextureUnit, 0, [rel g_scene_color]

    ; ---- level 0: the scene's highlights ----
    GL glProgramUniform1i, rbx, B_MODE, 0
    GL glProgramUniform2i, rbx, B_SRC_SIZE, [LOCAL(PF_W)], [LOCAL(PF_H)]
    GL glProgramUniform2i, rbx, B_DST_SIZE, [rel g_bloom_w], [rel g_bloom_h]
    mov dword [LOCAL(PF_L)], 0
    xor r8d, r8d
    call bind_levels                    ; (src: level 0, unused here)
    mov eax, [rel g_bloom_w]
    mov ecx, [rel g_bloom_h]
    call dispatch

    ; ---- down the chain ----
    mov eax, [rel g_bloom_w]
    mov [LOCAL(PF_DW)], eax
    mov eax, [rel g_bloom_h]
    mov [LOCAL(PF_DH)], eax
    GL glProgramUniform1i, rbx, B_MODE, 1
    mov dword [LOCAL(PF_L)], 1
.down:
    mov eax, [LOCAL(PF_L)]
    cmp eax, [rel g_bloom_levels]
    jae .down_done
    mov eax, [LOCAL(PF_DW)]
    mov [LOCAL(PF_SW)], eax
    shr eax, 1
    mov ecx, 1
    cmp eax, ecx
    cmovb eax, ecx
    mov [LOCAL(PF_DW)], eax
    mov eax, [LOCAL(PF_DH)]
    mov [LOCAL(PF_SH)], eax
    shr eax, 1
    cmp eax, ecx
    cmovb eax, ecx
    mov [LOCAL(PF_DH)], eax
    GL glProgramUniform2i, rbx, B_SRC_SIZE, [LOCAL(PF_SW)], [LOCAL(PF_SH)]
    GL glProgramUniform2i, rbx, B_DST_SIZE, [LOCAL(PF_DW)], [LOCAL(PF_DH)]
    mov r8d, [LOCAL(PF_L)]
    dec r8d
    call bind_levels                    ; src level - 1, dst level
    mov eax, [LOCAL(PF_DW)]
    mov ecx, [LOCAL(PF_DH)]
    call dispatch
    inc dword [LOCAL(PF_L)]
    jmp .down
.down_done:

    ; ---- back up: level n += upsampled level n + 1 ----
    GL glProgramUniform1i, rbx, B_MODE, 2
    mov eax, [rel g_bloom_levels]
    sub eax, 2
    mov [LOCAL(PF_L)], eax
.up:
    mov eax, [LOCAL(PF_L)]
    test eax, eax
    js .final
    ; sizes of level n (dst) and n + 1 (src)
    mov ecx, eax
    mov edx, [rel g_bloom_w]
    shr edx, cl
    mov r8d, 1
    cmp edx, r8d
    cmovb edx, r8d
    mov [LOCAL(PF_DW)], edx
    mov edx, [rel g_bloom_h]
    shr edx, cl
    cmp edx, r8d
    cmovb edx, r8d
    mov [LOCAL(PF_DH)], edx
    inc ecx
    mov edx, [rel g_bloom_w]
    shr edx, cl
    cmp edx, r8d
    cmovb edx, r8d
    mov [LOCAL(PF_SW)], edx
    mov edx, [rel g_bloom_h]
    shr edx, cl
    cmp edx, r8d
    cmovb edx, r8d
    mov [LOCAL(PF_SH)], edx
    GL glProgramUniform2i, rbx, B_SRC_SIZE, [LOCAL(PF_SW)], [LOCAL(PF_SH)]
    GL glProgramUniform2i, rbx, B_DST_SIZE, [LOCAL(PF_DW)], [LOCAL(PF_DH)]
    mov eax, [LOCAL(PF_L)]
    inc eax
    mov [LOCAL(PF_SW)], eax             ; (reuse: the source level)
    GL glBindImageTexture, 0, [rel g_bloom_tex], [LOCAL(PF_SW)], GL_FALSE, 0, GL_READ_ONLY, GL_RGBA16F
    GL glBindImageTexture, 1, [rel g_bloom_tex], [LOCAL(PF_L)], GL_FALSE, 0, GL_READ_WRITE, GL_RGBA16F
    mov eax, [LOCAL(PF_DW)]
    mov ecx, [LOCAL(PF_DH)]
    call dispatch
    dec dword [LOCAL(PF_L)]
    jmp .up

    ; ---- the final pass ----
.final:
    GL glBindFramebuffer, GL_FRAMEBUFFER, 0
    GL glDisable, GL_DEPTH_TEST
    mov ecx, [rel g_post_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    mov eax, [rel g_clouds]
    add eax, eax
    or eax, [rel g_bloom]
    GL glProgramUniform1i, rbx, P_FLAGS, rax
    movss xmm2, [rel c_exposure]
    GL glProgramUniform1f, rbx, P_EXPOSURE
    ; clouds: camera, sun, wind clock, the layer
    lea rax, [rel g_cam_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, rbx, P_VIEWPROJ, 1, GL_FALSE
    lea r9, [rel g_sun_dir]
    GL glProgramUniform3fv, rbx, P_SUN, 1, r9
    call timer_elapsed_us
    xor edx, edx
    div qword [rel c_wrap_us]
    cvtsi2ss xmm2, rdx
    divss xmm2, [rel c_million]
    GL glProgramUniform1f, rbx, P_TIME
    lea rax, [rel g_cam_pos]
    lea rcx, [rel g_post_tmp]
    cvtsd2ss xmm0, [rax]
    movss [rcx], xmm0
    cvtsd2ss xmm0, [rax + 8]
    movss [rcx + 4], xmm0
    cvtsd2ss xmm0, [rax + 16]
    movss [rcx + 8], xmm0
    lea r9, [rel g_post_tmp]
    GL glProgramUniform3fv, rbx, P_CAM, 1, r9
    lea rcx, [rel g_post_tmp]
    movss xmm0, [rel g_cloud_cover]
    movss [rcx], xmm0
    movss xmm0, [rel g_cloud_height]
    movss [rcx + 4], xmm0
    movss xmm0, [rel c_thickness]
    movss [rcx + 8], xmm0
    mov dword [rcx + 12], 0
    lea r9, [rel g_post_tmp]
    GL glProgramUniform4fv, rbx, P_CLOUD, 1, r9
    GL glBindTextureUnit, 2, [rel g_scene_depth]
    GL glBindTextureUnit, 0, [rel g_scene_color]
    cmp dword [rel g_bloom_tex], 0
    je .no_bloom_tex
    GL glBindTextureUnit, 1, [rel g_bloom_tex]
.no_bloom_tex:
    GL glBindVertexArray, [rel g_post_vao]
    GL glDrawArrays, GL_TRIANGLES, 0, 3
    GL glEnable, GL_DEPTH_TEST
    RETURN

; bind_levels: image 0 = bloom level r8d (read), image 1 = level r8d + 1
; (write); for the first pass r8d = 0 and image 1 = level 0 as well
; (helper of post_frame: locals at +8)   clobbers: volatile registers
bind_levels:
    sub rsp, 8 + 64                     ; (shadow space + stack arguments)
    mov [rsp + 64], r8                  ; keep the level
    mov eax, r8d
    mov [rsp + 32], rax                 ; arg 5: layer
    mov qword [rsp + 40], GL_READ_ONLY
    mov qword [rsp + 48], GL_RGBA16F
    mov ecx, 0
    mov edx, [rel g_bloom_tex]
    mov r8d, eax
    xor r9d, r9d
    call [rel glBindImageTexture]
    mov rax, [rsp + 64]
    cmp dword [LOCAL(PF_L) + 8 + 72], 0
    je .same                            ; (level 0 pass: write level 0)
    inc eax
.same:
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], GL_WRITE_ONLY
    mov qword [rsp + 48], GL_RGBA16F
    mov ecx, 1
    mov edx, [rel g_bloom_tex]
    mov r8d, eax
    xor r9d, r9d
    call [rel glBindImageTexture]
    add rsp, 8 + 64
    ret

; dispatch: 8 x 8 groups over eax x ecx, then a barrier for the next pass
;   clobbers: volatile registers
dispatch:
    sub rsp, 40
    add eax, 7
    shr eax, 3
    add ecx, 7
    shr ecx, 3
    mov edx, ecx
    mov ecx, eax
    mov r8d, 1
    call [rel glDispatchCompute]
    mov ecx, GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | GL_TEXTURE_FETCH_BARRIER_BIT
    call [rel glMemoryBarrier]
    add rsp, 40
    ret
ENDPROC

; -----------------------------------------------------------------------------
; post_shutdown — free the bloom texture and the vertex array.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC post_shutdown, 0
    cmp dword [rel g_bloom_tex], 0
    je .no_tex
    lea rdx, [rel g_bloom_tex]
    GL glDeleteTextures, 1, rdx
.no_tex:
    lea rdx, [rel g_post_vao]
    GL glDeleteVertexArrays, 1, rdx
    RETURN
ENDPROC
