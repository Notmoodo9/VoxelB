; =============================================================================
; gpu_alloc.asm — buddy allocator for ranges of the GPU quad buffer.
;
; Manages 2^GA_ORDERS units of GA_UNIT_QUADS quads (8 bytes each). A request
; is rounded up to a power-of-two number of units; free blocks of equal size
; whose buddies are also free are merged back. Bookkeeping lives in CPU
; arrays (perm arena): per unit a block-head state, order, and free-list
; links. Main thread only.
;
; Public API:
;   gpu_alloc_init() -> eax 1/0
;   gpu_alloc(units) -> eax first unit, or -1 if no block is large enough
;   gpu_free(first_unit)
;   gpu_alloc_units_needed(quads) -> eax units
;   g_gpu_units_used, GA_TOTAL_UNITS, GA_UNIT_QUADS
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"

global gpu_alloc_init, gpu_alloc, gpu_free, gpu_alloc_units_needed
global g_gpu_units_used

%define GA_ORDERS       18              ; 2^18 units
%define GA_TOTAL_UNITS  (1 << GA_ORDERS)
%define GA_UNIT_QUADS   64              ; 512 bytes per unit -> 128 MB total
%define ST_NONE         0               ; not a block head
%define ST_FREE         1
%define ST_USED         2

section .bss
alignb 8
g_next:         resq 1                  ; i32[units]  free-list next (-1 end)
g_prev:         resq 1                  ; i32[units]
g_state:        resq 1                  ; u8[units]
g_order:        resq 1                  ; u8[units]
g_heads:        resd GA_ORDERS + 1      ; free-list head per order (-1 empty)
g_gpu_units_used: resq 1

section .text

; -----------------------------------------------------------------------------
; list_push / list_remove — free-list maintenance.
;   in:  ecx = unit, edx = order
;   clobbers: rax, r8, r9, r10
; -----------------------------------------------------------------------------
list_push:
    mov r8, [rel g_next]
    mov r9, [rel g_prev]
    lea r10, [rel g_heads]
    mov eax, [r10 + rdx * 4]
    mov [r8 + rcx * 4], eax             ; next = old head
    mov dword [r9 + rcx * 4], -1
    test eax, eax
    js .empty
    mov [r9 + rax * 4], ecx             ; old head.prev = unit
.empty:
    mov [r10 + rdx * 4], ecx
    mov r8, [rel g_state]
    mov byte [r8 + rcx], ST_FREE
    mov r8, [rel g_order]
    mov [r8 + rcx], dl
    ret

list_remove:
    mov r8, [rel g_next]
    mov r9, [rel g_prev]
    mov eax, [r9 + rcx * 4]             ; prev
    mov r10d, [r8 + rcx * 4]            ; next
    test eax, eax
    js .was_head
    mov [r8 + rax * 4], r10d
    jmp .fix_next
.was_head:
    lea rax, [rel g_heads]
    mov [rax + rdx * 4], r10d
    mov eax, -1
.fix_next:
    test r10d, r10d
    js .done
    mov [r9 + r10 * 4], eax
.done:
    mov r8, [rel g_state]
    mov byte [r8 + rcx], ST_NONE
    ret

; -----------------------------------------------------------------------------
; gpu_alloc_init — one free block covering everything.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gpu_alloc_init, 0, rbx, rdi
    cmp qword [rel g_next], 0
    jne .arrays_ready                   ; second call (self test, then game)
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, GA_TOTAL_UNITS * 4, 64
    mov [rel g_next], rax
    test rax, rax
    jz .fail
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, GA_TOTAL_UNITS * 4, 64
    mov [rel g_prev], rax
    test rax, rax
    jz .fail
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, GA_TOTAL_UNITS, 64
    mov [rel g_state], rax
    test rax, rax
    jz .fail
    mov rdi, rax
    xor eax, eax
    mov ecx, GA_TOTAL_UNITS / 8
    rep stosq
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, GA_TOTAL_UNITS, 64
    mov [rel g_order], rax
    test rax, rax
    jz .fail
.arrays_ready:
    mov rdi, [rel g_state]
    xor eax, eax
    mov ecx, GA_TOTAL_UNITS / 8
    rep stosq
    lea rax, [rel g_heads]
    xor ecx, ecx
.heads:
    mov dword [rax + rcx * 4], -1
    inc ecx
    cmp ecx, GA_ORDERS
    jbe .heads
    mov qword [rel g_gpu_units_used], 0
    xor ecx, ecx
    mov edx, GA_ORDERS
    call list_push
    mov eax, 1
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gpu_alloc_units_needed — units for a quad count (>= 1).
;   in:  ecx = quads      out: eax = units
;   clobbers: rax
; -----------------------------------------------------------------------------
gpu_alloc_units_needed:
    lea eax, [ecx + GA_UNIT_QUADS - 1]
    shr eax, 6
    ret

; -----------------------------------------------------------------------------
; gpu_alloc — allocate a block of at least `units` units.
;   in:  ecx = units (>= 1)
;   out: eax = first unit, or -1 if no free block is large enough
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gpu_alloc, 0, rbx, rsi, rdi
    ; order k = ceil(log2(units))
    xor esi, esi
    mov eax, 1
.order:
    cmp eax, ecx
    jae .have_order
    shl eax, 1
    inc esi
    jmp .order
.have_order:
    cmp esi, GA_ORDERS
    ja .none
    ; smallest non-empty list j >= k
    mov edi, esi
    lea rbx, [rel g_heads]
.search:
    cmp edi, GA_ORDERS
    ja .none
    cmp dword [rbx + rdi * 4], 0
    jge .found
    inc edi
    jmp .search
.found:
    mov ecx, [rbx + rdi * 4]            ; (rbx is reused below as scratch)
    mov edx, edi
    call list_remove                    ; (leaves rcx/rdx intact)
    ; split down to order k, pushing the upper halves
.split:
    cmp edi, esi
    jbe .take
    dec edi
    mov eax, 1
    xchg ecx, edi
    shl eax, cl
    xchg ecx, edi
    lea r11d, [ecx + eax]               ; buddy (upper half)
    mov ebx, ecx                        ; keep the block start
    mov ecx, r11d
    mov edx, edi
    call list_push
    mov ecx, ebx
    jmp .split
.take:
    mov r8, [rel g_state]
    mov byte [r8 + rcx], ST_USED
    mov r8, [rel g_order]
    mov [r8 + rcx], sil
    mov eax, 1
    xchg ecx, esi
    shl eax, cl
    xchg ecx, esi
    add [rel g_gpu_units_used], rax
    mov eax, ecx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gpu_free — free a block returned by gpu_alloc, merging free buddies.
;   in:  ecx = first unit
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gpu_free, 0, rbx, rsi
    mov ebx, ecx                        ; block start
    mov r8, [rel g_order]
    movzx esi, byte [r8 + rbx]          ; order
    mov eax, 1
    mov ecx, esi
    shl eax, cl
    sub [rel g_gpu_units_used], rax
.merge:
    cmp esi, GA_ORDERS
    jae .push
    mov eax, 1
    mov ecx, esi
    shl eax, cl
    mov ecx, ebx
    xor ecx, eax                        ; buddy
    mov r8, [rel g_state]
    cmp byte [r8 + rcx], ST_FREE
    jne .push
    mov r8, [rel g_order]
    movzx eax, byte [r8 + rcx]
    cmp eax, esi
    jne .push
    mov edx, esi
    call list_remove                    ; (leaves rcx intact)
    cmp ecx, ebx
    cmovb ebx, ecx                      ; merged block starts at the lower
    inc esi
    jmp .merge
.push:
    mov ecx, ebx
    mov edx, esi
    call list_push
    RETURN
ENDPROC
