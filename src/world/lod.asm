; =============================================================================
; lod.asm — distant terrain: level-of-detail tiles (milestone 12, D80).
;
; Beyond the full-detail columns, the terrain is drawn as LOD tiles: a tile
; of level L (1..LOD_MAX_LEVEL) is 32 x 32 cells of 2^L x 2^L blocks, so it
; spans 2^L chunks. Every cell is one column of whole blocks: its height
; (the terrain's own height function, with the biomes' hill, dune, plateau,
; mesa and flatten settings blended over a coarse lattice), a top block by
; the surface rules (water, snow, steep rock, beach, the biome's ground,
; and a leaf canopy over forests), side faces down to lower neighbours, and
; skirts at the tile's edges that hide cracks between levels. Water is a
; separate translucent quad at the sea level.
;
; Level L covers the ring g_lod_r[L-1] <= distance < g_lod_r[L] around the
; camera (the fragment shader discards outside it, so neighbouring levels
; and the full-detail columns never overlap); tiles touching the ring are
; generated on worker threads, uploaded into the shared quad buffer and
; dropped when they leave it (with a margin).
;
; Public API:
;   lod_init() -> eax 1/0           (settings_load and stream_init first)
;   lod_update()                    once per frame (main thread)
;   lod_shutdown()
;   g_lod_tiles, g_lod_used         the tile array (LODTILE, see lod.inc)
;   g_lod_levels, g_lod_r           levels in use, ring radii (f32 blocks)
;   g_lod_ready, g_lod_inflight, g_lod_quads, g_lod_gen_count,
;   g_lod_gen_total_us, g_lod_gen_max_us   statistics
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "jobs.inc"
%include "gl.inc"
%include "terrain.inc"
%include "biome.inc"
%define LOD_IMPL
%include "lod.inc"

global lod_init, lod_update, lod_shutdown
global g_lod_tiles, g_lod_used, g_lod_levels, g_lod_r
global g_lod_ready, g_lod_inflight, g_lod_quads
global g_lod_gen_count, g_lod_gen_total_us, g_lod_gen_max_us

extern timer_elapsed_us, g_render_distance, g_lod_distance, g_cam_pos
extern gpu_alloc, gpu_free, gpu_alloc_units_needed, g_quad_buffer
extern g_lod_tint_tex
extern terrain_sample, g_world_seed, g_sea_level, g_beach_high, g_snow_line
extern g_b_top, g_b_stone, g_b_water, g_b_snow, g_b_beach, g_steep
extern g_detail_height, g_b_fill, atomic_max

IMPORT VirtualAlloc, VirtualFree

%define MEM_COMMIT          0x1000
%define MEM_RESERVE         0x2000
%define MEM_RELEASE         0x8000
%define PAGE_READWRITE      0x04

%define HASH_SIZE           16384       ; tile index slots (power of two)
%define HASH_EMPTY          -1
%define UPLOAD_BUDGET       (1024 * 1024)   ; bytes of LOD quads per frame
%define STAT_LOG_US         2000000     ; statistics in the log this often
%define G34                 (LOD_CELLS + 2) ; cells with a 1-cell border
%define LAT                 11          ; biome lattice points per side
%define LAT_STEP            4           ; cells between lattice points
%define CANOPY_DENSITY      0.006       ; trees per block^2 for a leaf canopy
%define CANOPY_HEIGHT       5
%define SKIRT_CELLS         2           ; skirt depth at tile edges (cells)
%define Y_BIAS              512         ; quad y is stored + this, then relative
%define F_DETAIL            9           ; terrain field: detail noise (terrain.asm)

section .rdata
align 4
c_half:         dd 0.5
c_one:          dd 1.0
c_quarter:      dd 0.25
c_canopy:       dd CANOPY_DENSITY
s_log_ready:    db "lod: ready ", 0
s_log_flight:   db " in flight ", 0
s_log_missing:  db " missing ", 0
s_log_quads:    db " quads ", 0
s_log_avg:      db " gen avg us ", 0
s_log_max:      db " max us ", 0
align 8
c_half_d:       dq 0.5
align 16
c_abs4:         times 4 dd 0x7FFFFFFF
side_ofs:       dd -1, 1, -G34, G34     ; -x, +x, -z, +z neighbours in the grid
side_face:      dd 0, 1, 4, 5
tint_field:     dd BIOME.gfac, BIOME.ffac, BIOME.wfac

section .bss
alignb 8
g_lod_tiles:        resq 1              ; LODTILE[MAX_LOD_TILES]
g_lod_used:         resq 1              ; slots ever used (high water)
g_lod_free:         resq 1              ; u32 stack of free slots
g_lod_free_n:       resq 1
g_lod_hash:         resq 1              ; i32[HASH_SIZE] tile index or -1
g_lod_counter:      resq 1              ; job counter
g_lod_ready:        resq 1
g_lod_inflight:     resq 1
g_lod_quads:        resq 1
g_lod_stamp:        resd 1
g_lod_levels:       resd 1
g_lod_r:            resd LOD_MAX_LEVEL + 1
g_lod_warned:       resd 1
g_lod_missing:      resd 1              ; tiles the rings still lack (this frame)
g_lod_done_logged:  resd 1
alignb 8
g_lod_next_log:     resq 1              ; us
g_lod_t0:           resq 1
alignb 64
g_lod_gen_count:    resq 1
g_lod_gen_total_us: resq 1
g_lod_gen_max_us:   resq 1

section .text

; -----------------------------------------------------------------------------
; lod_init — ring radii from the settings, the tile array and the hash map.
;   out: eax = 1 (0 on out of memory)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC lod_init, 0, rbx
    mov dword [rel g_lod_levels], 0
    ; r[0]: two chunks inside the full-detail radius (always fully loaded)
    mov eax, [rel g_render_distance]
    sub eax, 2
    shl eax, 5
    cvtsi2ss xmm0, eax
    movss [rel g_lod_r], xmm0
    mov ecx, [rel g_lod_distance]
    shl ecx, 5                          ; outer radius in blocks
    cmp ecx, eax
    jle .no_lod
    cvtsi2ss xmm1, ecx                  ; r_max
    xor ebx, ebx
.lv:
    inc ebx
    addss xmm0, xmm0                    ; r[L] = r0 * 2^L, at most r_max
    minss xmm0, xmm1
    lea rax, [rel g_lod_r]
    movss [rax + rbx * 4], xmm0
    comiss xmm0, xmm1
    jae .lv_done
    cmp ebx, LOD_MAX_LEVEL
    jb .lv
.lv_done:
    mov [rel g_lod_levels], ebx
.no_lod:
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, MAX_LOD_TILES * LODTILE_size, 64
    test rax, rax
    jz .oom
    mov [rel g_lod_tiles], rax
    mov rdi, rax
    xor eax, eax
    mov ecx, MAX_LOD_TILES * LODTILE_size / 8
    rep stosq
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, MAX_LOD_TILES * 4, 16
    test rax, rax
    jz .oom
    mov [rel g_lod_free], rax
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, HASH_SIZE * 4, 16
    test rax, rax
    jz .oom
    mov [rel g_lod_hash], rax
    mov rdi, rax
    mov eax, HASH_EMPTY
    mov ecx, HASH_SIZE
    rep stosd
    mov qword [rel g_lod_used], 0
    mov qword [rel g_lod_free_n], 0
    call timer_elapsed_us
    mov [rel g_lod_t0], rax
    add rax, STAT_LOG_US
    mov [rel g_lod_next_log], rax
    mov eax, [rel g_lod_levels]
    LOG_VAL LOG_LEVEL_INFO, "lod: levels", rax
    mov eax, 1
    RETURN
.oom:
    LOG_ERROR "lod: out of memory"
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; hash_home — home slot of a tile key.
;   in:  ecx = level, edx = tx, r8d = tz      out: eax = slot
;   clobbers: rax, rdx, r8
; -----------------------------------------------------------------------------
hash_home:
    imul edx, edx, 0x9E3779B1
    imul r8d, r8d, 0x85EBCA77
    lea eax, [ecx * 8 + ecx]
    imul eax, eax, 0xC2B2AE3D
    xor eax, edx
    xor eax, r8d
    mov edx, eax
    shr edx, 15
    xor eax, edx
    and eax, HASH_SIZE - 1
    ret

; TILE_PTR out, index — out = &tiles[index]
%macro TILE_PTR 2                       ; %1 = out reg, %2 = index reg (64, upper half clear)
    imul %1, %2, LODTILE_size
    add %1, [rel g_lod_tiles]
%endmacro

; -----------------------------------------------------------------------------
; hash_find — the tile with a key.
;   in:  ecx = level, edx = tx, r8d = tz
;   out: eax = tile index, or -1
;   clobbers: rax, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
hash_find:
    mov r9d, ecx
    mov r10d, edx
    mov r11d, r8d
    call hash_home
    mov rdx, [rel g_lod_hash]
.probe:
    mov ecx, [rdx + rax * 4]
    cmp ecx, HASH_EMPTY
    je .none
    imul r8, rcx, LODTILE_size
    add r8, [rel g_lod_tiles]
    cmp [r8 + LODTILE.level], r9d
    jne .next
    cmp [r8 + LODTILE.tx], r10d
    jne .next
    cmp [r8 + LODTILE.tz], r11d
    jne .next
    mov eax, ecx
    ret
.next:
    inc eax
    and eax, HASH_SIZE - 1
    jmp .probe
.none:
    mov eax, -1
    ret

; -----------------------------------------------------------------------------
; hash_insert — put a tile index in the map (the key must be new).
;   in:  ecx = tile index      clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
hash_insert:
    mov r9d, ecx
    imul rax, rcx, LODTILE_size
    add rax, [rel g_lod_tiles]
    mov ecx, [rax + LODTILE.level]
    mov edx, [rax + LODTILE.tx]
    mov r8d, [rax + LODTILE.tz]
    call hash_home
    mov rdx, [rel g_lod_hash]
.probe:
    cmp dword [rdx + rax * 4], HASH_EMPTY
    je .put
    inc eax
    and eax, HASH_SIZE - 1
    jmp .probe
.put:
    mov [rdx + rax * 4], r9d
    ret

; -----------------------------------------------------------------------------
; hash_remove — remove a tile index from the map (backward-shift deletion,
; so no tombstones pile up).
;   in:  ecx = tile index      clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC hash_remove, 0, rbx, rsi, rdi
    mov ebx, ecx
    TILE_PTR rax, rbx
    mov ecx, [rax + LODTILE.level]
    mov edx, [rax + LODTILE.tx]
    mov r8d, [rax + LODTILE.tz]
    call hash_home
    mov rdx, [rel g_lod_hash]
.find:
    cmp [rdx + rax * 4], ebx
    je .found
    cmp dword [rdx + rax * 4], HASH_EMPTY
    je .done                            ; (not there)
    inc eax
    and eax, HASH_SIZE - 1
    jmp .find
.found:
    mov esi, eax                        ; the hole
    mov edi, eax                        ; scan
.shift:
    inc edi
    and edi, HASH_SIZE - 1
    mov rdx, [rel g_lod_hash]
    mov ecx, [rdx + rdi * 4]
    cmp ecx, HASH_EMPTY
    je .clear
    ; home of the entry at edi
    TILE_PTR rax, rcx
    mov ecx, [rax + LODTILE.level]
    mov edx, [rax + LODTILE.tx]
    mov r8d, [rax + LODTILE.tz]
    call hash_home                      ; eax = home k
    ; can it move into the hole? (the hole lies cyclically in [k, edi))
    mov ecx, edi
    sub ecx, eax
    and ecx, HASH_SIZE - 1              ; distance home -> edi
    mov edx, edi
    sub edx, esi
    and edx, HASH_SIZE - 1              ; distance hole -> edi
    cmp edx, ecx
    ja .shift                           ; the hole is before its home: stays
    mov rdx, [rel g_lod_hash]
    mov ecx, [rdx + rdi * 4]
    mov [rdx + rsi * 4], ecx
    mov esi, edi
    jmp .shift
.clear:
    mov rdx, [rel g_lod_hash]
    mov dword [rdx + rsi * 4], HASH_EMPTY
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; tile_free — release a tile (its job must be done).
;   in:  ecx = tile index      clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC tile_free, 0, rbx, rsi
    mov ebx, ecx
    TILE_PTR rsi, rbx
    cmp dword [rsi + LODTILE.unit], -1
    je .no_gpu
    mov ecx, [rsi + LODTILE.unit]
    call gpu_free
    mov eax, [rsi + LODTILE.quads]
    sub [rel g_lod_quads], rax
    mov dword [rsi + LODTILE.unit], -1
.no_gpu:
    mov rcx, [rsi + LODTILE.buf]
    test rcx, rcx
    jz .no_buf
    API VirtualFree, rcx, 0, MEM_RELEASE
    mov qword [rsi + LODTILE.buf], 0
.no_buf:
    mov ecx, ebx
    call hash_remove
    mov dword [rsi + LODTILE.state], LT_FREE
    mov rax, [rel g_lod_free_n]
    mov rcx, [rel g_lod_free]
    mov [rcx + rax * 4], ebx
    inc qword [rel g_lod_free_n]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; tile_upload — move a MESHED tile's quads and tint into the GPU.
;   in:  rcx = LODTILE*
;   out: eax = bytes, or -1 if the quad buffer is full (stays MESHED)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC tile_upload, 0, rbx, rsi
    mov rbx, rcx
    mov esi, [rbx + LODTILE.quads]
    test esi, esi
    jz .tint
    mov ecx, esi
    call gpu_alloc_units_needed
    mov ecx, eax
    call gpu_alloc
    cmp eax, -1
    je .full
    mov [rbx + LODTILE.unit], eax
    mov ecx, eax
    shl ecx, 6
    mov [rbx + LODTILE.first], ecx
    add [rel g_lod_quads], rsi
    mov edx, eax
    shl rdx, 9                          ; byte offset
    mov r8, rsi
    shl r8, 3
    GL glNamedBufferSubData, [rel g_quad_buffer], rdx, r8, [rbx + LODTILE.buf]
.tint:
    ; the tile's biome colours into the LOD tint map (16 blocks per texel)
    mov eax, [rbx + LODTILE.tint_n]
    mov [rsp + 48], rax                 ; height
    mov [rsp + 40], rax                 ; width
    mov rax, [rbx + LODTILE.buf]
    mov ecx, [rbx + LODTILE.quads]
    lea rax, [rax + rcx * 8]
    mov [rsp + 80], rax                 ; pixels (after the quads)
    mov qword [rsp + 72], GL_UNSIGNED_BYTE
    mov qword [rsp + 64], GL_RGBA
    mov qword [rsp + 56], 3             ; depth (layers)
    mov qword [rsp + 32], 0             ; z offset
    mov ecx, [rbx + LODTILE.level]
    mov r8d, LOD_CELLS
    shl r8d, cl                         ; tile size in blocks
    mov eax, r8d
    imul eax, [rbx + LODTILE.tx]
    sar eax, 4
    and eax, LOD_TINT_SIZE - 1
    mov r9d, r8d
    imul r9d, [rbx + LODTILE.tz]
    sar r9d, 4
    and r9d, LOD_TINT_SIZE - 1
    mov r8d, eax
    GL glTextureSubImage3D, [rel g_lod_tint_tex], 0, r8, r9
    API VirtualFree, [rbx + LODTILE.buf], 0, MEM_RELEASE
    mov qword [rbx + LODTILE.buf], 0
    mov dword [rbx + LODTILE.state], LT_READY
    mov eax, esi
    shl eax, 3
    RETURN
.full:
    cmp dword [rel g_lod_warned], 0
    jne .quiet
    mov dword [rel g_lod_warned], 1
    LOG_WARN "lod: GPU quad buffer full; some LOD tiles wait (lower lod_distance)"
.quiet:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; lod_update — keep the tiles of every ring around the camera (main thread,
; never waits on jobs).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define LU_CX       0                   ; f32 camera x, z
%define LU_CZ       4
%define LU_L        8
%define LU_T        12                  ; tile size (blocks)
%define LU_TX       16
%define LU_TZ       20
%define LU_TX0      24
%define LU_TX1      28
%define LU_TZ1      32
%define LU_RIN      36                  ; f32 ring
%define LU_ROUT     40
%define LU_CAP      44
%define LU_BUDGET   48
%define LU_MIND     52                  ; f32
%define LU_MAXD     56
%define LU_LOCALS   64
PROC lod_update, LU_LOCALS, rbx, rsi, rdi, r12, r13
%assign LUB OUTGOING_SIZE - %$nregs * 8 - %$frame
%define LUL(x) rbp + LUB + (x)
    cmp dword [rel g_lod_levels], 0
    je .done
    inc dword [rel g_lod_stamp]
    movsd xmm0, [rel g_cam_pos]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(LU_CX)], xmm0
    movsd xmm0, [rel g_cam_pos + 16]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(LU_CZ)], xmm0
    ; jobs in flight: 8 per worker (a few ms each; the queue check below
    ; keeps the full-detail columns first)
    mov eax, [rel g_job_worker_count]
    shl eax, 3
    mov [LOCAL(LU_CAP)], eax
    mov dword [LOCAL(LU_BUDGET)], UPLOAD_BUDGET
    mov dword [rel g_lod_missing], 0
    ; full-detail columns first: new LOD jobs only while the job queue is
    ; short (the workers have spare time)
    call job_queue_depth
    cmp eax, [rel g_job_worker_count]
    jb .queue_ok
    mov dword [LOCAL(LU_CAP)], 0
.queue_ok:

    ; ---- pass 1: the tiles every ring needs (nearest levels first) ----
    mov dword [LOCAL(LU_L)], 1
.level:
    mov ecx, [LOCAL(LU_L)]
    cmp ecx, [rel g_lod_levels]
    ja .p1_done
    mov eax, LOD_CELLS
    shl eax, cl
    mov [LOCAL(LU_T)], eax
    lea rax, [rel g_lod_r]
    movss xmm0, [rax + rcx * 4 - 4]
    movss [LOCAL(LU_RIN)], xmm0
    movss xmm0, [rax + rcx * 4]
    movss [LOCAL(LU_ROUT)], xmm0
    ; tile range: camera +- (r_out + T)
    cvtsi2ss xmm1, dword [LOCAL(LU_T)]
    addss xmm0, xmm1
    movss xmm2, [LOCAL(LU_CX)]
    subss xmm2, xmm0
    divss xmm2, xmm1
    roundss xmm2, xmm2, 9
    cvttss2si eax, xmm2
    mov [LOCAL(LU_TX0)], eax
    movss xmm2, [LOCAL(LU_CX)]
    addss xmm2, xmm0
    divss xmm2, xmm1
    roundss xmm2, xmm2, 9
    cvttss2si eax, xmm2
    mov [LOCAL(LU_TX1)], eax
    movss xmm2, [LOCAL(LU_CZ)]
    subss xmm2, xmm0
    divss xmm2, xmm1
    roundss xmm2, xmm2, 9
    cvttss2si eax, xmm2
    mov [LOCAL(LU_TZ)], eax
    movss xmm2, [LOCAL(LU_CZ)]
    addss xmm2, xmm0
    divss xmm2, xmm1
    roundss xmm2, xmm2, 9
    cvttss2si eax, xmm2
    mov [LOCAL(LU_TZ1)], eax
.tz:
    mov eax, [LOCAL(LU_TX0)]
    mov [LOCAL(LU_TX)], eax
.tx:
    ; nearest and farthest distance from the camera to the tile's square
    call tile_distances
    ; keep band: near < r_out + T and far > r_in - T
    cvtsi2ss xmm2, dword [LOCAL(LU_T)]
    movss xmm3, [LOCAL(LU_ROUT)]
    addss xmm3, xmm2
    comiss xmm0, xmm3
    jae .tnext
    movss xmm3, [LOCAL(LU_RIN)]
    subss xmm3, xmm2
    comiss xmm1, xmm3
    jbe .tnext
    movss [LOCAL(LU_MIND)], xmm0
    movss [LOCAL(LU_MAXD)], xmm1
    mov ecx, [LOCAL(LU_L)]
    mov edx, [LOCAL(LU_TX)]
    mov r8d, [LOCAL(LU_TZ)]
    call hash_find
    cmp eax, -1
    je .missing
    TILE_PTR rcx, rax
    mov eax, [rel g_lod_stamp]
    mov [rcx + LODTILE.stamp], eax
    jmp .tnext
.missing:
    ; request band: near < r_out and far > r_in
    movss xmm0, [LOCAL(LU_MIND)]
    comiss xmm0, [LOCAL(LU_ROUT)]
    jae .tnext
    movss xmm0, [LOCAL(LU_MAXD)]
    comiss xmm0, [LOCAL(LU_RIN)]
    jbe .tnext
    inc dword [rel g_lod_missing]
    mov rax, [rel g_lod_inflight]
    cmp eax, [LOCAL(LU_CAP)]
    jae .tnext
    ; a slot: from the free stack, else a new one
    mov rax, [rel g_lod_free_n]
    test rax, rax
    jz .new_slot
    dec rax
    mov [rel g_lod_free_n], rax
    mov rcx, [rel g_lod_free]
    mov ebx, [rcx + rax * 4]
    jmp .have_slot
.new_slot:
    mov rax, [rel g_lod_used]
    cmp rax, MAX_LOD_TILES
    jae .tnext
    mov ebx, eax
    inc qword [rel g_lod_used]
.have_slot:
    TILE_PTR rsi, rbx
    mov eax, [LOCAL(LU_L)]
    mov [rsi + LODTILE.level], eax
    mov eax, [LOCAL(LU_TX)]
    mov [rsi + LODTILE.tx], eax
    mov eax, [LOCAL(LU_TZ)]
    mov [rsi + LODTILE.tz], eax
    mov eax, [rel g_lod_stamp]
    mov [rsi + LODTILE.stamp], eax
    mov dword [rsi + LODTILE.unit], -1
    mov qword [rsi + LODTILE.buf], 0
    mov dword [rsi + LODTILE.quads], 0
    mov dword [rsi + LODTILE.state], LT_GEN
    mov ecx, ebx
    call hash_insert
    inc qword [rel g_lod_inflight]
    lea rcx, [rel lod_tile_job]
    lea r8, [rel g_lod_counter]
    INVOKE job_submit, rcx, rsi, r8
.tnext:
    inc dword [LOCAL(LU_TX)]
    mov eax, [LOCAL(LU_TX)]
    cmp eax, [LOCAL(LU_TX1)]
    jle .tx
    inc dword [LOCAL(LU_TZ)]
    mov eax, [LOCAL(LU_TZ)]
    cmp eax, [LOCAL(LU_TZ1)]
    jle .tz
    inc dword [LOCAL(LU_L)]
    jmp .level
.p1_done:

    ; ---- pass 2: upload finished tiles, drop the ones no ring needs ----
    mov qword [rel g_lod_ready], 0
    mov qword [rel g_lod_inflight], 0
    xor r12d, r12d
.p2:
    cmp r12, [rel g_lod_used]
    jae .p2_done
    TILE_PTR rbx, r12
    mov eax, [rbx + LODTILE.state]
    cmp eax, LT_FREE
    je .p2_next
    cmp eax, LT_GEN
    jne .not_gen
    inc qword [rel g_lod_inflight]
    jmp .p2_next
.not_gen:
    mov ecx, [rel g_lod_stamp]
    cmp [rbx + LODTILE.stamp], ecx
    je .needed
    mov ecx, r12d
    call tile_free
    jmp .p2_next
.needed:
    cmp eax, LT_MESHED
    jne .ready
    cmp dword [LOCAL(LU_BUDGET)], 0
    jle .p2_next
    mov rcx, rbx
    call tile_upload
    cmp eax, -1
    je .p2_next
    sub [LOCAL(LU_BUDGET)], eax
.ready:
    inc qword [rel g_lod_ready]
.p2_next:
    inc r12
    jmp .p2
.p2_done:
    call lod_log
.done:
    RETURN


; tile_distances — xmm0 = nearest, xmm1 = farthest distance (xz) from the
; camera to the current tile's square (LU_TX, LU_TZ, LU_T); reads the
; frame through rbp.   clobbers: xmm0-xmm5
tile_distances:
    cvtsi2ss xmm4, dword [LUL(LU_T)]
    cvtsi2ss xmm2, dword [LUL(LU_TX)]
    mulss xmm2, xmm4
    subss xmm2, [LUL(LU_CX)]            ; a = x0 - c
    movss xmm3, xmm2
    addss xmm3, xmm4                    ; b = x1 - c
    ; near = max(a, -b, 0); far = max(|a|, |b|)
    xorps xmm5, xmm5
    subss xmm5, xmm3
    movss xmm0, xmm2
    maxss xmm0, xmm5
    xorps xmm5, xmm5
    maxss xmm0, xmm5
    andps xmm2, [rel c_abs4]
    andps xmm3, [rel c_abs4]
    maxss xmm2, xmm3
    mulss xmm0, xmm0                    ; near dx^2
    mulss xmm2, xmm2                    ; far dx^2
    cvtsi2ss xmm1, dword [LUL(LU_TZ)]
    mulss xmm1, xmm4
    subss xmm1, [LUL(LU_CZ)]
    movss xmm3, xmm1
    addss xmm3, xmm4
    xorps xmm5, xmm5
    subss xmm5, xmm3
    movss xmm4, xmm1
    maxss xmm4, xmm5
    xorps xmm5, xmm5
    maxss xmm4, xmm5
    mulss xmm4, xmm4
    addss xmm0, xmm4
    sqrtss xmm0, xmm0                   ; near
    andps xmm1, [rel c_abs4]
    andps xmm3, [rel c_abs4]
    maxss xmm1, xmm3
    mulss xmm1, xmm1
    addss xmm1, xmm2
    sqrtss xmm1, xmm1                   ; far
    ret
ENDPROC

; -----------------------------------------------------------------------------
; lod_log — every STAT_LOG_US: tiles, quads, generation times; once: when
; every ring is complete.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC lod_log, 0, rbx
    call timer_elapsed_us
    mov rbx, rax
    cmp dword [rel g_lod_done_logged], 0
    jne .periodic
    cmp dword [rel g_lod_missing], 0
    jne .periodic
    cmp qword [rel g_lod_inflight], 0
    jne .periodic
    mov dword [rel g_lod_done_logged], 1
    mov rax, rbx
    sub rax, [rel g_lod_t0]
    xor edx, edx
    mov ecx, 1000
    div rcx
    LOG_VAL LOG_LEVEL_INFO, "lod: all rings complete after ms", rax
.periodic:
    cmp rbx, [rel g_lod_next_log]
    jb .done
    add rbx, STAT_LOG_US
    mov [rel g_lod_next_log], rbx
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel s_log_ready]
    call log_append_str
    mov rcx, [rel g_lod_ready]
    call log_append_dec
    lea rcx, [rel s_log_flight]
    call log_append_str
    mov rcx, [rel g_lod_inflight]
    call log_append_dec
    lea rcx, [rel s_log_missing]
    call log_append_str
    mov ecx, [rel g_lod_missing]
    call log_append_dec
    lea rcx, [rel s_log_quads]
    call log_append_str
    mov rcx, [rel g_lod_quads]
    call log_append_dec
    lea rcx, [rel s_log_avg]
    call log_append_str
    mov rax, [rel g_lod_gen_total_us]
    xor edx, edx
    mov rcx, [rel g_lod_gen_count]
    test rcx, rcx
    jz .div0
    div rcx
.div0:
    mov rcx, rax
    call log_append_dec
    lea rcx, [rel s_log_max]
    call log_append_str
    mov rcx, [rel g_lod_gen_max_us]
    call log_append_dec
    call log_end
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; lod_shutdown — wait for the jobs, free every tile.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC lod_shutdown, 0, rbx
    lea rcx, [rel g_lod_counter]
    call job_wait
    xor ebx, ebx
.t:
    cmp rbx, [rel g_lod_used]
    jae .done
    TILE_PTR rax, rbx
    cmp dword [rax + LODTILE.state], LT_FREE
    je .n
    mov ecx, ebx
    call tile_free
.n:
    inc ebx
    jmp .t
.done:
    RETURN
ENDPROC

; =============================================================================
; Tile generation (worker thread)
; =============================================================================

; -----------------------------------------------------------------------------
; lod_tile_job — job: heights, surface blocks, quads and tint of one tile.
;   in:  rcx = LODTILE*, rdx = WORKER*
;   Publishes LT_MESHED last. The helpers below share its frame through rbp
;   (TJL), so they may be called at any stack depth.
; -----------------------------------------------------------------------------
%define TJ_T0       0
%define TJ_ARENA    8
%define TJ_MARK     16
%define TJ_X0       24                  ; tile origin (blocks)
%define TJ_Z0       28
%define TJ_S        32                  ; cell size (blocks)
%define TJ_L        36                  ; level
%define TJ_H        40                  ; i32[G34*G34] heights (first air)
%define TJ_B        48                  ; u16[G34*G34] top block
%define TJ_W        56                  ; u8[G34*G34] bit 0 under the sea, bit 1 canopy
%define TJ_BI       64                  ; u8[G34*G34] biome
%define TJ_LAT      72                  ; f32[LAT*LAT*LP] lattice parameters
%define TJ_LATB     80                  ; u8[LAT*LAT] lattice biome
%define TJ_Q        88                  ; u64 quads (scratch)
%define TJ_NQ       96                  ; quads so far
%define TJ_I        100
%define TJ_J        104
%define TJ_HC       108                 ; f32 (scratch)
%define TJ_MINY     112                 ; lowest quad y
%define TJ_MAXY     116                 ; highest quad top (exclusive)
%define TJ_NOPQ     120                 ; opaque quads
%define TJ_VIS      128                 ; u8[1024] greedy visited
%define TJ_PAR      136                 ; f32[LP] parameters of the current cell
%define TJ_TILE     160                 ; LODTILE*
%define TJ_S2       168                 ; TSAMPLE
%define TJ_BOT      (TJ_S2 + TSAMPLE_size)  ; mesh_sides: neighbour height
%define TJ_FILL     (TJ_BOT + 4)        ;   filler block of the cell
%define TJ_ROCK     (TJ_BOT + 8)        ;   rock block of the cell
%define TJ_BAND     (TJ_BOT + 12)       ;   top band height
%define TJ_LOCALS   (TJ_BOT + 16)
%define LP          6                   ; hill, dune, plateau, mesa, pull, pull*level
%define FILL_BAND   3                   ; filler blocks under the top band
PROC lod_tile_job, TJ_LOCALS, rbx, rsi, rdi, r12, r13, r14, r15
%assign TJB OUTGOING_SIZE - %$nregs * 8 - %$frame
%define TJL(x) rbp + TJB + (x)
    mov rbx, rcx                        ; tile
    mov [LOCAL(TJ_TILE)], rcx
    lea rax, [rdx + WORKER.scratch]
    mov [LOCAL(TJ_ARENA)], rax
    call timer_elapsed_us
    mov [LOCAL(TJ_T0)], rax
    mov rcx, [LOCAL(TJ_ARENA)]
    call arena_mark
    mov [LOCAL(TJ_MARK)], rax
    mov ecx, [rbx + LODTILE.level]
    mov [LOCAL(TJ_L)], ecx
    mov eax, 1
    shl eax, cl
    mov [LOCAL(TJ_S)], eax
    mov eax, LOD_CELLS
    shl eax, cl
    mov edx, eax
    imul eax, [rbx + LODTILE.tx]
    mov [LOCAL(TJ_X0)], eax
    imul edx, [rbx + LODTILE.tz]
    mov [LOCAL(TJ_Z0)], edx
    ; scratch arrays
%macro TJ_ALLOC 2
    mov rcx, [LOCAL(TJ_ARENA)]
    INVOKE arena_alloc, rcx, %2, 16
    test rax, rax
    jz .oom
    mov [LOCAL(%1)], rax
%endmacro
    TJ_ALLOC TJ_H, G34 * G34 * 4
    TJ_ALLOC TJ_B, G34 * G34 * 2
    TJ_ALLOC TJ_W, G34 * G34
    TJ_ALLOC TJ_BI, G34 * G34
    TJ_ALLOC TJ_LAT, LAT * LAT * LP * 4
    TJ_ALLOC TJ_LATB, LAT * LAT
    TJ_ALLOC TJ_VIS, LOD_CELLS * LOD_CELLS
    TJ_ALLOC TJ_Q, LOD_MAX_QUADS * 8

    ; ---- 1. biome lattice: every LAT_STEP cells, from cell -LAT_STEP ----
    mov dword [LOCAL(TJ_J)], 0
.lat_j:
    mov dword [LOCAL(TJ_I)], 0
.lat_i:
    mov eax, [LOCAL(TJ_I)]
    imul eax, eax, LAT_STEP
    sub eax, LAT_STEP
    mov ecx, [LOCAL(TJ_J)]
    imul ecx, ecx, LAT_STEP
    sub ecx, LAT_STEP
    call cell_world                     ; xmm0, xmm1 = cell centre
    movq r12, xmm0
    movq r13, xmm1
    lea rcx, [LOCAL(TJ_S2)]
    call terrain_sample
    cvttss2si ecx, [LOCAL(TJ_S2) + TSAMPLE.height]
    movq xmm0, r12
    movq xmm1, r13
    call biome_point                    ; eax = biome
    mov ecx, [LOCAL(TJ_J)]
    imul ecx, ecx, LAT
    add ecx, [LOCAL(TJ_I)]
    mov rdx, [LOCAL(TJ_LATB)]
    mov [rdx + rcx], al
    imul ecx, ecx, LP * 4
    add rcx, [LOCAL(TJ_LAT)]
    test eax, eax
    jnz .lat_biome
    ; no biome: the plain terrain
    mov dword [rcx], 0x3F800000
    mov dword [rcx + 4], 0
    mov qword [rcx + 8], 0
    mov qword [rcx + 16], 0
    jmp .lat_next
.lat_biome:
    imul rax, rax, BIOME_size
    lea rdx, [rel g_biomes]
    add rax, rdx
    mov edx, [rax + BIOME.hill]
    mov [rcx], edx
    mov edx, [rax + BIOME.dune_h]
    mov [rcx + 4], edx
    mov edx, [rax + BIOME.plateau_h]
    mov [rcx + 8], edx
    mov edx, [rax + BIOME.mesa_h]
    mov [rcx + 12], edx
    movss xmm0, [rax + BIOME.flatten + 4]   ; pull
    movss [rcx + 16], xmm0
    mulss xmm0, [rax + BIOME.flatten]       ; pull * level
    movss [rcx + 20], xmm0
.lat_next:
    inc dword [LOCAL(TJ_I)]
    cmp dword [LOCAL(TJ_I)], LAT
    jb .lat_i
    inc dword [LOCAL(TJ_J)]
    cmp dword [LOCAL(TJ_J)], LAT
    jb .lat_j

    ; ---- 2. cell heights (with a 1-cell border) ----
    mov dword [LOCAL(TJ_J)], 0
.h_j:
    mov dword [LOCAL(TJ_I)], 0
.h_i:
    call cell_height                    ; eax = H, ecx = biome
    mov edx, [LOCAL(TJ_J)]
    imul edx, edx, G34
    add edx, [LOCAL(TJ_I)]
    mov r8, [LOCAL(TJ_H)]
    mov [r8 + rdx * 4], eax
    mov r8, [LOCAL(TJ_BI)]
    mov [r8 + rdx], cl
    inc dword [LOCAL(TJ_I)]
    cmp dword [LOCAL(TJ_I)], G34
    jb .h_i
    inc dword [LOCAL(TJ_J)]
    cmp dword [LOCAL(TJ_J)], G34
    jb .h_j

    ; ---- 3. surface blocks (and the canopy, which raises the height) ----
    call surface_blocks

    ; ---- 4. quads ----
    mov dword [LOCAL(TJ_NQ)], 0
    mov dword [LOCAL(TJ_MINY)], 0x7FFFFFFF
    mov dword [LOCAL(TJ_MAXY)], 0x80000000
    call mesh_tops                      ; opaque tops (land and sea floor)
    call mesh_sides                     ; side faces down to lower neighbours
    mov eax, [LOCAL(TJ_NQ)]
    mov [LOCAL(TJ_NOPQ)], eax
    call mesh_water                     ; water surface (translucent)
    mov rbx, [LOCAL(TJ_TILE)]
    ; quad y: relative to the tile's lowest y
    mov eax, [LOCAL(TJ_MINY)]
    cmp dword [LOCAL(TJ_NQ)], 0
    jne .have_y
    xor eax, eax
    mov [LOCAL(TJ_MAXY)], eax
.have_y:
    mov [rbx + LODTILE.min_y], eax
    mov ecx, [LOCAL(TJ_MAXY)]
    sub ecx, eax
    mov [rbx + LODTILE.span], ecx
    add eax, Y_BIAS
    mov rsi, [LOCAL(TJ_Q)]
    xor ecx, ecx
.rel:
    cmp ecx, [LOCAL(TJ_NQ)]
    jae .rel_done
    mov rdx, [rsi + rcx * 8]
    mov r8, rdx
    shr r8, 10
    and r8d, 2047
    sub r8d, eax
    and r8d, 2047
    mov r9, ~(2047 << 10)
    and rdx, r9
    shl r8, 10
    or rdx, r8
    mov [rsi + rcx * 8], rdx
    inc ecx
    jmp .rel
.rel_done:
    mov eax, [LOCAL(TJ_NOPQ)]
    mov [rbx + LODTILE.n_opaque], eax
    mov ecx, [LOCAL(TJ_NQ)]
    sub ecx, eax
    mov [rbx + LODTILE.n_water], ecx

    ; ---- 5. hand quads + tint to the main thread ----
    mov ecx, [rbx + LODTILE.level]
    mov eax, 2
    shl eax, cl                         ; tint texels per side: T / 16
    mov [rbx + LODTILE.tint_n], eax
    imul eax, eax
    imul eax, eax, 12                   ; 3 layers x RGBA8
    mov r12d, eax
    mov r13d, [LOCAL(TJ_NQ)]
    lea rdx, [r13 * 8 + r12]
    API VirtualAlloc, 0, rdx, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE
    test rax, rax
    jz .oom
    mov [rbx + LODTILE.buf], rax
    mov rdi, rax
    mov rsi, [LOCAL(TJ_Q)]
    mov ecx, r13d
    rep movsq
    call tile_tint                      ; rdi = tint destination
    mov rbx, [LOCAL(TJ_TILE)]
    mov eax, [LOCAL(TJ_NQ)]
    mov [rbx + LODTILE.quads], eax
    call timer_elapsed_us
    sub rax, [LOCAL(TJ_T0)]
    mov rdx, rax
    lock add [rel g_lod_gen_total_us], rax
    lock inc qword [rel g_lod_gen_count]
    lea rcx, [rel g_lod_gen_max_us]
    call atomic_max
    jmp .published
.oom:
    mov rbx, [LOCAL(TJ_TILE)]
    mov dword [rbx + LODTILE.quads], 0
    mov qword [rbx + LODTILE.buf], 0
.published:
    mov rcx, [LOCAL(TJ_ARENA)]
    INVOKE arena_reset_to, rcx, [LOCAL(TJ_MARK)]
    mov rbx, [LOCAL(TJ_TILE)]
    mov dword [rbx + LODTILE.state], LT_MESHED
    RETURN

; ---- helpers (worker thread; the job's locals through TJL) ----

; cell_world: xmm0, xmm1 = world x, z (doubles) of the centre of cell
; (eax, ecx) (cell coordinates, may be outside 0..31)   clobbers rax, rcx, xmm2
cell_world:
    imul eax, [TJL(TJ_S)]
    add eax, [TJL(TJ_X0)]
    imul ecx, [TJL(TJ_S)]
    add ecx, [TJL(TJ_Z0)]
    cvtsi2sd xmm0, eax
    cvtsi2sd xmm1, ecx
    cvtsi2sd xmm2, dword [TJL(TJ_S)]
    mulsd xmm2, [rel c_half_d]
    addsd xmm0, xmm2
    addsd xmm1, xmm2
    ret

; cell_height: eax = H (first air) and ecx = biome of grid cell (TJ_I,
; TJ_J) (grid = cell + 1): the terrain height with the biome settings
; blended bilinearly from the lattice; the biome of the nearest lattice
; point.   clobbers: volatile registers, r12-r14
cell_height:
    sub rsp, 40                         ; (shadow space, alignment)
    mov eax, [TJL(TJ_I)]
    dec eax
    mov ecx, [TJL(TJ_J)]
    dec ecx
    call cell_world
    movq r12, xmm0
    movq r13, xmm1
    lea rcx, [TJL(TJ_S2)]
    call terrain_sample
    ; lattice position: (cell + LAT_STEP) / LAT_STEP
    mov eax, [TJL(TJ_I)]
    add eax, LAT_STEP - 1               ; (cell = grid - 1)
    cvtsi2ss xmm4, eax
    mulss xmm4, [rel c_quarter]
    mov eax, [TJL(TJ_J)]
    add eax, LAT_STEP - 1
    cvtsi2ss xmm5, eax
    mulss xmm5, [rel c_quarter]
    roundss xmm0, xmm4, 9
    cvttss2si r8d, xmm0                 ; li
    subss xmm4, xmm0                    ; fx
    roundss xmm0, xmm5, 9
    cvttss2si r9d, xmm0                 ; lj
    subss xmm5, xmm0                    ; fz
    cmp r8d, LAT - 2
    jle .li_ok
    mov r8d, LAT - 2
    movss xmm4, [rel c_one]
.li_ok:
    cmp r9d, LAT - 2
    jle .lj_ok
    mov r9d, LAT - 2
    movss xmm5, [rel c_one]
.lj_ok:
    ; nearest lattice point's biome
    mov eax, r8d
    comiss xmm4, [rel c_half]
    jb .nb_x
    inc eax
.nb_x:
    mov ecx, r9d
    comiss xmm5, [rel c_half]
    jb .nb_z
    inc ecx
.nb_z:
    imul ecx, ecx, LAT
    add ecx, eax
    mov rax, [TJL(TJ_LATB)]
    movzx r14d, byte [rax + rcx]        ; biome
    ; bilinear parameters
    imul r10d, r9d, LAT
    add r10d, r8d                       ; (li, lj)
    imul r10, r10, LP * 4
    add r10, [TJL(TJ_LAT)]
    xor eax, eax
.par:
    movss xmm0, [r10 + rax * 4]
    movss xmm1, [r10 + rax * 4 + LP * 4]
    subss xmm1, xmm0
    mulss xmm1, xmm4
    addss xmm0, xmm1
    movss xmm2, [r10 + rax * 4 + LAT * LP * 4]
    movss xmm3, [r10 + rax * 4 + LAT * LP * 4 + LP * 4]
    subss xmm3, xmm2
    mulss xmm3, xmm4
    addss xmm2, xmm3
    subss xmm2, xmm0
    mulss xmm2, xmm5
    addss xmm0, xmm2
    movss [TJL(TJ_PAR) + rax * 4], xmm0
    inc eax
    cmp eax, LP
    jb .par
    ; height without its detail part, hills scaled around the base
    movss xmm0, [TJL(TJ_S2) + TSAMPLE.fields + F_DETAIL * 4]
    mulss xmm0, [rel g_detail_height]
    movss [TJL(TJ_HC)], xmm0            ; the detail part
    movss xmm1, [TJL(TJ_S2) + TSAMPLE.height]
    subss xmm1, xmm0
    movss xmm2, [TJL(TJ_S2) + TSAMPLE.base]
    comiss xmm1, xmm2
    jbe .hill_done
    subss xmm1, xmm2
    mulss xmm1, [TJL(TJ_PAR)]
    addss xmm1, xmm2
.hill_done:
    movss [TJL(TJ_S2) + TSAMPLE.height], xmm1
    ; dunes, plateaus, mesas (on land above the beach)
    cvtsi2ss xmm0, dword [rel g_beach_high]
    comiss xmm0, xmm1
    jae .shapes_done
    xorps xmm0, xmm0
    comiss xmm0, [TJL(TJ_PAR) + 4]
    jae .no_dune
    movq xmm0, r12
    movq xmm1, r13
    call biome_dunes
    mulss xmm0, [TJL(TJ_PAR) + 4]
    addss xmm0, [TJL(TJ_S2) + TSAMPLE.height]
    movss [TJL(TJ_S2) + TSAMPLE.height], xmm0
.no_dune:
    xorps xmm0, xmm0
    comiss xmm0, [TJL(TJ_PAR) + 8]
    jae .no_plat
    movq xmm0, r12
    movq xmm1, r13
    call biome_plateau
    mulss xmm0, [TJL(TJ_PAR) + 8]
    addss xmm0, [TJL(TJ_S2) + TSAMPLE.height]
    movss [TJL(TJ_S2) + TSAMPLE.height], xmm0
.no_plat:
    xorps xmm0, xmm0
    comiss xmm0, [TJL(TJ_PAR) + 12]
    jae .shapes_done
    movq xmm0, r12
    movq xmm1, r13
    call biome_mesa
    mulss xmm0, [TJL(TJ_PAR) + 12]
    addss xmm0, [TJL(TJ_S2) + TSAMPLE.height]
    movss [TJL(TJ_S2) + TSAMPLE.height], xmm0
.shapes_done:
    ; flatten: towards the blended level (sum pull*level / sum pull)
    movss xmm0, [TJL(TJ_PAR) + 16]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .no_flat
    movss xmm1, [TJL(TJ_PAR) + 20]
    divss xmm1, xmm0                    ; level
    minss xmm0, [rel c_one]
    subss xmm1, [TJL(TJ_S2) + TSAMPLE.height]
    mulss xmm1, xmm0
    addss xmm1, [TJL(TJ_S2) + TSAMPLE.height]
    movss [TJL(TJ_S2) + TSAMPLE.height], xmm1
.no_flat:
    movss xmm0, [TJL(TJ_S2) + TSAMPLE.height]
    addss xmm0, [TJL(TJ_HC)]
    roundss xmm0, xmm0, 9
    cvttss2si eax, xmm0
    mov ecx, r14d
    add rsp, 40
    ret

; surface_blocks: top blocks of every grid cell, the water flags and the
; leaf canopy (raises the cell afterwards, so slopes see the ground)
;   clobbers: volatile registers, rsi, rdi, r12-r15
surface_blocks:
    xor r12d, r12d                      ; j
.sb_j:
    xor r13d, r13d                      ; i
.sb_i:
    imul r14d, r12d, G34
    add r14d, r13d                      ; index
    mov rax, [TJL(TJ_H)]
    mov r15d, [rax + r14 * 4]           ; H
    mov rax, [TJL(TJ_BI)]
    movzx esi, byte [rax + r14]
    imul rsi, rsi, BIOME_size
    lea rax, [rel g_biomes]
    add rsi, rax                        ; BIOME*
    mov rax, [TJL(TJ_W)]
    mov byte [rax + r14], 0
    lea edi, [r15d - 1]                 ; top block y
    cmp edi, [rel g_sea_level]
    jge .sb_land
    ; under the sea: the sea floor
    mov byte [rax + r14], 1
    mov eax, [rsi + BIOME.seabed]
    test eax, eax
    jnz .sb_put
    mov eax, [rel g_b_beach]
    jmp .sb_put
.sb_land:
    ; slope: the largest step to a neighbour inside the grid
    xor ecx, ecx
    mov rax, [TJL(TJ_H)]
%macro SB_NB 1
    mov edx, [rax + r14 * 4 + (%1) * 4]
    sub edx, r15d
    mov r8d, edx
    neg r8d
    cmovs r8d, edx
    cmp r8d, ecx
    cmovg ecx, r8d
%endmacro
    test r13d, r13d
    jz .sb_nx0
    SB_NB -1
.sb_nx0:
    cmp r13d, G34 - 1
    je .sb_nx1
    SB_NB 1
.sb_nx1:
    test r12d, r12d
    jz .sb_nz0
    SB_NB -G34
.sb_nz0:
    cmp r12d, G34 - 1
    je .sb_nz1
    SB_NB G34
.sb_nz1:
    mov r9d, ecx                        ; slope (blocks per cell)
    mov r10d, [rel g_steep]
    imul r10d, [TJL(TJ_S)]              ; steep (blocks per cell)
    cmp edi, [rel g_snow_line]
    jl .sb_not_snow
    ; snow clings to slopes up to twice the steep limit
    lea eax, [r10d * 2]
    cmp r9d, eax
    jge .sb_rock
    mov eax, [rel g_b_snow]
    jmp .sb_put
.sb_not_snow:
    cmp r9d, r10d
    jl .sb_not_steep
.sb_rock:
    mov eax, [rsi + BIOME.steep]
    test eax, eax
    jnz .sb_put
    mov eax, [rel g_b_stone]
    jmp .sb_put
.sb_not_steep:
    cmp edi, [rel g_beach_high]
    jg .sb_inland
    cmp dword [rsi + BIOME.own_shore], 0
    jne .sb_inland
    mov eax, [rsi + BIOME.beach]
    test eax, eax
    jnz .sb_put
    mov eax, [rel g_b_beach]
    jmp .sb_put
.sb_inland:
    ; glaciers: their snow (or ice)
    mov eax, [rsi + BIOME.ice]
    test eax, eax
    jz .sb_ground
    mov ecx, [rsi + BIOME.ice_snow]
    test ecx, ecx
    cmovnz eax, ecx
    jmp .sb_put
.sb_ground:
    ; forests: a leaf canopy CANOPY_HEIGHT above the ground
    movss xmm0, [rsi + BIOME.tree_dens]
    comiss xmm0, [rel c_canopy]
    jb .sb_top
    cmp dword [rsi + BIOME.ntrees], 0
    je .sb_top
    mov ecx, [rsi + BIOME.tree]         ; the first tree's leaves
    imul rcx, rcx, TREE_size
    lea rdx, [rel g_trees]
    mov eax, [rdx + rcx + TREE.leaves]
    test eax, eax
    jz .sb_top
    mov rdx, [TJL(TJ_W)]
    or byte [rdx + r14], 2
    jmp .sb_put
.sb_top:
    mov eax, [rsi + BIOME.top]
    test eax, eax
    jnz .sb_put
    mov eax, [rel g_b_top]
.sb_put:
    cmp eax, BLOCK_STRATA
    jne .sb_store
    mov eax, [rel g_b_stone]            ; (striped rock: plain stone far away)
.sb_store:
    mov rdx, [TJL(TJ_B)]
    mov [rdx + r14 * 2], ax
    inc r13d
    cmp r13d, G34
    jb .sb_i
    inc r12d
    cmp r12d, G34
    jb .sb_j
    ; raise the canopy cells
    mov rax, [TJL(TJ_W)]
    mov rdx, [TJL(TJ_H)]
    xor ecx, ecx
.sb_c:
    test byte [rax + rcx], 2
    jz .sb_c_next
    add dword [rdx + rcx * 4], CANOPY_HEIGHT
.sb_c_next:
    inc ecx
    cmp ecx, G34 * G34
    jb .sb_c
    ret

; emit: append a quad. in: eax = x, ecx = z (cells), edx = y (blocks,
; absolute), r8d = face, r9d = w - 1 (cells), r10d = h - 1 (cells along a
; horizontal axis, blocks up a side), r11d = block
;   clobbers: rax, rcx, rdx, r8-r11
emit:
    cmp dword [TJL(TJ_NQ)], LOD_MAX_QUADS
    jae .full
    cmp edx, [TJL(TJ_MINY)]
    jge .ymin
    mov [TJL(TJ_MINY)], edx
.ymin:
    push rax
    lea eax, [edx + 1]                  ; top of a horizontal face
    cmp r8d, 2
    je .top
    cmp r8d, 3
    je .top
    lea eax, [edx + r10d + 1]           ; top of a side face
.top:
    cmp eax, [TJL(TJ_MAXY)]
    jle .ymax
    mov [TJL(TJ_MAXY)], eax
.ymax:
    pop rax
    and eax, 31
    and ecx, 31
    shl ecx, 5
    or eax, ecx
    lea ecx, [edx + Y_BIAS]
    and ecx, 2047
    shl ecx, 10
    or eax, ecx
    mov ecx, r8d
    and ecx, 7
    shl ecx, 21
    or eax, ecx
    mov ecx, r9d
    and ecx, 31
    shl ecx, 24
    or eax, ecx                         ; low word (upper half of rax clear)
    and r11d, 0xFFFF
    mov ecx, r10d
    and ecx, 2047
    shl ecx, 16
    or r11d, ecx                        ; high word
    shl r11, 32
    or rax, r11
    mov rcx, [TJL(TJ_Q)]
    mov edx, [TJL(TJ_NQ)]
    mov [rcx + rdx * 8], rax
    inc dword [TJL(TJ_NQ)]
.full:
    ret

; mesh_tops: greedy rectangles of equal (height, block) over the 32 x 32
; inner cells (land tops and sea floors)
;   clobbers: volatile registers, rbx, rsi, rdi, r12-r15
mesh_tops:
    mov rdi, [TJL(TJ_VIS)]
    xor eax, eax
    mov ecx, LOD_CELLS * LOD_CELLS
    rep stosb
    xor r12d, r12d                      ; z
.mt_z:
    xor r13d, r13d                      ; x
.mt_x:
    mov eax, r12d
    shl eax, 5
    add eax, r13d
    mov rdx, [TJL(TJ_VIS)]
    cmp byte [rdx + rax], 0
    jne .mt_next
    ; key of this cell
    lea r14d, [r12d + 1]
    imul r14d, r14d, G34
    lea r14d, [r14d + r13d + 1]         ; grid index
    mov rdx, [TJL(TJ_H)]
    mov esi, [rdx + r14 * 4]            ; H
    mov rdx, [TJL(TJ_B)]
    movzx edi, word [rdx + r14 * 2]     ; block
    ; width along x
    mov r15d, 1
.mt_w:
    lea eax, [r13d + r15d]
    cmp eax, LOD_CELLS
    jae .mt_w_done
    lea ecx, [r14d + r15d]
    mov rdx, [TJL(TJ_H)]
    cmp [rdx + rcx * 4], esi
    jne .mt_w_done
    mov rdx, [TJL(TJ_B)]
    cmp [rdx + rcx * 2], di
    jne .mt_w_done
    mov edx, r12d
    shl edx, 5
    add edx, eax
    mov r8, [TJL(TJ_VIS)]
    cmp byte [r8 + rdx], 0
    jne .mt_w_done
    inc r15d
    jmp .mt_w
.mt_w_done:
    ; height along z: whole rows must match
    mov ebx, 1
.mt_h:
    lea eax, [r12d + ebx]
    cmp eax, LOD_CELLS
    jae .mt_h_done
    xor r8d, r8d
.mt_row:
    cmp r8d, r15d
    jae .mt_row_ok
    lea ecx, [r14d + r8d]
    imul eax, ebx, G34
    add ecx, eax
    mov rdx, [TJL(TJ_H)]
    cmp [rdx + rcx * 4], esi
    jne .mt_h_done
    mov rdx, [TJL(TJ_B)]
    cmp [rdx + rcx * 2], di
    jne .mt_h_done
    lea eax, [r12d + ebx]
    shl eax, 5
    add eax, r13d
    add eax, r8d
    mov rdx, [TJL(TJ_VIS)]
    cmp byte [rdx + rax], 0
    jne .mt_h_done
    inc r8d
    jmp .mt_row
.mt_row_ok:
    inc ebx
    jmp .mt_h
.mt_h_done:
    ; mark and emit
    xor ecx, ecx
.mt_mz:
    cmp ecx, ebx
    jae .mt_marked
    xor r8d, r8d
.mt_mx:
    cmp r8d, r15d
    jae .mt_mz_next
    lea eax, [r12d + ecx]
    shl eax, 5
    add eax, r13d
    add eax, r8d
    mov rdx, [TJL(TJ_VIS)]
    mov byte [rdx + rax], 1
    inc r8d
    jmp .mt_mx
.mt_mz_next:
    inc ecx
    jmp .mt_mz
.mt_marked:
    mov eax, r13d
    mov ecx, r12d
    lea edx, [esi - 1]                  ; the top block's y
    mov r8d, 3                          ; +Y
    lea r9d, [r15d - 1]
    lea r10d, [ebx - 1]
    mov r11d, edi
    call emit
.mt_next:
    inc r13d
    cmp r13d, LOD_CELLS
    jb .mt_x
    inc r12d
    cmp r12d, LOD_CELLS
    jb .mt_z
    ret

; mesh_sides: side faces of every inner cell down to its lower neighbours
; (the neighbours outside the tile are in the grid's border): a top band of
; the top block (the canopy's height for leaves), FILL_BAND blocks of the
; biome's filler, then rock
;   clobbers: volatile registers, rbx, rsi, rdi, r12-r15
mesh_sides:
    xor r12d, r12d                      ; z
.ms_z:
    xor r13d, r13d                      ; x
.ms_x:
    lea r14d, [r12d + 1]
    imul r14d, r14d, G34
    lea r14d, [r14d + r13d + 1]         ; grid index
    mov rdx, [TJL(TJ_H)]
    mov esi, [rdx + r14 * 4]            ; H
    mov rdx, [TJL(TJ_B)]
    movzx edi, word [rdx + r14 * 2]     ; top block
    ; this cell's bands
    mov rdx, [TJL(TJ_W)]
    mov eax, 1
    test byte [rdx + r14], 2
    jz .ms_band
    mov eax, CANOPY_HEIGHT
.ms_band:
    mov [TJL(TJ_BAND)], eax
    mov rdx, [TJL(TJ_BI)]
    movzx eax, byte [rdx + r14]
    imul rax, rax, BIOME_size
    lea rdx, [rel g_biomes]
    add rdx, rax
    mov eax, [rdx + BIOME.filler]
    test eax, eax
    jnz .ms_fill
    mov eax, [rel g_b_fill]
.ms_fill:
    cmp eax, BLOCK_STRATA
    jne .ms_fill_ok
    mov eax, [rel g_b_stone]
.ms_fill_ok:
    mov [TJL(TJ_FILL)], eax
    mov eax, [rdx + BIOME.steep]
    test eax, eax
    jnz .ms_rock
    mov eax, [rel g_b_stone]
.ms_rock:
    cmp eax, BLOCK_STRATA
    jne .ms_rock_ok
    mov eax, [rel g_b_stone]
.ms_rock_ok:
    mov [TJL(TJ_ROCK)], eax
    ; snow, sand and rock tops: one material all the way down
    cmp edi, [rel g_b_snow]
    je .ms_one
    cmp edi, [TJL(TJ_ROCK)]
    je .ms_one
    cmp edi, [rel g_b_stone]
    je .ms_one
    mov rdx, [TJL(TJ_W)]
    test byte [rdx + r14], 1
    jz .ms_dirs
.ms_one:
    mov [TJL(TJ_FILL)], edi
    mov [TJL(TJ_ROCK)], edi
.ms_dirs:
    xor r15d, r15d                      ; direction
.ms_d:
    lea rax, [rel side_ofs]
    movsxd rcx, dword [rax + r15 * 4]
    add rcx, r14
    mov rdx, [TJL(TJ_H)]
    mov ecx, [rdx + rcx * 4]            ; neighbour height
    cmp ecx, esi
    jge .ms_d_next
    mov [TJL(TJ_BOT)], ecx
    mov ebx, esi                        ; the band's top
    ; top band
    mov edx, ebx
    sub edx, [TJL(TJ_BAND)]
    mov r11d, edi
    call side_band
    jle .ms_d_next
    mov edx, ebx
    sub edx, FILL_BAND
    mov r11d, [TJL(TJ_FILL)]
    call side_band
    jle .ms_d_next
    mov edx, [TJL(TJ_BOT)]
    mov r11d, [TJL(TJ_ROCK)]
    call side_band
.ms_d_next:
    inc r15d
    cmp r15d, 4
    jb .ms_d
    inc r13d
    cmp r13d, LOD_CELLS
    jb .ms_x
    inc r12d
    cmp r12d, LOD_CELLS
    jb .ms_z
    ret

; side_band (mesh_sides): one side quad from max(edx, bottom) up to ebx
; with block r11d in direction r15d of cell (r13d, r12d); ebx = its bottom
; afterwards. out: flags "le" when the bottom was reached
side_band:
    cmp edx, [TJL(TJ_BOT)]
    jge .sb_lo
    mov edx, [TJL(TJ_BOT)]
.sb_lo:
    cmp edx, ebx
    jge .sb_none
    lea r10d, [ebx - 1]
    sub r10d, edx                       ; h - 1
    mov ebx, edx
    mov eax, r13d
    mov ecx, r12d
    lea r8, [rel side_face]
    mov r8d, [r8 + r15 * 4]
    xor r9d, r9d
    call emit
.sb_none:
    cmp ebx, [TJL(TJ_BOT)]
    ret

; mesh_water: greedy water surface rectangles at the sea level over the
; cells under the sea
;   clobbers: volatile registers, rbx, rsi, rdi, r12-r15
mesh_water:
    mov rdi, [TJL(TJ_VIS)]
    xor eax, eax
    mov ecx, LOD_CELLS * LOD_CELLS
    rep stosb
    mov rsi, [TJL(TJ_W)]
    mov rdi, [TJL(TJ_VIS)]
    xor r12d, r12d                      ; z
.mw_z:
    xor r13d, r13d                      ; x
.mw_x:
    mov eax, r12d
    shl eax, 5
    add eax, r13d
    cmp byte [rdi + rax], 0
    jne .mw_next
    lea r14d, [r12d + 1]
    imul r14d, r14d, G34
    lea r14d, [r14d + r13d + 1]
    test byte [rsi + r14], 1
    jz .mw_next
    ; width along x
    mov r15d, 1
.mw_w:
    lea eax, [r13d + r15d]
    cmp eax, LOD_CELLS
    jae .mw_w_done
    lea ecx, [r14d + r15d]
    test byte [rsi + rcx], 1
    jz .mw_w_done
    mov edx, r12d
    shl edx, 5
    add edx, eax
    cmp byte [rdi + rdx], 0
    jne .mw_w_done
    inc r15d
    jmp .mw_w
.mw_w_done:
    mov ebx, 1
.mw_h:
    lea eax, [r12d + ebx]
    cmp eax, LOD_CELLS
    jae .mw_h_done
    xor r8d, r8d
.mw_row:
    cmp r8d, r15d
    jae .mw_row_ok
    imul ecx, ebx, G34
    add ecx, r14d
    add ecx, r8d
    test byte [rsi + rcx], 1
    jz .mw_h_done
    lea eax, [r12d + ebx]
    shl eax, 5
    add eax, r13d
    add eax, r8d
    cmp byte [rdi + rax], 0
    jne .mw_h_done
    inc r8d
    jmp .mw_row
.mw_row_ok:
    inc ebx
    jmp .mw_h
.mw_h_done:
    xor ecx, ecx
.mw_mz:
    cmp ecx, ebx
    jae .mw_marked
    xor r8d, r8d
.mw_mx:
    cmp r8d, r15d
    jae .mw_mz_next
    lea eax, [r12d + ecx]
    shl eax, 5
    add eax, r13d
    add eax, r8d
    mov byte [rdi + rax], 1
    inc r8d
    jmp .mw_mx
.mw_mz_next:
    inc ecx
    jmp .mw_mz
.mw_marked:
    mov eax, r13d
    mov ecx, r12d
    mov edx, [rel g_sea_level]          ; the top water block
    mov r8d, 3
    lea r9d, [r15d - 1]
    lea r10d, [ebx - 1]
    mov r11d, [rel g_b_water]
    call emit
.mw_next:
    inc r13d
    cmp r13d, LOD_CELLS
    jb .mw_x
    inc r12d
    cmp r12d, LOD_CELLS
    jb .mw_z
    ret

; tile_tint: the tint texels at rdi: 3 layers (grass, foliage, water) of
; tint_n x tint_n RGBA8 factors, 16 blocks per texel, from the biome of the
; cell under each texel's centre
;   clobbers: volatile registers, rsi, rdi, r12-r15
tile_tint:
    mov rax, [TJL(TJ_TILE)]
    mov r12d, [rax + LODTILE.tint_n]
    xor r13d, r13d                      ; layer
.tt_l:
    xor r14d, r14d                      ; v
.tt_v:
    xor r15d, r15d                      ; u
.tt_u:
    mov ecx, [TJL(TJ_L)]
    mov eax, r15d
    shl eax, 4
    add eax, 8
    shr eax, cl                         ; cell x
    mov edx, r14d
    shl edx, 4
    add edx, 8
    shr edx, cl                         ; cell z
    inc edx
    imul edx, edx, G34
    lea edx, [edx + eax + 1]
    mov rax, [TJL(TJ_BI)]
    movzx eax, byte [rax + rdx]
    imul rax, rax, BIOME_size
    lea rsi, [rel g_biomes]
    add rsi, rax
    lea rax, [rel tint_field]
    mov eax, [rax + r13 * 4]
    mov eax, [rsi + rax]
    test eax, 0xFFFFFF
    jnz .tt_put
    mov eax, 0xFF404040                 ; (no biome: factor 1)
.tt_put:
    or eax, 0xFF000000
    stosd
    inc r15d
    cmp r15d, r12d
    jb .tt_u
    inc r14d
    cmp r14d, r12d
    jb .tt_v
    inc r13d
    cmp r13d, 3
    jb .tt_l
    ret
ENDPROC
