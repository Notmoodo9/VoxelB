; =============================================================================
; mob_render.asm — drawing the animals (milestone 19, DECISIONS D98).
;
; Every box of every animal in view is one instance record (96 bytes:
; position, body yaw, the box's pivot, corner, size, its turn, skin
; position, light) written each frame into one of three rotating shader
; storage buffers; shaders/mob.vert builds the box's 36 vertices from the
; record (vertex pulling, one glDrawArrays for all animals). Skins are one
; 64 x 64 texture array, a layer per variant. The same records are drawn
; into the sun's shadow cascades (mob.vert + mob_shadow.frag). Lighting and
; fog are the world's (scene_uniforms in world_render.asm); the sky light is
; ents_view.asm's look at the blocks above each animal.
;
; Public API:
;   mobs_render_init()          after the GL context (world_render_init)
;   mobs_prepare()              each frame before the shadow pass
;   mobs_draw()                 in the scene pass (opaque)
;   mobs_shadow(ecx = cascade + 1)   into the bound shadow layer
;   g_mobs_drawn, g_mob_boxes   statistics (overlay)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "memory.inc"
%include "file.inc"
%include "packet.inc"
%include "mobs.inc"
%include "ents_view.inc"

global mobs_render_init, mobs_prepare, mobs_draw, mobs_shadow
global g_mobs_drawn, g_mob_boxes, g_mob_prep_us

extern shader_create, shader_program, png_decode, sincosf, timer_elapsed_us
extern scene_uniforms, str_copy
extern g_cam_pos, g_cam_yaw, g_cam_pitch, g_cam_viewproj, g_cam_mod

%define MAX_INST        16384           ; boxes per frame
%define INST_BYTES      96
%define RING            3
%define SKIN_UNIT       11
%define INST_SSBO       11
%define U_VIEWPROJ      0
%define U_CASCADE       16
%define U_CAM_MOD       18

section .rdata
str_vs:         db "shaders/mob.vert", 0
str_fs:         db "shaders/mob.frag", 0
str_sfs:        db "shaders/mob_shadow.frag", 0
str_dir:        db "assets\textures\mobs\", 0
str_png:        db ".png", 0
str_bad_skin:   db "mobs: a skin is missing or not 64 x 64 (drawn checkered): ", 0
align 8
c_us:           dq 0.000001
c_behind:       dq -8.0                 ; behind the camera by more: skipped
align 4
c_one:          dd 1.0
c_baby:         dd 0.5
c_baby_head:    dd 1.5
c_leg:          dd 0.75                 ; leg swing (radians at full stride)
c_tail_rest:    dd 0.15
c_tail_walk:    dd 0.35
c_tail_sway:    dd 0.22
c_tail_rate:    dd 1.7
c_id_phase:     dd 0.7
c_sink:         dd 0.62                 ; lying down: blocks lower (adult)
c_love_rate:    dd 5.0
c_love_amp:     dd 0.17

section .bss
alignb 16
g_inst:         resb MAX_INST * INST_BYTES
g_ssbo:         resd RING
g_prog:         resd 1                  ; shader handles
g_shadow_prog:  resd 1
g_skins:        resd 1
g_vao:          resd 1
g_ok:           resd 1
g_frame:        resd 1
g_cur_ssbo:     resd 1
g_mob_boxes:    resd 1                  ; this frame
g_mobs_drawn:   resd 1
g_png:          resd 2
alignb 8
g_mob_prep_us:  resq 1                  ; mobs_prepare this frame (CPU)
g_prep_start:   resq 1
g_rel:          resb PATH_CAP
g_path:         resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; mobs_render_init — shaders, the skin array (a layer per variant), buffers.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC mobs_render_init, 16, rbx, rsi, rdi
    mov dword [rel g_ok], 0
    lea rcx, [rel str_vs]
    lea rdx, [rel str_fs]
    call shader_create
    cmp eax, -1
    je .fail
    mov [rel g_prog], eax
    lea rcx, [rel str_vs]
    lea rdx, [rel str_sfs]
    call shader_create
    cmp eax, -1
    je .fail
    mov [rel g_shadow_prog], eax
    ; skins
    mov ebx, [rel g_variant_count]
    test ebx, ebx
    jnz .layers
    mov ebx, 1
.layers:
    lea r8, [rel g_skins]
    GL glCreateTextures, GL_TEXTURE_2D_ARRAY, 1, r8
    GL glTextureStorage3D, [rel g_skins], 1, GL_RGBA8, SKIN_PX, SKIN_PX, rbx
    GL glTextureParameteri, [rel g_skins], GL_TEXTURE_MIN_FILTER, GL_NEAREST
    GL glTextureParameteri, [rel g_skins], GL_TEXTURE_MAG_FILTER, GL_NEAREST
    GL glTextureParameteri, [rel g_skins], GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, [rel g_skins], GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE
    GL glPixelStorei, GL_UNPACK_ALIGNMENT, 4
    xor esi, esi
.skin:
    cmp esi, [rel g_variant_count]
    jae .skins_done
    mov ecx, esi
    call load_skin
    inc esi
    jmp .skin
.skins_done:
    ; instance buffers
    xor esi, esi
.buf:
    lea rdx, [rel g_ssbo]
    lea rdx, [rdx + rsi * 4]
    GL glCreateBuffers, 1, rdx
    lea rax, [rel g_ssbo]
    mov ecx, [rax + rsi * 4]
    GL glNamedBufferStorage, rcx, MAX_INST * INST_BYTES, 0, GL_DYNAMIC_STORAGE_BIT
    inc esi
    cmp esi, RING
    jb .buf
    lea rdx, [rel g_vao]
    GL glCreateVertexArrays, 1, rdx
    mov dword [rel g_ok], 1
    LOG_INFO "mobs: renderer ready (skins, box instances, shadows)"
    RETURN
.fail:
    LOG_WARN "mobs: the animal shaders failed; animals are not drawn"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; load_skin — variant ecx's skin into its layer (a checkerboard if missing).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC load_skin, 16, rbx, rsi, rdi
    mov ebx, ecx
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    imul eax, ebx, VARIANT_size
    lea rcx, [rel g_variants]
    mov rsi, [rcx + rax + VARIANT.skin]
    lea rcx, [rel g_rel]
    lea rdx, [rel str_dir]
    call str_copy
    mov rcx, rax
    mov rdx, rsi
    call str_copy
    mov rcx, rax
    lea rdx, [rel str_png]
    call str_copy
    lea rcx, [rel g_path]
    lea rdx, [rel g_rel]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .bad
    lea r8, [rel g_png]
    lea r9, [rel g_arena_scratch]
    mov rcx, rax
    call png_decode
    test rax, rax
    jz .bad
    cmp dword [rel g_png], SKIN_PX
    jne .bad
    cmp dword [rel g_png + 4], SKIN_PX
    jne .bad
    mov rdi, rax
    jmp .upload
.bad:
    mov ecx, LOG_LEVEL_WARN
    call log_begin
    lea rcx, [rel str_bad_skin]
    call log_append_str
    mov rcx, rsi
    call log_append_str
    call log_end
    ; a magenta / black checkerboard
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, SKIN_PX * SKIN_PX * 4, 16
    test rax, rax
    jz .done
    mov rdi, rax
    xor ecx, ecx
.checker:
    mov eax, ecx
    shr eax, 2
    mov edx, ecx
    shr edx, 8
    xor eax, edx
    test eax, 1
    mov edx, 0xFFFF00FF
    jnz .px
    mov edx, 0xFF000000
.px:
    mov [rdi + rcx * 4], edx
    inc ecx
    cmp ecx, SKIN_PX * SKIN_PX
    jb .checker
.upload:
    mov [rsp + 80], rdi
    mov dword [rsp + 72], GL_UNSIGNED_BYTE
    mov dword [rsp + 64], GL_RGBA
    mov qword [rsp + 56], 1
    mov qword [rsp + 48], SKIN_PX
    mov qword [rsp + 40], SKIN_PX
    mov [rsp + 32], rbx
    GL glTextureSubImage3D, [rel g_skins], 0, 0, 0
.done:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mobs_prepare — animate, then one instance record per box of every animal
; in view, into this frame's buffer.
;   clobbers: volatile registers (keeps xmm6-xmm15)
; -----------------------------------------------------------------------------
%define P_FX        0                   ; f64 camera forward
%define P_FY        8
%define P_FZ        16
%define P_REL       24                  ; f32[3] animal - camera
%define P_SCALE     36
%define P_HEADS     40                  ; f32 head scale
%define P_LEG       44                  ; f32 leg swing
%define P_TAILY     48
%define P_TAILP     52
%define P_TIME      56                  ; f32 seconds
%define P_PART      60
%define P_END       64
%define P_ID        68
%define P_CP        72                  ; f32 cos pitch
%define P_LOVE      76                  ; f32 pink pulse
PROC mobs_prepare, 80, rbx, rsi, rdi, r12
    call timer_elapsed_us
    mov [rel g_prep_start], rax
    call prepare
    call timer_elapsed_us
    sub rax, [rel g_prep_start]
    mov [rel g_mob_prep_us], rax
    RETURN
ENDPROC

; prepare — mobs_prepare's work (timed by it)
PROC prepare, 80, rbx, rsi, rdi, r12, r13
    mov dword [rel g_mob_boxes], 0
    mov dword [rel g_mobs_drawn], 0
    cmp dword [rel g_ok], 0
    je .done
    call ents_view_update
    cmp dword [rel g_ents_shown], 0
    je .done
    ; the camera's forward vector (for skipping what is behind it)
    movss xmm0, [rel g_cam_pitch]
    call sincosf
    cvtss2sd xmm0, xmm0
    movsd [LOCAL(P_FY)], xmm0
    movss [LOCAL(P_CP)], xmm1
    movss xmm0, [rel g_cam_yaw]
    call sincosf
    mulss xmm0, [LOCAL(P_CP)]
    cvtss2sd xmm0, xmm0
    movsd [LOCAL(P_FX)], xmm0
    mulss xmm1, [LOCAL(P_CP)]
    cvtss2sd xmm1, xmm1
    xorpd xmm2, xmm2
    subsd xmm2, xmm1
    movsd [LOCAL(P_FZ)], xmm2
    call timer_elapsed_us
    xor edx, edx
    mov rcx, 3600000000
    div rcx
    cvtsi2sd xmm0, rdx
    mulsd xmm0, [rel c_us]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(P_TIME)], xmm0
    lea rdi, [rel g_inst]               ; next record
    xor r13d, r13d                      ; place in the list of shown animals
.ent:
    cmp r13d, [rel g_ents_shown]
    jae .upload
    lea rax, [rel g_vlist]
    movzx esi, word [rax + r13 * 2]     ; id
    imul eax, esi, VENT_size
    lea rbx, [rel g_vents]
    add rbx, rax
    mov [LOCAL(P_ID)], esi
    ; relative position; behind the camera?
    movsd xmm0, [rbx + VENT.shown]
    subsd xmm0, [rel g_cam_pos]
    movsd xmm1, [rbx + VENT.shown + 8]
    subsd xmm1, [rel g_cam_pos + 8]
    movsd xmm2, [rbx + VENT.shown + 16]
    subsd xmm2, [rel g_cam_pos + 16]
    cvtsd2ss xmm3, xmm0
    movss [LOCAL(P_REL)], xmm3
    cvtsd2ss xmm3, xmm1
    ; lying down: the body sinks onto its folded legs
    movss xmm4, [rbx + VENT.sleep]
    mulss xmm4, [rel c_sink]
    test word [rbx + VENT.flags], EPF_BABY
    jz .sink
    mulss xmm4, [rel c_baby]
.sink:
    subss xmm3, xmm4
    movss [LOCAL(P_REL + 4)], xmm3
    cvtsd2ss xmm3, xmm2
    movss [LOCAL(P_REL + 8)], xmm3
    mulsd xmm0, [LOCAL(P_FX)]
    mulsd xmm1, [LOCAL(P_FY)]
    mulsd xmm2, [LOCAL(P_FZ)]
    addsd xmm0, xmm1
    addsd xmm0, xmm2
    comisd xmm0, [rel c_behind]
    jb .next
    ; its model and room for its boxes
    movzx eax, word [rbx + VENT.variant]
    cmp eax, [rel g_variant_count]
    jae .next
    imul eax, eax, VARIANT_size
    lea rcx, [rel g_variants]
    mov eax, [rcx + rax + VARIANT.model]
    imul eax, eax, MODEL_size
    lea rcx, [rel g_models]
    add rcx, rax
    mov eax, [rcx + MODEL.first]
    mov [LOCAL(P_PART)], eax
    add eax, [rcx + MODEL.count]
    mov [LOCAL(P_END)], eax
    mov eax, [rel g_mob_boxes]
    add eax, [rcx + MODEL.count]
    cmp eax, MAX_INST
    ja .upload                          ; (full: the rest waits)
    inc dword [rel g_mobs_drawn]
    ; size: babies are half, with bigger heads
    mov eax, [rel c_one]
    mov [LOCAL(P_SCALE)], eax
    mov [LOCAL(P_HEADS)], eax
    test word [rbx + VENT.flags], EPF_BABY
    jz .sized
    mov eax, [rel c_baby]
    mov [LOCAL(P_SCALE)], eax
    mov eax, [rel c_baby_head]
    mov [LOCAL(P_HEADS)], eax
.sized:
    ; legs and tail
    movss xmm0, [rbx + VENT.phase]
    call sincosf
    mulss xmm0, [rel c_leg]
    mulss xmm0, [rbx + VENT.amp]
    movss [LOCAL(P_LEG)], xmm0
    cvtsi2ss xmm0, dword [LOCAL(P_ID)]
    mulss xmm0, [rel c_id_phase]
    movss xmm1, [LOCAL(P_TIME)]
    mulss xmm1, [rel c_tail_rate]
    addss xmm0, xmm1
    call sincosf
    mulss xmm0, [rel c_tail_sway]
    movss [LOCAL(P_TAILY)], xmm0
    movss xmm0, [rbx + VENT.amp]
    mulss xmm0, [rel c_tail_walk]
    addss xmm0, [rel c_tail_rest]
    movss [LOCAL(P_TAILP)], xmm0
    ; fed: a soft pink pulse
    xor eax, eax
    mov [LOCAL(P_LOVE)], eax
    test word [rbx + VENT.flags], EPF_LOVE
    jz .no_love
    movss xmm0, [LOCAL(P_TIME)]
    mulss xmm0, [rel c_love_rate]
    call sincosf
    mulss xmm0, [rel c_love_amp]
    addss xmm0, [rel c_love_amp]
    movss [LOCAL(P_LOVE)], xmm0
.no_love:
    ; ---- the boxes ----
.part:
    mov eax, [LOCAL(P_PART)]
    cmp eax, [LOCAL(P_END)]
    jae .next
    inc dword [LOCAL(P_PART)]
    imul eax, eax, MPART_size
    lea r12, [rel g_parts]
    add r12, rax
    ; a: position, body yaw
    mov eax, [LOCAL(P_REL)]
    mov [rdi], eax
    mov eax, [LOCAL(P_REL + 4)]
    mov [rdi + 4], eax
    mov eax, [LOCAL(P_REL + 8)]
    mov [rdi + 8], eax
    mov eax, [rbx + VENT.yaw]
    mov [rdi + 12], eax
    ; b: pivot, scale
    mov eax, [r12 + MPART.pivot]
    mov [rdi + 16], eax
    mov eax, [r12 + MPART.pivot + 4]
    mov [rdi + 20], eax
    mov eax, [r12 + MPART.pivot + 8]
    mov [rdi + 24], eax
    mov eax, [LOCAL(P_SCALE)]
    mov [rdi + 28], eax
    ; c: box corner, skin layer
    mov eax, [r12 + MPART.box]
    mov [rdi + 32], eax
    mov eax, [r12 + MPART.box + 4]
    mov [rdi + 36], eax
    mov eax, [r12 + MPART.box + 8]
    mov [rdi + 40], eax
    movzx eax, word [rbx + VENT.variant]
    cvtsi2ss xmm0, eax
    movss [rdi + 44], xmm0
    ; d: size, pitch
    mov eax, [r12 + MPART.size]
    mov [rdi + 48], eax
    mov eax, [r12 + MPART.size + 4]
    mov [rdi + 52], eax
    mov eax, [r12 + MPART.size + 8]
    mov [rdi + 56], eax
    ; e: yaw, roll, u, v; f: sky, hurt, head scale
    xor ecx, ecx                        ; pitch
    xor edx, edx                        ; yaw
    mov r8d, [rel c_one]                ; box scale
    mov eax, [r12 + MPART.motion]
    cmp eax, MOTION_HEAD
    jne .not_head
    mov ecx, [rbx + VENT.pitch]
    mov edx, [rbx + VENT.head]
    mov r8d, [LOCAL(P_HEADS)]
    jmp .motion_done
.not_head:
    cmp eax, MOTION_LEG0
    jne .not_leg0
    mov ecx, [LOCAL(P_LEG)]
    jmp .motion_done
.not_leg0:
    cmp eax, MOTION_LEG1
    jne .not_leg1
    mov ecx, [LOCAL(P_LEG)]
    xor ecx, 0x80000000
    jmp .motion_done
.not_leg1:
    cmp eax, MOTION_TAIL
    jne .motion_done
    mov ecx, [LOCAL(P_TAILP)]
    mov edx, [LOCAL(P_TAILY)]
.motion_done:
    mov [rdi + 60], ecx
    mov [rdi + 64], edx
    mov eax, [rbx + VENT.roll]
    mov [rdi + 68], eax
    movzx eax, word [r12 + MPART.u]
    cvtsi2ss xmm0, eax
    movss [rdi + 72], xmm0
    movzx eax, word [r12 + MPART.v]
    cvtsi2ss xmm0, eax
    movss [rdi + 76], xmm0
    mov eax, [rbx + VENT.sky]
    mov [rdi + 80], eax
    mov eax, [rbx + VENT.hurt]
    mov [rdi + 84], eax
    mov [rdi + 88], r8d
    mov eax, [LOCAL(P_LOVE)]
    mov [rdi + 92], eax
    add rdi, INST_BYTES
    inc dword [rel g_mob_boxes]
    jmp .part
.next:
    inc r13d
    jmp .ent
.upload:
    mov eax, [rel g_mob_boxes]
    test eax, eax
    jz .done
    ; this frame's buffer of the three
    inc dword [rel g_frame]
    mov eax, [rel g_frame]
    xor edx, edx
    mov ecx, RING
    div ecx
    lea rax, [rel g_ssbo]
    mov eax, [rax + rdx * 4]
    mov [rel g_cur_ssbo], eax
    mov r8d, [rel g_mob_boxes]
    imul r8, r8, INST_BYTES
    lea r9, [rel g_inst]
    GL glNamedBufferSubData, [rel g_cur_ssbo], 0, r8, r9
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mobs_draw — the animals into the scene (depth on; after the opaque world).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC mobs_draw, 0, rbx
    cmp dword [rel g_mob_boxes], 0
    je .done
    mov ecx, [rel g_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    mov ecx, ebx
    call scene_uniforms
    lea rax, [rel g_cam_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, rbx, U_VIEWPROJ, 1, GL_FALSE
    GL glProgramUniform1i, rbx, U_CASCADE, 0
    lea r9, [rel g_cam_mod]
    GL glProgramUniform3fv, rbx, U_CAM_MOD, 1, r9
    GL glBindVertexArray, [rel g_vao]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, INST_SSBO, [rel g_cur_ssbo]
    GL glBindTextureUnit, SKIN_UNIT, [rel g_skins]
    GL glDisable, GL_CULL_FACE
    mov r8d, [rel g_mob_boxes]
    imul r8d, r8d, 36
    GL glDrawArrays, GL_TRIANGLES, 0, r8
    GL glEnable, GL_CULL_FACE
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mobs_shadow — the animals into the bound shadow cascade layer.
;   in:  ecx = cascade + 1
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC mobs_shadow, 0, rbx, rsi
    mov esi, ecx
    cmp dword [rel g_mob_boxes], 0
    je .done
    mov ecx, [rel g_shadow_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    GL glProgramUniform1i, rbx, U_CASCADE, rsi
    GL glBindVertexArray, [rel g_vao]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, INST_SSBO, [rel g_cur_ssbo]
    mov r8d, [rel g_mob_boxes]
    imul r8d, r8d, 36
    GL glDrawArrays, GL_TRIANGLES, 0, r8
.done:
    RETURN
ENDPROC
