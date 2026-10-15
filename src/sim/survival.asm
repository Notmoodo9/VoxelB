; =============================================================================
; survival.asm — health, hunger, damage and death (milestone 20,
; design/survival/survival.md, DECISIONS D103).
;
; Only in Survival and Adventure; in Creative and Spectator nothing here
; changes (full health and hunger, no damage).
;   health and hunger in points (20 = 10 hearts / 10 food icons);
;   saturation: a hidden reserve (0 .. hunger) used up before hunger;
;   exhaustion: sprinting, swimming, jumping, mining, being hurt and
;   healing add to it; every `exhaustion_per_point` takes a saturation
;   point, or a hunger point when saturation is gone (× the difficulty's
;   hunger factor; Peaceful: none, and hunger refills);
;   natural regeneration by the difficulty (normal: fast while hunger is
;   full with saturation left, slow at 18+; fast: always; full_only;
;   none); starvation at hunger 0 down to the difficulty's floor;
;   damage: falls, drowning (air under water), lava and burning after it,
;   suffocation (head in a solid block), cactus, the void, animal rams
;   (behave.asm), starvation — × the difficulty's damage factor, with a
;   short time without new damage after a hit;
;   eating: holding the use button with food in hand (INB_USE) for the
;   item's eat time; food poisoning from some raw food (fast hunger drain);
;   death: everything in the inventory drops where the player died (5
;   minutes to pick it up); the player waits (PKT_S_SURVIVAL .flags
;   SVF_DEAD) until the client asks to respawn (PKT_C_RESPAWN): full
;   health and hunger at the world's spawn.
; Numbers: data/survival/survival.cfg; food values: the items' `food`.
;
; Public API:
;   survival_load()                     after items_load / blocks_load
;   survival_reset()                    a world starts (player.dat's values)
;   survival_tick(rcx = INPUT_PKT*, edx = buttons pressed since last tick)
;                                       after player_tick
;   survival_damage(ecx = health points, edx = CAUSE_*, r8d = mob)
;   survival_exhaust(xmm0 = f32 exhaustion), survival_mined()   (a block broken)
;   survival_respawn()                  PKT_C_RESPAWN
;   survival_spectate()                 PKT_C_SPECTATE: a dead Hardcore player
;                                       watches on as a spectator
;   survival_fill(rcx = SURV_PKT*)      the state for the client
;   g_sv_health, g_sv_hunger, g_sv_sat, g_sv_exh, g_sv_air, g_sv_burn,
;   g_sv_poison, g_sv_dead (saved in player.dat), g_sv_eating, g_sv_eat_speed
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "packet.inc"
%include "physics.inc"
%include "save.inc"
%include "block.inc"
%include "world.inc"
%include "items.inc"

global survival_load, survival_reset, survival_tick, survival_damage
global survival_exhaust, survival_respawn, survival_fill, survival_mined
global survival_spectate
global g_sv_health, g_sv_hunger, g_sv_sat, g_sv_exh, g_sv_air, g_sv_burn
global g_sv_poison, g_sv_dead, g_sv_eating, g_sv_eat_speed, g_test_block

extern str_ieq, str_parse_float, phys_block, block_find, drops_spawn_dur
extern inv_used_selected, inv_mark, player_spawn, world_spawn, edit_apply
extern timer_elapsed_us
extern g_pl_pos, g_pl_vel, g_pl_flags, g_pl_eye, g_pl_width, g_pl_height
extern g_world_mode, g_world_difficulty, g_inv, g_inv_sel
extern g_save_sv, g_save_sv_loaded, g_world_death, g_world_day
extern craft_close, graves_make, g_grave_pos, g_world_hardcore, g_world_hc_dead
extern combat_armor_hit, g_armor_hunger, g_armor_points, g_cb_safe
extern g_cb_blocking, g_roll

%define SLOT_SIZE       8
%define DIFFS           5               ; peaceful .. ultra
%define REGEN_NORMAL    0
%define REGEN_FAST      1
%define REGEN_FULL      2
%define REGEN_NONE      3
%define HALF_S          10              ; ticks: lava, suffocation, cactus, void
%define SECOND          20
%define GRAVE_WAIT      100             ; ticks a gravestone may wait for a busy column

section .rdata
str_file:       db "data/survival/survival.cfg", 0
str_label:      db "survival.cfg", 0
str_unknown:    db "unknown setting: ", 0
str_bad:        db "bad value for: ", 0
str_cactus:     db "cactus", 0
str_died:       db "survival: the player died, cause ", 0
k_difficulty:   db "difficulty", 0
k_damage:       db "damage", 0
k_hunger_d:     db "hunger", 0
k_regen:        db "regen", 0
k_regen_every:  db "regen_every", 0
k_floor:        db "starve_floor", 0
r_normal:       db "normal", 0
r_fast:         db "fast", 0
r_full:         db "full_only", 0
r_none:         db "none", 0
d_peaceful:     db "peaceful", 0
d_normal:       db "normal", 0
d_hard:         db "hard", 0
d_extreme:      db "extreme", 0
d_ultra:        db "ultra", 0
; top-level keys, in the order of the settings block below
k_0:  db "health", 0
k_1:  db "hunger", 0
k_2:  db "start_saturation", 0
k_3:  db "exhaustion_per_point", 0
k_4:  db "exhaust_sprint", 0
k_5:  db "exhaust_swim", 0
k_6:  db "exhaust_jump", 0
k_7:  db "exhaust_sprint_jump", 0
k_8:  db "exhaust_mine", 0
k_9:  db "exhaust_damage", 0
k_10: db "exhaust_heal", 0
k_11: db "regen_fast", 0
k_12: db "regen_slow", 0
k_13: db "regen_hunger", 0
k_14: db "starve_every", 0
k_15: db "eat_time", 0
k_16: db "eat_speed", 0
k_17: db "poison_time", 0
k_18: db "poison_exhaust", 0
k_19: db "fall_safe", 0
k_20: db "air", 0
k_21: db "drown_damage", 0
k_22: db "lava_damage", 0
k_23: db "burn_time", 0
k_24: db "burn_damage", 0
k_25: db "suffocate_damage", 0
k_26: db "cactus_damage", 0
k_27: db "void_y", 0
k_28: db "void_damage", 0
k_29: db "hurt_time", 0
align 8
key_table:  dq k_0, k_1, k_2, k_3, k_4, k_5, k_6, k_7, k_8, k_9, k_10, k_11
            dq k_12, k_13, k_14, k_15, k_16, k_17, k_18, k_19, k_20, k_21
            dq k_22, k_23, k_24, k_25, k_26, k_27, k_28, k_29
%define KEY_COUNT 30
diff_names: dq d_peaceful, d_normal, d_hard, d_extreme, d_ultra
regen_names: dq r_normal, r_fast, r_full, r_none
align 8
c_half_d:       dq 0.5
c_tiny:         dq 0.000001
c_probe:        dq 0.06                 ; cactus: how far around the body it pricks
c_probe_up:     dq 0.1
c_mid:          dq 1.0
align 4
c_twenty:       dd 20.0
c_half:         dd 0.5
c_one:          dd 1.0
c_zero:         dd 0.0
c_jump_vy:      dd 0.5                  ; leaving the ground faster than this: a jump

section .data
align 4
; settings (f32), same order as key_table
s_values:
s_health:       dd 20.0
s_hunger:       dd 20.0
s_start_sat:    dd 5.0
s_per_point:    dd 4.0
s_ex_sprint:    dd 0.1
s_ex_swim:      dd 0.01
s_ex_jump:      dd 0.05
s_ex_sjump:     dd 0.2
s_ex_mine:      dd 0.005
s_ex_damage:    dd 0.1
s_ex_heal:      dd 6.0
s_regen_fast:   dd 0.5
s_regen_slow:   dd 4.0
s_regen_hunger: dd 18.0
s_starve:       dd 4.0
s_eat_time:     dd 1.6
g_sv_eat_speed:
s_eat_speed:    dd 0.35
s_poison_time:  dd 30.0
s_poison_ex:    dd 0.5
s_fall_safe:    dd 3.0
s_air:          dd 15.0
s_drown:        dd 2.0
s_lava:         dd 4.0
s_burn_time:    dd 8.0
s_burn:         dd 1.0
s_suffocate:    dd 1.0
s_cactus:       dd 1.0
s_void_y:       dd -320.0
s_void:         dd 4.0
s_hurt:         dd 0.5
; by difficulty (peaceful .. ultra)
d_damage:       dd 0.5, 1.0, 1.5, 1.75, 2.0
d_hunger:       dd 0.0, 1.0, 1.25, 1.5, 1.75
d_regen:        dd REGEN_FAST, REGEN_NORMAL, REGEN_NORMAL, REGEN_FULL, REGEN_NONE
d_regen_every:  dd 1.0, 4.0, 4.0, 6.0, 4.0
d_floor:        dd 10.0, 1.0, 0.0, 0.0, 0.0

section .rdata
align 4
c_inv_2_24:     dd 0.000000059604644775390625 ; 1 / 2^24

section .bss
alignb 8
g_sv_health:    resd 1                  ; points (int)
g_sv_hunger:    resd 1
g_sv_sat:       resd 1                  ; f32
g_sv_exh:       resd 1                  ; f32
g_sv_air:       resd 1                  ; ticks of air left
g_sv_burn:      resd 1                  ; ticks still burning
g_sv_poison:    resd 1                  ; ticks of food poisoning left
g_sv_dead:      resd 1
g_sv_eating:    resd 1                  ; ticks into eating (0: not eating)
g_eat_item:     resd 1
g_section:      resd 1                  ; the cfg section: -1 top, 0..4 a difficulty, -2 unknown
g_cactus:       resd 1                  ; block id
; tick counts worked out from the settings
t_max_health:   resd 1
t_max_hunger:   resd 1
t_regen_fast:   resd 1
t_regen_slow:   resd 1
t_regen_hunger: resd 1
t_starve:       resd 1
t_eat:          resd 1
t_poison:       resd 1
t_air:          resd 1
t_burn:         resd 1
t_hurt:         resd 1
t_regen_every:  resd DIFFS
; timers
g_invuln:       resd 1                  ; ticks without new damage
g_regen_t:      resd 1
g_starve_t:     resd 1
g_drown_t:      resd 1
g_burn_t:       resd 1
g_lava_t:       resd 1
g_suff_t:       resd 1
g_cactus_t:     resd 1
g_void_t:       resd 1
g_refill_t:     resd 1
g_hurt_count:   resd 1                  ; hits taken (the client flashes on a change)
g_cause:        resd 1
g_cause_mob:    resd 1
g_sv_kept:      resd 1                  ; the last death kept the items (keep inventory)
g_sv_grave:     resd 1                  ; the last death's items are in a gravestone
g_grave_wait:   resd 1                  ; ticks left to place the gravestone
g_rng:          resd 1
g_grace:        resd 1                  ; 1: the next landing does no harm (a respawn)
g_test_block:   resb 32                 ; --test-block <name> (tests)
g_test_ticks:   resd 1
g_prev_flags:   resd 1
g_death_pos:    resd 3
alignb 8
g_fall_top:     resq 1                  ; f64 highest point of this fall
g_last_pos:     resq 3                  ; f64 the position last tick
g_spot:         resq 3
g_spawn:        resq 3                  ; respawn: the eyes
g_cfg_mark:     resq 1
g_path:         resb 512

section .text

; rand_u32 — eax = a random u32 (xorshift)   clobbers: rax, rcx
rand_u32:
    mov eax, [rel g_rng]
    test eax, eax
    jnz .go
    mov eax, 0x2545F491
.go:
    mov ecx, eax
    shl ecx, 13
    xor eax, ecx
    mov ecx, eax
    shr ecx, 17
    xor eax, ecx
    mov ecx, eax
    shl ecx, 5
    xor eax, ecx
    mov [rel g_rng], eax
    ret

; -----------------------------------------------------------------------------
; to_ticks — eax = round(xmm0 seconds * 20), at least 1   clobbers: xmm0
; -----------------------------------------------------------------------------
to_ticks:
    mulss xmm0, [rel c_twenty]
    cvtss2si eax, xmm0
    cmp eax, 1
    jge .ok
    mov eax, 1
.ok:
    ret

; -----------------------------------------------------------------------------
; survival_load — read data/survival/survival.cfg (missing: the defaults).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC survival_load, 0, rbx
    mov dword [rel g_section], -1
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [rel g_cfg_mark], rax
    lea rcx, [rel g_path]
    lea rdx, [rel str_file]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .missing
    lea rdx, [rel cfg_pair]
    lea r9, [rel str_label]
    mov qword [rsp + 32], CFG_SECTIONS
    INVOKE cfg_parse_ex, rax, rdx, 0, r9
    jmp .parsed
.missing:
    LOG_WARN "survival: data/survival/survival.cfg missing; built-in values"
.parsed:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [rel g_cfg_mark]
    ; whole numbers and ticks
    cvttss2si eax, [rel s_health]
    cmp eax, 1
    jge .h
    mov eax, 1
.h:
    mov [rel t_max_health], eax
    cvttss2si eax, [rel s_hunger]
    mov [rel t_max_hunger], eax
    cvttss2si eax, [rel s_regen_hunger]
    mov [rel t_regen_hunger], eax
    movss xmm0, [rel s_regen_fast]
    call to_ticks
    mov [rel t_regen_fast], eax
    movss xmm0, [rel s_regen_slow]
    call to_ticks
    mov [rel t_regen_slow], eax
    movss xmm0, [rel s_starve]
    call to_ticks
    mov [rel t_starve], eax
    movss xmm0, [rel s_eat_time]
    call to_ticks
    mov [rel t_eat], eax
    movss xmm0, [rel s_poison_time]
    call to_ticks
    mov [rel t_poison], eax
    movss xmm0, [rel s_air]
    call to_ticks
    mov [rel t_air], eax
    movss xmm0, [rel s_burn_time]
    call to_ticks
    mov [rel t_burn], eax
    movss xmm0, [rel s_hurt]
    call to_ticks
    mov [rel t_hurt], eax
    xor ebx, ebx
.every:
    lea rax, [rel d_regen_every]
    movss xmm0, [rax + rbx * 4]
    call to_ticks
    lea rcx, [rel t_regen_every]
    mov [rcx + rbx * 4], eax
    inc ebx
    cmp ebx, DIFFS
    jb .every
    lea rcx, [rel str_cactus]
    call block_find
    mov [rel g_cactus], eax
    mov eax, [rel t_max_health]
    LOG_VAL LOG_LEVEL_INFO, "survival: settings read; health ", rax
    RETURN
ENDPROC

; cfg callback: rcx = name (or a [section] with rdx = 0), rdx = value
PROC cfg_pair, 16, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    test rsi, rsi
    jnz .pair
    ; [difficulty <name>]
    mov dword [rel g_section], -2
    lea rdx, [rel k_difficulty]
    mov rcx, rbx
.word:
    mov al, [rcx]
    test al, al
    jz .done
    cmp al, ' '
    je .split
    inc rcx
    jmp .word
.split:
    mov byte [rcx], 0
    lea rsi, [rcx + 1]
.sp:
    cmp byte [rsi], ' '
    jne .named
    inc rsi
    jmp .sp
.named:
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .bad_section
    xor edi, edi
.d:
    lea rax, [rel diff_names]
    INVOKE str_ieq, rsi, [rax + rdi * 8]
    test eax, eax
    jnz .d_found
    inc edi
    cmp edi, DIFFS
    jb .d
.bad_section:
    lea rcx, [rel str_unknown]
    mov rdx, rbx
    call warn
    RETURN
.d_found:
    mov [rel g_section], edi
    RETURN
.pair:
    cmp dword [rel g_section], -2
    je .done                            ; (inside an unknown section)
    cmp dword [rel g_section], -1
    jne .diff_key
    xor edi, edi
.key:
    lea rax, [rel key_table]
    INVOKE str_ieq, rbx, [rax + rdi * 8]
    test eax, eax
    jnz .key_found
    inc edi
    cmp edi, KEY_COUNT
    jb .key
    jmp .unknown
.key_found:
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    lea rax, [rel s_values]
    movss [rax + rdi * 4], xmm0
    RETURN
.diff_key:
    mov edi, [rel g_section]
    lea rdx, [rel k_damage]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_damage
    lea rax, [rel d_damage]
    jmp .diff_float
.not_damage:
    lea rdx, [rel k_hunger_d]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_hunger
    lea rax, [rel d_hunger]
    jmp .diff_float
.not_hunger:
    lea rdx, [rel k_regen_every]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_every
    lea rax, [rel d_regen_every]
    jmp .diff_float
.not_every:
    lea rdx, [rel k_floor]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_floor
    lea rax, [rel d_floor]
    jmp .diff_float
.not_floor:
    lea rdx, [rel k_regen]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    xor ecx, ecx
.r:
    mov [LOCAL(8)], rcx
    lea rax, [rel regen_names]
    lea rax, [rax + rcx * 8]
    INVOKE str_ieq, rsi, [rax]
    mov rcx, [LOCAL(8)]
    test eax, eax
    jnz .r_found
    inc ecx
    cmp ecx, 4
    jb .r
    jmp .bad
.r_found:
    lea rax, [rel d_regen]
    mov [rax + rdi * 4], ecx
    RETURN
.diff_float:
    mov [LOCAL(0)], rax
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    mov rax, [LOCAL(0)]
    movss [rax + rdi * 4], xmm0
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

; warn — "survival.cfg: <rcx><rdx>"   clobbers: volatile
warn:
    mov r8, rdx
    mov rdx, rcx
    lea rcx, [rel str_label]
    jmp cfg_warn

; -----------------------------------------------------------------------------
; survival_reset — a world starts: player.dat's survival line, or full.
;   in:  rcx = the eye position the player starts at (respawn point when
;        the world has no generated spawn)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC survival_reset, 0, rbx
    mov rbx, rcx
    call timer_elapsed_us               ; (random rolls differ from run to run)
    or eax, 1
    mov [rel g_rng], eax
    mov rcx, rbx
    mov rax, [rcx]
    mov [rel g_spawn], rax
    mov rax, [rcx + 8]
    mov [rel g_spawn + 8], rax
    mov rax, [rcx + 16]
    mov [rel g_spawn + 16], rax
    call full
    cmp dword [rel g_save_sv_loaded], 0
    je .fresh
    ; health, hunger, saturation, exhaustion, air, burn, poison, dead
    lea rcx, [rel g_save_sv]
    cvttss2si eax, [rcx]
    cmp eax, 1
    jge .h
    mov eax, 1
.h:
    cmp eax, [rel t_max_health]
    jle .h2
    mov eax, [rel t_max_health]
.h2:
    mov [rel g_sv_health], eax
    cvttss2si eax, [rcx + 4]
    mov edx, [rel t_max_hunger]
    cmp eax, edx
    cmovg eax, edx
    xor edx, edx
    cmp eax, edx
    cmovl eax, edx
    mov [rel g_sv_hunger], eax
    mov eax, [rcx + 8]
    mov [rel g_sv_sat], eax
    mov eax, [rcx + 12]
    mov [rel g_sv_exh], eax
    cvttss2si eax, [rcx + 16]
    mov [rel g_sv_air], eax
    cvttss2si eax, [rcx + 20]
    mov [rel g_sv_burn], eax
    cvttss2si eax, [rcx + 24]
    mov [rel g_sv_poison], eax
    cvttss2si eax, [rcx + 28]
    mov [rel g_sv_dead], eax
.fresh:
    mov rax, [rel g_pl_pos + 8]
    mov [rel g_fall_top], rax
    mov rax, [rel g_pl_pos]
    mov [rel g_last_pos], rax
    mov rax, [rel g_pl_pos + 8]
    mov [rel g_last_pos + 8], rax
    mov rax, [rel g_pl_pos + 16]
    mov [rel g_last_pos + 16], rax
    RETURN
ENDPROC

; full — full health and hunger, nothing burning or poisoning
;   clobbers: rax, xmm0
full:
    mov eax, [rel t_max_health]
    mov [rel g_sv_health], eax
    mov eax, [rel t_max_hunger]
    mov [rel g_sv_hunger], eax
    mov eax, [rel s_start_sat]
    mov [rel g_sv_sat], eax
    xor eax, eax
    mov [rel g_sv_exh], eax
    mov [rel g_sv_burn], eax
    mov [rel g_sv_poison], eax
    mov [rel g_sv_dead], eax
    mov [rel g_sv_eating], eax
    mov [rel g_invuln], eax
    mov [rel g_regen_t], eax
    mov [rel g_starve_t], eax
    mov [rel g_drown_t], eax
    mov [rel g_burn_t], eax
    mov eax, [rel t_air]
    mov [rel g_sv_air], eax
    ret

; active — eax = 1 in Survival or Adventure   clobbers: rax
active:
    mov eax, [rel g_world_mode]
    cmp eax, MODE_SURVIVAL
    je .yes
    cmp eax, MODE_ADVENTURE
    je .yes
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; diff — eax = the difficulty (0..4)   clobbers: rax
diff:
    mov eax, [rel g_world_difficulty]
    cmp eax, DIFFS
    jb .ok
    mov eax, DIFF_NORMAL
.ok:
    ret

; -----------------------------------------------------------------------------
; survival_exhaust — add exhaustion (× the difficulty's hunger factor).
;   in:  xmm0 = f32   clobbers: rax, xmm0
; -----------------------------------------------------------------------------
survival_exhaust:
    call diff
    lea rcx, [rel d_hunger]
    mulss xmm0, [rcx + rax * 4]
    addss xmm0, [rel g_sv_exh]
    movss [rel g_sv_exh], xmm0
    ret

; move_exhaust — exhaustion from moving: × the armor's hunger factor
;   (heavy armor), then survival_exhaust.   clobbers: rax, xmm0
move_exhaust:
    mulss xmm0, [rel g_armor_hunger]
    jmp survival_exhaust

; survival_mined — a block was broken by hand or tool: its exhaustion
;   clobbers: rax, rcx, xmm0
survival_mined:
    movss xmm0, [rel s_ex_mine]
    jmp survival_exhaust

; -----------------------------------------------------------------------------
; survival_damage — the player is hurt.
;   in:  ecx = health points, edx = CAUSE_*, r8d = the mob (CAUSE_RAM)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC survival_damage, 0, rbx
    call active
    test eax, eax
    jz .done
    cmp dword [rel g_sv_dead], 0
    jne .done
    test ecx, ecx
    jle .done
    cmp edx, CAUSE_VOID
    je .hit                             ; (the void always hurts)
    cmp edx, CAUSE_STARVE
    je .hit
    cmp dword [rel g_invuln], 0
    jne .done
    cmp dword [rel g_cb_safe], 0
    jne .done                           ; (a dodge roll's first moment)
.hit:
    mov [rel g_cause], edx
    mov [rel g_cause_mob], r8d
    ; × the difficulty, at least 1
    cvtsi2ss xmm0, ecx
    call diff
    lea rdx, [rel d_damage]
    mulss xmm0, [rdx + rax * 4]
    ; armor takes its share of rams, burns and cactus pricks (and wears)
    mov eax, [rel g_cause]
    cmp eax, CAUSE_RAM
    je .armored
    cmp eax, CAUSE_LAVA
    je .armored
    cmp eax, CAUSE_FIRE
    je .armored
    cmp eax, CAUSE_CACTUS
    jne .round
.armored:
    ; (what gets through, rounded by chance: armor softens small hits too)
    call combat_armor_hit
    cvttss2si ebx, xmm0
    cvtsi2ss xmm1, ebx
    subss xmm0, xmm1                    ; the fraction
    call rand_u32
    shr eax, 8
    cvtsi2ss xmm1, eax
    mulss xmm1, [rel c_inv_2_24]
    comiss xmm1, xmm0
    jae .armor_rounded
    inc ebx
.armor_rounded:
    test ebx, ebx
    jz .done                            ; (all of it stopped)
    jmp .amount
.round:
    addss xmm0, [rel c_half]
    cvttss2si ebx, xmm0
    cmp ebx, 1
    jge .amount
    mov ebx, 1
.amount:
    mov eax, [rel t_hurt]
    mov [rel g_invuln], eax
    inc dword [rel g_hurt_count]
    sub [rel g_sv_health], ebx
    movss xmm0, [rel s_ex_damage]
    call survival_exhaust
    cmp dword [rel g_sv_health], 0
    jg .done
    mov dword [rel g_sv_health], 0
    call die
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; die — the player died: by the world's death rule (world.dat death) what
; they carry drops where they are, goes into a gravestone (graves.asm), or
; stays with them.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC die, 0, rbx
    mov dword [rel g_sv_dead], 1
    mov dword [rel g_sv_eating], 0
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_died]
    call log_append_str
    mov ecx, [rel g_cause]
    call log_append_dec
    call log_end
    ; where
    xor ebx, ebx
.pos:
    lea rax, [rel g_pl_pos]
    movsd xmm0, [rax + rbx * 8]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    lea rcx, [rel g_death_pos]
    mov [rcx + rbx * 4], eax
    inc ebx
    cmp ebx, 3
    jb .pos
    mov dword [rel g_sv_kept], 0
    mov dword [rel g_sv_grave], 0
    ; Hardcore: one life; the world ends (spectate or delete it)
    cmp dword [rel g_world_hardcore], 0
    je .one_of_many
    mov dword [rel g_world_hc_dead], 1
.one_of_many:
    ; an open window closes first: its grid and carried stack back into the
    ; slots, a chest's slots back into the chest
    call craft_close
    ; the world's death rule (keep inventory only below Hard: a gravestone
    ; there instead)
    mov eax, [rel g_world_death]
    cmp eax, DEATH_KEEP
    jne .rule
    cmp dword [rel g_world_difficulty], DIFF_HARD
    jb .rule
    mov eax, DEATH_GRAVE
.rule:
    cmp eax, DEATH_KEEP
    jne .not_keep
    mov dword [rel g_sv_kept], 1
    RETURN
.not_keep:
    cmp eax, DEATH_GRAVE
    jne .drop
    call graves_make
    cmp eax, 1
    je .in_grave
    cmp eax, 2
    jne .drop                           ; (no room for a stone: they drop)
    ; the column is busy: try again each tick (survival_tick), for a while
    mov dword [rel g_grave_wait], GRAVE_WAIT
    RETURN
.in_grave:
    mov dword [rel g_sv_grave], 1
    RETURN
.drop:
    call drop_all
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; drop_all — everything the player carries drops where they are.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC drop_all, 0, rbx, rsi
    ; the items: the slots, the carried stack, the grid, the off hand
    mov rax, [rel g_pl_pos]
    mov [rel g_spot], rax
    movsd xmm0, [rel g_pl_pos + 8]
    addsd xmm0, [rel c_mid]
    movsd [rel g_spot + 8], xmm0
    mov rax, [rel g_pl_pos + 16]
    mov [rel g_spot + 16], rax
    xor esi, esi
.slot:
    cmp esi, INV_ALL
    jae .dropped
    lea rax, [rel g_inv]
    lea rbx, [rax + rsi * SLOT_SIZE]
    movzx ecx, word [rbx]
    test ecx, ecx
    jz .next
    movzx edx, word [rbx + 2]
    lea r8, [rel g_spot]
    movzx r9d, word [rbx + 4]
    call drops_spawn_dur
    mov qword [rbx], 0
    mov ecx, esi
    call inv_mark
.next:
    inc esi
    jmp .slot
.dropped:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; survival_respawn — PKT_C_RESPAWN: a dead player comes back at the spawn.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC survival_respawn, 0
    cmp dword [rel g_sv_dead], 0
    je .done
    cmp dword [rel g_world_hc_dead], 0
    jne .done                           ; (Hardcore: no coming back)
    cmp dword [rel g_grave_wait], 0
    je .no_wait
    mov dword [rel g_grave_wait], 0     ; (still no stone: the items drop)
    call drop_all
.no_wait:
    call full
    lea rcx, [rel g_spot]
    call world_spawn
    test eax, eax
    jnz .placed
    mov rax, [rel g_spawn]
    mov [rel g_spot], rax
    mov rax, [rel g_spawn + 8]
    mov [rel g_spot + 8], rax
    mov rax, [rel g_spawn + 16]
    mov [rel g_spot + 16], rax
.placed:
    lea rcx, [rel g_spot]
    xor edx, edx
    call player_spawn
    mov rax, [rel g_pl_pos + 8]
    mov [rel g_fall_top], rax
    mov dword [rel g_grace], 1          ; (the spawn point may be above the ground)
    LOG_INFO "survival: the player respawned"
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; survival_fill — the state as a SURV_PKT.
;   in:  rcx = SURV_PKT*   clobbers: rax, rdx, xmm0
; -----------------------------------------------------------------------------
survival_fill:
    mov eax, [rel g_sv_health]
    mov [rcx + SURV_PKT.health], ax
    mov eax, [rel g_sv_hunger]
    mov [rcx + SURV_PKT.hunger], ax
    mov eax, [rel g_sv_sat]
    mov [rcx + SURV_PKT.sat], eax
    mov eax, [rel g_sv_air]
    mov [rcx + SURV_PKT.air], ax
    mov eax, [rel t_air]
    mov [rcx + SURV_PKT.air_max], ax
    xor edx, edx
    cmp dword [rel g_sv_poison], 0
    je .f1
    or edx, SVF_POISON
.f1:
    cmp dword [rel g_sv_burn], 0
    je .f2
    or edx, SVF_BURNING
.f2:
    cmp dword [rel g_sv_dead], 0
    je .f3
    or edx, SVF_DEAD
.f3:
    push rax
    call active
    test eax, eax
    pop rax
    jz .f4
    or edx, SVF_ACTIVE
.f4:
    cmp dword [rel g_cb_blocking], 0
    je .fblk
    or edx, SVF_BLOCKING
.fblk:
    cmp dword [rel g_roll], 0
    je .froll
    or edx, SVF_ROLLING
.froll:
    mov [rcx + SURV_PKT.flags], dx
    mov eax, [rel g_hurt_count]
    mov [rcx + SURV_PKT.hurt], ax
    mov eax, [rel g_cause]
    mov [rcx + SURV_PKT.cause], ax
    mov eax, [rel g_cause_mob]
    mov [rcx + SURV_PKT.cause_mob], ax
    mov eax, [rel g_sv_eating]
    mov [rcx + SURV_PKT.eat], ax
    mov eax, [rel t_eat]
    mov edx, [rel g_eat_item]
    test edx, edx
    jz .eat_total
    push rcx
    lea rcx, [rel g_item_eat]
    movzx edx, byte [rcx + rdx]
    pop rcx
    test edx, edx
    cmovnz eax, edx
.eat_total:
    mov [rcx + SURV_PKT.eat_total], ax
    mov eax, [rel g_death_pos]
    mov [rcx + SURV_PKT.death], eax
    mov eax, [rel g_death_pos + 4]
    mov [rcx + SURV_PKT.death + 4], eax
    mov eax, [rel g_death_pos + 8]
    mov [rcx + SURV_PKT.death + 8], eax
    mov eax, [rel g_world_day]
    mov [rcx + SURV_PKT.day], eax
    movss xmm0, [rel g_armor_points]
    addss xmm0, xmm0
    cvtss2si eax, xmm0
    mov [rcx + SURV_PKT.armor], ax
    mov eax, [rel g_grave_pos]
    mov [rcx + SURV_PKT.grave], eax
    mov eax, [rel g_grave_pos + 4]
    mov [rcx + SURV_PKT.grave + 4], eax
    mov eax, [rel g_grave_pos + 8]
    mov [rcx + SURV_PKT.grave + 8], eax
    movzx eax, word [rcx + SURV_PKT.flags]
    cmp dword [rel g_sv_grave], 0
    je .f5
    or eax, SVF_GRAVE
.f5:
    cmp dword [rel g_sv_kept], 0
    je .f6
    or eax, SVF_KEPT
.f6:
    cmp dword [rel g_grave_wait], 0
    je .f7
    or eax, SVF_KEPT | SVF_GRAVE        ; (both: the stone is still to come)
.f7:
    cmp dword [rel g_world_hc_dead], 0
    je .f8
    or eax, SVF_SPECTATE
.f8:
    mov [rcx + SURV_PKT.flags], ax
    ret

; -----------------------------------------------------------------------------
; every — eax = 1 once every ecx ticks of timer [rdx] (counting up)
;   clobbers: rax
; -----------------------------------------------------------------------------
every:
    inc dword [rdx]
    mov eax, [rdx]
    cmp eax, ecx
    jb .no
    mov dword [rdx], 0
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; block_here — eax = block id at the point (xmm0, xmm1, xmm2 doubles), -1
;   clobbers: volatile
block_here:
    roundsd xmm0, xmm0, 9
    cvttsd2si ecx, xmm0
    roundsd xmm1, xmm1, 9
    cvttsd2si edx, xmm1
    roundsd xmm2, xmm2, 9
    cvttsd2si r8d, xmm2
    jmp phys_block

; -----------------------------------------------------------------------------
; test_block — --test-block <name>: 3 s into the world the block fills the
; cells from under the player's feet up to the eyes (tests: water for
; drowning, lava, stone for suffocation, cactus).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define TB_X    0
%define TB_Y    4
%define TB_Z    8
PROC test_block, 16, rbx, rsi
    cmp byte [rel g_test_block], 0
    je .done
    inc dword [rel g_test_ticks]
    cmp dword [rel g_test_ticks], 60
    jb .done
    cmp dword [rel g_test_ticks], 160
    ja .done                            ; (tries for 5 s: a busy column refuses edits)
    lea rcx, [rel g_test_block]
    call block_find
    cmp eax, 0
    jle .done
    mov ebx, eax
    mov esi, -1                         ; under the feet, the feet, the head
.cell:
    movsd xmm0, [rel g_pl_pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [LOCAL(TB_X)], eax
    movsd xmm0, [rel g_pl_pos + 8]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    add eax, esi
    mov [LOCAL(TB_Y)], eax
    movsd xmm0, [rel g_pl_pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [LOCAL(TB_Z)], eax
    mov ecx, [LOCAL(TB_X)]
    mov edx, [LOCAL(TB_Y)]
    mov r8d, [LOCAL(TB_Z)]
    call phys_block
    cmp eax, ebx
    je .next                            ; (there already)
    mov ecx, [LOCAL(TB_X)]
    mov edx, [LOCAL(TB_Y)]
    mov r8d, [LOCAL(TB_Z)]
    mov r9d, ebx
    call edit_apply
.next:
    inc esi
    ; up to the cell of the eyes
    cvtss2sd xmm0, [rel g_pl_eye]
    addsd xmm0, [rel g_pl_pos + 8]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    movsd xmm0, [rel g_pl_pos + 8]
    roundsd xmm0, xmm0, 9
    cvttsd2si ecx, xmm0
    sub eax, ecx
    cmp esi, eax
    jle .cell
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; survival_tick — see the header.
;   in:  rcx = INPUT_PKT*, edx = buttons pressed since the last tick
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define S_IN    0
%define S_FLAGS 8
%define S_DIST  16                      ; f64 moved this tick (flat)
%define S_I     24
PROC survival_tick, 32, rbx, rsi, rdi
    mov [LOCAL(S_IN)], rcx
    call test_block
    ; a gravestone that could not be placed at once (a busy column)
    cmp dword [rel g_grave_wait], 0
    je .no_wait
    call grave_retry
.no_wait:
    call active
    test eax, eax
    jz .inactive
    cmp dword [rel g_sv_dead], 0
    jne .done
    mov eax, [rel g_pl_flags]
    mov [LOCAL(S_FLAGS)], eax
    test eax, PF_FROZEN
    jnz .remember
    cmp dword [rel g_invuln], 0
    je .moved
    dec dword [rel g_invuln]
.moved:
    ; ---- exhaustion from moving: sprinting, swimming, jumping ----
    movsd xmm0, [rel g_pl_pos]
    subsd xmm0, [rel g_last_pos]
    mulsd xmm0, xmm0
    movsd xmm1, [rel g_pl_pos + 16]
    subsd xmm1, [rel g_last_pos + 16]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    sqrtsd xmm0, xmm0
    movsd [LOCAL(S_DIST)], xmm0
    mov eax, [LOCAL(S_FLAGS)]
    test eax, PF_FLYING | PF_NOCLIP
    jnz .falls
    test eax, PF_IN_WATER
    jz .not_swim
    cvtsd2ss xmm0, [LOCAL(S_DIST)]
    mulss xmm0, [rel s_ex_swim]
    call move_exhaust
    jmp .jumps
.not_swim:
    test eax, PF_SPRINTING
    jz .jumps
    cvtsd2ss xmm0, [LOCAL(S_DIST)]
    mulss xmm0, [rel s_ex_sprint]
    call move_exhaust
.jumps:
    ; left the ground going up: a jump
    test dword [rel g_prev_flags], PF_ON_GROUND
    jz .falls
    mov eax, [LOCAL(S_FLAGS)]
    test eax, PF_ON_GROUND | PF_IN_WATER | PF_CLIMBING
    jnz .falls
    cvtsd2ss xmm0, [rel g_pl_vel + 8]
    comiss xmm0, [rel c_jump_vy]
    jbe .falls
    movss xmm0, [rel s_ex_jump]
    test dword [LOCAL(S_FLAGS)], PF_SPRINTING
    jz .jump_ex
    movss xmm0, [rel s_ex_sjump]
.jump_ex:
    call move_exhaust

.falls:
    ; ---- falls: from the highest point since the ground ----
    mov eax, [LOCAL(S_FLAGS)]
    test eax, PF_FLYING | PF_NOCLIP | PF_IN_WATER | PF_CLIMBING
    jnz .fall_reset
    test eax, PF_ON_GROUND
    jnz .landed
    movsd xmm0, [rel g_pl_pos + 8]
    maxsd xmm0, [rel g_fall_top]
    movsd [rel g_fall_top], xmm0
    jmp .air_check
.landed:
    cmp dword [rel g_grace], 0
    je .fall_hurts
    mov dword [rel g_grace], 0          ; (dropped in at the spawn: no harm)
    jmp .fall_reset
.fall_hurts:
    movsd xmm0, [rel g_fall_top]
    subsd xmm0, [rel g_pl_pos + 8]
    cvtss2sd xmm1, [rel s_fall_safe]
    subsd xmm0, xmm1
    addsd xmm0, [rel c_half_d]          ; (a half block counts: round)
    cvttsd2si ecx, xmm0
    test ecx, ecx
    jle .fall_reset
    mov edx, CAUSE_FALL
    xor r8d, r8d
    call survival_damage
.fall_reset:
    mov rax, [rel g_pl_pos + 8]
    mov [rel g_fall_top], rax

.air_check:
    ; ---- the head: under water (air), in a solid block (suffocation) ----
    movsd xmm0, [rel g_pl_pos]
    cvtss2sd xmm1, [rel g_pl_eye]
    addsd xmm1, [rel g_pl_pos + 8]
    movsd xmm2, [rel g_pl_pos + 16]
    call block_here
    mov ebx, eax
    cmp eax, -1
    je .breathing
    lea rcx, [rel g_block_move]
    test byte [rcx + rbx], MOVE_WATER
    jz .breathing
    cmp dword [rel g_sv_air], 0
    jle .drowning
    dec dword [rel g_sv_air]
    jmp .solid
.drowning:
    mov ecx, SECOND
    lea rdx, [rel g_drown_t]
    call every
    test eax, eax
    jz .solid
    cvttss2si ecx, [rel s_drown]
    mov edx, CAUSE_DROWN
    xor r8d, r8d
    call survival_damage
    jmp .solid
.breathing:
    mov dword [rel g_drown_t], 0
    mov eax, [rel g_sv_air]
    add eax, 5                          ; (air comes back fast)
    cmp eax, [rel t_air]
    jle .air_set
    mov eax, [rel t_air]
.air_set:
    mov [rel g_sv_air], eax
.solid:
    cmp ebx, -1
    je .lava
    test dword [LOCAL(S_FLAGS)], PF_NOCLIP | PF_FLYING
    jnz .lava
    lea rcx, [rel g_block_coll]
    cmp byte [rcx + rbx], 0
    je .no_suff
    lea rcx, [rel g_block_shape]
    cmp byte [rcx + rbx], SHAPE_CUBE
    jne .no_suff
    lea rcx, [rel g_block_layer]
    cmp byte [rcx + rbx], LAYER_OPAQUE
    jne .no_suff
    mov ecx, HALF_S
    lea rdx, [rel g_suff_t]
    call every
    test eax, eax
    jz .lava
    cvttss2si ecx, [rel s_suffocate]
    mov edx, CAUSE_SUFFOCATE
    xor r8d, r8d
    call survival_damage
    jmp .lava
.no_suff:
    mov dword [rel g_suff_t], 0

.lava:
    ; ---- lava, then burning; water puts it out ----
    test dword [LOCAL(S_FLAGS)], PF_IN_LAVA
    jz .no_lava
    mov eax, [rel t_burn]
    mov [rel g_sv_burn], eax
    mov ecx, HALF_S
    lea rdx, [rel g_lava_t]
    call every
    test eax, eax
    jz .cactus
    cvttss2si ecx, [rel s_lava]
    mov edx, CAUSE_LAVA
    xor r8d, r8d
    call survival_damage
    jmp .cactus
.no_lava:
    mov dword [rel g_lava_t], HALF_S - 1    ; (lava hurts at once)
    cmp dword [rel g_sv_burn], 0
    je .cactus
    test dword [LOCAL(S_FLAGS)], PF_IN_WATER
    jz .burning
    mov dword [rel g_sv_burn], 0
    jmp .cactus
.burning:
    dec dword [rel g_sv_burn]
    mov ecx, SECOND
    lea rdx, [rel g_burn_t]
    call every
    test eax, eax
    jz .cactus
    cvttss2si ecx, [rel s_burn]
    mov edx, CAUSE_FIRE
    xor r8d, r8d
    call survival_damage

.cactus:
    ; ---- cactus beside or under the body ----
    cmp dword [rel g_cactus], 0
    jle .void
    xor esi, esi
.probe:
    ; 0-3: the four sides at knee height, 4: under the feet
    movsd xmm0, [rel g_pl_pos]
    movsd xmm1, [rel g_pl_pos + 8]
    addsd xmm1, [rel c_probe_up]
    movsd xmm2, [rel g_pl_pos + 16]
    cvtss2sd xmm3, [rel g_pl_width]
    mulsd xmm3, [rel c_half_d]
    addsd xmm3, [rel c_probe]
    cmp esi, 0
    jne .p1
    addsd xmm0, xmm3
    jmp .probe_at
.p1:
    cmp esi, 1
    jne .p2
    subsd xmm0, xmm3
    jmp .probe_at
.p2:
    cmp esi, 2
    jne .p3
    addsd xmm2, xmm3
    jmp .probe_at
.p3:
    cmp esi, 3
    jne .p4
    subsd xmm2, xmm3
    jmp .probe_at
.p4:
    movsd xmm1, [rel g_pl_pos + 8]
    subsd xmm1, [rel c_probe]
.probe_at:
    call block_here
    cmp eax, [rel g_cactus]
    je .pricked
    inc esi
    cmp esi, 5
    jb .probe
    mov dword [rel g_cactus_t], HALF_S - 1
    jmp .void
.pricked:
    mov ecx, HALF_S
    lea rdx, [rel g_cactus_t]
    call every
    test eax, eax
    jz .void
    cvttss2si ecx, [rel s_cactus]
    mov edx, CAUSE_CACTUS
    xor r8d, r8d
    call survival_damage

.void:
    ; ---- below the world ----
    cvtss2sd xmm0, [rel s_void_y]
    comisd xmm0, [rel g_pl_pos + 8]
    jbe .poison
    mov ecx, HALF_S
    lea rdx, [rel g_void_t]
    call every
    test eax, eax
    jz .poison
    cvttss2si ecx, [rel s_void]
    mov edx, CAUSE_VOID
    xor r8d, r8d
    call survival_damage

.poison:
    cmp dword [rel g_sv_dead], 0
    jne .remember
    cmp dword [rel g_sv_poison], 0
    je .eat
    dec dword [rel g_sv_poison]
    movss xmm0, [rel s_poison_ex]
    divss xmm0, [rel c_twenty]
    call survival_exhaust

.eat:
    ; ---- eating: the use button held with food in hand ----
    mov rcx, [LOCAL(S_IN)]
    test dword [rcx + INPUT_PKT.buttons], INB_USE
    jz .not_eating
    mov eax, [rel g_inv_sel]
    lea rcx, [rel g_inv]
    movzx ebx, word [rcx + rax * SLOT_SIZE]
    test ebx, ebx
    jz .not_eating
    lea rcx, [rel g_item_food]
    cmp byte [rcx + rbx], 0
    je .not_eating
    lea rcx, [rel g_item_eatf]
    test byte [rcx + rbx], EATF_ALWAYS
    jnz .can_eat
    mov eax, [rel g_sv_hunger]
    cmp eax, [rel t_max_hunger]
    jge .not_eating
.can_eat:
    cmp ebx, [rel g_eat_item]
    je .chew
    mov [rel g_eat_item], ebx           ; (another food: start over)
    mov dword [rel g_sv_eating], 0
.chew:
    inc dword [rel g_sv_eating]
    mov eax, [rel t_eat]
    lea rcx, [rel g_item_eat]
    movzx ecx, byte [rcx + rbx]
    test ecx, ecx
    cmovnz eax, ecx
    cmp [rel g_sv_eating], eax
    jb .exhaustion
    ; eaten: hunger and saturation (saturation never above hunger)
    mov dword [rel g_sv_eating], 0
    lea rcx, [rel g_item_food]
    movzx eax, byte [rcx + rbx]
    add eax, [rel g_sv_hunger]
    cmp eax, [rel t_max_hunger]
    jle .hunger_set
    mov eax, [rel t_max_hunger]
.hunger_set:
    mov [rel g_sv_hunger], eax
    lea rcx, [rel g_item_sat]
    movss xmm0, [rcx + rbx * 4]
    addss xmm0, [rel g_sv_sat]
    cvtsi2ss xmm1, eax
    minss xmm0, xmm1
    movss [rel g_sv_sat], xmm0
    lea rcx, [rel g_item_eatf]
    test byte [rcx + rbx], EATF_CURE
    jz .no_cure
    mov dword [rel g_sv_poison], 0
.no_cure:
    lea rcx, [rel g_item_poison]
    movzx edi, byte [rcx + rbx]
    test edi, edi
    jz .swallow
    call rand_u32
    xor edx, edx
    mov ecx, 100
    div ecx
    cmp edx, edi
    jae .swallow
    mov eax, [rel t_poison]
    mov [rel g_sv_poison], eax
    LOG_DEBUG "survival: food poisoning"
.swallow:
    LOG_DEBUG "survival: the player ate"
    call inv_used_selected
    jmp .exhaustion
.not_eating:
    mov dword [rel g_sv_eating], 0
    mov dword [rel g_eat_item], 0

.exhaustion:
    ; ---- exhaustion takes saturation, then hunger ----
    movss xmm0, [rel g_sv_exh]
    comiss xmm0, [rel s_per_point]
    jb .peaceful
    subss xmm0, [rel s_per_point]
    movss [rel g_sv_exh], xmm0
    movss xmm0, [rel g_sv_sat]
    comiss xmm0, [rel c_zero]
    jbe .take_hunger
    subss xmm0, [rel c_one]
    maxss xmm0, [rel c_zero]
    movss [rel g_sv_sat], xmm0
    jmp .exhaustion
.take_hunger:
    cmp dword [rel g_sv_hunger], 0
    je .exhaustion
    dec dword [rel g_sv_hunger]
    jmp .exhaustion
.peaceful:
    ; no hunger drain (Peaceful): hunger fills back up
    call diff
    lea rcx, [rel d_hunger]
    movss xmm0, [rcx + rax * 4]
    comiss xmm0, [rel c_zero]
    ja .regen
    mov ecx, SECOND
    lea rdx, [rel g_refill_t]
    call every
    test eax, eax
    jz .regen
    mov eax, [rel g_sv_hunger]
    cmp eax, [rel t_max_hunger]
    jge .regen
    inc dword [rel g_sv_hunger]

.regen:
    ; ---- natural regeneration ----
    mov eax, [rel g_sv_health]
    cmp eax, [rel t_max_health]
    jge .no_regen
    call diff
    mov edi, eax
    lea rcx, [rel d_regen]
    mov eax, [rcx + rdi * 4]
    cmp eax, REGEN_NONE
    je .no_regen
    cmp eax, REGEN_FAST
    je .regen_fast_kind
    cmp eax, REGEN_FULL
    je .regen_full_kind
    ; normal: fast with full hunger and saturation, slow from 18
    mov eax, [rel g_sv_hunger]
    cmp eax, [rel t_max_hunger]
    jl .regen_slow_kind
    movss xmm0, [rel g_sv_sat]
    comiss xmm0, [rel c_zero]
    jbe .regen_slow_kind
    mov ecx, [rel t_regen_fast]
    jmp .regen_tick
.regen_slow_kind:
    mov eax, [rel g_sv_hunger]
    cmp eax, [rel t_regen_hunger]
    jl .no_regen
    mov ecx, [rel t_regen_slow]
    jmp .regen_tick
.regen_full_kind:
    mov eax, [rel g_sv_hunger]
    cmp eax, [rel t_max_hunger]
    jl .no_regen
    lea rcx, [rel t_regen_every]
    mov ecx, [rcx + rdi * 4]
.regen_tick:
    lea rdx, [rel g_regen_t]
    call every
    test eax, eax
    jz .starve
    inc dword [rel g_sv_health]
    movss xmm0, [rel s_ex_heal]
    call survival_exhaust
    jmp .starve
.regen_fast_kind:
    lea rcx, [rel t_regen_every]
    mov ecx, [rcx + rdi * 4]
    lea rdx, [rel g_regen_t]
    call every
    test eax, eax
    jz .starve
    inc dword [rel g_sv_health]
    jmp .starve
.no_regen:
    mov dword [rel g_regen_t], 0

.starve:
    ; ---- starvation, down to the difficulty's floor ----
    cmp dword [rel g_sv_hunger], 0
    jne .fed
    mov ecx, [rel t_starve]
    lea rdx, [rel g_starve_t]
    call every
    test eax, eax
    jz .remember
    call diff
    lea rcx, [rel d_floor]
    cvttss2si eax, [rcx + rax * 4]
    cmp [rel g_sv_health], eax
    jle .remember
    mov ecx, 1
    mov edx, CAUSE_STARVE
    xor r8d, r8d
    call survival_damage
    jmp .remember
.fed:
    mov dword [rel g_starve_t], 0

.remember:
    mov eax, [rel g_pl_flags]
    mov [rel g_prev_flags], eax
    mov rax, [rel g_pl_pos]
    mov [rel g_last_pos], rax
    mov rax, [rel g_pl_pos + 8]
    mov [rel g_last_pos + 8], rax
    mov rax, [rel g_pl_pos + 16]
    mov [rel g_last_pos + 16], rax
.done:
    RETURN
.inactive:
    ; Creative / Spectator: always full, nothing burning
    call full
    mov rax, [rel g_pl_pos + 8]
    mov [rel g_fall_top], rax
    jmp .remember
ENDPROC

; -----------------------------------------------------------------------------
; grave_retry — another try at the gravestone; when the time is up the items
; drop instead.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC grave_retry, 0
    call graves_make
    cmp eax, 1
    je .placed
    dec dword [rel g_grave_wait]
    jz .give_up
    cmp eax, 2
    je .done
.give_up:
    mov dword [rel g_grave_wait], 0
    call drop_all
    RETURN
.placed:
    mov dword [rel g_grave_wait], 0
    mov dword [rel g_sv_grave], 1
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; survival_spectate — PKT_C_SPECTATE: a Hardcore world's player died; they
; stay as a spectator (flying through everything, touching nothing) where
; they died. The world stays that way (world.dat game_mode = spectator,
; hardcore_dead = 1).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC survival_spectate, 0
    cmp dword [rel g_sv_dead], 0
    je .done
    cmp dword [rel g_world_hc_dead], 0
    je .done
    mov dword [rel g_world_mode], MODE_SPECTATOR
    mov dword [rel g_grave_wait], 0
    call full
    ; the eyes a little above where they fell
    mov rax, [rel g_pl_pos]
    mov [rel g_spot], rax
    cvtss2sd xmm0, [rel g_pl_eye]
    addsd xmm0, [rel g_pl_pos + 8]
    addsd xmm0, [rel c_mid]
    movsd [rel g_spot + 8], xmm0
    mov rax, [rel g_pl_pos + 16]
    mov [rel g_spot + 16], rax
    lea rcx, [rel g_spot]
    mov edx, PF_FLYING | PF_NOCLIP
    call player_spawn
    LOG_INFO "survival: Hardcore over; the player spectates"
.done:
    RETURN
ENDPROC
