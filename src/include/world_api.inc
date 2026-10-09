; =============================================================================
; world_api.inc — world module interface (src/world/world.asm).
; =============================================================================
%ifndef WORLD_API_INC
%define WORLD_API_INC
%include "world.inc"
%ifndef WORLD_IMPL
extern world_init, world_column, world_section_at, world_block_at
extern world_column_alloc, world_column_free, world_column_insert, world_column_remove
extern gen_column_job, atomic_max, world_hash_selftest
extern world_spawn, g_generator, g_seed_override, g_seed_override_set, g_force_flat
extern g_world_gen_count, g_world_gen_total_us, g_world_gen_max_us
%endif
%endif
