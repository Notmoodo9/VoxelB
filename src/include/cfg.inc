; =============================================================================
; cfg.inc — data-file parser interface (src/core/cfg.asm, DATA_FORMAT.md).
; =============================================================================
%ifndef CFG_INC
%define CFG_INC
%define CFG_SECTIONS 1
extern cfg_parse, cfg_parse_ex, cfg_next_token, cfg_warn, cfg_trim
extern cfg_rewrite, cfgw_int, cfgw_flag, cfgw_hundredths   ; (cfg_write.asm)
%endif
