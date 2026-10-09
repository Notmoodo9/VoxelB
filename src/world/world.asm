; =============================================================================
; world.asm — world description, column map and column generation.
;
; The world is infinite: columns are created by the streamer
; (src/world/stream.asm) around the player and generated here by jobs, from
; data/world/flat_test.cfg (debug blocks, layers, debug structures).
;
; Public API (see include/world_api.inc):
;   world_init() -> eax 1/0             load config, pools, hash map
;   world_column_alloc(cx, cz) -> rax   new COLUMN (state NEW), not mapped
;   world_column_free(col)
;   world_column_insert(col) / world_column_remove(col)   (main thread)
;   world_column(cx, cz) -> rax COLUMN* or 0   (main thread)
;   world_section_at(cx, sy, cz) / world_block_at(wx, wy, wz)   (main thread)
;   gen_column_job(COLUMN*, WORKER*)     job: fills the 40 sections, then
;                                        publishes COL_GENERATED
;   g_world_gen_count / _total_us / _max_us   generation timing
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
global world_column_alloc, world_column_free, world_column_insert, world_column_remove
global gen_column_job, atomic_max, world_hash_selftest
global g_world_gen_count, g_world_gen_total_us, g_world_gen_max_us

extern str_ieq, str_parse_float, str_parse_u64
extern blocks_init, block_register, block_find
extern timer_elapsed_us

%define MAX_LAYERS          16
%define MAX_STRUCT_BLOCKS   8
%define HASH_BITS           14          ; 16384 slots (render distance <= 48)
%define HASH_SIZE           (1 << HASH_BITS)
%define STRUCT_BASE_Y       100
%define STRUCT_TOP_Y        220
%define STRUCT_RADIUS       128         ; blocks around the origin
%define PILLAR_SPACING      37
%define PILLAR_TOP_Y        210
%define MAX_COLUMNS         65536

section .rdata
str_cfg_path:   db "data/world/flat_test.cfg", 0
str_cfg_label:  db "flat_test.cfg", 0
k_block:        db "block", 0
k_layer:        db "layer", 0
k_structures:   db "test_structures", 0
k_struct_blk:   db "structure_blocks", 0
k_pillar:       db "pillar_block", 0
str_unknown:    db "unknown setting: ", 0
str_bad_block:  db "unknown block: ", 0
str_bad_value:  db "bad value for: ", 0
name_columns:   db "columns", 0

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
g_hash:             resq 1              ; HASH_SIZE x {key, COLUMN*}
g_cfg_mark:         resq 1
alignb 64
g_world_gen_count:      resq 1
g_world_gen_total_us:   resq 1
g_world_gen_max_us:     resq 1
alignb 64
g_column_pool:      resb POOL_size
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
; world_column_insert — add a column to the map (main thread).
;   in:  rcx = COLUMN*
;   clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
world_column_insert:
    mov r9, rcx
    mov ecx, [r9 + COLUMN.cx]
    mov edx, [r9 + COLUMN.cz]
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
    mov [r8 + rcx + 8], r9
    ret

; -----------------------------------------------------------------------------
; world_column_remove — remove a column from the map (main thread).
; Linear probing with backward-shift deletion: following entries of the
; same probe chain are moved up, so lookups never need tombstones.
;   in:  rcx = COLUMN*
;   clobbers: rax, rcx, rdx, r8, r9, r10, r11
; -----------------------------------------------------------------------------
world_column_remove:
    mov r9, rcx
    mov ecx, [r9 + COLUMN.cx]
    mov edx, [r9 + COLUMN.cz]
    call hash_slot
    mov r8, [rel g_hash]
.find:
    mov rcx, rdx
    shl rcx, 4
    cmp qword [r8 + rcx + 8], 0
    je .done                            ; not present
    cmp [r8 + rcx + 8], r9
    je .found
    inc rdx
    and rdx, HASH_SIZE - 1
    jmp .find
.found:
    ; rdx = hole index
    mov r10, rdx                        ; j = scan index
.shift:
    inc r10
    and r10, HASH_SIZE - 1
    mov rcx, r10
    shl rcx, 4
    cmp qword [r8 + rcx + 8], 0
    je .clear_hole                      ; end of the cluster
    ; home slot of the entry at j
    mov rax, [r8 + rcx]
    mov r11, 0x9E3779B97F4A7C15
    imul r11, rax
    shr r11, 64 - HASH_BITS             ; k = home
    ; move it into the hole unless its home lies cyclically in (hole, j]
    ; i.e. keep if: hole < k <= j (no wrap) or wrapped equivalents
    mov rax, r10
    sub rax, r11
    and rax, HASH_SIZE - 1              ; distance home -> j
    mov rcx, r10
    sub rcx, rdx
    and rcx, HASH_SIZE - 1              ; distance hole -> j
    cmp rax, rcx
    jb .shift                           ; home is after the hole: stays
    ; move entry j -> hole
    mov rcx, r10
    shl rcx, 4
    mov rax, [r8 + rcx]
    mov r11, [r8 + rcx + 8]
    mov rcx, rdx
    shl rcx, 4
    mov [r8 + rcx], rax
    mov [r8 + rcx + 8], r11
    mov rdx, r10                        ; new hole
    jmp .shift
.clear_hole:
    mov rcx, rdx
    shl rcx, 4
    mov qword [r8 + rcx], 0
    mov qword [r8 + rcx + 8], 0
.done:
    ret

; -----------------------------------------------------------------------------
; world_column_alloc — new zeroed column (state NEW), not yet in the map.
;   in:  ecx = cx, edx = cz
;   out: rax = COLUMN*, or 0 if the column pool is exhausted (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_column_alloc, 0, rbx, rsi, rdi
    mov ebx, ecx
    mov esi, edx
    lea rcx, [rel g_column_pool]
    call pool_alloc
    test rax, rax
    jz .done
    mov rdi, rax
    mov rdx, rax
    xor eax, eax
    mov ecx, COLUMN_size / 8
    rep stosq
    mov rax, rdx
    mov [rax + COLUMN.cx], ebx
    mov [rax + COLUMN.cz], esi
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; world_column_free — free a column's sections and the column itself (it must
; not be in the map, nor in use by any job).
;   in:  rcx = COLUMN*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_column_free, 0, rbx, rsi
    mov rbx, rcx
    xor esi, esi
.sections:
    mov rcx, [rbx + COLUMN.sections + rsi * 8]
    call section_free
    inc esi
    cmp esi, SECTIONS_PER_COLUMN
    jb .sections
    lea rcx, [rel g_column_pool]
    mov rdx, rbx
    call pool_free
    RETURN
ENDPROC

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
;   in:  rcx = COLUMN*, rdx = WORKER*
;   Publishes COL_GENERATED after every section pointer is stored.
; -----------------------------------------------------------------------------
PROC gen_column_job, 16, rbx, rsi, rdi, r12, r13, r14, r15
    mov rbx, rcx                        ; COLUMN*
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
    lock inc qword [rel g_world_gen_count]
    mov rdx, rax
    lea rcx, [rel g_world_gen_max_us]
    call atomic_max
    ; publish: on x86 the section stores above are visible before this one
    mov dword [rbx + COLUMN.state], COL_GENERATED
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; world_hash_selftest — insert 3000 columns in a 60x50 block (dense probe
; clusters), remove every third one, check every lookup, remove the rest
; and check the table is empty. Uses a temporary table (g_hash is swapped).
;   out: eax = 1 pass / 0 fail
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define HT_N    3000
PROC world_hash_selftest, 16, rbx, rsi, rdi, r12, r13
    mov rax, [rel g_hash]
    mov [LOCAL(0)], rax
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(8)], rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, HASH_SIZE * 16, 64
    test rax, rax
    jz .fail
    mov [rel g_hash], rax
    mov rdi, rax
    xor eax, eax
    mov ecx, HASH_SIZE * 2
    rep stosq
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, HT_N * COLUMN_size, 64
    test rax, rax
    jz .fail
    mov r12, rax                        ; fake columns
    xor esi, esi
.insert:
    imul rbx, rsi, COLUMN_size
    add rbx, r12
    mov eax, esi
    xor edx, edx
    mov ecx, 60
    div ecx
    sub eax, 25
    sub edx, 30
    mov [rbx + COLUMN.cx], edx
    mov [rbx + COLUMN.cz], eax
    mov rcx, rbx
    call world_column_insert
    inc esi
    cmp esi, HT_N
    jb .insert
    ; remove every third
    xor esi, esi
.remove3:
    imul rcx, rsi, COLUMN_size
    add rcx, r12
    call world_column_remove
    add esi, 3
    cmp esi, HT_N
    jb .remove3
    ; check all lookups
    xor esi, esi
.check:
    imul rbx, rsi, COLUMN_size
    add rbx, r12
    mov ecx, [rbx + COLUMN.cx]
    mov edx, [rbx + COLUMN.cz]
    call world_column
    mov rdi, rax                        ; lookup result
    mov eax, esi
    xor edx, edx
    mov ecx, 3
    div ecx
    test edx, edx
    jz .must_be_gone
    cmp rdi, rbx
    jne .fail
    jmp .check_next
.must_be_gone:
    test rdi, rdi
    jnz .fail
.check_next:
    inc esi
    cmp esi, HT_N
    jb .check
    ; remove the rest; the table must end up empty
    xor esi, esi
.remove_rest:
    mov eax, esi
    xor edx, edx
    mov ecx, 3
    div ecx
    test edx, edx
    jz .skip_rest
    imul rcx, rsi, COLUMN_size
    add rcx, r12
    call world_column_remove
.skip_rest:
    inc esi
    cmp esi, HT_N
    jb .remove_rest
    mov rax, [rel g_hash]
    xor ecx, ecx
.empty:
    cmp qword [rax + rcx * 8], 0
    jne .fail
    inc ecx
    cmp ecx, HASH_SIZE * 2
    jb .empty
    mov rax, [LOCAL(0)]
    mov [rel g_hash], rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(8)]
    mov eax, 1
    RETURN
.fail:
    mov rax, [LOCAL(0)]
    mov [rel g_hash], rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(8)]
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; world_init — load the world description and set up pools and the map.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_init, 0, rbx, rdi
    call blocks_init
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
    lea rcx, [rel g_column_pool]
    lea rax, [rel name_columns]
    mov [rsp + 32], rax
    INVOKE pool_init, rcx, COLUMN_size, MAX_COLUMNS, 1024
    test eax, eax
    jz .fail
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, HASH_SIZE * 16, 64
    test rax, rax
    jz .fail
    mov [rel g_hash], rax
    mov rdi, rax
    xor eax, eax
    mov ecx, HASH_SIZE * 2
    rep stosq
    LOG_INFO "world: ready (infinite flat test world)"
    mov eax, 1
    RETURN
.fail:
    LOG_ERROR "world_init failed (out of memory?)"
    xor eax, eax
    RETURN
ENDPROC
