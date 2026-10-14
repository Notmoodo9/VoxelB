; =============================================================================
; mobs.asm — the data-driven animal registry (milestone 19,
; design/mobs/passive_animals.md, DATA_FORMAT.md "Mob files").
;
; Every data/mobs/*.mob file is read at start-up in file-name order. A file
; holds records:
;   [model <name>]  skin_size = 64 64
;                   part = name, motion, pivot x y z, box x y z, size w h d, u v
;                   (pixels, 16 = a block; facing north, y up from the feet;
;                   motion none | head | leg0 | leg1 | tail | coat | wing0 |
;                   wing1)
;   [mob <name>]    title, health, size = width height (blocks), speed
;                   (blocks per second), temper = calm | wild | fierce,
;                   drop = item, min, max (up to 4; item "coat": the
;                   variant's coat), food, graze, shear = tool, min, max,
;                   glide = fastest fall (blocks per second),
;                   lays = item, min, max (seconds), sexes, jump (blocks),
;                   fall (blocks), hops, eats = block patterns,
;                   rams = distance, % per second, milk = item, item,
;                   baby_skin = variant, skin (part 3b; drop lines may end
;                   in `male` and / or a chance `N%`),
;                   variant = name, skin, model [, coat item] (skin: a
;                   64 x 64 picture in assets/textures/mobs/)
;   [spawn]         mob, variant (default: the mob's first), biomes = list,
;                   chance = % of those biomes' columns with a herd,
;                   herd = min, max, mix = variant, % (up to 4),
;                   altitude = lowest ground (part 3b)
; Models come before the mobs that use them (file order). Adding an animal
; never needs assembly.
;
; Public API (include/mobs.inc):
;   mobs_load() -> eax 1   after items_load and biomes_load
;   g_models / g_model_count, g_parts / g_part_count, g_mobs / g_mob_count,
;   g_variants / g_variant_count, g_spawns / g_spawn_count
; =============================================================================
%define MOBS_IMPL
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "items.inc"
%include "biome.inc"
%include "block.inc"
%include "mobs.inc"

global mobs_load
global g_models, g_model_count, g_parts, g_part_count
global g_mobs, g_mob_count, g_variants, g_variant_count, g_spawns, g_spawn_count
global g_block_eat, g_baby_skins, g_baby_skin_count

extern str_ieq, str_copy, str_parse_float, str_parse_u64, str_dup, items_match_list

IMPORT FindFirstFileA, FindNextFileA, FindClose

%define MAX_FILES           64
%define FD_ATTR             0
%define FD_NAME             44
%define FILE_ATTRIBUTE_DIRECTORY 0x10
%define REC_NONE            0
%define REC_MODEL           1
%define REC_MOB             2
%define REC_SPAWN           3

section .rdata
str_pattern:    db "data\mobs\*.mob", 0
str_dir:        db "data\mobs\", 0
k_model:        db "model", 0
k_mob:          db "mob", 0
k_spawn:        db "spawn", 0
k_skin_size:    db "skin_size", 0
k_part:         db "part", 0
k_title:        db "title", 0
k_health:       db "health", 0
k_size:         db "size", 0
k_speed:        db "speed", 0
k_temper:       db "temper", 0
k_drop:         db "drop", 0
k_food:         db "food", 0
k_graze:        db "graze", 0
k_variant:      db "variant", 0
k_biomes:       db "biomes", 0
k_chance:       db "chance", 0
k_herd:         db "herd", 0
k_calm:         db "calm", 0
k_wild:         db "wild", 0
k_fierce:       db "fierce", 0
k_shear:        db "shear", 0
k_glide:        db "glide", 0
k_lays:         db "lays", 0
k_mix:          db "mix", 0
k_coat:         db "coat", 0
k_male:         db "male", 0
k_sexes:        db "sexes", 0
k_jump:         db "jump", 0
k_fall:         db "fall", 0
k_hops:         db "hops", 0
k_eats:         db "eats", 0
k_rams:         db "rams", 0
k_milk:         db "milk", 0
k_baby_skin:    db "baby_skin", 0
k_altitude:     db "altitude", 0
str_eat_full:   db "mobs: too many animals with `eats` (8 at most): ", 0
m_0:            db "none", 0
m_1:            db "head", 0
m_2:            db "leg0", 0
m_3:            db "leg1", 0
m_4:            db "tail", 0
m_5:            db "coat", 0
m_6:            db "wing0", 0
m_7:            db "wing1", 0
m_8:            db "head_male", 0
align 8
motion_names:   dq m_0, m_1, m_2, m_3, m_4, m_5, m_6, m_7, m_8
%define MOTION_NAMES 9
str_unknown:    db "unknown setting: ", 0
str_bad:        db "bad value for: ", 0
str_full:       db "too many models, parts, mobs, variants or spawns at: ", 0
str_no_item:    db "unknown item: ", 0
str_no_model:   db "unknown model: ", 0
str_no_mob:     db "unknown mob: ", 0
str_no_variant: db "unknown variant: ", 0
str_no_biome:   db "unknown biome: ", 0
str_skin:       db "only 64 x 64 skins are supported: ", 0
str_loaded:     db "mobs: ", 0
str_loaded2:    db " animals, ", 0
str_loaded3:    db " variants, ", 0
str_loaded4:    db " models (", 0
str_loaded5:    db " boxes), ", 0
str_loaded6:    db " spawn rules", 0

section .bss
alignb 16
g_parts:        resb MAX_PARTS * MPART_size
g_models:       resb MAX_MODELS * MODEL_size
g_mobs:         resb MAX_MOBS * MOB_size
g_variants:     resb MAX_VARIANTS * VARIANT_size
g_spawns:       resb MAX_SPAWNS * SPAWN_size
g_part_count:   resd 1
g_model_count:  resd 1
g_mob_count:    resd 1
g_variant_count: resd 1
g_spawn_count:  resd 1
g_eat_text:     resq MAX_MOBS           ; `eats` until every block is known
alignb 8
g_baby_skins:   resq MAX_VARIANTS       ; texture names of the young's skins
g_baby_skin_count: resd 1
alignb 16
g_block_eat:    resb 65536              ; bit per eats list: animals eat this block
g_kind:         resd 1
g_cur:          resd 1
g_file_count:   resd 1
alignb 8
g_label:        resq 1
g_file_names:   resq MAX_FILES
g_vals:         resd 16                 ; parsed numbers
g_find:         resb 320
g_rel:          resb PATH_CAP
g_path:         resb PATH_CAP

section .text

; warn — "<file>: <message><detail>"   in: rcx = message, rdx = detail
PROC warn, 0
    mov r8, rdx
    mov rdx, rcx
    mov rcx, [rel g_label]
    call cfg_warn
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; floats — parse up to r8d space-separated numbers into g_vals + rdx*4.
;   in:  rcx = text, edx = first g_vals index, r8d = how many
;   out: eax = 1 if all were found
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC floats, 0, rbx, rsi, rdi
    mov rsi, rcx
    mov ebx, edx
    lea edi, [rdx + r8]
.n:
    cmp ebx, edi
    jae .ok
    test rsi, rsi
    jz .bad
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    mov rsi, rdx                        ; (after the number)
    lea rax, [rel g_vals]
    movss [rax + rbx * 4], xmm0
    inc ebx
    jmp .n
.ok:
    mov eax, 1
    RETURN
.bad:
    xor eax, eax
    RETURN
ENDPROC

; find — eax = index of name rcx in a table of structures, -1
;   in:  rcx = name, rdx = table (name pointer first), r8d = count, r9d = stride
;   clobbers: volatile registers
PROC find, 0, rbx, rsi, rdi, r12, r13
    mov r12, rcx
    mov rsi, rdx
    mov edi, r8d
    mov r13d, r9d
    xor ebx, ebx
.n:
    cmp ebx, edi
    jae .none
    mov eax, ebx
    imul eax, r13d
    INVOKE str_ieq, [rsi + rax], r12
    test eax, eax
    jnz .found
    inc ebx
    jmp .n
.found:
    mov eax, ebx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mobs_pair — cfg_parse_ex callback: a "[kind name]" header (value 0) or a
; setting of the current record.
;   in:  rcx = name (or header text), rdx = value (0 for a header)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC mobs_pair, 16, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    mov rsi, rdx
    test rsi, rsi
    jnz .setting
    ; ---- header: "model <name>", "mob <name>" or "spawn" ----
    mov dword [rel g_kind], REC_NONE
    lea rdx, [rel k_spawn]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .spawn_header
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
    lea rdx, [rel k_model]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .model_header
    lea rdx, [rel k_mob]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .mob_header
.bad_header:
    lea rcx, [rel str_unknown]
    mov rdx, rbx
    call warn
    RETURN
.model_header:
    mov eax, [rel g_model_count]
    cmp eax, MAX_MODELS
    jae .full
    inc dword [rel g_model_count]
    mov [rel g_cur], eax
    imul eax, eax, MODEL_size
    lea rcx, [rel g_models]
    add rcx, rax
    mov [rcx + MODEL.name], rdi
    mov eax, [rel g_part_count]
    mov [rcx + MODEL.first], eax
    mov dword [rcx + MODEL.count], 0
    mov dword [rel g_kind], REC_MODEL
    RETURN
.mob_header:
    mov eax, [rel g_mob_count]
    cmp eax, MAX_MOBS
    jae .full
    inc dword [rel g_mob_count]
    mov [rel g_cur], eax
    imul eax, eax, MOB_size
    lea rcx, [rel g_mobs]
    add rcx, rax
    mov rdx, rcx
    xor eax, eax
.clear_mob:
    mov byte [rdx], 0
    inc rdx
    inc eax
    cmp eax, MOB_size
    jb .clear_mob
    mov [rcx + MOB.name], rdi
    mov [rcx + MOB.title], rdi
    mov dword [rcx + MOB.health], 10
    mov dword [rcx + MOB.width], __?float32?__(0.9)
    mov dword [rcx + MOB.height], __?float32?__(1.0)
    mov dword [rcx + MOB.speed], __?float32?__(1.2)
    mov dword [rcx + MOB.jump], __?float32?__(1.0)
    mov dword [rcx + MOB.fall], 3
    mov eax, [rel g_variant_count]
    mov [rcx + MOB.first_var], eax
    mov dword [rel g_kind], REC_MOB
    RETURN
.spawn_header:
    mov eax, [rel g_spawn_count]
    cmp eax, MAX_SPAWNS
    jae .full
    inc dword [rel g_spawn_count]
    mov [rel g_cur], eax
    imul eax, eax, SPAWN_size
    lea rcx, [rel g_spawns]
    add rcx, rax
    mov dword [rcx + SPAWN.biomes], 0
    mov dword [rcx + SPAWN.variant], -1
    mov dword [rcx + SPAWN.chance], 0
    mov dword [rcx + SPAWN.herd_min], 2
    mov dword [rcx + SPAWN.herd_max], 4
    mov dword [rcx + SPAWN.mixes], 0
    mov dword [rcx + SPAWN.altitude], -100000
    mov dword [rel g_kind], REC_SPAWN
    RETURN
.full:
    lea rcx, [rel str_full]
    mov rdx, rdi
    call warn
    RETURN

.setting:
    cmp dword [rel g_kind], REC_MODEL
    je .model_setting
    cmp dword [rel g_kind], REC_MOB
    je .mob_setting
    cmp dword [rel g_kind], REC_SPAWN
    je .spawn_setting
    RETURN

    ; ---- model ----
.model_setting:
    mov eax, [rel g_cur]
    imul eax, eax, MODEL_size
    lea r12, [rel g_models]
    add r12, rax
    lea rdx, [rel k_skin_size]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .m_part
    mov rcx, rsi
    xor edx, edx
    mov r8d, 2
    call floats
    test eax, eax
    jz .bad
    movss xmm0, [rel g_vals]
    comiss xmm0, [rel c_skin]
    jne .bad_skin
    movss xmm0, [rel g_vals + 4]
    comiss xmm0, [rel c_skin]
    jne .bad_skin
    RETURN
.bad_skin:
    lea rcx, [rel str_skin]
    mov rdx, [r12 + MODEL.name]
    call warn
    RETURN
.m_part:
    lea rdx, [rel k_part]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov eax, [rel g_part_count]
    cmp eax, MAX_PARTS
    jae .full_part
    cmp dword [r12 + MODEL.count], MAX_MODEL_PARTS
    jae .full_part
    imul eax, eax, MPART_size
    lea r13, [rel g_parts]
    add r13, rax
    ; name (skipped), motion, pivot, box, size, uv
    mov rcx, rsi
    call cfg_next_token
    test rdx, rdx
    jz .bad
    mov rcx, rdx
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov rcx, rax
    lea rdx, [rel motion_names]
    mov r8d, MOTION_NAMES
    mov r9d, 8
    call find
    test eax, eax
    js .bad
    mov [r13 + MPART.motion], eax
    mov dword [r13 + MPART.pad], 0
    xor edi, edi                        ; vals index
.m_triple:
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .bad
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov rcx, rax
    mov edx, edi
    mov r8d, 3
    cmp edi, 9
    jb .m_n
    mov r8d, 2
.m_n:
    call floats
    test eax, eax
    jz .bad
    add edi, 3
    cmp edi, 12
    jb .m_triple
    ; vals: pivot 0-2, box 3-5, size 6-8, uv 9-10
    lea rax, [rel g_vals]
    xor ecx, ecx
.m_copy:
    mov edx, [rax + rcx * 4]
    mov [r13 + MPART.pivot + rcx * 4], edx
    inc ecx
    cmp ecx, 9
    jb .m_copy
    cvttss2si ecx, [rax + 36]
    mov [r13 + MPART.u], cx
    cvttss2si ecx, [rax + 40]
    mov [r13 + MPART.v], cx
    inc dword [rel g_part_count]
    inc dword [r12 + MODEL.count]
    RETURN
.full_part:
    lea rcx, [rel str_full]
    mov rdx, [r12 + MODEL.name]
    call warn
    RETURN

    ; ---- mob ----
.mob_setting:
    mov eax, [rel g_cur]
    imul eax, eax, MOB_size
    lea r12, [rel g_mobs]
    add r12, rax
    lea rdx, [rel k_title]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_health
    mov [r12 + MOB.title], rsi
    RETURN
.b_health:
    lea rdx, [rel k_health]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_size
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    test rax, rax
    jz .bad
    cmp rax, 30000
    ja .bad
    mov [r12 + MOB.health], eax
    RETURN
.b_size:
    lea rdx, [rel k_size]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_speed
    mov rcx, rsi
    xor edx, edx
    mov r8d, 2
    call floats
    test eax, eax
    jz .bad
    mov eax, [rel g_vals]
    mov [r12 + MOB.width], eax
    mov eax, [rel g_vals + 4]
    mov [r12 + MOB.height], eax
    RETURN
.b_speed:
    lea rdx, [rel k_speed]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_temper
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    movss [r12 + MOB.speed], xmm0
    RETURN
.b_temper:
    lea rdx, [rel k_temper]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_drop
    lea rdx, [rel k_calm]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jz .b_wild
    mov dword [r12 + MOB.temper], TEMPER_CALM
    RETURN
.b_wild:
    lea rdx, [rel k_wild]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jz .b_fierce
    mov dword [r12 + MOB.temper], TEMPER_WILD
    RETURN
.b_fierce:
    lea rdx, [rel k_fierce]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jz .bad
    mov dword [r12 + MOB.temper], TEMPER_FIERCE
    RETURN
.b_drop:
    lea rdx, [rel k_drop]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_food
    mov edi, [r12 + MOB.drops]
    cmp edi, MAX_MOB_DROPS
    jae .full_mob
    mov rcx, rsi
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov [LOCAL(8)], rax
    lea rdx, [rel k_coat]
    INVOKE str_ieq, rax, rdx
    mov ecx, eax
    mov eax, DROP_COAT
    test ecx, ecx
    jnz .drop_item
    mov rcx, [LOCAL(8)]
    call item_find
    cmp eax, 0
    jle .no_item
.drop_item:
    mov [r12 + MOB.drop_item + rdi * 2], ax
    mov byte [r12 + MOB.drop_min + rdi], 1
    mov byte [r12 + MOB.drop_max + rdi], 1
    mov byte [r12 + MOB.drop_pct + rdi], 100
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .drop_done
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov rcx, rax
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, 64
    ja .bad
    mov [r12 + MOB.drop_min + rdi], al
    mov [r12 + MOB.drop_max + rdi], al
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .drop_done
    call cfg_next_token
    mov [LOCAL(0)], rdx                 ; (`male` may follow)
    mov rcx, rax
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, 64
    ja .bad
    cmp al, [r12 + MOB.drop_min + rdi]
    jb .bad
    mov [r12 + MOB.drop_max + rdi], al
    ; then `male` (only males drop it: antlers) and / or a chance `N%`
.drop_opt:
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .drop_done
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov [LOCAL(8)], rax
    lea rdx, [rel k_male]
    INVOKE str_ieq, rax, rdx
    test eax, eax
    jz .drop_pct
    bts dword [r12 + MOB.drop_male], edi
    jmp .drop_opt
.drop_pct:
    mov rcx, [LOCAL(8)]
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, 100
    ja .bad
    mov [r12 + MOB.drop_pct + rdi], al
    jmp .drop_opt
.drop_done:
    inc dword [r12 + MOB.drops]
    RETURN
.no_item:
    lea rcx, [rel str_no_item]
    mov rdx, [LOCAL(8)]
    call warn
    RETURN
.full_mob:
    lea rcx, [rel str_full]
    mov rdx, [r12 + MOB.name]
    call warn
    RETURN
.b_food:
    ; food = item, item ... (up to 4)
    lea rdx, [rel k_food]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_graze
    mov [LOCAL(0)], rsi
.food_next:
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .food_done
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov [LOCAL(8)], rax
    mov rcx, rax
    call item_find
    cmp eax, 0
    jle .food_unknown
    mov ecx, [r12 + MOB.foods]
    cmp ecx, MAX_MOB_FOODS
    jae .full_mob
    mov [r12 + MOB.food + rcx * 2], ax
    inc dword [r12 + MOB.foods]
    jmp .food_next
.food_unknown:
    lea rcx, [rel str_no_item]
    mov rdx, [LOCAL(8)]
    call warn
    jmp .food_next
.food_done:
    RETURN
.b_graze:
    lea rdx, [rel k_graze]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_shear
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    mov [r12 + MOB.graze], eax
    RETURN
.b_shear:
    ; shear = tool, min, max (coat items)
    lea rdx, [rel k_shear]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_glide
    mov rcx, rsi
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov [LOCAL(8)], rax
    mov rcx, rax
    call item_find
    cmp eax, 0
    jle .no_item
    mov [r12 + MOB.shear_tool], ax
    mov rcx, [LOCAL(0)]
    lea rdx, [rel g_vals]
    call two_counts
    test eax, eax
    jz .bad
    cmp dword [rel g_vals + 4], 64
    ja .bad
    mov eax, [rel g_vals]
    mov [r12 + MOB.shear_min], al
    mov eax, [rel g_vals + 4]
    mov [r12 + MOB.shear_max], al
    RETURN
.b_glide:
    ; glide = fastest fall, blocks per second
    lea rdx, [rel k_glide]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_lays
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jb .bad
    mulss xmm0, [rel c_per_tick]
    movss [r12 + MOB.glide], xmm0
    RETURN
.b_lays:
    ; lays = item, min, max (seconds between two)
    lea rdx, [rel k_lays]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_sexes
    mov rcx, rsi
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov [LOCAL(8)], rax
    mov rcx, rax
    call item_find
    cmp eax, 0
    jle .no_item
    mov [r12 + MOB.lay_item], ax
    mov rcx, [LOCAL(0)]
    lea rdx, [rel g_vals]
    call two_counts
    test eax, eax
    jz .bad
    mov eax, [rel g_vals]
    test eax, eax
    jz .bad
    imul eax, eax, 20
    mov [r12 + MOB.lay_min], eax
    mov eax, [rel g_vals + 4]
    imul eax, eax, 20
    mov [r12 + MOB.lay_max], eax
    RETURN
.b_sexes:
    ; sexes = 1: born male or female; hops = 1: moves in hops
    lea rdx, [rel k_sexes]
    INVOKE str_ieq, rbx, rdx
    mov edi, MOB.sexes
    test eax, eax
    jnz .b_flag
    lea rdx, [rel k_hops]
    INVOKE str_ieq, rbx, rdx
    mov edi, MOB.hops
    test eax, eax
    jnz .b_flag
    lea rdx, [rel k_fall]
    INVOKE str_ieq, rbx, rdx
    mov edi, MOB.fall
    test eax, eax
    jz .b_jump
.b_flag:
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, 16
    ja .bad
    mov [r12 + rdi], eax
    RETURN
.b_jump:
    ; jump = blocks it can jump up (deer 2, goats 3)
    lea rdx, [rel k_jump]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_eats
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    comiss xmm0, [rel c_one_f]
    jb .bad
    comiss xmm0, [rel c_four_f]
    ja .bad
    movss [r12 + MOB.jump], xmm0
    RETURN
.b_eats:
    ; eats = block patterns (resolved when every mob is read)
    lea rdx, [rel k_eats]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_rams
    mov eax, [rel g_cur]
    lea rcx, [rel g_eat_text]
    mov [rcx + rax * 8], rsi
    RETURN
.b_rams:
    ; rams = distance (blocks), % chance per second
    lea rdx, [rel k_rams]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_milk
    mov rcx, rsi
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov rcx, rax
    call str_parse_float
    test eax, eax
    jz .bad
    movss [r12 + MOB.rams_dist], xmm0
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .bad
    call str_parse_float
    test eax, eax
    jz .bad
    movss [r12 + MOB.rams_pct], xmm0
    RETURN
.b_milk:
    ; milk = the item that milks it, what that item becomes
    lea rdx, [rel k_milk]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_baby
    mov rcx, rsi
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov [LOCAL(8)], rax
    mov rcx, rax
    call item_find
    cmp eax, 0
    jle .no_item
    mov [r12 + MOB.milk_from], ax
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .bad
    call cfg_next_token
    mov [LOCAL(8)], rax
    mov rcx, rax
    call item_find
    cmp eax, 0
    jle .no_item
    mov [r12 + MOB.milk_to], ax
    RETURN
.b_baby:
    ; baby_skin = variant, skin: the young of that look wear this skin
    lea rdx, [rel k_baby_skin]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .b_variant
    mov rcx, rsi
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov [LOCAL(8)], rax
    ; the variant among this mob's
    mov edi, [r12 + MOB.first_var]
    mov r13d, [r12 + MOB.var_count]
    add r13d, edi
.bv:
    cmp edi, r13d
    jae .no_variant8
    imul eax, edi, VARIANT_size
    lea rcx, [rel g_variants]
    INVOKE str_ieq, [rcx + rax + VARIANT.name], [LOCAL(8)]
    test eax, eax
    jnz .bv_found
    inc edi
    jmp .bv
.bv_found:
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .bad
    call cfg_next_token
    mov ecx, [rel g_baby_skin_count]
    cmp ecx, MAX_VARIANTS
    jae .full_mob
    lea rdx, [rel g_baby_skins]
    mov [rdx + rcx * 8], rax
    inc dword [rel g_baby_skin_count]
    inc ecx                             ; (1 + index until the layers are known)
    imul eax, edi, VARIANT_size
    lea rdx, [rel g_variants]
    mov [rdx + rax + VARIANT.baby_layer], ecx
    RETURN
.no_variant8:
    lea rcx, [rel str_no_variant]
    mov rdx, [LOCAL(8)]
    call warn
    RETURN
.b_variant:
    lea rdx, [rel k_variant]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov eax, [rel g_variant_count]
    cmp eax, MAX_VARIANTS
    jae .full_mob
    imul eax, eax, VARIANT_size
    lea r13, [rel g_variants]
    add r13, rax
    ; name, skin, model
    mov rcx, rsi
    call cfg_next_token
    mov [r13 + VARIANT.name], rax
    test rdx, rdx
    jz .bad
    mov rcx, rdx
    call cfg_next_token
    mov [r13 + VARIANT.skin], rax
    test rdx, rdx
    jz .bad
    mov rcx, rdx
    call cfg_next_token
    mov [LOCAL(0)], rdx                 ; (the coat item, if any)
    mov [LOCAL(8)], rax
    mov rcx, rax
    lea rdx, [rel g_models]
    mov r8d, [rel g_model_count]
    mov r9d, MODEL_size
    call find
    test eax, eax
    js .no_model
    mov [r13 + VARIANT.model], eax
    mov eax, [rel g_cur]
    mov [r13 + VARIANT.mob], eax
    mov qword [r13 + VARIANT.coat], 0
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .v_counted
    call cfg_next_token
    mov [LOCAL(8)], rax
    mov rcx, rax
    call item_find
    cmp eax, 0
    jle .no_item
    mov [r13 + VARIANT.coat], eax
.v_counted:
    inc dword [rel g_variant_count]
    inc dword [r12 + MOB.var_count]
    RETURN
.no_model:
    lea rcx, [rel str_no_model]
    mov rdx, [LOCAL(8)]
    call warn
    RETURN

    ; ---- spawn ----
.spawn_setting:
    mov eax, [rel g_cur]
    imul eax, eax, SPAWN_size
    lea r12, [rel g_spawns]
    add r12, rax
    lea rdx, [rel k_mob]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .s_variant
    mov rcx, rsi
    lea rdx, [rel g_mobs]
    mov r8d, [rel g_mob_count]
    mov r9d, MOB_size
    call find
    test eax, eax
    js .no_mob
    imul eax, eax, MOB_size
    lea rcx, [rel g_mobs]
    cmp dword [rcx + rax + MOB.var_count], 0
    je .no_variant
    mov eax, [rcx + rax + MOB.first_var]
    mov [r12 + SPAWN.variant], eax
    RETURN
.no_mob:
    lea rcx, [rel str_no_mob]
    mov rdx, rsi
    call warn
    RETURN
.s_variant:
    lea rdx, [rel k_variant]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .s_biomes
    ; a variant of the record's mob (set first)
    mov eax, [r12 + SPAWN.variant]
    test eax, eax
    js .no_variant
    imul eax, eax, VARIANT_size
    lea rcx, [rel g_variants]
    mov eax, [rcx + rax + VARIANT.mob]
    imul eax, eax, MOB_size
    lea rcx, [rel g_mobs]
    add rcx, rax
    mov edi, [rcx + MOB.first_var]
    mov r13d, [rcx + MOB.var_count]
    add r13d, edi
.s_v:
    cmp edi, r13d
    jae .no_variant
    mov eax, edi
    imul eax, eax, VARIANT_size
    lea rcx, [rel g_variants]
    INVOKE str_ieq, [rcx + rax + VARIANT.name], rsi
    test eax, eax
    jnz .s_v_found
    inc edi
    jmp .s_v
.s_v_found:
    mov [r12 + SPAWN.variant], edi
    RETURN
.no_variant:
    lea rcx, [rel str_no_variant]
    mov rdx, rsi
    call warn
    RETURN
.s_biomes:
    lea rdx, [rel k_biomes]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .s_chance
    mov [LOCAL(0)], rsi
.s_b:
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .s_b_done
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov [LOCAL(8)], rax
    mov rcx, rax
    lea rdx, [rel g_biomes]
    mov r8d, [rel g_biome_count]
    mov r9d, BIOME_size
    call find
    test eax, eax
    js .s_b_unknown
    cmp eax, 32
    jae .s_b_unknown                    ; (a bit per biome: 32 at most)
    bts dword [r12 + SPAWN.biomes], eax
    jmp .s_b
.s_b_unknown:
    cmp dword [rel g_biome_count], 0
    je .s_b                             ; (the flat test world has no biomes)
    lea rcx, [rel str_no_biome]
    mov rdx, [LOCAL(8)]
    call warn
    jmp .s_b
.s_b_done:
    RETURN
.s_chance:
    lea rdx, [rel k_chance]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .s_herd
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    movss [r12 + SPAWN.chance], xmm0
    RETURN
.s_herd:
    lea rdx, [rel k_herd]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .s_mix
    mov rcx, rsi
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov rcx, rax
    call str_parse_u64
    test r8, r8
    jz .bad
    test rax, rax
    jz .bad
    cmp rax, 16
    ja .bad
    mov [r12 + SPAWN.herd_min], eax
    mov [r12 + SPAWN.herd_max], eax
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .herd_done
    call cfg_next_token
    mov rcx, rax
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, 16
    ja .bad
    cmp eax, [r12 + SPAWN.herd_min]
    jb .bad
    mov [r12 + SPAWN.herd_max], eax
.herd_done:
    RETURN
.s_mix:
    ; mix = variant, % (another look of the same animal in the herd)
    lea rdx, [rel k_mix]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .s_altitude
    mov eax, [r12 + SPAWN.mixes]
    cmp eax, MAX_MIX
    jae .full_spawn
    mov eax, [r12 + SPAWN.variant]
    test eax, eax
    js .no_variant
    mov rcx, rsi
    call cfg_next_token
    mov [LOCAL(0)], rdx
    mov [LOCAL(8)], rax
    mov ecx, [r12 + SPAWN.variant]
    mov rdx, rax
    call variant_of_mob
    test eax, eax
    js .mix_unknown
    mov ecx, [r12 + SPAWN.mixes]
    mov [r12 + SPAWN.mix_var + rcx * 4], eax
    mov rcx, [LOCAL(0)]
    test rcx, rcx
    jz .bad
    call str_parse_float
    test eax, eax
    jz .bad
    mov ecx, [r12 + SPAWN.mixes]
    movss [r12 + SPAWN.mix_pct + rcx * 4], xmm0
    inc dword [r12 + SPAWN.mixes]
    RETURN
.mix_unknown:
    lea rcx, [rel str_no_variant]
    mov rdx, [LOCAL(8)]
    call warn
    RETURN
.s_altitude:
    ; altitude = the lowest ground a herd of this rule stands on
    lea rdx, [rel k_altitude]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    cvttss2si eax, xmm0
    mov [r12 + SPAWN.altitude], eax
    RETURN
.full_spawn:
    lea rcx, [rel str_full]
    mov rdx, rbx
    call warn
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
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; two_counts — "min, max" (whole numbers, max >= min; one number: both)
;   in:  rcx = text (0: bad), rdx = u32[2] out
;   out: eax = 1 if good
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC two_counts, 0, rbx, rsi
    mov rbx, rdx
    test rcx, rcx
    jz .bad
    call cfg_next_token
    mov rsi, rdx
    mov rcx, rax
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, 0xFFFFFF
    ja .bad
    mov [rbx], eax
    mov [rbx + 4], eax
    test rsi, rsi
    jz .ok
    mov rcx, rsi
    call cfg_next_token
    mov rcx, rax
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, 0xFFFFFF
    ja .bad
    cmp eax, [rbx]
    jb .bad
    mov [rbx + 4], eax
.ok:
    mov eax, 1
    RETURN
.bad:
    xor eax, eax
    RETURN
ENDPROC

; variant_of_mob — eax = the variant named rdx of variant ecx's animal, -1
;   clobbers: volatile registers
PROC variant_of_mob, 0, rbx, rsi, rdi
    mov rsi, rdx
    imul eax, ecx, VARIANT_size
    lea rcx, [rel g_variants]
    mov eax, [rcx + rax + VARIANT.mob]
    imul eax, eax, MOB_size
    lea rcx, [rel g_mobs]
    add rcx, rax
    mov ebx, [rcx + MOB.first_var]
    mov edi, [rcx + MOB.var_count]
    add edi, ebx
.v:
    cmp ebx, edi
    jae .none
    imul eax, ebx, VARIANT_size
    lea rcx, [rel g_variants]
    INVOKE str_ieq, [rcx + rax + VARIANT.name], rsi
    test eax, eax
    jnz .found
    inc ebx
    jmp .v
.found:
    mov eax, ebx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; resolve_part3b — once every mob is read: jump speeds, the blocks each
; `eats` list names (a bit per list in g_block_eat), the young's skin
; layers (after the variants' own).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC resolve_part3b, 16, rbx, rsi, rdi, r12
    ; jump speed: 0.42 blocks per tick lifts about a block; v ~ sqrt(height)
    xor ebx, ebx
.jump:
    cmp ebx, [rel g_mob_count]
    jae .eats
    imul eax, ebx, MOB_size
    lea rsi, [rel g_mobs]
    add rsi, rax
    movss xmm0, [rsi + MOB.jump]
    sqrtss xmm0, xmm0
    mulss xmm0, [rel c_jump_v]
    movss [rsi + MOB.jump_v], xmm0
    inc ebx
    jmp .jump
.eats:
    lea rdi, [rel g_block_eat]
    xor eax, eax
    mov ecx, 65536 / 8
    rep stosq
    xor ebx, ebx
    xor r12d, r12d                      ; lists so far
    mov dword [LOCAL(8)], 0             ; blocks some animal eats
.eat_mob:
    cmp ebx, [rel g_mob_count]
    jae .babies
    lea rax, [rel g_eat_text]
    mov rsi, [rax + rbx * 8]
    test rsi, rsi
    jz .eat_next
    cmp r12d, MAX_EAT_LISTS
    jb .eat_room
    lea rcx, [rel str_eat_full]
    imul eax, ebx, MOB_size
    lea rdx, [rel g_mobs]
    mov rdx, [rdx + rax + MOB.name]
    call warn
    jmp .eat_next
.eat_room:
    mov eax, 1
    mov ecx, r12d
    shl eax, cl
    mov [LOCAL(0)], eax
    imul ecx, ebx, MOB_size
    lea rdx, [rel g_mobs]
    mov [rdx + rcx + MOB.eats], eax
    inc r12d
    mov edi, 1                          ; every block (id 0 is air)
.eat_block:
    cmp edi, [rel g_block_count]
    jae .eat_next
    lea rax, [rel g_block_names]
    mov rdx, [rax + rdi * 8]
    test rdx, rdx
    jz .eat_skip
    mov rcx, rsi
    call items_match_list
    test eax, eax
    jz .eat_skip
    mov eax, [LOCAL(0)]
    lea rcx, [rel g_block_eat]
    or [rcx + rdi], al
    inc dword [LOCAL(8)]
.eat_skip:
    inc edi
    jmp .eat_block
.eat_next:
    inc ebx
    jmp .eat_mob
.babies:
    mov eax, [LOCAL(8)]
    LOG_VAL LOG_LEVEL_INFO, "mobs: blocks animals eat (`eats`): ", rax
    xor ebx, ebx
.baby:
    cmp ebx, [rel g_variant_count]
    jae .done
    imul eax, ebx, VARIANT_size
    lea rcx, [rel g_variants]
    mov edx, [rcx + rax + VARIANT.baby_layer]
    test edx, edx
    jz .baby_next
    dec edx
    add edx, [rel g_variant_count]
    mov [rcx + rax + VARIANT.baby_layer], edx
.baby_next:
    inc ebx
    jmp .baby
.done:
    RETURN
ENDPROC

; name_less — eax = 1 if rcx sorts before rdx (case-insensitive)
;   clobbers: rax, rcx, rdx, r8, r9
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

; collect_files — data\mobs\*.mob, sorted by name
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

; load_file — parse data\mobs\<rcx> (the text stays: names point into it)
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
    lea rdx, [rel mobs_pair]
    INVOKE cfg_parse_ex, rax, rdx, 0, rbx, CFG_SECTIONS
    RETURN
.fail:
    LOG_WARN "mobs: could not read a mob file"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mobs_load — see the header. Spawn rules without a variant are dropped.
;   out: eax = 1
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC mobs_load, 0, rbx, rsi, rdi
    xor eax, eax
    mov [rel g_part_count], eax
    mov [rel g_model_count], eax
    mov [rel g_mob_count], eax
    mov [rel g_variant_count], eax
    mov [rel g_spawn_count], eax
    mov [rel g_baby_skin_count], eax
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
    call resolve_part3b
    ; keep only the spawn rules with a variant and some biomes
    lea rsi, [rel g_spawns]
    mov rdi, rsi
    xor ebx, ebx
.spawn:
    cmp ebx, [rel g_spawn_count]
    jae .spawns_done
    cmp dword [rsi + SPAWN.variant], 0
    jl .drop
    cmp dword [rsi + SPAWN.biomes], 0
    je .drop
    cmp rsi, rdi
    je .keep
    mov ecx, SPAWN_size
.copy:
    mov al, [rsi + rcx - 1]
    mov [rdi + rcx - 1], al
    loop .copy
.keep:
    add rdi, SPAWN_size
.drop:
    add rsi, SPAWN_size
    inc ebx
    jmp .spawn
.spawns_done:
    mov rax, rdi
    lea rcx, [rel g_spawns]
    sub rax, rcx
    xor edx, edx
    mov ecx, SPAWN_size
    div ecx
    mov [rel g_spawn_count], eax
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_loaded]
    call log_append_str
    mov ecx, [rel g_mob_count]
    call log_append_dec
    lea rcx, [rel str_loaded2]
    call log_append_str
    mov ecx, [rel g_variant_count]
    call log_append_dec
    lea rcx, [rel str_loaded3]
    call log_append_str
    mov ecx, [rel g_model_count]
    call log_append_dec
    lea rcx, [rel str_loaded4]
    call log_append_str
    mov ecx, [rel g_part_count]
    call log_append_dec
    lea rcx, [rel str_loaded5]
    call log_append_str
    mov ecx, [rel g_spawn_count]
    call log_append_dec
    lea rcx, [rel str_loaded6]
    call log_append_str
    call log_end
    mov eax, 1
    RETURN
ENDPROC

section .rdata
align 4
c_skin:         dd 64.0
c_per_tick:     dd 0.05
c_one_f:        dd 1.0
c_four_f:       dd 4.0
c_jump_v:       dd 0.42                 ; jump speed for 1 block (blocks per tick)
