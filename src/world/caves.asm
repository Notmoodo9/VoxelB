; =============================================================================
; caves.asm — caves, ravines, shafts, aquifers, lava, cave decoration and
; ores (design/terrain/underground.md). Settings: data/world/caves.cfg and
; data/world/ores.cfg (parsed by terrain.asm).
;
; Called by terrain_gen_column for every column / section:
;   caves_column(CAVECTX*)            per-column 2D data: crust, sky caverns,
;                                     pillars, ravines, shafts, fluid levels
;   caves_grid(CAVECTX*, y0) -> eax   3D cave fields on a 9x9x9 grid
;                                     (every 4 blocks); 1 if any cave may
;                                     touch the section
;   caves_profile(CAVECTX*, x, z)    cave fields of one block column at the 9
;                                     grid heights (bilinear), for the caller's
;                                     fast per-block test
;   caves_carve(CAVECTX*, x, wy, z, ly) -> eax
;                                     -1 = keep the block, else the id that
;                                     replaces it (0 air, water, lava)
;   caves_finish(CAVECTX*, ids, y0, sy)  ores, dripstone, floor patches
;
; Cave shapes:
;   caverns   "cheese": cavern noise above a height-dependent threshold
;             (spline cavern_threshold; lower deeper = bigger caverns),
;             except inside natural pillars
;   tunnels   where two 3D noise fields are both near zero (a curve)
;   passages  the same with narrower width (Y -200 .. 80)
;   shafts    round vertical pipes, at most one per shaft_spacing cell
;   ravines   2D lines inside a rare mask, carved from the surface down,
;             narrowing with depth
;   Normal caves stay `cave_crust` blocks below the surface except where the
;   entrance field allows them to break through, and inside the rare sky
;   caverns: an open bowl from the surface down to sky_cavern_depth (scaled
;   by the mask), over caverns with a lowered threshold.
; Fluids: aquifer regions (aquifer_size blocks) hold an optional lake level
; and a lava level; caves below a level fill with water / lava. Caves under
; the sea (surface at or below sea level + 3) flood up to sea level.
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "noise.inc"
%include "block.inc"
%include "terrain.inc"
%define CAVES_IMPL
%include "caves.inc"

global caves_column, caves_grid, caves_carve, caves_finish, caves_profile
global caves_survey

extern terrain_sample, log_xz
extern g_noise, g_splines, g_ores, g_ore_count, spline_eval
extern g_world_seed, g_sea_level
extern g_tunnel_w, g_pass_w, g_crust, g_entr_thr, g_sky_thr, g_sky_depth, g_sky_open
extern g_rav_thr, g_rav_w, g_rav_dmin, g_rav_dmax, g_shaft_space, g_shaft_chance
extern g_shaft_rmin, g_shaft_rmax
extern g_shaft_dmin, g_shaft_dmax, g_aq_size, g_lake_chance, g_lake_min, g_lake_max
extern g_lava_top, g_lava_min, g_lava_max, g_drip_chance, g_patch_thr, g_pillar_w
extern g_cave_bottom, g_ore_wall, g_b_lava, g_b_drip, g_b_mud, g_b_water, g_b_stone
extern g_b_deep, g_b_gravel, g_b_clay, g_is_strata

; field indices (match terrain.asm)
%define F_DETAIL        9
%define F_CHEESE        11
%define F_TUN_A         12
%define F_TUN_B         13
%define F_PASS_A        14
%define F_PASS_B        15
%define F_PILLAR        16
%define F_ENTRANCE      17
%define F_SKY           18
%define F_RAVINE        19
%define F_RAVINE_MASK   20
%define S_CHEESE        6
%define SPLINE_BYTES    132             ; SPLINE_size in terrain.asm

%define NOISE_AT(f)     (g_noise + (f) * NOISE_size)
%define G9              9               ; grid points along x and z (every 4)
%define GY              5               ; grid points along y (every 8)
%define GRID_N          (G9 * GY * G9)

section .rdata
align 4
nb_dx:          db -1, 1, 0, 0
nb_dz:          db 0, 0, -1, 1
align 4
c_one:          dd 1.0
c_two:          dd 2.0
c_big:          dd 1000.0
c_quarter:      dd 0.25
c_cheese_y:     dd 1.6              ; caverns are flatter than they are wide
c_sky_ramp:     dd 12.5             ; sky mask: (n - threshold) * this
c_inv65536:     dd 0.0000152587890625
c_pass_top:     dd 80.0
c_pass_bottom:  dd -200.0
align 8
c_cheese_y_d:   dq 1.6

section .text

; -----------------------------------------------------------------------------
; hash4 — 32-bit hash of four integers.
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

; -----------------------------------------------------------------------------
; floordiv — eax = floor(eax / ecx)        clobbers: rax, rdx
; -----------------------------------------------------------------------------
floordiv:
    cdq
    idiv ecx
    test edx, edx
    jns .ok
    dec eax
.ok:
    ret

; -----------------------------------------------------------------------------
; shaft_cell — the shaft of a cell of shaft_spacing x shaft_spacing blocks.
;   in:  ecx = cell x, edx = cell z
;   out: eax = 1 if the cell has a shaft: then r8d / r9d = centre x / z,
;        xmm0 = radius^2, r11d = depth
;   clobbers: rax, rcx, rdx, r8-r11, xmm0, xmm1
; -----------------------------------------------------------------------------
shaft_cell:
    push rbx
    push rsi
    push rdi
    mov ebx, ecx
    mov esi, edx
    mov r8d, 0x5348                     ; "SH"
    xor r9d, r9d
    call hash4
    mov r11d, eax
    mov ecx, ebx
    mov edx, esi
    mov r8d, 0x5352                     ; "SR"
    xor r9d, r9d
    call hash4
    mov edi, eax
    mov eax, r11d
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv65536]
    comiss xmm0, [rel g_shaft_chance]
    jae .none
    ; centre: 4 .. spacing - 5 inside the cell
    mov eax, [rel g_shaft_space]
    sub eax, 8
    mov ecx, r11d
    shr ecx, 16
    and ecx, 0xFF
    imul eax, ecx
    shr eax, 8
    add eax, 4
    mov r8d, ebx
    imul r8d, [rel g_shaft_space]
    add r8d, eax
    mov eax, [rel g_shaft_space]
    sub eax, 8
    mov ecx, r11d
    shr ecx, 24
    imul eax, ecx
    shr eax, 8
    add eax, 4
    mov r9d, esi
    imul r9d, [rel g_shaft_space]
    add r9d, eax
    ; radius^2
    mov eax, edi
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv65536]
    movss xmm1, [rel g_shaft_rmax]
    subss xmm1, [rel g_shaft_rmin]
    mulss xmm0, xmm1
    addss xmm0, [rel g_shaft_rmin]
    mulss xmm0, xmm0
    ; depth
    mov eax, edi
    shr eax, 16
    mov ecx, [rel g_shaft_dmax]
    sub ecx, [rel g_shaft_dmin]
    inc ecx
    xor edx, edx
    div ecx
    mov r11d, edx
    add r11d, [rel g_shaft_dmin]
    mov eax, 1
    jmp .out
.none:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rbx
    ret

; -----------------------------------------------------------------------------
; region_levels — fluid levels of the aquifer region holding (x, z).
;   in:  eax = world x, ecx = world z
;   out: eax = lake level (-32000 = no lake), edx = lava level
;   clobbers: rax, rcx, rdx, r8-r11, xmm0
; -----------------------------------------------------------------------------
region_levels:
    push rbx
    push rsi
    mov ebx, ecx
    mov ecx, [rel g_aq_size]
    call floordiv
    mov r11d, eax                       ; region x
    mov eax, ebx
    mov ecx, [rel g_aq_size]
    call floordiv
    mov ebx, eax                        ; region z
    mov ecx, r11d
    mov edx, ebx
    mov r8d, 0x4C41                     ; "LA": lake salt
    xor r9d, r9d
    call hash4
    mov esi, -32000
    mov r8d, eax
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv65536]
    comiss xmm0, [rel g_lake_chance]
    jae .no_lake
    mov eax, r8d
    shr eax, 16
    mov ecx, [rel g_lake_max]
    sub ecx, [rel g_lake_min]
    inc ecx
    xor edx, edx
    div ecx
    mov esi, edx
    add esi, [rel g_lake_min]
.no_lake:
    mov ecx, r11d
    mov edx, ebx
    mov r8d, 0x4C56                     ; "LV": lava salt
    xor r9d, r9d
    call hash4
    mov ecx, [rel g_lava_max]
    sub ecx, [rel g_lava_min]
    inc ecx
    xor edx, edx
    div ecx
    add edx, [rel g_lava_min]
    mov eax, esi
    pop rsi
    pop rbx
    ret

; -----------------------------------------------------------------------------
; fluid_at — what an open cave cell at height esi holds.
;   in:  esi = world y, r8d = lake level, r9d = lava level, r10d = flooded
;   out: eax = 0 air, 1 water, 2 lava      clobbers: rax
; -----------------------------------------------------------------------------
fluid_at:
    cmp esi, [rel g_lava_top]
    jg .not_lava
    cmp esi, r9d
    jg .not_lava
    mov eax, 2
    ret
.not_lava:
    cmp esi, r8d
    jle .water
    test r10d, r10d
    jz .air
    cmp esi, [rel g_sea_level]
    jle .water
.air:
    xor eax, eax
    ret
.water:
    mov eax, 1
    ret

; fbm2 at world (eax = x, ecx = z) of field f -> xmm0     (macro)
%macro FIELD2 1
    cvtsi2sd xmm1, eax
    cvtsi2sd xmm2, ecx
    lea rcx, [rel NOISE_AT(%1)]
    mov edx, [rel g_world_seed]
    call fbm2
%endmacro

; -----------------------------------------------------------------------------
; caves_column — per-column 2D cave data for the 32x32 columns.
;   in:  rcx = CAVECTX* (cx, cz, heights, cols set)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define CC_X        0
%define CC_Z        4
%define CC_WX       8
%define CC_WZ       12
%define CC_H        16
PROC caves_column, 32, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    mov dword [rbx + CAVECTX.columns_special], 0
    mov eax, [rbx + CAVECTX.cx]
    shl eax, 5
    mov [rbx + CAVECTX.cx_blocks], eax
    mov eax, [rbx + CAVECTX.cz]
    shl eax, 5
    mov [rbx + CAVECTX.cz_blocks], eax
    xor r12d, r12d                      ; z
.z:
    xor r13d, r13d                      ; x
.x:
    mov [LOCAL(CC_X)], r13d
    mov [LOCAL(CC_Z)], r12d
    mov eax, [rbx + CAVECTX.cx]
    shl eax, 5
    add eax, r13d
    mov [LOCAL(CC_WX)], eax
    mov eax, [rbx + CAVECTX.cz]
    shl eax, 5
    add eax, r12d
    mov [LOCAL(CC_WZ)], eax
    ; surface height H
    lea eax, [r12d + HB]
    imul eax, eax, HM
    lea eax, [eax + r13d + HB]
    mov rcx, [rbx + CAVECTX.heights]
    mov eax, [rcx + rax * 4]
    mov [LOCAL(CC_H)], eax
    ; column record
    mov edi, r12d
    shl edi, 5
    add edi, r13d
    imul rdi, rdi, CCOL_size
    add rdi, [rbx + CAVECTX.cols]

    ; crust: caves stay this far below the surface, unless an entrance
    mov eax, [LOCAL(CC_H)]
    sub eax, [rel g_crust]
    mov [rdi + CCOL.crust_top], eax
    mov eax, [LOCAL(CC_WX)]
    mov ecx, [LOCAL(CC_WZ)]
    FIELD2 F_ENTRANCE
    comiss xmm0, [rel g_entr_thr]
    jbe .no_entrance
    mov eax, [LOCAL(CC_H)]
    mov [rdi + CCOL.crust_top], eax
.no_entrance:
    ; sky caverns: mask 0..1, open to the sky
    mov eax, [LOCAL(CC_WX)]
    mov ecx, [LOCAL(CC_WZ)]
    FIELD2 F_SKY
    subss xmm0, [rel g_sky_thr]
    mulss xmm0, [rel c_sky_ramp]
    xorps xmm1, xmm1
    maxss xmm0, xmm1
    minss xmm0, [rel c_one]
    movss [rdi + CCOL.sky], xmm0
    comiss xmm0, xmm1
    jbe .no_sky
    mov eax, [LOCAL(CC_H)]
    mov [rdi + CCOL.crust_top], eax
    mov dword [rbx + CAVECTX.columns_special], 1
.no_sky:
    ; natural pillars (blobs of the pillar field)
    mov eax, [LOCAL(CC_WX)]
    mov ecx, [LOCAL(CC_WZ)]
    FIELD2 F_PILLAR
    xor eax, eax
    comiss xmm0, [rel g_pillar_w]
    seta al
    mov [rdi + CCOL.pillar], al
    ; flooded below the sea?
    mov eax, [rel g_sea_level]
    add eax, 3
    xor ecx, ecx
    cmp [LOCAL(CC_H)], eax
    setle cl
    mov [rdi + CCOL.flooded], cl
    ; floor patch: gravel / clay / mud from the detail field
    mov word [rdi + CCOL.patch], 0
    mov eax, [LOCAL(CC_WX)]
    mov ecx, [LOCAL(CC_WZ)]
    FIELD2 F_DETAIL
    movss xmm1, xmm0
    andps xmm1, [rel c_abs]
    comiss xmm1, [rel g_patch_thr]
    jbe .no_patch
    mov eax, [rel g_b_gravel]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    ja .patch_set
    mov eax, [rel g_b_clay]
    comiss xmm0, [rel c_patch_mud]
    ja .patch_set
    mov eax, [rel g_b_mud]
.patch_set:
    mov [rdi + CCOL.patch], ax
.no_patch:
    ; ravine
    mov dword [rdi + CCOL.ravine_depth], 0
    mov eax, [LOCAL(CC_WX)]
    mov ecx, [LOCAL(CC_WZ)]
    FIELD2 F_RAVINE_MASK
    comiss xmm0, [rel g_rav_thr]
    jbe .no_ravine
    ; depth grows with the mask: dmin .. dmax over mask threshold .. +0.15
    subss xmm0, [rel g_rav_thr]
    mulss xmm0, [rel c_depth_ramp]
    minss xmm0, [rel c_one]
    mov eax, [rel g_rav_dmax]
    sub eax, [rel g_rav_dmin]
    cvtsi2ss xmm1, eax
    mulss xmm0, xmm1
    cvttss2si eax, xmm0
    add eax, [rel g_rav_dmin]
    mov [rdi + CCOL.ravine_depth], eax
    mov eax, [LOCAL(CC_WX)]
    mov ecx, [LOCAL(CC_WZ)]
    FIELD2 F_RAVINE
    andps xmm0, [rel c_abs]
    divss xmm0, [rel g_rav_w]
    movss [rdi + CCOL.ravine_ratio], xmm0
    mov dword [rbx + CAVECTX.columns_special], 1
.no_ravine:
    ; shaft: a round pipe in this column's cell?
    mov dword [rdi + CCOL.shaft_top], -100000
    mov dword [rdi + CCOL.shaft_bottom], 100000
    mov eax, [LOCAL(CC_WX)]
    mov ecx, [rel g_shaft_space]
    call floordiv
    mov esi, eax
    mov eax, [LOCAL(CC_WZ)]
    mov ecx, [rel g_shaft_space]
    call floordiv
    mov edx, eax
    mov ecx, esi
    call shaft_cell
    test eax, eax
    jz .no_shaft
    mov eax, [LOCAL(CC_WX)]
    sub eax, r8d
    imul eax, eax
    mov ecx, [LOCAL(CC_WZ)]
    sub ecx, r9d
    imul ecx, ecx
    add eax, ecx
    cvtsi2ss xmm1, eax
    comiss xmm1, xmm0
    ja .no_shaft                        ; outside the radius
    mov eax, [LOCAL(CC_H)]
    dec eax
    mov [rdi + CCOL.shaft_top], eax
    sub eax, r11d
    mov [rdi + CCOL.shaft_bottom], eax
    mov dword [rbx + CAVECTX.columns_special], 1
.no_shaft:
    ; aquifer region: optional lake level, lava level
    mov eax, [LOCAL(CC_WX)]
    mov ecx, [LOCAL(CC_WZ)]
    call region_levels
    xorps xmm0, xmm0
    comiss xmm0, [rdi + CCOL.sky]
    jae .lake_ok
    mov eax, -32000                     ; no lakes in sky cavern bowls
.lake_ok:
    mov [rdi + CCOL.water_level], ax
    mov [rdi + CCOL.lava_level], dx

    inc r13d
    cmp r13d, 32
    jb .x
    inc r12d
    cmp r12d, 32
    jb .z

    ; side ring: the 4 x 32 columns just outside the chunk (records 1024 +
    ; side * 32 + i; sides -X +X -Z +Z), for caves_carve's aquifer barrier
    xor r12d, r12d
.ring:
    mov eax, r12d
    and eax, 31                         ; i
    mov ecx, r12d
    shr ecx, 5                          ; side
    mov edx, -1
    mov r8d, 32
    cmp ecx, 1
    cmove edx, r8d
    cmp ecx, 2
    jae .ring_z
    mov [LOCAL(CC_X)], edx              ; x side: (-1 or 32, i)
    mov [LOCAL(CC_Z)], eax
    jmp .ring_have
.ring_z:
    cmp ecx, 3
    cmove edx, r8d
    mov [LOCAL(CC_X)], eax              ; z side: (i, -1 or 32)
    mov [LOCAL(CC_Z)], edx
.ring_have:
    lea edi, [r12 + 1024]
    imul rdi, rdi, CCOL_size
    add rdi, [rbx + CAVECTX.cols]
    mov eax, [LOCAL(CC_Z)]
    add eax, HB
    imul eax, eax, HM
    add eax, [LOCAL(CC_X)]
    add eax, HB
    mov rcx, [rbx + CAVECTX.heights]
    mov eax, [rcx + rax * 4]
    mov ecx, [rel g_sea_level]
    add ecx, 3
    xor edx, edx
    cmp eax, ecx
    setle dl
    mov [rdi + CCOL.flooded], dl
    mov eax, [rbx + CAVECTX.cx_blocks]
    add eax, [LOCAL(CC_X)]
    mov [LOCAL(CC_WX)], eax
    mov ecx, [rbx + CAVECTX.cz_blocks]
    add ecx, [LOCAL(CC_Z)]
    mov [LOCAL(CC_WZ)], ecx
    call region_levels
    mov [LOCAL(CC_H)], eax
    mov [rdi + CCOL.lava_level], dx
    mov eax, [LOCAL(CC_WX)]
    mov ecx, [LOCAL(CC_WZ)]
    FIELD2 F_SKY
    mov eax, [LOCAL(CC_H)]
    comiss xmm0, [rel g_sky_thr]
    jbe .ring_lake
    mov eax, -32000                     ; no lakes in sky cavern bowls
.ring_lake:
    mov [rdi + CCOL.water_level], ax
    inc r12d
    cmp r12d, 128
    jb .ring
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; caves_grid — cave fields on a 9x5x9 grid (x, z every 4 blocks, y every 8)
; plus the cavern threshold per local y.
;   in:  rcx = CAVECTX*, edx = section y0
;   out: eax = 1 if a cave may touch this section (or a ravine/shaft/sky
;        column passes through it), 0 if carving can be skipped
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define GR_X        0
%define GR_Y        4
%define GR_Z        8
%define GR_I        12
%define GR_A        16
%define GR_B        20
%define GR_MAXC     24
%define GR_MINT     28
%define GR_MINTHR   32
PROC caves_grid, 48, rbx, rsi, rdi, r12, r13, r14
    mov rbx, rcx
    mov [rbx + CAVECTX.y0], edx
    ; thresholds per local y
    mov dword [LOCAL(GR_MINTHR)], 0x7F7FFFFF
    xor esi, esi
.thr:
    mov eax, [rbx + CAVECTX.y0]
    add eax, esi
    cvtsi2ss xmm0, eax
    lea rcx, [rel g_splines + S_CHEESE * SPLINE_BYTES]
    call spline_eval
    movss [rbx + CAVECTX.thr + rsi * 4], xmm0
    minss xmm0, [LOCAL(GR_MINTHR)]
    movss [LOCAL(GR_MINTHR)], xmm0
    inc esi
    cmp esi, 32
    jb .thr
    ; grid
    mov dword [LOCAL(GR_MAXC)], 0xFF7FFFFF
    mov dword [LOCAL(GR_MINT)], 0x7F7FFFFF
    xor r12d, r12d                      ; index
    xor r13d, r13d                      ; gz
.gz:
    xor r14d, r14d                      ; gy
.gy:
    xor esi, esi                        ; gx
.gx:
    mov eax, [rbx + CAVECTX.cx]
    shl eax, 5
    lea eax, [eax + esi * 4]
    mov [LOCAL(GR_X)], eax
    mov eax, [rbx + CAVECTX.y0]
    lea eax, [eax + r14d * 8]
    mov [LOCAL(GR_Y)], eax
    mov eax, [rbx + CAVECTX.cz]
    shl eax, 5
    lea eax, [eax + r13d * 4]
    mov [LOCAL(GR_Z)], eax
    ; cavern (y squashed: flatter caverns)
    cvtsi2sd xmm1, dword [LOCAL(GR_X)]
    cvtsi2sd xmm2, dword [LOCAL(GR_Y)]
    mulsd xmm2, [rel c_cheese_y_d]
    cvtsi2sd xmm3, dword [LOCAL(GR_Z)]
    lea rcx, [rel NOISE_AT(F_CHEESE)]
    mov edx, [rel g_world_seed]
    call fbm3
    mov rax, [rbx + CAVECTX.grid_c]
    movss [rax + r12 * 4], xmm0
    maxss xmm0, [LOCAL(GR_MAXC)]
    movss [LOCAL(GR_MAXC)], xmm0
    ; tunnels: sqrt(a^2 + b^2) - width
%macro FIELD3 2                         ; field, dest local
    cvtsi2sd xmm1, dword [LOCAL(GR_X)]
    cvtsi2sd xmm2, dword [LOCAL(GR_Y)]
    cvtsi2sd xmm3, dword [LOCAL(GR_Z)]
    lea rcx, [rel NOISE_AT(%1)]
    mov edx, [rel g_world_seed]
    call fbm3
    movss [LOCAL(%2)], xmm0
%endmacro
    FIELD3 F_TUN_A, GR_A
    FIELD3 F_TUN_B, GR_B
    movss xmm0, [LOCAL(GR_A)]
    mulss xmm0, xmm0
    movss xmm1, [LOCAL(GR_B)]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    subss xmm0, [rel g_tunnel_w]
    movss [LOCAL(GR_I)], xmm0           ; (reuse as T)
    ; passages only between their heights
    cvtsi2ss xmm1, dword [LOCAL(GR_Y)]
    comiss xmm1, [rel c_pass_top]
    ja .no_pass
    comiss xmm1, [rel c_pass_bottom]
    jb .no_pass
    FIELD3 F_PASS_A, GR_A
    FIELD3 F_PASS_B, GR_B
    movss xmm0, [LOCAL(GR_A)]
    mulss xmm0, xmm0
    movss xmm1, [LOCAL(GR_B)]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    subss xmm0, [rel g_pass_w]
    minss xmm0, [LOCAL(GR_I)]
    movss [LOCAL(GR_I)], xmm0
.no_pass:
    movss xmm0, [LOCAL(GR_I)]
    mov rax, [rbx + CAVECTX.grid_t]
    movss [rax + r12 * 4], xmm0
    minss xmm0, [LOCAL(GR_MINT)]
    movss [LOCAL(GR_MINT)], xmm0
    inc r12d
    inc esi
    cmp esi, G9
    jb .gx
    inc r14d
    cmp r14d, GY
    jb .gy
    inc r13d
    cmp r13d, G9
    jb .gz
    ; any cave? (interpolation stays within the grid's range)
    movss xmm0, [LOCAL(GR_MAXC)]
    addss xmm0, [rel g_sky_open]        ; sky caverns lower the threshold
    comiss xmm0, [LOCAL(GR_MINTHR)]
    ja .yes
    xorps xmm0, xmm0
    comiss xmm0, [LOCAL(GR_MINT)]
    ja .yes
    ; ravines and shafts are column features: always carve-check them
    mov eax, [rbx + CAVECTX.columns_special]
    test eax, eax
    jnz .yes
    xor eax, eax
    RETURN
.yes:
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; caves_profile — bilinear cave fields of the block column (x, z) at the 5
; grid heights (every 8 blocks), into CAVECTX.colc / colt; and whether the column has a
; ravine, shaft or sky cavern (CAVECTX.col_special).
;   in:  rcx = CAVECTX*, edx = x, r8d = z (0..31)
;   clobbers: rax, rcx, rdx, r8-r11, xmm0-xmm5
; -----------------------------------------------------------------------------
caves_profile:
    ; special column?
    mov eax, r8d
    shl eax, 5
    add eax, edx
    imul r9, rax, CCOL_size
    add r9, [rcx + CAVECTX.cols]
    xor eax, eax
    cmp dword [r9 + CCOL.ravine_depth], 0
    setne al
    mov r10d, [r9 + CCOL.shaft_top]
    cmp r10d, [r9 + CCOL.shaft_bottom]
    jl .no_shaft
    or eax, 1
.no_shaft:
    xorps xmm0, xmm0
    comiss xmm0, [r9 + CCOL.sky]
    jae .no_sky
    or eax, 1
.no_sky:
    mov [rcx + CAVECTX.col_special], eax
    ; cell and fractions in x and z
    mov r10d, edx
    shr r10d, 2
    and edx, 3
    cvtsi2ss xmm3, edx
    mulss xmm3, [rel c_quarter]         ; fx
    mov r11d, r8d
    shr r11d, 2
    and r8d, 3
    cvtsi2ss xmm5, r8d
    mulss xmm5, [rel c_quarter]         ; fz
    ; base index of (x cell, y 0, z cell): (z * GY + 0) * 9 + x
    imul eax, r11d, G9 * GY
    add eax, r10d
    mov r8, [rcx + CAVECTX.grid_c]
    lea r8, [r8 + rax * 4]
    mov r9, [rcx + CAVECTX.grid_t]
    lea r9, [r9 + rax * 4]
    xor edx, edx                        ; gy
.gy:
%macro BIL 2                            ; dst, grid base register
    movss %1, [%2 + 4]
    subss %1, [%2]
    mulss %1, xmm3
    addss %1, [%2]                      ; z0 row
    movss xmm4, [%2 + G9 * GY * 4 + 4]
    subss xmm4, [%2 + G9 * GY * 4]
    mulss xmm4, xmm3
    addss xmm4, [%2 + G9 * GY * 4]      ; z1 row
    subss xmm4, %1
    mulss xmm4, xmm5
    addss %1, xmm4
%endmacro
    BIL xmm0, r8
    movss [rcx + CAVECTX.colc + rdx * 4], xmm0
    BIL xmm1, r9
    movss [rcx + CAVECTX.colt + rdx * 4], xmm1
    add r8, G9 * 4                      ; next grid height
    add r9, G9 * 4
    inc edx
    cmp edx, GY
    jb .gy
    ret

; -----------------------------------------------------------------------------
; caves_carve — is a solid block at local (x, ly, z) / world y a cave?
;   in:  rcx = CAVECTX*, edx = x, r8d = world y, r9d = z, ARG(5) = local y,
;        ARG(6) = surface height H of the column
;   out: eax = -1 keep, else the replacing id (0 air, water, lava)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define CV_FLUID    0
%define CV_N        4
PROC caves_carve, 16, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    mov r12d, edx                       ; x
    mov r13d, r9d                       ; z
    mov esi, r8d                        ; wy
    cmp esi, [rel g_cave_bottom]
    jle .keep
    mov eax, r13d
    shl eax, 5
    add eax, r12d
    imul rdi, rax, CCOL_size
    add rdi, [rbx + CAVECTX.cols]
    ; ravine: from the surface down, narrowing with depth
    mov ecx, [rdi + CCOL.ravine_depth]
    test ecx, ecx
    jz .no_ravine
    mov eax, [ARG(6)]
    sub eax, esi                        ; depth below the surface (>= 1)
    cmp eax, ecx
    jge .no_ravine
    cvtsi2ss xmm0, eax
    cvtsi2ss xmm1, ecx
    divss xmm0, xmm1
    movss xmm1, [rel c_one]
    subss xmm1, xmm0                    ; allowed ratio
    comiss xmm1, [rdi + CCOL.ravine_ratio]
    ja .cave
.no_ravine:
    ; shaft
    cmp esi, [rdi + CCOL.shaft_top]
    jg .no_shaft
    cmp esi, [rdi + CCOL.shaft_bottom]
    jge .cave
.no_shaft:
    ; sky cavern bowl: open from the surface down to depth * m * (2 - m)
    movss xmm0, [rdi + CCOL.sky]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .no_bowl
    movss xmm1, [rel c_two]
    subss xmm1, xmm0
    mulss xmm0, xmm1
    cvtsi2ss xmm1, dword [rel g_sky_depth]
    mulss xmm0, xmm1
    mov eax, [ARG(6)]
    sub eax, esi                        ; depth below the surface
    cvtsi2ss xmm1, eax
    comiss xmm1, xmm0
    jb .cave
.no_bowl:
    ; below the crust?
    cmp esi, [rdi + CCOL.crust_top]
    jg .keep
    cmp dword [rbx + CAVECTX.active], 0
    je .keep
    ; tunnels / passages (values interpolated by the caller)
    movss xmm0, [rbx + CAVECTX.cur_t]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jb .cave
    ; caverns (not inside pillars)
    cmp byte [rdi + CCOL.pillar], 0
    jne .keep
    movss xmm0, [rbx + CAVECTX.cur_c]
    mov eax, [ARG(5)]
    movss xmm1, [rbx + CAVECTX.thr + rax * 4]
    movss xmm2, [rdi + CCOL.sky]
    mulss xmm2, [rel g_sky_open]
    subss xmm1, xmm2
    comiss xmm0, xmm1
    ja .cave
.keep:
    mov eax, -1
    RETURN
.cave:
    ; fluid by level: lava, lake, sea flooding, else air
    movsx r8d, word [rdi + CCOL.water_level]
    movsx r9d, word [rdi + CCOL.lava_level]
    movzx r10d, byte [rdi + CCOL.flooded]
    call fluid_at
    mov [LOCAL(CV_FLUID)], eax
    ; aquifer barrier: where a side neighbour would hold another fluid at this
    ; height (regions with different levels, the coast), keep the rock, so
    ; water and lava never stand as walls against open air
    mov dword [LOCAL(CV_N)], 0
.nb:
    mov eax, [LOCAL(CV_N)]
    lea rcx, [rel nb_dx]
    movsx edx, byte [rcx + rax]
    add edx, r12d                       ; neighbour x
    lea rcx, [rel nb_dz]
    movsx r8d, byte [rcx + rax]
    add r8d, r13d                       ; neighbour z
    cmp edx, 31
    ja .nb_outside
    cmp r8d, 31
    ja .nb_outside
    shl r8d, 5
    add r8d, edx                        ; record inside the chunk
    jmp .nb_load
.nb_outside:
    ; side ring record (caves_column): 1024 + side * 32 + i
    lea eax, [r8d + 1024]
    cmp edx, -1
    je .nb_ring
    lea eax, [r8d + 1056]
    cmp edx, 32
    je .nb_ring
    lea eax, [edx + 1088]
    cmp r8d, -1
    je .nb_ring
    lea eax, [edx + 1120]
.nb_ring:
    mov r8d, eax
.nb_load:
    imul rcx, r8, CCOL_size
    add rcx, [rbx + CAVECTX.cols]
    movsx r8d, word [rcx + CCOL.water_level]
    movsx r9d, word [rcx + CCOL.lava_level]
    movzx r10d, byte [rcx + CCOL.flooded]
.nb_fluid:
    call fluid_at
    cmp eax, [LOCAL(CV_FLUID)]
    jne .keep
    inc dword [LOCAL(CV_N)]
    cmp dword [LOCAL(CV_N)], 4
    jb .nb
    mov eax, [LOCAL(CV_FLUID)]
    test eax, eax
    jz .air
    cmp eax, 1
    je .water
    mov eax, [rel g_b_lava]
    RETURN
.air:
    xor eax, eax
    RETURN
.water:
    mov eax, [rel g_b_water]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; host_ok — may an ore of this record replace block `id`?
;   in:  rsi = ORE*, eax = id     out: eax = ore block to place, or 0
;   clobbers: rax
; -----------------------------------------------------------------------------
host_ok:
    cmp eax, [rel g_b_stone]
    jne .deep
    cmp dword [rsi + ORE.deep_only], 0
    jne .no
    mov eax, [rsi + ORE.block]
    ret
.deep:
    cmp eax, [rel g_b_deep]
    jne .band
    mov eax, [rsi + ORE.deep]
    test eax, eax
    jnz .have
    mov eax, [rsi + ORE.block]          ; one look in both (deep-only ores)
.have:
    ret
.band:
    ; striped rock (badlands bands) hosts ores marked `strata`
    cmp dword [rsi + ORE.strata], 0
    je .no
    lea rdx, [rel g_is_strata]
    cmp byte [rdx + rax], 0
    je .no
    mov eax, [rsi + ORE.block]
    ret
.no:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; caves_finish — ores, then dripstone and floor patches, in one section.
;   in:  rcx = CAVECTX*, rdx = ids u16[32768], r8d = y0, r9d = sy
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define FN_IDS      0
%define FN_Y0       8
%define FN_SY       12
%define FN_ORE      16
%define FN_ATT      20                  ; attempts for this ore
%define FN_I        24
%define FN_POS      28                  ; packed x | z << 5 | y << 10
%define FN_LEFT     32                  ; blocks left in the cluster
%define FN_WALL     36                  ; 1 = this attempt must touch air
%define FN_H        40
%define FN_CTX      48
%define FN_SEED     56
PROC caves_finish, 64, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(FN_CTX)], rcx
    mov [LOCAL(FN_IDS)], rdx
    mov [LOCAL(FN_Y0)], r8d
    mov [LOCAL(FN_SY)], r9d
    mov rbx, rdx                        ; ids

    ; ---- ores -------------------------------------------------------------------------
    mov dword [LOCAL(FN_ORE)], 0
.ore:
    mov eax, [LOCAL(FN_ORE)]
    cmp eax, [rel g_ore_count]
    jae .ores_done
    imul rsi, rax, ORE_size
    lea rcx, [rel g_ores]
    add rsi, rcx                        ; ORE*
    ; does the section overlap the ore's heights?
    mov eax, [LOCAL(FN_Y0)]
    add eax, 31
    cmp eax, [rsi + ORE.min_y]
    jl .ore_next
    mov eax, [LOCAL(FN_Y0)]
    cmp eax, [rsi + ORE.max_y]
    jg .ore_next
    ; attempts = per_section * (1 + wall bonus), randomly rounded
    movss xmm0, [rsi + ORE.per_section]
    movss xmm1, [rel g_ore_wall]
    addss xmm1, [rel c_one]
    mulss xmm0, xmm1
    movss xmm1, [rsi + ORE.mountain_bonus]
    addss xmm1, [rel c_one]
    mulss xmm0, xmm1                    ; (mountain bonus checked per attempt)
    cvttss2si r12d, xmm0
    cvtsi2ss xmm1, r12d
    subss xmm0, xmm1                    ; fraction
    mov rcx, [LOCAL(FN_CTX)]
    mov ecx, [rcx + CAVECTX.cx]
    mov edx, [LOCAL(FN_SY)]
    mov r8, [LOCAL(FN_CTX)]
    mov r8d, [r8 + CAVECTX.cz]
    mov r9d, [LOCAL(FN_ORE)]
    call hash4
    mov [LOCAL(FN_SEED)], eax
    and eax, 0xFFFF
    cvtsi2ss xmm1, eax
    mulss xmm1, [rel c_inv65536]
    comiss xmm1, xmm0
    jae .no_extra
    inc r12d
.no_extra:
    mov [LOCAL(FN_ATT)], r12d
    mov dword [LOCAL(FN_I)], 0
.attempt:
    mov eax, [LOCAL(FN_I)]
    cmp eax, [LOCAL(FN_ATT)]
    jae .vein
    ; position and size from a hash of (section seed, attempt)
    mov ecx, [LOCAL(FN_SEED)]
    mov edx, eax
    mov r8d, 0x4F52                     ; "OR"
    xor r9d, r9d
    call hash4
    mov r13d, eax                       ; random bits
    mov ecx, eax
    and ecx, 0x7FFF                     ; x | z << 5 | y << 10
    mov [LOCAL(FN_POS)], ecx
    ; the first per_section share are free attempts, the rest must touch air
    xor eax, eax
    movss xmm0, [rsi + ORE.per_section]
    movss xmm1, [rsi + ORE.mountain_bonus]
    addss xmm1, [rel c_one]
    mulss xmm0, xmm1
    cvtsi2ss xmm1, dword [LOCAL(FN_I)]
    comiss xmm1, xmm0
    setae al
    mov [LOCAL(FN_WALL)], eax
    ; world y in range, triangular density around the peak
    mov eax, [LOCAL(FN_POS)]
    shr eax, 10
    add eax, [LOCAL(FN_Y0)]             ; world y
    cmp eax, [rsi + ORE.min_y]
    jl .attempt_next
    cmp eax, [rsi + ORE.max_y]
    jg .attempt_next
    mov ecx, [rsi + ORE.peak_y]
    cmp ecx, 0x80000000
    je .density_ok
    ; weight = 1 - |y - peak| / half-range (half-range on that side)
    mov edx, eax
    sub edx, ecx                        ; y - peak
    mov r8d, [rsi + ORE.max_y]
    sub r8d, ecx                        ; above-peak range
    test edx, edx
    jns .side
    neg edx
    mov r8d, ecx
    sub r8d, [rsi + ORE.min_y]          ; below-peak range
.side:
    inc r8d
    cvtsi2ss xmm0, edx
    cvtsi2ss xmm1, r8d
    divss xmm0, xmm1
    movss xmm1, [rel c_one]
    subss xmm1, xmm0                    ; weight 0..1
    mov ecx, r13d
    shr ecx, 16
    cvtsi2ss xmm0, ecx
    mulss xmm0, [rel c_inv65536]
    comiss xmm0, xmm1
    jae .attempt_next
.density_ok:
    ; inside mountains only / mountain bonus
    mov eax, [LOCAL(FN_POS)]
    mov ecx, eax
    and ecx, 31                         ; x
    mov edx, eax
    shr edx, 5
    and edx, 31                         ; z
    ; `strata` ores: only in banded columns
    cmp dword [rsi + ORE.strata], 0
    je .any_column
    mov r8d, edx
    shl r8d, 5
    add r8d, ecx
    imul r8d, r8d, INFO_SIZE
    mov r9, [LOCAL(FN_CTX)]
    add r8, [r9 + CAVECTX.info]
    test byte [r8 + INFO_SFLAG], SF_STRATA
    jz .attempt_next
.any_column:
    lea edx, [edx + HB]
    imul edx, edx, HM
    lea edx, [edx + ecx + HB]
    mov r8, [LOCAL(FN_CTX)]
    mov r8, [r8 + CAVECTX.heights]
    mov r8d, [r8 + rdx * 4]             ; column surface
    mov [LOCAL(FN_H)], r8d
    ; bonus attempts (past per_section, not wall attempts) need a mountain
    cvtsi2ss xmm1, dword [LOCAL(FN_I)]
    comiss xmm1, [rsi + ORE.per_section]
    jb .base_attempt
    cmp dword [LOCAL(FN_WALL)], 0
    jne .base_attempt
    cmp r8d, 250
    jl .attempt_next
.base_attempt:
    shr eax, 10
    add eax, [LOCAL(FN_Y0)]             ; world y
    cmp dword [rsi + ORE.mountain_only], 0
    je .not_monly
    cmp eax, 180
    jl .attempt_next
    lea ecx, [eax + 8]
    cmp ecx, r8d
    jge .attempt_next                   ; must be well inside the mountain
.not_monly:
    ; the cluster: a random walk of size_min .. size_max blocks
    mov eax, [rsi + ORE.size_max]
    sub eax, [rsi + ORE.size_min]
    inc eax
    mov ecx, eax
    mov eax, r13d
    shr eax, 8
    and eax, 0xFF
    xor edx, edx
    div ecx
    add edx, [rsi + ORE.size_min]
    mov [LOCAL(FN_LEFT)], edx
    mov r14d, [LOCAL(FN_POS)]           ; current position
    mov r15d, r13d                      ; walk bits
    ; wall attempts: the first block must touch air
    cmp dword [LOCAL(FN_WALL)], 0
    je .walk
    mov ecx, r14d
    call touches_air
    test eax, eax
    jz .attempt_next
.walk:
    cmp dword [LOCAL(FN_LEFT)], 0
    jle .attempt_next
    movzx eax, word [rbx + r14 * 2]
    call host_ok
    test eax, eax
    jz .step
    mov [rbx + r14 * 2], ax
.step:
    dec dword [LOCAL(FN_LEFT)]
    ; move one block in a direction from the walk bits (stay in the section)
    imul r15d, r15d, 0x2C1B3C6D
    add r15d, 0x9E3779B9
    mov eax, r15d
    shr eax, 29                         ; 0..7
    mov ecx, r14d
    call walk_step
    mov r14d, eax
    jmp .walk
.attempt_next:
    inc dword [LOCAL(FN_I)]
    jmp .attempt

.vein:
    ; rare large vein (snakes through the section)
    movss xmm0, [rsi + ORE.vein_chance]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .ore_next
    mov ecx, [LOCAL(FN_SEED)]
    mov edx, 0x5645                     ; "VE"
    xor r8d, r8d
    xor r9d, r9d
    call hash4
    mov r13d, eax
    and eax, 0xFFFF
    cvtsi2ss xmm1, eax
    mulss xmm1, [rel c_inv65536]
    comiss xmm1, [rsi + ORE.vein_chance]
    jae .ore_next
    mov r14d, r13d
    shr r14d, 16
    and r14d, 0x7FFF                    ; start
    mov eax, [rsi + ORE.vein_size]
    mov [LOCAL(FN_LEFT)], eax
    mov r15d, r13d
    xor r12d, r12d                      ; preferred direction (0..5)
.vein_walk:
    cmp dword [LOCAL(FN_LEFT)], 0
    jle .ore_next
    mov eax, r14d
    shr eax, 10
    add eax, [LOCAL(FN_Y0)]
    cmp eax, [rsi + ORE.min_y]
    jl .vein_step
    cmp eax, [rsi + ORE.max_y]
    jg .vein_step
    movzx eax, word [rbx + r14 * 2]
    call host_ok
    test eax, eax
    jz .vein_step
    mov [rbx + r14 * 2], ax
.vein_step:
    dec dword [LOCAL(FN_LEFT)]
    imul r15d, r15d, 0x2C1B3C6D
    add r15d, 0x9E3779B9
    ; keep the preferred direction 3 times out of 4: long snaking veins
    mov eax, r15d
    shr eax, 30
    jnz .vein_keep
    mov eax, r15d
    shr eax, 27
    and eax, 7
    mov r12d, eax
.vein_keep:
    mov eax, r12d
    mov ecx, r14d
    call walk_step
    mov r14d, eax
    jmp .vein_walk

.ore_next:
    inc dword [LOCAL(FN_ORE)]
    jmp .ore
.ores_done:

    ; ---- dripstone and floor patches ---------------------------------------------
    mov r12, [LOCAL(FN_CTX)]
    xor r13d, r13d                      ; z
.dz:
    xor r14d, r14d                      ; x
.dx:
    mov eax, r13d
    shl eax, 5
    add eax, r14d
    imul rdi, rax, CCOL_size
    add rdi, [r12 + CAVECTX.cols]
    lea eax, [r13d + HB]
    imul eax, eax, HM
    lea eax, [eax + r14d + HB]
    mov rcx, [r12 + CAVECTX.heights]
    mov eax, [rcx + rax * 4]
    mov [LOCAL(FN_H)], eax              ; surface
    mov r15d, 1                         ; ly
.dy:
    mov eax, r15d
    shl eax, 10
    mov ecx, r13d
    shl ecx, 5
    or eax, ecx
    or eax, r14d                        ; index
    cmp word [rbx + rax * 2], 0
    jne .dy_next
    ; only cave air: below the surface's crust
    mov ecx, [LOCAL(FN_Y0)]
    add ecx, r15d
    mov edx, [LOCAL(FN_H)]
    sub edx, 2
    cmp ecx, edx
    jge .dy_next
    mov esi, eax                        ; index of the air block
    ; floor: solid stone / deep stone below
    movzx edx, word [rbx + rax * 2 - 2048]
    cmp edx, [rel g_b_stone]
    je .floor
    cmp edx, [rel g_b_deep]
    jne .ceiling
.floor:
    movzx edx, word [rdi + CCOL.patch]
    test edx, edx
    jz .no_patch
    mov [rbx + rsi * 2 - 2048], dx
.no_patch:
    ; stalagmite?
    mov ecx, [LOCAL(FN_Y0)]
    add ecx, r15d                       ; world y
    mov edx, r14d
    mov r8d, r13d
    mov r9d, 0x5354                     ; "ST"
    add edx, [r12 + CAVECTX.cx_blocks]
    add r8d, [r12 + CAVECTX.cz_blocks]
    call hash4
    mov ecx, eax
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv65536]
    comiss xmm0, [rel g_drip_chance]
    jae .ceiling
    shr ecx, 16
    and ecx, 3
    inc ecx                             ; length 1..4
    mov eax, esi
.mite:
    cmp word [rbx + rax * 2], 0
    jne .ceiling
    mov edx, [rel g_b_drip]             ; state 0: points up
    mov [rbx + rax * 2], dx
    add eax, 1024
    cmp eax, 32768
    jae .ceiling
    dec ecx
    jnz .mite
.ceiling:
    ; ceiling: solid above
    cmp r15d, 31
    jae .dy_next
    movzx edx, word [rbx + rsi * 2 + 2048]
    cmp edx, [rel g_b_stone]
    je .ceil
    cmp edx, [rel g_b_deep]
    jne .dy_next
.ceil:
    cmp word [rbx + rsi * 2], 0
    jne .dy_next
    mov ecx, [LOCAL(FN_Y0)]
    add ecx, r15d
    mov edx, r14d
    mov r8d, r13d
    mov r9d, 0x5443                     ; "TC"
    add edx, [r12 + CAVECTX.cx_blocks]
    add r8d, [r12 + CAVECTX.cz_blocks]
    call hash4
    mov ecx, eax
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv65536]
    comiss xmm0, [rel g_drip_chance]
    jae .dy_next
    shr ecx, 16
    and ecx, 3
    inc ecx
    mov eax, esi
.tite:
    cmp word [rbx + rax * 2], 0
    jne .dy_next
    mov edx, [rel g_b_drip]
    inc edx                             ; state 1: points down
    mov [rbx + rax * 2], dx
    sub eax, 1024
    js .dy_next
    dec ecx
    jnz .tite
.dy_next:
    inc r15d
    cmp r15d, 31
    jb .dy
    inc r14d
    cmp r14d, 32
    jb .dx
    inc r13d
    cmp r13d, 32
    jb .dz
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; walk_step — move a packed section position (x | z << 5 | y << 10) one block
; in direction eax (0..7: -x +x -z +z -y +y, 6/7 = +x / +z), clamped.
;   in:  ecx = position, eax = direction      out: eax = new position
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
walk_step:
    mov edx, ecx
    and edx, 31                         ; x
    mov r8d, ecx
    shr r8d, 5
    and r8d, 31                         ; z
    shr ecx, 10                         ; y
    cmp eax, 6
    jb .dir
    sub eax, 5                          ; 6 -> 1 (+x), 7 -> 2 (-z)... keep in 0..5
.dir:
    cmp eax, 0
    jne .d1
    test edx, edx
    jz .pack
    dec edx
    jmp .pack
.d1:
    cmp eax, 1
    jne .d2
    cmp edx, 31
    jae .pack
    inc edx
    jmp .pack
.d2:
    cmp eax, 2
    jne .d3
    test r8d, r8d
    jz .pack
    dec r8d
    jmp .pack
.d3:
    cmp eax, 3
    jne .d4
    cmp r8d, 31
    jae .pack
    inc r8d
    jmp .pack
.d4:
    cmp eax, 4
    jne .d5
    test ecx, ecx
    jz .pack
    dec ecx
    jmp .pack
.d5:
    cmp ecx, 31
    jae .pack
    inc ecx
.pack:
    shl ecx, 10
    shl r8d, 5
    or ecx, r8d
    or ecx, edx
    mov eax, ecx
    ret

; -----------------------------------------------------------------------------
; touches_air — does a section position have air in a face neighbour inside
; the section?   in: rbx = ids, ecx = packed position   out: eax = 1/0
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
touches_air:
    mov eax, ecx
    and eax, 31
    jz .no_mx
    cmp word [rbx + rcx * 2 - 2], 0
    je .yes
.no_mx:
    cmp eax, 31
    je .no_px
    cmp word [rbx + rcx * 2 + 2], 0
    je .yes
.no_px:
    mov eax, ecx
    shr eax, 5
    and eax, 31
    jz .no_mz
    cmp word [rbx + rcx * 2 - 64], 0
    je .yes
.no_mz:
    cmp eax, 31
    je .no_pz
    cmp word [rbx + rcx * 2 + 64], 0
    je .yes
.no_pz:
    mov eax, ecx
    shr eax, 10
    jz .no_my
    cmp word [rbx + rcx * 2 - 2048], 0
    je .yes
.no_my:
    cmp eax, 31
    je .no
    cmp word [rbx + rcx * 2 + 2048], 0
    je .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

section .rdata
c_sv_margin:    dd 0.05             ; survey: well inside a mask
str_sv_sky:     db "survey: nearest sky cavern at", 0
str_sv_ravine:  db "survey: nearest ravine at", 0
str_sv_shaft:   db "survey: nearest shaft at", 0
align 16
c_abs:          dd 0x7FFFFFFF, 0, 0, 0
c_patch_mud:    dd -0.45
c_depth_ramp:   dd 6.67             ; mask threshold .. +0.15 -> 0 .. 1

section .text
; -----------------------------------------------------------------------------
; caves_survey — log the nearest sky cavern, ravine and shaft on land within
; 2 km of the origin, with the surface height there (part of --survey).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define CS_D        0                   ; 3 x i32: best distance^2 (grid steps)
%define CS_X        12                  ; 3 x i32
%define CS_Z        24                  ; 3 x i32
%define CS_H        36                  ; 3 x i32: surface height
%define CS_WX       48
%define CS_WZ       52
%define CS_DD       56
%define CS_TS       64                  ; TSAMPLE
%define CS_GRID     256                 ; +-256 steps of 8 blocks
%define CS_STEP     8
PROC caves_survey, CS_TS + TSAMPLE_size, rbx, rsi, rdi
    mov dword [LOCAL(CS_D)], 0x7FFFFFFF
    mov dword [LOCAL(CS_D + 4)], 0x7FFFFFFF
    mov dword [LOCAL(CS_D + 8)], 0x7FFFFFFF
    mov esi, -CS_GRID                   ; gz
.z:
    mov ebx, -CS_GRID                   ; gx
.x:
    mov eax, ebx
    imul eax, eax
    mov ecx, esi
    imul ecx, ecx
    add eax, ecx
    mov [LOCAL(CS_DD)], eax
    cmp eax, [LOCAL(CS_D)]
    jl .test
    cmp eax, [LOCAL(CS_D + 4)]
    jl .test
    cmp eax, [LOCAL(CS_D + 8)]
    jge .next
.test:
    imul eax, ebx, CS_STEP
    mov [LOCAL(CS_WX)], eax
    imul eax, esi, CS_STEP
    mov [LOCAL(CS_WZ)], eax
    ; sky cavern
    mov eax, [LOCAL(CS_WX)]
    mov ecx, [LOCAL(CS_WZ)]
    FIELD2 F_SKY
    movss xmm1, [rel g_sky_thr]
    addss xmm1, [rel c_sv_margin]
    comiss xmm0, xmm1
    jbe .ravine
    xor edi, edi
    call .record
.ravine:
    mov eax, [LOCAL(CS_WX)]
    mov ecx, [LOCAL(CS_WZ)]
    FIELD2 F_RAVINE_MASK
    movss xmm1, [rel g_rav_thr]
    addss xmm1, [rel c_sv_margin]
    comiss xmm0, xmm1
    jbe .shaft
    mov eax, [LOCAL(CS_WX)]
    mov ecx, [LOCAL(CS_WZ)]
    FIELD2 F_RAVINE
    andps xmm0, [rel c_abs]
    comiss xmm0, [rel g_rav_w]
    jae .shaft
    mov edi, 1
    call .record
.shaft:
    ; the shaft of this point's cell (recorded at its centre)
    mov eax, [LOCAL(CS_WX)]
    mov ecx, [rel g_shaft_space]
    call floordiv
    mov edi, eax
    mov eax, [LOCAL(CS_WZ)]
    mov ecx, [rel g_shaft_space]
    call floordiv
    mov edx, eax
    mov ecx, edi
    call shaft_cell
    test eax, eax
    jz .next
    mov [LOCAL(CS_WX)], r8d
    mov [LOCAL(CS_WZ)], r9d
    mov edi, 2
    call .record
.next:
    inc ebx
    cmp ebx, CS_GRID
    jl .x
    inc esi
    cmp esi, CS_GRID
    jl .z
    ; report
    lea rcx, [rel str_sv_sky]
    xor edi, edi
    call .report
    lea rcx, [rel str_sv_ravine]
    mov edi, 1
    call .report
    lea rcx, [rel str_sv_shaft]
    mov edi, 2
    call .report
    RETURN

    ; kind edi at the current point, if nearer and on land
    ; (an inner call: locals are 8 bytes further from rsp, 48 while it
    ; reserves 40 for its own calls)
.record:
    mov eax, [LOCAL(CS_DD) + 8]
    cmp eax, [LOCAL(CS_D) + 8 + rdi * 4]
    jge .rec_done
    sub rsp, 40                         ; shadow space, 16-byte alignment
    cvtsi2sd xmm0, dword [LOCAL(CS_WX) + 48]
    cvtsi2sd xmm1, dword [LOCAL(CS_WZ) + 48]
    lea rcx, [LOCAL(CS_TS) + 48]
    call terrain_sample
    add rsp, 40
    cvttss2si eax, [LOCAL(CS_TS) + 8 + TSAMPLE.height]
    mov ecx, [rel g_sea_level]
    add ecx, 4
    cmp eax, ecx
    jl .rec_done                        ; under the sea
    mov [LOCAL(CS_H) + 8 + rdi * 4], eax
    mov eax, [LOCAL(CS_DD) + 8]
    mov [LOCAL(CS_D) + 8 + rdi * 4], eax
    mov eax, [LOCAL(CS_WX) + 8]
    mov [LOCAL(CS_X) + 8 + rdi * 4], eax
    mov eax, [LOCAL(CS_WZ) + 8]
    mov [LOCAL(CS_Z) + 8 + rdi * 4], eax
.rec_done:
    ret

    ; log kind edi with label rcx
.report:
    cmp dword [LOCAL(CS_D) + 8 + rdi * 4], 0x7FFFFFFF
    je .rep_done
    sub rsp, 40
    mov edx, [LOCAL(CS_X) + 48 + rdi * 4]
    mov r8d, [LOCAL(CS_Z) + 48 + rdi * 4]
    call log_xz
    mov eax, [LOCAL(CS_H) + 48 + rdi * 4]
    LOG_VAL LOG_LEVEL_INFO, "survey:   surface height there", rax
    add rsp, 40
.rep_done:
    ret
ENDPROC
