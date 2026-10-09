; =============================================================================
; memory.inc — arenas and pools (implementation: src/core/memory.asm).
;
; ARENA: linear allocator over a reserved virtual range, committed on demand
;   in 64 KB steps. Not thread-safe: each arena has one owner thread.
;   Free everything at once with arena_reset / arena_reset_to(mark).
; POOL:  fixed-size blocks, thread-safe and lock-free (Treiber stack with a
;   16-byte compare-and-swap + ABA tag), over a reserved range.
;
; Global arenas (main thread):
;   g_arena_perm     lives until exit (renderer buffers, tables, ...)
;   g_arena_frame    reset at the start of every frame
;   g_arena_scratch  temporary work: take arena_mark, use, arena_reset_to
; Worker threads have their own scratch arena (see jobs.inc).
; =============================================================================
%ifndef MEMORY_INC
%define MEMORY_INC

%define KB(x)   ((x) * 1024)
%define MB(x)   ((x) * 1024 * 1024)
%define GB(x)   ((x) * 1024 * 1024 * 1024)

struc ARENA
    .base       resq 1
    .reserved   resq 1
    .committed  resq 1
    .used       resq 1
    .peak       resq 1
    .name       resq 1
endstruc

struc POOL                              ; must be 16-byte aligned
    .free_ptr       resq 1              ; free list head  } updated together
    .free_tag       resq 1              ; ABA counter     } by cmpxchg16b
    .base           resq 1
    .block_size     resq 1
    .max_blocks     resq 1
    .bump           resq 1              ; blocks handed out from fresh memory
    .in_use         resq 1
    .precommitted   resq 1              ; blocks committed at init
    .name           resq 1
    .pad            resq 7              ; 128 bytes: keep pools apart
endstruc

%ifndef MEMORY_IMPL
extern mem_init, mem_shutdown
extern arena_init, arena_release, arena_alloc, arena_try_alloc
extern arena_mark, arena_reset_to, arena_reset
extern pool_init, pool_release, pool_alloc, pool_free
extern arena_alloc_shared
extern g_arena_perm, g_arena_frame, g_arena_scratch, g_mem_committed
%endif

%endif
