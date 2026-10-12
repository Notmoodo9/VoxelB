; =============================================================================
; lz.asm — a small LZ77 byte compressor for save files (milestone 17,
; DECISIONS D88). The format is LZ4-like:
;   sequence = token (high nibble: literal count, low nibble: match length
;   - 4; 15 = more length bytes follow, each adding 0..255 until one is not
;   255), the literals, then (unless the input ends here) a 16-bit little
;   endian offset back into the output and the extra match length bytes.
;   The last sequence has literals only.
; The compressor is greedy with a 4096-entry hash of 4-byte groups; matches
; may overlap their own output (runs compress to a few bytes).
;
; Public API:
;   lz_bound(n) -> rax                  output capacity that always suffices
;   lz_compress(src, n, dst, table) -> rax compressed size
;       table: LZ_TABLE_BYTES of scratch (any contents)
;   lz_decompress(src, n, dst, cap) -> rax output size, -1 if corrupt or
;       larger than cap
; =============================================================================
%include "macros.inc"

global lz_bound, lz_compress, lz_decompress

%define HASH_BITS       12
%define MIN_MATCH       4
%define MAX_OFFSET      65535
%define END_MARGIN      12              ; the last bytes are always literals

section .text

; lz_bound — rax = n + n / 255 + 16
lz_bound:
    mov rax, rcx
    xor edx, edx
    mov r8d, 255
    div r8
    add rax, rcx
    add rax, 16
    ret

; put_length — the extra bytes of a length >= 15 (value - 15).
;   in: rax = remaining (length - 15), rdi = out (advanced)   clobbers: rax
put_length:
.more:
    cmp rax, 255
    jb .last
    mov byte [rdi], 255
    inc rdi
    sub rax, 255
    jmp .more
.last:
    mov [rdi], al
    inc rdi
    ret

; -----------------------------------------------------------------------------
; emit — one sequence: literals [rbx, rsi) then (if r12 != 0) a match of
; r12 bytes at offset r13.
;   in:  rbx = literal start, rsi = literal end, r12 = match length (0: none),
;        r13 = offset, rdi = out (advanced)
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
emit:
    mov rcx, rsi
    sub rcx, rbx                        ; literal count
    ; token
    mov rax, rcx
    cmp rax, 15
    jb .lit_nib
    mov eax, 15
.lit_nib:
    shl eax, 4
    mov rdx, r12
    test rdx, rdx
    jz .tok
    sub rdx, MIN_MATCH
    cmp rdx, 15
    jb .ml_nib
    mov edx, 15
.ml_nib:
    or eax, edx
.tok:
    mov [rdi], al
    inc rdi
    cmp rcx, 15
    jb .copy
    lea rax, [rcx - 15]
    call put_length
.copy:
    mov r8, rsi
    mov rsi, rbx
    rep movsb                           ; (rsi ends at the literal end again)
    mov rsi, r8
    test r12, r12
    jz .done
    mov [rdi], r13w
    add rdi, 2
    mov rax, r12
    sub rax, MIN_MATCH
    cmp rax, 15
    jb .done
    sub rax, 15
    call put_length
.done:
    ret

; -----------------------------------------------------------------------------
; lz_compress — compress a buffer.
;   in:  rcx = src, rdx = n, r8 = dst (lz_bound(n) bytes), r9 = hash table
;        (LZ_TABLE_BYTES = 4 << HASH_BITS)
;   out: rax = compressed size
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC lz_compress, 16, rbx, rsi, rdi, r12, r13, r14, r15
    mov r14, rcx                        ; src
    lea r15, [rcx + rdx]                ; src end
    mov rdi, r8                         ; out
    mov [LOCAL(0)], r8
    ; table: empty (stores position + 1)
    mov r10, r9
    mov rdi, r10
    xor eax, eax
    mov ecx, 1 << HASH_BITS
    rep stosd
    mov rdi, [LOCAL(0)]
    mov rbx, r14                        ; anchor (literal start)
    mov rsi, r14                        ; ip
    lea r11, [r15 - END_MARGIN]         ; last match start
.scan:
    cmp rsi, r11
    jae .tail
    mov eax, [rsi]
    imul eax, eax, 0x9E3779B1
    shr eax, 32 - HASH_BITS
    mov ecx, [r10 + rax * 4]            ; candidate + 1
    mov rdx, rsi
    sub rdx, r14
    inc edx
    mov [r10 + rax * 4], edx
    test ecx, ecx
    jz .skip
    dec ecx
    lea r8, [r14 + rcx]                 ; candidate
    mov r13, rsi
    sub r13, r8                         ; offset
    jz .skip
    cmp r13, MAX_OFFSET
    ja .skip
    mov eax, [r8]
    cmp eax, [rsi]
    jne .skip
    ; extend the match
    mov r12d, MIN_MATCH
.extend:
    lea rax, [rsi + r12]
    cmp rax, r15
    jae .matched
    mov al, [r8 + r12]
    cmp al, [rsi + r12]
    jne .matched
    inc r12
    jmp .extend
.matched:
    call emit                           ; (keeps r10, r11)
    add rsi, r12
    mov rbx, rsi
    jmp .scan
.skip:
    inc rsi
    jmp .scan
.tail:
    mov rsi, r15
    xor r12d, r12d
    call emit                           ; the last literals
    mov rax, rdi
    sub rax, [LOCAL(0)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; lz_decompress — expand a buffer.
;   in:  rcx = src, rdx = n, r8 = dst, r9 = capacity
;   out: rax = bytes written, or -1 (corrupt input or too large)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC lz_decompress, 0, rbx, rsi, rdi, r12
    mov rsi, rcx
    lea r10, [rcx + rdx]                ; src end
    mov rdi, r8
    mov r12, r8                         ; dst start
    lea r11, [r8 + r9]                  ; dst end
.seq:
    cmp rsi, r10
    jae .bad                            ; (a stream always ends after literals)
    movzx ebx, byte [rsi]               ; token
    inc rsi
    mov ecx, ebx
    shr ecx, 4                          ; literal count
    cmp ecx, 15
    jne .lits
.lit_more:
    cmp rsi, r10
    jae .bad
    movzx eax, byte [rsi]
    inc rsi
    add rcx, rax
    cmp eax, 255
    je .lit_more
.lits:
    lea rax, [rsi + rcx]
    cmp rax, r10
    ja .bad
    lea rax, [rdi + rcx]
    cmp rax, r11
    ja .bad
    rep movsb
    cmp rsi, r10
    je .done                            ; the last sequence
    lea rax, [rsi + 2]
    cmp rax, r10
    ja .bad
    movzx edx, word [rsi]               ; offset
    add rsi, 2
    test edx, edx
    jz .bad
    mov ecx, ebx
    and ecx, 15
    cmp ecx, 15
    jne .match
.ml_more:
    cmp rsi, r10
    jae .bad
    movzx eax, byte [rsi]
    inc rsi
    add rcx, rax
    cmp eax, 255
    je .ml_more
.match:
    add rcx, MIN_MATCH
    mov rax, rdi
    sub rax, rdx                        ; match source
    cmp rax, r12
    jb .bad
    lea r8, [rdi + rcx]
    cmp r8, r11
    ja .bad
    mov r8, rsi
    mov rsi, rax
    rep movsb                           ; (byte by byte: overlaps repeat)
    mov rsi, r8
    jmp .seq
.done:
    mov rax, rdi
    sub rax, r12
    RETURN
.bad:
    mov rax, -1
    RETURN
ENDPROC
