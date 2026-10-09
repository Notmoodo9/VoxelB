; =============================================================================
; mesher.asm — greedy meshing of one section into packed quads.
;
; Input: the section and its 6 neighbours (-X,+X,-Y,+Y,-Z,+Z; 0 = air,
; NEIGHBOR_SOLID = solid boundary). The section is expanded into a 34^3 u16
; volume with a one-block border copied from the neighbours, so face culling
; across section borders is exact.
; For each face direction and each of the 32 slices a 32x32 mask of visible
; faces (block id, 0 = none) is built; equal ids are merged greedily into
; rectangles. Merging only compares block ids for now (light/AO equality
; joins in M13).
; A face is hidden when the neighbour block is opaque, or when both blocks
; are the same "cull self" block (translucent: glass next to glass).
; The output is ordered by render layer: opaque quads, then cutout, then
; translucent (g_block_layer), so a section draws each layer as one range.
;
; Quad format (u64, consumed by shaders/chunk.vert):
;   bits  0-5  x   6-11 y   12-17 z    block position in the section
;   bits 18-22 width-1 (along u)   23-27 height-1 (along v)
;   bits 28-30 face (0 -X, 1 +X, 2 -Y, 3 +Y, 4 -Z, 5 +Z)
;   bits 32-47 block id
; Face axes: X faces u=z v=y; Y faces u=x v=z; Z faces u=x v=y.
;
; Public API:
;   mesh_section(sect, neighbors[6], out u64[], scratch ARENA*)
;       -> rax quads, rdx = opaque count | cutout count << 32
;   MESH_MAX_QUADS (world.inc): output capacity per section
; =============================================================================
%include "macros.inc"
%include "memory.inc"
%include "section.inc"

global mesh_section, vis_pair_bit

extern g_block_opaque, g_block_layer, g_block_shape
extern shapes_emit

; g_block_opaque, g_block_layer, g_block_cullself and g_block_shape are
; consecutive 64 KB tables (src/world/block.asm)
%define CULLSELF_OFS    (2 * 65536)
%define SHAPE_OFS       (3 * 65536)

%define PAD             34
%define PAD2            (PAD * PAD)
%define VOL_SIZE        (PAD * PAD * PAD)
%define ORIGIN          (1 + PAD + PAD2)      ; volume index of block (0,0,0)
%define SOLID_ID        0xFFFF                ; border filler for solid edges

section .rdata
align 8
; border copy per face: vol_base, vol_sa, vol_sb, nb_base, nb_sa, nb_sb
border_table:
    dq 1190,              PAD2, PAD, 31,    1024, 32      ; -X: x=0  <- nb x=31
    dq 1223,              PAD2, PAD, 0,     1024, 32      ; +X: x=33 <- nb x=0
    dq 35,                PAD,  1,   31744, 32,   1       ; -Y: y=0  <- nb y=31
    dq 35 + 33 * PAD2,    PAD,  1,   0,     32,   1       ; +Y: y=33 <- nb y=0
    dq 1157,              PAD2, 1,   992,   1024, 1       ; -Z: z=0  <- nb z=31
    dq 1157 + 33 * PAD,   PAD2, 1,   0,     1024, 1       ; +Z: z=33 <- nb z=0
; mesh direction: axis stride A, u stride U, v stride V, neighbour offset
dir_table:
    dq 1,    PAD,  PAD2, -1
    dq 1,    PAD,  PAD2, 1
    dq PAD2, 1,    PAD,  -PAD2
    dq PAD2, 1,    PAD,  PAD2
    dq PAD,  1,    PAD2, -PAD
    dq PAD,  1,    PAD2, PAD

; bit of the face pair (i, j) in SECT.vis (faces -X +X -Y +Y -Z +Z)
vis_pair_bit:
    db 0xFF, 0,  1,  2,  3,  4
    db 0,  0xFF, 5,  6,  7,  8
    db 1,  5, 0xFF,  9, 10, 11
    db 2,  6,  9, 0xFF, 12, 13
    db 3,  7, 10, 12, 0xFF, 14
    db 4,  8, 11, 13, 14, 0xFF

section .text

; -----------------------------------------------------------------------------
; section_vis — which pairs of the section's 6 faces are connected through
; non-opaque blocks (flood fill of every open region). Used by the renderer's
; visibility walk (cave culling): a view can pass from face i to face j only
; if bit vis_pair_bit[i][j] is set.
;   in:  rcx = volume (34^3 u16), rdx = scratch ARENA*
;   out: eax = 15 pair bits
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC section_vis, 16, rbx, rsi, rdi, r12, r13, r14, r15
    mov rbx, rcx
    mov r15, rdx
    INVOKE arena_alloc, r15, 4096, 64   ; visited bits
    test rax, rax
    jz .all
    mov r12, rax
    mov rdi, rax
    xor eax, eax
    mov ecx, 4096 / 8
    rep stosq
    INVOKE arena_alloc, r15, 65536, 64  ; stack of cells
    test rax, rax
    jz .all
    mov r13, rax
    lea r14, [rel g_block_opaque]
    xor esi, esi                        ; vis bits
    xor edi, edi                        ; cell
.cell:
    bt [r12], edi
    jc .cell_next
    mov eax, edi
    call cell_vol_index
    movzx eax, word [rbx + rax * 2]
    cmp byte [r14 + rax], 0
    jne .cell_next                      ; opaque
    ; flood this region
    bts [r12], edi
    mov [r13], di
    mov r8d, 1                          ; stack size
    xor r9d, r9d                        ; faces touched
.pop:
    test r8d, r8d
    jz .region_done
    dec r8d
    movzx ecx, word [r13 + r8 * 2]
    mov eax, ecx
    and eax, 31                         ; x
    jnz .not_x0
    or r9d, 1
    jmp .nx_hi
.not_x0:
    lea edx, [ecx - 1]
    call try_push
.nx_hi:
    cmp eax, 31
    jne .not_x31
    or r9d, 2
    jmp .ny
.not_x31:
    lea edx, [ecx + 1]
    call try_push
.ny:
    mov eax, ecx
    shr eax, 10                         ; y
    jnz .not_y0
    or r9d, 4
    jmp .ny_hi
.not_y0:
    lea edx, [ecx - 1024]
    call try_push
.ny_hi:
    cmp eax, 31
    jne .not_y31
    or r9d, 8
    jmp .nz
.not_y31:
    lea edx, [ecx + 1024]
    call try_push
.nz:
    mov eax, ecx
    shr eax, 5
    and eax, 31                         ; z
    jnz .not_z0
    or r9d, 16
    jmp .nz_hi
.not_z0:
    lea edx, [ecx - 32]
    call try_push
.nz_hi:
    cmp eax, 31
    jne .not_z31
    or r9d, 32
    jmp .pop
.not_z31:
    lea edx, [ecx + 32]
    call try_push
    jmp .pop
.region_done:
    xor ecx, ecx                        ; i
.pi:
    bt r9d, ecx
    jnc .pi_next
    lea edx, [ecx + 1]                  ; j
.pj:
    cmp edx, 6
    jae .pi_next
    bt r9d, edx
    jnc .pj_next
    imul eax, ecx, 6
    add eax, edx
    lea r10, [rel vis_pair_bit]
    movzx eax, byte [r10 + rax]
    bts esi, eax
.pj_next:
    inc edx
    jmp .pj
.pi_next:
    inc ecx
    cmp ecx, 6
    jb .pi
    cmp esi, 0x7FFF
    je .done                            ; everything connected already
.cell_next:
    inc edi
    cmp edi, 32768
    jb .cell
.done:
    mov eax, esi
    RETURN
.all:
    mov eax, 0x7FFF
    RETURN
ENDPROC

; cell_vol_index — volume index of cell eax (x | z << 5 | y << 10).
;   out: eax   clobbers: rax, rdx, r10
cell_vol_index:
    mov edx, eax
    and edx, 31
    mov r10d, eax
    shr r10d, 5
    and r10d, 31
    imul r10d, r10d, PAD
    add edx, r10d
    shr eax, 10
    imul eax, eax, PAD2
    add eax, edx
    add eax, ORIGIN
    ret

; try_push — push neighbour cell edx if open and not visited.
;   uses rbx (volume), r12 (bits), r13 (stack), r14 (opaque), r8d (size)
;   keeps rax, rcx; clobbers rdx, r10, r11
try_push:
    bt [r12], edx
    jc .no
    mov r11d, eax
    push rdx
    mov eax, edx
    call cell_vol_index
    movzx eax, word [rbx + rax * 2]
    movzx eax, byte [r14 + rax]
    pop rdx
    xchg eax, r11d
    test r11d, r11d
    jnz .no
    bts [r12], edx
    mov [r13 + r8 * 2], dx
    inc r8d
.no:
    ret

; -----------------------------------------------------------------------------
; all_opaque — is every block of a section opaque? (uniform: its id; palette
; sections: every palette entry; raw 16-bit sections: assumed not)
;   in:  rcx = SECT*      out: eax = 1 if yes
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
all_opaque:
    lea r8, [rel g_block_opaque]
    movzx eax, byte [rcx + SECT.bits]
    test eax, eax
    jnz .palette
    movzx eax, word [rcx + SECT.uniform_id]
    movzx eax, byte [r8 + rax]
    ret
.palette:
    cmp eax, 16
    je .no
    movzx edx, word [rcx + SECT.pal_count]
    mov rcx, [rcx + SECT.palette]
    test rcx, rcx
    jz .no
.entry:
    test edx, edx
    jz .yes
    dec edx
    movzx eax, word [rcx + rdx * 2]
    cmp byte [r8 + rax], 0
    je .no
    jmp .entry
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; has_shapes — could a section contain shaped blocks? (uniform: its id;
; palette sections: any palette entry; raw 16-bit sections: assumed yes)
;   in:  rcx = SECT*      out: eax = 1 if yes
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
has_shapes:
    lea r8, [rel g_block_shape]
    movzx eax, byte [rcx + SECT.bits]
    test eax, eax
    jnz .palette
    movzx eax, word [rcx + SECT.uniform_id]
    movzx eax, byte [r8 + rax]
    test eax, eax
    setnz al
    ret
.palette:
    cmp eax, 16
    je .yes
    movzx edx, word [rcx + SECT.pal_count]
    mov rcx, [rcx + SECT.palette]
    test rcx, rcx
    jz .no
.entry:
    test edx, edx
    jz .no
    dec edx
    movzx eax, word [rcx + rdx * 2]
    cmp byte [r8 + rax], 0
    jne .yes
    jmp .entry
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; covered — does neighbour n fully cover the adjacent face with opaque blocks?
;   in:  rcx = neighbour (0 air, -1 solid, else SECT*)
;   out: eax = 1 if it is the solid boundary or an all-opaque section
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
covered:
    cmp rcx, NEIGHBOR_SOLID
    je .yes
    test rcx, rcx
    jz .no
    jmp all_opaque
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; mesh_section — build greedy quads for one section.
;   in:  rcx = SECT*, rdx = neighbours (6 qwords), r8 = out quads,
;        r9 = scratch ARENA* (needs ~150 KB; caller resets it)
;   out: rax = number of quads written
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define L_SECT      0
%define L_NB        8
%define L_OUT       16
%define L_ARENA     24
%define L_VOL       32
%define L_MASK      40
%define L_COUNT     48
%define L_DIR       56
%define L_SLICE     64
%define L_FACE      72
%define L_TMP       80
%define L_W         88
%define L_H         96
%define L_ID        104
%define L_SHAPES    112                   ; section holds shaped blocks
%define L_LOCALS    120
PROC mesh_section, L_LOCALS, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(L_SECT)], rcx
    mov [LOCAL(L_NB)], rdx
    mov [LOCAL(L_OUT)], r8
    mov [LOCAL(L_ARENA)], r9
    mov qword [LOCAL(L_COUNT)], 0

    ; ---- fully enclosed all-opaque section: nothing to draw ------------------------
    mov rbx, rcx
    call all_opaque
    test eax, eax
    jz .full_mesh
    mov rsi, [LOCAL(L_NB)]
    xor edi, edi
.cover_check:
    mov rcx, [rsi + rdi * 8]
    call covered
    test eax, eax
    jz .full_mesh
    inc edi
    cmp edi, 6
    jb .cover_check
    mov word [rbx + SECT.vis], 0        ; solid: nothing passes through
    xor eax, eax
    xor edx, edx
    RETURN

.full_mesh:
    mov rcx, [LOCAL(L_SECT)]
    call has_shapes
    mov [LOCAL(L_SHAPES)], rax
    ; ---- scratch: volume + decode buffer + mask -------------------------------------
    INVOKE arena_alloc, [LOCAL(L_ARENA)], VOL_SIZE * 2, 64
    test rax, rax
    jz .fail
    mov [LOCAL(L_VOL)], rax
    mov rdi, rax
    xor eax, eax
    mov ecx, (VOL_SIZE * 2 + 7) / 8
    rep stosq                           ; all air
    INVOKE arena_alloc, [LOCAL(L_ARENA)], SECTION_VOLUME * 2, 64
    test rax, rax
    jz .fail
    mov [LOCAL(L_TMP)], rax
    INVOKE section_decode, [LOCAL(L_SECT)], rax
    INVOKE arena_alloc, [LOCAL(L_ARENA)], 32 * 32 * 2, 64
    test rax, rax
    jz .fail
    mov [LOCAL(L_MASK)], rax

    ; ---- interior: 32 u16 per row (y, z) ------------------------------------------
    mov rsi, [LOCAL(L_TMP)]
    mov rdi, [LOCAL(L_VOL)]
    add rdi, ORIGIN * 2
    xor ebx, ebx                        ; row = y*32 + z
.rows:
    movdqu xmm0, [rsi]
    movdqu xmm1, [rsi + 16]
    movdqu xmm2, [rsi + 32]
    movdqu xmm3, [rsi + 48]
    movdqu [rdi], xmm0
    movdqu [rdi + 16], xmm1
    movdqu [rdi + 32], xmm2
    movdqu [rdi + 48], xmm3
    add rsi, 64
    add rdi, PAD * 2                    ; next z
    inc ebx
    test ebx, 31
    jnz .rows_same_y
    add rdi, (PAD2 - 32 * PAD) * 2      ; next y: skip the padding rows
.rows_same_y:
    cmp ebx, 1024
    jb .rows

    ; ---- borders from neighbours ---------------------------------------------------
    xor r12d, r12d                      ; face
.border:
    mov rax, [LOCAL(L_NB)]
    mov r13, [rax + r12 * 8]            ; neighbour
    test r13, r13
    jz .border_next                     ; air: already zero
    lea r14, [rel border_table]
    imul rax, r12, 48
    add r14, rax                        ; table row
    xor esi, esi                        ; a
.border_a:
    xor edi, edi                        ; b
.border_b:
    mov eax, SOLID_ID
    cmp r13, NEIGHBOR_SOLID
    je .border_store
    mov rdx, rsi
    imul rdx, [r14 + 32]
    mov rax, rdi
    imul rax, [r14 + 40]
    add rdx, rax
    add rdx, [r14 + 24]                 ; neighbour index
    mov rcx, r13
    call section_get
.border_store:
    mov rdx, rsi
    imul rdx, [r14 + 8]
    mov rcx, rdi
    imul rcx, [r14 + 16]
    add rdx, rcx
    add rdx, [r14]
    mov rcx, [LOCAL(L_VOL)]
    mov [rcx + rdx * 2], ax
    inc edi
    cmp edi, 32
    jb .border_b
    inc esi
    cmp esi, 32
    jb .border_a
.border_next:
    inc r12d
    cmp r12d, 6
    jb .border

    ; ---- greedy meshing per direction and slice ----------------------------------------
    mov qword [LOCAL(L_FACE)], 0
.dir:
    mov rax, [LOCAL(L_FACE)]
    lea r15, [rel dir_table]
    shl rax, 5
    add r15, rax                        ; r15 = {A, U, V, nb_off}
    mov qword [LOCAL(L_SLICE)], 0
.slice:
    ; build mask[v][u]
    mov r12, [LOCAL(L_VOL)]
    mov r13, [LOCAL(L_MASK)]
    lea r14, [rel g_block_opaque]
    mov rax, [LOCAL(L_SLICE)]
    imul rax, [r15]
    add rax, ORIGIN                     ; p of (s, 0, 0)
    mov rbx, rax                        ; row start
    xor edi, edi                        ; v
.mask_v:
    mov rsi, rbx                        ; p
    xor ecx, ecx                        ; u
.mask_u:
    movzx eax, word [r12 + rsi * 2]     ; block
    test eax, eax
    jz .mask_store
    cmp byte [r14 + rax + SHAPE_OFS], 0
    jne .mask_hidden                    ; shaped: drawn by shapes_emit
    mov rdx, rsi
    add rdx, [r15 + 24]
    movzx edx, word [r12 + rdx * 2]     ; neighbour block
    cmp byte [r14 + rdx], 0
    jne .mask_hidden
    cmp edx, eax
    jne .mask_store
    cmp byte [r14 + rax + CULLSELF_OFS], 0
    je .mask_store
.mask_hidden:
    xor eax, eax                        ; hidden face
.mask_store:
    mov [r13], ax
    add r13, 2
    add rsi, [r15 + 8]
    inc ecx
    cmp ecx, 32
    jb .mask_u
    add rbx, [r15 + 16]
    inc edi
    cmp edi, 32
    jb .mask_v

    ; greedy merge over the mask
    mov r13, [LOCAL(L_MASK)]
    xor edi, edi                        ; v
.g_v:
    xor esi, esi                        ; u
.g_u:
    mov eax, edi
    shl eax, 5
    add eax, esi
    movzx edx, word [r13 + rax * 2]     ; id
    test edx, edx
    jz .g_next_u
    mov [LOCAL(L_ID)], rdx
    ; width
    mov ecx, 1
.g_w:
    lea r8d, [esi + ecx]
    cmp r8d, 32
    jae .g_w_done
    lea r9d, [eax + ecx]
    cmp dx, [r13 + r9 * 2]
    jne .g_w_done
    inc ecx
    jmp .g_w
.g_w_done:
    mov [LOCAL(L_W)], rcx
    ; height
    mov r10d, 1                         ; h
.g_h:
    lea r8d, [edi + r10d]
    cmp r8d, 32
    jae .g_h_done
    shl r8d, 5
    add r8d, esi                        ; row start index
    xor r9d, r9d
.g_h_row:
    lea r11d, [r8d + r9d]
    cmp dx, [r13 + r11 * 2]
    jne .g_h_done
    inc r9d
    cmp r9d, ecx
    jb .g_h_row
    inc r10d
    jmp .g_h
.g_h_done:
    mov [LOCAL(L_H)], r10
    ; clear the rectangle
    xor r8d, r8d                        ; row offset
.g_clear_row:
    lea r9d, [edi + r8d]
    shl r9d, 5
    add r9d, esi
    xor r11d, r11d
.g_clear_col:
    lea eax, [r9d + r11d]
    mov word [r13 + rax * 2], 0
    inc r11d
    cmp r11d, ecx
    jb .g_clear_col
    inc r8d
    cmp r8d, r10d
    jb .g_clear_row
    ; local block position from (s, u, v)
    mov r8, [LOCAL(L_SLICE)]            ; s
    mov rax, [LOCAL(L_FACE)]
    cmp eax, 2
    jb .pos_x
    cmp eax, 4
    jb .pos_y
    ; Z faces: z=s, x=u, y=v
    mov r9d, esi                        ; x
    mov r10d, edi                       ; y
    mov r11d, r8d                       ; z
    jmp .emit
.pos_x:                                 ; X faces: x=s, z=u, y=v
    mov r9d, r8d
    mov r10d, edi
    mov r11d, esi
    jmp .emit
.pos_y:                                 ; Y faces: y=s, x=u, z=v
    mov r9d, esi
    mov r10d, r8d
    mov r11d, edi
.emit:
    ; quad = x | y<<6 | z<<12 | (w-1)<<18 | (h-1)<<23 | face<<28 | id<<32
    mov r8, r9
    shl r10, 6
    or r8, r10
    shl r11, 12
    or r8, r11
    mov rcx, [LOCAL(L_W)]
    dec rcx
    shl rcx, 18
    or r8, rcx
    mov rcx, [LOCAL(L_H)]
    dec rcx
    shl rcx, 23
    or r8, rcx
    mov rcx, [LOCAL(L_FACE)]
    shl rcx, 28
    or r8, rcx
    mov rcx, [LOCAL(L_ID)]
    shl rcx, 32
    or r8, rcx
    mov rax, [LOCAL(L_COUNT)]
    mov rcx, [LOCAL(L_OUT)]
    mov [rcx + rax * 8], r8
    inc qword [LOCAL(L_COUNT)]
    add esi, [LOCAL(L_W)]
    jmp .g_u_check
.g_next_u:
    inc esi
.g_u_check:
    cmp esi, 32
    jb .g_u
    inc edi
    cmp edi, 32
    jb .g_v

    inc qword [LOCAL(L_SLICE)]
    cmp qword [LOCAL(L_SLICE)], 32
    jb .slice
    inc qword [LOCAL(L_FACE)]
    cmp qword [LOCAL(L_FACE)], 6
    jb .dir

    ; ---- visibility through the section (cave culling) ----------------------------
    INVOKE section_vis, [LOCAL(L_VOL)], [LOCAL(L_ARENA)]
    mov rcx, [LOCAL(L_SECT)]
    mov [rcx + SECT.vis], ax

    ; ---- shaped blocks (slabs, stairs, ...) -------------------------------------------
    cmp qword [LOCAL(L_SHAPES)], 0
    je .no_shapes
    INVOKE shapes_emit, [LOCAL(L_VOL)], [LOCAL(L_OUT)], [LOCAL(L_COUNT)]
    mov [LOCAL(L_COUNT)], rax
.no_shapes:

    ; ---- order by render layer: opaque, cutout, translucent ----------------------
    mov rsi, [LOCAL(L_OUT)]
    mov rcx, [LOCAL(L_COUNT)]
    lea rdi, [rel g_block_layer]
    xor r8d, r8d                        ; opaque
    xor r9d, r9d                        ; cutout
    xor r10d, r10d
.count:
    cmp r10, rcx
    jae .counted
    movzx eax, word [rsi + r10 * 8 + 4]
    movzx eax, byte [rdi + rax]
    cmp eax, 1
    ja .count_next
    je .count_cut
    inc r8
    jmp .count_next
.count_cut:
    inc r9
.count_next:
    inc r10
    jmp .count
.counted:
    mov [LOCAL(L_W)], r8
    mov [LOCAL(L_H)], r9
    cmp r8, rcx
    je .ordered                         ; all opaque (the common case)
    lea rdx, [rcx * 8]
    INVOKE arena_alloc, [LOCAL(L_ARENA)], rdx, 8
    test rax, rax
    jz .fail
    mov rdi, rax                        ; copy of the quads
    mov rsi, [LOCAL(L_OUT)]
    mov rcx, [LOCAL(L_COUNT)]
    rep movsq
    mov rsi, rax                        ; source
    mov r8, [LOCAL(L_OUT)]              ; opaque cursor
    mov r9, [LOCAL(L_W)]
    lea r9, [r8 + r9 * 8]               ; cutout cursor
    mov r10, [LOCAL(L_H)]
    lea r10, [r9 + r10 * 8]             ; translucent cursor
    lea rdi, [rel g_block_layer]
    mov rcx, [LOCAL(L_COUNT)]
.scatter:
    test rcx, rcx
    jz .ordered
    mov rax, [rsi]
    add rsi, 8
    mov rdx, rax
    shr rdx, 32
    movzx edx, dx
    movzx edx, byte [rdi + rdx]
    cmp edx, 1
    ja .to_trans
    je .to_cut
    mov [r8], rax
    add r8, 8
    jmp .scatter_next
.to_cut:
    mov [r9], rax
    add r9, 8
    jmp .scatter_next
.to_trans:
    mov [r10], rax
    add r10, 8
.scatter_next:
    dec rcx
    jmp .scatter
.ordered:
    mov rax, [LOCAL(L_COUNT)]
    mov rdx, [LOCAL(L_H)]
    shl rdx, 32
    or rdx, [LOCAL(L_W)]
    RETURN
.fail:
    xor eax, eax
    xor edx, edx
    RETURN
ENDPROC
