; =============================================================================
; camera.asm — debug fly camera (client side).
;
; Conventions: right-handed, +Y up, yaw 0 looks toward -Z ("north"), yaw grows
; turning right (toward +X, "east"), pitch > 0 looks up.
; Rendering is camera-relative: shaders get g_cam_viewproj (rotation +
; projection only) and g_cam_pos, and transform (world - cam_pos). This keeps
; float precision when far from the origin.
; Projection: infinite far plane, reverse-Z, depth range [0,1]
; (glClipControl ZERO_TO_ONE; depth clear 0, GL_GREATER).
;
; Public API:
;   camera_init()                   default position/orientation
;   camera_update(ecx=w, edx=h)     apply mouse + movement actions for this
;                                   frame and rebuild g_cam_viewproj
;   g_cam_pos (3 doubles), g_cam_yaw, g_cam_pitch (radians), g_cam_viewproj
;   g_cam_autofly: nonzero = always fly forward (streaming tests, --flytest)
; =============================================================================
%include "macros.inc"
%include "input.inc"

global camera_init, camera_update
global g_cam_pos, g_cam_yaw, g_cam_pitch, g_cam_viewproj, g_cam_autofly

extern sincosf
extern g_frame_us

section .rdata
align 16
c_neg_mask:     dd 0x80000000, 0, 0, 0     ; 16-byte aligned (xorps operand)
c_deg2rad:      dd 0.017453292
c_two_pi:       dd 6.283185307
c_pitch_limit:  dd 1.553343         ; 89 degrees
c_half_fov:     dd 0.610865238      ; 70 degree vertical FOV / 2
c_near:         dd 0.05
c_us_to_s:      dd 0.000001
c_max_dt:       dd 0.1
c_one:          dd 1.0
c_zero:         dd 0.0
; start position: south of the block gallery and the test structures,
; looking north, slightly down
align 8
c_start_pos:    dq 0.5, 118.0, 462.0       ; doubles
c_start_pitch:  dd -0.35

section .bss
alignb 64
g_cam_viewproj: resd 16
alignb 8
g_cam_pos:      resq 3                  ; doubles: precise far from the origin
g_cam_autofly:  resd 1
g_cam_yaw:      resd 1
g_cam_pitch:    resd 1
alignb 4
t_sy:           resd 1
t_cy:           resd 1
t_sp:           resd 1
t_cp:           resd 1

section .text

; -----------------------------------------------------------------------------
; camera_init — reset to the start position.
;   clobbers: rax, xmm0
; -----------------------------------------------------------------------------
camera_init:
    mov rax, [rel c_start_pos]
    mov [rel g_cam_pos], rax
    mov rax, [rel c_start_pos + 8]
    mov [rel g_cam_pos + 8], rax
    mov rax, [rel c_start_pos + 16]
    mov [rel g_cam_pos + 16], rax
    mov dword [rel g_cam_yaw], 0
    movss xmm0, [rel c_start_pitch]
    movss [rel g_cam_pitch], xmm0
    ret

; -----------------------------------------------------------------------------
; axis_value — +1/-1/0 from a pair of actions.
;   in:  ecx = positive action, edx = negative action
;   out: xmm0 = 1.0, -1.0 or 0.0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC axis_value, 0, rbx, rsi
    mov esi, edx
    call input_down
    mov ebx, eax
    mov ecx, esi
    call input_down
    sub ebx, eax
    cvtsi2ss xmm0, ebx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; camera_update — mouse look, fly movement and matrix rebuild.
;   in:  ecx = framebuffer width, edx = framebuffer height (both > 0)
;   out: none
;   clobbers: volatile registers (incl. xmm0-xmm5)
; -----------------------------------------------------------------------------
%define CU_ASPECT   0
%define CU_DT       4
%define CU_F        8
%define CU_R        12
%define CU_U        16
%define CU_XMM6     32                  ; saved xmm6/xmm7 (nonvolatile)
%define CU_XMM7     48
PROC camera_update, 64
    movdqu [LOCAL(CU_XMM6)], xmm6
    movdqu [LOCAL(CU_XMM7)], xmm7
    cvtsi2ss xmm0, ecx
    cvtsi2ss xmm1, edx
    divss xmm0, xmm1
    movss [LOCAL(CU_ASPECT)], xmm0

    ; dt in seconds, clamped (no huge jumps after a hitch)
    mov rax, [rel g_frame_us]
    cvtsi2ss xmm0, rax
    mulss xmm0, [rel c_us_to_s]
    minss xmm0, [rel c_max_dt]
    movss [LOCAL(CU_DT)], xmm0

    ; ---- mouse look --------------------------------------------------------------
    cmp dword [rel g_mouse_captured], 0
    je .no_look
    movss xmm2, [rel g_mouse_sensitivity]
    mulss xmm2, [rel c_deg2rad]         ; radians per count
    cvtsi2ss xmm0, dword [rel g_mouse_dx]
    mulss xmm0, xmm2
    addss xmm0, [rel g_cam_yaw]
    ; wrap yaw into [0, 2pi)
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jae .yaw_not_neg
    addss xmm0, [rel c_two_pi]
.yaw_not_neg:
    comiss xmm0, [rel c_two_pi]
    jb .yaw_ok
    subss xmm0, [rel c_two_pi]
.yaw_ok:
    movss [rel g_cam_yaw], xmm0
    cvtsi2ss xmm0, dword [rel g_mouse_dy]
    mulss xmm0, xmm2
    xorps xmm1, xmm1
    comiss xmm1, [rel g_invert_mouse_y]
    je .no_invert
    xorps xmm0, [rel c_neg_mask]
.no_invert:
    movss xmm1, [rel g_cam_pitch]
    subss xmm1, xmm0
    minss xmm1, [rel c_pitch_limit]
    movss xmm0, [rel c_pitch_limit]
    xorps xmm0, [rel c_neg_mask]
    maxss xmm1, xmm0
    movss [rel g_cam_pitch], xmm1
.no_look:

    ; ---- orientation ------------------------------------------------------------------
    movss xmm0, [rel g_cam_yaw]
    call sincosf
    movss [rel t_sy], xmm0
    movss [rel t_cy], xmm1
    movss xmm0, [rel g_cam_pitch]
    call sincosf
    movss [rel t_sp], xmm0
    movss [rel t_cp], xmm1

    ; ---- movement -----------------------------------------------------------------------
    INVOKE axis_value, ACT_MOVE_FORWARD, ACT_MOVE_BACK
    cmp dword [rel g_cam_autofly], 0
    je .manual_forward
    movss xmm0, [rel c_one]             ; test mode: always forward
.manual_forward:
    movss [LOCAL(CU_F)], xmm0
    INVOKE axis_value, ACT_MOVE_RIGHT, ACT_MOVE_LEFT
    movss [LOCAL(CU_R)], xmm0
    INVOKE axis_value, ACT_MOVE_UP, ACT_MOVE_DOWN
    movss [LOCAL(CU_U)], xmm0
    ; wish = f*(sy,0,-cy) + r*(cy,0,sy) + u*(0,1,0)
    movss xmm3, [LOCAL(CU_F)]
    movss xmm4, [LOCAL(CU_R)]
    movss xmm0, xmm3
    mulss xmm0, [rel t_sy]
    movss xmm1, xmm4
    mulss xmm1, [rel t_cy]
    addss xmm0, xmm1                    ; wx
    movss xmm2, xmm4
    mulss xmm2, [rel t_sy]
    movss xmm1, xmm3
    mulss xmm1, [rel t_cy]
    subss xmm2, xmm1                    ; wz
    movss xmm1, [LOCAL(CU_U)]           ; wy
    ; normalise (diagonals are not faster)
    movss xmm5, xmm0
    mulss xmm5, xmm0
    movss xmm6, xmm1
    mulss xmm6, xmm1
    addss xmm5, xmm6
    movss xmm6, xmm2
    mulss xmm6, xmm2
    addss xmm5, xmm6
    xorps xmm6, xmm6
    comiss xmm5, xmm6
    jbe .no_move
    sqrtss xmm5, xmm5
    ; scale = speed * (sprint ? mult : 1) * dt / len
    movss xmm6, [rel g_fly_speed]
    mulss xmm6, [LOCAL(CU_DT)]
    divss xmm6, xmm5
    movss [LOCAL(CU_F)], xmm0           ; keep wx/wy/wz across the call
    movss [LOCAL(CU_R)], xmm1
    movss [LOCAL(CU_U)], xmm2
    movss [LOCAL(CU_ASPECT) + 24], xmm6
    mov ecx, ACT_SPRINT
    call input_down
    movss xmm6, [LOCAL(CU_ASPECT) + 24]
    test eax, eax
    jz .no_sprint
    mulss xmm6, [rel g_fly_sprint_mult]
.no_sprint:
    movss xmm0, [LOCAL(CU_F)]           ; (CU_F/R/U hold wish x/y/z here)
    mulss xmm0, xmm6
    cvtss2sd xmm0, xmm0
    addsd xmm0, [rel g_cam_pos]
    movsd [rel g_cam_pos], xmm0
    movss xmm0, [LOCAL(CU_R)]
    mulss xmm0, xmm6
    cvtss2sd xmm0, xmm0
    addsd xmm0, [rel g_cam_pos + 8]
    movsd [rel g_cam_pos + 8], xmm0
    movss xmm0, [LOCAL(CU_U)]
    mulss xmm0, xmm6
    cvtss2sd xmm0, xmm0
    addsd xmm0, [rel g_cam_pos + 16]
    movsd [rel g_cam_pos + 16], xmm0
.no_move:

    ; ---- view-projection (rotation only; column-major) --------------------------------------
    ; F = (sy*cp, sp, -cy*cp)   R = (cy, 0, sy)   U = (-sy*sp, cp, cy*sp)
    ; f = cot(fov/2), fa = f / aspect
    ; col j<3 = (fa*R_j, f*U_j, 0, F_j)        col3 = (0, 0, near, 0)
    movss xmm0, [rel c_half_fov]
    call sincosf
    divss xmm1, xmm0                    ; xmm1 = f
    movss xmm7, xmm1                    ; xmm7 = f
    movss xmm6, xmm1
    divss xmm6, [LOCAL(CU_ASPECT)]      ; xmm6 = fa
    lea rax, [rel g_cam_viewproj]
    xorps xmm5, xmm5
    ; column 0
    movss xmm0, [rel t_cy]
    mulss xmm0, xmm6
    movss [rax + 0], xmm0               ; fa*R.x
    movss xmm0, [rel t_sy]
    mulss xmm0, [rel t_sp]
    xorps xmm0, [rel c_neg_mask]
    mulss xmm0, xmm7
    movss [rax + 4], xmm0               ; f*U.x
    movss [rax + 8], xmm5
    movss xmm0, [rel t_sy]
    mulss xmm0, [rel t_cp]
    movss [rax + 12], xmm0              ; F.x
    ; column 1
    movss [rax + 16], xmm5              ; fa*R.y = 0
    movss xmm0, [rel t_cp]
    mulss xmm0, xmm7
    movss [rax + 20], xmm0              ; f*U.y
    movss [rax + 24], xmm5
    movss xmm0, [rel t_sp]
    movss [rax + 28], xmm0              ; F.y
    ; column 2
    movss xmm0, [rel t_sy]
    mulss xmm0, xmm6
    movss [rax + 32], xmm0              ; fa*R.z
    movss xmm0, [rel t_cy]
    mulss xmm0, [rel t_sp]
    mulss xmm0, xmm7
    movss [rax + 36], xmm0              ; f*U.z
    movss [rax + 40], xmm5
    movss xmm0, [rel t_cy]
    mulss xmm0, [rel t_cp]
    xorps xmm0, [rel c_neg_mask]
    movss [rax + 44], xmm0              ; F.z
    ; column 3
    movss [rax + 48], xmm5
    movss [rax + 52], xmm5
    movss xmm0, [rel c_near]
    movss [rax + 56], xmm0
    movss [rax + 60], xmm5

    movdqu xmm6, [LOCAL(CU_XMM6)]
    movdqu xmm7, [LOCAL(CU_XMM7)]
    RETURN
ENDPROC
