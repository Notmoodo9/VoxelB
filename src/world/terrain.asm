; =============================================================================
; terrain.asm — the overworld terrain generator (design/terrain/
; overworld_terrain.md). Every number lives in data/world/terrain.cfg.
;
; Height of a column (x, z), from 2D noise fields mapped through splines:
;   base   = base_height(continentalness)        oceans .. coast .. inland
;   land   = 0 in the ocean .. 1 inland            (no mountains at sea)
;   hills  = peaks_height(peaks) * mountain_factor(erosion)
;            * (1 + high_factor(high))             hills .. high mountains
;   giant  = giant_mask(giant) * (ridge^3 * giant_height
;            + jag * ridge^2 * jag_height)         rare ridgelines with spires
;   h      = base + land * (hills + rolling_height(rolling) + giant)
;            + detail * detail_height
;   rivers: where |river| is small the height is pulled down to river_bed
;           (valleys wider in lowlands, gorges in hills, none above
;           gorge_max)
; Overhangs and arches: in mountains, 3D noise adds +/- overhang amplitude
; around the surface. Surfaces by height and slope (grass, sand beaches,
; gravel shores and scree, stone cliffs, snow above the snow line), dirt
; below, then stone, deep stone below ~Y 0 and bedrock at the bottom.
; Air below sea level is water.
;
; Public API:
;   terrain_load() -> eax 1/0        read terrain.cfg (blocks must be loaded)
;   terrain_gen_column(COLUMN*, ARENA*)  fill the 40 sections of a column
;   terrain_sample(x, z, TSAMPLE*)   noise values and height at a point
;       in: xmm0 = x, xmm1 = z (doubles), rcx = TSAMPLE*
;   terrain_find_spawn(out 3 doubles)  a land position near the origin
;   terrain_survey()                 log statistics of a 25.6 x 25.6 km area
;                                    (ocean share, height tiers, rivers) and
;                                    where to see a giant range, the highest
;                                    point and a river (--survey)
;   g_world_seed, g_sea_level
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "noise.inc"
%include "block.inc"
%include "section.inc"
%include "world_api.inc"
%include "terrain.inc"

global terrain_load, terrain_gen_column, terrain_sample, terrain_find_spawn
global terrain_survey
global g_world_seed, g_sea_level

extern str_ieq, str_parse_float, str_parse_u64

%define FIELD_COUNT     11
%define F_CONT          0
%define F_EROS          1
%define F_PEAKS         2
%define F_HIGH          3
%define F_GIANT         4
%define F_RIDGES        5
%define F_JAG           6
%define F_ROLLING       7
%define F_RIVER         8
%define F_DETAIL        9
%define F_OVERHANG      10

%define SPLINE_COUNT    6
%define S_BASE          0
%define S_MOUNT         1
%define S_PEAKS         2
%define S_HIGH          3
%define S_GIANT         4
%define S_ROLLING       5
%define SPLINE_MAX      16
struc SPLINE
    .count      resd 1
    .x          resd SPLINE_MAX
    .y          resd SPLINE_MAX
endstruc

; setting types
%define T_FLOAT         0
%define T_INT           1
%define T_BLOCK         2

%define HM              34              ; heightmap side (column + 1 border)

section .rdata
str_cfg_path:   db "data/world/terrain.cfg", 0
str_cfg_label:  db "terrain.cfg", 0
k_noise:        db "noise", 0
k_spline:       db "spline", 0
k_scale:        db "scale", 0
k_octaves:      db "octaves", 0
k_persistence:  db "persistence", 0
k_ridged:       db "ridged", 0
k_salt:         db "salt", 0
k_point:        db "point", 0
str_unknown:    db "unknown setting: ", 0
str_bad:        db "bad value for: ", 0
str_bad_rec:    db "unknown record: ", 0
str_bad_block:  db "unknown block: ", 0
str_x:          db " x ", 0
str_z:          db " z ", 0
str_minus:      db "-", 0
str_highest:    db "survey: highest point at", 0
str_giant_at:   db "survey: nearest giant range at", 0
str_river_at:   db "survey: nearest river at", 0
; field names (records [noise <name>])
n_cont:     db "continentalness", 0
n_eros:     db "erosion", 0
n_peaks:    db "peaks", 0
n_high:     db "high", 0
n_giant:    db "giant", 0
n_ridges:   db "ridges", 0
n_jag:      db "jag", 0
n_rolling:  db "rolling", 0
n_river:    db "river", 0
n_detail:   db "detail", 0
n_overhang: db "overhang", 0
align 8
field_names:    dq n_cont, n_eros, n_peaks, n_high, n_giant, n_ridges, n_jag
                dq n_rolling, n_river, n_detail, n_overhang
; spline names (records [spline <name>])
s_base:     db "base_height", 0
s_mount:    db "mountain_factor", 0
s_peaks:    db "peaks_height", 0
s_high:     db "high_factor", 0
s_giant:    db "giant_mask", 0
s_rolling:  db "rolling_height", 0
align 8
spline_names:   dq s_base, s_mount, s_peaks, s_high, s_giant, s_rolling
; top-level settings: name, type, address
k_sea:          db "sea_level", 0
k_land_start:   db "land_start", 0
k_land_ramp:    db "land_ramp", 0
k_giant_h:      db "giant_height", 0
k_jag_h:        db "jag_height", 0
k_detail_h:     db "detail_height", 0
k_river_w:      db "river_width", 0
k_river_widen:  db "river_widen", 0
k_river_bed:    db "river_bed", 0
k_gorge_max:    db "gorge_max", 0
k_over_amp:     db "overhang_amplitude", 0
k_over_start:   db "overhang_start", 0
k_max_h:        db "max_height", 0
k_snow:         db "snow_line", 0
k_snow_var:     db "snow_line_variation", 0
k_snow_cap:     db "snow_cap_above", 0
k_beach_lo:     db "beach_low", 0
k_beach_hi:     db "beach_high", 0
k_steep:        db "steep_slope", 0
k_scree:        db "scree_slope", 0
k_scree_y:      db "scree_min_y", 0
k_deep_y:       db "deep_stone_y", 0
k_b_top:        db "top_block", 0
k_b_fill:       db "filler_block", 0
k_b_stone:      db "stone_block", 0
k_b_deep:       db "deep_block", 0
k_b_bedrock:    db "bedrock_block", 0
k_b_beach:      db "beach_block", 0
k_b_gravel:     db "gravel_block", 0
k_b_snow:       db "snow_block", 0
k_b_water:      db "water_block", 0
k_b_clay:       db "seabed_clay_block", 0
align 8
settings:
    dq k_sea,        T_INT,   g_sea_level
    dq k_land_start, T_FLOAT, g_land_start
    dq k_land_ramp,  T_FLOAT, g_land_ramp
    dq k_giant_h,    T_FLOAT, g_giant_height
    dq k_jag_h,      T_FLOAT, g_jag_height
    dq k_detail_h,   T_FLOAT, g_detail_height
    dq k_river_w,    T_FLOAT, g_river_width
    dq k_river_widen, T_FLOAT, g_river_widen
    dq k_river_bed,  T_FLOAT, g_river_bed
    dq k_gorge_max,  T_FLOAT, g_gorge_max
    dq k_over_amp,   T_FLOAT, g_over_amp
    dq k_over_start, T_FLOAT, g_over_start
    dq k_max_h,      T_FLOAT, g_max_height
    dq k_snow,       T_INT,   g_snow_line
    dq k_snow_var,   T_FLOAT, g_snow_var
    dq k_snow_cap,   T_INT,   g_snow_cap
    dq k_beach_lo,   T_INT,   g_beach_low
    dq k_beach_hi,   T_INT,   g_beach_high
    dq k_steep,      T_INT,   g_steep
    dq k_scree,      T_INT,   g_scree
    dq k_scree_y,    T_INT,   g_scree_y
    dq k_deep_y,     T_INT,   g_deep_y
    dq k_b_top,      T_BLOCK, g_b_top
    dq k_b_fill,     T_BLOCK, g_b_fill
    dq k_b_stone,    T_BLOCK, g_b_stone
    dq k_b_deep,     T_BLOCK, g_b_deep
    dq k_b_bedrock,  T_BLOCK, g_b_bedrock
    dq k_b_beach,    T_BLOCK, g_b_beach
    dq k_b_gravel,   T_BLOCK, g_b_gravel
    dq k_b_snow,     T_BLOCK, g_b_snow
    dq k_b_water,    T_BLOCK, g_b_water
    dq k_b_clay,     T_BLOCK, g_b_clay
    dq 0
align 4
c_zero:     dd 0.0
c_half:     dd 0.5
c_one:      dd 1.0
c_two:      dd 2.0
c_three:    dd 3.0
c_120:      dd 120.0
c_150:      dd 150.0
c_spawn_up: dd 24.0
c_08:       dd 0.8
c_six:      dd 6.0
c_1000:     dd 1000.0
c_quarter:  dd 0.25
c_eighth:   dd 0.125
align 8
c_one_d:    dq 1.0
c_half_d:   dq 0.5
c_gx_step:  dq 4.0
align 16
c_abs:      dd 0x7FFFFFFF, 0, 0, 0

section .data
align 4
g_world_seed:   dd 20261009
g_sea_level:    dd 96
g_land_start:   dd -0.12
g_land_ramp:    dd 0.25
g_giant_height: dd 650.0
g_jag_height:   dd 160.0
g_detail_height: dd 2.0
g_river_width:  dd 0.022
g_river_widen:  dd 5.0
g_river_bed:    dd 93.0
g_gorge_max:    dd 450.0
g_over_amp:     dd 40.0
g_over_start:   dd 160.0
g_max_height:   dd 1010.0
g_snow_line:    dd 300
g_snow_var:     dd 20.0
g_snow_cap:     dd 200
g_beach_low:    dd 94
g_beach_high:   dd 99
g_steep:        dd 4
g_scree:        dd 3
g_scree_y:      dd 180
g_deep_y:       dd 0

section .bss
alignb 8
g_noise:        resb NOISE_size * FIELD_COUNT
g_splines:      resb SPLINE_size * SPLINE_COUNT
g_cfg_mark:     resq 1
g_kind:         resd 1                  ; 0 none, 1 noise, 2 spline
g_rec:          resd 1
g_b_top:        resd 1
g_b_fill:       resd 1
g_b_stone:      resd 1
g_b_deep:       resd 1
g_b_bedrock:    resd 1
g_b_beach:      resd 1
g_b_gravel:     resd 1
g_b_snow:       resd 1
g_b_water:      resd 1
g_b_clay:       resd 1
g_cfg_path:     resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; warn — "terrain.cfg: <message><detail>".   in: rcx = message, rdx = detail
; -----------------------------------------------------------------------------
PROC warn, 0
    mov r8, rdx
    mov rdx, rcx
    lea rcx, [rel str_cfg_label]
    call cfg_warn
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; parse_f — float value or warn.   in: rcx = text, rdx = key
;   out: xmm0, eax = 1 if valid
; -----------------------------------------------------------------------------
PROC parse_f, 0, rbx
    mov rbx, rdx
    call str_parse_float
    test eax, eax
    jnz .ok
    lea rcx, [rel str_bad]
    mov rdx, rbx
    call warn
    xor eax, eax
.ok:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; find_in — index of a name in a table of char*.
;   in:  rcx = table, edx = count, r8 = name      out: eax = index or -1
; -----------------------------------------------------------------------------
PROC find_in, 0, rbx, rsi, rdi, r12
    mov rsi, rcx
    mov edi, edx
    mov r12, r8
    xor ebx, ebx
.next:
    cmp ebx, edi
    jae .none
    INVOKE str_ieq, [rsi + rbx * 8], r12
    test eax, eax
    jnz .found
    inc ebx
    jmp .next
.found:
    mov eax, ebx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; terrain_pair — cfg_parse_ex callback for terrain.cfg.
;   in:  rcx = name (or header), rdx = value (0 for a header)
; -----------------------------------------------------------------------------
PROC terrain_pair, 16, rbx, rsi, rdi, r12
    mov rbx, rcx
    mov rsi, rdx
    test rdx, rdx
    jnz .pair
    ; "[noise <name>]" / "[spline <name>]"
    mov dword [rel g_kind], 0
    mov rcx, rbx
.blank:
    mov al, [rcx]
    test al, al
    jz .bad_rec
    cmp al, ' '
    je .split
    inc rcx
    jmp .blank
.split:
    mov byte [rcx], 0
    lea rdi, [rcx + 1]
.skip:
    cmp byte [rdi], ' '
    jne .kind
    inc rdi
    jmp .skip
.kind:
    lea rdx, [rel k_noise]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_noise
    lea rcx, [rel field_names]
    mov edx, FIELD_COUNT
    mov r8, rdi
    call find_in
    cmp eax, -1
    je .bad_rec
    mov [rel g_rec], eax
    mov dword [rel g_kind], 1
    RETURN
.not_noise:
    lea rdx, [rel k_spline]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .bad_rec
    lea rcx, [rel spline_names]
    mov edx, SPLINE_COUNT
    mov r8, rdi
    call find_in
    cmp eax, -1
    je .bad_rec
    mov [rel g_rec], eax
    imul rcx, rax, SPLINE_size
    lea rdx, [rel g_splines]
    mov dword [rdx + rcx], 0            ; the record replaces the spline
    mov dword [rel g_kind], 2
    RETURN
.bad_rec:
    lea rcx, [rel str_bad_rec]
    mov rdx, rbx
    call warn
    RETURN

.pair:
    mov eax, [rel g_kind]
    cmp eax, 1
    je .noise
    cmp eax, 2
    je .spline
    ; top-level setting
    lea rdi, [rel settings]
.setting:
    mov rcx, [rdi]
    test rcx, rcx
    jz .unknown
    INVOKE str_ieq, rcx, rbx
    test eax, eax
    jnz .set
    add rdi, 24
    jmp .setting
.set:
    mov r12, [rdi + 16]                 ; address
    mov rax, [rdi + 8]
    cmp eax, T_FLOAT
    je .set_float
    cmp eax, T_INT
    je .set_int
    INVOKE block_find, rsi
    cmp eax, -1
    je .bad_block
    mov [r12], eax
    RETURN
.set_float:
    mov rcx, rsi
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    movss [r12], xmm0
    RETURN
.set_int:
    mov rcx, rsi
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    cvttss2si eax, xmm0
    mov [r12], eax
    RETURN
.bad_block:
    lea rcx, [rel str_bad_block]
    mov rdx, rsi
    call warn
    RETURN
.unknown:
    lea rcx, [rel str_unknown]
    mov rdx, rbx
    call warn
    RETURN

.noise:
    mov eax, [rel g_rec]
    imul rdi, rax, NOISE_size
    lea rax, [rel g_noise]
    add rdi, rax
    mov rcx, rsi
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    movss [LOCAL(0)], xmm0
    lea rdx, [rel k_scale]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .n_oct
    movss xmm0, [LOCAL(0)]
    cvtss2sd xmm0, xmm0
    movsd xmm1, [rel c_one_d]
    divsd xmm1, xmm0
    movsd [rdi + NOISE.freq], xmm1
    RETURN
.n_oct:
    cvttss2si r12d, [LOCAL(0)]
    lea rdx, [rel k_octaves]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .n_pers
    mov [rdi + NOISE.octaves], r12d
    RETURN
.n_pers:
    lea rdx, [rel k_persistence]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .n_ridged
    movss xmm0, [LOCAL(0)]
    movss [rdi + NOISE.persistence], xmm0
    RETURN
.n_ridged:
    lea rdx, [rel k_ridged]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .n_salt
    mov [rdi + NOISE.ridged], r12d
    RETURN
.n_salt:
    lea rdx, [rel k_salt]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov [rdi + NOISE.salt], r12d
    RETURN

.spline:                                ; point = x, y
    lea rdx, [rel k_point]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .unknown
    mov eax, [rel g_rec]
    imul rdi, rax, SPLINE_size
    lea rax, [rel g_splines]
    add rdi, rax
    mov eax, [rdi + SPLINE.count]
    cmp eax, SPLINE_MAX
    jae .bad
    mov rcx, rsi
    call cfg_next_token
    mov r12, rdx
    mov rcx, rax
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    test r12, r12
    jz .bad
    mov eax, [rdi + SPLINE.count]
    movss [rdi + SPLINE.x + rax * 4], xmm0
    mov rcx, r12
    call cfg_next_token
    mov rcx, rax
    mov rdx, rbx
    call parse_f
    test eax, eax
    jz .done
    mov eax, [rdi + SPLINE.count]
    movss [rdi + SPLINE.y + rax * 4], xmm0
    inc dword [rdi + SPLINE.count]
    RETURN
.bad:
    lea rcx, [rel str_bad]
    mov rdx, rbx
    call warn
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; terrain_load — read data/world/terrain.cfg.
;   out: eax = 1 ok, 0 missing file or splines (logged)
; -----------------------------------------------------------------------------
PROC terrain_load, 0, rbx
    ; field defaults: 1 octave at scale 256, persistence 0.5, salt = index
    xor ebx, ebx
.def:
    imul rcx, rbx, NOISE_size
    lea rax, [rel g_noise]
    add rcx, rax
    mov rax, 0x3F70000000000000         ; 1/256
    mov [rcx + NOISE.freq], rax
    mov dword [rcx + NOISE.octaves], 1
    mov dword [rcx + NOISE.persistence], 0x3F000000
    lea eax, [ebx + 1]
    mov [rcx + NOISE.salt], eax
    mov dword [rcx + NOISE.ridged], 0
    inc ebx
    cmp ebx, FIELD_COUNT
    jb .def
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
    lea rdx, [rel terrain_pair]
    lea r9, [rel str_cfg_label]
    INVOKE cfg_parse_ex, rax, rdx, 0, r9, CFG_SECTIONS
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [rel g_cfg_mark]
    ; every spline needs points, every block must be set
    xor ebx, ebx
.check:
    imul rcx, rbx, SPLINE_size
    lea rax, [rel g_splines]
    cmp dword [rax + rcx], 0
    je .incomplete
    inc ebx
    cmp ebx, SPLINE_COUNT
    jb .check
    cmp dword [rel g_b_stone], 0
    je .incomplete
    cmp dword [rel g_b_water], 0
    je .incomplete
    mov eax, [rel g_world_seed]
    LOG_VAL LOG_LEVEL_INFO, "terrain: generator ready, seed", rax
    mov eax, 1
    RETURN
.missing:
    LOG_ERROR "terrain: could not read data/world/terrain.cfg"
    xor eax, eax
    RETURN
.incomplete:
    LOG_ERROR "terrain: terrain.cfg lacks a spline or a block setting"
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; spline_eval — piecewise-linear curve, clamped at both ends.
;   in:  rcx = SPLINE*, xmm0 = x     out: xmm0 = y
;   clobbers: rax, rdx, xmm0-xmm3
; -----------------------------------------------------------------------------
spline_eval:
    mov edx, [rcx + SPLINE.count]
    comiss xmm0, [rcx + SPLINE.x]
    jbe .first
    xor eax, eax
.seg:
    lea r8d, [eax + 1]
    cmp r8d, edx
    jae .last
    comiss xmm0, [rcx + SPLINE.x + r8 * 4]
    jbe .lerp
    inc eax
    jmp .seg
.lerp:
    ; t = (x - x0) / (x1 - x0); y = y0 + t (y1 - y0)
    movss xmm1, [rcx + SPLINE.x + r8 * 4]
    subss xmm1, [rcx + SPLINE.x + rax * 4]
    subss xmm0, [rcx + SPLINE.x + rax * 4]
    divss xmm0, xmm1
    movss xmm2, [rcx + SPLINE.y + r8 * 4]
    subss xmm2, [rcx + SPLINE.y + rax * 4]
    mulss xmm0, xmm2
    addss xmm0, [rcx + SPLINE.y + rax * 4]
    ret
.first:
    movss xmm0, [rcx + SPLINE.y]
    ret
.last:
    dec edx
    movss xmm0, [rcx + SPLINE.y + rdx * 4]
    ret

; -----------------------------------------------------------------------------
; clamp01 — xmm0 = clamp(xmm0, 0, 1).   clobbers: xmm1
; -----------------------------------------------------------------------------
clamp01:
    xorps xmm1, xmm1
    maxss xmm0, xmm1
    minss xmm0, [rel c_one]
    ret

; -----------------------------------------------------------------------------
; terrain_sample — all noise fields and the height at a point.
;   in:  xmm0 = x, xmm1 = z (doubles), rcx = TSAMPLE*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define TS_X    0
%define TS_Z    8
PROC terrain_sample, 16, rbx, rsi
    mov rbx, rcx
    movsd [LOCAL(TS_X)], xmm0
    movsd [LOCAL(TS_Z)], xmm1
    xor esi, esi
.field:
    cmp esi, F_OVERHANG                 ; (overhang is the 3D field)
    jae .fields_done
    imul rcx, rsi, NOISE_size
    lea rax, [rel g_noise]
    add rcx, rax
    movsd xmm1, [LOCAL(TS_X)]
    movsd xmm2, [LOCAL(TS_Z)]
    mov edx, [rel g_world_seed]
    call fbm2
    movss [rbx + TSAMPLE.fields + rsi * 4], xmm0
    inc esi
    jmp .field
.fields_done:
    ; base = base_height(C)
    lea rcx, [rel g_splines + S_BASE * SPLINE_size]
    movss xmm0, [rbx + TSAMPLE.fields + F_CONT * 4]
    call spline_eval
    movss [rbx + TSAMPLE.height], xmm0
    ; land = clamp((C - land_start) / land_ramp)
    movss xmm0, [rbx + TSAMPLE.fields + F_CONT * 4]
    subss xmm0, [rel g_land_start]
    divss xmm0, [rel g_land_ramp]
    call clamp01
    movss [rbx + TSAMPLE.land], xmm0
    ; mountain factor, high factor
    lea rcx, [rel g_splines + S_MOUNT * SPLINE_size]
    movss xmm0, [rbx + TSAMPLE.fields + F_EROS * 4]
    call spline_eval
    movss [rbx + TSAMPLE.mount], xmm0
    lea rcx, [rel g_splines + S_HIGH * SPLINE_size]
    movss xmm0, [rbx + TSAMPLE.fields + F_HIGH * 4]
    call spline_eval
    addss xmm0, [rel c_one]
    movss [rbx + TSAMPLE.extra], xmm0   ; 1 + high
    ; hills = peaks_height(P) * mount * (1 + high)
    lea rcx, [rel g_splines + S_PEAKS * SPLINE_size]
    movss xmm0, [rbx + TSAMPLE.fields + F_PEAKS * 4]
    call spline_eval
    mulss xmm0, [rbx + TSAMPLE.mount]
    mulss xmm0, [rbx + TSAMPLE.extra]
    movss [rbx + TSAMPLE.extra], xmm0   ; hills
    ; + rolling
    lea rcx, [rel g_splines + S_ROLLING * SPLINE_size]
    movss xmm0, [rbx + TSAMPLE.fields + F_ROLLING * 4]
    call spline_eval
    addss xmm0, [rbx + TSAMPLE.extra]
    movss [rbx + TSAMPLE.extra], xmm0
    ; giant = mask * (r^3 * giant_height + j * r^2 * jag_height)
    lea rcx, [rel g_splines + S_GIANT * SPLINE_size]
    movss xmm0, [rbx + TSAMPLE.fields + F_GIANT * 4]
    call spline_eval
    call clamp01
    movss [rbx + TSAMPLE.giant], xmm0
    movss xmm4, [rbx + TSAMPLE.fields + F_RIDGES * 4]
    addss xmm4, [rel c_one]
    mulss xmm4, [rel c_half]            ; r in 0..1
    movss xmm0, xmm4
    call clamp01
    movss xmm4, xmm0
    movss xmm5, [rbx + TSAMPLE.fields + F_JAG * 4]
    addss xmm5, [rel c_one]
    mulss xmm5, [rel c_half]            ; j in 0..1
    movss xmm2, xmm4
    mulss xmm2, xmm4                    ; r^2
    movss xmm3, xmm2
    mulss xmm3, xmm4                    ; r^3
    mulss xmm3, [rel g_giant_height]
    mulss xmm2, xmm5
    mulss xmm2, [rel g_jag_height]
    addss xmm3, xmm2
    mulss xmm3, [rbx + TSAMPLE.giant]
    addss xmm3, [rbx + TSAMPLE.extra]
    mulss xmm3, [rbx + TSAMPLE.land]
    addss xmm3, [rbx + TSAMPLE.height]
    movss xmm0, [rbx + TSAMPLE.fields + F_DETAIL * 4]
    mulss xmm0, [rel g_detail_height]
    addss xmm3, xmm0                    ; h
    ; rivers: t = smoothstep over (|river| - w) / (valley - w)
    movss xmm0, [rbx + TSAMPLE.fields + F_RIVER * 4]
    andps xmm0, [rel c_abs]
    subss xmm0, [rel g_river_width]
    movss xmm1, [rel c_one]
    subss xmm1, [rbx + TSAMPLE.mount]
    maxss xmm1, [rel c_zero]
    mulss xmm1, [rel g_river_widen]
    mulss xmm1, [rel g_river_width]     ; valley - w
    addss xmm1, [rel g_river_width]
    divss xmm0, xmm1
    movss [rbx + TSAMPLE.river], xmm0   ; (before clamping, for the overlay)
    call clamp01
    movss xmm1, xmm0                    ; t
    mulss xmm1, xmm0
    movss xmm2, [rel c_three]
    subss xmm2, xmm0
    subss xmm2, xmm0
    mulss xmm1, xmm2                    ; t^2 (3 - 2t)
    ; carved = bed + (h - bed) * t when h > bed
    movss xmm2, xmm3
    subss xmm2, [rel g_river_bed]
    xorps xmm0, xmm0
    comiss xmm2, xmm0
    jbe .no_river
    mulss xmm2, xmm1
    addss xmm2, [rel g_river_bed]       ; carved height
    ; k = clamp((gorge_max - h) / 150) * land
    movss xmm0, [rel g_gorge_max]
    subss xmm0, xmm3
    divss xmm0, [rel c_150]
    movss xmm4, xmm2
    call clamp01
    mulss xmm0, [rbx + TSAMPLE.land]
    subss xmm4, xmm3
    mulss xmm4, xmm0
    addss xmm3, xmm4
.no_river:
    minss xmm3, [rel g_max_height]
    movss [rbx + TSAMPLE.height], xmm3
    ; overhang amplitude = clamp((h - start) / 120) * amp * max(mount, giant)
    movss xmm0, xmm3
    subss xmm0, [rel g_over_start]
    divss xmm0, [rel c_120]
    call clamp01
    mulss xmm0, [rel g_over_amp]
    movss xmm1, [rbx + TSAMPLE.mount]
    maxss xmm1, [rbx + TSAMPLE.giant]
    minss xmm1, [rel c_one]
    mulss xmm0, xmm1
    movss [rbx + TSAMPLE.overhang], xmm0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; terrain_find_spawn — the first land point (sea level + 3 .. 180) on rings
; of growing size around the origin (32-block steps).
;   in:  rcx = out (3 doubles: x, y, z)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC terrain_find_spawn, TSAMPLE_size + 16, rbx, rsi, rdi, r12
    mov rbx, rcx
    xor esi, esi                        ; ring
.ring:
    cmp esi, 96
    jae .give_up
    mov edi, esi
    neg edi                             ; dz
.row:
    cmp edi, esi
    jg .next_ring
    mov r12d, esi
    neg r12d                            ; dx
.col:
    cmp r12d, esi
    jg .next_row
    ; only the ring's border
    mov eax, r12d
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, esi
    je .try
    mov eax, edi
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, esi
    jne .next_col
.try:
    mov eax, r12d
    shl eax, 5
    cvtsi2sd xmm0, eax
    addsd xmm0, [rel c_half_d]
    mov eax, edi
    shl eax, 5
    cvtsi2sd xmm1, eax
    addsd xmm1, [rel c_half_d]
    movsd [LOCAL(TSAMPLE_size)], xmm0
    movsd [LOCAL(TSAMPLE_size + 8)], xmm1
    lea rcx, [LOCAL(0)]
    call terrain_sample
    cvttss2si eax, [LOCAL(TSAMPLE.height)]
    mov ecx, [rel g_sea_level]
    add ecx, 3
    cmp eax, ecx
    jl .next_col
    cmp eax, 180
    jg .next_col
    movsd xmm0, [LOCAL(TSAMPLE_size)]
    movsd [rbx], xmm0
    movss xmm0, [LOCAL(TSAMPLE.height)]
    addss xmm0, [rel c_spawn_up]
    cvtss2sd xmm0, xmm0
    movsd [rbx + 8], xmm0
    movsd xmm0, [LOCAL(TSAMPLE_size + 8)]
    movsd [rbx + 16], xmm0
    RETURN
.next_col:
    inc r12d
    jmp .col
.next_row:
    inc edi
    jmp .row
.next_ring:
    inc esi
    jmp .ring
.give_up:
    ; no land found: hover above the origin
    xorps xmm0, xmm0
    movsd [rbx], xmm0
    movsd [rbx + 16], xmm0
    mov eax, 200
    cvtsi2sd xmm0, eax
    movsd [rbx + 8], xmm0
    RETURN
ENDPROC


; -----------------------------------------------------------------------------
; log_xz — log "<label> x <x> z <z>" with signed coordinates.
;   in:  rcx = label, edx = x, r8d = z
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_xz, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov esi, edx
    mov edi, r8d
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    mov rcx, rbx
    call log_append_str
    lea rcx, [rel str_x]
    call log_append_str
    mov ecx, esi
    call append_signed
    lea rcx, [rel str_z]
    call log_append_str
    mov ecx, edi
    call append_signed
    call log_end
    RETURN
ENDPROC

; append_signed — log_append_dec with a leading '-' for negative values.
;   in: ecx = value
PROC append_signed, 0, rbx
    mov ebx, ecx
    test ebx, ebx
    jns .positive
    lea rcx, [rel str_minus]
    call log_append_str
    neg ebx
.positive:
    mov ecx, ebx
    call log_append_dec
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; terrain_survey — sample a 400 x 400 grid (every 64 blocks, centred on the
; origin) and log the share of ocean, lowland, hills, mountains, high
; mountains and giant ranges, plus coordinates worth visiting.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define SV_GRID     400
%define SV_STEP     64
%define SV_X        TSAMPLE_size            ; i32 world x
%define SV_Z        (TSAMPLE_size + 4)
%define SV_COUNTS   (TSAMPLE_size + 8)      ; 7 x u32
%define SV_BEST_H   (TSAMPLE_size + 40)
%define SV_BEST_X   (TSAMPLE_size + 44)
%define SV_BEST_Z   (TSAMPLE_size + 48)
%define SV_GIANT_X  (TSAMPLE_size + 52)
%define SV_GIANT_Z  (TSAMPLE_size + 56)
%define SV_RIVER_X  (TSAMPLE_size + 60)
%define SV_RIVER_Z  (TSAMPLE_size + 64)
%define SV_FLAGS    (TSAMPLE_size + 68)
%define SV_GD       (TSAMPLE_size + 72)     ; nearest giant distance^2
%define SV_RD       (TSAMPLE_size + 76)
%define SV_LOCALS   (TSAMPLE_size + 80)
PROC terrain_survey, SV_LOCALS, rbx, rsi, rdi
    lea rdi, [LOCAL(SV_COUNTS)]
    xor eax, eax
    mov ecx, 7
    rep stosd
    mov dword [LOCAL(SV_BEST_H)], -1000
    mov dword [LOCAL(SV_GD)], 0x7FFFFFFF
    mov dword [LOCAL(SV_RD)], 0x7FFFFFFF
    xor esi, esi                        ; gz
.z:
    xor ebx, ebx                        ; gx
.x:
    lea eax, [ebx - SV_GRID / 2]
    imul eax, eax, SV_STEP
    mov [LOCAL(SV_X)], eax
    cvtsi2sd xmm0, eax
    lea eax, [esi - SV_GRID / 2]
    imul eax, eax, SV_STEP
    mov [LOCAL(SV_Z)], eax
    cvtsi2sd xmm1, eax
    lea rcx, [LOCAL(0)]
    call terrain_sample
    cvttss2si eax, [LOCAL(TSAMPLE.height)]
    ; tier: 0 ocean, 1 lowland (<150), 2 hills (<200), 3 mountains (<350),
    ; 4 high (<550), 5 giant (>= 550)
    xor ecx, ecx
    cmp eax, [rel g_sea_level]
    jl .tier
    inc ecx
    cmp eax, 150
    jl .tier
    inc ecx
    cmp eax, 200
    jl .tier
    inc ecx
    cmp eax, 350
    jl .tier
    inc ecx
    cmp eax, 550
    jl .tier
    inc ecx
.tier:
    inc dword [LOCAL(SV_COUNTS) + rcx * 4]
    ; highest point
    cmp eax, [LOCAL(SV_BEST_H)]
    jle .not_best
    mov [LOCAL(SV_BEST_H)], eax
    mov edx, [LOCAL(SV_X)]
    mov [LOCAL(SV_BEST_X)], edx
    mov edx, [LOCAL(SV_Z)]
    mov [LOCAL(SV_BEST_Z)], edx
.not_best:
    ; distance^2 from the origin in grid steps
    lea edx, [ebx - SV_GRID / 2]
    imul edx, edx
    lea r8d, [esi - SV_GRID / 2]
    imul r8d, r8d
    add edx, r8d
    ; nearest giant range (mask > 0.8)
    movss xmm0, [LOCAL(TSAMPLE.giant)]
    comiss xmm0, [rel c_08]
    jbe .not_giant
    cmp edx, [LOCAL(SV_GD)]
    jge .not_giant
    mov [LOCAL(SV_GD)], edx
    mov r8d, [LOCAL(SV_X)]
    mov [LOCAL(SV_GIANT_X)], r8d
    mov r8d, [LOCAL(SV_Z)]
    mov [LOCAL(SV_GIANT_Z)], r8d
.not_giant:
    ; nearest river on land (river distance < 0, land > 0.5)
    xorps xmm0, xmm0
    comiss xmm0, [LOCAL(TSAMPLE.river)]
    jbe .not_river
    movss xmm0, [LOCAL(TSAMPLE.land)]
    comiss xmm0, [rel c_half]
    jbe .not_river
    cmp edx, [LOCAL(SV_RD)]
    jge .not_river
    mov [LOCAL(SV_RD)], edx
    mov r8d, [LOCAL(SV_X)]
    mov [LOCAL(SV_RIVER_X)], r8d
    mov r8d, [LOCAL(SV_Z)]
    mov [LOCAL(SV_RIVER_Z)], r8d
.not_river:
    inc ebx
    cmp ebx, SV_GRID
    jb .x
    inc esi
    cmp esi, SV_GRID
    jb .z
    ; report shares in per mille
%macro SV_SHARE 2
    mov eax, [LOCAL(SV_COUNTS) + (%1) * 4]
    imul eax, eax, 1000
    xor edx, edx
    mov ecx, SV_GRID * SV_GRID
    div ecx
    LOG_VAL LOG_LEVEL_INFO, %2, rax
%endmacro
    LOG_INFO "survey: 25.6 x 25.6 km around the origin, shares in per mille"
    SV_SHARE 0, "survey: ocean"
    SV_SHARE 1, "survey: lowland (< 150)"
    SV_SHARE 2, "survey: hills (150-200)"
    SV_SHARE 3, "survey: mountains (200-350)"
    SV_SHARE 4, "survey: high mountains (350-550)"
    SV_SHARE 5, "survey: giant ranges (550+)"
    mov eax, [LOCAL(SV_BEST_H)]
    LOG_VAL LOG_LEVEL_INFO, "survey: highest point, height", rax
    lea rcx, [rel str_highest]
    mov edx, [LOCAL(SV_BEST_X)]
    mov r8d, [LOCAL(SV_BEST_Z)]
    call log_xz
    cmp dword [LOCAL(SV_GD)], 0x7FFFFFFF
    je .no_giant
    lea rcx, [rel str_giant_at]
    mov edx, [LOCAL(SV_GIANT_X)]
    mov r8d, [LOCAL(SV_GIANT_Z)]
    call log_xz
    jmp .giant_done
.no_giant:
    LOG_INFO "survey: no giant range in this area"
.giant_done:
    cmp dword [LOCAL(SV_RD)], 0x7FFFFFFF
    je .done
    lea rcx, [rel str_river_at]
    mov edx, [LOCAL(SV_RIVER_X)]
    mov r8d, [LOCAL(SV_RIVER_Z)]
    call log_xz
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; underground — block below the surface layers at world y.
;   in:  ecx = y, edx = bedrock jitter (0..3), r8d = deep boundary y
;   out: eax = block id   clobbers: rax
; -----------------------------------------------------------------------------
underground:
    lea eax, [rdx + WORLD_MIN_Y + 3]
    cmp ecx, eax
    jle .bedrock
    cmp ecx, r8d
    jl .deep
    mov eax, [rel g_b_stone]
    ret
.deep:
    mov eax, [rel g_b_deep]
    ret
.bedrock:
    mov eax, [rel g_b_bedrock]
    ret

; -----------------------------------------------------------------------------
; terrain_gen_column — generate all 40 sections of a column.
;   in:  rcx = COLUMN*, rdx = scratch ARENA* (reset by the caller)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define G_COL       0
%define G_ARENA     8
%define G_H         16                  ; i32[34*34] surface heights
%define G_INFO      24                  ; per column: {A f32, top u16, fill u16,
                                        ;  deep y i16, jitter u8, pad} 12 bytes
%define G_IDS       32
%define G_GRID      40                  ; overhang noise grid f32[9*5*9]
%define G_MINH      48
%define G_MAXH      52
%define G_MAXA      56
%define G_SY        60
%define G_Y0        64
%define G_Z         72
%define G_HASGRID   76
%define G_CX        80
%define G_CZ        84
%define G_CGRID     88                  ; coarse grid {h, A} f32 x 10 x 10
%define G_DETAIL    68                  ; (detail noise of the current block)
%define G_SAMPLE    96                  ; TSAMPLE
%define G_LOCALS    (96 + TSAMPLE_size + 16)
%define INFO_SIZE   12
PROC terrain_gen_column, G_LOCALS, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(G_COL)], rcx
    mov [LOCAL(G_ARENA)], rdx
    mov eax, [rcx + COLUMN.cx]
    mov [LOCAL(G_CX)], eax
    mov eax, [rcx + COLUMN.cz]
    mov [LOCAL(G_CZ)], eax
    INVOKE arena_alloc, [LOCAL(G_ARENA)], HM * HM * 4, 16
    mov [LOCAL(G_H)], rax
    INVOKE arena_alloc, [LOCAL(G_ARENA)], 1024 * INFO_SIZE, 16
    mov [LOCAL(G_INFO)], rax
    INVOKE arena_alloc, [LOCAL(G_ARENA)], SECTION_VOLUME * 2, 64
    mov [LOCAL(G_IDS)], rax
    INVOKE arena_alloc, [LOCAL(G_ARENA)], 9 * 5 * 9 * 4, 16
    mov [LOCAL(G_GRID)], rax
    INVOKE arena_alloc, [LOCAL(G_ARENA)], 10 * 10 * 8, 16
    mov [LOCAL(G_CGRID)], rax
    test rax, rax
    jz .oom

    ; ---- coarse grid: every 4 blocks from -4 to 32 (10 x 10 samples) ------------
    ; the large-scale fields are smooth, so heights and overhang amplitudes
    ; are interpolated; only the detail noise is evaluated per block
    xor r12d, r12d                      ; gz
.cg_z:
    xor r13d, r13d                      ; gx
.cg_x:
    mov eax, [LOCAL(G_CX)]
    shl eax, 5
    lea eax, [eax + r13d * 4 - 4]
    cvtsi2sd xmm0, eax
    mov eax, [LOCAL(G_CZ)]
    shl eax, 5
    lea eax, [eax + r12d * 4 - 4]
    cvtsi2sd xmm1, eax
    lea rcx, [LOCAL(G_SAMPLE)]
    call terrain_sample
    imul ecx, r12d, 10
    add ecx, r13d
    mov rdx, [LOCAL(G_CGRID)]
    ; height without its detail part, overhang amplitude
    movss xmm0, [LOCAL(G_SAMPLE) + TSAMPLE.fields + F_DETAIL * 4]
    mulss xmm0, [rel g_detail_height]
    movss xmm1, [LOCAL(G_SAMPLE) + TSAMPLE.height]
    subss xmm1, xmm0
    movss [rdx + rcx * 8], xmm1
    movss xmm0, [LOCAL(G_SAMPLE) + TSAMPLE.overhang]
    movss [rdx + rcx * 8 + 4], xmm0
    inc r13d
    cmp r13d, 10
    jb .cg_x
    inc r12d
    cmp r12d, 10
    jb .cg_z

    ; ---- heightmap with a one-block border --------------------------------------------
    mov dword [LOCAL(G_MINH)], 0x7FFFFFFF
    mov dword [LOCAL(G_MAXH)], 0x80000000
    xorps xmm0, xmm0
    movss [LOCAL(G_MAXA)], xmm0
    xor r12d, r12d                      ; hz 0..33 (z = hz - 1)
.hm_z:
    xor r13d, r13d                      ; hx
.hm_x:
    ; detail noise at this block
    mov eax, [LOCAL(G_CX)]
    shl eax, 5
    lea eax, [eax + r13d - 1]
    cvtsi2sd xmm1, eax
    mov eax, [LOCAL(G_CZ)]
    shl eax, 5
    lea eax, [eax + r12d - 1]
    cvtsi2sd xmm2, eax
    lea rcx, [rel g_noise + F_DETAIL * NOISE_size]
    mov edx, [rel g_world_seed]
    call fbm2
    movss [LOCAL(G_DETAIL)], xmm0
    ; bilinear from the coarse grid: local x + 4 = 4 * gx + fx
    lea ecx, [r13d + 3]                 ; (hx - 1) + 4
    mov r8d, ecx
    shr r8d, 2                          ; gx
    and ecx, 3
    cvtsi2ss xmm4, ecx
    mulss xmm4, [rel c_quarter]         ; fx
    lea ecx, [r12d + 3]
    mov r9d, ecx
    shr r9d, 2                          ; gz
    and ecx, 3
    cvtsi2ss xmm5, ecx
    mulss xmm5, [rel c_quarter]         ; fz
    imul eax, r9d, 10
    add eax, r8d
    mov rdx, [LOCAL(G_CGRID)]
    lea rdx, [rdx + rax * 8]            ; cell (gx, gz); +8 = gx+1, +80 = gz+1
%macro BILERP 2                         ; dst xmm, component offset (0 h, 4 A)
    movss %1, [rdx + 8 + (%2)]
    subss %1, [rdx + (%2)]
    mulss %1, xmm4
    addss %1, [rdx + (%2)]
    movss xmm3, [rdx + 88 + (%2)]
    subss xmm3, [rdx + 80 + (%2)]
    mulss xmm3, xmm4
    addss xmm3, [rdx + 80 + (%2)]
    subss xmm3, %1
    mulss xmm3, xmm5
    addss %1, xmm3
%endmacro
    BILERP xmm0, 0
    movss xmm1, [LOCAL(G_DETAIL)]
    mulss xmm1, [rel g_detail_height]
    addss xmm0, xmm1
    roundss xmm0, xmm0, 9
    cvttss2si eax, xmm0                 ; H = floor(h): first air block
    imul ecx, r12d, HM
    add ecx, r13d
    mov r10, [LOCAL(G_H)]
    mov [r10 + rcx * 4], eax
    ; interior: min/max, overhang, deep boundary, bedrock jitter
    lea ecx, [r13d - 1]
    cmp ecx, 31
    ja .hm_next
    lea ecx, [r12d - 1]
    cmp ecx, 31
    ja .hm_next
    cmp eax, [LOCAL(G_MINH)]
    jge .not_min
    mov [LOCAL(G_MINH)], eax
.not_min:
    cmp eax, [LOCAL(G_MAXH)]
    jle .not_max
    mov [LOCAL(G_MAXH)], eax
.not_max:
    lea ecx, [r12d - 1]
    shl ecx, 5
    lea ecx, [ecx + r13d - 1]
    imul rcx, rcx, INFO_SIZE
    add rcx, [LOCAL(G_INFO)]
    BILERP xmm0, 4
    movss [rcx], xmm0
    maxss xmm0, [LOCAL(G_MAXA)]
    movss [LOCAL(G_MAXA)], xmm0
    ; deep stone boundary: deep_stone_y + 6 * detail
    movss xmm0, [LOCAL(G_DETAIL)]
    mulss xmm0, [rel c_six]
    cvttss2si eax, xmm0
    add eax, [rel g_deep_y]
    mov [rcx + 8], ax
    ; bedrock jitter from the low bits of the detail noise
    movss xmm0, [LOCAL(G_DETAIL)]
    mulss xmm0, [rel c_1000]
    cvttss2si eax, xmm0
    and eax, 3
    mov [rcx + 10], al
    ; snow line jitter (signed blocks)
    movss xmm0, [LOCAL(G_DETAIL)]
    mulss xmm0, [rel g_snow_var]
    cvttss2si eax, xmm0
    mov [rcx + 11], al
.hm_next:
    inc r13d
    cmp r13d, HM
    jb .hm_x
    inc r12d
    cmp r12d, HM
    jb .hm_z

    ; ---- surface blocks by height and slope --------------------------------------------
    xor r12d, r12d                      ; z
.sf_z:
    xor r13d, r13d                      ; x
.sf_x:
    lea ecx, [r12d + 1]
    imul ecx, ecx, HM
    lea ecx, [ecx + r13d + 1]
    mov rdx, [LOCAL(G_H)]
    mov eax, [rdx + rcx * 4]            ; H
    ; slope = max |H - neighbour|
    xor r8d, r8d
%macro SLOPE_NB 1
    mov r9d, [rdx + rcx * 4 + (%1) * 4]
    sub r9d, eax
    mov r10d, r9d
    neg r10d
    cmovs r10d, r9d
    cmp r10d, r8d
    cmovg r8d, r10d
%endmacro
    SLOPE_NB -1
    SLOPE_NB 1
    SLOPE_NB -HM
    SLOPE_NB HM
    mov ecx, r12d
    shl ecx, 5
    add ecx, r13d
    imul rcx, rcx, INFO_SIZE
    add rcx, [LOCAL(G_INFO)]
    lea r9d, [eax - 1]                  ; top block y
    ; snow above the (jittered) snow line unless steep
    movsx r10d, byte [rcx + 11]
    add r10d, [rel g_snow_line]
    cmp r9d, r10d
    jl .not_snow
    ; snow clings to steeper slopes than grass (twice the steep limit), and
    ; covers everything far above the snow line (snow_cap_above)
    mov eax, r10d
    add eax, [rel g_snow_cap]
    cmp r9d, eax
    jge .snow
    mov eax, [rel g_steep]
    add eax, eax
    cmp r8d, eax
    jge .stone_top
.snow:
    mov eax, [rel g_b_snow]
    mov edx, [rel g_b_stone]
    jmp .sf_store
.not_snow:
    cmp r8d, [rel g_steep]
    jge .stone_top
    ; under water: sea bed
    cmp r9d, [rel g_beach_low]
    jl .seabed
    ; shore band: sand, or gravel when moderately steep
    cmp r9d, [rel g_beach_high]
    jg .inland
    cmp r8d, [rel g_scree]
    jge .gravel_top
    mov eax, [rel g_b_beach]
    mov edx, eax
    jmp .sf_store
.inland:
    ; scree high up on moderate slopes
    cmp r8d, [rel g_scree]
    jl .grass
    cmp r9d, [rel g_scree_y]
    jge .gravel_top
.grass:
    mov eax, [rel g_b_top]
    mov edx, [rel g_b_fill]
    jmp .sf_store
.gravel_top:
    mov eax, [rel g_b_gravel]
    mov edx, eax
    jmp .sf_store
.stone_top:
    mov eax, [rel g_b_stone]
    mov edx, eax
    jmp .sf_store
.seabed:
    ; sand, with gravel and clay patches from the detail noise
    movss xmm0, [rcx]                   ; (overhang amplitude: unused here)
    mov eax, [rel g_b_beach]
    movsx r10d, byte [rcx + 11]         ; detail-based jitter as a patch value
    cmp r10d, 6
    jl .seabed_low
    mov eax, [rel g_b_gravel]
    jmp .seabed_store
.seabed_low:
    cmp r10d, -6
    jg .seabed_store
    mov eax, [rel g_b_clay]
.seabed_store:
    mov edx, eax
.sf_store:
    mov [rcx + 4], ax
    mov [rcx + 6], dx
    inc r13d
    cmp r13d, 32
    jb .sf_x
    inc r12d
    cmp r12d, 32
    jb .sf_z

    ; ---- sections ------------------------------------------------------------------------
    cvttss2si eax, [LOCAL(G_MAXA)]
    inc eax
    mov [LOCAL(G_MAXA)], eax            ; now an integer margin
    mov dword [LOCAL(G_SY)], 0
.section:
    mov eax, [LOCAL(G_SY)]
    shl eax, 5
    add eax, WORLD_MIN_Y
    mov [LOCAL(G_Y0)], eax
    mov ebx, eax                        ; y0
    ; above every surface (plus overhang margin)?
    mov ecx, [LOCAL(G_MAXH)]
    add ecx, [LOCAL(G_MAXA)]
    cmp ebx, ecx
    jl .not_above
    cmp ebx, [rel g_sea_level]
    jg .air
    lea eax, [ebx + 31]
    cmp eax, [rel g_sea_level]
    jg .detailed
    mov ecx, [rel g_b_water]
    jmp .uniform
.air:
    xor eax, eax
    jmp .store
.not_above:
    ; below every surface layer?
    mov ecx, [LOCAL(G_MINH)]
    sub ecx, [LOCAL(G_MAXA)]
    sub ecx, 6
    lea eax, [ebx + 31]
    cmp eax, ecx
    jge .detailed
    mov eax, [rel g_deep_y]
    add eax, 8
    cmp ebx, eax
    jl .maybe_deep
    mov ecx, [rel g_b_stone]
    jmp .uniform
.maybe_deep:
    mov eax, [rel g_deep_y]
    sub eax, 8
    lea ecx, [ebx + 31]
    cmp ecx, eax
    jge .detailed
    cmp ebx, WORLD_MIN_Y + 8
    jl .detailed
    mov ecx, [rel g_b_deep]
.uniform:
    mov edx, [LOCAL(G_CX)]
    mov r8d, [LOCAL(G_SY)]
    mov r9d, [LOCAL(G_CZ)]
    call section_make_uniform
    jmp .store

.detailed:
    ; overhang noise grid when this section is in the overhang band
    mov dword [LOCAL(G_HASGRID)], 0
    cmp dword [LOCAL(G_MAXA)], 1
    jle .fill
    INVOKE build_grid, [LOCAL(G_GRID)], [LOCAL(G_CX)], [LOCAL(G_CZ)], [LOCAL(G_Y0)]
    mov dword [LOCAL(G_HASGRID)], 1
.fill:
    xor r12d, r12d                      ; z
.f_z:
    xor r13d, r13d                      ; x
.f_x:
    lea ecx, [r12d + 1]
    imul ecx, ecx, HM
    lea ecx, [ecx + r13d + 1]
    mov rdx, [LOCAL(G_H)]
    mov r14d, [rdx + rcx * 4]           ; H
    mov ecx, r12d
    shl ecx, 5
    add ecx, r13d
    imul r15, rcx, INFO_SIZE
    add r15, [LOCAL(G_INFO)]            ; info
    xor esi, esi                        ; local y
.f_y:
    lea edi, [ebx + esi]                ; world y
    ; solid?
    cmp dword [LOCAL(G_HASGRID)], 0
    je .plain_solid
    movss xmm0, [r15]                   ; A
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .plain_solid
    ; density = (H - y) + A * grid(x, y, z)
    mov rcx, [LOCAL(G_GRID)]
    mov edx, r13d
    mov r8d, esi
    mov r9d, r12d
    call grid_sample                    ; xmm0 = n
    mulss xmm0, [r15]
    mov eax, r14d
    sub eax, edi
    cvtsi2ss xmm1, eax
    addss xmm0, xmm1
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    ja .solid
    jmp .not_solid
.plain_solid:
    cmp edi, r14d
    jl .solid
.not_solid:
    xor eax, eax
    cmp edi, [rel g_sea_level]
    jg .put
    mov eax, [rel g_b_water]
    jmp .put
.solid:
    cmp edi, r14d
    jge .crag
    mov eax, r14d
    dec eax
    sub eax, edi                        ; depth below the top block
    jz .top
    cmp eax, 3
    jle .filler
    mov ecx, edi
    movzx edx, byte [r15 + 10]
    movsx r8d, word [r15 + 8]
    call underground
    jmp .put
.top:
    movzx eax, word [r15 + 4]
    jmp .put
.filler:
    movzx eax, word [r15 + 6]
    jmp .put
.crag:
    mov eax, [rel g_b_stone]
.put:
    mov ecx, esi
    shl ecx, 10
    mov edx, r12d
    shl edx, 5
    or ecx, edx
    or ecx, r13d
    mov rdx, [LOCAL(G_IDS)]
    mov [rdx + rcx * 2], ax
    inc esi
    cmp esi, 32
    jb .f_y
    inc r13d
    cmp r13d, 32
    jb .f_x
    inc r12d
    cmp r12d, 32
    jb .f_z
    INVOKE section_build, [LOCAL(G_IDS)], [LOCAL(G_CX)], [LOCAL(G_SY)], [LOCAL(G_CZ)]
.store:
    mov rcx, [LOCAL(G_COL)]
    mov edx, [LOCAL(G_SY)]
    mov [rcx + COLUMN.sections + rdx * 8], rax
    inc dword [LOCAL(G_SY)]
    cmp dword [LOCAL(G_SY)], SECTIONS_PER_COLUMN
    jb .section
    RETURN
.oom:
    LOG_ERROR "terrain: out of scratch memory"
    RETURN

ENDPROC

; -----------------------------------------------------------------------------
; build_grid — overhang noise on a coarse grid for one section: 9 x 5 x 9
; samples (x, z every 4 blocks, y every 8), interpolated by grid_sample.
;   in:  rcx = grid (f32[9*5*9]), edx = cx, r8d = cz, r9d = section y0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC build_grid, 32, rbx, rsi, rdi, r12, r13, r14
    mov rdi, rcx
    mov r12d, edx
    shl r12d, 5                         ; x0
    mov r13d, r8d
    shl r13d, 5                         ; z0
    mov r14d, r9d                       ; y0
    xor esi, esi                        ; index
    xor ebx, ebx                        ; (gz << 16) | (gy << 8) | gx
.cell:
    movzx eax, bl                       ; gx
    lea eax, [r12d + eax * 4]
    cvtsi2sd xmm1, eax
    movzx eax, bh                       ; gy
    lea eax, [r14d + eax * 8]
    cvtsi2sd xmm2, eax
    mov eax, ebx
    shr eax, 16                         ; gz
    lea eax, [r13d + eax * 4]
    cvtsi2sd xmm3, eax
    lea rcx, [rel g_noise + F_OVERHANG * NOISE_size]
    mov edx, [rel g_world_seed]
    call fbm3
    movss [rdi + rsi * 4], xmm0
    inc esi
    ; advance gx, then gy, then gz
    inc bl
    cmp bl, 9
    jb .cell
    xor bl, bl
    inc bh
    cmp bh, 5
    jb .cell
    xor bh, bh
    add ebx, 0x10000
    cmp ebx, 9 << 16
    jb .cell
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; grid_sample — trilinear overhang noise at a local block position.
;   in:  rcx = grid, edx = x, r8d = y, r9d = z (0..31)    out: xmm0
;   clobbers: rax, rcx, rdx, r8-r11, xmm0-xmm5
; -----------------------------------------------------------------------------
grid_sample:
    mov r10d, edx
    shr r10d, 2                         ; ix
    and edx, 3
    cvtsi2ss xmm3, edx
    mulss xmm3, [rel c_quarter]         ; fx
    mov r11d, r8d
    shr r11d, 3                         ; iy
    and r8d, 7
    cvtsi2ss xmm4, r8d
    mulss xmm4, [rel c_eighth]          ; fy
    mov eax, r9d
    shr eax, 2                          ; iz
    and r9d, 3
    cvtsi2ss xmm5, r9d
    mulss xmm5, [rel c_quarter]         ; fz
    imul eax, eax, 5
    add eax, r11d
    imul eax, eax, 9
    add eax, r10d
    lea rcx, [rcx + rax * 4]
%macro LERPX 2                          ; dst, float offset of the x0 sample
    movss %1, [rcx + (%2) * 4 + 4]
    subss %1, [rcx + (%2) * 4]
    mulss %1, xmm3
    addss %1, [rcx + (%2) * 4]
%endmacro
    LERPX xmm0, 0                       ; y0 z0
    LERPX xmm1, 9                       ; y1 z0
    subss xmm1, xmm0
    mulss xmm1, xmm4
    addss xmm0, xmm1                    ; z0 plane
    LERPX xmm1, 45                      ; y0 z1
    LERPX xmm2, 54                      ; y1 z1
    subss xmm2, xmm1
    mulss xmm2, xmm4
    addss xmm1, xmm2                    ; z1 plane
    subss xmm1, xmm0
    mulss xmm1, xmm5
    addss xmm0, xmm1
    ret
