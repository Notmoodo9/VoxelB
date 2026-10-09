; =============================================================================
; png.asm — PNG decoder (zlib inflate + scanline unfiltering) to RGBA8.
;
; Supports every non-interlaced PNG a paint program writes: grey (1/2/4/8/16
; bits), RGB (8/16), palette (1/2/4/8, with tRNS alpha), grey+alpha (8/16)
; and RGBA (8/16); tRNS colour keys for 8-bit grey/RGB. 16-bit samples keep
; their high byte. Interlaced (Adam7) images are rejected with a warning.
; Chunk CRCs and the Adler-32 checksum are not verified (local asset files).
;
; Inflate follows RFC 1951 with canonical Huffman decoding (count/symbol
; tables, one bit at a time, as in zlib's "puff"): small and plenty fast
; for 16x16 textures.
;
; Public API:
;   png_decode(data, size, out PNG_INFO*, ARENA*) -> rax RGBA8 pixels or 0
;       pixels are w*h*4 bytes, rows top to bottom, allocated in the arena
;       (the arena also holds temporary buffers: use a scratch arena and
;       copy the pixels out, or reset it afterwards)
;   inflate_raw(src, src_size, dst, dst_cap) -> rax bytes written or -1
;       (raw deflate stream, no zlib header; used by the self test)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"

global png_decode, inflate_raw

; ---- inflate state ---------------------------------------------------------
%define MAXBITS     15
struc HUFF
    .count      resw 16
    .symbol     resw 288
endstruc

struc INFL
    .in_end     resq 1
    .out_base   resq 1
    .err        resd 1
    .pad        resd 1
    .len        resb HUFF_size
    .dist       resb HUFF_size
    .offs       resw 16
    .lengths    resw 320
endstruc

; registers while inflating:
;   r15 = INFL*   rsi = input   r12 = bit buffer   r13d = bit count
;   rdi = output  r14 = output end

section .rdata
align 2
lbase:  dw 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31
        dw 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
lext:   dw 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2
        dw 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
dbase:  dw 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193
        dw 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145
        dw 8193, 12289, 16385, 24577
dext:   dw 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6
        dw 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
clorder: db 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
png_sig: db 0x89, 'P', 'N', 'G', 13, 10, 26, 10

section .text

; -----------------------------------------------------------------------------
; getbits — take n bits (LSB first) from the input.
;   in:  ecx = n (0..16)     out: eax = value
;   On end of input, zeros are supplied and INFL.err is set.
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
getbits:
    mov edx, ecx
.fill:
    cmp r13d, edx
    jae .have
    cmp rsi, [r15 + INFL.in_end]
    jae .eof
    movzx eax, byte [rsi]
    inc rsi
    mov ecx, r13d
    shl rax, cl
    or r12, rax
    add r13d, 8
    jmp .fill
.eof:
    mov dword [r15 + INFL.err], 1
    add r13d, 8                         ; zero bits
    jmp .fill
.have:
    mov ecx, edx
    mov eax, 1
    shl eax, cl
    dec eax
    and eax, r12d
    shr r12, cl
    sub r13d, edx
    ret

; -----------------------------------------------------------------------------
; decode — decode one symbol with a canonical Huffman table.
;   in:  rbx = HUFF*         out: eax = symbol (-1 and INFL.err on error)
;   clobbers: rax, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
decode:
    xor r8d, r8d                        ; code
    xor r9d, r9d                        ; first
    xor r10d, r10d                      ; index
    mov r11d, 1                         ; len
.loop:
    mov ecx, 1
    call getbits
    or r8d, eax
    movzx eax, word [rbx + HUFF.count + r11 * 2]
    mov ecx, r8d
    sub ecx, r9d                        ; code - first
    cmp ecx, eax
    jb .found
    add r10d, eax
    add r9d, eax
    shl r9d, 1
    shl r8d, 1
    inc r11d
    cmp r11d, MAXBITS
    jbe .loop
    mov dword [r15 + INFL.err], 1
    mov eax, -1
    ret
.found:
    add ecx, r10d
    movzx eax, word [rbx + HUFF.symbol + rcx * 2]
    ret

; -----------------------------------------------------------------------------
; construct — build a HUFF table from code lengths.
;   in:  rbx = HUFF*, rcx = lengths (u16[n]), edx = n
;   out: eax = 0 complete, > 0 incomplete (allowed), < 0 over-subscribed
;   clobbers: rax, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
construct:
    mov r10, rcx                        ; lengths
    mov r11d, edx                       ; n
    xor eax, eax
    xor ecx, ecx
.zero:
    mov word [rbx + HUFF.count + rcx * 2], 0
    inc ecx
    cmp ecx, 16
    jb .zero
    xor ecx, ecx
.count:
    cmp ecx, r11d
    jae .counted
    movzx eax, word [r10 + rcx * 2]
    inc word [rbx + HUFF.count + rax * 2]
    inc ecx
    jmp .count
.counted:
    movzx eax, word [rbx + HUFF.count]
    cmp eax, r11d
    je .empty                           ; no codes at all
    mov r8d, 1                          ; left
    mov ecx, 1
.left:
    shl r8d, 1
    movzx eax, word [rbx + HUFF.count + rcx * 2]
    sub r8d, eax
    js .over
    inc ecx
    cmp ecx, MAXBITS
    jbe .left
    ; offsets
    mov word [r15 + INFL.offs + 2], 0
    mov ecx, 1
.offs:
    movzx eax, word [r15 + INFL.offs + rcx * 2]
    add ax, [rbx + HUFF.count + rcx * 2]
    mov [r15 + INFL.offs + rcx * 2 + 2], ax
    inc ecx
    cmp ecx, MAXBITS
    jb .offs
    xor ecx, ecx                        ; symbol
.sym:
    cmp ecx, r11d
    jae .built
    movzx eax, word [r10 + rcx * 2]
    test eax, eax
    jz .sym_next
    movzx edx, word [r15 + INFL.offs + rax * 2]
    mov [rbx + HUFF.symbol + rdx * 2], cx
    inc word [r15 + INFL.offs + rax * 2]
.sym_next:
    inc ecx
    jmp .sym
.built:
    mov eax, r8d
    ret
.empty:
    xor eax, eax
    ret
.over:
    mov eax, -1
    ret

; -----------------------------------------------------------------------------
; codes — decode literal/length + distance codes until end of block.
;   in:  INFL.len / INFL.dist built
;   out: eax = 0 ok, -1 error
;   clobbers: rax, rbx, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
codes:
.next:
    cmp dword [r15 + INFL.err], 0
    jne .error
    lea rbx, [r15 + INFL.len]
    call decode
    cmp eax, 256
    jb .literal
    je .end
    sub eax, 257
    cmp eax, 29
    jae .error
    ; length
    push rax
    lea rcx, [rel lext]
    movzx ecx, word [rcx + rax * 2]
    call getbits
    pop rcx
    lea rdx, [rel lbase]
    movzx edx, word [rdx + rcx * 2]
    add eax, edx
    push rax                            ; length
    lea rbx, [r15 + INFL.dist]
    call decode
    cmp eax, 30
    jae .error_pop
    push rax
    lea rcx, [rel dext]
    movzx ecx, word [rcx + rax * 2]
    call getbits
    pop rcx
    lea rdx, [rel dbase]
    movzx edx, word [rdx + rcx * 2]
    add eax, edx                        ; distance
    pop rcx                             ; length
    mov rdx, rdi
    sub rdx, [r15 + INFL.out_base]
    cmp rax, rdx
    ja .error                           ; reaches before the output start
    mov rdx, r14
    sub rdx, rdi
    cmp rcx, rdx
    ja .error                           ; output full
    mov rdx, rdi
    sub rdx, rax                        ; source (may overlap: byte copy)
.copy:
    mov al, [rdx]
    mov [rdi], al
    inc rdx
    inc rdi
    dec ecx
    jnz .copy
    jmp .next
.literal:
    cmp rdi, r14
    jae .error
    mov [rdi], al
    inc rdi
    jmp .next
.end:
    xor eax, eax
    ret
.error_pop:
    pop rax
.error:
    mov eax, -1
    ret

; -----------------------------------------------------------------------------
; block_fixed — set up the fixed Huffman tables (RFC 1951 3.2.6).
;   clobbers: rax, rbx, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
block_fixed:
    lea rdx, [r15 + INFL.lengths]
    xor ecx, ecx
.l:
    mov eax, 8
    cmp ecx, 144
    jb .set
    mov eax, 9
    cmp ecx, 256
    jb .set
    mov eax, 7
    cmp ecx, 280
    jb .set
    mov eax, 8
.set:
    mov [rdx + rcx * 2], ax
    inc ecx
    cmp ecx, 288
    jb .l
    lea rbx, [r15 + INFL.len]
    lea rcx, [r15 + INFL.lengths]
    mov edx, 288
    call construct
    lea rdx, [r15 + INFL.lengths]
    xor ecx, ecx
.d:
    mov word [rdx + rcx * 2], 5
    inc ecx
    cmp ecx, 30
    jb .d
    lea rbx, [r15 + INFL.dist]
    lea rcx, [r15 + INFL.lengths]
    mov edx, 30
    call construct
    ret

; -----------------------------------------------------------------------------
; block_dynamic — read the dynamic Huffman tables of a block.
;   out: eax = 0 ok, -1 error
;   clobbers: rax, rbx, rcx, rdx, r8-r11, xmm0 (no), uses stack for counts
; -----------------------------------------------------------------------------
block_dynamic:
    push rbp
    mov ecx, 5
    call getbits
    add eax, 257
    mov ebp, eax                        ; nlen
    mov ecx, 5
    call getbits
    inc eax
    shl eax, 16
    or ebp, eax                         ; ndist in the high half
    mov ecx, 4
    call getbits
    add eax, 4
    mov r8d, eax                        ; ncode
    cmp ebp, (30 << 16) | 286
    ; (validated below per half)
    mov eax, ebp
    and eax, 0xFFFF
    cmp eax, 286
    ja .error
    mov eax, ebp
    shr eax, 16
    cmp eax, 30
    ja .error
    ; code length code lengths
    lea rbx, [r15 + INFL.lengths]
    xor ecx, ecx
.z19:
    mov word [rbx + rcx * 2], 0
    inc ecx
    cmp ecx, 19
    jb .z19
    xor r9d, r9d
.cl:
    cmp r9d, r8d
    jae .cl_done
    push r8
    push r9
    mov ecx, 3
    call getbits
    pop r9
    pop r8
    lea rdx, [rel clorder]
    movzx edx, byte [rdx + r9]
    mov [r15 + INFL.lengths + rdx * 2], ax
    inc r9d
    jmp .cl
.cl_done:
    lea rbx, [r15 + INFL.len]
    lea rcx, [r15 + INFL.lengths]
    mov edx, 19
    call construct
    test eax, eax
    jnz .error                          ; must be complete
    ; literal/length + distance code lengths
    mov eax, ebp
    and eax, 0xFFFF
    mov edx, ebp
    shr edx, 16
    add eax, edx
    push rax                            ; total
    push 0                              ; index
.lens:
    mov rax, [rsp]
    cmp rax, [rsp + 8]
    jae .lens_done
    lea rbx, [r15 + INFL.len]
    call decode
    test eax, eax
    js .error_pop2
    cmp eax, 16
    jb .len_literal
    xor r9d, r9d                        ; value to repeat
    cmp eax, 16
    jne .zeros
    mov rcx, [rsp]
    test rcx, rcx
    jz .error_pop2                      ; repeat with no previous length
    movzx r9d, word [r15 + INFL.lengths + rcx * 2 - 2]
    push r9
    mov ecx, 2
    call getbits
    pop r9
    add eax, 3
    jmp .repeat
.zeros:
    cmp eax, 17
    jne .zeros18
    push r9
    mov ecx, 3
    call getbits
    pop r9
    add eax, 3
    jmp .repeat
.zeros18:
    push r9
    mov ecx, 7
    call getbits
    pop r9
    add eax, 11
.repeat:
    mov rcx, [rsp]
    lea rdx, [rcx + rax]
    cmp rdx, [rsp + 8]
    ja .error_pop2
.rep_loop:
    mov [r15 + INFL.lengths + rcx * 2], r9w
    inc rcx
    dec eax
    jnz .rep_loop
    mov [rsp], rcx
    jmp .lens
.len_literal:
    mov rcx, [rsp]
    mov [r15 + INFL.lengths + rcx * 2], ax
    inc qword [rsp]
    jmp .lens
.lens_done:
    add rsp, 16
    cmp word [r15 + INFL.lengths + 256 * 2], 0
    je .error                           ; no end-of-block code
    lea rbx, [r15 + INFL.len]
    lea rcx, [r15 + INFL.lengths]
    mov edx, ebp
    and edx, 0xFFFF
    call construct
    test eax, eax
    js .error
    jz .len_ok
    ; incomplete literal/length code only allowed for a single length-1 code
    movzx eax, word [r15 + INFL.len + HUFF.count + 2]
    mov ecx, ebp
    and ecx, 0xFFFF
    movzx edx, word [r15 + INFL.len + HUFF.count]
    sub ecx, edx
    cmp ecx, eax
    jne .error
.len_ok:
    lea rbx, [r15 + INFL.dist]
    mov eax, ebp
    and eax, 0xFFFF
    lea rcx, [r15 + INFL.lengths + rax * 2]
    mov edx, ebp
    shr edx, 16
    call construct
    test eax, eax
    js .error
    ; (an incomplete distance code is allowed: some encoders emit one code)
    xor eax, eax
    pop rbp
    ret
.error_pop2:
    add rsp, 16
.error:
    mov eax, -1
    pop rbp
    ret

; -----------------------------------------------------------------------------
; inflate_raw — decompress a raw deflate stream.
;   in:  rcx = src, rdx = src size, r8 = dst, r9 = dst capacity
;   out: rax = bytes written, or -1 on a malformed/truncated stream or if
;        the output does not fit
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC inflate_raw, INFL_size, rbx, rsi, rdi, r12, r13, r14, r15
    lea r15, [LOCAL(0)]
    lea rax, [rcx + rdx]
    mov [r15 + INFL.in_end], rax
    mov [r15 + INFL.out_base], r8
    mov dword [r15 + INFL.err], 0
    mov rsi, rcx
    mov rdi, r8
    lea r14, [r8 + r9]
    xor r12d, r12d
    xor r13d, r13d
.block:
    mov ecx, 1
    call getbits
    mov [r15 + INFL.pad], eax           ; last-block flag
    mov ecx, 2
    call getbits
    cmp eax, 0
    je .stored
    cmp eax, 1
    je .fixed
    cmp eax, 2
    je .dynamic
    jmp .fail
.stored:
    ; drop to a byte boundary (the bit buffer holds whole bytes beyond it)
    mov ecx, r13d
    and ecx, 7
    shr r12, cl
    sub r13d, ecx
    mov ecx, 16
    call getbits
    mov ebx, eax                        ; LEN
    mov ecx, 16
    call getbits
    not eax
    and eax, 0xFFFF
    cmp eax, ebx
    jne .fail
    mov rax, r14
    sub rax, rdi
    cmp rbx, rax
    ja .fail
.stored_copy:
    test ebx, ebx
    jz .block_done
    mov ecx, 8
    call getbits
    mov [rdi], al
    inc rdi
    dec ebx
    jmp .stored_copy
.fixed:
    call block_fixed
    call codes
    test eax, eax
    jnz .fail
    jmp .block_done
.dynamic:
    call block_dynamic
    test eax, eax
    jnz .fail
    call codes
    test eax, eax
    jnz .fail
.block_done:
    cmp dword [r15 + INFL.err], 0
    jne .fail
    cmp dword [r15 + INFL.pad], 0
    je .block
    mov rax, rdi
    sub rax, [r15 + INFL.out_base]
    RETURN
.fail:
    mov rax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; be32 — read a big-endian u32.   in: rcx = ptr   out: eax   clobbers: rax
; -----------------------------------------------------------------------------
%macro BE32 2                           ; dst32, mem
    mov %1, %2
    bswap %1
%endmacro

; -----------------------------------------------------------------------------
; paeth — PNG Paeth predictor.
;   in:  eax = a (left), edx = b (up), ecx = c (up-left)   out: eax
;   clobbers: rax, rcx, rdx, r8-r11
; -----------------------------------------------------------------------------
paeth:
    mov r8d, eax
    add r8d, edx
    sub r8d, ecx                        ; p = a + b - c
    mov r9d, r8d
    sub r9d, eax                        ; pa = |p - a|
    mov r10d, r9d
    neg r10d
    cmovns r9d, r10d
    mov r10d, r8d
    sub r10d, edx                       ; pb
    mov r11d, r10d
    neg r11d
    cmovns r10d, r11d
    mov r11d, r8d
    sub r11d, ecx                       ; pc
    mov r8d, r11d
    neg r8d
    cmovns r11d, r8d
    cmp r9d, r10d
    ja .not_a
    cmp r9d, r11d
    ja .not_a
    ret                                 ; a
.not_a:
    cmp r10d, r11d
    ja .c
    mov eax, edx                        ; b
    ret
.c:
    mov eax, ecx
    ret

; -----------------------------------------------------------------------------
; png_decode — decode a PNG file held in memory to RGBA8.
;   in:  rcx = data, rdx = size, r8 = PNG_INFO* (u32 width, u32 height),
;        r9 = ARENA* (pixels and temporaries)
;   out: rax = pixels (w*h*4 bytes, top row first), or 0 (warning logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define P_INFO      0
%define P_ARENA     8
%define P_END       16
%define P_W         24
%define P_H         28
%define P_DEPTH     32
%define P_TYPE      36
%define P_IDAT      40                  ; collected IDAT data
%define P_IDAT_LEN  48
%define P_PLTE      56                  ; palette RGBA (256 x 4), in the arena
%define P_TRNS_KEY  64                  ; colour key (grey or R,G,B in bytes 0-2)
%define P_HAS_KEY   68
%define P_ROWBYTES  72
%define P_BPP       80
%define P_RAW       88
%define P_OUT       96
%define P_CHAN      104
%define P_DATA      112
%define P_LOCALS    128
PROC png_decode, P_LOCALS, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(P_INFO)], r8
    mov [LOCAL(P_ARENA)], r9
    mov [LOCAL(P_DATA)], rcx
    lea rax, [rcx + rdx]
    mov [LOCAL(P_END)], rax
    mov qword [LOCAL(P_IDAT_LEN)], 0
    mov dword [LOCAL(P_HAS_KEY)], 0
    mov dword [LOCAL(P_W)], 0

    cmp rdx, 8 + 25
    jb .bad
    mov rax, [rcx]
    cmp rax, [rel png_sig]
    jne .bad

    ; palette table (opaque black default)
    INVOKE arena_alloc, [LOCAL(P_ARENA)], 1024, 16
    test rax, rax
    jz .bad
    mov [LOCAL(P_PLTE)], rax
    mov rdi, rax
    mov eax, 0xFF000000
    mov ecx, 256
    rep stosd

    ; IDAT buffer: at most the file size
    mov rdx, [LOCAL(P_END)]
    sub rdx, [LOCAL(P_DATA)]
    INVOKE arena_alloc, [LOCAL(P_ARENA)], rdx, 16
    test rax, rax
    jz .bad
    mov [LOCAL(P_IDAT)], rax

    ; ---- chunks -----------------------------------------------------------------------
    mov rsi, [LOCAL(P_DATA)]
    add rsi, 8
.chunk:
    lea rax, [rsi + 12]
    cmp rax, [LOCAL(P_END)]
    ja .bad
    BE32 ebx, [rsi]                     ; length
    mov r12d, [rsi + 4]                 ; type (as little-endian dword)
    lea r13, [rsi + 8]                  ; chunk data
    lea rax, [r13 + rbx + 4]
    cmp rax, [LOCAL(P_END)]
    ja .bad
    cmp r12d, 'IHDR'
    je .ihdr
    cmp r12d, 'PLTE'
    je .plte
    cmp r12d, 'tRNS'
    je .trns
    cmp r12d, 'IDAT'
    je .idat
    cmp r12d, 'IEND'
    je .chunks_done
.chunk_next:
    lea rsi, [r13 + rbx + 4]
    jmp .chunk

.ihdr:
    cmp ebx, 13
    jb .bad
    BE32 eax, [r13]
    mov [LOCAL(P_W)], eax
    BE32 eax, [r13 + 4]
    mov [LOCAL(P_H)], eax
    movzx eax, byte [r13 + 8]
    mov [LOCAL(P_DEPTH)], eax
    movzx eax, byte [r13 + 9]
    mov [LOCAL(P_TYPE)], eax
    cmp byte [r13 + 12], 0
    jne .interlaced
    jmp .chunk_next

.plte:
    mov rdi, [LOCAL(P_PLTE)]
    xor ecx, ecx
.plte_l:
    lea eax, [ecx + 2]
    cmp eax, ebx
    jae .chunk_next
    cmp ecx, 768
    jae .chunk_next
    movzx eax, byte [r13 + rcx]
    mov [rdi], al
    movzx eax, byte [r13 + rcx + 1]
    mov [rdi + 1], al
    movzx eax, byte [r13 + rcx + 2]
    mov [rdi + 2], al
    add rdi, 4
    add ecx, 3
    jmp .plte_l

.trns:
    cmp dword [LOCAL(P_TYPE)], 3
    je .trns_pal
    mov dword [LOCAL(P_HAS_KEY)], 1
    ; grey: one u16; RGB: three u16 — keep the low bytes (8-bit images)
    movzx eax, byte [r13 + 1]
    mov [LOCAL(P_TRNS_KEY)], al
    cmp ebx, 6
    jb .chunk_next
    movzx eax, byte [r13 + 3]
    mov [LOCAL(P_TRNS_KEY) + 1], al
    movzx eax, byte [r13 + 5]
    mov [LOCAL(P_TRNS_KEY) + 2], al
    jmp .chunk_next
.trns_pal:
    mov rdi, [LOCAL(P_PLTE)]
    xor ecx, ecx
.trns_l:
    cmp ecx, ebx
    jae .chunk_next
    cmp ecx, 256
    jae .chunk_next
    movzx eax, byte [r13 + rcx]
    mov [rdi + rcx * 4 + 3], al
    inc ecx
    jmp .trns_l

.idat:
    mov rdi, [LOCAL(P_IDAT)]
    add rdi, [LOCAL(P_IDAT_LEN)]
    mov rsi, r13
    mov ecx, ebx
    rep movsb
    add [LOCAL(P_IDAT_LEN)], rbx
    jmp .chunk_next

.chunks_done:
    ; ---- validate the header ------------------------------------------------------------
    mov eax, [LOCAL(P_W)]
    test eax, eax
    jz .bad
    cmp eax, 16384
    ja .bad
    mov eax, [LOCAL(P_H)]
    test eax, eax
    jz .bad
    cmp eax, 16384
    ja .bad
    ; channels by colour type
    mov eax, [LOCAL(P_TYPE)]
    mov ecx, 1
    cmp eax, 0
    je .chan
    mov ecx, 3
    cmp eax, 2
    je .chan
    mov ecx, 1
    cmp eax, 3
    je .chan
    mov ecx, 2
    cmp eax, 4
    je .chan
    mov ecx, 4
    cmp eax, 6
    je .chan
    jmp .unsupported
.chan:
    mov [LOCAL(P_CHAN)], ecx
    mov eax, [LOCAL(P_DEPTH)]
    cmp eax, 1
    je .depth_ok
    cmp eax, 2
    je .depth_ok
    cmp eax, 4
    je .depth_ok
    cmp eax, 8
    je .depth_ok
    cmp eax, 16
    jne .unsupported
.depth_ok:
    ; bits per pixel, row bytes, filter step
    imul ecx, eax                       ; bits per pixel
    mov eax, ecx
    add eax, 7
    shr eax, 3
    mov [LOCAL(P_BPP)], rax             ; >= 1
    mov eax, [LOCAL(P_W)]
    imul rax, rcx
    add rax, 7
    shr rax, 3
    mov [LOCAL(P_ROWBYTES)], rax

    ; ---- inflate (zlib header: CM 8, no preset dictionary) ------------------------------
    mov rsi, [LOCAL(P_IDAT)]
    cmp qword [LOCAL(P_IDAT_LEN)], 6
    jb .bad
    movzx eax, byte [rsi]
    and eax, 15
    cmp eax, 8
    jne .bad
    test byte [rsi + 1], 0x20
    jnz .bad
    mov rbx, [LOCAL(P_ROWBYTES)]
    inc rbx
    mov eax, [LOCAL(P_H)]
    imul rbx, rax                       ; raw size
    INVOKE arena_alloc, [LOCAL(P_ARENA)], rbx, 16
    test rax, rax
    jz .bad
    mov [LOCAL(P_RAW)], rax
    mov rcx, [LOCAL(P_IDAT)]
    add rcx, 2
    mov rdx, [LOCAL(P_IDAT_LEN)]
    sub rdx, 2
    INVOKE inflate_raw, rcx, rdx, rax, rbx
    cmp rax, rbx
    jne .bad

    ; ---- unfilter in place ------------------------------------------------------------------
    mov rsi, [LOCAL(P_RAW)]             ; row (filter byte first)
    xor r12d, r12d                      ; y
    mov r13, [LOCAL(P_ROWBYTES)]
    mov r14, [LOCAL(P_BPP)]
.unf_row:
    cmp r12d, [LOCAL(P_H)]
    jae .unf_done
    movzx ebx, byte [rsi]               ; filter type
    lea rdi, [rsi + 1]                  ; current row bytes
    mov r15, rdi
    sub r15, r13
    dec r15                             ; previous row bytes (y > 0)
    cmp ebx, 4
    ja .bad
    xor ecx, ecx                        ; x (byte index)
.unf_x:
    cmp rcx, r13
    jae .unf_next
    ; a = left, b = up, c = up-left
    xor eax, eax
    xor edx, edx
    xor r8d, r8d
    cmp rcx, r14
    jb .no_left
    mov r9, rcx
    sub r9, r14
    movzx eax, byte [rdi + r9]
    test r12d, r12d
    jz .no_left
    movzx r8d, byte [r15 + r9]
.no_left:
    test r12d, r12d
    jz .have_abc
    movzx edx, byte [r15 + rcx]
.have_abc:
    ; predictor by filter
    cmp ebx, 0
    je .pred_none
    cmp ebx, 1
    je .pred_sub
    cmp ebx, 2
    je .pred_up
    cmp ebx, 3
    je .pred_avg
    ; Paeth
    push rcx
    mov ecx, r8d
    call paeth
    pop rcx
    jmp .apply
.pred_none:
    xor eax, eax
    jmp .apply
.pred_sub:
    jmp .apply                          ; a
.pred_up:
    mov eax, edx
    jmp .apply
.pred_avg:
    add eax, edx
    shr eax, 1
.apply:
    add [rdi + rcx], al
    inc rcx
    jmp .unf_x
.unf_next:
    lea rsi, [rdi + r13]
    inc r12d
    jmp .unf_row
.unf_done:

    ; ---- convert to RGBA8 --------------------------------------------------------------------
    mov eax, [LOCAL(P_W)]
    mov ecx, [LOCAL(P_H)]
    imul rax, rcx
    shl rax, 2
    INVOKE arena_alloc, [LOCAL(P_ARENA)], rax, 16
    test rax, rax
    jz .bad
    mov [LOCAL(P_OUT)], rax
    mov rdi, rax                        ; output pixel
    xor r12d, r12d                      ; y
.cv_row:
    cmp r12d, [LOCAL(P_H)]
    jae .cv_done
    mov rax, [LOCAL(P_ROWBYTES)]
    inc rax
    imul rax, r12
    mov rsi, [LOCAL(P_RAW)]
    lea rsi, [rsi + rax + 1]            ; row data
    xor r13d, r13d                      ; x
.cv_px:
    cmp r13d, [LOCAL(P_W)]
    jae .cv_next_row
    mov ebx, [LOCAL(P_TYPE)]
    mov r14d, [LOCAL(P_DEPTH)]
    cmp r14d, 8
    jae .cv_bytes
    ; sub-byte sample (grey or palette): bit offset = x * depth
    mov eax, r13d
    imul eax, r14d
    mov edx, eax
    shr edx, 3
    movzx r8d, byte [rsi + rdx]
    and eax, 7
    mov ecx, 8
    sub ecx, r14d
    sub ecx, eax                        ; shift
    shr r8d, cl
    mov ecx, r14d
    mov eax, 1
    shl eax, cl
    dec eax                             ; mask
    and r8d, eax
    cmp ebx, 3
    je .cv_pal
    ; grey: scale to 0..255
    imul r8d, r8d, 255
    xchg eax, r8d
    xor edx, edx
    div r8d
    mov r8d, eax
    jmp .cv_grey
.cv_bytes:
    ; byte-aligned samples; 16-bit: take the high byte of each
    mov ecx, r14d
    shr ecx, 3                          ; bytes per sample (1 or 2)
    mov eax, r13d
    imul eax, [LOCAL(P_CHAN)]
    imul eax, ecx
    lea r9, [rsi + rax]                 ; first sample
    cmp ebx, 3
    je .cv_pal8
    cmp ebx, 0
    je .cv_g8
    cmp ebx, 4
    je .cv_ga
    cmp ebx, 2
    je .cv_rgb
    ; RGBA
    movzx eax, byte [r9]
    mov [rdi], al
    movzx eax, byte [r9 + rcx]
    mov [rdi + 1], al
    movzx eax, byte [r9 + rcx * 2]
    mov [rdi + 2], al
    lea rdx, [rcx + rcx * 2]
    movzx eax, byte [r9 + rdx]
    mov [rdi + 3], al
    jmp .cv_store_done
.cv_rgb:
    movzx eax, byte [r9]
    mov [rdi], al
    movzx eax, byte [r9 + rcx]
    mov [rdi + 1], al
    movzx eax, byte [r9 + rcx * 2]
    mov [rdi + 2], al
    mov byte [rdi + 3], 255
    cmp dword [LOCAL(P_HAS_KEY)], 0
    je .cv_store_done
    cmp ecx, 1
    jne .cv_store_done
    mov eax, [rdi]
    and eax, 0xFFFFFF
    mov edx, [LOCAL(P_TRNS_KEY)]
    and edx, 0xFFFFFF
    cmp eax, edx
    jne .cv_store_done
    mov byte [rdi + 3], 0
    jmp .cv_store_done
.cv_ga:
    movzx r8d, byte [r9]
    movzx eax, byte [r9 + rcx]
    mov [rdi + 3], al
    mov [rdi], r8b
    mov [rdi + 1], r8b
    mov [rdi + 2], r8b
    jmp .cv_store_done
.cv_g8:
    movzx r8d, byte [r9]
.cv_grey:
    mov [rdi], r8b
    mov [rdi + 1], r8b
    mov [rdi + 2], r8b
    mov byte [rdi + 3], 255
    cmp dword [LOCAL(P_HAS_KEY)], 0
    je .cv_store_done
    cmp r14d, 16
    je .cv_store_done
    cmp r8b, [LOCAL(P_TRNS_KEY)]
    jne .cv_store_done
    mov byte [rdi + 3], 0
    jmp .cv_store_done
.cv_pal8:
    movzx r8d, byte [r9]
.cv_pal:
    mov rax, [LOCAL(P_PLTE)]
    mov eax, [rax + r8 * 4]
    mov [rdi], eax
.cv_store_done:
    add rdi, 4
    inc r13d
    jmp .cv_px
.cv_next_row:
    inc r12d
    jmp .cv_row
.cv_done:
    mov rcx, [LOCAL(P_INFO)]
    mov eax, [LOCAL(P_W)]
    mov [rcx], eax
    mov eax, [LOCAL(P_H)]
    mov [rcx + 4], eax
    mov rax, [LOCAL(P_OUT)]
    RETURN

.interlaced:
    LOG_WARN "png: interlaced images are not supported (save without interlacing)"
    xor eax, eax
    RETURN
.unsupported:
    LOG_WARN "png: unsupported colour type / bit depth"
    xor eax, eax
    RETURN
.bad:
    LOG_WARN "png: malformed or truncated file"
    xor eax, eax
    RETURN
ENDPROC
