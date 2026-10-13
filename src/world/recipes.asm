; =============================================================================
; recipes.asm — the crafting recipes and crafting stations (milestone 18,
; design/items/items_inventory.md; DATA_FORMAT.md "Recipe files").
;
; data/recipes/*.recipes (file-name order):
;   [station <name>]   block = workbench   grid = 3
;   [furnace <name>]   block = furnace  lit = furnace_lit  speed = 1
;                      blast = 1 (can smelt `blast` recipes): input, fuel,
;                      output; the block becomes `lit` while it burns
;   [smelt <name>]     input = *iron_ore  result = iron_bar [n]  seconds = 10
;                      blast = 1 (only in a furnace with blast = 1)
;   [fuel]             <item pattern> = seconds   (one line per fuel)
;   [container <name>] block = chest  slots = 27  joins = 1  (a container:
;                      right click opens its slots; joins: two side by side
;                      with the same facing make one of twice the slots)
;   [recipe <id>]      shape = PP / PP     (rows split by '/'; '.' = empty)
;                      P = *_planks        (one character: a key; the value
;                                           is an item name pattern)
;                      ingredients = salt, sand, coal   (shapeless instead)
;                      result = workbench 1
;                      station = workbench  (default: by hand, which also
;                                            works on any station)
;                      each = *_planks      one recipe per item whose name
;                                           fits (one '*'); "{}" in every
;                                           value is what '*' stood for.
;                                           A copy naming an item that does
;                                           not exist is left out quietly.
;                      only = stone, *_terracotta   with `each`: only where
;                                           what '*' stood for fits these
; Recipes and stations need no assembly changes.
;
; Public API:
;   recipes_load()                      after items_load
;   recipe_match(rcx = u16 items[9] (3 x 3, row by row), edx = station in
;       use (0 by hand)) -> eax recipe, -1 none     (shaped also mirrored)
;   g_recipe_count, g_rec_result (u16), g_rec_amount (u8), g_rec_station
;   (u8: 0 by hand, else a station), g_rec_w / g_rec_h (u8; 0 = shapeless),
;   g_rec_cells (9 patterns per recipe, row by row; shapeless: the list)
;   g_block_station (u8 per block id: its station, 0 none), g_station_grid,
;   g_station_slots (u8: a container's slots, 0 = a crafting station),
;   g_station_joins (u8), g_station_kind (u8 STATION_*), g_station_speed (u8),
;   g_station_blast (u8), g_station_lit (u16 base block id, 0 none),
;   g_station_unlit (u16 base block id of `block`)
;   station_find(rcx = name) -> eax station + 1, -1 none
;   smelt_find(ecx = item, edx = 1 in a blast furnace) -> eax smelt, -1
;   g_smelt_result (u16), g_smelt_amount (u8), g_smelt_ticks (u32)
;   fuel_ticks(ecx = item) -> eax ticks it burns (0: not a fuel)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "block.inc"
%include "items.inc"

global recipes_load, recipe_match
global g_recipe_count, g_rec_result, g_rec_amount, g_rec_station, g_rec_w
global g_rec_h, g_rec_cells, g_block_station, g_station_grid, g_station_count
global g_rec_n, g_rec_ok, g_rec_names, g_station_names, recipe_cell_ok
global g_station_slots, g_station_joins, g_station_kind, g_station_speed
global g_station_blast, g_station_lit, g_station_unlit, station_find
global smelt_find, fuel_ticks, g_smelt_result, g_smelt_amount, g_smelt_ticks

extern str_ieq, str_len, str_parse_u64, str_dup, str_copy, str_parse_float

IMPORT FindFirstFileA, FindNextFileA, FindClose

%define MAX_RECIPES     1024
%define MAX_STATIONS    16
%define MAX_FILES       64
%define MAX_PAIRS       24
%define FD_ATTR         0
%define FD_NAME         44
%define REC_NONE        0
%define REC_RECIPE      1
%define REC_STATION     2
%define REC_SMELT       3
%define REC_FUEL        4
%define MAX_SMELTS      256
%define MAX_FUELS       64

section .rdata
str_pattern:    db "data\recipes\*.recipes", 0
str_dir:        db "data\recipes\", 0
k_recipe:       db "recipe", 0
k_station:      db "station", 0
k_container:    db "container", 0
k_slots:        db "slots", 0
k_joins:        db "joins", 0
k_furnace:      db "furnace", 0
k_smelt:        db "smelt", 0
k_fuel:         db "fuel", 0
k_lit:          db "lit", 0
k_speed:        db "speed", 0
k_blast:        db "blast", 0
k_input:        db "input", 0
k_seconds:      db "seconds", 0
k_block:        db "block", 0
k_grid:         db "grid", 0
k_shape:        db "shape", 0
k_ingredients:  db "ingredients", 0
k_result:       db "result", 0
str_unknown:    db "unknown setting: ", 0
str_bad:        db "bad value for: ", 0
str_no_item:    db "unknown item: ", 0
str_no_block:   db "unknown block: ", 0
str_no_station: db "unknown station: ", 0
str_no_key:     db "a shape uses a key with no item: ", 0
str_dropped:    db "recipe left out (no result or no shape): ", 0
str_full:       db "too many recipes or stations at: ", 0
str_loaded:     db "recipes: ", 0
str_loaded2:    db ", stations ", 0
str_no_match:   db "an ingredient matches no item: ", 0
%if BUILD_DEBUG
; debug self-check (recipes_selfcheck)
t_birch_planks: db "birch_planks", 0
t_birch_stairs: db "birch_stairs", 0
t_cobblestone: db "cobblestone", 0
t_dirt: db "dirt", 0
t_mossy_cobblestone: db "mossy_cobblestone", 0
t_oak_log: db "oak_log", 0
t_oak_planks: db "oak_planks", 0
t_oak_slab: db "oak_slab", 0
t_red_terracotta: db "red_terracotta", 0
t_red_terracotta_slab: db "red_terracotta_slab", 0
t_stick: db "stick", 0
t_stone: db "stone", 0
t_stone_slab: db "stone_slab", 0
t_stripped_spruce_log: db "stripped_spruce_log", 0
t_vine: db "vine", 0
t_workbench: db "workbench", 0
align 8
t_cases:
    dq 0, 0, 0, 0, t_oak_log, 0, 0, 0, 0, t_oak_planks, 4
    dq 0, 0, 0, t_oak_planks, t_oak_planks, 0, t_oak_planks, t_oak_planks, 0, t_workbench, 1
    dq 0, t_birch_planks, 0, 0, t_oak_planks, 0, 0, 0, 0, t_stick, 4
    dq 0, 0, t_birch_planks, 0, t_birch_planks, t_birch_planks, t_birch_planks, t_birch_planks, t_birch_planks, t_birch_stairs, 4
    dq t_birch_planks, 0, 0, t_birch_planks, t_birch_planks, 0, t_birch_planks, t_birch_planks, t_birch_planks, t_birch_stairs, 4
    dq 0, 0, 0, 0, 0, 0, t_vine, 0, t_cobblestone, t_mossy_cobblestone, 1
    dq t_red_terracotta, t_red_terracotta, t_red_terracotta, 0, 0, 0, 0, 0, 0, t_red_terracotta_slab, 6
    dq t_stone, t_stone, t_stone, 0, 0, 0, 0, 0, 0, t_stone_slab, 6
    dq t_oak_planks, t_oak_planks, t_oak_planks, 0, 0, 0, 0, 0, 0, t_oak_slab, 6
    dq 0, 0, 0, 0, t_dirt, 0, 0, 0, 0, 0, 0
    dq t_oak_log, t_stripped_spruce_log, 0, 0, 0, 0, 0, 0, 0, 0, 0
t_cases_end:
str_check_ok:   db "recipes: self-check PASS (", 0
str_check_ok2:  db " cases)", 0
str_check_bad:  db "recipes: self-check FAIL case ", 0
%endif
k_each:         db "each", 0
k_only:         db "only", 0
str_usable:     db " usable of ", 0
str_smelts:     db ", smelting ", 0
str_fuels:      db ", fuels ", 0
align 4
c_20:           dd 20.0

section .bss
alignb 8
g_rec_cells:    resq MAX_RECIPES * 9
g_rec_keys:     resq MAX_RECIPES * 26   ; while reading: key A..Z (and a..z share)
g_rec_shape:    resq MAX_RECIPES        ; while reading: the shape text
g_rec_names:    resq MAX_RECIPES
g_station_names: resq MAX_STATIONS
g_rec_result:   resw MAX_RECIPES
g_rec_amount:   resb MAX_RECIPES
g_rec_station:  resb MAX_RECIPES
g_rec_w:        resb MAX_RECIPES
g_rec_h:        resb MAX_RECIPES
g_rec_n:        resb MAX_RECIPES        ; shapeless: ingredients
g_rec_ok:       resb MAX_RECIPES
g_station_grid: resb MAX_STATIONS
g_station_slots: resb MAX_STATIONS
g_station_joins: resb MAX_STATIONS
g_station_kind: resb MAX_STATIONS
g_station_speed: resb MAX_STATIONS
g_station_blast: resb MAX_STATIONS
alignb 2
g_station_lit:  resw MAX_STATIONS
g_station_unlit: resw MAX_STATIONS
g_smelt_result: resw MAX_SMELTS
g_smelt_amount: resb MAX_SMELTS
g_smelt_blast:  resb MAX_SMELTS
alignb 8
g_smelt_input:  resq MAX_SMELTS         ; item patterns
g_fuel_pat:     resq MAX_FUELS
alignb 4
g_smelt_ticks:  resd MAX_SMELTS
g_fuel_tick:    resd MAX_FUELS
g_smelt_count:  resd 1
g_fuel_count:   resd 1
g_block_station: resb 65536
alignb 4
g_recipe_count: resd 1
g_station_count: resd 1
g_kind:         resd 1
g_cur:          resd 1
g_file_count:   resd 1
alignb 8
g_label:        resq 1
g_file_names:   resq MAX_FILES
g_find:         resb 320
g_rel:          resb PATH_CAP
g_path:         resb PATH_CAP
g_match_names:  resq 9                  ; recipe_match: the grid's item names
g_used:         resb 16
g_quiet:        resb MAX_RECIPES        ; made by `each`: drop without a warning
alignb 8
g_pair_names:   resq MAX_PAIRS          ; the [recipe] record being read
g_pair_values:  resq MAX_PAIRS
g_each:         resq 1
g_only:         resq 1
g_cap_text:     resb 128
g_rec_label:    resq 1
g_cap_ptr:      resq 1                  ; what '*' stood for
g_npairs:       resd 1
g_cap_len:      resd 1
g_applying:     resd 1                  ; recipes_pair applies (not records)
g_cur_quiet:    resd 1

section .text

; warn — rcx = message, rdx = detail (current file as label)
PROC warn, 0
    mov r8, rdx
    mov rdx, rcx
    mov rcx, [rel g_label]
    call cfg_warn
    RETURN
ENDPROC

; station_find — eax = station index + 1 of name rcx, -1   clobbers: volatile
PROC station_find, 0, rbx, rsi
    mov rsi, rcx
    xor ebx, ebx
.s:
    cmp ebx, [rel g_station_count]
    jae .none
    lea rax, [rel g_station_names]
    INVOKE str_ieq, [rax + rbx * 8], rsi
    test eax, eax
    jnz .found
    inc ebx
    jmp .s
.found:
    lea eax, [ebx + 1]                  ; (0 = by hand)
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; recipes_pair — cfg_parse_ex callback.
;   in:  rcx = name / header, rdx = value (0 for a header)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC recipes_pair, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    test rsi, rsi
    jnz .setting
    call flush_record
    mov dword [rel g_kind], REC_NONE
    lea rdx, [rel k_fuel]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .named
    mov dword [rel g_kind], REC_FUEL
    RETURN
.named:
    mov rdi, rbx
.word:
    mov al, [rdi]
    test al, al
    jz .bad_header
    cmp al, ' '
    je .split
    inc rdi
    jmp .word
.split:
    mov byte [rdi], 0
.name:
    inc rdi
    cmp byte [rdi], ' '
    je .name
    lea rdx, [rel k_recipe]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .recipe
    lea rdx, [rel k_station]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .station
    lea rdx, [rel k_container]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .container
    lea rdx, [rel k_furnace]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .furnace
    lea rdx, [rel k_smelt]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .smelt
.bad_header:
    lea rcx, [rel str_unknown]
    mov rdx, rbx
    call warn
    RETURN
.recipe:
    ; the settings are collected; flush_record makes the recipe(s)
    mov [rel g_rec_label], rdi
    mov qword [rel g_each], 0
    mov qword [rel g_only], 0
    mov dword [rel g_npairs], 0
    mov dword [rel g_kind], REC_RECIPE
    RETURN
.smelt:
    mov eax, [rel g_smelt_count]
    cmp eax, MAX_SMELTS
    jae .full
    inc dword [rel g_smelt_count]
    mov [rel g_cur], eax
    lea rcx, [rel g_smelt_amount]
    mov byte [rcx + rax], 1
    lea rcx, [rel g_smelt_ticks]
    mov dword [rcx + rax * 4], 200      ; 10 s
    mov dword [rel g_kind], REC_SMELT
    RETURN
.station:
    mov ecx, 3                          ; a crafting grid
    xor edx, edx
    mov r9d, STATION_CRAFTING
    jmp .usable
.container:
    xor ecx, ecx                        ; slots, no grid
    mov edx, 27
    mov r9d, STATION_CONTAINER
    jmp .usable
.furnace:
    xor ecx, ecx
    mov edx, 3                          ; input, fuel, output
    mov r9d, STATION_FURNACE
.usable:
    mov eax, [rel g_station_count]
    cmp eax, MAX_STATIONS
    jae .full
    inc dword [rel g_station_count]
    mov [rel g_cur], eax
    lea r8, [rel g_station_names]
    mov [r8 + rax * 8], rdi
    lea r8, [rel g_station_grid]
    mov [r8 + rax], cl
    lea r8, [rel g_station_slots]
    mov [r8 + rax], dl
    lea r8, [rel g_station_kind]
    mov [r8 + rax], r9b
    lea r8, [rel g_station_speed]
    mov byte [r8 + rax], 1
    mov dword [rel g_kind], REC_STATION
    RETURN
.full:
    lea rcx, [rel str_full]
    mov rdx, rdi
    call warn
    RETURN

.setting:
    mov edi, [rel g_cur]
    cmp dword [rel g_kind], REC_STATION
    je .station_setting
    cmp dword [rel g_kind], REC_SMELT
    je .smelt_setting
    cmp dword [rel g_kind], REC_FUEL
    je .fuel_setting
    cmp dword [rel g_kind], REC_RECIPE
    jne .done
    cmp dword [rel g_applying], 0
    jne .apply
    ; reading the record: keep the pair (each = ... for flush_record)
    lea rdx, [rel k_each]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_each
    mov [rel g_each], rsi
    RETURN
.not_each:
    lea rdx, [rel k_only]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .keep
    mov [rel g_only], rsi
    RETURN
.keep:
    mov eax, [rel g_npairs]
    cmp eax, MAX_PAIRS
    jae .full_pairs
    lea rcx, [rel g_pair_names]
    mov [rcx + rax * 8], rbx
    lea rcx, [rel g_pair_values]
    mov [rcx + rax * 8], rsi
    inc dword [rel g_npairs]
    RETURN
.full_pairs:
    lea rcx, [rel str_full]
    mov rdx, rbx
    call warn
    RETURN
.apply:
    ; a one-character name is a key
    cmp byte [rbx + 1], 0
    jne .not_key
    movzx eax, byte [rbx]
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    ja .unknown
    imul ecx, edi, 26
    add ecx, eax
    lea rax, [rel g_rec_keys]
    mov [rax + rcx * 8], rsi
    RETURN
.not_key:
    lea rdx, [rel k_shape]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_shape
    lea rax, [rel g_rec_shape]
    mov [rax + rdi * 8], rsi
    RETURN
.not_shape:
    lea rdx, [rel k_ingredients]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_ingredients
    ; shapeless: up to 9 patterns
    xor ebx, ebx
.ingredient:
    test rsi, rsi
    jz .ingredients_done
    cmp ebx, 9
    jae .ingredients_done
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    cmp byte [rax], 0
    je .ingredient
    imul ecx, edi, 9
    add ecx, ebx
    lea rdx, [rel g_rec_cells]
    mov [rdx + rcx * 8], rax
    inc ebx
    jmp .ingredient
.ingredients_done:
    lea rax, [rel g_rec_n]
    mov [rax + rdi], bl
    RETURN
.not_ingredients:
    lea rdx, [rel k_result]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_result
    ; "<item> [count]"
    mov rbx, rsi
.r_end:
    mov al, [rbx]
    test al, al
    jz .r_name
    cmp al, ' '
    je .r_count
    inc rbx
    jmp .r_end
.r_count:
    mov byte [rbx], 0
.r_skip:
    inc rbx
    cmp byte [rbx], ' '
    je .r_skip
    mov rcx, rbx
    call str_parse_u64
    test rax, rax
    jz .r_name
    cmp rax, 64
    ja .bad
    lea rcx, [rel g_rec_amount]
    mov [rcx + rdi], al
.r_name:
    mov rcx, rsi
    call item_find
    cmp eax, 0
    jle .no_item
    lea rcx, [rel g_rec_result]
    mov [rcx + rdi * 2], ax
    RETURN
.no_item:
    cmp dword [rel g_cur_quiet], 0
    jne .done
    lea rcx, [rel str_no_item]
    mov rdx, rsi
    call warn
    RETURN
.not_result:
    lea rdx, [rel k_station]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov rcx, rsi
    call station_find
    cmp eax, -1
    je .no_station
    lea rcx, [rel g_rec_station]
    mov [rcx + rdi], al
    RETURN
.no_station:
    lea rcx, [rel str_no_station]
    mov rdx, rsi
    call warn
    RETURN

.fuel_setting:
    ; <item pattern> = seconds
    mov eax, [rel g_fuel_count]
    cmp eax, MAX_FUELS
    jae .full_fuel
    mov rcx, rsi
    call str_parse_float
    mulss xmm0, [rel c_20]
    cvtss2si ecx, xmm0
    cmp ecx, 0
    jle .bad
    mov eax, [rel g_fuel_count]
    lea rdx, [rel g_fuel_tick]
    mov [rdx + rax * 4], ecx
    lea rdx, [rel g_fuel_pat]
    mov [rdx + rax * 8], rbx
    inc dword [rel g_fuel_count]
    RETURN
.full_fuel:
    lea rcx, [rel str_full]
    mov rdx, rbx
    call warn
    RETURN
.smelt_setting:
    lea rdx, [rel k_input]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_input
    lea rax, [rel g_smelt_input]
    mov [rax + rdi * 8], rsi
    RETURN
.not_input:
    lea rdx, [rel k_seconds]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_seconds
    mov rcx, rsi
    call str_parse_float
    mulss xmm0, [rel c_20]
    cvtss2si ecx, xmm0
    cmp ecx, 1
    jl .bad
    lea rax, [rel g_smelt_ticks]
    mov [rax + rdi * 4], ecx
    RETURN
.not_seconds:
    lea rdx, [rel k_blast]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_smelt_blast
    mov rcx, rsi
    call str_parse_u64
    test rax, rax
    setnz al
    lea rcx, [rel g_smelt_blast]
    mov [rcx + rdi], al
    RETURN
.not_smelt_blast:
    lea rdx, [rel k_result]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    ; "<item> [count]"
    mov rbx, rsi
.s_end:
    mov al, [rbx]
    test al, al
    jz .s_name
    cmp al, ' '
    je .s_count
    inc rbx
    jmp .s_end
.s_count:
    mov byte [rbx], 0
    lea rcx, [rbx + 1]
    call str_parse_u64
    test rax, rax
    jz .s_name
    cmp rax, 64
    ja .bad
    lea rcx, [rel g_smelt_amount]
    mov [rcx + rdi], al
.s_name:
    mov rcx, rsi
    call item_find
    cmp eax, 0
    jle .no_item
    lea rcx, [rel g_smelt_result]
    mov [rcx + rdi * 2], ax
    RETURN
.station_setting:
    lea rdx, [rel k_block]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_block
    mov rcx, rsi
    call block_find
    cmp eax, 0
    jle .no_block
    lea rcx, [rel g_station_unlit]
    mov [rcx + rdi * 2], ax
.map_states:
    ; every state of the block (a facing ...)
    lea rcx, [rel g_block_nstates]
    movzx r8d, word [rcx + rax * 2]
    test r8d, r8d
    jnz .states
    mov r8d, 1
.states:
    lea rcx, [rel g_block_station]
    add rcx, rax
    lea edx, [edi + 1]
.state:
    mov [rcx], dl
    inc rcx
    dec r8d
    jnz .state
    RETURN
.no_block:
    lea rcx, [rel str_no_block]
    mov rdx, rsi
    call warn
    RETURN
.not_block:
    lea rdx, [rel k_lit]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_lit
    mov rcx, rsi
    call block_find
    cmp eax, 0
    jle .no_block
    lea rcx, [rel g_station_lit]
    mov [rcx + rdi * 2], ax
    jmp .map_states                     ; (the lit block is the station too)
.not_lit:
    lea rdx, [rel k_speed]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_speed
    mov rcx, rsi
    call str_parse_u64
    cmp rax, 1
    jb .bad
    cmp rax, 8
    ja .bad
    lea rcx, [rel g_station_speed]
    mov [rcx + rdi], al
    RETURN
.not_speed:
    lea rdx, [rel k_blast]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_station_blast
    mov rcx, rsi
    call str_parse_u64
    test rax, rax
    setnz al
    lea rcx, [rel g_station_blast]
    mov [rcx + rdi], al
    RETURN
.not_station_blast:
    lea rdx, [rel k_slots]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_slots
    mov rcx, rsi
    call str_parse_u64
    cmp rax, 1
    jb .bad
    cmp rax, 27                         ; (a double container: twice that)
    ja .bad
    lea rcx, [rel g_station_slots]
    mov [rcx + rdi], al
    RETURN
.not_slots:
    lea rdx, [rel k_joins]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_joins
    mov rcx, rsi
    call str_parse_u64
    test rax, rax
    setnz al
    lea rcx, [rel g_station_joins]
    mov [rcx + rdi], al
    RETURN
.not_joins:
    lea rdx, [rel k_grid]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov rcx, rsi
    call str_parse_u64
    cmp rax, 2
    jb .bad
    cmp rax, 3
    ja .bad
    lea rcx, [rel g_station_grid]
    mov [rcx + rdi], al
    RETURN
.bad:
    lea rcx, [rel str_bad]
    mov rdx, rbx
    call warn
    RETURN
.unknown:
    lea rcx, [rel str_unknown]
    mov rdx, rbx
    call warn
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; flush_record — the [recipe] record just read becomes one recipe, or with
; `each` one per item that fits.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC flush_record, 0, rbx
    cmp dword [rel g_kind], REC_RECIPE
    jne .done
    mov dword [rel g_kind], REC_NONE
    cmp qword [rel g_each], 0
    jne .each
    mov qword [rel g_cap_ptr], 0
    xor ecx, ecx
    call new_recipe
    jmp .done
.each:
    mov ebx, 1
.item:
    cmp ebx, [rel g_item_count]
    jae .done
    lea rax, [rel g_item_names]
    mov rdx, [rax + rbx * 8]
    mov rcx, [rel g_each]
    call capture
    test eax, eax
    jz .next
    cmp qword [rel g_only], 0
    je .make
    ; `only`: the captured text must fit
    mov ecx, [rel g_cap_len]
    cmp ecx, 127
    ja .next
    mov rdx, [rel g_cap_ptr]
    lea r8, [rel g_cap_text]
    mov byte [r8 + rcx], 0
.cap:
    test ecx, ecx
    jz .cap_done
    dec ecx
    mov al, [rdx + rcx]
    mov [r8 + rcx], al
    jmp .cap
.cap_done:
    mov rcx, [rel g_only]
    lea rdx, [rel g_cap_text]
    call items_match_list
    test eax, eax
    jz .next
.make:
    mov ecx, 1
    call new_recipe
.next:
    inc ebx
    jmp .item
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; capture — eax = 1 if name rdx fits pattern rcx (text with one '*'; no '*':
; the same text); g_cap_ptr / g_cap_len = what '*' stood for.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC capture, 0, rbx, rsi, rdi
    mov rsi, rcx
    mov rdi, rdx
    ; the prefix
.prefix:
    movzx eax, byte [rsi]
    cmp al, '*'
    je .star
    test al, al
    jz .whole
    cmp al, [rdi]
    jne .no
    inc rsi
    inc rdi
    jmp .prefix
.whole:
    cmp byte [rdi], 0
    jne .no
    mov [rel g_cap_ptr], rdi
    mov dword [rel g_cap_len], 0
    jmp .yes
.star:
    inc rsi                             ; the suffix
    mov rcx, rsi
    call str_len
    mov rbx, rax
    mov rcx, rdi
    call str_len                        ; what is left of the name
    cmp rax, rbx
    jb .no
    sub rax, rbx                        ; the part '*' stands for
    lea rcx, [rdi + rax]
    xor edx, edx
.suffix:
    cmp rdx, rbx
    jae .match
    mov r8b, [rcx + rdx]
    cmp r8b, [rsi + rdx]
    jne .no
    inc rdx
    jmp .suffix
.match:
    test rax, rax
    jz .no                              ; ('*' stands for something)
    mov [rel g_cap_ptr], rdi
    mov [rel g_cap_len], eax
.yes:
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; subst — a copy of text rcx with every "{}" replaced by the capture.
;   out: rax = the copy (permanent arena), 0 if out of memory
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC subst, 0, rbx, rsi, rdi
    mov rsi, rcx
    call str_len
    mov ecx, [rel g_cap_len]
    shl ecx, 3                          ; (room for 8 "{}")
    lea rdx, [rax + rcx + 1]
    lea rcx, [rel g_arena_perm]
    mov r8d, 1
    call arena_alloc
    test rax, rax
    jz .done
    mov rbx, rax
    mov rdi, rax
    xor r9d, r9d                        ; "{}" replaced
.c:
    mov al, [rsi]
    cmp al, '{'
    jne .plain
    cmp byte [rsi + 1], '}'
    jne .plain
    cmp r9d, 8
    jae .plain
    inc r9d
    add rsi, 2
    mov rdx, [rel g_cap_ptr]
    mov ecx, [rel g_cap_len]
.cap:
    test ecx, ecx
    jz .c
    mov al, [rdx]
    mov [rdi], al
    inc rdx
    inc rdi
    dec ecx
    jmp .cap
.plain:
    mov [rdi], al
    test al, al
    jz .end
    inc rsi
    inc rdi
    jmp .c
.end:
    mov rax, rbx
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; new_recipe — a recipe from the record's pairs.
;   in:  ecx = 1: made by `each` (values get the capture; quiet)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC new_recipe, 0, rbx, rsi
    mov esi, ecx
    mov eax, [rel g_recipe_count]
    cmp eax, MAX_RECIPES
    jae .full
    inc dword [rel g_recipe_count]
    mov [rel g_cur], eax
    mov rcx, [rel g_rec_label]
    lea rdx, [rel g_rec_names]
    mov [rdx + rax * 8], rcx
    ; (the tables start zeroed: .bss)
    lea rcx, [rel g_rec_amount]
    mov byte [rcx + rax], 1
    lea rcx, [rel g_quiet]
    mov [rcx + rax], sil
    mov [rel g_cur_quiet], esi
    mov dword [rel g_applying], 1
    mov dword [rel g_kind], REC_RECIPE
    xor ebx, ebx
.pair:
    cmp ebx, [rel g_npairs]
    jae .done
    lea rax, [rel g_pair_values]
    mov rcx, [rax + rbx * 8]
    test esi, esi
    jz .value
    call subst
    test rax, rax
    jz .next
    mov rcx, rax
.value:
    mov rdx, rcx
    lea rax, [rel g_pair_names]
    mov rcx, [rax + rbx * 8]
    call recipes_pair
.next:
    inc ebx
    jmp .pair
.done:
    mov dword [rel g_applying], 0
    mov dword [rel g_kind], REC_NONE
    mov dword [rel g_cur_quiet], 0
    RETURN
.full:
    lea rcx, [rel str_full]
    mov rdx, [rel g_rec_label]
    call warn
    RETURN
ENDPROC

; pattern_any — eax = 1 if pattern list rcx matches some item
;   clobbers: volatile registers
PROC pattern_any, 0, rbx, rsi
    mov rsi, rcx
    mov ebx, 1
.item:
    cmp ebx, [rel g_item_count]
    jae .none
    lea rax, [rel g_item_names]
    mov rdx, [rax + rbx * 8]
    mov rcx, rsi
    call items_match_list
    test eax, eax
    jnz .done
    inc ebx
    jmp .item
.none:
    xor eax, eax
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; finish_recipe — turn recipe ebx's shape text and keys into cells; mark it
; usable (a result, and a shape or ingredients).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC finish_recipe, 0, rbx, rsi, rdi, r12, r13
    mov ebx, ecx
    lea rax, [rel g_rec_result]
    cmp word [rax + rbx * 2], 0
    je .drop
    lea rax, [rel g_rec_shape]
    mov rsi, [rax + rbx * 8]
    test rsi, rsi
    jnz .shaped
    lea rax, [rel g_rec_n]
    cmp byte [rax + rbx], 0
    je .drop
    jmp .ok
.shaped:
    ; rows split by '/': spaces around them don't count; '.' or ' ' inside a
    ; row is an empty cell
    xor r12d, r12d                      ; row
    xor r13d, r13d                      ; widest row
.row:
    cmp r12d, 3
    jae .rows_done
.lead:
    cmp byte [rsi], ' '
    jne .cells
    inc rsi
    jmp .lead
.cells:
    xor edi, edi                        ; column
.cell:
    movzx eax, byte [rsi]
    test eax, eax
    jz .row_end
    cmp eax, '/'
    je .row_end
    cmp edi, 3
    jae .skip_char
    cmp eax, ' '
    je .trail_or_empty
    cmp eax, '.'
    je .empty
    ; a key
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    ja .bad_key
    imul ecx, ebx, 26
    add ecx, eax
    lea rdx, [rel g_rec_keys]
    mov rdx, [rdx + rcx * 8]
    test rdx, rdx
    jz .bad_key
    imul ecx, ebx, 9
    imul eax, r12d, 3
    add ecx, eax
    add ecx, edi
    lea rax, [rel g_rec_cells]
    mov [rax + rcx * 8], rdx
.empty:
    inc edi
    cmp edi, r13d
    jbe .skip_char
    mov r13d, edi
.skip_char:
    inc rsi
    jmp .cell
.trail_or_empty:
    ; a space right before '/' or the end is not a cell
    mov rax, rsi
.ahead:
    inc rax
    cmp byte [rax], ' '
    je .ahead
    cmp byte [rax], 0
    je .row_end_at
    cmp byte [rax], '/'
    je .row_end_at
    jmp .empty
.row_end_at:
    mov rsi, rax
.row_end:
    inc r12d
    cmp byte [rsi], 0
    je .rows_done
    inc rsi                             ; past '/'
    jmp .row
.rows_done:
    test r13d, r13d
    jz .drop
    lea rax, [rel g_rec_w]
    mov [rax + rbx], r13b
    lea rax, [rel g_rec_h]
    mov [rax + rbx], r12b
.ok:
    ; every ingredient must be some item
    xor r12d, r12d
.check:
    cmp r12d, 9
    jae .usable
    imul ecx, ebx, 9
    add ecx, r12d
    lea rax, [rel g_rec_cells]
    mov rcx, [rax + rcx * 8]
    test rcx, rcx
    jz .check_next
    mov rsi, rcx
    call pattern_any
    test eax, eax
    jz .no_match
.check_next:
    inc r12d
    jmp .check
.usable:
    lea rax, [rel g_rec_ok]
    mov byte [rax + rbx], 1
    RETURN
.no_match:
    lea rax, [rel g_quiet]
    cmp byte [rax + rbx], 0
    jne .quiet
    lea rcx, [rel str_no_match]
    mov rdx, rsi
    call warn
    jmp .drop
.bad_key:
    lea rcx, [rel str_no_key]
    lea rax, [rel g_rec_names]
    mov rdx, [rax + rbx * 8]
    call warn
.drop:
    lea rax, [rel g_quiet]
    cmp byte [rax + rbx], 0
    jne .quiet
    lea rcx, [rel str_dropped]
    lea rax, [rel g_rec_names]
    mov rdx, [rax + rbx * 8]
    call warn
.quiet:
    RETURN
ENDPROC

; name_less — eax = 1 if rcx sorts before rdx   clobbers: rax, rcx, rdx, r8, r9
name_less:
.c:
    movzx eax, byte [rcx]
    movzx r8d, byte [rdx]
    or eax, 0x20
    or r8d, 0x20
    cmp eax, r8d
    jb .yes
    ja .no
    cmp byte [rcx], 0
    je .no
    inc rcx
    inc rdx
    jmp .c
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; collect_files — data\recipes\*.recipes, sorted
PROC collect_files, 0, rbx, rsi, rdi, r12
    mov dword [rel g_file_count], 0
    lea rcx, [rel g_path]
    lea rdx, [rel str_pattern]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_find]
    API FindFirstFileA, rcx, rdx
    cmp rax, -1
    je .done
    mov rbx, rax
.entry:
    test dword [rel g_find + FD_ATTR], 0x10
    jnz .next
    cmp dword [rel g_file_count], MAX_FILES
    jae .next
    lea rcx, [rel g_find + FD_NAME]
    call str_dup
    test rax, rax
    jz .next
    mov r12, rax
    mov esi, [rel g_file_count]
    lea rdi, [rel g_file_names]
.shift:
    test esi, esi
    jz .place
    mov rcx, r12
    mov rdx, [rdi + rsi * 8 - 8]
    call name_less
    test eax, eax
    jz .place
    mov rax, [rdi + rsi * 8 - 8]
    mov [rdi + rsi * 8], rax
    dec esi
    jmp .shift
.place:
    mov [rdi + rsi * 8], r12
    inc dword [rel g_file_count]
.next:
    lea rdx, [rel g_find]
    API FindNextFileA, rbx, rdx
    test eax, eax
    jnz .entry
    API FindClose, rbx
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; recipes_load — read every recipe file.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC recipes_load, 16, rbx, rsi
    call collect_files
    xor ebx, ebx
.file:
    cmp ebx, [rel g_file_count]
    jae .finish
    lea rax, [rel g_file_names]
    mov rsi, [rax + rbx * 8]
    mov [rel g_label], rsi
    lea rcx, [rel g_rel]
    lea rdx, [rel str_dir]
    call str_copy
    INVOKE str_copy, rax, rsi
    lea rcx, [rel g_path]
    lea rdx, [rel g_rel]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_perm]
    call file_load
    test rax, rax
    jz .next
    mov dword [rel g_kind], REC_NONE
    lea rdx, [rel recipes_pair]
    mov qword [rsp + 32], CFG_SECTIONS
    INVOKE cfg_parse_ex, rax, rdx, 0, rsi
    call flush_record                   ; (the file's last record)
.next:
    inc ebx
    jmp .file
.finish:
    xor ebx, ebx
.recipe:
    cmp ebx, [rel g_recipe_count]
    jae .loaded
    mov ecx, ebx
    call finish_recipe
    inc ebx
    jmp .recipe
.loaded:
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_loaded]
    call log_append_str
    xor ecx, ecx
    xor eax, eax
.usable:
    cmp eax, [rel g_recipe_count]
    jae .counted
    lea rdx, [rel g_rec_ok]
    movzx edx, byte [rdx + rax]
    add ecx, edx
    inc eax
    jmp .usable
.counted:
    call log_append_dec
    lea rcx, [rel str_usable]
    call log_append_str
    mov ecx, [rel g_recipe_count]
    call log_append_dec
    lea rcx, [rel str_loaded2]
    call log_append_str
    mov ecx, [rel g_station_count]
    call log_append_dec
    lea rcx, [rel str_smelts]
    call log_append_str
    mov ecx, [rel g_smelt_count]
    call log_append_dec
    lea rcx, [rel str_fuels]
    call log_append_str
    mov ecx, [rel g_fuel_count]
    call log_append_dec
    call log_end
%if BUILD_DEBUG
    call recipes_selfcheck
%endif
    RETURN
ENDPROC

%if BUILD_DEBUG
; -----------------------------------------------------------------------------
; recipes_selfcheck — debug builds: known grids must make known results
; (by hand, station 1 = the workbench); logs PASS or the failing case.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define K_GRID  0                       ; u16[9]
PROC recipes_selfcheck, 32, rbx, rsi, rdi
    lea rbx, [rel t_cases]
    xor esi, esi                        ; case
.case:
    lea rax, [rel t_cases_end]
    cmp rbx, rax
    jae .pass
    xor edi, edi
.cell:
    xor eax, eax
    mov rcx, [rbx + rdi * 8]
    test rcx, rcx
    jz .put
    call item_find
    cmp eax, 0
    jg .put
    xor eax, eax
.put:
    mov [LOCAL(K_GRID) + rdi * 2], ax
    inc edi
    cmp edi, 9
    jb .cell
    lea rcx, [LOCAL(K_GRID)]
    mov edx, 1
    call recipe_match
    mov rcx, [rbx + 72]                 ; the expected result
    test rcx, rcx
    jnz .want
    cmp eax, -1
    jne .fail
    jmp .next
.want:
    cmp eax, -1
    je .fail
    mov edi, eax
    call item_find
    lea rcx, [rel g_rec_result]
    movzx ecx, word [rcx + rdi * 2]
    cmp eax, ecx
    jne .fail
    lea rcx, [rel g_rec_amount]
    movzx ecx, byte [rcx + rdi]
    cmp rcx, [rbx + 80]
    jne .fail
.next:
    add rbx, 88
    inc esi
    jmp .case
.pass:
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_check_ok]
    call log_append_str
    mov ecx, esi
    call log_append_dec
    lea rcx, [rel str_check_ok2]
    call log_append_str
    call log_end
    RETURN
.fail:
    mov ecx, LOG_LEVEL_ERROR
    call log_begin
    lea rcx, [rel str_check_bad]
    call log_append_str
    mov ecx, esi
    call log_append_dec
    call log_end
    RETURN
ENDPROC
%endif

; -----------------------------------------------------------------------------
; smelt_find — the smelting of item ecx (edx = 1: in a blast furnace, which
; also does the `blast` ones).
;   out: eax = smelt index, -1 none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC smelt_find, 0, rbx, rsi, rdi
    test ecx, ecx
    jz .none
    mov edi, edx
    lea rax, [rel g_item_names]
    mov rsi, [rax + rcx * 8]
    xor ebx, ebx
.s:
    cmp ebx, [rel g_smelt_count]
    jae .none
    lea rax, [rel g_smelt_result]
    cmp word [rax + rbx * 2], 0
    je .next
    lea rax, [rel g_smelt_blast]
    cmp byte [rax + rbx], 0
    je .any
    test edi, edi
    jz .next
.any:
    lea rax, [rel g_smelt_input]
    mov rcx, [rax + rbx * 8]
    test rcx, rcx
    jz .next
    mov rdx, rsi
    call items_match_list
    test eax, eax
    jnz .found
.next:
    inc ebx
    jmp .s
.found:
    mov eax, ebx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; fuel_ticks — eax = how long item ecx burns (ticks), 0 if it is no fuel
;   clobbers: volatile registers
PROC fuel_ticks, 0, rbx, rsi
    xor eax, eax
    test ecx, ecx
    jz .done
    lea rax, [rel g_item_names]
    mov rsi, [rax + rcx * 8]
    xor ebx, ebx
.f:
    xor eax, eax
    cmp ebx, [rel g_fuel_count]
    jae .done
    lea rax, [rel g_fuel_pat]
    mov rcx, [rax + rbx * 8]
    mov rdx, rsi
    call items_match_list
    test eax, eax
    jnz .found
    inc ebx
    jmp .f
.found:
    lea rax, [rel g_fuel_tick]
    mov eax, [rax + rbx * 4]
.done:
    RETURN
ENDPROC

; cell_ok (recipe_cell_ok) — eax = 1 if item edx fits pattern rcx (no
; pattern: the cell must be empty)   clobbers: volatile registers
recipe_cell_ok:
PROC cell_ok, 0
    test rcx, rcx
    jnz .pattern
    xor eax, eax
    test edx, edx
    setz al
    RETURN
.pattern:
    xor eax, eax
    test edx, edx
    jz .done
    lea rax, [rel g_item_names]
    mov rdx, [rax + rdx * 8]
    call items_match_list
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; recipe_match — see the header.
;   in:  rcx = u16 items[9] (row by row, 3 wide), edx = the station in use
;        (0 by hand; a recipe made at a station needs that station; a recipe
;        bigger than 2 x 2 needs a 3 x 3 grid, which the caller's grid says)
;   out: eax = recipe index, -1 if nothing matches
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define M_GRID      0                   ; u16[9]
%define M_X0        20                  ; the used part of the grid
%define M_Y0        24
%define M_W         28
%define M_H         32
%define M_N         36                  ; items in the grid
%define M_MIRROR    40
%define M_STATION   44
PROC recipe_match, 48, rbx, rsi, rdi, r12, r13, r14
    mov [LOCAL(M_STATION)], edx
    ; copy the grid; find its used box
    mov r8d, 3
    mov r9d, 3
    mov r10d, -1
    mov r11d, -1
    xor edi, edi                        ; count
    xor eax, eax
.copy:
    movzx edx, word [rcx + rax * 2]
    mov [LOCAL(M_GRID) + rax * 2], dx
    test edx, edx
    jz .copy_next
    inc edi
    mov r14d, eax
    xor edx, edx
    mov esi, 3
    div esi                             ; eax = row, edx = column
    cmp edx, r8d
    cmovb r8d, edx
    cmp eax, r9d
    cmovb r9d, eax
    cmp edx, r10d
    jle .c1
    mov r10d, edx
.c1:
    cmp eax, r11d
    jle .c2
    mov r11d, eax
.c2:
    mov eax, r14d
.copy_next:
    inc eax
    cmp eax, 9
    jb .copy
    test edi, edi
    jz .none
    mov [LOCAL(M_N)], edi
    mov [LOCAL(M_X0)], r8d
    mov [LOCAL(M_Y0)], r9d
    sub r10d, r8d
    inc r10d
    mov [LOCAL(M_W)], r10d
    sub r11d, r9d
    inc r11d
    mov [LOCAL(M_H)], r11d
    ; every recipe
    xor ebx, ebx
.recipe:
    cmp ebx, [rel g_recipe_count]
    jae .none
    lea rax, [rel g_rec_ok]
    cmp byte [rax + rbx], 0
    je .next
    ; a station recipe needs its station
    lea rax, [rel g_rec_station]
    movzx eax, byte [rax + rbx]
    test eax, eax
    jz .station_ok
    cmp eax, [LOCAL(M_STATION)]
    jne .next
.station_ok:
    lea rax, [rel g_rec_w]
    movzx eax, byte [rax + rbx]
    test eax, eax
    jz .shapeless
    ; ---- shaped: same size, every cell fits (or fits mirrored) ----
    cmp eax, [LOCAL(M_W)]
    jne .next
    lea rax, [rel g_rec_h]
    movzx eax, byte [rax + rbx]
    cmp eax, [LOCAL(M_H)]
    jne .next
    mov dword [LOCAL(M_MIRROR)], 0
.try:
    xor r12d, r12d                      ; row
.srow:
    cmp r12d, [LOCAL(M_H)]
    jae .found
    xor r13d, r13d                      ; column
.scol:
    cmp r13d, [LOCAL(M_W)]
    jae .srow_next
    ; the recipe's cell (mirrored: from the right)
    mov eax, r13d
    cmp dword [LOCAL(M_MIRROR)], 0
    je .rc
    mov eax, [LOCAL(M_W)]
    dec eax
    sub eax, r13d
.rc:
    imul ecx, ebx, 9
    imul edx, r12d, 3
    add ecx, edx
    add ecx, eax
    lea rax, [rel g_rec_cells]
    mov rcx, [rax + rcx * 8]
    ; the grid's cell
    mov eax, r12d
    add eax, [LOCAL(M_Y0)]
    imul eax, eax, 3
    add eax, r13d
    add eax, [LOCAL(M_X0)]
    movzx edx, word [LOCAL(M_GRID) + rax * 2]
    call cell_ok
    test eax, eax
    jz .mismatch
    inc r13d
    jmp .scol
.srow_next:
    inc r12d
    jmp .srow
.mismatch:
    cmp dword [LOCAL(M_MIRROR)], 0
    jne .next
    mov dword [LOCAL(M_MIRROR)], 1
    jmp .try
    ; ---- shapeless: as many items as ingredients, each used once ----
.shapeless:
    lea rax, [rel g_rec_n]
    movzx eax, byte [rax + rbx]
    cmp eax, [LOCAL(M_N)]
    jne .next
    lea rdi, [rel g_used]
    mov qword [rdi], 0
    mov byte [rdi + 8], 0
    xor r12d, r12d                      ; grid cell
.gcell:
    cmp r12d, 9
    jae .found
    movzx r14d, word [LOCAL(M_GRID) + r12 * 2]
    test r14d, r14d
    jz .gnext
    xor r13d, r13d                      ; ingredient
.ing:
    lea rax, [rel g_rec_n]
    movzx eax, byte [rax + rbx]
    cmp r13d, eax
    jae .next                           ; this item fits no free ingredient
    lea rax, [rel g_used]
    cmp byte [rax + r13], 0
    jne .ing_next
    imul ecx, ebx, 9
    add ecx, r13d
    lea rax, [rel g_rec_cells]
    mov rcx, [rax + rcx * 8]
    mov edx, r14d
    call cell_ok
    test eax, eax
    jz .ing_next
    lea rax, [rel g_used]
    mov byte [rax + r13], 1
    jmp .gnext
.ing_next:
    inc r13d
    jmp .ing
.gnext:
    inc r12d
    jmp .gcell
.next:
    inc ebx
    jmp .recipe
.found:
    mov eax, ebx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

