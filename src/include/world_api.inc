; =============================================================================
; world_api.inc — world module interface (src/world/world.asm).
; =============================================================================
%ifndef WORLD_API_INC
%define WORLD_API_INC
%include "world.inc"
%ifndef WORLD_IMPL
extern world_init, world_column, world_section_at, world_block_at
extern g_draw_list, g_draw_count, g_mesh_staging, g_world_quads
extern g_world_columns_n, g_world_mesh_list_count
extern g_world_gen_wall_us, g_world_gen_total_us, g_world_gen_max_us
extern g_world_mesh_wall_us, g_world_mesh_total_us, g_world_mesh_max_us
extern g_world_radius
%endif
%endif
