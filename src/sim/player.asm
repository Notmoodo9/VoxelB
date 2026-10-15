; =============================================================================
; player.asm — the player's movement in the simulation (milestone 16, D85).
;
; One call per 20 TPS tick. Movement follows the latest input packet:
;   walking (sprint forward, sneak slower), jumping, auto step-up onto
;   slabs and stairs (step_height), gravity with a terminal speed;
;   sneaking on the ground never walks off an edge;
;   swimming in water (and slowly in lava): sink slowly, jump swims up,
;   sneak dives; jumping against a bank climbs out;
;   climbing ladders and vines: jump or walk into them to go up, sneak to
;   hold on;
;   Creative flight (fly_speed, sprint multiplies it): jump / sneak go up
;   and down; landing ends the flight;
;   noclip (the --flytest streaming test): flying through everything.
; The body is an AABB width × height; position = the centre of the feet.
; Speeds and sizes come from data/entities/player.cfg, gravity from
; data/world/world.cfg. Until the ground under the player is generated the
; player is frozen in place.
;
; Public API:
;   player_load()                       read player.cfg
;   player_spawn(rcx = eye position 3 doubles, edx = PF_FLYING | PF_NOCLIP)
;   player_tick(rcx = INPUT_PKT*, edx = jump pressed since the last tick)
;   player_toggle_fly()
;   player_fill(rcx = PLAYER_PKT*)      the state for the client
;   g_pl_pos, g_pl_vel, g_pl_flags
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "packet.inc"
%include "physics.inc"
%include "save.inc"

global player_load, player_spawn, player_tick, player_toggle_fly, player_fill
global g_pl_pos, g_pl_vel, g_pl_flags, g_pl_eye, g_pl_reach, g_pl_width, g_pl_height

extern str_ieq, str_parse_float, sincosf, g_gravity, g_world_mode
extern g_sv_eating, g_sv_eat_speed

%define TICK_DT     0.05
%define MAX_FALL_Y  -512.0              ; below the world: stop falling here

section .rdata
str_cfg_path:   db "data/entities/player.cfg", 0
str_cfg_label:  db "player.cfg", 0
str_unknown:    db "unknown setting: ", 0
str_bad:        db "bad value for: ", 0
; player.cfg keys, in the order of the settings block below
k_width:        db "width", 0
k_height:       db "height", 0
k_eye:          db "eye_height", 0
k_sneak_eye:    db "sneak_eye_height", 0
k_walk:         db "walk_speed", 0
k_sprint:       db "sprint_speed", 0
k_sneak:        db "sneak_speed", 0
k_jump:         db "jump_velocity", 0
k_ground_acc:   db "ground_accel", 0
k_air_acc:      db "air_accel", 0
k_terminal:     db "terminal_speed", 0
k_step:         db "step_height", 0
k_swim:         db "swim_speed", 0
k_swim_sprint:  db "swim_sprint_speed", 0
k_swim_up:      db "swim_up_speed", 0
k_sink:         db "sink_speed", 0
k_water_acc:    db "water_accel", 0
k_lava:         db "lava_slowdown", 0
k_climb:        db "climb_speed", 0
k_climb_down:   db "climb_down_speed", 0
k_fly:          db "fly_speed", 0
k_fly_sprint:   db "fly_sprint_multiplier", 0
k_fly_vert:     db "fly_vertical", 0
k_fly_acc:      db "fly_accel", 0
k_flytest:      db "flytest_speed", 0
k_reach:        db "reach", 0
align 8
key_table:      dq k_width, k_height, k_eye, k_sneak_eye, k_walk, k_sprint, k_sneak
                dq k_jump, k_ground_acc, k_air_acc, k_terminal, k_step, k_swim
                dq k_swim_sprint, k_swim_up, k_sink, k_water_acc, k_lava, k_climb
                dq k_climb_down, k_fly, k_fly_sprint, k_fly_vert, k_fly_acc, k_flytest
                dq k_reach
%define KEY_COUNT 26
align 8
c_dt:           dq TICK_DT
c_half:         dq 0.5
c_zero_d:       dq 0.0
c_edge_step:    dq 0.05                 ; sneak edge guard: shrink moves by this
c_max_fall:     dq MAX_FALL_Y
c_tiny:         dq 1.0e-9
align 16
c_abs_d:        dq 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF
c_one_f:        dd 1.0
c_eye_rate:     dd 0.5                  ; eye height: share of the gap per tick

section .data
align 4
; settings (f32), same order as key_table
s_values:
g_pl_width:
s_width:        dd 0.6
g_pl_height:
s_height:       dd 1.8
s_eye:          dd 1.62
s_sneak_eye:    dd 1.27
s_walk:         dd 4.317
s_sprint:       dd 5.612
s_sneak:        dd 1.31
s_jump:         dd 8.95
s_ground_acc:   dd 0.5
s_air_acc:      dd 0.08
s_terminal:     dd 78.0
s_step:         dd 0.6
s_swim:         dd 2.2
s_swim_sprint:  dd 4.0
s_swim_up:      dd 3.5
s_sink:         dd 1.5
s_water_acc:    dd 0.2
s_lava:         dd 0.5
s_climb:        dd 2.35
s_climb_down:   dd 3.0
s_fly:          dd 12.0
s_fly_sprint:   dd 5.0
s_fly_vert:     dd 0.6
s_fly_acc:      dd 0.35
s_flytest:      dd 60.0
g_pl_reach:
s_reach:        dd 5.0

section .bss
alignb 16
g_pl_pos:       resq 3                  ; feet centre (doubles)
g_pl_vel:       resq 3                  ; blocks/s (doubles)
g_box:          resq 6                  ; AABB scratch
g_box2:         resq 6
g_region:       resq 6
g_move:         resq 3                  ; requested move this tick
g_res:          resq 3                  ; move after collision
g_res2:         resq 3                  ; (step-up attempt)
g_wish:         resq 3                  ; target velocity
g_pl_flags:     resd 1                  ; PF_*
g_pl_eye:       resd 1                  ; current eye height (f32)
g_hit_h:        resd 1                  ; last tick ran into a wall
g_cfg_mark:     resq 1
g_cfg_path:     resb 512

section .text

; -----------------------------------------------------------------------------
; player_load — read data/entities/player.cfg (missing file: defaults).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC player_load, 0
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [rel g_cfg_mark], rax
    lea rcx, [rel g_cfg_path]
    lea rdx, [rel str_cfg_path]
    call path_make
    lea rcx, [rel g_cfg_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .missing
    lea rdx, [rel cfg_pair]
    lea r9, [rel str_cfg_label]
    INVOKE cfg_parse, rax, rdx, 0, r9
    jmp .done
.missing:
    LOG_WARN "data/entities/player.cfg not found; built-in movement settings used"
.done:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [rel g_cfg_mark]
    RETURN
ENDPROC

; cfg_parse callback: rcx = name, rdx = value
PROC cfg_pair, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    xor edi, edi
.find:
    cmp edi, KEY_COUNT
    jae .unknown
    lea rax, [rel key_table]
    INVOKE str_ieq, rbx, [rax + rdi * 8]
    test eax, eax
    jnz .found
    inc edi
    jmp .find
.found:
    mov rcx, rsi
    call str_parse_float
    test eax, eax
    jz .bad
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jb .bad                             ; (all settings are >= 0)
    lea rax, [rel s_values]
    movss [rax + rdi * 4], xmm0
    RETURN
.unknown:
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_unknown]
    INVOKE cfg_warn, rcx, rdx, rbx
    RETURN
.bad:
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_bad]
    INVOKE cfg_warn, rcx, rdx, rbx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; player_spawn — place the player with its eyes at a position.
;   in:  rcx = eye position (3 doubles), edx = starting PF_FLYING / PF_NOCLIP
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
player_spawn:
    and edx, PF_FLYING | PF_NOCLIP
    cmp dword [rel g_world_mode], MODE_SPECTATOR
    jne .not_spectator
    mov edx, PF_FLYING | PF_NOCLIP      ; (a spectator flies through everything)
.not_spectator:
    cmp dword [rel g_world_mode], MODE_CREATIVE
    je .flags
    test edx, PF_NOCLIP
    jnz .flags
    and edx, ~PF_FLYING                 ; (Survival walks)
.flags:
    mov [rel g_pl_flags], edx
    movsd xmm0, [rcx]
    movsd [rel g_pl_pos], xmm0
    movss xmm1, [rel s_eye]
    movss [rel g_pl_eye], xmm1
    cvtss2sd xmm1, xmm1
    movsd xmm0, [rcx + 8]
    subsd xmm0, xmm1
    movsd [rel g_pl_pos + 8], xmm0
    movsd xmm0, [rcx + 16]
    movsd [rel g_pl_pos + 16], xmm0
    xorps xmm0, xmm0
    movsd [rel g_pl_vel], xmm0
    movsd [rel g_pl_vel + 8], xmm0
    movsd [rel g_pl_vel + 16], xmm0
    mov dword [rel g_hit_h], 0
    ret

; -----------------------------------------------------------------------------
; player_toggle_fly — start or stop flying (Creative; noclip always flies).
;   clobbers: rax, xmm0
; -----------------------------------------------------------------------------
player_toggle_fly:
    test dword [rel g_pl_flags], PF_NOCLIP
    jnz .done
    cmp dword [rel g_world_mode], MODE_CREATIVE
    jne .done                           ; (Survival walks)
    xor dword [rel g_pl_flags], PF_FLYING
    xorps xmm0, xmm0
    movsd [rel g_pl_vel + 8], xmm0
.done:
    ret

; -----------------------------------------------------------------------------
; player_fill — the player's state as a PLAYER_PKT payload.
;   in:  rcx = PLAYER_PKT*
;   clobbers: rax, xmm0
; -----------------------------------------------------------------------------
player_fill:
%assign i 0
%rep 3
    mov rax, [rel g_pl_pos + i * 8]
    mov [rcx + PLAYER_PKT.pos + i * 8], rax
    cvtsd2ss xmm0, [rel g_pl_vel + i * 8]
    movss [rcx + PLAYER_PKT.vel + i * 4], xmm0
%assign i i + 1
%endrep
    mov eax, [rel g_pl_eye]
    mov [rcx + PLAYER_PKT.eye], eax
    mov eax, [rel g_pl_flags]
    mov [rcx + PLAYER_PKT.flags], eax
    mov eax, GAMEMODE_CREATIVE
    cmp dword [rel g_world_mode], MODE_CREATIVE
    je .mode
    mov eax, GAMEMODE_SPECTATOR
    cmp dword [rel g_world_mode], MODE_SPECTATOR
    je .mode
    mov eax, GAMEMODE_SURVIVAL
.mode:
    mov [rcx + PLAYER_PKT.mode], eax
    mov eax, [rel s_reach]
    mov [rcx + PLAYER_PKT.reach], eax
    ret

; -----------------------------------------------------------------------------
; make_box — the body's AABB at the current position.
;   in:  rcx = out AABB
;   clobbers: xmm0-xmm2
; -----------------------------------------------------------------------------
make_box:
    cvtss2sd xmm1, [rel s_width]
    mulsd xmm1, [rel c_half]
    movsd xmm0, [rel g_pl_pos]
    subsd xmm0, xmm1
    movsd [rcx + AABB_MINX], xmm0
    addsd xmm0, xmm1
    addsd xmm0, xmm1
    movsd [rcx + AABB_MAXX], xmm0
    movsd xmm0, [rel g_pl_pos + 16]
    subsd xmm0, xmm1
    movsd [rcx + AABB_MINZ], xmm0
    addsd xmm0, xmm1
    addsd xmm0, xmm1
    movsd [rcx + AABB_MAXZ], xmm0
    movsd xmm0, [rel g_pl_pos + 8]
    movsd [rcx + AABB_MINY], xmm0
    cvtss2sd xmm2, [rel s_height]
    addsd xmm0, xmm2
    movsd [rcx + AABB_MAXY], xmm0
    ret

; box_shift — move an AABB along one axis.   in: rcx, edx = axis, xmm0 = d
box_shift:
    movsd xmm1, [rcx + rdx * 8]
    addsd xmm1, xmm0
    movsd [rcx + rdx * 8], xmm1
    movsd xmm1, [rcx + 24 + rdx * 8]
    addsd xmm1, xmm0
    movsd [rcx + 24 + rdx * 8], xmm1
    ret

; box_copy — rdx = destination, rcx = source (48 bytes).  clobbers xmm0
box_copy:
%assign i 0
%rep 6
    movsd xmm0, [rcx + i * 8]
    movsd [rdx + i * 8], xmm0
%assign i i + 1
%endrep
    ret

; -----------------------------------------------------------------------------
; sweep — move an AABB by a vector against the gathered boxes: y, then x,
; then z.
;   in:  rcx = AABB (moved), rdx = requested move (3 doubles), r8 = result
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC sweep, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
%macro SWEEP_AXIS 1
    movsd xmm0, [rsi + %1 * 8]
    mov rcx, rbx
    mov edx, %1
    call phys_clip
    movsd [rdi + %1 * 8], xmm0
    mov rcx, rbx
    mov edx, %1
    call box_shift
%endmacro
    SWEEP_AXIS 1
    SWEEP_AXIS 0
    SWEEP_AXIS 2
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; edge_guard — sneaking on the ground: shorten the horizontal move until the
; body would still stand on something (a drop deeper than step_height).
;   in:  ecx = axis mask (1 x, 4 z: both moved together)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC edge_guard, 0, rbx
    mov ebx, ecx
.try:
    ; nothing left to shorten?
    xorps xmm0, xmm0
    test ebx, 1
    jz .no_x
    comisd xmm0, [rel g_move]
    jne .test
.no_x:
    test ebx, 4
    jz .done
    comisd xmm0, [rel g_move + 16]
    je .done
.test:
    lea rcx, [rel g_box]
    lea rdx, [rel g_box2]
    call box_copy
    lea rcx, [rel g_box2]
    mov edx, 1
    cvtss2sd xmm0, [rel s_step]
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movsd xmm0, xmm1
    call box_shift
    test ebx, 1
    jz .shift_z
    lea rcx, [rel g_box2]
    xor edx, edx
    movsd xmm0, [rel g_move]
    call box_shift
.shift_z:
    test ebx, 4
    jz .check
    lea rcx, [rel g_box2]
    mov edx, 2
    movsd xmm0, [rel g_move + 16]
    call box_shift
.check:
    lea rcx, [rel g_box2]
    call phys_overlap
    test eax, eax
    jnz .done                           ; still supported
    test ebx, 1
    jz .shrink_z
    lea rcx, [rel g_move]
    call shrink
.shrink_z:
    test ebx, 4
    jz .try
    lea rcx, [rel g_move + 16]
    call shrink
    jmp .try
.done:
    RETURN
ENDPROC

; shrink — move a double toward 0 by c_edge_step (to 0 if smaller). rcx = ptr
shrink:
    movsd xmm0, [rcx]
    movapd xmm1, xmm0
    andpd xmm1, [rel c_abs_d]
    comisd xmm1, [rel c_edge_step]
    jbe .zero
    xorps xmm2, xmm2
    comisd xmm0, xmm2
    jb .neg
    subsd xmm0, [rel c_edge_step]
    movsd [rcx], xmm0
    ret
.neg:
    addsd xmm0, [rel c_edge_step]
    movsd [rcx], xmm0
    ret
.zero:
    xorps xmm0, xmm0
    movsd [rcx], xmm0
    ret

; approach — v += (target - v) * k   (doubles; xmm0 = v, xmm1 = target,
; xmm2 = k) -> xmm0
%macro APPROACH 0
    subsd xmm1, xmm0
    mulsd xmm1, xmm2
    addsd xmm0, xmm1
%endmacro

; -----------------------------------------------------------------------------
; player_tick — one tick of movement.
;   in:  rcx = INPUT_PKT* (latest input), edx = INB_* bits pressed at any
;        time since the last tick (so short taps are not lost)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define T_FWD       0                   ; f32
%define T_STRAFE    4
%define T_SIN       8
%define T_COS       12
%define T_BUTTONS   16
%define T_TOUCH     20                  ; MOVE_* at the start of the tick
%define T_SPEED     24                  ; f32 target horizontal speed
%define T_ACC       32                  ; f64 approach rate
%define T_ONGROUND  40
%define T_LOWER     48                  ; AABB (48 bytes): the lower body
PROC player_tick, 112, rbx, rsi, rdi, r12
    mov rbx, rcx
    mov eax, [rbx + INPUT_PKT.buttons]
    or eax, edx
    mov [LOCAL(T_BUTTONS)], eax
    mov eax, [rbx + INPUT_PKT.forward]
    mov [LOCAL(T_FWD)], eax
    mov eax, [rbx + INPUT_PKT.strafe]
    mov [LOCAL(T_STRAFE)], eax
    movss xmm0, [rbx + INPUT_PKT.yaw]
    call sincosf
    movss [LOCAL(T_SIN)], xmm0
    movss [LOCAL(T_COS)], xmm1
    mov r12d, [rel g_pl_flags]
    mov eax, r12d
    and eax, PF_ON_GROUND
    mov [LOCAL(T_ONGROUND)], eax
    and r12d, PF_FLYING | PF_NOCLIP     ; the flags rebuilt below

    ; ---- the ground under the player must be generated -------------------------
    test r12d, PF_NOCLIP
    jnz .known
    movsd xmm0, [rel g_pl_pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si ecx, xmm0
    movsd xmm0, [rel g_pl_pos + 8]
    roundsd xmm0, xmm0, 9
    cvttsd2si edx, xmm0
    movsd xmm0, [rel g_pl_pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si r8d, xmm0
    call phys_block
    cmp eax, -1
    jne .known
    or r12d, PF_FROZEN
    xorps xmm0, xmm0
    movsd [rel g_pl_vel], xmm0
    movsd [rel g_pl_vel + 8], xmm0
    movsd [rel g_pl_vel + 16], xmm0
    jmp .flags
.known:

    ; ---- what the body is in -------------------------------------------------------------
    lea rcx, [rel g_box]
    call make_box
    xor eax, eax
    test r12d, PF_NOCLIP
    jnz .touch_done
    lea rcx, [rel g_box]
    call phys_touch
    and eax, MOVE_CLIMB
    mov esi, eax                        ; climbing
    ; liquids: the lower third of the body (feet .. +0.6)
    lea rcx, [rel g_box]
    lea rdx, [LOCAL(T_LOWER)]
    call box_copy
    movsd xmm0, [LOCAL(T_LOWER) + AABB_MINY]
    cvtss2sd xmm1, [rel s_height]
    divsd xmm1, [rel c_three]
    addsd xmm0, xmm1
    movsd [LOCAL(T_LOWER) + AABB_MAXY], xmm0
    lea rcx, [LOCAL(T_LOWER)]
    call phys_touch
    and eax, MOVE_WATER | MOVE_LAVA
    or eax, esi
.touch_done:
    mov [LOCAL(T_TOUCH)], eax
    test eax, MOVE_WATER
    jz .no_water_flag
    or r12d, PF_IN_WATER
.no_water_flag:
    test eax, MOVE_LAVA
    jz .no_lava_flag
    or r12d, PF_IN_LAVA
.no_lava_flag:
    test eax, MOVE_CLIMB
    jz .no_climb_flag
    test r12d, PF_FLYING
    jnz .no_climb_flag
    or r12d, PF_CLIMBING
.no_climb_flag:
    test dword [LOCAL(T_BUTTONS)], INB_SNEAK
    jz .no_sneak_flag
    test r12d, PF_FLYING
    jnz .no_sneak_flag
    or r12d, PF_SNEAKING
.no_sneak_flag:
    test dword [LOCAL(T_BUTTONS)], INB_SPRINT
    jz .no_sprint_flag
    xorps xmm0, xmm0
    comiss xmm0, [LOCAL(T_FWD)]
    jae .no_sprint_flag                 ; sprinting needs forward
    test r12d, PF_SNEAKING
    jnz .no_sprint_flag
    or r12d, PF_SPRINTING
.no_sprint_flag:

    ; ---- target horizontal speed and how fast we reach it -------------------------
    test r12d, PF_NOCLIP
    jz .not_noclip
    movss xmm0, [rel s_flytest]
    mov rax, __?float64?__(1.0)         ; (noclip: immediate)
    jmp .speed_set
.not_noclip:
    test r12d, PF_FLYING
    jz .not_flying
    movss xmm0, [rel s_fly]
    test r12d, PF_SPRINTING
    jz .fly_acc
    mulss xmm0, [rel s_fly_sprint]
.fly_acc:
    cvtss2sd xmm1, [rel s_fly_acc]
    movq rax, xmm1
    jmp .speed_set
.not_flying:
    test r12d, PF_IN_WATER | PF_IN_LAVA
    jz .on_land
    movss xmm0, [rel s_swim]
    test r12d, PF_SPRINTING
    jz .swim_lava
    movss xmm0, [rel s_swim_sprint]
.swim_lava:
    test r12d, PF_IN_LAVA
    jz .swim_acc
    mulss xmm0, [rel s_lava]
.swim_acc:
    cvtss2sd xmm1, [rel s_water_acc]
    movq rax, xmm1
    jmp .speed_set
.on_land:
    movss xmm0, [rel s_walk]
    test r12d, PF_SPRINTING
    jz .not_sprint
    movss xmm0, [rel s_sprint]
.not_sprint:
    test r12d, PF_SNEAKING
    jz .eating
    movss xmm0, [rel s_sneak]
.eating:
    cmp dword [rel g_sv_eating], 0
    je .land_acc
    mulss xmm0, [rel g_sv_eat_speed]    ; (eating: slow, milestone 20)
.land_acc:
    cvtss2sd xmm1, [rel s_air_acc]
    cmp dword [LOCAL(T_ONGROUND)], 0
    je .air
    cvtss2sd xmm1, [rel s_ground_acc]
.air:
    movq rax, xmm1
.speed_set:
    movss [LOCAL(T_SPEED)], xmm0
    mov [LOCAL(T_ACC)], rax

    ; ---- wish = forward * F + strafe * R, length <= 1, times the speed -------------
    ; F = (sin yaw, -cos yaw), R = (cos yaw, sin yaw)   (x, z)
    movss xmm0, [LOCAL(T_FWD)]
    mulss xmm0, [LOCAL(T_SIN)]
    movss xmm1, [LOCAL(T_STRAFE)]
    mulss xmm1, [LOCAL(T_COS)]
    addss xmm0, xmm1                    ; x
    movss xmm2, [LOCAL(T_STRAFE)]
    mulss xmm2, [LOCAL(T_SIN)]
    movss xmm1, [LOCAL(T_FWD)]
    mulss xmm1, [LOCAL(T_COS)]
    subss xmm2, xmm1                    ; z
    movss xmm3, xmm0
    mulss xmm3, xmm0
    movss xmm4, xmm2
    mulss xmm4, xmm2
    addss xmm3, xmm4
    comiss xmm3, [rel c_one_f]
    jbe .wish_len_ok
    sqrtss xmm3, xmm3
    divss xmm0, xmm3
    divss xmm2, xmm3
.wish_len_ok:
    mulss xmm0, [LOCAL(T_SPEED)]
    mulss xmm2, [LOCAL(T_SPEED)]
    cvtss2sd xmm0, xmm0
    cvtss2sd xmm2, xmm2
    movsd [rel g_wish], xmm0
    movsd [rel g_wish + 16], xmm2

    ; ---- horizontal velocity approaches the wish ------------------------------------
    movsd xmm0, [rel g_pl_vel]
    movsd xmm1, [rel g_wish]
    movsd xmm2, [LOCAL(T_ACC)]
    APPROACH
    movsd [rel g_pl_vel], xmm0
    movsd xmm0, [rel g_pl_vel + 16]
    movsd xmm1, [rel g_wish + 16]
    movsd xmm2, [LOCAL(T_ACC)]
    APPROACH
    movsd [rel g_pl_vel + 16], xmm0

    ; ---- vertical velocity ------------------------------------------------------------
    mov eax, [LOCAL(T_BUTTONS)]
    test r12d, PF_FLYING | PF_NOCLIP
    jz .vert_not_flying
    ; flying: jump up, sneak down
    xorps xmm1, xmm1
    test eax, INB_JUMP
    jz .fly_no_up
    addss xmm1, [rel c_one_f]
.fly_no_up:
    test eax, INB_SNEAK
    jz .fly_no_down
    subss xmm1, [rel c_one_f]
.fly_no_down:
    mulss xmm1, [LOCAL(T_SPEED)]
    mulss xmm1, [rel s_fly_vert]
    test r12d, PF_NOCLIP
    jz .fly_v
    movss xmm1, [rel c_zero_f]          ; (noclip: keep the height)
    test eax, INB_JUMP | INB_SNEAK
    jz .fly_v
    movss xmm1, [rel s_fly]
    test eax, INB_JUMP
    jnz .fly_v
    xorps xmm1, [rel c_neg_f]
.fly_v:
    cvtss2sd xmm1, xmm1
    movsd xmm0, [rel g_pl_vel + 8]
    movsd xmm2, [LOCAL(T_ACC)]
    APPROACH
    movsd [rel g_pl_vel + 8], xmm0
    jmp .vert_done
.vert_not_flying:
    test r12d, PF_IN_WATER | PF_IN_LAVA
    jz .vert_land
    ; swimming: towards sink speed, swim up with jump, dive with sneak
    movss xmm1, [rel s_sink]
    xorps xmm1, [rel c_neg_f]
    test eax, INB_SNEAK
    jz .swim_not_down
    movss xmm1, [rel s_swim_up]
    xorps xmm1, [rel c_neg_f]
.swim_not_down:
    test eax, INB_JUMP
    jz .swim_v
    movss xmm1, [rel s_swim_up]
.swim_v:
    cvtss2sd xmm1, xmm1
    movsd xmm0, [rel g_pl_vel + 8]
    cvtss2sd xmm2, [rel s_water_acc]
    APPROACH
    ; jumping against a bank: climb out
    test eax, INB_JUMP
    jz .swim_store
    cmp dword [rel g_hit_h], 0
    je .swim_store
    cvtss2sd xmm1, [rel s_jump]
    mulsd xmm1, [rel c_bank]
    maxsd xmm0, xmm1
.swim_store:
    movsd [rel g_pl_vel + 8], xmm0
    jmp .climbing
.vert_land:
    ; gravity, terminal speed, jump from the ground
    movsd xmm0, [rel g_pl_vel + 8]
    cvtss2sd xmm1, [rel g_gravity]
    mulsd xmm1, [rel c_dt]
    subsd xmm0, xmm1
    cvtss2sd xmm1, [rel s_terminal]
    xorpd xmm2, xmm2
    subsd xmm2, xmm1
    maxsd xmm0, xmm2
    test eax, INB_JUMP
    jz .land_store
    cmp dword [LOCAL(T_ONGROUND)], 0
    je .land_store
    cvtss2sd xmm0, [rel s_jump]
.land_store:
    movsd [rel g_pl_vel + 8], xmm0
.climbing:
    test r12d, PF_CLIMBING
    jz .vert_done
    ; ladders: slow fall, up with jump or walking into the wall, sneak holds
    movsd xmm0, [rel g_pl_vel + 8]
    cvtss2sd xmm1, [rel s_climb_down]
    xorpd xmm2, xmm2
    subsd xmm2, xmm1
    maxsd xmm0, xmm2
    mov eax, [LOCAL(T_BUTTONS)]
    test eax, INB_SNEAK
    jz .climb_up
    xorpd xmm2, xmm2
    maxsd xmm0, xmm2
    jmp .climb_store
.climb_up:
    test eax, INB_JUMP
    jnz .climb_go
    cmp dword [rel g_hit_h], 0
    je .climb_store
.climb_go:
    cvtss2sd xmm0, [rel s_climb]
.climb_store:
    movsd [rel g_pl_vel + 8], xmm0
.vert_done:

    ; ---- the move this tick --------------------------------------------------------------
%assign i 0
%rep 3
    movsd xmm0, [rel g_pl_vel + i * 8]
    mulsd xmm0, [rel c_dt]
    movsd [rel g_move + i * 8], xmm0
%assign i i + 1
%endrep
    test r12d, PF_NOCLIP
    jz .collide
%assign i 0
%rep 3
    movsd xmm0, [rel g_pl_pos + i * 8]
    addsd xmm0, [rel g_move + i * 8]
    movsd [rel g_pl_pos + i * 8], xmm0
%assign i i + 1
%endrep
    mov dword [rel g_hit_h], 0
    jmp .eye

.collide:
    ; gather the boxes around body + move (+ step height above and below)
    cvtss2sd xmm3, [rel s_step]
    addsd xmm3, [rel c_half]            ; margin
%assign i 0
%rep 3
    movsd xmm2, [rel g_move + i * 8]
    andpd xmm2, [rel c_abs_d]
    addsd xmm2, xmm3
    movsd xmm0, [rel g_box + i * 8]
    subsd xmm0, xmm2
    movsd [rel g_region + i * 8], xmm0
    movsd xmm0, [rel g_box + 24 + i * 8]
    addsd xmm0, xmm2
    movsd [rel g_region + 24 + i * 8], xmm0
%assign i i + 1
%endrep
    lea rcx, [rel g_region]
    call phys_gather

    ; sneaking on the ground: don't walk off edges
    test r12d, PF_SNEAKING
    jz .no_guard
    cmp dword [LOCAL(T_ONGROUND)], 0
    je .no_guard
    mov ecx, 1
    call edge_guard
    mov ecx, 4
    call edge_guard
    mov ecx, 5
    call edge_guard
.no_guard:

    ; move: y, x, z
    lea rcx, [rel g_box]
    lea rdx, [rel g_move]
    lea r8, [rel g_res]
    call sweep
    ; blocked sideways on the ground (or climbing out of water): step up
    call hit_sideways
    test eax, eax
    jz .no_step
    cmp dword [LOCAL(T_ONGROUND)], 0
    je .no_step
    lea rcx, [rel g_box2]
    call make_box
    ; up by step_height (as far as there is room), sideways, back down
    cvtss2sd xmm0, [rel s_step]
    lea rcx, [rel g_box2]
    mov edx, 1
    call phys_clip
    movsd [LOCAL(T_LOWER)], xmm0        ; (reused: the rise)
    lea rcx, [rel g_box2]
    mov edx, 1
    call box_shift
    movsd xmm0, [rel g_move]
    lea rcx, [rel g_box2]
    xor edx, edx
    call phys_clip
    movsd [rel g_res2], xmm0
    lea rcx, [rel g_box2]
    xor edx, edx
    call box_shift
    movsd xmm0, [rel g_move + 16]
    lea rcx, [rel g_box2]
    mov edx, 2
    call phys_clip
    movsd [rel g_res2 + 16], xmm0
    lea rcx, [rel g_box2]
    mov edx, 2
    call box_shift
    xorpd xmm0, xmm0
    subsd xmm0, [LOCAL(T_LOWER)]
    movsd xmm1, [rel g_move + 8]
    minsd xmm1, [rel c_zero_d]
    addsd xmm0, xmm1                    ; down by the rise (+ the fall)
    lea rcx, [rel g_box2]
    mov edx, 1
    call phys_clip
    movsd xmm2, xmm0
    lea rcx, [rel g_box2]
    mov edx, 1
    call box_shift
    ; better than the plain move? (farther sideways)
    movsd xmm0, [rel g_res2]
    mulsd xmm0, xmm0
    movsd xmm1, [rel g_res2 + 16]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    movsd xmm1, [rel g_res]
    mulsd xmm1, xmm1
    movsd xmm2, [rel g_res + 16]
    mulsd xmm2, xmm2
    addsd xmm1, xmm2
    addsd xmm1, [rel c_tiny]
    comisd xmm0, xmm1
    jbe .no_step
    lea rcx, [rel g_box2]
    lea rdx, [rel g_box]
    call box_copy
    mov rax, [rel g_res2]
    mov [rel g_res], rax
    mov rax, [rel g_res2 + 16]
    mov [rel g_res + 16], rax
    ; (it ends on the ground: the y move was stopped)
    movsd xmm0, [rel g_box + AABB_MINY]
    subsd xmm0, [rel g_pl_pos + 8]
    movsd [rel g_res + 8], xmm0
    mov rax, [rel c_big_down]
    mov [rel g_move + 8], rax
.no_step:
    ; new position: the box's feet centre
    movsd xmm0, [rel g_box + AABB_MINX]
    addsd xmm0, [rel g_box + AABB_MAXX]
    mulsd xmm0, [rel c_half]
    movsd [rel g_pl_pos], xmm0
    movsd xmm0, [rel g_box + AABB_MINZ]
    addsd xmm0, [rel g_box + AABB_MAXZ]
    mulsd xmm0, [rel c_half]
    movsd [rel g_pl_pos + 16], xmm0
    movsd xmm0, [rel g_box + AABB_MINY]
    movsd [rel g_pl_pos + 8], xmm0

    ; collisions stop the velocity on that axis; landing
    call hit_sideways
    mov [rel g_hit_h], eax
    movsd xmm0, [rel g_res]
    comisd xmm0, [rel g_move]
    je .x_free
    xorps xmm1, xmm1
    movsd [rel g_pl_vel], xmm1
.x_free:
    movsd xmm0, [rel g_res + 16]
    comisd xmm0, [rel g_move + 16]
    je .z_free
    xorps xmm1, xmm1
    movsd [rel g_pl_vel + 16], xmm1
.z_free:
    movsd xmm0, [rel g_res + 8]
    comisd xmm0, [rel g_move + 8]
    je .eye
    xorps xmm1, xmm1
    comisd xmm1, [rel g_move + 8]
    jbe .y_stop                         ; moving up: hit the ceiling
    or r12d, PF_ON_GROUND
    and r12d, ~PF_FLYING                ; landing ends a flight
.y_stop:
    movsd [rel g_pl_vel + 8], xmm1

.eye:
    ; never fall forever below the world
    movsd xmm0, [rel g_pl_pos + 8]
    comisd xmm0, [rel c_max_fall]
    jae .eye_height
    movsd xmm0, [rel c_max_fall]
    movsd [rel g_pl_pos + 8], xmm0
    xorps xmm0, xmm0
    movsd [rel g_pl_vel + 8], xmm0
.eye_height:
    movss xmm1, [rel s_eye]
    test r12d, PF_SNEAKING
    jz .eye_target
    movss xmm1, [rel s_sneak_eye]
.eye_target:
    movss xmm0, [rel g_pl_eye]
    subss xmm1, xmm0
    mulss xmm1, [rel c_eye_rate]
    addss xmm0, xmm1
    movss [rel g_pl_eye], xmm0
.flags:
    mov [rel g_pl_flags], r12d
    RETURN
ENDPROC

; hit_sideways — eax = 1 if the x or z move was shortened (g_res vs g_move)
hit_sideways:
    xor eax, eax
    movsd xmm0, [rel g_res]
    comisd xmm0, [rel g_move]
    jne .hit
    movsd xmm0, [rel g_res + 16]
    comisd xmm0, [rel g_move + 16]
    jne .hit
    ret
.hit:
    mov eax, 1
    ret

section .rdata
align 8
c_three:        dq 3.0
c_bank:         dq 1.0                  ; climbing out of water: share of a jump
c_big_down:     dq -1.0                 ; (marks "moving down" after a step-up)
align 16
c_neg_f:        dd 0x80000000, 0, 0, 0
c_zero_f:       dd 0.0
