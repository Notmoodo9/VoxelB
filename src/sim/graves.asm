; =============================================================================
; graves.asm — gravestones (milestone 20 part 2, design/survival/survival.md).
;
; In a world whose death rule is `grave` (world.dat death = grave), what the
; player carries (the 36 slots and the off hand) goes into a gravestone
; where they died instead of dropping: a block (data/recipes [grave]: the
; `gravestone` block, shape headstone) placed in the first free cell at or
; above the death spot, settled down onto the ground. It shows the player's
; name and the day (the client's floating label, PKT_S_GRAVE).
; Right-clicking it (crafting.asm hands every station of kind STATION_GRAVE
; here) puts everything back: each item into the slot it came from if that
; slot is empty, else wherever it fits (inv_add_dur); what does not fit
; drops at the stone. Emptied, it crumbles (the block becomes air). It
; cannot be mined (mining.cfg: unbreakable); a stone removed some other way
; (Creative) drops its items.
; No room for a stone (no free cell, the world not generated there, all
; MAX_GRAVES in use): the items drop as with the `drop` rule.
; Saved in <world>\graves.dat: `grave = x, y, z, day, name`, then its
; items: `item = slot, item name, count, wear`.
;
; Public API:
;   graves_reset()                      a new world: none
;   graves_load()                       after save_open (graves.dat); sends
;                                       the client every gravestone
;   graves_save()                       with the world (save_all)
;   graves_make() -> eax 1 if the items went into a gravestone (g_grave_pos),
;                    2 not now (the column is busy: try again), 0 no
;   graves_use(ecx = x, edx = y, r8d = z)   right click
;   graves_broken(ecx = x, edx = y, r8d = z)  a block was removed
;   g_grave_pos (i32 x 3: the last gravestone made), g_grave_count (overlay)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "cfg.inc"
%include "packet.inc"
%include "block.inc"
%include "world.inc"

global graves_reset, graves_load, graves_save, graves_make, graves_use
global graves_broken, g_grave_pos, g_grave_count

extern phys_block, edit_apply, edit_queue, inv_add_dur, inv_mark, drops_spawn_dur
extern pkt_send, g_to_client, g_inv, g_pl_pos, g_pl_reach, g_save_enabled
extern world_spawn
extern g_world_day, g_item_names, block_find
extern save_text_load, save_text_release, save_text_write, item_find
extern str_copy, str_append_sdec, str_append_dec, str_parse_u64, str_ieq

IMPORT GetEnvironmentVariableA

%define SLOT_SIZE       8
%define GRAVE_ITEMS     (INV_SLOTS + 1) ; the 36 slots and the off hand
%define NAME_LEN        24              ; GRAVE_PKT.name
%define SEARCH_UP       8               ; cells looked at above the death spot
%define SETTLE_DOWN     16              ; cells it may sink to reach the ground

struc GRAVE
    .x      resd 1
    .y      resd 1
    .z      resd 1
    .day    resd 1
    .used   resd 1
    .count  resd 1                      ; items
    .name   resb NAME_LEN
    .items  resq GRAVE_ITEMS            ; {u16 slot, u16 item, u16 count, u16 wear}
endstruc

section .rdata
str_file:       db "graves.dat", 0
str_label:      db "graves.dat", 0
str_block:      db "gravestone", 0
str_env:        db "USERNAME", 0
str_nameless:   db "a traveller", 0
k_grave:        db "grave", 0
k_item:         db "item", 0
t_head:         db "# Gravestones (written by the game): grave = x, y, z, day, name;", 13, 10
                db "# then its items: item = slot, item, count, wear", 13, 10, 0
t_grave:        db "grave = ", 0
t_item:         db "item = ", 0
t_comma:        db ", ", 0
t_nl:           db 13, 10, 0
align 16
c_abs:          dq 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF
c_half:         dq 0.5
c_reach_extra:  dq 2.0

section .bss
alignb 8
g_graves:       resb MAX_GRAVES * GRAVE_size
g_grave_count:  resd 1
g_grave_pos:    resd 3
g_cur:          resd 1                  ; graves.dat: the grave its item lines go to
g_vals:         resd 5
alignb 8
g_drop_at:      resq 3
g_pkt:          resb GRAVE_PKT_size
g_name:         resb 64                 ; the player's name

section .text

; grave_ptr — rax = &g_graves[ecx]   clobbers: rax
grave_ptr:
    imul eax, ecx, GRAVE_size
    push rcx
    lea rcx, [rel g_graves]
    add rax, rcx
    pop rcx
    ret

; -----------------------------------------------------------------------------
; graves_reset — no gravestones
;   clobbers: rax, rcx, rdi
; -----------------------------------------------------------------------------
PROC graves_reset, 0, rdi
    lea rdi, [rel g_graves]
    xor eax, eax
    mov ecx, MAX_GRAVES * GRAVE_size / 8
    rep stosq
    mov dword [rel g_grave_count], 0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; send — PKT_S_GRAVE for grave ecx (its state now).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC send, 0, rbx, rsi, rdi
    mov ebx, ecx
    call grave_ptr
    mov rsi, rax
    mov [rel g_pkt + GRAVE_PKT.index], bx
    mov eax, [rsi + GRAVE.used]
    mov [rel g_pkt + GRAVE_PKT.used], ax
    mov eax, [rsi + GRAVE.x]
    mov [rel g_pkt + GRAVE_PKT.pos], eax
    mov eax, [rsi + GRAVE.y]
    mov [rel g_pkt + GRAVE_PKT.pos + 4], eax
    mov eax, [rsi + GRAVE.z]
    mov [rel g_pkt + GRAVE_PKT.pos + 8], eax
    mov eax, [rsi + GRAVE.day]
    mov [rel g_pkt + GRAVE_PKT.day], eax
    lea rdi, [rel g_pkt + GRAVE_PKT.name]
    add rsi, GRAVE.name
    mov ecx, NAME_LEN
    rep movsb
    lea rcx, [rel g_to_client]
    lea r8, [rel g_pkt]
    INVOKE pkt_send, rcx, PKT_S_GRAVE, r8, GRAVE_PKT_size
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; free_record — eax = an unused grave, -1 if all are used
;   clobbers: rax, rcx
; -----------------------------------------------------------------------------
free_record:
    xor ecx, ecx
.next:
    cmp ecx, MAX_GRAVES
    jae .none
    call grave_ptr
    cmp dword [rax + GRAVE.used], 0
    je .found
    inc ecx
    jmp .next
.found:
    mov eax, ecx
    ret
.none:
    mov eax, -1
    ret

; -----------------------------------------------------------------------------
; find — eax = the grave at (ecx, edx, r8d), -1 if none
;   clobbers: rax, r9, r10
; -----------------------------------------------------------------------------
find:
    lea r9, [rel g_graves]
    xor eax, eax
.next:
    cmp eax, MAX_GRAVES
    jae .none
    cmp dword [r9 + GRAVE.used], 0
    je .skip
    cmp [r9 + GRAVE.x], ecx
    jne .skip
    cmp [r9 + GRAVE.y], edx
    jne .skip
    cmp [r9 + GRAVE.z], r8d
    je .found
.skip:
    add r9, GRAVE_size
    inc eax
    jmp .next
.none:
    mov eax, -1
.found:
    ret

; -----------------------------------------------------------------------------
; forget — grave ecx is gone: the record is freed, the client told.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC forget, 0, rbx
    mov ebx, ecx
    call grave_ptr
    mov dword [rax + GRAVE.used], 0
    mov dword [rax + GRAVE.count], 0
    dec dword [rel g_grave_count]
    mov ecx, ebx
    call send
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; free_cell — eax = 1 if a gravestone may stand in (ecx, edx, r8d): air, a
; liquid or a plant; 0 if not; -1 if it is not generated.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC free_cell, 0
    call phys_block
    cmp eax, -1
    je .done
    test eax, eax
    jz .yes
    lea rcx, [rel g_block_phys]
    test byte [rcx + rax], BPHYS_LIQUID_MASK
    jnz .yes
    lea rcx, [rel g_block_shape]
    movzx ecx, byte [rcx + rax]
    cmp ecx, SHAPE_PLANT
    je .yes
    cmp ecx, SHAPE_TALL_PLANT
    je .yes
    xor eax, eax
    RETURN
.yes:
    mov eax, 1
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; player_name — the player's name into rcx (NAME_LEN bytes, zero-terminated):
; the Windows user name, else "a traveller".
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC player_name, 0, rbx
    mov rbx, rcx
    lea rcx, [rel str_env]
    lea rdx, [rel g_name]
    API GetEnvironmentVariableA, rcx, rdx, 64
    test eax, eax
    jz .nameless
    cmp eax, 64
    jae .nameless
    lea rdx, [rel g_name]
    jmp .copy
.nameless:
    lea rdx, [rel str_nameless]
.copy:
    xor ecx, ecx
.ch:
    mov al, [rdx + rcx]
    mov [rbx + rcx], al
    test al, al
    jz .done
    inc ecx
    cmp ecx, NAME_LEN - 1
    jb .ch
    mov byte [rbx + rcx], 0
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; graves_make — the player died with the `grave` rule: everything they carry
; goes into a new gravestone near where they are.
;   out: eax = 1 if it did (g_grave_pos; the slots are emptied), 2 not now
;        (the column is busy meshing: try again next tick), 0 if not (the
;        caller drops the items)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define M_X     0
%define M_Y     4
%define M_Z     8
%define M_REC   12
%define M_STEP  16
%define M_SPAWN 24                      ; f64 x 3: the world's spawn
%define M_FACE  48
PROC graves_make, 64, rbx, rsi, rdi
    ; anything to keep?
    xor esi, esi
    xor ecx, ecx
.any:
    cmp ecx, INV_SLOTS
    jae .offhand
    lea rax, [rel g_inv]
    cmp word [rax + rcx * SLOT_SIZE], 0
    je .any_next
    inc esi
.any_next:
    inc ecx
    jmp .any
.offhand:
    lea rax, [rel g_inv]
    cmp word [rax + INV_OFFHAND * SLOT_SIZE], 0
    je .counted
    inc esi
.counted:
    test esi, esi
    jz .no
    call free_record
    cmp eax, -1
    je .no
    mov [LOCAL(M_REC)], eax
    ; the cell: the feet's, or the first free one above it
    xor ebx, ebx
.pos:
    lea rax, [rel g_pl_pos]
    movsd xmm0, [rax + rbx * 8]
    roundsd xmm0, xmm0, 9
    cvttsd2si eax, xmm0
    mov [LOCAL(M_X) + rbx * 4], eax
    inc ebx
    cmp ebx, 3
    jb .pos
    mov dword [LOCAL(M_STEP)], 0
.up:
    mov ecx, [LOCAL(M_X)]
    mov edx, [LOCAL(M_Y)]
    mov r8d, [LOCAL(M_Z)]
    call free_cell
    cmp eax, -1
    je .no
    test eax, eax
    jnz .settle
    inc dword [LOCAL(M_Y)]
    inc dword [LOCAL(M_STEP)]
    cmp dword [LOCAL(M_STEP)], SEARCH_UP
    jb .up
    jmp .no
.settle:
    ; down onto the ground (a fall into a ravine: on its floor)
    mov dword [LOCAL(M_STEP)], 0
.down:
    mov ecx, [LOCAL(M_X)]
    mov edx, [LOCAL(M_Y)]
    dec edx
    mov r8d, [LOCAL(M_Z)]
    call free_cell
    cmp eax, 1
    jne .place
    dec dword [LOCAL(M_Y)]
    inc dword [LOCAL(M_STEP)]
    cmp dword [LOCAL(M_STEP)], SETTLE_DOWN
    jb .down
.place:
    ; its front (north in its own frame) turned towards the world's spawn,
    ; where the player comes back from: state 0 north, 1 east, 2 south, 3 west
    mov dword [LOCAL(M_FACE)], 0
    lea rcx, [LOCAL(M_SPAWN)]
    call world_spawn
    test eax, eax
    jz .faced
    cvtsi2sd xmm0, dword [LOCAL(M_X)]
    movsd xmm2, [LOCAL(M_SPAWN)]
    subsd xmm2, xmm0                    ; dx
    cvtsi2sd xmm0, dword [LOCAL(M_Z)]
    movsd xmm3, [LOCAL(M_SPAWN) + 16]
    subsd xmm3, xmm0                    ; dz
    movsd xmm4, xmm2
    andpd xmm4, [rel c_abs]
    movsd xmm5, xmm3
    andpd xmm5, [rel c_abs]
    xorpd xmm0, xmm0
    comisd xmm4, xmm5
    ja .east_west
    comisd xmm3, xmm0
    jb .faced                           ; (north)
    mov dword [LOCAL(M_FACE)], 2        ; south
    jmp .faced
.east_west:
    mov dword [LOCAL(M_FACE)], 1        ; east
    comisd xmm2, xmm0
    jae .faced
    mov dword [LOCAL(M_FACE)], 3        ; west
.faced:
    lea rcx, [rel str_block]
    call block_find
    test eax, eax
    jle .no
    lea r9d, [eax + 0]
    add r9d, [LOCAL(M_FACE)]
    mov ecx, [LOCAL(M_X)]
    mov edx, [LOCAL(M_Y)]
    mov r8d, [LOCAL(M_Z)]
    call edit_apply
    cmp eax, 1
    je .placed
    test eax, eax
    jnz .no
    mov eax, 2                          ; (busy: again next tick)
    RETURN
.placed:
    ; the record: where, when, whose, what
    mov ecx, [LOCAL(M_REC)]
    call grave_ptr
    mov rbx, rax
    mov eax, [LOCAL(M_X)]
    mov [rbx + GRAVE.x], eax
    mov [rel g_grave_pos], eax
    mov eax, [LOCAL(M_Y)]
    mov [rbx + GRAVE.y], eax
    mov [rel g_grave_pos + 4], eax
    mov eax, [LOCAL(M_Z)]
    mov [rbx + GRAVE.z], eax
    mov [rel g_grave_pos + 8], eax
    mov eax, [rel g_world_day]
    mov [rbx + GRAVE.day], eax
    mov dword [rbx + GRAVE.used], 1
    mov dword [rbx + GRAVE.count], 0
    inc dword [rel g_grave_count]
    lea rcx, [rbx + GRAVE.name]
    call player_name
    xor esi, esi
.take:
    cmp esi, INV_SLOTS
    jbe .slot
    jmp .taken
.slot:
    mov edi, esi
    cmp esi, INV_SLOTS
    jb .have_slot
    mov edi, INV_OFFHAND                ; (the last one: the off hand)
.have_slot:
    lea rax, [rel g_inv]
    lea rdx, [rax + rdi * SLOT_SIZE]
    movzx eax, word [rdx]
    test eax, eax
    jz .take_next
    mov ecx, [rbx + GRAVE.count]
    lea r8, [rbx + GRAVE.items + rcx * 8]
    mov [r8], di                        ; slot
    mov [r8 + 2], ax                    ; item
    mov ax, [rdx + 2]
    mov [r8 + 4], ax                    ; count
    mov ax, [rdx + 4]
    mov [r8 + 6], ax                    ; wear
    inc dword [rbx + GRAVE.count]
    mov qword [rdx], 0
    mov ecx, edi
    call inv_mark
.take_next:
    inc esi
    jmp .take
.taken:
    mov ecx, [LOCAL(M_REC)]
    call send
    LOG_INFO "graves: the items went into a gravestone"
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; drop_item — item r8 (a GRAVE item) drops at grave rbx
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC drop_item, 0, rsi
    mov rsi, r8
    cvtsi2sd xmm0, dword [rbx + GRAVE.x]
    addsd xmm0, [rel c_half]
    movsd [rel g_drop_at], xmm0
    cvtsi2sd xmm0, dword [rbx + GRAVE.y]
    addsd xmm0, [rel c_half]
    addsd xmm0, [rel c_half]
    movsd [rel g_drop_at + 8], xmm0
    cvtsi2sd xmm0, dword [rbx + GRAVE.z]
    addsd xmm0, [rel c_half]
    movsd [rel g_drop_at + 16], xmm0
    movzx ecx, word [rsi + 2]
    movzx edx, word [rsi + 4]
    lea r8, [rel g_drop_at]
    movzx r9d, word [rsi + 6]
    call drops_spawn_dur
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; graves_use — see the header: everything back to the player, the stone
; crumbles.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define U_X     0
%define U_Y     4
%define U_Z     8
%define U_REC   12
PROC graves_use, 32, rbx, rsi, rdi
    mov [LOCAL(U_X)], ecx
    mov [LOCAL(U_Y)], edx
    mov [LOCAL(U_Z)], r8d
    ; within reach of the player
    cvtsi2sd xmm0, ecx
    addsd xmm0, [rel c_half]
    subsd xmm0, [rel g_pl_pos]
    cvtsi2sd xmm1, edx
    subsd xmm1, [rel g_pl_pos + 8]
    cvtsi2sd xmm2, r8d
    addsd xmm2, [rel c_half]
    subsd xmm2, [rel g_pl_pos + 16]
    mulsd xmm0, xmm0
    mulsd xmm1, xmm1
    mulsd xmm2, xmm2
    addsd xmm0, xmm1
    addsd xmm0, xmm2
    cvtss2sd xmm1, [rel g_pl_reach]
    addsd xmm1, [rel c_reach_extra]
    mulsd xmm1, xmm1
    comisd xmm0, xmm1
    ja .done
    call find
    cmp eax, -1
    je .crumble                         ; (a stone without a record: just crumbles)
    mov [LOCAL(U_REC)], eax
    mov ecx, eax
    call grave_ptr
    mov rbx, rax
    xor esi, esi
.item:
    cmp esi, [rbx + GRAVE.count]
    jae .emptied
    lea rdi, [rbx + GRAVE.items + rsi * 8]
    ; its own slot, if that is empty
    movzx ecx, word [rdi]
    cmp ecx, INV_ALL
    jae .anywhere
    lea rax, [rel g_inv]
    lea rdx, [rax + rcx * SLOT_SIZE]
    cmp word [rdx], 0
    jne .anywhere
    mov ax, [rdi + 2]
    mov [rdx], ax
    mov ax, [rdi + 4]
    mov [rdx + 2], ax
    mov ax, [rdi + 6]
    mov [rdx + 4], ax
    mov word [rdx + 6], 0
    call inv_mark
    jmp .next
.anywhere:
    movzx ecx, word [rdi + 2]
    movzx edx, word [rdi + 4]
    movzx r8d, word [rdi + 6]
    call inv_add_dur
    test eax, eax
    jz .next
    ; what does not fit drops at the stone
    mov [rdi + 4], ax
    mov r8, rdi
    call drop_item
.next:
    inc esi
    jmp .item
.emptied:
    mov ecx, [LOCAL(U_REC)]
    call forget
    LOG_INFO "graves: a gravestone was emptied"
.crumble:
    mov ecx, [LOCAL(U_X)]
    mov edx, [LOCAL(U_Y)]
    mov r8d, [LOCAL(U_Z)]
    xor r9d, r9d
    call edit_queue                     ; (as soon as the column is free)
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; graves_broken — a block at (ecx, edx, r8d) was removed: a gravestone's
; items drop there.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC graves_broken, 16, rbx, rsi
    call find
    cmp eax, -1
    je .done
    mov [LOCAL(0)], eax
    mov ecx, eax
    call grave_ptr
    mov rbx, rax
    xor esi, esi
.item:
    cmp esi, [rbx + GRAVE.count]
    jae .dropped
    lea r8, [rbx + GRAVE.items + rsi * 8]
    call drop_item
    inc esi
    jmp .item
.dropped:
    mov ecx, [LOCAL(0)]
    call forget
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; graves_save — graves.dat (written even when there are none)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC graves_save, 16, rbx, rsi, rdi, r12
    cmp dword [rel g_save_enabled], 0
    je .done
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, MAX_GRAVES * (GRAVE_ITEMS + 1) * 128 + 256, 16
    test rax, rax
    jz .release
    mov rdi, rax
    mov rcx, rax
    lea rdx, [rel t_head]
    call str_copy
    xor esi, esi
.grave:
    cmp esi, MAX_GRAVES
    jae .write
    mov ecx, esi
    mov rbx, rax
    call grave_ptr
    xchg rbx, rax
    cmp dword [rbx + GRAVE.used], 0
    je .next
    mov rcx, rax
    lea rdx, [rel t_grave]
    call str_copy
    movsxd rdx, dword [rbx + GRAVE.x]
    INVOKE str_append_sdec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    movsxd rdx, dword [rbx + GRAVE.y]
    INVOKE str_append_sdec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    movsxd rdx, dword [rbx + GRAVE.z]
    INVOKE str_append_sdec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    mov edx, [rbx + GRAVE.day]
    INVOKE str_append_dec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    mov rcx, rax
    lea rdx, [rbx + GRAVE.name]
    call str_copy
    mov rcx, rax
    lea rdx, [rel t_nl]
    call str_copy
    xor r12d, r12d
.item:
    cmp r12d, [rbx + GRAVE.count]
    jae .next
    mov rcx, rax
    lea rdx, [rel t_item]
    call str_copy
    movzx edx, word [rbx + GRAVE.items + r12 * 8]
    INVOKE str_append_dec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    movzx ecx, word [rbx + GRAVE.items + r12 * 8 + 2]
    lea rdx, [rel g_item_names]
    mov rdx, [rdx + rcx * 8]
    mov rcx, rax
    call str_copy
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    movzx edx, word [rbx + GRAVE.items + r12 * 8 + 4]
    INVOKE str_append_dec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    movzx edx, word [rbx + GRAVE.items + r12 * 8 + 6]
    INVOKE str_append_dec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_nl]
    call str_copy
    inc r12d
    jmp .item
.next:
    inc esi
    jmp .grave
.write:
    lea rdx, [rel str_file]
    mov r8, rdi
    call save_text_write
.release:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; graves_load — graves.dat (a world without one: none); the client is sent
; every gravestone.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC graves_load, 0, rbx
    call graves_reset
    mov dword [rel g_cur], -1
    cmp dword [rel g_save_enabled], 0
    je .done
    lea rdx, [rel str_file]
    call save_text_load
    test rax, rax
    jz .release
    lea rdx, [rel grave_pair]
    lea r9, [rel str_label]
    INVOKE cfg_parse, rax, rdx, 0, r9
.release:
    call save_text_release
    xor ebx, ebx
.send:
    cmp ebx, MAX_GRAVES
    jae .sent
    mov ecx, ebx
    call grave_ptr
    cmp dword [rax + GRAVE.used], 0
    je .send_next
    mov ecx, ebx
    call send
.send_next:
    inc ebx
    jmp .send
.sent:
    cmp dword [rel g_grave_count], 0
    je .done
    LOG_INFO "graves: gravestones were loaded"
.done:
    RETURN
ENDPROC

; numbers — ecx numbers (signed) of the list at rsi into g_vals; rsi moves on
;   out: eax = 1 if all were there   clobbers: volatile registers but rsi
PROC numbers, 16, rbx, rdi
    mov ebx, ecx
    xor edi, edi
.num:
    cmp edi, ebx
    jae .ok
    test rsi, rsi
    jz .short
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    xor r8d, r8d
    cmp byte [rax], '-'
    jne .digits
    mov r8d, 1
    inc rax
.digits:
    mov [LOCAL(0)], r8d
    mov rcx, rax
    call str_parse_u64
    cmp dword [LOCAL(0)], 0
    je .positive
    neg eax
.positive:
    lea rcx, [rel g_vals]
    mov [rcx + rdi * 4], eax
    inc edi
    jmp .num
.ok:
    mov eax, 1
    RETURN
.short:
    xor eax, eax
    RETURN
ENDPROC

; grave_pair — graves.dat callback: rcx = name, rdx = value
PROC grave_pair, 16, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    lea rdx, [rel k_grave]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_grave
    ; grave = x, y, z, day, name
    mov dword [rel g_cur], -1
    mov ecx, 4
    call numbers
    test eax, eax
    jz .done
    test rsi, rsi
    jz .done
    call free_record
    cmp eax, -1
    je .done
    mov [rel g_cur], eax
    mov ecx, eax
    call grave_ptr
    mov rdi, rax
    mov eax, [rel g_vals]
    mov [rdi + GRAVE.x], eax
    mov eax, [rel g_vals + 4]
    mov [rdi + GRAVE.y], eax
    mov eax, [rel g_vals + 8]
    mov [rdi + GRAVE.z], eax
    mov eax, [rel g_vals + 12]
    mov [rdi + GRAVE.day], eax
    mov dword [rdi + GRAVE.used], 1
    mov dword [rdi + GRAVE.count], 0
    inc dword [rel g_grave_count]
    mov rcx, rsi
    call cfg_next_token
    xor ecx, ecx
.name:
    mov dl, [rax + rcx]
    mov [rdi + GRAVE.name + rcx], dl
    test dl, dl
    jz .done
    inc ecx
    cmp ecx, NAME_LEN - 1
    jb .name
    mov byte [rdi + GRAVE.name + rcx], 0
    RETURN
.not_grave:
    lea rdx, [rel k_item]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .done
    ; item = slot, item, count, wear (for the last grave)
    cmp dword [rel g_cur], -1
    je .done
    mov ecx, 1
    call numbers
    test eax, eax
    jz .done
    test rsi, rsi
    jz .done
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    mov rcx, rax
    call item_find
    test eax, eax
    jle .done
    mov [LOCAL(0)], eax
    mov eax, [rel g_vals]
    mov [LOCAL(4)], eax
    mov ecx, 2
    call numbers
    test eax, eax
    jz .done
    mov ecx, [rel g_cur]
    call grave_ptr
    mov rdi, rax
    mov ecx, [rdi + GRAVE.count]
    cmp ecx, GRAVE_ITEMS
    jae .done
    lea r8, [rdi + GRAVE.items + rcx * 8]
    mov eax, [LOCAL(4)]
    mov [r8], ax
    mov eax, [LOCAL(0)]
    mov [r8 + 2], ax
    mov eax, [rel g_vals]
    test eax, eax
    jle .done
    mov [r8 + 4], ax
    mov eax, [rel g_vals + 4]
    mov [r8 + 6], ax
    inc dword [rdi + GRAVE.count]
.done:
    RETURN
ENDPROC
