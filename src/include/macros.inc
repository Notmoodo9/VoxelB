; =============================================================================
; macros.inc — core assembler macros shared by every module.
;
; Provides:
;   PROC / RETURN / ENDPROC   Win64-ABI prologue/epilogue with saved registers
;   LOCAL(off)                address of a local variable inside a PROC frame
;   ARG(n)                    address of incoming stack argument n (n >= 5)
;   INVOKE target, args...    call an internal routine with Win64 arguments
;   API name, args...         call an imported Win32 function (__imp_name)
;   IMPORT name, ...          declare imported Win32 functions
;   ASSERT cc, "message"      debug-only assertion on a condition code
;
; Frame layout produced by PROC (rsp is 16-byte aligned for the whole body):
;
;   [rbp + 16 + 8*k]   caller shadow space / stack args (ARG(5) = rbp+48)
;   [rbp + 8]          return address
;   [rbp]              saved rbp
;   [rbp - 8*n]        saved nonvolatile registers (n = count)
;   ...                locals          -> LOCAL(0) .. LOCAL(locals-1)
;   [rsp + 32 .. +95]  outgoing stack arguments 5..12
;   [rsp + 0  .. +31]  outgoing shadow space
;
; Rules:
;   * Do not change rsp inside a PROC body (LOCAL() is rsp-relative).
;   * INVOKE/API load stack args (5+) first through r11, then rcx/rdx/r8/r9.
;     Never pass r11 as an argument, and never pass rcx/rdx/r8/r9 as a
;     source for a *different* argument slot that is filled earlier.
;   * Arguments are moved with `mov`, so label operands become absolute
;     (relocated) addresses. Use `lea` into a register first if you prefer.
;   * XMM6-XMM15 are not saved automatically; spill them to locals by hand.
; =============================================================================
%ifndef MACROS_INC
%define MACROS_INC

bits 64
default rel

%ifndef BUILD_DEBUG
    %define BUILD_DEBUG 0
%endif

%define SHADOW_SPACE    32
%define MAX_STACK_ARGS  8
%define OUTGOING_SIZE   (SHADOW_SPACE + MAX_STACK_ARGS * 8)
%define ALIGN16(x)      (((x) + 15) & ~15)
%define LOCAL(x)        rsp + OUTGOING_SIZE + (x)
%define ARG(n)          rbp + 16 + ((n) - 1) * 8

; -----------------------------------------------------------------------------
; PUSHREGS / POPREGS reg, reg, ...   push in order / pop in reverse order
; -----------------------------------------------------------------------------
%macro PUSHREGS 0-*
    %rep %0
        push %1
        %rotate 1
    %endrep
%endmacro

%macro POPREGS 0-*
    %rep %0
        %rotate -1
        pop %1
    %endrep
%endmacro

; -----------------------------------------------------------------------------
; PROC name, locals_bytes [, nonvolatile regs to save ...]
; -----------------------------------------------------------------------------
%macro PROC 2-*
    %push proc
    %1:
    push rbp
    mov rbp, rsp
    %assign %$nregs %0 - 2
    %if %0 > 2
        %define %$regs %{3:-1}
        PUSHREGS %{3:-1}
    %endif
    %assign %$frame ALIGN16((%2) + OUTGOING_SIZE + %$nregs * 8) - %$nregs * 8
    sub rsp, %$frame
%endmacro

; RETURN — epilogue; may appear several times inside one PROC.
%macro RETURN 0
    lea rsp, [rbp - %$nregs * 8]
    %if %$nregs > 0
        POPREGS %$regs
    %endif
    pop rbp
    ret
%endmacro

%macro ENDPROC 0
    %pop proc
%endmacro

; -----------------------------------------------------------------------------
; Argument loading for INVOKE / API.
; -----------------------------------------------------------------------------
%macro SETREG 2
    %ifnidni %1, %2
        mov %1, %2
    %endif
%endmacro

%macro SETARGS 0-*
    %if %0 > 12
        %error "too many call arguments (max 12)"
    %endif
    ; pass 1: stack arguments 5..n
    %assign %%i 0
    %rep %0
        %if %%i >= 4
            mov r11, %1
            mov [rsp + SHADOW_SPACE + (%%i - 4) * 8], r11
        %endif
        %assign %%i %%i + 1
        %rotate 1
    %endrep
    ; pass 2: register arguments 1..4
    %assign %%i 0
    %rep %0
        %if %%i == 0
            SETREG rcx, %1
        %elif %%i == 1
            SETREG rdx, %1
        %elif %%i == 2
            SETREG r8, %1
        %elif %%i == 3
            SETREG r9, %1
        %endif
        %assign %%i %%i + 1
        %rotate 1
    %endrep
%endmacro

; INVOKE target [, args...]   — call internal routine
%macro INVOKE 1-*
    %if %0 > 1
        SETARGS %{2:-1}
    %endif
    call %1
%endmacro

; API name [, args...]        — call imported Win32 function
%macro API 1-*
    %if %0 > 1
        SETARGS %{2:-1}
    %endif
    call [rel __imp_%1]
%endmacro

; IMPORT name, ...            — declare Win32 imports
%macro IMPORT 1-*
    %rep %0
        extern __imp_%1
        %rotate 1
    %endrep
%endmacro

; -----------------------------------------------------------------------------
; Inline zero-terminated string constant. Usage:  STR my_label, "text"
; Emits the string into .rdata and returns to .text.
; -----------------------------------------------------------------------------
%macro STR 2+
    [section .rdata]
    %1: db %2, 0
    __?SECT?__
%endmacro

; -----------------------------------------------------------------------------
; ASSERT cc, "message"  — debug builds only. Fails when condition cc is FALSE.
; Example:  test rax, rax / ASSERT nz, "pointer must not be null"
; -----------------------------------------------------------------------------
%ifndef LOG_IMPL
extern assert_fail
%endif
%macro ASSERT_AT 4+                     ; file, line, cc, message
    %if BUILD_DEBUG
        j%+3 %%ok
        [section .rdata]
        %%file: db %1, 0
        %%msg:  db %4, 0
        __?SECT?__
        lea rcx, [rel %%file]
        mov edx, %2
        lea r8, [rel %%msg]
        call assert_fail
    %%ok:
    %endif
%endmacro
; single-line wrapper so __?FILE?__/__?LINE?__ expand at the call site
%define ASSERT ASSERT_AT __?FILE?__, __?LINE?__,

%endif
