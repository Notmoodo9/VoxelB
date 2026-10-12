; =============================================================================
; light.asm — skylight and RGB block light for a column (milestone 13, D81).
;
; light_build runs in a column's mesh job (worker thread). It reads the
; column and its 8 neighbours (all generated, kept alive by the streamer's
; busy counters) into a light volume (see light.inc) and computes:
;   * skylight: straight down from the open sky without loss until the
;     first opaque block (filtering blocks such as leaves and water take
;     their light_filter per block), then a flood fill sideways and down
;     into overhangs, caves and under trees, losing 1 (+ filter) per step;
;   * block light: a flood fill from every emitting block (light = r, g, b
;     in the block files), the three channels at once (saturating byte
;     subtraction), losing 1 (+ filter) per step.
; Light leaving the volume is lost; with a 16-block margin that only matters
; for paths that go out and come back.
;
; Public API:
;   light_init()                          after blocks_load (g_light_op)
;   light_build(COLUMN*, ARENA*) -> rax   LVOL* in the arena, or 0
;   g_light_op                            u8 per block id (LOP_* bits)
;   g_light_count, g_light_total_us, g_light_max_us   statistics
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "section.inc"
%include "block.inc"
%define LIGHT_IMPL
%include "light.inc"

global light_init, light_build, g_light_op
global g_light_count, g_light_total_us, g_light_max_us, g_light_sources

extern timer_elapsed_us, atomic_max

%define QCAP            (1 << 20)       ; flood-fill queue entries (ring)
%define QMASK           (QCAP - 1)

section .rdata
align 8
; neighbour columns in volume order (dz, dx from -1): COLUMN.nb index, or
; -1 for the column itself
col_nb:         dd 4, 2, 5,  0, -1, 1,  6, 3, 7

section .bss
alignb 64
g_light_op:         resb MAX_BLOCK_TYPES
alignb 64
g_light_count:      resq 1
g_light_total_us:   resq 1
g_light_max_us:     resq 1
g_light_sources:    resq 1              ; emitting blocks found (all columns)

section .text

; -----------------------------------------------------------------------------
; light_init — light properties per block id: opaque blocks stop light;
; others lose light_filter extra per block (default: 1 for cut-out cubes such
; as leaves, else 0).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC light_init, 0, rbx
    xor ebx, ebx
.id:
    cmp ebx, MAX_BLOCK_TYPES
    jae .done
    lea rax, [rel g_block_lfilter]
    movzx edx, byte [rax + rbx]
    cmp edx, 0xFF
    jne .have_filter
    xor edx, edx
    lea rax, [rel g_block_layer]
    cmp byte [rax + rbx], LAYER_CUTOUT
    jne .have_filter
    lea rax, [rel g_block_shape]
    cmp byte [rax + rbx], SHAPE_CUBE
    jne .have_filter
    mov edx, 1
.have_filter:
    shl edx, LOP_FILTER_SHIFT
    lea rax, [rel g_block_opaque]
    cmp byte [rax + rbx], 0
    je .store
    or edx, LOP_OPAQUE
.store:
    lea rax, [rel g_light_op]
    mov [rax + rbx], dl
    inc ebx
    jmp .id
.done:
    ; air never stops or filters light
    mov byte [rel g_light_op], 0
    LOG_INFO "light: block light properties ready"
    RETURN
ENDPROC

; NB6 fn — call fn with ecx = each in-volume neighbour of cell ebx
%macro NB6 1
    mov eax, ebx
    and eax, 63
    jz %%x0
    lea ecx, [ebx - 1]
    call %1
%%x0:
    mov eax, ebx
    and eax, 63
    cmp eax, 63
    je %%x1
    lea ecx, [ebx + 1]
    call %1
%%x1:
    mov eax, ebx
    shr eax, 6
    and eax, 63
    jz %%z0
    lea ecx, [ebx - LV_W]
    call %1
%%z0:
    mov eax, ebx
    shr eax, 6
    and eax, 63
    cmp eax, 63
    je %%z1
    lea ecx, [ebx + LV_W]
    call %1
%%z1:
    cmp ebx, LV_LAYER
    jb %%y0
    lea ecx, [ebx - LV_LAYER]
    call %1
%%y0:
    lea ecx, [ebx + LV_LAYER]
    cmp ecx, [LOCAL(LB_TOTAL)]
    jae %%y1
    call %1
%%y1:
%endmacro

; -----------------------------------------------------------------------------
; light_build — the light volume of a column.
;   in:  rcx = COLUMN* (nb[0..7] set), rdx = ARENA* (scratch)
;   out: rax = LVOL*, or 0 if out of scratch memory
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define LB_COL      0
%define LB_ARENA    8
%define LB_VOL      16
%define LB_YTOP     24                  ; i32[4096] lowest cell with sky 15
%define LB_TMP      32                  ; u16[32768] decoded section
%define LB_T0       40
%define LB_C        48                  ; neighbour column 0..8
%define LB_SY       52
%define LB_H        56                  ; layers
%define LB_TOTAL    60                  ; cells
%define LB_XS       64                  ; column-local x range of this column
%define LB_XE       68
%define LB_ZS       72
%define LB_ZE       76
%define LB_DX       80                  ; volume offset of local (0, 0) in x, z
%define LB_DZ       84
%define LB_UNI      88                  ; uniform section: its id, else -1
%define LB_SECT     96
%define LB_LOCALS   104
PROC light_build, LB_LOCALS, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(LB_COL)], rcx
    mov [LOCAL(LB_ARENA)], rdx
    call timer_elapsed_us
    mov [LOCAL(LB_T0)], rax
    INVOKE arena_alloc, [LOCAL(LB_ARENA)], LVOL_size, 16
    test rax, rax
    jz .fail
    mov [LOCAL(LB_VOL)], rax
    mov rbx, rax
    mov qword [rbx + LVOL.light], 0
    mov qword [rbx + LVOL.op], 0

    ; ---- height: above the highest stored section of the 9 columns ----
    mov r12d, -1                        ; top section
    xor esi, esi
.top_col:
    mov ecx, esi
    call column_ptr                     ; rax = COLUMN*
    mov edx, SECTIONS_PER_COLUMN - 1
.top_sy:
    cmp edx, r12d
    jle .top_next
    cmp qword [rax + COLUMN.sections + rdx * 8], 0
    jne .top_found
    dec edx
    jmp .top_sy
.top_found:
    mov r12d, edx
.top_next:
    inc esi
    cmp esi, 9
    jb .top_col
    xor eax, eax
    test r12d, r12d
    js .have_h
    lea eax, [r12d + 1]
    shl eax, 5
    add eax, LV_M                       ; room for light to spread up
    cmp eax, SECTIONS_PER_COLUMN * 32
    jbe .have_h
    mov eax, SECTIONS_PER_COLUMN * 32
.have_h:
    mov [rbx + LVOL.h], eax
    mov [LOCAL(LB_H)], eax
    test eax, eax
    jz .done                            ; nothing but sky
    shl eax, 12
    mov [LOCAL(LB_TOTAL)], eax

    ; ---- memory ----
    mov edx, [LOCAL(LB_TOTAL)]
    add edx, edx
    INVOKE arena_alloc, [LOCAL(LB_ARENA)], rdx, 64
    test rax, rax
    jz .fail
    mov [rbx + LVOL.light], rax
    mov rdi, rax
    mov ecx, [LOCAL(LB_TOTAL)]
    shr ecx, 2
    xor eax, eax
    rep stosq
    mov edx, [LOCAL(LB_TOTAL)]
    INVOKE arena_alloc, [LOCAL(LB_ARENA)], rdx, 64
    test rax, rax
    jz .fail
    mov [rbx + LVOL.op], rax
    mov rdi, rax
    mov ecx, [LOCAL(LB_TOTAL)]
    shr ecx, 3
    xor eax, eax
    rep stosq
    INVOKE arena_alloc, [LOCAL(LB_ARENA)], LV_LAYER * 4, 64
    test rax, rax
    jz .fail
    mov [LOCAL(LB_YTOP)], rax
    INVOKE arena_alloc, [LOCAL(LB_ARENA)], SECTION_VOLUME * 2, 64
    test rax, rax
    jz .fail
    mov [LOCAL(LB_TMP)], rax
    INVOKE arena_alloc, [LOCAL(LB_ARENA)], QCAP * 4, 64
    test rax, rax
    jz .fail
    mov r14, rax                        ; queue
    mov r12, [rbx + LVOL.light]
    mov r13, [rbx + LVOL.op]
    xor esi, esi                        ; head
    xor edi, edi                        ; tail

    ; ---- 1. blocks: light properties and emitters of the 9 columns ----
    mov dword [LOCAL(LB_C)], 0
.fill_col:
    mov eax, [LOCAL(LB_C)]
    xor edx, edx
    mov ecx, 3
    div ecx                             ; eax = dz + 1, edx = dx + 1
    ; x range inside that column: dx -1 -> 16..31, 0 -> 0..31, 1 -> 0..15
    xor ecx, ecx
    mov r8d, 32
    cmp edx, 0
    jne .x_not_left
    mov ecx, 16
.x_not_left:
    cmp edx, 2
    jne .x_not_right
    mov r8d, 16
.x_not_right:
    mov [LOCAL(LB_XS)], ecx
    mov [LOCAL(LB_XE)], r8d
    imul edx, edx, 32
    sub edx, 16
    mov [LOCAL(LB_DX)], edx             ; lx = x + (dx + 1) * 32 - 16
    xor ecx, ecx
    mov r8d, 32
    cmp eax, 0
    jne .z_not_left
    mov ecx, 16
.z_not_left:
    cmp eax, 2
    jne .z_not_right
    mov r8d, 16
.z_not_right:
    mov [LOCAL(LB_ZS)], ecx
    mov [LOCAL(LB_ZE)], r8d
    imul eax, eax, 32
    sub eax, 16
    mov [LOCAL(LB_DZ)], eax
    mov dword [LOCAL(LB_SY)], 0
.fill_sy:
    mov eax, [LOCAL(LB_SY)]
    shl eax, 5
    cmp eax, [LOCAL(LB_H)]
    jae .fill_col_next
    mov ecx, [LOCAL(LB_C)]
    call column_ptr
    mov ecx, [LOCAL(LB_SY)]
    mov rcx, [rax + COLUMN.sections + rcx * 8]
    test rcx, rcx
    jz .fill_sy_next                    ; air
    mov [LOCAL(LB_SECT)], rcx
    mov dword [LOCAL(LB_UNI)], -1
    cmp byte [rcx + SECT.bits], 0
    jne .decode
    movzx eax, word [rcx + SECT.uniform_id]
    mov [LOCAL(LB_UNI)], eax
    and eax, MAX_BLOCK_TYPES - 1
    lea rdx, [rel g_light_op]
    cmp byte [rdx + rax], 0
    jne .fill_box
    lea rdx, [rel g_block_light]
    cmp word [rdx + rax * 2], 0
    je .fill_sy_next                    ; uniform, light passes freely
    jmp .fill_box
.decode:
    INVOKE section_decode, [LOCAL(LB_SECT)], [LOCAL(LB_TMP)]
.fill_box:
    call fill_box
.fill_sy_next:
    inc dword [LOCAL(LB_SY)]
    cmp dword [LOCAL(LB_SY)], SECTIONS_PER_COLUMN
    jb .fill_sy
.fill_col_next:
    inc dword [LOCAL(LB_C)]
    cmp dword [LOCAL(LB_C)], 9
    jb .fill_col

    ; ---- 2. block light flood fill (queue = the emitters) ----
    mov eax, edi
    lock add [rel g_light_sources], rax
.bl_pop:
    cmp esi, edi
    je .bl_done
    mov eax, esi
    and eax, QMASK
    mov ebx, [r14 + rax * 4]            ; cell
    inc esi
    movzx eax, word [r12 + rbx * 2]
    and eax, 0xFFF
    jz .bl_pop
    ; channels as bytes: r | g << 8 | b << 16
    mov edx, eax
    and edx, 0xF
    mov ecx, eax
    and ecx, 0xF0
    shl ecx, 4
    or edx, ecx
    and eax, 0xF00
    shl eax, 8
    or edx, eax
    movd xmm4, edx                      ; source channels
    NB6 relax_block
    jmp .bl_pop
.bl_done:

    ; ---- 3. skylight straight down from the top ----
    xor esi, esi
    xor edi, edi
    mov r15, [LOCAL(LB_YTOP)]
    xor ecx, ecx                        ; column (xz)
.sky_col:
    mov eax, [LOCAL(LB_H)]
    mov [r15 + rcx * 4], eax            ; lowest 15 so far: none
    lea r8d, [eax - 1]
    shl r8d, 12
    add r8d, ecx                        ; cell
    mov r9d, 15
.sky_down:
    movzx eax, byte [r13 + r8]
    test eax, LOP_OPAQUE
    jnz .sky_col_done
    shr eax, LOP_FILTER_SHIFT
    sub r9d, eax
    jle .sky_col_done
    mov eax, r9d
    shl eax, 12
    or [r12 + r8 * 2], ax
    cmp r9d, 15
    jne .sky_not_full
    mov eax, r8d
    shr eax, 12
    mov [r15 + rcx * 4], eax
.sky_not_full:
    sub r8d, LV_LAYER
    jns .sky_down
.sky_col_done:
    inc ecx
    cmp ecx, LV_LAYER
    jb .sky_col

    ; seeds: full-sky cells beside a column whose full sky starts higher
    xor ecx, ecx
.seed_col:
    xor r9d, r9d                        ; highest neighbour start
    mov eax, ecx
    and eax, 63
    jz .seed_x0
    mov edx, [r15 + rcx * 4 - 4]
    cmp edx, r9d
    cmovg r9d, edx
.seed_x0:
    cmp eax, 63
    je .seed_x1
    mov edx, [r15 + rcx * 4 + 4]
    cmp edx, r9d
    cmovg r9d, edx
.seed_x1:
    mov eax, ecx
    shr eax, 6
    jz .seed_z0
    mov edx, [r15 + rcx * 4 - 256]
    cmp edx, r9d
    cmovg r9d, edx
.seed_z0:
    cmp eax, 63
    je .seed_z1
    mov edx, [r15 + rcx * 4 + 256]
    cmp edx, r9d
    cmovg r9d, edx
.seed_z1:
    mov r8d, [r15 + rcx * 4]            ; y from this column's start
.seed_y:
    cmp r8d, r9d
    jge .seed_next
    mov eax, r8d
    shl eax, 12
    add eax, ecx
    mov edx, edi
    sub edx, esi
    cmp edx, QCAP
    jae .seed_next
    mov edx, edi
    and edx, QMASK
    mov [r14 + rdx * 4], eax
    inc edi
    inc r8d
    jmp .seed_y
.seed_next:
    inc ecx
    cmp ecx, LV_LAYER
    jb .seed_col

    ; ---- 4. skylight flood fill ----
.sk_pop:
    cmp esi, edi
    je .sk_done
    mov eax, esi
    and eax, QMASK
    mov ebx, [r14 + rax * 4]
    inc esi
    movzx r9d, word [r12 + rbx * 2]
    shr r9d, 12                         ; source sky
    cmp r9d, 1
    jbe .sk_pop
    NB6 relax_sky
    jmp .sk_pop
.sk_done:

.done:
    call timer_elapsed_us
    sub rax, [LOCAL(LB_T0)]
    lock add [rel g_light_total_us], rax
    lock inc qword [rel g_light_count]
    mov rdx, rax
    lea rcx, [rel g_light_max_us]
    call atomic_max
    mov rax, [LOCAL(LB_VOL)]
    RETURN
.fail:
    xor eax, eax
    RETURN

; ---- helpers (share the frame: locals at +8 from a direct call) ----

; column_ptr: rax = the COLUMN* of neighbour slot ecx (0..8, volume order)
;   clobbers rax, rcx
column_ptr:
    lea rax, [rel col_nb]
    mov ecx, [rax + rcx * 4]
    mov rax, [LOCAL(LB_COL) + 8]
    test ecx, ecx
    js .self
    mov rax, [rax + COLUMN.nb + rcx * 8]
.self:
    ret

; fill_box: copy the light properties of the current section's box into
; the volume and queue its emitters (uniform: LB_UNI, else the decoded
; LB_TMP).   clobbers: volatile registers, rbx, r15 (rsi/rdi: queue)
fill_box:
    ; uniform section of a non-emitting block: whole rows at once
    mov eax, [LOCAL(LB_UNI) + 8]
    test eax, eax
    js .fb_cells
    and eax, MAX_BLOCK_TYPES - 1
    lea rdx, [rel g_block_light]
    cmp word [rdx + rax * 2], 0
    jne .fb_cells
    lea rdx, [rel g_light_op]
    movzx r11d, byte [rdx + rax]        ; the value
    push rdi
    xor ebx, ebx                        ; y
.fr_y:
    mov eax, [LOCAL(LB_SY) + 16]
    shl eax, 5
    add eax, ebx
    cmp eax, [LOCAL(LB_H) + 16]
    jae .fr_done
    shl eax, 12
    mov r15d, eax
    mov r9d, [LOCAL(LB_ZS) + 16]
.fr_z:
    cmp r9d, [LOCAL(LB_ZE) + 16]
    jae .fr_y_next
    mov edx, r9d
    add edx, [LOCAL(LB_DZ) + 16]
    shl edx, 6
    add edx, [LOCAL(LB_XS) + 16]
    add edx, [LOCAL(LB_DX) + 16]
    add edx, r15d
    lea rdi, [r13 + rdx]
    mov ecx, [LOCAL(LB_XE) + 16]
    sub ecx, [LOCAL(LB_XS) + 16]
    mov eax, r11d
    rep stosb
    inc r9d
    jmp .fr_z
.fr_y_next:
    inc ebx
    cmp ebx, 32
    jb .fr_y
.fr_done:
    pop rdi
    ret
.fb_cells:
    xor ebx, ebx                        ; y
.fb_y:
    mov eax, [LOCAL(LB_SY) + 8]
    shl eax, 5
    add eax, ebx                        ; ly
    cmp eax, [LOCAL(LB_H) + 8]
    jae .fb_done
    shl eax, 12
    mov r15d, eax                       ; layer base
    mov r9d, [LOCAL(LB_ZS) + 8]         ; z
.fb_z:
    cmp r9d, [LOCAL(LB_ZE) + 8]
    jae .fb_y_next
    mov r10d, [LOCAL(LB_XS) + 8]        ; x
.fb_x:
    cmp r10d, [LOCAL(LB_XE) + 8]
    jae .fb_z_next
    mov eax, [LOCAL(LB_UNI) + 8]
    test eax, eax
    jns .fb_id
    mov eax, ebx
    shl eax, 10
    mov edx, r9d
    shl edx, 5
    add eax, edx
    add eax, r10d
    mov rdx, [LOCAL(LB_TMP) + 8]
    movzx eax, word [rdx + rax * 2]
.fb_id:
    and eax, MAX_BLOCK_TYPES - 1
    ; volume cell
    lea edx, [r9d + 0]
    add edx, [LOCAL(LB_DZ) + 8]
    shl edx, 6
    add edx, r10d
    add edx, [LOCAL(LB_DX) + 8]
    add edx, r15d
    lea r8, [rel g_light_op]
    movzx r11d, byte [r8 + rax]
    mov [r13 + rdx], r11b
    lea r8, [rel g_block_light]
    movzx r11d, word [r8 + rax * 2]
    test r11d, r11d
    jz .fb_next
    ; an emitter: its light, queued (inside a uniform section only its
    ; boundary: the cells within are surrounded by the same block)
    mov [r12 + rdx * 2], r11w
    cmp dword [LOCAL(LB_UNI) + 8], 0
    jl .fb_queue
    test ebx, ebx
    jz .fb_queue
    cmp ebx, 31
    je .fb_queue
    cmp r9d, [LOCAL(LB_ZS) + 8]
    je .fb_queue
    mov eax, [LOCAL(LB_ZE) + 8]
    dec eax
    cmp r9d, eax
    je .fb_queue
    cmp r10d, [LOCAL(LB_XS) + 8]
    je .fb_queue
    mov eax, [LOCAL(LB_XE) + 8]
    dec eax
    cmp r10d, eax
    jne .fb_next
.fb_queue:
    mov eax, edi
    sub eax, esi
    cmp eax, QCAP
    jae .fb_next
    mov eax, edi
    and eax, QMASK
    mov [r14 + rax * 4], edx
    inc edi
.fb_next:
    inc r10d
    jmp .fb_x
.fb_z_next:
    inc r9d
    jmp .fb_z
.fb_y_next:
    inc ebx
    cmp ebx, 32
    jb .fb_y
.fb_done:
    ret

; relax_block: neighbour ecx of the current cell; xmm4 = the source's
; channels as bytes. Spreads block light into it (minus 1 + its filter per
; channel, saturating) and queues it if it got brighter.
;   clobbers: rax, rdx, r8, r11, xmm0-xmm2
relax_block:
    movzx eax, byte [r13 + rcx]
    test eax, LOP_OPAQUE
    jnz .rb_ret
    shr eax, LOP_FILTER_SHIFT
    inc eax
    imul eax, eax, 0x010101
    movd xmm1, eax
    movdqa xmm0, xmm4
    psubusb xmm0, xmm1                  ; what arrives
    movd eax, xmm0
    test eax, eax
    jz .rb_ret
    movzx r8d, word [r12 + rcx * 2]     ; current
    mov edx, r8d
    and edx, 0xF
    mov r11d, r8d
    and r11d, 0xF0
    shl r11d, 4
    or edx, r11d
    mov r11d, r8d
    and r11d, 0xF00
    shl r11d, 8
    or edx, r11d
    movd xmm2, edx
    pmaxub xmm2, xmm0
    movd eax, xmm2
    cmp eax, edx
    je .rb_ret                          ; no channel got brighter
    ; pack back into nibbles, keep the sky
    mov edx, eax
    and edx, 0xF
    mov r11d, eax
    shr r11d, 4
    and r11d, 0xF0
    or edx, r11d
    shr eax, 8
    and eax, 0xF00
    or edx, eax
    and r8d, 0xF000
    or edx, r8d
    mov [r12 + rcx * 2], dx
    mov eax, edi
    sub eax, esi
    cmp eax, QCAP
    jae .rb_ret
    mov eax, edi
    and eax, QMASK
    mov [r14 + rax * 4], ecx
    inc edi
.rb_ret:
    ret

; relax_sky: neighbour ecx; r9d = the source's sky. Spreads skylight (minus
; 1 + filter) and queues the cell if it got brighter.
;   clobbers: rax, rdx, r8
relax_sky:
    movzx eax, byte [r13 + rcx]
    test eax, LOP_OPAQUE
    jnz .rs_ret
    shr eax, LOP_FILTER_SHIFT
    mov edx, r9d
    sub edx, eax
    dec edx                             ; arriving sky
    jle .rs_ret
    movzx r8d, word [r12 + rcx * 2]
    mov eax, r8d
    shr eax, 12
    cmp edx, eax
    jle .rs_ret
    and r8d, 0xFFF
    shl edx, 12
    or r8d, edx
    mov [r12 + rcx * 2], r8w
    mov eax, edi
    sub eax, esi
    cmp eax, QCAP
    jae .rs_ret
    mov eax, edi
    and eax, QMASK
    mov [r14 + rax * 4], ecx
    inc edi
.rs_ret:
    ret
ENDPROC
