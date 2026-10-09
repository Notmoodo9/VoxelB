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

%define POND_CELL       128
%define POND_MAX_R      6.0
%define MEADOW_SHIFT    9               ; 512-block meadow cells
%define TREE_CELL_SHIFT 2               ; 4-block tree cells

; leaf and log placement modes (put_block)
%define PUT_LEAVES      0
%define PUT_LOG         1
%define PUT_PLANT       2

section .rdata
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
c_edge:         dd 0.55                 ; crown: leaves beyond this may drop
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
; 8 directions (cos, sin) for pond axes and branches
dirs:           dd 1.0, 0.0,  0.7071, 0.7071,  0.0, 1.0,  -0.7071, 0.7071
                dd -1.0, 0.0,  -0.7071, -0.7071,  0.0, -1.0,  0.7071, -0.7071

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
    imul eax, eax, 96
    shr eax, 8
    add eax, 16
    mov ecx, [LOCAL(FP_CX)]
    imul ecx, ecx, POND_CELL
    add eax, ecx
    mov ecx, [rbx + FCTX.cx]
    shl ecx, 5
    sub eax, ecx                        ; local x
    mov [LOCAL(FP_X)], eax
    mov eax, [LOCAL(FP_H)]
    shr eax, 24
    imul eax, eax, 96
    shr eax, 8
    add eax, 16
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
    ; on land, above the beach
    mov ecx, [LOCAL(FP_X)]
    mov edx, [LOCAL(FP_Z)]
    HM_INDEX ecx, edx
    mov rcx, [rbx + FCTX.heights]
    mov eax, [rcx + rax * 4]
    dec eax
    cmp eax, [rel g_beach_high]
    jle .next_cell
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
    cmp eax, 3
    jg .next_cell
    mov eax, [LOCAL(FP_MIN)]
    dec eax                             ; water level: the lowest rim top
    cmp eax, [rel g_sea_level]
    jle .next_cell
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
    lea ecx, [r12d + ecx + 3]
    mov [rdi + CAND.ytop], ecx
    cmp ecx, [rbx + FCTX.top]
    jle .counted
    mov [rbx + FCTX.top], ecx
.counted:
    inc dword [rbx + FCTX.ncand]
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
%define DP_LOCALS   32
PROC decide_plant, DP_LOCALS, rbx, rsi
    mov [LOCAL(DP_X)], ecx
    mov [LOCAL(DP_Z)], edx
    movss [LOCAL(DP_D)], xmm0
    mov rbx, r8
    cmp dword [rbx + BIOME.nflowers], 0
    je .cover
    ; ---- meadow (one candidate per 512 x 512 cell) ----
    xorps xmm0, xmm0
    comiss xmm0, [rbx + BIOME.meadow_ch]
    jae .clusters
    mov ecx, [LOCAL(DP_X)]
    sar ecx, MEADOW_SHIFT
    mov edx, [LOCAL(DP_Z)]
    sar edx, MEADOW_SHIFT
    mov r8d, 0x4D45                     ; "ME"
    xor r9d, r9d
    call hash4
    mov [LOCAL(DP_HM)], eax
    FRAC16 ax
    comiss xmm0, [rbx + BIOME.meadow_ch]
    jae .clusters
    mov ecx, [LOCAL(DP_X)]
    sar ecx, MEADOW_SHIFT
    mov edx, [LOCAL(DP_Z)]
    sar edx, MEADOW_SHIFT
    mov r8d, 0x4D5A                     ; "MZ"
    xor r9d, r9d
    call hash4
    mov [LOCAL(DP_HM2)], eax
    ; centre 64 .. 448 inside the cell
    mov eax, [LOCAL(DP_HM)]
    shr eax, 16
    and eax, 0xFF
    imul eax, eax, 384
    shr eax, 8
    add eax, 64
    mov ecx, [LOCAL(DP_X)]
    and ecx, (1 << MEADOW_SHIFT) - 1
    sub ecx, eax                        ; dx
    mov eax, [LOCAL(DP_HM)]
    shr eax, 24
    imul eax, eax, 384
    shr eax, 8
    add eax, 64
    mov edx, [LOCAL(DP_Z)]
    and edx, (1 << MEADOW_SHIFT) - 1
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
    div dword [rbx + BIOME.nflowers]
    mov eax, [rbx + BIOME.flower + rdx * 4]
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
%define FS_LOCALS   16
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
    movzx ecx, word [rsi + INFO_TOP]
    cmp ecx, [rel g_b_top]
    jne .pnext
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
    ; decide
    mov ecx, [rbx + FCTX.cx]
    shl ecx, 5
    add ecx, r13d
    mov edx, [rbx + FCTX.cz]
    shl edx, 5
    add edx, r12d
    movzx eax, byte [rsi + INFO_BIOME]
    imul r8, rax, BIOME_size
    lea rax, [rel g_biomes]
    add r8, rax
    movzx eax, byte [rsi + INFO_DENS]
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv255]
    call decide_plant
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
    cmp eax, [rel g_b_top]
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
    add eax, 31
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
%define SVF_COUNTS  64                  ; u32[MAX_BIOMES]
%define SVF_S       (64 + MAX_BIOMES * 4)
%define SVF_LOCALS  (SVF_S + TSAMPLE_size)
%define SVF_GRID    64                  ; samples per side, every 64 blocks
PROC flora_survey, SVF_LOCALS, rbx, rsi, rdi, r12, r13
    lea rdi, [LOCAL(SVF_COUNTS)]
    xor eax, eax
    mov ecx, MAX_BIOMES
    rep stosd
    mov dword [LOCAL(SVF_LAND)], 0
    mov dword [LOCAL(SVF_MD)], 0x7FFFFFFF
    mov dword [LOCAL(SVF_PD)], 0x7FFFFFFF
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
    jle .gnext
    inc dword [LOCAL(SVF_LAND)]
    inc dword [LOCAL(SVF_COUNTS) + rax * 4]
.gnext:
    inc r13d
    cmp r13d, SVF_GRID
    jb .gx
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
    imul eax, eax, 96
    shr eax, 8
    add eax, 16
    mov ecx, r13d
    imul ecx, ecx, POND_CELL
    add eax, ecx
    mov [LOCAL(SVF_X)], eax
    mov eax, [LOCAL(SVF_HASH)]
    shr eax, 24
    imul eax, eax, 96
    shr eax, 8
    add eax, 16
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
    RETURN

; sample_biome — biome (no blending) and height at [SVF_X], [SVF_Z]
;   out: eax = biome, edx = height   (inner call: locals +8)
sample_biome:
    sub rsp, 40
    cvtsi2sd xmm0, dword [LOCAL(SVF_X) + 48]
    cvtsi2sd xmm1, dword [LOCAL(SVF_Z) + 48]
    call biome_climate
    movss [LOCAL(SVF_T) + 48], xmm0
    movss [LOCAL(SVF_H) + 48], xmm1
    cvtsi2sd xmm0, dword [LOCAL(SVF_X) + 48]
    cvtsi2sd xmm1, dword [LOCAL(SVF_Z) + 48]
    lea rcx, [LOCAL(SVF_S) + 48]
    call terrain_sample
    cvttss2si ecx, [LOCAL(SVF_S) + 48 + TSAMPLE.height]
    mov [LOCAL(SVF_GX) + 48], ecx
    movss xmm0, [LOCAL(SVF_T) + 48]
    movss xmm1, [LOCAL(SVF_H) + 48]
    call biome_pick
    mov edx, [LOCAL(SVF_GX) + 48]
    add rsp, 40
    ret
ENDPROC

section .rdata
s_sv_biome:     db "survey: biome ", 0
s_sv_sp:        db " ", 0
s_sv_meadow:    db "survey: nearest flower meadow centre at", 0
s_sv_pond:      db "survey: nearest pond centre at", 0
