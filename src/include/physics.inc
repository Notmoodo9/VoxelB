; =============================================================================
; physics.inc — block collision for the simulation (src/sim/physics.asm).
; =============================================================================
%ifndef PHYSICS_INC
%define PHYSICS_INC

; g_block_move flags
%define MOVE_CLIMB      1               ; ladders, vines
%define MOVE_WATER      2
%define MOVE_LAVA       4

; an AABB: 6 doubles
%define AABB_MINX       0
%define AABB_MINY       8
%define AABB_MINZ       16
%define AABB_MAXX       24
%define AABB_MAXY       32
%define AABB_MAXZ       40
%define AABB_BYTES      48

%ifndef PHYSICS_IMPL
extern phys_init, phys_block, phys_gather, phys_clip, phys_overlap, phys_touch
extern g_block_coll, g_block_move
%endif
%endif
