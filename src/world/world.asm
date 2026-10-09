; =============================================================================
; world.asm — Milestone 5 test world: config, columns, generation, meshing.
;
; The world is a fixed square of (2*radius)^2 columns around the origin,
; described by data/world/flat_test.cfg (blocks, layers, debug structures).
; Generation and meshing run as parallel jobs (one job per column, then one
; per stored section); mesh quads are appended to a shared staging arena and
; uploaded to the GPU once by world_render. Milestone 6 turns this into
; streaming around the player.
;
; Public API (see include/world_api.inc):
;   world_init() -> eax 1/0            load config, generate, mesh
;   world_column(cx, cz) -> rax COLUMN* or 0
;   world_section_at(cx, sy, cz) -> rax SECT* or 0
;   world_block_at(wx, wy, wz) -> eax block id
;   g_draw_list / g_draw_count         sections that have quads
;   g_mesh_staging (ARENA), g_world_quads, timing stats (g_world_*)
; =============================================================================
%define WORLD_IMPL
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "jobs.inc"
%include "file.inc"
%include "cfg.inc"
%include "section.inc"
%include "world_api.inc"

global world_init, world_column, world_section_at, world_block_at
global g_draw_list, g_draw_count, g_mesh_staging, g_world_quads
global g_world_columns_n, g_world_mesh_list_count
global g_world_gen_wall_us, g_world_gen_total_us, g_world_gen_max_us
global g_world_mesh_wall_us, g_world_mesh_total_us, g_world_mesh_max_us
global g_world_radius

extern str_ieq, str_parse_float, str_parse_u64
extern blocks_init, block_register, block_find
extern mesh_section
extern timer_elapsed_us

%define MAX_LAYERS          16
%define MAX_STRUCT_BLOCKS   8
%define HASH_BITS           13
%define HASH_SIZE           (1 << HASH_BITS)
%define STRUCT_BASE_Y       100
%define STRUCT_TOP_Y        220
%define STRUCT_RADIUS       128         ; blocks around the origin
%define PILLAR_SPACING      37
%define PILLAR_TOP_Y        210
%define MESH_MAX_QUADS      98304
%define STAGING_RESERVE     MB(512)

section .rdata
str_cfg_path:   db "data/world/flat_test.cfg", 0
str_cfg_label:  db "flat_test.cfg", 0
k_block:        db "block", 0
k_radius:       db "radius_chunks", 0
k_layer:        db "layer", 0
k_structures:   db "test_structures", 0
k_struct_blk:   db "structure_blocks", 0
k_pillar:       db "pillar_block", 0
str_unknown:    db "unknown setting: ", 0
str_bad_block:  db "unknown block: ", 0
str_bad_value:  db "bad value for: ", 0
name_staging:   db "mesh staging", 0
str_gen:        db "world: generated ", 0
str_cols:       db " columns in ", 0
str_us_wall:    db " us wall (", 0
str_us_job:     db " us per column avg, max ", 0
str_us_close:   db " us)", 0
str_mesh:       db "world: meshed ", 0
str_sections:   db " sections in ", 0
str_us_sec:     db " us per section avg, max ", 0
str_quads:      db "world: quads ", 0
str_drawn:      db ", sections with geometry ", 0
str_stored:     db ", stored sections ", 0

section .data
align 4
g_world_radius:     dd 8

section .bss
alignb 8
g_layer_top:        resd MAX_LAYERS
g_layer_id:         resd MAX_LAYERS
g_layer_count:      resd 1
g_struct_enabled:   resd 1
g_struct_ids:       resd MAX_STRUCT_BLOCKS
g_struct_count:     resd 1
g_pillar_id:        resd 1
alignb 8
g_columns:          resq 1              ; COLUMN* array
g_world_columns_n:  resq 1
g_hash:             resq 1              ; HASH_SIZE x {key, COLUMN*}
g_mesh_list:        resq 1              ; SECT* array
g_world_mesh_list_count: resq 1
g_draw_list:        resq 1              ; SECT* array (quad_count > 0)
g_draw_count:       resq 1
g_counter:          resq 1
g_cfg_mark:         resq 1
alignb 64
g_world_quads:          resq 1
g_world_gen_total_us:   resq 1
g_world_gen_max_us:     resq 1
g_world_mesh_total_us:  resq 1
g_world_mesh_max_us:    resq 1
g_world_gen_wall_us:    resq 1
g_world_mesh_wall_us:   resq 1
alignb 64
g_mesh_staging:     resb ARENA_size
g_cfg_path:         resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; atomic_max — [rcx] = max([rcx], rdx), lock-free.
;   clobbers: rax
; -----------------------------------------------------------------------------
atomic_max:
    mov rax, [rcx]
.retry:
    cmp rdx, rax
    jbe .done
    lock cmpxchg [rcx], rdx
    jne .retry
.done:
    ret

; -----------------------------------------------------------------------------
; parse_hex — parse hexadecimal digits (optional 0x / #).
;   in:  rcx = text      out: eax = value, edx = digit count
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
parse_hex:
    cmp byte [rcx], '#'
    jne .no_hash
    inc rcx
.no_hash:
    cmp word [rcx], '0x'
    jne .digits
    add rcx, 2
.digits:
    xor eax, eax
    xor edx, edx
.loop:
    movzx r8d, byte [rcx]
    or r8d, 0x20                        ; lower-case letters
    sub r8d, '0'
    cmp r8d, 9
    jbe .digit
    sub r8d, 'a' - '0'
    cmp r8d, 5
    ja .end
    add r8d, 10
.digit:
    shl eax, 4
    or eax, r8d
    inc edx
    inc rcx
    jmp .loop
.end:
    ret

; -----------------------------------------------------------------------------
; parse_int — signed integer via the float parser (enough for coordinates).
;   in:  rcx = text      out: eax = value, edx = 1 if valid
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC parse_int, 0
    call str_parse_float
    mov edx, eax
    cvttss2si eax, xmm0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; lookup_block_token — next list token resolved to a block id.
;   in:  rcx = cursor
;   out: eax = id (-1 unknown, warned), rdx = next cursor (0 = last)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC lookup_block_token, 0, rbx, rsi
    call cfg_next_token
    mov rsi, rdx
    mov rbx, rax
    INVOKE block_find, rbx
    cmp eax, -1
    jne .ok
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_bad_block]
    INVOKE cfg_warn, rcx, rdx, rbx
    mov eax, -1
.ok:
    mov rdx, rsi
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; world_pair — cfg_parse callback for flat_test.cfg.
;   in:  rcx = name, rdx = value
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_pair, 0, rbx, rsi, rdi, r12
    mov rbx, rcx
    mov rsi, rdx
    lea rdx, [rel k_block]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .block
    lea rdx, [rel k_radius]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .radius
    lea rdx, [rel k_layer]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .layer
    lea rdx, [rel k_structures]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .structures
    lea rdx, [rel k_struct_blk]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .struct_blocks
    lea rdx, [rel k_pillar]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .pillar
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_unknown]
    INVOKE cfg_warn, rcx, rdx, rbx
    RETURN

.block:                                 ; block = name, RRGGBB
    mov rcx, rsi
    call cfg_next_token
    mov rdi, rax                        ; name
    test rdx, rdx
    jz .bad
    mov rcx, rdx
    call cfg_next_token
    mov rcx, rax
    call parse_hex
    test edx, edx
    jz .bad
    INVOKE block_register, rdi, rax
    RETURN

.radius:
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp eax, 1
    jb .bad
    cmp eax, 32
    ja .bad
    mov [rel g_world_radius], eax
    RETURN

.layer:                                 ; layer = block, top_y
    mov ecx, [rel g_layer_count]
    cmp ecx, MAX_LAYERS
    jae .bad
    mov rcx, rsi
    call lookup_block_token
    cmp eax, -1
    je .done
    mov edi, eax
    test rdx, rdx
    jz .bad
    mov rcx, rdx
    call cfg_next_token
    mov rcx, rax
    call parse_int
    test edx, edx
    jz .bad
    mov ecx, [rel g_layer_count]
    lea rdx, [rel g_layer_top]
    mov [rdx + rcx * 4], eax
    lea rdx, [rel g_layer_id]
    mov [rdx + rcx * 4], edi
    inc dword [rel g_layer_count]
    RETURN

.structures:
    mov rcx, rsi
    call str_parse_u64
    mov [rel g_struct_enabled], eax
    RETURN

.struct_blocks:
    mov r12, rsi                        ; cursor
.sb_next:
    test r12, r12
    jz .done
    mov ecx, [rel g_struct_count]
    cmp ecx, MAX_STRUCT_BLOCKS
    jae .done
    mov rcx, r12
    call lookup_block_token
    mov r12, rdx
    cmp eax, -1
    je .sb_next
    mov ecx, [rel g_struct_count]
    lea rdx, [rel g_struct_ids]
    mov [rdx + rcx * 4], eax
    inc dword [rel g_struct_count]
    jmp .sb_next

.pillar:
    mov rcx, rsi
    call lookup_block_token
    cmp eax, -1
    je .done
    mov [rel g_pillar_id], eax
    RETURN

.bad:
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_bad_value]
    INVOKE cfg_warn, rcx, rdx, rbx
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; hash_slot — first probe slot for a column key.
;   in:  ecx = cx, edx = cz     out: rax = key, rdx = slot index
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
hash_slot:
    mov eax, ecx                        ; zero-extends cx
    shl rdx, 32
    or rax, rdx                         ; key = cz:cx
    mov rdx, 0x9E3779B97F4A7C15
    imul rdx, rax
    shr rdx, 64 - HASH_BITS
    ret

; -----------------------------------------------------------------------------
; world_column — find a column by chunk coordinates.
;   in:  ecx = cx, edx = cz
;   out: rax = COLUMN* or 0
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
world_column:
    call hash_slot
    mov r8, [rel g_hash]
    test r8, r8
    jz .none
.probe:
    mov rcx, rdx
    shl rcx, 4
    cmp qword [r8 + rcx + 8], 0
    je .none
    cmp [r8 + rcx], rax
    je .found
    inc rdx
    and rdx, HASH_SIZE - 1
    jmp .probe
.found:
    mov rax, [r8 + rcx + 8]
    ret
.none:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; world_section_at — section by chunk coordinates (sy 0..39).
;   in:  ecx = cx, edx = sy, r8d = cz
;   out: rax = SECT* or 0 (air / missing / out of range)
;   clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
world_section_at:
    cmp edx, SECTIONS_PER_COLUMN
    jae .none                           ; also catches negative sy
    mov r9d, edx
    mov edx, r8d
    call world_column
    test rax, rax
    jz .none
    mov rax, [rax + COLUMN.sections + r9 * 8]
    ret
.none:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; world_block_at — block id at world coordinates.
;   in:  ecx = wx, edx = wy, r8d = wz
;   out: eax = block id (air outside the world)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_block_at, 0, rbx
    add edx, -WORLD_MIN_Y               ; y relative to the world bottom
    js .air
    ; idx = (y&31)<<10 | (z&31)<<5 | (x&31)
    mov ebx, edx
    and ebx, 31
    shl ebx, 10
    mov eax, r8d
    and eax, 31
    shl eax, 5
    or ebx, eax
    mov eax, ecx
    and eax, 31
    or ebx, eax
    sar ecx, 5
    sar edx, 5
    sar r8d, 5
    call world_section_at
    mov rcx, rax
    mov edx, ebx
    call section_get
    RETURN
.air:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; layer_index — which layer covers world height y.
;   in:  ecx = y      out: eax = layer index (== count: above all layers)
;   clobbers: rax, rdx
; -----------------------------------------------------------------------------
layer_index:
    xor eax, eax
    lea rdx, [rel g_layer_top]
.next:
    cmp eax, [rel g_layer_count]
    jae .done
    cmp ecx, [rdx + rax * 4]
    jle .done
    inc eax
    jmp .next
.done:
    ret

; -----------------------------------------------------------------------------
; layer_block — block id of a layer index (air past the last layer).
;   in:  eax = index      out: eax = id
;   clobbers: rax, rdx
; -----------------------------------------------------------------------------
layer_block:
    cmp eax, [rel g_layer_count]
    jae .air
    lea rdx, [rel g_layer_id]
    mov eax, [rdx + rax * 4]
    ret
.air:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; pos_mod — positive modulo.
;   in:  ecx = value, r8d = modulus (> 0)    out: eax = value mod modulus
;   clobbers: rax, rdx
; -----------------------------------------------------------------------------
pos_mod:
    mov eax, ecx
    cdq
    idiv r8d
    mov eax, edx
    test eax, eax
    jns .ok
    add eax, r8d
.ok:
    ret

; -----------------------------------------------------------------------------
; apply_structures — stamp the debug structures (hills of banded blocks and
; pillars) into a section's id array. Debug content for testing the mesher,
; not game content.
;   in:  rcx = ids u16[32768], edx = cx, r8d = cz, r9d = y0 (section base)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define AS_IDS  0
%define AS_CX   8
%define AS_CZ   16
%define AS_Y0   24
%define AS_Z    32
%define AS_X    40
PROC apply_structures, 48, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(AS_IDS)], rcx
    movsxd rax, edx
    mov [LOCAL(AS_CX)], rax
    movsxd rax, r8d
    mov [LOCAL(AS_CZ)], rax
    movsxd rax, r9d
    mov [LOCAL(AS_Y0)], rax
    cmp dword [rel g_struct_count], 0
    je .done
    mov qword [LOCAL(AS_Z)], 0
.z_loop:
    mov qword [LOCAL(AS_X)], 0
.x_loop:
    ; world coordinates
    mov r12, [LOCAL(AS_CX)]
    shl r12, 5
    add r12, [LOCAL(AS_X)]              ; wx
    mov r13, [LOCAL(AS_CZ)]
    shl r13, 5
    add r13, [LOCAL(AS_Z)]              ; wz
    ; inside the structure square?
    mov rax, r12
    cqo
    xor rax, rdx
    sub rax, rdx
    cmp rax, STRUCT_RADIUS
    jge .next_x
    mov rax, r13
    cqo
    xor rax, rdx
    sub rax, rdx
    cmp rax, STRUCT_RADIUS
    jge .next_x
    ; pillar?
    xor r15d, r15d                      ; r15 = pillar flag
    cmp dword [rel g_pillar_id], 0
    je .hill
    mov ecx, r12d
    mov r8d, PILLAR_SPACING
    call pos_mod
    test eax, eax
    jnz .hill
    mov ecx, r13d
    mov r8d, PILLAR_SPACING
    call pos_mod
    test eax, eax
    jnz .hill
    mov r15d, 1
    mov r14d, PILLAR_TOP_Y              ; exclusive top
    jmp .fill
.hill:
    ; h = (64 - |wx&63 - 32| - |wz&63 - 32|) / 2 + small hash jitter
    mov eax, r12d
    and eax, 63
    sub eax, 32
    cdq
    xor eax, edx
    sub eax, edx
    mov ecx, eax
    mov eax, r13d
    and eax, 63
    sub eax, 32
    cdq
    xor eax, edx
    sub eax, edx
    add ecx, eax
    mov eax, 64
    sub eax, ecx
    sar eax, 1
    mov r14d, eax
    mov eax, r12d
    sar eax, 2
    imul eax, eax, 73856093
    mov ecx, r13d
    sar ecx, 2
    imul ecx, ecx, 19349663
    xor eax, ecx
    shr eax, 13
    and eax, 3
    add r14d, eax
    test r14d, r14d
    jle .next_x
    add r14d, STRUCT_BASE_Y             ; exclusive top
.fill:
    ; y from max(base, y0) to min(top, y0+32) - 1
    mov rbx, [LOCAL(AS_Y0)]
    mov eax, STRUCT_BASE_Y
    cmp ebx, eax
    cmovl ebx, eax                      ; ebx = y start
    mov rsi, [LOCAL(AS_Y0)]
    add esi, 32
    cmp esi, r14d
    cmovg esi, r14d                     ; esi = y end (exclusive)
.y_loop:
    cmp ebx, esi
    jge .next_x
    ; block
    mov edi, [rel g_pillar_id]
    test r15d, r15d
    jnz .have_block
    mov eax, ebx
    sub eax, STRUCT_BASE_Y
    xor edx, edx
    mov ecx, 6
    div ecx
    xor edx, edx
    div dword [rel g_struct_count]
    lea rax, [rel g_struct_ids]
    mov edi, [rax + rdx * 4]
.have_block:
    ; idx = (y - y0) << 10 | z << 5 | x
    mov eax, ebx
    sub eax, [LOCAL(AS_Y0)]
    shl eax, 10
    mov ecx, [LOCAL(AS_Z)]
    shl ecx, 5
    or eax, ecx
    or eax, [LOCAL(AS_X)]
    mov rcx, [LOCAL(AS_IDS)]
    mov [rcx + rax * 2], di
    inc ebx
    jmp .y_loop
.next_x:
    inc qword [LOCAL(AS_X)]
    cmp qword [LOCAL(AS_X)], 32
    jb .x_loop
    inc qword [LOCAL(AS_Z)]
    cmp qword [LOCAL(AS_Z)], 32
    jb .z_loop
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gen_column_job — job: generate all 40 sections of one column.
;   in:  rcx = column index, rdx = WORKER*
; -----------------------------------------------------------------------------
PROC gen_column_job, 16, rbx, rsi, rdi, r12, r13, r14, r15
    mov rax, [rel g_columns]
    mov rbx, [rax + rcx * 8]            ; COLUMN*
    lea r15, [rdx + WORKER.scratch]
    call timer_elapsed_us
    mov [LOCAL(0)], rax
    xor r12, r12                        ; ids buffer (allocated on demand)
    ; does this column touch the structure square?
    xor r14d, r14d
    cmp dword [rel g_struct_enabled], 0
    je .no_struct
    mov eax, [rbx + COLUMN.cx]
    shl eax, 5
    cmp eax, STRUCT_RADIUS
    jge .no_struct
    add eax, 32
    cmp eax, -STRUCT_RADIUS
    jle .no_struct
    mov eax, [rbx + COLUMN.cz]
    shl eax, 5
    cmp eax, STRUCT_RADIUS
    jge .no_struct
    add eax, 32
    cmp eax, -STRUCT_RADIUS
    jle .no_struct
    mov r14d, 1
.no_struct:
    xor esi, esi                        ; sy
.section:
    mov edi, esi
    shl edi, 5
    add edi, WORLD_MIN_Y                ; y0
    ; structures in this section's height range?
    xor r13d, r13d
    test r14d, r14d
    jz .layers
    cmp edi, STRUCT_TOP_Y
    jge .layers
    lea eax, [edi + 32]
    cmp eax, STRUCT_BASE_Y
    jle .layers
    mov r13d, 1
.layers:
    mov ecx, edi
    call layer_index
    mov [LOCAL(8)], eax
    lea ecx, [edi + 31]
    call layer_index
    test r13d, r13d
    jnz .detailed
    cmp eax, [LOCAL(8)]
    jne .detailed
    ; uniform section (or air)
    call layer_block
    mov ecx, eax
    mov edx, [rbx + COLUMN.cx]
    mov r8d, esi
    mov r9d, [rbx + COLUMN.cz]
    call section_make_uniform
    jmp .store
.detailed:
    test r12, r12
    jnz .have_buf
    INVOKE arena_alloc, r15, SECTION_VOLUME * 2, 64
    mov r12, rax
    test r12, r12
    jz .next
.have_buf:
    ; fill layer by layer: one id per y row of 1024
    xor ecx, ecx                        ; local y
.fill_y:
    mov [LOCAL(8)], rcx
    add ecx, edi
    call layer_index
    call layer_block
    mov rcx, [LOCAL(8)]
    mov rdx, rcx
    shl rdx, 11                         ; * 1024 entries * 2 bytes
    push rdi
    lea rdi, [r12 + rdx]
    mov rdx, rcx
    mov ecx, 1024
    rep stosw
    mov rcx, rdx
    pop rdi
    inc ecx
    cmp ecx, 32
    jb .fill_y
    test r13d, r13d
    jz .build
    INVOKE apply_structures, r12, [rbx + COLUMN.cx], [rbx + COLUMN.cz], rdi
.build:
    mov edx, [rbx + COLUMN.cx]
    mov r8d, esi
    mov r9d, [rbx + COLUMN.cz]
    INVOKE section_build, r12, rdx, r8, r9
.store:
    mov [rbx + COLUMN.sections + rsi * 8], rax
.next:
    inc esi
    cmp esi, SECTIONS_PER_COLUMN
    jb .section
    call timer_elapsed_us
    sub rax, [LOCAL(0)]
    lock add [rel g_world_gen_total_us], rax
    mov rdx, rax
    lea rcx, [rel g_world_gen_max_us]
    call atomic_max
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mesh_section_job — job: mesh one stored section and append its quads to
; the shared staging arena.
;   in:  rcx = index into g_mesh_list, rdx = WORKER*
; -----------------------------------------------------------------------------
%define MJ_NB   0                       ; 6 neighbour pointers
%define MJ_T0   48
PROC mesh_section_job, 64, rbx, rsi, rdi, r12, r13, r14, r15
    mov rax, [rel g_mesh_list]
    mov rbx, [rax + rcx * 8]            ; SECT*
    lea r15, [rdx + WORKER.scratch]
    call timer_elapsed_us
    mov [LOCAL(MJ_T0)], rax
    mov r12d, [rbx + SECT.cx]
    mov r13d, [rbx + SECT.sy]
    mov r14d, [rbx + SECT.cz]
    ; neighbours: -X +X -Y +Y -Z +Z
    lea ecx, [r12d - 1]
    INVOKE world_section_at, rcx, r13, r14
    mov [LOCAL(MJ_NB + 0)], rax
    lea ecx, [r12d + 1]
    INVOKE world_section_at, rcx, r13, r14
    mov [LOCAL(MJ_NB + 8)], rax
    mov rax, NEIGHBOR_SOLID             ; below the world: solid
    test r13d, r13d
    jz .below_done
    lea edx, [r13d - 1]
    INVOKE world_section_at, r12, rdx, r14
.below_done:
    mov [LOCAL(MJ_NB + 16)], rax
    lea edx, [r13d + 1]
    INVOKE world_section_at, r12, rdx, r14
    mov [LOCAL(MJ_NB + 24)], rax
    lea r8d, [r14d - 1]
    INVOKE world_section_at, r12, r13, r8
    mov [LOCAL(MJ_NB + 32)], rax
    lea r8d, [r14d + 1]
    INVOKE world_section_at, r12, r13, r8
    mov [LOCAL(MJ_NB + 40)], rax

    INVOKE arena_alloc, r15, MESH_MAX_QUADS * 8, 64
    test rax, rax
    jz .done
    mov rsi, rax                        ; quads
    lea rdx, [LOCAL(MJ_NB)]
    INVOKE mesh_section, rbx, rdx, rsi, r15
    mov [rbx + SECT.quad_count], eax
    mov rdi, rax                        ; count
    test rdi, rdi
    jz .timing
    lock add [rel g_world_quads], rdi
    lea rdx, [rdi * 8]
    lea rcx, [rel g_mesh_staging]
    call arena_alloc_shared
    test rax, rax
    jz .lost
    mov rdx, rax
    sub rdx, [rel g_mesh_staging + ARENA.base]
    shr rdx, 3
    mov [rbx + SECT.quad_first], edx
    ; copy the quads
    mov rcx, rdi
    mov r8, rdi
    mov rdi, rax
    mov rax, rsi
    mov rsi, rax
    mov rcx, r8
    rep movsq
    jmp .timing
.lost:
    mov dword [rbx + SECT.quad_count], 0
.timing:
    call timer_elapsed_us
    sub rax, [LOCAL(MJ_T0)]
    mov [rbx + SECT.mesh_us], eax
    lock add [rel g_world_mesh_total_us], rax
    mov rdx, rax
    lea rcx, [rel g_world_mesh_max_us]
    call atomic_max
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_timing — "<a><n1><b><n2><c><n3><d><n4><e>" helper for the summary.
;   in:  rcx = string table (5 qword ptrs), rdx = values (4 qwords)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_timing, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    xor edi, edi
.part:
    mov rcx, [rbx + rdi * 8]
    call log_append_str
    cmp edi, 4
    jae .end
    mov rcx, [rsi + rdi * 8]
    call log_append_dec
    inc edi
    jmp .part
.end:
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; world_init — load the test-world description, generate and mesh it.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define WI_STR      0                   ; 5 string pointers
%define WI_VAL      40                  ; 4 values
%define WI_T0       72
PROC world_init, 80, rbx, rsi, rdi, r12, r13
    call blocks_init
    ; ---- config -------------------------------------------------------------
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
    jnz .cfg_ok
    LOG_ERROR "could not read data/world/flat_test.cfg"
    xor eax, eax
    RETURN
.cfg_ok:
    lea rdx, [rel world_pair]
    lea r9, [rel str_cfg_label]
    INVOKE cfg_parse, rax, rdx, 0, r9
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [rel g_cfg_mark]
    cmp dword [rel g_layer_count], 0
    jne .layers_ok
    LOG_ERROR "flat_test.cfg defines no layers"
    xor eax, eax
    RETURN
.layers_ok:
    call sections_init
    test eax, eax
    jz .fail
    lea rcx, [rel g_mesh_staging]
    lea r8, [rel name_staging]
    INVOKE arena_init, rcx, STAGING_RESERVE, r8
    test eax, eax
    jz .fail

    ; ---- columns + hash ---------------------------------------------------------
    mov eax, [rel g_world_radius]
    lea ebx, [eax * 2]
    imul ebx, ebx                       ; column count
    mov [rel g_world_columns_n], rbx
    lea rcx, [rel g_arena_perm]
    lea rdx, [rbx * 8]
    INVOKE arena_alloc, rcx, rdx, 64
    test rax, rax
    jz .fail
    mov [rel g_columns], rax
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, HASH_SIZE * 16, 64
    test rax, rax
    jz .fail
    mov [rel g_hash], rax
    mov rdi, rax
    xor eax, eax
    mov ecx, HASH_SIZE * 2
    rep stosq
    xor r12d, r12d                      ; column index
    mov esi, [rel g_world_radius]
    neg esi                             ; cz
.cz_loop:
    mov edi, [rel g_world_radius]
    neg edi                             ; cx
.cx_loop:
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, COLUMN_size, 16
    test rax, rax
    jz .fail
    mov r13, rax
    mov [r13 + COLUMN.cx], edi
    mov [r13 + COLUMN.cz], esi
    push rdi
    lea rdi, [r13 + COLUMN.sections]
    xor eax, eax
    mov ecx, SECTIONS_PER_COLUMN
    rep stosq
    pop rdi
    mov rax, [rel g_columns]
    mov [rax + r12 * 8], r13
    ; insert into the hash table
    mov ecx, edi
    mov edx, esi
    call hash_slot
    mov r8, [rel g_hash]
.probe:
    mov rcx, rdx
    shl rcx, 4
    cmp qword [r8 + rcx + 8], 0
    je .insert
    inc rdx
    and rdx, HASH_SIZE - 1
    jmp .probe
.insert:
    mov [r8 + rcx], rax
    mov [r8 + rcx + 8], r13
    inc r12d
    inc edi
    cmp edi, [rel g_world_radius]
    jl .cx_loop
    inc esi
    cmp esi, [rel g_world_radius]
    jl .cz_loop

    ; ---- generate (parallel) -------------------------------------------------------
    call timer_elapsed_us
    mov [LOCAL(WI_T0)], rax
    mov qword [rel g_counter], 0
    lea rcx, [rel gen_column_job]
    lea r8, [rel g_counter]
    INVOKE job_dispatch, rcx, rbx, r8
    lea rcx, [rel g_counter]
    call job_wait
    call timer_elapsed_us
    sub rax, [LOCAL(WI_T0)]
    mov [rel g_world_gen_wall_us], rax

    ; ---- list stored sections -------------------------------------------------------
    lea rcx, [rel g_arena_perm]
    imul rdx, rbx, SECTIONS_PER_COLUMN * 8
    INVOKE arena_alloc, rcx, rdx, 64
    test rax, rax
    jz .fail
    mov [rel g_mesh_list], rax
    mov rdi, rax
    xor r12d, r12d                      ; count
    xor esi, esi                        ; column
.list_col:
    mov rax, [rel g_columns]
    mov r13, [rax + rsi * 8]
    xor ecx, ecx
.list_sec:
    mov rax, [r13 + COLUMN.sections + rcx * 8]
    test rax, rax
    jz .list_skip
    mov [rdi + r12 * 8], rax
    inc r12d
.list_skip:
    inc ecx
    cmp ecx, SECTIONS_PER_COLUMN
    jb .list_sec
    inc esi
    cmp rsi, rbx
    jb .list_col
    mov [rel g_world_mesh_list_count], r12

    ; ---- mesh (parallel) ----------------------------------------------------------------
    call timer_elapsed_us
    mov [LOCAL(WI_T0)], rax
    mov qword [rel g_counter], 0
    lea rcx, [rel mesh_section_job]
    lea r8, [rel g_counter]
    INVOKE job_dispatch, rcx, r12, r8
    lea rcx, [rel g_counter]
    call job_wait
    call timer_elapsed_us
    sub rax, [LOCAL(WI_T0)]
    mov [rel g_world_mesh_wall_us], rax

    ; ---- draw list ------------------------------------------------------------------------
    lea rcx, [rel g_arena_perm]
    lea rdx, [r12 * 8 + 8]
    INVOKE arena_alloc, rcx, rdx, 64
    test rax, rax
    jz .fail
    mov [rel g_draw_list], rax
    mov rdi, rax
    mov rsi, [rel g_mesh_list]
    xor ecx, ecx
    xor edx, edx
.draw_scan:
    cmp rcx, r12
    jae .draw_done
    mov rax, [rsi + rcx * 8]
    cmp dword [rax + SECT.quad_count], 0
    je .draw_skip
    mov [rdi + rdx * 8], rax
    inc rdx
.draw_skip:
    inc rcx
    jmp .draw_scan
.draw_done:
    mov [rel g_draw_count], rdx

    ; ---- summary ----------------------------------------------------------------------------
    lea rax, [rel str_gen]
    mov [LOCAL(WI_STR)], rax
    lea rax, [rel str_cols]
    mov [LOCAL(WI_STR + 8)], rax
    lea rax, [rel str_us_wall]
    mov [LOCAL(WI_STR + 16)], rax
    lea rax, [rel str_us_job]
    mov [LOCAL(WI_STR + 24)], rax
    lea rax, [rel str_us_close]
    mov [LOCAL(WI_STR + 32)], rax
    mov [LOCAL(WI_VAL)], rbx
    mov rax, [rel g_world_gen_wall_us]
    mov [LOCAL(WI_VAL + 8)], rax
    mov rax, [rel g_world_gen_total_us]
    xor edx, edx
    div rbx
    mov [LOCAL(WI_VAL + 16)], rax
    mov rax, [rel g_world_gen_max_us]
    mov [LOCAL(WI_VAL + 24)], rax
    lea rcx, [LOCAL(WI_STR)]
    lea rdx, [LOCAL(WI_VAL)]
    call log_timing

    lea rax, [rel str_mesh]
    mov [LOCAL(WI_STR)], rax
    lea rax, [rel str_sections]
    mov [LOCAL(WI_STR + 8)], rax
    lea rax, [rel str_us_sec]
    mov [LOCAL(WI_STR + 24)], rax
    mov [LOCAL(WI_VAL)], r12
    mov rax, [rel g_world_mesh_wall_us]
    mov [LOCAL(WI_VAL + 8)], rax
    mov rax, [rel g_world_mesh_total_us]
    xor edx, edx
    mov rcx, r12
    test rcx, rcx
    jnz .div_ok
    mov ecx, 1
.div_ok:
    div rcx
    mov [LOCAL(WI_VAL + 16)], rax
    mov rax, [rel g_world_mesh_max_us]
    mov [LOCAL(WI_VAL + 24)], rax
    lea rcx, [LOCAL(WI_STR)]
    lea rdx, [LOCAL(WI_VAL)]
    call log_timing

    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_quads]
    call log_append_str
    mov rcx, [rel g_world_quads]
    call log_append_dec
    lea rcx, [rel str_drawn]
    call log_append_str
    mov rcx, [rel g_draw_count]
    call log_append_dec
    lea rcx, [rel str_stored]
    call log_append_str
    mov rcx, [rel g_sections_live]
    call log_append_dec
    call log_end
    mov eax, 1
    RETURN
.fail:
    LOG_ERROR "world_init failed (out of memory?)"
    xor eax, eax
    RETURN
ENDPROC
