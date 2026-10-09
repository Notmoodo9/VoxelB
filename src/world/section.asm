; =============================================================================
; section.asm — palette-compressed 32x32x32 block sections.
;
; Storage per section (SECT header from a pool, 64 bytes):
;   bits 0     uniform: one block id in the header, no data at all
;   bits 1..8  palette of up to 2^bits ids (u16[256] block) + packed indices
;              (32768 * bits / 8 bytes: 4, 8, 16 or 32 KB)
;   bits 16    raw u16 ids (64 KB), no palette (more than 256 kinds)
; All-air sections are not stored at all (a null SECT* means air).
; Every allocation comes from lock-free pools, so worker threads can build
; and free sections concurrently.
;
; Public API (see include/section.inc):
;   sections_init() -> eax 1/0
;   section_build(ids u16[32768], cx, sy, cz) -> rax SECT* (0 = all air)
;   section_get(sect, idx) -> eax id            (sect may be 0)
;   section_decode(sect, out u16[32768])        (sect may be 0)
;   section_set(sect, idx, id, scratch ARENA*) -> eax 1/0  (grows palette)
;   section_make_uniform(id, cx, sy, cz) -> rax SECT* (0 for air)
;   section_free(sect)
;   g_sections_live, g_section_bytes
; =============================================================================
%define SECTION_IMPL
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "world.inc"

global sections_init, section_build, section_get, section_decode
global section_set, section_free, section_make_uniform
global g_sections_live, g_section_bytes

section .rdata
name_sect:      db "section headers", 0
name_pal:       db "section palettes", 0
name_d1:        db "section data 1-bit", 0
name_d2:        db "section data 2-bit", 0
name_d4:        db "section data 4-bit", 0
name_d8:        db "section data 8-bit", 0
name_d16:       db "section data 16-bit", 0
align 8
; data pool index by bit width: bits -> slot (1->0, 2->1, 4->2, 8->3, 16->4)
data_pool_names: dq name_d1, name_d2, name_d4, name_d8, name_d16
data_pool_max:   dq 65536, 65536, 65536, 65536, 32768

section .bss
alignb 64
g_pool_sect:    resb POOL_size
g_pool_pal:     resb POOL_size
g_pool_data:    resb POOL_size * 5
alignb 64
g_sections_live: resq 8                 ; own cache line
g_section_bytes: resq 8
g_sections_ready: resd 1

section .text

; -----------------------------------------------------------------------------
; bits_slot — data pool slot for a bit width.
;   in:  ecx = bits (1, 2, 4, 8, 16)     out: rax = POOL*
;   clobbers: rax, rcx
; -----------------------------------------------------------------------------
bits_slot:
    bsf ecx, ecx                        ; 0..4
    imul ecx, ecx, POOL_size
    lea rax, [rel g_pool_data]
    add rax, rcx
    ret

; -----------------------------------------------------------------------------
; sections_init — create the section pools (address space only).
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC sections_init, 0, rbx, rsi
    cmp dword [rel g_sections_ready], 0
    jne .ready                          ; idempotent (self test + world)
    lea rcx, [rel g_pool_sect]
    lea rax, [rel name_sect]
    mov [rsp + 32], rax
    INVOKE pool_init, rcx, SECT_size, 1 << 20, 4096
    test eax, eax
    jz .fail
    lea rcx, [rel g_pool_pal]
    lea rax, [rel name_pal]
    mov [rsp + 32], rax
    INVOKE pool_init, rcx, 512, 1 << 18, 0
    test eax, eax
    jz .fail
    xor esi, esi                        ; slot 0..4
.data_pools:
    mov ecx, esi                        ; block = 32768 * bits / 8 = 4096 << slot
    mov edx, 4096
    shl edx, cl                         ; block size
    imul rbx, rsi, POOL_size
    lea rcx, [rel g_pool_data]
    add rcx, rbx
    lea rax, [rel data_pool_names]
    mov rax, [rax + rsi * 8]
    mov [rsp + 32], rax
    lea rax, [rel data_pool_max]
    mov r8, [rax + rsi * 8]
    INVOKE pool_init, rcx, rdx, r8, 0
    test eax, eax
    jz .fail
    inc esi
    cmp esi, 5
    jb .data_pools
    LOG_INFO "sections: pools reserved"
    mov dword [rel g_sections_ready], 1
.ready:
    mov eax, 1
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; build_storage — compute palette/bits for ids[] and fill the section's
; storage fields (palette, data, bits, pal_count, uniform_id).
;   in:  rcx = SECT*, rdx = ids u16[32768]
;   out: eax = 1 on success, 0 if a pool was exhausted (logged)
;        (an all-air array yields bits 0 with uniform_id 0)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define BS_PAL      0                   ; u16[256] working palette
%define BS_LOCALS   512
PROC build_storage, BS_LOCALS, rbx, rsi, rdi, r12, r13, r14, r15
    mov rbx, rcx                        ; sect
    mov rsi, rdx                        ; ids
    lea rdi, [LOCAL(BS_PAL)]            ; palette
    ; ---- pass 1: palette ----------------------------------------------------
    xor r12d, r12d                      ; pal count
    mov r13d, -1                        ; last id
    xor ecx, ecx                        ; index
.p1:
    movzx eax, word [rsi + rcx * 2]
    cmp eax, r13d
    je .p1_next
    mov r13d, eax
    xor edx, edx
.p1_find:
    cmp edx, r12d
    jae .p1_add
    cmp ax, [rdi + rdx * 2]
    je .p1_next
    inc edx
    jmp .p1_find
.p1_add:
    cmp r12d, 256
    jae .raw                            ; more than 256 kinds: raw 16-bit
    mov [rdi + r12 * 2], ax
    inc r12d
.p1_next:
    inc ecx
    cmp ecx, SECTION_VOLUME
    jb .p1

    mov [rbx + SECT.pal_count], r12w
    cmp r12d, 1
    jne .packed
    ; ---- uniform --------------------------------------------------------------
    mov byte [rbx + SECT.bits], 0
    mov ax, [rdi]
    mov [rbx + SECT.uniform_id], ax
    mov qword [rbx + SECT.palette], 0
    mov qword [rbx + SECT.data], 0
    mov eax, 1
    RETURN

.packed:
    ; bits = smallest power of two with 2^bits >= count
    mov r14d, 1
    cmp r12d, 2
    jbe .bits_ok
    mov r14d, 2
    cmp r12d, 4
    jbe .bits_ok
    mov r14d, 4
    cmp r12d, 16
    jbe .bits_ok
    mov r14d, 8
.bits_ok:
    mov [rbx + SECT.bits], r14b
    lea rcx, [rel g_pool_pal]
    call pool_alloc
    test rax, rax
    jz .fail
    mov [rbx + SECT.palette], rax
    ; copy palette (256 entries; unused tail is harmless)
    mov rcx, rax
    xor edx, edx
.copy_pal:
    mov r8, [rdi + rdx * 8]
    mov [rcx + rdx * 8], r8
    inc edx
    cmp edx, 64
    jb .copy_pal
    mov ecx, r14d
    call bits_slot
    mov rcx, rax
    call pool_alloc
    test rax, rax
    jz .fail
    mov [rbx + SECT.data], rax
    mov r15, rax                        ; data
    ; zero the packed data: 4096 << log2(bits) bytes
    mov ecx, r14d
    bsf ecx, ecx
    mov edx, 4096 / 8
    shl edx, cl
    mov r10, rdi                        ; keep the palette pointer
    mov rdi, r15
    mov ecx, edx
    xor eax, eax
    rep stosq
    mov rdi, r10
    ; ---- pass 2: pack indices ---------------------------------------------------
    ; r13 = last id, r12 = last index (cache for runs)
    mov r13d, -1
    xor ecx, ecx                        ; block index
.p2:
    movzx eax, word [rsi + rcx * 2]
    cmp eax, r13d
    je .p2_have
    mov r13d, eax
    xor edx, edx
.p2_find:
    cmp ax, [rdi + rdx * 2]
    je .p2_found
    inc edx
    jmp .p2_find                        ; always found (built in pass 1)
.p2_found:
    mov r12d, edx
.p2_have:
    ; bitpos = index * bits
    mov eax, ecx
    imul eax, r14d
    mov edx, eax
    shr edx, 3                          ; byte offset
    and eax, 7                          ; shift
    mov r8d, r12d
    xchg ecx, eax
    shl r8d, cl
    xchg ecx, eax
    or [r15 + rdx], r8b
    inc ecx
    cmp ecx, SECTION_VOLUME
    jb .p2
    mov eax, 1
    RETURN

.raw:
    mov byte [rbx + SECT.bits], 16
    mov word [rbx + SECT.pal_count], 0
    mov qword [rbx + SECT.palette], 0
    mov ecx, 16
    call bits_slot
    mov rcx, rax
    call pool_alloc
    test rax, rax
    jz .fail
    mov [rbx + SECT.data], rax
    mov rdi, rax
    mov ecx, SECTION_VOLUME * 2 / 8
    rep movsq
    mov eax, 1
    RETURN
.fail:
    LOG_ERROR "sections: out of pool space"
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; storage_bytes — memory used by a section's storage (+ header).
;   in:  rcx = SECT*     out: rax = bytes
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
storage_bytes:
    movzx edx, byte [rcx + SECT.bits]
    mov eax, SECT_size
    test edx, edx
    jz .done
    cmp edx, 16
    je .raw
    add eax, 512                        ; palette
    mov ecx, edx
    bsf ecx, ecx
    mov edx, 4096
    shl edx, cl
    add eax, edx
    ret
.raw:
    add eax, SECTION_VOLUME * 2
.done:
    ret

; -----------------------------------------------------------------------------
; free_storage — return palette and data blocks to their pools.
;   in:  rcx = SECT*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC free_storage, 0, rbx
    mov rbx, rcx
    mov rdx, [rbx + SECT.palette]
    test rdx, rdx
    jz .no_pal
    lea rcx, [rel g_pool_pal]
    call pool_free
    mov qword [rbx + SECT.palette], 0
.no_pal:
    mov rdx, [rbx + SECT.data]
    test rdx, rdx
    jz .no_data
    movzx ecx, byte [rbx + SECT.bits]
    call bits_slot
    mov rcx, rax
    mov rdx, [rbx + SECT.data]
    call pool_free
    mov qword [rbx + SECT.data], 0
.no_data:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; section_build — create a section from a full id array.
;   in:  rcx = ids u16[32768], edx = cx, r8d = sy, r9d = cz
;   out: rax = SECT*, or 0 if every block is air (or on pool exhaustion,
;        logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC section_build, 0, rbx, rsi, rdi, r12, r13
    mov rsi, rcx
    mov edi, edx
    mov r12d, r8d
    mov r13d, r9d
    lea rcx, [rel g_pool_sect]
    call pool_alloc
    test rax, rax
    jz .fail
    mov rbx, rax
    mov [rbx + SECT.cx], edi
    mov [rbx + SECT.sy], r12d
    mov [rbx + SECT.cz], r13d
    mov byte [rbx + SECT.flags], 0
    xor eax, eax
    mov [rbx + SECT.quad_first], eax
    mov [rbx + SECT.quad_count], eax
    mov [rbx + SECT.mesh_us], eax
    mov [rbx + SECT.quad_opaque], eax
    mov [rbx + SECT.quad_cutout], eax
    mov [rbx + SECT.cpu_first], eax
    mov [rbx + SECT.palette], rax
    mov [rbx + SECT.data], rax
    INVOKE build_storage, rbx, rsi
    test eax, eax
    jz .fail_free
    cmp byte [rbx + SECT.bits], 0
    jne .keep
    cmp word [rbx + SECT.uniform_id], BLOCK_AIR
    jne .keep
    ; all air: not stored
    lea rcx, [rel g_pool_sect]
    mov rdx, rbx
    call pool_free
    xor eax, eax
    RETURN
.keep:
    lock inc qword [rel g_sections_live]
    mov rcx, rbx
    call storage_bytes
    lock add [rel g_section_bytes], rax
    mov rax, rbx
    RETURN
.fail_free:
    mov rcx, rbx
    call free_storage
    lea rcx, [rel g_pool_sect]
    mov rdx, rbx
    call pool_free
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; section_make_uniform — create a section filled with one block (no data).
;   in:  ecx = block id, edx = cx, r8d = sy, r9d = cz
;   out: rax = SECT*, or 0 for air / pool exhaustion (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC section_make_uniform, 0, rbx, rsi, rdi, r12, r13
    test ecx, ecx
    jz .air
    mov esi, ecx
    mov edi, edx
    mov r12d, r8d
    mov r13d, r9d
    lea rcx, [rel g_pool_sect]
    call pool_alloc
    test rax, rax
    jz .air
    mov rbx, rax
    mov [rbx + SECT.cx], edi
    mov [rbx + SECT.sy], r12d
    mov [rbx + SECT.cz], r13d
    mov byte [rbx + SECT.bits], 0
    mov byte [rbx + SECT.flags], 0
    mov word [rbx + SECT.pal_count], 1
    mov [rbx + SECT.uniform_id], si
    xor eax, eax
    mov [rbx + SECT.palette], rax
    mov [rbx + SECT.data], rax
    mov [rbx + SECT.quad_first], eax
    mov [rbx + SECT.quad_count], eax
    mov [rbx + SECT.mesh_us], eax
    mov [rbx + SECT.quad_opaque], eax
    mov [rbx + SECT.quad_cutout], eax
    mov [rbx + SECT.cpu_first], eax
    lock inc qword [rel g_sections_live]
    lock add qword [rel g_section_bytes], SECT_size
    mov rax, rbx
    RETURN
.air:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; section_free — free a section and its storage (0 is ignored).
;   in:  rcx = SECT*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC section_free, 0, rbx
    test rcx, rcx
    jz .done
    mov rbx, rcx
    call storage_bytes
    neg rax
    lock add [rel g_section_bytes], rax
    lock dec qword [rel g_sections_live]
    mov rcx, rbx
    call free_storage
    lea rcx, [rel g_pool_sect]
    mov rdx, rbx
    call pool_free
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; section_get — block id at an index.
;   in:  rcx = SECT* (0 = air), edx = idx (y<<10 | z<<5 | x)
;   out: eax = block id
;   clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
section_get:
    test rcx, rcx
    jz .air
    movzx r8d, byte [rcx + SECT.bits]
    test r8d, r8d
    jz .uniform
    cmp r8d, 16
    je .raw
    mov rax, rcx                        ; sect
    mov ecx, r8d
    imul edx, ecx                       ; bitpos
    mov r8, [rax + SECT.data]
    mov r9d, edx
    shr r9d, 3
    movzx r8d, byte [r8 + r9]           ; byte
    and edx, 7
    xchg ecx, edx                       ; cl = shift, edx = bits
    shr r8d, cl
    mov ecx, edx
    mov edx, 1
    shl edx, cl
    dec edx                             ; mask
    and r8d, edx
    mov rax, [rax + SECT.palette]
    movzx eax, word [rax + r8 * 2]
    ret
.uniform:
    movzx eax, word [rcx + SECT.uniform_id]
    ret
.raw:
    mov rax, [rcx + SECT.data]
    movzx eax, word [rax + rdx * 2]
    ret
.air:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; section_decode — expand a section to a full u16[32768] id array.
;   in:  rcx = SECT* (0 = air), rdx = out
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC section_decode, 0, rbx, rsi, rdi, r12, r13
    mov rdi, rdx
    test rcx, rcx
    jz .fill_air
    mov rbx, rcx
    movzx r12d, byte [rbx + SECT.bits]
    test r12d, r12d
    jz .fill_uniform
    cmp r12d, 16
    je .copy_raw
    ; generic packed decode, one byte at a time
    mov rsi, [rbx + SECT.data]
    mov r13, [rbx + SECT.palette]
    mov ecx, r12d
    mov r9d, 1
    shl r9d, cl
    dec r9d                             ; mask
    mov eax, 8
    xor edx, edx
    div r12d
    mov r10d, eax                       ; entries per byte
    mov r11d, SECTION_VOLUME
.byte_loop:
    movzx eax, byte [rsi]
    inc rsi
    mov edx, r10d
.entry:
    mov r8d, eax
    and r8d, r9d
    movzx r8d, word [r13 + r8 * 2]
    mov [rdi], r8w
    add rdi, 2
    mov ecx, r12d
    shr eax, cl
    dec edx
    jnz .entry
    sub r11d, r10d
    jnz .byte_loop
    RETURN
.fill_uniform:
    movzx eax, word [rbx + SECT.uniform_id]
    mov ecx, SECTION_VOLUME
    rep stosw
    RETURN
.fill_air:
    xor eax, eax
    mov ecx, SECTION_VOLUME * 2 / 8
    rep stosq
    RETURN
.copy_raw:
    mov rsi, [rbx + SECT.data]
    mov ecx, SECTION_VOLUME * 2 / 8
    rep movsq
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; section_set — change one block, growing the palette/bit width if needed.
;   in:  rcx = SECT* (non-null), edx = idx, r8d = id, r9 = scratch ARENA*
;        (64 KB temporary, only when the storage must be rebuilt)
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC section_set, 0, rbx, rsi, rdi, r12, r13, r14
    mov rbx, rcx
    mov esi, edx                        ; idx
    mov edi, r8d                        ; id
    mov r12, r9                         ; scratch arena
    movzx r13d, byte [rbx + SECT.bits]
    cmp r13d, 16
    je .raw
    test r13d, r13d
    jz .rebuild_check_uniform
    ; find id in palette
    mov rax, [rbx + SECT.palette]
    movzx ecx, word [rbx + SECT.pal_count]
    xor edx, edx
.find:
    cmp edx, ecx
    jae .not_found
    cmp di, [rax + rdx * 2]
    je .write_index
    inc edx
    jmp .find
.not_found:
    mov r8d, 1
    xchg ecx, r13d
    shl r8d, cl                         ; capacity = 1 << bits
    xchg ecx, r13d
    cmp ecx, r8d
    jae .rebuild                        ; full: grow
    mov [rax + rcx * 2], di             ; append
    inc word [rbx + SECT.pal_count]
    mov edx, ecx
.write_index:
    ; clear and set `bits` bits at bitpos = idx * bits
    mov eax, esi
    imul eax, r13d
    mov r9d, eax
    shr r9d, 3                          ; byte
    and eax, 7                          ; shift
    mov r10, [rbx + SECT.data]
    mov ecx, r13d
    mov r8d, 1
    shl r8d, cl
    dec r8d                             ; mask
    mov ecx, eax
    shl r8d, cl
    shl edx, cl
    not r8d
    and [r10 + r9], r8b
    or [r10 + r9], dl
    mov eax, 1
    RETURN
.raw:
    mov rax, [rbx + SECT.data]
    mov [rax + rsi * 2], di
    mov eax, 1
    RETURN
.rebuild_check_uniform:
    cmp di, [rbx + SECT.uniform_id]
    jne .rebuild
    mov eax, 1
    RETURN
.rebuild:
    ; decode -> modify -> rebuild storage (palette is recomputed exactly)
    mov rcx, r12
    call arena_mark
    mov r14, rax
    INVOKE arena_alloc, r12, SECTION_VOLUME * 2, 64
    test rax, rax
    jz .fail
    mov r13, rax
    INVOKE section_decode, rbx, r13
    mov [r13 + rsi * 2], di
    mov rcx, rbx
    call storage_bytes
    neg rax
    lock add [rel g_section_bytes], rax
    mov rcx, rbx
    call free_storage
    INVOKE build_storage, rbx, r13
    test eax, eax
    jz .fail_reset
    mov rcx, rbx
    call storage_bytes
    lock add [rel g_section_bytes], rax
    INVOKE arena_reset_to, r12, r14
    mov eax, 1
    RETURN
.fail_reset:
    INVOKE arena_reset_to, r12, r14
.fail:
    xor eax, eax
    RETURN
ENDPROC
