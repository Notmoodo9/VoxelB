; =============================================================================
; block.inc — block registry interface (src/world/block.asm, DATA_FORMAT.md).
; =============================================================================
%ifndef BLOCK_INC
%define BLOCK_INC
%include "world.inc"

; g_block_phys: movement settings as written in the block files (the sim's
; physics.asm resolves the defaults by shape)
%define BPHYS_COLL_MASK     0x03        ; collision: 0 by shape, 1 none, 2 full
%define BPHYS_COLL_NONE     0x01
%define BPHYS_COLL_FULL     0x02
%define BPHYS_CLIMB_SHIFT   2
%define BPHYS_CLIMB_MASK    0x0C        ; climbable: 0 by shape, 1 no, 2 yes
%define BPHYS_LIQUID_MASK   0x30        ; liquid: 0 none, water, lava
%define BPHYS_LIQUID_WATER  0x10
%define BPHYS_LIQUID_LAVA   0x20
%ifndef BLOCK_IMPL
extern blocks_load, block_find, tex_find
extern g_block_count, g_block_names, g_block_colors, g_block_opaque
extern g_block_layer, g_block_cullself, g_block_light, g_block_flags, g_block_tex
extern g_block_shape, g_block_state, g_block_nstates, g_block_tintmask
extern g_block_lfilter, g_block_water, g_block_phys
extern g_tex_count, g_tex_names, g_tex_frame_ms, g_tex_glow, g_tex_interp
%endif
%endif
