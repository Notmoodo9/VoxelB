; =============================================================================
; shader.inc — shader program interface (src/render/shader.asm).
; =============================================================================
%ifndef SHADER_INC
%define SHADER_INC
%ifndef SHADER_IMPL
extern shader_create, shader_program, shader_poll, shader_reload_all, shader_shutdown
extern g_shader_count, g_shader_reloads, g_shader_failures, g_shader_last_ok
%endif
%endif
