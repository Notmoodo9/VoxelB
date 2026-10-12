; =============================================================================
; lod.inc — distant terrain tiles (src/world/lod.asm, milestone 12, D80).
; =============================================================================
%ifndef LOD_INC
%define LOD_INC

%define LOD_CELLS       32              ; cells per tile side
%define LOD_MAX_LEVEL   5               ; cells of 2..32 blocks
%define MAX_LOD_TILES   8192
%define LOD_MAX_QUADS   16384           ; per tile
%define LOD_TINT_SIZE   1024            ; LOD tint map texels per side (16 blocks each)

; tile states
%define LT_FREE         0
%define LT_GEN          1               ; a job is building it
%define LT_MESHED       2               ; quads ready on the CPU
%define LT_READY        3               ; in the GPU quad buffer

; LOD quad (8 bytes):
;   low:  x 0-4, z 5-9 (cells), y 10-20 (blocks above the tile's min_y),
;         face 21-23, w - 1 24-28 (cells)
;   high: block 0-15, h - 1 16-26 (cells on a top face, blocks on a side)
struc LODTILE
    .level      resd 1
    .tx         resd 1                  ; tile coordinates (size 32 << level)
    .tz         resd 1
    .state      resd 1
    .min_y      resd 1                  ; lowest quad y
    .span       resd 1                  ; height of the quads' box
    .n_opaque   resd 1                  ; opaque quads (first), then water
    .n_water    resd 1
    .unit       resd 1                  ; gpu_alloc unit (-1 none)
    .first      resd 1                  ; first quad in the quad buffer
    .stamp      resd 1                  ; last lod_update that needed it
    .tint_n     resd 1                  ; tint texels per side
    .buf        resq 1                  ; CPU quads + tint (until uploaded)
    .quads      resd 1                  ; n_opaque + n_water
    .pad        resd 1
endstruc

%ifndef LOD_IMPL
extern lod_init, lod_update, lod_shutdown
extern g_lod_tiles, g_lod_used, g_lod_levels, g_lod_r
extern g_lod_ready, g_lod_inflight, g_lod_quads
extern g_lod_gen_count, g_lod_gen_total_us, g_lod_gen_max_us
%endif

%endif
