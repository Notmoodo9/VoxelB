; =============================================================================
; dig.asm — mining a block in Survival (milestone 18): while the client holds
; break on a block (INPUT_PKT INB_DIG + .dig), the block's mining time
; (mining.asm: hardness, the tool in hand) runs down; at the end it breaks
; (edit_request) and, if it can be harvested, drops its item. Looking away
; or letting go starts over. Progress goes to the client for the cracks.
; Creative breaks at once (PKT_C_BREAK) and drops nothing.
;
; Public API:
;   dig_reset()
;   dig_tick(rcx = INPUT_PKT*)           once per simulation tick
; =============================================================================
%include "macros.inc"
%include "packet.inc"
%include "save.inc"
%include "items.inc"

global dig_reset, dig_tick

extern phys_block, mining_time, mining_drop, edit_request, drops_spawn
extern pkt_send, g_to_client, g_world_mode, g_inv, g_inv_sel

%define TICK_S          0.05
%define COOLDOWN_TICKS  5               ; between two blocks when held

section .rdata
align 8
c_tick:         dd TICK_S
c_one:          dd 1.0
c_none:         dd -1.0
align 8
c_half:         dq 0.5

section .bss
alignb 8
g_active:       resd 1
g_pos:          resd 3
g_progress:     resd 1                  ; f32 0..1
g_cool:         resd 1
g_req:          resb BLOCK_PKT_size
g_out:          resb DIG_PKT_size
g_at:           resq 3

section .text

; dig_reset — nothing being mined
dig_reset:
    mov dword [rel g_active], 0
    mov dword [rel g_progress], 0
    mov dword [rel g_cool], 0
    ret

; send — the progress (or -1: stopped) to the client
PROC send, 0
    mov eax, [rel g_pos]
    mov [rel g_out + DIG_PKT.pos], eax
    mov eax, [rel g_pos + 4]
    mov [rel g_out + DIG_PKT.pos + 4], eax
    mov eax, [rel g_pos + 8]
    mov [rel g_out + DIG_PKT.pos + 8], eax
    mov eax, [rel g_progress]
    cmp dword [rel g_active], 0
    jne .p
    mov eax, [rel c_none]
.p:
    mov [rel g_out + DIG_PKT.progress], eax
    lea rcx, [rel g_to_client]
    lea r8, [rel g_out]
    INVOKE pkt_send, rcx, PKT_S_DIG, r8, DIG_PKT_size
    RETURN
ENDPROC

; stop — stop mining (the client hears of it once)
PROC stop, 0
    cmp dword [rel g_active], 0
    je .done
    mov dword [rel g_active], 0
    mov dword [rel g_progress], 0
    call send
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; dig_tick — see the header.
;   in:  rcx = the latest INPUT_PKT
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define D_BLOCK     0
%define D_HARVEST   4
PROC dig_tick, 16, rbx, rsi
    mov rbx, rcx
    cmp dword [rel g_cool], 0
    je .cooled
    dec dword [rel g_cool]
.cooled:
    cmp dword [rel g_world_mode], MODE_CREATIVE
    je .stop
    test dword [rbx + INPUT_PKT.buttons], INB_DIG
    jz .stop
    ; a new block: start over
    mov eax, [rbx + INPUT_PKT.dig]
    mov ecx, [rbx + INPUT_PKT.dig + 4]
    mov edx, [rbx + INPUT_PKT.dig + 8]
    cmp dword [rel g_active], 0
    je .new
    cmp eax, [rel g_pos]
    jne .new
    cmp ecx, [rel g_pos + 4]
    jne .new
    cmp edx, [rel g_pos + 8]
    je .same
.new:
    mov [rel g_pos], eax
    mov [rel g_pos + 4], ecx
    mov [rel g_pos + 8], edx
    mov dword [rel g_progress], 0
    mov dword [rel g_active], 1
.same:
    cmp dword [rel g_cool], 0
    jne .done
    mov ecx, [rel g_pos]
    mov edx, [rel g_pos + 4]
    mov r8d, [rel g_pos + 8]
    call phys_block
    cmp eax, 0
    jle .stop                           ; air, or not generated
    mov [LOCAL(D_BLOCK)], eax
    ; the time it takes with the item in hand
    mov ecx, [rel g_inv_sel]
    lea rdx, [rel g_inv]
    movzx edx, word [rdx + rcx * 8]
    mov ecx, eax
    call mining_time
    mov [LOCAL(D_HARVEST)], eax
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jb .stop                            ; never breaks
    movss xmm2, [rel c_one]
    je .add                             ; at once
    movss xmm2, [rel c_tick]
    divss xmm2, xmm0
.add:
    addss xmm2, [rel g_progress]
    movss [rel g_progress], xmm2
    comiss xmm2, [rel c_one]
    jae .broken
    call send
    jmp .done
.broken:
    ; break it (the usual checks: reach, liquids ...)
    mov eax, [rel g_pos]
    mov [rel g_req + BLOCK_PKT.x], eax
    mov eax, [rel g_pos + 4]
    mov [rel g_req + BLOCK_PKT.y], eax
    mov eax, [rel g_pos + 8]
    mov [rel g_req + BLOCK_PKT.z], eax
    mov dword [rel g_req + BLOCK_PKT.id], 0
    lea rcx, [rel g_req]
    xor edx, edx
    call edit_request
    mov esi, eax
    mov dword [rel g_cool], COOLDOWN_TICKS
    call stop
    test esi, esi
    jz .done
    cmp dword [LOCAL(D_HARVEST)], 0
    je .done
    mov ecx, [LOCAL(D_BLOCK)]
    call mining_drop
    test eax, eax
    jz .done
    mov ebx, eax
    mov esi, edx
    ; from the block's centre
    xor ecx, ecx
.centre:
    lea rax, [rel g_pos]
    cvtsi2sd xmm0, dword [rax + rcx * 4]
    addsd xmm0, [rel c_half]
    lea rax, [rel g_at]
    movsd [rax + rcx * 8], xmm0
    inc ecx
    cmp ecx, 3
    jb .centre
    lea r8, [rel g_at]
    mov ecx, ebx
    mov edx, esi
    call drops_spawn
    jmp .done
.stop:
    call stop
.done:
    RETURN
ENDPROC
