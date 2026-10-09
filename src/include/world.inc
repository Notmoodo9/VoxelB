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
%define MAX_BLOCK_TYPES     256         ; debug block table (M7: registry)

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
    .pad0       resw 3
    .palette    resq 1                  ; u16[256] (bits 1..8), else 0
    .data       resq 1                  ; packed indices / raw u16 ids
    .quad_first resd 1                  ; first quad in the GPU quad buffer
    .quad_count resd 1
    .mesh_us    resd 1
    .pad1       resd 1
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
endstruc

%endif
