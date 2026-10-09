; =============================================================================
; selftest.asm — start-up self test of arenas, pools and the job system.
; Runs in debug builds and with --selftest (CI). Logs "selftest: PASS" or the
; failures; never shows a dialog.
;
;   1. arenas: alignment, mark/reset, refusing allocations past the reserve
;   2. jobs:   job_dispatch of COMPUTE_JOBS jobs of xorshift work (~10-20 us
;              each), results compared with a serial run on the main thread
;              (gives the parallel speed-up)
;   4. sections: palette compression at every bit width (1/2/4/8/16):
;              build from arrays with 1..300 distinct ids, compare every
;              block via section_get and section_decode, then 3000 random
;              section_set calls growing a uniform section to raw 16-bit,
;              checked against a shadow array
;   3. pools:  POOL_JOBS jobs submitted one by one (job_submit) that each
;              allocate, fill, verify and free
;              blocks concurrently (lock-free pool under contention), plus
;              worker scratch-arena use
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "jobs.inc"
%include "section.inc"

global selftest_run

extern timer_elapsed_us, str_append_dec
extern mesh_section, g_block_opaque
extern gpu_alloc_init, gpu_alloc, gpu_free, g_gpu_units_used
extern world_hash_selftest, png_decode

%define COMPUTE_JOBS        4096
%define COMPUTE_ITERS       8000
%define POOL_JOBS           8192
%define BLOCKS_PER_JOB      8
%define POOL_BLOCK          256

section .rdata
name_test_arena:    db "selftest arena", 0
name_test_pool:     db "selftest pool", 0
str_serial:         db "selftest: serial compute us ", 0
str_parallel:       db ", parallel us ", 0
str_speedup:        db ", speed-up ", 0
str_x:              db "x", 0
str_threads:        db " with threads ", 0
str_pool:           db "selftest: pool storm ", 0
str_pool_jobs:      db " jobs, fresh blocks used ", 0
str_pool_us:        db ", us ", 0
str_sect_fail:      db "selftest: section mismatch, distinct ids ", 0
str_sect_bits:      db ", bits ", 0
str_mesh_case:      db "selftest: mesher case ", 0
str_mesh_got:       db " quads ", 0
str_mesh_want:      db " expected ", 0
str_mesh_first:     db " first quad ", 0
align 4
sect_variants:      dd 1, 2, 3, 17, 200, 300     ; distinct ids per test
sect_expect_bits:   dd 0, 1, 2, 8, 8, 16

section .bss
alignb 64
g_test_pool:        resb POOL_size
alignb 8
g_test_arena:       resb ARENA_size
g_results:          resq 1              ; COMPUTE_JOBS qwords (main scratch)
g_errors:           resq 1
g_counter:          resq 1
g_numbuf:           resb 32
alignb 8
g_nb_tmp:           resq 6

section .text

; -----------------------------------------------------------------------------
; compute_value — deterministic busy work.
;   in:  rcx = index      out: rax = value
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
compute_value:
    mov rax, 0x9E3779B97F4A7C15
    imul rax, rcx
    inc rax
    mov ecx, COMPUTE_ITERS
.loop:
    mov rdx, rax
    shl rdx, 13
    xor rax, rdx
    mov rdx, rax
    shr rdx, 7
    xor rax, rdx
    mov rdx, rax
    shl rdx, 17
    xor rax, rdx
    dec ecx
    jnz .loop
    ret

; -----------------------------------------------------------------------------
; job_compute — job: results[arg] = compute_value(arg).
;   in:  rcx = index, rdx = WORKER*
; -----------------------------------------------------------------------------
PROC job_compute, 0, rbx
    mov rbx, rcx
    call compute_value
    mov rcx, [rel g_results]
    mov [rcx + rbx * 8], rax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; job_pool_storm — job: allocate BLOCKS_PER_JOB pool blocks, stamp, verify,
; free; also allocate from the worker's scratch arena.
;   in:  rcx = job id, rdx = WORKER*
; -----------------------------------------------------------------------------
PROC job_pool_storm, BLOCKS_PER_JOB * 8, rbx, rsi, rdi, r12
    mov r12, rcx                        ; job id
    lea rcx, [rdx + WORKER.scratch]
    INVOKE arena_try_alloc, rcx, 1024, 64
    test rax, rax
    jz .error
    test al, 63
    jnz .error
    mov [rax], r12                      ; touch it
    xor esi, esi
.alloc:
    lea rcx, [rel g_test_pool]
    call pool_alloc
    test rax, rax
    jz .error
    mov [LOCAL(0) + rsi * 8], rax
    mov rdx, r12
    shl rdx, 8
    or rdx, rsi                         ; stamp = id << 8 | k
    mov [rax + 8], rdx
    mov [rax + POOL_BLOCK - 8], rdx
    inc esi
    cmp esi, BLOCKS_PER_JOB
    jb .alloc
    xor esi, esi
.verify:
    mov rax, [LOCAL(0) + rsi * 8]
    mov rdx, r12
    shl rdx, 8
    or rdx, rsi
    cmp [rax + 8], rdx
    jne .error_free
    cmp [rax + POOL_BLOCK - 8], rdx
    jne .error_free
    inc esi
    cmp esi, BLOCKS_PER_JOB
    jb .verify
    jmp .free
.error_free:
    lock inc qword [rel g_errors]
.free:
    xor esi, esi
.free_loop:
    lea rcx, [rel g_test_pool]
    mov rdx, [LOCAL(0) + rsi * 8]
    call pool_free
    inc esi
    cmp esi, BLOCKS_PER_JOB
    jb .free_loop
    RETURN
.error:
    lock inc qword [rel g_errors]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; test_arenas — arena behaviour checks.
;   out: eax = 1 pass / 0 fail (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC test_arenas, 0, rbx, rsi
    lea rbx, [rel g_test_arena]
    lea r8, [rel name_test_arena]
    INVOKE arena_init, rbx, MB(1), r8
    test eax, eax
    jz .fail
    INVOKE arena_try_alloc, rbx, 100, 16
    test rax, rax
    jz .fail
    test al, 15
    jnz .fail
    INVOKE arena_try_alloc, rbx, 1, 4096
    test rax, rax
    jz .fail
    test eax, 4095
    jnz .fail
    mov rcx, rbx
    call arena_mark
    mov rsi, rax
    INVOKE arena_try_alloc, rbx, KB(200), 8
    test rax, rax
    jz .fail
    mov byte [rax + KB(200) - 1], 0x5A  ; committed on demand: writable
    INVOKE arena_reset_to, rbx, rsi
    cmp [rbx + ARENA.used], rsi
    jne .fail
    INVOKE arena_try_alloc, rbx, MB(2), 8
    test rax, rax
    jnz .fail                           ; must refuse: beyond the reserve
    ; shared (atomic) allocations must return base + offset exactly, even
    ; at unaligned offsets inside a page
    mov qword [rbx + ARENA.used], 24    ; unaligned start
    INVOKE arena_alloc_shared, rbx, 24
    mov rcx, [rbx + ARENA.base]
    add rcx, 24
    cmp rax, rcx
    jne .fail
    mov rsi, rax
    INVOKE arena_alloc_shared, rbx, 8
    lea rcx, [rsi + 32]                 ; 24 rounded up to 16 -> 32
    cmp rax, rcx
    jne .fail
    mov qword [rax], 0x1234             ; committed: writable
    mov rcx, rbx
    call arena_release
    LOG_INFO "selftest: arenas ok"
    mov eax, 1
    RETURN
.fail:
    LOG_ERROR "selftest: arena check failed"
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; test_compute — parallel vs serial compute.
;   out: eax = 1 pass / 0 fail (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC test_compute, 0, rbx, rsi, rdi, r12, r13
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov r13, rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, COMPUTE_JOBS * 8, 64
    test rax, rax
    jz .fail
    mov [rel g_results], rax

    ; serial reference (not stored: summed into rdi)
    call timer_elapsed_us
    mov r12, rax
    xor ebx, ebx
    xor edi, edi
.serial:
    mov rcx, rbx
    call compute_value
    add rdi, rax
    inc ebx
    cmp ebx, COMPUTE_JOBS
    jb .serial
    call timer_elapsed_us
    sub rax, r12
    mov r12, rax                        ; r12 = serial us

    ; parallel
    call timer_elapsed_us
    mov rsi, rax
    mov qword [rel g_counter], 0
    lea rcx, [rel job_compute]
    lea r8, [rel g_counter]
    INVOKE job_dispatch, rcx, COMPUTE_JOBS, r8
    lea rcx, [rel g_counter]
    call job_wait
    call timer_elapsed_us
    sub rax, rsi
    mov rsi, rax                        ; rsi = parallel us

    ; compare: the parallel results must sum to the serial checksum, and
    ; each must match its own recomputation (spot check every 64th)
    mov rcx, [rel g_results]
    xor eax, eax
    xor ebx, ebx
.sum:
    add rax, [rcx + rbx * 8]
    inc ebx
    cmp ebx, COMPUTE_JOBS
    jb .sum
    cmp rax, rdi
    jne .mismatch
    xor ebx, ebx
.spot:
    mov rcx, rbx
    call compute_value
    mov rcx, [rel g_results]
    cmp rax, [rcx + rbx * 8]
    jne .mismatch
    add ebx, 64
    cmp ebx, COMPUTE_JOBS
    jb .spot

    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_serial]
    call log_append_str
    mov rcx, r12
    call log_append_dec
    lea rcx, [rel str_parallel]
    call log_append_str
    mov rcx, rsi
    call log_append_dec
    lea rcx, [rel str_speedup]
    call log_append_str
    ; speed-up with 2 decimals
    mov rax, r12
    imul rax, rax, 100
    xor edx, edx
    test rsi, rsi
    jz .no_div
    div rsi
.no_div:
    lea rcx, [rel g_numbuf]
    INVOKE str_append_dec, rcx, rax, 2
    lea rcx, [rel g_numbuf]
    call log_append_str
    lea rcx, [rel str_x]
    call log_append_str
    lea rcx, [rel str_threads]
    call log_append_str
    mov ecx, [rel g_job_worker_count]
    inc ecx                             ; + main thread (helps in job_wait)
    call log_append_dec
    call log_end
    LOG_INFO "selftest: parallel results match serial"
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, r13
    mov eax, 1
    RETURN
.mismatch:
    LOG_ERROR "selftest: parallel compute results differ from serial"
.fail:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, r13
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; test_pool — concurrent pool alloc/free storm.
;   out: eax = 1 pass / 0 fail (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC test_pool, 0, rbx, rsi
    lea rcx, [rel g_test_pool]
    lea rax, [rel name_test_pool]
    mov [rsp + 32], rax
    INVOKE pool_init, rcx, POOL_BLOCK, 65536, 256
    test eax, eax
    jz .fail
    mov qword [rel g_errors], 0
    mov qword [rel g_counter], 0
    call timer_elapsed_us
    mov rsi, rax
    xor ebx, ebx
.submit:
    lea rcx, [rel job_pool_storm]
    lea r8, [rel g_counter]
    INVOKE job_submit, rcx, rbx, r8
    inc ebx
    cmp ebx, POOL_JOBS
    jb .submit
    lea rcx, [rel g_counter]
    call job_wait
    call timer_elapsed_us
    sub rax, rsi
    mov rsi, rax

    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_pool]
    call log_append_str
    mov ecx, POOL_JOBS
    call log_append_dec
    lea rcx, [rel str_pool_jobs]
    call log_append_str
    mov rcx, [rel g_test_pool + POOL.bump]
    call log_append_dec
    lea rcx, [rel str_pool_us]
    call log_append_str
    mov rcx, rsi
    call log_append_dec
    call log_end

    cmp qword [rel g_errors], 0
    jne .corrupt
    cmp qword [rel g_test_pool + POOL.in_use], 0
    jne .leak
    lea rcx, [rel g_test_pool]
    call pool_release
    LOG_INFO "selftest: pool ok (no corruption, no leaks)"
    mov eax, 1
    RETURN
.corrupt:
    mov rax, [rel g_errors]
    LOG_VAL LOG_LEVEL_ERROR, "selftest: pool corruption / allocation errors:", rax
    jmp .fail
.leak:
    mov rax, [rel g_test_pool + POOL.in_use]
    LOG_VAL LOG_LEVEL_ERROR, "selftest: pool blocks still in use:", rax
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; test_sections — palette compression round trips and growth.
;   out: eax = 1 pass / 0 fail (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC test_sections, 16, rbx, rsi, rdi, r12, r13, r14, r15
    call sections_init
    test eax, eax
    jz .fail_plain
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, SECTION_VOLUME * 2, 64
    mov r12, rax                        ; ids / shadow
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, SECTION_VOLUME * 2, 64
    mov r13, rax                        ; decode buffer
    test r12, r12
    jz .fail
    test r13, r13
    jz .fail

    ; ---- all air -> no section ---------------------------------------------------
    mov rdi, r12
    xor eax, eax
    mov ecx, SECTION_VOLUME * 2 / 8
    rep stosq
    INVOKE section_build, r12, 0, 0, 0
    test rax, rax
    jnz .fail

    ; ---- variants ----------------------------------------------------------------
    xor r14d, r14d                      ; variant
.variant:
    lea rax, [rel sect_variants]
    mov r15d, [rax + r14 * 4]           ; distinct ids
    xor ecx, ecx
.fill:
    ; id = (i * 7919 + i/37) mod n + 1   (every id appears)
    mov eax, ecx
    imul eax, eax, 7919
    mov edx, ecx
    shr edx, 5
    add eax, edx
    xor edx, edx
    div r15d
    inc edx
    mov [r12 + rcx * 2], dx
    inc ecx
    cmp ecx, SECTION_VOLUME
    jb .fill
    INVOKE section_build, r12, 1, 2, 3
    test rax, rax
    jz .variant_fail
    mov rbx, rax
    movzx eax, byte [rbx + SECT.bits]
    lea rcx, [rel sect_expect_bits]
    cmp eax, [rcx + r14 * 4]
    jne .variant_fail_free
    xor esi, esi
.check_get:
    mov rcx, rbx
    mov edx, esi
    call section_get
    cmp ax, [r12 + rsi * 2]
    jne .variant_fail_free
    inc esi
    cmp esi, SECTION_VOLUME
    jb .check_get
    INVOKE section_decode, rbx, r13
    mov rsi, r12
    mov rdi, r13
    mov ecx, SECTION_VOLUME * 2
    repe cmpsb
    jne .variant_fail_free
    mov rcx, rbx
    call section_free
    inc r14d
    cmp r14d, 6
    jb .variant

    ; ---- growth through section_set ------------------------------------------------
    mov ecx, 5
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call section_make_uniform
    test rax, rax
    jz .fail
    mov rbx, rax
    mov rdi, r12
    mov eax, 5
    mov ecx, SECTION_VOLUME
    rep stosw                           ; shadow = 5 everywhere
    mov r15d, 12345                     ; LCG state
    xor r14d, r14d
.set_loop:
    imul r15d, r15d, 1103515245
    add r15d, 12345
    mov esi, r15d
    shr esi, 8
    and esi, SECTION_VOLUME - 1         ; index
    imul r15d, r15d, 1103515245
    add r15d, 12345
    mov edi, r15d
    shr edi, 8
    xor edx, edx
    mov eax, edi
    mov ecx, 600
    div ecx
    lea edi, [edx + 1]                  ; id 1..600
    mov [r12 + rsi * 2], di
    lea r9, [rel g_arena_scratch]
    INVOKE section_set, rbx, rsi, rdi, r9
    test eax, eax
    jz .grow_fail
    inc r14d
    cmp r14d, 3000
    jb .set_loop
    xor esi, esi
.check_grow:
    mov rcx, rbx
    mov edx, esi
    call section_get
    cmp ax, [r12 + rsi * 2]
    jne .grow_fail
    inc esi
    cmp esi, SECTION_VOLUME
    jb .check_grow
    cmp byte [rbx + SECT.bits], 16
    jne .grow_fail                      ; > 256 distinct ids: must be raw
    mov rcx, rbx
    call section_free
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    LOG_INFO "selftest: sections ok (palettes 1/2/4/8/16-bit, growth via set)"
    mov eax, 1
    RETURN

.variant_fail_free:
    mov rcx, rbx
    call section_free
.variant_fail:
    mov ecx, LOG_LEVEL_ERROR
    call log_begin
    lea rcx, [rel str_sect_fail]
    call log_append_str
    mov ecx, r15d
    call log_append_dec
    call log_end
    jmp .fail
.grow_fail:
    LOG_ERROR "selftest: section_set growth produced wrong blocks"
.fail:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
.fail_plain:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mesh_case — mesh a section with all 6 neighbours set to one value and
; compare the quad count.
;   in:  rcx = SECT*, rdx = neighbour value, r8 = expected count,
;        r9 = case number, ARG 5 = quad buffer
;   out: eax = 1 if the count matched (mismatch logged with the first quad)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC mesh_case, 48, rbx, rsi, rdi, r12
    mov rbx, rcx
    mov rsi, r8
    mov rdi, r9
    mov r12, [ARG(5)]
    xor eax, eax
.fill_nb:
    mov [LOCAL(0) + rax * 8], rdx
    inc eax
    cmp eax, 6
    jb .fill_nb
    lea rdx, [LOCAL(0)]
    lea r9, [rel g_arena_scratch]
    INVOKE mesh_section, rbx, rdx, r12, r9
    cmp rax, rsi
    je .ok
    mov rbx, rax
    mov ecx, LOG_LEVEL_ERROR
    call log_begin
    lea rcx, [rel str_mesh_case]
    call log_append_str
    mov rcx, rdi
    call log_append_dec
    lea rcx, [rel str_mesh_got]
    call log_append_str
    mov rcx, rbx
    call log_append_dec
    lea rcx, [rel str_mesh_want]
    call log_append_str
    mov rcx, rsi
    call log_append_dec
    lea rcx, [rel str_mesh_first]
    call log_append_str
    mov rcx, [r12]
    call log_append_hex
    call log_end
    xor eax, eax
    RETURN
.ok:
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; test_mesher — exact quad counts for simple configurations.
;   out: eax = 1 pass / 0 fail (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC test_mesher, 16, rbx, rsi, rdi, r12, r13
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rax, [rel g_block_opaque]
    mov byte [rax + 1], 1               ; id 1 opaque (restored at the end)
    mov byte [rax + 0xFFFF], 1
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, 98304 * 8, 64
    mov r12, rax                        ; quad buffer
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, SECTION_VOLUME * 2, 64
    mov r13, rax                        ; ids
    mov ebx, 1                          ; result

    ; case 1: uniform stone, air around -> 6 full faces
    INVOKE section_make_uniform, 1, 0, 0, 0
    mov rsi, rax
    mov [rsp + 32], r12
    INVOKE mesh_case, rsi, 0, 6, 1
    and ebx, eax
    ; case 2: uniform stone, solid around -> nothing (fast path)
    mov [rsp + 32], r12
    INVOKE mesh_case, rsi, NEIGHBOR_SOLID, 0, 2
    and ebx, eax
    mov rcx, rsi
    call section_free

    ; case 3: single block at (5, 6, 7) in air -> 6 unit quads
    mov rdi, r13
    xor eax, eax
    mov ecx, SECTION_VOLUME * 2 / 8
    rep stosq
    mov word [r13 + ((6 << 10) | (7 << 5) | 5) * 2], 1
    INVOKE section_build, r13, 0, 0, 0
    mov rsi, rax
    mov [rsp + 32], r12
    INVOKE mesh_case, rsi, 0, 6, 3
    and ebx, eax
    mov rcx, rsi
    call section_free

    ; case 4: stone with one air cavity at (10, 10, 10), solid around -> 6
    mov rdi, r13
    mov eax, 1
    mov ecx, SECTION_VOLUME
    rep stosw
    mov word [r13 + ((10 << 10) | (10 << 5) | 10) * 2], 0
    INVOKE section_build, r13, 0, 0, 0
    mov rsi, rax
    mov [rsp + 32], r12
    INVOKE mesh_case, rsi, NEIGHBOR_SOLID, 6, 4
    and ebx, eax
    mov rcx, rsi
    call section_free

    ; case 5: bottom half stone (y < 16), air above and around -> 6 quads
    ; (top 32x32, bottom 32x32, 4 sides of 32x16)
    mov rdi, r13
    mov eax, 1
    mov ecx, SECTION_VOLUME / 2
    rep stosw
    xor eax, eax
    mov ecx, SECTION_VOLUME / 2
    rep stosw
    INVOKE section_build, r13, 0, 0, 0
    mov rsi, rax
    mov [rsp + 32], r12
    INVOKE mesh_case, rsi, 0, 6, 5
    and ebx, eax
    mov rcx, rsi
    call section_free

    ; case 6: half-stone section with half-stone side neighbours, solid
    ; below, air above -> exactly 1 quad (the 32x32 top)
    mov rdi, r13
    mov eax, 1
    mov ecx, SECTION_VOLUME / 2
    rep stosw
    xor eax, eax
    mov ecx, SECTION_VOLUME / 2
    rep stosw
    INVOKE section_build, r13, 0, 0, 0
    mov rsi, rax
    mov [LOCAL(8)], rsi
    lea rdi, [rel g_nb_tmp]
    mov [rdi + 0], rsi                  ; -X
    mov [rdi + 8], rsi                  ; +X
    mov qword [rdi + 16], NEIGHBOR_SOLID
    mov qword [rdi + 24], 0             ; +Y air
    mov [rdi + 32], rsi                 ; -Z
    mov [rdi + 40], rsi                 ; +Z
    lea r9, [rel g_arena_scratch]
    INVOKE mesh_section, rsi, rdi, r12, r9
    cmp rax, 1
    je .case6_ok
    mov rsi, rax
    LOG_VAL LOG_LEVEL_ERROR, "selftest: mesher case 6 quads (expected 1):", rsi
    LOG_HEX LOG_LEVEL_ERROR, "selftest: mesher case 6 first quad", [r12]
    xor ebx, ebx
.case6_ok:
    mov rcx, [LOCAL(8)]
    call section_free

    lea rax, [rel g_block_opaque]
    mov byte [rax + 1], 0
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    test ebx, ebx
    jz .fail
    LOG_INFO "selftest: mesher ok (6 cases)"
    mov eax, 1
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; test_gpu_alloc — buddy allocator: 2000 random allocations, distinctness
; and in-range checks, free everything in a scrambled order, then the whole
; space must be one free block again (an allocation of all units succeeds).
;   out: eax = 1 pass / 0 fail (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define GT_N    2000
PROC test_gpu_alloc, 16, rbx, rsi, rdi, r12, r13, r14
    call gpu_alloc_init
    test eax, eax
    jz .fail
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, GT_N * 8, 64
    mov r12, rax                        ; {start, size} as 2 x u32
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, (1 << 18) / 8, 64
    mov r13, rax                        ; ownership bitmap over units
    mov rdi, rax
    xor eax, eax
    mov ecx, (1 << 18) / 64
    rep stosq
    mov r14d, 777                       ; LCG
    xor esi, esi
.alloc:
    imul r14d, r14d, 1103515245
    add r14d, 12345
    mov ecx, r14d
    shr ecx, 16
    and ecx, 63
    inc ecx                             ; 1..64 units
    mov ebx, ecx
    call gpu_alloc
    cmp eax, -1
    je .fail_free
    ; power-of-two size actually reserved
    mov ecx, 1
.pow:
    cmp ecx, ebx
    jae .pow_ok
    shl ecx, 1
    jmp .pow
.pow_ok:
    mov [r12 + rsi * 8], eax
    mov [r12 + rsi * 8 + 4], ecx
    ; mark units; none may be owned already
    mov edx, eax
    add ecx, eax
    cmp ecx, 1 << 18
    ja .fail_free
.mark:
    bts [r13], edx
    jc .fail_free                       ; overlap!
    inc edx
    cmp edx, ecx
    jb .mark
    inc esi
    cmp esi, GT_N
    jb .alloc
    ; free in a scrambled order (stride 7 is coprime with 2000)
    xor esi, esi
    xor edi, edi
.free:
    mov ecx, [r12 + rdi * 8]
    call gpu_free
    add edi, 7
    cmp edi, GT_N
    jb .no_wrap
    sub edi, GT_N
.no_wrap:
    inc esi
    cmp esi, GT_N
    jb .free
    cmp qword [rel g_gpu_units_used], 0
    jne .fail_reset
    mov ecx, 1 << 18
    call gpu_alloc                      ; everything must have merged back
    test eax, eax
    jnz .fail_reset
    mov ecx, eax
    call gpu_free
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    LOG_INFO "selftest: gpu buddy allocator ok (2000 blocks, full re-merge)"
    mov eax, 1
    RETURN
.fail_free:
.fail_reset:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
.fail:
    LOG_ERROR "selftest: gpu buddy allocator failed"
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; test_png — decode the reference PNGs of png_tests.inc (every colour type
; and filter, stored/fixed/dynamic deflate, split IDAT, tRNS) and compare the
; RGBA8 result with the FNV-1a hashes computed by tools/make_png_tests.py.
;   out: eax = 1 pass / 0 fail
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%include "png_tests.inc"
section .text
PROC test_png, 32, rbx, rsi, rdi, r12
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    xor ebx, ebx                        ; test index
.test:
    cmp ebx, PNG_TEST_COUNT
    jae .pass
    imul rsi, rbx, 32
    lea rax, [rel png_tests]
    add rsi, rax                        ; entry
    lea r8, [LOCAL(8)]
    lea r9, [rel g_arena_scratch]
    INVOKE png_decode, [rsi], [rsi + 8], r8, r9
    test rax, rax
    jz .fail
    mov r12, rax                        ; pixels
    mov eax, [LOCAL(8)]
    cmp eax, [rsi + 16]
    jne .fail
    mov ecx, [LOCAL(12)]
    cmp ecx, [rsi + 20]
    jne .fail
    ; FNV-1a over w * h * 4 bytes
    imul ecx, eax
    shl ecx, 2
    mov rdi, r12
    mov edx, 0x811C9DC5
.hash:
    test ecx, ecx
    jz .hashed
    movzx eax, byte [rdi]
    xor edx, eax
    imul edx, edx, 0x01000193
    inc rdi
    dec ecx
    jmp .hash
.hashed:
    cmp edx, [rsi + 24]
    jne .fail
    inc ebx
    jmp .test
.pass:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    LOG_INFO "selftest: png decoder ok (5 images: all colour types, filters, deflate modes)"
    mov eax, 1
    RETURN
.fail:
    LOG_VAL LOG_LEVEL_ERROR, "selftest: png decoder failed on test", rbx
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; selftest_run — run all checks (needs mem_init, jobs_init, timer_init).
;   out: eax = 1 if everything passed, 0 otherwise (failures logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC selftest_run, 0, rbx
    mov ebx, 1
    call test_arenas
    and ebx, eax
    call test_compute
    and ebx, eax
    call test_pool
    and ebx, eax
    call test_sections
    and ebx, eax
    call test_mesher
    and ebx, eax
    call test_gpu_alloc
    and ebx, eax
    call test_png
    and ebx, eax
    call world_hash_selftest
    test eax, eax
    jnz .hash_ok
    LOG_ERROR "selftest: column hash map insert/remove failed"
    xor ebx, ebx
    jmp .hash_done
.hash_ok:
    LOG_INFO "selftest: column hash map ok (3000 keys, backward-shift delete)"
.hash_done:
    test ebx, ebx
    jz .failed
    LOG_INFO "selftest: PASS"
    mov eax, 1
    RETURN
.failed:
    LOG_ERROR "selftest: FAIL"
    xor eax, eax
    RETURN
ENDPROC
