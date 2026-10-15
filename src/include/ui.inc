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
%define UIK_SKIN        6               ; journal skin 9-slice (milestone 18 part 5)

; the journal skin's pieces (assets/textures/ui/journal.cfg, ui_draw.asm)
%define SKIN_LEATHER    0
%define SKIN_PAGE       1
%define SKIN_SLOT       2
%define SKIN_SLOT_HI    3
%define SKIN_SEAL       4
%define SKIN_CORNER_TL  5
%define SKIN_CORNER_TR  6
%define SKIN_CORNER_BL  7
%define SKIN_CORNER_BR  8
%define SKIN_RIBBON     9
%define SKIN_BUTTON     10
%define SKIN_BUTTON_HI  11
%define SKIN_FIELD      12
%define SKIN_BOOK       13
%define SKIN_CHECK_OFF  14
%define SKIN_CHECK_ON   15
%define SKIN_KNOB       16
%define SKIN_STRIP      17
%define SKIN_STRIP_SLOT 18
%define SKIN_TIP        19
%define SKIN_PAGE_TILE  20
%define SKIN_HEART           21
%define SKIN_HEART_HALF      22
%define SKIN_HEART_EMPTY     23
%define SKIN_FOOD            24
%define SKIN_FOOD_HALF       25
%define SKIN_FOOD_EMPTY      26
%define SKIN_FOOD_SICK       27
%define SKIN_FOOD_SICK_HALF  28
%define SKIN_BUBBLE          29
%define SKIN_BUBBLE_POP      30
%define SKIN_ARMOR           31      ; milestone 21 part 2: the armor row
%define SKIN_ARMOR_HALF      32
%define SKIN_ARMOR_EMPTY     33
%define SKIN_COUNT      34

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

; the look: the adventurer's journal (design/ui/journal_ui.md, milestone 18
; part 5): sepia ink on cream parchment, red-brown leather, wax-seal red,
; brass (0xAABBGGRR)
%define COL_ACCENT      0xFF1C20A8      ; wax-seal red #A8201C
%define COL_ACCENT2     0xFF1E2E6B      ; leather red-brown #6B2E1E
%define COL_INK         0xFF14243B      ; sepia ink #3B2414
%define COL_TEXT        COL_INK         ; text on the pages
%define COL_TEXT_DIM    0xC0284A6A      ; faded ink
%define COL_TEXT_OFF    0x70284A6A      ; pale ink (disabled, placeholders)
%define COL_LIGHT       0xFFC8E6F4      ; cream: text on leather and the world
%define COL_LIGHT_DIM   0xC0B0D0E0
%define COL_BRASS       0xFF3AA2C9      ; brass #C9A23A
%define COL_PAPER       0xFFC0E3F1      ; parchment #F1E3C0
%define COL_GLASS       0x8C1A1410      ; (old glass tint, debug overlay)
%define COL_GLASS_EDGE  0x50FFFFFF
%define COL_BUTTON      0x50000000
%define COL_SHADOW      0x70000000
%define COL_DANGER      0xFF1C28B8      ; red ink #B8281C
%define COL_FIELD       0x10000000      ; text field wash

%endif
