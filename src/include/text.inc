; =============================================================================
; text.inc — text/rectangle batch renderer interface (src/render/text.asm).
; =============================================================================
%ifndef TEXT_INC
%define TEXT_INC
%ifndef TEXT_IMPL
extern text_init, text_shutdown, text_begin, text_add, text_rect, text_flush
extern g_text_scale, g_font_cell_w, g_font_cell_h
%endif
%endif
