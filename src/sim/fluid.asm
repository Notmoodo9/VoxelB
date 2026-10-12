; =============================================================================
; fluid.asm — flowing liquids in the simulation (milestone 16 part 3,
; DECISIONS D87).
;
; Liquids are data: a source block (`water`, `lava`) names nothing; its
; flowing block (`shape = fluid`, `source = water`) has 8 states: levels
; 1..7 (states 0..6) and falling (state 7), with `flow_range` (how many
; levels it spreads) and `flow_delay` (ticks per step).
;
; Cells are updated when something near them changed (a block edit, or a
; neighbour's liquid changed), `flow_delay` ticks later. An update works
; out what the cell should hold from its neighbours (Minecraft-like):
;   * the same liquid directly above: falling liquid;
;   * else the lowest level next to it + 1, counting a source or a
;     waterlogged block as level 0, and a flowing or falling neighbour only
;     where it rests on something (liquid above air falls instead of
;     spreading); falling liquid that rests counts as level 0;
;   * beyond flow_range: nothing (the liquid dries up).
; Only air, plants and flowing liquid are replaced; sources never change.
; A change schedules the 6 neighbours.
;
; Scheduled cells live in BUCKETS ring buckets by tick; each tick takes
; at most MAX_PER_TICK of them (the rest moves on to the next tick).
;
; Public API:
;   fluid_schedule(ecx = x, edx = y, r8d = z, r9d = delay in ticks)
;   fluid_schedule_around(ecx, edx, r8d, r9d = delay)   the cell and its 6
;                                       neighbours
;   fluid_tick(rcx = tick number)       run the updates due now
;   g_fluid_updates, g_fluid_changes, g_fluid_pending   statistics
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "block.inc"
%include "physics.inc"

global fluid_schedule, fluid_schedule_around, fluid_tick
global g_fluid_updates, g_fluid_changes, g_fluid_pending

extern phys_block, edit_apply

%define BUCKETS         128             ; > the longest flow_delay (100)
%define BUCKET_CAP      4096            ; cells per bucket
%define MAX_PER_TICK    2048
%define NONE            -2              ; desired: no liquid

section .rdata
align 4
nb6_dx:         dd -1, 1, 0, 0, 0, 0
nb6_dy:         dd 0, 0, -1, 1, 0, 0
nb6_dz:         dd 0, 0, 0, 0, -1, 1
side_dx:        dd -1, 1, 0, 0
side_dz:        dd 0, 0, -1, 1
str_full:       db "fluid: too many liquid updates at once; some were skipped", 0

section .bss
alignb 16
g_buckets:      resd BUCKETS * BUCKET_CAP * 4   ; x, y, z, pad
g_bucket_n:     resd BUCKETS
g_fluid_tick:   resq 1                  ; the tick being run (for scheduling)
g_fluid_updates: resq 1
g_fluid_changes: resq 1
g_fluid_pending: resq 1
g_full_warned:  resd 1

section .text

; -----------------------------------------------------------------------------
; fluid_schedule — update a cell after a delay.
;   in:  ecx = x, edx = y, r8d = z, r9d = delay (1..BUCKETS-1 ticks)
;   clobbers: rax, r9-r11
; -----------------------------------------------------------------------------
fluid_schedule:
    mov rax, [rel g_fluid_tick]
    add rax, r9
    and eax, BUCKETS - 1
    lea r10, [rel g_bucket_n]
    mov r11d, [r10 + rax * 4]
    cmp r11d, BUCKET_CAP
    jae .full
    inc dword [r10 + rax * 4]
    imul rax, rax, BUCKET_CAP
    add rax, r11
    shl rax, 4
    lea r10, [rel g_buckets]
    mov [r10 + rax], ecx
    mov [r10 + rax + 4], edx
    mov [r10 + rax + 8], r8d
    inc qword [rel g_fluid_pending]
    ret
.full:
    cmp dword [rel g_full_warned], 0
    jne .quiet
    mov dword [rel g_full_warned], 1
    push rcx
    push rdx
    push r8
    sub rsp, 32
    mov ecx, LOG_LEVEL_WARN
    lea rdx, [rel str_full]
    call log_msg
    add rsp, 32
    pop r8
    pop rdx
    pop rcx
.quiet:
    ret

; -----------------------------------------------------------------------------
; fluid_schedule_around — the cell and its 6 neighbours.
;   in:  ecx = x, edx = y, r8d = z, r9d = delay
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC fluid_schedule_around, 0, rbx, rsi, rdi, r12, r13
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    mov r12d, r9d
    call fluid_schedule
    xor r13d, r13d
.nb:
    lea rax, [rel nb6_dx]
    mov ecx, ebx
    add ecx, [rax + r13 * 4]
    lea rax, [rel nb6_dy]
    mov edx, esi
    add edx, [rax + r13 * 4]
    lea rax, [rel nb6_dz]
    mov r8d, edi
    add r8d, [rax + r13 * 4]
    mov r9d, r12d
    call fluid_schedule
    inc r13d
    cmp r13d, 6
    jb .nb
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; liquid_level — what a block is for liquid family `src`.
;   in:  eax = block id (-1 unknown), r12d = source id of the family
;   out: eax = 0 source (or waterlogged, for water), 1..7 level, 8 falling,
;        -1 not this liquid
;   clobbers: rax, rcx
; -----------------------------------------------------------------------------
liquid_level:
    cmp eax, 0
    jle .no
    cmp eax, r12d
    je .source
    lea rcx, [rel g_block_shape]
    cmp byte [rcx + rax], SHAPE_FLUID
    jne .not_flowing
    lea rcx, [rel g_block_source]
    cmp [rcx + rax * 2], r12w
    jne .no
    lea rcx, [rel g_block_state]
    movzx eax, byte [rcx + rax]
    inc eax                             ; level = state + 1 (falling: 8)
    ret
.not_flowing:
    lea rcx, [rel g_block_flags]
    test byte [rcx + rax], BLOCKF_WATERLOGGED
    jz .no
    cmp r12d, [rel g_block_water]
    jne .no
.source:
    xor eax, eax
    ret
.no:
    mov eax, -1
    ret

; replaceable — eax = 1 if liquid may flow into block eax (air, a plant)
replaceable:
    test eax, eax
    jz .yes
    cmp eax, -1
    je .no
    lea rcx, [rel g_block_flags]
    test byte [rcx + rax], BLOCKF_WATERLOGGED
    jnz .no
    lea rcx, [rel g_block_shape]
    movzx ecx, byte [rcx + rax]
    cmp ecx, SHAPE_PLANT
    je .yes
    cmp ecx, SHAPE_TALL_PLANT
    je .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; -----------------------------------------------------------------------------
; family_near — the liquid of a flowing cell, or of a source/flowing block
; next to (or above) an empty cell.
;   in:  eax = the cell's block, ebx/esi/edi = x, y, z
;   out: eax = source id of the family, 0 = none
;   clobbers: volatile registers (not rbx, rsi, rdi, r12+)
; -----------------------------------------------------------------------------
PROC family_near, 0, r13, r14
    lea rcx, [rel g_block_shape]
    cmp byte [rcx + rax], SHAPE_FLUID
    jne .search
    lea rcx, [rel g_block_source]
    movzx eax, word [rcx + rax * 2]
    RETURN
.search:
    mov r13d, -1                        ; check above (-1), then the 4 sides
.n:
    mov ecx, ebx
    lea edx, [esi + 1]
    mov r8d, edi
    cmp r13d, -1
    je .look
    lea rax, [rel side_dx]
    add ecx, [rax + r13 * 4]
    dec edx
    lea rax, [rel side_dz]
    add r8d, [rax + r13 * 4]
.look:
    call phys_block
    cmp eax, 0
    jle .next
    lea rcx, [rel g_block_flowing]
    movzx r14d, word [rcx + rax * 2]
    test r14d, r14d
    jz .not_source
    RETURN                              ; a source with a flowing block
.not_source:
    lea rcx, [rel g_block_shape]
    cmp byte [rcx + rax], SHAPE_FLUID
    jne .not_fluid
    lea rcx, [rel g_block_source]
    movzx eax, word [rcx + rax * 2]
    RETURN
.not_fluid:
    lea rcx, [rel g_block_flags]
    test byte [rcx + rax], BLOCKF_WATERLOGGED
    jz .next
    mov eax, [rel g_block_water]        ; (river weed: water)
    lea rcx, [rel g_block_flowing]
    cmp word [rcx + rax * 2], 0
    je .next
    RETURN
.next:
    inc r13d
    cmp r13d, 4
    jl .n
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; rests — does the block at (x, y, z) stand on something liquid can't fall
; through (not air or a plant)?
;   in:  ecx, edx, r8d = the block's position
;   out: eax = 1 / 0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC rests, 0
    dec edx
    call phys_block
    call replaceable
    xor eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; update_cell — work out and set what one cell should hold.
;   in:  ecx = x, edx = y, r8d = z
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define U_CUR       0
%define U_BEST      4
%define U_FLOWING   8
%define U_RANGE     12
%define U_SIDE      16
%define U_NB        20
%define U_LEVEL     24
PROC update_cell, 32, rbx, rsi, rdi, r12, r13
    mov ebx, ecx
    mov esi, edx
    mov edi, r8d
    inc qword [rel g_fluid_updates]
    call phys_block
    mov [LOCAL(U_CUR)], eax
    cmp eax, -1
    je .done                            ; not generated
    ; only empty cells and flowing liquid change
    test eax, eax
    jz .candidate
    lea rcx, [rel g_block_shape]
    cmp byte [rcx + rax], SHAPE_FLUID
    je .candidate
    call replaceable
    test eax, eax
    jz .done
.candidate:
    mov eax, [LOCAL(U_CUR)]
    call family_near
    test eax, eax
    jz .done
    mov r12d, eax                       ; the liquid's source block
    lea rcx, [rel g_block_flowing]
    movzx eax, word [rcx + r12 * 2]
    test eax, eax
    jz .done                            ; (a liquid that doesn't flow)
    mov [LOCAL(U_FLOWING)], eax
    lea rcx, [rel g_block_frange]
    movzx eax, byte [rcx + rax]
    mov [LOCAL(U_RANGE)], eax

    ; the same liquid above: falling
    mov ecx, ebx
    lea edx, [esi + 1]
    mov r8d, edi
    call phys_block
    call liquid_level
    test eax, eax
    js .sideways
    mov r13d, FLUID_FALLING
    jmp .apply
.sideways:
    mov dword [LOCAL(U_BEST)], 99
    mov dword [LOCAL(U_SIDE)], 0
.side:
    mov eax, [LOCAL(U_SIDE)]
    lea rcx, [rel side_dx]
    mov r13d, ebx
    add r13d, [rcx + rax * 4]           ; neighbour x
    lea rcx, [rel side_dz]
    mov r8d, edi
    add r8d, [rcx + rax * 4]
    mov [LOCAL(U_NB)], r8d
    mov ecx, r13d
    mov edx, esi
    call phys_block
    call liquid_level
    test eax, eax
    js .side_next
    jz .side_take                       ; a source spreads anyway
    ; flowing / falling: only where it rests on something
    mov [LOCAL(U_LEVEL)], eax           ; its level
    mov ecx, r13d
    mov edx, esi
    mov r8d, [LOCAL(U_NB)]
    call rests
    test eax, eax
    jz .side_next
    mov eax, [LOCAL(U_LEVEL)]
    cmp eax, 8
    jne .side_take
    xor eax, eax                        ; resting falling liquid: like a source
.side_take:
    inc eax
    cmp eax, [LOCAL(U_BEST)]
    jge .side_next
    mov [LOCAL(U_BEST)], eax
.side_next:
    inc dword [LOCAL(U_SIDE)]
    cmp dword [LOCAL(U_SIDE)], 4
    jb .side
    mov eax, [LOCAL(U_BEST)]
    mov r13d, NONE
    cmp eax, [LOCAL(U_RANGE)]
    jg .apply
    lea r13d, [eax - 1]                 ; level L -> state L - 1

.apply:
    mov eax, [LOCAL(U_CUR)]
    cmp r13d, NONE
    jne .liquid
    ; nothing: only flowing liquid dries up (air and plants stay)
    lea rcx, [rel g_block_shape]
    cmp byte [rcx + rax], SHAPE_FLUID
    jne .done
    xor r9d, r9d
    jmp .set
.liquid:
    mov r9d, [LOCAL(U_FLOWING)]
    add r9d, r13d                       ; the flowing block's state
    cmp r9d, eax
    je .done                            ; already so
.set:
    inc qword [rel g_fluid_changes]
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    call edit_apply                     ; (announces it, schedules around)
    test eax, eax
    jnz .done
    ; the column is busy: try again next tick
    mov ecx, ebx
    mov edx, esi
    mov r8d, edi
    mov r9d, 1
    call fluid_schedule
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; fluid_tick — run the updates due in this tick.
;   in:  rcx = tick number
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC fluid_tick, 0, rbx, rsi, rdi, r12
    mov [rel g_fluid_tick], rcx
    mov eax, ecx
    and eax, BUCKETS - 1
    mov r12d, eax                       ; this tick's bucket
    lea rcx, [rel g_bucket_n]
    mov ebx, [rcx + r12 * 4]            ; cells in it
    mov dword [rcx + r12 * 4], 0
    xor esi, esi
.cell:
    cmp esi, ebx
    jae .done
    mov eax, r12d
    imul eax, eax, BUCKET_CAP
    add eax, esi
    shl rax, 4
    lea rdi, [rel g_buckets]
    add rdi, rax
    dec qword [rel g_fluid_pending]
    mov ecx, [rdi]
    mov edx, [rdi + 4]
    mov r8d, [rdi + 8]
    cmp esi, MAX_PER_TICK
    jae .later
    call update_cell
    jmp .next
.later:
    mov r9d, 1                          ; too many now: next tick
    call fluid_schedule
.next:
    inc esi
    jmp .cell
.done:
    RETURN
ENDPROC
