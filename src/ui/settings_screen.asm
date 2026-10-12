; =============================================================================
; settings_screen.asm — the settings screen (milestone 17, design/ui/menus.md):
; tabs Graphics (presets Low / Medium / High / Ultra and every effect),
; Controls (rebind every action: two keys each; mouse sensitivity, invert)
; and Game (field of view, autosave, HUD). Opened from the main menu and the
; pause menu.
;
; Changes apply at once where they can (effects, shadows, FOV, keys); the
; render and LOD distances when the screen closes (the streamer rebuilds its
; rings). Closing writes what changed back into graphics.cfg, controls.cfg
; and game.cfg, keeping their comments (cfg_write.asm).
;
; The rows are tables (SROW): a label, the variable and how to step it, so a
; new setting is one line here plus its key in settings.asm.
;
; Public API:
;   settings_screen_open()
;   settings_screen_frame(ecx = canvas centre x) -> eax 1 when Done
;   settings_screen_back() -> eax 1 if Esc was used up here (it cancels a
;       key being rebound)
;   settings_screen_close()             apply and write back
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "input.inc"
%include "ui.inc"

global settings_screen_open, settings_screen_frame, settings_screen_back
global settings_screen_close

extern ui_button, ui_panel, ui_label, ui_text
extern g_ui_vh, g_ui_click
extern str_copy, str_append_dec
extern settings_save_graphics, settings_save_game, shadow_apply
extern stream_set_distance, lod_reset
extern g_render_distance, g_lod_distance, g_shadows, g_shadow_res
extern g_shadow_distance, g_water_quality, g_clouds, g_bloom, g_height_fog
extern g_smooth_lighting, g_ambient_occlusion, g_opaque_leaves
extern g_gpu_culling, g_occlusion_culling, g_fov, g_autosave_minutes
extern g_show_hud

; row kinds
%define SK_TOGGLE       0               ; u32 0/1
%define SK_RANGE        1               ; u32 min..max by step
%define SK_LIST         2               ; u32, one of a list of values
%define SK_HUND         3               ; f32 shown and stepped in hundredths
%define SK_FTOGGLE      4               ; f32 0.0 / 1.0

; what a change touches
%define G_GRAPHICS      1               ; graphics.cfg
%define G_SHADOWS       2               ; shadow maps (shadow_apply)
%define G_DISTANCE      4               ; render / LOD distance (on close)
%define G_GAME          8               ; game.cfg
%define G_CONTROLS      16              ; controls.cfg

%define TAB_GRAPHICS    0
%define TAB_CONTROLS    1
%define TAB_GAME        2
%define TAB_COUNT       3

%define PANEL_W         820
%define PANEL_H         640
%define ROW_STEP        46
%define VK_DELETE       0x2E

struc SROW
    .label      resq 1
    .var        resq 1
    .kind       resd 1
    .min        resd 1
    .max        resd 1
    .step       resd 1
    .list       resq 1                  ; SK_LIST: u32 values
    .names      resq 1                  ; names per list index / per value - min (0: numbers)
    .suffix     resq 1                  ; after a number (0: none)
    .group      resd 1
    .pad        resd 1
endstruc

; ROW label, var, kind, min, max, step, list, names, suffix, group
%macro ROW 10
    dq %1, %2
    dd %3, %4, %5, %6
    dq %7, %8, %9
    dd %10, 0
%endmacro

section .rdata
s_title:        db "Settings", 0
s_done:         db "Done", 0
s_tab0:         db "Graphics", 0
s_tab1:         db "Controls", 0
s_tab2:         db "Game", 0
s_preset:       db "Preset", 0
s_custom:       db "Custom", 0
s_p0:           db "Low", 0
s_p1:           db "Medium", 0
s_p2:           db "High", 0
s_p3:           db "Ultra", 0
s_on:           db "On", 0
s_off:          db "Off", 0
s_left:         db "<", 0
s_right:        db ">", 0
s_press:        db "Press a key", 0
s_keys_hint:    db "Click a key to change it, then press the new key (Delete: none, Esc: cancel)", 0
s_restart_hint: db "Fast leaves takes effect after a restart", 0
s_chunks:       db " chunks", 0
s_blocks:       db " blocks", 0
; graphics rows
l_render:       db "Render distance", 0
l_lod:          db "Far terrain", 0
l_shadows:      db "Shadows", 0
l_shadow_res:   db "Shadow detail", 0
l_shadow_dist:  db "Shadow distance", 0
l_water:        db "Water", 0
l_clouds:       db "Clouds", 0
l_bloom:        db "Bloom", 0
l_hfog:         db "Height fog", 0
l_smooth:       db "Smooth lighting", 0
l_ao:           db "Ambient occlusion", 0
l_leaves:       db "Fast leaves", 0
l_gpu:          db "GPU culling", 0
l_occl:         db "Occlusion culling", 0
; controls rows
l_sens:         db "Mouse sensitivity", 0
l_invert:       db "Invert mouse Y", 0
; game rows
l_fov:          db "Field of view", 0
l_autosave:     db "Autosave", 0
l_hud:          db "Show HUD", 0
; list names
n_lod0:         db "Off", 0
n_lod1:         db "32 chunks", 0
n_lod2:         db "48 chunks", 0
n_lod3:         db "64 chunks", 0
n_lod4:         db "96 chunks", 0
n_lod5:         db "128 chunks", 0
n_lod6:         db "192 chunks", 0
n_lod7:         db "256 chunks", 0
n_res0:         db "Low", 0
n_res1:         db "Medium", 0
n_res2:         db "High", 0
n_water0:       db "Simple", 0
n_water1:       db "Clear", 0
n_water2:       db "Reflective", 0
n_auto0:        db "Off", 0
n_auto1:        db "1 min", 0
n_auto2:        db "2 min", 0
n_auto3:        db "5 min", 0
n_auto4:        db "10 min", 0
n_auto5:        db "15 min", 0
n_auto6:        db "30 min", 0
; action names as shown (input.inc ACT_* order)
a_0:            db "Move forward", 0
a_1:            db "Move back", 0
a_2:            db "Move left", 0
a_3:            db "Move right", 0
a_4:            db "Up / jump", 0
a_5:            db "Down / sneak", 0
a_6:            db "Sprint", 0
a_7:            db "Debug overlay", 0
a_8:            db "Vsync", 0
a_9:            db "Reload shaders", 0
a_10:           db "Menu / pause", 0
a_11:           db "Held light", 0
a_12:           db "Fast time", 0
a_13:           db "Break block", 0
a_14:           db "Place block", 0
a_15:           db "Pick block", 0

align 8
tab_names:      dq s_tab0, s_tab1, s_tab2
preset_names:   dq s_p0, s_p1, s_p2, s_p3
action_names:   dq a_0, a_1, a_2, a_3, a_4, a_5, a_6, a_7, a_8, a_9, a_10
                dq a_11, a_12, a_13, a_14, a_15
%if ($ - action_names) / 8 != ACT_COUNT
    %error "action_names does not match ACT_COUNT"
%endif
lod_names:      dq n_lod0, n_lod1, n_lod2, n_lod3, n_lod4, n_lod5, n_lod6, n_lod7
res_names:      dq n_res0, n_res1, n_res2
water_names:    dq n_water0, n_water1, n_water2
auto_names:     dq n_auto0, n_auto1, n_auto2, n_auto3, n_auto4, n_auto5, n_auto6
align 4
lod_list:       dd 0, 32, 48, 64, 96, 128, 192, 256
res_list:       dd 1024, 2048, 4096
auto_list:      dd 0, 1, 2, 5, 10, 15, 30

align 8
; Graphics: 7 rows on the left, 7 on the right
rows_graphics:
    ROW l_render, g_render_distance, SK_RANGE, 4, 48, 2, 0, 0, s_chunks, G_GRAPHICS | G_DISTANCE
    ROW l_lod, g_lod_distance, SK_LIST, 0, 7, 0, lod_list, lod_names, 0, G_GRAPHICS | G_DISTANCE
    ROW l_shadows, g_shadows, SK_TOGGLE, 0, 1, 1, 0, 0, 0, G_GRAPHICS | G_SHADOWS
    ROW l_shadow_res, g_shadow_res, SK_LIST, 0, 2, 0, res_list, res_names, 0, G_GRAPHICS | G_SHADOWS
    ROW l_shadow_dist, g_shadow_distance, SK_RANGE, 64, 512, 32, 0, 0, s_blocks, G_GRAPHICS
    ROW l_water, g_water_quality, SK_RANGE, 0, 2, 1, 0, water_names, 0, G_GRAPHICS
    ROW l_clouds, g_clouds, SK_TOGGLE, 0, 1, 1, 0, 0, 0, G_GRAPHICS
    ROW l_bloom, g_bloom, SK_TOGGLE, 0, 1, 1, 0, 0, 0, G_GRAPHICS
    ROW l_hfog, g_height_fog, SK_TOGGLE, 0, 1, 1, 0, 0, 0, G_GRAPHICS
    ROW l_smooth, g_smooth_lighting, SK_TOGGLE, 0, 1, 1, 0, 0, 0, G_GRAPHICS
    ROW l_ao, g_ambient_occlusion, SK_TOGGLE, 0, 1, 1, 0, 0, 0, G_GRAPHICS
    ROW l_leaves, g_opaque_leaves, SK_TOGGLE, 0, 1, 1, 0, 0, 0, G_GRAPHICS
    ROW l_gpu, g_gpu_culling, SK_TOGGLE, 0, 1, 1, 0, 0, 0, G_GRAPHICS
    ROW l_occl, g_occlusion_culling, SK_TOGGLE, 0, 1, 1, 0, 0, 0, G_GRAPHICS
GRAPHICS_ROWS equ ($ - rows_graphics) / SROW_size
rows_controls:
    ROW l_sens, g_mouse_sensitivity, SK_HUND, 2, 100, 1, 0, 0, 0, G_CONTROLS
    ROW l_invert, g_invert_mouse_y, SK_FTOGGLE, 0, 1, 1, 0, 0, 0, G_CONTROLS
rows_game:
    ROW l_fov, g_fov, SK_RANGE, 50, 110, 5, 0, 0, 0, G_GAME
    ROW l_autosave, g_autosave_minutes, SK_LIST, 0, 6, 0, auto_list, auto_names, 0, G_GAME
    ROW l_hud, g_show_hud, SK_TOGGLE, 0, 1, 1, 0, 0, 0, G_GAME
GAME_ROWS equ ($ - rows_game) / SROW_size

; presets: the values of these settings (in this order) for Low .. Ultra
preset_vars:    dq g_render_distance, g_lod_distance, g_smooth_lighting
                dq g_ambient_occlusion, g_bloom, g_height_fog, g_shadows
                dq g_shadow_res, g_shadow_distance, g_clouds, g_water_quality
PRESET_VARS equ ($ - preset_vars) / 8
align 4
presets:        dd  8,  32, 1, 0, 0, 0, 0, 1024,  96, 0, 0   ; Low
                dd 12,  48, 1, 1, 1, 1, 1, 1024, 128, 1, 1   ; Medium
                dd 16,  64, 1, 1, 1, 1, 1, 2048, 160, 1, 2   ; High
                dd 24, 128, 1, 1, 1, 1, 1, 4096, 256, 1, 2   ; Ultra
PRESET_COUNT equ 4
c_hundred:      dd 100.0
c_round:        dd 0.5
c_one:          dd 1.0

section .bss
alignb 4
g_tab:          resd 1
g_dirty:        resd 1                  ; G_* touched since opening
g_wait_action:  resd 1                  ; action being rebound, -1 none
g_wait_slot:    resd 1
g_wait_armed:   resd 1                  ; (from the frame after the click)
g_old_render:   resd 1
g_old_lod:      resd 1
g_text:         resb 48

section .text

; -----------------------------------------------------------------------------
; settings_screen_open — start with nothing changed.
;   clobbers: rax
; -----------------------------------------------------------------------------
settings_screen_open:
    mov dword [rel g_dirty], 0
    mov dword [rel g_wait_action], -1
    mov eax, [rel g_render_distance]
    mov [rel g_old_render], eax
    mov eax, [rel g_lod_distance]
    mov [rel g_old_lod], eax
    ret

; settings_screen_back — Esc: cancel a rebinding (eax 1), else eax 0
settings_screen_back:
    xor eax, eax
    cmp dword [rel g_wait_action], 0
    jl .done
    mov dword [rel g_wait_action], -1
    mov eax, 1
.done:
    ret

; -----------------------------------------------------------------------------
; settings_screen_close — apply what waits for closing and write the files.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC settings_screen_close, 0, rbx
    mov dword [rel g_wait_action], -1
    mov ebx, [rel g_dirty]
    test ebx, G_DISTANCE
    jz .files
    mov eax, [rel g_render_distance]
    cmp eax, [rel g_old_render]
    je .lod
    call stream_set_distance
    jmp .lod_reset                      ; (the LOD rings start at the render distance)
.lod:
    mov eax, [rel g_lod_distance]
    cmp eax, [rel g_old_lod]
    je .files
.lod_reset:
    call lod_reset
.files:
    test ebx, G_GRAPHICS
    jz .controls
    call settings_save_graphics
.controls:
    test ebx, G_CONTROLS
    jz .game
    call input_save_bindings
.game:
    test ebx, G_GAME
    jz .done
    call settings_save_game
.done:
    mov dword [rel g_dirty], 0
    mov eax, [rel g_render_distance]
    mov [rel g_old_render], eax
    mov eax, [rel g_lod_distance]
    mov [rel g_old_lod], eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; get_value / set_value — a row's value as an integer (SK_HUND: hundredths;
; SK_FTOGGLE: 0/1).
;   in:  rcx = SROW* (set_value: edx = value)
;   out: eax = value
;   clobbers: rax, rdx, r8, xmm0
; -----------------------------------------------------------------------------
get_value:
    mov r8, [rcx + SROW.var]
    mov eax, [rcx + SROW.kind]
    cmp eax, SK_HUND
    je .hund
    cmp eax, SK_FTOGGLE
    je .ftoggle
    mov eax, [r8]
    ret
.hund:
    movss xmm0, [r8]
    mulss xmm0, [rel c_hundred]
    addss xmm0, [rel c_round]
    cvttss2si eax, xmm0
    ret
.ftoggle:
    xorps xmm0, xmm0
    xor eax, eax
    ucomiss xmm0, [r8]
    setne al
    ret

set_value:
    mov r8, [rcx + SROW.var]
    mov eax, [rcx + SROW.kind]
    cmp eax, SK_HUND
    je .hund
    cmp eax, SK_FTOGGLE
    je .ftoggle
    mov [r8], edx
    ret
.hund:
    cvtsi2ss xmm0, edx
    divss xmm0, [rel c_hundred]
    movss [r8], xmm0
    ret
.ftoggle:
    xorps xmm0, xmm0
    test edx, edx
    jz .store
    movss xmm0, [rel c_one]
.store:
    movss [r8], xmm0
    ret

; list_index — eax = index of the largest list value <= the row's value
; (0 if none); edx = 1 if it is equal.   in: rcx = SROW*, r9d = value
;   clobbers: rax, rdx, r8, r10, r11
list_index:
    mov r8, [rcx + SROW.list]
    xor eax, eax
    xor r10d, r10d
.i:
    cmp r10d, [rcx + SROW.max]
    ja .done
    cmp [r8 + r10 * 4], r9d
    jg .done
    mov eax, r10d
    inc r10d
    jmp .i
.done:
    xor edx, edx
    cmp [r8 + rax * 4], r9d
    sete dl
    ret

; -----------------------------------------------------------------------------
; draw_row — one setting: its label and a toggle or a < value > stepper.
;   in:  rcx = SROW*, edx = x, r8d = y, r9d = w, ARG5 = widget id
;   out: eax = 1 if the value changed
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define D_VALUE     0
%define D_CHANGED   4
%define D_NEW       8
PROC draw_row, 16, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    mov esi, edx
    mov edi, r8d
    mov r12d, r9d
    mov r13d, [ARG(5)]
    mov dword [LOCAL(D_CHANGED)], 0
    mov rcx, rbx
    call get_value
    mov [LOCAL(D_VALUE)], eax
    ; the label
    lea r8d, [edi + 8]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], 0
    INVOKE ui_label, [rbx + SROW.label], rsi, r8, 18
    mov eax, [rbx + SROW.kind]
    cmp eax, SK_TOGGLE
    je .toggle
    cmp eax, SK_FTOGGLE
    je .toggle

    ; ---- stepper ----
    ; the value text
    lea rcx, [rel g_text]
    mov r9d, [LOCAL(D_VALUE)]
    cmp dword [rbx + SROW.kind], SK_LIST
    jne .number
    mov rcx, rbx
    call list_index
    test edx, edx
    jz .list_number
    mov rdx, [rbx + SROW.names]
    mov rdx, [rdx + rax * 8]
    lea rcx, [rel g_text]
    call str_copy
    jmp .text_done
.list_number:
    lea rcx, [rel g_text]
    INVOKE str_append_dec, rcx, [LOCAL(D_VALUE)], 0
    jmp .text_done
.number:
    mov rdx, [rbx + SROW.names]
    test rdx, rdx
    jz .digits
    mov eax, r9d
    sub eax, [rbx + SROW.min]
    mov rdx, [rdx + rax * 8]
    lea rcx, [rel g_text]
    call str_copy
    jmp .text_done
.digits:
    xor r8d, r8d
    cmp dword [rbx + SROW.kind], SK_HUND
    jne .dec
    mov r8d, 2
.dec:
    lea rcx, [rel g_text]
    mov edx, r9d
    call str_append_dec
    mov rdx, [rbx + SROW.suffix]
    test rdx, rdx
    jz .text_done
    mov rcx, rax
    call str_copy
.text_done:
    lea edx, [esi + r12d - 93]
    lea r8d, [edi + 8]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel g_text]
    INVOKE ui_label, rcx, rdx, r8, 19
    ; "<": one step down (disabled at the bottom)
    mov ecx, [LOCAL(D_VALUE)]
    mov rax, rbx
    call step_down
    mov [LOCAL(D_NEW)], eax
    xor r10d, r10d
    cmp eax, [LOCAL(D_VALUE)]
    jne .left
    mov r10d, UIW_DISABLED
.left:
    mov [rsp + 48], r10
    mov qword [rsp + 32], 36
    lea rax, [rel s_left]
    mov [rsp + 40], rax
    lea edx, [esi + r12d - 186]
    INVOKE ui_button, r13, rdx, rdi, 36
    test eax, eax
    jz .right
    mov edx, [LOCAL(D_NEW)]
    mov rcx, rbx
    call set_value
    mov dword [LOCAL(D_CHANGED)], 1
    jmp .done
.right:
    mov ecx, [LOCAL(D_VALUE)]
    mov rax, rbx
    call step_up
    mov [LOCAL(D_NEW)], eax
    xor r10d, r10d
    cmp eax, [LOCAL(D_VALUE)]
    jne .right_ok
    mov r10d, UIW_DISABLED
.right_ok:
    mov [rsp + 48], r10
    mov qword [rsp + 32], 36
    lea rax, [rel s_right]
    mov [rsp + 40], rax
    lea edx, [esi + r12d - 36]
    lea ecx, [r13d + 1]
    INVOKE ui_button, rcx, rdx, rdi, 36
    test eax, eax
    jz .done
    mov edx, [LOCAL(D_NEW)]
    mov rcx, rbx
    call set_value
    mov dword [LOCAL(D_CHANGED)], 1
    jmp .done

    ; ---- toggle ----
.toggle:
    lea rax, [rel s_off]
    xor r10d, r10d
    cmp dword [LOCAL(D_VALUE)], 0
    je .t_flags
    lea rax, [rel s_on]
    mov r10d, UIW_SELECTED
.t_flags:
    mov [rsp + 40], rax
    mov [rsp + 48], r10
    mov qword [rsp + 32], 36
    lea edx, [esi + r12d - 120]
    INVOKE ui_button, r13, rdx, rdi, 120
    test eax, eax
    jz .done
    mov edx, [LOCAL(D_VALUE)]
    xor edx, 1
    mov rcx, rbx
    call set_value
    mov dword [LOCAL(D_CHANGED)], 1
.done:
    mov eax, [LOCAL(D_CHANGED)]
    RETURN
ENDPROC

; step_down / step_up — the value one step lower / higher (clamped).
;   in:  rax = SROW*, ecx = value
;   out: eax = new value
;   clobbers: rax, rcx, rdx, r8-r11
PROC step_down, 0, rbx
    mov rbx, rax
    cmp dword [rbx + SROW.kind], SK_LIST
    je .list
    mov eax, ecx
    sub eax, [rbx + SROW.step]
    cmp eax, [rbx + SROW.min]
    jge .done
    mov eax, [rbx + SROW.min]
    cmp ecx, eax
    jge .done
    mov eax, ecx                        ; (already below: stay)
.done:
    RETURN
.list:
    mov r9d, ecx
    mov rcx, rbx
    call list_index
    test edx, edx
    jz .at                              ; (between values: the one below)
    test eax, eax
    jz .at
    dec eax
.at:
    mov r8, [rbx + SROW.list]
    mov eax, [r8 + rax * 4]
    cmp eax, r9d
    jle .list_done
    mov eax, r9d                        ; (below the whole list: stay)
.list_done:
    RETURN
ENDPROC

PROC step_up, 0, rbx
    mov rbx, rax
    cmp dword [rbx + SROW.kind], SK_LIST
    je .list
    mov eax, ecx
    add eax, [rbx + SROW.step]
    cmp eax, [rbx + SROW.max]
    jle .done
    mov eax, [rbx + SROW.max]
    cmp ecx, eax
    jle .done
    mov eax, ecx                        ; (already above: stay)
.done:
    RETURN
.list:
    mov r9d, ecx
    mov rcx, rbx
    call list_index
    mov r8, [rbx + SROW.list]
    cmp [r8 + rax * 4], r9d
    jg .list_at                         ; (below the whole list: its first)
    cmp eax, [rbx + SROW.max]
    jae .list_at
    inc eax
.list_at:
    mov eax, [r8 + rax * 4]
    cmp eax, r9d
    jge .list_done
    mov eax, r9d
.list_done:
    RETURN
ENDPROC

; preset_matches — eax = 1 if every preset setting has preset ecx's value
preset_matches:
    imul ecx, ecx, PRESET_VARS * 4
    lea rdx, [rel presets]
    add rdx, rcx
    lea r8, [rel preset_vars]
    xor r9d, r9d
.v:
    cmp r9d, PRESET_VARS
    jae .yes
    mov rax, [r8 + r9 * 8]
    mov eax, [rax]
    cmp eax, [rdx + r9 * 4]
    jne .no
    inc r9d
    jmp .v
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; apply_preset — set the preset ecx's values   clobbers: rax, rcx, rdx, r8, r9
apply_preset:
    imul ecx, ecx, PRESET_VARS * 4
    lea rdx, [rel presets]
    add rdx, rcx
    lea r8, [rel preset_vars]
    xor r9d, r9d
.v:
    cmp r9d, PRESET_VARS
    jae .done
    mov rax, [r8 + r9 * 8]
    mov ecx, [rdx + r9 * 4]
    mov [rax], ecx
    inc r9d
    jmp .v
.done:
    ret

; changed — a row changed: remember what it touches; shadows apply now
;   in: rcx = SROW*   clobbers: volatile registers
PROC changed, 0, rbx
    mov ebx, [rcx + SROW.group]
    or [rel g_dirty], ebx
    test ebx, G_SHADOWS
    jz .done
    call shadow_apply
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; settings_screen_frame — draw the screen and handle it.
;   in:  ecx = canvas centre x (units)
;   out: eax = 1 when Done was clicked
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define F_CX        0
%define F_DONE      4
%define F_Y0        8
PROC settings_screen_frame, 16, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(F_CX)], ecx
    mov dword [LOCAL(F_DONE)], 0
    mov edi, ecx
    sub edi, PANEL_W / 2                ; panel left
    mov esi, [rel g_ui_vh]
    sub esi, PANEL_H
    sar esi, 1                          ; panel top
    INVOKE ui_panel, rdi, rsi, PANEL_W, PANEL_H
    lea r8d, [esi + 20]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], UI_CENTER | UI_BOLD
    lea rcx, [rel s_title]
    INVOKE ui_label, rcx, [LOCAL(F_CX)], r8, 34
    ; tabs
    xor ebx, ebx
.tab:
    cmp ebx, TAB_COUNT
    jae .tabs_done
    lea rax, [rel tab_names]
    mov rax, [rax + rbx * 8]
    mov [rsp + 40], rax
    mov qword [rsp + 32], 44
    xor r10d, r10d
    cmp ebx, [rel g_tab]
    jne .tab_f
    mov r10d, UIW_SELECTED
.tab_f:
    mov [rsp + 48], r10
    imul edx, ebx, 196
    add edx, [LOCAL(F_CX)]
    sub edx, 3 * 196 / 2 - 8
    lea r8d, [esi + 72]
    lea ecx, [ebx + 100]
    INVOKE ui_button, rcx, rdx, r8, 180
    test eax, eax
    jz .tab_next
    mov [rel g_tab], ebx
    mov dword [rel g_wait_action], -1
.tab_next:
    inc ebx
    jmp .tab
.tabs_done:
    lea eax, [esi + 140]
    mov [LOCAL(F_Y0)], eax
    mov eax, [rel g_tab]
    cmp eax, TAB_CONTROLS
    je .controls
    cmp eax, TAB_GAME
    je .game

    ; ---- graphics ----
    ; presets
    mov r8d, [LOCAL(F_Y0)]
    add r8d, 8
    lea edx, [edi + 40]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], 0
    lea rcx, [rel s_preset]
    INVOKE ui_label, rcx, rdx, r8, 19
    xor ebx, ebx
    xor r15d, r15d                      ; a preset matches
.preset:
    cmp ebx, PRESET_COUNT
    jae .presets_done
    mov ecx, ebx
    call preset_matches
    xor r10d, r10d
    test eax, eax
    jz .p_flags
    mov r10d, UIW_SELECTED
    mov r15d, 1
.p_flags:
    mov [rsp + 48], r10
    lea rax, [rel preset_names]
    mov rax, [rax + rbx * 8]
    mov [rsp + 40], rax
    mov qword [rsp + 32], 38
    imul edx, ebx, 134
    add edx, edi
    add edx, 200
    mov r8d, [LOCAL(F_Y0)]
    lea ecx, [ebx + 104]
    INVOKE ui_button, rcx, rdx, r8, 124
    test eax, eax
    jz .p_next
    mov ecx, ebx
    call apply_preset
    or dword [rel g_dirty], G_GRAPHICS | G_DISTANCE
    call shadow_apply
.p_next:
    inc ebx
    jmp .preset
.presets_done:
    test r15d, r15d
    jnz .g_rows
    mov r8d, [LOCAL(F_Y0)]
    add r8d, 8
    lea edx, [edi + PANEL_W - 40]
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], UI_RIGHT
    lea rcx, [rel s_custom]
    INVOKE ui_label, rcx, rdx, r8, 19
.g_rows:
    xor ebx, ebx
.g_row:
    cmp ebx, GRAPHICS_ROWS
    jae .g_hint
    imul eax, ebx, SROW_size
    lea r12, [rel rows_graphics]
    add r12, rax
    ; 7 rows per column
    mov eax, ebx
    xor edx, edx
    mov ecx, 7
    div ecx                             ; eax = column, edx = row
    imul r8d, edx, ROW_STEP
    add r8d, [LOCAL(F_Y0)]
    add r8d, 62
    imul edx, eax, 390
    add edx, edi
    add edx, 40
    lea eax, [ebx * 2 + 120]
    mov [rsp + 32], rax
    INVOKE draw_row, r12, rdx, r8, 350
    test eax, eax
    jz .g_next
    mov rcx, r12
    call changed
.g_next:
    inc ebx
    jmp .g_row
.g_hint:
    mov r8d, [LOCAL(F_Y0)]
    add r8d, 62 + 7 * ROW_STEP + 6
    mov dword [rsp + 32], COL_TEXT_OFF
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel s_restart_hint]
    INVOKE ui_label, rcx, [LOCAL(F_CX)], r8, 15
    jmp .done_button

    ; ---- controls ----
.controls:
    ; a key for the action being rebound (from the frame after the click)
    cmp dword [rel g_wait_action], 0
    jl .c_rows
    cmp dword [rel g_wait_armed], 0
    je .c_rows
    call input_any_pressed
    test eax, eax
    jz .c_rows
    cmp eax, VK_DELETE
    jne .c_bind
    xor eax, eax                        ; Delete: no key
.c_bind:
    mov ecx, [rel g_wait_action]
    lea rdx, [rel g_bindings]
    lea rdx, [rdx + rcx * BINDS_PER_ACTION]
    mov ecx, [rel g_wait_slot]
    mov [rdx + rcx], al
    mov dword [rel g_wait_action], -1
    mov dword [rel g_ui_click], 0       ; (a mouse button bound: no click)
    or dword [rel g_dirty], G_CONTROLS
.c_rows:
    xor ebx, ebx
.c_action:
    cmp ebx, ACT_COUNT
    jae .c_extra
    ; 8 per column
    mov eax, ebx
    and eax, 7
    imul r13d, eax, 42
    add r13d, [LOCAL(F_Y0)]             ; row top
    mov eax, ebx
    shr eax, 3
    imul r12d, eax, 390
    add r12d, edi
    add r12d, 40                        ; row left
    lea r8d, [r13d + 7]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], 0
    lea rax, [rel action_names]
    mov rcx, [rax + rbx * 8]
    INVOKE ui_label, rcx, r12, r8, 17
    xor r14d, r14d                      ; slot
.c_slot:
    cmp r14d, BINDS_PER_ACTION
    jae .c_next
    xor r10d, r10d
    cmp ebx, [rel g_wait_action]
    jne .c_key
    cmp r14d, [rel g_wait_slot]
    jne .c_key
    lea rax, [rel s_press]
    mov r10d, UIW_PRIMARY
    jmp .c_label
.c_key:
    lea rax, [rel g_bindings]
    lea rax, [rax + rbx * BINDS_PER_ACTION]
    movzx ecx, byte [rax + r14]
    call input_key_name
.c_label:
    mov [rsp + 40], rax
    mov [rsp + 48], r10
    mov qword [rsp + 32], 34
    imul edx, r14d, 104
    add edx, r12d
    add edx, 350 - 202
    lea ecx, [ebx * 2 + 190]
    add ecx, r14d
    INVOKE ui_button, rcx, rdx, r13, 98
    test eax, eax
    jz .c_slot_next
    mov [rel g_wait_action], ebx
    mov [rel g_wait_slot], r14d
    mov dword [rel g_wait_armed], 0
.c_slot_next:
    inc r14d
    jmp .c_slot
.c_next:
    inc ebx
    jmp .c_action
.c_extra:
    ; sensitivity (left), invert (right)
    mov r8d, [LOCAL(F_Y0)]
    add r8d, 8 * 42 + 14
    mov qword [rsp + 32], 240
    lea rcx, [rel rows_controls]
    lea edx, [edi + 40]
    INVOKE draw_row, rcx, rdx, r8, 350
    test eax, eax
    jz .c_invert
    lea rcx, [rel rows_controls]
    call changed
.c_invert:
    mov r8d, [LOCAL(F_Y0)]
    add r8d, 8 * 42 + 14
    mov qword [rsp + 32], 242
    lea rcx, [rel rows_controls + SROW_size]
    lea edx, [edi + 430]
    INVOKE draw_row, rcx, rdx, r8, 350
    test eax, eax
    jz .c_hint
    lea rcx, [rel rows_controls + SROW_size]
    call changed
.c_hint:
    mov r8d, [LOCAL(F_Y0)]
    add r8d, 8 * 42 + 14 + ROW_STEP + 4
    mov dword [rsp + 32], COL_TEXT_OFF
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel s_keys_hint]
    INVOKE ui_label, rcx, [LOCAL(F_CX)], r8, 15
    ; the click that started a rebinding is not the key
    cmp dword [rel g_wait_action], 0
    jl .done_button
    mov dword [rel g_wait_armed], 1
    jmp .done_button

    ; ---- game ----
.game:
    xor ebx, ebx
.gm_row:
    cmp ebx, GAME_ROWS
    jae .done_button
    imul eax, ebx, SROW_size
    lea r12, [rel rows_game]
    add r12, rax
    imul r8d, ebx, ROW_STEP + 8
    add r8d, [LOCAL(F_Y0)]
    add r8d, 10
    mov edx, [LOCAL(F_CX)]
    sub edx, 220
    lea eax, [ebx * 2 + 160]
    mov [rsp + 32], rax
    INVOKE draw_row, r12, rdx, r8, 440
    test eax, eax
    jz .gm_next
    mov rcx, r12
    call changed
.gm_next:
    inc ebx
    jmp .gm_row

.done_button:
    lea r8d, [esi + PANEL_H - 24 - 52]
    mov edx, [LOCAL(F_CX)]
    sub edx, 120
    mov qword [rsp + 32], 52
    lea rax, [rel s_done]
    mov [rsp + 40], rax
    mov qword [rsp + 48], UIW_PRIMARY
    INVOKE ui_button, 108, rdx, r8, 240
    mov [LOCAL(F_DONE)], eax
    mov eax, [LOCAL(F_DONE)]
    RETURN
ENDPROC
