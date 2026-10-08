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
%define CONFIG_CAP              65536
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

str_bad_line:       db "controls.cfg: line without '=': ", 0
str_bad_name:       db "controls.cfg: unknown action or setting: ", 0
str_bad_key:        db "controls.cfg: unknown key name: ", 0
str_bad_number:     db "controls.cfg: expected a number for: ", 0
str_too_many:       db "controls.cfg: more than 2 keys for: ", 0
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
g_config_buf:       resb CONFIG_CAP
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
; trim — trim ASCII whitespace/control chars from [start, end) and write a
; terminator at the new end.
;   in:  rcx = start, rdx = end (exclusive)
;   out: rax = trimmed start
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
trim:
.front:
    cmp rcx, rdx
    jae .term
    cmp byte [rcx], ' '
    ja .back
    inc rcx
    jmp .front
.back:
    cmp rdx, rcx
    jbe .term
    cmp byte [rdx - 1], ' '
    ja .term
    dec rdx
    jmp .back
.term:
    mov byte [rdx], 0
    mov rax, rcx
    ret

; -----------------------------------------------------------------------------
; log_with — log "<prefix><text>" at WARN level.
;   in:  rcx = prefix, rdx = text
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_with, 0, rbx, rsi
    mov rbx, rcx
    mov rsi, rdx
    mov ecx, LOG_LEVEL_WARN
    call log_begin
    mov rcx, rbx
    call log_append_str
    mov rcx, rsi
    call log_append_str
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; apply_binding — parse "Key[, Key]" into the bindings of one action.
;   in:  ecx = action id, rdx = value text (zero-terminated, trimmed)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC apply_binding, 0, rbx, rsi, rdi, r12, r13, r14
    mov r12d, ecx                       ; action
    mov rsi, rdx                        ; cursor
    xor r13d, r13d                      ; keys stored so far
    lea rdi, [rel g_bindings]
    lea rdi, [rdi + r12 * BINDS_PER_ACTION]
    mov word [rdi], 0                   ; clear this action's bindings
.token:
    mov rbx, rsi                        ; token start
.find_end:
    mov al, [rsi]
    test al, al
    jz .have_token
    cmp al, ','
    je .have_token
    inc rsi
    jmp .find_end
.have_token:
    movzx r14d, byte [rsi]              ; remember the separator (trim may
    INVOKE trim, rbx, rsi               ; overwrite it with the terminator)
    mov rbx, rax
    cmp byte [rbx], 0
    je .advance                         ; empty token
    INVOKE key_lookup, rbx
    test eax, eax
    jnz .known
    lea rcx, [rel str_bad_key]
    INVOKE log_with, rcx, rbx
    jmp .advance
.known:
    cmp r13d, BINDS_PER_ACTION
    jb .store
    mov ecx, r12d
    call input_action_name
    lea rcx, [rel str_too_many]
    INVOKE log_with, rcx, rax
    jmp .advance
.store:
    mov [rdi + r13], al
    inc r13d
.advance:
    test r14d, r14d
    je .done
    inc rsi
    jmp .token
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; input_load_bindings — read data/config/controls.cfg.
;   Format: one "name = value" per line, '#' starts a comment. Action names
;   take one or two key names separated by ','; settings take a number.
;   in:  none
;   out: eax = 1 if the file was read, 0 otherwise (error logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC input_load_bindings, 0, rbx, rsi, rdi, r12, r13, r14, r15
    lea rcx, [rel g_config_path]
    lea rdx, [rel STR_CONTROLS]
    call path_make
    lea rcx, [rel g_config_path]
    lea rdx, [rel g_config_buf]
    INVOKE file_read_all, rcx, rdx, CONFIG_CAP
    cmp rax, -1
    jne .read_ok
    LOG_ERROR "could not read data/config/controls.cfg"
    xor eax, eax
    RETURN
.read_ok:
    lea rsi, [rel g_config_buf]         ; rsi = line start
.line:
    cmp byte [rsi], 0
    je .finished
    ; rdi = line end (newline or terminator)
    mov rdi, rsi
.find_eol:
    mov al, [rdi]
    test al, al
    jz .eol
    cmp al, 10
    je .eol
    inc rdi
    jmp .find_eol
.eol:
    xor r14d, r14d                      ; r14 = 1 if more lines follow
    cmp byte [rdi], 0
    je .last
    mov r14d, 1
.last:
    mov byte [rdi], 0
    mov r15, rdi                        ; r15 = original line end
    ; cut comment
    mov rcx, rsi
.find_hash:
    cmp rcx, rdi
    jae .no_hash
    cmp byte [rcx], '#'
    je .hash
    inc rcx
    jmp .find_hash
.hash:
    mov byte [rcx], 0
    mov rdi, rcx
.no_hash:
    ; find '='
    mov r12, rsi
.find_eq:
    cmp r12, rdi
    jae .no_eq
    cmp byte [r12], '='
    je .have_eq
    inc r12
    jmp .find_eq
.no_eq:
    INVOKE trim, rsi, rdi
    cmp byte [rax], 0
    je .next_line                       ; blank / comment-only line
    lea rcx, [rel str_bad_line]
    INVOKE log_with, rcx, rax
    jmp .next_line
.have_eq:
    INVOKE trim, rsi, r12
    mov rbx, rax                        ; rbx = name
    lea rcx, [r12 + 1]
    INVOKE trim, rcx, rdi
    mov r13, rax                        ; r13 = value

    ; action?
    xor r12d, r12d
.try_action:
    mov ecx, r12d
    call input_action_name
    INVOKE str_ieq, rax, rbx
    test eax, eax
    jnz .is_action
    inc r12d
    cmp r12d, ACT_COUNT
    jb .try_action
    ; setting?
    xor r12d, r12d
.try_setting:
    lea rax, [rel setting_table]
    mov rcx, r12
    shl rcx, 4
    INVOKE str_ieq, [rax + rcx], rbx
    test eax, eax
    jnz .is_setting
    inc r12d
    cmp r12d, setting_count
    jb .try_setting
    lea rcx, [rel str_bad_name]
    INVOKE log_with, rcx, rbx
    jmp .next_line
.is_action:
    INVOKE apply_binding, r12, r13
    jmp .next_line
.is_setting:
    INVOKE str_parse_float, r13
    test eax, eax
    jz .bad_number
    lea rax, [rel setting_table]
    mov rcx, r12
    shl rcx, 4
    mov rax, [rax + rcx + 8]
    movss [rax], xmm0
    jmp .next_line
.bad_number:
    lea rcx, [rel str_bad_number]
    INVOKE log_with, rcx, rbx
.next_line:
    test r14d, r14d
    jz .finished
    lea rsi, [r15 + 1]
    jmp .line
.finished:
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
