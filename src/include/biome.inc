; =============================================================================
; biome.inc — biome registry, climate and per-chunk blend maps
; (src/world/biome.asm, DATA_FORMAT.md "Biome files", design/biomes/).
; =============================================================================
%ifndef BIOME_INC
%define BIOME_INC

%define MAX_BIOMES      32              ; including 0 = "none" (no biome yet)
%define MAX_TREES       32
%define BIOME_PLANTS    8
%define BIOME_FLOWERS   16
%define BIOME_TREES     8

%define TREE_ROUND      0               ; trunk + round crown (small oak)
%define TREE_BRANCHING  1               ; trunk + branches with leaf clusters
%define TREE_BUSH       2               ; log stub + low leaf clump
%define TREE_GIANT      3               ; tapering trunk, roots, heavy branches
%define TREE_FALLEN     4               ; a log lying on the ground
%define TREE_STUMP      5               ; a short upright log

; per-chunk blend map: biome samples every 16 blocks from -64 to +96 around
; the chunk, blurred (tent filter, radius 32) into points from -32 to +64
%define BM_RAW          11
%define BM_PTS          7
%define BM_STEP         16

struc BIOME
    .name           resq 1              ; char*
    .temp           resd 2              ; temperature range (0..1)
    .humid          resd 2              ; humidity range (0..1)
    .height         resd 2              ; surface height range (int)
    .hill           resd 1              ; float: hill height factor
    .grass          resd 1              ; 0xRRGGBB
    .foliage        resd 1
    .gfac           resd 1              ; RGBA8 tint factors (128 = 1.0)
    .ffac           resd 1
    .top            resd 1              ; block id (0 = terrain default)
    .filler         resd 1
    .flower_ch      resd 1              ; float: share of grass with flowers
    .meadow_ch      resd 1              ; float: chance per 512 x 512 cell
    .meadow_r       resd 2              ; float radius range
    .meadow_dens    resd 1              ; float: flower share inside
    .meadow_mixed   resd 1              ; float: share of mixed meadows
    .tree_dens      resd 1              ; float: trees per block^2
    .bush_dens      resd 1
    .pond_ch        resd 1              ; float: chance per 128 x 128 cell
    .pond_r         resd 2              ; float radius range (max 7)
    .pond_depth     resd 1              ; int: deepest water
    .pond_floor     resd 1              ; block (0 = filler)
    .nplants        resd 1              ; ground cover: block, chance
    .plant          resd BIOME_PLANTS
    .plant_ch       resd BIOME_PLANTS
    .nflowers       resd 1
    .flower         resd BIOME_FLOWERS
    .ntrees         resd 1              ; trees: TREE index, weight
    .tree           resd BIOME_TREES
    .tree_w         resd BIOME_TREES
    .nbushes        resd 1
    .bush           resd BIOME_TREES
    .bush_w         resd BIOME_TREES
    .weird          resd 2              ; weirdness range (rare pockets)
    .priority       resd 1              ; higher wins where boxes overlap
    .litter         resd 1              ; block near tree trunks (0 = none)
    .litter_r       resd 1              ; int radius around trunks
    .litter_ch      resd 1              ; float share inside the radius
    .nshade         resd 1              ; plants on litter: block, chance
    .shade          resd BIOME_PLANTS
    .shade_ch       resd BIOME_PLANTS
    .clear_ch       resd 1              ; clearing chance per 160 x 160 cell
    .clear_r        resd 2              ; float radius range
    .clear_fl       resd 1              ; flower share inside clearings
    .ring_ch        resd 1              ; mushroom ring chance per 128 x 128
    .ring_r         resd 2              ; float radius range
    .nrings         resd 1              ; ring plants (block list)
    .ring           resd BIOME_FLOWERS
    .patch          resd 1              ; top patch block (0 = none)
    .patch_lvl      resd 1              ; float: detail noise above this
    .meadow_cell    resd 1              ; meadow candidate cell size (power of 2)
    .nmflowers      resd 1              ; meadow flowers (0 = use `flowers`)
    .mflower        resd BIOME_FLOWERS
endstruc

struc TREE
    .name           resq 1
    .kind           resd 1              ; TREE_*
    .log            resd 1              ; block ids
    .leaves         resd 1
    .height         resd 2              ; int trunk height range
    .radius         resd 2              ; float crown radius range
    .branches       resd 2              ; int branch count range
    .gaps           resd 1              ; float: chance to drop an edge leaf
    .base_r         resd 2              ; float trunk base radius range (giant)
    .roots          resd 2              ; int root count range (giant)
endstruc

struc BMAP
    .cx             resd 1
    .cz             resd 1
    .raw            resb 124            ; BM_RAW^2 biome ids
    .w              resd BM_PTS * BM_PTS * MAX_BIOMES
endstruc

%ifndef BIOME_IMPL
extern biomes_load, biome_climate, biome_pick, bmap_build, bmap_col, bmap_tint
extern biome_at, biome_point
extern g_biomes, g_biome_count, g_trees, g_tree_count
%endif
%endif
