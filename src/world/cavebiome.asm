; =============================================================================
; cavebiome.asm — cave biomes: decorated cave regions underground
; (design/biomes/crystal_caves.md). Data: `[cave_biome]` records in
; data/biomes/ (parsed by biome.asm into g_caveb).
;
;   cavebiome_section(CAVECTX*, ids, y0)   after the cave decoration of a
;                                          section: decorate its cave biomes
;   cavebiome_at(x, y, z) -> eax           the cave biome (index + 1) whose
;                                          region holds a point, 0 = none
;   cavebiome_survey()                     part of --survey: the nearest
;                                          cave biome region point
;
; A cave biome lives where its 3D region field (noise, `region_scale`) is in
; its `region` range and y in its `depth` range. A second field (theme
; noise, `theme_scale`) picks one of its themes per area; a `rainbow` share
; of 16-block cells mixes every theme per block. Both fields are evaluated
; every 8 blocks and interpolated. Inside the region:
;   * stone and deep stone become the theme's stone (the `ore` at a chance);
;   * pillars: per 16 x 16 cell of the chunk, with `pillar_chance`, a disc of
;     `pillar_radius` where all cave air becomes the theme's crystal;
;   * floors (air over an opaque block): pools (noise above `pool_chance`,
;     the floor's top 2 blocks), moss patches, sprouts pointing up, the
;     fungus, crystal clumps;
;   * ceilings: sprouts pointing down, crystal stalactites.
; Only cave air under the surface crust is decorated (not water or lava).
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "noise.inc"
%include "block.inc"
%include "terrain.inc"
%include "biome.inc"
%include "caves.inc"

global cavebiome_section, cavebiome_at, cavebiome_survey

extern log_xz

extern g_world_seed, g_b_stone, g_b_deep

%define SALT_REGION     0xCA0           ; + 2 x cave biome index
%define SALT_THEME      0xCA1
%define SALT_POOL       0xCB0
%define SALT_MOSS       0xCB1
%define CG5             5               ; grid points per axis (every 8 blocks)

section .rdata
align 8
c_one_d:        dq 1.0
c_vstretch:     dq 1.5                  ; regions are flatter than wide
c_inv10d:       dq 0.1                  ; pool shapes (scale 10)
c_inv6d:        dq 0.16666666667        ; moss patches (scale 6)
align 4
c_eighth:       dd 0.125
c_half:         dd 0.5
c_one:          dd 1.0
c_inv65536:     dd 0.0000152587890625
c_margin:       dd 0.05

section .text
; -----------------------------------------------------------------------------
; hash3 — 32-bit hash of three integers and a salt.
;   in:  ecx, edx, r8d, r9d = salt      out: eax      clobbers: rax, rdx, r10
; -----------------------------------------------------------------------------
hash3:
    imul eax, ecx, 0x8DA6B343
    imul edx, edx, 0xD8163841
    add eax, edx
    imul r10d, r8d, 0xCB1AB31F
    add eax, r10d
    imul r10d, r9d, 0x61C88647
    add eax, r10d
    add eax, [rel g_world_seed]
    mov edx, eax
    shr edx, 15
    xor eax, edx
    imul eax, eax, 0x2C1B3C6D
    mov edx, eax
    shr edx, 13
    xor eax, edx
    imul eax, eax, 0x297A2D39
    mov edx, eax
    shr edx, 15
    xor eax, edx
    ret

; frac — xmm0 = low 16 bits of eax / 65536      clobbers: rax, xmm0
%macro FRAC 0
    movzx eax, ax
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv65536]
%endmacro

; -----------------------------------------------------------------------------
; field — a cave biome's region or theme noise at a world point.
;   in:  xmm0, xmm1, xmm2 = x, y, z (doubles), rcx = CAVEB*, edx = cave
;        biome index, r8d = 0 region / 1 theme
;   out: xmm0      clobbers: volatile registers
; -----------------------------------------------------------------------------
field:
    movss xmm3, [rcx + CAVEB.region_scale]
    test r8d, r8d
    jz .scale
    movss xmm3, [rcx + CAVEB.theme_scale]
.scale:
    cvtss2sd xmm3, xmm3
    movsd xmm4, [rel c_one_d]
    divsd xmm4, xmm3
    mulsd xmm0, xmm4
    mulsd xmm2, xmm4
    mulsd xmm4, [rel c_vstretch]
    mulsd xmm1, xmm4
    lea ecx, [edx * 2 + SALT_REGION]
    add ecx, r8d
    xor ecx, [rel g_world_seed]
    jmp noise3

; -----------------------------------------------------------------------------
; cavebiome_at — the cave biome at a world point (unblended), for the survey.
;   in:  ecx = x, edx = y, r8d = z
;   out: eax = index + 1, or 0      clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC cavebiome_at, 32, rbx, rsi, rdi
    mov [LOCAL(0)], ecx
    mov [LOCAL(4)], edx
    mov [LOCAL(8)], r8d
    xor ebx, ebx
.cb:
    cmp ebx, [rel g_caveb_count]
    jae .none
    imul rsi, rbx, CAVEB_size
    lea rax, [rel g_caveb]
    add rsi, rax
    mov eax, [LOCAL(4)]
    cmp eax, [rsi + CAVEB.depth]
    jl .next
    cmp eax, [rsi + CAVEB.depth + 4]
    jg .next
    cvtsi2sd xmm0, dword [LOCAL(0)]
    cvtsi2sd xmm1, dword [LOCAL(4)]
    cvtsi2sd xmm2, dword [LOCAL(8)]
    mov rcx, rsi
    mov edx, ebx
    xor r8d, r8d
    call field
    comiss xmm0, [rsi + CAVEB.region]
    jb .next
    comiss xmm0, [rsi + CAVEB.region + 4]
    ja .next
    lea eax, [ebx + 1]
    RETURN
.next:
    inc ebx
    jmp .cb
.none:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; cavebiome_section — decorate the cave biomes in one section (see header).
;   in:  rcx = CAVECTX*, rdx = ids u16[32768], r8d = y0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define CS_CTX      0
%define CS_IDS      8
%define CS_B        16                  ; CAVEB*
%define CS_Y0       24
%define CS_CB       28                  ; cave biome index
%define CS_I        32
%define CS_J        36
%define CS_K        40
%define CS_MAX      44                  ; f32 grid maximum
%define CS_MIN      48
%define CS_NP       52                  ; pillars
%define CS_PX       56                  ; i32[4]
%define CS_PZ       72                  ; i32[4]
%define CS_PR       88                  ; f32[4] radius^2
%define CS_PT       104                 ; i32[4] theme
%define CS_THEME    120                 ; theme of the current block
%define CS_IDX      124                 ; index of the current block
%define CS_SURF     128                 ; surface of the current column
%define CS_WX       132
%define CS_WY       136
%define CS_WZ       140
%define CS_HASH     144
%define CS_R        160                 ; f32[125] region grid
%define CS_T        (CS_R + 500)        ; f32[125] theme grid
%define CS_LOCALS   (CS_T + 500 + 8)
PROC cavebiome_section, CS_LOCALS, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(CS_CTX)], rcx
    mov [LOCAL(CS_IDS)], rdx
    mov [LOCAL(CS_Y0)], r8d
    mov dword [LOCAL(CS_CB)], 0
.cb:
    mov eax, [LOCAL(CS_CB)]
    cmp eax, [rel g_caveb_count]
    jae .done
    imul rsi, rax, CAVEB_size
    lea rcx, [rel g_caveb]
    add rsi, rcx
    mov [LOCAL(CS_B)], rsi
    cmp dword [rsi + CAVEB.ntheme], 0
    je .cb_next
    ; the section within the depth range?
    mov eax, [LOCAL(CS_Y0)]
    add eax, 31
    cmp eax, [rsi + CAVEB.depth]
    jl .cb_next
    mov eax, [LOCAL(CS_Y0)]
    cmp eax, [rsi + CAVEB.depth + 4]
    jg .cb_next
    ; ---- the region and theme grids (every 8 blocks) ----
    mov dword [LOCAL(CS_MAX)], 0xC2C80000       ; -100
    mov dword [LOCAL(CS_MIN)], 0x42C80000       ; 100
    mov dword [LOCAL(CS_J)], 0                  ; y
.gy:
    mov dword [LOCAL(CS_K)], 0                  ; z
.gz:
    mov dword [LOCAL(CS_I)], 0                  ; x
.gx:
    mov rcx, [LOCAL(CS_CTX)]
    mov eax, [LOCAL(CS_I)]
    shl eax, 3
    add eax, [rcx + CAVECTX.cx_blocks]
    cvtsi2sd xmm0, eax
    mov eax, [LOCAL(CS_J)]
    shl eax, 3
    add eax, [LOCAL(CS_Y0)]
    cvtsi2sd xmm1, eax
    mov eax, [LOCAL(CS_K)]
    shl eax, 3
    add eax, [rcx + CAVECTX.cz_blocks]
    cvtsi2sd xmm2, eax
    mov rcx, rsi
    mov edx, [LOCAL(CS_CB)]
    xor r8d, r8d
    call field
    mov eax, [LOCAL(CS_J)]
    imul eax, eax, CG5
    add eax, [LOCAL(CS_K)]
    imul eax, eax, CG5
    add eax, [LOCAL(CS_I)]
    movss [LOCAL(CS_R) + rax * 4], xmm0
    movss xmm1, xmm0
    maxss xmm1, [LOCAL(CS_MAX)]
    movss [LOCAL(CS_MAX)], xmm1
    minss xmm0, [LOCAL(CS_MIN)]
    movss [LOCAL(CS_MIN)], xmm0
    inc dword [LOCAL(CS_I)]
    cmp dword [LOCAL(CS_I)], CG5
    jb .gx
    inc dword [LOCAL(CS_K)]
    cmp dword [LOCAL(CS_K)], CG5
    jb .gz
    inc dword [LOCAL(CS_J)]
    cmp dword [LOCAL(CS_J)], CG5
    jb .gy
    ; no part of the region here: skip (interpolation stays inside the
    ; grid's extremes)
    movss xmm0, [LOCAL(CS_MAX)]
    comiss xmm0, [rsi + CAVEB.region]
    jb .cb_next
    movss xmm0, [LOCAL(CS_MIN)]
    comiss xmm0, [rsi + CAVEB.region + 4]
    ja .cb_next
    ; theme grid
    mov dword [LOCAL(CS_J)], 0
.ty:
    mov dword [LOCAL(CS_K)], 0
.tz:
    mov dword [LOCAL(CS_I)], 0
.tx:
    mov rcx, [LOCAL(CS_CTX)]
    mov eax, [LOCAL(CS_I)]
    shl eax, 3
    add eax, [rcx + CAVECTX.cx_blocks]
    cvtsi2sd xmm0, eax
    mov eax, [LOCAL(CS_J)]
    shl eax, 3
    add eax, [LOCAL(CS_Y0)]
    cvtsi2sd xmm1, eax
    mov eax, [LOCAL(CS_K)]
    shl eax, 3
    add eax, [rcx + CAVECTX.cz_blocks]
    cvtsi2sd xmm2, eax
    mov rcx, rsi
    mov edx, [LOCAL(CS_CB)]
    mov r8d, 1
    call field
    mov eax, [LOCAL(CS_J)]
    imul eax, eax, CG5
    add eax, [LOCAL(CS_K)]
    imul eax, eax, CG5
    add eax, [LOCAL(CS_I)]
    movss [LOCAL(CS_T) + rax * 4], xmm0
    inc dword [LOCAL(CS_I)]
    cmp dword [LOCAL(CS_I)], CG5
    jb .tx
    inc dword [LOCAL(CS_K)]
    cmp dword [LOCAL(CS_K)], CG5
    jb .tz
    inc dword [LOCAL(CS_J)]
    cmp dword [LOCAL(CS_J)], CG5
    jb .ty

    ; ---- pillars: per 16 x 16 cell of the chunk (the disc stays inside) ----
    mov dword [LOCAL(CS_NP)], 0
    xor r12d, r12d                      ; cell
.pc:
    mov rcx, [LOCAL(CS_CTX)]
    mov eax, r12d
    and eax, 1
    shl eax, 4
    mov [LOCAL(CS_I)], eax              ; cell origin x (local)
    add eax, [rcx + CAVECTX.cx_blocks]
    mov ecx, eax
    mov eax, r12d
    shr eax, 1
    shl eax, 4
    mov [LOCAL(CS_K)], eax
    mov rdx, [LOCAL(CS_CTX)]
    add eax, [rdx + CAVECTX.cz_blocks]
    mov edx, eax
    mov r8d, [LOCAL(CS_CB)]
    mov r9d, 0x5049                     ; "PI"
    call hash3
    mov [LOCAL(CS_HASH)], eax
    FRAC
    comiss xmm0, [rsi + CAVEB.pillar_ch]
    jae .pc_next
    mov ecx, [LOCAL(CS_NP)]
    mov eax, [LOCAL(CS_HASH)]
    shr eax, 16
    and eax, 15
    xor edx, edx
    mov r8d, 10
    div r8d
    lea eax, [edx + 3]
    add eax, [LOCAL(CS_I)]
    mov [LOCAL(CS_PX) + rcx * 4], eax
    mov eax, [LOCAL(CS_HASH)]
    shr eax, 20
    and eax, 15
    xor edx, edx
    mov r8d, 10
    div r8d
    lea eax, [edx + 3]
    add eax, [LOCAL(CS_K)]
    mov [LOCAL(CS_PZ) + rcx * 4], eax
    mov eax, [LOCAL(CS_HASH)]
    shr eax, 24
    cvtsi2ss xmm0, eax
    mulss xmm0, [rel c_inv65536]
    mulss xmm0, [rel c_256]             ; 0..1
    movss xmm1, [rsi + CAVEB.pillar_r + 4]
    subss xmm1, [rsi + CAVEB.pillar_r]
    mulss xmm1, xmm0
    addss xmm1, [rsi + CAVEB.pillar_r]
    mulss xmm1, xmm1
    movss [LOCAL(CS_PR) + rcx * 4], xmm1
    inc dword [LOCAL(CS_NP)]
.pc_next:
    inc r12d
    cmp r12d, 4
    jb .pc

    ; ---- pass A: stone, ores, pillars ----
    mov rbx, [LOCAL(CS_IDS)]
    xor r13d, r13d                      ; z
.az:
    xor r14d, r14d                      ; x
.ax:
    ; the column's surface (decorate under the crust only)
    lea eax, [r13d + HB]
    imul eax, eax, HM
    lea eax, [eax + r14d + HB]
    mov rcx, [LOCAL(CS_CTX)]
    mov rcx, [rcx + CAVECTX.heights]
    mov eax, [rcx + rax * 4]
    sub eax, 3
    mov [LOCAL(CS_SURF)], eax
    xor r12d, r12d                      ; y
.ay:
    mov eax, [LOCAL(CS_Y0)]
    add eax, r12d
    cmp eax, [LOCAL(CS_SURF)]
    jge .an
    cmp eax, [rsi + CAVEB.depth]
    jl .an
    cmp eax, [rsi + CAVEB.depth + 4]
    jg .an
    mov eax, r12d
    shl eax, 10
    mov ecx, r13d
    shl ecx, 5
    or eax, ecx
    or eax, r14d
    mov [LOCAL(CS_IDX)], eax
    movzx edi, word [rbx + rax * 2]     ; block
    ; only stone, deep stone and cave air matter here
    test edi, edi
    jz .a_cand
    cmp edi, [rel g_b_stone]
    je .a_cand
    cmp edi, [rel g_b_deep]
    jne .an
.a_cand:
    lea rcx, [LOCAL(CS_R)]
    mov edx, r14d
    mov r8d, r12d
    mov r9d, r13d
    call tri
    comiss xmm0, [rsi + CAVEB.region]
    jb .an
    comiss xmm0, [rsi + CAVEB.region + 4]
    ja .an
    call theme_here
    mov [LOCAL(CS_THEME)], eax
    test edi, edi
    jz .a_air
    ; stone: the theme's stone, or the ore
    call block_hash
    shr eax, 8
    FRAC
    mov edx, [LOCAL(CS_THEME)]
    mov eax, [rsi + CAVEB.th_stone + rdx * 4]
    comiss xmm0, [rsi + CAVEB.ore_ch]
    jae .a_put
    mov ecx, [rsi + CAVEB.ore]
    test ecx, ecx
    cmovnz eax, ecx
.a_put:
    test eax, eax
    jz .an
    mov ecx, [LOCAL(CS_IDX)]
    mov [rbx + rcx * 2], ax
    jmp .an
.a_air:
    ; air inside a pillar disc: the theme's crystal
    xor ecx, ecx
.ap:
    cmp ecx, [LOCAL(CS_NP)]
    jae .an
    mov eax, r14d
    sub eax, [LOCAL(CS_PX) + rcx * 4]
    imul eax, eax
    mov edx, r13d
    sub edx, [LOCAL(CS_PZ) + rcx * 4]
    imul edx, edx
    add eax, edx
    cvtsi2ss xmm0, eax
    comiss xmm0, [LOCAL(CS_PR) + rcx * 4]
    jbe .a_pillar
    inc ecx
    jmp .ap
.a_pillar:
    mov edx, [LOCAL(CS_THEME)]
    mov eax, [rsi + CAVEB.th_crystal + rdx * 4]
    mov ecx, [LOCAL(CS_IDX)]
    mov [rbx + rcx * 2], ax
.an:
    inc r12d
    cmp r12d, 32
    jb .ay
    inc r14d
    cmp r14d, 32
    jb .ax
    inc r13d
    cmp r13d, 32
    jb .az

    ; ---- pass B: floors and ceilings (ly 1..30) ----
    xor r13d, r13d
.bz:
    xor r14d, r14d
.bx:
    lea eax, [r13d + HB]
    imul eax, eax, HM
    lea eax, [eax + r14d + HB]
    mov rcx, [LOCAL(CS_CTX)]
    mov rcx, [rcx + CAVECTX.heights]
    mov eax, [rcx + rax * 4]
    sub eax, 3
    mov [LOCAL(CS_SURF)], eax
    mov r12d, 1
.by:
    mov eax, [LOCAL(CS_Y0)]
    add eax, r12d
    cmp eax, [LOCAL(CS_SURF)]
    jge .bn
    cmp eax, [rsi + CAVEB.depth]
    jl .bn
    cmp eax, [rsi + CAVEB.depth + 4]
    jg .bn
    mov eax, r12d
    shl eax, 10
    mov ecx, r13d
    shl ecx, 5
    or eax, ecx
    or eax, r14d
    mov [LOCAL(CS_IDX)], eax
    cmp word [rbx + rax * 2], 0
    jne .bn
    lea r15, [rel g_block_opaque]
    ; floor or ceiling?
    movzx ecx, word [rbx + rax * 2 - 2048]
    movzx edx, word [rbx + rax * 2 + 2048]
    movzx ecx, byte [r15 + rcx]
    movzx edx, byte [r15 + rdx]
    or ecx, edx
    jz .bn
    lea rcx, [LOCAL(CS_R)]
    mov edx, r14d
    mov r8d, r12d
    mov r9d, r13d
    call tri
    comiss xmm0, [rsi + CAVEB.region]
    jb .bn
    comiss xmm0, [rsi + CAVEB.region + 4]
    ja .bn
    call theme_here
    mov [LOCAL(CS_THEME)], eax
    call block_hash
    mov [LOCAL(CS_HASH)], eax
    mov eax, [LOCAL(CS_IDX)]
    movzx ecx, word [rbx + rax * 2 - 2048]
    cmp byte [r15 + rcx], 0
    je .ceiling
    ; ---- floor ----
    ; pools: the floor's top 2 blocks (organic shapes from noise)
    call world_xyz
    cvtsi2sd xmm0, dword [LOCAL(CS_WX)]
    mulsd xmm0, [rel c_inv10d]
    cvtsi2sd xmm1, dword [LOCAL(CS_WZ)]
    mulsd xmm1, [rel c_inv10d]
    cvtsi2sd xmm2, dword [LOCAL(CS_WY)]
    mulsd xmm2, [rel c_inv10d]
    mov ecx, [rel g_world_seed]
    xor ecx, SALT_POOL
    call noise3
    xorps xmm1, xmm1
    comiss xmm1, [rsi + CAVEB.pool_ch]
    jae .no_pool
    comiss xmm0, [rsi + CAVEB.pool_ch]
    jbe .no_pool
    mov edx, [LOCAL(CS_THEME)]
    mov edx, [rsi + CAVEB.th_pool + rdx * 4]
    test edx, edx
    jz .no_pool
    mov eax, [LOCAL(CS_IDX)]
    mov [rbx + rax * 2 - 2048], dx
    cmp r12d, 2
    jb .bn
    movzx ecx, word [rbx + rax * 2 - 4096]
    cmp byte [r15 + rcx], 0
    je .bn
    mov [rbx + rax * 2 - 4096], dx
    jmp .bn
.no_pool:
    ; moss patches on the floor
    mov eax, [rsi + CAVEB.moss]
    test eax, eax
    jz .no_moss
    cvtsi2sd xmm0, dword [LOCAL(CS_WX)]
    mulsd xmm0, [rel c_inv6d]
    cvtsi2sd xmm1, dword [LOCAL(CS_WZ)]
    mulsd xmm1, [rel c_inv6d]
    cvtsi2sd xmm2, dword [LOCAL(CS_WY)]
    mulsd xmm2, [rel c_inv6d]
    mov ecx, [rel g_world_seed]
    xor ecx, SALT_MOSS
    call noise3
    comiss xmm0, [rsi + CAVEB.moss_ch]
    jbe .no_moss
    mov eax, [LOCAL(CS_IDX)]
    mov edx, [rsi + CAVEB.moss]
    mov [rbx + rax * 2 - 2048], dx
.no_moss:
    ; one of: a sprout, the fungus, a crystal clump
    mov eax, [LOCAL(CS_HASH)]
    FRAC
    comiss xmm0, [rsi + CAVEB.sprout_ch]
    jae .f_fungus
    mov edx, [LOCAL(CS_THEME)]
    mov edx, [rsi + CAVEB.th_sprout + rdx * 4]   ; state 0: points up
    test edx, edx
    jz .bn
    mov eax, [LOCAL(CS_IDX)]
    mov [rbx + rax * 2], dx
    jmp .bn
.f_fungus:
    subss xmm0, [rsi + CAVEB.sprout_ch]
    comiss xmm0, [rsi + CAVEB.fungus_ch]
    jae .f_clump
    mov edx, [rsi + CAVEB.fungus]
    test edx, edx
    jz .bn
    mov eax, [LOCAL(CS_IDX)]
    mov [rbx + rax * 2], dx
    jmp .bn
.f_clump:
    subss xmm0, [rsi + CAVEB.fungus_ch]
    comiss xmm0, [rsi + CAVEB.clump_ch]
    jae .bn
    ; 1-3 crystal blocks up
    mov edx, [LOCAL(CS_THEME)]
    mov edx, [rsi + CAVEB.th_crystal + rdx * 4]
    mov ecx, [LOCAL(CS_HASH)]
    shr ecx, 16
    and ecx, 3
    jnz .cl_n
    inc ecx
.cl_n:
    mov eax, [LOCAL(CS_IDX)]
.cl:
    cmp eax, 32768
    jae .bn
    cmp word [rbx + rax * 2], 0
    jne .bn
    mov [rbx + rax * 2], dx
    add eax, 1024
    dec ecx
    jnz .cl
    jmp .bn
.ceiling:
    ; ---- ceiling: a sprout pointing down, or a crystal stalactite ----
    mov eax, [LOCAL(CS_HASH)]
    FRAC
    comiss xmm0, [rsi + CAVEB.sprout_ch]
    jae .c_drip
    mov edx, [LOCAL(CS_THEME)]
    mov edx, [rsi + CAVEB.th_sprout + rdx * 4]
    test edx, edx
    jz .bn
    inc edx                             ; state 1: points down
    mov eax, [LOCAL(CS_IDX)]
    mov [rbx + rax * 2], dx
    jmp .bn
.c_drip:
    subss xmm0, [rsi + CAVEB.sprout_ch]
    comiss xmm0, [rsi + CAVEB.drip_ch]
    jae .bn
    mov edx, [LOCAL(CS_THEME)]
    mov edx, [rsi + CAVEB.th_crystal + rdx * 4]
    mov ecx, [LOCAL(CS_HASH)]
    shr ecx, 16
    and ecx, 3
    jnz .dr_n
    inc ecx
.dr_n:
    mov eax, [LOCAL(CS_IDX)]
.dr:
    cmp word [rbx + rax * 2], 0
    jne .bn
    mov [rbx + rax * 2], dx
    sub eax, 1024
    js .bn
    dec ecx
    jnz .dr
.bn:
    inc r12d
    cmp r12d, 31
    jb .by
    inc r14d
    cmp r14d, 32
    jb .bx
    inc r13d
    cmp r13d, 32
    jb .bz
.cb_next:
    inc dword [LOCAL(CS_CB)]
    jmp .cb
.done:
    RETURN

; ---- helpers sharing the frame (called from the passes: rsp is 8 lower,
; so locals are reached at LOCAL(...) + 8) ----

; world_xyz: CS_WX/WY/WZ of the current block (r14 x, r12 y, r13 z)
world_xyz:
    mov rcx, [LOCAL(CS_CTX) + 8]
    mov eax, r14d
    add eax, [rcx + CAVECTX.cx_blocks]
    mov [LOCAL(CS_WX) + 8], eax
    mov eax, r12d
    add eax, [LOCAL(CS_Y0) + 8]
    mov [LOCAL(CS_WY) + 8], eax
    mov eax, r13d
    add eax, [rcx + CAVECTX.cz_blocks]
    mov [LOCAL(CS_WZ) + 8], eax
    ret

; block_hash: eax = hash of the current block's world position and the
; cave biome
block_hash:
    sub rsp, 8
    call world_xyz_inner
    mov ecx, [LOCAL(CS_WX) + 16]
    mov edx, [LOCAL(CS_WY) + 16]
    mov r8d, [LOCAL(CS_WZ) + 16]
    mov r9d, [LOCAL(CS_CB) + 16]
    add r9d, 0x4342                     ; "CB"
    call hash3
    add rsp, 8
    ret
world_xyz_inner:                        ; (world_xyz one call level deeper)
    mov rcx, [LOCAL(CS_CTX) + 24]
    mov eax, r14d
    add eax, [rcx + CAVECTX.cx_blocks]
    mov [LOCAL(CS_WX) + 24], eax
    mov eax, r12d
    add eax, [LOCAL(CS_Y0) + 24]
    mov [LOCAL(CS_WY) + 24], eax
    mov eax, r13d
    add eax, [rcx + CAVECTX.cz_blocks]
    mov [LOCAL(CS_WZ) + 24], eax
    ret

; theme_here: eax = the theme of the current block (rainbow cells: a theme
; per block)
theme_here:
    sub rsp, 8
    ; rainbow: per 16-block cell
    xorps xmm0, xmm0
    comiss xmm0, [rsi + CAVEB.rainbow]
    jae .th_field
    mov rcx, [LOCAL(CS_CTX) + 16]
    mov eax, r14d
    add eax, [rcx + CAVECTX.cx_blocks]
    sar eax, 4
    mov ecx, eax
    mov eax, r12d
    add eax, [LOCAL(CS_Y0) + 16]
    sar eax, 4
    mov edx, eax
    mov rax, [LOCAL(CS_CTX) + 16]
    mov r8d, r13d
    add r8d, [rax + CAVECTX.cz_blocks]
    sar r8d, 4
    mov r9d, 0x5242                     ; "RB"
    call hash3
    FRAC
    comiss xmm0, [rsi + CAVEB.rainbow]
    jae .th_field
    ; a theme per block
    call world_xyz_inner
    mov ecx, [LOCAL(CS_WX) + 16]
    mov edx, [LOCAL(CS_WY) + 16]
    mov r8d, [LOCAL(CS_WZ) + 16]
    mov r9d, 0x5254                     ; "RT"
    call hash3
    shr eax, 8
    and eax, 0xFFFF
    xor edx, edx
    div dword [rsi + CAVEB.ntheme]
    mov eax, edx
    add rsp, 8
    ret
.th_field:
    lea rcx, [LOCAL(CS_T) + 16]
    mov edx, r14d
    mov r8d, r12d
    mov r9d, r13d
    call tri
    ; (-0.6 .. 0.6 covers most of the noise) -> 0 .. ntheme - 1
    mulss xmm0, [rel c_theme_k]
    addss xmm0, [rel c_half]
    cvtsi2ss xmm1, dword [rsi + CAVEB.ntheme]
    mulss xmm0, xmm1
    cvttss2si eax, xmm0
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    mov ecx, [rsi + CAVEB.ntheme]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    add rsp, 8
    ret
ENDPROC

; -----------------------------------------------------------------------------
; tri — trilinear value of a 5 x 5 x 5 grid (every 8 blocks) at a local block.
;   in:  rcx = f32 grid, edx = x, r8d = y, r9d = z (0..31)
;   out: xmm0      clobbers: rax, rdx, r8-r11, xmm0-xmm5
; -----------------------------------------------------------------------------
tri:
    mov eax, edx
    and eax, 7
    cvtsi2ss xmm3, eax
    mulss xmm3, [rel c_eighth]          ; fx
    mov eax, r8d
    and eax, 7
    cvtsi2ss xmm4, eax
    mulss xmm4, [rel c_eighth]          ; fy
    mov eax, r9d
    and eax, 7
    cvtsi2ss xmm5, eax
    mulss xmm5, [rel c_eighth]          ; fz
    shr edx, 3
    shr r8d, 3
    shr r9d, 3
    imul eax, r8d, CG5
    add eax, r9d
    imul eax, eax, CG5
    add eax, edx                        ; (gx, gy, gz)
    lea r10, [rcx + rax * 4]
%macro LERPX 2                          ; %1 = out, %2 = byte offset of the x pair
    movss %1, [r10 + (%2)]
    movss xmm2, [r10 + (%2) + 4]
    subss xmm2, %1
    mulss xmm2, xmm3
    addss %1, xmm2
%endmacro
    movd r11d, xmm4                             ; (fy: xmm4 is a temporary below)
    LERPX xmm0, 0                               ; (y, z)
    LERPX xmm1, CG5 * 4                         ; (y, z + 1)
    subss xmm1, xmm0
    mulss xmm1, xmm5
    addss xmm0, xmm1                            ; y layer
    LERPX xmm1, CG5 * CG5 * 4                   ; (y + 1, z)
    LERPX xmm4, CG5 * CG5 * 4 + CG5 * 4         ; (y + 1, z + 1)
    subss xmm4, xmm1
    mulss xmm4, xmm5
    addss xmm1, xmm4                            ; y + 1 layer
    subss xmm1, xmm0
    movd xmm4, r11d
    mulss xmm1, xmm4
    addss xmm0, xmm1
    ret

section .rdata
align 4
c_256:          dd 256.0
c_theme_k:      dd 0.8333333                ; theme field: 0.5 + n / 1.2

section .text
; -----------------------------------------------------------------------------
; cavebiome_survey — the share of the volume (every 64 blocks within 1 km,
; y -16 .. -176 every 40) inside cave biome regions, and the nearest such
; point, logged with its height.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define SV_X        0
%define SV_Y        4
%define SV_Z        8
%define SV_D        12
%define SV_BX       16
%define SV_BY       20
%define SV_BZ       24
%define SV_N        28                  ; samples inside a region
%define SV_ALL      32
%define SV_LOCALS   48
PROC cavebiome_survey, SV_LOCALS, rbx, rsi, rdi
    cmp dword [rel g_caveb_count], 0
    je .done
    mov dword [LOCAL(SV_D)], 0x7FFFFFFF
    mov dword [LOCAL(SV_N)], 0
    mov dword [LOCAL(SV_ALL)], 0
    mov dword [LOCAL(SV_Y)], -16
.y:
    mov dword [LOCAL(SV_Z)], -1024
.z:
    mov dword [LOCAL(SV_X)], -1024
.x:
    mov eax, [LOCAL(SV_X)]
    imul eax, eax
    mov ecx, [LOCAL(SV_Z)]
    imul ecx, ecx
    add eax, ecx
    mov ebx, eax
    inc dword [LOCAL(SV_ALL)]
    mov ecx, [LOCAL(SV_X)]
    mov edx, [LOCAL(SV_Y)]
    mov r8d, [LOCAL(SV_Z)]
    call cavebiome_at
    test eax, eax
    jz .next
    inc dword [LOCAL(SV_N)]
    cmp ebx, [LOCAL(SV_D)]
    jae .next
    mov [LOCAL(SV_D)], ebx
    mov eax, [LOCAL(SV_X)]
    mov [LOCAL(SV_BX)], eax
    mov eax, [LOCAL(SV_Y)]
    mov [LOCAL(SV_BY)], eax
    mov eax, [LOCAL(SV_Z)]
    mov [LOCAL(SV_BZ)], eax
.next:
    add dword [LOCAL(SV_X)], 64
    cmp dword [LOCAL(SV_X)], 1024
    jle .x
    add dword [LOCAL(SV_Z)], 64
    cmp dword [LOCAL(SV_Z)], 1024
    jle .z
    sub dword [LOCAL(SV_Y)], 40
    cmp dword [LOCAL(SV_Y)], -176
    jge .y
    mov eax, [LOCAL(SV_N)]
    imul eax, eax, 1000
    xor edx, edx
    div dword [LOCAL(SV_ALL)]
    LOG_VAL LOG_LEVEL_INFO, "survey: cave biome regions (per mille of the volume at y -16 .. -176)", rax
    cmp dword [LOCAL(SV_D)], 0x7FFFFFFF
    je .none
    lea rcx, [rel s_sv_cave]
    mov edx, [LOCAL(SV_BX)]
    mov r8d, [LOCAL(SV_BZ)]
    call log_xz
    mov eax, [LOCAL(SV_BY)]
    neg eax                             ; (the log prints unsigned values)
    LOG_VAL LOG_LEVEL_INFO, "survey:   blocks below y 0", rax
    RETURN
.none:
    LOG_INFO "survey: no cave biome region within 1 km"
.done:
    RETURN
ENDPROC

section .rdata
s_sv_cave:      db "survey: nearest cave biome region (crystal grotto) at", 0
