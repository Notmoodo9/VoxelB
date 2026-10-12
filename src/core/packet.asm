; =============================================================================
; packet.asm — the packet queues between the client and the simulation
; (packet.inc, DECISIONS D85).
;
; Lock-free single-producer single-consumer rings: the producer owns .head,
; the consumer owns .tail; each publishes its counter after the slot is
; written / read (x86 stores are not reordered with older stores, and loads
; not with older loads, so plain moves are enough).
;
; Public API:
;   pkt_send(queue, type, payload, size) -> eax 1, or 0 if the queue is full
;       (the packet is dropped and counted in g_pkt_dropped)
;   pkt_recv(queue, out PKT*) -> eax packet type, or 0 if empty
;   g_to_sim, g_to_client           the two queues
;   g_pkt_sent_sim, g_pkt_sent_client, g_pkt_dropped   counters (overlay)
; =============================================================================
%define PACKET_IMPL
%include "macros.inc"
%include "packet.inc"

global pkt_send, pkt_recv, g_to_sim, g_to_client
global g_pkt_sent_sim, g_pkt_sent_client, g_pkt_dropped

section .bss
alignb 64
g_to_sim:           resb PKTQ_size
alignb 64
g_to_client:        resb PKTQ_size
g_pkt_sent_sim:     resq 1
g_pkt_sent_client:  resq 1
g_pkt_dropped:      resq 1

section .text

; -----------------------------------------------------------------------------
; pkt_send — append a packet.
;   in:  rcx = queue, edx = type, r8 = payload (may be 0 when r9d = 0),
;        r9d = payload size (<= PKT_PAYLOAD_MAX)
;   out: eax = 1 sent, 0 queue full (dropped)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC pkt_send, 0, rsi, rdi
    mov rax, [rcx + PKTQ.head]
    mov r10, [rcx + PKTQ.tail]
    mov r11, rax
    sub r11, r10
    cmp r11, PKT_QUEUE_SLOTS
    jae .full
    mov r11, rax
    and r11, PKT_QUEUE_SLOTS - 1
    shl r11, 6                          ; * PKT_SIZE
    lea rdi, [rcx + PKTQ.slots + r11]
    mov [rdi + PKT.type], dx
    mov [rdi + PKT.size], r9w
    mov rsi, r8
    lea rdi, [rdi + PKT.data]
    mov r10, rcx
    mov ecx, r9d
    rep movsb
    inc rax
    mov [r10 + PKTQ.head], rax          ; publish
    lea rdx, [rel g_to_sim]
    lea rcx, [rel g_pkt_sent_sim]
    cmp r10, rdx
    je .count
    lea rcx, [rel g_pkt_sent_client]
.count:
    inc qword [rcx]
    mov eax, 1
    RETURN
.full:
    inc qword [rel g_pkt_dropped]
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; pkt_recv — take the oldest packet.
;   in:  rcx = queue, rdx = out (PKT_SIZE bytes)
;   out: eax = packet type, 0 if the queue is empty
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC pkt_recv, 0, rsi, rdi
    mov rax, [rcx + PKTQ.tail]
    cmp rax, [rcx + PKTQ.head]
    je .empty
    mov r11, rax
    and r11, PKT_QUEUE_SLOTS - 1
    shl r11, 6
    lea rsi, [rcx + PKTQ.slots + r11]
    mov rdi, rdx
    mov r10, rcx
    mov ecx, PKT_SIZE / 8
    rep movsq
    inc rax
    mov [r10 + PKTQ.tail], rax          ; the slot is free again
    movzx eax, word [rdx + PKT.type]
    RETURN
.empty:
    xor eax, eax
    RETURN
ENDPROC
