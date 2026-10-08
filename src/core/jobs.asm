; =============================================================================
; jobs.asm — worker threads and a lock-free job queue.
;
; Queue: bounded multi-producer/multi-consumer ring (Dmitry Vyukov's
; algorithm): each cell carries a sequence number; producers and consumers
; claim positions with a CAS on tail/head, so neither side ever takes a lock.
; On x86 (TSO) the plain stores of the job data become visible before the
; following store of the cell's sequence number, which publishes it.
;
; Workers sleep on a semaphore when there is no work. g_sleeping counts
; sleepers that have not been woken yet. A submitter that sees g_sleeping > 0
; *claims* one sleeper (CAS g_sleeping -1) and releases one semaphore token,
; so a burst of submits costs at most one wake-up per sleeping worker instead
; of one syscall per job. Dekker-style ordering: the submitter fences between
; publishing the job and reading g_sleeping; a sleeper registers with a
; locked increment and then re-checks the queue. If work appeared, it tries
; to unregister; if a submitter already claimed it (count hit 0), it consumes
; the token that was released for it.
;
; Public API (see include/jobs.inc):
;   jobs_init(ecx = workers, 0 = auto: logical CPUs - 1) -> eax 1/0
;   jobs_shutdown()
;   job_submit(rcx = fn, rdx = arg, r8 = counter* or 0)
;   job_dispatch(rcx = fn, edx = count, r8 = counter* or 0)
;                                   parallel-for: count jobs, arg = 0..count-1
;   job_wait(rcx = counter*)        the calling thread runs jobs meanwhile
;   job_queue_depth() -> rax
;   g_job_worker_count, g_jobs_completed, g_job_contexts (WORKER array)
; =============================================================================
%define JOBS_IMPL
%include "macros.inc"
%include "log.inc"
%include "jobs.inc"

global jobs_init, jobs_shutdown, job_submit, job_dispatch, job_wait, job_queue_depth
global g_job_worker_count, g_jobs_completed, g_job_contexts

extern g_cpu_logical

IMPORT CreateThread, WaitForSingleObject, CloseHandle
IMPORT CreateSemaphoreA, ReleaseSemaphore
IMPORT TlsAlloc, TlsFree, TlsSetValue, TlsGetValue
IMPORT SetThreadDescription

%define QUEUE_CAPACITY  4096            ; power of two
%define QUEUE_MASK      (QUEUE_CAPACITY - 1)
%define INFINITE        0xFFFFFFFF
%define SPIN_COUNT      2048            ; pause loops (~50-100 us) before sleeping
%define DISPATCH_WAKE   64              ; job_dispatch wakes sleepers every N jobs
%define WORKER_SCRATCH  MB(64)

struc CELL                              ; 32 bytes
    .seq        resq 1
    .fn         resq 1
    .arg        resq 1
    .counter    resq 1
endstruc

section .rdata
name_scratch:   db "job scratch", 0
; L"VoxelB worker" (UTF-16 thread name, shown by debuggers/profilers)
thread_name:    dw 'V','o','x','e','l','B',' ','w','o','r','k','e','r', 0
str_worker:     db "jobs: worker ", 0
str_ran:        db " ran ", 0
str_jobs:       db " jobs", 0

section .bss
alignb 64
g_queue_tail:       resq 8              ; own cache line
g_queue_head:       resq 8              ; own cache line
g_sleeping:         resq 8              ; own cache line
g_jobs_completed:   resq 8              ; own cache line
alignb 64
g_queue:            resb QUEUE_CAPACITY * CELL_size
alignb 128
g_job_contexts:     resb (MAX_WORKERS + 1) * WORKER_size
alignb 8
g_job_semaphore:    resq 1
g_job_worker_count: resd 1
g_job_quit:         resd 1
g_job_tls:          resd 1

section .text

; -----------------------------------------------------------------------------
; queue_push — enqueue a job.
;   in:  rcx = fn, rdx = arg, r8 = counter
;   out: eax = 1 if queued, 0 if the queue is full
;   clobbers: rax, r9, r10, r11
; -----------------------------------------------------------------------------
queue_push:
    mov r9, [rel g_queue_tail]          ; r9 = pos
.retry:
    mov r10, r9
    and r10, QUEUE_MASK
    shl r10, 5
    lea r11, [rel g_queue]
    add r10, r11                        ; r10 = cell
    mov rax, [r10 + CELL.seq]
    sub rax, r9                         ; dif = seq - pos
    jz .claim
    js .full                            ; seq < pos: still being consumed
    mov r9, [rel g_queue_tail]          ; another producer moved on
    jmp .retry
.claim:
    mov rax, r9
    lea r11, [r9 + 1]
    lock cmpxchg [rel g_queue_tail], r11
    jz .claimed
    mov r9, rax                         ; current tail
    jmp .retry
.claimed:
    mov [r10 + CELL.fn], rcx
    mov [r10 + CELL.arg], rdx
    mov [r10 + CELL.counter], r8
    lea rax, [r9 + 1]
    mov [r10 + CELL.seq], rax           ; publish (release on x86)
    mov eax, 1
    ret
.full:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; queue_pop — dequeue a job.
;   out: eax = 1 and rcx = fn, rdx = arg, r8 = counter; or eax = 0 if empty
;   clobbers: rax, rcx, rdx, r8, r9, r10, r11
; -----------------------------------------------------------------------------
queue_pop:
    mov r9, [rel g_queue_head]          ; r9 = pos
.retry:
    mov r10, r9
    and r10, QUEUE_MASK
    shl r10, 5
    lea r11, [rel g_queue]
    add r10, r11
    mov rax, [r10 + CELL.seq]
    lea r11, [r9 + 1]
    sub rax, r11                        ; dif = seq - (pos + 1)
    jz .claim
    js .empty                           ; not yet published
    mov r9, [rel g_queue_head]
    jmp .retry
.claim:
    mov rax, r9
    lea r11, [r9 + 1]
    lock cmpxchg [rel g_queue_head], r11
    jz .claimed
    mov r9, rax
    jmp .retry
.claimed:
    mov rcx, [r10 + CELL.fn]
    mov rdx, [r10 + CELL.arg]
    mov r8, [r10 + CELL.counter]
    lea rax, [r9 + QUEUE_CAPACITY]
    mov [r10 + CELL.seq], rax           ; free the cell for the next lap
    mov eax, 1
    ret
.empty:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; job_queue_depth — approximate number of queued jobs.
;   out: rax
;   clobbers: rax
; -----------------------------------------------------------------------------
job_queue_depth:
    mov rax, [rel g_queue_tail]
    sub rax, [rel g_queue_head]
    jns .ok
    xor eax, eax
.ok:
    ret

; -----------------------------------------------------------------------------
; run_job — execute one job on a thread context and signal completion.
;   in:  rcx = fn, rdx = arg, r8 = counter (or 0), r9 = WORKER*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC run_job, 0, rbx, rsi
    mov rbx, r9
    mov rsi, r8
    mov rax, rcx
    mov rcx, rdx
    mov rdx, rbx
    call rax                            ; fn(arg, worker)
    lea rcx, [rbx + WORKER.scratch]
    call arena_reset
    inc qword [rbx + WORKER.jobs_done]
    lock inc qword [rel g_jobs_completed]
    test rsi, rsi
    jz .done
    lock dec qword [rsi]                ; full barrier: results are visible
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; try_run_one — pop and run one job, if any.
;   in:  rcx = WORKER* of the calling thread
;   out: eax = 1 if a job ran, 0 if the queue was empty
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC try_run_one, 0, rbx
    mov rbx, rcx
    call queue_pop
    test eax, eax
    jz .none
    mov r9, rbx
    call run_job
    mov eax, 1
.none:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; current_context — WORKER* of the calling thread (main thread's if unset).
;   out: rax
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC current_context, 0
    mov ecx, [rel g_job_tls]
    API TlsGetValue, rcx
    test rax, rax
    jnz .ok
    lea rax, [rel g_job_contexts]
.ok:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; job_submit — queue a job (any thread). If the queue is full, the job runs
; immediately on the calling thread instead (natural back-pressure).
;   in:  rcx = fn, rdx = arg, r8 = counter* (or 0)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC job_submit, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    test rdi, rdi
    jz .no_counter
    lock inc qword [rdi]
.no_counter:
    call queue_push
    test eax, eax
    jz .inline
    mov ecx, 1
    call wake_sleepers
    RETURN
.inline:
    call current_context
    mov r9, rax
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call run_job
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; wake_sleepers — after publishing jobs: claim up to `max` sleeping workers
; and wake them with a single semaphore release.
;   in:  ecx = max workers to wake
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC wake_sleepers, 0
    mfence                              ; publish jobs before reading sleepers
    mov r8d, ecx
    mov rax, [rel g_sleeping]
.claim:
    test rax, rax
    jz .done                            ; nobody asleep: someone will find it
    mov rdx, rax
    cmp rdx, r8
    jbe .k_ok
    mov rdx, r8                         ; k = min(sleeping, max)
.k_ok:
    mov rcx, rax
    sub rcx, rdx
    lock cmpxchg [rel g_sleeping], rcx  ; rax reloaded on failure
    jne .claim
    API ReleaseSemaphore, [rel g_job_semaphore], rdx, 0
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; job_dispatch — parallel-for: queue `count` jobs fn(i, worker) for
; i = 0..count-1, waking sleeping workers in batches (one syscall per
; DISPATCH_WAKE jobs at most, instead of one per job).
;   in:  rcx = fn, edx = count, r8 = counter* (or 0)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC job_dispatch, 0, rbx, rsi, rdi, r12, r13
    mov rbx, rcx                        ; fn
    mov r12d, edx                       ; count
    mov rdi, r8                         ; counter
    test rdi, rdi
    jz .no_counter
    lock add [rdi], r12
.no_counter:
    xor esi, esi                        ; index
.next:
    cmp esi, r12d
    jae .finish
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call queue_push
    test eax, eax
    jnz .pushed
    ; queue full: wake everyone and run this one here
    mov ecx, MAX_WORKERS
    call wake_sleepers
    call current_context
    mov r9, rax
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call run_job
.pushed:
    inc esi
    mov eax, esi
    and eax, DISPATCH_WAKE - 1
    jnz .next
    mov ecx, MAX_WORKERS
    call wake_sleepers
    jmp .next
.finish:
    mov ecx, MAX_WORKERS
    call wake_sleepers
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; job_wait — wait until a counter reaches zero, running queued jobs on the
; calling thread meanwhile (so waiting never wastes a core or deadlocks).
;   in:  rcx = counter*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC job_wait, 0, rbx, rsi
    mov rbx, rcx
    call current_context
    mov rsi, rax
.loop:
    cmp qword [rbx], 0
    je .done
    mov rcx, rsi
    call try_run_one
    test eax, eax
    jnz .loop
    pause
    jmp .loop
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; worker_main — thread procedure of a worker.
;   in:  rcx = WORKER*
;   out: eax = 0 (thread exit code)
; -----------------------------------------------------------------------------
PROC worker_main, 0, rbx, rsi
    mov rbx, rcx
    mov ecx, [rel g_job_tls]
    API TlsSetValue, rcx, rbx
    API SetThreadDescription, -2, thread_name   ; -2 = GetCurrentThread()
.loop:
    cmp dword [rel g_job_quit], 0
    jne .exit
    mov rcx, rbx
    call try_run_one
    test eax, eax
    jnz .loop
    ; brief spin before sleeping: new work often arrives in bursts
    mov esi, SPIN_COUNT
.spin:
    pause
    call job_queue_depth
    test rax, rax
    jnz .loop
    dec esi
    jnz .spin
    lock inc qword [rel g_sleeping]     ; register (full barrier), re-check
    call job_queue_depth
    test rax, rax
    jnz .unregister
    cmp dword [rel g_job_quit], 0
    jne .unregister
.sleep:
    ; a submitter (or shutdown) claims us and releases a token
    API WaitForSingleObject, [rel g_job_semaphore], INFINITE
    jmp .loop
.unregister:
    mov rax, [rel g_sleeping]
.unreg_retry:
    test rax, rax
    jz .sleep                           ; already claimed: take our token
    lea rcx, [rax - 1]
    lock cmpxchg [rel g_sleeping], rcx
    jne .unreg_retry
    jmp .loop
.exit:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; jobs_init — start the worker threads.
;   in:  ecx = worker count (0 = logical processors - 1, at least 1)
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC jobs_init, 0, rbx, rsi, rdi
    mov esi, ecx
    test esi, esi
    jnz .count_given
    mov esi, [rel g_cpu_logical]
    dec esi
.count_given:
    cmp esi, 1
    jge .min_ok
    mov esi, 1
.min_ok:
    cmp esi, MAX_WORKERS
    jle .max_ok
    mov esi, MAX_WORKERS
.max_ok:
    mov [rel g_job_worker_count], esi

    ; queue cells start with seq = index
    lea rax, [rel g_queue]
    xor ecx, ecx
.init_cells:
    mov [rax + CELL.seq], rcx
    add rax, CELL_size
    inc ecx
    cmp ecx, QUEUE_CAPACITY
    jb .init_cells
    xor eax, eax
    mov [rel g_queue_head], rax
    mov [rel g_queue_tail], rax
    mov [rel g_sleeping], rax
    mov [rel g_jobs_completed], rax
    mov [rel g_job_quit], eax

    API TlsAlloc
    mov [rel g_job_tls], eax
    API CreateSemaphoreA, 0, 0, 0x7FFFFFFF, 0
    mov [rel g_job_semaphore], rax
    test rax, rax
    jnz .sem_ok
    LOG_ERROR "jobs: CreateSemaphore failed"
    xor eax, eax
    RETURN
.sem_ok:
    ; context 0 = main thread
    xor edi, edi
.contexts:
    mov eax, edi
    imul eax, eax, WORKER_size
    lea rbx, [rel g_job_contexts]
    add rbx, rax
    mov [rbx + WORKER.index], edi
    mov qword [rbx + WORKER.thread], 0
    mov qword [rbx + WORKER.jobs_done], 0
    lea rcx, [rbx + WORKER.scratch]
    lea r8, [rel name_scratch]
    INVOKE arena_init, rcx, WORKER_SCRATCH, r8
    test eax, eax
    jz .fail
    test edi, edi
    jnz .spawn
    mov ecx, [rel g_job_tls]
    API TlsSetValue, rcx, rbx
    jmp .next
.spawn:
    lea r8, [rel worker_main]
    API CreateThread, 0, 0, r8, rbx, 0, 0
    mov [rbx + WORKER.thread], rax
    test rax, rax
    jnz .next
    LOG_ERROR "jobs: CreateThread failed"
    jmp .fail
.next:
    inc edi
    cmp edi, esi
    jbe .contexts
    LOG_VAL LOG_LEVEL_INFO, "jobs: worker threads started:", rsi
    mov eax, 1
    RETURN
.fail:
    mov [rel g_job_worker_count], edi   ; only shut down what started
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; jobs_shutdown — stop and join all workers (queued jobs are dropped).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC jobs_shutdown, 0, rbx, rsi, rdi
    mov dword [rel g_job_quit], 1
    mov esi, [rel g_job_worker_count]
    mfence
    ; wake every worker; spare tokens are harmless (the semaphore is closed)
    API ReleaseSemaphore, [rel g_job_semaphore], rsi, 0
    xor edi, edi
.join:
    mov eax, edi
    imul eax, eax, WORKER_size
    lea rbx, [rel g_job_contexts]
    add rbx, rax
    mov rcx, [rbx + WORKER.thread]
    test rcx, rcx
    jz .no_thread
    API WaitForSingleObject, rcx, INFINITE
    API CloseHandle, [rbx + WORKER.thread]
    mov qword [rbx + WORKER.thread], 0
.no_thread:
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_worker]
    call log_append_str
    mov ecx, edi
    call log_append_dec
    lea rcx, [rel str_ran]
    call log_append_str
    mov rcx, [rbx + WORKER.jobs_done]
    call log_append_dec
    lea rcx, [rel str_jobs]
    call log_append_str
    call log_end
    lea rcx, [rbx + WORKER.scratch]
    call arena_release
    inc edi
    cmp edi, esi
    jbe .join
    API CloseHandle, [rel g_job_semaphore]
    mov ecx, [rel g_job_tls]
    API TlsFree, rcx
    RETURN
ENDPROC
