; =============================================================================
; cpu.asm — CPU feature detection (CPUID/XGETBV) and core count.
;
; Public API:
;   cpu_detect() -> eax 1 if the baseline (SSE4.2) is present, else 0
;   g_cpu_sse42, g_cpu_avx2 (1/0, AVX2 also requires OS YMM support),
;   g_cpu_logical (logical processors in all groups), g_cpu_brand
; =============================================================================
%include "macros.inc"
%include "log.inc"

global cpu_detect, g_cpu_sse42, g_cpu_avx2, g_cpu_logical, g_cpu_brand

IMPORT GetActiveProcessorCount

%define ALL_PROCESSOR_GROUPS    0xFFFF

section .rdata
str_cpu:        db "cpu: ", 0
str_threads:    db ", logical processors ", 0
str_sse42:      db ", SSE4.2 ", 0
str_avx2:       db ", AVX2 ", 0
str_yes:        db "yes", 0
str_no:         db "no", 0

section .bss
alignb 4
g_cpu_sse42:    resd 1
g_cpu_avx2:     resd 1
g_cpu_logical:  resd 1
g_cpu_brand:    resb 64

section .text

; -----------------------------------------------------------------------------
; append_yes_no — log_append "yes"/"no".
;   in:  ecx = flag
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC append_yes_no, 0
    lea rax, [rel str_no]
    lea rdx, [rel str_yes]
    test ecx, ecx
    cmovnz rax, rdx
    mov rcx, rax
    call log_append_str
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; cpu_detect — fill the g_cpu_* globals and log them.
;   out: eax = 1 if SSE4.2 is available (required baseline), else 0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC cpu_detect, 0, rbx, rsi, rdi
    ; leaf 1: SSE4.2 (ecx 20), OSXSAVE (ecx 27), AVX (ecx 28)
    mov eax, 1
    xor ecx, ecx
    cpuid
    mov esi, ecx
    xor eax, eax
    bt esi, 20
    setc al
    mov [rel g_cpu_sse42], eax
    ; AVX2 needs: CPUID.7.0:EBX[5], AVX, OSXSAVE and XCR0 bits 1+2 (SSE+YMM)
    xor edi, edi
    bt esi, 27
    jnc .no_avx2
    bt esi, 28
    jnc .no_avx2
    xor ecx, ecx
    xgetbv
    and eax, 6
    cmp eax, 6
    jne .no_avx2
    mov eax, 7
    xor ecx, ecx
    cpuid
    bt ebx, 5
    jnc .no_avx2
    mov edi, 1
.no_avx2:
    mov [rel g_cpu_avx2], edi

    ; brand string: leaves 0x80000002..4 (if supported)
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .no_brand
    lea rsi, [rel g_cpu_brand]
    mov edi, 0x80000002
.brand:
    mov eax, edi
    cpuid
    mov [rsi], eax
    mov [rsi + 4], ebx
    mov [rsi + 8], ecx
    mov [rsi + 12], edx
    add rsi, 16
    inc edi
    cmp edi, 0x80000004
    jbe .brand
    mov byte [rsi], 0
.no_brand:

    API GetActiveProcessorCount, ALL_PROCESSOR_GROUPS
    test eax, eax
    jnz .count_ok
    mov eax, 1
.count_ok:
    mov [rel g_cpu_logical], eax

    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_cpu]
    call log_append_str
    ; skip leading spaces some CPUs put in the brand string
    lea rcx, [rel g_cpu_brand]
.trim:
    cmp byte [rcx], ' '
    jne .trimmed
    inc rcx
    jmp .trim
.trimmed:
    call log_append_str
    lea rcx, [rel str_threads]
    call log_append_str
    mov ecx, [rel g_cpu_logical]
    call log_append_dec
    lea rcx, [rel str_sse42]
    call log_append_str
    mov ecx, [rel g_cpu_sse42]
    call append_yes_no
    lea rcx, [rel str_avx2]
    call log_append_str
    mov ecx, [rel g_cpu_avx2]
    call append_yes_no
    call log_end

    mov eax, [rel g_cpu_sse42]
    RETURN
ENDPROC
