; =============================================================================
; stream.asm — infinite world streaming around the camera.
;
; Every frame (stream_update, main thread, never waits on jobs):
;   1. walk the loaded columns: upload finished meshes to the GPU (byte
;      budget per frame), unload columns beyond render distance + 3 whose
;      jobs are done (busy == 0), count work in flight;
;   2. walk a spiral of chunk offsets sorted by distance (nearest first):
;      create + queue generation for missing columns within distance + 1,
;      queue meshing for generated columns within the render distance whose
;      4 horizontal neighbours are generated (so borders mesh correctly the
;      first time). In-flight jobs are capped so the queue stays short and
;      priorities follow the camera.
; Workers never touch the column map: a mesh job gets its neighbours'
; pointers at submit time, and the busy counters keep those columns alive.
;
; Public API:
;   stream_init() -> eax 1/0       (settings_load must have run)
;   stream_update()                once per frame, after camera_update
;   stream_shutdown()              waits for in-flight jobs, frees everything
;   g_loaded / g_loaded_count      columns (for drawing: state COL_READY)
;   g_stream_* statistics (render distance: settings.asm)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "jobs.inc"
%include "file.inc"
%include "cfg.inc"
%include "gl.inc"
%include "section.inc"
%include "world_api.inc"

global stream_init, stream_update, stream_shutdown
global g_loaded, g_loaded_count
global g_stream_ready, g_stream_gen_inflight, g_stream_mesh_inflight
global g_stream_update_us, g_stream_update_max_us, g_stream_upload_frame
global g_stream_quads, g_stream_mesh_count, g_stream_mesh_total_us
global g_stream_mesh_max_us, g_stream_cpu_mesh_bytes, g_stream_view_ms

extern timer_elapsed_us, g_render_distance, g_frame_us
extern mesh_section, tint_upload
extern gpu_alloc_init, gpu_alloc, gpu_free, gpu_alloc_units_needed
extern g_quad_buffer, g_cam_pos

IMPORT VirtualAlloc, VirtualFree

%define MAX_LOADED          16384
%define UPLOAD_BUDGET       (2 * 1024 * 1024)   ; bytes per frame
%define STAT_LOG_US         2000000
%define MEM_COMMIT          0x1000
%define MEM_RESERVE         0x2000
%define MEM_RELEASE         0x8000
%define PAGE_READWRITE      0x04

section .rdata
str_view:       db "stream: view complete, columns ", 0
str_after:      db " after ms ", 0
str_stat:       db "stream: loaded ", 0
str_ready:      db " ready ", 0
str_gen:        db " gen ", 0
str_mesh:       db " mesh ", 0
str_quads:      db " gpu quads ", 0
str_update:     db " update max us ", 0
str_mesh_avg:   db " mesh avg us ", 0
str_upd_avg:    db " update avg us ", 0
str_upl:        db " upload total us ", 0
str_upl_max:    db " upload max us ", 0

section .bss
alignb 8
g_loaded:               resq 1          ; COLUMN*[MAX_LOADED]
g_loaded_count:         resq 1
g_spiral:               resq 1          ; {i16 dx, i16 dz}[], sorted by distance
g_spiral_count:         resq 1          ; entries with d^2 <= (R+1)^2
g_spiral_inner:         resq 1          ; entries with d^2 <= R^2
g_stream_inflight:      resq 1          ; job counter for every stream job
g_stream_ready:         resq 1
g_stream_gen_inflight:  resq 1
g_stream_mesh_inflight: resq 1
g_stream_update_us:     resq 1
g_stream_update_max_us: resq 1
g_stream_upload_frame:  resq 1
g_stream_quads:         resq 1          ; quads on the GPU
g_stream_view_ms:       resq 1          ; time until the first full view
g_upd_total_us:         resq 1          ; since the last stats line
g_upd_frames:           resq 1
g_upl_total_us:         resq 1          ; time inside upload_column
g_upl_max_us:           resq 1
g_last_stat_us:         resq 1
g_gpu_full_warned:      resd 1
g_view_logged:          resd 1
alignb 64
g_stream_mesh_count:    resq 1
g_stream_mesh_total_us: resq 1
g_stream_mesh_max_us:   resq 1
g_stream_cpu_mesh_bytes: resq 1

section .text

; -----------------------------------------------------------------------------
; build_spiral — chunk offsets within render distance + 1, sorted by squared
; distance (counting sort), as {i16 dx, i16 dz}.
;   out: eax = 1 on success
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define BSP_COUNTS  0                   ; u32 per d^2 bucket (in scratch)
PROC build_spiral, 16, rbx, rsi, rdi, r12, r13, r14, r15
    mov r12d, [rel g_render_distance]
    lea r13d, [r12d + 1]                ; outer radius
    mov r14d, r13d
    imul r14d, r14d                     ; outer^2
    ; buckets 0 .. outer^2
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea edx, [r14d * 4 + 8]
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, rdx, 16
    test rax, rax
    jz .fail
    mov rbx, rax
    mov rdi, rax
    lea ecx, [r14d + 2]
    xor eax, eax
    rep stosd
    ; count
    mov esi, r13d
    neg esi                             ; dz
.count_z:
    mov edi, r13d
    neg edi                             ; dx
.count_x:
    mov eax, edi
    imul eax, eax
    mov ecx, esi
    imul ecx, ecx
    add eax, ecx
    cmp eax, r14d
    ja .count_next
    inc dword [rbx + rax * 4]
.count_next:
    inc edi
    cmp edi, r13d
    jle .count_x
    inc esi
    cmp esi, r13d
    jle .count_z
    ; prefix sums -> start index per bucket; also total and inner count
    xor eax, eax                        ; running total
    xor ecx, ecx
    mov r15d, r12d
    imul r15d, r15d                     ; inner^2
.prefix:
    cmp ecx, r15d
    jne .not_inner_end
    mov edx, [rbx + rcx * 4]
    add edx, eax
    mov [rel g_spiral_inner], rdx       ; entries with d^2 <= R^2
.not_inner_end:
    mov edx, [rbx + rcx * 4]
    mov [rbx + rcx * 4], eax
    add eax, edx
    inc ecx
    cmp ecx, r14d
    jbe .prefix
    mov [rel g_spiral_count], rax
    ; storage
    lea rdx, [rax * 4]
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, rdx, 16
    test rax, rax
    jz .fail
    mov [rel g_spiral], rax
    mov r15, rax
    ; place
    mov esi, r13d
    neg esi
.place_z:
    mov edi, r13d
    neg edi
.place_x:
    mov eax, edi
    imul eax, eax
    mov ecx, esi
    imul ecx, ecx
    add eax, ecx
    cmp eax, r14d
    ja .place_next
    mov ecx, [rbx + rax * 4]
    inc dword [rbx + rax * 4]
    mov [r15 + rcx * 4], di
    mov [r15 + rcx * 4 + 2], si
.place_next:
    inc edi
    cmp edi, r13d
    jle .place_x
    inc esi
    cmp esi, r13d
    jle .place_z
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    mov eax, 1
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; stream_init — set up the GPU allocator, the loaded list and the spiral.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC stream_init, 0, rbx
    call gpu_alloc_init
    test eax, eax
    jz .fail
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, MAX_LOADED * 8, 64
    mov [rel g_loaded], rax
    test rax, rax
    jz .fail
    mov qword [rel g_loaded_count], 0
    call build_spiral
    test eax, eax
    jz .fail
    mov rax, [rel g_spiral_count]
    LOG_VAL LOG_LEVEL_INFO, "stream: spiral offsets", rax
    call timer_elapsed_us
    mov [rel g_last_stat_us], rax
    mov eax, 1
    RETURN
.fail:
    LOG_ERROR "stream_init failed"
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; mesh_column_job — job: mesh every stored section of a column.
; All quads of the column end up contiguous in the worker's scratch arena
; (each section's output buffer starts where the previous output ended),
; then are copied into one VirtualAlloc block for the main thread.
;   in:  rcx = COLUMN* (nb[] set, busy counters raised), rdx = WORKER*
;   Publishes COL_MESHED last.
; -----------------------------------------------------------------------------
%define MC_NB       0                   ; 6 neighbour pointers
%define MC_T0       48
%define MC_BASE     56                  ; scratch address where quads start
%define MC_TOTAL    64                  ; quads so far
%define MC_MARK     72
%define MC_SY       80
PROC mesh_column_job, 96, rbx, rsi, rdi, r12, r13, r14, r15
    mov rbx, rcx                        ; column
    lea r15, [rdx + WORKER.scratch]
    call timer_elapsed_us
    mov [LOCAL(MC_T0)], rax
    mov rcx, r15
    call arena_mark
    add rax, [r15 + ARENA.base]
    mov [LOCAL(MC_BASE)], rax
    mov qword [LOCAL(MC_TOTAL)], 0
    xor r12d, r12d                      ; sy
.section:
    mov r13, [rbx + COLUMN.sections + r12 * 8]
    test r13, r13
    jz .next
    ; neighbours: -X +X -Y +Y -Z +Z
    mov rax, [rbx + COLUMN.nb + 0]
    mov rax, [rax + COLUMN.sections + r12 * 8]
    mov [LOCAL(MC_NB + 0)], rax
    mov rax, [rbx + COLUMN.nb + 8]
    mov rax, [rax + COLUMN.sections + r12 * 8]
    mov [LOCAL(MC_NB + 8)], rax
    mov rax, NEIGHBOR_SOLID
    test r12d, r12d
    jz .below
    mov rax, [rbx + COLUMN.sections + r12 * 8 - 8]
.below:
    mov [LOCAL(MC_NB + 16)], rax
    xor eax, eax
    cmp r12d, SECTIONS_PER_COLUMN - 1
    je .above
    mov rax, [rbx + COLUMN.sections + r12 * 8 + 8]
.above:
    mov [LOCAL(MC_NB + 24)], rax
    mov rax, [rbx + COLUMN.nb + 16]
    mov rax, [rax + COLUMN.sections + r12 * 8]
    mov [LOCAL(MC_NB + 32)], rax
    mov rax, [rbx + COLUMN.nb + 24]
    mov rax, [rax + COLUMN.sections + r12 * 8]
    mov [LOCAL(MC_NB + 40)], rax

    call timer_elapsed_us
    mov r14, rax                        ; section t0
    mov rcx, r15
    call arena_mark
    mov [LOCAL(MC_MARK)], rax
    INVOKE arena_alloc, r15, MESH_MAX_QUADS * 8, 8
    test rax, rax
    jz .next
    mov rsi, rax                        ; output (= base + total * 8)
    lea rdx, [LOCAL(MC_NB)]
    INVOKE mesh_section, r13, rdx, rsi, r15
    mov rdi, rax                        ; count
    mov [r13 + SECT.quad_opaque], edx
    shr rdx, 32
    mov [r13 + SECT.quad_cutout], edx
    INVOKE arena_reset_to, r15, [LOCAL(MC_MARK)]
    mov [r13 + SECT.quad_count], edi
    test rdi, rdi
    jz .timed
    lea rdx, [rdi * 8]
    INVOKE arena_alloc, r15, rdx, 8     ; keeps exactly this output
    mov rax, [LOCAL(MC_TOTAL)]
    mov [r13 + SECT.cpu_first], eax     ; offset within the column buffer
    add [LOCAL(MC_TOTAL)], rdi
.timed:
    call timer_elapsed_us
    sub rax, r14
    mov [r13 + SECT.mesh_us], eax
.next:
    inc r12d
    cmp r12d, SECTIONS_PER_COLUMN
    jb .section

    ; hand the quads to the main thread
    mov qword [rbx + COLUMN.mesh_buf], 0
    mov rsi, [LOCAL(MC_TOTAL)]
    shl rsi, 3                          ; bytes
    mov [rbx + COLUMN.mesh_bytes], rsi
    test rsi, rsi
    jz .publish
    API VirtualAlloc, 0, rsi, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE
    test rax, rax
    jz .alloc_failed
    mov [rbx + COLUMN.mesh_buf], rax
    mov rdi, rax
    mov rcx, rsi
    mov rsi, [LOCAL(MC_BASE)]
    shr rcx, 3
    rep movsq
    mov rax, [rbx + COLUMN.mesh_bytes]
    lock add [rel g_stream_cpu_mesh_bytes], rax
    jmp .publish
.alloc_failed:
    mov qword [rbx + COLUMN.mesh_bytes], 0
.publish:
    ; statistics
    call timer_elapsed_us
    sub rax, [LOCAL(MC_T0)]
    lock add [rel g_stream_mesh_total_us], rax
    lock inc qword [rel g_stream_mesh_count]
    mov rdx, rax
    lea rcx, [rel g_stream_mesh_max_us]
    call atomic_max
    ; release the columns we read, then publish our result
    xor ecx, ecx
.release:
    mov rax, [rbx + COLUMN.nb + rcx * 8]
    lock dec dword [rax + COLUMN.busy]
    inc ecx
    cmp ecx, 4
    jb .release
    lock dec dword [rbx + COLUMN.busy]
    mov dword [rbx + COLUMN.state], COL_MESHED
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; free_column_gpu — release a column's GPU ranges.
;   in:  rcx = COLUMN*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC free_column_gpu, 0, rbx, rsi
    mov rbx, rcx
.bits:
    mov rax, [rbx + COLUMN.geo_mask]
    test rax, rax
    jz .done
    bsf rsi, rax
    btr qword [rbx + COLUMN.geo_mask], rsi
    mov rax, [rbx + COLUMN.sections + rsi * 8]
    mov ecx, [rax + SECT.quad_count]
    sub [rel g_stream_quads], rcx
    mov ecx, [rax + SECT.quad_first]
    shr ecx, 6
    call gpu_free
    jmp .bits
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; upload_column — move a MESHED column's quads into the GPU buffer.
;   in:  rcx = COLUMN*
;   out: eax = bytes uploaded, or -1 if the GPU buffer is full (nothing kept)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC upload_column, 0, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    xor r12d, r12d                      ; bytes
    mov qword [rbx + COLUMN.geo_mask], 0
    mov r13, [rbx + COLUMN.mesh_buf]
    test r13, r13
    jz .done
    xor esi, esi                        ; sy
.section:
    mov rdi, [rbx + COLUMN.sections + rsi * 8]
    test rdi, rdi
    jz .next
    mov ecx, [rdi + SECT.quad_count]
    test ecx, ecx
    jz .next
    call gpu_alloc_units_needed
    mov ecx, eax
    call gpu_alloc
    cmp eax, -1
    je .full
    ; upload: offset = unit * 512 bytes, source = mesh_buf + cpu_first * 8
    mov r8d, eax                        ; unit
    mov r9d, [rdi + SECT.cpu_first]
    shl r9, 3
    add r9, r13                         ; source
    mov ecx, eax
    shl ecx, 6
    mov [rdi + SECT.quad_first], ecx    ; now: first quad in the GPU buffer
    mov eax, [rdi + SECT.quad_count]
    add [rel g_stream_quads], rax
    shl rax, 3                          ; bytes
    add r12, rax
    mov rdx, r8
    shl rdx, 9                          ; byte offset
    bts qword [rbx + COLUMN.geo_mask], rsi
    GL glNamedBufferSubData, [rel g_quad_buffer], rdx, rax, r9
.next:
    inc esi
    cmp esi, SECTIONS_PER_COLUMN
    jb .section
    mov rdx, [rbx + COLUMN.mesh_bytes]
    neg rdx
    lock add [rel g_stream_cpu_mesh_bytes], rdx
    API VirtualFree, r13, 0, MEM_RELEASE
    mov qword [rbx + COLUMN.mesh_buf], 0
.done:
    mov rcx, rbx
    call tint_upload
    mov dword [rbx + COLUMN.state], COL_READY
    mov eax, r12d
    RETURN
.full:
    ; roll back this column's ranges; keep it MESHED to retry later (the
    ; CPU mesh offsets are in cpu_first, so a retry uploads correctly)
    mov rsi, [rbx + COLUMN.geo_mask]    ; (rsi/rdi are free again here)
.rollback:
    test rsi, rsi
    jz .rolled
    bsf rdi, rsi
    btr rsi, rdi
    mov rdx, [rbx + COLUMN.sections + rdi * 8]
    mov r8d, [rdx + SECT.quad_count]
    sub [rel g_stream_quads], r8
    mov ecx, [rdx + SECT.quad_first]
    shr ecx, 6
    call gpu_free
    jmp .rollback
.rolled:
    mov qword [rbx + COLUMN.geo_mask], 0
    cmp dword [rel g_gpu_full_warned], 0
    jne .quiet
    mov dword [rel g_gpu_full_warned], 1
    LOG_WARN "stream: GPU quad buffer full; some columns wait (lower render_distance)"
.quiet:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; unload_column — free a column (must be idle) and drop it from the lists.
;   in:  rcx = COLUMN*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC unload_column, 0, rbx
    mov rbx, rcx
    mov rcx, rbx
    call free_column_gpu
    mov rcx, [rbx + COLUMN.mesh_buf]
    test rcx, rcx
    jz .no_buf
    mov rdx, [rbx + COLUMN.mesh_bytes]
    neg rdx
    lock add [rel g_stream_cpu_mesh_bytes], rdx
    API VirtualFree, rcx, 0, MEM_RELEASE
.no_buf:
    mov rcx, rbx
    call world_column_remove
    ; swap-remove from the loaded list
    mov rdx, [rel g_loaded]
    mov eax, [rbx + COLUMN.list_index]
    mov rcx, [rel g_loaded_count]
    dec rcx
    mov [rel g_loaded_count], rcx
    mov r8, [rdx + rcx * 8]             ; last
    mov [rdx + rax * 8], r8
    mov [r8 + COLUMN.list_index], eax
    mov rcx, rbx
    call world_column_free
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; camera_chunk — chunk coordinates of the camera.
;   out: eax = ccx, edx = ccz
;   clobbers: rax, rdx, xmm0
; -----------------------------------------------------------------------------
camera_chunk:
    movsd xmm0, [rel g_cam_pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    movsd xmm0, [rel g_cam_pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si rdx, xmm0
    sar rdx, 5
    ret

; -----------------------------------------------------------------------------
; neighbors_ready — are the 4 horizontal neighbours generated?
;   in:  rcx = COLUMN*
;   out: eax = 1 and the column's nb[] filled, or 0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC neighbors_ready, 0, rbx, rsi, rdi
    mov rbx, rcx
    xor esi, esi
.next:
    mov ecx, [rbx + COLUMN.cx]
    mov edx, [rbx + COLUMN.cz]
    cmp esi, 0
    jne .n1
    dec ecx
    jmp .look
.n1:
    cmp esi, 1
    jne .n2
    inc ecx
    jmp .look
.n2:
    cmp esi, 2
    jne .n3
    dec edx
    jmp .look
.n3:
    inc edx
.look:
    call world_column
    test rax, rax
    jz .no
    cmp dword [rax + COLUMN.state], COL_GENERATED
    jb .no                              ; NEW or GENERATING
    mov [rbx + COLUMN.nb + rsi * 8], rax
    inc esi
    cmp esi, 4
    jb .next
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; stream_update — one streaming step (main thread, never blocks on jobs).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define SU_T0       0
%define SU_CCX      8
%define SU_CCZ      16
%define SU_R2       24
%define SU_GEN_R2   32
%define SU_UNL_R2   40
%define SU_CAP      48
%define SU_BUDGET   56
%define SU_READY_IN 64
PROC stream_update, 80, rbx, rsi, rdi, r12, r13, r14, r15
    call timer_elapsed_us
    mov [LOCAL(SU_T0)], rax
    call camera_chunk
    movsxd rax, eax
    movsxd rdx, edx
    mov [LOCAL(SU_CCX)], rax
    mov [LOCAL(SU_CCZ)], rdx
    mov eax, [rel g_render_distance]
    mov ecx, eax
    imul ecx, ecx
    mov [LOCAL(SU_R2)], rcx
    lea ecx, [eax + 1]
    imul ecx, ecx
    mov [LOCAL(SU_GEN_R2)], rcx
    lea ecx, [eax + 3]
    imul ecx, ecx
    mov [LOCAL(SU_UNL_R2)], rcx
    mov eax, [rel g_job_worker_count]
    inc eax
    shl eax, 4                          ; 16 jobs per thread in flight: enough
                                        ; to keep workers busy for a frame
    ; slow frames: allow proportionally more (up to 8x), so streaming does
    ; not depend on the frame rate
    mov rcx, [rel g_frame_us]
    shr rcx, 14                         ; / ~16 ms
    cmp rcx, 1
    jae .cap_min
    mov ecx, 1
.cap_min:
    cmp rcx, 8
    jbe .cap_max
    mov ecx, 8
.cap_max:
    imul eax, ecx
    mov [LOCAL(SU_CAP)], rax
    mov qword [LOCAL(SU_BUDGET)], UPLOAD_BUDGET
    mov qword [rel g_stream_upload_frame], 0
    xor eax, eax
    mov [rel g_stream_ready], rax
    mov [rel g_stream_gen_inflight], rax
    mov [rel g_stream_mesh_inflight], rax
    mov [LOCAL(SU_READY_IN)], rax

    ; ---- pass 1: loaded columns (backwards: unloading swap-removes) ---------
    mov r12, [rel g_loaded_count]
.p1:
    test r12, r12
    jz .p1_done
    dec r12
    mov rax, [rel g_loaded]
    mov rbx, [rax + r12 * 8]
    ; squared distance
    movsxd rax, dword [rbx + COLUMN.cx]
    sub rax, [LOCAL(SU_CCX)]
    imul rax, rax
    movsxd rcx, dword [rbx + COLUMN.cz]
    sub rcx, [LOCAL(SU_CCZ)]
    imul rcx, rcx
    add rax, rcx
    mov r13, rax                        ; d^2
    mov eax, [rbx + COLUMN.state]
    cmp eax, COL_GENERATING
    jne .not_gen
    inc qword [rel g_stream_gen_inflight]
    jmp .p1
.not_gen:
    cmp eax, COL_MESHING
    jne .not_meshing
    inc qword [rel g_stream_mesh_inflight]
    jmp .p1
.not_meshing:
    cmp eax, COL_MESHED
    jne .not_meshed
    cmp r13, [LOCAL(SU_UNL_R2)]
    ja .maybe_unload                    ; far away: drop instead of upload
    cmp qword [LOCAL(SU_BUDGET)], 0
    jle .p1
    call timer_elapsed_us
    mov r14, rax
    mov rcx, rbx
    call upload_column
    mov r15, rax
    call timer_elapsed_us
    sub rax, r14
    add [rel g_upl_total_us], rax
    cmp rax, [rel g_upl_max_us]
    jbe .upl_max_ok
    mov [rel g_upl_max_us], rax
.upl_max_ok:
    mov rax, r15
    cmp eax, -1
    je .p1
    sub [LOCAL(SU_BUDGET)], rax
    add [rel g_stream_upload_frame], rax
    mov eax, COL_READY
.not_meshed:
    cmp eax, COL_READY
    jne .maybe_unload
    inc qword [rel g_stream_ready]
    cmp r13, [LOCAL(SU_R2)]
    ja .maybe_unload
    inc qword [LOCAL(SU_READY_IN)]
.maybe_unload:
    cmp r13, [LOCAL(SU_UNL_R2)]
    jbe .p1
    cmp dword [rbx + COLUMN.busy], 0
    jne .p1
    mov eax, [rbx + COLUMN.state]
    cmp eax, COL_GENERATED
    je .unload
    cmp eax, COL_MESHED
    je .unload
    cmp eax, COL_READY
    jne .p1
.unload:
    mov rcx, rbx
    call unload_column
    jmp .p1
.p1_done:

    ; ---- view complete? ---------------------------------------------------------------
    cmp dword [rel g_view_logged], 0
    jne .view_done
    mov rax, [LOCAL(SU_READY_IN)]
    cmp rax, [rel g_spiral_inner]
    jb .view_done
    mov dword [rel g_view_logged], 1
    mov rax, [LOCAL(SU_T0)]
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rel g_stream_view_ms], rax
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_view]
    call log_append_str
    mov rcx, [rel g_spiral_inner]
    call log_append_dec
    lea rcx, [rel str_after]
    call log_append_str
    mov rcx, [rel g_stream_view_ms]
    call log_append_dec
    call log_end
.view_done:

    ; ---- pass 2: spiral, nearest first ------------------------------------------------
    mov r14, [rel g_spiral]
    xor r12d, r12d                      ; spiral index
.p2:
    cmp r12, [rel g_spiral_count]
    jae .p2_done
    mov rax, [rel g_stream_gen_inflight]
    cmp rax, [LOCAL(SU_CAP)]
    jb .p2_work
    mov rax, [rel g_stream_mesh_inflight]
    cmp rax, [LOCAL(SU_CAP)]
    jae .p2_done                        ; both pipelines full
.p2_work:
    movsx esi, word [r14 + r12 * 4]     ; dx
    movsx edi, word [r14 + r12 * 4 + 2] ; dz
    mov eax, esi
    imul eax, eax
    mov ecx, edi
    imul ecx, ecx
    add eax, ecx
    mov r15d, eax                       ; d^2
    add esi, [LOCAL(SU_CCX)]
    add edi, [LOCAL(SU_CCZ)]
    mov ecx, esi
    mov edx, edi
    call world_column
    test rax, rax
    jnz .exists
    ; create + generate
    mov rax, [rel g_stream_gen_inflight]
    cmp rax, [LOCAL(SU_CAP)]
    jae .p2_next
    cmp qword [rel g_loaded_count], MAX_LOADED
    jae .p2_next
    INVOKE world_column_alloc, rsi, rdi
    test rax, rax
    jz .p2_next
    mov rbx, rax
    mov rcx, rbx
    call world_column_insert
    mov rax, [rel g_loaded_count]
    mov rcx, [rel g_loaded]
    mov [rcx + rax * 8], rbx
    mov [rbx + COLUMN.list_index], eax
    inc qword [rel g_loaded_count]
    mov dword [rbx + COLUMN.state], COL_GENERATING
    inc qword [rel g_stream_gen_inflight]
    lea rcx, [rel gen_column_job]
    lea r8, [rel g_stream_inflight]
    INVOKE job_submit, rcx, rbx, r8
    jmp .p2_next
.exists:
    mov rbx, rax
    cmp dword [rbx + COLUMN.state], COL_GENERATED
    jne .p2_next
    cmp r15, [LOCAL(SU_R2)]
    ja .p2_next
    mov rax, [rel g_stream_mesh_inflight]
    cmp rax, [LOCAL(SU_CAP)]
    jae .p2_next
    mov rcx, rbx
    call neighbors_ready
    test eax, eax
    jz .p2_next
    ; reserve the column and its neighbours, then queue the mesh job
    lock inc dword [rbx + COLUMN.busy]
    xor ecx, ecx
.reserve:
    mov rax, [rbx + COLUMN.nb + rcx * 8]
    lock inc dword [rax + COLUMN.busy]
    inc ecx
    cmp ecx, 4
    jb .reserve
    mov dword [rbx + COLUMN.state], COL_MESHING
    inc qword [rel g_stream_mesh_inflight]
    lea rcx, [rel mesh_column_job]
    lea r8, [rel g_stream_inflight]
    INVOKE job_submit, rcx, rbx, r8
.p2_next:
    inc r12
    jmp .p2
.p2_done:

    ; ---- timing + periodic log -----------------------------------------------------------
    call timer_elapsed_us
    mov rbx, rax
    sub rax, [LOCAL(SU_T0)]
    mov [rel g_stream_update_us], rax
    add [rel g_upd_total_us], rax
    inc qword [rel g_upd_frames]
    cmp rax, [rel g_stream_update_max_us]
    jbe .max_ok
    mov [rel g_stream_update_max_us], rax
.max_ok:
    mov rax, rbx
    sub rax, [rel g_last_stat_us]
    cmp rax, STAT_LOG_US
    jb .no_log
    mov [rel g_last_stat_us], rbx
    call log_stats
.no_log:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_stats — one "stream:" summary line.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_stats, 0
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_stat]
    call log_append_str
    mov rcx, [rel g_loaded_count]
    call log_append_dec
    lea rcx, [rel str_ready]
    call log_append_str
    mov rcx, [rel g_stream_ready]
    call log_append_dec
    lea rcx, [rel str_gen]
    call log_append_str
    mov rcx, [rel g_stream_gen_inflight]
    call log_append_dec
    lea rcx, [rel str_mesh]
    call log_append_str
    mov rcx, [rel g_stream_mesh_inflight]
    call log_append_dec
    lea rcx, [rel str_quads]
    call log_append_str
    mov rcx, [rel g_stream_quads]
    call log_append_dec
    lea rcx, [rel str_update]
    call log_append_str
    mov rcx, [rel g_stream_update_max_us]
    call log_append_dec
    lea rcx, [rel str_mesh_avg]
    call log_append_str
    mov rax, [rel g_stream_mesh_total_us]
    mov rcx, [rel g_stream_mesh_count]
    xor edx, edx
    test rcx, rcx
    jz .no_div
    div rcx
.no_div:
    mov rcx, rax
    call log_append_dec
    lea rcx, [rel str_upd_avg]
    call log_append_str
    mov rax, [rel g_upd_total_us]
    mov rcx, [rel g_upd_frames]
    xor edx, edx
    test rcx, rcx
    jz .no_div2
    div rcx
.no_div2:
    mov rcx, rax
    call log_append_dec
    lea rcx, [rel str_upl]
    call log_append_str
    mov rcx, [rel g_upl_total_us]
    call log_append_dec
    lea rcx, [rel str_upl_max]
    call log_append_str
    mov rcx, [rel g_upl_max_us]
    call log_append_dec
    call log_end
    xor eax, eax
    mov [rel g_stream_update_max_us], rax
    mov [rel g_upd_total_us], rax
    mov [rel g_upd_frames], rax
    mov [rel g_upl_total_us], rax
    mov [rel g_upl_max_us], rax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; stream_shutdown — wait for in-flight jobs, then free every column.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC stream_shutdown, 0
    lea rcx, [rel g_stream_inflight]
    call job_wait
.next:
    mov rax, [rel g_loaded_count]
    test rax, rax
    jz .done
    mov rcx, [rel g_loaded]
    mov rcx, [rcx + rax * 8 - 8]
    call unload_column
    jmp .next
.done:
    LOG_INFO "stream: all columns released"
    RETURN
ENDPROC
