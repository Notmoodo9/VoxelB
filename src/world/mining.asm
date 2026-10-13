; =============================================================================
; mining.asm — how blocks are mined and what they drop (milestone 18,
; design/items/items_inventory.md; DATA_FORMAT.md "mining.cfg").
;
; data/items/mining.cfg holds materials and drops:
;   [material <name>]  hardness = 1.5   tool = pickaxe   tier = wood
;                      blocks = stone, *bricks     shapes = plant, tall_plant
;   [drops]            <block pattern> = <item> [count] | none
;   [bonus]            <block pattern> = <item> <count>, <percent>   a chance
;                      of something extra besides the usual drop (resin
;                      from logs, plant fibre from grass)
; A block gets the first material whose `shapes` or `blocks` match it (all
; its states alike); unmatched blocks are hardness 1, any tool, no tier. A
; block drops its own item unless a [drops] line says otherwise.
;
; Rules (the classic ones): a block with a tier needs that tool at that
; tier or better to drop anything; time = hardness x 1.5 (or x 5 when it
; can't be harvested), divided by the tool's speed when it is the right
; tool. Hardness 0 breaks at once; below 0 never.
;
; Public API:
;   mining_load()                        after items_load
;   mining_time(ecx = block, edx = item in hand (0 = hand))
;       -> xmm0 seconds (< 0: unbreakable), eax 1 if it will drop
;   mining_drop(ecx = block) -> eax item (0 = nothing), edx count
;   mining_bonus(ecx = block) -> eax item (0 = none), edx count, r8d percent
;   g_block_hardness (f32), g_block_tool, g_block_tier (u8) per block id
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "block.inc"
%include "items.inc"

global mining_load, mining_time, mining_drop, mining_bonus
global g_block_hardness, g_block_tool, g_block_tier

extern str_ieq, str_parse_u64, str_parse_float, item_find

%define MAX_MATERIALS   64
%define MAX_DROPS       128
%define REC_NONE        0
%define REC_MATERIAL    1
%define REC_DROPS       2
%define REC_BONUS       3

section .rdata
str_file:       db "data/items/mining.cfg", 0
str_label:      db "mining.cfg", 0
k_material:     db "material", 0
k_drops:        db "drops", 0
k_bonus:        db "bonus", 0
k_hardness:     db "hardness", 0
k_tool:         db "tool", 0
k_tier:         db "tier", 0
k_blocks:       db "blocks", 0
k_shapes:       db "shapes", 0
v_none:         db "none", 0
str_unknown:    db "unknown setting: ", 0
str_bad:        db "bad value for: ", 0
str_no_item:    db "unknown item: ", 0
str_full:       db "too many materials or drops at: ", 0
str_loaded:     db "mining: materials ", 0
str_loaded2:    db ", drop rules ", 0
s_cube:         db "cube", 0
s_slab:         db "slab", 0
s_stairs:       db "stairs", 0
s_fence:        db "fence", 0
s_gate:         db "fence_gate", 0
s_door:         db "door", 0
s_trapdoor:     db "trapdoor", 0
s_ladder:       db "ladder", 0
s_sign:         db "sign", 0
s_wall_sign:    db "wall_sign", 0
s_plate:        db "pressure_plate", 0
s_wall:         db "wall", 0
s_pillar:       db "pillar", 0
s_pane:         db "pane", 0
s_spike:        db "spike", 0
s_plant:        db "plant", 0
s_tall_plant:   db "tall_plant", 0
s_stalk:        db "stalk", 0
s_fluid:        db "fluid", 0
align 8
shape_names:    dq s_cube, s_slab, s_stairs, s_fence, s_gate, s_door, s_trapdoor
                dq s_ladder, s_sign, s_wall_sign, s_plate, s_wall, s_pillar, s_pane, s_spike
                dq s_plant, s_tall_plant, s_stalk, s_fluid
align 4
c_one:          dd 1.0
c_harvest:      dd 1.5
c_no_harvest:   dd 5.0

section .bss
alignb 8
g_mat_blocks:   resq MAX_MATERIALS      ; patterns (0 none)
g_mat_shapes:   resd MAX_MATERIALS      ; bit per SHAPE_*
g_mat_hard:     resd MAX_MATERIALS      ; f32
g_mat_tool:     resb MAX_MATERIALS
g_mat_tier:     resb MAX_MATERIALS
alignb 8
g_drop_pat:     resq MAX_DROPS
g_drop_val:     resq MAX_DROPS
g_bonus_pat:    resq MAX_DROPS
g_bonus_val:    resq MAX_DROPS
g_block_hardness: resd 65536
g_block_drop:   resw 65536              ; item dropped (by base block id)
g_block_dropn:  resb 65536              ; how many
g_block_bonus:  resw 65536              ; [bonus]: the extra item
g_block_bonusn: resb 65536
g_block_bonusp: resb 65536              ; its chance (percent)
g_block_tool:   resb 65536
g_block_tier:   resb 65536
alignb 4
g_mat_count:    resd 1
g_drop_count:   resd 1
g_bonus_count:  resd 1
g_kind:         resd 1
g_cur:          resd 1
g_mark:         resq 1
g_path:         resb PATH_CAP

section .text

; warn — rcx = message, rdx = detail (label: mining.cfg)
PROC warn, 0
    mov r8, rdx
    mov rdx, rcx
    lea rcx, [rel str_label]
    call cfg_warn
    RETURN
ENDPROC

; shape_bits — eax = bits of the shape names in list rcx   clobbers: volatile
PROC shape_bits, 0, rbx, rsi, rdi, r12
    mov rsi, rcx
    xor edi, edi
.token:
    test rsi, rsi
    jz .done
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    mov rbx, rax
    xor r12d, r12d
.name:
    cmp r12d, SHAPE_COUNT
    jae .unknown
    lea rax, [rel shape_names]
    INVOKE str_ieq, [rax + r12 * 8], rbx
    test eax, eax
    jnz .found
    inc r12d
    jmp .name
.found:
    bts edi, r12d
    jmp .token
.unknown:
    lea rcx, [rel str_bad]
    mov rdx, rbx
    call warn
    jmp .token
.done:
    mov eax, edi
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mining_pair — cfg_parse_ex callback.
;   in:  rcx = name / header, rdx = value (0 for a header)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC mining_pair, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    test rsi, rsi
    jnz .setting
    ; "[material <name>]" or "[drops]"
    mov dword [rel g_kind], REC_NONE
    lea rdx, [rel k_drops]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_drops
    mov dword [rel g_kind], REC_DROPS
    RETURN
.not_drops:
    lea rdx, [rel k_bonus]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_bonus
    mov dword [rel g_kind], REC_BONUS
    RETURN
.not_bonus:
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
    lea rdx, [rel k_material]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .bad_header
    mov eax, [rel g_mat_count]
    cmp eax, MAX_MATERIALS
    jae .full
    inc dword [rel g_mat_count]
    mov [rel g_cur], eax
    lea rcx, [rel g_mat_blocks]
    mov qword [rcx + rax * 8], 0
    lea rcx, [rel g_mat_shapes]
    mov dword [rcx + rax * 4], 0
    mov edx, [rel c_one]
    lea rcx, [rel g_mat_hard]
    mov [rcx + rax * 4], edx
    lea rcx, [rel g_mat_tool]
    mov byte [rcx + rax], TOOL_NONE
    lea rcx, [rel g_mat_tier]
    mov byte [rcx + rax], TIER_HAND
    mov dword [rel g_kind], REC_MATERIAL
    RETURN
.bad_header:
    lea rcx, [rel str_unknown]
    mov rdx, rbx
    call warn
    RETURN
.full:
    lea rcx, [rel str_full]
    mov rdx, rbx
    call warn
    RETURN

.setting:
    cmp dword [rel g_kind], REC_BONUS
    jne .not_bonus_line
    mov eax, [rel g_bonus_count]
    cmp eax, MAX_DROPS
    jae .full
    inc dword [rel g_bonus_count]
    lea rcx, [rel g_bonus_pat]
    mov [rcx + rax * 8], rbx
    lea rcx, [rel g_bonus_val]
    mov [rcx + rax * 8], rsi
    RETURN
.not_bonus_line:
    cmp dword [rel g_kind], REC_DROPS
    jne .material
    mov eax, [rel g_drop_count]
    cmp eax, MAX_DROPS
    jae .full
    inc dword [rel g_drop_count]
    lea rcx, [rel g_drop_pat]
    mov [rcx + rax * 8], rbx
    lea rcx, [rel g_drop_val]
    mov [rcx + rax * 8], rsi
    RETURN
.material:
    cmp dword [rel g_kind], REC_MATERIAL
    jne .done
    mov edi, [rel g_cur]
    lea rdx, [rel k_hardness]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_hard
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    lea rcx, [rel g_mat_hard]
    movss [rcx + rdi * 4], xmm0
    RETURN
.not_hard:
    lea rdx, [rel k_tool]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_tool
    mov rcx, rsi
    call item_tool_index
    test eax, eax
    js .bad
    lea rcx, [rel g_mat_tool]
    mov [rcx + rdi], al
    RETURN
.not_tool:
    lea rdx, [rel k_tier]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_tier
    mov rcx, rsi
    call item_tier_index
    test eax, eax
    js .bad
    lea rcx, [rel g_mat_tier]
    mov [rcx + rdi], al
    RETURN
.not_tier:
    lea rdx, [rel k_blocks]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_blocks
    lea rcx, [rel g_mat_blocks]
    mov [rcx + rdi * 8], rsi
    RETURN
.not_blocks:
    lea rdx, [rel k_shapes]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov rcx, rsi
    call shape_bits
    lea rcx, [rel g_mat_shapes]
    mov [rcx + rdi * 4], eax
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
; parse_drop — "<item> [count]" or "none".
;   in:  rcx = text (kept)
;   out: eax = item (0 = nothing, -1 = unknown), edx = count
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC parse_drop, 0, rbx, rsi
    mov rbx, rcx
    lea rdx, [rel v_none]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .item
    xor eax, eax
    xor edx, edx
    RETURN
.item:
    ; the name ends at a space; a count may follow
    mov rsi, rbx
.end:
    mov al, [rsi]
    test al, al
    jz .one
    cmp al, ' '
    je .count
    inc rsi
    jmp .end
.one:
    mov rcx, rbx
    call item_find
    mov edx, 1
    RETURN
.count:
    mov byte [rsi], 0
    mov rcx, rbx
    call item_find
    mov byte [rsi], ' '
    mov ebx, eax
.skip:
    inc rsi
    cmp byte [rsi], ' '
    je .skip
    mov rcx, rsi
    call str_parse_u64
    mov edx, eax
    test edx, edx
    jnz .counted
    mov edx, 1
.counted:
    cmp edx, 64
    jbe .ok
    mov edx, 64
.ok:
    mov eax, ebx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mining_load — read mining.cfg and settle every block.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC mining_load, 16, rbx, rsi, rdi, r12, r13
    mov dword [rel g_mat_count], 0
    mov dword [rel g_drop_count], 0
    mov dword [rel g_bonus_count], 0
    lea rcx, [rel g_path]
    lea rdx, [rel str_file]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_perm]         ; (patterns point into the text)
    call file_load
    test rax, rax
    jz .missing
    mov dword [rel g_kind], REC_NONE
    lea rdx, [rel mining_pair]
    lea r9, [rel str_label]
    mov qword [rsp + 32], CFG_SECTIONS
    INVOKE cfg_parse_ex, rax, rdx, 0, r9
    jmp .settle
.missing:
    LOG_WARN "mining: data/items/mining.cfg missing; every block is hardness 1"
.settle:
    mov ebx, 1                          ; block id
.block:
    cmp ebx, [rel g_block_count]
    jae .loaded
    ; defaults
    mov eax, [rel c_one]
    lea rcx, [rel g_block_hardness]
    mov [rcx + rbx * 4], eax
    lea rcx, [rel g_block_tool]
    mov byte [rcx + rbx], TOOL_NONE
    lea rcx, [rel g_block_tier]
    mov byte [rcx + rbx], TIER_HAND
    lea rcx, [rel g_block_item]
    movzx eax, word [rcx + rbx * 2]
    lea rcx, [rel g_block_drop]
    mov [rcx + rbx * 2], ax
    lea rcx, [rel g_block_dropn]
    mov byte [rcx + rbx], 1
    ; the base block's name (states share it)
    lea rax, [rel g_block_state]
    movzx eax, byte [rax + rbx]
    mov r12d, ebx
    sub r12d, eax                       ; base id
    lea rax, [rel g_block_names]
    mov r13, [rax + r12 * 8]
    lea rax, [rel g_block_shape]
    movzx edi, byte [rax + rbx]         ; shape
    ; the first material that matches
    xor esi, esi
.mat:
    cmp esi, [rel g_mat_count]
    jae .drops
    lea rax, [rel g_mat_shapes]
    bt dword [rax + rsi * 4], edi
    jc .use
    lea rax, [rel g_mat_blocks]
    mov rcx, [rax + rsi * 8]
    test rcx, rcx
    jz .mat_next
    mov rdx, r13
    call items_match_list
    test eax, eax
    jnz .use
.mat_next:
    inc esi
    jmp .mat
.use:
    lea rax, [rel g_mat_hard]
    mov eax, [rax + rsi * 4]
    lea rcx, [rel g_block_hardness]
    mov [rcx + rbx * 4], eax
    lea rax, [rel g_mat_tool]
    mov al, [rax + rsi]
    lea rcx, [rel g_block_tool]
    mov [rcx + rbx], al
    lea rax, [rel g_mat_tier]
    mov al, [rax + rsi]
    lea rcx, [rel g_block_tier]
    mov [rcx + rbx], al
.drops:
    xor esi, esi
.drop:
    cmp esi, [rel g_drop_count]
    jae .bonus
    lea rax, [rel g_drop_pat]
    mov rcx, [rax + rsi * 8]
    mov rdx, r13
    call items_match_list
    test eax, eax
    jnz .drop_found
    inc esi
    jmp .drop
.drop_found:
    lea rax, [rel g_drop_val]
    mov rcx, [rax + rsi * 8]
    call parse_drop
    cmp eax, -1
    jne .drop_set
    lea rax, [rel g_drop_val]
    mov rdx, [rax + rsi * 8]
    lea rcx, [rel str_no_item]
    call warn
    jmp .bonus
.drop_set:
    lea rcx, [rel g_block_drop]
    mov [rcx + rbx * 2], ax
    lea rcx, [rel g_block_dropn]
    mov [rcx + rbx], dl
.bonus:
    ; the first [bonus] line that matches
    xor esi, esi
.bonus_line:
    cmp esi, [rel g_bonus_count]
    jae .next
    lea rax, [rel g_bonus_pat]
    mov rcx, [rax + rsi * 8]
    mov rdx, r13
    call items_match_list
    test eax, eax
    jnz .bonus_found
    inc esi
    jmp .bonus_line
.bonus_found:
    lea rax, [rel g_bonus_val]
    mov rcx, [rax + rsi * 8]
    call parse_drop
    cmp eax, 0
    jle .next                           ; (unknown items: warned by [drops] users)
    lea rcx, [rel g_block_bonus]
    mov [rcx + rbx * 2], ax
    lea rcx, [rel g_block_bonusn]
    mov [rcx + rbx], dl
    ; the chance: after the ','
    lea rax, [rel g_bonus_val]
    mov rcx, [rax + rsi * 8]
.comma:
    mov al, [rcx]
    test al, al
    jz .always
    inc rcx
    cmp al, ','
    jne .comma
    call str_parse_u64
    cmp rax, 100
    jbe .chance
.always:
    mov eax, 100
.chance:
    lea rcx, [rel g_block_bonusp]
    mov [rcx + rbx], al
.next:
    inc ebx
    jmp .block
.loaded:
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_loaded]
    call log_append_str
    mov ecx, [rel g_mat_count]
    call log_append_dec
    lea rcx, [rel str_loaded2]
    call log_append_str
    mov ecx, [rel g_drop_count]
    call log_append_dec
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mining_time — see the header.
;   in:  ecx = block, edx = item in hand
;   out: xmm0 = seconds (negative: unbreakable), eax = 1 if it will drop
;   clobbers: rax, rcx, rdx, r8, r9, r10, xmm0, xmm1
; -----------------------------------------------------------------------------
mining_time:
    lea rax, [rel g_block_hardness]
    movss xmm0, [rax + rcx * 4]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jb .never
    ; the tool in hand: type r8d, tier r9d, &speed rcx
    lea rax, [rel g_item_tool]
    movzx r8d, byte [rax + rdx]
    lea rax, [rel g_item_tier]
    movzx r9d, byte [rax + rdx]
    lea rax, [rel g_block_tool]
    movzx eax, byte [rax + rcx]         ; the block's tool
    lea r10, [rel g_block_tier]
    movzx r10d, byte [r10 + rcx]        ; the block's tier
    lea rcx, [rel g_item_speed]
    lea rcx, [rcx + rdx * 4]
    mov edx, r10d
    ; can it be harvested?
    test edx, edx
    jz .harvest                         ; no tier: always drops
    cmp r8d, eax
    jne .no_harvest
    cmp r9d, edx
    jb .no_harvest
.harvest:
    mulss xmm0, [rel c_harvest]
    mov edx, 1
    jmp .speed
.no_harvest:
    mulss xmm0, [rel c_no_harvest]
    xor edx, edx
.speed:
    ; the right tool divides by its speed
    test eax, eax
    jz .done
    cmp r8d, eax
    jne .done
    divss xmm0, [rcx]
.done:
    mov eax, edx
    ret
.never:
    xor eax, eax
    ret

; mining_bonus — eax = block ecx's [bonus] item (0 none), edx = count,
; r8d = chance in percent
mining_bonus:
    lea rax, [rel g_block_bonusp]
    movzx r8d, byte [rax + rcx]
    lea rax, [rel g_block_bonusn]
    movzx edx, byte [rax + rcx]
    lea rax, [rel g_block_bonus]
    movzx eax, word [rax + rcx * 2]
    ret

; mining_drop — eax = item dropped by block ecx (0 nothing), edx = count
mining_drop:
    lea rax, [rel g_block_dropn]
    movzx edx, byte [rax + rcx]
    lea rax, [rel g_block_drop]
    movzx eax, word [rax + rcx * 2]
    ret
