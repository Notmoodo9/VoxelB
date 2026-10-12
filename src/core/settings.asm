; =============================================================================
; settings.asm — graphics settings from data/config/graphics.cfg.
;
; Loaded once at start-up, before the world and the streamer, because both
; the block registry (opaque_leaves) and the streamer (render_distance) use
; them. Restart after editing.
;
; Public API:
;   settings_load()              parse the file (missing file: defaults)
;   g_render_distance (u32)      full-detail view distance in chunks, 2..48
;   g_opaque_leaves (u32)        1 = draw leaves as solid cubes (low-end)
;   g_gpu_culling (u32)          1 = cull the draws in a compute shader
;   g_occlusion_culling (u32)    1 = Hi-Z occlusion culling (needs gpu_culling)
;   g_lod_distance (u32)         LOD terrain out to this many chunks, 0..256
;                                (0 or <= render_distance: no LOD)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"

global settings_load, g_render_distance, g_opaque_leaves
global g_gpu_culling, g_occlusion_culling, g_lod_distance

extern str_ieq, str_parse_u64

%define MIN_DISTANCE        2
%define MAX_DISTANCE        48
%define MAX_LOD_DISTANCE    256

section .rdata
str_cfg_path:   db "data/config/graphics.cfg", 0
str_cfg_label:  db "graphics.cfg", 0
k_distance:     db "render_distance", 0
k_leaves:       db "opaque_leaves", 0
k_gpu_cull:     db "gpu_culling", 0
k_occlusion:    db "occlusion_culling", 0
k_lod:          db "lod_distance", 0
str_unknown:    db "unknown setting: ", 0
str_bad:        db "bad value for: ", 0

section .data
align 4
g_render_distance:  dd 16
g_opaque_leaves:    dd 0
g_gpu_culling:      dd 1
g_occlusion_culling: dd 1
g_lod_distance:     dd 64

section .bss
alignb 8
g_cfg_mark:     resq 1
g_cfg_path:     resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; graphics_pair — cfg_parse callback for graphics.cfg.
;   in:  rcx = name, rdx = value
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC graphics_pair, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    lea rdx, [rel k_distance]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .distance
    lea rdx, [rel k_leaves]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .leaves
    lea rdx, [rel k_gpu_cull]
    INVOKE str_ieq, rbx, rdx
    lea rdi, [rel g_gpu_culling]
    test eax, eax
    jnz .flag
    lea rdx, [rel k_occlusion]
    INVOKE str_ieq, rbx, rdx
    lea rdi, [rel g_occlusion_culling]
    test eax, eax
    jnz .flag
    lea rdx, [rel k_lod]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .lod
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_unknown]
    INVOKE cfg_warn, rcx, rdx, rbx
    RETURN
.distance:
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp eax, MIN_DISTANCE
    jb .bad
    cmp eax, MAX_DISTANCE
    ja .bad
    mov [rel g_render_distance], eax
    RETURN
.lod:
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp eax, MAX_LOD_DISTANCE
    ja .bad
    mov [rel g_lod_distance], eax
    RETURN
.leaves:
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp eax, 1
    ja .bad
    mov [rel g_opaque_leaves], eax
    RETURN
.flag:                                  ; 0 / 1 into [rdi]
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp eax, 1
    ja .bad
    mov [rdi], eax
    RETURN
.bad:
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_bad]
    INVOKE cfg_warn, rcx, rdx, rbx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; settings_load — read graphics.cfg into the globals above.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC settings_load, 0
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [rel g_cfg_mark], rax
    lea rcx, [rel g_cfg_path]
    lea rdx, [rel str_cfg_path]
    call path_make
    lea rcx, [rel g_cfg_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .no_cfg
    lea rdx, [rel graphics_pair]
    lea r9, [rel str_cfg_label]
    INVOKE cfg_parse, rax, rdx, 0, r9
    jmp .done
.no_cfg:
    LOG_WARN "data/config/graphics.cfg missing; using defaults"
.done:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [rel g_cfg_mark]
    mov eax, [rel g_render_distance]
    LOG_VAL LOG_LEVEL_INFO, "settings: render distance (chunks)", rax
    mov eax, [rel g_opaque_leaves]
    LOG_VAL LOG_LEVEL_INFO, "settings: opaque leaves", rax
    mov eax, [rel g_lod_distance]
    LOG_VAL LOG_LEVEL_INFO, "settings: LOD distance (chunks)", rax
    RETURN
ENDPROC
