; =============================================================================
; mob_render.asm — drawing the animals (milestone 19, DECISIONS D98).
;
; Every box of every animal in view is one instance record (112 bytes:
; position, body yaw, the box's pivot, corner, size, its turn and roll,
; skin position, light) written each frame into one of three rotating shader
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

extern shader_create, shader_program, png_decode, sincosf, atan2f, timer_elapsed_us
extern scene_uniforms, str_copy
extern g_cam_pos, g_cam_yaw, g_cam_pitch, g_cam_viewproj, g_cam_mod

%define MAX_INST        16384           ; boxes per frame
%define INST_BYTES      112
%define RING            3
%define SKIN_UNIT       11
%define INST_SSBO       11
%define U_VIEWPROJ      0
%define U_CASCADE       16
%define U_CAM_MOD       18
%define ROPE_SEGS       12              ; boxes per lead

section .rdata
str_vs:         db "shaders/mob.vert", 0
str_fs:         db "shaders/mob.frag", 0
str_sfs:        db "shaders/mob_shadow.frag", 0
str_dir:        db "assets\textures\mobs\", 0
str_png:        db ".png", 0
str_rope:       db "lead_rope", 0
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
c_flap_rate:    dd 22.0                 ; part 3: wings in the air
c_flap_base:    dd 0.55
c_flap_amp:     dd 0.45
c_rope_fwd:     dd 0.45                 ; the lead's end: forward of the body's middle (x width)
c_rope_up:      dd 0.8                  ; ... and up (x height)
c_hand_fwd:     dd 0.5                  ; the player's end: in front of the eyes ...
c_hand_right:   dd 0.4
c_hand_down:    dd -0.55
c_sag:          dd 0.12                 ; slack per block of rope
c_sag_min:      dd 0.15
c_tenth:        dd 0.1
c_four:         dd 4.0
c_px:           dd 16.0
c_thick:        dd 0.8                  ; pixels
c_half_thick:   dd -0.4
c_inv_segs:     dd 0.083333333          ; 1 / ROPE_SEGS
align 8
c_half_d:       dq 0.5
c_knot_up:      dq 0.7
align 16
c_neg:          dd 0x80000000, 0, 0, 0

section .bss
alignb 16
g_inst:         resb MAX_INST * INST_BYTES
g_ssbo:         resd RING
g_prog:         resd 1                  ; shader handles
g_shadow_prog:  resd 1
g_skins:        resd 1
g_rope_layer:   resd 1                  ; the lead's rope in the skin array
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
    add ebx, [rel g_baby_skin_count]
    mov [rel g_rope_layer], ebx         ; (the last layer: the lead's rope)
    inc ebx
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
    imul eax, esi, VARIANT_size
    lea rdx, [rel g_variants]
    mov rdx, [rdx + rax + VARIANT.skin]
    call load_skin
    inc esi
    jmp .skin
.skins_done:
    ; then the young's own skins (part 3b), after the variants' layers
    xor esi, esi
.baby_skin:
    cmp esi, [rel g_baby_skin_count]
    jae .babies_done
    mov ecx, esi
    add ecx, [rel g_variant_count]
    lea rdx, [rel g_baby_skins]
    mov rdx, [rdx + rsi * 8]
    call load_skin
    inc esi
    jmp .baby_skin
.babies_done:
    mov ecx, [rel g_rope_layer]
    lea rdx, [rel str_rope]
    call load_skin
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
; load_skin — a skin into a layer of the array (a checkerboard if missing).
;   in:  ecx = layer, rdx = skin name (assets/textures/mobs/<name>.png)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC load_skin, 16, rbx, rsi, rdi
    mov ebx, ecx
    mov rsi, rdx
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
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
%define P_FLAP      80                  ; f32 wing roll (part 3)
PROC mobs_prepare, 96, rbx, rsi, rdi, r12
    call timer_elapsed_us
    mov [rel g_prep_start], rax
    call prepare
    call timer_elapsed_us
    sub rax, [rel g_prep_start]
    mov [rel g_mob_prep_us], rax
    RETURN
ENDPROC

; prepare — mobs_prepare's work (timed by it)
PROC prepare, 96, rbx, rsi, rdi, r12, r13
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
    ; off the ground: wings beat
    xor eax, eax
    mov [LOCAL(P_FLAP)], eax
    test word [rbx + VENT.flags], EPF_AIR
    jz .no_flap
    cvtsi2ss xmm0, dword [LOCAL(P_ID)]
    movss xmm1, [LOCAL(P_TIME)]
    mulss xmm1, [rel c_flap_rate]
    addss xmm0, xmm1
    call sincosf
    mulss xmm0, [rel c_flap_amp]
    addss xmm0, [rel c_flap_base]
    movss [LOCAL(P_FLAP)], xmm0
.no_flap:
    ; ---- the boxes ----
.part:
    mov eax, [LOCAL(P_PART)]
    cmp eax, [LOCAL(P_END)]
    jae .lead
    inc dword [LOCAL(P_PART)]
    imul eax, eax, MPART_size
    lea r12, [rel g_parts]
    add r12, rax
    ; a shorn coat is not drawn
    cmp dword [r12 + MPART.motion], MOTION_COAT
    jne .not_coat
    test word [rbx + VENT.flags], EPF_SHEARED
    jnz .part
.not_coat:
    ; antlers and the like only on males (and not on the young)
    cmp dword [r12 + MPART.motion], MOTION_MALE
    jne .shown
    test word [rbx + VENT.flags], EPF_BABY
    jnz .part
    test word [rbx + VENT.flags], EPF_MALE
    jz .part
.shown:
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
    test word [rbx + VENT.flags], EPF_BABY
    jz .layer
    imul ecx, eax, VARIANT_size         ; the young may wear their own skin
    lea rdx, [rel g_variants]
    mov ecx, [rdx + rcx + VARIANT.baby_layer]
    test ecx, ecx
    cmovnz eax, ecx
.layer:
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
    xor r9d, r9d                        ; roll (wings)
    mov eax, [r12 + MPART.motion]
    cmp eax, MOTION_HEAD
    je .head
    cmp eax, MOTION_MALE
    jne .not_head
.head:
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
    jne .not_tail
    mov ecx, [LOCAL(P_TAILP)]
    mov edx, [LOCAL(P_TAILY)]
    jmp .motion_done
.not_tail:
    cmp eax, MOTION_WING0
    jne .not_wing0
    mov r9d, [LOCAL(P_FLAP)]
    xor r9d, 0x80000000                 ; (the left wing lifts to -x)
    jmp .motion_done
.not_wing0:
    cmp eax, MOTION_WING1
    jne .motion_done
    mov r9d, [LOCAL(P_FLAP)]
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
    ; g: the box's roll
    mov [rdi + 96], r9d
    xor eax, eax
    mov [rdi + 100], eax
    mov [rdi + 104], eax
    mov [rdi + 108], eax
    add rdi, INST_BYTES
    inc dword [rel g_mob_boxes]
    jmp .part
.lead:
    call rope                           ; (on a lead: the rope; part 3b)
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
; rope — the lead of animal rbx (VENT*; EPF_LEASH or EPF_KNOT), if any: from
; its neck to the player's hand or its fence post, ROPE_SEGS thin boxes
; sagging less the more it is stretched. Written at rdi, which advances.
;   clobbers: volatile registers, rdi (the next record)
; -----------------------------------------------------------------------------
%define R_A     0                       ; f32 x 3: the animal's end
%define R_B     12                      ; f32 x 3: the holder's end
%define R_SAG   24
%define R_I     28
%define R_P0    32                      ; f32 x 3: this segment's start
%define R_P1    44                      ; f32 x 3: its end
%define R_D     56                      ; f32 x 3: P1 - P0
%define R_LEN   68
%define R_YAW   72
%define R_H     76
PROC rope, 96, rsi
    test word [rbx + VENT.flags], EPF_LEASH | EPF_KNOT
    jz .done
    mov eax, [rel g_mob_boxes]
    add eax, ROPE_SEGS
    cmp eax, MAX_INST
    ja .done
    movzx eax, word [rbx + VENT.variant]
    cmp eax, [rel g_variant_count]
    jae .done
    imul eax, eax, VARIANT_size
    lea rcx, [rel g_variants]
    mov eax, [rcx + rax + VARIANT.mob]
    imul eax, eax, MOB_size
    lea rsi, [rel g_mobs]
    add rsi, rax
    ; the animal's end: at its neck
    movss xmm0, [rbx + VENT.yaw]
    call sincosf
    movss xmm2, [rsi + MOB.width]
    mulss xmm2, [rel c_rope_fwd]
    movss xmm3, [rsi + MOB.height]
    mulss xmm3, [rel c_rope_up]
    test word [rbx + VENT.flags], EPF_BABY
    jz .adult
    mulss xmm2, [rel c_baby]
    mulss xmm3, [rel c_baby]
.adult:
    mulss xmm0, xmm2                    ; forward: (sin yaw, 0, -cos yaw)
    mulss xmm1, xmm2
    movsd xmm4, [rbx + VENT.shown]
    subsd xmm4, [rel g_cam_pos]
    cvtsd2ss xmm4, xmm4
    addss xmm4, xmm0
    movss [LOCAL(R_A)], xmm4
    movsd xmm4, [rbx + VENT.shown + 8]
    subsd xmm4, [rel g_cam_pos + 8]
    cvtsd2ss xmm4, xmm4
    addss xmm4, xmm3
    movss [LOCAL(R_A + 4)], xmm4
    movsd xmm4, [rbx + VENT.shown + 16]
    subsd xmm4, [rel g_cam_pos + 16]
    cvtsd2ss xmm4, xmm4
    subss xmm4, xmm1
    movss [LOCAL(R_A + 8)], xmm4
    ; the holder's end: the fence post's top, or the player's hand
    test word [rbx + VENT.flags], EPF_KNOT
    jz .hand
    cvtsi2sd xmm0, dword [rbx + VENT.knot]
    addsd xmm0, [rel c_half_d]
    subsd xmm0, [rel g_cam_pos]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(R_B)], xmm0
    cvtsi2sd xmm0, dword [rbx + VENT.knot + 4]
    addsd xmm0, [rel c_knot_up]
    subsd xmm0, [rel g_cam_pos + 8]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(R_B + 4)], xmm0
    cvtsi2sd xmm0, dword [rbx + VENT.knot + 8]
    addsd xmm0, [rel c_half_d]
    subsd xmm0, [rel g_cam_pos + 16]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(R_B + 8)], xmm0
    jmp .ends
.hand:
    ; forward (sin, 0, -cos) and right (cos, 0, sin) of the view's yaw
    movss xmm0, [rel g_cam_yaw]
    call sincosf
    movss xmm2, xmm0
    mulss xmm2, [rel c_hand_fwd]
    movss xmm3, xmm1
    mulss xmm3, [rel c_hand_right]
    addss xmm2, xmm3
    movss [LOCAL(R_B)], xmm2
    mov eax, [rel c_hand_down]
    mov [LOCAL(R_B + 4)], eax
    mulss xmm1, [rel c_hand_fwd]
    mulss xmm0, [rel c_hand_right]
    subss xmm0, xmm1
    movss [LOCAL(R_B + 8)], xmm0
.ends:
    ; the slack: 0.12 a block, less as it nears 10 blocks (snapping)
    movss xmm0, [LOCAL(R_B)]
    subss xmm0, [LOCAL(R_A)]
    mulss xmm0, xmm0
    movss xmm1, [LOCAL(R_B + 4)]
    subss xmm1, [LOCAL(R_A + 4)]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [LOCAL(R_B + 8)]
    subss xmm1, [LOCAL(R_A + 8)]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0                   ; its length
    movss xmm1, xmm0
    mulss xmm1, [rel c_tenth]
    movss xmm2, [rel c_one]
    subss xmm2, xmm1
    maxss xmm2, [rel c_sag_min]
    mulss xmm0, [rel c_sag]
    mulss xmm0, xmm2
    movss [LOCAL(R_SAG)], xmm0
    mov eax, [LOCAL(R_A)]
    mov [LOCAL(R_P0)], eax
    mov eax, [LOCAL(R_A + 4)]
    mov [LOCAL(R_P0 + 4)], eax
    mov eax, [LOCAL(R_A + 8)]
    mov [LOCAL(R_P0 + 8)], eax
    mov dword [LOCAL(R_I)], 1
.seg:
    ; P1 = A + (B - A) t, sagging 4 t (1 - t) of the slack
    cvtsi2ss xmm0, dword [LOCAL(R_I)]
    mulss xmm0, [rel c_inv_segs]        ; t
    xor ecx, ecx
.axis:
    movss xmm1, [LOCAL(R_B) + rcx * 4]
    subss xmm1, [LOCAL(R_A) + rcx * 4]
    mulss xmm1, xmm0
    addss xmm1, [LOCAL(R_A) + rcx * 4]
    movss [LOCAL(R_P1) + rcx * 4], xmm1
    inc ecx
    cmp ecx, 3
    jb .axis
    movss xmm1, [rel c_one]
    subss xmm1, xmm0
    mulss xmm1, xmm0
    mulss xmm1, [rel c_four]
    mulss xmm1, [LOCAL(R_SAG)]
    movss xmm2, [LOCAL(R_P1 + 4)]
    subss xmm2, xmm1
    movss [LOCAL(R_P1 + 4)], xmm2
    ; the box along P0 -> P1: yaw = atan2(-dx, dz), pitch = atan2(-dy, flat)
    xor ecx, ecx
.d:
    movss xmm1, [LOCAL(R_P1) + rcx * 4]
    subss xmm1, [LOCAL(R_P0) + rcx * 4]
    movss [LOCAL(R_D) + rcx * 4], xmm1
    inc ecx
    cmp ecx, 3
    jb .d
    movss xmm0, [LOCAL(R_D)]
    mulss xmm0, xmm0
    movss xmm1, [LOCAL(R_D + 8)]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    movss [LOCAL(R_H)], xmm0
    movss xmm1, [LOCAL(R_D + 4)]
    mulss xmm1, xmm1
    mulss xmm0, xmm0
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    movss [LOCAL(R_LEN)], xmm0
    movss xmm0, [LOCAL(R_D)]
    xorps xmm0, [rel c_neg]
    movss xmm1, [LOCAL(R_D + 8)]
    call atan2f
    movss [LOCAL(R_YAW)], xmm0
    movss xmm0, [LOCAL(R_D + 4)]
    xorps xmm0, [rel c_neg]
    movss xmm1, [LOCAL(R_H)]
    call atan2f                         ; (the pitch)
    ; the record
    movss [rdi + 60], xmm0
    mov eax, [LOCAL(R_P0)]
    mov [rdi], eax
    mov eax, [LOCAL(R_P0 + 4)]
    mov [rdi + 4], eax
    mov eax, [LOCAL(R_P0 + 8)]
    mov [rdi + 8], eax
    xor eax, eax
    mov [rdi + 12], eax                 ; (no body yaw)
    mov [rdi + 16], eax                 ; pivot 0
    mov [rdi + 20], eax
    mov [rdi + 24], eax
    mov edx, [rel c_one]
    mov [rdi + 28], edx                 ; scale 1
    mov ecx, [rel c_half_thick]
    mov [rdi + 32], ecx                 ; corner: centred on the line
    mov [rdi + 36], ecx
    mov [rdi + 40], eax
    cvtsi2ss xmm0, dword [rel g_rope_layer]
    movss [rdi + 44], xmm0
    mov ecx, [rel c_thick]
    mov [rdi + 48], ecx
    mov [rdi + 52], ecx
    movss xmm0, [LOCAL(R_LEN)]
    mulss xmm0, [rel c_px]
    movss [rdi + 56], xmm0              ; its length in pixels
    mov ecx, [LOCAL(R_YAW)]
    mov [rdi + 64], ecx
    mov [rdi + 68], eax
    mov [rdi + 72], eax
    mov [rdi + 76], eax
    mov ecx, [rbx + VENT.sky]
    mov [rdi + 80], ecx
    mov [rdi + 84], eax
    mov [rdi + 88], edx                 ; box scale 1
    mov [rdi + 92], eax
    mov [rdi + 96], eax
    mov [rdi + 100], eax
    mov [rdi + 104], eax
    mov [rdi + 108], eax
    add rdi, INST_BYTES
    inc dword [rel g_mob_boxes]
    ; on to the next
    mov eax, [LOCAL(R_P1)]
    mov [LOCAL(R_P0)], eax
    mov eax, [LOCAL(R_P1 + 4)]
    mov [LOCAL(R_P0 + 4)], eax
    mov eax, [LOCAL(R_P1 + 8)]
    mov [LOCAL(R_P0 + 8)], eax
    inc dword [LOCAL(R_I)]
    cmp dword [LOCAL(R_I)], ROPE_SEGS
    jbe .seg
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
