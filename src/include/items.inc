; =============================================================================
; items.inc — item registry interface (src/world/items.asm, milestone 18).
; =============================================================================
%ifndef ITEMS_INC
%define ITEMS_INC
%define MAX_ITEMS       4096
%define MAX_TABS        16
%define ITEMF_HIDDEN    1               ; not in the Creative inventory
; tool types and tiers (item settings `tool`, `tier`; mining.cfg)
%define TOOL_NONE       0
%define TOOL_PICKAXE    1
%define TOOL_AXE        2
%define TOOL_SHOVEL     3
%define TOOL_HOE        4
%define TOOL_COUNT      5
%define TIER_HAND       0               ; wood 1, stone 2, copper 3, iron 4,
%define TIER_COUNT      9               ; diamond 5, mythril 6, adamantite 7, star_crystal 8
%ifndef ITEMS_IMPL
extern items_load, item_find
extern g_item_count, g_item_names, g_item_titles, g_item_block, g_item_stack
extern g_item_tab, g_item_tex, g_item_flags, g_block_item
extern g_tab_count, g_tab_titles, g_tab_icon
extern g_item_tool, g_item_tier, g_item_speed, g_item_dur
extern item_tool_index, item_tier_index, items_match_list
%endif
%endif
