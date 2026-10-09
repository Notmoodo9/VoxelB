; =============================================================================
; section.inc — section storage interface (src/world/section.asm).
; =============================================================================
%ifndef SECTION_INC
%define SECTION_INC
%include "world.inc"
%ifndef SECTION_IMPL
extern sections_init, section_build, section_get, section_decode
extern section_set, section_free, section_make_uniform
extern g_sections_live, g_section_bytes
%endif
%endif
