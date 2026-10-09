; =============================================================================
; cfg.asm — parser for the line-based "name = value" data format
; (DATA_FORMAT.md). Shared by every data/config file reader.
;
; Public API (see include/cfg.inc):
;   cfg_parse(text, callback, user, label)
;       text is modified in place (terminators are written). For every
;       "name = value" line: callback(rcx = name, rdx = value, r8 = user).
;       Both strings are trimmed and zero-terminated. '#' starts a comment.
;       Lines without '=' are logged as warnings (prefixed with `label`).
;   cfg_parse_ex(text, callback, user, label, flags)
;       flags bit 0 (CFG_SECTIONS): a line "[header]" calls
;       callback(rcx = header text, rdx = 0, r8 = user) instead of warning.
;   cfg_next_token(cursor) -> rax = token, rdx = next cursor (0 = last)
;       splits a value list on ','; tokens are trimmed and terminated.
;   cfg_warn(label, message, detail)   log "<label>: <message><detail>"
; =============================================================================
%include "macros.inc"
%include "log.inc"

global cfg_parse, cfg_parse_ex, cfg_next_token, cfg_warn, cfg_trim

section .rdata
str_colon_sp:   db ": ", 0
str_no_eq:      db "line without '=': ", 0

section .text

; -----------------------------------------------------------------------------
; cfg_trim — trim whitespace/control chars of [start, end), terminate.
;   in:  rcx = start, rdx = end (exclusive)
;   out: rax = trimmed start
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
cfg_trim:
.front:
    cmp rcx, rdx
    jae .term
    cmp byte [rcx], ' '
    ja .back
    inc rcx
    jmp .front
.back:
    cmp rdx, rcx
    jbe .term
    cmp byte [rdx - 1], ' '
    ja .term
    dec rdx
    jmp .back
.term:
    mov byte [rdx], 0
    mov rax, rcx
    ret

; -----------------------------------------------------------------------------
; str_len_local — length of a zero-terminated string.
;   in:  rcx = string   out: rax = length   clobbers: rax
; -----------------------------------------------------------------------------
str_len_local:
    xor eax, eax
.l:
    cmp byte [rcx + rax], 0
    je .d
    inc rax
    jmp .l
.d:
    ret

; -----------------------------------------------------------------------------
; cfg_warn — log "<label>: <message><detail>" at WARN level.
;   in:  rcx = label, rdx = message, r8 = detail (may be 0)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC cfg_warn, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov ecx, LOG_LEVEL_WARN
    call log_begin
    mov rcx, rbx
    call log_append_str
    lea rcx, [rel str_colon_sp]
    call log_append_str
    mov rcx, rsi
    call log_append_str
    mov rcx, rdi
    call log_append_str
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; cfg_next_token — take the next ','-separated token of a value list.
;   in:  rcx = cursor (zero-terminated)
;   out: rax = token (trimmed, terminated; may be empty)
;        rdx = cursor for the next token, or 0 if this was the last one
;   clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
cfg_next_token:
    mov r8, rcx                         ; start
.scan:
    mov al, [rcx]
    test al, al
    jz .last
    cmp al, ','
    je .sep
    inc rcx
    jmp .scan
.sep:
    lea r9, [rcx + 1]                   ; next cursor
    mov rdx, rcx
    mov rcx, r8
    call cfg_trim
    mov rdx, r9
    ret
.last:
    mov rdx, rcx
    mov rcx, r8
    call cfg_trim
    xor edx, edx
    ret

; -----------------------------------------------------------------------------
; cfg_parse — walk all lines and report "name = value" pairs.
;   in:  rcx = text (zero-terminated, modified), rdx = callback,
;        r8 = user value passed to the callback, r9 = label for warnings
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC cfg_parse, 0
    INVOKE cfg_parse_ex, rcx, rdx, r8, r9, 0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; cfg_parse_ex — cfg_parse with flags (bit 0: report "[header]" lines).
;   in:  rcx = text, rdx = callback, r8 = user, r9 = label, ARG(5) = flags
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC cfg_parse_ex, 16, rbx, rsi, rdi, r12, r13, r14, r15
    mov rax, [ARG(5)]
    mov [LOCAL(8)], rax                 ; flags
    mov rsi, rcx                        ; line start
    mov r13, rdx                        ; callback
    mov r14, r8                         ; user
    mov r15, r9                         ; label
.line:
    cmp byte [rsi], 0
    je .done
    mov rdi, rsi
.eol:
    mov al, [rdi]
    test al, al
    jz .have_eol
    cmp al, 10
    je .have_eol
    inc rdi
    jmp .eol
.have_eol:
    mov rbx, rdi                        ; rbx = original line end
    movzx eax, byte [rdi]
    mov [LOCAL(0)], rax                 ; 10 = more lines follow, 0 = last
    mov byte [rdi], 0
    ; cut comment
    mov rcx, rsi
.hash:
    cmp rcx, rdi
    jae .no_hash
    cmp byte [rcx], '#'
    je .cut
    inc rcx
    jmp .hash
.cut:
    mov byte [rcx], 0
    mov rdi, rcx
.no_hash:
    mov r12, rsi
.eq:
    cmp r12, rdi
    jae .no_eq
    cmp byte [r12], '='
    je .have_eq
    inc r12
    jmp .eq
.no_eq:
    INVOKE cfg_trim, rsi, rdi
    cmp byte [rax], 0
    je .next
    test qword [LOCAL(8)], 1
    jz .warn_line
    cmp byte [rax], '['
    jne .warn_line
    ; "[header]": strip the brackets
    mov rcx, rax
    call str_len_local
    lea rdx, [rcx + rax]                ; end
    cmp byte [rdx - 1], ']'
    jne .warn_line_rcx
    inc rcx
    dec rdx
    call cfg_trim
    mov rcx, rax
    xor edx, edx
    mov r8, r14
    call r13
    jmp .next
.warn_line_rcx:
    mov rax, rcx
.warn_line:
    lea rdx, [rel str_no_eq]
    INVOKE cfg_warn, r15, rdx, rax
    jmp .next
.have_eq:
    INVOKE cfg_trim, rsi, r12
    mov rsi, rax                        ; name
    lea rcx, [r12 + 1]
    INVOKE cfg_trim, rcx, rdi           ; value in rax
    mov rcx, rsi
    mov rdx, rax
    mov r8, r14
    call r13
.next:
    cmp qword [LOCAL(0)], 0
    je .done
    lea rsi, [rbx + 1]
    jmp .line
.done:
    RETURN
ENDPROC
