; =============================================================================
; math.asm — scalar math helpers not provided by SSE.
; =============================================================================
%include "macros.inc"

global sincosf, atan2f

section .bss
alignb 4
g_sc_tmp:   resd 1                      ; main-thread scratch for x87 transfers

section .text

; -----------------------------------------------------------------------------
; sincosf — sine and cosine of an angle (x87 fsincos; |angle| < 2^63).
;   in:  xmm0 = angle in radians (float)
;   out: xmm0 = sin(angle), xmm1 = cos(angle)
;   clobbers: xmm0, xmm1, x87 st0-st1 (left empty)
;   note: uses a static scratch slot; call from the main thread only.
; -----------------------------------------------------------------------------
sincosf:
    movss [rel g_sc_tmp], xmm0
    fld dword [rel g_sc_tmp]
    fsincos                             ; st0 = cos, st1 = sin
    fstp dword [rel g_sc_tmp]
    movss xmm1, [rel g_sc_tmp]
    fstp dword [rel g_sc_tmp]
    movss xmm0, [rel g_sc_tmp]
    ret

; -----------------------------------------------------------------------------
; atan2f — the angle of the point (x, y) (x87 fpatan; milestone 19).
;   in:  xmm0 = y, xmm1 = x (floats)
;   out: xmm0 = atan2(y, x) in radians, -pi .. pi
;   clobbers: xmm0, x87 st0-st1 (left empty)
;   note: uses a static scratch slot; call from the main thread only.
; -----------------------------------------------------------------------------
atan2f:
    movss [rel g_sc_tmp], xmm0
    fld dword [rel g_sc_tmp]            ; y
    movss [rel g_sc_tmp], xmm1
    fld dword [rel g_sc_tmp]            ; x (st0), y (st1)
    fpatan                              ; st0 = atan(st1 / st0), quadrant-correct
    fstp dword [rel g_sc_tmp]
    movss xmm0, [rel g_sc_tmp]
    ret
