; =============================================================================
; terrain.inc — terrain generator interface (src/world/terrain.asm).
; =============================================================================
%ifndef TERRAIN_INC
%define TERRAIN_INC

struc TSAMPLE                           ; terrain_sample output (floats)
    .fields     resd 11                 ; noise fields (continentalness, ...)
    .height     resd 1                  ; surface height (first air block)
    .land       resd 1                  ; 0 ocean .. 1 inland
    .mount      resd 1                  ; mountain factor
    .extra      resd 1                  ; hills + rolling (internal)
    .giant      resd 1                  ; giant-range mask 0..1
    .river      resd 1                  ; river distance (< 0: in the river)
    .overhang   resd 1                  ; overhang amplitude (blocks)
    .base       resd 1                  ; base height (continentalness spline)
    .pad        resd 1
endstruc

; heightmap of a chunk with a border: HB blocks on each side (trees and
; ponds reach into neighbouring chunks)
%define HB              16
%define HM              (32 + 2 * HB)

; per-column info of the 32 x 32 interior (terrain_gen_column)
%define INFO_SIZE       16
%define INFO_A          0               ; f32 overhang amplitude
%define INFO_TOP        4               ; u16 top block
%define INFO_FILL       6               ; u16 filler block
%define INFO_DEEP       8               ; i16 deep stone boundary
%define INFO_JITTER     10              ; u8 bedrock jitter
%define INFO_SNOW       11              ; i8 snow line jitter
%define INFO_BIOME      12              ; u8 biome
%define INFO_DENS       13              ; u8 vegetation density 0..255
%define INFO_POND       14              ; i16 pond water level (POND_NONE)
%define POND_NONE       -32768


struc ORE                               ; one [ore] record (ores.cfg)
    .block          resd 1              ; block in stone
    .deep           resd 1              ; block in deep stone (0 = none)
    .min_y          resd 1
    .max_y          resd 1
    .peak_y         resd 1              ; most common height (0x80000000 = flat)
    .size_min       resd 1              ; blocks per cluster
    .size_max       resd 1
    .per_section    resd 1              ; float: clusters per 32^3 section in range
    .mountain_only  resd 1              ; 1 = only inside mountains (y >= 180)
    .mountain_bonus resd 1              ; float: extra clusters inside mountains
    .deep_only      resd 1              ; 1 = only in deep stone
    .vein_chance    resd 1              ; float: large vein chance per section
    .vein_size      resd 1              ; blocks in a large vein
endstruc

%endif
