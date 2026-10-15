; =============================================================================
; drops.asm — dropped items lying in the world (milestone 18,
; design/items/items_inventory.md): a mined block pops out as an item that
; falls, slides to a stop, joins nearby items of its kind, drifts to the
; player once close and goes into the inventory; after 5 minutes it is gone.
;
; Each drop is simulated as a point with a small radius against the
; blocks' collision (any colliding block counts as a full cube: drops are
; small and short-lived). Moving drops are sent to the client every tick
; (PKT_S_DROP); resting ones are not. Drops are not saved with the world.
;
; Public API:
;   drops_reset()                       a new world: none
;   drops_spawn(ecx = item, edx = count, r8 = f64[3] centre) -> eax id / -1
;   drops_spawn_dur(... r9d = wear)     a worn tool
;   drops_tick()                        once per simulation tick
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "packet.inc"
%include "physics.inc"

global drops_reset, drops_spawn, drops_spawn_dur, drops_tick, g_drop_count

extern phys_block, inv_add_dur, pkt_send, g_to_client, g_block_coll
extern g_pl_pos, g_item_stack, g_sv_dead

%define LIFE_TICKS      6000            ; 5 minutes at 20 ticks per second
%define PICKUP_TICKS    10              ; just dropped: not yet
%define MERGE_EVERY     10
%define F_ACTIVE        1
%define F_RESTING       2
%define F_DIRTY         4               ; send it this tick

struc DROP
    .pos    resq 3                      ; f64 centre
    .vel    resd 3                      ; f32 blocks per tick
    .item   resw 1
    .count  resw 1
    .age    resd 1                      ; ticks
    .flags  resd 1
    .wear   resw 1                      ; a worn tool keeps its wear
    .pad    resb 6
endstruc

section .rdata
align 8
c_gravity:      dq 0.04                 ; blocks per tick^2 (16 b/s^2)
c_air:          dq 0.98
c_ground:       dq 0.55
c_rest:         dq 0.0004               ; squared speed: at rest
c_radius:       dq 0.125
c_half:         dq 0.5
c_body_mid:     dq 0.9                  ; player centre above the feet
c_pickup2:      dq 2.25                 ; (1.5 blocks)^2
c_magnet2:      dq 9.0                  ; (3 blocks)^2
c_magnet:       dq 0.06                 ; pull per tick
c_merge2:       dq 1.0
c_spread:       dq 0.00000000023283064365386963 ; 2^-32: random u32 -> 0..1
c_pop:          dq 0.12
c_max_fall:     dq -1.5
c_below:        dq 0.2

section .bss
alignb 16
g_drops:        resb MAX_DROPS * DROP_size
g_drop_count:   resd 1                  ; active (overlay)
g_rand:         resd 1
g_tick:         resd 1
g_out:          resb DROP_PKT_size

section .text

; rand — eax = a random u32 (xorshift)   clobbers: rax, rcx
rand:
    mov eax, [rel g_rand]
    test eax, eax
    jnz .go
    mov eax, 0x9E3779B9
.go:
    mov ecx, eax
    shl ecx, 13
    xor eax, ecx
    mov ecx, eax
    shr ecx, 17
    xor eax, ecx
    mov ecx, eax
    shl ecx, 5
    xor eax, ecx
    mov [rel g_rand], eax
    ret

; rand_signed — xmm0 = -0.5 .. 0.5   clobbers: rax, rcx, xmm0, xmm1
rand_signed:
    call rand
    cvtsi2sd xmm0, rax
    mulsd xmm0, [rel c_spread]
    subsd xmm0, [rel c_half]
    ret

; drops_reset — no drops (a new world)
PROC drops_reset, 0, rdi
    lea rdi, [rel g_drops]
    xor eax, eax
    mov ecx, MAX_DROPS * DROP_size / 8
    rep stosq
    mov dword [rel g_drop_count], 0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; drops_spawn — an item pops out (a mined block's centre).
;   in:  ecx = item, edx = count, r8 = f64[3] where
;   out: eax = id (slot), -1 if the table is full
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
drops_spawn:
    xor r9d, r9d
PROC drops_spawn_dur, 0, rbx, rsi, rdi, r12, r13
    mov esi, ecx
    mov edi, edx
    mov r13d, r9d
    lea rbx, [rel g_drops]
    xor eax, eax
.find:
    cmp eax, MAX_DROPS
    jae .full
    test dword [rbx + DROP.flags], F_ACTIVE
    jz .found
    add rbx, DROP_size
    inc eax
    jmp .find
.found:
    mov r12d, eax                       ; the id
    mov rax, [r8]
    mov [rbx + DROP.pos], rax
    mov rax, [r8 + 8]
    mov [rbx + DROP.pos + 8], rax
    mov rax, [r8 + 16]
    mov [rbx + DROP.pos + 16], rax
    mov [rbx + DROP.item], si
    mov [rbx + DROP.count], di
    mov [rbx + DROP.wear], r13w
    mov dword [rbx + DROP.age], 0
    mov dword [rbx + DROP.flags], F_ACTIVE | F_DIRTY
    ; a little hop in a random direction
    call rand_signed
    mulsd xmm0, [rel c_pop]
    cvtsd2ss xmm0, xmm0
    movss [rbx + DROP.vel], xmm0
    call rand_signed
    mulsd xmm0, [rel c_pop]
    cvtsd2ss xmm0, xmm0
    movss [rbx + DROP.vel + 8], xmm0
    mov eax, 0x3E19999A                 ; 0.15 up
    mov [rbx + DROP.vel + 4], eax
    inc dword [rel g_drop_count]
    mov eax, r12d
    RETURN
.full:
    mov eax, -1
    RETURN
ENDPROC

; solid_at — eax = 1 if the block at the f64 point (xmm0, xmm1, xmm2) collides
;   clobbers: volatile registers
PROC solid_at, 0
    roundsd xmm0, xmm0, 9
    cvttsd2si ecx, xmm0
    roundsd xmm1, xmm1, 9
    cvttsd2si edx, xmm1
    roundsd xmm2, xmm2, 9
    cvttsd2si r8d, xmm2
    call phys_block
    cmp eax, -1
    je .solid                           ; (not generated: solid)
    lea rcx, [rel g_block_coll]
    movzx eax, byte [rcx + rax]
    test eax, eax
    setnz al
    RETURN
.solid:
    mov eax, 1
    RETURN
ENDPROC

; send — tell the client about drop rbx (id esi)
PROC send, 0
    mov rax, [rbx + DROP.pos]
    mov [rel g_out + DROP_PKT.pos], rax
    mov rax, [rbx + DROP.pos + 8]
    mov [rel g_out + DROP_PKT.pos + 8], rax
    mov rax, [rbx + DROP.pos + 16]
    mov [rel g_out + DROP_PKT.pos + 16], rax
    mov [rel g_out + DROP_PKT.id], esi
    mov ax, [rbx + DROP.item]
    mov [rel g_out + DROP_PKT.item], ax
    mov ax, [rbx + DROP.count]
    mov [rel g_out + DROP_PKT.count], ax
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_DROP, r8, DROP_PKT_size
    RETURN
ENDPROC

; gone — drop rbx (id esi) is removed; the client forgets it
PROC gone, 0
    mov dword [rbx + DROP.flags], 0
    dec dword [rel g_drop_count]
    mov [rel g_out + DROP_PKT.id], esi
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_DROP_GONE, r8, DROP_PKT_size
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; move_axis — move drop rbx along one axis by its velocity; a collision
; stops it on that axis.
;   in:  edx = axis 0..2
;   out: eax = 1 if it hit something
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define M_AXIS  0
PROC move_axis, 16
    mov [LOCAL(M_AXIS)], edx
    cvtss2sd xmm3, [rbx + DROP.vel + rdx * 4]
    xorps xmm4, xmm4
    comisd xmm3, xmm4
    je .none
    ; the leading edge after the move
    movsd xmm0, [rbx + DROP.pos]
    movsd xmm1, [rbx + DROP.pos + 8]
    movsd xmm2, [rbx + DROP.pos + 16]
    movsd xmm5, [rel c_radius]
    jae .positive
    xorpd xmm5, [rel c_sign]
.positive:
    addsd xmm5, xmm3                    ; move + edge offset
    cmp edx, 1
    jb .x
    je .y
    addsd xmm2, xmm5
    jmp .test
.x:
    addsd xmm0, xmm5
    jmp .test
.y:
    addsd xmm1, xmm5
.test:
    call solid_at
    mov edx, [LOCAL(M_AXIS)]
    test eax, eax
    jnz .hit
    cvtss2sd xmm3, [rbx + DROP.vel + rdx * 4]
    movsd xmm0, [rbx + DROP.pos + rdx * 8]
    addsd xmm0, xmm3
    movsd [rbx + DROP.pos + rdx * 8], xmm0
.none:
    xor eax, eax
    RETURN
.hit:
    mov dword [rbx + DROP.vel + rdx * 4], 0
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; drops_tick — physics, pickup, merging, age; sends what moved.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define T_GROUND    0
PROC drops_tick, 16, rbx, rsi, rdi, r12
    inc dword [rel g_tick]
    cmp dword [rel g_drop_count], 0
    je .done
    lea rbx, [rel g_drops]
    xor esi, esi
.drop:
    cmp esi, MAX_DROPS
    jae .done
    test dword [rbx + DROP.flags], F_ACTIVE
    jz .next
    inc dword [rbx + DROP.age]
    cmp dword [rbx + DROP.age], LIFE_TICKS
    jb .alive
    call gone
    jmp .next
.alive:
    ; ---- towards the player, and into the inventory ----
    movsd xmm0, [rbx + DROP.pos]
    subsd xmm0, [rel g_pl_pos]          ; dx
    movsd xmm1, [rbx + DROP.pos + 8]
    subsd xmm1, [rel g_pl_pos + 8]
    subsd xmm1, [rel c_body_mid]        ; dy (to the body's middle)
    movsd xmm2, [rbx + DROP.pos + 16]
    subsd xmm2, [rel g_pl_pos + 16]     ; dz
    movsd xmm3, xmm0
    mulsd xmm3, xmm0
    movsd xmm4, xmm1
    mulsd xmm4, xmm1
    addsd xmm3, xmm4
    movsd xmm4, xmm2
    mulsd xmm4, xmm2
    addsd xmm3, xmm4                    ; distance^2
    cmp dword [rbx + DROP.age], PICKUP_TICKS
    jb .physics
    cmp dword [rel g_sv_dead], 0
    jne .physics                        ; (a dead player picks nothing up; M20)
    comisd xmm3, [rel c_pickup2]
    jae .magnet
    ; picked up: what fits goes into the inventory
    movzx ecx, word [rbx + DROP.item]
    movzx edx, word [rbx + DROP.count]
    movzx r8d, word [rbx + DROP.wear]
    call inv_add_dur
    test eax, eax
    jnz .partly
    call gone
    jmp .next
.partly:
    cmp ax, [rbx + DROP.count]
    je .physics                         ; (nothing fitted)
    mov [rbx + DROP.count], ax
    or dword [rbx + DROP.flags], F_DIRTY
    jmp .physics
.magnet:
    comisd xmm3, [rel c_magnet2]
    jae .physics
    ; drift towards the player: velocity += -d / |d| * pull
    sqrtsd xmm3, xmm3
    movsd xmm4, [rel c_magnet]
    divsd xmm4, xmm3
    mulsd xmm0, xmm4
    mulsd xmm1, xmm4
    mulsd xmm2, xmm4
    cvtss2sd xmm5, [rbx + DROP.vel]
    subsd xmm5, xmm0
    cvtsd2ss xmm5, xmm5
    movss [rbx + DROP.vel], xmm5
    cvtss2sd xmm5, [rbx + DROP.vel + 4]
    subsd xmm5, xmm1
    cvtsd2ss xmm5, xmm5
    movss [rbx + DROP.vel + 4], xmm5
    cvtss2sd xmm5, [rbx + DROP.vel + 8]
    subsd xmm5, xmm2
    cvtsd2ss xmm5, xmm5
    movss [rbx + DROP.vel + 8], xmm5
    and dword [rbx + DROP.flags], ~F_RESTING
.physics:
    test dword [rbx + DROP.flags], F_RESTING
    jnz .merge
    ; gravity (with a top speed) and air drag
    cvtss2sd xmm0, [rbx + DROP.vel + 4]
    subsd xmm0, [rel c_gravity]
    maxsd xmm0, [rel c_max_fall]
    cvtsd2ss xmm0, xmm0
    movss [rbx + DROP.vel + 4], xmm0
    mov dword [LOCAL(T_GROUND)], 0
    mov edx, 1
    call move_axis
    test eax, eax
    jz .xz
    mov dword [LOCAL(T_GROUND)], 1
.xz:
    xor edx, edx
    call move_axis
    mov edx, 2
    call move_axis
    ; friction: on the ground much more
    movsd xmm1, [rel c_air]
    cmp dword [LOCAL(T_GROUND)], 0
    je .drag
    movsd xmm1, [rel c_ground]
.drag:
    cvtss2sd xmm0, [rbx + DROP.vel]
    mulsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movss [rbx + DROP.vel], xmm0
    cvtss2sd xmm0, [rbx + DROP.vel + 8]
    mulsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movss [rbx + DROP.vel + 8], xmm0
    or dword [rbx + DROP.flags], F_DIRTY
    ; at rest on the ground?
    cmp dword [LOCAL(T_GROUND)], 0
    je .merge
    movss xmm0, [rbx + DROP.vel]
    mulss xmm0, xmm0
    movss xmm1, [rbx + DROP.vel + 8]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    cvtss2sd xmm0, xmm0
    comisd xmm0, [rel c_rest]
    jae .merge
    or dword [rbx + DROP.flags], F_RESTING
    mov qword [rbx + DROP.vel], 0
    mov dword [rbx + DROP.vel + 8], 0
.merge:
    ; now and then, join a resting drop of the same item nearby
    mov eax, [rel g_tick]
    add eax, esi
    xor edx, edx
    mov ecx, MERGE_EVERY
    div ecx
    test edx, edx
    jnz .send
    test dword [rbx + DROP.flags], F_RESTING
    jz .send
    ; the ground under it may be gone
    movsd xmm0, [rbx + DROP.pos]
    movsd xmm1, [rbx + DROP.pos + 8]
    subsd xmm1, [rel c_below]
    movsd xmm2, [rbx + DROP.pos + 16]
    call solid_at
    test eax, eax
    jnz .grounded
    and dword [rbx + DROP.flags], ~F_RESTING
    jmp .send
.grounded:
    call merge
    test dword [rbx + DROP.flags], F_ACTIVE
    jz .next                            ; (merged into another one)
.send:
    test dword [rbx + DROP.flags], F_DIRTY
    jz .next
    and dword [rbx + DROP.flags], ~F_DIRTY
    call send
.next:
    add rbx, DROP_size
    inc esi
    jmp .drop
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; merge — drop rbx (id esi) gives what it can to another resting drop of
; the same item within a block; gone if it gave everything.
;   clobbers: volatile registers (keeps rbx, rsi)
; -----------------------------------------------------------------------------
PROC merge, 0, rdi, r12, r13
    lea rdi, [rel g_drops]
    xor r12d, r12d
.other:
    cmp r12d, MAX_DROPS
    jae .done
    cmp r12d, esi
    je .next
    mov eax, [rdi + DROP.flags]
    and eax, F_ACTIVE | F_RESTING
    cmp eax, F_ACTIVE | F_RESTING
    jne .next
    mov ax, [rdi + DROP.item]
    cmp ax, [rbx + DROP.item]
    jne .next
    mov ax, [rdi + DROP.wear]
    cmp ax, [rbx + DROP.wear]
    jne .next
    movsd xmm0, [rdi + DROP.pos]
    subsd xmm0, [rbx + DROP.pos]
    mulsd xmm0, xmm0
    movsd xmm1, [rdi + DROP.pos + 8]
    subsd xmm1, [rbx + DROP.pos + 8]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    movsd xmm1, [rdi + DROP.pos + 16]
    subsd xmm1, [rbx + DROP.pos + 16]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    comisd xmm0, [rel c_merge2]
    jae .next
    ; room in the other one
    movzx ecx, word [rbx + DROP.item]
    lea rax, [rel g_item_stack]
    movzx eax, byte [rax + rcx]
    movzx ecx, word [rdi + DROP.count]
    sub eax, ecx
    jle .next
    movzx ecx, word [rbx + DROP.count]
    cmp eax, ecx
    cmova eax, ecx
    add [rdi + DROP.count], ax
    sub [rbx + DROP.count], ax
    or dword [rdi + DROP.flags], F_DIRTY
    mov dword [rdi + DROP.age], 0       ; (the joined stack starts its 5 minutes again)
    or dword [rbx + DROP.flags], F_DIRTY
    cmp word [rbx + DROP.count], 0
    jne .next
    call gone
    jmp .done
.next:
    add rdi, DROP_size
    inc r12d
    jmp .other
.done:
    RETURN
ENDPROC

section .rdata
align 16
c_sign:         dq 0x8000000000000000, 0
