; =============================================================================
; cfg_write.asm — write settings back into a data file (milestone 17: the
; settings screen), keeping everything else in it: comments, blank lines,
; the order of the keys, a comment after a value, unknown keys. Only the
; value text of the listed keys is replaced; listed keys the file lacks are
; appended. The new file replaces the old one through a .tmp file and a
; rename, so a crash never leaves half a file.
;
; Public API (declared in cfg.inc):
;   cfg_rewrite(rcx = root-relative path, rdx = CFGW[], r8d = count) -> eax 1/0
;       CFGW: {key, formatter, arg}; formatter(rcx = cursor, rdx = arg)
;       writes the value text and returns rax = the new cursor (at its
;       terminator). At most CFGW_MAX entries.
;   cfgw_int(cursor, u32*)          "16"
;   cfgw_flag(cursor, f32*)         "1" if nonzero, else "0"
;   cfgw_hundredths(cursor, f32*)   "0.12" (two decimals)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"

global cfg_rewrite, cfgw_int, cfgw_flag, cfgw_hundredths

extern str_copy, str_len, str_append_dec

IMPORT CreateFileA, WriteFile, CloseHandle, MoveFileExA

%define GENERIC_WRITE           0x40000000
%define CREATE_ALWAYS           2
%define FILE_ATTRIBUTE_NORMAL   0x80
%define MOVEFILE_REPLACE_EXISTING 1
%define CFGW_MAX                64
%define VALUE_ROOM              128     ; bytes per entry for its value text

section .rdata
str_tmp:        db ".tmp", 0
str_eq:         db " = ", 0
str_written:    db "settings: written ", 0
str_failed:     db "settings: could not write ", 0
align 4
c_hundred:      dd 100.0
c_round:        dd 0.5

section .bss
alignb 8
g_found:        resb CFGW_MAX
g_rpath:        resb PATH_CAP
g_tpath:        resb PATH_CAP + 8
g_written:      resd 1

section .text

; -----------------------------------------------------------------------------
; cfgw_int / cfgw_flag / cfgw_hundredths — value formatters (see header).
;   in:  rcx = cursor, rdx = pointer to the value
;   out: rax = new cursor
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC cfgw_int, 0
    mov edx, [rdx]
    xor r8d, r8d
    call str_append_dec
    RETURN
ENDPROC

PROC cfgw_flag, 0
    xor eax, eax
    xorps xmm0, xmm0
    ucomiss xmm0, [rdx]
    setne al
    mov edx, eax
    xor r8d, r8d
    call str_append_dec
    RETURN
ENDPROC

PROC cfgw_hundredths, 0
    movss xmm0, [rdx]
    mulss xmm0, [rel c_hundred]
    addss xmm0, [rel c_round]
    cvttss2si edx, xmm0
    test edx, edx
    jns .ok
    xor edx, edx
.ok:
    mov r8d, 2
    call str_append_dec
    RETURN
ENDPROC

; key_match — eax = 1 if the zero-terminated key [rcx] equals the r8d bytes
; at [rdx], ignoring ASCII case.   clobbers: rax, rcx, rdx, r8, r9
key_match:
.c:
    movzx eax, byte [rcx]
    test r8d, r8d
    jz .end
    test eax, eax
    jz .no
    movzx r9d, byte [rdx]
    or eax, 0x20                        ; (letters, '_' and digits survive)
    or r9d, 0x20
    cmp eax, r9d
    jne .no
    inc rcx
    inc rdx
    dec r8d
    jmp .c
.end:
    test eax, eax                       ; the key must end here too
    jnz .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; cfg_rewrite — see the header.
; -----------------------------------------------------------------------------
%define R_MARK      0
%define R_TEXT      8                   ; old text (0: no file yet)
%define R_OUT       16                  ; output start
%define R_KEYEND    24
%define R_HANDLE    32
%define R_LINE_END  40                  ; end of the line's content (before \r\n)
%define R_IDX       48
PROC cfg_rewrite, 64, rbx, rsi, rdi, r12, r13, r14, r15
    mov r12, rdx                        ; entries
    mov r13d, r8d                       ; count
    cmp r13d, CFGW_MAX
    jbe .count_ok
    mov r13d, CFGW_MAX
.count_ok:
    lea rbx, [rcx]
    lea rcx, [rel g_rpath]
    mov rdx, rbx
    call path_make
    lea rdi, [rel g_found]
    xor eax, eax
    mov ecx, CFGW_MAX
    rep stosb
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(R_MARK)], rax
    lea rcx, [rel g_rpath]
    lea rdx, [rel g_arena_scratch]
    call file_load
    mov [LOCAL(R_TEXT)], rax
    xor ebx, ebx                        ; old length
    test rax, rax
    jz .alloc
    mov rbx, rdx
.alloc:
    imul edx, r13d, VALUE_ROOM + 64
    add rdx, rbx
    add rdx, 256
    lea rcx, [rel g_arena_scratch]
    mov r8d, 16
    call arena_alloc
    test rax, rax
    jz .fail
    mov [LOCAL(R_OUT)], rax
    mov rdi, rax                        ; output cursor
    mov rsi, [LOCAL(R_TEXT)]            ; input cursor
    test rsi, rsi
    jz .append

    ; ---- line by line ----
.line:
    cmp byte [rsi], 0
    je .append
    ; the line's content end (before \r / \n) and its full end
    mov r14, rsi
.find_end:
    movzx eax, byte [r14]
    test eax, eax
    jz .ended
    cmp eax, 10
    je .ended
    cmp eax, 13
    je .ended
    inc r14
    jmp .find_end
.ended:
    mov [LOCAL(R_LINE_END)], r14
    ; key: first non-space; '#' or no '=' before '#': copy the line as is
    mov r15, rsi
.skip_lead:
    cmp r15, r14
    jae .verbatim
    cmp byte [r15], ' '
    je .lead_next
    cmp byte [r15], 9
    jne .lead_done
.lead_next:
    inc r15
    jmp .skip_lead
.lead_done:
    cmp byte [r15], '#'
    je .verbatim
    mov rax, r15
.find_eq:
    cmp rax, r14
    jae .verbatim
    movzx ecx, byte [rax]
    cmp ecx, '#'
    je .verbatim
    cmp ecx, '='
    je .have_eq
    inc rax
    jmp .find_eq
.have_eq:
    mov rbx, rax                        ; '='
    ; key end: back over spaces
    mov rcx, rax
.key_trim:
    cmp rcx, r15
    jbe .key_ready
    cmp byte [rcx - 1], ' '
    je .key_back
    cmp byte [rcx - 1], 9
    jne .key_ready
.key_back:
    dec rcx
    jmp .key_trim
.key_ready:
    mov [LOCAL(R_KEYEND)], rcx
    ; which entry?
    xor edx, edx
.entry:
    cmp edx, r13d
    jae .verbatim
    mov [LOCAL(R_IDX)], edx
    imul eax, edx, 24
    mov rcx, [r12 + rax]
    mov r8, [LOCAL(R_KEYEND)]
    sub r8, r15
    mov rdx, r15
    call key_match
    mov edx, [LOCAL(R_IDX)]
    test eax, eax
    jnz .matched
    inc edx
    jmp .entry
.matched:
    lea rax, [rel g_found]
    mov byte [rax + rdx], 1
    imul eax, edx, 24
    lea r15, [r12 + rax]                ; the entry
    ; value start: after '=' and its spaces
    lea rax, [rbx + 1]
.val_lead:
    cmp rax, r14
    jae .val_start
    cmp byte [rax], ' '
    je .val_lead_next
    cmp byte [rax], 9
    jne .val_start
.val_lead_next:
    inc rax
    jmp .val_lead
.val_start:
    mov rbx, rax                        ; value start
    ; value end: a '#' (a comment after the value) or the line end, then
    ; back over spaces
    mov rcx, rax
.val_scan:
    cmp rcx, r14
    jae .val_end
    cmp byte [rcx], '#'
    je .val_end
    inc rcx
    jmp .val_scan
.val_end:
    mov r8, rcx                         ; (where the rest of the line starts)
.val_trim:
    cmp r8, rbx
    jbe .val_trimmed
    cmp byte [r8 - 1], ' '
    je .val_back
    cmp byte [r8 - 1], 9
    jne .val_trimmed
.val_back:
    dec r8
    jmp .val_trim
.val_trimmed:
    mov [LOCAL(R_KEYEND)], r8           ; (reused: value end)
    ; copy [line start, value start)
    mov rcx, rbx
    sub rcx, rsi
    rep movsb
    mov rsi, rbx
    cmp byte [rdi - 1], '='
    jne .format
    mov byte [rdi], ' '
    inc rdi
.format:
    mov rcx, rdi
    mov rdx, [r15 + 16]
    call [r15 + 8]
    mov rdi, rax
    ; skip the old value; a comment straight after it keeps a space
    mov rsi, [LOCAL(R_KEYEND)]
    cmp rsi, r14
    jae .verbatim
    cmp byte [rsi], ' '
    je .verbatim
    cmp byte [rsi], 9
    je .verbatim
    mov byte [rdi], ' '
    inc rdi
    ; fall through: copy the rest of the line
.verbatim:
    ; copy [rsi, line end) and its line break
    mov rcx, r14
    sub rcx, rsi
    rep movsb
    cmp byte [rsi], 13
    jne .lf
    movsb
.lf:
    cmp byte [rsi], 10
    jne .line
    movsb
    jmp .line

    ; ---- keys the file did not have ----
.append:
    xor ebx, ebx
.missing:
    cmp ebx, r13d
    jae .write
    lea rax, [rel g_found]
    cmp byte [rax + rbx], 0
    jne .missing_next
    mov rax, [LOCAL(R_OUT)]
    cmp rdi, rax
    je .no_break
    cmp byte [rdi - 1], 10
    je .no_break
    mov byte [rdi], 10
    inc rdi
.no_break:
    imul eax, ebx, 24
    lea r15, [r12 + rax]
    mov rcx, rdi
    mov rdx, [r15]
    call str_copy
    mov rcx, rax
    lea rdx, [rel str_eq]
    call str_copy
    mov rcx, rax
    mov rdx, [r15 + 16]
    call [r15 + 8]
    mov byte [rax], 10
    lea rdi, [rax + 1]
.missing_next:
    inc ebx
    jmp .missing

    ; ---- the file: .tmp, then rename over the old one ----
.write:
    lea rcx, [rel g_tpath]
    lea rdx, [rel g_rpath]
    call str_copy
    mov rcx, rax
    lea rdx, [rel str_tmp]
    call str_copy
    lea rcx, [rel g_tpath]
    mov qword [rsp + 32], CREATE_ALWAYS
    mov qword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov qword [rsp + 48], 0
    mov edx, GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    call [rel __imp_CreateFileA]
    cmp rax, -1
    je .fail
    mov [LOCAL(R_HANDLE)], rax
    mov r8, rdi
    sub r8, [LOCAL(R_OUT)]
    lea r9, [rel g_written]
    mov qword [rsp + 32], 0
    API WriteFile, [LOCAL(R_HANDLE)], [LOCAL(R_OUT)], r8, r9
    mov ebx, eax
    API CloseHandle, [LOCAL(R_HANDLE)]
    test ebx, ebx
    jz .fail
    lea rcx, [rel g_tpath]
    lea rdx, [rel g_rpath]
    API MoveFileExA, rcx, rdx, MOVEFILE_REPLACE_EXISTING
    test eax, eax
    jz .fail
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_written]
    call log_append_str
    lea rcx, [rel g_rpath]
    call log_append_str
    call log_end
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(R_MARK)]
    mov eax, 1
    RETURN
.fail:
    mov ecx, LOG_LEVEL_WARN
    call log_begin
    lea rcx, [rel str_failed]
    call log_append_str
    lea rcx, [rel g_rpath]
    call log_append_str
    call log_end
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(R_MARK)]
    xor eax, eax
    RETURN
ENDPROC
