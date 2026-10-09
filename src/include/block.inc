; =============================================================================
; block.inc — block registry interface (src/world/block.asm, DATA_FORMAT.md).
; =============================================================================
%ifndef BLOCK_INC
%define BLOCK_INC
%include "world.inc"
%ifndef BLOCK_IMPL
extern blocks_load, block_find, tex_find
extern g_block_count, g_block_names, g_block_colors, g_block_opaque
extern g_block_layer, g_block_cullself, g_block_light, g_block_flags, g_block_tex
extern g_tex_count, g_tex_names, g_tex_frame_ms, g_tex_glow, g_tex_interp
%endif
%endif
