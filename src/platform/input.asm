; =============================================================================
; input.asm — keyboard/mouse state, Raw Input mouse deltas, action bindings
; loaded from data/config/controls.cfg, and mouse capture.
;
; Per frame: input_new_frame() (before the message pump), then query with
; input_down(action) / input_pressed(action) and read g_mouse_dx/dy.
; The WndProc forwards key/button messages (input_on_key), WM_INPUT
; (input_on_raw_input) and focus loss (input_on_focus_lost).
; =============================================================================
%define INPUT_IMPL
%include "macros.inc"
%include "win32.inc"
%include "log.inc"
%include "file.inc"
%include "memory.inc"
%include "cfg.inc"
%include "input.inc"
%include "window.inc"

global input_init, input_load_bindings, input_new_frame
global input_on_key, input_on_raw_input, input_on_focus_lost
global input_down, input_pressed, input_vk_pressed
global input_set_capture, input_update_capture, input_key_name, input_action_name
global g_mouse_dx, g_mouse_dy, g_mouse_captured, g_bindings
global g_mouse_sensitivity, g_invert_mouse_y, g_fly_speed, g_fly_sprint_mult

extern str_ieq, str_parse_float

IMPORT RegisterRawInputDevices, GetRawInputData
IMPORT ShowCursor, ClipCursor, GetClientRect, MapWindowPoints

%define RID_INPUT               0x10000003
%define RIM_TYPEMOUSE           0
%define MOUSE_MOVE_ABSOLUTE     1
%define RAWINPUTHEADER_SIZE     24
%define RAW_MOUSE_FLAGS         24      ; offsets inside RAWINPUT (x64)
%define RAW_MOUSE_LASTX         36
%define RAW_MOUSE_LASTY         40
%define CAPTURE_SETTLE_FRAMES   3       ; ignore motion caused by the cursor jump

section .rdata
STR_CONTROLS:       db "data/config/controls.cfg", 0
str_unknown_q:      db "?", 0
str_none:           db "-", 0

; action names, in ACT_* order (also the names used in controls.cfg)
an_0:  db "move_forward", 0
an_1:  db "move_back", 0
an_2:  db "move_left", 0
an_3:  db "move_right", 0
an_4:  db "move_up", 0
an_5:  db "move_down", 0
an_6:  db "sprint", 0
an_7:  db "toggle_debug_overlay", 0
an_8:  db "toggle_vsync", 0
an_9:  db "reload_shaders", 0
an_10: db "menu", 0
align 8
action_name_table:  dq an_0, an_1, an_2, an_3, an_4, an_5, an_6, an_7, an_8, an_9, an_10
%if ($ - action_name_table) / 8 != ACT_COUNT
    %error "action_name_table does not match ACT_COUNT"
%endif

; settings that live in controls.cfg next to the bindings: name, float*
set_sens:   db "mouse_sensitivity", 0
set_inv:    db "invert_mouse_y", 0
set_speed:  db "fly_speed", 0
set_sprint: db "fly_sprint_multiplier", 0
align 8
setting_table:      dq set_sens, g_mouse_sensitivity
                    dq set_inv, g_invert_mouse_y
                    dq set_speed, g_fly_speed
                    dq set_sprint, g_fly_sprint_mult
setting_count equ ($ - setting_table) / 16

str_cfg_label:      db "controls.cfg", 0
str_bad_name:       db "unknown action or setting: ", 0
str_bad_key:        db "unknown key name: ", 0
str_bad_number:     db "expected a number for: ", 0
str_too_many:       db "more than 2 keys for: ", 0
str_bound:          db "bound ", 0
str_arrow:          db " -> ", 0
str_comma:          db ", ", 0

%include "keytable.inc"

section .data
align 4
; Fallback values, used only if controls.cfg omits a setting.
g_mouse_sensitivity:    dd 0.12         ; degrees per mouse count
g_invert_mouse_y:       dd 0.0          ; nonzero = invert
g_fly_speed:            dd 12.0         ; blocks per second
g_fly_sprint_mult:      dd 5.0

section .bss
alignb 16
g_keys_down:        resb 256
g_keys_pressed:     resb 256                ; went down since input_new_frame
g_bindings:         resb ACT_COUNT * BINDS_PER_ACTION
alignb 4
g_mouse_dx:         resd 1
g_mouse_dy:         resd 1
g_mouse_captured:   resd 1
g_capture_settle:   resd 1                  ; frames to ignore deltas after capture
alignb 16
alignb 8
g_config_path:      resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; input_init — register the mouse for Raw Input on the main window.
;   in/out: none (uses g_hwnd)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC input_init, 16
    mov word [LOCAL(0)], 1              ; usUsagePage: generic desktop
    mov word [LOCAL(2)], 2              ; usUsage: mouse
    mov dword [LOCAL(4)], 0             ; dwFlags
    mov rax, [rel g_hwnd]
    mov [LOCAL(8)], rax                 ; hwndTarget
    lea rcx, [LOCAL(0)]
    API RegisterRawInputDevices, rcx, 1, 16
    test eax, eax
    jnz .ok
    LOG_WARN "RegisterRawInputDevices failed; mouse look unavailable"
    RETURN
.ok:
    LOG_INFO "raw mouse input registered"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; key_lookup — find a key by name (case-insensitive).
;   in:  rcx = zero-terminated name
;   out: eax = virtual-key code, 0 if unknown
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC key_lookup, 0, rbx, rsi, rdi
    mov rdi, rcx
    lea rbx, [rel key_name_table]
    mov esi, key_name_count
.next:
    INVOKE str_ieq, rbx, rdi
    test eax, eax
    jnz .found
    add rbx, 16
    dec esi
    jnz .next
    xor eax, eax
    RETURN
.found:
    movzx eax, byte [rbx + 12]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; input_key_name — display name of a virtual-key code.
;   in:  ecx = vk (0 = unbound)
;   out: rax = zero-terminated name ("-" if unbound, "?" if unknown)
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
input_key_name:
    lea rax, [rel str_none]
    test ecx, ecx
    jz .done
    lea rax, [rel key_name_table]
    mov edx, key_name_count
.next:
    cmp cl, [rax + 12]
    je .done
    add rax, 16
    dec edx
    jnz .next
    lea rax, [rel str_unknown_q]
.done:
    ret

; -----------------------------------------------------------------------------
; input_action_name — the controls.cfg name of an action.
;   in:  ecx = action id (0 .. ACT_COUNT-1)
;   out: rax = zero-terminated name
;   clobbers: rax
; -----------------------------------------------------------------------------
input_action_name:
    lea rax, [rel action_name_table]
    mov rax, [rax + rcx * 8]
    ret

; -----------------------------------------------------------------------------
; apply_binding — parse "Key[, Key]" into the bindings of one action.
;   in:  ecx = action id, rdx = value text (zero-terminated, trimmed)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC apply_binding, 0, rbx, rsi, rdi, r12, r13
    mov r12d, ecx                       ; action
    mov rsi, rdx                        ; cursor (0 = done)
    xor r13d, r13d                      ; keys stored so far
    lea rdi, [rel g_bindings]
    lea rdi, [rdi + r12 * BINDS_PER_ACTION]
    mov word [rdi], 0                   ; clear this action's bindings
.token:
    test rsi, rsi
    jz .done
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    mov rbx, rax
    cmp byte [rbx], 0
    je .token                           ; empty token
    INVOKE key_lookup, rbx
    test eax, eax
    jnz .known
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_bad_key]
    INVOKE cfg_warn, rcx, rdx, rbx
    jmp .token
.known:
    cmp r13d, BINDS_PER_ACTION
    jb .store
    mov ecx, r12d
    call input_action_name
    mov r8, rax
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_too_many]
    call cfg_warn
    jmp .token
.store:
    mov [rdi + r13], al
    inc r13d
    jmp .token
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; controls_pair — cfg_parse callback for controls.cfg.
;   in:  rcx = name, rdx = value, r8 = user (unused)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC controls_pair, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    xor edi, edi
.try_action:
    mov ecx, edi
    call input_action_name
    INVOKE str_ieq, rax, rbx
    test eax, eax
    jnz .is_action
    inc edi
    cmp edi, ACT_COUNT
    jb .try_action
    xor edi, edi
.try_setting:
    lea rax, [rel setting_table]
    mov rcx, rdi
    shl rcx, 4
    INVOKE str_ieq, [rax + rcx], rbx
    test eax, eax
    jnz .is_setting
    inc edi
    cmp edi, setting_count
    jb .try_setting
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_bad_name]
    INVOKE cfg_warn, rcx, rdx, rbx
    RETURN
.is_action:
    INVOKE apply_binding, rdi, rsi
    RETURN
.is_setting:
    INVOKE str_parse_float, rsi
    test eax, eax
    jz .bad_number
    lea rax, [rel setting_table]
    mov rcx, rdi
    shl rcx, 4
    mov rax, [rax + rcx + 8]
    movss [rax], xmm0
    RETURN
.bad_number:
    lea rcx, [rel str_cfg_label]
    lea rdx, [rel str_bad_number]
    INVOKE cfg_warn, rcx, rdx, rbx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; input_load_bindings — read data/config/controls.cfg (format: DATA_FORMAT.md).
;   Action names take one or two key names separated by ','; settings take
;   a number. Problems are logged as warnings and skipped.
;   out: eax = 1 if the file was read, 0 otherwise (error logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC input_load_bindings, 0, rbx
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov rbx, rax
    lea rcx, [rel g_config_path]
    lea rdx, [rel STR_CONTROLS]
    call path_make
    lea rcx, [rel g_config_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jnz .read_ok
    LOG_ERROR "could not read data/config/controls.cfg"
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, rbx
    xor eax, eax
    RETURN
.read_ok:
    lea rdx, [rel controls_pair]
    lea r9, [rel str_cfg_label]
    INVOKE cfg_parse, rax, rdx, 0, r9
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, rbx
    call log_bindings
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_bindings — log every action's keys ("bound move_forward -> W, Up").
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_bindings, 0, rbx, rsi
    xor ebx, ebx
.next:
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_bound]
    call log_append_str
    mov ecx, ebx
    call input_action_name
    mov rcx, rax
    call log_append_str
    lea rcx, [rel str_arrow]
    call log_append_str
    lea rsi, [rel g_bindings]
    lea rsi, [rsi + rbx * BINDS_PER_ACTION]
    movzx ecx, byte [rsi]
    call input_key_name
    mov rcx, rax
    call log_append_str
    movzx ecx, byte [rsi + 1]
    test ecx, ecx
    jz .one
    lea rcx, [rel str_comma]
    call log_append_str
    movzx ecx, byte [rsi + 1]
    call input_key_name
    mov rcx, rax
    call log_append_str
.one:
    call log_end
    inc ebx
    cmp ebx, ACT_COUNT
    jb .next
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; input_new_frame — start a frame: clear the "pressed" latches and mouse
; deltas. Call before pumping messages.
;   clobbers: rax, xmm0
; -----------------------------------------------------------------------------
input_new_frame:
    lea rax, [rel g_keys_pressed]
    xorps xmm0, xmm0
%assign i 0
%rep 16
    movdqa [rax + i], xmm0
%assign i i + 16
%endrep
    mov dword [rel g_mouse_dx], 0
    mov dword [rel g_mouse_dy], 0
    cmp dword [rel g_capture_settle], 0
    je .settled
    dec dword [rel g_capture_settle]
.settled:
    ret

; -----------------------------------------------------------------------------
; input_on_key — record a key or mouse-button transition. An up->down change
; latches "pressed" for this frame, so a tap shorter than a frame (down and
; up in the same message pump) is still seen; auto-repeat is not a press.
;   in:  ecx = virtual-key code (0..255), edx = 1 down / 0 up
;   clobbers: rax, rcx, r8
; -----------------------------------------------------------------------------
input_on_key:
    lea rax, [rel g_keys_down]
    movzx ecx, cl
    test edx, edx
    jz .store
    cmp byte [rax + rcx], 0
    jne .store                          ; already down: auto-repeat
    lea r8, [rel g_keys_pressed]
    mov byte [r8 + rcx], 1
.store:
    mov [rax + rcx], dl
    ret

; -----------------------------------------------------------------------------
; input_on_raw_input — handle WM_INPUT: accumulate relative mouse motion
; while the mouse is captured.
;   in:  rcx = HRAWINPUT (lParam of WM_INPUT)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC input_on_raw_input, 64
    mov dword [LOCAL(48)], 48           ; buffer size in/out
    lea r8, [LOCAL(0)]
    lea r9, [LOCAL(48)]
    mov qword [rsp + 32], RAWINPUTHEADER_SIZE
    INVOKE [rel __imp_GetRawInputData], rcx, RID_INPUT, r8, r9
    cmp eax, -1
    je .done
    cmp dword [LOCAL(0)], RIM_TYPEMOUSE
    jne .done
    test word [LOCAL(RAW_MOUSE_FLAGS)], MOUSE_MOVE_ABSOLUTE
    jnz .done
    cmp dword [rel g_mouse_captured], 0
    je .done
    cmp dword [rel g_capture_settle], 0
    jne .done
    mov eax, [LOCAL(RAW_MOUSE_LASTX)]
    add [rel g_mouse_dx], eax
    mov eax, [LOCAL(RAW_MOUSE_LASTY)]
    add [rel g_mouse_dy], eax
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; input_on_focus_lost — forget held keys and release the mouse.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC input_on_focus_lost, 0, rdi
    lea rdi, [rel g_keys_down]
    xor eax, eax
    mov ecx, 256
    rep stosb
    xor ecx, ecx
    call input_set_capture
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; input_down — is any key bound to this action held?
;   in:  ecx = action id
;   out: eax = 1/0
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
input_down:
    lea rax, [rel g_bindings]
    lea rcx, [rax + rcx * BINDS_PER_ACTION]
    lea rdx, [rel g_keys_down]
    xor eax, eax
%assign k 0
%rep BINDS_PER_ACTION
    movzx r8d, byte [rcx + k]
    test r8d, r8d
    jz .skip%[k]
    or al, [rdx + r8]
.skip%[k]:
%assign k k + 1
%endrep
    ret

; -----------------------------------------------------------------------------
; input_pressed — did a key bound to this action go down this frame?
;   in:  ecx = action id
;   out: eax = 1/0
;   clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
input_pressed:
    lea rax, [rel g_bindings]
    lea r9, [rax + rcx * BINDS_PER_ACTION]
    xor eax, eax
%assign k 0
%rep BINDS_PER_ACTION
    movzx ecx, byte [r9 + k]
    test ecx, ecx
    jz .skip%[k]
    call input_vk_pressed_raw
.skip%[k]:
%assign k k + 1
%endrep
    ret

; -----------------------------------------------------------------------------
; input_vk_pressed — did this key go down this frame?
;   in:  ecx = vk
;   out: eax = 1/0
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
input_vk_pressed:
    xor eax, eax
input_vk_pressed_raw:                   ; ORs the result into al
    movzx ecx, cl
    lea rdx, [rel g_keys_pressed]
    or al, [rdx + rcx]
    ret

; -----------------------------------------------------------------------------
; input_set_capture — capture (hide + confine) or release the mouse.
;   in:  ecx = 1 capture / 0 release
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC input_set_capture, 0
    test ecx, ecx
    jz .release
    cmp dword [rel g_mouse_captured], 0
    jne .done
    mov dword [rel g_mouse_captured], 1
    mov dword [rel g_capture_settle], CAPTURE_SETTLE_FRAMES
    API ShowCursor, 0
    call input_update_capture
    LOG_INFO "mouse captured"
    RETURN
.release:
    cmp dword [rel g_mouse_captured], 0
    je .done
    mov dword [rel g_mouse_captured], 0
    API ShowCursor, 1
    API ClipCursor, 0
    LOG_INFO "mouse released"
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; input_update_capture — keep the cursor confined to the client area while
; captured (call every frame; the window may have moved or resized).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC input_update_capture, RECT_size
    cmp dword [rel g_mouse_captured], 0
    je .done
    lea rdx, [LOCAL(0)]
    API GetClientRect, [rel g_hwnd], rdx
    lea r8, [LOCAL(0)]
    API MapWindowPoints, [rel g_hwnd], 0, r8, 2
    lea rcx, [LOCAL(0)]
    API ClipCursor, rcx
.done:
    RETURN
ENDPROC
