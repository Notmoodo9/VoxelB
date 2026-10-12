; =============================================================================
; light.inc — per-column light volumes (src/world/light.asm, milestone 13, D81).
;
; A light volume covers a column plus a 16-block margin on every side
; (64 x 64 cells) from the world bottom up to above its highest blocks.
; Cell index: ly * 4096 + lz * 64 + lx, where lx = x + 16, lz = z + 16
; (x, z column-local, -16..47) and ly = world y + 256.
; Cell light (u16): r | g << 4 | b << 8 | sky << 12, 0..15 each (block light
; packs like g_block_light). Cells above the volume are open sky (sky 15).
; =============================================================================
%ifndef LIGHT_INC
%define LIGHT_INC

%define LV_W            64              ; cells per side
%define LV_M            16              ; margin around the column
%define LV_LAYER        4096            ; cells per layer
%define LIGHT_SKY_FULL  0xF000

; g_light_op bits (per block id)
%define LOP_OPAQUE      1               ; blocks light (and counts for AO)
%define LOP_FILTER_SHIFT 4              ; bits 4-7: extra loss per block passed

struc LVOL
    .h          resd 1                  ; layers (0: nothing but sky)
    .pad        resd 1
    .light      resq 1                  ; u16 per cell
    .op         resq 1                  ; u8 per cell (g_light_op of its block)
endstruc

%ifndef LIGHT_IMPL
extern light_init, light_build, g_light_op
extern g_light_count, g_light_total_us, g_light_max_us, g_light_sources
%endif

%endif
