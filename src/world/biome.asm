; =============================================================================
; biome.asm — data-driven biomes: registry, climate, biome choice and the
; per-chunk blend map (design/biomes/biome_system.md, DATA_FORMAT.md).
;
; Every data/biomes/*.biome file is read at start-up in file-name order. A
; file holds records:
;   [climate]               grass_reference / foliage_reference colours,
;                           contrast of the climate noise
;   [noise temperature]     the climate fields (scale, octaves, persistence,
;   [noise humidity]        salt)
;   [tree <name>]           a tree or bush generator (kind, blocks, sizes)
;   [biome <name>]          climate box, heights, colours, terrain, plants,
;                           flowers, meadows, trees, bushes, ponds
; Trees must be defined before the biomes that use them (file order).
;
; Choice: temperature and humidity (0..1, from 2D noise) and the surface
; height select the biome whose box contains them (nearest box centre when
; boxes overlap); nothing matches -> biome 0 ("none": plain terrain).
; Blending: per chunk, biomes are sampled every 16 blocks and blurred with a
; tent filter (radius 32), giving smooth weights for colours, terrain and
; vegetation density.
;
; Public API (include/biome.inc):
;   biomes_load() -> eax 1/0            (after blocks and terrain)
;   biome_climate(x, z)                 in: xmm0, xmm1 doubles
;                                       out: xmm0 temperature, xmm1 humidity
;   biome_pick(t, h, height) -> eax     in: xmm0, xmm1, ecx
;   bmap_build(BMAP*, cx, cz)           blend map of a chunk
;   bmap_col(BMAP*, lx, lz)             at chunk-local block (-32..63):
;       out: eax biome, xmm0 density 0..1 (fades towards borders),
;            xmm1 hill factor, xmm2 dune height, xmm3 plateau height
;   bmap_tint(BMAP*, lx, lz)            out: eax grass, edx foliage RGBA8
;                                       factors (64 = 1.0)
;   biome_at(x, z) -> rax name          (debug overlay; caches its chunk)
;   g_biomes, g_biome_count, g_trees, g_tree_count
; =============================================================================
%define BIOME_IMPL
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "noise.inc"
%include "block.inc"
%include "terrain.inc"
%include "biome.inc"

global biomes_load, biome_climate, biome_pick, bmap_build, bmap_col, bmap_tint
global biome_at, biome_point, biome_dunes, biome_plateau, biome_mesa, biome_strata_wave
global g_strata, g_is_strata, bmap_dither, bmap_flatten
global g_biomes, g_biome_count, g_trees, g_tree_count

extern str_ieq, str_len, str_copy, str_dup, str_parse_float
extern terrain_sample, g_world_seed, g_b_stone

IMPORT FindFirstFileA, FindNextFileA, FindClose

%define MAX_FILES       64
%define FD_ATTR         0
%define FD_NAME         44
%define FILE_ATTRIBUTE_DIRECTORY 0x10

; setting types
%define T_FLOAT         0
%define T_INT           1
%define T_BLOCK         2
%define T_RANGE_F       3               ; "a, b" floats at +0, +4
%define T_RANGE_I       4
%define T_COLOR         5               ; RRGGBB hex (optional #)
%define T_PLANT         6               ; block, chance (appended)
%define T_TREEREF       7               ; tree name, weight (appended)
%define T_BLOCKLIST     8               ; blocks (appended)
%define T_KIND          9               ; tree kind name
%define T_PATCH         10              ; block, float level

; record kinds
%define K_NONE          0
%define K_BIOME         1
%define K_TREE          2
%define K_CLIMATE       3
%define K_NOISE         4

section .rdata
str_pattern:    db "data\biomes\*.biome", 0
str_dir:        db "data\biomes\", 0
str_none:       db "none", 0
k_biome:        db "biome", 0
k_tree:         db "tree", 0
k_climate:      db "climate", 0
k_noise:        db "noise", 0
n_temp:         db "temperature", 0
n_humid:        db "humidity", 0
n_weird:        db "weirdness", 0
n_dunes:        db "dunes", 0
n_plateaus:     db "plateaus", 0
n_mesas:        db "mesas", 0
n_strata:       db "strata", 0
n_rarity:       db "rarity", 0
k_ridged:       db "ridged", 0
k_scale:        db "scale", 0
k_octaves:      db "octaves", 0
k_persistence:  db "persistence", 0
k_salt:         db "salt", 0
k_grass_ref:    db "grass_reference", 0
k_foliage_ref:  db "foliage_reference", 0
k_water_ref:    db "water_reference", 0
k_b_water:      db "water_color", 0
k_b_flatten:    db "flatten", 0
k_b_own_shore:  db "own_shore", 0
k_b_wplant:     db "water_plant", 0
k_b_rarity:     db "rarity", 0
k_b_isle_ch:    db "island_chance", 0
k_b_isle_r:     db "island_radius", 0
k_b_isle_y:     db "island_height", 0
k_b_isle_ore:   db "island_ore", 0
k_b_isle_roots: db "island_roots", 0
k_contrast:     db "contrast", 0
; biome keys
k_b_temp:       db "temperature", 0
k_b_humid:      db "humidity", 0
k_b_height:     db "height", 0
k_b_hill:       db "hill_scale", 0
k_b_grass:      db "grass_color", 0
k_b_foliage:    db "foliage_color", 0
k_b_top:        db "top_block", 0
k_b_filler:     db "filler_block", 0
k_b_plant:      db "plant", 0
k_b_flowers:    db "flowers", 0
k_b_flower_ch:  db "flower_chance", 0
k_b_meadow_ch:  db "meadow_chance", 0
k_b_meadow_r:   db "meadow_radius", 0
k_b_meadow_d:   db "meadow_density", 0
k_b_meadow_m:   db "meadow_mixed", 0
k_b_tree:       db "tree", 0
k_b_tree_d:     db "tree_density", 0
k_b_bush:       db "bush", 0
k_b_bush_d:     db "bush_density", 0
k_b_pond_ch:    db "pond_chance", 0
k_b_pond_r:     db "pond_radius", 0
k_b_pond_d:     db "pond_depth", 0
k_b_pond_f:     db "pond_floor", 0
k_b_weird:      db "weirdness", 0
k_b_prio:       db "priority", 0
k_b_litter:     db "litter_block", 0
k_b_litter_r:   db "litter_radius", 0
k_b_litter_ch:  db "litter_chance", 0
k_b_shade:      db "shade_plant", 0
k_b_clear_ch:   db "clearing_chance", 0
k_b_clear_r:    db "clearing_radius", 0
k_b_clear_fl:   db "clearing_flower_chance", 0
k_b_ring_ch:    db "ring_chance", 0
k_b_ring_r:     db "ring_radius", 0
k_b_ring:       db "ring_plants", 0
k_b_patch:      db "top_patch", 0
k_b_patch_low:  db "top_patch_low", 0
k_b_pond_top:   db "pond_top", 0
k_b_mesa:       db "mesa_height", 0
k_b_strata:     db "strata", 0
k_b_strata_t:   db "strata_thickness", 0
k_b_strata_min: db "strata_min_y", 0
k_b_wash:       db "wash_block", 0
k_b_beach:      db "beach_block", 0
v_strata:       db "strata", 0
k_b_mcell:      db "meadow_cell", 0
k_b_mflowers:   db "meadow_flowers", 0
k_b_dune:       db "dune_height", 0
k_b_steep:      db "steep_block", 0
k_b_pslope:     db "pond_slope", 0
k_b_plateau:    db "plateau_height", 0
v_acacia:       db "acacia", 0
v_baobab:       db "baobab", 0
v_kapok:        db "kapok", 0
v_grove:        db "grove", 0
v_stone_ring:   db "stone_ring", 0
v_cypress:      db "cypress", 0
v_gnarled:      db "gnarled", 0
v_mushroom:     db "mushroom", 0
k_t_under:      db "underside", 0
k_t_lean:       db "lean", 0
k_b_dry:        db "dry_ponds", 0
k_t_vines:      db "vines", 0
k_t_hang:       db "hanging_vines", 0
k_t_fungus:     db "fungus", 0
k_t_pods:       db "pods", 0
k_t_vine_len:   db "vine_length", 0
k_t_chance:     db "chance", 0
v_cactus:       db "cactus", 0
v_rock:         db "rock", 0
v_arch:         db "arch", 0
v_fossil:       db "fossil", 0
v_palm:         db "palm", 0
v_conifer:      db "conifer", 0
k_t_base_r:     db "base_radius", 0
k_t_roots:      db "roots", 0
v_giant:        db "giant", 0
v_fallen:       db "fallen", 0
v_stump:        db "stump", 0
; tree keys
k_t_kind:       db "kind", 0
k_t_log:        db "log", 0
k_t_leaves:     db "leaves", 0
k_t_height:     db "height", 0
k_t_radius:     db "radius", 0
k_t_branches:   db "branches", 0
k_t_gaps:       db "leaf_gaps", 0
v_round:        db "round", 0
v_branching:    db "branching", 0
v_bush:         db "bush", 0
str_unknown:    db "unknown setting: ", 0
str_bad:        db "bad value for: ", 0
str_bad_rec:    db "unknown record: ", 0
str_bad_block:  db "unknown block: ", 0
str_bad_tree:   db "unknown tree (define trees before biomes): ", 0
str_too_many:   db "too many entries: ", 0
str_loaded:     db "biomes: ", 0
str_loaded2:    db " biomes, ", 0
str_loaded3:    db " trees", 0

align 8
biome_settings:
    dq k_b_temp,      T_RANGE_F,  BIOME.temp
    dq k_b_humid,     T_RANGE_F,  BIOME.humid
    dq k_b_height,    T_RANGE_I,  BIOME.height
    dq k_b_hill,      T_FLOAT,    BIOME.hill
    dq k_b_grass,     T_COLOR,    BIOME.grass
    dq k_b_foliage,   T_COLOR,    BIOME.foliage
    dq k_b_water,     T_COLOR,    BIOME.water
    dq k_b_flatten,   T_RANGE_F,  BIOME.flatten
    dq k_b_own_shore, T_INT,      BIOME.own_shore
    dq k_b_wplant,    T_PLANT,    BIOME.nwplants
    dq k_b_rarity,    T_RANGE_F,  BIOME.rarity
    dq k_b_isle_ch,   T_FLOAT,    BIOME.isle_ch
    dq k_b_isle_r,    T_RANGE_F,  BIOME.isle_r
    dq k_b_isle_y,    T_RANGE_I,  BIOME.isle_y
    dq k_b_isle_ore,  T_PLANT,    BIOME.nisle_ore
    dq k_b_isle_roots, T_PATCH,   BIOME.isle_roots
    dq k_b_top,       T_BLOCK,    BIOME.top
    dq k_b_filler,    T_BLOCK,    BIOME.filler
    dq k_b_plant,     T_PLANT,    BIOME.nplants
    dq k_b_flowers,   T_BLOCKLIST, BIOME.nflowers
    dq k_b_flower_ch, T_FLOAT,    BIOME.flower_ch
    dq k_b_meadow_ch, T_FLOAT,    BIOME.meadow_ch
    dq k_b_meadow_r,  T_RANGE_F,  BIOME.meadow_r
    dq k_b_meadow_d,  T_FLOAT,    BIOME.meadow_dens
    dq k_b_meadow_m,  T_FLOAT,    BIOME.meadow_mixed
    dq k_b_tree,      T_TREEREF,  BIOME.ntrees
    dq k_b_tree_d,    T_FLOAT,    BIOME.tree_dens
    dq k_b_bush,      T_TREEREF,  BIOME.nbushes
    dq k_b_bush_d,    T_FLOAT,    BIOME.bush_dens
    dq k_b_pond_ch,   T_FLOAT,    BIOME.pond_ch
    dq k_b_pond_r,    T_RANGE_F,  BIOME.pond_r
    dq k_b_pond_d,    T_INT,      BIOME.pond_depth
    dq k_b_pond_f,    T_BLOCK,    BIOME.pond_floor
    dq k_b_weird,     T_RANGE_F,  BIOME.weird
    dq k_b_prio,      T_INT,      BIOME.priority
    dq k_b_litter,    T_BLOCK,    BIOME.litter
    dq k_b_litter_r,  T_INT,      BIOME.litter_r
    dq k_b_litter_ch, T_FLOAT,    BIOME.litter_ch
    dq k_b_shade,     T_PLANT,    BIOME.nshade
    dq k_b_clear_ch,  T_FLOAT,    BIOME.clear_ch
    dq k_b_clear_r,   T_RANGE_F,  BIOME.clear_r
    dq k_b_clear_fl,  T_FLOAT,    BIOME.clear_fl
    dq k_b_ring_ch,   T_FLOAT,    BIOME.ring_ch
    dq k_b_ring_r,    T_RANGE_F,  BIOME.ring_r
    dq k_b_ring,      T_BLOCKLIST, BIOME.nrings
    dq k_b_patch,     T_PATCH,    BIOME.patch
    dq k_b_mcell,     T_INT,      BIOME.meadow_cell
    dq k_b_mflowers,  T_BLOCKLIST, BIOME.nmflowers
    dq k_b_dune,      T_FLOAT,    BIOME.dune_h
    dq k_b_steep,     T_BLOCK,    BIOME.steep
    dq k_b_pslope,    T_INT,      BIOME.pond_slope
    dq k_b_plateau,   T_FLOAT,    BIOME.plateau_h
    dq k_b_patch_low, T_PATCH,    BIOME.patch_low
    dq k_b_pond_top,  T_BLOCK,    BIOME.pond_top
    dq k_b_mesa,      T_FLOAT,    BIOME.mesa_h
    dq k_b_strata,    T_BLOCKLIST, BIOME.nstrata
    dq k_b_strata_t,  T_RANGE_I,  BIOME.strata_thick
    dq k_b_strata_min, T_INT,     BIOME.strata_min
    dq k_b_wash,      T_BLOCK,    BIOME.wash
    dq k_b_beach,     T_BLOCK,    BIOME.beach
    dq k_b_dry,       T_PATCH,    BIOME.dry_block
    dq 0
tree_settings:
    dq k_t_kind,      T_KIND,     TREE.kind
    dq k_t_log,       T_BLOCK,    TREE.log
    dq k_t_leaves,    T_BLOCK,    TREE.leaves
    dq k_t_height,    T_RANGE_I,  TREE.height
    dq k_t_radius,    T_RANGE_F,  TREE.radius
    dq k_t_branches,  T_RANGE_I,  TREE.branches
    dq k_t_gaps,      T_FLOAT,    TREE.gaps
    dq k_t_base_r,    T_RANGE_F,  TREE.base_r
    dq k_t_roots,     T_RANGE_I,  TREE.roots
    dq k_t_chance,    T_FLOAT,    TREE.chance
    dq k_t_vines,     T_PATCH,    TREE.vine
    dq k_t_hang,      T_PATCH,    TREE.hang
    dq k_t_fungus,    T_PATCH,    TREE.fungus
    dq k_t_pods,      T_PATCH,    TREE.pod
    dq k_t_vine_len,  T_RANGE_I,  TREE.vine_len
    dq k_t_lean,      T_FLOAT,    TREE.lean
    dq k_t_under,     T_BLOCK,    TREE.under
    dq 0
climate_settings:
    dq k_grass_ref,   T_COLOR,    g_grass_ref
    dq k_foliage_ref, T_COLOR,    g_foliage_ref
    dq k_water_ref,   T_COLOR,    g_water_ref
    dq k_contrast,    T_FLOAT,    g_contrast
    dq 0
kind_names:     dq v_round, v_branching, v_bush, v_giant, v_fallen, v_stump
                dq v_cactus, v_rock, v_arch, v_fossil, v_palm, v_conifer
                dq v_acacia, v_baobab, v_kapok, v_grove, v_stone_ring
                dq v_cypress, v_gnarled, v_mushroom
%define KIND_COUNT 20

align 4
c_one:          dd 1.0
c_plateau_thr:  dd 0.22
c_plateau_ramp: dd 14.0
c_mesa_thr:     dd -0.05
c_mesa_ramp:    dd 4.0
c_mesa_steps:   dd 3.0
c_mesa_riser:   dd 0.75
c_four:         dd 4.0
c_strata_wave:  dd 4.0
c_half:         dd 0.5
c_zero:         dd 0.0
c_64:           dd 64.0
c_255:          dd 255.0
c_inv16:        dd 0.0625
c_inv81:        dd 0.012345679
c_dens_lo:      dd 0.5                  ; own weight where vegetation ends
c_dens_inv:     dd 2.857142857          ; 1 / 0.35: full density at 0.85
c_big:          dd 1.0e30
tent:           dd 1.0, 2.0, 3.0, 2.0, 1.0
align 8
c_one_d:        dq 1.0

section .data
align 4
g_grass_ref:    dd 0x6DB33F             ; average colour of the grass texture
g_foliage_ref:  dd 0x4E9A2E
g_water_ref:    dd 0x0D58CF             ; average colour of the water texture
g_contrast:     dd 1.0

section .bss
alignb 16
g_biomes:       resb MAX_BIOMES * BIOME_size
g_trees:        resb MAX_TREES * TREE_size
alignb 2
g_strata:       resw MAX_BIOMES * STRATA_LEN
g_is_strata:    resb 65536
alignb 8
g_clim_noise:   resb 8 * NOISE_size     ; temperature, humidity, weirdness, dunes, plateaus, mesas, strata, rarity
alignb 4
g_biome_count:  resd 1
g_tree_count:   resd 1
g_kind:         resd 1
g_rec:          resd 1
g_file_count:   resd 1
alignb 8
g_label:        resq 1
g_file_names:   resq MAX_FILES
g_find_data:    resb 320
g_path:         resb 512
g_rel:          resb 256
g_at_cx:        resd 1                  ; biome_at cache
g_at_cz:        resd 1
g_at_valid:     resd 1
alignb 16
g_at_map:       resb BMAP_size

section .text

; -----------------------------------------------------------------------------
; warn — "<file>: <msg><arg>"   in: rcx = message, rdx = argument
; -----------------------------------------------------------------------------
PROC warn, 0
    mov r8, rdx
    mov rdx, rcx
    mov rcx, [rel g_label]
    call cfg_warn
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; parse_f — float or warn.   in: rcx = text, rdx = key
;   out: xmm0, eax = 1 if valid
; -----------------------------------------------------------------------------
PROC parse_f, 0, rbx
    mov rbx, rdx
    test rcx, rcx
    jz .bad
    call str_parse_float
    test eax, eax
    jnz .ok
.bad:
    lea rcx, [rel str_bad]
    mov rdx, rbx
    call warn
    xor eax, eax
.ok:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; parse_hex — "RRGGBB" or "#RRGGBB".   in: rcx = text
;   out: eax = value, edx = 1 if valid
; -----------------------------------------------------------------------------
parse_hex:
    cmp byte [rcx], '#'
    jne .start
    inc rcx
.start:
    xor eax, eax
    xor edx, edx                        ; digits
.digit:
    movzx r8d, byte [rcx]
    lea r9d, [r8 - '0']
    cmp r9d, 9
    jbe .have
    or r8d, 0x20
    lea r9d, [r8 - 'a']
    cmp r9d, 5
    ja .end
    add r9d, 10
.have:
    shl eax, 4
    or eax, r9d
    inc edx
    inc rcx
    jmp .digit
.end:
    cmp edx, 6
    sete dl
    movzx edx, dl
    ret

; -----------------------------------------------------------------------------
; biomes_load — read every data/biomes/*.biome file.
;   out: eax = 1 (missing files only mean "no biomes")
; -----------------------------------------------------------------------------
PROC biomes_load, 0, rbx, rsi
    ; climate noise defaults: 2 octaves at scale 800
    lea rbx, [rel g_clim_noise]
    xor esi, esi
.nd:
    mov rax, 0x3F547AE147AE147B         ; 1/800
    mov [rbx + NOISE.freq], rax
    mov dword [rbx + NOISE.octaves], 2
    mov dword [rbx + NOISE.persistence], 0x3F000000
    lea eax, [esi + 301]
    mov [rbx + NOISE.salt], eax
    mov dword [rbx + NOISE.ridged], 0
    add rbx, NOISE_size
    inc esi
    cmp esi, 8
    jb .nd
    ; biome 0: none
    lea rcx, [rel g_biomes]
    call biome_defaults
    lea rax, [rel str_none]
    mov [rel g_biomes + BIOME.name], rax
    mov dword [rel g_biome_count], 1
    mov dword [rel g_tree_count], 0
    mov dword [rel g_kind], K_NONE

    call collect_files
    xor ebx, ebx
.file:
    cmp ebx, [rel g_file_count]
    jae .files_done
    lea rax, [rel g_file_names]
    mov rcx, [rax + rbx * 8]
    call load_file
    inc ebx
    jmp .file
.files_done:
    call strata_build
    ; colour factors (relative to the textures' own colours)
    xor ebx, ebx
.fac:
    cmp ebx, [rel g_biome_count]
    jae .fac_done
    imul rsi, rbx, BIOME_size
    lea rax, [rel g_biomes]
    add rsi, rax
    mov ecx, [rsi + BIOME.grass]
    mov edx, [rel g_grass_ref]
    call color_factor
    mov [rsi + BIOME.gfac], eax
    mov ecx, [rsi + BIOME.foliage]
    mov edx, [rel g_foliage_ref]
    call color_factor
    mov [rsi + BIOME.ffac], eax
    mov ecx, [rsi + BIOME.water]
    mov edx, [rel g_water_ref]
    call color_factor
    mov [rsi + BIOME.wfac], eax
    inc ebx
    jmp .fac
.fac_done:
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_loaded]
    call log_append_str
    mov ecx, [rel g_biome_count]
    dec ecx
    call log_append_dec
    lea rcx, [rel str_loaded2]
    call log_append_str
    mov ecx, [rel g_tree_count]
    call log_append_dec
    lea rcx, [rel str_loaded3]
    call log_append_str
    call log_end
    mov dword [rel g_at_valid], 0
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; color_factor — RGBA8 factor colour / reference per channel (64 = 1.0).
;   in:  ecx = colour 0xRRGGBB, edx = reference    out: eax = RGBA8 (A 255)
;   clobbers: rax, rcx, rdx, r8-r10, xmm0-xmm1
; -----------------------------------------------------------------------------
color_factor:
    mov r9d, ecx
    mov r10d, edx
    mov eax, 0xFF000000                 ; alpha
    xor r8d, r8d                        ; channel: 0 R (bits 16-23) .. 2 B
.ch:
    mov ecx, 16
    imul edx, r8d, 8
    sub ecx, edx                        ; shift of this channel in 0xRRGGBB
    mov edx, r9d
    shr edx, cl
    and edx, 0xFF
    cvtsi2ss xmm0, edx
    mov edx, r10d
    shr edx, cl
    and edx, 0xFF
    cmp edx, 1
    jae .ref_ok
    mov edx, 1
.ref_ok:
    cvtsi2ss xmm1, edx
    divss xmm0, xmm1
    mulss xmm0, [rel c_64]
    minss xmm0, [rel c_255]
    cvttss2si edx, xmm0
    imul ecx, r8d, 8                    ; RGBA8 in memory: R lowest byte
    shl edx, cl
    or eax, edx
    inc r8d
    cmp r8d, 3
    jb .ch
    ret

; -----------------------------------------------------------------------------
; biome_defaults — reset a biome record.   in: rcx = BIOME*
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
biome_defaults:
    push rdi
    mov rdx, rcx
    mov rdi, rcx
    xor eax, eax
    mov ecx, BIOME_size / 4
    rep stosd
    pop rdi
    mov dword [rdx + BIOME.temp + 4], 0x3F800000
    mov dword [rdx + BIOME.humid + 4], 0x3F800000
    mov dword [rdx + BIOME.height], -100000
    mov dword [rdx + BIOME.height + 4], 100000
    mov dword [rdx + BIOME.hill], 0x3F800000
    mov eax, [rel g_grass_ref]
    mov [rdx + BIOME.grass], eax
    mov eax, [rel g_foliage_ref]
    mov [rdx + BIOME.foliage], eax
    mov eax, [rel g_water_ref]
    mov [rdx + BIOME.water], eax
    mov dword [rdx + BIOME.meadow_r], 0x41A00000      ; 20
    mov dword [rdx + BIOME.meadow_r + 4], 0x42480000  ; 50
    mov dword [rdx + BIOME.meadow_dens], 0x3F19999A   ; 0.6
    mov dword [rdx + BIOME.meadow_mixed], 0x3F000000  ; 0.5
    mov dword [rdx + BIOME.pond_r], 0x40400000        ; 3
    mov dword [rdx + BIOME.pond_r + 4], 0x40C00000    ; 6
    mov dword [rdx + BIOME.pond_depth], 2
    mov dword [rdx + BIOME.weird + 4], 0x3F800000     ; 0 .. 1
    mov dword [rdx + BIOME.rarity + 4], 0x3F800000    ; 0 .. 1
    mov dword [rdx + BIOME.litter_r], 2
    mov dword [rdx + BIOME.clear_r], 0x41000000       ; 8
    mov dword [rdx + BIOME.clear_r + 4], 0x41800000   ; 16
    mov dword [rdx + BIOME.ring_r], 0x40400000        ; 3
    mov dword [rdx + BIOME.ring_r + 4], 0x40A00000    ; 5
    mov dword [rdx + BIOME.meadow_cell], 512
    mov dword [rdx + BIOME.pond_slope], 3
    ret

; -----------------------------------------------------------------------------
; collect_files — list data\biomes\*.biome sorted by name (ASCII order).
; -----------------------------------------------------------------------------
PROC collect_files, 0, rbx, rsi, rdi, r12
    mov dword [rel g_file_count], 0
    lea rcx, [rel g_path]
    lea rdx, [rel str_pattern]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_find_data]
    API FindFirstFileA, rcx, rdx
    cmp rax, -1
    je .done
    mov rbx, rax
.entry:
    lea rax, [rel g_find_data]
    test dword [rax + FD_ATTR], FILE_ATTRIBUTE_DIRECTORY
    jnz .next
    cmp dword [rel g_file_count], MAX_FILES
    jae .next
    lea rcx, [rel g_find_data + FD_NAME]
    call str_dup
    test rax, rax
    jz .next
    mov r12, rax
    mov esi, [rel g_file_count]
    lea rdi, [rel g_file_names]
.shift:
    test esi, esi
    jz .place
    mov rcx, r12
    mov rdx, [rdi + rsi * 8 - 8]
    call name_less
    test eax, eax
    jz .place
    mov rax, [rdi + rsi * 8 - 8]
    mov [rdi + rsi * 8], rax
    dec esi
    jmp .shift
.place:
    mov [rdi + rsi * 8], r12
    inc dword [rel g_file_count]
.next:
    lea rdx, [rel g_find_data]
    API FindNextFileA, rbx, rdx
    test eax, eax
    jnz .entry
    API FindClose, rbx
.done:
    RETURN
ENDPROC

; name_less — case-insensitive a < b.  in: rcx, rdx  out: eax
;   clobbers: rax, rcx, rdx, r8, r9
name_less:
.loop:
    movzx r8d, byte [rcx]
    movzx r9d, byte [rdx]
    lea eax, [r8 - 'A']
    cmp eax, 25
    ja .a_ok
    add r8d, 32
.a_ok:
    lea eax, [r9 - 'A']
    cmp eax, 25
    ja .b_ok
    add r9d, 32
.b_ok:
    cmp r8d, r9d
    jb .less
    ja .not_less
    test r8d, r8d
    jz .not_less
    inc rcx
    inc rdx
    jmp .loop
.less:
    mov eax, 1
    ret
.not_less:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; load_file — parse one biome file.   in: rcx = file name
; -----------------------------------------------------------------------------
PROC load_file, 0, rbx, rsi
    mov rbx, rcx
    mov [rel g_label], rbx
    mov dword [rel g_kind], K_NONE
    lea rcx, [rel g_rel]
    lea rdx, [rel str_dir]
    call str_copy
    INVOKE str_copy, rax, rbx
    lea rcx, [rel g_path]
    lea rdx, [rel g_rel]
    call path_make
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov rsi, rax
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .fail
    lea rdx, [rel biome_pair]
    INVOKE cfg_parse_ex, rax, rdx, 0, rbx, CFG_SECTIONS
.fail:
    lea rcx, [rel g_arena_scratch]
    mov rdx, rsi
    call arena_reset_to
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; find_tree — index of a tree by name.   in: rcx = name   out: eax or -1
; -----------------------------------------------------------------------------
PROC find_tree, 0, rbx, rsi
    mov rsi, rcx
    xor ebx, ebx
.t:
    cmp ebx, [rel g_tree_count]
    jae .none
    imul rax, rbx, TREE_size
    lea rcx, [rel g_trees]
    INVOKE str_ieq, [rcx + rax + TREE.name], rsi
    test eax, eax
    jnz .found
    inc ebx
    jmp .t
.found:
    mov eax, ebx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; biome_pair — cfg callback: a "[kind name]" header (rdx = 0) or a setting.
;   in:  rcx = key / header, rdx = value
; -----------------------------------------------------------------------------
PROC biome_pair, 16, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    mov rsi, rdx
    test rdx, rdx
    jnz .pair
    ; header: split "kind name"
    mov dword [rel g_kind], K_NONE
    mov rcx, rbx
.blank:
    mov al, [rcx]
    test al, al
    jz .no_name
    cmp al, ' '
    je .split
    inc rcx
    jmp .blank
.no_name:
    mov rdi, rcx                        ; empty name
    jmp .kind
.split:
    mov byte [rcx], 0
    lea rdi, [rcx + 1]
.skip:
    cmp byte [rdi], ' '
    jne .kind
    inc rdi
    jmp .skip
.kind:
    lea rdx, [rel k_climate]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_climate
    mov dword [rel g_kind], K_CLIMATE
    RETURN
.not_climate:
    lea rdx, [rel k_noise]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_noise
    xor r12d, r12d
    lea rdx, [rel n_temp]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jnz .noise_rec
    mov r12d, 1
    lea rdx, [rel n_humid]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jnz .noise_rec
    mov r12d, 2
    lea rdx, [rel n_weird]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jnz .noise_rec
    mov r12d, 3
    lea rdx, [rel n_dunes]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jnz .noise_rec
    mov r12d, 4
    lea rdx, [rel n_plateaus]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jnz .noise_rec
    mov r12d, 5
    lea rdx, [rel n_mesas]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jnz .noise_rec
    mov r12d, 6
    lea rdx, [rel n_strata]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jnz .noise_rec
    mov r12d, 7
    lea rdx, [rel n_rarity]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jz .bad_rec
.noise_rec:
    mov [rel g_rec], r12d
    mov dword [rel g_kind], K_NOISE
    RETURN
.not_noise:
    lea rdx, [rel k_tree]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_tree
    mov eax, [rel g_tree_count]
    cmp eax, MAX_TREES
    jae .full
    mov [rel g_rec], eax
    imul r12, rax, TREE_size
    lea rax, [rel g_trees]
    add r12, rax
    mov rcx, rdi
    call str_dup
    mov [r12 + TREE.name], rax
    mov dword [r12 + TREE.kind], TREE_ROUND
    mov dword [r12 + TREE.log], 0
    mov dword [r12 + TREE.leaves], 0
    mov dword [r12 + TREE.height], 5
    mov dword [r12 + TREE.height + 4], 7
    mov dword [r12 + TREE.radius], 0x40000000       ; 2
    mov dword [r12 + TREE.radius + 4], 0x40400000   ; 3
    mov dword [r12 + TREE.branches], 2
    mov dword [r12 + TREE.branches + 4], 4
    mov dword [r12 + TREE.gaps], 0x3E4CCCCD         ; 0.2
    mov dword [r12 + TREE.base_r], 0x40400000       ; 3
    mov dword [r12 + TREE.base_r + 4], 0x40900000   ; 4.5
    mov dword [r12 + TREE.roots], 4
    mov dword [r12 + TREE.roots + 4], 7
    mov dword [r12 + TREE.chance], 0x3F000000       ; 0.5
    mov dword [r12 + TREE.vine], 0
    mov dword [r12 + TREE.hang], 0
    mov dword [r12 + TREE.fungus], 0
    mov dword [r12 + TREE.pod], 0
    mov dword [r12 + TREE.vine_len], 2
    mov dword [r12 + TREE.vine_len + 4], 8
    mov dword [r12 + TREE.lean], 0
    mov dword [r12 + TREE.under], 0
    inc dword [rel g_tree_count]
    mov dword [rel g_kind], K_TREE
    RETURN
.not_tree:
    lea rdx, [rel k_biome]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .bad_rec
    mov eax, [rel g_biome_count]
    cmp eax, MAX_BIOMES
    jae .full
    mov [rel g_rec], eax
    imul r12, rax, BIOME_size
    lea rax, [rel g_biomes]
    add r12, rax
    mov rcx, r12
    call biome_defaults
    mov rcx, rdi
    call str_dup
    mov [r12 + BIOME.name], rax
    inc dword [rel g_biome_count]
    mov dword [rel g_kind], K_BIOME
    RETURN
.full:
    lea rcx, [rel str_too_many]
    mov rdx, rbx
    call warn
    RETURN
.bad_rec:
    lea rcx, [rel str_bad_rec]
    mov rdx, rbx
    call warn
    RETURN

.pair:
    mov eax, [rel g_kind]
    cmp eax, K_NOISE
    je .noise
    xor r12d, r12d                      ; base address
    lea rdi, [rel climate_settings]
    cmp eax, K_CLIMATE
    je .find
    mov ecx, [rel g_rec]
    lea rdi, [rel tree_settings]
    imul r12, rcx, TREE_size
    lea rdx, [rel g_trees]
    add r12, rdx
    cmp eax, K_TREE
    je .find
    lea rdi, [rel biome_settings]
    imul r12, rcx, BIOME_size
    lea rdx, [rel g_biomes]
    add r12, rdx
    cmp eax, K_BIOME
    je .find
    lea rcx, [rel str_unknown]
    mov rdx, rbx
    call warn
    RETURN
.find:
    mov rcx, [rdi]
    test rcx, rcx
    jz .unknown
    INVOKE str_ieq, rcx, rbx
    test eax, eax
    jnz .set
    add rdi, 24
    jmp .find
.unknown:
    lea rcx, [rel str_unknown]
    mov rdx, rbx
    call warn
    RETURN
.set:
    mov r13, [rdi + 16]
    add r13, r12                        ; field address
    mov rax, [rdi + 8]
    cmp eax, T_FLOAT
    je .t_float
    cmp eax, T_INT
    je .t_int
    cmp eax, T_BLOCK
    je .t_block
    cmp eax, T_RANGE_F
    je .t_range
    cmp eax, T_RANGE_I
    je .t_range
    cmp eax, T_COLOR
    je .t_color
    cmp eax, T_PLANT
    je .t_plant
    cmp eax, T_TREEREF
    je .t_treeref
    cmp eax, T_BLOCKLIST
    je .t_blocklist
    cmp eax, T_PATCH
    je .t_patch
    ; T_KIND
    xor edi, edi
.kind_find:
    cmp edi, KIND_COUNT
    jae .bad
    lea rax, [rel kind_names]
    INVOKE str_ieq, [rax + rdi * 8], rsi
    test eax, eax
    jnz .kind_ok
    inc edi
    jmp .kind_find
.kind_ok:
    mov [r13], edi
    RETURN

.t_float:
    mov rcx, rsi
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    movss [r13], xmm0
    RETURN
.t_int:
    mov rcx, rsi
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    cvttss2si eax, xmm0
    mov [r13], eax
    RETURN
.t_block:
    lea rdx, [rel v_strata]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jz .t_block_find
    mov dword [r13], BLOCK_STRATA       ; banded by height (striped rock)
    RETURN
.t_block_find:
    INVOKE block_find, rsi
    cmp eax, -1
    je .bad_block
    mov [r13], eax
    RETURN
.bad_block:
    lea rcx, [rel str_bad_block]
    mov rdx, rsi
    call warn
    RETURN
.t_range:                               ; "a, b" (or one value: a = b)
    mov [LOCAL(0)], eax                 ; type
    mov rcx, rsi
    call cfg_next_token
    mov rdi, rdx                        ; rest
    mov rcx, rax
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    movss [LOCAL(4)], xmm0
    movss [LOCAL(8)], xmm0
    test rdi, rdi
    jz .range_store
    mov rcx, rdi
    call cfg_next_token
    mov rcx, rax
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    movss [LOCAL(8)], xmm0
.range_store:
    movss xmm0, [LOCAL(4)]
    movss xmm1, [LOCAL(8)]
    cmp dword [LOCAL(0)], T_RANGE_I
    je .range_int
    movss [r13], xmm0
    movss [r13 + 4], xmm1
    RETURN
.range_int:
    cvttss2si eax, xmm0
    mov [r13], eax
    cvttss2si eax, xmm1
    mov [r13 + 4], eax
    RETURN
.t_color:
    mov rcx, rsi
    call parse_hex
    test edx, edx
    jz .bad
    mov [r13], eax
    RETURN
.t_plant:                               ; block, chance
    cmp dword [r13], BIOME_PLANTS
    jae .full_list
    mov rcx, rsi
    call cfg_next_token
    mov rdi, rdx
    INVOKE block_find, rax
    cmp eax, -1
    je .bad_block
    mov ecx, [r13]
    mov [r13 + 4 + rcx * 4], eax
    mov rcx, rdi
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    mov ecx, [r13]
    movss [r13 + 4 + BIOME_PLANTS * 4 + rcx * 4], xmm0
    inc dword [r13]
    RETURN
.t_treeref:                             ; tree, weight (default 1)
    cmp dword [r13], BIOME_TREES
    jae .full_list
    mov rcx, rsi
    call cfg_next_token
    mov rdi, rdx
    mov rcx, rax
    mov [LOCAL(0)], rax
    call find_tree
    cmp eax, -1
    je .bad_tree
    mov ecx, [r13]
    mov [r13 + 4 + rcx * 4], eax
    mov dword [r13 + 4 + BIOME_TREES * 4 + rcx * 4], 0x3F800000
    test rdi, rdi
    jz .tref_done
    mov rcx, rdi
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    mov ecx, [r13]
    movss [r13 + 4 + BIOME_TREES * 4 + rcx * 4], xmm0
.tref_done:
    inc dword [r13]
    RETURN
.bad_tree:
    lea rcx, [rel str_bad_tree]
    mov rdx, [LOCAL(0)]
    call warn
    RETURN
.t_patch:                               ; block, level
    mov rcx, rsi
    call cfg_next_token
    mov rdi, rdx
    mov [LOCAL(0)], rax
    INVOKE block_find, rax
    cmp eax, -1
    je .patch_bad
    mov [r13], eax
    mov rcx, rdi
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    movss [r13 + 4], xmm0
    RETURN
.patch_bad:
    lea rcx, [rel str_bad_block]
    mov rdx, [LOCAL(0)]
    call warn
    RETURN
.t_blocklist:
    mov rdi, rsi
.bl_token:
    test rdi, rdi
    jz .done
    mov rcx, rdi
    call cfg_next_token
    mov rdi, rdx
    cmp byte [rax], 0
    je .bl_token
    mov [LOCAL(0)], rax
    INVOKE block_find, rax
    cmp eax, -1
    je .bl_bad
    cmp dword [r13], BIOME_FLOWERS
    jae .full_list
    mov ecx, [r13]
    mov [r13 + 4 + rcx * 4], eax
    inc dword [r13]
    jmp .bl_token
.bl_bad:
    lea rcx, [rel str_bad_block]
    mov rdx, [LOCAL(0)]
    call warn
    jmp .bl_token
.full_list:
    lea rcx, [rel str_too_many]
    mov rdx, rbx
    call warn
    RETURN

.noise:
    mov eax, [rel g_rec]
    imul rdi, rax, NOISE_size
    lea rax, [rel g_clim_noise]
    add rdi, rax
    mov rcx, rsi
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    movss [LOCAL(0)], xmm0
    lea rdx, [rel k_scale]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .n_oct
    movss xmm0, [LOCAL(0)]
    cvtss2sd xmm0, xmm0
    movsd xmm1, [rel c_one_d]
    divsd xmm1, xmm0
    movsd [rdi + NOISE.freq], xmm1
    RETURN
.n_oct:
    cvttss2si r12d, [LOCAL(0)]
    lea rdx, [rel k_octaves]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .n_pers
    mov [rdi + NOISE.octaves], r12d
    RETURN
.n_pers:
    lea rdx, [rel k_persistence]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .n_salt
    movss xmm0, [LOCAL(0)]
    movss [rdi + NOISE.persistence], xmm0
    RETURN
.n_salt:
    lea rdx, [rel k_ridged]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .n_salt2
    mov [rdi + NOISE.ridged], r12d
    RETURN
.n_salt2:
    lea rdx, [rel k_salt]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov [rdi + NOISE.salt], r12d
    RETURN
.bad:
    lea rcx, [rel str_bad]
    mov rdx, rbx
    call warn
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; biome_climate — temperature, humidity, weirdness and rarity at a point
; (0..1).
;   in:  xmm0 = x, xmm1 = z (doubles)
;   out: xmm0 = temperature, xmm1 = humidity, xmm2 = weirdness, xmm3 = rarity
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC biome_climate, 32, rbx
    movsd [LOCAL(0)], xmm0
    movsd [LOCAL(8)], xmm1
    xor ebx, ebx
.f:
    mov eax, ebx
    cmp eax, 3
    jne .f_idx
    mov eax, 7                          ; (the 4th value: the rarity field)
.f_idx:
    imul rcx, rax, NOISE_size
    lea rax, [rel g_clim_noise]
    add rcx, rax
    movsd xmm1, [LOCAL(0)]
    movsd xmm2, [LOCAL(8)]
    mov edx, [rel g_world_seed]
    call fbm2
    call clim_norm
    movss [LOCAL(16) + rbx * 4], xmm0
    inc ebx
    cmp ebx, 4
    jb .f
    movss xmm0, [LOCAL(16)]
    movss xmm1, [LOCAL(20)]
    movss xmm2, [LOCAL(24)]
    movss xmm3, [LOCAL(28)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; biome_point — the (unblended) biome at a world point with a surface height.
;   in:  xmm0 = x, xmm1 = z (doubles), ecx = surface height
;   out: eax = biome      clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC biome_point, 0, rbx
    mov ebx, ecx
    call biome_climate
    mov ecx, ebx
    call biome_pick
    RETURN
ENDPROC

; clim_norm: xmm0 = clamp(0.5 + n * contrast, 0, 1)   clobbers xmm1
clim_norm:
    mulss xmm0, [rel g_contrast]
    addss xmm0, [rel c_half]
    maxss xmm0, [rel c_zero]
    minss xmm0, [rel c_one]
    ret

; -----------------------------------------------------------------------------
; biome_pick — the biome for a climate and surface height: among the boxes
; that contain the climate, the highest priority, then the nearest centre.
;   in:  xmm0 = temperature, xmm1 = humidity, xmm2 = weirdness,
;        xmm3 = rarity, ecx = surface height
;   out: eax = biome index (0 = none)
;   clobbers: rax, rcx, rdx, r8-r11, xmm3-xmm5
; -----------------------------------------------------------------------------
biome_pick:
    sub rsp, 8                          ; (one float of scratch, the rarity)
    movss [rsp + 4], xmm3
    xor eax, eax                        ; best
    movss xmm5, [rel c_big]             ; best distance
    mov r11d, 0x80000000                ; best priority
    mov edx, 1
    lea r8, [rel g_biomes + BIOME_size]
.b:
    cmp edx, [rel g_biome_count]
    jae .done
    cmp ecx, [r8 + BIOME.height]
    jl .next
    cmp ecx, [r8 + BIOME.height + 4]
    jg .next
    comiss xmm0, [r8 + BIOME.temp]
    jb .next
    comiss xmm0, [r8 + BIOME.temp + 4]
    ja .next
    comiss xmm1, [r8 + BIOME.humid]
    jb .next
    comiss xmm1, [r8 + BIOME.humid + 4]
    ja .next
    comiss xmm2, [r8 + BIOME.weird]
    jb .next
    comiss xmm2, [r8 + BIOME.weird + 4]
    ja .next
    movss xmm4, [rsp + 4]
    comiss xmm4, [r8 + BIOME.rarity]
    jb .next
    comiss xmm4, [r8 + BIOME.rarity + 4]
    ja .next
    ; distance to the box centre, relative to its size
    movss xmm3, [r8 + BIOME.temp]
    addss xmm3, [r8 + BIOME.temp + 4]
    mulss xmm3, [rel c_half]
    subss xmm3, xmm0
    movss xmm4, [r8 + BIOME.temp + 4]
    subss xmm4, [r8 + BIOME.temp]
    addss xmm4, [rel c_inv16]           ; (never 0)
    divss xmm3, xmm4
    mulss xmm3, xmm3
    movss [rsp], xmm3
    movss xmm3, [r8 + BIOME.humid]
    addss xmm3, [r8 + BIOME.humid + 4]
    mulss xmm3, [rel c_half]
    subss xmm3, xmm1
    movss xmm4, [r8 + BIOME.humid + 4]
    subss xmm4, [r8 + BIOME.humid]
    addss xmm4, [rel c_inv16]
    divss xmm3, xmm4
    mulss xmm3, xmm3
    addss xmm3, [rsp]                   ; distance^2
    mov r10d, [r8 + BIOME.priority]
    cmp r10d, r11d
    jg .take                            ; higher priority
    jl .next
    comiss xmm3, xmm5
    jae .next
.take:
    movss xmm5, xmm3
    mov r11d, r10d
    mov eax, edx
.next:
    inc edx
    add r8, BIOME_size
    jmp .b
.done:
    add rsp, 8
    ret

; -----------------------------------------------------------------------------
; bmap_build — biome samples around a chunk and their blurred weights.
;   in:  rcx = BMAP*, edx = cx, r8d = cz
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define BB_I        0
%define BB_J        4
%define BB_X        8
%define BB_Z        12
%define BB_T        16
%define BB_H        20
%define BB_S        32                  ; TSAMPLE
%define BB_LOCALS   (32 + TSAMPLE_size)
PROC bmap_build, BB_LOCALS, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    mov [rbx + BMAP.cx], edx
    mov [rbx + BMAP.cz], r8d
    ; ---- raw samples ----
    xor r12d, r12d                      ; j (z)
.rz:
    xor r13d, r13d                      ; i (x)
.rx:
    mov eax, [rbx + BMAP.cx]
    shl eax, 5
    imul ecx, r13d, BM_STEP
    lea eax, [eax + ecx - 64]
    mov [LOCAL(BB_X)], eax
    mov eax, [rbx + BMAP.cz]
    shl eax, 5
    imul ecx, r12d, BM_STEP
    lea eax, [eax + ecx - 64]
    mov [LOCAL(BB_Z)], eax
    cvtsi2sd xmm0, dword [LOCAL(BB_X)]
    cvtsi2sd xmm1, dword [LOCAL(BB_Z)]
    lea rcx, [LOCAL(BB_S)]
    call terrain_sample
    cvtsi2sd xmm0, dword [LOCAL(BB_X)]
    cvtsi2sd xmm1, dword [LOCAL(BB_Z)]
    cvttss2si ecx, [LOCAL(BB_S) + TSAMPLE.height]
    call biome_point
    imul ecx, r12d, BM_RAW
    add ecx, r13d
    mov [rbx + BMAP.raw + rcx], al
    inc r13d
    cmp r13d, BM_RAW
    jb .rx
    inc r12d
    cmp r12d, BM_RAW
    jb .rz
    ; ---- blur: point (pj, pi) = tent over raw (pj..pj+4, pi..pi+4) ----
    lea rdi, [rbx + BMAP.w]
    xor eax, eax
    mov ecx, BM_PTS * BM_PTS * MAX_BIOMES
    rep stosd
    xor r12d, r12d                      ; pj
.pz:
    xor r13d, r13d                      ; pi
.px:
    imul eax, r12d, BM_PTS
    add eax, r13d
    imul rsi, rax, MAX_BIOMES * 4
    lea rsi, [rbx + BMAP.w + rsi]       ; weight vector
    xor r8d, r8d                        ; dj
.dj:
    xor r9d, r9d                        ; di
.di:
    lea eax, [r12d + r8d]
    imul eax, eax, BM_RAW
    add eax, r13d
    add eax, r9d
    movzx eax, byte [rbx + BMAP.raw + rax]
    lea rcx, [rel tent]
    movss xmm0, [rcx + r8 * 4]
    mulss xmm0, [rcx + r9 * 4]
    mulss xmm0, [rel c_inv81]
    addss xmm0, [rsi + rax * 4]
    movss [rsi + rax * 4], xmm0
    inc r9d
    cmp r9d, 5
    jb .di
    inc r8d
    cmp r8d, 5
    jb .dj
    inc r13d
    cmp r13d, BM_PTS
    jb .px
    inc r12d
    cmp r12d, BM_PTS
    jb .pz
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; bmap_weights — bilinear blend of the weight vectors at a local block.
;   in:  rcx = BMAP*, edx = lx, r8d = lz (-32..63), r9 = out f32[MAX_BIOMES]
;   clobbers: rax, rcx, rdx, r8, r10, r11, xmm0-xmm5
; -----------------------------------------------------------------------------
bmap_weights:
    add edx, 32
    add r8d, 32
    mov eax, edx
    shr eax, 4                          ; point i (0..5)
    and edx, 15
    cvtsi2ss xmm4, edx
    mulss xmm4, [rel c_inv16]           ; fx
    mov r10d, r8d
    shr r10d, 4                         ; point j
    and r8d, 15
    cvtsi2ss xmm5, r8d
    mulss xmm5, [rel c_inv16]           ; fz
    imul r10d, r10d, BM_PTS
    add eax, r10d
    imul rax, rax, MAX_BIOMES * 4
    lea r10, [rcx + BMAP.w + rax]       ; (i, j); +MB*4 = i+1; +PTS*MB*4 = j+1
    xor r11d, r11d
.b:
    movss xmm0, [r10 + r11 * 4]
    movss xmm1, [r10 + r11 * 4 + MAX_BIOMES * 4]
    subss xmm1, xmm0
    mulss xmm1, xmm4
    addss xmm0, xmm1                    ; top row
    movss xmm2, [r10 + r11 * 4 + BM_PTS * MAX_BIOMES * 4]
    movss xmm3, [r10 + r11 * 4 + BM_PTS * MAX_BIOMES * 4 + MAX_BIOMES * 4]
    subss xmm3, xmm2
    mulss xmm3, xmm4
    addss xmm2, xmm3                    ; bottom row
    subss xmm2, xmm0
    mulss xmm2, xmm5
    addss xmm0, xmm2
    movss [r9 + r11 * 4], xmm0
    inc r11d
    cmp r11d, [rel g_biome_count]
    jb .b
    ret

; -----------------------------------------------------------------------------
; bmap_col — biome, vegetation density and hill factor at a local block.
;   in:  rcx = BMAP*, edx = lx, r8d = lz (-32..63)
;   out: eax = biome, xmm0 = density 0..1, xmm1 = hill factor
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC bmap_col, MAX_BIOMES * 4
    lea r9, [LOCAL(0)]
    call bmap_weights
    xor eax, eax                        ; argmax
    xorps xmm2, xmm2                    ; max weight
    xorps xmm1, xmm1                    ; hill
    xorps xmm4, xmm4                    ; dune height
    xorps xmm5, xmm5                    ; plateau height
    xor ecx, ecx
    lea r8, [rel g_biomes]
.b:
    movss xmm0, [LOCAL(0) + rcx * 4]
    movss xmm3, xmm0
    mulss xmm3, [r8 + BIOME.hill]
    addss xmm1, xmm3
    movss xmm3, xmm0
    mulss xmm3, [r8 + BIOME.dune_h]
    addss xmm4, xmm3
    movss xmm3, xmm0
    mulss xmm3, [r8 + BIOME.plateau_h]
    addss xmm5, xmm3
    comiss xmm0, xmm2
    jbe .next
    movss xmm2, xmm0
    mov eax, ecx
.next:
    add r8, BIOME_size
    inc ecx
    cmp ecx, [rel g_biome_count]
    jb .b
    ; density: 0 at weight 0.5 (the border) .. 1 at 0.85
    movss xmm0, xmm2
    subss xmm0, [rel c_dens_lo]
    mulss xmm0, [rel c_dens_inv]
    maxss xmm0, [rel c_zero]
    minss xmm0, [rel c_one]
    movss xmm2, xmm4
    movss xmm3, xmm5
    ; blended mesa height
    xorps xmm4, xmm4
    xor ecx, ecx
    lea r8, [rel g_biomes]
.m:
    movss xmm5, [LOCAL(0) + rcx * 4]
    mulss xmm5, [r8 + BIOME.mesa_h]
    addss xmm4, xmm5
    add r8, BIOME_size
    inc ecx
    cmp ecx, [rel g_biome_count]
    jb .m
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; bmap_dither — the biome of a column with a ragged border: where the two
; strongest biomes are close (weight difference below `jitter`), the second
; one wins. With a per-block noise as the jitter, biome borders (and the top
; blocks that follow them: snow, red sand) fray instead of running straight.
;   in:  rcx = BMAP*, edx = lx, r8d = lz, xmm0 = jitter (f32)
;   out: eax = biome      clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC bmap_dither, MAX_BIOMES * 4 + 16
    movss [LOCAL(MAX_BIOMES * 4)], xmm0
    lea r9, [LOCAL(0)]
    call bmap_weights
    xor eax, eax                        ; best
    xor edx, edx                        ; second
    xorps xmm1, xmm1                    ; best weight
    xorps xmm2, xmm2                    ; second weight
    xor ecx, ecx
.b:
    movss xmm0, [LOCAL(0) + rcx * 4]
    comiss xmm0, xmm1
    jbe .not_best
    movss xmm2, xmm1
    mov edx, eax
    movss xmm1, xmm0
    mov eax, ecx
    jmp .next
.not_best:
    comiss xmm0, xmm2
    jbe .next
    movss xmm2, xmm0
    mov edx, ecx
.next:
    inc ecx
    cmp ecx, [rel g_biome_count]
    jb .b
    subss xmm1, xmm2
    comiss xmm1, [LOCAL(MAX_BIOMES * 4)]
    jae .done
    xorps xmm0, xmm0
    comiss xmm2, xmm0
    jbe .done                           ; (no second biome here)
    mov eax, edx
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; bmap_flatten — the blended `flatten` pull at a local block: how strongly the
; land is drawn to a level (swamps: just above the sea), and that level.
;   in:  rcx = BMAP*, edx = lx, r8d = lz
;   out: xmm0 = pull 0..1, xmm1 = target height (valid when pull > 0)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC bmap_flatten, MAX_BIOMES * 4
    lea r9, [LOCAL(0)]
    call bmap_weights
    xorps xmm0, xmm0                    ; sum w * pull
    xorps xmm1, xmm1                    ; sum w * pull * target
    xor ecx, ecx
    lea r8, [rel g_biomes]
.b:
    movss xmm2, [LOCAL(0) + rcx * 4]
    mulss xmm2, [r8 + BIOME.flatten + 4]
    addss xmm0, xmm2
    mulss xmm2, [r8 + BIOME.flatten]
    addss xmm1, xmm2
    add r8, BIOME_size
    inc ecx
    cmp ecx, [rel g_biome_count]
    jb .b
    xorps xmm2, xmm2
    comiss xmm0, xmm2
    jbe .done
    divss xmm1, xmm0
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; biome_mesa — mesa shape 0..1 at a world point (design/biomes/badlands.md):
; the "mesas" field ramps to a mask m = clamp((n - thr) * ramp), which is
; cut into MESA_STEPS flat terraces with steep risers in the last quarter
; of each step: buttes and stepped mesas with cliffs between.
;   in:  xmm0 = x, xmm1 = z (doubles)     out: xmm0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define MESA_STEPS  3
PROC biome_mesa, 0
    movsd xmm2, xmm1
    movsd xmm1, xmm0
    lea rcx, [rel g_clim_noise + 5 * NOISE_size]
    mov edx, [rel g_world_seed]
    call fbm2
    subss xmm0, [rel c_mesa_thr]
    mulss xmm0, [rel c_mesa_ramp]
    maxss xmm0, [rel c_zero]
    minss xmm0, [rel c_one]
    mulss xmm0, [rel c_mesa_steps]      ; s = m * steps
    roundss xmm1, xmm0, 9               ; i = floor(s)
    subss xmm0, xmm1                    ; f
    subss xmm0, [rel c_mesa_riser]      ; riser: f 0.75 .. 1 -> 0 .. 1
    mulss xmm0, [rel c_four]
    maxss xmm0, [rel c_zero]
    minss xmm0, [rel c_one]
    addss xmm0, xmm1
    divss xmm0, [rel c_mesa_steps]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; biome_strata_wave — the slow "strata" field at a world point, in blocks
; (bands shift up and down by up to STRATA_WAVE).
;   in:  xmm0 = x, xmm1 = z (doubles)     out: eax (signed)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC biome_strata_wave, 0
    movsd xmm2, xmm1
    movsd xmm1, xmm0
    lea rcx, [rel g_clim_noise + 6 * NOISE_size]
    mov edx, [rel g_world_seed]
    call fbm2
    mulss xmm0, [rel c_strata_wave]
    cvtss2si eax, xmm0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; strata_build — fill every biome's band table (g_strata, STRATA_LEN ids):
; its `strata` blocks in seeded random order (never the same twice in a
; row), each `strata_thickness` thick; biomes without bands get stone.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC strata_build, 0, rbx, rsi, rdi, r12, r13
    xor ebx, ebx                        ; biome
.biome:
    cmp ebx, [rel g_biome_count]
    jae .done
    imul rsi, rbx, BIOME_size
    lea rax, [rel g_biomes]
    add rsi, rax
    mov eax, ebx
    shl eax, 8                          ; (STRATA_LEN * 2 bytes)
    lea rdi, [rel g_strata]
    add rdi, rax
    cmp dword [rsi + BIOME.nstrata], 0
    jne .bands
    xor ecx, ecx
    mov eax, [rel g_b_stone]
.fill_stone:
    mov [rdi + rcx * 2], ax
    inc ecx
    cmp ecx, STRATA_LEN
    jb .fill_stone
    jmp .next
.bands:
    ; mark the band blocks (ores may replace them)
    xor ecx, ecx
.mark:
    mov eax, [rsi + BIOME.strata + rcx * 4]
    lea rdx, [rel g_is_strata]
    mov byte [rdx + rax], 1
    inc ecx
    cmp ecx, [rsi + BIOME.nstrata]
    jb .mark
    ; walk the table: hash -> band, hash -> thickness
    mov r12d, [rel g_world_seed]
    imul eax, ebx, 0x9E3779B1
    xor r12d, eax                       ; rng state
    xor r13d, r13d                      ; y
    mov r8d, -1                         ; previous band
.band:
    cmp r13d, STRATA_LEN
    jae .next
    imul r12d, r12d, 1664525
    add r12d, 1013904223
    mov eax, r12d
    shr eax, 8
    xor edx, edx
    div dword [rsi + BIOME.nstrata]
    cmp edx, r8d
    jne .band_ok
    inc edx                             ; not the same band twice in a row
    cmp edx, [rsi + BIOME.nstrata]
    jb .band_ok
    xor edx, edx
.band_ok:
    mov r8d, edx
    mov r9d, [rsi + BIOME.strata + rdx * 4]
    imul r12d, r12d, 1664525
    add r12d, 1013904223
    mov eax, r12d
    shr eax, 8
    mov ecx, [rsi + BIOME.strata_thick + 4]
    sub ecx, [rsi + BIOME.strata_thick]
    inc ecx
    xor edx, edx
    div ecx
    add edx, [rsi + BIOME.strata_thick]
    jg .thick_ok
    mov edx, 1
.thick_ok:
    mov [rdi + r13 * 2], r9w
    inc r13d
    cmp r13d, STRATA_LEN
    jae .next
    dec edx
    jnz .thick_ok
    jmp .band
.next:
    inc ebx
    jmp .biome
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; biome_plateau — plateau shape 0..1 at a world point: 0 below the
; "plateaus" field's threshold, a steep ramp (cliffs) to 1 above it.
;   in:  xmm0 = x, xmm1 = z (doubles)     out: xmm0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC biome_plateau, 0
    movsd xmm2, xmm1
    movsd xmm1, xmm0
    lea rcx, [rel g_clim_noise + 4 * NOISE_size]
    mov edx, [rel g_world_seed]
    call fbm2
    subss xmm0, [rel c_plateau_thr]
    mulss xmm0, [rel c_plateau_ramp]
    maxss xmm0, [rel c_zero]
    minss xmm0, [rel c_one]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; biome_dunes — dune shape 0..1 at a world point (the ridged "dunes" field:
; crests near 1, flat basins at 0).
;   in:  xmm0 = x, xmm1 = z (doubles)     out: xmm0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC biome_dunes, 0
    movsd xmm2, xmm1
    movsd xmm1, xmm0
    lea rcx, [rel g_clim_noise + 3 * NOISE_size]
    mov edx, [rel g_world_seed]
    call fbm2
    ; ridged sums are about -1 .. 1: map to 0 .. 1 and sharpen
    addss xmm0, [rel c_one]
    mulss xmm0, [rel c_half]
    maxss xmm0, [rel c_zero]
    minss xmm0, [rel c_one]
    mulss xmm0, xmm0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; bmap_tint — blended grass, foliage and water tint factors at a local block
; (out: eax grass, edx foliage, ecx water).
;   in:  rcx = BMAP*, edx = lx, r8d = lz
;   out: eax = grass RGBA8, edx = foliage RGBA8
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC bmap_tint, MAX_BIOMES * 4 + 32, rbx
    lea r9, [LOCAL(0)]
    call bmap_weights
    xor ebx, ebx                        ; 0 grass, 1 foliage
.layer:
    xorps xmm3, xmm3                    ; r
    xorps xmm4, xmm4                    ; g
    xorps xmm5, xmm5                    ; b
    xor ecx, ecx
    lea r8, [rel g_biomes]
.b:
    movss xmm0, [LOCAL(0) + rcx * 4]
    mov eax, [r8 + BIOME.gfac]
    test ebx, ebx
    jz .have
    mov eax, [r8 + BIOME.ffac]
    cmp ebx, 1
    je .have
    mov eax, [r8 + BIOME.wfac]
.have:
    movzx edx, al
    cvtsi2ss xmm1, edx
    mulss xmm1, xmm0
    addss xmm3, xmm1
    movzx edx, ah
    cvtsi2ss xmm1, edx
    mulss xmm1, xmm0
    addss xmm4, xmm1
    shr eax, 16
    movzx edx, al
    cvtsi2ss xmm1, edx
    mulss xmm1, xmm0
    addss xmm5, xmm1
    add r8, BIOME_size
    inc ecx
    cmp ecx, [rel g_biome_count]
    jb .b
    cvtss2si eax, xmm3
    cvtss2si ecx, xmm4
    shl ecx, 8
    or eax, ecx
    cvtss2si ecx, xmm5
    shl ecx, 16
    or eax, ecx
    or eax, 0xFF000000
    mov [LOCAL(MAX_BIOMES * 4) + rbx * 4], eax
    inc ebx
    cmp ebx, 3
    jb .layer
    mov eax, [LOCAL(MAX_BIOMES * 4)]
    mov edx, [LOCAL(MAX_BIOMES * 4 + 4)]
    mov ecx, [LOCAL(MAX_BIOMES * 4 + 8)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; biome_at — name of the biome at a world block (debug overlay). Builds and
; caches the blend map of the block's chunk (main thread only).
;   in:  ecx = x, edx = z      out: rax = name
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC biome_at, 0, rbx, rsi, rdi
    mov esi, ecx
    mov edi, edx
    mov eax, esi
    sar eax, 5
    mov ecx, edi
    sar ecx, 5
    cmp dword [rel g_at_valid], 0
    je .build
    cmp eax, [rel g_at_cx]
    jne .build
    cmp ecx, [rel g_at_cz]
    je .have
.build:
    mov [rel g_at_cx], eax
    mov [rel g_at_cz], ecx
    lea rcx, [rel g_at_map]
    mov edx, [rel g_at_cx]
    mov r8d, [rel g_at_cz]
    call bmap_build
    mov dword [rel g_at_valid], 1
.have:
    lea rcx, [rel g_at_map]
    mov edx, esi
    and edx, 31
    mov r8d, edi
    and r8d, 31
    call bmap_col
    imul rax, rax, BIOME_size
    lea rcx, [rel g_biomes]
    mov rax, [rcx + rax + BIOME.name]
    RETURN
ENDPROC
