; =============================================================================
; physics.asm — block collision for the simulation (milestone 16, D85).
;
; Every block id resolves to a collision kind and movement flags:
;   collision: none (air, liquids, plants, signs, pressure plates), a full
;   cube (cubes), or boxes by its shape and state (slabs, stairs, fences,
;   doors, ...); `collision = none | full` in a block file overrides it.
;   Fences, fence gates and walls are 1.5 blocks high, so they can't be
;   jumped over. Stairs collide as their slab plus the back half (corners
;   are not modelled).
;   movement flags: climbable (ladders and vines by default; `climbable`),
;   water and lava (`liquid`).
; Columns that are not generated yet collide as solid blocks, so nothing
; falls into unloaded ground.
;
; Boxes and positions are doubles (exact far from the origin). An AABB is
; 6 doubles: min x, y, z, max x, y, z.
;
; Public API:
;   phys_init()                         after blocks_load
;   phys_block(ecx=x, edx=y, r8d=z) -> eax id, -1 if not generated
;   phys_gather(rcx = region AABB) -> eax box count (the solid boxes of all
;                                       blocks touching the region)
;   phys_clip(rcx = AABB, edx = axis 0..2, xmm0 = move) -> xmm0 the move
;                                       limited by the gathered boxes
;   phys_overlap(rcx = AABB) -> eax 1 if a gathered box intersects it
;   phys_touch(rcx = AABB) -> eax MOVE_* flags of the blocks it touches
;   g_block_coll, g_block_move          resolved tables (by block id)
; =============================================================================
%define PHYSICS_IMPL
%include "macros.inc"
%include "log.inc"
%include "block.inc"
%include "world_api.inc"
%include "section.inc"
%include "physics.inc"

global phys_init, phys_block, phys_gather, phys_clip, phys_overlap, phys_touch
global g_block_coll, g_block_move, g_phys_boxes

%define MAX_BOXES       2048
%define BOX_BYTES       48
%define COLL_NONE       0
%define COLL_FULL       1
%define COLL_SHAPE      2
%define MAX_SHAPE_BOXES 8

section .rdata
align 8
c_eps:          dq 1.0e-7
c_sixteenth:    dq 0.0625
c_one_d:        dq 1.0
; neighbour offsets N, E, S, W: dx, dz
dir_dx:         dd 0, 1, 0, -1
dir_dz:         dd -1, 0, 1, 0
; back half of a stair by facing (quadrant bits qx + 2*qz; as shapes.asm)
back_mask:      db 0b0011, 0b1010, 0b1100, 0b0101
; ---- boxes facing north (-Z), 1/16 units: x0, y0, z0, x1, y1, z1 ----------------
k_full:         db 0, 0, 0, 16, 16, 16
k_slab_bottom:  db 0, 0, 0, 16, 8, 16
k_slab_top:     db 0, 8, 0, 16, 16, 16
k_fence_post:   db 6, 0, 6, 10, 24, 10
k_fence_arm:    db 6, 0, 0, 10, 24, 6
k_gate_closed:  db 0, 0, 6, 16, 24, 10
k_door_closed:  db 0, 0, 0, 16, 16, 3
k_door_left:    db 0, 0, 0, 3, 16, 16
k_door_right:   db 13, 0, 0, 16, 16, 16
k_trap_bottom:  db 0, 0, 0, 16, 3, 16
k_trap_top:     db 0, 13, 0, 16, 16, 16
k_trap_open:    db 0, 0, 0, 16, 16, 3
k_ladder:       db 0, 0, 0, 16, 16, 2
k_wall_post:    db 4, 0, 4, 12, 24, 12
k_wall_arm:     db 5, 0, 0, 11, 24, 8
k_pane_post:    db 7, 0, 7, 9, 16, 9
k_pane_arm:     db 7, 0, 0, 9, 16, 7
k_spike:        db 4, 0, 4, 12, 16, 12
k_stalk:        db 6, 0, 6, 10, 16, 10
str_box_full:   db "physics: too many collision boxes in one move; some were skipped", 0

section .bss
g_block_coll:   resb MAX_BLOCK_TYPES
g_block_move:   resb MAX_BLOCK_TYPES
alignb 16
g_phys_boxes:   resb MAX_BOXES * BOX_BYTES
g_box_count:    resd 1
g_box_warned:   resd 1
g_shape_tmp:    resb MAX_SHAPE_BOXES * 6

section .text

; -----------------------------------------------------------------------------
; phys_init — resolve every block's collision kind and movement flags.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC phys_init, 0, rbx
    xor ebx, ebx
.next:
    cmp ebx, [rel g_block_count]
    jae .done
    lea rax, [rel g_block_phys]
    movzx r8d, byte [rax + rbx]         ; settings as written
    lea rax, [rel g_block_shape]
    movzx r9d, byte [rax + rbx]
    ; collision by shape
    mov r10d, COLL_SHAPE
    cmp r9d, SHAPE_CUBE
    jne .not_cube
    mov r10d, COLL_FULL
.not_cube:
    cmp r9d, SHAPE_PLANT
    je .no_coll
    cmp r9d, SHAPE_TALL_PLANT
    je .no_coll
    cmp r9d, SHAPE_SIGN
    je .no_coll
    cmp r9d, SHAPE_WALL_SIGN
    je .no_coll
    cmp r9d, SHAPE_PLATE
    je .no_coll
    test r8d, BPHYS_LIQUID_MASK
    jz .coll_set
.no_coll:
    mov r10d, COLL_NONE
.coll_set:
    mov eax, r8d
    and eax, BPHYS_COLL_MASK
    cmp eax, BPHYS_COLL_NONE
    jne .not_none
    mov r10d, COLL_NONE
.not_none:
    cmp eax, BPHYS_COLL_FULL
    jne .not_full
    mov r10d, COLL_FULL
.not_full:
    test ebx, ebx
    jnz .not_air
    xor r10d, r10d                      ; air
.not_air:
    lea rax, [rel g_block_coll]
    mov [rax + rbx], r10b
    ; movement flags
    xor r10d, r10d
    cmp r9d, SHAPE_LADDER
    jne .climb_set
    mov r10d, MOVE_CLIMB
.climb_set:
    mov eax, r8d
    and eax, BPHYS_CLIMB_MASK
    cmp eax, 1 << BPHYS_CLIMB_SHIFT
    jne .climb_yes
    xor r10d, r10d                      ; climbable = 0
.climb_yes:
    cmp eax, 2 << BPHYS_CLIMB_SHIFT
    jne .liquid
    mov r10d, MOVE_CLIMB
.liquid:
    mov eax, r8d
    and eax, BPHYS_LIQUID_MASK
    cmp eax, BPHYS_LIQUID_WATER
    jne .not_water
    or r10d, MOVE_WATER
.not_water:
    cmp eax, BPHYS_LIQUID_LAVA
    jne .not_lava
    or r10d, MOVE_LAVA
.not_lava:
    ; waterlogged blocks (river weed) stand in water
    lea rax, [rel g_block_flags]
    test byte [rax + rbx], BLOCKF_WATERLOGGED
    jz .store_move
    or r10d, MOVE_WATER
.store_move:
    lea rax, [rel g_block_move]
    mov [rax + rbx], r10b
    inc ebx
    jmp .next
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; phys_block — block id at a world position, for the simulation.
;   in:  ecx = x, edx = y, r8d = z
;   out: eax = id (air above / below the world), -1 = column not generated
;   clobbers: rax, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
PROC phys_block, 0, rbx, rsi
    add edx, -WORLD_MIN_Y
    js .air
    cmp edx, SECTIONS_PER_COLUMN * SECTION_SIZE
    jae .air
    ; idx = (y&31)<<10 | (z&31)<<5 | (x&31)
    mov ebx, edx
    and ebx, 31
    shl ebx, 10
    mov eax, r8d
    and eax, 31
    shl eax, 5
    or ebx, eax
    mov eax, ecx
    and eax, 31
    or ebx, eax
    mov esi, edx
    shr esi, 5                          ; section index
    sar ecx, 5
    mov edx, r8d
    sar edx, 5
    call world_column
    test rax, rax
    jz .unknown
    mov ecx, [rax + COLUMN.state]
    cmp ecx, COL_GENERATED
    jb .unknown
    mov rcx, [rax + COLUMN.sections + rsi * 8]
    mov edx, ebx
    call section_get
    RETURN
.unknown:
    mov eax, -1
    RETURN
.air:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; rotate_box — copy a north-frame box, turned by r quarter turns (clockwise
; seen from above), to the shape list.
;   in:  rcx = box (6 bytes), edx = r, r15 = write cursor (advanced by 6)
;   clobbers: rax, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
rotate_box:
    movzx r8d, byte [rcx]               ; x0
    movzx r9d, byte [rcx + 2]           ; z0
    movzx r10d, byte [rcx + 3]          ; x1
    movzx r11d, byte [rcx + 5]          ; z1
    mov al, [rcx + 1]
    mov [r15 + 1], al
    mov al, [rcx + 4]
    mov [r15 + 4], al
    and edx, 3
.rot:
    test edx, edx
    jz .store
    ; (x0, z0, x1, z1) -> (16 - z1, x0, 16 - z0, x1)
    mov eax, 16
    sub eax, r11d
    mov ecx, 16
    sub ecx, r9d
    mov r9d, r8d
    mov r11d, r10d
    mov r8d, eax
    mov r10d, ecx
    dec edx
    jmp .rot
.store:
    mov [r15], r8b
    mov [r15 + 2], r9b
    mov [r15 + 3], r10b
    mov [r15 + 5], r11b
    add r15, 6
    ret

; -----------------------------------------------------------------------------
; connections — which sides a fence, wall or pane joins (as shapes.asm).
;   in:  ecx = x, edx = y, r8d = z, r9d = own shape
;   out: eax = bits N, E, S, W
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC connections, 16, rbx, rsi, rdi, r12, r13
    mov esi, ecx
    mov edi, edx
    mov r12d, r8d
    mov r13d, r9d
    xor ebx, ebx                        ; direction
    mov dword [LOCAL(0)], 0
.dir:
    lea rax, [rel dir_dx]
    mov ecx, esi
    add ecx, [rax + rbx * 4]
    lea rax, [rel dir_dz]
    mov r8d, r12d
    add r8d, [rax + rbx * 4]
    mov edx, edi
    call phys_block
    cmp eax, -1
    je .next
    lea rcx, [rel g_block_opaque]
    cmp byte [rcx + rax], 0
    jne .join
    lea rcx, [rel g_block_shape]
    movzx eax, byte [rcx + rax]
    cmp eax, r13d
    je .join
    cmp r13d, SHAPE_FENCE
    jne .not_fence
    cmp eax, SHAPE_FENCE_GATE
    je .join
.not_fence:
    cmp r13d, SHAPE_PANE
    jne .next
    cmp eax, SHAPE_WALL
    jne .next
.join:
    bts dword [LOCAL(0)], ebx
.next:
    inc ebx
    cmp ebx, 4
    jb .dir
    mov eax, [LOCAL(0)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; shape_boxes — collision boxes of a shaped block (1/16 units, may reach up
; to 24 for fences and walls) into g_shape_tmp.
;   in:  ecx = id, edx = x, r8d = y, r9d = z
;   out: eax = box count
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC shape_boxes, 16, rbx, rsi, rdi, r12, r13, r14, r15
    mov r12d, edx                       ; x
    mov r13d, r8d                       ; y
    mov r14d, r9d                       ; z
    lea rax, [rel g_block_state]
    movzx ebx, byte [rax + rcx]         ; state
    lea rax, [rel g_block_shape]
    movzx esi, byte [rax + rcx]         ; shape
    lea r15, [rel g_shape_tmp]
    cmp esi, SHAPE_SLAB
    je .slab
    cmp esi, SHAPE_STAIRS
    je .stairs
    cmp esi, SHAPE_FENCE
    je .fence
    cmp esi, SHAPE_FENCE_GATE
    je .gate
    cmp esi, SHAPE_DOOR
    je .door
    cmp esi, SHAPE_TRAPDOOR
    je .trapdoor
    cmp esi, SHAPE_LADDER
    je .ladder
    cmp esi, SHAPE_WALL
    je .wall
    cmp esi, SHAPE_PANE
    je .pane
    cmp esi, SHAPE_SPIKE
    je .spike
    cmp esi, SHAPE_STALK
    je .stalk
    ; pillars and anything else: a full cube
    lea rcx, [rel k_full]
    jmp .one
.spike:
    lea rcx, [rel k_spike]
    jmp .one
.stalk:
    lea rcx, [rel k_stalk]
    jmp .one
.slab:
    lea rcx, [rel k_slab_bottom]
    test ebx, 1
    jz .one
    lea rcx, [rel k_slab_top]
.one:
    xor edx, edx
    call rotate_box
    jmp .done

.stairs:
    lea rcx, [rel k_slab_bottom]
    test ebx, 4
    jz .st_base
    lea rcx, [rel k_slab_top]
.st_base:
    xor edx, edx
    call rotate_box
    mov eax, ebx
    and eax, 3
    lea rcx, [rel back_mask]
    movzx ecx, byte [rcx + rax]         ; quadrants
    mov dl, 8                           ; step y0, y1
    mov r8b, 16
    test ebx, 4
    jz .st_q
    xor dl, dl
    mov r8b, 8
.st_q:
    xor r9d, r9d
.st_quad:
    bt ecx, r9d
    jnc .st_next
    mov eax, r9d
    and eax, 1
    shl eax, 3
    mov [r15], al
    add al, 8
    mov [r15 + 3], al
    mov eax, r9d
    shr eax, 1
    shl eax, 3
    mov [r15 + 2], al
    add al, 8
    mov [r15 + 5], al
    mov [r15 + 1], dl
    mov [r15 + 4], r8b
    add r15, 6
.st_next:
    inc r9d
    cmp r9d, 4
    jb .st_quad
    jmp .done

.fence:
    lea rcx, [rel k_fence_post]
    lea rdi, [rel k_fence_arm]
    mov r9d, SHAPE_FENCE
    jmp .post_arms
.wall:
    lea rcx, [rel k_wall_post]
    lea rdi, [rel k_wall_arm]
    mov r9d, SHAPE_WALL
    jmp .post_arms
.pane:
    lea rcx, [rel k_pane_post]
    lea rdi, [rel k_pane_arm]
    mov r9d, SHAPE_PANE
.post_arms:
    mov [LOCAL(0)], r9d
    xor edx, edx
    call rotate_box                     ; the post
    INVOKE connections, r12, r13, r14, [LOCAL(0)]
    mov ebx, eax
    cmp dword [LOCAL(0)], SHAPE_PANE
    jne .arms
    test ebx, ebx
    jnz .arms
    mov ebx, 0b1111                     ; a lone pane is a cross
.arms:
    xor esi, esi
.arm:
    bt ebx, esi
    jnc .arm_next
    mov rcx, rdi
    mov edx, esi
    call rotate_box
.arm_next:
    inc esi
    cmp esi, 4
    jb .arm
    jmp .done

.gate:
    test ebx, 4
    jnz .done                           ; open: walk through
    lea rcx, [rel k_gate_closed]
    mov edx, ebx
    call rotate_box
    jmp .done

.door:
    lea rcx, [rel k_door_closed]
    test ebx, 8
    jz .door_add
    lea rcx, [rel k_door_left]
    test ebx, 16
    jz .door_add
    lea rcx, [rel k_door_right]
.door_add:
    mov edx, ebx
    call rotate_box
    jmp .done

.trapdoor:
    lea rcx, [rel k_trap_open]
    test ebx, 8
    jnz .trap_add
    lea rcx, [rel k_trap_bottom]
    test ebx, 4
    jz .trap_add
    lea rcx, [rel k_trap_top]
.trap_add:
    mov edx, ebx
    call rotate_box
    jmp .done

.ladder:
    lea rcx, [rel k_ladder]
    mov edx, ebx
    call rotate_box

.done:
    lea rax, [rel g_shape_tmp]
    sub r15, rax
    mov rax, r15
    xor edx, edx
    mov ecx, 6
    div ecx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; add_box — append a box: cell (ecx, edx, r8d) + r9 (6 bytes, 1/16 units),
; or the whole cell when r9 = 0.
;   clobbers: rax, rcx, rdx, r8, r10, xmm0-xmm3
; -----------------------------------------------------------------------------
add_box:
    mov eax, [rel g_box_count]
    cmp eax, MAX_BOXES
    jae .full
    imul rax, rax, BOX_BYTES
    lea r10, [rel g_phys_boxes]
    add r10, rax
    cvtsi2sd xmm0, ecx
    cvtsi2sd xmm1, edx
    cvtsi2sd xmm2, r8d
    test r9, r9
    jz .cell
    ; min = cell + b0 / 16, max = cell + b1 / 16
    movzx eax, byte [r9]
    cvtsi2sd xmm3, eax
    mulsd xmm3, [rel c_sixteenth]
    addsd xmm3, xmm0
    movsd [r10], xmm3
    movzx eax, byte [r9 + 3]
    cvtsi2sd xmm3, eax
    mulsd xmm3, [rel c_sixteenth]
    addsd xmm3, xmm0
    movsd [r10 + 24], xmm3
    movzx eax, byte [r9 + 1]
    cvtsi2sd xmm3, eax
    mulsd xmm3, [rel c_sixteenth]
    addsd xmm3, xmm1
    movsd [r10 + 8], xmm3
    movzx eax, byte [r9 + 4]
    cvtsi2sd xmm3, eax
    mulsd xmm3, [rel c_sixteenth]
    addsd xmm3, xmm1
    movsd [r10 + 32], xmm3
    movzx eax, byte [r9 + 2]
    cvtsi2sd xmm3, eax
    mulsd xmm3, [rel c_sixteenth]
    addsd xmm3, xmm2
    movsd [r10 + 16], xmm3
    movzx eax, byte [r9 + 5]
    cvtsi2sd xmm3, eax
    mulsd xmm3, [rel c_sixteenth]
    addsd xmm3, xmm2
    movsd [r10 + 40], xmm3
    inc dword [rel g_box_count]
    ret
.cell:
    movsd [r10], xmm0
    movsd [r10 + 8], xmm1
    movsd [r10 + 16], xmm2
    addsd xmm0, [rel c_one_d]
    addsd xmm1, [rel c_one_d]
    addsd xmm2, [rel c_one_d]
    movsd [r10 + 24], xmm0
    movsd [r10 + 32], xmm1
    movsd [r10 + 40], xmm2
    inc dword [rel g_box_count]
    ret
.full:
    cmp dword [rel g_box_warned], 0
    jne .quiet
    mov dword [rel g_box_warned], 1
    push rcx                            ; (keeps the stack aligned for log_msg:
    sub rsp, 32                         ;  8 + 8 + 32 + the caller's frame)
    mov ecx, LOG_LEVEL_WARN
    lea rdx, [rel str_box_full]
    call log_msg
    add rsp, 32
    pop rcx
.quiet:
    ret

; floor of a double -> eax.   in: xmm0   clobbers: xmm0
%macro FLOOR_I 2
    movsd xmm0, %2
    roundsd xmm0, xmm0, 9
    cvttsd2si %1, xmm0
%endmacro

; -----------------------------------------------------------------------------
; cell_range — the cells an AABB touches: [floor(min), floor(max - eps)]
; per axis (a box ending exactly on a cell border doesn't touch that cell).
;   in:  rcx = AABB, rdx = out 6 dwords (x0, y0, z0, x1, y1, z1)
;   clobbers: rax, xmm0
; -----------------------------------------------------------------------------
cell_range:
    FLOOR_I eax, [rcx]
    mov [rdx], eax
    FLOOR_I eax, [rcx + 8]
    mov [rdx + 4], eax
    FLOOR_I eax, [rcx + 16]
    mov [rdx + 8], eax
%assign i 0
%rep 3
    movsd xmm0, [rcx + 24 + i * 8]
    subsd xmm0, [rel c_eps]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [rdx + 12 + i * 4], eax
%assign i i + 1
%endrep
    ret

; -----------------------------------------------------------------------------
; phys_gather — collect the solid boxes of every block touching a region
; (one extra layer below: fences and walls reach 1.5 blocks up).
;   in:  rcx = region AABB
;   out: eax = box count
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define G_RANGE     0                   ; 6 dwords
%define G_X         24
%define G_Y         28
%define G_Z         32
PROC phys_gather, 48, rbx, rsi, rdi, r12, r13
    mov dword [rel g_box_count], 0
    lea rdx, [LOCAL(G_RANGE)]
    call cell_range
    dec dword [LOCAL(G_RANGE) + 4]      ; y0 - 1
    mov eax, [LOCAL(G_RANGE) + 4]
    mov [LOCAL(G_Y)], eax
.y:
    mov eax, [LOCAL(G_RANGE) + 8]
    mov [LOCAL(G_Z)], eax
.z:
    mov eax, [LOCAL(G_RANGE)]
    mov [LOCAL(G_X)], eax
.x:
    mov ecx, [LOCAL(G_X)]
    mov edx, [LOCAL(G_Y)]
    mov r8d, [LOCAL(G_Z)]
    call phys_block
    cmp eax, -1
    je .solid
    lea rcx, [rel g_block_coll]
    movzx edx, byte [rcx + rax]
    cmp edx, COLL_NONE
    je .next
    cmp edx, COLL_FULL
    je .solid
    ; shaped: its boxes
    INVOKE shape_boxes, rax, [LOCAL(G_X)], [LOCAL(G_Y)], [LOCAL(G_Z)]
    mov ebx, eax
    lea rsi, [rel g_shape_tmp]
.shape_box:
    test ebx, ebx
    jz .next
    mov ecx, [LOCAL(G_X)]
    mov edx, [LOCAL(G_Y)]
    mov r8d, [LOCAL(G_Z)]
    mov r9, rsi
    call add_box
    add rsi, 6
    dec ebx
    jmp .shape_box
.solid:
    mov ecx, [LOCAL(G_X)]
    mov edx, [LOCAL(G_Y)]
    mov r8d, [LOCAL(G_Z)]
    xor r9d, r9d
    call add_box
.next:
    inc dword [LOCAL(G_X)]
    mov eax, [LOCAL(G_X)]
    cmp eax, [LOCAL(G_RANGE) + 12]
    jle .x
    inc dword [LOCAL(G_Z)]
    mov eax, [LOCAL(G_Z)]
    cmp eax, [LOCAL(G_RANGE) + 20]
    jle .z
    inc dword [LOCAL(G_Y)]
    mov eax, [LOCAL(G_Y)]
    cmp eax, [LOCAL(G_RANGE) + 16]
    jle .y
    mov eax, [rel g_box_count]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; phys_clip — limit a move along one axis by the gathered boxes.
;   in:  rcx = AABB, edx = axis (0 x, 1 y, 2 z), xmm0 = move (double)
;   out: xmm0 = allowed move (same sign, |out| <= |in|)
;   clobbers: rax, rdx, r8-r11, xmm1-xmm4
; -----------------------------------------------------------------------------
phys_clip:
    ; the two other axes
    lea r8d, [edx + 1]
    cmp r8d, 3
    jb .a1
    xor r8d, r8d
.a1:
    lea r9d, [r8d + 1]
    cmp r9d, 3
    jb .a2
    xor r9d, r9d
.a2:
    lea r10, [rel g_phys_boxes]
    mov r11d, [rel g_box_count]
    movsd xmm4, [rel c_eps]
.box:
    test r11d, r11d
    jz .done
    ; overlap on the other axes: box.max > p.min + eps and box.min < p.max - eps
    movsd xmm1, [rcx + r8 * 8]
    addsd xmm1, xmm4
    comisd xmm1, [r10 + 24 + r8 * 8]
    jae .next
    movsd xmm1, [rcx + 24 + r8 * 8]
    subsd xmm1, xmm4
    comisd xmm1, [r10 + r8 * 8]
    jbe .next
    movsd xmm1, [rcx + r9 * 8]
    addsd xmm1, xmm4
    comisd xmm1, [r10 + 24 + r9 * 8]
    jae .next
    movsd xmm1, [rcx + 24 + r9 * 8]
    subsd xmm1, xmm4
    comisd xmm1, [r10 + r9 * 8]
    jbe .next
    xorps xmm2, xmm2
    comisd xmm0, xmm2
    je .done
    jb .negative
    ; moving +: a box beyond our max side
    movsd xmm1, [rcx + 24 + rdx * 8]
    subsd xmm1, xmm4
    comisd xmm1, [r10 + rdx * 8]
    ja .next                            ; (it starts behind our face)
    movsd xmm3, [r10 + rdx * 8]
    subsd xmm3, [rcx + 24 + rdx * 8]
    maxsd xmm3, xmm2
    minsd xmm0, xmm3
    jmp .next
.negative:
    movsd xmm1, [rcx + rdx * 8]
    addsd xmm1, xmm4
    comisd xmm1, [r10 + 24 + rdx * 8]
    jb .next
    movsd xmm3, [r10 + 24 + rdx * 8]
    subsd xmm3, [rcx + rdx * 8]
    minsd xmm3, xmm2
    maxsd xmm0, xmm3
.next:
    add r10, BOX_BYTES
    dec r11d
    jmp .box
.done:
    ret

; -----------------------------------------------------------------------------
; phys_overlap — does a gathered box intersect the AABB (by more than eps)?
;   in:  rcx = AABB
;   out: eax = 1 / 0
;   clobbers: rax, rdx, r10, r11, xmm1, xmm4
; -----------------------------------------------------------------------------
phys_overlap:
    lea r10, [rel g_phys_boxes]
    mov r11d, [rel g_box_count]
    movsd xmm4, [rel c_eps]
.box:
    test r11d, r11d
    jz .none
    xor edx, edx
.axis:
    movsd xmm1, [rcx + rdx * 8]
    addsd xmm1, xmm4
    comisd xmm1, [r10 + 24 + rdx * 8]
    jae .next
    movsd xmm1, [rcx + 24 + rdx * 8]
    subsd xmm1, xmm4
    comisd xmm1, [r10 + rdx * 8]
    jbe .next
    inc edx
    cmp edx, 3
    jb .axis
    mov eax, 1
    ret
.next:
    add r10, BOX_BYTES
    dec r11d
    jmp .box
.none:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; phys_touch — movement flags of the blocks an AABB is inside.
;   in:  rcx = AABB
;   out: eax = MOVE_* bits
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC phys_touch, 48, rbx
    lea rdx, [LOCAL(G_RANGE)]
    call cell_range
    xor ebx, ebx
    mov eax, [LOCAL(G_RANGE) + 4]
    mov [LOCAL(G_Y)], eax
.y:
    mov eax, [LOCAL(G_RANGE) + 8]
    mov [LOCAL(G_Z)], eax
.z:
    mov eax, [LOCAL(G_RANGE)]
    mov [LOCAL(G_X)], eax
.x:
    mov ecx, [LOCAL(G_X)]
    mov edx, [LOCAL(G_Y)]
    mov r8d, [LOCAL(G_Z)]
    call phys_block
    cmp eax, -1
    je .next
    lea rcx, [rel g_block_move]
    or bl, [rcx + rax]
.next:
    inc dword [LOCAL(G_X)]
    mov eax, [LOCAL(G_X)]
    cmp eax, [LOCAL(G_RANGE) + 12]
    jle .x
    inc dword [LOCAL(G_Z)]
    mov eax, [LOCAL(G_Z)]
    cmp eax, [LOCAL(G_RANGE) + 20]
    jle .z
    inc dword [LOCAL(G_Y)]
    mov eax, [LOCAL(G_Y)]
    cmp eax, [LOCAL(G_RANGE) + 16]
    jle .y
    mov eax, ebx
    RETURN
ENDPROC
