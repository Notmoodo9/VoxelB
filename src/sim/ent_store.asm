; =============================================================================
; ent_store.asm — where the animals live when nobody looks: entity regions
; in memory and on disk, and the herds placed in new land (milestone 19,
; design/mobs/passive_animals.md, DECISIONS D98).
;
; The world is cut into entity regions of 32 x 32 chunk columns (1024 x
; 1024 blocks), like the block region files. A region in memory holds its
; animals (entities.asm's table) and a bit per column: herds placed there
; already. Regions load when something needs them (an animal walks in, the
; land nearby is checked for herds) and are saved and dropped when the
; player is far away; every region in memory is saved with the world.
; File: <world>\overworld\entities\e.<rx>.<rz>.vxe
;   "VXEN", u32 version (1), u32 animals, u32 0, 128 bytes of column bits,
;   then 64 bytes per animal: f64 x, y, z, f32 yaw, u16 health, u16 flags
;   (1 baby, 2 shorn: part 3), u32 age (ticks), 24 bytes "mob:variant" (zero-padded), u32
;   herd id (0: none; milestone 19 part 2, in the field that was 0).
; A rule's `mix` lines give some of a herd other looks of the same animal
; (part 3: a few black sheep in a white flock).
; Unknown variants (a removed data file) are dropped with a warning.
;
; Herds: every column within POP_RADIUS of the player, once generated, is
; checked once: its biome (at the centre) picks a spawn rule by the rules'
; chances (data/mobs: % of the biome's columns with a herd), seeded by the
; world seed and the column (the same world gets the same herds). Animals
; stand on the first solid, opaque ground from the top (not on leaves, not
; in water). A slow trickle refills: every 30 seconds a column a little
; away from the player with no animals around gets a fresh roll.
;
; Public API (include/entity.inc):
;   store_reset()                     a new world: no regions
;   store_open()                      after save_open: the entities folder
;   store_update()                    once per tick (after ents_tick)
;   store_save_all()                  with the world (save_all)
;   store_region_of(xmm0 = x, xmm1 = z) -> eax region slot, -1 (doubles)
;   g_eregs, g_store_pop_us, g_store_pop_count   (overlay)
; =============================================================================
%define ENT_STORE_IMPL
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "win32.inc"
%include "world.inc"
%include "block.inc"
%include "biome.inc"
%include "physics.inc"
%include "mobs.inc"
%include "packet.inc"
%include "entity.inc"

global store_reset, store_open, store_update, store_save_all, store_region_of
global g_eregs, g_store_pop_us, g_store_pop_count

extern world_column, g_save_enabled, g_dir, g_world_seed, g_pl_pos
extern str_copy, str_append_sdec, str_len, str_ieq, timer_elapsed_us

IMPORT CreateFileA, WriteFile, CloseHandle, CreateDirectoryA

%define UNLOAD_DIST     768             ; blocks from the player to a region's edge
%define TRICKLE_TICKS   600             ; 30 seconds
%define FILE_VERSION    1
%define HEADER_BYTES    144             ; 16 + 128
%define RECORD_BYTES    64
%define KEY_BYTES       24

section .rdata
str_overworld:  db "overworld\", 0
str_entities:   db "entities\", 0
str_e:          db "e.", 0
str_dot:        db ".", 0
str_vxe:        db ".vxe", 0
str_colon:      db ":", 0
str_unknown:    db "entities: an unknown animal in a saved region was dropped: ", 0
str_bad_file:   db "entities: a damaged region file was ignored: ", 0
str_herd:       db "entities: ", 0
str_herd2:      db " x ", 0
str_herd3:      db " at column ", 0
str_herd4:      db ", ", 0
str_minus:      db "-", 0
align 8
c_half:         dq 0.5
c_region:       dq 1024.0
c_unload2:      dq 589824.0             ; UNLOAD_DIST^2
c_u32:          dq 0.00000000023283064365386963 ; 2^-32
c_hundred:      dq 100.0

section .bss
alignb 16
g_eregs:        resb MAX_EREGIONS * EREG_size
g_pmap:         resb BMAP_size
g_pos:          resq 3
g_key:          resb 32
alignb 8
g_store_pop_us: resq 1                  ; the last herd placement
g_store_pop_count: resq 1               ; columns checked for herds
g_edir:         resb PATH_CAP           ; ...\overworld\entities\ (absolute)
g_path:         resb PATH_CAP
alignb 4
g_ticks:        resd 1
g_rng:          resd 1                  ; this column's random numbers
g_trickle_rng:  resd 1
g_warned:       resd 1

section .text

; rng — eax = the next random u32 of g_rng (xorshift)   clobbers: rax, rcx
rng:
    mov eax, [rel g_rng]
    mov ecx, eax
    shl ecx, 13
    xor eax, ecx
    mov ecx, eax
    shr ecx, 17
    xor eax, ecx
    mov ecx, eax
    shl ecx, 5
    xor eax, ecx
    mov [rel g_rng], eax
    ret

; rng_below — eax = 0 .. ecx - 1   clobbers: rax, rcx, rdx
rng_below:
    mov edx, ecx
    push rdx
    call rng
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

; seed_column — g_rng from the world seed and a column (ecx = cx, edx = cz)
;   clobbers: rax, rcx, rdx
seed_column:
    imul eax, ecx, 0x27D4EB2F
    imul edx, edx, 0x165667B1
    xor eax, edx
    xor eax, [rel g_world_seed]
    xor eax, 0x4D4F4253                 ; "MOBS"
    mov edx, eax
    shr edx, 15
    xor eax, edx
    imul eax, eax, 0x2C1B3C6D
    mov edx, eax
    shr edx, 12
    xor eax, edx
    test eax, eax
    jnz .ok
    mov eax, 0x9E3779B9
.ok:
    mov [rel g_rng], eax
    ret

; store_reset — no regions (a new world; nothing is saved)
PROC store_reset, 0, rdi
    lea rdi, [rel g_eregs]
    xor eax, eax
    mov ecx, MAX_EREGIONS * EREG_size / 8
    rep stosq
    mov dword [rel g_ticks], 0
    mov dword [rel g_warned], 0
    mov qword [rel g_store_pop_count], 0
    mov eax, [rel g_world_seed]
    or eax, 1
    mov [rel g_trickle_rng], eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; store_open — the world's entities folder (after save_open).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC store_open, 0
    mov byte [rel g_edir], 0
    cmp dword [rel g_save_enabled], 0
    je .done
    lea rcx, [rel g_edir]
    lea rdx, [rel g_dir]
    call str_copy
    lea rdx, [rel str_overworld]
    mov rcx, rax
    call str_copy
    lea rdx, [rel str_entities]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_edir]
    API CreateDirectoryA, rcx, 0
.done:
    RETURN
ENDPROC

; region_path — g_path = <entities dir>e.<rx>.<rz>.vxe   (ecx = rx, edx = rz)
PROC region_path, 0, rbx, rsi
    mov ebx, ecx
    mov esi, edx
    lea rcx, [rel g_path]
    lea rdx, [rel g_edir]
    call str_copy
    lea rdx, [rel str_e]
    mov rcx, rax
    call str_copy
    movsxd rdx, ebx
    INVOKE str_append_sdec, rax, rdx, 0
    lea rdx, [rel str_dot]
    mov rcx, rax
    call str_copy
    movsxd rdx, esi
    INVOKE str_append_sdec, rax, rdx, 0
    lea rdx, [rel str_vxe]
    mov rcx, rax
    call str_copy
    RETURN
ENDPROC

; variant_key — g_key = "mob:variant" of variant ecx (at most 23 characters)
;   clobbers: volatile registers
PROC variant_key, 0, rbx, rsi, rdi
    imul eax, ecx, VARIANT_size
    lea rbx, [rel g_variants]
    add rbx, rax
    lea rdi, [rel g_key]
    xor eax, eax
    mov ecx, 4
.clear:
    mov [rdi + rcx * 8 - 8], rax
    loop .clear
    mov eax, [rbx + VARIANT.mob]
    imul eax, eax, MOB_size
    lea rcx, [rel g_mobs]
    mov rsi, [rcx + rax + MOB.name]
    xor edx, edx
    call .append
    mov byte [rdi + rdx], ':'
    inc edx
    mov rsi, [rbx + VARIANT.name]
    call .append
    RETURN
.append:                                ; rsi string -> g_key + edx (keeps 23)
    mov al, [rsi]
    test al, al
    jz .end
    cmp edx, KEY_BYTES - 1
    jae .end
    mov [rdi + rdx], al
    inc rsi
    inc edx
    jmp .append
.end:
    ret
ENDPROC

; -----------------------------------------------------------------------------
; save_region — write region slot ecx to its file (if saving is on).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define SR_MARK     0
%define SR_BUF      8
%define SR_N        16
%define SR_SLOT     20
%define SR_WRITTEN  24
PROC save_region, 32, rbx, rsi, rdi, r12, r13
    mov [LOCAL(SR_SLOT)], ecx
    cmp dword [rel g_save_enabled], 0
    je .done
    cmp byte [rel g_edir], 0
    je .done
    imul eax, ecx, EREG_size
    lea r12, [rel g_eregs]
    add r12, rax
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(SR_MARK)], rax
    mov eax, [r12 + EREG.count]
    imul eax, eax, RECORD_BYTES
    add eax, HEADER_BYTES
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, rax, 16
    test rax, rax
    jz .release
    mov r13, rax
    mov [LOCAL(SR_BUF)], rax
    mov dword [r13], 'VXEN'
    mov dword [r13 + 4], FILE_VERSION
    mov dword [r13 + 12], 0
    xor ecx, ecx
.pop:
    mov rax, [r12 + EREG.pop + rcx]
    mov [r13 + 16 + rcx], rax
    add ecx, 8
    cmp ecx, 128
    jb .pop
    ; the animals of this region
    lea rdi, [r13 + HEADER_BYTES]
    mov dword [LOCAL(SR_N)], 0
    lea rbx, [rel g_ents]
    xor esi, esi
.ent:
    cmp esi, MAX_ENTITIES
    jae .write
    test dword [rbx + EntT.flags], EF_ACTIVE
    jz .next
    test dword [rbx + EntT.flags], EF_DYING
    jnz .next
    movzx eax, word [rbx + EntT.region]
    cmp eax, [LOCAL(SR_SLOT)]
    jne .next
    mov eax, [LOCAL(SR_N)]
    cmp eax, [r12 + EREG.count]
    jae .write                          ; (never more than counted)
    mov rax, [rbx + EntT.pos]
    mov [rdi], rax
    mov rax, [rbx + EntT.pos + 8]
    mov [rdi + 8], rax
    mov rax, [rbx + EntT.pos + 16]
    mov [rdi + 16], rax
    mov eax, [rbx + EntT.yaw]
    mov [rdi + 24], eax
    mov ax, [rbx + EntT.health]
    mov [rdi + 28], ax
    xor eax, eax
    test dword [rbx + EntT.flags], EF_BABY
    jz .flags
    mov eax, 1
.flags:
    test dword [rbx + EntT.flags], EF_SHEARED
    jz .flags2
    or eax, 2
.flags2:
    mov [rdi + 30], ax
    mov eax, [rbx + EntT.age]
    mov [rdi + 32], eax
    movzx ecx, word [rbx + EntT.variant]
    call variant_key                    ; (keeps rdi)
    lea rax, [rel g_key]
    mov rcx, [rax]
    mov [rdi + 36], rcx
    mov rcx, [rax + 8]
    mov [rdi + 44], rcx
    mov rcx, [rax + 16]
    mov [rdi + 52], rcx
    mov eax, [rbx + EntT.herd]
    mov [rdi + 60], eax
    add rdi, RECORD_BYTES
    inc dword [LOCAL(SR_N)]
.next:
    add rbx, EntT_size
    inc esi
    jmp .ent
.write:
    mov eax, [LOCAL(SR_N)]
    mov [r13 + 8], eax
    mov ecx, [r12 + EREG.rx]
    mov edx, [r12 + EREG.rz]
    call region_path
    lea rcx, [rel g_path]
    mov qword [rsp + 48], 0
    mov dword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov qword [rsp + 32], CREATE_ALWAYS
    mov edx, GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    call [rel __imp_CreateFileA]
    cmp rax, -1
    je .release
    mov rbx, rax
    mov r8d, [LOCAL(SR_N)]
    imul r8d, r8d, RECORD_BYTES
    add r8d, HEADER_BYTES
    lea r9, [LOCAL(SR_WRITTEN)]
    mov qword [rsp + 32], 0
    API WriteFile, rbx, r13, r8, r9
    API CloseHandle, rbx
.release:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(SR_MARK)]
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; load_region — region slot ebx (rx, rz set, used) gets its file's animals.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define LR_MARK     0
%define LR_N        8
%define LR_I        12
%define LR_END      16
PROC load_region, 32, rsi, rdi, r12, r13
    cmp dword [rel g_save_enabled], 0
    je .done
    cmp byte [rel g_edir], 0
    je .done
    imul eax, ebx, EREG_size
    lea r12, [rel g_eregs]
    add r12, rax
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(LR_MARK)], rax
    mov ecx, [r12 + EREG.rx]
    mov edx, [r12 + EREG.rz]
    call region_path
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .release                         ; (no file: a new region)
    mov r13, rax
    cmp rdx, HEADER_BYTES
    jb .bad
    cmp dword [r13], 'VXEN'
    jne .bad
    cmp dword [r13 + 4], FILE_VERSION
    jne .bad
    mov eax, [r13 + 8]
    mov [LOCAL(LR_N)], eax
    imul rax, rax, RECORD_BYTES
    add rax, HEADER_BYTES
    cmp rdx, rax
    jb .bad
    xor ecx, ecx
.pop:
    mov rax, [r13 + 16 + rcx]
    mov [r12 + EREG.pop + rcx], rax
    add ecx, 8
    cmp ecx, 128
    jb .pop
    lea rsi, [r13 + HEADER_BYTES]
    mov dword [LOCAL(LR_I)], 0
.rec:
    mov eax, [LOCAL(LR_I)]
    cmp eax, [LOCAL(LR_N)]
    jae .release
    ; the variant by its key
    mov byte [rsi + 36 + KEY_BYTES - 1], 0
    xor edi, edi
.var:
    cmp edi, [rel g_variant_count]
    jae .unknown
    mov ecx, edi
    call variant_key
    lea rcx, [rel g_key]
    lea rdx, [rsi + 36]
    call str_ieq
    test eax, eax
    jnz .found
    inc edi
    jmp .var
.unknown:
    lea rdx, [rsi + 36]
    lea rcx, [rel str_unknown]
    call log_warn_str
    jmp .next
.found:
    mov ecx, edi
    xor edx, edx
    test word [rsi + 30], 1
    jz .adult
    mov edx, EF_BABY
.adult:
    mov r8, rsi
    call ent_new
    test eax, eax
    js .next
    imul rax, rax, EntT_size
    lea rcx, [rel g_ents]
    add rax, rcx
    mov ecx, [rsi + 24]
    mov [rax + EntT.yaw], ecx
    mov cx, [rsi + 28]
    test cx, cx
    jz .health
    mov [rax + EntT.health], cx
.health:
    mov ecx, [rsi + 32]
    mov [rax + EntT.age], ecx
    mov ecx, [rsi + 60]
    mov [rax + EntT.herd], ecx
    test word [rsi + 30], 2
    jz .next
    or dword [rax + EntT.flags], EF_SHEARED
.next:
    add rsi, RECORD_BYTES
    inc dword [LOCAL(LR_I)]
    jmp .rec
.bad:
    mov ecx, LOG_LEVEL_WARN
    call log_begin
    lea rcx, [rel str_bad_file]
    call log_append_str
    lea rcx, [rel g_path]
    call log_append_str
    call log_end
.release:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(LR_MARK)]
.done:
    RETURN
ENDPROC

; log_sdec — append a signed number (ecx) to the log line   clobbers: volatile
PROC log_sdec, 0, rbx
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

; log_warn_str — "<rcx><rdx>" at WARN   clobbers: volatile registers
PROC log_warn_str, 0, rbx, rsi
    mov rbx, rcx
    mov rsi, rdx
    mov ecx, LOG_LEVEL_WARN
    call log_begin
    mov rcx, rbx
    call log_append_str
    mov rcx, rsi
    call log_append_str
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; store_region_of — the region slot holding the point; loads the region (its
; file's animals) if it is not in memory yet.
;   in:  xmm0 = x, xmm1 = z (doubles)
;   out: eax = slot, -1 if no slot is free
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC store_region_of, 0, rbx, rsi, rdi
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, EREGION_SHIFT
    mov esi, eax
    roundsd xmm1, xmm1, 9
    cvttsd2si rax, xmm1
    sar rax, EREGION_SHIFT
    mov edi, eax
    lea rcx, [rel g_eregs]
    xor ebx, ebx
    mov edx, -1                         ; a free slot
.find:
    cmp ebx, MAX_EREGIONS
    jae .not_found
    cmp dword [rcx + EREG.used], 0
    je .free
    cmp [rcx + EREG.rx], esi
    jne .next
    cmp [rcx + EREG.rz], edi
    jne .next
    mov eax, ebx
    RETURN
.free:
    cmp edx, -1
    jne .next
    mov edx, ebx
.next:
    add rcx, EREG_size
    inc ebx
    jmp .find
.not_found:
    cmp edx, -1
    je .full
    mov ebx, edx
    imul eax, ebx, EREG_size
    lea rcx, [rel g_eregs]
    add rcx, rax
    mov rdx, rcx
    xor eax, eax
.clear:
    mov [rdx], rax
    add rdx, 8
    lea r8, [rcx + EREG_size]
    cmp rdx, r8
    jb .clear
    mov [rcx + EREG.rx], esi
    mov [rcx + EREG.rz], edi
    mov dword [rcx + EREG.used], 1
    call load_region
    mov eax, ebx
    RETURN
.full:
    cmp dword [rel g_warned], 0
    jne .quiet
    mov dword [rel g_warned], 1
    LOG_WARN "entities: too many regions in memory"
.quiet:
    mov eax, -1
    RETURN
ENDPROC

; unload_region — save region slot ecx, remove its animals, free it
PROC unload_region, 0, rbx, rsi, rdi
    mov edi, ecx
    call save_region
    lea rbx, [rel g_ents]
    xor esi, esi
.ent:
    cmp esi, MAX_ENTITIES
    jae .free
    test dword [rbx + EntT.flags], EF_ACTIVE
    jz .next
    movzx eax, word [rbx + EntT.region]
    cmp eax, edi
    jne .next
    mov ecx, esi
    call ent_remove
.next:
    add rbx, EntT_size
    inc esi
    jmp .ent
.free:
    imul eax, edi, EREG_size
    lea rcx, [rel g_eregs]
    mov dword [rcx + rax + EREG.used], 0
    RETURN
ENDPROC

; store_save_all — every region in memory to disk   clobbers: volatile
PROC store_save_all, 0, rbx
    xor ebx, ebx
.r:
    cmp ebx, MAX_EREGIONS
    jae .done
    imul eax, ebx, EREG_size
    lea rcx, [rel g_eregs]
    cmp dword [rcx + rax + EREG.used], 0
    je .next
    mov ecx, ebx
    call save_region
.next:
    inc ebx
    jmp .r
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; surface — the feet height of an animal standing at block column (ecx, edx):
; the first solid block from the top, if it is opaque ground (not leaves,
; not liquid) with room above.
;   out: eax = 1 found, edx = feet y; 0 none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define SU_X    0
%define SU_Z    4
%define SU_Y    8
%define SU_END  12
PROC surface, 16, rbx, rsi
    mov [LOCAL(SU_X)], ecx
    mov [LOCAL(SU_Z)], edx
    sar ecx, 5
    sar edx, 5
    call world_column
    test rax, rax
    jz .none
    cmp dword [rax + COLUMN.state], COL_GENERATED
    jb .none
    mov rbx, rax
    mov esi, SECTIONS_PER_COLUMN - 1
.section:
    test esi, esi
    js .none
    mov rax, [rbx + COLUMN.sections + rsi * 8]
    test rax, rax
    jz .next_section
    cmp byte [rax + SECT.bits], 0
    jne .scan
    cmp word [rax + SECT.uniform_id], BLOCK_AIR
    je .next_section
.scan:
    mov eax, esi
    shl eax, 5
    add eax, WORLD_MIN_Y
    mov [LOCAL(SU_END)], eax
    add eax, 31
    mov [LOCAL(SU_Y)], eax
.y:
    mov ecx, [LOCAL(SU_X)]
    mov edx, [LOCAL(SU_Y)]
    mov r8d, [LOCAL(SU_Z)]
    call phys_block
    cmp eax, -1
    je .none
    lea rcx, [rel g_block_move]
    test byte [rcx + rax], MOVE_WATER | MOVE_LAVA
    jnz .none                           ; (water or lava on top)
    lea rcx, [rel g_block_coll]
    cmp byte [rcx + rax], 0
    jne .ground
    dec dword [LOCAL(SU_Y)]
    mov eax, [LOCAL(SU_Y)]
    cmp eax, [LOCAL(SU_END)]
    jge .y
.next_section:
    dec esi
    jmp .section
.ground:
    lea rcx, [rel g_block_layer]
    cmp byte [rcx + rax], LAYER_OPAQUE
    jne .none                           ; (leaves: a tree top)
    mov edx, [LOCAL(SU_Y)]
    inc edx
    mov eax, 1
    RETURN
.none:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; populate — place a herd in column (ecx, edx) by its biome's spawn rules.
;   in:  r8d = 1: a new roll (the trickle; the column's bit is ignored)
;   out: eax = 1 checked (or nothing to do), 0 not ready (not generated)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define PO_CX       0
%define PO_CZ       4
%define PO_FORCE    8
%define PO_SLOT     12
%define PO_BIT      16
%define PO_BIOME    20
%define PO_SUM      24                  ; f64
%define PO_RULE     32
%define PO_N        36
%define PO_LX       40
%define PO_LZ       44
%define PO_I        48
%define PO_PLACED   52
%define PO_HERD     72
%define PO_START    56                  ; u64
PROC populate, 80, rbx, rsi, rdi, r12
    mov [LOCAL(PO_CX)], ecx
    mov [LOCAL(PO_CZ)], edx
    mov [LOCAL(PO_FORCE)], r8d
    call world_column
    test rax, rax
    jz .not_ready
    cmp dword [rax + COLUMN.state], COL_GENERATED
    jb .not_ready
    ; its region and bit
    mov eax, [LOCAL(PO_CX)]
    shl eax, 5
    add eax, 16
    cvtsi2sd xmm0, eax
    mov eax, [LOCAL(PO_CZ)]
    shl eax, 5
    add eax, 16
    cvtsi2sd xmm1, eax
    call store_region_of
    test eax, eax
    js .done
    mov [LOCAL(PO_SLOT)], eax
    mov ecx, [LOCAL(PO_CX)]
    and ecx, 31
    mov edx, [LOCAL(PO_CZ)]
    and edx, 31
    shl edx, 5
    or ecx, edx
    mov [LOCAL(PO_BIT)], ecx
    imul eax, eax, EREG_size
    lea r12, [rel g_eregs]
    add r12, rax
    cmp dword [LOCAL(PO_FORCE)], 0
    jne .roll
    bt [r12 + EREG.pop], ecx
    jc .done
    bts [r12 + EREG.pop], ecx
.roll:
    inc qword [rel g_store_pop_count]
    cmp dword [rel g_biome_count], 0
    je .done                            ; (the flat test world)
    call timer_elapsed_us
    mov [LOCAL(PO_START)], rax
    ; the biome at the column's centre
    lea rcx, [rel g_pmap]
    mov edx, [LOCAL(PO_CX)]
    mov r8d, [LOCAL(PO_CZ)]
    call bmap_build
    lea rcx, [rel g_pmap]
    mov edx, 16
    mov r8d, 16
    call bmap_col
    mov [LOCAL(PO_BIOME)], eax
    ; random numbers: the column's own (the trickle: fresh ones)
    mov ecx, [LOCAL(PO_CX)]
    mov edx, [LOCAL(PO_CZ)]
    call seed_column
    cmp dword [LOCAL(PO_FORCE)], 0
    je .sum
    mov eax, [rel g_trickle_rng]
    xor [rel g_rng], eax
    call rng
    mov [rel g_trickle_rng], eax
    cmp dword [rel g_rng], 0
    jne .sum
    mov dword [rel g_rng], 1
.sum:
    ; the rules of this biome: total chance (%)
    xorps xmm0, xmm0
    movsd [LOCAL(PO_SUM)], xmm0
    lea rsi, [rel g_spawns]
    xor edi, edi
    mov ecx, [LOCAL(PO_BIOME)]
.sum_rule:
    cmp edi, [rel g_spawn_count]
    jae .summed
    bt [rsi + SPAWN.biomes], ecx
    jnc .sum_next
    cvtss2sd xmm0, [rsi + SPAWN.chance]
    addsd xmm0, [LOCAL(PO_SUM)]
    movsd [LOCAL(PO_SUM)], xmm0
.sum_next:
    add rsi, SPAWN_size
    inc edi
    jmp .sum_rule
.summed:
    call rng
    mov eax, eax
    cvtsi2sd xmm0, rax
    mulsd xmm0, [rel c_u32]
    mulsd xmm0, [rel c_hundred]         ; 0 .. 100
    comisd xmm0, [LOCAL(PO_SUM)]
    jae .timed                          ; (no herd here)
    ; which rule: walk the chances
    lea rsi, [rel g_spawns]
    xor edi, edi
    mov ecx, [LOCAL(PO_BIOME)]
.pick:
    cmp edi, [rel g_spawn_count]
    jae .timed
    bt [rsi + SPAWN.biomes], ecx
    jnc .pick_next
    cvtss2sd xmm1, [rsi + SPAWN.chance]
    comisd xmm0, xmm1
    jb .picked
    subsd xmm0, xmm1
.pick_next:
    add rsi, SPAWN_size
    inc edi
    jmp .pick
.picked:
    mov rbx, rsi                        ; the rule
    mov ecx, [rbx + SPAWN.herd_max]
    sub ecx, [rbx + SPAWN.herd_min]
    inc ecx
    call rng_below
    add eax, [rbx + SPAWN.herd_min]
    mov [LOCAL(PO_N)], eax
    ; the herd's middle, away from the column's edges
    mov ecx, 20
    call rng_below
    add eax, 6
    mov [LOCAL(PO_LX)], eax
    mov ecx, 20
    call rng_below
    add eax, 6
    mov [LOCAL(PO_LZ)], eax
    mov dword [LOCAL(PO_I)], 0
    mov dword [LOCAL(PO_PLACED)], 0
    call rng                            ; the herd's id (never 0)
    or eax, 1
    mov [LOCAL(PO_HERD)], eax
.animal:
    mov eax, [LOCAL(PO_I)]
    cmp eax, [LOCAL(PO_N)]
    jb .more
    cmp dword [LOCAL(PO_PLACED)], 0
    jne .herd_placed
    jmp .timed
.more:
    inc dword [LOCAL(PO_I)]
    mov ecx, 7
    call rng_below
    lea esi, [rax - 3]
    add esi, [LOCAL(PO_LX)]
    mov eax, [LOCAL(PO_CX)]
    shl eax, 5
    add esi, eax                        ; x
    mov ecx, 7
    call rng_below
    lea edi, [rax - 3]
    add edi, [LOCAL(PO_LZ)]
    mov eax, [LOCAL(PO_CZ)]
    shl eax, 5
    add edi, eax                        ; z
    mov ecx, esi
    mov edx, edi
    call surface
    test eax, eax
    jz .animal
    cvtsi2sd xmm0, esi
    addsd xmm0, [rel c_half]
    movsd [rel g_pos], xmm0
    cvtsi2sd xmm0, edx
    movsd [rel g_pos + 8], xmm0
    cvtsi2sd xmm0, edi
    addsd xmm0, [rel c_half]
    movsd [rel g_pos + 16], xmm0
    call herd_look
    mov ecx, eax
    xor edx, edx
    lea r8, [rel g_pos]
    call ent_new
    test eax, eax
    js .animal
    imul rax, rax, EntT_size
    lea rcx, [rel g_ents]
    mov edx, [LOCAL(PO_HERD)]
    mov [rcx + rax + EntT.herd], edx
    inc dword [LOCAL(PO_PLACED)]
    jmp .animal
.herd_placed:
    ; (debug log) "entities: 3 x cow:spotted at column cx, cz"
    mov ecx, [rbx + SPAWN.variant]
    call variant_key
    mov ecx, LOG_LEVEL_DEBUG
    call log_begin
    lea rcx, [rel str_herd]
    call log_append_str
    mov ecx, [LOCAL(PO_PLACED)]
    call log_append_dec
    lea rcx, [rel str_herd2]
    call log_append_str
    lea rcx, [rel g_key]
    call log_append_str
    lea rcx, [rel str_herd3]
    call log_append_str
    mov ecx, [LOCAL(PO_CX)]
    call log_sdec
    lea rcx, [rel str_herd4]
    call log_append_str
    mov ecx, [LOCAL(PO_CZ)]
    call log_sdec
    call log_end
    jmp .timed_now
.timed:
.timed_now:
    call timer_elapsed_us
    sub rax, [LOCAL(PO_START)]
    mov [rel g_store_pop_us], rax
.done:
    mov eax, 1
    RETURN
.not_ready:
    xor eax, eax
    RETURN
ENDPROC

; herd_look — eax = the look of the next animal of rule rbx: one of its
; `mix` looks by their %, else the rule's own   clobbers: rax, rcx, rdx, xmm0, xmm1
herd_look:
    cmp dword [rbx + SPAWN.mixes], 0
    je .own
    call rng
    mov eax, eax
    cvtsi2sd xmm0, rax
    mulsd xmm0, [rel c_u32]
    mulsd xmm0, [rel c_hundred]         ; 0 .. 100
    xor edx, edx
.mix:
    cmp edx, [rbx + SPAWN.mixes]
    jae .own
    cvtss2sd xmm1, [rbx + SPAWN.mix_pct + rdx * 4]
    comisd xmm0, xmm1
    jb .mixed
    subsd xmm0, xmm1
    inc edx
    jmp .mix
.mixed:
    mov eax, [rbx + SPAWN.mix_var + rdx * 4]
    ret
.own:
    mov eax, [rbx + SPAWN.variant]
    ret

; -----------------------------------------------------------------------------
; store_update — once per tick: herds for one new column nearby; now and
; then the far regions saved and dropped, and the trickle.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define SU2_PCX     0
%define SU2_PCZ     4
%define SU2_R       8
%define SU2_DX      12
%define SU2_DZ      16
PROC store_update, 32, rbx, rsi, rdi
    inc dword [rel g_ticks]
    movsd xmm0, [rel g_pl_pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    mov [LOCAL(SU2_PCX)], eax
    movsd xmm0, [rel g_pl_pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    mov [LOCAL(SU2_PCZ)], eax
    ; ---- the nearest column not checked yet (rings outwards) ----
    mov dword [LOCAL(SU2_R)], 0
.ring:
    mov eax, [LOCAL(SU2_R)]
    cmp eax, POP_RADIUS
    jg .ringed
    neg eax
    mov [LOCAL(SU2_DZ)], eax
.rz:
    mov eax, [LOCAL(SU2_DZ)]
    cmp eax, [LOCAL(SU2_R)]
    jg .ring_next
    mov eax, [LOCAL(SU2_R)]
    neg eax
    mov [LOCAL(SU2_DX)], eax
.rx:
    mov eax, [LOCAL(SU2_DX)]
    cmp eax, [LOCAL(SU2_R)]
    jg .rz_next
    ; only the ring's edge
    mov ecx, eax
    neg ecx
    cmovs ecx, eax
    mov edx, [LOCAL(SU2_DZ)]
    mov r8d, edx
    neg r8d
    cmovs r8d, edx
    cmp ecx, r8d
    cmovb ecx, r8d
    cmp ecx, [LOCAL(SU2_R)]
    jne .rx_next
    ; checked already? (cheap test before populate)
    mov ecx, [LOCAL(SU2_PCX)]
    add ecx, [LOCAL(SU2_DX)]
    mov edx, [LOCAL(SU2_PCZ)]
    add edx, [LOCAL(SU2_DZ)]
    call column_checked
    test eax, eax
    jnz .rx_next
    mov ecx, [LOCAL(SU2_PCX)]
    add ecx, [LOCAL(SU2_DX)]
    mov edx, [LOCAL(SU2_PCZ)]
    add edx, [LOCAL(SU2_DZ)]
    xor r8d, r8d
    call populate
    test eax, eax
    jnz .ringed                         ; (one column per tick)
.rx_next:
    inc dword [LOCAL(SU2_DX)]
    jmp .rx
.rz_next:
    inc dword [LOCAL(SU2_DZ)]
    jmp .rz
.ring_next:
    inc dword [LOCAL(SU2_R)]
    jmp .ring
.ringed:
    ; ---- every second: drop the regions far away ----
    mov eax, [rel g_ticks]
    xor edx, edx
    mov ecx, 20
    div ecx
    test edx, edx
    jnz .trickle
    xor ebx, ebx
.region:
    cmp ebx, MAX_EREGIONS
    jae .trickle
    imul eax, ebx, EREG_size
    lea rsi, [rel g_eregs]
    add rsi, rax
    cmp dword [rsi + EREG.used], 0
    je .region_next
    ; distance from the player to the region's square
    mov eax, [rsi + EREG.rx]
    shl eax, EREGION_SHIFT
    cvtsi2sd xmm0, eax                  ; min x
    movsd xmm1, xmm0
    addsd xmm1, [rel c_region]          ; max x
    movsd xmm2, [rel g_pl_pos]
    maxsd xmm2, xmm0
    minsd xmm2, xmm1
    subsd xmm2, [rel g_pl_pos]
    mulsd xmm2, xmm2
    mov eax, [rsi + EREG.rz]
    shl eax, EREGION_SHIFT
    cvtsi2sd xmm0, eax
    movsd xmm1, xmm0
    addsd xmm1, [rel c_region]
    movsd xmm3, [rel g_pl_pos + 16]
    maxsd xmm3, xmm0
    minsd xmm3, xmm1
    subsd xmm3, [rel g_pl_pos + 16]
    mulsd xmm3, xmm3
    addsd xmm2, xmm3
    comisd xmm2, [rel c_unload2]
    jbe .region_next
    mov ecx, ebx
    call unload_region
.region_next:
    inc ebx
    jmp .region
.trickle:
    ; ---- every 30 seconds: an empty spot nearby gets a new roll ----
    mov eax, [rel g_ticks]
    xor edx, edx
    mov ecx, TRICKLE_TICKS
    div ecx
    test edx, edx
    jnz .done
    mov eax, [rel g_trickle_rng]
    mov [rel g_rng], eax
    mov ecx, 2 * POP_RADIUS + 1
    call rng_below
    sub eax, POP_RADIUS
    mov [LOCAL(SU2_DX)], eax
    mov ecx, 2 * POP_RADIUS + 1
    call rng_below
    sub eax, POP_RADIUS
    mov [LOCAL(SU2_DZ)], eax
    mov eax, [rel g_rng]
    mov [rel g_trickle_rng], eax
    ; not right next to the player (nothing pops up in view)
    mov eax, [LOCAL(SU2_DX)]
    mov ecx, eax
    neg ecx
    cmovs ecx, eax
    mov eax, [LOCAL(SU2_DZ)]
    mov edx, eax
    neg edx
    cmovs edx, eax
    cmp ecx, edx
    cmovb ecx, edx
    cmp ecx, 3
    jb .done
    mov ecx, [LOCAL(SU2_PCX)]
    add ecx, [LOCAL(SU2_DX)]
    mov edx, [LOCAL(SU2_PCZ)]
    add edx, [LOCAL(SU2_DZ)]
    call animals_near
    test eax, eax
    jnz .done
    mov ecx, [LOCAL(SU2_PCX)]
    add ecx, [LOCAL(SU2_DX)]
    mov edx, [LOCAL(SU2_PCZ)]
    add edx, [LOCAL(SU2_DZ)]
    mov r8d, 1
    call populate
.done:
    RETURN
ENDPROC

; column_checked — eax = 1 if column (ecx, edx) had its herd roll (its
; region is in memory and its bit is set)   clobbers: volatile registers
PROC column_checked, 0
    mov eax, ecx
    sar eax, 5
    mov r8d, edx
    sar r8d, 5
    lea r9, [rel g_eregs]
    xor r10d, r10d
.find:
    cmp r10d, MAX_EREGIONS
    jae .no
    cmp dword [r9 + EREG.used], 0
    je .next
    cmp [r9 + EREG.rx], eax
    jne .next
    cmp [r9 + EREG.rz], r8d
    jne .next
    and ecx, 31
    and edx, 31
    shl edx, 5
    or ecx, edx
    xor eax, eax
    bt [r9 + EREG.pop], ecx
    setc al
    RETURN
.next:
    add r9, EREG_size
    inc r10d
    jmp .find
.no:
    xor eax, eax
    RETURN
ENDPROC

; animals_near — eax = 1 if an animal stands in column (ecx, edx) or the 8
; around it   clobbers: volatile registers
PROC animals_near, 0
    lea r8, [rel g_ents]
    xor r9d, r9d
.ent:
    cmp r9d, MAX_ENTITIES
    jae .no
    test dword [r8 + EntT.flags], EF_ACTIVE
    jz .next
    movsd xmm0, [r8 + EntT.pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    sub eax, ecx
    add eax, 1
    cmp eax, 2
    ja .next
    movsd xmm0, [r8 + EntT.pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    sub eax, edx
    add eax, 1
    cmp eax, 2
    ja .next
    mov eax, 1
    RETURN
.next:
    add r8, EntT_size
    inc r9d
    jmp .ent
.no:
    xor eax, eax
    RETURN
ENDPROC
