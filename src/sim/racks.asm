; =============================================================================
; racks.asm — drying racks (milestone 19 part 3, design/mobs/passive_animals.md
; "Hides and drying"; DATA_FORMAT.md "Recipe files" [rack]).
;
; Right-clicking a rack (crafting.asm hands every station of kind
; STATION_RACK here):
;   * an empty rack, holding a hide one of its `hang` lines takes (a salted
;     hide): the rack shows it hanging (its wet block) and starts drying;
;   * a rack showing a dry hide: the result (leather) goes to the player
;     (or drops at the rack if there is no room) and the rack is empty again;
;   * a rack still drying: nothing.
; Drying takes the rack's `seconds`; a rack whose column is not loaded when
; its time is up dries as soon as it can. A rack broken while drying is
; forgotten (it drops the hide and itself: mining.cfg).
; What is drying is saved in <world>\racks.dat: `rack = x, y, z, ticks
; left, hang line` (the hang line by its input item's name).
;
; Public API:
;   racks_reset()                       a new world: nothing drying
;   racks_load()                        after save_open (racks.dat)
;   racks_use(ecx = x, edx = y, r8d = z, r9d = station + 1)
;   racks_tick()                        once per simulation tick
;   racks_save()                        with the world (save_all)
;   g_rack_count                        racks drying (overlay)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "cfg.inc"
%include "items.inc"
%include "packet.inc"

global racks_reset, racks_load, racks_use, racks_tick, racks_save, g_rack_count

extern phys_block, edit_apply, inv_used_selected, inv_add, drops_spawn
extern g_inv, g_inv_sel, g_pl_pos, g_pl_reach, g_save_enabled
extern g_hang_count, g_hang_station, g_hang_input, g_hang_wet, g_hang_result
extern g_hang_dry, g_station_ticks, g_station_unlit, g_item_names
extern save_text_load, save_text_release, save_text_write, item_find
extern str_copy, str_append_sdec, str_append_dec, str_parse_u64, str_ieq

%define MAX_RACKS       256
%define DEFAULT_TICKS   2400            ; (a rack without `seconds`: 2 minutes)

struc RACK
    .x      resd 1
    .y      resd 1
    .z      resd 1
    .left   resd 1                      ; ticks of drying left
    .hang   resd 1                      ; its hang line
endstruc

section .rdata
str_file:       db "racks.dat", 0
str_label:      db "racks.dat", 0
k_rack:         db "rack", 0
t_head:         db "# Hides drying on racks (written by the game): x, y, z, ticks left, hide", 13, 10, 0
t_rack:         db "rack = ", 0
t_comma:        db ", ", 0
t_nl:           db 13, 10, 0
align 8
c_half:         dq 0.5
c_reach_extra:  dq 2.0

section .bss
alignb 8
g_racks:        resb MAX_RACKS * RACK_size
g_rack_count:   resd 1
g_rtick:        resd 1
g_vals:         resd 5
alignb 8
g_drop_at:      resq 3

section .text

; racks_reset — nothing drying
PROC racks_reset, 0
    mov dword [rel g_rack_count], 0
    mov dword [rel g_rtick], 0
    RETURN
ENDPROC

; add — a rack starts drying: (ecx, edx, r8d), r9d = hang line, ticks [ARG]
;   in:  eax = ticks   clobbers: rax, r10, r11
add:
    mov r10d, [rel g_rack_count]
    cmp r10d, MAX_RACKS
    jae .full
    imul r10d, r10d, RACK_size
    lea r11, [rel g_racks]
    add r11, r10
    mov [r11 + RACK.x], ecx
    mov [r11 + RACK.y], edx
    mov [r11 + RACK.z], r8d
    mov [r11 + RACK.left], eax
    mov [r11 + RACK.hang], r9d
    inc dword [rel g_rack_count]
.full:
    ret

; held_item — eax = the item in the player's main hand   clobbers: rax, rcx
held_item:
    mov eax, [rel g_inv_sel]
    lea rcx, [rel g_inv]
    movzx eax, word [rcx + rax * 8]
    ret

; -----------------------------------------------------------------------------
; racks_use — see the header.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define U_X     0
%define U_Y     4
%define U_Z     8
%define U_ST    12                      ; station (0-based)
%define U_BLOCK 16
PROC racks_use, 32, rbx, rsi
    mov [LOCAL(U_X)], ecx
    mov [LOCAL(U_Y)], edx
    mov [LOCAL(U_Z)], r8d
    dec r9d
    mov [LOCAL(U_ST)], r9d
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
    call phys_block
    mov [LOCAL(U_BLOCK)], eax
    ; ---- an empty rack: hang what the player holds ----
    mov ecx, [LOCAL(U_ST)]
    lea rdx, [rel g_station_unlit]
    movzx edx, word [rdx + rcx * 2]
    cmp eax, edx
    jne .not_empty
    call held_item
    mov esi, eax
    xor ebx, ebx
.find_hang:
    cmp ebx, [rel g_hang_count]
    jae .done
    lea rcx, [rel g_hang_station]
    movzx ecx, byte [rcx + rbx]
    cmp ecx, [LOCAL(U_ST)]
    jne .next_hang
    lea rcx, [rel g_hang_input]
    cmp si, [rcx + rbx * 2]
    je .hang
.next_hang:
    inc ebx
    jmp .find_hang
.hang:
    mov ecx, [LOCAL(U_X)]
    mov edx, [LOCAL(U_Y)]
    mov r8d, [LOCAL(U_Z)]
    lea rax, [rel g_hang_wet]
    movzx r9d, word [rax + rbx * 2]
    call edit_apply
    cmp eax, 1
    jne .done
    call inv_used_selected
    mov ecx, [LOCAL(U_ST)]
    lea rax, [rel g_station_ticks]
    mov eax, [rax + rcx * 4]
    test eax, eax
    jnz .ticks
    mov eax, DEFAULT_TICKS
.ticks:
    mov ecx, [LOCAL(U_X)]
    mov edx, [LOCAL(U_Y)]
    mov r8d, [LOCAL(U_Z)]
    mov r9d, ebx
    call add
    RETURN
.not_empty:
    ; ---- a dry hide: take it ----
    xor ebx, ebx
.find_dry:
    cmp ebx, [rel g_hang_count]
    jae .done
    lea rcx, [rel g_hang_dry]
    mov eax, [LOCAL(U_BLOCK)]
    cmp ax, [rcx + rbx * 2]
    je .take
    inc ebx
    jmp .find_dry
.take:
    mov ecx, [LOCAL(U_X)]
    mov edx, [LOCAL(U_Y)]
    mov r8d, [LOCAL(U_Z)]
    mov eax, [LOCAL(U_ST)]
    lea r9, [rel g_station_unlit]
    movzx r9d, word [r9 + rax * 2]
    call edit_apply
    cmp eax, 1
    jne .done
    lea rax, [rel g_hang_result]
    movzx ecx, word [rax + rbx * 2]
    mov esi, ecx
    mov edx, 1
    call inv_add
    test eax, eax
    jz .done
    ; no room: it drops on the rack
    cvtsi2sd xmm0, dword [LOCAL(U_X)]
    addsd xmm0, [rel c_half]
    movsd [rel g_drop_at], xmm0
    cvtsi2sd xmm0, dword [LOCAL(U_Y)]
    addsd xmm0, [rel c_half]
    addsd xmm0, [rel c_half]
    addsd xmm0, [rel c_half]
    movsd [rel g_drop_at + 8], xmm0
    cvtsi2sd xmm0, dword [LOCAL(U_Z)]
    addsd xmm0, [rel c_half]
    movsd [rel g_drop_at + 16], xmm0
    mov ecx, esi
    mov edx, 1
    lea r8, [rel g_drop_at]
    call drops_spawn
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; racks_tick — once a second: time passes on every drying rack.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC racks_tick, 0, rbx, rsi
    inc dword [rel g_rtick]
    cmp dword [rel g_rtick], 20
    jb .done
    mov dword [rel g_rtick], 0
    xor esi, esi
.rack:
    cmp esi, [rel g_rack_count]
    jae .done
    imul eax, esi, RACK_size
    lea rbx, [rel g_racks]
    add rbx, rax
    sub dword [rbx + RACK.left], 20
    jg .next
    mov dword [rbx + RACK.left], 0
    ; dry: still the wet rack there?
    mov ecx, [rbx + RACK.x]
    mov edx, [rbx + RACK.y]
    mov r8d, [rbx + RACK.z]
    call phys_block
    cmp eax, -1
    je .next                            ; (not loaded: when it is)
    mov ecx, [rbx + RACK.hang]
    lea rdx, [rel g_hang_wet]
    cmp ax, [rdx + rcx * 2]
    jne .forget                         ; (broken or changed)
    lea rdx, [rel g_hang_dry]
    movzx r9d, word [rdx + rcx * 2]
    mov ecx, [rbx + RACK.x]
    mov edx, [rbx + RACK.y]
    mov r8d, [rbx + RACK.z]
    call edit_apply
    cmp eax, 0
    je .next                            ; (busy: next second)
.forget:
    ; the last one takes its place
    dec dword [rel g_rack_count]
    mov eax, [rel g_rack_count]
    imul eax, eax, RACK_size
    lea rcx, [rel g_racks]
    add rcx, rax
    mov rax, [rcx]
    mov [rbx], rax
    mov rax, [rcx + 8]
    mov [rbx + 8], rax
    mov eax, [rcx + 16]
    mov [rbx + 16], eax
    jmp .rack
.next:
    inc esi
    jmp .rack
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; racks_save — racks.dat: what is drying (written even when nothing is)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC racks_save, 16, rbx, rsi, rdi
    cmp dword [rel g_save_enabled], 0
    je .done
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    mov eax, [rel g_rack_count]
    imul eax, eax, 128
    add eax, 256
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, rax, 16
    test rax, rax
    jz .release
    mov rdi, rax
    mov rcx, rax
    lea rdx, [rel t_head]
    call str_copy
    xor esi, esi
.rack:
    cmp esi, [rel g_rack_count]
    jae .write
    imul ebx, esi, RACK_size
    lea rcx, [rel g_racks]
    add rbx, rcx
    mov rcx, rax
    lea rdx, [rel t_rack]
    call str_copy
    movsxd rdx, dword [rbx + RACK.x]
    INVOKE str_append_sdec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    movsxd rdx, dword [rbx + RACK.y]
    INVOKE str_append_sdec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    movsxd rdx, dword [rbx + RACK.z]
    INVOKE str_append_sdec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    mov edx, [rbx + RACK.left]
    INVOKE str_append_dec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel t_comma]
    call str_copy
    ; the hang line by its input item's name
    mov ecx, [rbx + RACK.hang]
    lea rdx, [rel g_hang_input]
    movzx ecx, word [rdx + rcx * 2]
    lea rdx, [rel g_item_names]
    mov rdx, [rdx + rcx * 8]
    mov rcx, rax
    call str_copy
    mov rcx, rax
    lea rdx, [rel t_nl]
    call str_copy
    inc esi
    jmp .rack
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
; racks_load — racks.dat (a world without one: nothing drying)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC racks_load, 0
    call racks_reset
    cmp dword [rel g_save_enabled], 0
    je .done
    lea rdx, [rel str_file]
    call save_text_load
    test rax, rax
    jz .release
    lea rdx, [rel rack_pair]
    lea r9, [rel str_label]
    INVOKE cfg_parse, rax, rdx, 0, r9
.release:
    call save_text_release
    mov ecx, [rel g_rack_count]
    test ecx, ecx
    jz .done
    LOG_INFO "racks: hides drying on racks were loaded"
.done:
    RETURN
ENDPROC

; rack_pair — racks.dat callback: rcx = name, rdx = value
PROC rack_pair, 16, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    lea rdx, [rel k_rack]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .done
    ; x, y, z, ticks: signed numbers
    xor edi, edi
.num:
    cmp edi, 4
    jae .hang
    mov rcx, rsi
    call cfg_next_token
    test rdx, rdx
    jz .done
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
.hang:
    mov rcx, rsi
    call cfg_next_token
    mov rcx, rax
    call item_find
    test eax, eax
    jle .done
    xor ecx, ecx
.line:
    cmp ecx, [rel g_hang_count]
    jae .done
    lea rdx, [rel g_hang_input]
    cmp ax, [rdx + rcx * 2]
    je .found
    inc ecx
    jmp .line
.found:
    mov r9d, ecx
    mov ecx, [rel g_vals]
    mov edx, [rel g_vals + 4]
    mov r8d, [rel g_vals + 8]
    mov eax, [rel g_vals + 12]
    call add
.done:
    RETURN
ENDPROC
