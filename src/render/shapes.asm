; =============================================================================
; shapes.asm — geometry of shaped blocks (slabs, stairs, fences, doors, ...).
;
; A shaped block is drawn as a few boxes in 1/16-block units, built from its
; shape (g_block_shape), its state (g_block_state: facing, half, open, ...)
; and its six neighbours (stair corners, fence/wall/pane connections, pillar
; parts). Boxes are described for facing north (-Z) and rotated about the
; vertical axis for the other facings.
; Each visible box face becomes one "model quad" (bit 31 set) in the
; section's quad list; shaders/chunk.vert expands it:
;   lo: bits 0-14 block x, y, z (5 bits each)   15-26 box min x, y, z (4 bits)
;       28-30 face   31 = 1 (model quad)
;   hi: bits 0-15 block id   16-27 box size-1 x, y, z (4 bits each)
; A box face lying on the block's boundary is skipped when the neighbour
; there is opaque.
;
; Public API:
;   shapes_emit(vol, out, count) -> rax new count
;       vol = the mesher's 34^3 padded u16 volume; appends model quads for
;       every shaped block of the section (stops at MESH_MAX_QUADS)
; =============================================================================
%include "macros.inc"
%include "world.inc"

global shapes_emit

extern g_block_opaque, g_block_shape, g_block_state

%define PAD             34
%define PAD2            (PAD * PAD)
%define ORIGIN          (1 + PAD + PAD2)
%define MAX_BOXES       16

section .rdata
; neighbour offsets in the volume, by direction: N, E, S, W, up, down
align 8
dir_off:        dq -PAD, 1, PAD, -1, PAD2, -PAD2
; quadrants of the back half for each facing (bit = qx + 2*qz)
back_mask:      db 0b0011, 0b1010, 0b1100, 0b0101
; ---- boxes in the north frame: x0, y0, z0, x1, y1, z1 ------------------------
b_slab_bottom:  db 0, 0, 0, 16, 8, 16
b_slab_top:     db 0, 8, 0, 16, 16, 16
b_fence_post:   db 6, 0, 6, 10, 16, 10
b_fence_rail1:  db 7, 6, 0, 9, 9, 6
b_fence_rail2:  db 7, 12, 0, 9, 15, 6
b_gate_post1:   db 0, 5, 7, 2, 16, 9
b_gate_post2:   db 14, 5, 7, 16, 16, 9
b_gate_rail1:   db 2, 6, 7, 14, 9, 9
b_gate_rail2:   db 2, 12, 7, 14, 15, 9
b_gate_bars:    db 6, 9, 7, 10, 12, 9
b_gate_open1:   db 0, 6, 9, 2, 9, 16
b_gate_open2:   db 0, 12, 9, 2, 15, 16
b_gate_open3:   db 14, 6, 9, 16, 9, 16
b_gate_open4:   db 14, 12, 9, 16, 15, 16
b_door_closed:  db 0, 0, 0, 16, 16, 3
b_door_left:    db 0, 0, 0, 3, 16, 16
b_door_right:   db 13, 0, 0, 16, 16, 16
b_trap_bottom:  db 0, 0, 0, 16, 3, 16
b_trap_top:     db 0, 13, 0, 16, 16, 16
b_trap_open:    db 0, 0, 0, 16, 16, 3
b_ladder:       db 0, 0, 0, 16, 16, 1
b_sign_stick:   db 7, 0, 7, 9, 9, 9
b_sign_board:   db 0, 9, 7, 16, 16, 9
b_wall_sign:    db 0, 4, 0, 16, 12, 2
b_plate_up:     db 1, 0, 1, 15, 1, 15
b_plate_down:   db 2, 0, 2, 14, 1, 14
b_wall_post:    db 4, 0, 4, 12, 16, 12
b_wall_arm:     db 5, 0, 0, 11, 14, 8
b_pillar_base:  db 0, 0, 0, 16, 3, 16
b_pillar_cap:   db 0, 13, 0, 16, 16, 16
b_pane_post:    db 7, 0, 7, 9, 16, 9
b_pane_arm:     db 7, 0, 0, 9, 16, 7

align 8
shape_jump:     dq shapes_emit.s_none, shapes_emit.s_slab, shapes_emit.s_stairs
                dq shapes_emit.s_fence, shapes_emit.s_gate, shapes_emit.s_door
                dq shapes_emit.s_trapdoor, shapes_emit.s_ladder, shapes_emit.s_sign
                dq shapes_emit.s_wall_sign, shapes_emit.s_plate, shapes_emit.s_wall
                dq shapes_emit.s_pillar, shapes_emit.s_pane, shapes_emit.s_spike

section .text

; -----------------------------------------------------------------------------
; add_box — append a north-frame box rotated by r quarter turns (clockwise
; seen from above: north -> east -> south -> west).
;   in:  rcx = box (6 bytes), edx = r (0..3), r15 = write cursor (advanced)
;   clobbers: rax, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
add_box:
    movzx r8d, byte [rcx]               ; x0
    movzx r9d, byte [rcx + 2]           ; z0
    movzx r10d, byte [rcx + 3]          ; x1
    movzx r11d, byte [rcx + 5]          ; z1
    mov al, [rcx + 1]
    mov [r15 + 1], al                   ; y0
    mov al, [rcx + 4]
    mov [r15 + 4], al                   ; y1
    and edx, 3
.rot:
    test edx, edx
    jz .store
    ; (x0, z0, x1, z1) -> (16 - z1, x0, 16 - z0, x1)
    mov eax, 16
    sub eax, r11d                       ; new x0
    mov ecx, 16
    sub ecx, r9d                        ; new x1
    mov r9d, r8d                        ; new z0 = x0
    mov r11d, r10d                      ; new z1 = x1
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
; add_quadrants — append one box per set quadrant bit (bit = qx + 2*qz).
;   in:  ecx = mask, edx = y0, r8d = y1, r15 = write cursor
;   clobbers: rax, rcx, rdx, r9, r10
; -----------------------------------------------------------------------------
add_quadrants:
    xor r9d, r9d                        ; quadrant
.q:
    bt ecx, r9d
    jnc .next
    mov eax, r9d
    and eax, 1
    shl eax, 3                          ; x0
    mov [r15], al
    add al, 8
    mov [r15 + 3], al
    mov eax, r9d
    shr eax, 1
    shl eax, 3                          ; z0
    mov [r15 + 2], al
    add al, 8
    mov [r15 + 5], al
    mov [r15 + 1], dl
    mov [r15 + 4], r8b
    add r15, 6
.next:
    inc r9d
    cmp r9d, 4
    jb .q
    ret

; -----------------------------------------------------------------------------
; shapes_emit — append model quads for every shaped block of a section.
;   in:  rcx = volume (34^3 u16), rdx = out quads, r8 = current count
;   out: rax = new count
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define S_VOL       0
%define S_OUT       8
%define S_X         16
%define S_Y         20
%define S_Z         24
%define S_ID        28
%define S_P         32
%define S_STATE     40
%define S_CONN      44                  ; connection bits N, E, S, W
%define S_BOXES     48                  ; MAX_BOXES * 6 bytes
%define S_LOCALS    (48 + MAX_BOXES * 6 + 8)
PROC shapes_emit, S_LOCALS, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(S_VOL)], rcx
    mov [LOCAL(S_OUT)], rdx
    mov rdi, r8                         ; count
    lea r13, [rel g_block_shape]
    mov dword [LOCAL(S_Y)], 0
.y_loop:
    mov dword [LOCAL(S_Z)], 0
.z_loop:
    ; p = ORIGIN + y * PAD2 + z * PAD
    mov eax, [LOCAL(S_Y)]
    imul eax, eax, PAD2
    mov ecx, [LOCAL(S_Z)]
    imul ecx, ecx, PAD
    lea r12d, [eax + ecx + ORIGIN]      ; p for x = 0
    mov rbx, [LOCAL(S_VOL)]
    xor esi, esi                        ; x
.x_loop:
    movzx r14d, word [rbx + r12 * 2]    ; id
    movzx eax, byte [r13 + r14]
    test eax, eax
    jnz .shaped
.x_next:
    inc r12d
    inc esi
    cmp esi, 32
    jb .x_loop
    inc dword [LOCAL(S_Z)]
    cmp dword [LOCAL(S_Z)], 32
    jb .z_loop
    inc dword [LOCAL(S_Y)]
    cmp dword [LOCAL(S_Y)], 32
    jb .y_loop
    mov rax, rdi
    RETURN

.shaped:
    mov [LOCAL(S_X)], esi
    mov [LOCAL(S_ID)], r14d
    mov [LOCAL(S_P)], r12
    lea rcx, [rel g_block_state]
    movzx ecx, byte [rcx + r14]
    mov [LOCAL(S_STATE)], ecx
    lea r15, [LOCAL(S_BOXES)]           ; box cursor
    lea rcx, [rel shape_jump]
    jmp [rcx + rax * 8]

; ---- shape builders: append boxes at r15, then jump to .emit ---------------------
.s_none:
    jmp .emit

.s_slab:
    lea rcx, [rel b_slab_bottom]
    test dword [LOCAL(S_STATE)], 1
    jz .slab_add
    lea rcx, [rel b_slab_top]
.slab_add:
    xor edx, edx
    call add_box
    jmp .emit

.s_stairs:
    ; base slab
    mov eax, [LOCAL(S_STATE)]
    lea rcx, [rel b_slab_bottom]
    test eax, 4
    jz .st_base
    lea rcx, [rel b_slab_top]
.st_base:
    xor edx, edx
    call add_box
    ; step quadrants: back half, adjusted by perpendicular stairs behind
    ; (outer corner) or in front (inner corner) with the same half
    mov eax, [LOCAL(S_STATE)]
    and eax, 3                          ; facing f
    lea rcx, [rel back_mask]
    movzx r8d, byte [rcx + rax]         ; mask
    mov [LOCAL(S_CONN)], r8d
    ; behind: neighbour in direction f
    lea rcx, [rel dir_off]
    mov rdx, [rcx + rax * 8]
    add rdx, r12
    call stair_neighbor                 ; eax = its facing or -1
    cmp eax, -1
    je .st_front
    mov ecx, [LOCAL(S_STATE)]
    xor ecx, eax
    test ecx, 1
    jz .st_front                        ; parallel: straight
    lea rcx, [rel back_mask]
    movzx ecx, byte [rcx + rax]
    and [LOCAL(S_CONN)], ecx            ; outer corner
    jmp .st_steps
.st_front:
    mov eax, [LOCAL(S_STATE)]
    xor eax, 2                          ; opposite direction
    and eax, 3
    lea rcx, [rel dir_off]
    mov rdx, [rcx + rax * 8]
    add rdx, r12
    call stair_neighbor
    cmp eax, -1
    je .st_steps
    mov ecx, [LOCAL(S_STATE)]
    xor ecx, eax
    test ecx, 1
    jz .st_steps
    lea rcx, [rel back_mask]
    movzx ecx, byte [rcx + rax]
    or [LOCAL(S_CONN)], ecx             ; inner corner
.st_steps:
    mov ecx, [LOCAL(S_CONN)]
    mov edx, 8
    mov r8d, 16
    test dword [LOCAL(S_STATE)], 4
    jz .st_add
    xor edx, edx
    mov r8d, 8
.st_add:
    call add_quadrants
    jmp .emit

.s_fence:
    mov ecx, SHAPE_FENCE
    call connections
    lea rcx, [rel b_fence_post]
    xor edx, edx
    call add_box
    xor ebx, ebx                        ; direction
.fence_dir:
    bt dword [LOCAL(S_CONN)], ebx
    jnc .fence_next
    lea rcx, [rel b_fence_rail1]
    mov edx, ebx
    call add_box
    lea rcx, [rel b_fence_rail2]
    mov edx, ebx
    call add_box
.fence_next:
    inc ebx
    cmp ebx, 4
    jb .fence_dir
    jmp .emit

.s_gate:
    mov ebx, [LOCAL(S_STATE)]           ; facing in bits 0-1
    lea rcx, [rel b_gate_post1]
    mov edx, ebx
    call add_box
    lea rcx, [rel b_gate_post2]
    mov edx, ebx
    call add_box
    test ebx, 4
    jnz .gate_open
    lea rcx, [rel b_gate_rail1]
    mov edx, ebx
    call add_box
    lea rcx, [rel b_gate_rail2]
    mov edx, ebx
    call add_box
    lea rcx, [rel b_gate_bars]
    mov edx, ebx
    call add_box
    jmp .emit
.gate_open:
    lea rcx, [rel b_gate_open1]
    mov edx, ebx
    call add_box
    lea rcx, [rel b_gate_open2]
    mov edx, ebx
    call add_box
    lea rcx, [rel b_gate_open3]
    mov edx, ebx
    call add_box
    lea rcx, [rel b_gate_open4]
    mov edx, ebx
    call add_box
    jmp .emit

.s_door:
    mov edx, [LOCAL(S_STATE)]
    lea rcx, [rel b_door_closed]
    test edx, 8
    jz .door_add
    lea rcx, [rel b_door_left]
    test edx, 16
    jz .door_add
    lea rcx, [rel b_door_right]
.door_add:
    call add_box
    jmp .emit

.s_trapdoor:
    mov edx, [LOCAL(S_STATE)]
    lea rcx, [rel b_trap_open]
    test edx, 8
    jnz .trap_add
    lea rcx, [rel b_trap_bottom]
    test edx, 4
    jz .trap_add
    lea rcx, [rel b_trap_top]
.trap_add:
    call add_box
    jmp .emit

.s_ladder:
    lea rcx, [rel b_ladder]
    mov edx, [LOCAL(S_STATE)]
    call add_box
    jmp .emit

.s_sign:
    lea rcx, [rel b_sign_stick]
    mov edx, [LOCAL(S_STATE)]
    call add_box
    lea rcx, [rel b_sign_board]
    mov edx, [LOCAL(S_STATE)]
    call add_box
    jmp .emit

.s_wall_sign:
    lea rcx, [rel b_wall_sign]
    mov edx, [LOCAL(S_STATE)]
    call add_box
    jmp .emit

.s_plate:
    lea rcx, [rel b_plate_up]
    test dword [LOCAL(S_STATE)], 1
    jz .plate_add
    lea rcx, [rel b_plate_down]
.plate_add:
    xor edx, edx
    call add_box
    jmp .emit

.s_wall:
    mov ecx, SHAPE_WALL
    call connections
    ; no post on a straight run (N+S only or E+W only)
    mov eax, [LOCAL(S_CONN)]
    cmp eax, 0b0101
    je .wall_arms
    cmp eax, 0b1010
    je .wall_arms
    lea rcx, [rel b_wall_post]
    xor edx, edx
    call add_box
.wall_arms:
    xor ebx, ebx
.wall_dir:
    bt dword [LOCAL(S_CONN)], ebx
    jnc .wall_next
    lea rcx, [rel b_wall_arm]
    mov edx, ebx
    call add_box
.wall_next:
    inc ebx
    cmp ebx, 4
    jb .wall_dir
    jmp .emit

.s_pillar:
    ; base unless the same pillar is below, capital unless it is above
    mov eax, [LOCAL(S_ID)]
    mov rbx, [LOCAL(S_VOL)]
    xor r8d, r8d                        ; shaft y0
    mov r9d, 16                         ; shaft y1
    lea rcx, [r12 - PAD2]
    cmp [rbx + rcx * 2], ax
    je .pillar_no_base
    push r9
    lea rcx, [rel b_pillar_base]
    xor edx, edx
    call add_box
    pop r9
    mov r8d, 3
.pillar_no_base:
    mov eax, [LOCAL(S_ID)]
    lea rcx, [r12 + PAD2]
    cmp [rbx + rcx * 2], ax
    je .pillar_shaft
    push r8
    lea rcx, [rel b_pillar_cap]
    xor edx, edx
    call add_box
    pop r8
    mov r9d, 13
.pillar_shaft:
    mov byte [r15], 2
    mov [r15 + 1], r8b
    mov byte [r15 + 2], 2
    mov byte [r15 + 3], 14
    mov [r15 + 4], r9b
    mov byte [r15 + 5], 14
    add r15, 6
    jmp .emit

.s_spike:
    ; width by part: base (attached), middle, tip (nothing beyond)
    ; up (state 0): attached below, grows up; down: attached above
    mov eax, [LOCAL(S_ID)]
    mov rbx, [LOCAL(S_VOL)]
    mov rcx, PAD2                       ; growth direction offset
    test dword [LOCAL(S_STATE)], 1
    jz .spike_dir
    neg rcx
.spike_dir:
    lea rdx, [r12 + rcx]                ; next block in the growth direction
    xor r8d, r8d                        ; inset: 0 tip.. computed below
    cmp [rbx + rdx * 2], ax
    jne .spike_tip
    mov rdx, r12
    sub rdx, rcx                        ; block it grows from
    cmp [rbx + rdx * 2], ax
    je .spike_mid
    mov r8d, 4                          ; base: 4..12
    jmp .spike_box
.spike_mid:
    mov r8d, 5                          ; middle: 5..11
    jmp .spike_box
.spike_tip:
    mov r8d, 6                          ; tip: 6..10
.spike_box:
    mov [r15], r8b
    mov byte [r15 + 1], 0
    mov [r15 + 2], r8b
    mov eax, 16
    sub eax, r8d
    mov [r15 + 3], al
    mov byte [r15 + 4], 16
    mov [r15 + 5], al
    add r15, 6
    jmp .emit

.s_pane:
    mov ecx, SHAPE_PANE
    call connections
    cmp dword [LOCAL(S_CONN)], 0
    jne .pane_post
    mov dword [LOCAL(S_CONN)], 0b1111   ; alone: a cross
.pane_post:
    lea rcx, [rel b_pane_post]
    xor edx, edx
    call add_box
    xor ebx, ebx
.pane_dir:
    bt dword [LOCAL(S_CONN)], ebx
    jnc .pane_next
    lea rcx, [rel b_pane_arm]
    mov edx, ebx
    call add_box
.pane_next:
    inc ebx
    cmp ebx, 4
    jb .pane_dir
    jmp .emit

; ---- emit the visible faces of the collected boxes -------------------------------
.emit:
    mov rbx, [LOCAL(S_VOL)]
    lea r14, [LOCAL(S_BOXES)]           ; box
.box:
    cmp r14, r15
    jae .box_done
    xor r9d, r9d                        ; face
.face:
    ; on the block boundary next to an opaque neighbour? then hidden
    mov eax, r9d
    shr eax, 1                          ; axis 0 x, 1 y, 2 z
    xor ecx, ecx
    test r9d, 1
    jnz .face_pos
    movzx ecx, byte [r14 + rax]         ; min on that axis
    test ecx, ecx
    jnz .face_visible
    jmp .face_boundary
.face_pos:
    movzx ecx, byte [r14 + rax + 3]
    cmp ecx, 16
    jne .face_visible
.face_boundary:
    ; neighbour offset for this face: -X +X -Y +Y -Z +Z
    mov rdx, [LOCAL(S_P)]
    cmp r9d, 0
    jne .nb1
    dec rdx
    jmp .nb_have
.nb1:
    cmp r9d, 1
    jne .nb2
    inc rdx
    jmp .nb_have
.nb2:
    cmp r9d, 2
    jne .nb3
    sub rdx, PAD2
    jmp .nb_have
.nb3:
    cmp r9d, 3
    jne .nb4
    add rdx, PAD2
    jmp .nb_have
.nb4:
    cmp r9d, 4
    jne .nb5
    sub rdx, PAD
    jmp .nb_have
.nb5:
    add rdx, PAD
.nb_have:
    movzx edx, word [rbx + rdx * 2]
    lea rcx, [rel g_block_opaque]
    cmp byte [rcx + rdx], 0
    jne .face_next
.face_visible:
    cmp rdi, MESH_MAX_QUADS
    jae .box_done
    ; lo = x | y<<5 | z<<10 | x0<<15 | y0<<19 | z0<<23 | face<<28 | 1<<31
    mov eax, [LOCAL(S_X)]
    mov ecx, [LOCAL(S_Y)]
    shl ecx, 5
    or eax, ecx
    mov ecx, [LOCAL(S_Z)]
    shl ecx, 10
    or eax, ecx
    movzx ecx, byte [r14]
    shl ecx, 15
    or eax, ecx
    movzx ecx, byte [r14 + 1]
    shl ecx, 19
    or eax, ecx
    movzx ecx, byte [r14 + 2]
    shl ecx, 23
    or eax, ecx
    mov ecx, r9d
    shl ecx, 28
    or eax, ecx
    or eax, 0x80000000
    ; hi = id | (sx-1)<<16 | (sy-1)<<20 | (sz-1)<<24
    mov edx, [LOCAL(S_ID)]
    movzx ecx, byte [r14 + 3]
    movzx r8d, byte [r14]
    sub ecx, r8d
    dec ecx
    shl ecx, 16
    or edx, ecx
    movzx ecx, byte [r14 + 4]
    movzx r8d, byte [r14 + 1]
    sub ecx, r8d
    dec ecx
    shl ecx, 20
    or edx, ecx
    movzx ecx, byte [r14 + 5]
    movzx r8d, byte [r14 + 2]
    sub ecx, r8d
    dec ecx
    shl ecx, 24
    or edx, ecx
    mov rcx, [LOCAL(S_OUT)]
    mov [rcx + rdi * 8], eax
    mov [rcx + rdi * 8 + 4], edx
    inc rdi
.face_next:
    inc r9d
    cmp r9d, 6
    jb .face
    add r14, 6
    jmp .box
.box_done:
    ; restore the scan registers
    mov rbx, [LOCAL(S_VOL)]
    mov r12, [LOCAL(S_P)]
    mov esi, [LOCAL(S_X)]
    lea r13, [rel g_block_shape]
    jmp .x_next

; -----------------------------------------------------------------------------
; stair_neighbor (local) — facing of a stair at volume index rdx when it has
; the same half as the current stair.
;   in:  rdx = volume index; frame locals of shapes_emit (via rsp + 8)
;   out: eax = facing 0..3, or -1
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
stair_neighbor:
    mov rcx, [rsp + 8 + OUTGOING_SIZE + S_VOL]
    movzx edx, word [rcx + rdx * 2]
    lea rcx, [rel g_block_shape]
    cmp byte [rcx + rdx], SHAPE_STAIRS
    jne .no
    lea rcx, [rel g_block_state]
    movzx eax, byte [rcx + rdx]
    mov ecx, [rsp + 8 + OUTGOING_SIZE + S_STATE]
    xor ecx, eax
    test ecx, 4
    jnz .no                             ; other half
    and eax, 3
    ret
.no:
    mov eax, -1
    ret

; -----------------------------------------------------------------------------
; connections (local) — which horizontal neighbours a fence / wall / pane
; joins: an opaque block, or a block of the same family (fences also join
; fence gates; panes also join walls).
;   in:  ecx = SHAPE_FENCE / SHAPE_WALL / SHAPE_PANE; r12 = volume index
;   out: [S_CONN] = bits N, E, S, W
;   clobbers: rax, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
connections:
    mov r10d, ecx                       ; own shape
    mov r11, [rsp + 8 + OUTGOING_SIZE + S_VOL]
    xor r8d, r8d                        ; bits
    xor r9d, r9d                        ; direction
.dir:
    lea rcx, [rel dir_off]
    mov rdx, [rcx + r9 * 8]
    add rdx, r12
    movzx edx, word [r11 + rdx * 2]     ; neighbour id
    lea rcx, [rel g_block_opaque]
    cmp byte [rcx + rdx], 0
    jne .join
    lea rcx, [rel g_block_shape]
    movzx eax, byte [rcx + rdx]
    cmp eax, r10d
    je .join
    cmp r10d, SHAPE_FENCE
    jne .not_fence
    cmp eax, SHAPE_FENCE_GATE
    je .join
.not_fence:
    cmp r10d, SHAPE_PANE
    jne .next
    cmp eax, SHAPE_WALL
    jne .next
.join:
    bts r8d, r9d
.next:
    inc r9d
    cmp r9d, 4
    jb .dir
    mov [rsp + 8 + OUTGOING_SIZE + S_CONN], r8d
    ret
