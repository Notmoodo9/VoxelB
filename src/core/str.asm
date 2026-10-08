; =============================================================================
; str.asm — string and number formatting utilities (no CRT).
; All routines are leaf functions following the Win64 ABI.
; =============================================================================
%include "macros.inc"

global str_len, str_find, str_parse_u64, str_copy, fmt_u64, fmt_hex64, fmt_decimal

section .text

; -----------------------------------------------------------------------------
; str_len — length of a zero-terminated string.
;   in:  rcx = pointer to string
;   out: rax = length in bytes (excluding terminator)
;   clobbers: rax
; -----------------------------------------------------------------------------
str_len:
    mov rax, rcx
.loop:
    cmp byte [rax], 0
    je .done
    inc rax
    jmp .loop
.done:
    sub rax, rcx
    ret

; -----------------------------------------------------------------------------
; str_find — find first occurrence of needle in haystack (case-sensitive).
;   in:  rcx = haystack (zero-terminated), rdx = needle (zero-terminated)
;   out: rax = pointer to match inside haystack, or 0 if not found
;        (an empty needle matches at the start of haystack)
;   clobbers: rax, r8, r9, r10
; -----------------------------------------------------------------------------
str_find:
    mov rax, rcx
.outer:
    xor r8, r8                      ; index into needle
.inner:
    mov r9b, [rdx + r8]
    test r9b, r9b
    jz .found                       ; reached end of needle: match
    mov r10b, [rax + r8]
    cmp r10b, r9b
    jne .next
    inc r8
    jmp .inner
.next:
    cmp byte [rax], 0
    je .notfound
    inc rax
    jmp .outer
.found:
    ret
.notfound:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; str_parse_u64 — parse an unsigned decimal number, skipping leading spaces.
;   in:  rcx = pointer to text
;   out: rax = parsed value (0 if no digits; wraps on overflow)
;        rdx = pointer to first byte after the digits
;        r8  = number of digits consumed
;   clobbers: rax, rdx, r8, r9
; -----------------------------------------------------------------------------
str_parse_u64:
    mov rdx, rcx
.skip:
    cmp byte [rdx], ' '
    je .space
    cmp byte [rdx], 9               ; tab
    jne .digits
.space:
    inc rdx
    jmp .skip
.digits:
    xor eax, eax
    xor r8, r8
.loop:
    movzx r9d, byte [rdx]
    sub r9d, '0'
    cmp r9d, 9
    ja .done
    imul rax, rax, 10
    add rax, r9
    inc rdx
    inc r8
    jmp .loop
.done:
    ret

; -----------------------------------------------------------------------------
; fmt_u64 — format an unsigned value as decimal, right-aligned.
;   in:  rcx = destination buffer (needs max(20, width) bytes; not terminated)
;        rdx = value
;        r8  = minimum field width (0 = no padding, max 32)
;        r9  = pad character (low byte, e.g. ' ' or '0')
;   out: rax = number of bytes written
;   clobbers: rax, rcx, rdx, r8, r9, r10, r11
; -----------------------------------------------------------------------------
fmt_u64:
    ; produce digits backwards into a scratch area on the stack (Win64 has no
    ; red zone, so reserve it explicitly)
    sub rsp, 40
    mov r10, rcx                    ; r10 = destination
    mov rax, rdx
    mov ecx, 10
    lea r11, [rsp + 32]             ; r11 = write cursor (moves backwards)
.digit:
    xor edx, edx
    div rcx
    add dl, '0'
    dec r11
    mov [r11], dl
    test rax, rax
    jnz .digit
    lea rax, [rsp + 32]
    sub rax, r11                    ; rax = digit count
    xor edx, edx                    ; rdx = bytes written
.pad:
    cmp r8, rax
    jbe .copy
    mov [r10 + rdx], r9b
    inc rdx
    dec r8
    jmp .pad
.copy:
    lea rcx, [rsp + 32]
.copy_loop:
    cmp r11, rcx
    je .out
    mov r9b, [r11]
    mov [r10 + rdx], r9b
    inc rdx
    inc r11
    jmp .copy_loop
.out:
    mov rax, rdx
    add rsp, 40
    ret

; -----------------------------------------------------------------------------
; fmt_hex64 — format a value as 16 upper-case hex digits (no prefix).
;   in:  rcx = destination buffer (16 bytes; not terminated)
;        rdx = value
;   out: rax = 16
;   clobbers: rax, rdx, r8, r9
; -----------------------------------------------------------------------------
fmt_hex64:
    mov r8d, 15
.loop:
    mov r9d, edx
    and r9d, 0xF
    cmp r9d, 10
    jb .num
    add r9d, 'A' - 10 - '0'
.num:
    add r9d, '0'
    mov [rcx + r8], r9b
    shr rdx, 4
    dec r8
    jns .loop
    mov eax, 16
    ret

; -----------------------------------------------------------------------------
; str_copy — copy a zero-terminated string, including the terminator.
;   in:  rcx = destination, rdx = source
;   out: rax = pointer to the terminator written in the destination (so
;        calls can be chained to build a string)
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
str_copy:
    mov rax, rcx
.loop:
    mov cl, [rdx]
    mov [rax], cl
    test cl, cl
    jz .done
    inc rax
    inc rdx
    jmp .loop
.done:
    ret

; -----------------------------------------------------------------------------
; fmt_decimal — format a fixed-point value: value / 10^frac with exactly
; `frac` digits after the point (e.g. 16667, 3 -> "16.667").
;   in:  rcx = destination buffer (not terminated), rdx = value,
;        r8 = number of fraction digits (0..9)
;   out: rax = number of bytes written
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC fmt_decimal, 0, rbx, rsi, rdi, r12
    mov rbx, rcx                        ; rbx = destination
    mov rax, rdx
    mov rdi, r8                         ; rdi = fraction digits
    mov ecx, 1
    mov r9, rdi
.pow:
    test r9, r9
    jz .pow_done
    imul rcx, rcx, 10
    dec r9
    jmp .pow
.pow_done:
    xor edx, edx
    div rcx
    mov r12, rdx                        ; r12 = fraction part
    INVOKE fmt_u64, rbx, rax, 0, ' '
    mov rsi, rax                        ; rsi = bytes written
    test rdi, rdi
    jz .done
    mov byte [rbx + rsi], '.'
    inc rsi
    lea rcx, [rbx + rsi]
    INVOKE fmt_u64, rcx, r12, rdi, '0'
    add rsi, rax
.done:
    mov rax, rsi
    RETURN
ENDPROC
