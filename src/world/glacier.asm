; =============================================================================
; glacier.asm — glacier ice on the cold mountains (design/biomes/glacier.md).
;
; Glacier biomes (with `ice_block`) put a layer of ice on the ground. The
; biome is picked by the smoothed surface height (`smooth_height`), so it
; reaches down valleys between high ground: the tongues.
;
;   glacier_pass(FCTX*) -> eax      raise the heightmap to the ice surface,
;                                   moraines at the edge; per-column ice data
;                                   in INFO (ground, crevasse, biome, world
;                                   x/z); eax = highest interior surface
;   glacier_block(info*, y, S) -> eax   the ice block at y in a column whose
;                                   surface (first air) is S; 0 = air
;
; Ice surface S = max(ground + cap, smoothed height - fill), at most `fill
; max` above the ground: thin on ridges, valleys filled to a broad surface.
; It ends where the glacier weight drops below `ice_edge` (a sheer wall:
; the snout and edge cliffs); a band below that is a moraine ridge. Steep
; ice (the smoothed height's slope above `serac`) breaks into 3 x 3 blocks
; of random heights. Crevasses: lines of ridged noise inside a field mask,
; cut from the top; ice caves: 3D noise inside thick ice.
; =============================================================================
%include "macros.inc"
%include "noise.inc"
%include "block.inc"
%include "terrain.inc"
%include "biome.inc"
%define GLACIER_IMPL
%include "flora.inc"

global glacier_pass, glacier_block

extern g_world_seed

%define SALT_CAP        0x1C0
%define SALT_CREV       0x1C1
%define SALT_FIELD      0x1C2
%define SALT_CAVE       0x1C3
%define SALT_CAVEMASK   0x1C4
%define CAVE_MIN_T      10              ; ice at least this thick has caves
%define CAVE_ROOF       4               ; caves stay this far under the surface

section .rdata
align 16
c_abs:          dd 0x7FFFFFFF, 0, 0, 0  ; (andps: a whole aligned xmm)
c_inv48d:       dq 0.020833333333       ; cap variation scale 48
c_inv20d:       dq 0.05                 ; crevasse lines scale 20
c_inv150d:      dq 0.006666666667       ; crevasse fields scale 150
c_inv14d:       dq 0.071428571429       ; caves scale 14 (horizontal)
c_inv8d:        dq 0.125                ;   and 8 (vertical)
c_inv90d:       dq 0.011111111111       ; cave mask scale 90
align 4
c_one:          dd 1.0
c_half:         dd 0.5
c_two:          dd 2.0
c_onehalf:      dd 1.5
c_field:        dd 0.1                  ; crevasse field mask threshold
c_cave_mask:    dd 0.2                  ; cave mask threshold

section .text
; -----------------------------------------------------------------------------
; glacier_pass — ice and moraines over the heightmap (see the header).
;   in:  rcx = FCTX* (heights, glac, info, bmap, cx, cz)
;   out: eax = highest interior surface (-100000 if no ice)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define GL_I        0                   ; heightmap column
%define GL_J        4
%define GL_LX       8                   ; local
%define GL_LZ       12
%define GL_WX       16                  ; world
%define GL_WZ       20
%define GL_W        24                  ; f32 glacier weight
%define GL_B        32                  ; BIOME*
%define GL_BI       40                  ; its index
%define GL_H        44                  ; ground
%define GL_S        48                  ; f32 ice surface
%define GL_HS       52                  ; f32 smoothed height
%define GL_G        56                  ; f32 slope
%define GL_MAX      60
%define GL_INFO     64                  ; INFO* (interior) or 0
%define GL_T        72
%define GL_TMP      76
%define GL_LOCALS   80
PROC glacier_pass, GL_LOCALS, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    mov dword [LOCAL(GL_MAX)], -100000
    ; no ice by default
    mov rdi, [rbx + FCTX.glac]
    xor eax, eax
    mov ecx, HM * HM
    rep stosb
    mov rsi, [rbx + FCTX.info]
    xor ecx, ecx
.clear:
    mov byte [rsi + INFO_GFLAG], 0
    mov byte [rsi + INFO_CREV], 0
    add rsi, INFO_SIZE
    inc ecx
    cmp ecx, 1024
    jb .clear
    ; a glacier biome among the blend samples?
    mov rsi, [rbx + FCTX.bmap]
    xor ecx, ecx
.raw:
    movzx eax, byte [rsi + BMAP.raw + rcx]
    imul rax, rax, BIOME_size
    lea rdx, [rel g_biomes]
    cmp dword [rdx + rax + BIOME.ice], 0
    jne .some
    inc ecx
    cmp ecx, BM_RAW * BM_RAW
    jb .raw
    jmp .done
.some:
    mov dword [LOCAL(GL_J)], 0
.j:
    mov dword [LOCAL(GL_I)], 0
.i:
    mov eax, [LOCAL(GL_I)]
    sub eax, HB
    mov [LOCAL(GL_LX)], eax
    mov eax, [LOCAL(GL_J)]
    sub eax, HB
    mov [LOCAL(GL_LZ)], eax
    mov rcx, [rbx + FCTX.bmap]
    mov edx, [LOCAL(GL_LX)]
    mov r8d, [LOCAL(GL_LZ)]
    call bmap_ice
    test eax, eax
    jz .next
    movss [LOCAL(GL_W)], xmm0
    mov [LOCAL(GL_BI)], eax
    imul rax, rax, BIOME_size
    lea rcx, [rel g_biomes]
    add rax, rcx
    mov [LOCAL(GL_B)], rax
    mov rdi, rax
    ; edge band: weight below the edge minus the moraine band: nothing
    movss xmm1, [rdi + BIOME.ice_edge]
    subss xmm1, [rdi + BIOME.ice_edge + 4]
    comiss xmm0, xmm1
    jb .next
    ; interior column?
    mov qword [LOCAL(GL_INFO)], 0
    mov eax, [LOCAL(GL_LX)]
    cmp eax, 31
    ja .not_inner
    mov ecx, [LOCAL(GL_LZ)]
    cmp ecx, 31
    ja .not_inner
    shl ecx, 5
    add ecx, eax
    imul rcx, rcx, INFO_SIZE
    add rcx, [rbx + FCTX.info]
    mov [LOCAL(GL_INFO)], rcx
.not_inner:
    mov eax, [rbx + FCTX.cx]
    shl eax, 5
    add eax, [LOCAL(GL_LX)]
    mov [LOCAL(GL_WX)], eax
    mov eax, [rbx + FCTX.cz]
    shl eax, 5
    add eax, [LOCAL(GL_LZ)]
    mov [LOCAL(GL_WZ)], eax
    mov eax, [LOCAL(GL_J)]
    imul eax, eax, HM
    add eax, [LOCAL(GL_I)]
    mov rcx, [rbx + FCTX.heights]
    mov edx, [rcx + rax * 4]
    mov [LOCAL(GL_H)], edx
    movss xmm0, [LOCAL(GL_W)]
    comiss xmm0, [rdi + BIOME.ice_edge]
    jae .ice
    ; ---- moraine: a ridge (tent across the band) of moraine_height ----
    movss xmm1, [rdi + BIOME.ice_edge]
    subss xmm1, [rdi + BIOME.ice_edge + 4]
    subss xmm0, xmm1
    divss xmm0, [rdi + BIOME.ice_edge + 4]  ; t 0..1 across the band
    addss xmm0, xmm0
    subss xmm0, [rel c_one]
    andps xmm0, [rel c_abs]
    movss xmm1, [rel c_one]
    subss xmm1, xmm0
    mulss xmm1, [rdi + BIOME.moraine_h]
    addss xmm1, [rel c_half]
    cvttss2si edx, xmm1
    add edx, [LOCAL(GL_H)]
    mov [rcx + rax * 4], edx
    mov rcx, [rbx + FCTX.glac]
    mov byte [rcx + rax], GF_MORAINE
    mov rcx, [LOCAL(GL_INFO)]
    test rcx, rcx
    jz .next
    mov byte [rcx + INFO_GFLAG], GF_MORAINE
    mov eax, [LOCAL(GL_BI)]
    mov [rcx + INFO_GBIOME], al
    cmp edx, [LOCAL(GL_MAX)]
    jle .next
    mov [LOCAL(GL_MAX)], edx
    jmp .next

.ice:
    ; ---- the ice surface ----
    mov rcx, [rbx + FCTX.bmap]
    mov edx, [LOCAL(GL_LX)]
    mov r8d, [LOCAL(GL_LZ)]
    call bmap_hs
    movss [LOCAL(GL_HS)], xmm0
    ; slope of the smoothed height (central differences)
    mov rcx, [rbx + FCTX.bmap]
    mov edx, [LOCAL(GL_LX)]
    inc edx
    mov r8d, [LOCAL(GL_LZ)]
    call bmap_hs
    movss [LOCAL(GL_G)], xmm0
    mov rcx, [rbx + FCTX.bmap]
    mov edx, [LOCAL(GL_LX)]
    dec edx
    mov r8d, [LOCAL(GL_LZ)]
    call bmap_hs
    movss xmm1, [LOCAL(GL_G)]
    subss xmm1, xmm0
    mulss xmm1, xmm1
    movss [LOCAL(GL_G)], xmm1
    mov rcx, [rbx + FCTX.bmap]
    mov edx, [LOCAL(GL_LX)]
    mov r8d, [LOCAL(GL_LZ)]
    inc r8d
    call bmap_hs
    movss [LOCAL(GL_S)], xmm0
    mov rcx, [rbx + FCTX.bmap]
    mov edx, [LOCAL(GL_LX)]
    mov r8d, [LOCAL(GL_LZ)]
    dec r8d
    call bmap_hs
    movss xmm1, [LOCAL(GL_S)]
    subss xmm1, xmm0
    mulss xmm1, xmm1
    addss xmm1, [LOCAL(GL_G)]
    sqrtss xmm1, xmm1
    mulss xmm1, [rel c_half]
    movss [LOCAL(GL_G)], xmm1           ; blocks per block
    ; cap thickness: ice_cap range, varying smoothly
    cvtsi2sd xmm0, dword [LOCAL(GL_WX)]
    mulsd xmm0, [rel c_inv48d]
    cvtsi2sd xmm1, dword [LOCAL(GL_WZ)]
    mulsd xmm1, [rel c_inv48d]
    mov ecx, [rel g_world_seed]
    xor ecx, SALT_CAP
    call noise2
    mulss xmm0, [rel c_half]
    addss xmm0, [rel c_half]            ; 0..1
    mov rdi, [LOCAL(GL_B)]
    movss xmm1, [rdi + BIOME.ice_cap + 4]
    subss xmm1, [rdi + BIOME.ice_cap]
    mulss xmm1, xmm0
    addss xmm1, [rdi + BIOME.ice_cap]
    cvtsi2ss xmm2, dword [LOCAL(GL_H)]
    addss xmm1, xmm2                    ; ground + cap
    movss xmm0, [LOCAL(GL_HS)]
    subss xmm0, [rdi + BIOME.ice_fill]  ; smoothed - fill
    maxss xmm0, xmm1
    movss xmm1, [rdi + BIOME.ice_fill + 4]
    addss xmm1, xmm2
    minss xmm0, xmm1                    ; at most ground + max
    cvttss2si eax, xmm0
    mov [LOCAL(GL_T)], eax              ; (surface, for now)
    ; seracs: steep ice breaks into 3 x 3 blocks of random heights
    movss xmm0, [LOCAL(GL_G)]
    comiss xmm0, [rdi + BIOME.serac]
    jbe .no_serac
    mov eax, [LOCAL(GL_WX)]
    cdq
    mov ecx, 3
    idiv ecx
    test edx, edx
    jns .sx
    dec eax
.sx:
    mov [LOCAL(GL_TMP)], eax
    mov eax, [LOCAL(GL_WZ)]
    cdq
    mov ecx, 3
    idiv ecx
    test edx, edx
    jns .sz
    dec eax
.sz:
    imul eax, eax, 0xD8163841
    mov ecx, [LOCAL(GL_TMP)]
    imul ecx, ecx, 0x8DA6B343
    add eax, ecx
    add eax, [rel g_world_seed]
    mov ecx, eax
    shr ecx, 15
    xor eax, ecx
    imul eax, eax, 0x2C1B3C6D
    mov ecx, eax
    shr ecx, 13
    xor eax, ecx
    and eax, 0xFFFF
    cvttss2si ecx, [rdi + BIOME.serac + 4]  ; amplitude A
    lea r8d, [ecx * 2 + 1]
    xor edx, edx
    div r8d
    sub edx, ecx                        ; -A .. A
    add [LOCAL(GL_T)], edx
    mov eax, [LOCAL(GL_H)]
    add eax, 2
    cmp [LOCAL(GL_T)], eax
    jge .no_serac
    mov [LOCAL(GL_T)], eax
.no_serac:
    ; store the surface
    mov eax, [LOCAL(GL_J)]
    imul eax, eax, HM
    add eax, [LOCAL(GL_I)]
    mov rcx, [rbx + FCTX.heights]
    mov edx, [LOCAL(GL_T)]
    mov [rcx + rax * 4], edx
    mov rcx, [rbx + FCTX.glac]
    mov byte [rcx + rax], GF_ICE
    mov rsi, [LOCAL(GL_INFO)]
    test rsi, rsi
    jz .next
    cmp edx, [LOCAL(GL_MAX)]
    jle .not_max
    mov [LOCAL(GL_MAX)], edx
.not_max:
    mov byte [rsi + INFO_GFLAG], GF_ICE
    mov eax, [LOCAL(GL_BI)]
    mov [rsi + INFO_GBIOME], al
    mov eax, [LOCAL(GL_H)]
    mov [rsi + INFO_GROUND], ax
    mov dword [rsi + INFO_A], 0         ; (no overhangs in the ice)
    mov eax, [LOCAL(GL_WX)]
    mov [rsi + INFO_WX], eax
    mov eax, [LOCAL(GL_WZ)]
    mov [rsi + INFO_WZ], eax
    ; ---- crevasses: ridged lines inside the crevasse fields ----
    cvtsi2sd xmm0, dword [LOCAL(GL_WX)]
    mulsd xmm0, [rel c_inv150d]
    cvtsi2sd xmm1, dword [LOCAL(GL_WZ)]
    mulsd xmm1, [rel c_inv150d]
    mov ecx, [rel g_world_seed]
    xor ecx, SALT_FIELD
    call noise2
    comiss xmm0, [rel c_field]
    jbe .next
    cvtsi2sd xmm0, dword [LOCAL(GL_WX)]
    mulsd xmm0, [rel c_inv20d]
    cvtsi2sd xmm1, dword [LOCAL(GL_WZ)]
    mulsd xmm1, [rel c_inv20d]
    mov ecx, [rel g_world_seed]
    xor ecx, SALT_CREV
    call noise2
    andps xmm0, [rel c_abs]
    movss xmm1, [rel c_one]
    subss xmm1, xmm0                    ; ridged 0..1
    mov rdi, [LOCAL(GL_B)]
    comiss xmm1, [rdi + BIOME.crevasse]
    jbe .next
    ; depth: deepest at the line's centre (1.5 x the way to 1, capped)
    subss xmm1, [rdi + BIOME.crevasse]
    movss xmm0, [rel c_one]
    subss xmm0, [rdi + BIOME.crevasse]
    divss xmm1, xmm0
    mulss xmm1, [rel c_onehalf]
    minss xmm1, [rel c_one]
    mulss xmm1, [rdi + BIOME.crevasse + 4]
    cvttss2si eax, xmm1
    mov ecx, [LOCAL(GL_T)]
    sub ecx, [LOCAL(GL_H)]
    sub ecx, 2                          ; never through the ice
    cmp eax, ecx
    jle .crev_ok
    mov eax, ecx
.crev_ok:
    test eax, eax
    jle .next
    cmp eax, 255
    jle .crev_store
    mov eax, 255
.crev_store:
    mov [rsi + INFO_CREV], al
.next:
    inc dword [LOCAL(GL_I)]
    cmp dword [LOCAL(GL_I)], HM
    jb .i
    inc dword [LOCAL(GL_J)]
    cmp dword [LOCAL(GL_J)], HM
    jb .j
.done:
    mov eax, [LOCAL(GL_MAX)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; glacier_block — the block of a glaciated column at y (from the ground up
; to the surface): air in crevasses (from the top) and ice caves; the top
; is snow above the biome's `ice_snow` height (jittered) else ice; below
; `ice_deep` depth the deep ice (blue).
;   in:  rcx = INFO*, edx = y, r8d = S (first air above the ice)
;   out: eax = block id (0 = air)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define GB_Y        0
%define GB_D        4                   ; depth below the top block
%define GB_INFO     8
%define GB_LOCALS   16
PROC glacier_block, GB_LOCALS, rbx, rsi
    mov rsi, rcx
    mov [LOCAL(GB_Y)], edx
    movzx eax, byte [rsi + INFO_GBIOME]
    imul rax, rax, BIOME_size
    lea rbx, [rel g_biomes]
    add rbx, rax                        ; BIOME*
    lea eax, [r8d - 1]
    sub eax, edx
    mov [LOCAL(GB_D)], eax
    ; crevasse
    movzx ecx, byte [rsi + INFO_CREV]
    cmp eax, ecx
    jl .air
    ; ice caves: inside ice at least CAVE_MIN_T thick, under a roof
    xorps xmm0, xmm0
    comiss xmm0, [rbx + BIOME.ice_caves]
    jae .material
    cmp eax, CAVE_ROOF
    jl .material
    movsx ecx, word [rsi + INFO_GROUND]
    cmp edx, ecx
    jle .material                       ; (a floor of ice over the ground)
    mov eax, r8d
    sub eax, ecx
    cmp eax, CAVE_MIN_T
    jl .material
    cvtsi2sd xmm0, dword [rsi + INFO_WX]
    mulsd xmm0, [rel c_inv90d]
    cvtsi2sd xmm1, dword [rsi + INFO_WZ]
    mulsd xmm1, [rel c_inv90d]
    mov ecx, [rel g_world_seed]
    xor ecx, SALT_CAVEMASK
    call noise2
    comiss xmm0, [rel c_cave_mask]
    jbe .material
    cvtsi2sd xmm0, dword [rsi + INFO_WX]
    mulsd xmm0, [rel c_inv14d]
    cvtsi2sd xmm1, dword [LOCAL(GB_Y)]
    mulsd xmm1, [rel c_inv8d]
    cvtsi2sd xmm2, dword [rsi + INFO_WZ]
    mulsd xmm2, [rel c_inv14d]
    mov ecx, [rel g_world_seed]
    xor ecx, SALT_CAVE
    call noise3
    comiss xmm0, [rbx + BIOME.ice_caves]
    ja .air
.material:
    mov eax, [LOCAL(GB_D)]
    test eax, eax
    jnz .below
    ; the top: snow high up
    mov eax, [rbx + BIOME.ice_snow]
    test eax, eax
    jz .ice
    cvttss2si ecx, [rbx + BIOME.ice_snow_y]
    movsx edx, byte [rsi + INFO_SNOW]
    add ecx, edx
    cmp [LOCAL(GB_Y)], ecx
    jl .ice
    RETURN
.below:
    mov ecx, [rbx + BIOME.ice_deep]
    test ecx, ecx
    jz .ice
    cvttss2si edx, [rbx + BIOME.ice_deep_d]
    cmp eax, edx
    jl .ice
    mov eax, ecx
    RETURN
.ice:
    mov eax, [rbx + BIOME.ice]
    RETURN
.air:
    xor eax, eax
    RETURN
ENDPROC
