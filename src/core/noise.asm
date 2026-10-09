; =============================================================================
; noise.asm — seeded gradient noise (Perlin-style, quintic fade) in 2D and
; 3D, and fractal sums of it.
;
; Coordinates are doubles, so the lattice cell and the fraction stay exact
; far from the origin; the fraction and the gradient math are floats. The
; lattice hash mixes the cell, the seed and an integer salt per field, so
; every noise field of a world is independent and fully deterministic.
;
; Public API (include/noise.inc):
;   noise2(x, y, seed) -> xmm0 float in about [-1, 1]
;       in: xmm0 = x (double), xmm1 = y (double), ecx = seed
;   noise3(x, y, z, seed) -> xmm0 float in about [-1, 1]
;       in: xmm0, xmm1, xmm2 = x, y, z (doubles), ecx = seed
;   fbm2(NOISE*, x, y, seed) -> xmm0      fbm3(NOISE*, x, y, z, seed)
;       in: rcx = NOISE*, xmm1/xmm2(/xmm3) = coordinates, edx = world seed
;       octave sum normalised to about [-1, 1]; NOISE.ridged = 1 sums
;       (1 - |n|) * 2 - 1 instead (sharp ridges)
;   All clobber rax, rcx, rdx, r8-r11, xmm0-xmm5 only.
; =============================================================================
%include "macros.inc"
%define NOISE_IMPL
%include "noise.inc"

global noise2, noise3, fbm2, fbm3

section .rdata
align 16
; 2D gradients: 8 directions (x, y)
grad2:  dd 1.0, 0.0,  -1.0, 0.0,  0.0, 1.0,  0.0, -1.0
        dd 0.70710678, 0.70710678,  -0.70710678, 0.70710678
        dd 0.70710678, -0.70710678, -0.70710678, -0.70710678
; 3D gradients: the 12 cube edge directions, 4 repeated (x, y, z, pad)
grad3:  dd 1.0, 1.0, 0.0, 0,   -1.0, 1.0, 0.0, 0,   1.0, -1.0, 0.0, 0,   -1.0, -1.0, 0.0, 0
        dd 1.0, 0.0, 1.0, 0,   -1.0, 0.0, 1.0, 0,   1.0, 0.0, -1.0, 0,   -1.0, 0.0, -1.0, 0
        dd 0.0, 1.0, 1.0, 0,   0.0, -1.0, 1.0, 0,   0.0, 1.0, -1.0, 0,   0.0, -1.0, -1.0, 0
        dd 1.0, 1.0, 0.0, 0,   -1.0, 1.0, 0.0, 0,   0.0, -1.0, 1.0, 0,   0.0, -1.0, -1.0, 0
c_one:      dd 1.0
c_two:      dd 2.0
c_six:      dd 6.0
c_fifteen:  dd 15.0
c_ten:      dd 10.0
c_scale2:   dd 1.41421356
c_scale3:   dd 1.0
align 16
c_abs:      dd 0x7FFFFFFF, 0, 0, 0

section .text

; -----------------------------------------------------------------------------
; hash — 32-bit lattice hash.
;   in:  r8d = ix, r9d = iy, r10d = iz, r11d = seed    out: eax
;   clobbers: rax, rdx
; -----------------------------------------------------------------------------
hash:
    imul eax, r8d, 0x8DA6B343
    imul edx, r9d, 0xD8163841
    add eax, edx
    imul edx, r10d, 0x6C8E9CF5
    add eax, edx
    imul edx, r11d, 0xCB1AB31F
    add eax, edx
    mov edx, eax
    shr edx, 15
    xor eax, edx
    imul eax, eax, 0x2C1B3C6D
    mov edx, eax
    shr edx, 12
    xor eax, edx
    imul eax, eax, 0x297A2D39
    mov edx, eax
    shr edx, 15
    xor eax, edx
    ret

; -----------------------------------------------------------------------------
; fade — quintic 6t^5 - 15t^4 + 10t^3.   in/out: xmm0   clobbers: xmm1, xmm2
; -----------------------------------------------------------------------------
fade:
    movss xmm1, xmm0
    mulss xmm1, [rel c_six]
    subss xmm1, [rel c_fifteen]
    mulss xmm1, xmm0
    addss xmm1, [rel c_ten]             ; t(6t - 15) + 10
    movss xmm2, xmm0
    mulss xmm2, xmm0
    mulss xmm2, xmm0                    ; t^3
    mulss xmm1, xmm2
    movss xmm0, xmm1
    ret

; -----------------------------------------------------------------------------
; noise2 — 2D gradient noise.   (see header)
; -----------------------------------------------------------------------------
%define N_FX    0
%define N_FY    4
%define N_FZ    8
%define N_D     16                      ; 8 corner dot products
%define N_IX    48
%define N_IY    52
%define N_IZ    56
%define N_SEED  60
%define N_U     64
%define N_V     68
%define N_W     72
PROC noise2, 80
    mov [LOCAL(N_SEED)], ecx
    roundsd xmm2, xmm0, 9               ; floor
    roundsd xmm3, xmm1, 9
    cvttsd2si rax, xmm2
    mov [LOCAL(N_IX)], eax
    cvttsd2si rax, xmm3
    mov [LOCAL(N_IY)], eax
    subsd xmm0, xmm2
    subsd xmm1, xmm3
    cvtsd2ss xmm0, xmm0
    cvtsd2ss xmm1, xmm1
    movss [LOCAL(N_FX)], xmm0
    movss [LOCAL(N_FY)], xmm1
    xor ecx, ecx                        ; corner 0..3
.corner:
    mov r8d, ecx
    and r8d, 1
    mov r9d, ecx
    shr r9d, 1
    add r8d, [LOCAL(N_IX)]
    add r9d, [LOCAL(N_IY)]
    xor r10d, r10d
    mov r11d, [LOCAL(N_SEED)]
    call hash
    and eax, 7
    lea rdx, [rel grad2]
    lea rdx, [rdx + rax * 8]
    ; dot = gx * (fx - cx) + gy * (fy - cy)
    movss xmm0, [LOCAL(N_FX)]
    test ecx, 1
    jz .x0
    subss xmm0, [rel c_one]
.x0:
    mulss xmm0, [rdx]
    movss xmm1, [LOCAL(N_FY)]
    test ecx, 2
    jz .y0
    subss xmm1, [rel c_one]
.y0:
    mulss xmm1, [rdx + 4]
    addss xmm0, xmm1
    movss [LOCAL(N_D) + rcx * 4], xmm0
    inc ecx
    cmp ecx, 4
    jb .corner
    movss xmm0, [LOCAL(N_FX)]
    call fade
    movss [LOCAL(N_U)], xmm0
    movss xmm0, [LOCAL(N_FY)]
    call fade
    movss xmm3, xmm0                    ; v
    ; a = d0 + u (d1 - d0), b = d2 + u (d3 - d2), r = a + v (b - a)
    movss xmm4, [LOCAL(N_U)]
    movss xmm0, [LOCAL(N_D) + 4]
    subss xmm0, [LOCAL(N_D)]
    mulss xmm0, xmm4
    addss xmm0, [LOCAL(N_D)]
    movss xmm1, [LOCAL(N_D) + 12]
    subss xmm1, [LOCAL(N_D) + 8]
    mulss xmm1, xmm4
    addss xmm1, [LOCAL(N_D) + 8]
    subss xmm1, xmm0
    mulss xmm1, xmm3
    addss xmm0, xmm1
    mulss xmm0, [rel c_scale2]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; noise3 — 3D gradient noise.   (see header)
; -----------------------------------------------------------------------------
PROC noise3, 80
    mov [LOCAL(N_SEED)], ecx
    roundsd xmm3, xmm0, 9
    roundsd xmm4, xmm1, 9
    roundsd xmm5, xmm2, 9
    cvttsd2si rax, xmm3
    mov [LOCAL(N_IX)], eax
    cvttsd2si rax, xmm4
    mov [LOCAL(N_IY)], eax
    cvttsd2si rax, xmm5
    mov [LOCAL(N_IZ)], eax
    subsd xmm0, xmm3
    subsd xmm1, xmm4
    subsd xmm2, xmm5
    cvtsd2ss xmm0, xmm0
    cvtsd2ss xmm1, xmm1
    cvtsd2ss xmm2, xmm2
    movss [LOCAL(N_FX)], xmm0
    movss [LOCAL(N_FY)], xmm1
    movss [LOCAL(N_FZ)], xmm2
    xor ecx, ecx                        ; corner 0..7: bit0 x, bit1 y, bit2 z
.corner:
    mov r8d, ecx
    and r8d, 1
    add r8d, [LOCAL(N_IX)]
    mov r9d, ecx
    shr r9d, 1
    and r9d, 1
    add r9d, [LOCAL(N_IY)]
    mov r10d, ecx
    shr r10d, 2
    add r10d, [LOCAL(N_IZ)]
    mov r11d, [LOCAL(N_SEED)]
    call hash
    and eax, 15
    shl eax, 4
    lea rdx, [rel grad3]
    add rdx, rax
    movss xmm0, [LOCAL(N_FX)]
    test ecx, 1
    jz .x0
    subss xmm0, [rel c_one]
.x0:
    mulss xmm0, [rdx]
    movss xmm1, [LOCAL(N_FY)]
    test ecx, 2
    jz .y0
    subss xmm1, [rel c_one]
.y0:
    mulss xmm1, [rdx + 4]
    addss xmm0, xmm1
    movss xmm1, [LOCAL(N_FZ)]
    test ecx, 4
    jz .z0
    subss xmm1, [rel c_one]
.z0:
    mulss xmm1, [rdx + 8]
    addss xmm0, xmm1
    movss [LOCAL(N_D) + rcx * 4], xmm0
    inc ecx
    cmp ecx, 8
    jb .corner
    movss xmm0, [LOCAL(N_FX)]
    call fade
    movss [LOCAL(N_U)], xmm0
    movss xmm0, [LOCAL(N_FY)]
    call fade
    movss [LOCAL(N_V)], xmm0
    movss xmm0, [LOCAL(N_FZ)]
    call fade
    movss [LOCAL(N_W)], xmm0
    ; lerp along x for the 4 (y, z) pairs: d[k] = d[2k] + u (d[2k+1] - d[2k])
    movss xmm4, [LOCAL(N_U)]
    xor ecx, ecx
.lx:
    movss xmm0, [LOCAL(N_D) + rcx * 8 + 4]
    subss xmm0, [LOCAL(N_D) + rcx * 8]
    mulss xmm0, xmm4
    addss xmm0, [LOCAL(N_D) + rcx * 8]
    movss [LOCAL(N_D) + rcx * 4], xmm0
    inc ecx
    cmp ecx, 4
    jb .lx
    ; along y: e0 = d0 + v (d1 - d0), e1 = d2 + v (d3 - d2)
    movss xmm4, [LOCAL(N_V)]
    movss xmm0, [LOCAL(N_D) + 4]
    subss xmm0, [LOCAL(N_D)]
    mulss xmm0, xmm4
    addss xmm0, [LOCAL(N_D)]
    movss xmm1, [LOCAL(N_D) + 12]
    subss xmm1, [LOCAL(N_D) + 8]
    mulss xmm1, xmm4
    addss xmm1, [LOCAL(N_D) + 8]
    ; along z
    subss xmm1, xmm0
    mulss xmm1, [LOCAL(N_W)]
    addss xmm0, xmm1
    mulss xmm0, [rel c_scale3]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; fbm2 / fbm3 — fractal sum over NOISE.octaves octaves.   (see header)
; -----------------------------------------------------------------------------
%define F_X     0                       ; doubles
%define F_Y     8
%define F_Z     16
%define F_SUM   24                      ; floats
%define F_AMP   28
%define F_NORM  32
%define F_OCT   36
%define F_SEED  40
%define F_P     48
%define F_DIM   56
fbm2:
    mov r8d, 2
    jmp fbm_impl

fbm3:
    mov r8d, 3
    jmp fbm_impl

; -----------------------------------------------------------------------------
; fbm_impl — fbm2 / fbm3 with the dimension in r8d (2 or 3).
; -----------------------------------------------------------------------------
PROC fbm_impl, 64
    mov [LOCAL(F_DIM)], r8d
    mov [LOCAL(F_P)], rcx
    ; seed = world seed * 31 + salt
    imul edx, edx, 31
    add edx, [rcx + NOISE.salt]
    mov [LOCAL(F_SEED)], edx
    mulsd xmm1, [rcx + NOISE.freq]
    mulsd xmm2, [rcx + NOISE.freq]
    mulsd xmm3, [rcx + NOISE.freq]
    movsd [LOCAL(F_X)], xmm1
    movsd [LOCAL(F_Y)], xmm2
    movsd [LOCAL(F_Z)], xmm3
    xorps xmm0, xmm0
    movss [LOCAL(F_SUM)], xmm0
    movss [LOCAL(F_NORM)], xmm0
    movss xmm0, [rel c_one]
    movss [LOCAL(F_AMP)], xmm0
    mov dword [LOCAL(F_OCT)], 0
.octave:
    mov rcx, [LOCAL(F_P)]
    mov eax, [LOCAL(F_OCT)]
    cmp eax, [rcx + NOISE.octaves]
    jae .done
    movsd xmm0, [LOCAL(F_X)]
    movsd xmm1, [LOCAL(F_Y)]
    movsd xmm2, [LOCAL(F_Z)]
    mov ecx, [LOCAL(F_SEED)]
    add ecx, eax                        ; a different lattice per octave
    imul ecx, ecx, 0x9E3779B1
    cmp dword [LOCAL(F_DIM)], 2
    jne .three
    call noise2
    jmp .have
.three:
    call noise3
.have:
    mov rcx, [LOCAL(F_P)]
    cmp dword [rcx + NOISE.ridged], 0
    je .plain
    ; ridged: (1 - |n|) * 2 - 1
    andps xmm0, [rel c_abs]
    movss xmm1, [rel c_one]
    subss xmm1, xmm0
    addss xmm1, xmm1
    subss xmm1, [rel c_one]
    movss xmm0, xmm1
.plain:
    mulss xmm0, [LOCAL(F_AMP)]
    addss xmm0, [LOCAL(F_SUM)]
    movss [LOCAL(F_SUM)], xmm0
    movss xmm0, [LOCAL(F_AMP)]
    addss xmm0, [LOCAL(F_NORM)]
    movss [LOCAL(F_NORM)], xmm0
    movss xmm0, [LOCAL(F_AMP)]
    mulss xmm0, [rcx + NOISE.persistence]
    movss [LOCAL(F_AMP)], xmm0
    ; next octave: coordinates x lacunarity (2)
    movsd xmm0, [LOCAL(F_X)]
    addsd xmm0, xmm0
    movsd [LOCAL(F_X)], xmm0
    movsd xmm0, [LOCAL(F_Y)]
    addsd xmm0, xmm0
    movsd [LOCAL(F_Y)], xmm0
    movsd xmm0, [LOCAL(F_Z)]
    addsd xmm0, xmm0
    movsd [LOCAL(F_Z)], xmm0
    inc dword [LOCAL(F_OCT)]
    jmp .octave
.done:
    movss xmm0, [LOCAL(F_SUM)]
    movss xmm1, [LOCAL(F_NORM)]
    xorps xmm2, xmm2
    comiss xmm1, xmm2
    jbe .zero
    divss xmm0, xmm1
    RETURN
.zero:
    xorps xmm0, xmm0
    RETURN
ENDPROC
