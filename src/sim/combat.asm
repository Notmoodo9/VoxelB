; =============================================================================
; combat.asm — melee in the simulation (milestone 21 part 1,
; design/combat/combat.md, DECISIONS D105).
;
; The swing meter: ticks since the last swing over the item's `swing` time
; (the hand's for items without one); it starts again at every swing (a hit
; or a swing at the air) and when the item in hand changes. A hit does
;   damage × (min_factor + (1 − min_factor) × meter²)
; and knock-back × (0.4 + 0.6 × meter). A full swing while falling (not on
; the ground, in water, climbing or flying) is a critical hit (× crit_factor);
; a full sword swing on the ground also sweeps the animals within
; sweep_radius of the target (sweep_damage + sweep_fraction × the damage,
; half the knock-back). Weapons wear weapon_wear per hit, other tools
; tool_wear (Survival). A landed hit is told to the client (PKT_S_HIT) for
; the hit pause, the shake and the sparks or dust.
; Numbers: data/combat/combat.cfg; weapon stats: the items' `weapon`,
; `damage`, `swing`, `knockback`, `reach`.
;
; Public API:
;   combat_load()                       after items_load
;   combat_reset()                      a world starts
;   combat_tick()                       once per simulation tick
;   combat_attack(rcx = ENT_PKT*)       PKT_C_ATTACK: .id the animal, or
;                                       -1: a swing at nothing
;   combat_swing_ticks(ecx = item) -> eax ticks a full swing takes (client too)
;   combat_armor_hit(xmm0 = f32 damage) -> xmm0 the damage the armor lets
;                                       through; each piece worn wears by 1
;   g_armor_points, g_armor_speed, g_armor_hunger, g_armor_heavy,
;   g_armor_medium (f32): the armor worn (part 2), worked out every tick:
;   points = the pieces' `protection`; speed x (1 − medium_slow × medium
;   share − heavy_slow × heavy share); hunger from moving x (1 +
;   heavy_hunger × heavy share); a piece's share of the body: helmet 15 %,
;   chestplate 40 %, leggings 30 %, boots 15 %
;   Shields and the dodge roll (part 2):
;   combat_block(xmm0 = f32 dx, xmm1 = f32 dz: the attacker - the player,
;       xmm2 = f32 damage) -> eax 1: a raised shield took it (it wears by
;       the damage) and xmm0 = f32 x the knock-back (shield_push)
;   combat_dodge(rcx = DODGE_PKT*)      PKT_C_DODGE: roll that way
;   g_cb_blocking: 1 while the shield is up (the use button held with a
;   shield in the off hand and nothing usable in the main hand, for
;   shield_raise); the player walks at sneak speed
;   g_roll (ticks left), g_roll_vel (f64 x, z): player_tick holds the
;   speed of a roll; g_cb_safe: ticks the roll keeps damage off
;   g_cb_values: the settings (f32, in the order of k_table; the client reads
;   g_cb_min_factor, g_cb_hit_pause, g_cb_crit_pause, g_cb_heavy_pause,
;   g_cb_shake)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "packet.inc"
%include "items.inc"
%include "save.inc"
%include "entity.inc"

global combat_load, combat_reset, combat_tick, combat_attack, combat_swing_ticks
global g_cb_min_factor, g_cb_hit_pause, g_cb_crit_pause, g_cb_heavy_pause
global g_cb_shake, g_cb_crit_meter
global combat_armor_hit, g_armor_points, g_armor_speed, g_armor_hunger
global g_armor_heavy, g_armor_medium
global combat_block, combat_dodge, g_cb_blocking, g_cb_safe, g_roll, g_roll_vel

extern str_ieq, str_parse_float, inv_wear_selected, inv_wear_slot, survival_exhaust
extern pkt_send, g_to_client
extern g_inv, g_inv_sel, g_pl_pos, g_pl_vel, g_pl_flags, g_pl_reach
extern g_world_mode, g_sv_dead, g_input, sincosf

%define SLOT_SIZE       8

section .rdata
str_file:       db "data/combat/combat.cfg", 0
str_label:      db "combat.cfg", 0
str_unknown:    db "unknown setting: ", 0
str_bad:        db "bad value for: ", 0
str_hit:        db "combat: hit, damage x10 ", 0
str_flags:      db ", flags ", 0
k_0:  db "hand_damage", 0
k_1:  db "hand_swing", 0
k_2:  db "min_factor", 0
k_3:  db "crit_factor", 0
k_4:  db "crit_meter", 0
k_5:  db "sweep_damage", 0
k_6:  db "sweep_fraction", 0
k_7:  db "sweep_radius", 0
k_8:  db "reach_extra", 0
k_9:  db "exhaust_attack", 0
k_10: db "weapon_wear", 0
k_11: db "tool_wear", 0
k_12: db "hit_pause", 0
k_13: db "crit_pause", 0
k_14: db "heavy_pause", 0
k_15: db "shake", 0
k_16: db "protection_per_point", 0
k_17: db "protection_cap", 0
k_18: db "medium_slow", 0
k_19: db "heavy_slow", 0
k_20: db "heavy_hunger", 0
k_21: db "shield_raise", 0
k_22: db "shield_arc", 0
k_23: db "shield_push", 0
k_24: db "roll_distance", 0
k_25: db "roll_distance_medium", 0
k_26: db "roll_time", 0
k_27: db "roll_safe", 0
k_28: db "roll_cooldown", 0
k_29: db "exhaust_roll", 0
k_30: db "roll_heavy", 0
align 8
k_table:    dq k_0, k_1, k_2, k_3, k_4, k_5, k_6, k_7, k_8, k_9, k_10, k_11
            dq k_12, k_13, k_14, k_15, k_16, k_17, k_18, k_19, k_20
            dq k_21, k_22, k_23, k_24, k_25, k_26, k_27, k_28, k_29, k_30
%define KEY_COUNT 31
align 8
c_lift:         dq 0.7                  ; the hit's point over the animal's feet
c_half_kb:      dd 0.5
c_kb_base:      dd 0.4
c_kb_meter:     dd 0.6
c_one:          dd 1.0
c_twenty:       dd 20.0
c_ten:          dd 10.0

section .data
align 4
g_cb_values:
s_hand_damage:  dd 1.0
s_hand_swing:   dd 0.25
g_cb_min_factor:
s_min_factor:   dd 0.2
s_crit_factor:  dd 1.5
g_cb_crit_meter:
s_crit_meter:   dd 0.9
s_sweep_damage: dd 1.0
s_sweep_frac:   dd 0.3
s_sweep_radius: dd 1.0
s_reach_extra:  dd 1.5
s_ex_attack:    dd 0.1
s_weapon_wear:  dd 1.0
s_tool_wear:    dd 2.0
g_cb_hit_pause:
s_hit_pause:    dd 0.05
g_cb_crit_pause:
s_crit_pause:   dd 0.08
g_cb_heavy_pause:
s_heavy_pause:  dd 0.1
g_cb_shake:
s_shake:        dd 0.6
s_per_point:    dd 0.04                 ; armor (part 2): damage taken x (1 - this x points)
s_prot_cap:     dd 20.0
s_medium_slow:  dd 0.05
s_heavy_slow:   dd 0.12
s_heavy_hunger: dd 0.25
s_shield_raise: dd 0.25                 ; seconds to raise a shield
s_shield_arc:   dd 90.0                 ; degrees in front it covers
s_shield_push:  dd 0.3                  ; x the knock-back of a blocked hit
s_roll_dist:    dd 3.0                  ; dodge roll: blocks (light armor)
s_roll_dist_m:  dd 2.0                  ; ... all in medium (or heavy) armor
s_roll_time:    dd 0.35                 ; seconds
s_roll_safe:    dd 0.2                  ; seconds without damage
s_roll_cool:    dd 1.5                  ; seconds before the next
s_ex_roll:      dd 0.3                  ; exhaustion
s_roll_heavy:   dd 0.5                  ; heavy share from which there is no roll
; the armor worn, worked out every tick (combat_tick)
g_armor_points: dd 0.0                  ; f32 protection points
g_armor_speed:  dd 1.0                  ; f32 x walking speed
g_armor_hunger: dd 1.0                  ; f32 x hunger from moving
g_armor_heavy:  dd 0.0                  ; f32 share of the body in heavy armor
g_armor_medium: dd 0.0                  ; f32 ... in medium armor

section .bss
alignb 8
g_cfg_mark:     resq 1
g_path:         resb 260
g_hit:          resb HIT_PKT_size
alignb 4
g_since:        resd 1                  ; ticks since the last swing
g_held:         resd 1                  ; the item in hand last tick
g_held_sel:     resd 1                  ; and its slot
g_target:       resd 1                  ; the animal hit (sweep: not again)
g_meter:        resd 1                  ; f32 the swing's meter
g_raise:        resd 1                  ; ticks the shield has been held up
g_cb_blocking:  resd 1                  ; 1: the shield is raised
g_roll:         resd 1                  ; ticks of dodge roll left
g_cb_safe:      resd 1                  ; ticks without damage left (roll)
g_roll_cool:    resd 1                  ; ticks before the next roll
alignb 8
g_roll_vel:     resq 2                  ; f64 x, z blocks a second

section .text

; -----------------------------------------------------------------------------
; combat_load — data/combat/combat.cfg (missing: the built-in values).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC combat_load, 0
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
    INVOKE cfg_parse, rax, rdx, 0, r9
    jmp .parsed
.missing:
    LOG_WARN "combat: data/combat/combat.cfg missing; built-in values"
.parsed:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [rel g_cfg_mark]
    RETURN
ENDPROC

; cfg_pair — combat.cfg callback: rcx = name, rdx = value
PROC cfg_pair, 16, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    xor edi, edi
.key:
    cmp edi, KEY_COUNT
    jae .unknown
    lea rax, [rel k_table]
    INVOKE str_ieq, rbx, [rax + rdi * 8]
    test eax, eax
    jnz .found
    inc edi
    jmp .key
.found:
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jb .bad
    lea rax, [rel g_cb_values]
    movss [rax + rdi * 4], xmm0
    RETURN
.unknown:
    lea rdx, [rel str_unknown]
    jmp .warn
.bad:
    lea rdx, [rel str_bad]
.warn:
    lea rcx, [rel str_label]
    INVOKE cfg_warn, rcx, rdx, rbx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; combat_reset — a world starts: the meter full
;   clobbers: rax
; -----------------------------------------------------------------------------
combat_reset:
    xor eax, eax
    mov [rel g_raise], eax
    mov [rel g_cb_blocking], eax
    mov [rel g_roll], eax
    mov [rel g_cb_safe], eax
    mov [rel g_roll_cool], eax
    mov dword [rel g_since], 1000
    mov dword [rel g_held], -1
    mov dword [rel g_held_sel], -1
    ret

; -----------------------------------------------------------------------------
; combat_swing_ticks — ticks a full swing with this item takes.
;   in:  ecx = item (0: the hand)   out: eax ticks (>= 1)
;   clobbers: rax, rdx, xmm0
; -----------------------------------------------------------------------------
combat_swing_ticks:
    lea rdx, [rel g_item_swing]
    movzx eax, byte [rdx + rcx]
    test ecx, ecx
    jz .hand
    test eax, eax
    jnz .done
.hand:
    movss xmm0, [rel s_hand_swing]
    mulss xmm0, [rel c_twenty]
    cvtss2si eax, xmm0
    cmp eax, 1
    jge .done
    mov eax, 1
.done:
    ret

; held — eax = the item in hand   clobbers: rax, rdx
held:
    mov eax, [rel g_inv_sel]
    lea rdx, [rel g_inv]
    movzx eax, word [rdx + rax * SLOT_SIZE]
    ret

; -----------------------------------------------------------------------------
; combat_tick — the meter fills; a new item in hand starts it again; the
; armor worn is summed up.
;   clobbers: rax, rcx, rdx, xmm0-xmm3
; -----------------------------------------------------------------------------
combat_tick:
    call armor_sums
    call shield_tick
    ; the dodge roll's clocks
    cmp dword [rel g_roll], 0
    je .rolled
    dec dword [rel g_roll]
.rolled:
    cmp dword [rel g_cb_safe], 0
    je .safe
    dec dword [rel g_cb_safe]
.safe:
    cmp dword [rel g_roll_cool], 0
    je .cool
    dec dword [rel g_roll_cool]
.cool:
    cmp dword [rel g_since], 1000
    jae .counted
    inc dword [rel g_since]
.counted:
    call held
    mov edx, [rel g_inv_sel]
    cmp eax, [rel g_held]
    jne .changed
    cmp edx, [rel g_held_sel]
    je .done
.changed:
    mov [rel g_held], eax
    mov [rel g_held_sel], edx
    mov dword [rel g_since], 0
.done:
    ret

; -----------------------------------------------------------------------------
; combat_attack — see the header.
;   in:  rcx = ENT_PKT*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define A_ID     0
%define A_ITEM   4
%define A_DMG    8                      ; f32
%define A_KB     12                     ; f32
%define A_FLAGS  16
%define A_I      20
PROC combat_attack, 32, rbx, rsi, rdi
    mov eax, [rcx + ENT_PKT.id]
    mov [LOCAL(A_ID)], eax
    cmp dword [rel g_world_mode], MODE_SPECTATOR
    je .done
    cmp dword [rel g_sv_dead], 0
    jne .done
    ; the meter of this swing, and a new one starts
    call held
    mov [LOCAL(A_ITEM)], eax
    mov ecx, eax
    call combat_swing_ticks
    cvtsi2ss xmm1, eax
    cvtsi2ss xmm0, dword [rel g_since]
    divss xmm0, xmm1
    minss xmm0, [rel c_one]
    movss [rel g_meter], xmm0
    mov dword [rel g_since], 0
    cmp dword [LOCAL(A_ID)], MAX_ENTITIES
    jae .done                           ; (a swing at nothing)
    ; the animal, within reach (the item's extra reach too)
    mov eax, [LOCAL(A_ID)]
    imul rax, rax, EntT_size
    lea rbx, [rel g_ents]
    add rbx, rax
    test dword [rbx + EntT.flags], EF_ACTIVE
    jz .done
    movsd xmm0, [rbx + EntT.pos]
    subsd xmm0, [rel g_pl_pos]
    mulsd xmm0, xmm0
    movsd xmm1, [rbx + EntT.pos + 16]
    subsd xmm1, [rel g_pl_pos + 16]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    movss xmm2, [rel g_pl_reach]
    addss xmm2, [rel s_reach_extra]
    mov ecx, [LOCAL(A_ITEM)]
    lea rdx, [rel g_item_reach]
    addss xmm2, [rdx + rcx * 4]
    mulss xmm2, xmm2
    cvtss2sd xmm2, xmm2
    comisd xmm0, xmm2
    ja .done
    ; damage × (min + (1 − min) × meter²)
    mov ecx, [LOCAL(A_ITEM)]
    lea rdx, [rel g_item_damage]
    movss xmm0, [rdx + rcx * 4]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    ja .damage
    movss xmm0, [rel s_hand_damage]
.damage:
    movss xmm1, [rel g_meter]
    mulss xmm1, xmm1
    movss xmm2, [rel c_one]
    subss xmm2, [rel s_min_factor]
    mulss xmm1, xmm2
    addss xmm1, [rel s_min_factor]
    mulss xmm0, xmm1
    movss [LOCAL(A_DMG)], xmm0
    ; knock-back × (0.4 + 0.6 × meter)
    lea rdx, [rel g_item_kb]
    movss xmm0, [rdx + rcx * 4]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    ja .kb
    movss xmm0, [rel c_one]
.kb:
    movss xmm1, [rel g_meter]
    mulss xmm1, [rel c_kb_meter]
    addss xmm1, [rel c_kb_base]
    mulss xmm0, xmm1
    movss [LOCAL(A_KB)], xmm0
    mov dword [LOCAL(A_FLAGS)], 0
    ; heavy weapons (axes, maces): a stronger hit pause
    lea rdx, [rel g_item_weapon]
    movzx eax, byte [rdx + rcx]
    cmp eax, WEAPON_AXE
    je .heavy
    cmp eax, WEAPON_MACE
    jne .crit
.heavy:
    or dword [LOCAL(A_FLAGS)], HITF_HEAVY
.crit:
    ; a full swing while falling: a critical hit
    movss xmm0, [rel g_meter]
    comiss xmm0, [rel s_crit_meter]
    jb .hit
    test dword [rel g_pl_flags], PF_ON_GROUND | PF_IN_WATER | PF_CLIMBING | PF_FLYING
    jnz .hit
    xorpd xmm1, xmm1
    comisd xmm1, [rel g_pl_vel + 8]
    jbe .hit                            ; (rising)
    movss xmm0, [LOCAL(A_DMG)]
    mulss xmm0, [rel s_crit_factor]
    movss [LOCAL(A_DMG)], xmm0
    or dword [LOCAL(A_FLAGS)], HITF_CRIT
.hit:
    mov ecx, [LOCAL(A_ID)]
    movss xmm1, [LOCAL(A_DMG)]
    movss xmm2, [LOCAL(A_KB)]
    call ents_hit
    test eax, eax
    jz .done
    ; worn by the hit; hunger
    call wear
    movss xmm0, [rel s_ex_attack]
    call survival_exhaust
    ; a full sword swing on the ground sweeps the animals beside the target
    mov ecx, [LOCAL(A_ITEM)]
    lea rdx, [rel g_item_weapon]
    cmp byte [rdx + rcx], WEAPON_SWORD
    jne .told
    movss xmm0, [rel g_meter]
    comiss xmm0, [rel s_crit_meter]
    jb .told
    test dword [rel g_pl_flags], PF_ON_GROUND
    jz .told
    test dword [LOCAL(A_FLAGS)], HITF_CRIT
    jnz .told
    call sweep
.told:
%if BUILD_DEBUG
    ; (debug log: the damage × 10 and the flags)
    mov ecx, LOG_LEVEL_DEBUG
    call log_begin
    lea rcx, [rel str_hit]
    call log_append_str
    movss xmm0, [LOCAL(A_DMG)]
    mulss xmm0, [rel c_ten]
    cvtss2si ecx, xmm0
    call log_append_dec
    lea rcx, [rel str_flags]
    call log_append_str
    mov ecx, [LOCAL(A_FLAGS)]
    call log_append_dec
    call log_end
%endif
    ; the client: where, and how hard
    mov rax, [rbx + EntT.pos]
    mov [rel g_hit + HIT_PKT.pos], rax
    movsd xmm0, [rbx + EntT.pos + 8]
    addsd xmm0, [rel c_lift]
    movsd [rel g_hit + HIT_PKT.pos + 8], xmm0
    mov rax, [rbx + EntT.pos + 16]
    mov [rel g_hit + HIT_PKT.pos + 16], rax
    mov eax, [LOCAL(A_FLAGS)]
    mov [rel g_hit + HIT_PKT.flags], ax
    mov eax, [rel g_meter]
    mov [rel g_hit + HIT_PKT.meter], eax
    lea rcx, [rel g_to_client]
    lea r8, [rel g_hit]
    INVOKE pkt_send, rcx, PKT_S_HIT, r8, HIT_PKT_size
.done:
    RETURN

; sweep — (inside combat_attack: rbx = the target, its LOCALs) every other
; awake animal within sweep_radius of it (horizontally, 1 block up or down)
sweep:
    sub rsp, 8                          ; (keeps the calls aligned)
    mov edi, [LOCAL(A_ID) + 16]
    xor esi, esi
.s_ent:
    cmp esi, MAX_ENTITIES
    jae .s_done
    cmp esi, edi
    je .s_next
    imul rax, rsi, EntT_size
    lea rdx, [rel g_ents]
    add rdx, rax
    mov eax, [rdx + EntT.flags]
    and eax, EF_ACTIVE | EF_AWAKE | EF_DYING
    cmp eax, EF_ACTIVE | EF_AWAKE
    jne .s_next
    movsd xmm0, [rdx + EntT.pos + 8]
    subsd xmm0, [rbx + EntT.pos + 8]
    mulsd xmm0, xmm0
    comisd xmm0, [rel c_one_d]
    ja .s_next
    movsd xmm0, [rdx + EntT.pos]
    subsd xmm0, [rbx + EntT.pos]
    mulsd xmm0, xmm0
    movsd xmm1, [rdx + EntT.pos + 16]
    subsd xmm1, [rbx + EntT.pos + 16]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    cvtss2sd xmm1, [rel s_sweep_radius]
    addsd xmm1, [rel c_body]
    mulsd xmm1, xmm1
    comisd xmm0, xmm1
    ja .s_next
    movss xmm1, [LOCAL(A_DMG) + 16]
    mulss xmm1, [rel s_sweep_frac]
    addss xmm1, [rel s_sweep_damage]
    movss xmm2, [LOCAL(A_KB) + 16]
    mulss xmm2, [rel c_half_kb]
    mov ecx, esi
    call ents_hit
    test eax, eax
    jz .s_next
    or dword [LOCAL(A_FLAGS) + 16], HITF_SWEEP
.s_next:
    inc esi
    jmp .s_ent
.s_done:
    add rsp, 8
    ret
ENDPROC

; -----------------------------------------------------------------------------
; wear — the item in hand is worn by a hit (Survival): weapons weapon_wear,
; other tools tool_wear, anything else nothing.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC wear, 0, rbx
    call held
    test eax, eax
    jz .done
    lea rdx, [rel g_item_weapon]
    movss xmm0, [rel s_weapon_wear]
    cmp byte [rdx + rax], WEAPON_NONE
    jne .times
    lea rdx, [rel g_item_tool]
    cmp byte [rdx + rax], TOOL_NONE
    je .done
    movss xmm0, [rel s_tool_wear]
.times:
    cvtss2si ebx, xmm0
.again:
    test ebx, ebx
    jle .done
    call inv_wear_selected
    dec ebx
    jmp .again
.done:
    RETURN
ENDPROC

section .rdata
align 8
c_one_d:        dq 1.0
c_body:         dq 0.5                  ; (half an animal's width)

section .text

; -----------------------------------------------------------------------------
; armor_sums — g_armor_* from the armor slots (a piece counts only in its
; own slot)   clobbers: rax, rcx, rdx, xmm0-xmm3
; -----------------------------------------------------------------------------
armor_sums:
    xorps xmm0, xmm0                    ; points
    xorps xmm1, xmm1                    ; medium share
    xorps xmm2, xmm2                    ; heavy share
    xor ecx, ecx
.piece:
    lea rax, [rel g_inv + INV_ARMOR * SLOT_SIZE]
    movzx eax, word [rax + rcx * SLOT_SIZE]
    test eax, eax
    jz .next
    lea rdx, [rel g_item_armor]
    movzx edx, byte [rdx + rax]
    dec edx
    cmp edx, ecx
    jne .next                           ; (not worn there)
    lea rdx, [rel g_item_prot]
    addss xmm0, [rdx + rax * 4]
    lea rdx, [rel g_item_weight]
    movzx edx, byte [rdx + rax]
    lea rax, [rel c_share]
    movss xmm3, [rax + rcx * 4]
    cmp edx, WEIGHT_MEDIUM
    jne .not_medium
    addss xmm1, xmm3
.not_medium:
    cmp edx, WEIGHT_HEAVY
    jne .next
    addss xmm2, xmm3
.next:
    inc ecx
    cmp ecx, 4
    jb .piece
    movss [rel g_armor_points], xmm0
    movss [rel g_armor_medium], xmm1
    movss [rel g_armor_heavy], xmm2
    mulss xmm1, [rel s_medium_slow]
    movss xmm3, xmm2
    mulss xmm3, [rel s_heavy_slow]
    movss xmm0, [rel c_one]
    subss xmm0, xmm1
    subss xmm0, xmm3
    movss [rel g_armor_speed], xmm0
    mulss xmm2, [rel s_heavy_hunger]
    addss xmm2, [rel c_one]
    movss [rel g_armor_hunger], xmm2
    ret

; -----------------------------------------------------------------------------
; combat_armor_hit — see the header.
;   in:  xmm0 = f32 damage   out: xmm0 = f32 damage after the armor
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC combat_armor_hit, 16, rbx
    movss xmm1, [rel g_armor_points]
    minss xmm1, [rel s_prot_cap]
    mulss xmm1, [rel s_per_point]
    movss xmm2, [rel c_one]
    subss xmm2, xmm1
    maxss xmm2, [rel c_zero]
    mulss xmm0, xmm2
    movss [LOCAL(0)], xmm0
    ; every piece worn takes the hit
    xor ebx, ebx
.wear:
    lea rax, [rel g_inv + INV_ARMOR * SLOT_SIZE]
    cmp word [rax + rbx * SLOT_SIZE], 0
    je .next
    lea ecx, [ebx + INV_ARMOR]
    call inv_wear_slot
.next:
    inc ebx
    cmp ebx, 4
    jb .wear
    movss xmm0, [LOCAL(0)]
    RETURN
ENDPROC

section .rdata
align 4
c_share:        dd 0.15, 0.40, 0.30, 0.15   ; helmet, chestplate, leggings, boots
c_zero:         dd 0.0

section .text
; -----------------------------------------------------------------------------
; shield_tick — g_cb_blocking: the use button held with a shield in the off
; hand (and in the main hand nothing that eats or places) for shield_raise.
;   clobbers: rax, rcx, rdx, xmm0
; -----------------------------------------------------------------------------
shield_tick:
    cmp dword [rel g_world_mode], MODE_SPECTATOR
    je .down
    cmp dword [rel g_sv_dead], 0
    jne .down
    cmp dword [rel g_roll], 0
    jne .down
    test dword [rel g_input + INPUT_PKT.buttons], INB_USE
    jz .down
    movzx eax, word [rel g_inv + INV_OFFHAND * SLOT_SIZE]
    lea rdx, [rel g_item_armor]
    cmp byte [rdx + rax], ARMOR_SHIELD
    jne .down
    test eax, eax
    jz .down
    call held
    test eax, eax
    jz .up
    lea rdx, [rel g_item_food]
    cmp byte [rdx + rax], 0
    jne .down
    lea rdx, [rel g_item_block]
    cmp word [rdx + rax * 2], 0
    jne .down
.up:
    inc dword [rel g_raise]
    movss xmm0, [rel s_shield_raise]
    mulss xmm0, [rel c_twenty]
    cvtss2si eax, xmm0
    xor ecx, ecx
    cmp [rel g_raise], eax
    setge cl
    mov [rel g_cb_blocking], ecx
    ret
.down:
    xor eax, eax
    mov [rel g_raise], eax
    mov [rel g_cb_blocking], eax
    ret

; -----------------------------------------------------------------------------
; combat_block — see the header.
;   in:  xmm0, xmm1 = f32 dx, dz (the attacker - the player), xmm2 = f32 damage
;   out: eax = 1 blocked (xmm0 = f32 knock-back factor), 0 not
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define B_DX    0
%define B_DZ    4
%define B_DMG   8
%define B_N     12
PROC combat_block, 16, rbx
    cmp dword [rel g_cb_blocking], 0
    je .no
    movss [LOCAL(B_DX)], xmm0
    movss [LOCAL(B_DZ)], xmm1
    movss [LOCAL(B_DMG)], xmm2
    ; in front: the look (sin yaw, -cos yaw) within half the arc of it
    movss xmm0, [rel g_input + INPUT_PKT.yaw]
    call sincosf                        ; xmm0 = sin, xmm1 = cos
    mulss xmm0, [LOCAL(B_DX)]
    mulss xmm1, [LOCAL(B_DZ)]
    subss xmm0, xmm1                    ; |d| cos(angle)
    movss xmm2, [LOCAL(B_DX)]
    mulss xmm2, xmm2
    movss xmm3, [LOCAL(B_DZ)]
    mulss xmm3, xmm3
    addss xmm2, xmm3
    sqrtss xmm2, xmm2
    movss [LOCAL(B_N)], xmm0
    movss xmm0, [rel s_shield_arc]
    mulss xmm0, [rel c_half_deg]        ; half the arc, in radians
    movss [LOCAL(B_DX)], xmm2
    call cosf_
    mulss xmm0, [LOCAL(B_DX)]
    comiss xmm0, [LOCAL(B_N)]
    ja .no
    ; the shield wears by the damage (rounded)
    movss xmm0, [LOCAL(B_DMG)]
    addss xmm0, [rel c_half_kb]
    cvttss2si ebx, xmm0
.wear:
    test ebx, ebx
    jle .worn
    cmp word [rel g_inv + INV_OFFHAND * SLOT_SIZE], 0
    je .worn                            ; (it broke)
    mov ecx, INV_OFFHAND
    call inv_wear_slot
    dec ebx
    jmp .wear
.worn:
    movss xmm0, [rel s_shield_push]
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; cosf_ — xmm0 = cos(xmm0)   clobbers: volatile registers
cosf_:
    sub rsp, 40
    call sincosf
    movss xmm0, xmm1
    add rsp, 40
    ret

; -----------------------------------------------------------------------------
; combat_dodge — PKT_C_DODGE: a roll along (dx, dz) if the player is on the
; ground, not in heavy armor (share >= roll_heavy), not blocking and the
; cooldown is over. Medium (and heavy) armor shortens it toward
; roll_distance_medium.
;   in:  rcx = DODGE_PKT*   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC combat_dodge, 16, rbx
    mov rbx, rcx
    cmp dword [rel g_world_mode], MODE_SPECTATOR
    je .done
    cmp dword [rel g_sv_dead], 0
    jne .done
    cmp dword [rel g_roll_cool], 0
    jne .done
    cmp dword [rel g_cb_blocking], 0
    jne .done
    mov eax, [rel g_pl_flags]
    test eax, PF_ON_GROUND
    jz .done
    test eax, PF_FLYING | PF_NOCLIP | PF_IN_WATER | PF_IN_LAVA | PF_CLIMBING
    jnz .done
    movss xmm0, [rel g_armor_heavy]
    comiss xmm0, [rel s_roll_heavy]
    jae .done
    ; the direction, made unit length
    movss xmm0, [rbx + DODGE_PKT.dx]
    movss xmm1, [rbx + DODGE_PKT.dz]
    movss xmm2, xmm0
    mulss xmm2, xmm0
    movss xmm3, xmm1
    mulss xmm3, xmm1
    addss xmm2, xmm3
    sqrtss xmm2, xmm2
    comiss xmm2, [rel c_tiny_f]
    jbe .done
    divss xmm0, xmm2
    divss xmm1, xmm2
    ; distance: roll_distance - (roll_distance - medium) x (medium + heavy)
    movss xmm2, [rel g_armor_medium]
    addss xmm2, [rel g_armor_heavy]
    minss xmm2, [rel c_one]
    movss xmm3, [rel s_roll_dist]
    subss xmm3, [rel s_roll_dist_m]
    mulss xmm3, xmm2
    movss xmm2, [rel s_roll_dist]
    subss xmm2, xmm3
    divss xmm2, [rel s_roll_time]       ; blocks a second
    mulss xmm0, xmm2
    mulss xmm1, xmm2
    cvtss2sd xmm0, xmm0
    cvtss2sd xmm1, xmm1
    movsd [rel g_roll_vel], xmm0
    movsd [rel g_roll_vel + 8], xmm1
    movss xmm0, [rel s_roll_time]
    mulss xmm0, [rel c_twenty]
    cvtss2si eax, xmm0
    mov [rel g_roll], eax
    movss xmm0, [rel s_roll_safe]
    mulss xmm0, [rel c_twenty]
    cvtss2si eax, xmm0
    mov [rel g_cb_safe], eax
    movss xmm0, [rel s_roll_cool]
    mulss xmm0, [rel c_twenty]
    cvtss2si eax, xmm0
    mov [rel g_roll_cool], eax
    movss xmm0, [rel s_ex_roll]
    call survival_exhaust
    LOG_DEBUG "combat: dodge roll"
.done:
    RETURN
ENDPROC

section .rdata
align 4
c_half_deg:     dd 0.00872664626        ; pi / 360: half of a degree count, in radians
c_tiny_f:       dd 0.001
