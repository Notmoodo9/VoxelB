; =============================================================================
; png_write.asm — write an RGB PNG file (milestone 17: world thumbnails).
;
; The image data is a zlib stream of *stored* deflate blocks (no
; compression: thumbnails are small), with the PNG chunk CRCs and the
; Adler-32 checksum, so any viewer opens the file.
;
; Public API:
;   png_write(path, rgba, w, h, flip, arena) -> eax 1/0
;       rgba: w * h * 4 bytes (alpha ignored); flip = 1 if the rows are
;       bottom-up (glReadPixels); the arena holds the file while it is built
; =============================================================================
%include "macros.inc"
%include "memory.inc"

global png_write

IMPORT CreateFileA, WriteFile, CloseHandle

%define GENERIC_WRITE   0x40000000
%define CREATE_ALWAYS   2
%define FILE_ATTRIBUTE_NORMAL 0x80
%define STORED_MAX      65535

section .rdata
png_sig:        db 0x89, "PNG", 13, 10, 26, 10

section .bss
alignb 4
g_crc_table:    resd 256
g_crc_ready:    resd 1

section .text

; crc_init — the CRC-32 table (polynomial 0xEDB88320), once
crc_init:
    cmp dword [rel g_crc_ready], 0
    jne .done
    xor ecx, ecx
.n:
    mov eax, ecx
    mov edx, 8
.k:
    shr eax, 1
    jnc .no_xor
    xor eax, 0xEDB88320
.no_xor:
    dec edx
    jnz .k
    lea r8, [rel g_crc_table]
    mov [r8 + rcx * 4], eax
    inc ecx
    cmp ecx, 256
    jb .n
    mov dword [rel g_crc_ready], 1
.done:
    ret

; crc32 — eax = CRC-32 of [rcx, rcx + rdx)   clobbers: rax, rcx, rdx, r8, r9
crc32:
    mov eax, 0xFFFFFFFF
    lea r8, [rel g_crc_table]
.b:
    test rdx, rdx
    jz .done
    movzx r9d, byte [rcx]
    xor r9d, eax
    and r9d, 0xFF
    shr eax, 8
    xor eax, [r8 + r9 * 4]
    inc rcx
    dec rdx
    jmp .b
.done:
    not eax
    ret

; put_be32 — store eax big-endian at [rdi], rdi += 4
%macro PUT_BE32 0
    bswap eax
    mov [rdi], eax
    add rdi, 4
%endmacro

; -----------------------------------------------------------------------------
; png_write — see the header.
;   in:  rcx = path, rdx = rgba, r8d = w, r9d = h, ARG5 = flip, ARG6 = ARENA*
;   out: eax = 1 written, 0 failed
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define P_PATH      0
%define P_MARK      8
%define P_BUF       16
%define P_RAW       24                  ; filtered rows (filter byte + RGB)
%define P_RAWLEN    32
%define P_WRITTEN   40
%define P_IDAT      48                  ; start of the IDAT chunk's length
PROC png_write, 64, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(P_PATH)], rcx
    mov rsi, rdx                        ; rgba
    mov r12d, r8d                       ; w
    mov r13d, r9d                       ; h
    call crc_init
    mov rcx, [ARG(6)]
    call arena_mark
    mov [LOCAL(P_MARK)], rax
    ; raw scanlines: h * (1 + 3w)
    lea eax, [r12d * 2 + r12d]
    inc eax
    mov r14d, eax                       ; row bytes
    imul eax, r13d
    mov [LOCAL(P_RAWLEN)], rax
    ; the file: signature, IHDR, IDAT (zlib: 2 + blocks * 5 + data + 4), IEND
    mov rdx, rax
    shr rdx, 16
    inc rdx
    imul rdx, rdx, 5
    add rdx, rax
    add rdx, rax                        ; (room for the raw rows too)
    add rdx, 256
    mov rcx, [ARG(6)]
    mov r8d, 16
    call arena_alloc
    test rax, rax
    jz .fail
    mov [LOCAL(P_RAW)], rax             ; raw rows first, the file after them
    add rax, [LOCAL(P_RAWLEN)]
    add rax, 15
    and rax, -16
    mov [LOCAL(P_BUF)], rax
    ; ---- the filtered rows (filter 0, RGB) ----
    mov rdi, [LOCAL(P_RAW)]
    xor ebx, ebx                        ; row
.row:
    cmp ebx, r13d
    jae .rows_done
    mov eax, ebx
    cmp qword [ARG(5)], 0
    je .src_row
    mov eax, r13d
    dec eax
    sub eax, ebx                        ; bottom-up source
.src_row:
    imul eax, r12d
    lea r8, [rsi + rax * 4]
    mov byte [rdi], 0
    inc rdi
    xor ecx, ecx
.px:
    mov eax, [r8 + rcx * 4]
    mov [rdi], ax
    shr eax, 16
    mov [rdi + 2], al
    add rdi, 3
    inc ecx
    cmp ecx, r12d
    jb .px
    inc ebx
    jmp .row
.rows_done:
    ; ---- signature + IHDR ----
    mov rdi, [LOCAL(P_BUF)]
    mov rax, [rel png_sig]
    mov [rdi], rax
    add rdi, 8
    mov eax, 13
    PUT_BE32
    mov r15, rdi                        ; chunk type start (for the CRC)
    mov dword [rdi], 'IHDR'
    add rdi, 4
    mov eax, r12d
    PUT_BE32
    mov eax, r13d
    PUT_BE32
    mov byte [rdi], 8                   ; bit depth
    mov byte [rdi + 1], 2               ; colour type: RGB
    mov word [rdi + 2], 0               ; compression, filter
    mov byte [rdi + 4], 0               ; no interlace
    add rdi, 5
    mov rcx, r15
    mov rdx, rdi
    sub rdx, r15
    call crc32
    PUT_BE32
    ; ---- IDAT: zlib header, stored blocks, Adler-32 ----
    mov [LOCAL(P_IDAT)], rdi
    add rdi, 4                          ; (its length, written below)
    mov r15, rdi
    mov dword [rdi], 'IDAT'
    add rdi, 4
    mov byte [rdi], 0x78                ; zlib: deflate, 32 K window
    mov byte [rdi + 1], 0x01            ; (no dictionary, check bits)
    add rdi, 2
    mov rsi, [LOCAL(P_RAW)]
    mov rbx, [LOCAL(P_RAWLEN)]          ; bytes left
.block:
    mov ecx, STORED_MAX
    cmp rbx, rcx
    cmovb ecx, ebx
    xor eax, eax
    cmp rbx, rcx
    jne .not_last
    mov eax, 1                          ; BFINAL
.not_last:
    mov [rdi], al                       ; BTYPE 00 (stored)
    mov [rdi + 1], cx
    mov edx, ecx
    not edx
    mov [rdi + 3], dx
    add rdi, 5
    sub rbx, rcx
    rep movsb
    test rbx, rbx
    jnz .block
    ; Adler-32 of the raw rows
    mov rcx, [LOCAL(P_RAW)]
    mov rdx, [LOCAL(P_RAWLEN)]
    mov r8d, 1                          ; a
    xor r9d, r9d                        ; b
.adler:
    test rdx, rdx
    jz .adler_done
    movzx eax, byte [rcx]
    add r8d, eax
    cmp r8d, 65521
    jb .a_ok
    sub r8d, 65521
.a_ok:
    add r9d, r8d
    cmp r9d, 65521
    jb .b_ok
    sub r9d, 65521
.b_ok:
    inc rcx
    dec rdx
    jmp .adler
.adler_done:
    mov eax, r9d
    shl eax, 16
    or eax, r8d
    PUT_BE32
    ; the chunk's length and CRC
    mov rax, rdi
    sub rax, r15
    sub eax, 4
    mov rcx, [LOCAL(P_IDAT)]
    bswap eax
    mov [rcx], eax
    mov rcx, r15
    mov rdx, rdi
    sub rdx, r15
    call crc32
    PUT_BE32
    ; ---- IEND ----
    xor eax, eax
    PUT_BE32
    mov r15, rdi
    mov dword [rdi], 'IEND'
    add rdi, 4
    mov rcx, r15
    mov edx, 4
    call crc32
    PUT_BE32
    ; ---- the file ----
    mov rcx, [LOCAL(P_PATH)]
    mov qword [rsp + 32], CREATE_ALWAYS
    mov qword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov qword [rsp + 48], 0
    mov edx, GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    call [rel __imp_CreateFileA]
    cmp rax, -1
    je .fail_reset
    mov rbx, rax
    mov r8, rdi
    sub r8, [LOCAL(P_BUF)]
    lea r9, [LOCAL(P_WRITTEN)]
    mov qword [rsp + 32], 0
    API WriteFile, rbx, [LOCAL(P_BUF)], r8, r9
    mov esi, eax
    API CloseHandle, rbx
    mov rcx, [ARG(6)]
    INVOKE arena_reset_to, rcx, [LOCAL(P_MARK)]
    mov eax, esi
    test eax, eax
    setnz al
    movzx eax, al
    RETURN
.fail_reset:
    mov rcx, [ARG(6)]
    INVOKE arena_reset_to, rcx, [LOCAL(P_MARK)]
.fail:
    xor eax, eax
    RETURN
ENDPROC
