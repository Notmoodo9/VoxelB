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

extern str_ieq, str_parse_float, inv_wear_selected, survival_exhaust
extern pkt_send, g_to_client
extern g_inv, g_inv_sel, g_pl_pos, g_pl_vel, g_pl_flags, g_pl_reach
extern g_world_mode, g_sv_dead

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
align 8
k_table:    dq k_0, k_1, k_2, k_3, k_4, k_5, k_6, k_7, k_8, k_9, k_10, k_11
            dq k_12, k_13, k_14, k_15
%define KEY_COUNT 16
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
; combat_tick — the meter fills; a new item in hand starts it again.
;   clobbers: rax, rdx
; -----------------------------------------------------------------------------
combat_tick:
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
