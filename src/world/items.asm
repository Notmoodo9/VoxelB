; =============================================================================
; items.asm — the data-driven item registry (milestone 18,
; design/items/items_inventory.md, DATA_FORMAT.md "Item files").
;
; Every block (its first state; not the flowing states of liquids) is an
; item by itself, in block order. data/items/*.items (file-name order) add
; and change items and define the Creative inventory's tabs:
;   [tab <id>]    title = Building   icon = <item>
;                 blocks = *bricks*, *planks, stone*   (name patterns, '*'
;                 = anything; a block item goes to the first tab matching it)
;   [hidden]      blocks = *_wall_sign   (block items not in the Creative
;                 inventory)
;   [item <name>] title = ..., texture = <png in assets/textures/items/>,
;                 block = <block it places>, stack = 1..64, tab = <tab id>,
;                 hidden = 1 (not in the Creative inventory)
; An [item] with a block's name changes that block's item. Items left
; without a tab go to the last tab. Adding items never needs assembly.
;
; Public API (include/items.inc):
;   items_load() -> eax 1/0     after blocks_load
;   item_find(name) -> eax id or -1 (0 = no item)
;   tables by item id (u16 ids; capacity MAX_ITEMS):
;     g_item_count, g_item_names, g_item_titles (shown names), g_item_block
;     (u16 block placed, 0 = none), g_item_stack (u8), g_item_tab (u8),
;     g_item_tex (char* texture name or 0: a sprite instead of a block icon),
;     g_item_flags (ITEMF_*)
;   g_block_item (u16 per block id: the item of a block, any state)
;   tabs: g_tab_count, g_tab_titles, g_tab_icon (u16 item)
; =============================================================================
%define ITEMS_IMPL
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "block.inc"
%include "items.inc"

global items_load, item_find
global g_item_count, g_item_names, g_item_titles, g_item_block, g_item_stack
global g_item_tab, g_item_tex, g_item_flags, g_block_item
global g_tab_count, g_tab_titles, g_tab_icon

extern str_ieq, str_len, str_copy, str_parse_u64, str_dup

IMPORT FindFirstFileA, FindNextFileA, FindClose

%define MAX_FILES           64
%define FD_ATTR             0
%define FD_NAME             44
%define FILE_ATTRIBUTE_DIRECTORY 0x10
%define TAB_UNSET           0xFF
%define REC_NONE            0
%define REC_ITEM            1
%define REC_TAB             2
%define REC_HIDDEN          3

section .rdata
str_pattern:    db "data\items\*.items", 0
str_dir:        db "data\items\", 0
k_item:         db "item", 0
k_tab:          db "tab", 0
k_hidden_rec:   db "hidden", 0
k_title:        db "title", 0
k_texture:      db "texture", 0
k_block:        db "block", 0
k_stack:        db "stack", 0
k_hidden:       db "hidden", 0
k_icon:         db "icon", 0
k_blocks:       db "blocks", 0
str_unknown:    db "unknown setting: ", 0
str_no_block:   db "unknown block: ", 0
str_no_item:    db "unknown item: ", 0
str_no_tab:     db "unknown tab: ", 0
str_bad:        db "bad value for: ", 0
str_full:       db "too many items or tabs at: ", 0
str_loaded:     db "items: ", 0
str_loaded2:    db " items (", 0
str_loaded3:    db " from blocks), tabs ", 0

section .bss
alignb 8
g_item_names:   resq MAX_ITEMS
g_item_titles:  resq MAX_ITEMS
g_item_tex:     resq MAX_ITEMS
g_item_block:   resw MAX_ITEMS
g_item_stack:   resb MAX_ITEMS
g_item_tab:     resb MAX_ITEMS
g_item_flags:   resb MAX_ITEMS
alignb 8
g_block_item:   resw 65536
g_tab_titles:   resq MAX_TABS
g_tab_ids:      resq MAX_TABS
g_tab_patterns: resq MAX_TABS
g_tab_icon_name: resq MAX_TABS
g_tab_icon:     resw MAX_TABS
alignb 4
g_item_count:   resd 1
g_tab_count:    resd 1
g_block_items:  resd 1
g_kind:         resd 1
g_cur:          resd 1                  ; item / tab being read
g_file_count:   resd 1
alignb 8
g_label:        resq 1
g_hide_patterns: resq 1
g_file_names:   resq MAX_FILES
g_find:         resb 320
g_rel:          resb PATH_CAP
g_path:         resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; make_title — "stone_bricks" -> "Stone bricks" (a new string).
;   in:  rcx = name
;   out: rax = title (0 if out of memory)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC make_title, 0, rbx
    call str_dup
    test rax, rax
    jz .done
    mov rbx, rax
    mov rcx, rax
.c:
    mov dl, [rcx]
    test dl, dl
    jz .cap
    cmp dl, '_'
    jne .n
    mov byte [rcx], ' '
.n:
    inc rcx
    jmp .c
.cap:
    mov dl, [rbx]
    cmp dl, 'a'
    jb .ok
    cmp dl, 'z'
    ja .ok
    sub dl, 32
    mov [rbx], dl
.ok:
    mov rax, rbx
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; item_find — an item by name (case-insensitive).
;   in:  rcx = name
;   out: eax = item id, -1 if none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC item_find, 0, rbx, rsi
    mov rsi, rcx
    mov ebx, 1
.i:
    cmp ebx, [rel g_item_count]
    jae .none
    lea rax, [rel g_item_names]
    INVOKE str_ieq, [rax + rbx * 8], rsi
    test eax, eax
    jnz .found
    inc ebx
    jmp .i
.found:
    mov eax, ebx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; tab_find — eax = tab index of id rcx, -1 if none   clobbers: volatile
PROC tab_find, 0, rbx, rsi
    mov rsi, rcx
    xor ebx, ebx
.t:
    cmp ebx, [rel g_tab_count]
    jae .none
    lea rax, [rel g_tab_ids]
    INVOKE str_ieq, [rax + rbx * 8], rsi
    test eax, eax
    jnz .found
    inc ebx
    jmp .t
.found:
    mov eax, ebx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; glob_match — does a name match a pattern ('*' = any run of characters;
; case-insensitive)?
;   in:  rcx = pattern (ends at 0 or ','), rdx = name
;   out: eax = 1 / 0
;   clobbers: rax, rcx, rdx, r8, r9, r10, r11
; -----------------------------------------------------------------------------
glob_match:
    xor r10, r10                        ; pattern after the last '*' (0 none)
    xor r11, r11                        ; name position to retry from
.loop:
    movzx eax, byte [rcx]
    cmp eax, ','
    jne .not_end
    xor eax, eax
.not_end:
    cmp eax, '*'
    je .star
    movzx r8d, byte [rdx]
    test r8d, r8d
    jz .name_end
    test eax, eax
    jz .mismatch
    or eax, 0x20
    or r8d, 0x20
    cmp eax, r8d
    jne .mismatch
    inc rcx
    inc rdx
    jmp .loop
.star:
    inc rcx
    mov r10, rcx
    mov r11, rdx
    jmp .loop
.mismatch:
    test r10, r10
    jz .no
    inc r11
    cmp byte [r11 - 1], 0
    je .no
    mov rcx, r10
    mov rdx, r11
    jmp .loop
.name_end:
    ; the rest of the pattern must be only '*'
.tail:
    movzx eax, byte [rcx]
    test eax, eax
    jz .yes
    cmp eax, ','
    je .yes
    cmp eax, ' '
    je .yes
    cmp eax, '*'
    jne .no
    inc rcx
    jmp .tail
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; matches_list — eax = 1 if name rdx matches any pattern of the list rcx
; ("a*, *b, c")   clobbers: volatile registers
PROC matches_list, 0, rbx, rsi
    mov rbx, rcx
    mov rsi, rdx
.pattern:
    cmp byte [rbx], ' '
    jne .start
    inc rbx
    jmp .pattern
.start:
    cmp byte [rbx], 0
    je .no
    mov rcx, rbx
    mov rdx, rsi
    call glob_match
    test eax, eax
    jnz .yes
.skip:
    mov al, [rbx]
    test al, al
    jz .no
    inc rbx
    cmp al, ','
    jne .skip
    jmp .pattern
.yes:
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; new_item — append an item.
;   in:  rcx = name (kept)
;   out: eax = id, -1 if full
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC new_item, 0, rbx, rsi
    mov rsi, rcx
    mov ebx, [rel g_item_count]
    cmp ebx, MAX_ITEMS
    jae .full
    inc dword [rel g_item_count]
    lea rax, [rel g_item_names]
    mov [rax + rbx * 8], rsi
    mov rcx, rsi
    call make_title
    lea rcx, [rel g_item_titles]
    mov [rcx + rbx * 8], rax
    lea rax, [rel g_item_tex]
    mov qword [rax + rbx * 8], 0
    lea rax, [rel g_item_block]
    mov word [rax + rbx * 2], 0
    lea rax, [rel g_item_stack]
    mov byte [rax + rbx], 64
    lea rax, [rel g_item_tab]
    mov byte [rax + rbx], TAB_UNSET
    lea rax, [rel g_item_flags]
    mov byte [rax + rbx], 0
    mov eax, ebx
    RETURN
.full:
    mov eax, -1
    RETURN
ENDPROC

; warn — cfg warning with the current file as label: rcx = message, rdx = detail
PROC warn, 0
    mov r8, rdx
    mov rdx, rcx
    mov rcx, [rel g_label]
    call cfg_warn
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; items_pair — cfg_parse_ex callback: a "[kind name]" header (value 0) or a
; setting of the current record.
;   in:  rcx = name (or header text), rdx = value (0 for a header)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC items_pair, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    test rsi, rsi
    jnz .setting
    ; header: "item <name>", "tab <id>" or "hidden"
    mov dword [rel g_kind], REC_NONE
    lea rdx, [rel k_hidden_rec]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_hidden
    mov dword [rel g_kind], REC_HIDDEN
    RETURN
.not_hidden:
    mov rdi, rbx
.word_end:
    mov al, [rdi]
    test al, al
    jz .bad_header
    cmp al, ' '
    je .split
    inc rdi
    jmp .word_end
.split:
    mov byte [rdi], 0
.name:
    inc rdi
    cmp byte [rdi], ' '
    je .name
    lea rdx, [rel k_item]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .item_header
    lea rdx, [rel k_tab]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .tab_header
.bad_header:
    lea rcx, [rel str_unknown]
    mov rdx, rbx
    call warn
    RETURN
.item_header:
    mov rcx, rdi
    call item_find
    cmp eax, -1
    jne .item_set
    mov rcx, rdi
    call new_item
    cmp eax, -1
    je .full
.item_set:
    mov [rel g_cur], eax
    mov dword [rel g_kind], REC_ITEM
    RETURN
.tab_header:
    mov rcx, rdi
    call tab_find
    cmp eax, -1
    jne .tab_set
    mov eax, [rel g_tab_count]
    cmp eax, MAX_TABS
    jae .full
    inc dword [rel g_tab_count]
    lea rcx, [rel g_tab_ids]
    mov [rcx + rax * 8], rdi
    lea rcx, [rel g_tab_titles]
    mov [rcx + rax * 8], rdi
    lea rcx, [rel g_tab_patterns]
    mov qword [rcx + rax * 8], 0
    lea rcx, [rel g_tab_icon_name]
    mov qword [rcx + rax * 8], 0
.tab_set:
    mov [rel g_cur], eax
    mov dword [rel g_kind], REC_TAB
    RETURN
.full:
    lea rcx, [rel str_full]
    mov rdx, rdi
    call warn
    RETURN

.setting:
    mov edi, [rel g_cur]
    cmp dword [rel g_kind], REC_ITEM
    je .item_setting
    cmp dword [rel g_kind], REC_HIDDEN
    jne .not_hide
    lea rdx, [rel k_blocks]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov [rel g_hide_patterns], rsi
    RETURN
.not_hide:
    cmp dword [rel g_kind], REC_TAB
    jne .done
    ; ---- tab ----
    lea rdx, [rel k_title]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .t_icon
    lea rax, [rel g_tab_titles]
    mov [rax + rdi * 8], rsi
    RETURN
.t_icon:
    lea rdx, [rel k_icon]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .t_blocks
    lea rax, [rel g_tab_icon_name]
    mov [rax + rdi * 8], rsi
    RETURN
.t_blocks:
    lea rdx, [rel k_blocks]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    lea rax, [rel g_tab_patterns]
    mov [rax + rdi * 8], rsi
    RETURN

    ; ---- item ----
.item_setting:
    lea rdx, [rel k_title]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .i_texture
    lea rax, [rel g_item_titles]
    mov [rax + rdi * 8], rsi
    RETURN
.i_texture:
    lea rdx, [rel k_texture]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .i_block
    lea rax, [rel g_item_tex]
    mov [rax + rdi * 8], rsi
    RETURN
.i_block:
    lea rdx, [rel k_block]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .i_stack
    mov rcx, rsi
    call block_find
    cmp eax, 0
    jle .no_block
    lea rcx, [rel g_item_block]
    mov [rcx + rdi * 2], ax
    RETURN
.no_block:
    lea rcx, [rel str_no_block]
    mov rdx, rsi
    call warn
    RETURN
.i_stack:
    lea rdx, [rel k_stack]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .i_tab
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    test rax, rax
    jz .bad
    cmp rax, 64
    ja .bad
    lea rcx, [rel g_item_stack]
    mov [rcx + rdi], al
    RETURN
.i_tab:
    lea rdx, [rel k_tab]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .i_hidden
    mov rcx, rsi
    call tab_find
    cmp eax, -1
    je .no_tab
    lea rcx, [rel g_item_tab]
    mov [rcx + rdi], al
    RETURN
.no_tab:
    lea rcx, [rel str_no_tab]
    mov rdx, rsi
    call warn
    RETURN
.i_hidden:
    lea rdx, [rel k_hidden]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    lea rcx, [rel g_item_flags]
    and byte [rcx + rdi], ~ITEMF_HIDDEN
    test rax, rax
    jz .done
    or byte [rcx + rdi], ITEMF_HIDDEN
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

; name_less — eax = 1 if rcx sorts before rdx (case-insensitive)
;   clobbers: rax, rcx, rdx, r8, r9
name_less:
.c:
    movzx eax, byte [rcx]
    movzx r8d, byte [rdx]
    mov r9d, eax
    sub r9d, 'A'
    cmp r9d, 25
    ja .a_ok
    add eax, 32
.a_ok:
    mov r9d, r8d
    sub r9d, 'A'
    cmp r9d, 25
    ja .b_ok
    add r8d, 32
.b_ok:
    cmp eax, r8d
    jb .yes
    ja .no
    test eax, eax
    jz .no
    inc rcx
    inc rdx
    jmp .c
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; collect_files — data\items\*.items, sorted by name
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
    test dword [rel g_find + FD_ATTR], FILE_ATTRIBUTE_DIRECTORY
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

; load_file — parse data\items\<rcx>
PROC load_file, 0, rbx
    mov rbx, rcx
    mov [rel g_label], rbx
    lea rcx, [rel g_rel]
    lea rdx, [rel str_dir]
    call str_copy
    INVOKE str_copy, rax, rbx
    lea rcx, [rel g_path]
    lea rdx, [rel g_rel]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_perm]
    call file_load
    test rax, rax
    jz .fail
    mov dword [rel g_kind], REC_NONE
    lea rdx, [rel items_pair]
    INVOKE cfg_parse_ex, rax, rdx, 0, rbx, CFG_SECTIONS
    RETURN
.fail:
    LOG_WARN "items: could not read an item file"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; items_load — see the header.
;   out: eax = 1 (0 if there are no items at all)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC items_load, 0, rbx, rsi, rdi, r12
    mov dword [rel g_item_count], 1     ; (0 = no item)
    mov qword [rel g_hide_patterns], 0
    mov dword [rel g_tab_count], 0
    lea rdi, [rel g_block_item]
    xor eax, eax
    mov ecx, 65536 * 2 / 8
    rep stosq
    ; ---- every block's first state, but not flowing liquid states ----
    mov ebx, 1
.block:
    cmp ebx, [rel g_block_count]
    jae .blocks_done
    lea rax, [rel g_block_source]
    cmp word [rax + rbx * 2], 0
    jne .next_block                     ; (a flowing liquid: no item)
    lea rax, [rel g_block_state]
    cmp byte [rax + rbx], 0
    jne .state
    lea rax, [rel g_block_names]
    mov rcx, [rax + rbx * 8]
    call new_item
    cmp eax, -1
    je .blocks_done
    mov esi, eax                        ; the item of this block (and its states)
    lea rcx, [rel g_item_block]
    mov [rcx + rsi * 2], bx
    lea rcx, [rel g_block_item]
    mov [rcx + rbx * 2], si
    jmp .next_block
.state:
    ; later states share their base block's item
    lea rcx, [rel g_block_item]
    mov [rcx + rbx * 2], si
.next_block:
    inc ebx
    jmp .block
.blocks_done:
    mov eax, [rel g_item_count]
    dec eax
    mov [rel g_block_items], eax
    ; ---- the files ----
    call collect_files
    xor ebx, ebx
.file:
    cmp ebx, [rel g_file_count]
    jae .files_done
    lea rax, [rel g_file_names]
    mov rcx, [rax + rbx * 8]
    call load_file
    inc ebx
    jmp .file
.files_done:
    ; ---- tabs: icons; block items by pattern; the rest to the last tab ----
    xor ebx, ebx
.tab_icon:
    cmp ebx, [rel g_tab_count]
    jae .assign
    lea rax, [rel g_tab_icon]
    mov word [rax + rbx * 2], 1
    lea rax, [rel g_tab_icon_name]
    mov rcx, [rax + rbx * 8]
    test rcx, rcx
    jz .tab_next
    call item_find
    cmp eax, 0
    jle .tab_bad_icon
    lea rcx, [rel g_tab_icon]
    mov [rcx + rbx * 2], ax
    jmp .tab_next
.tab_bad_icon:
    lea rax, [rel g_tab_icon_name]
    mov rdx, [rax + rbx * 8]
    lea rcx, [rel str_no_item]
    call warn
.tab_next:
    inc ebx
    jmp .tab_icon
.assign:
    mov ebx, 1
.item:
    cmp ebx, [rel g_item_count]
    jae .loaded
    mov rcx, [rel g_hide_patterns]
    test rcx, rcx
    jz .not_hidden_item
    cmp ebx, [rel g_block_items]
    ja .not_hidden_item                 ; (only block items)
    lea rax, [rel g_item_names]
    mov rdx, [rax + rbx * 8]
    call matches_list
    test eax, eax
    jz .not_hidden_item
    lea rax, [rel g_item_flags]
    or byte [rax + rbx], ITEMF_HIDDEN
.not_hidden_item:
    lea rax, [rel g_item_tab]
    cmp byte [rax + rbx], TAB_UNSET
    jne .item_next
    xor esi, esi                        ; tab
.match:
    cmp esi, [rel g_tab_count]
    jae .last
    lea rax, [rel g_tab_patterns]
    mov rcx, [rax + rsi * 8]
    test rcx, rcx
    jz .match_next
    lea rax, [rel g_item_names]
    mov rdx, [rax + rbx * 8]
    call matches_list
    test eax, eax
    jnz .set
.match_next:
    inc esi
    jmp .match
.last:
    mov esi, [rel g_tab_count]
    dec esi
    jns .set
    xor esi, esi
.set:
    lea rax, [rel g_item_tab]
    mov [rax + rbx], sil
.item_next:
    inc ebx
    jmp .item
.loaded:
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_loaded]
    call log_append_str
    mov ecx, [rel g_item_count]
    dec ecx
    call log_append_dec
    lea rcx, [rel str_loaded2]
    call log_append_str
    mov ecx, [rel g_block_items]
    call log_append_dec
    lea rcx, [rel str_loaded3]
    call log_append_str
    mov ecx, [rel g_tab_count]
    call log_append_dec
    call log_end
    xor eax, eax
    cmp dword [rel g_item_count], 1
    seta al
    RETURN
ENDPROC
