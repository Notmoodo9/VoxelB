; =============================================================================
; behave.asm — how animals behave (milestone 19 part 2,
; design/mobs/passive_animals.md, DECISIONS D99).
;
; Every awake animal decides each tick, in this order:
;   1. hurt: runs from the player for 5 s (its whole herd within 16 blocks
;      runs too); wild animals also run from a player within 12 blocks;
;   2. night: it walks back to its herd and lies down until morning (a hit
;      wakes it);
;   3. fed (in love): it goes to another fed adult of its kind within 12
;      blocks; when they meet, a baby of one of their looks appears between
;      them, and both rest 5 minutes before they can breed again;
;   4. a player within 10 blocks holding its food: it follows, stopping 2.5
;      blocks away and looking up at the player;
;   5. a baby keeps within 5 blocks of a grown-up of its herd;
;   (part 3) a fierce animal (boar) that is hit charges the player instead
;      of running: for up to 6 s it runs at them and, reaching them,
;      knocks them back, then backs off; its herd stays;
;   6. otherwise: stands and looks around, wanders a few blocks (back
;      towards its herd when it strayed more than 8 blocks), or grazes: the
;      grass under it turns to dirt, which grows back in 1–3 minutes; a
;      shorn animal's coat grows back when it grazes.
; Part 3: shears (the mob's `shear` tool) take a coat (1–3 of the
; variant's coat item) from an adult; layers (`lays`) drop their item every
; few minutes.
; Movement goes along A* paths (pathfind.asm), worked out again now and
; then for moving targets; at most PATHS_PER_TICK paths per tick (the rest
; wait a tick). Babies grow up in 20 minutes; feeding one takes 2 off.
; Herd centres are worked out once a second.
;
; Public API (include/entity.inc):
;   behave_reset()                      a new world
;   behave_tick()                       once per tick before the animals
;   behave(rbx = EntT*, esi = id, xmm0 = dx, xmm1 = dz, xmm2 = distance^2
;          from the player) — decide, set its velocity, turn its head
;   behave_hurt(rbx = EntT*)            it was hit: it and its herd run
;   behave_interact(rcx = ENT_PKT*)     the player used the item in hand on it
;   g_herd_count, g_regrow_count        statistics (overlay)
; =============================================================================
%define BEHAVE_IMPL
%include "macros.inc"
%include "log.inc"
%include "packet.inc"
%include "physics.inc"
%include "mobs.inc"
%include "entity.inc"
%include "items.inc"
%include "block.inc"
%include "world.inc"

global behave_reset, behave_tick, behave, behave_hurt, behave_interact
global lead_tie, lead_drop, g_lead_item, g_give_name, g_lead_test
global behave_name
global g_herd_count, g_regrow_count, g_breed_test, g_mob_gallery, g_gallery_name

extern path_find, g_pf_start, g_pf_goal, g_pf_height, g_pf_out, g_pf_climb, g_pf_fall
extern phys_block, inv_turn_slot, g_block_eat
extern atan2f, edit_apply, block_find, inv_used_selected, inv_wear_selected
extern drops_spawn, ent_new, str_ieq, inv_mark, survival_damage
extern g_pl_pos, g_pl_vel, g_pl_reach, g_inv, g_inv_sel, g_sim_time

%define PATHS_PER_TICK  3
%define FLEE_TICKS      100
%define MAX_HERDS       512             ; power of two (hash)
%define MAX_REGROW      512
%define HERD_EVERY      20
%define CHARGE_TICKS    120             ; a fierce animal gives up after 6 s
%define BACK_OFF_TICKS  30              ; after ramming: backs off 1.5 s

section .rdata
str_grass:      db "grass_block", 0
str_dirt:       db "dirt", 0
str_lead:       db "lead", 0
str_name_tag:   db "name_tag", 0
str_test_fence: db "oak_fence", 0
str_led:        db "entities: --lead-test put animals on the lead: ", 0
str_fed:        db "entities: --breed-test fed the grown-ups nearby: ", 0
str_gallery:    db "entities: --mob-gallery placed every look: ", 0
align 8
c_per_tick:     dq 0.05
c_flee_mul:     dq 2.2
c_follow_mul:   dq 1.2
c_half:         dq 0.5
c_one:          dq 1.0
c_wild2:        dq 144.0
c_follow2:      dq 100.0                ; a player holding food within 10 blocks
c_stop2:        dq 6.25                 ; stops 2.5 blocks away
c_look2:        dq 36.0
c_mate2:        dq 144.0                ; mates within 12 blocks
c_meet2:        dq 2.89                 ; (1.7 blocks)^2: a baby
c_baby2:        dq 25.0                 ; babies within 5 blocks of a grown-up
c_herd2:        dq 64.0                 ; strays more than 8 blocks: back
c_gather2:      dq 25.0                 ; at night: within 5 blocks of the herd
c_flock2:       dq 256.0                ; a hurt animal's herd within 16 blocks runs
c_wander_r:     dq 7.0
c_flee_dist:    dq 10.0
c_arrive2:      dq 0.16                 ; at a waypoint: within 0.4 blocks
c_reach_extra:  dq 1.5
c_u32:          dq 0.00000000023283064365386963 ; 2^-32
c_tiny:         dq 0.000001
c_acc_ground:   dq 0.3
c_acc_air:      dq 0.05
c_acc_water:    dq 0.15
c_jump:         dq 0.42
c_moving2:      dq 0.0004
c_eye_lift:     dq -0.4
c_night_end:    dq 0.23                 ; sleeps before 5:30 ...
c_night_start:  dq 0.79                 ; ... and after 19:00
c_gallery_young: dq 2.0
c_gallery_z:    dq 3.0
c_gallery_per:  dq 0.55
c_charge_mul:   dq 2.4                  ; charging: faster than running away
c_ram2:         dq 1.96                 ; (1.4 blocks)^2: it reaches the player
c_ram_dy:       dq 1.6
c_ram_push:     dq 9.0                  ; the player flies off (blocks per second)
c_ram_up:       dq 5.5
c_lay_up:       dq 0.3
c_shear_up:     dq 0.8
c_hop:          dq 0.3                  ; a rabbit's hop (blocks per tick)
c_eat2:         dq 1.0                  ; (1 block)^2: at the food
c_hundred:      dq 100.0
c_test_step:    dq 6.0                  ; --lead-test: the player's steps
c_snap2:        dq 100.0                ; a lead snaps beyond 10 blocks
c_pull2:        dq 36.0                 ; ... and pulls beyond 6
c_pull_d:       dq 6.0
c_pull_k:       dq 0.6                  ; extra pull per block beyond 6
c_led2:         dq 9.0                  ; a led animal stops 3 blocks from the player
c_tied2:        dq 2.25                 ; ... 1.5 blocks from its fence post
c_lift:         dq 0.6                  ; the holder this much higher: it hops up
align 4
c_turn:         dd 0.25
c_head_turn:    dd 0.2
c_two_pi:       dd 6.28318531
c_pi_f:         dd 3.14159265
c_head_max:     dd 1.2
c_pitch_max:    dd 0.7
c_look_far:     dd 0.9
c_graze_pitch:  dd -0.95
c_sleep_pitch:  dd -0.35
c_progress:     dd 0.02
align 16
c_neg_f:        dd 0x80000000, 0, 0, 0
c_sign_d:       dq 0x8000000000000000, 0
c_abs_d:        dq 0x7FFFFFFFFFFFFFFF, 0

section .bss
alignb 8
g_herd_id:      resd MAX_HERDS
g_herd_n:       resd MAX_HERDS
g_herd_x:       resq MAX_HERDS          ; sums, then centres
g_herd_z:       resq MAX_HERDS
g_regrow:       resd MAX_REGROW * 4     ; x, y, z, due tick
g_herd_count:   resd 1
g_breed_test:   resd 1                  ; --breed-test
g_mob_gallery:  resd 1                  ; --mob-gallery
g_gallery_name: resb 32                 ; --mob-gallery <animal> (empty: all)
g_give_name:    resb 32                 ; --give <item>: into the hand (tests)
g_lead_test:    resd 1                  ; --lead-test
g_test_pkt:     resb BLOCK_PKT_size
g_regrow_count: resd 1
g_btick:        resd 1
g_rand:         resd 1
g_budget:       resd 1                  ; paths left this tick
g_grass:        resd 1                  ; block ids
g_dirt:         resd 1
g_lead_item:    resd 1                  ; the lead (part 3b; 0: none in the data)
g_tag_item:     resd 1                  ; the name tag (part 3b; 0: none)
g_knot:         resd 3                  ; lead_tie: the fence post
alignb 8
g_wx:           resq 1                  ; the wanted velocity this tick
g_wz:           resq 1
g_speed:        resq 1
g_dx:           resq 1                  ; to the player (entity - player)
g_dz:           resq 1
g_d2:           resq 1
g_tx:           resq 1                  ; a target point
g_tz:           resq 1
g_ty:           resd 1
alignb 8
g_spot:         resq 3                  ; where an egg or wool drops

section .text

; rand — eax = a random u32 (xorshift)   clobbers: rax, rcx
rand:
    mov eax, [rel g_rand]
    test eax, eax
    jnz .go
    mov eax, 0x6C8E9CF5
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

; turn — xmm0 towards xmm1 by at most xmm2   out: xmm0   clobbers: xmm0-xmm3
turn:
    movss xmm3, xmm0
    movss xmm0, xmm1
    subss xmm0, xmm3
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

; ent_of — rax = EntT* of id ecx   clobbers: rax
ent_of:
    mov eax, ecx
    imul rax, rax, EntT_size
    push rcx
    lea rcx, [rel g_ents]
    add rax, rcx
    pop rcx
    ret

; -----------------------------------------------------------------------------
; behave_reset — a new world: no herds, nothing to regrow; block ids
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC behave_reset, 0
    xor eax, eax
    mov [rel g_herd_count], eax
    mov [rel g_regrow_count], eax
    mov [rel g_btick], eax
    lea rcx, [rel str_grass]
    call block_find
    mov [rel g_grass], eax
    lea rcx, [rel str_dirt]
    call block_find
    mov [rel g_dirt], eax
    lea rcx, [rel str_lead]
    call item_find
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    mov [rel g_lead_item], eax
    lea rcx, [rel str_name_tag]
    call item_find
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    mov [rel g_tag_item], eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gallery — --mob-gallery: one animal of every look (or of the named
; animal's looks) in a row north of the player (2 blocks apart; 3 blocks
; away and half a block more per animal), at
; the player's height (they drop to the ground), turned to the player and
; resting a while (screenshots, tests); each with its young 2 blocks nearer,
; and a male where the animal has sexes.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gallery, 32, rbx, rsi, rdi
    ; how many
    xor esi, esi
    xor edi, edi
.count:
    cmp esi, [rel g_variant_count]
    jae .counted
    mov ecx, esi
    call gallery_wants
    add edi, eax
    inc esi
    jmp .count
.counted:
    ; the row: nearer for a few, further for many
    cvtsi2sd xmm0, edi
    mulsd xmm0, [rel c_gallery_per]
    addsd xmm0, [rel c_gallery_z]
    movsd [LOCAL(24)], xmm0
    shr edi, 1
    neg edi                             ; (the row's first place)
    xor esi, esi
    xor ebx, ebx                        ; placed
.v:
    cmp esi, [rel g_variant_count]
    jae .done
    mov ecx, esi
    call gallery_wants
    test eax, eax
    jz .next
    lea ecx, [rdi + rbx]
    inc ebx
    add ecx, ecx
    cvtsi2sd xmm0, ecx
    addsd xmm0, [rel g_pl_pos]
    movsd [LOCAL(0)], xmm0
    mov rax, [rel g_pl_pos + 8]
    mov [LOCAL(8)], rax
    movsd xmm0, [rel g_pl_pos + 16]
    subsd xmm0, [LOCAL(24)]
    movsd [LOCAL(16)], xmm0
    mov ecx, esi
    xor edx, edx
    lea r8, [LOCAL(0)]
    call ent_new
    test eax, eax
    js .next
    mov ecx, eax
    call ent_of
    mov ecx, [rel c_pi_f]
    mov [rax + EntT.yaw], ecx
    mov word [rax + EntT.timer], 400
    ; an animal with sexes shows its male look (antlers)
    movzx ecx, word [rax + EntT.variant]
    imul ecx, ecx, VARIANT_size
    lea rdx, [rel g_variants]
    mov ecx, [rdx + rcx + VARIANT.mob]
    imul ecx, ecx, MOB_size
    lea rdx, [rel g_mobs]
    cmp dword [rdx + rcx + MOB.sexes], 0
    je .young
    or dword [rax + EntT.flags], EF_MALE | EF_DIRTY
.young:
    ; and its young, a step nearer
    movsd xmm0, [LOCAL(16)]
    addsd xmm0, [rel c_gallery_young]
    movsd [LOCAL(16)], xmm0
    mov ecx, esi
    mov edx, EF_BABY
    lea r8, [LOCAL(0)]
    call ent_new
    test eax, eax
    js .next
    mov ecx, eax
    call ent_of
    mov ecx, [rel c_pi_f]
    mov [rax + EntT.yaw], ecx
    mov word [rax + EntT.timer], 400
.next:
    inc esi
    jmp .v
.done:
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_gallery]
    call log_append_str
    mov ecx, ebx
    call log_append_dec
    call log_end
    RETURN
ENDPROC

; gallery_wants — eax = 1 if variant ecx is in the gallery (its animal's or
; its own name is the one asked for)   clobbers: volatile
PROC gallery_wants, 0, rbx
    mov eax, 1
    cmp byte [rel g_gallery_name], 0
    je .done
    imul ebx, ecx, VARIANT_size
    lea rax, [rel g_variants]
    add rbx, rax
    ; the animal's name ...
    mov eax, [rbx + VARIANT.mob]
    imul eax, eax, MOB_size
    lea rcx, [rel g_mobs]
    lea rdx, [rel g_gallery_name]
    INVOKE str_ieq, [rcx + rax + MOB.name], rdx
    test eax, eax
    jnz .yes
    ; ... or the look's
    lea rdx, [rel g_gallery_name]
    INVOKE str_ieq, [rbx + VARIANT.name], rdx
    test eax, eax
    jz .done
.yes:
    mov eax, 1
.done:
    RETURN
ENDPROC

; herd_slot — eax = the hash slot of herd id ecx (inserted if new), -1 full
;   clobbers: rax, rdx, r8
herd_slot:
    mov eax, ecx
    imul eax, eax, 0x9E3779B1
    shr eax, 23                         ; 9 bits
    lea r8, [rel g_herd_id]
    mov edx, MAX_HERDS
.probe:
    cmp [r8 + rax * 4], ecx
    je .found
    cmp dword [r8 + rax * 4], 0
    je .new
    inc eax
    and eax, MAX_HERDS - 1
    dec edx
    jnz .probe
    mov eax, -1
    ret
.new:
    mov [r8 + rax * 4], ecx
.found:
    ret

; -----------------------------------------------------------------------------
; behave_tick — once per tick: path budget; herd centres every second;
; dirt that grows back.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC behave_tick, 0, rbx, rsi, rdi
    inc dword [rel g_btick]
    mov dword [rel g_budget], PATHS_PER_TICK
    ; --breed-test: 5 s in, every awake grown-up is fed
    cmp dword [rel g_breed_test], 0
    je .no_test
    cmp dword [rel g_btick], 100
    jne .no_test
    lea rbx, [rel g_ents]
    mov ecx, MAX_ENTITIES
    xor esi, esi
.feed:
    mov eax, [rbx + EntT.flags]
    and eax, EF_ACTIVE | EF_AWAKE | EF_DYING | EF_BABY
    cmp eax, EF_ACTIVE | EF_AWAKE
    jne .feed_next
    mov word [rbx + EntT.love], LOVE_TICKS
    or dword [rbx + EntT.flags], EF_DIRTY
    inc esi
.feed_next:
    add rbx, EntT_size
    dec ecx
    jnz .feed
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_fed]
    call log_append_str
    mov ecx, esi
    call log_append_dec
    call log_end
.no_test:
    cmp dword [rel g_mob_gallery], 0
    je .no_gallery
    cmp dword [rel g_btick], 60
    jne .no_gallery
    call gallery
.no_gallery:
    ; --give <item>: 16 of it into the hand, once (tests)
    cmp byte [rel g_give_name], 0
    je .no_give
    cmp dword [rel g_btick], 40
    jne .no_give
    lea rcx, [rel g_give_name]
    call item_find
    cmp eax, 0
    jle .no_give
    mov ecx, [rel g_inv_sel]
    lea rdx, [rel g_inv]
    mov [rdx + rcx * 8], ax
    mov word [rdx + rcx * 8 + 2], 16
    mov word [rdx + rcx * 8 + 4], 0
    call inv_mark
.no_give:
    ; --lead-test: 4 s in, the animals within 8 blocks go on the player's
    ; lead; 15 s in, a fence post 2 blocks east of the player and they are
    ; tied to it (tests: pulling, snapping, the rope, knots)
    cmp dword [rel g_lead_test], 0
    je .no_lead_test
    cmp dword [rel g_btick], 80
    jne .no_leash_all
    lea rbx, [rel g_ents]
    mov ecx, MAX_ENTITIES
    xor esi, esi
.leash_all:
    mov eax, [rbx + EntT.flags]
    and eax, EF_ACTIVE | EF_AWAKE | EF_DYING
    cmp eax, EF_ACTIVE | EF_AWAKE
    jne .leash_next
    movsd xmm0, [rbx + EntT.pos]
    subsd xmm0, [rel g_pl_pos]
    mulsd xmm0, xmm0
    movsd xmm1, [rbx + EntT.pos + 16]
    subsd xmm1, [rel g_pl_pos + 16]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    comisd xmm0, [rel c_herd2]
    jae .leash_next
    mov dword [rbx + EntT.leash], LEASH_PLAYER
    or dword [rbx + EntT.flags], EF_DIRTY
    inc esi
.leash_next:
    add rbx, EntT_size
    dec ecx
    jnz .leash_all
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_led]
    call log_append_str
    mov ecx, esi
    call log_append_dec
    call log_end
.no_leash_all:
    ; 8 s in: the player steps 6 blocks south (the animals are pulled
    ; along); 20 s in: 12 blocks more (animals still on the player's lead
    ; snap free; those tied to the fence stay)
    cmp dword [rel g_btick], 160
    jne .no_step
    movsd xmm0, [rel g_pl_pos + 16]
    addsd xmm0, [rel c_test_step]
    movsd [rel g_pl_pos + 16], xmm0
.no_step:
    cmp dword [rel g_btick], 400
    jne .no_step2
    movsd xmm0, [rel g_pl_pos + 16]
    addsd xmm0, [rel c_test_step]
    addsd xmm0, [rel c_test_step]
    movsd [rel g_pl_pos + 16], xmm0
.no_step2:
    cmp dword [rel g_btick], 300
    jne .no_lead_test
    movsd xmm0, [rel g_pl_pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    add eax, 2
    mov [rel g_test_pkt + BLOCK_PKT.x], eax
    movsd xmm0, [rel g_pl_pos + 8]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_test_pkt + BLOCK_PKT.y], eax
    movsd xmm0, [rel g_pl_pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_test_pkt + BLOCK_PKT.z], eax
    lea rcx, [rel str_test_fence]
    call block_find
    test eax, eax
    jle .no_lead_test
    mov r9d, eax
    mov ecx, [rel g_test_pkt + BLOCK_PKT.x]
    mov edx, [rel g_test_pkt + BLOCK_PKT.y]
    mov r8d, [rel g_test_pkt + BLOCK_PKT.z]
    call edit_apply
    lea rcx, [rel g_test_pkt]
    call lead_tie
.no_lead_test:
    mov eax, [rel g_btick]
    xor edx, edx
    mov ecx, HERD_EVERY
    div ecx
    test edx, edx
    jnz .done
    ; ---- herd centres: the awake animals of each herd ----
    lea rdi, [rel g_herd_id]
    xor eax, eax
    mov ecx, MAX_HERDS * (4 + 4 + 8 + 8) / 8
    rep stosq
    lea rbx, [rel g_ents]
    xor esi, esi
.ent:
    cmp esi, MAX_ENTITIES
    jae .centres
    mov eax, [rbx + EntT.flags]
    and eax, EF_ACTIVE | EF_AWAKE | EF_DYING
    cmp eax, EF_ACTIVE | EF_AWAKE
    jne .next
    mov ecx, [rbx + EntT.herd]
    test ecx, ecx
    jz .next
    call herd_slot
    test eax, eax
    js .next
    lea rcx, [rel g_herd_n]
    inc dword [rcx + rax * 4]
    lea rcx, [rel g_herd_x]
    movsd xmm0, [rcx + rax * 8]
    addsd xmm0, [rbx + EntT.pos]
    movsd [rcx + rax * 8], xmm0
    lea rcx, [rel g_herd_z]
    movsd xmm0, [rcx + rax * 8]
    addsd xmm0, [rbx + EntT.pos + 16]
    movsd [rcx + rax * 8], xmm0
.next:
    add rbx, EntT_size
    inc esi
    jmp .ent
.centres:
    xor esi, esi
    mov dword [rel g_herd_count], 0
.centre:
    cmp esi, MAX_HERDS
    jae .regrow
    lea rcx, [rel g_herd_n]
    mov eax, [rcx + rsi * 4]
    test eax, eax
    jz .centre_next
    inc dword [rel g_herd_count]
    cvtsi2sd xmm1, eax
    lea rcx, [rel g_herd_x]
    movsd xmm0, [rcx + rsi * 8]
    divsd xmm0, xmm1
    movsd [rcx + rsi * 8], xmm0
    lea rcx, [rel g_herd_z]
    movsd xmm0, [rcx + rsi * 8]
    divsd xmm0, xmm1
    movsd [rcx + rsi * 8], xmm0
.centre_next:
    inc esi
    jmp .centre
.regrow:
    ; ---- grazed grass grows back ----
    xor esi, esi
.grow:
    cmp esi, [rel g_regrow_count]
    jae .done
    mov eax, esi
    shl eax, 4
    lea rbx, [rel g_regrow]
    add rbx, rax
    mov eax, [rel g_btick]
    cmp eax, [rbx + 12]
    jb .grow_next
    ; due: dirt (still) turns back into grass
    mov ecx, [rbx]
    mov edx, [rbx + 4]
    mov r8d, [rbx + 8]
    call phys_block
    cmp eax, [rel g_dirt]
    jne .forget
    mov ecx, [rbx]
    mov edx, [rbx + 4]
    mov r8d, [rbx + 8]
    mov r9d, [rel g_grass]
    call edit_apply
    test eax, eax
    jz .grow_next                       ; (busy column: later)
.forget:
    ; the last entry takes this place
    dec dword [rel g_regrow_count]
    mov eax, [rel g_regrow_count]
    shl eax, 4
    lea rcx, [rel g_regrow]
    mov rdx, [rcx + rax]
    mov [rbx], rdx
    mov rdx, [rcx + rax + 8]
    mov [rbx + 8], rdx
    jmp .grow                           ; (look at the moved one)
.grow_next:
    inc esi
    jmp .grow
.done:
    RETURN
ENDPROC

; herd_centre — the centre of entity rbx's herd
;   out: eax = 1 found (xmm0 = x, xmm1 = z), 0 none
;   clobbers: rax, rcx, rdx, r8, xmm0, xmm1
herd_centre:
    mov ecx, [rbx + EntT.herd]
    test ecx, ecx
    jz .none
    call herd_slot
    test eax, eax
    js .none
    lea rcx, [rel g_herd_n]
    cmp dword [rcx + rax * 4], 2
    jb .none                            ; (alone: no herd to go back to)
    lea rcx, [rel g_herd_x]
    movsd xmm0, [rcx + rax * 8]
    lea rcx, [rel g_herd_z]
    movsd xmm1, [rcx + rax * 8]
    mov eax, 1
    ret
.none:
    xor eax, eax
    ret

; dist2_to — xmm0 = horizontal distance^2 from entity rbx to (xmm0, xmm1)
;   clobbers: xmm0, xmm1
dist2_to:
    subsd xmm0, [rbx + EntT.pos]
    subsd xmm1, [rbx + EntT.pos + 16]
    mulsd xmm0, xmm0
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    ret

; is_night — eax = 1 at night (simulation clock)   clobbers: rax, xmm0
is_night:
    xor eax, eax
    movsd xmm0, [rel g_sim_time]
    comisd xmm0, [rel c_night_end]
    jb .night
    comisd xmm0, [rel c_night_start]
    ja .night
    ret
.night:
    mov eax, 1
    ret

; holds_food — eax = 1 if the player's main hand holds entity rbx's food
;   clobbers: rax, rcx, rdx, r8
holds_food:
    mov eax, [rel g_inv_sel]
    lea rcx, [rel g_inv]
    movzx edx, word [rcx + rax * 8]     ; the item
    test edx, edx
    jz .no
    call mob_of
    mov r8d, [rax + MOB.foods]
    xor ecx, ecx
.f:
    cmp ecx, r8d
    jae .no
    cmp dx, [rax + MOB.food + rcx * 2]
    je .yes
    inc ecx
    jmp .f
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; plan — a path for entity rbx (id esi) to the point (g_tx, g_ty, g_tz).
;   out: eax = waypoints (0: nowhere to go; -1: no paths left this tick)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC plan, 0
    cmp dword [rel g_budget], 0
    jle .later
    dec dword [rel g_budget]
    movsd xmm0, [rbx + EntT.pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_pf_start], eax
    movsd xmm0, [rbx + EntT.pos + 8]
    addsd xmm0, [rel c_tiny]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_pf_start + 4], eax
    movsd xmm0, [rbx + EntT.pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_pf_start + 8], eax
    movsd xmm0, [rel g_tx]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_pf_goal], eax
    mov eax, [rel g_ty]
    mov [rel g_pf_goal + 4], eax
    movsd xmm0, [rel g_tz]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_pf_goal + 8], eax
    ; the room the body needs: its height in whole blocks (at least 1)
    call mob_of
    movss xmm0, [rax + MOB.height]
    test dword [rbx + EntT.flags], EF_BABY
    jz .adult
    mulss xmm0, [rel c_half_f]
.adult:
    roundss xmm0, xmm0, 10              ; up
    cvttss2si eax, xmm0
    cmp eax, 1
    jge .h1
    mov eax, 1
.h1:
    cmp eax, 3
    jle .h2
    mov eax, 3
.h2:
    mov [rel g_pf_height], eax
    ; how far up it can jump and down it may drop (part 3b)
    call mob_of
    cvttss2si ecx, [rax + MOB.jump]
    cmp ecx, 1
    jge .c1
    mov ecx, 1
.c1:
    cmp ecx, 4
    jle .c2
    mov ecx, 4
.c2:
    mov [rel g_pf_climb], ecx
    mov ecx, [rax + MOB.fall]
    cmp ecx, 1
    jge .f1
    mov ecx, 1
.f1:
    cmp ecx, 8
    jle .f2
    mov ecx, 8
.f2:
    mov [rel g_pf_fall], ecx
    mov eax, esi
    imul rax, rax, PATH_MAX * WP_BYTES
    lea rcx, [rel g_paths]
    add rax, rcx
    mov [rel g_pf_out], rax
    call path_find
    mov [rbx + EntT.path_len], al
    mov byte [rbx + EntT.path_i], 0
    mov dword [rbx + EntT.best], 0x7F000000
    mov word [rbx + EntT.stuck], 0
    mov rcx, [rel g_tx]
    mov [rbx + EntT.goal], rcx
    mov rcx, [rel g_tz]
    mov [rbx + EntT.goal + 8], rcx
    RETURN
.later:
    mov eax, -1
    RETURN
ENDPROC

; target_feet — g_ty = the feet block of entity rbx (the plan's y for a
; point on its own level)   clobbers: rax, xmm0
target_feet:
    movsd xmm0, [rbx + EntT.pos + 8]
    addsd xmm0, [rel c_tiny]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_ty], eax
    ret

; -----------------------------------------------------------------------------
; follow_path — walk entity rbx (id esi) along its path at g_speed.
;   out: eax = 1 walking, 0 the path is done or it got stuck
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC follow_path, 16, rdi
.waypoint:
    movzx eax, byte [rbx + EntT.path_i]
    cmp al, [rbx + EntT.path_len]
    jae .done
    mov ecx, esi
    imul rcx, rcx, PATH_MAX * WP_BYTES
    lea rdi, [rel g_paths]
    add rdi, rcx
    imul eax, eax, WP_BYTES
    add rdi, rax                        ; the waypoint
    cvtsi2sd xmm0, dword [rdi]
    addsd xmm0, [rel c_half]
    subsd xmm0, [rbx + EntT.pos]
    cvtsi2sd xmm1, dword [rdi + 8]
    addsd xmm1, [rel c_half]
    subsd xmm1, [rbx + EntT.pos + 16]
    movsd xmm2, xmm0
    mulsd xmm2, xmm0
    movsd xmm3, xmm1
    mulsd xmm3, xmm1
    addsd xmm2, xmm3
    comisd xmm2, [rel c_arrive2]
    jae .go
    ; there: the next one
    inc byte [rbx + EntT.path_i]
    mov dword [rbx + EntT.best], 0x7F000000
    mov word [rbx + EntT.stuck], 0
    jmp .waypoint
.go:
    sqrtsd xmm2, xmm2
    ; stuck: no closer for 2 seconds
    cvtsd2ss xmm3, xmm2
    movss xmm4, [rbx + EntT.best]
    subss xmm4, [rel c_progress]
    comiss xmm3, xmm4
    jae .not_closer
    movss [rbx + EntT.best], xmm3
    mov word [rbx + EntT.stuck], 0
    jmp .heading
.not_closer:
    inc word [rbx + EntT.stuck]
    cmp word [rbx + EntT.stuck], 40
    jae .stuck
.heading:
    divsd xmm0, xmm2
    divsd xmm1, xmm2
    movsd [LOCAL(0)], xmm0
    movsd [LOCAL(8)], xmm1
    mulsd xmm0, [rel g_speed]
    mulsd xmm1, [rel g_speed]
    movsd [rel g_wx], xmm0
    movsd [rel g_wz], xmm1
    ; up a step: jump when close to it, on the ground
    movsd xmm0, [rbx + EntT.pos + 8]
    addsd xmm0, [rel c_half]
    cvtsi2sd xmm1, dword [rdi + 4]
    comisd xmm1, xmm0
    jb .turn
    test dword [rbx + EntT.flags], EF_GROUND
    jz .turn
    call mob_of
    cvtss2sd xmm0, [rax + MOB.jump_v]   ; (deer leap, goats spring up)
    movsd [rbx + EntT.vel + 8], xmm0
.turn:
    ; the body turns to where it goes: yaw = atan2(dx, -dz)
    cvtsd2ss xmm0, [LOCAL(0)]
    cvtsd2ss xmm1, [LOCAL(8)]
    xorps xmm1, [rel c_neg_f]
    call atan2f
    movss xmm1, xmm0
    movss xmm0, [rbx + EntT.yaw]
    movss xmm2, [rel c_turn]
    call turn
    movss [rbx + EntT.yaw], xmm0
    mov eax, 1
    RETURN
.stuck:
    mov byte [rbx + EntT.path_len], 0
.done:
    xor eax, eax
    RETURN
ENDPROC

; look_at_player — the head turns to the player (rbx; g_dx, g_dz, g_d2)
;   clobbers: volatile registers
PROC look_at_player, 0
    movsd xmm0, [rel g_dx]
    xorpd xmm0, [rel c_sign_d]
    cvtsd2ss xmm0, xmm0
    cvtsd2ss xmm1, [rel g_dz]
    call atan2f
    subss xmm0, [rbx + EntT.yaw]
    call wrap
    minss xmm0, [rel c_head_max]
    movss xmm1, [rel c_head_max]
    xorps xmm1, [rel c_neg_f]
    maxss xmm0, xmm1
    movss [rbx + EntT.look_yaw], xmm0
    movsd xmm1, [rel g_d2]
    sqrtsd xmm1, xmm1
    cvtsd2ss xmm1, xmm1
    movsd xmm0, [rel g_pl_pos + 8]
    subsd xmm0, [rbx + EntT.pos + 8]
    subsd xmm0, [rel c_eye_lift]
    cvtsd2ss xmm0, xmm0
    call atan2f
    minss xmm0, [rel c_pitch_max]
    movss xmm1, [rel c_pitch_max]
    xorps xmm1, [rel c_neg_f]
    maxss xmm0, xmm1
    movss [rbx + EntT.look_pitch], xmm0
    RETURN
ENDPROC

; flee_target — g_tx/g_tz: 10 blocks straight away from the player, a little
; to the side   clobbers: volatile registers
PROC flee_target, 0
    movsd xmm0, [rel g_dx]
    movsd xmm1, [rel g_dz]
    movsd xmm2, [rel g_d2]
    sqrtsd xmm2, xmm2
    addsd xmm2, [rel c_tiny]
    movsd xmm3, [rel c_flee_dist]
    divsd xmm3, xmm2
    mulsd xmm0, xmm3
    mulsd xmm1, xmm3
    movsd [rel g_tx], xmm0
    movsd [rel g_tz], xmm1
    call rand01
    subsd xmm0, [rel c_half]
    mulsd xmm0, [rel c_wander_r]
    movsd xmm1, [rel g_tx]
    addsd xmm1, xmm0
    addsd xmm1, [rbx + EntT.pos]
    movsd [rel g_tx], xmm1
    movsd xmm1, [rel g_tz]
    subsd xmm1, xmm0
    addsd xmm1, [rbx + EntT.pos + 16]
    movsd [rel g_tz], xmm1
    call target_feet
    RETURN
ENDPROC

; start_flee — entity rbx runs from the player (wakes up)   clobbers: volatile
PROC start_flee, 0
    mov byte [rbx + EntT.state], AI_FLEE
    mov word [rbx + EntT.timer], FLEE_TICKS
    mov byte [rbx + EntT.path_len], 0
    mov word [rbx + EntT.repath], 0
    test dword [rbx + EntT.flags], EF_SLEEP
    jz .done
    and dword [rbx + EntT.flags], ~EF_SLEEP
    or dword [rbx + EntT.flags], EF_DIRTY
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; behave_hurt — entity rbx was hit: it runs, and so does its herd nearby.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC behave_hurt, 0, rbx, rsi, rdi, r12
    call mob_of
    cmp dword [rax + MOB.temper], TEMPER_FIERCE
    jne .runs
    ; a fierce one turns on the player (its herd stays)
    mov byte [rbx + EntT.state], AI_CHARGE
    mov word [rbx + EntT.timer], CHARGE_TICKS
    mov byte [rbx + EntT.path_len], 0
    mov word [rbx + EntT.repath], 0
    and dword [rbx + EntT.flags], ~EF_SLEEP
    or dword [rbx + EntT.flags], EF_DIRTY
    RETURN
.runs:
    call start_flee
    mov r12d, [rbx + EntT.herd]
    test r12d, r12d
    jz .done
    mov rdi, rbx
    lea rbx, [rel g_ents]
    xor esi, esi
.ent:
    cmp esi, MAX_ENTITIES
    jae .back
    cmp rbx, rdi
    je .next
    mov eax, [rbx + EntT.flags]
    and eax, EF_ACTIVE | EF_AWAKE | EF_DYING
    cmp eax, EF_ACTIVE | EF_AWAKE
    jne .next
    cmp [rbx + EntT.herd], r12d
    jne .next
    movsd xmm0, [rdi + EntT.pos]
    movsd xmm1, [rdi + EntT.pos + 16]
    call dist2_to
    comisd xmm0, [rel c_flock2]
    ja .next
    call start_flee
.next:
    add rbx, EntT_size
    inc esi
    jmp .ent
.back:
    mov rbx, rdi
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; behave_interact — the player used the item in hand on an animal: its food
; makes an adult want a mate (not while resting) and helps a baby grow.
;   in:  rcx = ENT_PKT* (.id)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC behave_interact, 0, rbx, rsi
    mov esi, [rcx + ENT_PKT.id]
    cmp esi, MAX_ENTITIES
    jae .done
    mov ecx, esi
    call ent_of
    mov rbx, rax
    mov eax, [rbx + EntT.flags]
    and eax, EF_ACTIVE | EF_AWAKE | EF_DYING
    cmp eax, EF_ACTIVE | EF_AWAKE
    jne .done
    ; within reach
    movsd xmm0, [rel g_pl_pos]
    movsd xmm1, [rel g_pl_pos + 16]
    call dist2_to
    cvtss2sd xmm1, [rel g_pl_reach]
    addsd xmm1, [rel c_reach_extra]
    mulsd xmm1, xmm1
    comisd xmm0, xmm1
    ja .done
    ; a lead: a led animal is let go (the lead drops), one tied to a fence
    ; is taken back, and a lead in hand goes on a free one (part 3b)
    mov eax, [rbx + EntT.leash]
    cmp eax, LEASH_PLAYER
    jne .not_led
    call lead_drop
    RETURN
.not_led:
    cmp eax, LEASH_KNOT
    jne .no_knot
    mov dword [rbx + EntT.leash], LEASH_PLAYER
    or dword [rbx + EntT.flags], EF_DIRTY
    RETURN
.no_knot:
    mov eax, [rel g_lead_item]
    test eax, eax
    jz .shears
    mov ecx, [rel g_inv_sel]
    lea r8, [rel g_inv]
    cmp ax, [r8 + rcx * 8]
    jne .shears
    mov dword [rbx + EntT.leash], LEASH_PLAYER
    or dword [rbx + EntT.flags], EF_DIRTY
    LOG_DEBUG "entities: an animal was put on a lead"
    call inv_used_selected
    RETURN
.shears:
    ; shears: its coat
    call mob_of
    movzx edx, word [rax + MOB.shear_tool]
    test edx, edx
    jz .feed
    mov ecx, [rel g_inv_sel]
    lea r8, [rel g_inv]
    cmp dx, [r8 + rcx * 8]
    jne .feed
    call shear
    RETURN
.feed:
    ; a bucket: milk (grown-ups)
    call mob_of
    movzx edx, word [rax + MOB.milk_from]
    test edx, edx
    jz .no_milk
    mov ecx, [rel g_inv_sel]
    lea r8, [rel g_inv]
    cmp dx, [r8 + rcx * 8]
    jne .no_milk
    test dword [rbx + EntT.flags], EF_BABY
    jnz .done
    movzx edx, word [rax + MOB.milk_to]
    mov esi, edx
    mov ecx, [rel g_inv_sel]
    call inv_turn_slot
    test eax, eax
    jz .milked
    movsd xmm0, [rel c_shear_up]
    call spot_above
    mov ecx, esi
    mov edx, 1
    lea r8, [rel g_spot]
    call drops_spawn
.milked:
    LOG_DEBUG "entities: an animal was milked"
    RETURN
.no_milk:
    call holds_food
    test eax, eax
    jz .done
    test dword [rbx + EntT.flags], EF_BABY
    jnz .baby
    cmp word [rbx + EntT.cooldown], 0
    jne .done
    cmp word [rbx + EntT.love], 0
    jne .done
    mov word [rbx + EntT.love], LOVE_TICKS
    mov dword [rbx + EntT.target], -1
    or dword [rbx + EntT.flags], EF_DIRTY
    LOG_DEBUG "entities: an animal was fed (looks for a mate)"
    call inv_used_selected
    RETURN
.baby:
    add dword [rbx + EntT.age], GROW_TICKS / 10
    call inv_used_selected
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; shear — the player's shears on entity rbx: a grown-up with its coat gives
; shear_min .. shear_max of its variant's coat item (they pop out); the
; shears wear.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC shear, 0, rsi, rdi
    test dword [rbx + EntT.flags], EF_BABY | EF_SHEARED
    jnz .done
    movzx eax, word [rbx + EntT.variant]
    imul eax, eax, VARIANT_size
    lea rcx, [rel g_variants]
    mov esi, [rcx + rax + VARIANT.coat]
    test esi, esi
    jz .done
    call mob_of
    mov rdi, rax
    movzx ecx, byte [rdi + MOB.shear_max]
    movzx eax, byte [rdi + MOB.shear_min]
    sub ecx, eax
    inc ecx
    call rand_below
    movzx ecx, byte [rdi + MOB.shear_min]
    add eax, ecx
    mov edi, eax
    or dword [rbx + EntT.flags], EF_SHEARED | EF_DIRTY
    test edi, edi
    jz .worn
    movsd xmm0, [rel c_shear_up]
    call spot_above
    mov ecx, esi
    mov edx, edi
    lea r8, [rel g_spot]
    call drops_spawn
.worn:
    call inv_wear_selected
    LOG_DEBUG "entities: an animal was shorn"
.done:
    RETURN
ENDPROC

; spot_above — g_spot = entity rbx's feet, xmm0 blocks up   clobbers: rax
spot_above:
    mov rax, [rbx + EntT.pos]
    mov [rel g_spot], rax
    addsd xmm0, [rbx + EntT.pos + 8]
    movsd [rel g_spot + 8], xmm0
    mov rax, [rbx + EntT.pos + 16]
    mov [rel g_spot + 16], rax
    ret

; -----------------------------------------------------------------------------
; lay — a grown-up layer (mob rdi has `lays`): counts down and drops its
; item now and then (lay_min .. lay_max ticks apart).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC lay, 0
    movzx eax, word [rdi + MOB.lay_item]
    test eax, eax
    jz .done
    test dword [rbx + EntT.flags], EF_BABY
    jnz .done
    mov eax, [rbx + EntT.lay]
    test eax, eax
    jz .count                           ; (not counting yet: start)
    dec eax
    mov [rbx + EntT.lay], eax
    jnz .done
    movsd xmm0, [rel c_lay_up]
    call spot_above
    movzx ecx, word [rdi + MOB.lay_item]
    mov edx, 1
    lea r8, [rel g_spot]
    call drops_spawn
    LOG_DEBUG "entities: an animal laid"
.count:
    mov ecx, [rdi + MOB.lay_max]
    sub ecx, [rdi + MOB.lay_min]
    inc ecx
    call rand_below
    add eax, [rdi + MOB.lay_min]
    or eax, 1
    mov [rbx + EntT.lay], eax
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; ram — a charging animal (rbx) reached the player: they are knocked away
; (g_dx, g_dz: animal - player; g_d2).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC ram, 0
    movsd xmm2, [rel g_d2]
    sqrtsd xmm2, xmm2
    addsd xmm2, [rel c_tiny]
    movsd xmm0, [rel g_dx]
    movsd xmm1, [rel g_dz]
    divsd xmm0, xmm2
    divsd xmm1, xmm2
    mulsd xmm0, [rel c_ram_push]
    mulsd xmm1, [rel c_ram_push]
    xorpd xmm0, [rel c_sign_d]          ; (away from the animal)
    xorpd xmm1, [rel c_sign_d]
    movsd [rel g_pl_vel], xmm0
    movsd [rel g_pl_vel + 16], xmm1
    movsd xmm0, [rel g_pl_vel + 8]
    maxsd xmm0, [rel c_ram_up]
    movsd [rel g_pl_vel + 8], xmm0
    LOG_DEBUG "entities: a fierce animal rammed the player"
    ; it hurts (milestone 20)
    call mob_of
    mov ecx, [rax + MOB.ram_damage]
    mov edx, CAUSE_RAM
    movzx r8d, word [rbx + EntT.mob]
    call survival_damage
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; find_food — a block entity rbx (mob rdi) eats within 4 blocks around its
; feet (its level and one up or down): EntT.food.
;   out: eax = 1 found
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define FF_X    0
%define FF_Y    4
%define FF_Z    8
%define FF_DX   12
%define FF_DY   16
%define FF_DZ   20
PROC find_food, 32, rsi
    movsd xmm0, [rbx + EntT.pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [LOCAL(FF_X)], eax
    movsd xmm0, [rbx + EntT.pos + 8]
    addsd xmm0, [rel c_tiny]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [LOCAL(FF_Y)], eax
    movsd xmm0, [rbx + EntT.pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [LOCAL(FF_Z)], eax
    mov dword [LOCAL(FF_DY)], -1
.dy:
    mov dword [LOCAL(FF_DZ)], -4
.dz:
    mov dword [LOCAL(FF_DX)], -4
.dx:
    mov ecx, [LOCAL(FF_X)]
    add ecx, [LOCAL(FF_DX)]
    mov edx, [LOCAL(FF_Y)]
    add edx, [LOCAL(FF_DY)]
    mov r8d, [LOCAL(FF_Z)]
    add r8d, [LOCAL(FF_DZ)]
    call phys_block
    test eax, eax
    jle .next
    lea rcx, [rel g_block_eat]
    movzx ecx, byte [rcx + rax]
    test ecx, [rdi + MOB.eats]
    jz .next
    mov eax, [LOCAL(FF_X)]
    add eax, [LOCAL(FF_DX)]
    mov [rbx + EntT.food], eax
    mov eax, [LOCAL(FF_Y)]
    add eax, [LOCAL(FF_DY)]
    mov [rbx + EntT.food + 4], eax
    mov eax, [LOCAL(FF_Z)]
    add eax, [LOCAL(FF_DZ)]
    mov [rbx + EntT.food + 8], eax
    mov eax, 1
    RETURN
.next:
    inc dword [LOCAL(FF_DX)]
    cmp dword [LOCAL(FF_DX)], 4
    jle .dx
    inc dword [LOCAL(FF_DZ)]
    cmp dword [LOCAL(FF_DZ)], 4
    jle .dz
    inc dword [LOCAL(FF_DY)]
    cmp dword [LOCAL(FF_DY)], 1
    jle .dy
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; eat_or_walk — entity rbx (mob rdi) in AI_EAT: at its food it eats it (the
; block is gone for good), else it walks there.
;   out: eax = 1 still going (walking or nibbling), 0 done (eaten, gone or
;        unreachable)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC eat_or_walk, 0
    ; still something it eats there?
    mov ecx, [rbx + EntT.food]
    mov edx, [rbx + EntT.food + 4]
    mov r8d, [rbx + EntT.food + 8]
    call phys_block
    test eax, eax
    jle .gone
    lea rcx, [rel g_block_eat]
    movzx ecx, byte [rcx + rax]
    test ecx, [rdi + MOB.eats]
    jz .gone
    cvtsi2sd xmm0, dword [rbx + EntT.food]
    addsd xmm0, [rel c_half]
    movsd [rel g_tx], xmm0
    cvtsi2sd xmm1, dword [rbx + EntT.food + 8]
    addsd xmm1, [rel c_half]
    movsd [rel g_tz], xmm1
    call dist2_to
    comisd xmm0, [rel c_eat2]
    jae .walk
    ; there: head down, a moment, then it is eaten
    mov dword [rbx + EntT.look_yaw], 0
    mov eax, [rel c_graze_pitch]
    mov [rbx + EntT.look_pitch], eax
    cmp word [rbx + EntT.timer], 280
    jbe .bite
    mov eax, 1
    RETURN
.bite:
    mov ecx, [rbx + EntT.food]
    mov edx, [rbx + EntT.food + 4]
    mov r8d, [rbx + EntT.food + 8]
    xor r9d, r9d
    call edit_apply
    LOG_DEBUG "entities: an animal ate a flower"
.gone:
    xor eax, eax
    RETURN
.walk:
    ; (the nibbling waits until it gets there)
    cmp word [rbx + EntT.timer], 290
    jae .keep
    mov word [rbx + EntT.timer], 290
.keep:
    mov eax, [rbx + EntT.food + 4]
    mov [rel g_ty], eax
    mov ecx, 20
    call go_to
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; maybe_ram — a rammer (goat; mob rdi) with a player within `rams` blocks
; may start a charge (once a second, `rams` % chance); the charge knocks
; the player back like a boar's.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC maybe_ram, 0
    movss xmm0, [rdi + MOB.rams_dist]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .done
    test dword [rbx + EntT.flags], EF_BABY | EF_SLEEP
    jnz .done
    movzx eax, byte [rbx + EntT.state]
    cmp eax, AI_CHARGE
    je .done
    cmp eax, AI_FLEE
    je .done
    cvtss2sd xmm0, xmm0
    mulsd xmm0, xmm0
    comisd xmm0, [rel g_d2]
    jbe .done
    ; once a second (spread over the animals)
    mov eax, [rel g_btick]
    add eax, esi
    xor edx, edx
    mov ecx, 20
    div ecx
    test edx, edx
    jnz .done
    call rand01
    mulsd xmm0, [rel c_hundred]
    cvtss2sd xmm1, [rdi + MOB.rams_pct]
    comisd xmm0, xmm1
    jae .done
    mov byte [rbx + EntT.state], AI_CHARGE
    mov word [rbx + EntT.timer], CHARGE_TICKS
    mov byte [rbx + EntT.path_len], 0
    mov word [rbx + EntT.repath], 0
    or dword [rbx + EntT.flags], EF_DIRTY
    LOG_DEBUG "entities: an animal rams the player"
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; find_mate — another fed adult of the same kind within 12 blocks
;   in:  rbx = EntT*, esi = its id
;   out: rax = the mate's EntT* (0 none), edx = its id
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC find_mate, 0, rdi, r12
    lea rdi, [rel g_ents]
    xor r12d, r12d
.ent:
    cmp r12d, MAX_ENTITIES
    jae .none
    cmp r12d, esi
    je .next
    mov eax, [rdi + EntT.flags]
    and eax, EF_ACTIVE | EF_AWAKE | EF_DYING | EF_BABY
    cmp eax, EF_ACTIVE | EF_AWAKE
    jne .next
    cmp word [rdi + EntT.love], 0
    je .next
    mov ax, [rdi + EntT.mob]
    cmp ax, [rbx + EntT.mob]
    jne .next
    movsd xmm0, [rdi + EntT.pos]
    movsd xmm1, [rdi + EntT.pos + 16]
    call dist2_to
    comisd xmm0, [rel c_mate2]
    ja .next
    mov rax, rdi
    mov edx, r12d
    RETURN
.next:
    add rdi, EntT_size
    inc r12d
    jmp .ent
.none:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; breed — entity rbx and its mate (rdi) meet: a baby between them.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC breed, 48, rdi
    mov rdi, rax
    xor eax, eax
    mov [rbx + EntT.love], ax
    mov [rdi + EntT.love], ax
    mov word [rbx + EntT.cooldown], BREED_COOLDOWN
    mov word [rdi + EntT.cooldown], BREED_COOLDOWN
    or dword [rbx + EntT.flags], EF_DIRTY
    or dword [rdi + EntT.flags], EF_DIRTY
    ; between them
    movsd xmm0, [rbx + EntT.pos]
    addsd xmm0, [rdi + EntT.pos]
    mulsd xmm0, [rel c_half]
    movsd [LOCAL(0)], xmm0
    movsd xmm0, [rbx + EntT.pos + 8]
    maxsd xmm0, [rdi + EntT.pos + 8]
    movsd [LOCAL(8)], xmm0
    movsd xmm0, [rbx + EntT.pos + 16]
    addsd xmm0, [rdi + EntT.pos + 16]
    mulsd xmm0, [rel c_half]
    movsd [LOCAL(16)], xmm0
    ; one of the parents' looks
    movzx ecx, word [rbx + EntT.variant]
    mov [LOCAL(24)], ecx
    mov ecx, 2
    call rand_below
    test eax, eax
    jz .look
    movzx ecx, word [rdi + EntT.variant]
    mov [LOCAL(24)], ecx
.look:
    mov ecx, [LOCAL(24)]
    mov edx, EF_BABY
    lea r8, [LOCAL(0)]
    call ent_new
    test eax, eax
    js .done
    mov ecx, eax
    call ent_of
    mov [LOCAL(32)], rax                ; the baby
    cmp dword [rbx + EntT.herd], 0
    jne .herd
    ; parents without a herd start one
    call rand
    or eax, 1
    mov [rbx + EntT.herd], eax
    mov [rdi + EntT.herd], eax
.herd:
    mov rax, [LOCAL(32)]
    mov ecx, [rbx + EntT.herd]
    mov [rax + EntT.herd], ecx
    LOG_INFO "entities: a baby was born"
.done:
    RETURN
ENDPROC

; nearest_grownup — rax = the nearest adult of entity rbx's herd (0 none),
; xmm0 = its distance^2   clobbers: volatile registers
PROC nearest_grownup, 16, rdi, r12
    xor eax, eax
    mov [LOCAL(0)], rax
    mov rax, 0x7FF0000000000000         ; (infinity)
    mov [LOCAL(8)], rax
    mov r12d, [rbx + EntT.herd]
    test r12d, r12d
    jz .done
    lea rdi, [rel g_ents]
    mov ecx, MAX_ENTITIES
.ent:
    mov eax, [rdi + EntT.flags]
    and eax, EF_ACTIVE | EF_AWAKE | EF_DYING | EF_BABY
    cmp eax, EF_ACTIVE | EF_AWAKE
    jne .next
    cmp [rdi + EntT.herd], r12d
    jne .next
    movsd xmm0, [rdi + EntT.pos]
    movsd xmm1, [rdi + EntT.pos + 16]
    call dist2_to
    comisd xmm0, [LOCAL(8)]
    jae .next
    movsd [LOCAL(8)], xmm0
    mov [LOCAL(0)], rdi
.next:
    add rdi, EntT_size
    dec ecx
    jnz .ent
.done:
    mov rax, [LOCAL(0)]
    movsd xmm0, [LOCAL(8)]
    RETURN
ENDPROC

; graze_here — the grass block under entity rbx becomes dirt; it grows back
;   clobbers: volatile registers
PROC graze_here, 16, rdi
    movsd xmm0, [rbx + EntT.pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [LOCAL(0)], eax
    movsd xmm0, [rbx + EntT.pos + 8]
    addsd xmm0, [rel c_tiny]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    dec eax
    mov [LOCAL(4)], eax
    movsd xmm0, [rbx + EntT.pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [LOCAL(8)], eax
    mov ecx, [LOCAL(0)]
    mov edx, [LOCAL(4)]
    mov r8d, [LOCAL(8)]
    call phys_block
    cmp eax, [rel g_grass]
    jne .done
    mov eax, [rel g_regrow_count]
    cmp eax, MAX_REGROW
    jae .done                           ; (too much grazed at once: leave it)
    mov ecx, [LOCAL(0)]
    mov edx, [LOCAL(4)]
    mov r8d, [LOCAL(8)]
    mov r9d, [rel g_dirt]
    call edit_apply
    test eax, eax
    jz .done
    ; a shorn coat grows back
    test dword [rbx + EntT.flags], EF_SHEARED
    jz .regrow
    and dword [rbx + EntT.flags], ~EF_SHEARED
    or dword [rbx + EntT.flags], EF_DIRTY
    LOG_DEBUG "entities: a shorn coat grew back (grazing)"
.regrow:
    mov eax, [rel g_regrow_count]
    inc dword [rel g_regrow_count]
    shl eax, 4
    lea rdi, [rel g_regrow]
    add rdi, rax
    mov eax, [LOCAL(0)]
    mov [rdi], eax
    mov eax, [LOCAL(4)]
    mov [rdi + 4], eax
    mov eax, [LOCAL(8)]
    mov [rdi + 8], eax
    mov ecx, 2400
    call rand_below
    add eax, 1200                       ; 1 - 3 minutes
    add eax, [rel g_btick]
    mov [rdi + 12], eax
.done:
    RETURN
ENDPROC

; on_grass — eax = 1 if entity rbx stands on a grass block   clobbers: volatile
PROC on_grass, 0
    movsd xmm0, [rbx + EntT.pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si ecx, xmm0
    movsd xmm0, [rbx + EntT.pos + 8]
    addsd xmm0, [rel c_tiny]
    roundsd xmm0, xmm0, 9
    cvttsd2si edx, xmm0
    dec edx
    movsd xmm0, [rbx + EntT.pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si r8d, xmm0
    call phys_block
    cmp eax, [rel g_grass]
    sete al
    movzx eax, al
    RETURN
ENDPROC

; go_to — path to (g_tx, g_ty, g_tz) every `repath` ticks (ecx) and walk it
;   out: eax = 1 walking
;   clobbers: volatile registers
PROC go_to, 16
    mov [LOCAL(0)], ecx
    cmp word [rbx + EntT.repath], 0
    je .plan
    movzx eax, byte [rbx + EntT.path_i]
    cmp al, [rbx + EntT.path_len]
    jb .walk
.plan:
    call plan
    cmp eax, -1
    je .walk                            ; (no paths left this tick: next tick)
    mov eax, [LOCAL(0)]
    mov [rbx + EntT.repath], ax
.walk:
    call follow_path
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; lead_walk — entity rbx (mob rdi) is on a lead: it walks after the player
; (stopping 3 blocks away) or stays by its fence post; lagging more than 6
; blocks it is pulled straight along (faster the further), hopping up when
; the holder is higher; beyond 10 blocks (or with its fence gone) the lead
; snaps and drops.
;   out: eax = 1 its move is decided, 0 the lead snapped
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define LW_HX   0                       ; f64 the holder
%define LW_HY   8
%define LW_HZ   16
%define LW_STOP 24                      ; f64 close enough (squared, flat)
%define LW_DX   32
%define LW_DY   40
%define LW_DZ   48
%define LW_D2   56
PROC lead_walk, 64
    cmp dword [rbx + EntT.leash], LEASH_KNOT
    je .knot
    mov rax, [rel g_pl_pos]
    mov [LOCAL(LW_HX)], rax
    mov rax, [rel g_pl_pos + 8]
    mov [LOCAL(LW_HY)], rax
    mov rax, [rel g_pl_pos + 16]
    mov [LOCAL(LW_HZ)], rax
    mov rax, [rel c_led2]
    mov [LOCAL(LW_STOP)], rax
    jmp .held
.knot:
    ; the fence post still there? (not loaded: it waits)
    mov ecx, [rbx + EntT.knot]
    mov edx, [rbx + EntT.knot + 4]
    mov r8d, [rbx + EntT.knot + 8]
    call phys_block
    cmp eax, -1
    je .stand
    lea rcx, [rel g_block_shape]
    cmp byte [rcx + rax], SHAPE_FENCE
    jne .snap
    cvtsi2sd xmm0, dword [rbx + EntT.knot]
    addsd xmm0, [rel c_half]
    movsd [LOCAL(LW_HX)], xmm0
    cvtsi2sd xmm0, dword [rbx + EntT.knot + 4]
    movsd [LOCAL(LW_HY)], xmm0
    cvtsi2sd xmm0, dword [rbx + EntT.knot + 8]
    addsd xmm0, [rel c_half]
    movsd [LOCAL(LW_HZ)], xmm0
    mov rax, [rel c_tied2]
    mov [LOCAL(LW_STOP)], rax
.held:
    movsd xmm0, [LOCAL(LW_HX)]
    subsd xmm0, [rbx + EntT.pos]
    movsd [LOCAL(LW_DX)], xmm0
    movsd xmm1, [LOCAL(LW_HY)]
    subsd xmm1, [rbx + EntT.pos + 8]
    movsd [LOCAL(LW_DY)], xmm1
    movsd xmm2, [LOCAL(LW_HZ)]
    subsd xmm2, [rbx + EntT.pos + 16]
    movsd [LOCAL(LW_DZ)], xmm2
    mulsd xmm0, xmm0
    mulsd xmm2, xmm2
    addsd xmm0, xmm2
    movsd [LOCAL(LW_D2)], xmm0          ; (flat)
    mulsd xmm1, xmm1
    addsd xmm1, xmm0
    comisd xmm1, [rel c_snap2]
    ja .snap
    ; held: no sleeping, no running off
    test dword [rbx + EntT.flags], EF_SLEEP
    jz .awake
    and dword [rbx + EntT.flags], ~EF_SLEEP
    or dword [rbx + EntT.flags], EF_DIRTY
.awake:
    mov byte [rbx + EntT.state], AI_FOLLOW
    movsd xmm0, [LOCAL(LW_D2)]
    comisd xmm0, [LOCAL(LW_STOP)]
    jae .walk
    mov byte [rbx + EntT.path_len], 0
.stand:
    movsd xmm0, [rel g_d2]
    comisd xmm0, [rel c_look2]
    jae .done
    call look_at_player
    jmp .done
.walk:
    ; after the holder along a path ...
    mov rax, [LOCAL(LW_HX)]
    mov [rel g_tx], rax
    mov rax, [LOCAL(LW_HZ)]
    mov [rel g_tz], rax
    movsd xmm0, [LOCAL(LW_HY)]
    addsd xmm0, [rel c_tiny]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_ty], eax
    movsd xmm0, [rel g_speed]
    mulsd xmm0, [rel c_follow_mul]
    movsd [rel g_speed], xmm0
    mov ecx, 10
    call go_to
    mov dword [rbx + EntT.look_yaw], 0
    mov dword [rbx + EntT.look_pitch], 0
    ; ... and lagging behind: pulled straight at it
    movsd xmm0, [LOCAL(LW_D2)]
    comisd xmm0, [rel c_pull2]
    jbe .done
    sqrtsd xmm0, xmm0
    movsd xmm3, xmm0
    subsd xmm3, [rel c_pull_d]
    mulsd xmm3, [rel c_pull_k]
    addsd xmm3, [rel c_one]
    mulsd xmm3, [rel g_speed]           ; the pull (blocks per tick)
    movsd xmm1, [LOCAL(LW_DX)]
    divsd xmm1, xmm0
    mulsd xmm1, xmm3
    movsd [rel g_wx], xmm1
    movsd xmm2, [LOCAL(LW_DZ)]
    divsd xmm2, xmm0
    mulsd xmm2, xmm3
    movsd [rel g_wz], xmm2
    ; the body turns along: yaw = atan2(wx, -wz)
    cvtsd2ss xmm0, xmm1
    xorpd xmm2, [rel c_sign_d]
    cvtsd2ss xmm1, xmm2
    call atan2f
    movss xmm1, xmm0
    movss xmm0, [rbx + EntT.yaw]
    movss xmm2, [rel c_turn]
    call turn
    movss [rbx + EntT.yaw], xmm0
    ; the holder higher up: a hop
    movsd xmm0, [LOCAL(LW_DY)]
    comisd xmm0, [rel c_lift]
    jbe .done
    test dword [rbx + EntT.flags], EF_GROUND
    jz .done
    call mob_of
    cvtss2sd xmm0, [rax + MOB.jump_v]
    movsd [rbx + EntT.vel + 8], xmm0
.done:
    mov eax, 1
    RETURN
.snap:
    call lead_drop
    LOG_DEBUG "entities: a lead snapped"
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; lead_drop — entity rbx comes off its lead; the lead drops beside it.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC lead_drop, 0
    cmp dword [rbx + EntT.leash], LEASH_NONE
    je .done
    mov dword [rbx + EntT.leash], LEASH_NONE
    or dword [rbx + EntT.flags], EF_DIRTY
    mov byte [rbx + EntT.path_len], 0
    cmp dword [rel g_lead_item], 0
    je .done
    movsd xmm0, [rel c_shear_up]
    call spot_above
    mov ecx, [rel g_lead_item]
    mov edx, 1
    lea r8, [rel g_spot]
    call drops_spawn
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; lead_tie — PKT_C_TIE: the animals the player leads within 10 blocks of the
; fence at the packet's block are tied to it.
;   in:  rcx = BLOCK_PKT*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC lead_tie, 0, rbx, rsi
    mov eax, [rcx + BLOCK_PKT.x]
    mov [rel g_knot], eax
    mov eax, [rcx + BLOCK_PKT.y]
    mov [rel g_knot + 4], eax
    mov eax, [rcx + BLOCK_PKT.z]
    mov [rel g_knot + 8], eax
    mov ecx, [rel g_knot]
    mov edx, [rel g_knot + 4]
    mov r8d, [rel g_knot + 8]
    call phys_block
    cmp eax, -1
    je .done
    lea rcx, [rel g_block_shape]
    cmp byte [rcx + rax], SHAPE_FENCE
    jne .done
    lea rbx, [rel g_ents]
    mov esi, MAX_ENTITIES
.ent:
    mov eax, [rbx + EntT.flags]
    and eax, EF_ACTIVE | EF_DYING
    cmp eax, EF_ACTIVE
    jne .next
    cmp dword [rbx + EntT.leash], LEASH_PLAYER
    jne .next
    cvtsi2sd xmm0, dword [rel g_knot]
    addsd xmm0, [rel c_half]
    cvtsi2sd xmm1, dword [rel g_knot + 8]
    addsd xmm1, [rel c_half]
    call dist2_to
    comisd xmm0, [rel c_snap2]
    jae .next
    mov dword [rbx + EntT.leash], LEASH_KNOT
    mov eax, [rel g_knot]
    mov [rbx + EntT.knot], eax
    mov eax, [rel g_knot + 4]
    mov [rbx + EntT.knot + 4], eax
    mov eax, [rel g_knot + 8]
    mov [rbx + EntT.knot + 8], eax
    or dword [rbx + EntT.flags], EF_DIRTY
    mov byte [rbx + EntT.path_len], 0
    LOG_DEBUG "entities: a led animal was tied to a fence"
.next:
    add rbx, EntT_size
    dec esi
    jnz .ent
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; behave_name — PKT_C_NAME: the name tag in the player's hand names an animal
; within reach (printable characters, at most 23; used up in Survival); the
; client is told (PKT_S_ENTITY_NAME). A blank name changes nothing.
;   in:  rcx = NAME_PKT*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC behave_name, 0, rbx, rsi, rdi
    mov rdi, rcx
    mov esi, [rdi + NAME_PKT.id]
    cmp esi, MAX_ENTITIES
    jae .done
    mov eax, [rel g_tag_item]
    test eax, eax
    jz .done
    mov ecx, [rel g_inv_sel]
    lea r8, [rel g_inv]
    cmp ax, [r8 + rcx * 8]
    jne .done                           ; (the tag is not in hand any more)
    mov ecx, esi
    call ent_of
    mov rbx, rax
    mov eax, [rbx + EntT.flags]
    and eax, EF_ACTIVE | EF_DYING
    cmp eax, EF_ACTIVE
    jne .done
    movsd xmm0, [rel g_pl_pos]
    movsd xmm1, [rel g_pl_pos + 16]
    call dist2_to
    cvtss2sd xmm1, [rel g_pl_reach]
    addsd xmm1, [rel c_reach_extra]
    addsd xmm1, [rel c_reach_extra]     ; (it may have stepped away while typing)
    mulsd xmm1, xmm1
    comisd xmm0, xmm1
    ja .done
    ; the name: printable ASCII, spaces trimmed at the ends
    xor ecx, ecx                        ; read
    xor edx, edx                        ; written
.skip:
    cmp byte [rdi + NAME_PKT.name + rcx], ' '
    jne .copy
    inc ecx
    cmp ecx, NAME_MAX - 1
    jb .skip
.copy:
    cmp ecx, NAME_MAX - 1
    jae .copied
    movzx eax, byte [rdi + NAME_PKT.name + rcx]
    test eax, eax
    jz .copied
    inc ecx
    cmp eax, ' '
    jb .copy
    cmp eax, '~'
    ja .copy
    mov [rbx + EntT.name + rdx], al
    inc edx
    jmp .copy
.copied:
    test edx, edx
    jz .done                            ; (blank)
.trim:
    cmp byte [rbx + EntT.name + rdx - 1], ' '
    jne .end
    dec edx
    jnz .trim
.end:
    mov byte [rbx + EntT.name + rdx], 0
.clear:
    inc edx
    cmp edx, NAME_MAX
    jae .named
    mov byte [rbx + EntT.name + rdx], 0
    jmp .clear
.named:
    LOG_DEBUG "entities: an animal was given a name"
    call inv_used_selected
    test dword [rbx + EntT.flags], EF_SENT
    jz .done
    call ent_send_name
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; behave — see the header.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC behave, 16, rdi
    movsd [rel g_dx], xmm0
    movsd [rel g_dz], xmm1
    movsd [rel g_d2], xmm2
    xorps xmm0, xmm0
    movsd [rel g_wx], xmm0
    movsd [rel g_wz], xmm0
    call mob_of
    mov rdi, rax
    cvtss2sd xmm0, [rdi + MOB.speed]
    mulsd xmm0, [rel c_per_tick]
    movsd [rel g_speed], xmm0
    ; ---- timers; growing up ----
    cmp word [rbx + EntT.timer], 0
    je .t1
    dec word [rbx + EntT.timer]
.t1:
    cmp word [rbx + EntT.repath], 0
    je .t2
    dec word [rbx + EntT.repath]
.t2:
    cmp word [rbx + EntT.cooldown], 0
    je .t3
    dec word [rbx + EntT.cooldown]
.t3:
    cmp word [rbx + EntT.love], 0
    je .t4
    dec word [rbx + EntT.love]
    jnz .t4
    or dword [rbx + EntT.flags], EF_DIRTY   ; (no longer in love)
.t4:
    test dword [rbx + EntT.flags], EF_BABY
    jz .grown
    cmp dword [rbx + EntT.age], GROW_TICKS
    jb .grown
    and dword [rbx + EntT.flags], ~EF_BABY
    or dword [rbx + EntT.flags], EF_DIRTY
.grown:
    call lay                            ; (eggs; rdi = MOB*)

    ; ---- 0. on a lead: it follows whoever holds it (part 3b) ----
    cmp dword [rbx + EntT.leash], LEASH_NONE
    je .free
    call lead_walk
    test eax, eax
    jnz .apply
.free:

    ; ---- 0. rammers (goats) sometimes go for a player standing close ----
    call maybe_ram

    ; ---- 0. charging the player (fierce, hit) ----
    cmp byte [rbx + EntT.state], AI_CHARGE
    jne .no_charge
    cmp word [rbx + EntT.timer], 0
    je .to_idle
    movsd xmm0, [rel g_speed]
    mulsd xmm0, [rel c_charge_mul]
    movsd [rel g_speed], xmm0
    call look_at_player
    movsd xmm0, [rel g_d2]
    comisd xmm0, [rel c_ram2]
    jae .charge_go
    movsd xmm0, [rel g_pl_pos + 8]
    subsd xmm0, [rbx + EntT.pos + 8]
    andpd xmm0, [rel c_abs_d]
    comisd xmm0, [rel c_ram_dy]
    ja .charge_go
    call ram
    call start_flee                     ; (backs off a moment)
    mov word [rbx + EntT.timer], BACK_OFF_TICKS
    jmp .apply
.charge_go:
    mov rax, [rel g_pl_pos]
    mov [rel g_tx], rax
    mov rax, [rel g_pl_pos + 16]
    mov [rel g_tz], rax
    movsd xmm0, [rel g_pl_pos + 8]
    addsd xmm0, [rel c_tiny]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_ty], eax
    mov ecx, 5
    call go_to
    test eax, eax
    jnz .apply
    ; (no path, or at its end: straight at them)
    movsd xmm0, [rel g_dx]
    movsd xmm1, [rel g_dz]
    movsd xmm2, [rel g_d2]
    sqrtsd xmm2, xmm2
    addsd xmm2, [rel c_tiny]
    divsd xmm0, xmm2
    divsd xmm1, xmm2
    mulsd xmm0, [rel g_speed]
    mulsd xmm1, [rel g_speed]
    xorpd xmm0, [rel c_sign_d]
    xorpd xmm1, [rel c_sign_d]
    movsd [rel g_wx], xmm0
    movsd [rel g_wz], xmm1
    ; the body turns to them: yaw = atan2(dx, -dz)
    cvtsd2ss xmm0, xmm0
    xorpd xmm1, [rel c_sign_d]
    cvtsd2ss xmm1, xmm1
    call atan2f
    movss xmm1, xmm0
    movss xmm0, [rbx + EntT.yaw]
    movss xmm2, [rel c_turn]
    call turn
    movss [rbx + EntT.yaw], xmm0
    jmp .apply
.no_charge:

    ; ---- 1. running away ----
    cmp byte [rbx + EntT.state], AI_FLEE
    jne .no_flee
    cmp word [rbx + EntT.timer], 0
    je .to_idle
    movsd xmm0, [rel g_speed]
    mulsd xmm0, [rel c_flee_mul]
    movsd [rel g_speed], xmm0
    movzx eax, byte [rbx + EntT.path_i]
    cmp al, [rbx + EntT.path_len]
    jb .flee_walk
    call flee_target
    mov word [rbx + EntT.repath], 0
.flee_walk:
    mov ecx, 1000
    call go_to
    mov dword [rbx + EntT.look_yaw], 0
    mov dword [rbx + EntT.look_pitch], 0
    jmp .apply
.no_flee:
    cmp dword [rdi + MOB.temper], TEMPER_WILD
    jne .not_wild
    movsd xmm0, [rel g_d2]
    comisd xmm0, [rel c_wild2]
    jae .not_wild
    call start_flee
    jmp .apply
.not_wild:

    ; ---- 2. sleeping ----
    call is_night
    mov [LOCAL(0)], eax
    cmp byte [rbx + EntT.state], AI_SLEEP
    jne .awake
    test eax, eax
    jnz .sleeping
    ; morning
    and dword [rbx + EntT.flags], ~EF_SLEEP
    or dword [rbx + EntT.flags], EF_DIRTY
    jmp .to_idle
.sleeping:
    mov dword [rbx + EntT.look_yaw], 0
    mov eax, [rel c_sleep_pitch]
    mov [rbx + EntT.look_pitch], eax
    jmp .apply
.awake:

    ; ---- 3. in love: to a mate ----
    cmp word [rbx + EntT.love], 0
    je .no_love
    test dword [rbx + EntT.flags], EF_BABY
    jnz .no_love
    call find_mate
    test rax, rax
    jz .no_love
    mov [LOCAL(8)], rax
    mov byte [rbx + EntT.state], AI_SEEK
    movsd xmm0, [rax + EntT.pos]
    movsd xmm1, [rax + EntT.pos + 16]
    call dist2_to
    comisd xmm0, [rel c_meet2]
    jae .to_mate
    mov rax, [LOCAL(8)]
    call breed
    jmp .to_idle
.to_mate:
    mov byte [rbx + EntT.state], AI_SEEK
    mov rax, [LOCAL(8)]
    mov rcx, [rax + EntT.pos]
    mov [rel g_tx], rcx
    mov rcx, [rax + EntT.pos + 16]
    mov [rel g_tz], rcx
    call target_feet
    mov ecx, 10
    call go_to
    jmp .apply
.no_love:

    ; ---- 4. a player holding its food ----
    movsd xmm0, [rel g_d2]
    comisd xmm0, [rel c_follow2]
    jae .no_food
    call holds_food
    test eax, eax
    jz .no_food
    mov byte [rbx + EntT.state], AI_FOLLOW
    call look_at_player
    movsd xmm0, [rel g_d2]
    comisd xmm0, [rel c_stop2]
    jb .apply                           ; (close enough: stands and looks)
    movsd xmm0, [rel g_speed]
    mulsd xmm0, [rel c_follow_mul]
    movsd [rel g_speed], xmm0
    mov rax, [rel g_pl_pos]
    mov [rel g_tx], rax
    mov rax, [rel g_pl_pos + 16]
    mov [rel g_tz], rax
    movsd xmm0, [rel g_pl_pos + 8]
    addsd xmm0, [rel c_tiny]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rel g_ty], eax
    mov ecx, 10
    call go_to
    jmp .apply
.no_food:
    cmp byte [rbx + EntT.state], AI_FOLLOW
    jne .no_follow
    mov byte [rbx + EntT.state], AI_IDLE
    mov byte [rbx + EntT.path_len], 0
.no_follow:

    ; ---- 5. night: back to the herd, then lie down ----
    cmp dword [LOCAL(0)], 0
    je .day
    call herd_centre
    test eax, eax
    jz .lie_down
    movsd [rel g_tx], xmm0
    movsd [rel g_tz], xmm1
    call dist2_to
    comisd xmm0, [rel c_gather2]
    jb .lie_down
    mov byte [rbx + EntT.state], AI_SEEK
    call target_feet
    mov ecx, 40
    call go_to
    test eax, eax
    jnz .apply
.lie_down:
    mov byte [rbx + EntT.state], AI_SLEEP
    mov byte [rbx + EntT.path_len], 0
    or dword [rbx + EntT.flags], EF_SLEEP | EF_DIRTY
    jmp .apply
.day:

    ; ---- 6. a baby keeps close to a grown-up of its herd ----
    test dword [rbx + EntT.flags], EF_BABY
    jz .not_baby
    call nearest_grownup
    test rax, rax
    jz .not_baby
    comisd xmm0, [rel c_baby2]
    jb .not_baby
    mov byte [rbx + EntT.state], AI_SEEK
    mov rcx, [rax + EntT.pos]
    mov [rel g_tx], rcx
    mov rcx, [rax + EntT.pos + 16]
    mov [rel g_tz], rcx
    call target_feet
    mov ecx, 20
    call go_to
    test eax, eax
    jnz .apply
.not_baby:

    ; ---- 7. the day: idle, wander, graze ----
    movzx eax, byte [rbx + EntT.state]
    cmp eax, AI_WANDER
    je .wander
    cmp eax, AI_GRAZE
    je .graze
    cmp eax, AI_EAT
    je .eat
    cmp eax, AI_IDLE
    je .idle
    jmp .to_idle                        ; (seek / follow ended)
.eat:
    ; to the block it eats; there, it eats it (for good)
    cmp word [rbx + EntT.timer], 0
    je .to_idle
    call eat_or_walk
    test eax, eax
    jnz .apply
    jmp .to_idle
.wander:
    call follow_path
    test eax, eax
    jnz .apply_ahead
    jmp .to_idle
.graze:
    mov dword [rbx + EntT.look_yaw], 0
    mov eax, [rel c_graze_pitch]
    mov [rbx + EntT.look_pitch], eax
    cmp word [rbx + EntT.timer], 0
    jne .apply
    call graze_here
    jmp .to_idle
.idle:
    cmp word [rbx + EntT.timer], 0
    jne .look
    ; eaters (rabbits) look for something to eat nearby now and then
    cmp dword [rdi + MOB.eats], 0
    je .no_eats
    mov ecx, 3
    call rand_below
    test eax, eax
    jnz .no_eats
    call find_food
    test eax, eax
    jz .no_eats
    mov byte [rbx + EntT.state], AI_EAT
    mov word [rbx + EntT.timer], 300
    mov word [rbx + EntT.repath], 0
    mov byte [rbx + EntT.path_len], 0
    jmp .apply
.no_eats:
    mov ecx, 10
    call rand_below
    cmp eax, 2
    jae .wander_pick
    cmp dword [rdi + MOB.graze], 0
    je .wander_pick
    call on_grass
    test eax, eax
    jz .wander_pick
    mov byte [rbx + EntT.state], AI_GRAZE
    mov ecx, 30
    call rand_below
    add eax, 40
    mov [rbx + EntT.timer], ax
    jmp .apply
.wander_pick:
    cmp eax, 8
    jae .rest
    ; a spot a few blocks away (towards the herd if it strayed)
    call herd_centre
    test eax, eax
    jz .random_spot
    movsd [rel g_tx], xmm0
    movsd [rel g_tz], xmm1
    call dist2_to
    comisd xmm0, [rel c_herd2]
    jb .random_spot
    movsd xmm0, [rel g_tx]
    movsd xmm1, [rel g_tz]
    jmp .spot
.random_spot:
    movsd xmm0, [rbx + EntT.pos]
    movsd xmm1, [rbx + EntT.pos + 16]
.spot:
    movsd [rel g_tx], xmm0
    movsd [rel g_tz], xmm1
    call rand01
    subsd xmm0, [rel c_half]
    addsd xmm0, xmm0
    mulsd xmm0, [rel c_wander_r]
    addsd xmm0, [rel g_tx]
    movsd [rel g_tx], xmm0
    call rand01
    subsd xmm0, [rel c_half]
    addsd xmm0, xmm0
    mulsd xmm0, [rel c_wander_r]
    addsd xmm0, [rel g_tz]
    movsd [rel g_tz], xmm0
    call target_feet
    call plan
    cmp eax, -1
    je .look                            ; (no paths left this tick)
    test eax, eax
    jz .rest
    mov byte [rbx + EntT.state], AI_WANDER
    jmp .apply
.rest:
    mov ecx, 100
    call rand_below
    add eax, 40
    mov [rbx + EntT.timer], ax
    jmp .look
.to_idle:
    mov byte [rbx + EntT.state], AI_IDLE
    mov byte [rbx + EntT.path_len], 0
    mov ecx, 100
    call rand_below
    add eax, 30
    mov [rbx + EntT.timer], ax

    ; ---- the head: at a player close by, else now and then somewhere ----
.look:
    movsd xmm0, [rel g_d2]
    comisd xmm0, [rel c_look2]
    jae .look_around
    call look_at_player
    jmp .apply
.look_around:
    mov ecx, 60
    call rand_below
    test eax, eax
    jnz .apply
    call rand01
    subsd xmm0, [rel c_half]
    cvtsd2ss xmm0, xmm0
    addss xmm0, xmm0
    mulss xmm0, [rel c_look_far]
    movss [rbx + EntT.look_yaw], xmm0
    call rand01
    subsd xmm0, [rel c_half]
    cvtsd2ss xmm0, xmm0
    mulss xmm0, [rel c_pitch_max]
    movss [rbx + EntT.look_pitch], xmm0
    jmp .apply
.apply_ahead:
    mov dword [rbx + EntT.look_yaw], 0
    mov dword [rbx + EntT.look_pitch], 0

    ; ---- the velocity approaches the wanted one ----
.apply:
    movsd xmm2, [rel c_acc_ground]
    test dword [rbx + EntT.flags], EF_WATER
    jz .not_water
    movsd xmm2, [rel c_acc_water]
    jmp .acc
.not_water:
    test dword [rbx + EntT.flags], EF_GROUND
    jnz .acc
    movsd xmm2, [rel c_acc_air]
.acc:
    movsd xmm0, [rel g_wx]
    subsd xmm0, [rbx + EntT.vel]
    mulsd xmm0, xmm2
    addsd xmm0, [rbx + EntT.vel]
    movsd [rbx + EntT.vel], xmm0
    movsd xmm0, [rel g_wz]
    subsd xmm0, [rbx + EntT.vel + 16]
    mulsd xmm0, xmm2
    addsd xmm0, [rbx + EntT.vel + 16]
    movsd [rbx + EntT.vel + 16], xmm0
    ; hoppers (rabbits) move in little hops
    cmp dword [rdi + MOB.hops], 0
    je .no_hop
    test dword [rbx + EntT.flags], EF_GROUND
    jz .no_hop
    movsd xmm0, [rel g_wx]
    mulsd xmm0, xmm0
    movsd xmm1, [rel g_wz]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    comisd xmm0, [rel c_moving2]
    jb .no_hop
    movsd xmm0, [rel c_hop]
    movsd [rbx + EntT.vel + 8], xmm0
.no_hop:
    ; a jump when it walked into a step (on the ground, wanting to move)
    test dword [rbx + EntT.flags], EF_BUMPED
    jz .no_jump
    movsd xmm0, [rel g_wx]
    mulsd xmm0, xmm0
    movsd xmm1, [rel g_wz]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    comisd xmm0, [rel c_moving2]
    jb .no_jump
    test dword [rbx + EntT.flags], EF_WATER
    jnz .swim_jump
    test dword [rbx + EntT.flags], EF_GROUND
    jz .no_jump
    cvtss2sd xmm0, [rdi + MOB.jump_v]
    movsd [rbx + EntT.vel + 8], xmm0
    jmp .no_jump
.swim_jump:
    movsd xmm0, [rel c_jump]
    mulsd xmm0, [rel c_half]
    movsd [rbx + EntT.vel + 8], xmm0
.no_jump:
    movss xmm0, [rbx + EntT.head_yaw]
    movss xmm1, [rbx + EntT.look_yaw]
    movss xmm2, [rel c_head_turn]
    call turn
    movss [rbx + EntT.head_yaw], xmm0
    movss xmm0, [rbx + EntT.head_pitch]
    movss xmm1, [rbx + EntT.look_pitch]
    movss xmm2, [rel c_head_turn]
    call turn
    movss [rbx + EntT.head_pitch], xmm0
    RETURN
ENDPROC

section .rdata
align 4
c_half_f:       dd 0.5
