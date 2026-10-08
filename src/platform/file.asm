; =============================================================================
; file.asm — whole-file reads, file timestamps and the game's root directory.
;
; Public API (see include/file.inc):
;   paths_init() -> eax 1/0          find the root dir that contains data\
;   path_make(dst, rel)              dst = root + rel (dst >= PATH_CAP bytes)
;   file_read_all(path, buf, cap) -> rax bytes (or -1); buf zero-terminated
;   file_load(path, arena) -> rax ptr (0 on failure), rdx size; the data is
;                                    zero-terminated and lives in the arena
;   file_mtime(path) -> rax          last-write FILETIME, 0 if missing
;   g_root_dir                       root path with trailing separator
; =============================================================================
%define FILE_IMPL
%include "macros.inc"
%include "win32.inc"
%include "log.inc"
%include "file.inc"
%include "memory.inc"

global paths_init, path_make, file_read_all, file_load, file_mtime, g_root_dir

extern str_copy

IMPORT GetModuleFileNameA, GetFileAttributesA, GetFileAttributesExA
IMPORT CreateFileA, ReadFile, CloseHandle, GetFileSizeEx

%define GENERIC_READ                0x80000000
%define FILE_SHARE_WRITE            0x00000002
%define FILE_SHARE_DELETE           0x00000004
%define OPEN_EXISTING               3
%define FILE_ATTRIBUTE_DIRECTORY    0x10
%define INVALID_FILE_ATTRIBUTES     0xFFFFFFFF

section .rdata
str_data_dir:       db "data", 0
str_up_two:         db "..\..\", 0
str_root_is:        db "game root: ", 0
str_read_fail:      db "could not read file: ", 0

section .bss
g_root_dir:         resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; is_data_root — does "<dir>data" exist as a directory?
;   in:  rcx = directory with trailing separator (zero-terminated)
;   out: eax = 1 if yes
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC is_data_root, PATH_CAP
    lea rdx, [rcx]
    lea rcx, [LOCAL(0)]
    call str_copy
    lea rdx, [rel str_data_dir]
    INVOKE str_copy, rax, rdx
    lea rcx, [LOCAL(0)]
    API GetFileAttributesA, rcx
    cmp eax, INVALID_FILE_ATTRIBUTES
    je .no
    test eax, FILE_ATTRIBUTE_DIRECTORY
    jz .no
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; paths_init — set g_root_dir: the exe's folder if it contains data\ (the
; packaged layout), else two levels up (the build\<config>\ dev layout).
;   in:  none
;   out: eax = 1 if a root with data\ was found, 0 otherwise
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC paths_init, 0, rbx
    lea rbx, [rel g_root_dir]
    API GetModuleFileNameA, 0, rbx, PATH_CAP - 16
    ; cut after the last separator
    mov rcx, rbx
    mov rdx, rbx
.scan:
    mov al, [rcx]
    test al, al
    jz .cut
    inc rcx
    cmp al, '\'
    je .sep
    cmp al, '/'
    jne .scan
.sep:
    mov rdx, rcx
    jmp .scan
.cut:
    mov byte [rdx], 0
    mov rcx, rbx
    call is_data_root
    test eax, eax
    jnz .found
    ; dev layout: <root>\build\<config>\voxelb.exe
    mov rcx, rbx
.end:
    cmp byte [rcx], 0
    je .append
    inc rcx
    jmp .end
.append:
    lea rdx, [rel str_up_two]
    call str_copy
    mov rcx, rbx
    call is_data_root
    test eax, eax
    jnz .found
    LOG_ERROR "data folder not found next to the exe or two levels up"
    xor eax, eax
    RETURN
.found:
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_root_is]
    call log_append_str
    mov rcx, rbx
    call log_append_str
    call log_end
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; path_make — build an absolute path from a root-relative one.
;   in:  rcx = destination (PATH_CAP bytes), rdx = relative path (forward
;        slashes are fine; Windows accepts them)
;   out: rax = pointer to the terminator in the destination
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC path_make, 0, rbx
    mov rbx, rdx
    lea rdx, [rel g_root_dir]
    call str_copy
    INVOKE str_copy, rax, rbx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; file_read_all — read a whole file into a buffer and zero-terminate it.
;   in:  rcx = path, rdx = buffer, r8 = buffer capacity (incl. terminator)
;   out: rax = bytes read, or -1 on failure (missing, locked, too large)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC file_read_all, 16, rbx, rsi, rdi, r12
    mov rbx, rcx                        ; path
    mov rsi, rdx                        ; buffer
    lea rdi, [r8 - 1]                   ; max bytes
    API CreateFileA, rbx, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0
    cmp rax, INVALID_HANDLE_VALUE
    je .fail
    mov r12, rax
    mov dword [LOCAL(0)], 0
    lea r9, [LOCAL(0)]
    API ReadFile, r12, rsi, rdi, r9, 0
    mov ebx, eax
    API CloseHandle, r12
    test ebx, ebx
    jz .fail
    mov eax, [LOCAL(0)]
    cmp rax, rdi
    jae .fail                           ; filled the buffer: probably truncated
    mov byte [rsi + rax], 0
    RETURN
.fail:
    mov rax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; file_load — read a whole file into memory allocated from an arena.
;   in:  rcx = path, rdx = ARENA*
;   out: rax = data (zero-terminated), rdx = size in bytes;
;        rax = 0 on failure (missing/locked file, > 1 GB, arena full)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC file_load, 16, rbx, rsi, rdi, r12, r13
    mov rbx, rcx                        ; path
    mov r13, rdx                        ; arena
    API CreateFileA, rbx, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0
    cmp rax, INVALID_HANDLE_VALUE
    je .fail
    mov r12, rax                        ; handle
    lea rdx, [LOCAL(0)]
    API GetFileSizeEx, r12, rdx
    test eax, eax
    jz .fail_close
    mov rsi, [LOCAL(0)]                 ; size
    cmp rsi, GB(1)
    ja .fail_close
    lea rdx, [rsi + 1]
    INVOKE arena_try_alloc, r13, rdx, 16
    test rax, rax
    jz .fail_close
    mov rdi, rax                        ; buffer
    mov dword [LOCAL(8)], 0
    lea r9, [LOCAL(8)]
    API ReadFile, r12, rdi, rsi, r9, 0
    mov ebx, eax
    API CloseHandle, r12
    test ebx, ebx
    jz .fail
    mov eax, [LOCAL(8)]
    cmp rax, rsi
    jne .fail                           ; short read
    mov byte [rdi + rsi], 0
    mov rax, rdi
    mov rdx, rsi
    RETURN
.fail_close:
    API CloseHandle, r12
.fail:
    xor eax, eax
    xor edx, edx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; file_mtime — last-write time of a file.
;   in:  rcx = path
;   out: rax = FILETIME as u64, or 0 if the file cannot be queried
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC file_mtime, 48
    lea r8, [LOCAL(0)]
    API GetFileAttributesExA, rcx, 0, r8
    test eax, eax
    jz .none
    mov rax, [LOCAL(20)]                ; ftLastWriteTime
    RETURN
.none:
    xor eax, eax
    RETURN
ENDPROC
