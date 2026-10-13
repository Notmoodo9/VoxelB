; =============================================================================
; entities.asm — the simulation's animals (milestone 19,
; design/mobs/passive_animals.md, DECISIONS D98).
;
; Every animal is a slot in one table (MAX_ENTITIES); the slot is its id on
; the client. An animal belongs to the entity region it stands in
; (ent_store.asm keeps regions in memory and on disk). Animals within
; SIM_RADIUS of the player, on generated ground, are awake: they think,
; move and are sent to the client (PKT_S_ENTITY when something changed);
; the others wait, frozen, and the client forgets them (PKT_S_ENTITY_GONE).
;
;
; Deciding where to go is behave.asm's (part 2: paths, herds, food, sleep,
; breeding); this module keeps the table, the bodies and the packets.
; Bodies: a box of the mob's size against the blocks (physics.asm), gravity,
; a jump when walking into a 1-block step, floating and swimming in water.
; Hits (PKT_C_ATTACK): 1 damage (weapons come with combat, milestone 21),
; knock-back, a red flash; at 0 health it falls over and drops its loot.
;
; Public API (include/entity.inc):
;   ents_reset()                    a new world: none
;   ents_tick()                     once per simulation tick
;   ents_attack(rcx = ENT_PKT*)     the player hit an animal
;   ent_new(ecx = variant, edx = EF_BABY or 0, r8 = f64[3] feet) -> eax id / -1
;   ent_remove(ecx = id)            gone (the client is told)
;   g_ents, g_ent_count             the table, animals in it
;   g_ent_awake, g_ent_sent, g_ent_tick_us   statistics (overlay)
; =============================================================================
%define ENTITIES_IMPL
%include "macros.inc"
%include "log.inc"
%include "packet.inc"
%include "physics.inc"
%include "mobs.inc"
%include "entity.inc"

global ents_reset, ents_tick, ents_attack, ent_new, ent_remove, g_ents, g_ent_count
global g_ent_awake, g_ent_tick_us, g_ent_sent, g_paths

extern pkt_send, g_to_client, drops_spawn, sincosf, atan2f, timer_elapsed_us
extern g_pl_pos, g_pl_eye, g_pl_reach

%define HURT_TICKS      10              ; red flash; no new hit meanwhile
%define FLEE_TICKS      100
%define DEATH_TICKS     20              ; falling over, then the loot
%define WILD_FLEE2      144.0           ; wild animals run within 12 blocks
%define LOOK2           36.0            ; heads turn to a player within 6 blocks
%define WANDER_R        7.0

section .rdata
align 8
c_gravity:      dq 0.08                 ; blocks per tick^2
c_drag_y:       dq 0.98
c_jump:         dq 0.42                 ; up 1.1 blocks
c_swim_up:      dq 0.04
c_swim_max:     dq 0.12
c_acc_ground:   dq 0.3
c_acc_air:      dq 0.05
c_acc_water:    dq 0.15
c_per_tick:     dq 0.05                 ; blocks per second -> per tick
c_flee_mul:     dq 2.2
c_baby_scale:   dq 0.5
c_half:         dq 0.5
c_margin:       dq 1.0
c_sim_r2:       dq 16384.0              ; SIM_RADIUS^2
c_wild2:        dq WILD_FLEE2
c_look2:        dq LOOK2
c_wander_r:     dq WANDER_R
c_flee_dist:    dq 10.0
c_arrive2:      dq 0.36                 ; (0.6 blocks)^2: there
c_u32:          dq 0.00000000023283064365386963 ; 2^-32
c_knock:        dq 0.42
c_knock_up:     dq 0.34
c_reach_extra:  dq 1.5
c_probe:        dq 0.55                 ; how far ahead it looks for drops
c_moving2:      dq 0.0004               ; squared speed: moving
c_eye_lift:     dq -0.4               ; the player's eyes above its head
c_lower:        dq 0.5                  ; water: the lower half of the body
c_progress:     dd 0.02                 ; closer by this: not stuck
align 4
c_turn:         dd 0.25                 ; radians per tick
c_head_turn:    dd 0.2
c_pi:           dd 3.14159265
c_two_pi:       dd 6.28318531
c_head_max:     dd 1.2                  ; how far the head turns from the body
c_pitch_max:    dd 0.7
c_look_far:     dd 0.9                  ; looking around: up to this
c_zero_f:       dd 0.0
align 16
c_neg_f:        dd 0x80000000, 0, 0, 0     ; (xorps: 16-byte aligned)
c_abs_d:        dq 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF

section .bss
alignb 16
g_ents:         resb MAX_ENTITIES * EntT_size
g_paths:        resb MAX_ENTITIES * PATH_MAX * WP_BYTES ; each animal's path
g_box:          resq 6
g_region:       resq 6
g_move:         resq 3
g_res:          resq 3
g_lower:        resq 6
g_out:          resb ENT_PKT_size
alignb 4
g_ent_count:    resd 1
g_ent_awake:    resd 1                  ; this tick
g_ent_sent:     resd 1                  ; the client knows these
g_rand:         resd 1
g_hint:         resd 1                  ; a free slot is likely here
alignb 8
g_ent_tick_us:  resq 1                  ; the last tick's animals

section .text

; rand — eax = a random u32 (xorshift)   clobbers: rax, rcx
rand:
    mov eax, [rel g_rand]
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
    mov [rel g_rand], eax
    ret

; rand01 — xmm0 = 0 .. 1 (double)   clobbers: rax, rcx, xmm0
rand01:
    call rand
    mov eax, eax
    cvtsi2sd xmm0, rax
    mulsd xmm0, [rel c_u32]
    ret

; rand_below — eax = 0 .. ecx - 1   clobbers: rax, rcx, rdx
rand_below:
    mov edx, ecx
    push rdx
    call rand
    pop rcx
    xor edx, edx
    test ecx, ecx
    jz .zero
    div ecx
    mov eax, edx
    ret
.zero:
    xor eax, eax
    ret

; wrap — xmm0 into -pi .. pi (float)   clobbers: xmm0, xmm1
wrap:
    movss xmm1, xmm0
    divss xmm1, [rel c_two_pi]
    roundss xmm1, xmm1, 0
    mulss xmm1, [rel c_two_pi]
    subss xmm0, xmm1
    ret

; turn — xmm0 towards xmm1 by at most xmm2 (angles, float)
;   out: xmm0   clobbers: xmm0, xmm1, xmm3
turn:
    movss xmm3, xmm0
    movss xmm0, xmm1
    subss xmm0, xmm3                    ; difference
    call wrap
    movss xmm1, xmm2
    minss xmm0, xmm1
    xorps xmm1, [rel c_neg_f]
    maxss xmm0, xmm1
    addss xmm0, xmm3
    jmp wrap

; mob_of — rax = MOB* of entity rbx   clobbers: rax
mob_of:
    movzx eax, word [rbx + EntT.mob]
    imul eax, eax, MOB_size
    push rcx
    lea rcx, [rel g_mobs]
    add rax, rcx
    pop rcx
    ret

; size_of — xmm0 = half width, xmm1 = height (doubles) of entity rbx
;   clobbers: rax, xmm0, xmm1
size_of:
    call mob_of
    cvtss2sd xmm0, [rax + MOB.width]
    mulsd xmm0, [rel c_half]
    cvtss2sd xmm1, [rax + MOB.height]
    test dword [rbx + EntT.flags], EF_BABY
    jz .done
    mulsd xmm0, [rel c_baby_scale]
    mulsd xmm1, [rel c_baby_scale]
.done:
    ret

; ents_reset — no animals (a new world)
PROC ents_reset, 0, rdi
    lea rdi, [rel g_ents]
    xor eax, eax
    mov ecx, MAX_ENTITIES * EntT_size / 8
    rep stosq
    mov dword [rel g_ent_count], 0
    mov dword [rel g_ent_awake], 0
    mov dword [rel g_ent_sent], 0
    mov dword [rel g_hint], 0
    call behave_reset
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ent_new — a new animal.
;   in:  ecx = variant, edx = EF_BABY or 0, r8 = f64[3] feet centre
;   out: eax = id, -1 if the table is full or its region can't be held
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ent_new, 16, rbx, rsi, rdi, r12, r13
    mov esi, ecx
    mov edi, edx
    mov r12, r8
    ; its region first
    movsd xmm0, [r12]
    movsd xmm1, [r12 + 16]
    call store_region_of
    test eax, eax
    js .fail
    mov r13d, eax
    ; a free slot
    mov ecx, [rel g_hint]
    xor edx, edx
.find:
    cmp edx, MAX_ENTITIES
    jae .fail
    mov eax, ecx
    imul rax, rax, EntT_size
    lea rbx, [rel g_ents]
    add rbx, rax
    test dword [rbx + EntT.flags], EF_ACTIVE
    jz .found
    inc ecx
    and ecx, MAX_ENTITIES - 1
    inc edx
    jmp .find
.found:
    mov [LOCAL(0)], ecx
    lea eax, [rcx + 1]
    and eax, MAX_ENTITIES - 1
    mov [rel g_hint], eax
    xor eax, eax
    xor ecx, ecx
.clear:
    mov [rbx + rcx], rax
    add ecx, 8
    cmp ecx, EntT_size
    jb .clear
    mov rax, [r12]
    mov [rbx + EntT.pos], rax
    mov [rbx + EntT.goal], rax
    mov rax, [r12 + 8]
    mov [rbx + EntT.pos + 8], rax
    mov rax, [r12 + 16]
    mov [rbx + EntT.pos + 16], rax
    mov [rbx + EntT.goal + 8], rax
    mov [rbx + EntT.variant], si
    imul eax, esi, VARIANT_size
    lea rcx, [rel g_variants]
    mov eax, [rcx + rax + VARIANT.mob]
    mov [rbx + EntT.mob], ax
    imul eax, eax, MOB_size
    lea rcx, [rel g_mobs]
    mov eax, [rcx + rax + MOB.health]
    mov [rbx + EntT.health], ax
    mov [rbx + EntT.region], r13w
    mov dword [rbx + EntT.target], -1
    and edi, EF_BABY
    or edi, EF_ACTIVE | EF_DIRTY
    mov [rbx + EntT.flags], edi
    ; a random heading, a short rest first
    call rand01
    cvtsd2ss xmm0, xmm0
    mulss xmm0, [rel c_two_pi]
    movss [rbx + EntT.yaw], xmm0
    mov ecx, 60
    call rand_below
    add eax, 20
    mov [rbx + EntT.timer], ax
    mov byte [rbx + EntT.state], AI_IDLE
    inc dword [rel g_ent_count]
    imul eax, r13d, EREG_size
    lea rcx, [rel g_eregs]
    inc dword [rcx + rax + EREG.count]
    mov eax, [LOCAL(0)]
    RETURN
.fail:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ent_remove — an animal is gone; the client forgets it.
;   in:  ecx = id     clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ent_remove, 0, rbx, rsi
    mov esi, ecx
    imul rax, rsi, EntT_size
    lea rbx, [rel g_ents]
    add rbx, rax
    test dword [rbx + EntT.flags], EF_ACTIVE
    jz .done
    test dword [rbx + EntT.flags], EF_SENT
    jz .unsent
    call send_gone
.unsent:
    movzx eax, word [rbx + EntT.region]
    imul eax, eax, EREG_size
    lea rcx, [rel g_eregs]
    dec dword [rcx + rax + EREG.count]
    mov dword [rbx + EntT.flags], 0
    dec dword [rel g_ent_count]
.done:
    RETURN
ENDPROC

; send — PKT_S_ENTITY for entity rbx (id esi)   clobbers: volatile
PROC send, 0
    mov rax, [rbx + EntT.pos]
    mov [rel g_out + ENT_PKT.pos], rax
    mov rax, [rbx + EntT.pos + 8]
    mov [rel g_out + ENT_PKT.pos + 8], rax
    mov rax, [rbx + EntT.pos + 16]
    mov [rel g_out + ENT_PKT.pos + 16], rax
    mov [rel g_out + ENT_PKT.id], esi
    mov eax, [rbx + EntT.yaw]
    mov [rel g_out + ENT_PKT.yaw], eax
    mov eax, [rbx + EntT.head_yaw]
    mov [rel g_out + ENT_PKT.head_yaw], eax
    mov eax, [rbx + EntT.head_pitch]
    mov [rel g_out + ENT_PKT.head_pitch], eax
    mov ax, [rbx + EntT.variant]
    mov [rel g_out + ENT_PKT.variant], ax
    xor eax, eax
    mov ecx, [rbx + EntT.flags]
    test ecx, EF_BABY
    jz .not_baby
    or eax, EPF_BABY
.not_baby:
    cmp word [rbx + EntT.hurt], 0
    je .not_hurt
    or eax, EPF_HURT
.not_hurt:
    test ecx, EF_DYING
    jz .not_dying
    or eax, EPF_DYING | EPF_HURT
.not_dying:
    test ecx, EF_WATER
    jz .not_water
    or eax, EPF_WATER
.not_water:
    test ecx, EF_SLEEP
    jz .not_asleep
    or eax, EPF_SLEEP
.not_asleep:
    cmp word [rbx + EntT.love], 0
    je .not_love
    or eax, EPF_LOVE
.not_love:
    mov [rel g_out + ENT_PKT.flags], ax
    test ecx, EF_SENT
    jnz .known
    or dword [rbx + EntT.flags], EF_SENT
    inc dword [rel g_ent_sent]
.known:
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_ENTITY, r8, ENT_PKT_size
    RETURN
ENDPROC

; send_gone — PKT_S_ENTITY_GONE for entity rbx (id esi)   clobbers: volatile
PROC send_gone, 0
    and dword [rbx + EntT.flags], ~EF_SENT
    dec dword [rel g_ent_sent]
    mov [rel g_out + ENT_PKT.id], esi
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_ENTITY_GONE, r8, ENT_PKT_size
    RETURN
ENDPROC

; block_at — eax = block id at the f64 point (xmm0, xmm1, xmm2), -1 if not
; generated   clobbers: volatile registers
PROC block_at, 0
    roundsd xmm0, xmm0, 9
    cvttsd2si ecx, xmm0
    roundsd xmm1, xmm1, 9
    cvttsd2si edx, xmm1
    roundsd xmm2, xmm2, 9
    cvttsd2si r8d, xmm2
    call phys_block
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; body — move entity rbx by its velocity against the blocks; sets
; EF_GROUND, EF_WATER, EF_BUMPED and stops the velocity on blocked axes.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC body, 16, rsi
    call size_of
    movsd [LOCAL(0)], xmm0              ; half width
    movsd xmm2, [rbx + EntT.pos]
    movsd xmm3, xmm2
    subsd xmm2, xmm0
    addsd xmm3, xmm0
    movsd [rel g_box + AABB_MINX], xmm2
    movsd [rel g_box + AABB_MAXX], xmm3
    movsd xmm2, [rbx + EntT.pos + 16]
    movsd xmm3, xmm2
    subsd xmm2, xmm0
    addsd xmm3, xmm0
    movsd [rel g_box + AABB_MINZ], xmm2
    movsd [rel g_box + AABB_MAXZ], xmm3
    movsd xmm2, [rbx + EntT.pos + 8]
    movsd [rel g_box + AABB_MINY], xmm2
    addsd xmm2, xmm1
    movsd [rel g_box + AABB_MAXY], xmm2
    ; the region the move can touch
    xor ecx, ecx
.region:
    movsd xmm0, [rbx + EntT.vel + rcx * 8]
    lea rax, [rel g_move]
    movsd [rax + rcx * 8], xmm0
    andpd xmm0, [rel c_abs_d]
    addsd xmm0, [rel c_margin]
    lea rax, [rel g_box]
    movsd xmm1, [rax + rcx * 8]
    subsd xmm1, xmm0
    lea rax, [rel g_region]
    movsd [rax + rcx * 8], xmm1
    lea rax, [rel g_box + 24]
    movsd xmm1, [rax + rcx * 8]
    addsd xmm1, xmm0
    lea rax, [rel g_region + 24]
    movsd [rax + rcx * 8], xmm1
    inc ecx
    cmp ecx, 3
    jb .region
    lea rcx, [rel g_region]
    call phys_gather
    ; y, then x, then z
    and dword [rbx + EntT.flags], ~(EF_GROUND | EF_BUMPED | EF_WATER)
    mov esi, 1
.axis:
    lea rax, [rel g_move]
    movsd xmm0, [rax + rsi * 8]
    lea rcx, [rel g_box]
    mov edx, esi
    call phys_clip
    lea rax, [rel g_res]
    movsd [rax + rsi * 8], xmm0
    lea rax, [rel g_box]
    movsd xmm1, [rax + rsi * 8]
    addsd xmm1, xmm0
    movsd [rax + rsi * 8], xmm1
    lea rax, [rel g_box + 24]
    movsd xmm1, [rax + rsi * 8]
    addsd xmm1, xmm0
    movsd [rax + rsi * 8], xmm1
    lea rax, [rel g_move]
    comisd xmm0, [rax + rsi * 8]
    je .free
    ; blocked on this axis
    xorps xmm1, xmm1
    lea rax, [rbx + EntT.vel]
    cmp esi, 1
    jne .side
    comisd xmm1, [rel g_move + 8]
    jbe .stop                           ; (moving up: a ceiling)
    or dword [rbx + EntT.flags], EF_GROUND
    jmp .stop
.side:
    or dword [rbx + EntT.flags], EF_BUMPED
.stop:
    movsd [rax + rsi * 8], xmm1
.free:
    ; next axis: 1 -> 0 -> 2
    cmp esi, 1
    jne .not_y
    xor esi, esi
    jmp .axis
.not_y:
    test esi, esi
    jnz .moved
    mov esi, 2
    jmp .axis
.moved:
    ; the feet centre
    movsd xmm0, [rel g_box + AABB_MINX]
    addsd xmm0, [rel g_box + AABB_MAXX]
    mulsd xmm0, [rel c_half]
    movsd [rbx + EntT.pos], xmm0
    movsd xmm0, [rel g_box + AABB_MINZ]
    addsd xmm0, [rel g_box + AABB_MAXZ]
    mulsd xmm0, [rel c_half]
    movsd [rbx + EntT.pos + 16], xmm0
    movsd xmm0, [rel g_box + AABB_MINY]
    movsd [rbx + EntT.pos + 8], xmm0
    ; in water: the lower half of the body
    lea rsi, [rel g_lower]
    lea rdx, [rel g_box]
    mov ecx, 6
.copy:
    mov rax, [rdx + rcx * 8 - 8]
    mov [rsi + rcx * 8 - 8], rax
    loop .copy
    movsd xmm0, [rel g_box + AABB_MAXY]
    subsd xmm0, [rel g_box + AABB_MINY]
    mulsd xmm0, [rel c_lower]
    addsd xmm0, [rel g_box + AABB_MINY]
    movsd [rel g_lower + AABB_MAXY], xmm0
    lea rcx, [rel g_lower]
    call phys_touch
    test eax, MOVE_WATER | MOVE_LAVA
    jz .done
    or dword [rbx + EntT.flags], EF_WATER
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; die — entity rbx (id esi) drops its loot and is gone.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC die, 32, rdi, r12
    test dword [rbx + EntT.flags], EF_BABY
    jnz .gone                           ; (babies drop nothing)
    call mob_of
    mov r12, rax
    mov rax, [rbx + EntT.pos]
    mov [LOCAL(0)], rax
    movsd xmm0, [rbx + EntT.pos + 8]
    addsd xmm0, [rel c_half]
    movsd [LOCAL(8)], xmm0
    mov rax, [rbx + EntT.pos + 16]
    mov [LOCAL(16)], rax
    xor edi, edi
.drop:
    cmp edi, [r12 + MOB.drops]
    jae .gone
    movzx ecx, byte [r12 + MOB.drop_max + rdi]
    movzx eax, byte [r12 + MOB.drop_min + rdi]
    sub ecx, eax
    inc ecx
    call rand_below
    movzx ecx, byte [r12 + MOB.drop_min + rdi]
    add eax, ecx
    test eax, eax
    jz .next
    mov edx, eax
    movzx ecx, word [r12 + MOB.drop_item + rdi * 2]
    lea r8, [LOCAL(0)]
    call drops_spawn
.next:
    inc edi
    jmp .drop
.gone:
    mov ecx, esi
    call ent_remove
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ents_attack — the player hit an animal: damage, knock-back, it runs.
;   in:  rcx = ENT_PKT* (.id)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ents_attack, 0, rbx, rsi
    mov esi, [rcx + ENT_PKT.id]
    cmp esi, MAX_ENTITIES
    jae .done
    imul rax, rsi, EntT_size
    lea rbx, [rel g_ents]
    add rbx, rax
    mov eax, [rbx + EntT.flags]
    and eax, EF_ACTIVE | EF_AWAKE | EF_DYING
    cmp eax, EF_ACTIVE | EF_AWAKE
    jne .done
    cmp word [rbx + EntT.hurt], 0
    jne .done                           ; (just hit)
    ; within reach of the eyes (the reach plus a little: aimed at its body)
    movsd xmm0, [rbx + EntT.pos]
    subsd xmm0, [rel g_pl_pos]
    movsd xmm1, [rbx + EntT.pos + 16]
    subsd xmm1, [rel g_pl_pos + 16]
    movsd xmm2, xmm0
    mulsd xmm2, xmm0
    movsd xmm3, xmm1
    mulsd xmm3, xmm1
    addsd xmm2, xmm3
    cvtss2sd xmm3, [rel g_pl_reach]
    addsd xmm3, [rel c_reach_extra]
    mulsd xmm3, xmm3
    comisd xmm2, xmm3
    ja .done
    sqrtsd xmm2, xmm2
    addsd xmm2, [rel c_tiny]
    ; knock-back away from the player
    divsd xmm0, xmm2
    divsd xmm1, xmm2
    mulsd xmm0, [rel c_knock]
    mulsd xmm1, [rel c_knock]
    movsd [rbx + EntT.vel], xmm0
    movsd [rbx + EntT.vel + 16], xmm1
    movsd xmm0, [rel c_knock_up]
    movsd [rbx + EntT.vel + 8], xmm0
    mov word [rbx + EntT.hurt], HURT_TICKS
    or dword [rbx + EntT.flags], EF_DIRTY
    dec word [rbx + EntT.health]
    jg .alive
    or dword [rbx + EntT.flags], EF_DYING
    mov byte [rbx + EntT.death], 0
    jmp .done
.alive:
    call behave_hurt                    ; it and its herd run
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ents_tick — every animal: awake or not, think, move, die, tell the client.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define T_START     0
%define T_DX        8
%define T_DZ        16
%define T_D2        24
%define T_OLD       32                  ; 24 bytes: the position before
%define T_YAW       56
PROC ents_tick, 64, rbx, rsi, rdi
    call timer_elapsed_us
    mov [LOCAL(T_START)], rax
    call behave_tick                    ; herd centres, regrowing grass
    mov dword [rel g_ent_awake], 0
    cmp dword [rel g_ent_count], 0
    je .stats
    lea rbx, [rel g_ents]
    xor esi, esi
.ent:
    cmp esi, MAX_ENTITIES
    jae .stats
    mov edi, [rbx + EntT.flags]
    test edi, EF_ACTIVE
    jz .next
    ; ---- awake: near the player, on generated ground ----
    movsd xmm0, [rbx + EntT.pos]
    subsd xmm0, [rel g_pl_pos]
    movsd [LOCAL(T_DX)], xmm0
    movsd xmm1, [rbx + EntT.pos + 16]
    subsd xmm1, [rel g_pl_pos + 16]
    movsd [LOCAL(T_DZ)], xmm1
    mulsd xmm0, xmm0
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    movsd [LOCAL(T_D2)], xmm0
    comisd xmm0, [rel c_sim_r2]
    ja .asleep
    movsd xmm0, [rbx + EntT.pos]
    movsd xmm1, [rbx + EntT.pos + 8]
    movsd xmm2, [rbx + EntT.pos + 16]
    call block_at
    cmp eax, -1
    je .asleep
    or dword [rbx + EntT.flags], EF_AWAKE
    inc dword [rel g_ent_awake]
    inc dword [rbx + EntT.age]
    mov rax, [rbx + EntT.pos]
    mov [LOCAL(T_OLD)], rax
    mov rax, [rbx + EntT.pos + 8]
    mov [LOCAL(T_OLD + 8)], rax
    mov rax, [rbx + EntT.pos + 16]
    mov [LOCAL(T_OLD + 16)], rax
    mov eax, [rbx + EntT.yaw]
    mov [LOCAL(T_YAW)], eax
    mov eax, [rbx + EntT.head_yaw]
    xor eax, [rbx + EntT.head_pitch]
    mov [LOCAL(T_YAW + 4)], eax
    ; ---- red flash; dying ----
    cmp word [rbx + EntT.hurt], 0
    je .hurt_done
    dec word [rbx + EntT.hurt]
    jnz .hurt_done
    or dword [rbx + EntT.flags], EF_DIRTY   ; (the flash ends)
.hurt_done:
    test dword [rbx + EntT.flags], EF_DYING
    jz .living
    inc byte [rbx + EntT.death]
    cmp byte [rbx + EntT.death], DEATH_TICKS
    jb .fall
    call die
    jmp .next
.living:
    movsd xmm0, [LOCAL(T_DX)]
    movsd xmm1, [LOCAL(T_DZ)]
    movsd xmm2, [LOCAL(T_D2)]
    call behave                         ; (behave.asm, part 2)
.fall:
    ; ---- gravity, water, the move ----
    movsd xmm0, [rbx + EntT.vel + 8]
    test dword [rbx + EntT.flags], EF_WATER
    jz .gravity
    addsd xmm0, [rel c_swim_up]         ; floats up (swims at the surface)
    minsd xmm0, [rel c_swim_max]
    mulsd xmm0, [rel c_drag_y]
    jmp .vy
.gravity:
    subsd xmm0, [rel c_gravity]
    mulsd xmm0, [rel c_drag_y]
.vy:
    movsd [rbx + EntT.vel + 8], xmm0
    test dword [rbx + EntT.flags], EF_DYING
    jz .move
    ; (dying: no walking)
    xorps xmm0, xmm0
    movsd [rbx + EntT.vel], xmm0
    movsd [rbx + EntT.vel + 16], xmm0
.move:
    call body
    call region_follow
    ; ---- changed? tell the client ----
    mov eax, [rbx + EntT.yaw]
    cmp eax, [LOCAL(T_YAW)]
    jne .dirty
    mov eax, [rbx + EntT.head_yaw]
    xor eax, [rbx + EntT.head_pitch]
    cmp eax, [LOCAL(T_YAW + 4)]
    jne .dirty
    mov rax, [rbx + EntT.pos]
    cmp rax, [LOCAL(T_OLD)]
    jne .dirty
    mov rax, [rbx + EntT.pos + 8]
    cmp rax, [LOCAL(T_OLD + 8)]
    jne .dirty
    mov rax, [rbx + EntT.pos + 16]
    cmp rax, [LOCAL(T_OLD + 16)]
    jne .dirty
    jmp .send
.dirty:
    or dword [rbx + EntT.flags], EF_DIRTY
.send:
    mov eax, [rbx + EntT.flags]
    test eax, EF_SENT
    jz .send_now
    test eax, EF_DIRTY
    jz .next
.send_now:
    and dword [rbx + EntT.flags], ~EF_DIRTY
    call send
    jmp .next
.asleep:
    and dword [rbx + EntT.flags], ~EF_AWAKE
    test dword [rbx + EntT.flags], EF_SENT
    jz .next
    call send_gone
.next:
    add rbx, EntT_size
    inc esi
    jmp .ent
.stats:
    call timer_elapsed_us
    sub rax, [LOCAL(T_START)]
    mov [rel g_ent_tick_us], rax
    RETURN
ENDPROC

; region_follow — entity rbx moved into another entity region?
;   clobbers: volatile registers
PROC region_follow, 0, rsi
    movzx esi, word [rbx + EntT.region]
    imul eax, esi, EREG_size
    lea rcx, [rel g_eregs]
    add rcx, rax
    movsd xmm0, [rbx + EntT.pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, EREGION_SHIFT
    cmp eax, [rcx + EREG.rx]
    jne .moved
    movsd xmm0, [rbx + EntT.pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, EREGION_SHIFT
    cmp eax, [rcx + EREG.rz]
    je .done
.moved:
    movsd xmm0, [rbx + EntT.pos]
    movsd xmm1, [rbx + EntT.pos + 16]
    call store_region_of
    test eax, eax
    js .done                            ; (no room: stays counted where it was)
    imul ecx, esi, EREG_size
    lea rdx, [rel g_eregs]
    dec dword [rdx + rcx + EREG.count]
    mov [rbx + EntT.region], ax
    imul ecx, eax, EREG_size
    inc dword [rdx + rcx + EREG.count]
.done:
    RETURN
ENDPROC

section .rdata
align 16
c_sign_d:       dq 0x8000000000000000, 0
c_tiny:         dq 0.000001
