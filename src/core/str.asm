; =============================================================================
; str.asm — string and number formatting utilities (no CRT).
; All routines are leaf functions following the Win64 ABI.
; =============================================================================
%include "macros.inc"

global str_len, str_find, str_parse_u64, str_copy, fmt_u64, fmt_hex64, fmt_decimal
global str_ieq, str_parse_float, fmt_signed_decimal, str_append_dec, str_append_sdec

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

; -----------------------------------------------------------------------------
; str_ieq — compare two zero-terminated strings, ignoring ASCII case.
;   in:  rcx = string a, rdx = string b
;   out: eax = 1 if equal, 0 otherwise
;   clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
str_ieq:
.loop:
    movzx r8d, byte [rcx]
    movzx r9d, byte [rdx]
    lea eax, [r8 - 'a']
    cmp eax, 25
    ja .a_ok
    sub r8d, 32
.a_ok:
    lea eax, [r9 - 'a']
    cmp eax, 25
    ja .b_ok
    sub r9d, 32
.b_ok:
    cmp r8d, r9d
    jne .ne
    test r8d, r8d
    jz .eq
    inc rcx
    inc rdx
    jmp .loop
.eq:
    mov eax, 1
    ret
.ne:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; str_parse_float — parse "[-]digits[.digits]" (leading spaces skipped).
;   in:  rcx = text
;   out: xmm0 = value (float), rdx = pointer after the number,
;        eax = 1 if at least one digit was read, else 0
;   clobbers: rax, rcx, rdx, r8, r9, r10, r11, xmm0, xmm1
; -----------------------------------------------------------------------------
str_parse_float:
    mov rdx, rcx
.skip:
    cmp byte [rdx], ' '
    je .sp
    cmp byte [rdx], 9
    jne .sign
.sp:
    inc rdx
    jmp .skip
.sign:
    xor r10d, r10d                      ; r10 = negative flag
    cmp byte [rdx], '-'
    jne .int
    mov r10d, 1
    inc rdx
.int:
    xor eax, eax                        ; mantissa
    xor r11d, r11d                      ; digit count
    mov r8d, 1                          ; fraction divisor (10^fraction digits)
    xor ecx, ecx                        ; in-fraction flag
.digit:
    movzx r9d, byte [rdx]
    cmp r9d, '.'
    jne .not_dot
    test ecx, ecx
    jnz .done
    mov ecx, 1
    inc rdx
    jmp .digit
.not_dot:
    sub r9d, '0'
    cmp r9d, 9
    ja .done
    cmp r11d, 17                        ; ignore digits beyond int64 precision
    jae .skip_digit
    imul rax, rax, 10
    add rax, r9
    test ecx, ecx
    jz .counted
    imul r8, r8, 10
.counted:
    inc r11d
.skip_digit:
    inc rdx
    jmp .digit
.done:
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, r8
    divsd xmm0, xmm1
    test r10d, r10d
    jz .pos
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movapd xmm0, xmm1
.pos:
    cvtsd2ss xmm0, xmm0
    xor eax, eax
    test r11d, r11d
    setnz al
    ret

; -----------------------------------------------------------------------------
; fmt_signed_decimal — like fmt_decimal for a signed value ("-12.50").
;   in:  rcx = destination (not terminated), rdx = signed value,
;        r8 = fraction digits
;   out: rax = bytes written
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC fmt_signed_decimal, 0, rbx
    xor ebx, ebx
    test rdx, rdx
    jns .positive
    mov byte [rcx], '-'
    inc rcx
    neg rdx
    mov ebx, 1
.positive:
    call fmt_decimal
    add rax, rbx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; str_append_dec — write a fixed-point unsigned number at a string cursor and
; terminate it (for building strings with str_copy-style chaining).
;   in:  rcx = cursor, rdx = value, r8 = fraction digits
;   out: rax = new cursor (points at the terminator)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC str_append_dec, 0, rbx
    mov rbx, rcx
    call fmt_decimal
    add rax, rbx
    mov byte [rax], 0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; str_append_sdec — like str_append_dec for a signed value.
;   in:  rcx = cursor, rdx = signed value, r8 = fraction digits
;   out: rax = new cursor (points at the terminator)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC str_append_sdec, 0, rbx
    mov rbx, rcx
    call fmt_signed_decimal
    add rax, rbx
    mov byte [rax], 0
    RETURN
ENDPROC
