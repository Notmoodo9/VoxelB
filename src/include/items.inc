; =============================================================================
; items.inc — item registry interface (src/world/items.asm, milestone 18).
; =============================================================================
%ifndef ITEMS_INC
%define ITEMS_INC
%define MAX_ITEMS       4096
%define MAX_TABS        16
%define ITEMF_HIDDEN    1               ; not in the Creative inventory
%ifndef ITEMS_IMPL
extern items_load, item_find
extern g_item_count, g_item_names, g_item_titles, g_item_block, g_item_stack
extern g_item_tab, g_item_tex, g_item_flags, g_block_item
extern g_tab_count, g_tab_titles, g_tab_icon
%endif
%endif
