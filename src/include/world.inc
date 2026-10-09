; =============================================================================
; world.inc — world constants and structures.
;   Sections are 32x32x32 blocks; a column holds 40 sections (Y -256..1023).
;   Block index inside a section: idx = y << 10 | z << 5 | x.
; =============================================================================
%ifndef WORLD_INC
%define WORLD_INC

%define SECTION_SIZE        32
%define SECTION_SHIFT       5
%define SECTION_VOLUME      32768
%define WORLD_MIN_Y         -256
%define SECTIONS_PER_COLUMN 40
%define BLOCK_AIR           0
%define MAX_BLOCK_TYPES     4096        ; block registry capacity (ids are u16)
%define MAX_TEXTURES        2048        ; named block textures

; render layers (g_block_layer): drawn in this order
%define LAYER_OPAQUE        0
%define LAYER_CUTOUT        1           ; alpha-tested (leaves)
%define LAYER_TRANSLUCENT   2           ; blended, back to front (glass, ice)
%define BLOCKF_SWAY         1           ; g_block_flags: vertex sway (leaves)
%define BLOCKF_TINT_GRASS   2           ; biome grass colour (faces: g_block_tintmask)
%define BLOCKF_TINT_FOLIAGE 4           ; biome foliage colour
%define BLOCKF_AXIS         8           ; log axis states: 0 Y, 1 X, 2 Z (cube shape)

; mesher output capacity per section (greedy worst case is 98304 quads;
; the rest is room for shaped-block quads)
%define MESH_MAX_QUADS      131072

; block shapes (g_block_shape); each has a fixed number of states, stored as
; consecutive block ids starting at the base block (g_block_state = index)
%define SHAPE_CUBE          0
%define SHAPE_SLAB          1           ; bit 0: top
%define SHAPE_STAIRS        2           ; bits 0-1 facing, bit 2: upside down
%define SHAPE_FENCE         3
%define SHAPE_FENCE_GATE    4           ; bits 0-1 facing, bit 2: open
%define SHAPE_DOOR          5           ; 0-1 facing, 2 upper, 3 open, 4 hinge right
%define SHAPE_TRAPDOOR      6           ; 0-1 facing, 2 top, 3 open
%define SHAPE_LADDER        7           ; 0-1 facing
%define SHAPE_SIGN          8           ; 0-1 rotation
%define SHAPE_WALL_SIGN     9           ; 0-1 facing
%define SHAPE_PLATE         10          ; bit 0: pressed
%define SHAPE_WALL          11
%define SHAPE_PILLAR        12
%define SHAPE_PANE          13
%define SHAPE_SPIKE         14          ; bit 0: points down (base/middle/tip automatic)
%define SHAPE_PLANT         15          ; two crossed planes (grass, flowers)
%define SHAPE_TALL_PLANT    16          ; bit 0: upper half (upper_textures)
%define SHAPE_COUNT         17
; facings: 0 north (-Z), 1 east (+X), 2 south (+Z), 3 west (-X)

; Neighbour sentinel for the mesher: a solid boundary (below the world).
%define NEIGHBOR_SOLID      -1

struc SECT                              ; one section; 64 bytes, from a pool
    .cx         resd 1
    .sy         resd 1                  ; 0..39 (world y = -256 + sy*32)
    .cz         resd 1
    .bits       resb 1                  ; 0 (uniform), 1, 2, 4, 8, 16
    .flags      resb 1
    .pal_count  resw 1
    .uniform_id resw 1                  ; block id when bits = 0
    .vis        resw 1                  ; face-to-face visibility (15 pair bits,
                                        ; see mesher.asm); set when meshed
    .pad0       resw 2
    .palette    resq 1                  ; u16[256] (bits 1..8), else 0
    .data       resq 1                  ; packed indices / raw u16 ids
    .quad_first resd 1                  ; first quad in the GPU quad buffer
    .quad_count resd 1                  ; all layers: opaque, cutout, translucent
    .mesh_us    resd 1
    .quad_opaque resd 1                 ; quads of LAYER_OPAQUE (stored first)
    .quad_cutout resd 1                 ; then LAYER_CUTOUT, then the rest
    .cpu_first  resd 1                  ; first quad in the column's CPU mesh
endstruc

; column states (COLUMN.state); written by the owner of the transition:
;   main: NEW -> (submit) GENERATING, GENERATED -> (submit) MESHING,
;         MESHED -> (upload) READY;   workers: GENERATING -> GENERATED,
;         MESHING -> MESHED (published last, after all results are written)
%define COL_NEW         0
%define COL_GENERATING  1
%define COL_GENERATED   2
%define COL_MESHING     3
%define COL_MESHED      4
%define COL_READY       5

struc COLUMN
    .cx         resd 1
    .cz         resd 1
    .state      resd 1                  ; COL_* (atomic)
    .busy       resd 1                  ; mesh jobs reading this column
    .sections   resq SECTIONS_PER_COLUMN
    .nb         resq 4                  ; -X, +X, -Z, +Z (set at mesh submit)
    .mesh_buf   resq 1                  ; quads of all sections (VirtualAlloc)
    .mesh_bytes resq 1
    .geo_mask   resq 1                  ; bit sy = section has quads on the GPU
    .list_index resd 1                  ; position in the loaded-column list
    .pad        resd 1
    .vstamp     resw SECTIONS_PER_COLUMN ; visibility walk: frame stamp per section
    .vqueue     resd SECTIONS_PER_COLUMN ; visibility walk: queue slot this frame
    .tint       resd 2 * 64             ; biome colours, 8 x 8 per layer (grass,
                                        ;  foliage), RGBA8 factors (128 = 1.0); 0 = unset
endstruc

%endif
