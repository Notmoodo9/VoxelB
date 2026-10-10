; =============================================================================
; biome.inc — biome registry, climate and per-chunk blend maps
; (src/world/biome.asm, DATA_FORMAT.md "Biome files", design/biomes/).
; =============================================================================
%ifndef BIOME_INC
%define BIOME_INC

%define MAX_BIOMES      32              ; including 0 = "none" (no biome yet)
%define MAX_TREES       64
%define BIOME_PLANTS    8
%define BIOME_FLOWERS   16
%define BIOME_TREES     8

%define TREE_ROUND      0               ; trunk + round crown (small oak)
%define TREE_BRANCHING  1               ; trunk + branches with leaf clusters
%define TREE_BUSH       2               ; log stub + low leaf clump
%define TREE_GIANT      3               ; tapering trunk, roots, heavy branches
%define TREE_FALLEN     4               ; a log lying on the ground
%define TREE_STUMP      5               ; a short upright log
%define TREE_CACTUS     6               ; column with arms and a flower on top
%define TREE_ROCK       7               ; stacked discs shrinking upward (boulder, spire)
%define TREE_ARCH       8               ; a half-ring with legs into the ground
%define TREE_FOSSIL     9               ; a half-buried spine with ribs
%define TREE_PALM       10              ; leaning curved trunk, drooping fronds
%define TREE_CONIFER    11              ; tall trunk with tiers of needles to a tip
%define TREE_ACACIA     12              ; forked trunk with flat leaf pads
%define TREE_BAOBAB     13              ; fat bottle trunk, stubby branches
%define TREE_KAPOK      14              ; buttress fins, tall bare trunk, umbrella crown
%define TREE_GROVE      15              ; a disc of thin stalks (bamboo grove)
%define TREE_STONE_RING 16              ; standing stones evenly on a ring
%define TREE_CYPRESS    17              ; flared trunk, flat layered crowns, knees
%define TREE_GNARLED    18              ; twisting leaning trunk, crooked branches
%define TREE_MUSHROOM   19              ; stem with a dome or flat cap (giant mushrooms)
%define TREE_SPIKE      20              ; a tapering spire with a core (ice spikes)

; per-chunk blend map: biome samples every 16 blocks from -64 to +96 around
; the chunk, blurred (tent filter, radius 32) into points from -32 to +64
%define BM_RAW          11
%define BM_PTS          7
%define BM_STEP         16

; a block id that stands for "the striped band at this height" (badlands):
; the biome's band table (g_strata) picks the real block by world y
%define BLOCK_STRATA    0xFFFE
%define STRATA_LEN      128             ; bands repeat every 128 blocks

struc BIOME
    .name           resq 1              ; char*
    .temp           resd 2              ; temperature range (0..1)
    .humid          resd 2              ; humidity range (0..1)
    .height         resd 2              ; surface height range (int)
    .hill           resd 1              ; float: hill height factor
    .grass          resd 1              ; 0xRRGGBB
    .foliage        resd 1
    .gfac           resd 1              ; RGBA8 tint factors (64 = 1.0, up to 4x)
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
    .dune_h         resd 1              ; float: dune height (blended)
    .steep          resd 1              ; block on steep slopes (0 = stone)
    .pond_slope     resd 1              ; int: ground height range a pond may cut into
    .plateau_h      resd 1              ; float: plateau height (blended)
    .patch_low      resd 1              ; top patch where the detail noise is below a level
    .patch_low_lvl  resd 1
    .pond_top       resd 1              ; block for a pond's top water layer (0 = water; ice)
    .mesa_h         resd 1              ; float: mesa height (blended, terraced)
    .nstrata        resd 1              ; band blocks of striped rock (badlands)
    .strata         resd BIOME_FLOWERS
    .strata_thick   resd 2              ; int band thickness range
    .strata_min     resd 1              ; int: bands from this world y up
    .wash           resd 1              ; block of dry washes on low ground (0 = none)
    .beach          resd 1              ; shore band block (0 = the world's beach sand)
    .dry_block      resd 1              ; dry hollows: floor block (salt), share of ponds
    .dry_share      resd 1
    .water          resd 1              ; 0xRRGGBB water colour, and its factor
    .wfac           resd 1
    .flatten        resd 2              ; f32 target height, pull 0..1 (blended)
    .own_shore      resd 1              ; 1: the shore band uses the biome's own ground
    .nwplants       resd 1              ; water plants: block, chance (on the surface)
    .wplant         resd BIOME_PLANTS
    .wplant_ch      resd BIOME_PLANTS
    .rarity         resd 2              ; range of the "rarity" field (rare pockets)
    .isle_ch        resd 1              ; floating islands: chance per 48 x 48 cell
    .isle_r         resd 2              ; f32 radius range (max 25)
    .isle_y         resd 2              ; int centre height range
    .nisle_ore      resd 1              ; blocks in the island stone: block, chance
    .isle_ore       resd BIOME_PLANTS
    .isle_ore_ch    resd BIOME_PLANTS
    .isle_roots     resd 1              ; strands under the islands: block, chance
    .isle_roots_ch  resd 1
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
    .chance         resd 1              ; float: kind-specific chance (cactus flower, arms)
    .vine           resd 1              ; trunk-side vine block (ladder shape), chance per side
    .vine_ch        resd 1
    .hang           resd 1              ; hanging strand block under leaves, chance per leaf
    .hang_ch        resd 1
    .fungus         resd 1              ; shelf fungus block on trunk sides, chance per side
    .fungus_ch      resd 1
    .pod            resd 1              ; pod block on trunk sides, chance per tree (1-3 pods)
    .pod_ch         resd 1
    .vine_len       resd 2              ; int length range of vines and strands
    .lean           resd 1              ; float: blocks east per block of height (wind)
    .under          resd 1              ; block under a mushroom cap (gills), 0 = none
endstruc

struc BMAP
    .cx             resd 1
    .cz             resd 1
    .raw            resb 124            ; BM_RAW^2 biome ids
    .w              resd BM_PTS * BM_PTS * MAX_BIOMES
endstruc

%ifndef BIOME_IMPL
extern biomes_load, biome_climate, biome_pick, bmap_build, bmap_col, bmap_tint
extern biome_at, biome_point, biome_dunes, biome_plateau, biome_mesa, biome_strata_wave
extern g_strata, g_is_strata, bmap_dither, bmap_flatten
extern g_biomes, g_biome_count, g_trees, g_tree_count
%endif
%endif
