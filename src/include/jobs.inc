; =============================================================================
; jobs.inc — job system interface (implementation: src/core/jobs.asm).
;
; A job is a function  fn(rcx = arg, rdx = WORKER* of the running thread).
; It may use the WORKER's scratch arena freely; the arena is reset after
; every job. Completion is tracked with counters: a qword that job_submit
; increments and the worker decrements when the job has finished (with a
; full barrier, so results written by the job are visible once it reads 0).
; =============================================================================
%ifndef JOBS_INC
%define JOBS_INC

%include "memory.inc"

%define MAX_WORKERS     31

struc WORKER                            ; one per thread; 128-byte aligned
    .index      resd 1                  ; 0 = main thread, 1.. = workers
    .pad0       resd 1
    .thread     resq 1                  ; thread handle (0 for main)
    .jobs_done  resq 1
    .scratch    resb ARENA_size
    .pad1       resb 128 - 24 - ARENA_size
endstruc

%ifndef JOBS_IMPL
extern jobs_init, jobs_shutdown, job_submit, job_dispatch, job_wait, job_queue_depth
extern g_job_worker_count, g_jobs_completed, g_job_contexts
%endif

%endif
