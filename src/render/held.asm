; =============================================================================
; held.asm — first person (milestone 18; reworked after v0.19.3, D101):
; the player's arm in the lower right holding what is in the hand — a block
; as a small cube, an item or a flat block as a thin model of its picture
; (one 1/16 box per pixel), like Minecraft. The hand sways while walking,
; swings in an arc when used (again and again while mining) and dips while
; the item in hand changes. The off hand shows its item in the lower left.
; Drawn over the finished frame with its own cleared depth (shaders/held.*),
; before the HUD.
;
; Public API:
;   held_init() -> eax 1/0              after icons_init
;   held_draw(ecx = width, edx = height)
;   held_swing()                        start a swing (break / place)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "packet.inc"

global held_init, held_draw, held_swing

extern shader_create, shader_program, block_textures_bind, icon_uv, icon_kind
extern timer_elapsed_us, sincosf
extern g_cinv, g_csel, g_item_block, g_icon_tex, g_daylight, g_held_on, hand_light
extern g_cl_player, g_csv

%define SWING_US        300000          ; (Minecraft: 6 ticks)
%define EQUIP_US        160000          ; the dip when the item in hand changes
%define PICTURE_VERTS   (256 * 36)      ; a picture's 16 x 16 pixel boxes

section .rdata
str_vs:         db "shaders/held.vert", 0
str_fs:         db "shaders/held.frag", 0
align 4
c_us:           dd 0.000001
c_swing:        dd 3.3333333            ; 1 / 0.3 s
c_equip:        dd 6.25                 ; 1 / 0.16 s
c_one:          dd 1.0
c_light0:       dd 0.32
c_light1:       dd 0.68
c_held_min:     dd 0.85
c_bob_rate:     dd 9.0                  ; radians per second of walking
c_bob_amp:      dd 0.022
c_speed_full:   dd 4.3                  ; walking speed: full sway
c_neg:          dd -1.0

section .bss
alignb 8
g_swing_t0:     resq 1                  ; when the swing started (0: none)
g_bob_phase:    resd 1
g_prog:         resd 1
g_vao:          resd 1
g_uv:           resd 4
g_last_us:      resq 1
g_equip_t0:     resq 1                  ; when the main hand's item changed
g_equip_item:   resd 1                  ; the item it changed to

section .text

; held_init — the program and an empty VAO
PROC held_init, 0
    lea rcx, [rel str_vs]
    lea rdx, [rel str_fs]
    call shader_create
    cmp eax, -1
    je .fail
    mov ecx, eax
    call shader_program
    mov [rel g_prog], eax
    lea rdx, [rel g_vao]
    GL glCreateVertexArrays, 1, rdx
    mov eax, 1
    RETURN
.fail:
    LOG_WARN "held: the in-hand shader failed; nothing is shown in hand"
    xor eax, eax
    RETURN
ENDPROC

; held_swing — start a swing
PROC held_swing, 0
    call timer_elapsed_us
    mov [rel g_swing_t0], rax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; held_draw — see the header.
;   in:  ecx = width, edx = height
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC held_draw, 0, rbx, rsi, rdi
    mov esi, ecx
    mov edi, edx
    cmp dword [rel g_prog], 0
    je .done
    ; its own depth (the world's is in the scene's framebuffer)
    GL glDepthMask, GL_TRUE
    GL glClear, GL_DEPTH_BUFFER_BIT
    ; the main hand (lower right), then the off hand (mirrored, lower left)
    mov eax, [rel g_csel]
    lea rcx, [rel g_cinv]
    movzx r8d, word [rcx + rax * 8]
    mov ecx, esi
    mov edx, edi
    xor r9d, r9d
    call held_item
    lea rcx, [rel g_cinv]
    movzx r8d, word [rcx + INV_OFFHAND * 8]
    mov ecx, esi
    mov edx, edi
    mov r9d, 1
    call held_item
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; held_item — one hand: the main hand's arm (always) and what it holds.
;   in:  ecx = width, edx = height, r8d = item (0: none), r9d = 1 the off
;        hand (mirrored, no arm, no swing)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define D_W     0
%define D_H     4
%define D_ITEM  8
%define D_SWING 12
%define D_NOW   16
%define D_DT    24
%define D_SPEED 28
%define D_MIRROR 32
%define D_EQUIP 36
%define D_LIGHT 40
PROC held_item, 48, rbx, rsi
    mov [LOCAL(D_W)], ecx
    mov [LOCAL(D_H)], edx
    mov [LOCAL(D_MIRROR)], r9d
    mov ebx, r8d
    test edx, edx
    jz .done
    test ebx, ebx
    jnz .something
    cmp dword [LOCAL(D_MIRROR)], 0
    jne .done                           ; (an empty off hand: nothing)
.something:
    call timer_elapsed_us
    mov [LOCAL(D_NOW)], rax
    cmp dword [LOCAL(D_MIRROR)], 0
    jne .no_dt                          ; (the main hand steps the clocks)
    mov rcx, rax
    sub rcx, [rel g_last_us]
    mov [rel g_last_us], rax
    cmp rcx, 100000
    jbe .dt
    mov ecx, 100000
.dt:
    cvtsi2ss xmm0, rcx
    mulss xmm0, [rel c_us]
    movss [LOCAL(D_DT)], xmm0
    ; the item changed: dip and come back up
    cmp ebx, [rel g_equip_item]
    je .no_dt
    mov [rel g_equip_item], ebx
    mov [rel g_equip_t0], rax
.no_dt:
    GL glUseProgram, [rel g_prog]
    GL glBindVertexArray, [rel g_vao]
    call block_textures_bind
    GL glBindTextureUnit, 1, [rel g_icon_tex]
    GL glViewport, 0, 0, [LOCAL(D_W)], [LOCAL(D_H)]
    GL glEnable, GL_DEPTH_TEST
    GL glDisable, GL_CULL_FACE          ; (the depth sorts it; mirroring flips the winding)
    GL glDisable, GL_BLEND
    GL glProgramUniform1i, [rel g_prog], 7, [LOCAL(D_MIRROR)]
    xor eax, eax
    test ebx, ebx
    setz al
    GL glProgramUniform1i, [rel g_prog], 9, rax
    ; ---- the swing: 0..1 over SWING_US (the main hand only) ----
    xorps xmm0, xmm0
    cmp dword [LOCAL(D_MIRROR)], 0
    jne .swing
    mov rax, [rel g_swing_t0]
    test rax, rax
    jz .swing
    mov rcx, [LOCAL(D_NOW)]
    sub rcx, rax
    cmp rcx, SWING_US
    jae .swing_over
    cvtsi2ss xmm0, rcx
    mulss xmm0, [rel c_us]
    mulss xmm0, [rel c_swing]
    jmp .swing
.swing_over:
    mov qword [rel g_swing_t0], 0
.swing:
    movss [LOCAL(D_SWING)], xmm0
    movss xmm2, [LOCAL(D_SWING)]
    GL glProgramUniform1f, [rel g_prog], 3
    ; ---- the equip dip: 0 just changed .. 1 up ----
    movss xmm0, [rel c_one]
    cmp dword [LOCAL(D_MIRROR)], 0
    jne .equip
    mov rcx, [LOCAL(D_NOW)]
    sub rcx, [rel g_equip_t0]
    cmp rcx, EQUIP_US
    jae .equip
    cvtsi2ss xmm0, rcx
    mulss xmm0, [rel c_us]
    mulss xmm0, [rel c_equip]
.equip:
    movss [LOCAL(D_EQUIP)], xmm0
    movss xmm2, [LOCAL(D_EQUIP)]
    GL glProgramUniform1f, [rel g_prog], 8
    ; ---- eating (milestone 20): how far through, main hand only ----
    xorps xmm2, xmm2
    cmp dword [LOCAL(D_MIRROR)], 0
    jne .eat
    movzx eax, word [rel g_csv + SURV_PKT.eat]
    movzx ecx, word [rel g_csv + SURV_PKT.eat_total]
    test eax, eax
    jz .eat
    test ecx, ecx
    jz .eat
    cvtsi2ss xmm2, eax
    cvtsi2ss xmm0, ecx
    divss xmm2, xmm0
.eat:
    GL glProgramUniform1f, [rel g_prog], 10
    ; ---- walking sway: by the horizontal speed ----
    movss xmm0, [rel g_cl_player + PLAYER_PKT.vel]
    mulss xmm0, xmm0
    movss xmm1, [rel g_cl_player + PLAYER_PKT.vel + 8]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    test dword [rel g_cl_player + PLAYER_PKT.flags], PF_ON_GROUND
    jnz .ground
    xorps xmm0, xmm0
.ground:
    divss xmm0, [rel c_speed_full]
    minss xmm0, [rel c_one]
    movss [LOCAL(D_SPEED)], xmm0        ; 0..1
    movss xmm1, [rel g_bob_phase]
    cmp dword [LOCAL(D_MIRROR)], 0
    jne .phase_kept                     ; (the main hand steps the sway)
    movss xmm1, [LOCAL(D_DT)]
    mulss xmm1, [rel c_bob_rate]
    mulss xmm1, xmm0
    addss xmm1, [rel g_bob_phase]
    movss [rel g_bob_phase], xmm1
.phase_kept:
    movss xmm0, xmm1
    call sincosf                        ; xmm0 = sin, xmm1 = cos
    movss xmm2, [LOCAL(D_SPEED)]
    mulss xmm2, [rel c_bob_amp]
    mulss xmm0, xmm2                    ; x sway
    andps xmm1, [rel c_abs]
    mulss xmm1, xmm2
    mulss xmm1, [rel c_neg]             ; y: down on each step
    movss [rel g_uv], xmm0
    movss [rel g_uv + 4], xmm1
    lea r9, [rel g_uv]
    GL glProgramUniform2fv, [rel g_prog], 4, 1, r9
    cvtsi2ss xmm2, dword [LOCAL(D_W)]
    cvtsi2ss xmm0, dword [LOCAL(D_H)]
    divss xmm2, xmm0
    GL glProgramUniform1f, [rel g_prog], 5
    ; ---- light: the daylight, or the held light ----
    movss xmm2, [rel g_daylight]
    mulss xmm2, [rel c_light1]
    addss xmm2, [rel c_light0]
    cmp dword [rel g_held_on], 0
    jne .lit
    movss [LOCAL(D_LIGHT)], xmm2
    call hand_light                     ; (a light block in a hand)
    movss xmm2, [LOCAL(D_LIGHT)]
    test eax, eax
    jz .light
.lit:
    maxss xmm2, [rel c_held_min]
.light:
    GL glProgramUniform1f, [rel g_prog], 6
    ; ---- the arm (the main hand) ----
    cmp dword [LOCAL(D_MIRROR)], 0
    jne .no_arm
    GL glProgramUniform1i, [rel g_prog], 1, 0
    GL glDrawArrays, GL_TRIANGLES, 0, 36
.no_arm:
    test ebx, ebx
    jz .drawn
    ; ---- what it holds: a cube from the block textures, or a picture ----
    mov ecx, ebx
    call icon_kind
    mov esi, 1                          ; part 1: a block
    cmp eax, 2
    jne .kind
    mov esi, 2                          ; part 2: a picture
.kind:
    GL glProgramUniform1i, [rel g_prog], 1, rsi
    lea rax, [rel g_item_block]
    movzx r9d, word [rax + rbx * 2]
    GL glProgramUniform1ui, [rel g_prog], 0, r9
    mov ecx, ebx
    lea rdx, [rel g_uv]
    call icon_uv
    lea r9, [rel g_uv]
    GL glProgramUniform4fv, [rel g_prog], 2, 1, r9
    mov r8d, 36
    cmp esi, 2
    jne .count
    mov r8d, PICTURE_VERTS
.count:
    GL glDrawArrays, GL_TRIANGLES, 0, r8
.drawn:
    GL glEnable, GL_CULL_FACE
    GL glBindVertexArray, 0
.done:
    RETURN
ENDPROC

section .rdata
align 16
c_abs:          dd 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF
