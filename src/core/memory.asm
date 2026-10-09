; =============================================================================
; memory.asm — virtual-memory arenas and lock-free fixed-size pools.
; See include/memory.inc for the model; DECISIONS.md D23 for the rationale.
; =============================================================================
%define MEMORY_IMPL
%include "macros.inc"
%include "log.inc"
%include "memory.inc"

global mem_init, mem_shutdown
global arena_init, arena_release, arena_alloc, arena_try_alloc
global arena_mark, arena_reset_to, arena_reset
global pool_init, pool_release, pool_alloc, pool_free
global arena_alloc_shared
global g_arena_perm, g_arena_frame, g_arena_scratch, g_mem_committed

IMPORT VirtualAlloc, VirtualFree

%define MEM_COMMIT          0x1000
%define MEM_RESERVE         0x2000
%define MEM_RELEASE         0x8000
%define PAGE_NOACCESS       0x01
%define PAGE_READWRITE      0x04
%define COMMIT_GRANULE      KB(64)

section .rdata
name_perm:      db "perm", 0
name_frame:     db "frame", 0
name_scratch:   db "scratch", 0
str_oom:        db "arena out of reserved space: ", 0
str_commit:     db "VirtualAlloc commit failed for: ", 0
str_reserve:    db "VirtualAlloc reserve failed for: ", 0
str_pool_full:  db "pool exhausted: ", 0

section .bss
alignb 64
g_arena_perm:       resb ARENA_size
alignb 64
g_arena_frame:      resb ARENA_size
alignb 64
g_arena_scratch:    resb ARENA_size
alignb 64
g_mem_committed:    resq 1              ; bytes committed by arenas + pools

section .text

; -----------------------------------------------------------------------------
; log_named — log "<prefix><name>" at ERROR level.
;   in:  rcx = prefix, rdx = name
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_named, 0, rbx, rsi
    mov rbx, rcx
    mov rsi, rdx
    mov ecx, LOG_LEVEL_ERROR
    call log_begin
    mov rcx, rbx
    call log_append_str
    mov rcx, rsi
    call log_append_str
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; arena_init — reserve address space for an arena (nothing committed yet).
;   in:  rcx = ARENA*, rdx = bytes to reserve, r8 = name (static string)
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC arena_init, 0, rbx, rsi
    mov rbx, rcx
    mov rsi, rdx
    mov [rbx + ARENA.name], r8
    xor eax, eax
    mov [rbx + ARENA.committed], rax
    mov [rbx + ARENA.used], rax
    mov [rbx + ARENA.peak], rax
    mov [rbx + ARENA.reserved], rsi
    API VirtualAlloc, 0, rsi, MEM_RESERVE, PAGE_NOACCESS
    mov [rbx + ARENA.base], rax
    test rax, rax
    jnz .ok
    lea rcx, [rel str_reserve]
    INVOKE log_named, rcx, [rbx + ARENA.name]
    xor eax, eax
    RETURN
.ok:
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; arena_release — return an arena's address space to the OS.
;   in:  rcx = ARENA*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC arena_release, 0, rbx
    mov rbx, rcx
    mov rcx, [rbx + ARENA.base]
    test rcx, rcx
    jz .done
    API VirtualFree, rcx, 0, MEM_RELEASE
    mov rax, [rbx + ARENA.committed]
    neg rax
    lock add [rel g_mem_committed], rax
    xor eax, eax
    mov [rbx + ARENA.base], rax
    mov [rbx + ARENA.committed], rax
    mov [rbx + ARENA.used], rax
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; arena_try_alloc — allocate from an arena without logging on failure.
;   in:  rcx = ARENA*, rdx = size in bytes, r8 = alignment (power of two)
;   out: rax = pointer, or 0 if the reservation is exhausted / commit failed
;   clobbers: volatile registers
;   note: memory is zero only the first time it is committed.
; -----------------------------------------------------------------------------
PROC arena_try_alloc, 16, rbx, rsi, rdi
    mov rbx, rcx
    lea rax, [r8 - 1]
    mov rsi, [rbx + ARENA.used]
    add rsi, rax
    not rax
    and rsi, rax                        ; rsi = aligned offset
    lea rdi, [rsi + rdx]                ; rdi = end offset
    cmp rdi, [rbx + ARENA.reserved]
    ja .fail
    cmp rdi, [rbx + ARENA.committed]
    jbe .committed
    ; commit up to the next granule boundary (capped at the reservation)
    lea rdx, [rdi + COMMIT_GRANULE - 1]
    and rdx, -COMMIT_GRANULE
    cmp rdx, [rbx + ARENA.reserved]
    jbe .cap_ok
    mov rdx, [rbx + ARENA.reserved]
.cap_ok:
    mov rcx, [rbx + ARENA.committed]
    sub rdx, rcx                        ; bytes to commit
    add rcx, [rbx + ARENA.base]         ; from here
    mov [LOCAL(0)], rdx
    API VirtualAlloc, rcx, rdx, MEM_COMMIT, PAGE_READWRITE
    test rax, rax
    jz .fail
    mov rdx, [LOCAL(0)]
    add [rbx + ARENA.committed], rdx
    lock add [rel g_mem_committed], rdx
.committed:
    mov [rbx + ARENA.used], rdi
    cmp rdi, [rbx + ARENA.peak]
    jbe .peak_ok
    mov [rbx + ARENA.peak], rdi
.peak_ok:
    mov rax, [rbx + ARENA.base]
    add rax, rsi
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; arena_alloc — allocate from an arena; logs an error on failure.
;   in:  rcx = ARENA*, rdx = size, r8 = alignment (power of two)
;   out: rax = pointer, or 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC arena_alloc, 0, rbx
    mov rbx, rcx
    call arena_try_alloc
    test rax, rax
    jnz .ok
    lea rcx, [rel str_oom]
    INVOKE log_named, rcx, [rbx + ARENA.name]
    xor eax, eax
.ok:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; arena_alloc_shared — thread-safe bump allocation from an arena that several
; threads append to (e.g. mesh staging). Uses an atomic add on .used and
; commits the returned range itself (VirtualAlloc commit is idempotent and
; thread-safe). Do not mix with arena_alloc on the same arena while threads
; are allocating; reset only when no thread is using it.
;   in:  rcx = ARENA*, rdx = size (rounded up to 16 bytes)
;   out: rax = pointer, or 0 if the reservation is exhausted (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC arena_alloc_shared, 0, rbx, rsi, rdi
    mov rbx, rcx
    lea rsi, [rdx + 15]
    and rsi, -16                        ; size
    mov rax, rsi
    lock xadd [rbx + ARENA.used], rax   ; rax = offset
    mov rdi, rax
    add rax, rsi
    cmp rax, [rbx + ARENA.reserved]
    ja .full
    ; peak = max(peak, end) (racy but only statistics)
    cmp rax, [rbx + ARENA.peak]
    jbe .peak_ok
    mov [rbx + ARENA.peak], rax
.peak_ok:
    mov rcx, [rbx + ARENA.base]
    add rcx, rdi
    API VirtualAlloc, rcx, rsi, MEM_COMMIT, PAGE_READWRITE
    test rax, rax
    jz .full
    lock add [rel g_mem_committed], rsi
    lock add [rbx + ARENA.committed], rsi
    ; VirtualAlloc returns the start of the first committed *page*, not our
    ; (unaligned) address: return base + offset ourselves
    mov rax, [rbx + ARENA.base]
    add rax, rdi
    RETURN
.full:
    LOG_ERROR "shared arena exhausted"
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; arena_mark — current position, for a later arena_reset_to.
;   in:  rcx = ARENA*         out: rax = mark
;   clobbers: rax
; -----------------------------------------------------------------------------
arena_mark:
    mov rax, [rcx + ARENA.used]
    ret

; -----------------------------------------------------------------------------
; arena_reset_to — free everything allocated after a mark (keeps commits).
;   in:  rcx = ARENA*, rdx = mark
;   clobbers: none
; -----------------------------------------------------------------------------
arena_reset_to:
    mov [rcx + ARENA.used], rdx
    ret

; -----------------------------------------------------------------------------
; arena_reset — free everything in the arena (keeps commits).
;   in:  rcx = ARENA*
;   clobbers: none
; -----------------------------------------------------------------------------
arena_reset:
    mov qword [rcx + ARENA.used], 0
    ret

; -----------------------------------------------------------------------------
; pool_init — reserve space for max_blocks blocks and commit the first
; `precommit` of them.
;   in:  rcx = POOL* (16-byte aligned), rdx = block size (>= 8, multiple of
;        8), r8 = max blocks, r9 = blocks to commit now, ARG 5 = name
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC pool_init, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rax, [ARG(5)]
    mov [rbx + POOL.name], rax
    xor eax, eax
    mov [rbx + POOL.free_ptr], rax
    mov [rbx + POOL.free_tag], rax
    mov [rbx + POOL.bump], rax
    mov [rbx + POOL.in_use], rax
    mov [rbx + POOL.block_size], rdx
    mov [rbx + POOL.max_blocks], r8
    mov [rbx + POOL.precommitted], r9
    mov rsi, rdx
    imul rsi, r8                        ; bytes to reserve
    mov rdi, rdx
    imul rdi, r9                        ; bytes to commit now
    API VirtualAlloc, 0, rsi, MEM_RESERVE, PAGE_NOACCESS
    mov [rbx + POOL.base], rax
    test rax, rax
    jz .fail_reserve
    test rdi, rdi
    jz .ok
    API VirtualAlloc, rax, rdi, MEM_COMMIT, PAGE_READWRITE
    test rax, rax
    jz .fail_commit
    lock add [rel g_mem_committed], rdi
.ok:
    mov eax, 1
    RETURN
.fail_reserve:
    lea rcx, [rel str_reserve]
    INVOKE log_named, rcx, [rbx + POOL.name]
    xor eax, eax
    RETURN
.fail_commit:
    lea rcx, [rel str_commit]
    INVOKE log_named, rcx, [rbx + POOL.name]
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; pool_release — return a pool's memory to the OS (no thread may use it).
;   in:  rcx = POOL*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC pool_release, 0, rbx
    mov rbx, rcx
    mov rcx, [rbx + POOL.base]
    test rcx, rcx
    jz .done
    API VirtualFree, rcx, 0, MEM_RELEASE
    ; committed bytes: the larger of precommitted and bump-allocated blocks
    mov rax, [rbx + POOL.bump]
    cmp rax, [rbx + POOL.precommitted]
    jae .count
    mov rax, [rbx + POOL.precommitted]
.count:
    imul rax, [rbx + POOL.block_size]
    neg rax
    lock add [rel g_mem_committed], rax
    mov qword [rbx + POOL.base], 0
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; pool_alloc — take one block (thread-safe, lock-free).
;   in:  rcx = POOL*
;   out: rax = block, or 0 if the pool is exhausted (logged)
;   clobbers: volatile registers
;   note: block contents are undefined (the first 8 bytes held a link).
; -----------------------------------------------------------------------------
PROC pool_alloc, 0, rbx, rsi, rdi
    mov rdi, rcx                        ; rdi = pool (rbx/rcx used by cmpxchg16b)
.retry:
    mov rax, [rdi + POOL.free_ptr]
    mov rdx, [rdi + POOL.free_tag]
    test rax, rax
    jz .bump
    ; next = first qword of the head block. The block may be popped and
    ; reused concurrently; then the tag has changed and the CAS fails.
    mov rbx, [rax]
    lea rcx, [rdx + 1]
    lock cmpxchg16b [rdi + POOL.free_ptr]
    jne .retry
    lock inc qword [rdi + POOL.in_use]
    RETURN
.bump:
    mov eax, 1
    lock xadd [rdi + POOL.bump], rax    ; rax = block index
    cmp rax, [rdi + POOL.max_blocks]
    jae .exhausted
    mov rsi, rax
    imul rsi, [rdi + POOL.block_size]
    add rsi, [rdi + POOL.base]          ; rsi = block address
    cmp rax, [rdi + POOL.precommitted]
    jb .ready
    ; past the pre-committed part: commit this block's pages (idempotent,
    ; thread-safe; another block on the same page may commit it too)
    mov rdx, [rdi + POOL.block_size]
    API VirtualAlloc, rsi, rdx, MEM_COMMIT, PAGE_READWRITE
    test rax, rax
    jz .exhausted
    mov rax, [rdi + POOL.block_size]
    lock add [rel g_mem_committed], rax
.ready:
    lock inc qword [rdi + POOL.in_use]
    mov rax, rsi
    RETURN
.exhausted:
    lea rcx, [rel str_pool_full]
    INVOKE log_named, rcx, [rdi + POOL.name]
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; pool_free — give a block back (thread-safe, lock-free).
;   in:  rcx = POOL*, rdx = block (0 is ignored)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC pool_free, 0, rbx, rdi
    test rdx, rdx
    jz .done
    mov rdi, rcx
    mov rbx, rdx                        ; new head
.retry:
    mov rax, [rdi + POOL.free_ptr]
    mov rdx, [rdi + POOL.free_tag]
    mov [rbx], rax                      ; link to the current head
    lea rcx, [rdx + 1]
    lock cmpxchg16b [rdi + POOL.free_ptr]
    jne .retry
    lock dec qword [rdi + POOL.in_use]
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mem_init — create the global arenas.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC mem_init, 0
    lea rcx, [rel g_arena_perm]
    lea r8, [rel name_perm]
    INVOKE arena_init, rcx, GB(1), r8
    test eax, eax
    jz .fail
    lea rcx, [rel g_arena_frame]
    lea r8, [rel name_frame]
    INVOKE arena_init, rcx, MB(64), r8
    test eax, eax
    jz .fail
    lea rcx, [rel g_arena_scratch]
    lea r8, [rel name_scratch]
    INVOKE arena_init, rcx, MB(256), r8
    test eax, eax
    jz .fail
    LOG_INFO "memory: arenas reserved (perm 1 GB, frame 64 MB, scratch 256 MB)"
    mov eax, 1
.fail:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mem_shutdown — release the global arenas.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC mem_shutdown, 0
    mov rax, [rel g_arena_perm + ARENA.peak]
    LOG_VAL LOG_LEVEL_INFO, "memory: perm arena peak bytes", rax
    mov rax, [rel g_arena_frame + ARENA.peak]
    LOG_VAL LOG_LEVEL_INFO, "memory: frame arena peak bytes", rax
    mov rax, [rel g_arena_scratch + ARENA.peak]
    LOG_VAL LOG_LEVEL_INFO, "memory: scratch arena peak bytes", rax
    lea rcx, [rel g_arena_perm]
    call arena_release
    lea rcx, [rel g_arena_frame]
    call arena_release
    lea rcx, [rel g_arena_scratch]
    call arena_release
    RETURN
ENDPROC
