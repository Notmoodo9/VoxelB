; =============================================================================
; ui.inc — the menus' / HUD's renderer and widgets (src/ui/ui_draw.asm,
; src/ui/ui.asm; milestone 17).
; =============================================================================
%ifndef UI_INC
%define UI_INC

; quad kinds (ui.vert / ui.frag)
%define UIK_RECT        0
%define UIK_GLYPH       1
%define UIK_GLASS       2
%define UIK_GLOW        3
%define UIK_IMAGE       4
%define UIK_ICON        5               ; item icon atlas (milestone 18)

; ui_text flags
%define UI_CENTER       1
%define UI_RIGHT        2
%define UI_SHADOW       4
%define UI_BOLD         8

; widget flags
%define UIW_DISABLED    1               ; greyed out, no clicks
%define UIW_SELECTED    2               ; drawn as chosen (toggles, tabs)
%define UIW_PRIMARY     4               ; filled with the accent colour
%define UIW_DANGER      8               ; filled red (Delete)

; the look (design/ui/menus.md): teal accent, glass panels (0xAABBGGRR)
%define COL_ACCENT      0xFFD8C21E      ; teal / turquoise #1EC2D8
%define COL_ACCENT2     0xFFB09A0E      ; deeper teal
%define COL_TEXT        0xFFF4F4F4
%define COL_TEXT_DIM    0xB0E0E0E0
%define COL_TEXT_OFF    0x60D0D0D0
%define COL_GLASS       0x8C1A1410      ; dark tint over the blurred world
%define COL_GLASS_EDGE  0x50FFFFFF
%define COL_BUTTON      0x50000000
%define COL_SHADOW      0x70000000
%define COL_DANGER      0xD03838D8      ; warm red #D83838
%define COL_FIELD       0x70000000      ; text field fill

%endif
