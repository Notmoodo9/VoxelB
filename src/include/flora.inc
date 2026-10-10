; =============================================================================
; flora.inc — vegetation, trees and ponds of a chunk (src/world/flora.asm).
; =============================================================================
%ifndef FLORA_INC
%define FLORA_INC

%define MAX_PONDS       8
%define MAX_CANDS       640
%define TREE_REACH      20              ; blocks a tree may spread from its trunk
%define MAX_ISLES       16
%define ISLE_CELL       48              ; one floating island candidate per cell
%define ISLE_MAX_R      25

struc POND                              ; a pond touching the chunk (local)
    .x          resd 1                  ; centre (chunk-local blocks)
    .z          resd 1
    .rx         resd 1                  ; f32 radii along its axes (+ rim)
    .rz         resd 1
    .c          resd 1                  ; f32 axis direction (cos, sin)
    .s          resd 1
endstruc

struc ISLE                              ; a floating island near the chunk
    .x          resd 1                  ; centre (chunk-local)
    .z          resd 1
    .r          resd 1                  ; f32 radius
    .yc         resd 1                  ; centre (top) height
    .b          resq 1                  ; BIOME* at the centre
    .h          resd 1                  ; hash
    .cellx      resd 1
    .cellz      resd 1
    .pad        resd 1
endstruc

struc CAND                              ; a tree or bush that may touch the chunk
    .x          resd 1                  ; trunk (chunk-local, -8..39)
    .z          resd 1
    .y          resd 1                  ; first air block above the ground
    .ytop       resd 1                  ; highest block it can reach
    .tree       resd 1                  ; TREE index
    .seed       resd 1
endstruc

struc FCTX
    .cx         resd 1
    .cz         resd 1
    .heights    resq 1                  ; i32[HM*HM] (ponds modify it)
    .pond       resq 1                  ; i16[HM*HM] water level or POND_NONE
    .info       resq 1                  ; INFO_SIZE x 1024 (terrain.inc)
    .bmap       resq 1                  ; BMAP*
    .ids        resq 1                  ; section being filled
    .y0         resd 1
    .top        resd 1                  ; highest y any tree reaches
    .npond      resd 1
    .ncand      resd 1
    .ponds      resb MAX_PONDS * POND_size
    .cand       resb MAX_CANDS * CAND_size
    .litter     resw 1024               ; litter block per interior column (0 = none)
    .nisle      resd 1
    .pad2       resd 1
    .isles      resb MAX_ISLES * ISLE_size
endstruc

%ifndef FLORA_IMPL
extern flora_ponds, flora_prepare, flora_section, flora_survey, flora_islands
%endif
%endif
