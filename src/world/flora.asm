; =============================================================================
; flora.asm — what grows on the surface: ponds, ground cover, flowers,
; meadows, trees and bushes (design/biomes/plains.md). Every setting comes
; from the biome files (data/biomes/*.biome, src/world/biome.asm).
;
; Everything is a pure function of the world seed and position, so a chunk
; and its neighbours agree on every tree, plant and pond that crosses their
; border:
;   ponds   one candidate per 128 x 128 cell (biome pond_chance); an ellipse
;           dug below the lowest ground on its rim and filled with water;
;           (cells of 64 x 64 blocks)
;           radius at most 6 so its rim stays inside the heightmap border
;   trees   one candidate per 4 x 4 cell (biome tree_density, bush_density,
;           weighted lists); grown only on flat inland ground outside ponds
;   plants  per block: meadow (one candidate per 512 x 512 cell), flower
;           clusters (8 x 8 cells), else ground cover by chance
; Vegetation density fades towards biome borders (blend map weight).
;
; Public API (include/flora.inc):
;   flora_ponds(FCTX*)        dig ponds into the heightmap, set water levels
;   flora_prepare(FCTX*)      list the trees that can reach the chunk
;   flora_section(FCTX*, ids, y0)  place plants and trees in one section
; =============================================================================
%define FLORA_IMPL
%include "macros.inc"
%include "log.inc"
%include "world.inc"
%include "block.inc"
%include "terrain.inc"
%include "biome.inc"
%include "flora.inc"

global flora_ponds, flora_prepare, flora_section, flora_survey

extern g_world_seed, g_sea_level, g_beach_high, g_b_top
extern terrain_sample, log_xz

%define POND_CELL       64
%define POND_SPAN       (POND_CELL * 3 / 4)   ; centre range inside a cell
%define POND_OFS        (POND_CELL / 8)
%define POND_MAX_R      6.0
%define MEADOW_SHIFT    9               ; 512-block meadow cells
%define TREE_CELL_SHIFT 2               ; 4-block tree cells

; leaf and log placement modes (put_block)
%define PUT_LEAVES      0
%define PUT_LOG         1
%define PUT_PLANT       2
%define PUT_SOLID       3               ; replace anything (rocks, fossils, arch legs)

section .rdata
align 16
c_abs:          dd 0x7FFFFFFF, 0, 0, 0
align 4
c_one:          dd 1.0
c_half:         dd 0.5
c_zero:         dd 0.0
c_inv65536:     dd 0.0000152587890625
c_inv2_24:      dd 0.000000059604644775
c_pond_max_r:   dd POND_MAX_R
c_pond_min_r:   dd 1.5
c_rim:          dd 1.5                  ; rim: this far outside the ellipse
c_aspect_lo:    dd 0.6
c_aspect_span:  dd 0.4
c_keep_out:     dd 2.6                  ; trees: e (rim radii) to keep away
c_edge:         dd 0.55
c_ring_w:       dd 0.55                 ; ring thickness (half)
c_rock_top:     dd 0.45                 ; rock: top radius share
c_arch_flat:    dd 0.85                 ; arch: height / radius
c_arch_step:    dd 0.06                 ; arch: angle step (radians)
c_pi:           dd 3.14159265
c_arch_t:       dd 1.1                  ; arch thickness (disc radius)
c_palm_lean:    dd 0.18                 ; palm: lean per block (grows with height)
c_rock_rough:   dd 0.08                 ; rock: share of edge blocks left out
c_half_pi:      dd 1.5707963
c_inv6:         dd 0.16666667
c_inv12:        dd 0.083333333
c_inv20:        dd 0.05
c_inv30:        dd 0.033333333
c_inv42:        dd 0.023809524
c_inv56:        dd 0.017857143
align 16
c_sign:         dd 0x80000000, 0, 0, 0
c_g_crown:      dd 0.55                 ; giant: crown base at this share of the height
c_g_top_r:      dd 1.5                  ; trunk radius at the crown base (3 x 3)
c_g_end_r:      dd 0.8                  ; and at the top
c_g_taper:      dd 0.7                  ; (1.5 - 0.8)
c_g_upper:      dd 0.45                 ; (1 - 0.55)
c_g_flare:      dd 0.4                  ; extra radius per block below y 3
c_g_disc:       dd 0.35                 ; disc test slack
c_g_branch_lo:  dd 0.45
c_g_branch_span: dd 0.42
c_g_rise:       dd 0.55                 ; branch rise per block
c_g_root_drop:  dd 0.45                 ; root fall per block
c_g_root_in:    dd 0.6
c_g_cl_dn:      dd 0.7
c_g_cl_up:      dd 0.8
c_g_top_scale:  dd 1.1
c_3:            dd 3.0
c_clear_cell:   dd 0.00625              ; 1 / 160                 ; crown: leaves beyond this may drop
c_16:           dd 16.0
c_flower_cl:    dd 12.8                 ; cluster chance per flower share
c_cl_fill:      dd 0.6                  ; share of a cluster that flowers
c_wobble_lo:    dd 0.8                  ; meadow edge: radius x 0.8 .. 1.2
c_wobble_span:  dd 0.4
c_down:         dd 0.9                  ; crown shape: below / above centre
c_up:           dd 0.8
c_bush_down:    dd 1.0
c_bush_up:      dd 0.8
c_branch_up:    dd 0.6
c_branch_lo:    dd 0.45
c_branch_span:  dd 0.3
c_branch_r:     dd 0.75
; 16 directions (cos, sin) for giant roots and branches
dirs16:         dd 1.00000, 0.00000, 0.92388, 0.38268, 0.70711, 0.70711, 0.38268, 0.92388, 0.00000, 1.00000, -0.38268, 0.92388, -0.70711, 0.70711, -0.92388, 0.38268
                dd -1.00000, 0.00000, -0.92388, -0.38268, -0.70711, -0.70711, -0.38268, -0.92388, -0.00000, -1.00000, 0.38268, -0.92388, 0.70711, -0.70711, 0.92388, -0.38268
; 8 directions (cos, sin) for pond axes and branches
dirs:           dd 1.0, 0.0,  0.7071, 0.7071,  0.0, 1.0,  -0.7071, 0.7071
                dd -1.0, 0.0,  -0.7071, -0.7071,  0.0, -1.0,  0.7071, -0.7071

align 8
special_gen:    dq gen_giant, gen_fallen, gen_stump, gen_cactus, gen_rock
                dq gen_arch, gen_fossil, gen_palm, gen_conifer
                dq gen_acacia, gen_baobab

section .text

; -----------------------------------------------------------------------------
; hash4 — 32-bit hash of four integers and the world seed.
;   in:  ecx, edx, r8d, r9d      out: eax      clobbers: rax, rdx, r10
; -----------------------------------------------------------------------------
hash4:
    imul eax, ecx, 0x8DA6B343
    imul edx, edx, 0xD8163841
    add eax, edx
    imul r10d, r8d, 0xCB1AB31F
    add eax, r10d
    imul r10d, r9d, 0x6C8E9CF5
    add eax, r10d
    add eax, [rel g_world_seed]
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

; FRAC16 src — xmm0 = 16-bit value / 65536     clobbers: rax (!), xmm0
%macro FRAC16 1                         ; %1 = source register (32-bit)
    movzx eax, %1
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv65536]
%endmacro

; rng — LCG step on edi; xmm0 = 0..1 from the high 24 bits
;   clobbers: rax, xmm0
rng:
    imul edi, edi, 1664525
    add edi, 1013904223
    mov eax, edi
    shr eax, 8
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv2_24]
    ret

; floordiv — eax = floor(eax / ecx)        clobbers: rax, rdx
floordiv:
    cdq
    idiv ecx
    test edx, edx
    jns .ok
    dec eax
.ok:
    ret

; hm_index — eax = heightmap index of local (ecx = x, edx = z)
%macro HM_INDEX 2
    lea eax, [%2 + HB]
    imul eax, eax, HM
    lea eax, [eax + %1 + HB]
%endmacro

; -----------------------------------------------------------------------------
; put_block — set one block of the section being filled, if it is inside and
; the place is free for it.
;   in:  rbx = FCTX*, ecx = x, edx = world y, r8d = z (chunk-local),
;        r9d = id, r10d = PUT_LEAVES / PUT_LOG / PUT_PLANT
;   leaves: replace air and plants; logs: also leaves (cutout cubes);
;   plants: air only
;   clobbers: rax, rcx, rdx, r8, r11
; -----------------------------------------------------------------------------
put_block:
    cmp ecx, 31
    ja .no
    cmp r8d, 31
    ja .no
    sub edx, [rbx + FCTX.y0]
    cmp edx, 31
    ja .no
    shl edx, 10
    shl r8d, 5
    or edx, r8d
    or edx, ecx                         ; index
    mov rax, [rbx + FCTX.ids]
    movzx r11d, word [rax + rdx * 2]
    test r11d, r11d
    jz .put
    cmp r10d, PUT_SOLID
    je .put
    cmp r10d, PUT_PLANT
    je .no
    lea rcx, [rel g_block_shape]
    movzx ecx, byte [rcx + r11]
    cmp ecx, SHAPE_PLANT
    je .put
    cmp ecx, SHAPE_TALL_PLANT
    je .put
    cmp r10d, PUT_LOG
    jne .no
    test ecx, ecx
    jnz .no                             ; (other shaped blocks stay)
    lea rcx, [rel g_block_layer]
    cmp byte [rcx + r11], LAYER_CUTOUT
    jne .no
.put:
    mov [rax + rdx * 2], r9w
.no:
    ret

; -----------------------------------------------------------------------------
; ellipse — e = (u / rx)^2 + (v / rz)^2 of a column relative to a pond.
;   in:  rsi = POND*, ecx = x, edx = z (local)    out: xmm0 = e
;   clobbers: rax, xmm0-xmm3
; -----------------------------------------------------------------------------
ellipse:
    mov eax, ecx
    sub eax, [rsi + POND.x]
    cvtsi2ss xmm0, eax                  ; dx
    mov eax, edx
    sub eax, [rsi + POND.z]
    cvtsi2ss xmm1, eax                  ; dz
    movss xmm2, xmm0
    mulss xmm2, [rsi + POND.c]
    movss xmm3, xmm1
    mulss xmm3, [rsi + POND.s]
    addss xmm2, xmm3                    ; u
    mulss xmm1, [rsi + POND.c]
    mulss xmm0, [rsi + POND.s]
    subss xmm1, xmm0                    ; v
    divss xmm2, [rsi + POND.rx]
    divss xmm1, [rsi + POND.rz]
    mulss xmm2, xmm2
    mulss xmm1, xmm1
    addss xmm2, xmm1
    movss xmm0, xmm2
    ret

; -----------------------------------------------------------------------------
; flora_ponds — dig the ponds whose centre lies within 8 blocks of the chunk
; into the heightmap and record their water levels.
;   in:  rcx = FCTX*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define FP_CX       0                   ; cell
%define FP_CZ       4
%define FP_CZ1      8
%define FP_CX0      12
%define FP_CX1      16
%define FP_H        20                  ; hash
%define FP_H2       24
%define FP_B        28                  ; BIOME*
%define FP_MIN      40                  ; lowest rim height
%define FP_MAX      44                  ; highest inside
%define FP_W        48                  ; water level
%define FP_X        52
%define FP_Z        56
%define FP_D        60                  ; density
%define FP_RIMSQ    64                  ; f32 rim e
%define FP_POND     72                  ; POND (24 bytes)
%define FP_LOCALS   104
PROC flora_ponds, FP_LOCALS, rbx, rsi, rdi, r12, r13, r14, r15
    mov rbx, rcx
    mov dword [rbx + FCTX.npond], 0
    ; cells covering centres -16 .. 47 around the chunk (ponds within reach
    ; of the chunk's trees are listed too)
    mov eax, [rbx + FCTX.cx]
    shl eax, 5
    sub eax, 16
    mov ecx, POND_CELL
    call floordiv
    mov [LOCAL(FP_CX0)], eax
    mov eax, [rbx + FCTX.cx]
    shl eax, 5
    add eax, 47
    mov ecx, POND_CELL
    call floordiv
    mov [LOCAL(FP_CX1)], eax
    mov eax, [rbx + FCTX.cz]
    shl eax, 5
    sub eax, 16
    mov ecx, POND_CELL
    call floordiv
    mov [LOCAL(FP_CZ)], eax
    mov eax, [rbx + FCTX.cz]
    shl eax, 5
    add eax, 47
    mov ecx, POND_CELL
    call floordiv
    mov [LOCAL(FP_CZ1)], eax
.cell_z:
    mov eax, [LOCAL(FP_CX0)]
    mov [LOCAL(FP_CX)], eax
.cell_x:
    mov ecx, [LOCAL(FP_CX)]
    mov edx, [LOCAL(FP_CZ)]
    mov r8d, 0x5044                     ; "PD"
    xor r9d, r9d
    call hash4
    mov [LOCAL(FP_H)], eax
    mov ecx, [LOCAL(FP_CX)]
    mov edx, [LOCAL(FP_CZ)]
    mov r8d, 0x5045                     ; "PE"
    xor r9d, r9d
    call hash4
    mov [LOCAL(FP_H2)], eax
    ; centre: 16 .. 112 inside the cell
    mov eax, [LOCAL(FP_H)]
    shr eax, 16
    and eax, 0xFF
    imul eax, eax, POND_SPAN
    shr eax, 8
    add eax, POND_OFS
    mov ecx, [LOCAL(FP_CX)]
    imul ecx, ecx, POND_CELL
    add eax, ecx
    mov ecx, [rbx + FCTX.cx]
    shl ecx, 5
    sub eax, ecx                        ; local x
    mov [LOCAL(FP_X)], eax
    mov eax, [LOCAL(FP_H)]
    shr eax, 24
    imul eax, eax, POND_SPAN
    shr eax, 8
    add eax, POND_OFS
    mov ecx, [LOCAL(FP_CZ)]
    imul ecx, ecx, POND_CELL
    add eax, ecx
    mov ecx, [rbx + FCTX.cz]
    shl ecx, 5
    sub eax, ecx
    mov [LOCAL(FP_Z)], eax
    ; inside -16 .. 47?
    mov eax, [LOCAL(FP_X)]
    add eax, 16
    cmp eax, 63
    ja .next_cell
    mov eax, [LOCAL(FP_Z)]
    add eax, 16
    cmp eax, 63
    ja .next_cell
    ; biome there: chance x density
    mov rcx, [rbx + FCTX.bmap]
    mov edx, [LOCAL(FP_X)]
    mov r8d, [LOCAL(FP_Z)]
    call bmap_col
    movss [LOCAL(FP_D)], xmm0
    imul rax, rax, BIOME_size
    lea rcx, [rel g_biomes]
    add rax, rcx
    mov [LOCAL(FP_B)], rax
    movss xmm1, [rax + BIOME.pond_ch]
    mulss xmm1, [LOCAL(FP_D)]
    FRAC16 word [LOCAL(FP_H)]
    comiss xmm0, xmm1
    jae .next_cell
    ; on land, above the sea
    mov ecx, [LOCAL(FP_X)]
    mov edx, [LOCAL(FP_Z)]
    HM_INDEX ecx, edx
    mov rcx, [rbx + FCTX.heights]
    mov eax, [rcx + rax * 4]
    dec eax
    cmp eax, [rel g_sea_level]
    jle .next_cell                      ; (its water must not be below the sea)
    ; shape: radius, aspect, axis direction
    lea r12, [LOCAL(FP_POND)]
    mov eax, [LOCAL(FP_X)]
    mov [r12 + POND.x], eax
    mov eax, [LOCAL(FP_Z)]
    mov [r12 + POND.z], eax
    FRAC16 word [LOCAL(FP_H2)]
    mov rax, [LOCAL(FP_B)]
    movss xmm1, [rax + BIOME.pond_r + 4]
    subss xmm1, [rax + BIOME.pond_r]
    mulss xmm1, xmm0
    addss xmm1, [rax + BIOME.pond_r]
    minss xmm1, [rel c_pond_max_r]
    maxss xmm1, [rel c_pond_min_r]
    movss [r12 + POND.rx], xmm1
    mov eax, [LOCAL(FP_H2)]
    shr eax, 16
    and eax, 0xFF
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv65536]
    mulss xmm0, [rel c_16]
    mulss xmm0, [rel c_16]              ; (0..1)
    mulss xmm0, [rel c_aspect_span]
    addss xmm0, [rel c_aspect_lo]
    mulss xmm0, xmm1
    movss [r12 + POND.rz], xmm0
    mov eax, [LOCAL(FP_H2)]
    shr eax, 24
    and eax, 7
    lea rcx, [rel dirs]
    movss xmm0, [rcx + rax * 8]
    movss [r12 + POND.c], xmm0
    movss xmm0, [rcx + rax * 8 + 4]
    movss [r12 + POND.s], xmm0
    ; rim: e <= ((r + 1.5) / r)^2
    movss xmm0, [r12 + POND.rx]
    addss xmm0, [rel c_rim]
    divss xmm0, [r12 + POND.rx]
    mulss xmm0, xmm0
    movss [LOCAL(FP_RIMSQ)], xmm0
    ; pass 1: lowest ground on the rim, highest inside
    mov dword [LOCAL(FP_MIN)], 0x7FFFFFFF
    mov dword [LOCAL(FP_MAX)], 0x80000000
    mov rsi, r12
    mov r13d, -8                        ; dz
.p1_z:
    mov r14d, -8                        ; dx
.p1_x:
    mov ecx, [LOCAL(FP_X)]
    add ecx, r14d
    mov edx, [LOCAL(FP_Z)]
    add edx, r13d
    lea eax, [ecx + HB]
    cmp eax, HM - 1
    ja .p1_next
    lea eax, [edx + HB]
    cmp eax, HM - 1
    ja .p1_next
    mov r15d, ecx
    mov edi, edx
    call ellipse
    comiss xmm0, [LOCAL(FP_RIMSQ)]
    ja .p1_next
    HM_INDEX r15d, edi
    mov rcx, [rbx + FCTX.heights]
    mov eax, [rcx + rax * 4]
    comiss xmm0, [rel c_one]
    jbe .p1_inside
    cmp eax, [LOCAL(FP_MIN)]
    jge .p1_next
    mov [LOCAL(FP_MIN)], eax
    jmp .p1_next
.p1_inside:
    cmp eax, [LOCAL(FP_MAX)]
    jle .p1_next
    mov [LOCAL(FP_MAX)], eax
.p1_next:
    inc r14d
    cmp r14d, 8
    jle .p1_x
    inc r13d
    cmp r13d, 8
    jle .p1_z
    ; too steep for a pond?
    mov eax, [LOCAL(FP_MAX)]
    sub eax, [LOCAL(FP_MIN)]
    mov rcx, [LOCAL(FP_B)]
    cmp eax, [rcx + BIOME.pond_slope]
    jg .next_cell
    mov eax, [LOCAL(FP_MIN)]
    dec eax                             ; water level: the lowest rim top
    cmp eax, [rel g_sea_level]
    jl .next_cell                       ; (at sea level next to the sea is fine)
    mov [LOCAL(FP_W)], eax
    ; pass 2: dig and set the water level inside the ellipse
    mov r13d, -8
.p2_z:
    mov r14d, -8
.p2_x:
    mov ecx, [LOCAL(FP_X)]
    add ecx, r14d
    mov edx, [LOCAL(FP_Z)]
    add edx, r13d
    lea eax, [ecx + HB]
    cmp eax, HM - 1
    ja .p2_next
    lea eax, [edx + HB]
    cmp eax, HM - 1
    ja .p2_next
    mov r15d, ecx
    mov edi, edx
    call ellipse
    comiss xmm0, [rel c_one]
    ja .p2_next
    ; depth = 1 + (1 - e) * pond_depth
    movss xmm1, [rel c_one]
    subss xmm1, xmm0
    mov rax, [LOCAL(FP_B)]
    cvtsi2ss xmm2, dword [rax + BIOME.pond_depth]
    mulss xmm1, xmm2
    cvttss2si ecx, xmm1
    inc ecx
    mov edx, [LOCAL(FP_W)]
    inc edx
    sub edx, ecx                        ; pond floor (first water block)
    HM_INDEX r15d, edi
    mov rcx, [rbx + FCTX.heights]
    cmp edx, [rcx + rax * 4]
    jge .p2_level
    mov [rcx + rax * 4], edx
.p2_level:
    mov rcx, [rbx + FCTX.pond]
    movsx edx, word [rcx + rax * 2]
    mov r8d, [LOCAL(FP_W)]
    cmp edx, POND_NONE
    je .p2_set
    cmp edx, r8d
    jle .p2_next                        ; (overlapping ponds: the lower level)
.p2_set:
    mov [rcx + rax * 2], r8w
.p2_next:
    inc r14d
    cmp r14d, 8
    jle .p2_x
    inc r13d
    cmp r13d, 8
    jle .p2_z
    ; remember it (trees keep away from it and its rim)
    mov eax, [rbx + FCTX.npond]
    cmp eax, MAX_PONDS
    jae .next_cell
    imul rdi, rax, POND_size
    lea rdi, [rbx + FCTX.ponds + rdi]
    movups xmm0, [r12]
    movups [rdi], xmm0
    mov rax, [r12 + 16]
    mov [rdi + 16], rax
    ; store the rim radii for the exclusion test
    movss xmm0, [rdi + POND.rx]
    addss xmm0, [rel c_rim]
    movss [rdi + POND.rx], xmm0
    movss xmm0, [rdi + POND.rz]
    addss xmm0, [rel c_rim]
    movss [rdi + POND.rz], xmm0
    inc dword [rbx + FCTX.npond]
.next_cell:
    inc dword [LOCAL(FP_CX)]
    mov eax, [LOCAL(FP_CX)]
    cmp eax, [LOCAL(FP_CX1)]
    jle .cell_x
    inc dword [LOCAL(FP_CZ)]
    mov eax, [LOCAL(FP_CZ)]
    cmp eax, [LOCAL(FP_CZ1)]
    jle .cell_z
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; pick_weighted — index into a weighted list.
;   in:  rcx = list (count, ids[8], weights[8]), xmm0 = 0..1
;   out: eax = id, or -1 if the list is empty
;   clobbers: rax, rdx, r8, xmm0-xmm2
; -----------------------------------------------------------------------------
pick_weighted:
    mov edx, [rcx]
    test edx, edx
    jz .none
    xorps xmm1, xmm1                    ; total weight
    xor r8d, r8d
.sum:
    addss xmm1, [rcx + 4 + BIOME_TREES * 4 + r8 * 4]
    inc r8d
    cmp r8d, edx
    jb .sum
    mulss xmm0, xmm1                    ; target
    xorps xmm2, xmm2
    xor r8d, r8d
.find:
    addss xmm2, [rcx + 4 + BIOME_TREES * 4 + r8 * 4]
    comiss xmm0, xmm2
    jb .found
    inc r8d
    cmp r8d, edx
    jb .find
    dec r8d
.found:
    mov eax, [rcx + 4 + r8 * 4]
    ret
.none:
    mov eax, -1
    ret

; -----------------------------------------------------------------------------
; flora_prepare — list every tree and bush whose trunk is within TREE_REACH
; blocks of the chunk, in world order (so neighbours place them alike).
;   in:  rcx = FCTX*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define FR_CX       0
%define FR_CZ       4
%define FR_CX0      8
%define FR_CX1      12
%define FR_CZ1      16
%define FR_X        20
%define FR_Z        24
%define FR_B        32                  ; BIOME*
%define FR_D        40
%define FR_H        44
%define FR_KIND     48                  ; 0 tree, 1 bush
%define FR_LOCALS   64
PROC flora_prepare, FR_LOCALS, rbx, rsi, rdi, r12, r13, r14, r15
    mov rbx, rcx
    mov dword [rbx + FCTX.ncand], 0
    mov dword [rbx + FCTX.top], -100000
    lea rdi, [rbx + FCTX.litter]
    xor eax, eax
    mov ecx, 1024 / 4
    rep stosq
    mov eax, [rbx + FCTX.cx]
    shl eax, 5
    sub eax, TREE_REACH
    sar eax, TREE_CELL_SHIFT
    mov [LOCAL(FR_CX0)], eax
    mov eax, [rbx + FCTX.cx]
    shl eax, 5
    add eax, 31 + TREE_REACH
    sar eax, TREE_CELL_SHIFT
    mov [LOCAL(FR_CX1)], eax
    mov eax, [rbx + FCTX.cz]
    shl eax, 5
    sub eax, TREE_REACH
    sar eax, TREE_CELL_SHIFT
    mov [LOCAL(FR_CZ)], eax
    mov eax, [rbx + FCTX.cz]
    shl eax, 5
    add eax, 31 + TREE_REACH
    sar eax, TREE_CELL_SHIFT
    mov [LOCAL(FR_CZ1)], eax
.cz:
    mov eax, [LOCAL(FR_CX0)]
    mov [LOCAL(FR_CX)], eax
.cx:
    mov dword [LOCAL(FR_KIND)], 0
.kind:
    mov ecx, [LOCAL(FR_CX)]
    mov edx, [LOCAL(FR_CZ)]
    mov r8d, 0x5452                     ; "TR"
    add r8d, [LOCAL(FR_KIND)]
    xor r9d, r9d
    call hash4
    mov [LOCAL(FR_H)], eax
    ; trunk position in the cell
    mov ecx, eax
    and ecx, 3
    mov edx, [LOCAL(FR_CX)]
    shl edx, TREE_CELL_SHIFT
    add ecx, edx
    mov edx, [rbx + FCTX.cx]
    shl edx, 5
    sub ecx, edx
    mov [LOCAL(FR_X)], ecx
    mov ecx, eax
    shr ecx, 2
    and ecx, 3
    mov edx, [LOCAL(FR_CZ)]
    shl edx, TREE_CELL_SHIFT
    add ecx, edx
    mov edx, [rbx + FCTX.cz]
    shl edx, 5
    sub ecx, edx
    mov [LOCAL(FR_Z)], ecx
    ; within reach of the chunk?
    mov eax, [LOCAL(FR_X)]
    add eax, TREE_REACH
    cmp eax, 31 + 2 * TREE_REACH
    ja .next_kind
    mov eax, [LOCAL(FR_Z)]
    add eax, TREE_REACH
    cmp eax, 31 + 2 * TREE_REACH
    ja .next_kind
    ; biome, density -> chance per cell (16 blocks)
    mov rcx, [rbx + FCTX.bmap]
    mov edx, [LOCAL(FR_X)]
    mov r8d, [LOCAL(FR_Z)]
    call bmap_col
    test eax, eax
    jz .next_kind
    movss [LOCAL(FR_D)], xmm0
    imul rax, rax, BIOME_size
    lea rcx, [rel g_biomes]
    add rax, rcx
    mov [LOCAL(FR_B)], rax
    movss xmm1, [rax + BIOME.tree_dens]
    cmp dword [LOCAL(FR_KIND)], 0
    je .dens
    movss xmm1, [rax + BIOME.bush_dens]
.dens:
    mulss xmm1, [rel c_16]
    mulss xmm1, [LOCAL(FR_D)]
    mov eax, [LOCAL(FR_H)]
    shr eax, 8
    FRAC16 ax
    comiss xmm0, xmm1
    jae .next_kind
    ; ground: flat, inland, dry, outside ponds
    mov ecx, [LOCAL(FR_X)]
    mov edx, [LOCAL(FR_Z)]
    HM_INDEX ecx, edx
    mov rcx, [rbx + FCTX.heights]
    mov r12d, [rcx + rax * 4]           ; H
    lea edx, [r12d - 1]
    cmp edx, [rel g_beach_high]
    jle .next_kind
    mov rdx, [rbx + FCTX.pond]
    cmp word [rdx + rax * 2], POND_NONE
    jne .next_kind
%macro FLAT_NB 1
    mov edx, [rcx + rax * 4 + (%1) * 4]
    sub edx, r12d
    add edx, 1
    cmp edx, 2
    ja .next_kind                       ; |neighbour - H| > 1
%endmacro
    FLAT_NB 1
    FLAT_NB -1
    FLAT_NB HM
    FLAT_NB -HM
    xor r13d, r13d
.pond_check:
    cmp r13d, [rbx + FCTX.npond]
    jae .ground_ok
    imul rsi, r13, POND_size
    lea rsi, [rbx + FCTX.ponds + rsi]
    mov ecx, [LOCAL(FR_X)]
    mov edx, [LOCAL(FR_Z)]
    call ellipse
    comiss xmm0, [rel c_keep_out]
    jbe .next_kind                      ; (rim radii: crowns stay off the water)
    inc r13d
    jmp .pond_check
.ground_ok:
    ; trees keep out of clearings
    cmp dword [LOCAL(FR_KIND)], 0
    jne .not_clearing
    mov ecx, [rbx + FCTX.cx]
    shl ecx, 5
    add ecx, [LOCAL(FR_X)]
    mov edx, [rbx + FCTX.cz]
    shl edx, 5
    add edx, [LOCAL(FR_Z)]
    mov r8, [LOCAL(FR_B)]
    call in_clearing
    test eax, eax
    jnz .next_kind
.not_clearing:
    ; which tree (weighted list)
    mov ecx, [LOCAL(FR_CX)]
    mov edx, [LOCAL(FR_CZ)]
    mov r8d, 0x5344                     ; "SD"
    add r8d, [LOCAL(FR_KIND)]
    xor r9d, r9d
    call hash4
    mov r14d, eax                       ; seed
    FRAC16 ax
    mov rcx, [LOCAL(FR_B)]
    add rcx, BIOME.ntrees
    cmp dword [LOCAL(FR_KIND)], 0
    je .pick
    mov rcx, [LOCAL(FR_B)]
    add rcx, BIOME.nbushes
.pick:
    call pick_weighted
    cmp eax, -1
    je .next_kind
    mov r15d, eax                       ; tree
    mov eax, [rbx + FCTX.ncand]
    cmp eax, MAX_CANDS
    jae .next_kind
    imul rdi, rax, CAND_size
    lea rdi, [rbx + FCTX.cand + rdi]
    mov eax, [LOCAL(FR_X)]
    mov [rdi + CAND.x], eax
    mov eax, [LOCAL(FR_Z)]
    mov [rdi + CAND.z], eax
    mov [rdi + CAND.y], r12d
    mov [rdi + CAND.tree], r15d
    mov [rdi + CAND.seed], r14d
    ; highest block: trunk + crown
    imul rax, r15, TREE_size
    lea rcx, [rel g_trees]
    add rax, rcx
    cvttss2si ecx, [rax + TREE.radius + 4]
    add ecx, [rax + TREE.height + 4]
    lea ecx, [r12d + ecx + 8]           ; (forks, pads and tufts above the trunk)
    mov [rdi + CAND.ytop], ecx
    cmp ecx, [rbx + FCTX.top]
    jle .counted
    mov [rbx + FCTX.top], ecx
.counted:
    inc dword [rbx + FCTX.ncand]
    ; leaf litter around the trunks of the tree layer
    cmp dword [LOCAL(FR_KIND)], 0
    jne .next_kind
    mov rsi, [LOCAL(FR_B)]
    cmp dword [rsi + BIOME.litter], 0
    je .next_kind
    mov r13d, [rsi + BIOME.litter_r]
    neg r13d                            ; dz
.lit_z:
    mov r12d, [rsi + BIOME.litter_r]
    neg r12d                            ; dx
.lit_x:
    mov eax, r12d
    imul eax, eax
    mov ecx, r13d
    imul ecx, ecx
    add eax, ecx
    mov ecx, [rsi + BIOME.litter_r]
    imul ecx, ecx
    inc ecx
    cmp eax, ecx
    jg .lit_next
    mov r14d, [LOCAL(FR_X)]
    add r14d, r12d
    cmp r14d, 31
    ja .lit_next
    mov r15d, [LOCAL(FR_Z)]
    add r15d, r13d
    cmp r15d, 31
    ja .lit_next
    mov ecx, [rbx + FCTX.cx]
    shl ecx, 5
    add ecx, r14d
    mov edx, [rbx + FCTX.cz]
    shl edx, 5
    add edx, r15d
    mov r8d, 0x4C49                     ; "LI"
    xor r9d, r9d
    call hash4
    FRAC16 ax
    comiss xmm0, [rsi + BIOME.litter_ch]
    jae .lit_next
    mov eax, r15d
    shl eax, 5
    add eax, r14d
    mov ecx, [rsi + BIOME.litter]
    mov [rbx + FCTX.litter + rax * 2], cx
.lit_next:
    inc r12d
    cmp r12d, [rsi + BIOME.litter_r]
    jle .lit_x
    inc r13d
    cmp r13d, [rsi + BIOME.litter_r]
    jle .lit_z
.next_kind:
    inc dword [LOCAL(FR_KIND)]
    cmp dword [LOCAL(FR_KIND)], 2
    jb .kind
    inc dword [LOCAL(FR_CX)]
    mov eax, [LOCAL(FR_CX)]
    cmp eax, [LOCAL(FR_CX1)]
    jle .cx
    inc dword [LOCAL(FR_CZ)]
    mov eax, [LOCAL(FR_CZ)]
    cmp eax, [LOCAL(FR_CZ1)]
    jle .cz
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; in_clearing — is a world column inside a clearing of the biome? (one
; candidate per 160 x 160 cell, centre inside the cell)
;   in:  ecx = world x, edx = world z, r8 = BIOME*
;   out: eax = 1 inside
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define IC_X        0
%define IC_Z        4
%define IC_H        8
%define IC_OX       12                  ; cell origin
%define IC_OZ       16
%define IC_LOCALS   32
PROC in_clearing, IC_LOCALS, rbx
    mov rbx, r8
    xorps xmm0, xmm0
    comiss xmm0, [rbx + BIOME.clear_ch]
    jae .no
    mov [LOCAL(IC_X)], ecx
    mov [LOCAL(IC_Z)], edx
    mov eax, ecx
    mov ecx, 160
    call floordiv
    mov r9d, eax                        ; cell x
    mov eax, [LOCAL(IC_Z)]
    mov ecx, 160
    call floordiv
    mov edx, eax                        ; cell z
    imul eax, r9d, 160
    mov [LOCAL(IC_OX)], eax
    imul eax, edx, 160
    mov [LOCAL(IC_OZ)], eax
    mov ecx, r9d
    mov r8d, 0x434C                     ; "CL"
    xor r9d, r9d
    call hash4
    mov [LOCAL(IC_H)], eax
    FRAC16 ax
    comiss xmm0, [rbx + BIOME.clear_ch]
    jae .no
    ; centre 24 .. 136 inside the cell
    mov eax, [LOCAL(IC_H)]
    shr eax, 16
    and eax, 0xFF
    imul eax, eax, 112
    shr eax, 8
    add eax, 24
    add eax, [LOCAL(IC_OX)]
    mov ecx, [LOCAL(IC_X)]
    sub ecx, eax
    mov eax, [LOCAL(IC_H)]
    shr eax, 24
    imul eax, eax, 112
    shr eax, 8
    add eax, 24
    add eax, [LOCAL(IC_OZ)]
    mov edx, [LOCAL(IC_Z)]
    sub edx, eax
    imul ecx, ecx
    imul edx, edx
    add ecx, edx
    cvtsi2ss xmm3, ecx                  ; distance^2
    mov eax, [LOCAL(IC_H)]
    shr eax, 8
    and eax, 0xFF
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv255]
    movss xmm1, [rbx + BIOME.clear_r + 4]
    subss xmm1, [rbx + BIOME.clear_r]
    mulss xmm1, xmm0
    addss xmm1, [rbx + BIOME.clear_r]   ; radius
    mulss xmm1, xmm1
    comiss xmm3, xmm1
    ja .no
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; decide_plant — the plant at a world column of a biome.
;   in:  ecx = world x, edx = world z, r8 = BIOME*, xmm0 = density
;   out: eax = block id (0 = none)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define DP_X        0
%define DP_Z        4
%define DP_D        8
%define DP_HM       12
%define DP_HM2      16
%define DP_T        20
%define DP_SH       28                  ; meadow cell shift
%define DP_LOCALS   32
PROC decide_plant, DP_LOCALS, rbx, rsi
    mov [LOCAL(DP_X)], ecx
    mov [LOCAL(DP_Z)], edx
    movss [LOCAL(DP_D)], xmm0
    mov rbx, r8
    ; ---- mushroom rings (one candidate per 128 x 128 cell) ----
    cmp dword [rbx + BIOME.nrings], 0
    je .no_ring
    mov ecx, [LOCAL(DP_X)]
    sar ecx, 7
    mov edx, [LOCAL(DP_Z)]
    sar edx, 7
    mov r8d, 0x5249                     ; "RI"
    xor r9d, r9d
    call hash4
    mov [LOCAL(DP_HM)], eax
    FRAC16 ax
    comiss xmm0, [rbx + BIOME.ring_ch]
    jae .no_ring
    mov eax, [LOCAL(DP_HM)]
    shr eax, 16
    and eax, 0x7F
    add eax, ((128 - 0x7F) / 2)         ; (centre inside the cell)
    mov ecx, [LOCAL(DP_X)]
    and ecx, 127
    sub ecx, eax
    mov eax, [LOCAL(DP_HM)]
    shr eax, 23
    and eax, 0x7F
    mov edx, [LOCAL(DP_Z)]
    and edx, 127
    sub edx, eax
    imul ecx, ecx
    imul edx, edx
    add ecx, edx
    cvtsi2ss xmm3, ecx
    sqrtss xmm3, xmm3                   ; distance
    mov eax, [LOCAL(DP_HM)]
    shr eax, 8
    and eax, 0xFF
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv255]
    movss xmm1, [rbx + BIOME.ring_r + 4]
    subss xmm1, [rbx + BIOME.ring_r]
    mulss xmm1, xmm0
    addss xmm1, [rbx + BIOME.ring_r]    ; radius
    subss xmm3, xmm1
    andps xmm3, [rel c_abs]
    comiss xmm3, [rel c_ring_w]
    ja .no_ring
    mov eax, [LOCAL(DP_X)]
    imul eax, eax, 0x9E3779B1
    add eax, [LOCAL(DP_Z)]
    shr eax, 20
    xor edx, edx
    div dword [rbx + BIOME.nrings]
    mov eax, [rbx + BIOME.ring + rdx * 4]
    RETURN
.no_ring:
    ; ---- clearings: scattered flowers ----
    xorps xmm0, xmm0
    comiss xmm0, [rbx + BIOME.clear_ch]
    jae .no_clearing
    cmp dword [rbx + BIOME.nflowers], 0
    je .no_clearing
    mov ecx, [LOCAL(DP_X)]
    mov edx, [LOCAL(DP_Z)]
    mov r8, rbx
    call in_clearing
    test eax, eax
    jz .no_clearing
    mov ecx, [LOCAL(DP_X)]
    mov edx, [LOCAL(DP_Z)]
    mov r8d, 0x4346                     ; "CF"
    xor r9d, r9d
    call hash4
    mov esi, eax
    FRAC16 ax
    comiss xmm0, [rbx + BIOME.clear_fl]
    jae .cover
    mov eax, esi
    shr eax, 16
    xor edx, edx
    div dword [rbx + BIOME.nflowers]
    mov eax, [rbx + BIOME.flower + rdx * 4]
    RETURN
.no_clearing:
    cmp dword [rbx + BIOME.nflowers], 0
    je .cover
    ; ---- meadow (one candidate per meadow_cell^2, default 512) ----
    xorps xmm0, xmm0
    comiss xmm0, [rbx + BIOME.meadow_ch]
    jae .clusters
    bsr eax, dword [rbx + BIOME.meadow_cell]
    mov [LOCAL(DP_SH)], eax
    mov eax, [LOCAL(DP_SH)]
    mov edx, [LOCAL(DP_Z)]
    mov ecx, eax
    sar edx, cl
    mov ecx, [LOCAL(DP_X)]
    xchg eax, ecx
    sar eax, cl
    mov ecx, eax
    mov r8d, 0x4D45                     ; "ME"
    xor r9d, r9d
    call hash4
    mov [LOCAL(DP_HM)], eax
    FRAC16 ax
    comiss xmm0, [rbx + BIOME.meadow_ch]
    jae .clusters
    mov eax, [LOCAL(DP_SH)]
    mov edx, [LOCAL(DP_Z)]
    mov ecx, eax
    sar edx, cl
    mov ecx, [LOCAL(DP_X)]
    xchg eax, ecx
    sar eax, cl
    mov ecx, eax
    mov r8d, 0x4D5A                     ; "MZ"
    xor r9d, r9d
    call hash4
    mov [LOCAL(DP_HM2)], eax
    ; centre cell/8 .. 7 cell/8 inside the cell
    mov r8d, [rbx + BIOME.meadow_cell]
    mov eax, [LOCAL(DP_HM)]
    shr eax, 16
    and eax, 0xFF
    lea r9d, [r8d * 3]
    shr r9d, 2                          ; 3/4 cell
    imul eax, r9d
    shr eax, 8
    mov r9d, r8d
    shr r9d, 3
    add eax, r9d
    lea r10d, [r8d - 1]
    mov ecx, [LOCAL(DP_X)]
    and ecx, r10d
    sub ecx, eax                        ; dx
    mov eax, [LOCAL(DP_HM)]
    shr eax, 24
    lea r9d, [r8d * 3]
    shr r9d, 2
    imul eax, r9d
    shr eax, 8
    mov r9d, r8d
    shr r9d, 3
    add eax, r9d
    mov edx, [LOCAL(DP_Z)]
    and edx, r10d
    sub edx, eax                        ; dz
    imul ecx, ecx
    imul edx, edx
    add ecx, edx
    cvtsi2ss xmm3, ecx                  ; distance^2
    ; radius (ragged edge: x 0.8 .. 1.2 per 4 x 4 blocks)
    FRAC16 word [LOCAL(DP_HM2)]
    movss xmm1, [rbx + BIOME.meadow_r + 4]
    subss xmm1, [rbx + BIOME.meadow_r]
    mulss xmm1, xmm0
    addss xmm1, [rbx + BIOME.meadow_r]
    movss [LOCAL(DP_T)], xmm1
    mov ecx, [LOCAL(DP_X)]
    sar ecx, 2
    mov edx, [LOCAL(DP_Z)]
    sar edx, 2
    mov r8d, 0x4D57                     ; "MW"
    xor r9d, r9d
    movss [LOCAL(DP_T) + 4], xmm3
    call hash4
    FRAC16 ax
    mulss xmm0, [rel c_wobble_span]
    addss xmm0, [rel c_wobble_lo]
    mulss xmm0, [LOCAL(DP_T)]
    mulss xmm0, xmm0                    ; radius^2
    comiss xmm0, [LOCAL(DP_T) + 4]
    jbe .clusters                       ; outside
    ; inside: flowers at meadow density
    mov ecx, [LOCAL(DP_X)]
    mov edx, [LOCAL(DP_Z)]
    mov r8d, 0x4D42                     ; "MB"
    xor r9d, r9d
    call hash4
    mov esi, eax
    FRAC16 ax
    movss xmm1, [rbx + BIOME.meadow_dens]
    mulss xmm1, [LOCAL(DP_D)]
    comiss xmm0, xmm1
    jae .cover
    ; one colour, or mixed
    FRAC16 word [LOCAL(DP_HM2) + 2]
    comiss xmm0, [rbx + BIOME.meadow_mixed]
    jb .mixed
    mov eax, [LOCAL(DP_HM)]
    shr eax, 8
    and eax, 0xFF
    jmp .flower_idx
.mixed:
    mov eax, esi
    shr eax, 16
.flower_idx:
    xor edx, edx
    cmp dword [rbx + BIOME.nmflowers], 0
    jne .meadow_list
    div dword [rbx + BIOME.nflowers]
    mov eax, [rbx + BIOME.flower + rdx * 4]
    RETURN
.meadow_list:
    div dword [rbx + BIOME.nmflowers]
    mov eax, [rbx + BIOME.mflower + rdx * 4]
    RETURN

.clusters:
    ; ---- small same-colour flower clusters (8 x 8 cells) ----
    mov ecx, [LOCAL(DP_X)]
    sar ecx, 3
    mov edx, [LOCAL(DP_Z)]
    sar edx, 3
    mov r8d, 0x464C                     ; "FL"
    xor r9d, r9d
    call hash4
    mov esi, eax
    FRAC16 ax
    movss xmm1, [rbx + BIOME.flower_ch]
    mulss xmm1, [rel c_flower_cl]
    mulss xmm1, [LOCAL(DP_D)]
    comiss xmm0, xmm1
    jae .cover
    mov eax, esi
    shr eax, 16
    and eax, 3
    mov ecx, [LOCAL(DP_X)]
    and ecx, 7
    sub ecx, eax
    sub ecx, 2                          ; dx from the cluster centre
    mov eax, esi
    shr eax, 18
    and eax, 3
    mov edx, [LOCAL(DP_Z)]
    and edx, 7
    sub edx, eax
    sub edx, 2
    imul ecx, ecx
    imul edx, edx
    add ecx, edx
    cmp ecx, 3
    ja .cover
    mov ecx, [LOCAL(DP_X)]
    mov edx, [LOCAL(DP_Z)]
    mov r8d, 0x4642                     ; "FB"
    xor r9d, r9d
    call hash4
    FRAC16 ax
    comiss xmm0, [rel c_cl_fill]
    jae .cover
    mov eax, esi
    shr eax, 24
    xor edx, edx
    div dword [rbx + BIOME.nflowers]
    mov eax, [rbx + BIOME.flower + rdx * 4]
    RETURN

.cover:
    ; ---- ground cover by chance ----
    mov ecx, [LOCAL(DP_X)]
    mov edx, [LOCAL(DP_Z)]
    mov r8d, 0x4752                     ; "GR"
    xor r9d, r9d
    call hash4
    FRAC16 ax
    xorps xmm2, xmm2                    ; cumulative chance
    xor ecx, ecx
.pl:
    cmp ecx, [rbx + BIOME.nplants]
    jae .none
    movss xmm1, [rbx + BIOME.plant_ch + rcx * 4]
    mulss xmm1, [LOCAL(DP_D)]
    addss xmm2, xmm1
    comiss xmm0, xmm2
    jb .plant
    inc ecx
    jmp .pl
.plant:
    mov eax, [rbx + BIOME.plant + rcx * 4]
    RETURN
.none:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; blob — a leaf clump: ellipsoid of radius r (vertical scale down / up),
; edge leaves dropped by chance.
;   in:  rbx = FCTX*, rsi = TREE*, edi = rng state (advanced),
;        ecx = cx, edx = cy, r8d = cz, xmm0 = r, xmm1 = down, xmm2 = up
;   clobbers: volatile registers (keeps rbx, rsi, rdi)
; -----------------------------------------------------------------------------
%define BL_CX       0
%define BL_CY       4
%define BL_CZ       8
%define BL_R        12
%define BL_DN       16
%define BL_UP       20
%define BL_RI       24
%define BL_E        28
%define BL_LOCALS   32
PROC blob, BL_LOCALS, r12, r13, r14
    mov [LOCAL(BL_CX)], ecx
    mov [LOCAL(BL_CY)], edx
    mov [LOCAL(BL_CZ)], r8d
    movss [LOCAL(BL_R)], xmm0
    mulss xmm1, xmm0
    movss [LOCAL(BL_DN)], xmm1          ; vertical radius below
    mulss xmm2, xmm0
    movss [LOCAL(BL_UP)], xmm2          ; above
    addss xmm0, [rel c_half]
    cvttss2si eax, xmm0
    mov [LOCAL(BL_RI)], eax
    mov r12d, eax
    neg r12d                            ; dy
.dy:
    mov r13d, [LOCAL(BL_RI)]
    neg r13d                            ; dz
.dz:
    mov r14d, [LOCAL(BL_RI)]
    neg r14d                            ; dx
.dx:
    ; e = (dx^2 + dz^2) / r^2 + (dy / vr)^2
    mov eax, r14d
    imul eax, eax
    mov ecx, r13d
    imul ecx, ecx
    add eax, ecx
    cvtsi2ss xmm0, eax
    movss xmm1, [LOCAL(BL_R)]
    mulss xmm1, xmm1
    divss xmm0, xmm1
    cvtsi2ss xmm2, r12d
    movss xmm3, [LOCAL(BL_UP)]
    test r12d, r12d
    jns .vr
    movss xmm3, [LOCAL(BL_DN)]
.vr:
    divss xmm2, xmm3
    mulss xmm2, xmm2
    addss xmm0, xmm2
    comiss xmm0, [rel c_one]
    ja .next
    comiss xmm0, [rel c_edge]
    jbe .leaf
    call rng
    comiss xmm0, [rsi + TREE.gaps]
    jb .next
.leaf:
    mov ecx, [LOCAL(BL_CX)]
    add ecx, r14d
    mov edx, [LOCAL(BL_CY)]
    add edx, r12d
    mov r8d, [LOCAL(BL_CZ)]
    add r8d, r13d
    mov r9d, [rsi + TREE.leaves]
    mov r10d, PUT_LEAVES
    call put_block
.next:
    inc r14d
    cmp r14d, [LOCAL(BL_RI)]
    jle .dx
    inc r13d
    cmp r13d, [LOCAL(BL_RI)]
    jle .dz
    inc r12d
    cmp r12d, [LOCAL(BL_RI)]
    jle .dy
    RETURN
ENDPROC

; AXIS_LOG reg — turn log id `reg` (32-bit) into its lying state for the
; horizontal direction (xmm4 = dx, xmm5 = dz): 1 along X, 2 along Z, if the
; block has axis states.   clobbers: rax, xmm4, xmm5
%macro AXIS_LOG 1
    lea rax, [rel g_block_flags]
    add rax, r9                         ; (the id is always in r9)
    test byte [rax], BLOCKF_AXIS
    jz %%done
    andps xmm4, [rel c_abs]
    andps xmm5, [rel c_abs]
    inc %1
    comiss xmm4, xmm5
    jae %%done
    inc %1
%%done:
%endmacro

; rand_int — eax = lo + rng % (hi - lo + 1).  in: ecx = lo, edx = hi
;   clobbers: rax, rcx, rdx, r8, xmm0
rand_int:
    mov r8d, ecx
    sub edx, ecx
    inc edx
    mov ecx, edx
    imul edi, edi, 1664525
    add edi, 1013904223
    mov eax, edi
    shr eax, 8
    xor edx, edx
    div ecx
    lea eax, [r8 + rdx]
    ret

; -----------------------------------------------------------------------------
; gen_tree — grow one candidate, placing the blocks inside the section.
;   in:  rcx = FCTX*, rdx = CAND*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define GT_X        0
%define GT_Y        4
%define GT_Z        8
%define GT_H        12                  ; trunk height
%define GT_R        16                  ; crown radius (f32)
%define GT_N        20                  ; branches left
%define GT_BX       24                  ; branch position (f32 x, y, z)
%define GT_BY       28
%define GT_BZ       32
%define GT_DX       36                  ; branch direction
%define GT_DZ       40
%define GT_L        44                  ; steps left
%define GT_LOCALS   48
PROC gen_tree, GT_LOCALS, rbx, rsi, rdi, r12
    mov rbx, rcx
    mov eax, [rdx + CAND.x]
    mov [LOCAL(GT_X)], eax
    mov eax, [rdx + CAND.y]
    mov [LOCAL(GT_Y)], eax
    mov eax, [rdx + CAND.z]
    mov [LOCAL(GT_Z)], eax
    mov edi, [rdx + CAND.seed]
    mov eax, [rdx + CAND.tree]
    imul rsi, rax, TREE_size
    lea rax, [rel g_trees]
    add rsi, rax
    mov eax, [rsi + TREE.kind]
    cmp eax, TREE_GIANT
    jae .special
    ; trunk height, crown radius
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    mov [LOCAL(GT_H)], eax
    call rng
    movss xmm1, [rsi + TREE.radius + 4]
    subss xmm1, [rsi + TREE.radius]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.radius]
    movss [LOCAL(GT_R)], xmm1
    cmp dword [rsi + TREE.kind], TREE_BUSH
    je .bush
    ; ---- trunk ----
    xor r12d, r12d
.trunk:
    mov ecx, [LOCAL(GT_X)]
    mov edx, [LOCAL(GT_Y)]
    add edx, r12d
    mov r8d, [LOCAL(GT_Z)]
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
    inc r12d
    cmp r12d, [LOCAL(GT_H)]
    jb .trunk
    cmp dword [rsi + TREE.kind], TREE_BRANCHING
    jne .crown
    ; ---- branches: diagonal log runs ending in leaf clusters ----
    mov ecx, [rsi + TREE.branches]
    mov edx, [rsi + TREE.branches + 4]
    call rand_int
    mov [LOCAL(GT_N)], eax
.branch:
    cmp dword [LOCAL(GT_N)], 0
    jle .crown
    dec dword [LOCAL(GT_N)]
    ; start: 45 .. 75% up the trunk; direction one of 8
    call rng
    mulss xmm0, [rel c_branch_span]
    addss xmm0, [rel c_branch_lo]
    cvtsi2ss xmm1, dword [LOCAL(GT_H)]
    mulss xmm0, xmm1
    cvtsi2ss xmm1, dword [LOCAL(GT_Y)]
    addss xmm0, xmm1
    movss [LOCAL(GT_BY)], xmm0
    cvtsi2ss xmm0, dword [LOCAL(GT_X)]
    addss xmm0, [rel c_half]
    movss [LOCAL(GT_BX)], xmm0
    cvtsi2ss xmm0, dword [LOCAL(GT_Z)]
    addss xmm0, [rel c_half]
    movss [LOCAL(GT_BZ)], xmm0
    mov ecx, 0
    mov edx, 7
    call rand_int
    lea rcx, [rel dirs]
    movss xmm0, [rcx + rax * 8]
    movss [LOCAL(GT_DX)], xmm0
    movss xmm0, [rcx + rax * 8 + 4]
    movss [LOCAL(GT_DZ)], xmm0
    mov ecx, 3
    mov edx, 5
    call rand_int
    mov [LOCAL(GT_L)], eax
.step:
    movss xmm0, [LOCAL(GT_BX)]
    addss xmm0, [LOCAL(GT_DX)]
    movss [LOCAL(GT_BX)], xmm0
    movss xmm0, [LOCAL(GT_BZ)]
    addss xmm0, [LOCAL(GT_DZ)]
    movss [LOCAL(GT_BZ)], xmm0
    movss xmm0, [LOCAL(GT_BY)]
    addss xmm0, [rel c_branch_up]
    movss [LOCAL(GT_BY)], xmm0
    roundss xmm0, [LOCAL(GT_BX)], 9
    cvttss2si ecx, xmm0
    roundss xmm0, [LOCAL(GT_BY)], 9
    cvttss2si edx, xmm0
    roundss xmm0, [LOCAL(GT_BZ)], 9
    cvttss2si r8d, xmm0
    mov r9d, [rsi + TREE.log]
    movss xmm4, [LOCAL(GT_DX)]
    movss xmm5, [LOCAL(GT_DZ)]
    AXIS_LOG r9d
    mov r10d, PUT_LOG
    call put_block
    dec dword [LOCAL(GT_L)]
    jnz .step
    ; leaf cluster at the end
    roundss xmm0, [LOCAL(GT_BX)], 9
    cvttss2si ecx, xmm0
    roundss xmm0, [LOCAL(GT_BY)], 9
    cvttss2si edx, xmm0
    inc edx
    roundss xmm0, [LOCAL(GT_BZ)], 9
    cvttss2si r8d, xmm0
    movss xmm0, [LOCAL(GT_R)]
    mulss xmm0, [rel c_branch_r]
    movss xmm1, [rel c_down]
    movss xmm2, [rel c_up]
    call blob
    jmp .branch
.crown:
    ; ---- crown around the top of the trunk ----
    mov ecx, [LOCAL(GT_X)]
    mov edx, [LOCAL(GT_Y)]
    add edx, [LOCAL(GT_H)]
    dec edx
    mov r8d, [LOCAL(GT_Z)]
    movss xmm0, [LOCAL(GT_R)]
    movss xmm1, [rel c_down]
    movss xmm2, [rel c_up]
    call blob
    RETURN
.bush:
    mov ecx, [LOCAL(GT_X)]
    mov edx, [LOCAL(GT_Y)]
    mov r8d, [LOCAL(GT_Z)]
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
    mov ecx, [LOCAL(GT_X)]
    mov edx, [LOCAL(GT_Y)]
    mov r8d, [LOCAL(GT_Z)]
    movss xmm0, [LOCAL(GT_R)]
    movss xmm1, [rel c_bush_down]
    movss xmm2, [rel c_bush_up]
    call blob
    RETURN
.special:
    ; giants, fallen logs, stumps, cacti, rocks, arches, fossils, palms:
    ; their own generators
    mov ecx, [LOCAL(GT_X)]
    mov edx, [LOCAL(GT_Y)]
    mov r8d, [LOCAL(GT_Z)]
    mov r9, rsi
    mov eax, [rsi + TREE.kind]
    sub eax, TREE_GIANT
    lea r10, [rel special_gen]
    call [r10 + rax * 8]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gen_stump — a short upright log.   (rbx = FCTX*, edi = rng state)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gen_stump, 16, rsi, r12, r13
    mov rsi, r9
    mov [LOCAL(0)], ecx
    mov r12d, edx
    mov [LOCAL(4)], r8d
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    lea r13d, [r12d + eax]
.s:
    cmp r12d, r13d
    jge .done
    mov ecx, [LOCAL(0)]
    mov edx, r12d
    mov r8d, [LOCAL(4)]
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
    inc r12d
    jmp .s
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gen_fallen — a log lying on the ground along X or Z, as long as the ground
; stays level.   (rbx = FCTX*, edi = rng state)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define GF_X        0
%define GF_Y        4
%define GF_Z        8
%define GF_DX       12
%define GF_DZ       16
%define GF_LOG      20
%define GF_LOCALS   32
PROC gen_fallen, GF_LOCALS, rsi, r12, r13
    mov rsi, r9
    mov [LOCAL(GF_X)], ecx
    mov [LOCAL(GF_Y)], edx
    mov [LOCAL(GF_Z)], r8d
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    mov r12d, eax                       ; length
    ; direction: +-X or +-Z
    mov eax, edi
    shr eax, 29
    mov dword [LOCAL(GF_DX)], 0
    mov dword [LOCAL(GF_DZ)], 0
    mov ecx, 1
    test eax, 4
    jz .pos
    neg ecx
.pos:
    mov r9d, [rsi + TREE.log]
    lea rdx, [rel g_block_flags]
    test eax, 1
    jz .along_z
    mov [LOCAL(GF_DX)], ecx
    test byte [rdx + r9], BLOCKF_AXIS
    jz .have_log
    inc r9d                             ; lying along X
    jmp .have_log
.along_z:
    mov [LOCAL(GF_DZ)], ecx
    test byte [rdx + r9], BLOCKF_AXIS
    jz .have_log
    add r9d, 2                          ; lying along Z
.have_log:
    mov [LOCAL(GF_LOG)], r9d
    xor r13d, r13d                      ; step
.l:
    cmp r13d, r12d
    jge .done
    ; this column: inside the heightmap and level with the start?
    mov ecx, [LOCAL(GF_DX)]
    imul ecx, r13d
    add ecx, [LOCAL(GF_X)]
    mov edx, [LOCAL(GF_DZ)]
    imul edx, r13d
    add edx, [LOCAL(GF_Z)]
    lea eax, [ecx + HB]
    cmp eax, HM - 1
    ja .done
    lea eax, [edx + HB]
    cmp eax, HM - 1
    ja .done
    HM_INDEX ecx, edx
    mov r8, [rbx + FCTX.heights]
    mov eax, [r8 + rax * 4]
    cmp eax, [LOCAL(GF_Y)]
    jne .done
    mov r8d, edx
    mov edx, [LOCAL(GF_Y)]
    mov r9d, [LOCAL(GF_LOG)]
    mov r10d, PUT_LOG
    call put_block
    inc r13d
    jmp .l
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gen_giant — an old-growth giant (design/biomes/old_growth_forest.md): a
; trunk of discs that flares at the ground and tapers from base_radius to
; 3 x 3 at the crown base (55% up) and thinner above, arching roots, heavy
; branches rising outwards with leaf clusters, and a crown on top.
;   (rbx = FCTX*, edi = rng state)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define GG_X        0
%define GG_Y        4
%define GG_Z        8
%define GG_H        12                  ; height
%define GG_R0       16                  ; f32 base radius
%define GG_R        20                  ; f32 radius of this disc
%define GG_RI       24
%define GG_YI       28                  ; disc y (relative)
%define GG_N        32                  ; roots / branches left
%define GG_I        36
%define GG_CNT      40
%define GG_DX       44                  ; f32 direction
%define GG_DZ       48
%define GG_L        52                  ; steps
%define GG_K        56
%define GG_PX       60                  ; f32 position
%define GG_PY       64
%define GG_PZ       68
%define GG_LOG      72
%define GG_LOCALS   80
PROC gen_giant, GG_LOCALS, rsi, r12, r13, r14
    mov rsi, r9
    mov [LOCAL(GG_X)], ecx
    mov [LOCAL(GG_Y)], edx
    mov [LOCAL(GG_Z)], r8d
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    mov [LOCAL(GG_H)], eax
    call rng
    movss xmm1, [rsi + TREE.base_r + 4]
    subss xmm1, [rsi + TREE.base_r]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.base_r]
    movss [LOCAL(GG_R0)], xmm1

    ; ---- trunk: discs from 3 below the ground to the top ----
    mov dword [LOCAL(GG_YI)], -3
.disc:
    mov eax, [LOCAL(GG_YI)]
    cmp eax, [LOCAL(GG_H)]
    jge .roots
    ; t = max(y, 0) / H
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    cvtsi2ss xmm0, eax
    cvtsi2ss xmm1, dword [LOCAL(GG_H)]
    divss xmm0, xmm1                    ; t
    comiss xmm0, [rel c_g_crown]
    jae .upper
    ; below the crown: 1.5 + (R0 - 1.5) * (1 - t / 0.55)^2
    divss xmm0, [rel c_g_crown]
    movss xmm1, [rel c_one]
    subss xmm1, xmm0
    mulss xmm1, xmm1
    movss xmm2, [LOCAL(GG_R0)]
    subss xmm2, [rel c_g_top_r]
    mulss xmm1, xmm2
    addss xmm1, [rel c_g_top_r]
    jmp .flare
.upper:
    ; above: 1.5 .. 0.8
    subss xmm0, [rel c_g_crown]
    divss xmm0, [rel c_g_upper]
    mulss xmm0, [rel c_g_taper]
    movss xmm1, [rel c_g_top_r]
    subss xmm1, xmm0
.flare:
    ; flare: + 0.4 per block below y 3
    mov eax, 3
    sub eax, [LOCAL(GG_YI)]
    jle .radius
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_g_flare]
    addss xmm1, xmm0
.radius:
    movss [LOCAL(GG_R)], xmm1
    addss xmm1, [rel c_half]
    cvttss2si eax, xmm1
    mov [LOCAL(GG_RI)], eax
    mov r12d, eax
    neg r12d                            ; dz
.dz:
    mov r13d, [LOCAL(GG_RI)]
    neg r13d                            ; dx
.dx:
    mov eax, r13d
    imul eax, eax
    mov ecx, r12d
    imul ecx, ecx
    add eax, ecx
    cvtsi2ss xmm0, eax
    movss xmm1, [LOCAL(GG_R)]
    mulss xmm1, xmm1
    addss xmm1, [rel c_g_disc]
    comiss xmm0, xmm1
    ja .dx_next
    mov ecx, [LOCAL(GG_X)]
    add ecx, r13d
    mov edx, [LOCAL(GG_Y)]
    add edx, [LOCAL(GG_YI)]
    mov r8d, [LOCAL(GG_Z)]
    add r8d, r12d
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
.dx_next:
    inc r13d
    cmp r13d, [LOCAL(GG_RI)]
    jle .dx
    inc r12d
    cmp r12d, [LOCAL(GG_RI)]
    jle .dz
    inc dword [LOCAL(GG_YI)]
    jmp .disc

    ; ---- roots: arching outwards and down from the base ----
.roots:
    mov ecx, [rsi + TREE.roots]
    mov edx, [rsi + TREE.roots + 4]
    call rand_int
    mov [LOCAL(GG_CNT)], eax
    mov dword [LOCAL(GG_I)], 0
.root:
    mov eax, [LOCAL(GG_I)]
    cmp eax, [LOCAL(GG_CNT)]
    jge .branches
    ; direction: evenly spread (16 steps) with a random offset
    imul eax, eax, 16
    xor edx, edx
    div dword [LOCAL(GG_CNT)]
    mov r12d, eax
    mov ecx, 0
    mov edx, 2
    call rand_int
    add eax, r12d
    and eax, 15
    lea rcx, [rel dirs16]
    movss xmm0, [rcx + rax * 8]
    movss [LOCAL(GG_DX)], xmm0
    movss xmm0, [rcx + rax * 8 + 4]
    movss [LOCAL(GG_DZ)], xmm0
    mov ecx, 5
    mov edx, 9
    call rand_int
    mov [LOCAL(GG_L)], eax
    mov r9d, [rsi + TREE.log]
    movss xmm4, [LOCAL(GG_DX)]
    movss xmm5, [LOCAL(GG_DZ)]
    AXIS_LOG r9d
    mov [LOCAL(GG_LOG)], r9d
    mov dword [LOCAL(GG_K)], 0
.root_step:
    mov eax, [LOCAL(GG_K)]
    cmp eax, [LOCAL(GG_L)]
    jge .root_next
    ; distance from the axis: base radius * 0.6 + k
    cvtsi2ss xmm2, eax
    movss xmm3, [LOCAL(GG_R0)]
    mulss xmm3, [rel c_g_root_in]
    addss xmm2, xmm3
    movss xmm0, [LOCAL(GG_DX)]
    mulss xmm0, xmm2
    cvtsi2ss xmm1, dword [LOCAL(GG_X)]
    addss xmm0, xmm1
    addss xmm0, [rel c_half]
    roundss xmm0, xmm0, 9
    cvttss2si ecx, xmm0
    mov [LOCAL(GG_PX)], ecx
    movss xmm0, [LOCAL(GG_DZ)]
    mulss xmm0, xmm2
    cvtsi2ss xmm1, dword [LOCAL(GG_Z)]
    addss xmm0, xmm1
    addss xmm0, [rel c_half]
    roundss xmm0, xmm0, 9
    cvttss2si r8d, xmm0
    mov [LOCAL(GG_PZ)], r8d
    ; height: 1 above the ground at the trunk, falling outwards
    cvtsi2ss xmm0, dword [LOCAL(GG_K)]
    mulss xmm0, [rel c_g_root_drop]
    cvttss2si eax, xmm0
    mov edx, [LOCAL(GG_Y)]
    inc edx
    sub edx, eax
    mov [LOCAL(GG_PY)], edx
    mov r9d, [LOCAL(GG_LOG)]
    mov r10d, PUT_LOG
    call put_block
    ; thick near the trunk: a second block below
    mov eax, [LOCAL(GG_K)]
    add eax, eax
    cmp eax, [LOCAL(GG_L)]
    jge .root_thin
    mov ecx, [LOCAL(GG_PX)]
    mov edx, [LOCAL(GG_PY)]
    dec edx
    mov r8d, [LOCAL(GG_PZ)]
    mov r9d, [LOCAL(GG_LOG)]
    mov r10d, PUT_LOG
    call put_block
.root_thin:
    inc dword [LOCAL(GG_K)]
    jmp .root_step
.root_next:
    inc dword [LOCAL(GG_I)]
    jmp .root

    ; ---- heavy branches from 55% up, each with a leaf cluster ----
.branches:
    mov ecx, [rsi + TREE.branches]
    mov edx, [rsi + TREE.branches + 4]
    call rand_int
    mov [LOCAL(GG_CNT)], eax
    mov dword [LOCAL(GG_I)], 0
.branch:
    mov eax, [LOCAL(GG_I)]
    cmp eax, [LOCAL(GG_CNT)]
    jge .crown
    imul eax, eax, 16
    xor edx, edx
    div dword [LOCAL(GG_CNT)]
    mov r12d, eax
    mov ecx, 0
    mov edx, 3
    call rand_int
    add eax, r12d
    and eax, 15
    lea rcx, [rel dirs16]
    movss xmm0, [rcx + rax * 8]
    movss [LOCAL(GG_DX)], xmm0
    movss xmm0, [rcx + rax * 8 + 4]
    movss [LOCAL(GG_DZ)], xmm0
    ; start height: 55 .. 88% up
    call rng
    mulss xmm0, [rel c_g_branch_span]
    addss xmm0, [rel c_g_branch_lo]
    cvtsi2ss xmm1, dword [LOCAL(GG_H)]
    mulss xmm0, xmm1
    cvtsi2ss xmm1, dword [LOCAL(GG_Y)]
    addss xmm0, xmm1
    movss [LOCAL(GG_PY)], xmm0
    cvtsi2ss xmm0, dword [LOCAL(GG_X)]
    addss xmm0, [rel c_half]
    movss [LOCAL(GG_PX)], xmm0
    cvtsi2ss xmm0, dword [LOCAL(GG_Z)]
    addss xmm0, [rel c_half]
    movss [LOCAL(GG_PZ)], xmm0
    ; length: H / 7 .. H / 5 (at most 12)
    mov eax, [LOCAL(GG_H)]
    xor edx, edx
    mov ecx, 7
    div ecx
    mov r12d, eax
    mov eax, [LOCAL(GG_H)]
    xor edx, edx
    mov ecx, 5
    div ecx
    mov edx, 12
    cmp eax, edx
    cmova eax, edx
    mov edx, eax
    mov ecx, r12d
    cmp ecx, edx
    cmova ecx, edx
    call rand_int
    mov [LOCAL(GG_L)], eax
    mov r9d, [rsi + TREE.log]
    movss xmm4, [LOCAL(GG_DX)]
    movss xmm5, [LOCAL(GG_DZ)]
    AXIS_LOG r9d
    mov [LOCAL(GG_LOG)], r9d
    mov dword [LOCAL(GG_K)], 0
.b_step:
    mov eax, [LOCAL(GG_K)]
    cmp eax, [LOCAL(GG_L)]
    jge .b_end
    movss xmm0, [LOCAL(GG_PX)]
    addss xmm0, [LOCAL(GG_DX)]
    movss [LOCAL(GG_PX)], xmm0
    movss xmm0, [LOCAL(GG_PZ)]
    addss xmm0, [LOCAL(GG_DZ)]
    movss [LOCAL(GG_PZ)], xmm0
    movss xmm0, [LOCAL(GG_PY)]
    addss xmm0, [rel c_g_rise]
    movss [LOCAL(GG_PY)], xmm0
    call .put_branch
    ; thick near the trunk: a second log above
    mov eax, [LOCAL(GG_K)]
    add eax, eax
    cmp eax, [LOCAL(GG_L)]
    jge .b_thin
    movss xmm0, [LOCAL(GG_PY)]
    addss xmm0, [rel c_one]
    movss [LOCAL(GG_PY)], xmm0
    call .put_branch
    movss xmm0, [LOCAL(GG_PY)]
    subss xmm0, [rel c_one]
    movss [LOCAL(GG_PY)], xmm0
.b_thin:
    inc dword [LOCAL(GG_K)]
    jmp .b_step
.b_end:
    ; leaf cluster at the end
    roundss xmm0, [LOCAL(GG_PX)], 9
    cvttss2si ecx, xmm0
    roundss xmm0, [LOCAL(GG_PY)], 9
    cvttss2si edx, xmm0
    inc edx
    roundss xmm0, [LOCAL(GG_PZ)], 9
    cvttss2si r8d, xmm0
    mov [LOCAL(GG_PX)], ecx             ; (reuse as ints for the call)
    mov [LOCAL(GG_PY)], edx
    mov [LOCAL(GG_PZ)], r8d
    call rng
    movss xmm1, [rsi + TREE.radius + 4]
    subss xmm1, [rsi + TREE.radius]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.radius]
    movss xmm0, xmm1
    mov ecx, [LOCAL(GG_PX)]
    mov edx, [LOCAL(GG_PY)]
    mov r8d, [LOCAL(GG_PZ)]
    movss xmm1, [rel c_g_cl_dn]
    movss xmm2, [rel c_g_cl_up]
    call blob
    inc dword [LOCAL(GG_I)]
    jmp .branch

    ; ---- crown on top ----
.crown:
    call rng
    movss xmm1, [rsi + TREE.radius + 4]
    subss xmm1, [rsi + TREE.radius]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.radius]
    mulss xmm1, [rel c_g_top_scale]
    movss xmm0, xmm1
    mov ecx, [LOCAL(GG_X)]
    mov edx, [LOCAL(GG_Y)]
    add edx, [LOCAL(GG_H)]
    mov r8d, [LOCAL(GG_Z)]
    movss xmm1, [rel c_g_cl_dn]
    movss xmm2, [rel c_g_cl_up]
    call blob
    RETURN

    ; put one branch log at the rounded current position (inner call:
    ; locals are 8 bytes further away; reserves its own shadow space)
.put_branch:
    sub rsp, 40
    roundss xmm0, [LOCAL(GG_PX) + 48], 9
    cvttss2si ecx, xmm0
    roundss xmm0, [LOCAL(GG_PY) + 48], 9
    cvttss2si edx, xmm0
    roundss xmm0, [LOCAL(GG_PZ) + 48], 9
    cvttss2si r8d, xmm0
    mov r9d, [LOCAL(GG_LOG) + 48]
    mov r10d, PUT_LOG
    call put_block
    add rsp, 40
    ret
ENDPROC

; -----------------------------------------------------------------------------
; flora_section — plants and trees of one section (after it is filled).
;   in:  rcx = FCTX*, rdx = ids (u16[32768]), r8d = section y0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define FS_X        0
%define FS_Z        4
%define FS_H        8
%define FS_ID       12
%define FS_GROUND   16                  ; the block the plant stands on
%define FS_B        24                  ; BIOME*
%define FS_LOCALS   32
PROC flora_section, FS_LOCALS, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    mov [rbx + FCTX.ids], rdx
    mov [rbx + FCTX.y0], r8d
    ; ---- plants on the interior columns ----
    xor r12d, r12d                      ; z
.pz:
    xor r13d, r13d                      ; x
.px:
    mov eax, r12d
    shl eax, 5
    add eax, r13d
    imul rsi, rax, INFO_SIZE
    add rsi, [rbx + FCTX.info]
    movzx eax, byte [rsi + INFO_BIOME]
    test eax, eax
    jz .pnext
    cmp byte [rsi + INFO_DENS], 0
    je .pnext
    cmp word [rsi + INFO_POND], POND_NONE
    jne .pnext
    ; plants grow on grass and on the biome's top patch block (moss)
    movzx eax, byte [rsi + INFO_BIOME]
    imul r8, rax, BIOME_size
    lea rax, [rel g_biomes]
    add r8, rax
    mov [LOCAL(FS_B)], r8
    movzx ecx, word [rsi + INFO_TOP]
    mov [LOCAL(FS_GROUND)], ecx
    cmp ecx, [rel g_b_top]
    je .ground_kind
    cmp ecx, [r8 + BIOME.top]
    je .ground_kind
    cmp ecx, [r8 + BIOME.patch]
    jne .pnext
    test ecx, ecx
    jz .pnext
.ground_kind:
    HM_INDEX r13d, r12d
    mov rcx, [rbx + FCTX.heights]
    mov edi, [rcx + rax * 4]            ; H: the plant's block
    lea eax, [edi - 1]
    cmp eax, [rel g_sea_level]
    jle .pnext
    ; the plant (y = H) or a tall plant's top (H + 1) in this section?
    mov eax, edi
    sub eax, [rbx + FCTX.y0]
    inc eax
    cmp eax, 32
    ja .pnext
    ; leaf litter near trunks: replaces the grass top, shade plants on it
    mov eax, r12d
    shl eax, 5
    add eax, r13d
    movzx eax, word [rbx + FCTX.litter + rax * 2]
    test eax, eax
    jz .decide
    mov ecx, [LOCAL(FS_GROUND)]
    cmp ecx, [rel g_b_top]
    jne .decide
    mov [LOCAL(FS_GROUND)], eax
    lea edx, [edi - 1]
    sub edx, [rbx + FCTX.y0]
    cmp edx, 31
    ja .litter_plant
    shl edx, 10
    mov ecx, r12d
    shl ecx, 5
    or edx, ecx
    or edx, r13d
    mov rcx, [rbx + FCTX.ids]
    movzx r8d, word [rcx + rdx * 2]
    cmp r8d, [rel g_b_top]
    jne .litter_plant                   ; (a cave opened it, or a tree stands there)
    mov [rcx + rdx * 2], ax
.litter_plant:
    mov ecx, [rbx + FCTX.cx]
    shl ecx, 5
    add ecx, r13d
    mov edx, [rbx + FCTX.cz]
    shl edx, 5
    add edx, r12d
    mov r8d, 0x5348                     ; "SH"
    xor r9d, r9d
    call hash4
    FRAC16 ax
    mov r8, [LOCAL(FS_B)]
    xorps xmm2, xmm2
    xor ecx, ecx
.sh:
    cmp ecx, [r8 + BIOME.nshade]
    jae .pnext
    addss xmm2, [r8 + BIOME.shade_ch + rcx * 4]
    comiss xmm0, xmm2
    jb .sh_found
    inc ecx
    jmp .sh
.sh_found:
    mov eax, [r8 + BIOME.shade + rcx * 4]
    jmp .have_plant
.decide:
    mov ecx, [rbx + FCTX.cx]
    shl ecx, 5
    add ecx, r13d
    mov edx, [rbx + FCTX.cz]
    shl edx, 5
    add edx, r12d
    mov r8, [LOCAL(FS_B)]
    movzx eax, byte [rsi + INFO_DENS]
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv255]
    call decide_plant
.have_plant:
    test eax, eax
    jz .pnext
    mov [LOCAL(FS_ID)], eax
    ; ground below must still be there (caves may open the surface)
    lea edx, [edi - 1]
    sub edx, [rbx + FCTX.y0]
    cmp edx, 31
    ja .ground_ok
    shl edx, 10
    mov eax, r12d
    shl eax, 5
    or edx, eax
    or edx, r13d
    mov rax, [rbx + FCTX.ids]
    movzx eax, word [rax + rdx * 2]
    cmp eax, [LOCAL(FS_GROUND)]
    jne .pnext
.ground_ok:
    mov ecx, r13d
    mov edx, edi
    mov r8d, r12d
    mov r9d, [LOCAL(FS_ID)]
    mov r10d, PUT_PLANT
    call put_block
    ; tall plant: its upper half (next state) above
    mov eax, [LOCAL(FS_ID)]
    lea rcx, [rel g_block_shape]
    cmp byte [rcx + rax], SHAPE_TALL_PLANT
    jne .pnext
    mov ecx, r13d
    lea edx, [edi + 1]
    mov r8d, r12d
    mov r9d, [LOCAL(FS_ID)]
    inc r9d
    mov r10d, PUT_PLANT
    call put_block
.pnext:
    inc r13d
    cmp r13d, 32
    jb .px
    inc r12d
    cmp r12d, 32
    jb .pz
    ; ---- trees reaching this section ----
    xor r12d, r12d
.tree:
    cmp r12d, [rbx + FCTX.ncand]
    jae .done
    imul rdx, r12, CAND_size
    lea rdx, [rbx + FCTX.cand + rdx]
    mov eax, [rbx + FCTX.y0]
    cmp [rdx + CAND.ytop], eax
    jl .tree_next
    add eax, 31 + 8                     ; (giant trunks and roots reach below)
    cmp [rdx + CAND.y], eax
    jg .tree_next
    mov rcx, rbx
    call gen_tree
.tree_next:
    inc r12d
    jmp .tree
.done:
    RETURN
ENDPROC

section .rdata
align 4
c_inv255:       dd 0.003921568627

section .text
; -----------------------------------------------------------------------------
; flora_survey — part of --survey: biome shares on land within 4 km of the
; origin, and the nearest meadow and pond centres (blend-free biome choice).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define SVF_GX      0
%define SVF_GZ      4
%define SVF_X       8
%define SVF_Z       12
%define SVF_T       16
%define SVF_H       20
%define SVF_LAND    24
%define SVF_MD      28                  ; nearest meadow distance^2
%define SVF_MX      32
%define SVF_MZ      36
%define SVF_PD      40
%define SVF_PX      44
%define SVF_PZ      48
%define SVF_HASH    52
%define SVF_PREV    56                  ; biome of the previous sample in the row
%define SVF_COUNTS  64                  ; u32[MAX_BIOMES]
%define SVF_ND      (64 + MAX_BIOMES * 4)       ; nearest sample per biome: d^2
%define SVF_NX      (SVF_ND + MAX_BIOMES * 4)
%define SVF_NZ      (SVF_NX + MAX_BIOMES * 4)
%define SVF_S       (SVF_NZ + MAX_BIOMES * 4)
%define SVF_QD      (SVF_S + TSAMPLE_size)  ; nearest plateau: d^2, x, z
%define SVF_QX      (SVF_QD + 4)
%define SVF_QZ      (SVF_QD + 8)
%define SVF_QB      (SVF_QD + 12)           ; biome of the current sample
%define SVF_LOCALS  (SVF_QD + 16)
%define SVF_GRID    64                  ; samples per side, every 64 blocks
PROC flora_survey, SVF_LOCALS, rbx, rsi, rdi, r12, r13
    lea rdi, [LOCAL(SVF_COUNTS)]
    xor eax, eax
    mov ecx, MAX_BIOMES
    rep stosd
    mov dword [LOCAL(SVF_PREV)], -1
    lea rdi, [LOCAL(SVF_ND)]
    mov eax, 0x7FFFFFFF
    mov ecx, MAX_BIOMES
    rep stosd
    mov dword [LOCAL(SVF_LAND)], 0
    mov dword [LOCAL(SVF_MD)], 0x7FFFFFFF
    mov dword [LOCAL(SVF_PD)], 0x7FFFFFFF
    mov dword [LOCAL(SVF_QD)], 0x7FFFFFFF
    ; ---- biome shares ----
    xor r12d, r12d
.gz:
    xor r13d, r13d
.gx:
    lea eax, [r13d - SVF_GRID / 2]
    shl eax, 6
    mov [LOCAL(SVF_X)], eax
    lea eax, [r12d - SVF_GRID / 2]
    shl eax, 6
    mov [LOCAL(SVF_Z)], eax
    call sample_biome
    cmp edx, [rel g_sea_level]
    jg .land
    mov dword [LOCAL(SVF_PREV)], -1
    jmp .gnext
.land:
    inc dword [LOCAL(SVF_LAND)]
    inc dword [LOCAL(SVF_COUNTS) + rax * 4]
    ; nearest plateau top (a biome with plateau_height, plateau mask ~1)
    mov [LOCAL(SVF_QB)], eax
    imul rcx, rax, BIOME_size
    lea rdx, [rel g_biomes]
    test dword [rdx + rcx + BIOME.plateau_h], 0x7FFFFFFF
    jz .no_plat
    mov ecx, [LOCAL(SVF_X)]
    imul ecx, ecx
    mov edx, [LOCAL(SVF_Z)]
    imul edx, edx
    add ecx, edx
    cmp ecx, [LOCAL(SVF_QD)]
    jae .no_plat
    mov [LOCAL(SVF_GZ)], ecx
    cvtsi2sd xmm0, dword [LOCAL(SVF_X)]
    cvtsi2sd xmm1, dword [LOCAL(SVF_Z)]
    call biome_plateau
    comiss xmm0, [rel c_sv_plat]
    jb .no_plat
    mov ecx, [LOCAL(SVF_GZ)]
    mov [LOCAL(SVF_QD)], ecx
    mov ecx, [LOCAL(SVF_X)]
    mov [LOCAL(SVF_QX)], ecx
    mov ecx, [LOCAL(SVF_Z)]
    mov [LOCAL(SVF_QZ)], ecx
.no_plat:
    mov eax, [LOCAL(SVF_QB)]
    ; nearest place well inside the biome: the sample to the west matches too
    cmp eax, [LOCAL(SVF_PREV)]
    mov [LOCAL(SVF_PREV)], eax
    jne .gnext
    mov ecx, [LOCAL(SVF_X)]
    imul ecx, ecx
    mov edx, [LOCAL(SVF_Z)]
    imul edx, edx
    add ecx, edx
    cmp ecx, [LOCAL(SVF_ND) + rax * 4]
    jae .gnext
    mov [LOCAL(SVF_ND) + rax * 4], ecx
    mov ecx, [LOCAL(SVF_X)]
    mov [LOCAL(SVF_NX) + rax * 4], ecx
    mov ecx, [LOCAL(SVF_Z)]
    mov [LOCAL(SVF_NZ) + rax * 4], ecx
.gnext:
    inc r13d
    cmp r13d, SVF_GRID
    jb .gx
    mov dword [LOCAL(SVF_PREV)], -1
    inc r12d
    cmp r12d, SVF_GRID
    jb .gz
    ; ---- nearest meadow: cells within +-8 (4 km) ----
    mov r12d, -8
.mz:
    mov r13d, -8
.mx:
    mov ecx, r13d
    mov edx, r12d
    mov r8d, 0x4D45                     ; "ME" (as decide_plant)
    xor r9d, r9d
    call hash4
    mov [LOCAL(SVF_HASH)], eax
    shr eax, 16
    and eax, 0xFF
    imul eax, eax, 384
    shr eax, 8
    add eax, 64
    mov ecx, r13d
    shl ecx, MEADOW_SHIFT
    add eax, ecx
    mov [LOCAL(SVF_X)], eax
    mov eax, [LOCAL(SVF_HASH)]
    shr eax, 24
    imul eax, eax, 384
    shr eax, 8
    add eax, 64
    mov ecx, r12d
    shl ecx, MEADOW_SHIFT
    add eax, ecx
    mov [LOCAL(SVF_Z)], eax
    call sample_biome
    test eax, eax
    jz .mnext
    imul rax, rax, BIOME_size
    lea rcx, [rel g_biomes]
    add rax, rcx
    cmp dword [rax + BIOME.nflowers], 0
    je .mnext
    mov rbx, rax
    FRAC16 word [LOCAL(SVF_HASH)]
    comiss xmm0, [rbx + BIOME.meadow_ch]
    jae .mnext
    mov eax, [LOCAL(SVF_X)]
    imul eax, eax
    mov ecx, [LOCAL(SVF_Z)]
    imul ecx, ecx
    add eax, ecx
    cmp eax, [LOCAL(SVF_MD)]
    jae .mnext
    mov [LOCAL(SVF_MD)], eax
    mov eax, [LOCAL(SVF_X)]
    mov [LOCAL(SVF_MX)], eax
    mov eax, [LOCAL(SVF_Z)]
    mov [LOCAL(SVF_MZ)], eax
.mnext:
    inc r13d
    cmp r13d, 8
    jl .mx
    inc r12d
    cmp r12d, 8
    jl .mz
    ; ---- nearest pond: cells within +-16 (2 km) ----
    mov r12d, -16
.pz:
    mov r13d, -16
.px:
    mov ecx, r13d
    mov edx, r12d
    mov r8d, 0x5044                     ; "PD" (as flora_ponds)
    xor r9d, r9d
    call hash4
    mov [LOCAL(SVF_HASH)], eax
    shr eax, 16
    and eax, 0xFF
    imul eax, eax, POND_SPAN
    shr eax, 8
    add eax, POND_OFS
    mov ecx, r13d
    imul ecx, ecx, POND_CELL
    add eax, ecx
    mov [LOCAL(SVF_X)], eax
    mov eax, [LOCAL(SVF_HASH)]
    shr eax, 24
    imul eax, eax, POND_SPAN
    shr eax, 8
    add eax, POND_OFS
    mov ecx, r12d
    imul ecx, ecx, POND_CELL
    add eax, ecx
    mov [LOCAL(SVF_Z)], eax
    call sample_biome
    test eax, eax
    jz .pnext
    imul rax, rax, BIOME_size
    lea rcx, [rel g_biomes]
    lea rbx, [rax + rcx]
    FRAC16 word [LOCAL(SVF_HASH)]
    comiss xmm0, [rbx + BIOME.pond_ch]
    jae .pnext
    mov eax, [LOCAL(SVF_X)]
    imul eax, eax
    mov ecx, [LOCAL(SVF_Z)]
    imul ecx, ecx
    add eax, ecx
    cmp eax, [LOCAL(SVF_PD)]
    jae .pnext
    mov [LOCAL(SVF_PD)], eax
    mov eax, [LOCAL(SVF_X)]
    mov [LOCAL(SVF_PX)], eax
    mov eax, [LOCAL(SVF_Z)]
    mov [LOCAL(SVF_PZ)], eax
.pnext:
    inc r13d
    cmp r13d, 16
    jl .px
    inc r12d
    cmp r12d, 16
    jl .pz
    ; ---- report ----
    LOG_INFO "survey: biomes on land within 2 km (per mille of land samples)"
    mov ebx, 1
.rep:
    cmp ebx, [rel g_biome_count]
    jae .rep_none
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel s_sv_biome]
    call log_append_str
    imul rax, rbx, BIOME_size
    lea rcx, [rel g_biomes]
    mov rcx, [rcx + rax + BIOME.name]
    call log_append_str
    lea rcx, [rel s_sv_sp]
    call log_append_str
    mov eax, [LOCAL(SVF_COUNTS) + rbx * 4]
    imul eax, eax, 1000
    xor edx, edx
    mov ecx, [LOCAL(SVF_LAND)]
    test ecx, ecx
    jz .rep_div0
    div ecx
.rep_div0:
    mov ecx, eax
    call log_append_dec
    call log_end
    cmp dword [LOCAL(SVF_ND) + rbx * 4], 0x7FFFFFFF
    je .rep_next
    lea rcx, [rel s_sv_near]
    mov edx, [LOCAL(SVF_NX) + rbx * 4]
    mov r8d, [LOCAL(SVF_NZ) + rbx * 4]
    call log_xz
.rep_next:
    inc ebx
    jmp .rep
.rep_none:
    mov eax, [LOCAL(SVF_COUNTS)]
    imul eax, eax, 1000
    xor edx, edx
    mov ecx, [LOCAL(SVF_LAND)]
    test ecx, ecx
    jz .rep_div1
    div ecx
.rep_div1:
    LOG_VAL LOG_LEVEL_INFO, "survey: biome none (not designed yet)", rax
    cmp dword [LOCAL(SVF_MD)], 0x7FFFFFFF
    je .no_meadow
    lea rcx, [rel s_sv_meadow]
    mov edx, [LOCAL(SVF_MX)]
    mov r8d, [LOCAL(SVF_MZ)]
    call log_xz
.no_meadow:
    cmp dword [LOCAL(SVF_PD)], 0x7FFFFFFF
    je .no_pond
    lea rcx, [rel s_sv_pond]
    mov edx, [LOCAL(SVF_PX)]
    mov r8d, [LOCAL(SVF_PZ)]
    call log_xz
.no_pond:
    cmp dword [LOCAL(SVF_QD)], 0x7FFFFFFF
    je .no_plateau
    lea rcx, [rel s_sv_plateau]
    mov edx, [LOCAL(SVF_QX)]
    mov r8d, [LOCAL(SVF_QZ)]
    call log_xz
.no_plateau:
    RETURN

; sample_biome — biome (no blending) and height at [SVF_X], [SVF_Z]
;   out: eax = biome, edx = height   (inner call: locals +8)
sample_biome:
    sub rsp, 40
    cvtsi2sd xmm0, dword [LOCAL(SVF_X) + 48]
    cvtsi2sd xmm1, dword [LOCAL(SVF_Z) + 48]
    lea rcx, [LOCAL(SVF_S) + 48]
    call terrain_sample
    cvttss2si ecx, [LOCAL(SVF_S) + 48 + TSAMPLE.height]
    mov [LOCAL(SVF_GX) + 48], ecx
    cvtsi2sd xmm0, dword [LOCAL(SVF_X) + 48]
    cvtsi2sd xmm1, dword [LOCAL(SVF_Z) + 48]
    call biome_point
    mov edx, [LOCAL(SVF_GX) + 48]
    add rsp, 40
    ret
ENDPROC

section .rdata
s_sv_biome:     db "survey: biome ", 0
s_sv_sp:        db " ", 0
s_sv_near:      db "survey:   nearest place well inside at", 0
s_sv_meadow:    db "survey: nearest flower meadow centre at", 0
s_sv_pond:      db "survey: nearest pond centre at", 0
s_sv_plateau:   db "survey: nearest plateau top at", 0
c_sv_plat:      dd 0.95

section .text
; -----------------------------------------------------------------------------
; gen_cactus — a cactus column with optional arms and a flower on top
; (TREE.log = cactus, TREE.leaves = flower, TREE.branches = arm count range,
; TREE.chance = flower chance).   (rbx = FCTX*, edi = rng state)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
; -----------------------------------------------------------------------------
%define GC_X        0
%define GC_Y        4
%define GC_Z        8
%define GC_H        12
%define GC_N        16
%define GC_AX       20                  ; arm offset
%define GC_AZ       24
%define GC_AY       28
%define GC_LOCALS   32
PROC gen_cactus, GC_LOCALS, rsi, r12
    mov rsi, r9
    mov [LOCAL(GC_X)], ecx
    mov [LOCAL(GC_Y)], edx
    mov [LOCAL(GC_Z)], r8d
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    mov [LOCAL(GC_H)], eax
    xor r12d, r12d
.col:
    cmp r12d, [LOCAL(GC_H)]
    jge .flower
    mov ecx, [LOCAL(GC_X)]
    mov edx, [LOCAL(GC_Y)]
    add edx, r12d
    mov r8d, [LOCAL(GC_Z)]
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
    inc r12d
    jmp .col
.flower:
    call rng
    comiss xmm0, [rsi + TREE.chance]
    jae .arms
    mov ecx, [LOCAL(GC_X)]
    mov edx, [LOCAL(GC_Y)]
    add edx, [LOCAL(GC_H)]
    mov r8d, [LOCAL(GC_Z)]
    mov r9d, [rsi + TREE.leaves]
    mov r10d, PUT_PLANT
    call put_block
.arms:
    ; arms only on cacti at least 3 tall
    cmp dword [LOCAL(GC_H)], 3
    jl .done
    mov ecx, [rsi + TREE.branches]
    mov edx, [rsi + TREE.branches + 4]
    call rand_int
    mov [LOCAL(GC_N)], eax
.arm:
    cmp dword [LOCAL(GC_N)], 0
    jle .done
    dec dword [LOCAL(GC_N)]
    ; side: one of 4, start 1 .. H-2 up
    mov ecx, 0
    mov edx, 3
    call rand_int
    xor ecx, ecx
    xor edx, edx
    cmp eax, 0
    jne .s1
    mov ecx, 1
.s1:
    cmp eax, 1
    jne .s2
    mov ecx, -1
.s2:
    cmp eax, 2
    jne .s3
    mov edx, 1
.s3:
    cmp eax, 3
    jne .s4
    mov edx, -1
.s4:
    mov [LOCAL(GC_AX)], ecx
    mov [LOCAL(GC_AZ)], edx
    mov ecx, 1
    mov edx, [LOCAL(GC_H)]
    sub edx, 2
    call rand_int
    add eax, [LOCAL(GC_Y)]
    mov [LOCAL(GC_AY)], eax
    ; the elbow, then up 1 .. 3
    mov ecx, 1
    mov edx, 3
    call rand_int
    mov r12d, eax
    inc r12d
.up:
    dec r12d
    js .arm
    mov ecx, [LOCAL(GC_X)]
    add ecx, [LOCAL(GC_AX)]
    mov edx, [LOCAL(GC_AY)]
    add edx, r12d
    mov r8d, [LOCAL(GC_Z)]
    add r8d, [LOCAL(GC_AZ)]
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
    jmp .up
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gen_rock — stacked discs shrinking upward, sunk 2 blocks into the ground:
; a boulder (low) or a spire (tall). TREE.log = block, TREE.radius = base
; radius range, TREE.height = height range.   (rbx = FCTX*, edi = rng)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
; -----------------------------------------------------------------------------
%define GR_X        0
%define GR_Y        4
%define GR_Z        8
%define GR_H        12
%define GR_R0       16
%define GR_R        20
%define GR_RI       24
%define GR_YI       28
%define GR_LOCALS   32
PROC gen_rock, GR_LOCALS, rsi, r12, r13
    mov rsi, r9
    mov [LOCAL(GR_X)], ecx
    mov [LOCAL(GR_Y)], edx
    mov [LOCAL(GR_Z)], r8d
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    mov [LOCAL(GR_H)], eax
    call rng
    movss xmm1, [rsi + TREE.radius + 4]
    subss xmm1, [rsi + TREE.radius]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.radius]
    movss [LOCAL(GR_R0)], xmm1
    mov dword [LOCAL(GR_YI)], -2
.disc:
    mov eax, [LOCAL(GR_YI)]
    cmp eax, [LOCAL(GR_H)]
    jge .done
    ; r = R0 * (1 - (1 - top) * t^1.5), t = y / H
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    cvtsi2ss xmm0, eax
    cvtsi2ss xmm1, dword [LOCAL(GR_H)]
    divss xmm0, xmm1
    sqrtss xmm1, xmm0
    mulss xmm0, xmm1                    ; t^1.5
    movss xmm1, [rel c_one]
    subss xmm1, [rel c_rock_top]
    mulss xmm0, xmm1
    movss xmm1, [rel c_one]
    subss xmm1, xmm0
    mulss xmm1, [LOCAL(GR_R0)]
    movss [LOCAL(GR_R)], xmm1
    addss xmm1, [rel c_half]
    cvttss2si eax, xmm1
    mov [LOCAL(GR_RI)], eax
    mov r12d, eax
    neg r12d
.dz:
    mov r13d, [LOCAL(GR_RI)]
    neg r13d
.dx:
    mov eax, r13d
    imul eax, eax
    mov ecx, r12d
    imul ecx, ecx
    add eax, ecx
    cvtsi2ss xmm0, eax
    movss xmm1, [LOCAL(GR_R)]
    mulss xmm1, xmm1
    addss xmm1, [rel c_g_disc]
    comiss xmm0, xmm1
    ja .dx_next
    ; rough edges
    call rng
    comiss xmm0, [rel c_rock_rough]
    jb .dx_next
    mov ecx, [LOCAL(GR_X)]
    add ecx, r13d
    mov edx, [LOCAL(GR_Y)]
    add edx, [LOCAL(GR_YI)]
    mov r8d, [LOCAL(GR_Z)]
    add r8d, r12d
    mov r9d, [rsi + TREE.log]
    ; upper half: the `leaves` block if set (moss on top of boulders)
    mov eax, [LOCAL(GR_YI)]
    add eax, eax
    cmp eax, [LOCAL(GR_H)]
    jl .rock_low
    mov eax, [rsi + TREE.leaves]
    test eax, eax
    jz .rock_low
    call rng
    comiss xmm0, [rel c_half]
    jb .rock_low
    mov r9d, [rsi + TREE.leaves]
.rock_low:
    mov ecx, [LOCAL(GR_X)]
    add ecx, r13d
    mov edx, [LOCAL(GR_Y)]
    add edx, [LOCAL(GR_YI)]
    mov r8d, [LOCAL(GR_Z)]
    add r8d, r12d
    mov r10d, PUT_SOLID
    call put_block
.dx_next:
    inc r13d
    cmp r13d, [LOCAL(GR_RI)]
    jle .dx
    inc r12d
    cmp r12d, [LOCAL(GR_RI)]
    jle .dz
    inc dword [LOCAL(GR_YI)]
    jmp .disc
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gen_arch — a natural arch: a half-ring of radius R (TREE.radius) along X or
; Z, 0.85 R high, made of discs (thickness 1.1), with its legs carried 3
; blocks down into the ground.   (rbx = FCTX*, edi = rng)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
; -----------------------------------------------------------------------------
%define GA_X        0
%define GA_Y        4
%define GA_Z        8
%define GA_R        12
%define GA_A        16                  ; angle
%define GA_ALONGX   20
%define GA_PX       24                  ; f32 centre of this disc
%define GA_PY       28
%define GA_DY       32
%define GA_DH       36                  ; ints: offsets
%define GA_DV       40
%define GA_LEG      44
%define GA_LOCALS   48
PROC gen_arch, GA_LOCALS, rsi, r12, r13
    mov rsi, r9
    mov [LOCAL(GA_X)], ecx
    mov [LOCAL(GA_Y)], edx
    mov [LOCAL(GA_Z)], r8d
    call rng
    movss xmm1, [rsi + TREE.radius + 4]
    subss xmm1, [rsi + TREE.radius]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.radius]
    movss [LOCAL(GA_R)], xmm1
    mov eax, edi
    shr eax, 31
    mov [LOCAL(GA_ALONGX)], eax
    xorps xmm0, xmm0
    movss [LOCAL(GA_A)], xmm0
.ang:
    movss xmm0, [LOCAL(GA_A)]
    comiss xmm0, [rel c_pi]
    ja .done
    ; p = (R cos a, 0.85 R sin a) relative to the centre at ground level
    movss xmm1, xmm0
    call .cos_sin                       ; xmm0 = cos, xmm1 = sin
    mulss xmm0, [LOCAL(GA_R)]
    movss [LOCAL(GA_PX)], xmm0
    mulss xmm1, [LOCAL(GA_R)]
    mulss xmm1, [rel c_arch_flat]
    movss [LOCAL(GA_PY)], xmm1
    ; a small disc (cross-section) around p; at the two ends extend down
    mov r12d, -1                        ; dv (vertical)
.dv:
    mov r13d, -1                        ; dh (across the arch)
.dh:
    mov eax, r12d
    imul eax, eax
    mov ecx, r13d
    imul ecx, ecx
    add eax, ecx
    cmp eax, 1
    jg .dh_next
    movss xmm0, [LOCAL(GA_PX)]
    roundss xmm0, xmm0, 9
    cvttss2si eax, xmm0                 ; along
    movss xmm0, [LOCAL(GA_PY)]
    roundss xmm0, xmm0, 9
    cvttss2si edx, xmm0
    add edx, r12d
    add edx, [LOCAL(GA_Y)]
    cmp dword [LOCAL(GA_ALONGX)], 0
    je .along_z
    mov ecx, [LOCAL(GA_X)]
    add ecx, eax
    mov r8d, [LOCAL(GA_Z)]
    add r8d, r13d
    jmp .put
.along_z:
    mov ecx, [LOCAL(GA_X)]
    add ecx, r13d
    mov r8d, [LOCAL(GA_Z)]
    add r8d, eax
.put:
    mov [LOCAL(GA_DH)], ecx
    mov [LOCAL(GA_DV)], r8d
    mov [LOCAL(GA_DY)], edx
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_SOLID
    call put_block
    ; legs: near the ends (sin small), carry down 3 blocks
    movss xmm0, [LOCAL(GA_PY)]
    comiss xmm0, [rel c_arch_t]
    ja .dh_next
    mov eax, 1
.leg:
    cmp eax, 4
    jge .dh_next
    mov [LOCAL(GA_LEG)], eax
    mov ecx, [LOCAL(GA_DH)]
    mov edx, [LOCAL(GA_DY)]
    sub edx, eax
    mov r8d, [LOCAL(GA_DV)]
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_SOLID
    call put_block
    mov eax, [LOCAL(GA_LEG)]
    inc eax
    jmp .leg
.dh_next:
    inc r13d
    cmp r13d, 1
    jle .dh
    inc r12d
    cmp r12d, 1
    jle .dv
    movss xmm0, [LOCAL(GA_A)]
    addss xmm0, [rel c_arch_step]
    movss [LOCAL(GA_A)], xmm0
    jmp .ang
.done:
    RETURN

    ; cos and sin of xmm1 (0..pi) by Taylor series around pi/2
    ;   out: xmm0 = cos, xmm1 = sin      clobbers: xmm2-xmm3
    ;   (inner helper: no stack use)
.cos_sin:
    subss xmm1, [rel c_half_pi]         ; u = a - pi/2: cos a = -sin u, sin a = cos u
    movss xmm2, xmm1
    mulss xmm2, xmm2                    ; u^2
    ; sin u = u (1 - u^2/6 (1 - u^2/20 (1 - u^2/42)))
    movss xmm3, xmm2
    mulss xmm3, [rel c_inv42]
    movss xmm0, [rel c_one]
    subss xmm0, xmm3
    mulss xmm0, xmm2
    mulss xmm0, [rel c_inv20]
    movss xmm3, [rel c_one]
    subss xmm3, xmm0
    mulss xmm3, xmm2
    mulss xmm3, [rel c_inv6]
    movss xmm0, [rel c_one]
    subss xmm0, xmm3
    mulss xmm0, xmm1                    ; sin u
    xorps xmm0, [rel c_sign]            ; cos a = -sin u
    ; cos u = 1 - u^2/2 (1 - u^2/12 (1 - u^2/30 (1 - u^2/56)))
    movss xmm3, xmm2
    mulss xmm3, [rel c_inv56]
    movss xmm1, [rel c_one]
    subss xmm1, xmm3
    mulss xmm1, xmm2
    mulss xmm1, [rel c_inv30]
    movss xmm3, [rel c_one]
    subss xmm3, xmm1
    mulss xmm3, xmm2
    mulss xmm3, [rel c_inv12]
    movss xmm1, [rel c_one]
    subss xmm1, xmm3
    mulss xmm1, xmm2
    mulss xmm1, [rel c_half]
    movss xmm3, [rel c_one]
    subss xmm3, xmm1
    movss xmm1, xmm3                    ; sin a = cos u
    ret
ENDPROC

; -----------------------------------------------------------------------------
; gen_fossil — a spine of TREE.log (bone) along X or Z, half-buried (at the
; ground block), with ribs arching up on both sides every 2 blocks.
;   (rbx = FCTX*, edi = rng)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
; -----------------------------------------------------------------------------
%define GF2_X       0
%define GF2_Y       4
%define GF2_Z       8
%define GF2_L       12
%define GF2_AX      16
%define GF2_I       20
%define GF2_LOCALS  32
; FOSSIL_PUT across, up — one bone at (segment i, across, up)
%macro FOSSIL_PUT 2
    mov eax, [LOCAL(GF2_I)]
    mov r11d, %1
    cmp dword [LOCAL(GF2_AX)], 0
    je %%along_z
    mov ecx, [LOCAL(GF2_X)]
    add ecx, eax
    mov r8d, [LOCAL(GF2_Z)]
    add r8d, r11d
    jmp %%have
%%along_z:
    mov ecx, [LOCAL(GF2_X)]
    add ecx, r11d
    mov r8d, [LOCAL(GF2_Z)]
    add r8d, eax
%%have:
    mov edx, [LOCAL(GF2_Y)]
    add edx, %2
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_SOLID
    call put_block
%endmacro
PROC gen_fossil, GF2_LOCALS, rsi
    mov rsi, r9
    mov [LOCAL(GF2_X)], ecx
    dec edx                             ; half-buried: in the ground block
    mov [LOCAL(GF2_Y)], edx
    mov [LOCAL(GF2_Z)], r8d
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    mov [LOCAL(GF2_L)], eax
    mov eax, edi
    shr eax, 31
    mov [LOCAL(GF2_AX)], eax
    mov dword [LOCAL(GF2_I)], 0
.seg:
    mov eax, [LOCAL(GF2_I)]
    cmp eax, [LOCAL(GF2_L)]
    jge .done
    FOSSIL_PUT 0, 0
    ; ribs on every second segment, not at the head or the tail
    mov eax, [LOCAL(GF2_I)]
    test eax, 1
    jnz .next
    test eax, eax
    jz .next
    inc eax
    cmp eax, [LOCAL(GF2_L)]
    jge .next
    FOSSIL_PUT 1, 1
    FOSSIL_PUT -1, 1
    FOSSIL_PUT 2, 2
    FOSSIL_PUT -2, 2
    FOSSIL_PUT 2, 3
    FOSSIL_PUT -2, 3
.next:
    inc dword [LOCAL(GF2_I)]
    jmp .seg
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gen_palm — a palm: a trunk that curves away from upright (top offset about
; 0.4 x height in one of 8 directions), a tuft of leaves on top and 8 fronds
; of TREE.radius length that droop towards their tips.
;   (rbx = FCTX*, edi = rng)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
; -----------------------------------------------------------------------------
%define GP_X        0
%define GP_Y        4
%define GP_Z        8
%define GP_H        12
%define GP_DX       16                  ; f32 lean direction
%define GP_DZ       20
%define GP_I        24
%define GP_TX       28                  ; top of the trunk
%define GP_TY       32
%define GP_TZ       36
%define GP_L        40                  ; frond length
%define GP_D        44                  ; frond direction
%define GP_K        48
%define GP_LOCALS   64
PROC gen_palm, GP_LOCALS, rsi
    mov rsi, r9
    mov [LOCAL(GP_X)], ecx
    mov [LOCAL(GP_Y)], edx
    mov [LOCAL(GP_Z)], r8d
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    mov [LOCAL(GP_H)], eax
    mov ecx, 0
    mov edx, 7
    call rand_int
    lea rcx, [rel dirs]
    movss xmm0, [rcx + rax * 8]
    movss [LOCAL(GP_DX)], xmm0
    movss xmm0, [rcx + rax * 8 + 4]
    movss [LOCAL(GP_DZ)], xmm0
    mov dword [LOCAL(GP_I)], 0
.trunk:
    mov eax, [LOCAL(GP_I)]
    cmp eax, [LOCAL(GP_H)]
    jge .crown
    ; offset = 0.4 * i^2 / H
    imul eax, eax
    cvtsi2ss xmm2, eax
    cvtsi2ss xmm1, dword [LOCAL(GP_H)]
    divss xmm2, xmm1
    mulss xmm2, [rel c_palm_off]
    movss xmm0, [LOCAL(GP_DX)]
    mulss xmm0, xmm2
    roundss xmm0, xmm0, 9
    cvttss2si ecx, xmm0
    add ecx, [LOCAL(GP_X)]
    movss xmm0, [LOCAL(GP_DZ)]
    mulss xmm0, xmm2
    roundss xmm0, xmm0, 9
    cvttss2si r8d, xmm0
    add r8d, [LOCAL(GP_Z)]
    mov edx, [LOCAL(GP_Y)]
    add edx, [LOCAL(GP_I)]
    mov [LOCAL(GP_TX)], ecx
    mov [LOCAL(GP_TY)], edx
    mov [LOCAL(GP_TZ)], r8d
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
    inc dword [LOCAL(GP_I)]
    jmp .trunk
.crown:
    ; tuft: the block above the trunk and its 4 neighbours
    mov ecx, [LOCAL(GP_TX)]
    mov edx, [LOCAL(GP_TY)]
    inc edx
    mov r8d, [LOCAL(GP_TZ)]
    mov r9d, [rsi + TREE.leaves]
    mov r10d, PUT_LEAVES
    call put_block
    ; fronds
    mov dword [LOCAL(GP_D)], 0
.frond:
    cmp dword [LOCAL(GP_D)], 8
    jge .done
    call rng
    movss xmm1, [rsi + TREE.radius + 4]
    subss xmm1, [rsi + TREE.radius]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.radius]
    cvttss2si eax, xmm1
    mov [LOCAL(GP_L)], eax
    mov dword [LOCAL(GP_K)], 1
.leaf:
    mov eax, [LOCAL(GP_K)]
    cmp eax, [LOCAL(GP_L)]
    jg .frond_next
    mov ecx, [LOCAL(GP_D)]
    lea r10, [rel dirs]
    cvtsi2ss xmm2, eax
    movss xmm0, [r10 + rcx * 8]
    mulss xmm0, xmm2
    roundss xmm0, xmm0, 9
    cvttss2si ecx, xmm0
    add ecx, [LOCAL(GP_TX)]
    mov edx, [LOCAL(GP_D)]
    movss xmm0, [r10 + rdx * 8 + 4]
    mulss xmm0, xmm2
    roundss xmm0, xmm0, 9
    cvttss2si r8d, xmm0
    add r8d, [LOCAL(GP_TZ)]
    ; droop: y = top + 1 - k^2 / (2 L)
    mov eax, [LOCAL(GP_K)]
    imul eax, eax
    mov r9d, [LOCAL(GP_L)]
    add r9d, r9d
    xor edx, edx
    div r9d
    mov edx, [LOCAL(GP_TY)]
    inc edx
    sub edx, eax
    mov r9d, [rsi + TREE.leaves]
    mov r10d, PUT_LEAVES
    call put_block
    inc dword [LOCAL(GP_K)]
    jmp .leaf
.frond_next:
    inc dword [LOCAL(GP_D)]
    jmp .frond
.done:
    RETURN
ENDPROC

section .rdata
c_palm_off:     dd 0.4

section .text
; -----------------------------------------------------------------------------
; gen_conifer — a spruce: a trunk of `height`, needles from a quarter of the
; way up in discs whose radius shrinks linearly from `radius` to 0 at the
; tip; every second layer is one block smaller (layered tiers); a needle
; block caps the tip.   (rbx = FCTX*, edi = rng)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
; -----------------------------------------------------------------------------
%define GN_X        0
%define GN_Y        4
%define GN_Z        8
%define GN_H        12
%define GN_R0       16
%define GN_R        20
%define GN_RI       24
%define GN_YI       28
%define GN_B        32                  ; first needle layer
%define GN_LOCALS   48
PROC gen_conifer, GN_LOCALS, rsi, r12, r13
    mov rsi, r9
    mov [LOCAL(GN_X)], ecx
    mov [LOCAL(GN_Y)], edx
    mov [LOCAL(GN_Z)], r8d
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    mov [LOCAL(GN_H)], eax
    call rng
    movss xmm1, [rsi + TREE.radius + 4]
    subss xmm1, [rsi + TREE.radius]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.radius]
    movss [LOCAL(GN_R0)], xmm1
    mov eax, [LOCAL(GN_H)]
    shr eax, 2
    inc eax
    mov [LOCAL(GN_B)], eax
    ; trunk (ends 3 below the tip, so the top is a cone of needles)
    xor r12d, r12d
.trunk:
    mov eax, [LOCAL(GN_H)]
    sub eax, 3
    cmp r12d, eax
    jge .needles
    mov ecx, [LOCAL(GN_X)]
    mov edx, [LOCAL(GN_Y)]
    add edx, r12d
    mov r8d, [LOCAL(GN_Z)]
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
    inc r12d
    jmp .trunk
.needles:
    mov eax, [LOCAL(GN_B)]
    mov [LOCAL(GN_YI)], eax
.layer:
    mov eax, [LOCAL(GN_YI)]
    cmp eax, [LOCAL(GN_H)]
    jg .done
    ; r = R0 * (H - y) / (H - B), minus 0.8 on odd layers
    mov ecx, [LOCAL(GN_H)]
    sub ecx, eax
    cvtsi2ss xmm0, ecx
    mov ecx, [LOCAL(GN_H)]
    sub ecx, [LOCAL(GN_B)]
    cvtsi2ss xmm1, ecx
    divss xmm0, xmm1
    mulss xmm0, [LOCAL(GN_R0)]
    test eax, 1
    jz .even
    subss xmm0, [rel c_tier]
.even:
    maxss xmm0, [rel c_zero]
    movss [LOCAL(GN_R)], xmm0
    addss xmm0, [rel c_half]
    cvttss2si eax, xmm0
    mov [LOCAL(GN_RI)], eax
    mov r12d, eax
    neg r12d
.dz:
    mov r13d, [LOCAL(GN_RI)]
    neg r13d
.dx:
    mov eax, r13d
    imul eax, eax
    mov ecx, r12d
    imul ecx, ecx
    add eax, ecx
    cvtsi2ss xmm0, eax
    movss xmm1, [LOCAL(GN_R)]
    mulss xmm1, xmm1
    addss xmm1, [rel c_g_disc]
    comiss xmm0, xmm1
    ja .dx_next
    ; ragged edge
    movss xmm1, [LOCAL(GN_R)]
    subss xmm1, [rel c_one]
    mulss xmm1, xmm1
    comiss xmm0, xmm1
    jbe .put
    call rng
    comiss xmm0, [rsi + TREE.gaps]
    jb .dx_next
.put:
    mov ecx, [LOCAL(GN_X)]
    add ecx, r13d
    mov edx, [LOCAL(GN_Y)]
    add edx, [LOCAL(GN_YI)]
    mov r8d, [LOCAL(GN_Z)]
    add r8d, r12d
    mov r9d, [rsi + TREE.leaves]
    mov r10d, PUT_LEAVES
    call put_block
.dx_next:
    inc r13d
    cmp r13d, [LOCAL(GN_RI)]
    jle .dx
    inc r12d
    cmp r12d, [LOCAL(GN_RI)]
    jle .dz
    inc dword [LOCAL(GN_YI)]
    jmp .layer
.done:
    RETURN
ENDPROC

section .rdata
c_tier:         dd 0.8

section .text
; -----------------------------------------------------------------------------
; pad — a flat leaf pad: a disc of radius r at y, and a disc of r - 1.3 one
; layer above.   (rbx = FCTX*, rsi = TREE*, edi = rng)
;   in:  ecx = x, edx = y, r8d = z, xmm0 = r
; -----------------------------------------------------------------------------
%define PD_X        0
%define PD_Y        4
%define PD_Z        8
%define PD_R        12
%define PD_RI       16
%define PD_L        20
%define PD_LOCALS   32
PROC pad, PD_LOCALS, r12, r13
    mov [LOCAL(PD_X)], ecx
    mov [LOCAL(PD_Y)], edx
    mov [LOCAL(PD_Z)], r8d
    movss [LOCAL(PD_R)], xmm0
    mov dword [LOCAL(PD_L)], 0
.layer:
    movss xmm0, [LOCAL(PD_R)]
    addss xmm0, [rel c_half]
    cvttss2si eax, xmm0
    mov [LOCAL(PD_RI)], eax
    mov r12d, eax
    neg r12d
.dz:
    mov r13d, [LOCAL(PD_RI)]
    neg r13d
.dx:
    mov eax, r13d
    imul eax, eax
    mov ecx, r12d
    imul ecx, ecx
    add eax, ecx
    cvtsi2ss xmm0, eax
    movss xmm1, [LOCAL(PD_R)]
    mulss xmm1, xmm1
    addss xmm1, [rel c_g_disc]
    comiss xmm0, xmm1
    ja .next
    ; ragged rim
    movss xmm1, [LOCAL(PD_R)]
    subss xmm1, [rel c_one]
    mulss xmm1, xmm1
    comiss xmm0, xmm1
    jbe .put
    call rng
    comiss xmm0, [rsi + TREE.gaps]
    jb .next
.put:
    mov ecx, [LOCAL(PD_X)]
    add ecx, r13d
    mov edx, [LOCAL(PD_Y)]
    add edx, [LOCAL(PD_L)]
    mov r8d, [LOCAL(PD_Z)]
    add r8d, r12d
    mov r9d, [rsi + TREE.leaves]
    mov r10d, PUT_LEAVES
    call put_block
.next:
    inc r13d
    cmp r13d, [LOCAL(PD_RI)]
    jle .dx
    inc r12d
    cmp r12d, [LOCAL(PD_RI)]
    jle .dz
    cmp dword [LOCAL(PD_L)], 0
    jne .done
    mov dword [LOCAL(PD_L)], 1
    movss xmm0, [LOCAL(PD_R)]
    subss xmm0, [rel c_pad_top]
    movss [LOCAL(PD_R)], xmm0
    comiss xmm0, [rel c_half]
    ja .layer
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gen_acacia — a trunk of `height` that forks into 2 diagonal limbs (2..4
; blocks each, opposite-ish directions), each ending in a flat leaf pad of
; `radius`.   (rbx = FCTX*, edi = rng)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
; -----------------------------------------------------------------------------
%define GK_X        0
%define GK_Y        4
%define GK_Z        8
%define GK_H        12
%define GK_D0       16                  ; first limb direction (0..7)
%define GK_I        20
%define GK_PX       24
%define GK_PY       28
%define GK_PZ       32
%define GK_L        36
%define GK_K        40
%define GK_DIR      44
%define GK_LOCALS   48
PROC gen_acacia, GK_LOCALS, rsi
    mov rsi, r9
    mov [LOCAL(GK_X)], ecx
    mov [LOCAL(GK_Y)], edx
    mov [LOCAL(GK_Z)], r8d
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    mov [LOCAL(GK_H)], eax
    xor ecx, ecx
.trunk:
    cmp ecx, [LOCAL(GK_H)]
    jge .forks
    mov [LOCAL(GK_K)], ecx
    mov edx, [LOCAL(GK_Y)]
    add edx, ecx
    mov ecx, [LOCAL(GK_X)]
    mov r8d, [LOCAL(GK_Z)]
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
    mov ecx, [LOCAL(GK_K)]
    inc ecx
    jmp .trunk
.forks:
    mov ecx, 0
    mov edx, 7
    call rand_int
    mov [LOCAL(GK_D0)], eax
    mov dword [LOCAL(GK_I)], 0
.fork:
    cmp dword [LOCAL(GK_I)], 2
    jge .done
    ; direction: d0, then d0 + 3..5 (roughly opposite)
    mov eax, [LOCAL(GK_D0)]
    cmp dword [LOCAL(GK_I)], 0
    je .have_dir
    mov ecx, 3
    mov edx, 5
    call rand_int
    add eax, [LOCAL(GK_D0)]
.have_dir:
    and eax, 7
    mov [LOCAL(GK_DIR)], eax
    mov eax, [LOCAL(GK_X)]
    mov [LOCAL(GK_PX)], eax
    mov eax, [LOCAL(GK_Y)]
    add eax, [LOCAL(GK_H)]
    dec eax
    mov [LOCAL(GK_PY)], eax
    mov eax, [LOCAL(GK_Z)]
    mov [LOCAL(GK_PZ)], eax
    mov ecx, 2
    mov edx, 4
    call rand_int
    mov [LOCAL(GK_L)], eax
.limb:
    cmp dword [LOCAL(GK_L)], 0
    jle .pad
    dec dword [LOCAL(GK_L)]
    ; step diagonally out and up
    mov eax, [LOCAL(GK_DIR)]
    lea rcx, [rel dir_step]
    movsx edx, byte [rcx + rax * 2]
    add [LOCAL(GK_PX)], edx
    movsx edx, byte [rcx + rax * 2 + 1]
    add [LOCAL(GK_PZ)], edx
    inc dword [LOCAL(GK_PY)]
    mov ecx, [LOCAL(GK_PX)]
    mov edx, [LOCAL(GK_PY)]
    mov r8d, [LOCAL(GK_PZ)]
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
    jmp .limb
.pad:
    call rng
    movss xmm1, [rsi + TREE.radius + 4]
    subss xmm1, [rsi + TREE.radius]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.radius]
    movss xmm0, xmm1
    mov ecx, [LOCAL(GK_PX)]
    mov edx, [LOCAL(GK_PY)]
    inc edx
    mov r8d, [LOCAL(GK_PZ)]
    call pad
    inc dword [LOCAL(GK_I)]
    jmp .fork
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gen_baobab — a fat bottle-shaped trunk: radius from base_radius, bulging
; to 1.15x at 40% of the height and narrowing to 0.6x at the top; then
; `branches` stubby branches (2..4 blocks, steeply up) with small leaf
; tufts of `radius`.   (rbx = FCTX*, edi = rng)
;   in:  ecx = x, edx = y (first air), r8d = z, r9 = TREE*
; -----------------------------------------------------------------------------
%define GB_X        0
%define GB_Y        4
%define GB_Z        8
%define GB_H        12
%define GB_R0       16
%define GB_R        20
%define GB_RI       24
%define GB_YI       28
%define GB_N        32
%define GB_PX       36
%define GB_PY       40
%define GB_PZ       44
%define GB_L        48
%define GB_DIR      52
%define GB_LOCALS   64
PROC gen_baobab, GB_LOCALS, rsi, r12, r13
    mov rsi, r9
    mov [LOCAL(GB_X)], ecx
    mov [LOCAL(GB_Y)], edx
    mov [LOCAL(GB_Z)], r8d
    mov ecx, [rsi + TREE.height]
    mov edx, [rsi + TREE.height + 4]
    call rand_int
    mov [LOCAL(GB_H)], eax
    call rng
    movss xmm1, [rsi + TREE.base_r + 4]
    subss xmm1, [rsi + TREE.base_r]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.base_r]
    movss [LOCAL(GB_R0)], xmm1
    mov dword [LOCAL(GB_YI)], -1
.disc:
    mov eax, [LOCAL(GB_YI)]
    cmp eax, [LOCAL(GB_H)]
    jge .branches
    ; t = y / H; f = 1 + 0.15 * sin-ish bulge: 1 + 0.6 t (1 - t) * ... ->
    ; f = 1 + 0.6 t - 1.0 t^2 (1.0 at 0, ~1.09 at 0.3, 0.6 at 1)
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    cvtsi2ss xmm0, eax
    cvtsi2ss xmm1, dword [LOCAL(GB_H)]
    divss xmm0, xmm1                    ; t
    movss xmm1, xmm0
    mulss xmm1, xmm0                    ; t^2
    mulss xmm0, [rel c_bb_lin]
    addss xmm0, [rel c_one]
    subss xmm0, xmm1
    mulss xmm0, [LOCAL(GB_R0)]
    movss [LOCAL(GB_R)], xmm0
    addss xmm0, [rel c_half]
    cvttss2si eax, xmm0
    mov [LOCAL(GB_RI)], eax
    mov r12d, eax
    neg r12d
.dz:
    mov r13d, [LOCAL(GB_RI)]
    neg r13d
.dx:
    mov eax, r13d
    imul eax, eax
    mov ecx, r12d
    imul ecx, ecx
    add eax, ecx
    cvtsi2ss xmm0, eax
    movss xmm1, [LOCAL(GB_R)]
    mulss xmm1, xmm1
    addss xmm1, [rel c_g_disc]
    comiss xmm0, xmm1
    ja .dx_next
    mov ecx, [LOCAL(GB_X)]
    add ecx, r13d
    mov edx, [LOCAL(GB_Y)]
    add edx, [LOCAL(GB_YI)]
    mov r8d, [LOCAL(GB_Z)]
    add r8d, r12d
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
.dx_next:
    inc r13d
    cmp r13d, [LOCAL(GB_RI)]
    jle .dx
    inc r12d
    cmp r12d, [LOCAL(GB_RI)]
    jle .dz
    inc dword [LOCAL(GB_YI)]
    jmp .disc
.branches:
    mov ecx, [rsi + TREE.branches]
    mov edx, [rsi + TREE.branches + 4]
    call rand_int
    mov [LOCAL(GB_N)], eax
.branch:
    cmp dword [LOCAL(GB_N)], 0
    jle .done
    dec dword [LOCAL(GB_N)]
    mov ecx, 0
    mov edx, 7
    call rand_int
    mov [LOCAL(GB_DIR)], eax
    ; start at the top rim
    movss xmm0, [LOCAL(GB_R0)]
    mulss xmm0, [rel c_bb_top]
    cvttss2si r8d, xmm0
    lea rcx, [rel dir_step]
    movsx edx, byte [rcx + rax * 2]
    imul edx, r8d
    add edx, [LOCAL(GB_X)]
    mov [LOCAL(GB_PX)], edx
    movsx edx, byte [rcx + rax * 2 + 1]
    imul edx, r8d
    add edx, [LOCAL(GB_Z)]
    mov [LOCAL(GB_PZ)], edx
    mov eax, [LOCAL(GB_Y)]
    add eax, [LOCAL(GB_H)]
    dec eax
    mov [LOCAL(GB_PY)], eax
    mov ecx, 2
    mov edx, 4
    call rand_int
    mov [LOCAL(GB_L)], eax
.step:
    cmp dword [LOCAL(GB_L)], 0
    jle .tuft
    dec dword [LOCAL(GB_L)]
    inc dword [LOCAL(GB_PY)]
    ; outward every second step
    test dword [LOCAL(GB_L)], 1
    jz .put
    mov eax, [LOCAL(GB_DIR)]
    lea rcx, [rel dir_step]
    movsx edx, byte [rcx + rax * 2]
    add [LOCAL(GB_PX)], edx
    movsx edx, byte [rcx + rax * 2 + 1]
    add [LOCAL(GB_PZ)], edx
.put:
    mov ecx, [LOCAL(GB_PX)]
    mov edx, [LOCAL(GB_PY)]
    mov r8d, [LOCAL(GB_PZ)]
    mov r9d, [rsi + TREE.log]
    mov r10d, PUT_LOG
    call put_block
    jmp .step
.tuft:
    call rng
    movss xmm1, [rsi + TREE.radius + 4]
    subss xmm1, [rsi + TREE.radius]
    mulss xmm1, xmm0
    addss xmm1, [rsi + TREE.radius]
    movss xmm0, xmm1
    mov ecx, [LOCAL(GB_PX)]
    mov edx, [LOCAL(GB_PY)]
    inc edx
    mov r8d, [LOCAL(GB_PZ)]
    movss xmm1, [rel c_bush_down]
    movss xmm2, [rel c_bush_up]
    call blob
    jmp .branch
.done:
    RETURN
ENDPROC

section .rdata
c_pad_top:      dd 1.3
c_bb_lin:       dd 0.6
c_bb_top:       dd 0.6
; 8 directions as block steps (dx, dz)
dir_step:       db 1, 0,  1, 1,  0, 1,  -1, 1,  -1, 0,  -1, -1,  0, -1,  1, -1
