; =============================================================================
; block.asm — debug block table (Milestone 5).
;
; Holds the placeholder blocks declared by data/world/flat_test.cfg
; ("block = name, RRGGBB"): name, flat colour, opaque flag. Block 0 is air.
; Milestone 7 replaces this with the data-driven block registry + textures
; (the real block set is a design item, see design/BACKLOG.md).
;
; Public API:
;   blocks_init()                         air only
;   block_register(name, rgb) -> eax id (or 0 if the table is full)
;   block_find(name) -> eax id, or -1 if unknown ("air" -> 0)
;   g_block_count, g_block_names (qword ptrs), g_block_colors (u32 RGBA,
;   R in the low byte), g_block_opaque (byte per id, 64 KB table so any
;   u16 id can be looked up)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "world.inc"

global blocks_init, block_register, block_find
global g_block_count, g_block_names, g_block_colors, g_block_opaque

extern str_ieq, str_len, str_copy

section .rdata
str_air:        db "air", 0
str_registered: db "block registered: ", 0
str_id:         db " id ", 0

section .bss
alignb 4
g_block_count:  resd 1
alignb 8
g_block_names:  resq MAX_BLOCK_TYPES
alignb 16
g_block_colors: resd MAX_BLOCK_TYPES
alignb 16
g_block_opaque: resb 65536

section .text

; -----------------------------------------------------------------------------
; blocks_init — reset the table to just air (id 0, transparent).
;   clobbers: rax, rcx, rdi
; -----------------------------------------------------------------------------
PROC blocks_init, 0, rdi
    lea rdi, [rel g_block_opaque]
    xor eax, eax
    mov ecx, 65536 / 8
    rep stosq
    lea rax, [rel g_block_opaque]
    mov byte [rax + 0xFFFF], 1          ; mesher's "solid boundary" id
    lea rax, [rel str_air]
    mov [rel g_block_names], rax
    mov dword [rel g_block_colors], 0
    mov dword [rel g_block_count], 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; block_find — id of a block by name (case-insensitive).
;   in:  rcx = name
;   out: eax = id, or -1 if unknown
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC block_find, 0, rbx, rsi
    mov rsi, rcx
    xor ebx, ebx
.next:
    cmp ebx, [rel g_block_count]
    jae .none
    lea rax, [rel g_block_names]
    INVOKE str_ieq, [rax + rbx * 8], rsi
    test eax, eax
    jnz .found
    inc ebx
    jmp .next
.found:
    mov eax, ebx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; block_register — add an opaque block with a flat colour.
;   in:  rcx = name (copied), edx = colour 0xRRGGBB
;   out: eax = new id, or 0 if the table is full / name exists (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC block_register, 0, rbx, rsi, rdi
    mov rsi, rcx
    mov edi, edx
    call block_find
    cmp eax, -1
    je .new
    LOG_WARN "block declared twice; keeping the first definition"
    xor eax, eax
    RETURN
.new:
    mov ebx, [rel g_block_count]
    cmp ebx, MAX_BLOCK_TYPES
    jb .room
    LOG_WARN "debug block table full"
    xor eax, eax
    RETURN
.room:
    ; copy the name into the permanent arena
    mov rcx, rsi
    call str_len
    lea rdx, [rax + 1]
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, rdx, 1
    test rax, rax
    jz .fail
    lea rcx, [rel g_block_names]
    mov [rcx + rbx * 8], rax
    INVOKE str_copy, rax, rsi
    ; 0xRRGGBB -> RGBA bytes (R low), alpha 255
    mov eax, edi
    bswap eax                           ; BB GG RR 00 -> 00RRGGBB swapped
    shr eax, 8                          ; 0x00BBGGRR
    or eax, 0xFF000000
    lea rcx, [rel g_block_colors]
    mov [rcx + rbx * 4], eax
    lea rcx, [rel g_block_opaque]
    mov byte [rcx + rbx], 1
    inc dword [rel g_block_count]
    mov ecx, LOG_LEVEL_DEBUG
    call log_begin
    lea rcx, [rel str_registered]
    call log_append_str
    lea rcx, [rel g_block_names]
    mov rcx, [rcx + rbx * 8]
    call log_append_str
    lea rcx, [rel str_id]
    call log_append_str
    mov ecx, ebx
    call log_append_dec
    call log_end
    mov eax, ebx
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC
