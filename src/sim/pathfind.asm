; =============================================================================
; pathfind.asm — A* paths over the blocks for animals (milestone 19 part 2,
; DECISIONS D99).
;
; A cell is a block position where an animal's feet can be: its own block
; and the ones above it (the animal's height in blocks) let a body through
; (no collision, no lava), and the block below holds it up (it collides) or
; the feet are in water (swimming). From a cell an animal can go to the 8
; cells around it on the same level (diagonals only if both sides are
; open, so it never cuts corners), up 1 (a jump: room above its head
; first) or down by up to 3. Costs: 10 straight, 14 diagonal, +6 up, +2 per
; block down, +20 in water. Distances guide the search (octile + height).
;
; The search stops at NODE_MAX cells or SEARCH_R blocks from the start; if
; the goal was not reached the path leads to the cell that got closest to
; it (a wander, a chase or a flight still makes progress).
;
; Public API:
;   path_find() -> eax waypoints (0: nowhere to go)
;     in:  g_pf_start (i32 x, y, z: the feet's block), g_pf_goal (i32 x, y, z),
;          g_pf_height (blocks of room the body needs, 1..3),
;          g_pf_out (WP* room for PATH_MAX waypoints)
;     out: the waypoints (i32 x, y, z each), first step first; g_pf_nodes
;   g_pf_calls, g_pf_us (statistics)
; =============================================================================
%include "macros.inc"
%include "physics.inc"

global path_find, g_pf_start, g_pf_goal, g_pf_height, g_pf_out
global g_pf_nodes, g_pf_calls, g_pf_us

extern timer_elapsed_us

%define NODE_MAX        480
%define HEAP_MAX        4096
%define HASH_SIZE       2048            ; power of two
%define SEARCH_R        24
%define PATH_MAX        16
%define COST_STRAIGHT   10
%define COST_DIAG       14
%define COST_UP         6
%define COST_DOWN       2
%define COST_WATER      20

section .rdata
; the 8 directions: dx, dz (the 4 straight ones first)
dir_dx:         dd 1, -1, 0, 0, 1, 1, -1, -1
dir_dz:         dd 0, 0, 1, -1, 1, -1, 1, -1

section .bss
alignb 16
g_nx:           resd NODE_MAX
g_ny:           resd NODE_MAX
g_nz:           resd NODE_MAX
g_ng:           resd NODE_MAX               ; cost from the start
g_nh:           resd NODE_MAX               ; estimate to the goal
g_np:           resd NODE_MAX               ; parent (-1: the start)
g_nclosed:      resb NODE_MAX
alignb 4
g_hash:         resw HASH_SIZE              ; node + 1 (0: empty)
g_heap:         resd HEAP_MAX               ; f << 12 | node (one dword compare)
g_rev:          resd NODE_MAX               ; the path, goal first
g_pf_start:     resd 3
g_pf_goal:      resd 3
g_pf_height:    resd 1
g_pf_nodes:     resd 1
g_heap_n:       resd 1
g_best:         resd 1
alignb 8
g_pf_out:       resq 1
g_pf_calls:     resq 1
g_pf_us:        resq 1                      ; time in path_find (total)

section .text

; -----------------------------------------------------------------------------
; open_at — eax = 1 if a body can be in block (ecx, edx, r8d): no collision,
; no lava; 0 otherwise (not generated counts as closed)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC open_at, 0
    call phys_block
    cmp eax, -1
    je .no
    lea rcx, [rel g_block_move]
    test byte [rcx + rax], MOVE_LAVA
    jnz .no
    lea rcx, [rel g_block_coll]
    cmp byte [rcx + rax], 0
    jne .no
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; column_open — eax = 1 if the body fits from block y up (ecx, edx, r8d;
; g_pf_height blocks)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC column_open, 16, rbx, rsi, rdi, r12
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    xor r12d, r12d
.up:
    cmp r12d, [rel g_pf_height]
    jae .yes
    mov ecx, ebx
    lea edx, [rsi + r12]
    mov r8d, edi
    call open_at
    test eax, eax
    jz .no
    inc r12d
    jmp .up
.yes:
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; stand_at — can feet be at (ecx, edx, r8d)? The body fits, and the block
;   below holds it up or the feet are in water.
;   out: eax = 0 no, 1 yes, 2 yes in water
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC stand_at, 16, rbx, rsi, rdi
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    call column_open
    test eax, eax
    jz .no
    ; in water?
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    call phys_block
    lea rcx, [rel g_block_move]
    test byte [rcx + rax], MOVE_WATER
    jnz .water
    lea edx, [rsi - 1]
    mov ecx, ebx
    mov r8d, edi
    call phys_block
    cmp eax, -1
    je .no
    lea rcx, [rel g_block_coll]
    cmp byte [rcx + rax], 0
    je .no
    mov eax, 1
    RETURN
.water:
    mov eax, 2
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; estimate — eax = octile distance * 10 + |dy| * 10 from node ecx to the goal
;   clobbers: rax, rcx, rdx, r8, r9
estimate:
    lea r8, [rel g_nx]
    mov eax, [r8 + rcx * 4]
    sub eax, [rel g_pf_goal]
    mov edx, eax
    neg edx
    cmovs edx, eax                      ; |dx|
    lea r8, [rel g_nz]
    mov eax, [r8 + rcx * 4]
    sub eax, [rel g_pf_goal + 8]
    mov r9d, eax
    neg r9d
    cmovs r9d, eax                      ; |dz|
    mov eax, edx
    cmp edx, r9d
    cmovb eax, r9d                      ; max
    cmova edx, r9d                      ; min
    imul eax, eax, COST_STRAIGHT
    imul edx, edx, COST_DIAG - COST_STRAIGHT
    add eax, edx
    lea r8, [rel g_ny]
    mov edx, [r8 + rcx * 4]
    sub edx, [rel g_pf_goal + 4]
    mov r9d, edx
    neg r9d
    cmovs r9d, edx
    imul r9d, r9d, COST_STRAIGHT
    add eax, r9d
    ret

; hash_of — rdx = hash slot start for (ecx, edx, r8d)   clobbers: rax, rdx
hash_of:
    imul eax, ecx, 73856093
    imul edx, edx, 19349663
    xor eax, edx
    imul edx, r8d, 83492791
    xor eax, edx
    and eax, HASH_SIZE - 1
    mov edx, eax
    ret

; -----------------------------------------------------------------------------
; node_get — the node of cell (ecx, edx, r8d), created if new.
;   out: eax = node, -1 if full; r9d = 1 if it was new
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC node_get, 16, rbx, rsi, rdi
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    call hash_of
    lea r10, [rel g_hash]
.probe:
    movzx eax, word [r10 + rdx * 2]
    test eax, eax
    jz .new
    dec eax
    lea r11, [rel g_nx]
    cmp [r11 + rax * 4], ebx
    jne .next
    lea r11, [rel g_ny]
    cmp [r11 + rax * 4], esi
    jne .next
    lea r11, [rel g_nz]
    cmp [r11 + rax * 4], edi
    jne .next
    xor r9d, r9d
    RETURN
.next:
    inc edx
    and edx, HASH_SIZE - 1
    jmp .probe
.new:
    mov eax, [rel g_pf_nodes]
    cmp eax, NODE_MAX
    jae .full
    inc dword [rel g_pf_nodes]
    lea ecx, [rax + 1]
    mov [r10 + rdx * 2], cx
    lea r11, [rel g_nx]
    mov [r11 + rax * 4], ebx
    lea r11, [rel g_ny]
    mov [r11 + rax * 4], esi
    lea r11, [rel g_nz]
    mov [r11 + rax * 4], edi
    lea r11, [rel g_ng]
    mov dword [r11 + rax * 4], 0x7FFFFFFF
    lea r11, [rel g_nclosed]
    mov byte [r11 + rax], 0
    mov ebx, eax
    mov ecx, eax
    call estimate
    lea r11, [rel g_nh]
    mov [r11 + rbx * 4], eax
    mov eax, ebx
    mov r9d, 1
    RETURN
.full:
    mov eax, -1
    RETURN
ENDPROC

; heap_push — key ecx (f << 12 | node)   clobbers: rax, rcx, rdx, r8, r9
heap_push:
    mov eax, [rel g_heap_n]
    cmp eax, HEAP_MAX
    jae .done
    inc dword [rel g_heap_n]
    lea r8, [rel g_heap]
.up:
    test eax, eax
    jz .place
    lea edx, [rax - 1]
    shr edx, 1                          ; parent
    mov r9d, [r8 + rdx * 4]
    cmp r9d, ecx
    jbe .place
    mov [r8 + rax * 4], r9d
    mov eax, edx
    jmp .up
.place:
    mov [r8 + rax * 4], ecx
.done:
    ret

; heap_pop — eax = the smallest key, -1 if empty   clobbers: rax, rcx, rdx, r8-r11
heap_pop:
    mov ecx, [rel g_heap_n]
    test ecx, ecx
    jz .empty
    lea r8, [rel g_heap]
    mov r11d, [r8]                      ; result
    dec ecx
    mov [rel g_heap_n], ecx
    mov r9d, [r8 + rcx * 4]             ; the last one sinks from the top
    xor eax, eax
.down:
    lea edx, [rax * 2 + 1]
    cmp edx, ecx
    jae .place
    lea r10d, [rdx + 1]
    cmp r10d, ecx
    jae .one
    mov r10d, [r8 + r10 * 4]
    cmp r10d, [r8 + rdx * 4]
    jae .one
    inc edx
.one:
    mov r10d, [r8 + rdx * 4]
    cmp r10d, r9d
    jae .place
    mov [r8 + rax * 4], r10d
    mov eax, edx
    jmp .down
.place:
    mov [r8 + rax * 4], r9d
    mov eax, r11d
    ret
.empty:
    mov eax, -1
    ret

; -----------------------------------------------------------------------------
; try_move — consider going from node esi to cell (ecx, edx, r8d) for the
; cost r9d (the caller checked the cell can be stood in).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC try_move, 16, rbx, rdi
    mov ebx, r9d
    ; within the search square
    mov eax, ecx
    sub eax, [rel g_pf_start]
    add eax, SEARCH_R
    cmp eax, 2 * SEARCH_R
    ja .done
    mov eax, r8d
    sub eax, [rel g_pf_start + 8]
    add eax, SEARCH_R
    cmp eax, 2 * SEARCH_R
    ja .done
    call node_get
    test eax, eax
    js .done
    mov edi, eax
    lea rcx, [rel g_nclosed]
    cmp byte [rcx + rdi], 0
    jne .done
    lea rcx, [rel g_ng]
    mov eax, [rcx + rsi * 4]
    add eax, ebx                        ; new cost
    cmp eax, [rcx + rdi * 4]
    jge .done
    mov [rcx + rdi * 4], eax
    lea rcx, [rel g_np]
    mov [rcx + rdi * 4], esi
    lea rcx, [rel g_nh]
    add eax, [rcx + rdi * 4]            ; f
    cmp eax, 0xFFFFF
    jbe .key
    mov eax, 0xFFFFF
.key:
    shl eax, 12
    or eax, edi
    mov ecx, eax
    call heap_push
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; path_find — see the header.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define F_START     0                   ; u64 timer
%define F_X         8
%define F_Y         12
%define F_Z         16
%define F_D         20                  ; direction
%define F_NX        24
%define F_NZ        28
%define F_OPEN      32                  ; straight directions open (bits)
%define F_DROP      36
%define F_N         40
PROC path_find, 48, rbx, rsi, rdi, r12, r13
    call timer_elapsed_us
    mov [LOCAL(F_START)], rax
    inc qword [rel g_pf_calls]
    ; clear the hash; the start
    lea rdi, [rel g_hash]
    xor eax, eax
    mov ecx, HASH_SIZE * 2 / 8
    rep stosq
    mov dword [rel g_pf_nodes], 0
    mov dword [rel g_heap_n], 0
    mov ecx, [rel g_pf_start]
    mov edx, [rel g_pf_start + 4]
    mov r8d, [rel g_pf_start + 8]
    call node_get
    mov esi, eax                        ; (node 0)
    lea rcx, [rel g_ng]
    mov dword [rcx], 0
    lea rcx, [rel g_np]
    mov dword [rcx], -1
    mov [rel g_best], esi
    lea rcx, [rel g_nh]
    mov ecx, [rcx]
    shl ecx, 12
    call heap_push
.search:
    call heap_pop
    cmp eax, -1
    je .done_search
    mov esi, eax
    and esi, 0xFFF                      ; node
    lea rcx, [rel g_nclosed]
    cmp byte [rcx + rsi], 0
    jne .search                         ; (an old entry)
    mov byte [rcx + rsi], 1
    ; closest to the goal so far?
    lea rcx, [rel g_nh]
    mov eax, [rcx + rsi * 4]
    mov edx, [rel g_best]
    cmp eax, [rcx + rdx * 4]
    jae .not_best
    mov [rel g_best], esi
.not_best:
    test eax, eax
    jz .done_search                     ; (there)
    lea rcx, [rel g_nx]
    mov eax, [rcx + rsi * 4]
    mov [LOCAL(F_X)], eax
    lea rcx, [rel g_ny]
    mov eax, [rcx + rsi * 4]
    mov [LOCAL(F_Y)], eax
    lea rcx, [rel g_nz]
    mov eax, [rcx + rsi * 4]
    mov [LOCAL(F_Z)], eax
    mov dword [LOCAL(F_OPEN)], 0
    mov dword [LOCAL(F_D)], 0
.dir:
    mov eax, [LOCAL(F_D)]
    cmp eax, 8
    jae .search
    lea rcx, [rel dir_dx]
    mov ecx, [rcx + rax * 4]
    add ecx, [LOCAL(F_X)]
    mov [LOCAL(F_NX)], ecx
    lea rcx, [rel dir_dz]
    mov ecx, [rcx + rax * 4]
    add ecx, [LOCAL(F_Z)]
    mov [LOCAL(F_NZ)], ecx
    mov r12d, COST_STRAIGHT
    cmp eax, 4
    jb .straight
    ; diagonal: both straight neighbours on its sides must be open
    mov r12d, COST_DIAG
    lea rcx, [rel dir_dx]
    mov ecx, [rcx + rax * 4]
    mov edx, 1                          ; +X is bit 0, -X bit 1
    cmp ecx, 0
    jg .dx_bit
    mov edx, 2
.dx_bit:
    lea rcx, [rel dir_dz]
    mov ecx, [rcx + rax * 4]
    mov r8d, 4                          ; +Z bit 2, -Z bit 3
    cmp ecx, 0
    jg .dz_bit
    mov r8d, 8
.dz_bit:
    or edx, r8d
    mov eax, [LOCAL(F_OPEN)]
    and eax, edx
    cmp eax, edx
    jne .next_dir
.straight:
    ; the same level
    mov ecx, [LOCAL(F_NX)]
    mov edx, [LOCAL(F_Y)]
    mov r8d, [LOCAL(F_NZ)]
    call stand_at
    test eax, eax
    jz .not_level
    mov r9d, r12d
    cmp eax, 2
    jne .level_cost
    add r9d, COST_WATER
.level_cost:
    call mark_open
    mov ecx, [LOCAL(F_NX)]
    mov edx, [LOCAL(F_Y)]
    mov r8d, [LOCAL(F_NZ)]
    call try_move
    jmp .next_dir
.not_level:
    cmp dword [LOCAL(F_D)], 4
    jae .next_dir                       ; (diagonals: no climbing or dropping)
    ; up one: room above the head first, then the cell above the neighbour
    mov ecx, [LOCAL(F_X)]
    mov edx, [LOCAL(F_Y)]
    add edx, [rel g_pf_height]
    mov r8d, [LOCAL(F_Z)]
    call open_at
    test eax, eax
    jz .down
    mov ecx, [LOCAL(F_NX)]
    mov edx, [LOCAL(F_Y)]
    inc edx
    mov r8d, [LOCAL(F_NZ)]
    call stand_at
    test eax, eax
    jz .down
    mov r9d, r12d
    add r9d, COST_UP
    mov ecx, [LOCAL(F_NX)]
    mov edx, [LOCAL(F_Y)]
    inc edx
    mov r8d, [LOCAL(F_NZ)]
    call try_move
    jmp .next_dir
.down:
    ; down 1..3: the body must fit on the way (the neighbour's column open)
    mov ecx, [LOCAL(F_NX)]
    mov edx, [LOCAL(F_Y)]
    mov r8d, [LOCAL(F_NZ)]
    call column_open
    test eax, eax
    jz .next_dir
    mov dword [LOCAL(F_DROP)], 1
.drop:
    mov ecx, [LOCAL(F_NX)]
    mov edx, [LOCAL(F_Y)]
    sub edx, [LOCAL(F_DROP)]
    mov r8d, [LOCAL(F_NZ)]
    call stand_at
    test eax, eax
    jnz .landed
    inc dword [LOCAL(F_DROP)]
    cmp dword [LOCAL(F_DROP)], 3
    jbe .drop
    jmp .next_dir
.landed:
    mov r9d, [LOCAL(F_DROP)]
    imul r9d, r9d, COST_DOWN
    add r9d, r12d
    cmp eax, 2
    jne .drop_cost
    add r9d, COST_WATER
.drop_cost:
    mov ecx, [LOCAL(F_NX)]
    mov edx, [LOCAL(F_Y)]
    sub edx, [LOCAL(F_DROP)]
    mov r8d, [LOCAL(F_NZ)]
    call try_move
.next_dir:
    inc dword [LOCAL(F_D)]
    jmp .dir
.done_search:
    ; the path: from the best node back to the start
    mov ecx, [rel g_best]
    xor ebx, ebx                        ; length
    lea r8, [rel g_np]
    lea r9, [rel g_rev]
.back:
    mov eax, [r8 + rcx * 4]
    cmp eax, -1
    je .reversed                        ; (the start itself is not a step)
    mov [r9 + rbx * 4], ecx
    inc ebx
    mov ecx, eax
    cmp ebx, NODE_MAX
    jb .back
.reversed:
    ; first steps first, at most PATH_MAX
    mov r12d, ebx
    cmp r12d, PATH_MAX
    jbe .count
    mov r12d, PATH_MAX
.count:
    mov rdi, [rel g_pf_out]
    xor r13d, r13d
.copy:
    cmp r13d, r12d
    jae .finish
    mov eax, ebx
    sub eax, r13d
    dec eax
    mov ecx, [r9 + rax * 4]
    lea rax, [rel g_nx]
    mov edx, [rax + rcx * 4]
    mov [rdi], edx
    lea rax, [rel g_ny]
    mov edx, [rax + rcx * 4]
    mov [rdi + 4], edx
    lea rax, [rel g_nz]
    mov edx, [rax + rcx * 4]
    mov [rdi + 8], edx
    add rdi, 12
    inc r13d
    jmp .copy
.finish:
    call timer_elapsed_us
    sub rax, [LOCAL(F_START)]
    add [rel g_pf_us], rax
    mov eax, r12d
    RETURN
ENDPROC

; mark_open — the straight direction F_D is open (for the diagonals); runs in
; path_find's frame (a plain call, no frame of its own)
mark_open:
    mov eax, [rsp + 8 + OUTGOING_SIZE + F_D]
    cmp eax, 4
    jae .done
    bts dword [rsp + 8 + OUTGOING_SIZE + F_OPEN], eax
.done:
    ret
