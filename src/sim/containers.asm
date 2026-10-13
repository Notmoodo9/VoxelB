; =============================================================================
; containers.asm — what is inside chests (and later other containers), owned
; by the simulation (milestone 18 part 3, design/items/items_inventory.md).
;
; A container is a block position with up to CONT_SLOTS slots (the same
; {u16 item, u16 count, u16 durability, u16 spare} as the inventory). An
; entry is made when a container block is first opened, and saved with the
; world (save.asm: containers.dat) while it holds anything. The open window
; shows a copy (crafting.asm) that is written back when it closes or the
; world saves.
;
; Public API:
;   cont_reset()
;   cont_find(ecx = x, edx = y, r8d = z) -> eax entry, -1 none
;   cont_get(ecx = x, edx = y, r8d = z) -> eax entry (made if new), -1 full
;   cont_slots(ecx = entry) -> rax SLOT[CONT_SLOTS]
;   cont_remove(ecx = entry)
;   g_conts (CONT[MAX_CONTAINERS]), g_cont_count (entries in use or freed:
;   the highest used index + 1)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%define CONTAINERS_IMPL
%include "containers.inc"

global cont_reset, cont_find, cont_get, cont_slots, cont_remove
global g_conts, g_cont_count

section .bss
alignb 16
g_conts:        resb MAX_CONTAINERS * CONT_size
g_cont_count:   resd 1
g_full_warned:  resd 1

section .text

; cont_reset — no containers   clobbers: rax, rcx, rdi
PROC cont_reset, 0, rdi
    lea rdi, [rel g_conts]
    xor eax, eax
    mov ecx, MAX_CONTAINERS * CONT_size / 8
    rep stosq
    mov dword [rel g_cont_count], 0
    mov dword [rel g_full_warned], 0
    RETURN
ENDPROC

; cont_find — see the header   clobbers: rax, r9, r10
cont_find:
    lea r9, [rel g_conts]
    xor eax, eax
.e:
    cmp eax, [rel g_cont_count]
    jae .none
    cmp dword [r9 + CONT.used], 0
    je .next
    cmp [r9 + CONT.x], ecx
    jne .next
    cmp [r9 + CONT.y], edx
    jne .next
    cmp [r9 + CONT.z], r8d
    je .done
.next:
    add r9, CONT_size
    inc eax
    jmp .e
.none:
    mov eax, -1
.done:
    ret

; cont_get — see the header   clobbers: rax, r9, r10, r11
PROC cont_get, 0
    call cont_find
    cmp eax, -1
    jne .done
    ; a free entry (or a new one at the end)
    lea r9, [rel g_conts]
    xor eax, eax
.free:
    cmp eax, [rel g_cont_count]
    jae .append
    cmp dword [r9 + CONT.used], 0
    je .take
    add r9, CONT_size
    inc eax
    jmp .free
.append:
    cmp eax, MAX_CONTAINERS
    jae .full
    inc dword [rel g_cont_count]
.take:
    mov [r9 + CONT.x], ecx
    mov [r9 + CONT.y], edx
    mov [r9 + CONT.z], r8d
    mov dword [r9 + CONT.used], 1
    mov dword [r9 + CONT.station], 0    ; (station, lit, pad)
    mov dword [r9 + CONT.burn], 0
    mov dword [r9 + CONT.burn_max], 0
    mov dword [r9 + CONT.cook], 0
    lea r10, [r9 + CONT.slots]
    mov r11d, CONT_SLOTS
.clear:
    mov qword [r10], 0
    add r10, 8
    dec r11d
    jnz .clear
.done:
    RETURN
.full:
    cmp dword [rel g_full_warned], 0
    jne .none
    mov dword [rel g_full_warned], 1
    LOG_WARN "containers: too many in this world (4096); a new one stays empty"
.none:
    mov eax, -1
    RETURN
ENDPROC

; cont_slots — rax = the slots of entry ecx   clobbers: rax
cont_slots:
    imul eax, ecx, CONT_size
    add rax, CONT.slots
    push rcx
    lea rcx, [rel g_conts]
    add rax, rcx
    pop rcx
    ret

; cont_remove — entry ecx is gone (its items are the caller's)   clobbers: rax
cont_remove:
    cmp ecx, [rel g_cont_count]
    jae .done
    imul eax, ecx, CONT_size
    push rcx
    lea rcx, [rel g_conts]
    mov dword [rcx + rax + CONT.used], 0
    pop rcx
.done:
    ret
