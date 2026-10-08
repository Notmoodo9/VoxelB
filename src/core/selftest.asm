; =============================================================================
; selftest.asm — start-up self test of arenas, pools and the job system.
; Runs in debug builds and with --selftest (CI). Logs "selftest: PASS" or the
; failures; never shows a dialog.
;
;   1. arenas: alignment, mark/reset, refusing allocations past the reserve
;   2. jobs:   job_dispatch of COMPUTE_JOBS jobs of xorshift work (~10-20 us
;              each), results compared with a serial run on the main thread
;              (gives the parallel speed-up)
;   3. pools:  POOL_JOBS jobs submitted one by one (job_submit) that each
;              allocate, fill, verify and free
;              blocks concurrently (lock-free pool under contention), plus
;              worker scratch-arena use
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "jobs.inc"

global selftest_run

extern timer_elapsed_us, str_append_dec

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

section .bss
alignb 64
g_test_pool:        resb POOL_size
alignb 8
g_test_arena:       resb ARENA_size
g_results:          resq 1              ; COMPUTE_JOBS qwords (main scratch)
g_errors:           resq 1
g_counter:          resq 1
g_numbuf:           resb 32

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
