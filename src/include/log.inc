; =============================================================================
; log.inc — logging interface (implementation: src/core/log.asm).
;
;   LOG_INFO  "text"            one line at INFO level
;   LOG_WARN  "text"
;   LOG_ERROR "text"
;   LOG_DEBUG "text"            compiled out of release builds
;   LOG_VAL   level, "text", value   "text <decimal value>"
;   LOG_HEX   level, "text", value   "text 0x<hex value>"
;   (LOG_VAL/LOG_HEX at LOG_LEVEL_DEBUG are compiled out of release builds)
;
; All macros clobber the volatile registers (rax, rcx, rdx, r8-r11).
; The value operand of LOG_VAL/LOG_HEX is loaded into r8 *before* rcx/rdx,
; so any register (including rcx/rdx) may be passed as the value.
; =============================================================================
%ifndef LOG_INC
%define LOG_INC

%define LOG_LEVEL_DEBUG 0
%define LOG_LEVEL_INFO  1
%define LOG_LEVEL_WARN  2
%define LOG_LEVEL_ERROR 3

%ifndef LOG_IMPL                        ; defined by log.asm itself
extern log_init, log_shutdown
extern log_msg, log_val, log_hex
extern log_begin, log_append_str, log_append_dec, log_append_hex, log_end
extern log_fatal
%endif

%macro LOG_AT 2+
    [section .rdata]
    %%s: db %2, 0
    __?SECT?__
    lea rdx, [rel %%s]
    mov ecx, %1
    call log_msg
%endmacro

%macro LOG_INFO 1+
    LOG_AT LOG_LEVEL_INFO, %1
%endmacro
%macro LOG_WARN 1+
    LOG_AT LOG_LEVEL_WARN, %1
%endmacro
%macro LOG_ERROR 1+
    LOG_AT LOG_LEVEL_ERROR, %1
%endmacro
%macro LOG_DEBUG 1+
    %if BUILD_DEBUG
        LOG_AT LOG_LEVEL_DEBUG, %1
    %endif
%endmacro

%macro LOG_VAL 3
    %if ((%1) != LOG_LEVEL_DEBUG) || BUILD_DEBUG
        [section .rdata]
        %%s: db %2, 0
        __?SECT?__
        SETREG r8, %3
        lea rdx, [rel %%s]
        mov ecx, %1
        call log_val
    %endif
%endmacro

%macro LOG_HEX 3
    %if ((%1) != LOG_LEVEL_DEBUG) || BUILD_DEBUG
        [section .rdata]
        %%s: db %2, 0
        __?SECT?__
        SETREG r8, %3
        lea rdx, [rel %%s]
        mov ecx, %1
        call log_hex
    %endif
%endmacro

%endif
