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
;   g_smooth_lighting (u32)      1 = corner lights mixed across faces
;   g_ambient_occlusion (u32)    1 = darker inner corners
;   g_held_light (u32)           the held light's r | g << 8 | b << 16 (0..15)
;   g_bloom (u32)                1 = bloom (milestone 14)
;   g_height_fog (u32)           1 = height fog in low ground
;   g_shadows (u32)              1 = cascaded shadow maps (milestone 14 part 2)
;   g_clouds (u32)               1 = the cloud layer
;   g_water_quality (u32)        0 simple water, 1 refraction and depth colour,
;                                2 + reflections (milestone 15)
;   g_shadow_res (u32)           shadow map size, 512..4096 (power of two)
;   g_shadow_distance (u32)      shadows out to this many blocks, 32..512
;                                (0 or <= render_distance: no LOD)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"

global settings_load, g_render_distance, g_opaque_leaves
global g_gpu_culling, g_occlusion_culling, g_lod_distance
global g_smooth_lighting, g_ambient_occlusion, g_held_light, g_bloom, g_height_fog
global g_shadows, g_shadow_res, g_shadow_distance, g_clouds, g_water_quality

extern str_ieq, str_parse_u64, cfg_next_token

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
k_smooth:       db "smooth_lighting", 0
k_ao:           db "ambient_occlusion", 0
k_held:         db "held_light", 0
k_bloom:        db "bloom", 0
k_hfog:         db "height_fog", 0
k_shadows:      db "shadows", 0
k_clouds:       db "clouds", 0
k_water:        db "water_quality", 0
k_shadow_res:   db "shadow_resolution", 0
k_shadow_dist:  db "shadow_distance", 0
str_unknown:    db "unknown setting: ", 0
str_bad:        db "bad value for: ", 0

section .data
align 4
g_render_distance:  dd 16
g_opaque_leaves:    dd 0
g_gpu_culling:      dd 1
g_occlusion_culling: dd 1
g_lod_distance:     dd 64
g_smooth_lighting:  dd 1
g_ambient_occlusion: dd 1
g_held_light:       dd 14 | (11 << 8) | (6 << 16)   ; a warm torch
g_bloom:            dd 1
g_height_fog:       dd 1
g_shadows:          dd 1
g_clouds:           dd 1
g_water_quality:    dd 2
g_shadow_res:       dd 2048
g_shadow_distance:  dd 160

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
PROC graphics_pair, 0, rbx, rsi, rdi, r12
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
    lea rdx, [rel k_smooth]
    INVOKE str_ieq, rbx, rdx
    lea rdi, [rel g_smooth_lighting]
    test eax, eax
    jnz .flag
    lea rdx, [rel k_ao]
    INVOKE str_ieq, rbx, rdx
    lea rdi, [rel g_ambient_occlusion]
    test eax, eax
    jnz .flag
    lea rdx, [rel k_held]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .held
    lea rdx, [rel k_bloom]
    INVOKE str_ieq, rbx, rdx
    lea rdi, [rel g_bloom]
    test eax, eax
    jnz .flag
    lea rdx, [rel k_hfog]
    INVOKE str_ieq, rbx, rdx
    lea rdi, [rel g_height_fog]
    test eax, eax
    jnz .flag
    lea rdx, [rel k_shadows]
    INVOKE str_ieq, rbx, rdx
    lea rdi, [rel g_shadows]
    test eax, eax
    jnz .flag
    lea rdx, [rel k_clouds]
    INVOKE str_ieq, rbx, rdx
    lea rdi, [rel g_clouds]
    test eax, eax
    jnz .flag
    lea rdx, [rel k_water]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .water
    lea rdx, [rel k_shadow_res]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .shadow_res
    lea rdx, [rel k_shadow_dist]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .shadow_dist
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
.held:                                  ; held_light = r, g, b (0..15)
    xor edi, edi                        ; packed
    xor r12d, r12d                      ; channel
.held_ch:
    test rsi, rsi
    jz .held_bad
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    mov rcx, rax
    call str_parse_u64
    test r8, r8
    jz .held_bad
    cmp rax, 15
    ja .held_bad
    lea ecx, [r12d * 8]
    shl eax, cl
    or edi, eax
    inc r12d
    cmp r12d, 3
    jb .held_ch
    mov [rel g_held_light], edi
    RETURN
.held_bad:
    jmp .bad
.shadow_res:                            ; 512, 1024, 2048 or 4096
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, 512
    jb .bad
    cmp rax, 4096
    ja .bad
    lea rcx, [rax - 1]
    test rax, rcx
    jnz .bad                            ; (not a power of two)
    mov [rel g_shadow_res], eax
    RETURN
.water:                                 ; 0, 1 or 2
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, 2
    ja .bad
    mov [rel g_water_quality], eax
    RETURN
.shadow_dist:
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, 32
    jb .bad
    cmp rax, 512
    ja .bad
    mov [rel g_shadow_distance], eax
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
