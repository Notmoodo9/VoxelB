; =============================================================================
; window.asm — Win32 main window: class registration, creation, message pump,
; window procedure and teardown.
;
; Public API (see include/window.inc):
;   window_init(width, height, title, autoclose_ms) -> eax 1 ok / 0 fail
;   window_pump()                                   -> eax 1 running / 0 quit
;   window_shutdown()
;   g_hwnd, g_hinstance, g_client_w, g_client_h, g_window_active, g_exit_code
;   g_close_requested   set by WM_CLOSE (close button, Alt+F4, Esc, autoclose);
;                       the main loop then shuts down while the window and GL
;                       context still exist, and window_shutdown destroys it
; Keyboard, mouse-button and WM_INPUT messages are forwarded to input.asm.
; =============================================================================
%include "macros.inc"
%include "win32.inc"
%include "log.inc"
%include "input.inc"

global window_init, window_pump, window_shutdown
global g_hwnd, g_hinstance, g_client_w, g_client_h, g_window_active, g_exit_code
global g_close_requested

IMPORT GetModuleHandleA, GetLastError
IMPORT SetProcessDpiAwarenessContext, RegisterClassExA, UnregisterClassA
IMPORT LoadIconA, LoadCursorA, AdjustWindowRectEx, GetSystemMetrics
IMPORT CreateWindowExA, DestroyWindow, ShowWindow, GetClientRect, SetWindowPos
IMPORT PeekMessageA, TranslateMessage, DispatchMessageA, DefWindowProcA
IMPORT PostMessageA, PostQuitMessage, SetTimer, KillTimer
IMPORT CreateSolidBrush, DeleteObject

%define AUTOCLOSE_TIMER_ID  1
%define BACKGROUND_COLOR    0x00402010      ; COLORREF 0x00BBGGRR: deep navy

section .rdata
window_class_name:  db "VoxelBWindowClass", 0

section .bss
alignb 8
g_hwnd:             resq 1
g_hinstance:        resq 1
g_client_w:         resd 1
g_client_h:         resd 1
g_window_active:    resd 1
g_exit_code:        resd 1
g_close_requested:  resd 1
alignb 8
g_background_brush: resq 1

section .text

; -----------------------------------------------------------------------------
; window_init — register the window class and create the visible main window,
; centred on the primary monitor, with a client area of width x height pixels.
;   in:  ecx = client width, edx = client height, r8 = window title,
;        r9d = autoclose milliseconds (0 = never; test/headless runs)
;   out: eax = 1 on success, 0 on failure (error already logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define WI_WC       0                           ; WNDCLASSEXA (80 bytes)
%define WI_RECT     WNDCLASSEXA_size            ; RECT (16 bytes)
%define WI_LOCALS   (WNDCLASSEXA_size + RECT_size)

PROC window_init, WI_LOCALS, rbx, rsi, rdi, r12, r13, r14
    mov r12d, ecx                       ; r12 = client width
    mov r13d, edx                       ; r13 = client height
    mov r14, r8                         ; r14 = title
    mov ebx, r9d                        ; rbx = autoclose ms

    ; Per-monitor DPI awareness so the client area is in real pixels.
    ; Prefer v2 (Windows 10 1703+); fall back to v1 where v2 is unknown.
    API SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    test eax, eax
    jnz .dpi_ok
    API SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE
    test eax, eax
    jz .dpi_fail
    LOG_INFO "DPI awareness: per-monitor v1 (v2 unavailable)"
    jmp .dpi_ok
.dpi_fail:
    API GetLastError
    cmp eax, ERROR_ACCESS_DENIED        ; awareness already fixed by system/manifest
    jne .dpi_warn
    LOG_INFO "DPI awareness already set by the system; keeping it"
    jmp .dpi_ok
.dpi_warn:
    LOG_VAL LOG_LEVEL_WARN, "SetProcessDpiAwarenessContext failed (already set or unsupported), GetLastError =", rax
.dpi_ok:

    API GetModuleHandleA, 0
    test rax, rax
    ASSERT nz, "GetModuleHandleA(NULL) returned NULL"
    mov [rel g_hinstance], rax

    ; ---- fill WNDCLASSEXA ----------------------------------------------------
    lea rdi, [LOCAL(WI_WC)]
    xor eax, eax
    mov ecx, WNDCLASSEXA_size
    rep stosb
    lea rdi, [LOCAL(WI_WC)]
    mov dword [rdi + WNDCLASSEXA.cbSize], WNDCLASSEXA_size
    mov dword [rdi + WNDCLASSEXA.style], CS_OWNDC | CS_HREDRAW | CS_VREDRAW
    lea rax, [rel window_proc]
    mov [rdi + WNDCLASSEXA.lpfnWndProc], rax
    mov rax, [rel g_hinstance]
    mov [rdi + WNDCLASSEXA.hInstance], rax
    lea rax, [rel window_class_name]
    mov [rdi + WNDCLASSEXA.lpszClassName], rax
    API LoadIconA, 0, IDI_APPLICATION
    mov [rdi + WNDCLASSEXA.hIcon], rax
    mov [rdi + WNDCLASSEXA.hIconSm], rax
    API LoadCursorA, 0, IDC_ARROW
    mov [rdi + WNDCLASSEXA.hCursor], rax
    ; background shown until the renderer draws (and in headless screenshots)
    API CreateSolidBrush, BACKGROUND_COLOR
    mov [rel g_background_brush], rax
    mov [rdi + WNDCLASSEXA.hbrBackground], rax

    API RegisterClassExA, rdi
    test ax, ax
    jnz .class_ok
    API GetLastError
    LOG_VAL LOG_LEVEL_ERROR, "RegisterClassExA failed, GetLastError =", rax
    xor eax, eax
    RETURN
.class_ok:

    ; ---- outer window size for the requested client size ---------------------
    lea rsi, [LOCAL(WI_RECT)]
    mov dword [rsi + RECT.left], 0
    mov dword [rsi + RECT.top], 0
    mov [rsi + RECT.right], r12d
    mov [rsi + RECT.bottom], r13d
    API AdjustWindowRectEx, rsi, WS_OVERLAPPEDWINDOW, 0, 0
    mov r12d, [rsi + RECT.right]
    sub r12d, [rsi + RECT.left]         ; r12 = outer width
    mov r13d, [rsi + RECT.bottom]
    sub r13d, [rsi + RECT.top]          ; r13 = outer height

    ; ---- centre on the primary monitor (clamped to >= 0) ---------------------
    API GetSystemMetrics, SM_CXSCREEN
    sub eax, r12d
    sar eax, 1
    jns .x_ok
    xor eax, eax
.x_ok:
    mov esi, eax                        ; rsi = x
    API GetSystemMetrics, SM_CYSCREEN
    sub eax, r13d
    sar eax, 1
    jns .y_ok
    xor eax, eax
.y_ok:
    mov edi, eax                        ; rdi = y

    lea rdx, [rel window_class_name]
    API CreateWindowExA, 0, rdx, r14, WS_OVERLAPPEDWINDOW | WS_VISIBLE, rsi, rdi, r12, r13, 0, 0, [rel g_hinstance], 0
    test rax, rax
    jnz .window_ok
    API GetLastError
    LOG_VAL LOG_LEVEL_ERROR, "CreateWindowExA failed, GetLastError =", rax
    lea rdx, [rel window_class_name]
    API UnregisterClassA, rdx, [rel g_hinstance]
    xor eax, eax
    RETURN
.window_ok:
    mov [rel g_hwnd], rax
    API ShowWindow, rax, SW_SHOW

    ; ---- actual client size ----------------------------------------------------
    lea rsi, [LOCAL(WI_RECT)]
    API GetClientRect, [rel g_hwnd], rsi
    mov eax, [rsi + RECT.right]
    sub eax, [rsi + RECT.left]
    mov [rel g_client_w], eax
    mov eax, [rsi + RECT.bottom]
    sub eax, [rsi + RECT.top]
    mov [rel g_client_h], eax

    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_created]
    call log_append_str
    mov ecx, [rel g_client_w]
    call log_append_dec
    lea rcx, [rel str_x]
    call log_append_str
    mov ecx, [rel g_client_h]
    call log_append_dec
    call log_end

    ; ---- optional autoclose timer (automated test runs) -----------------------
    test ebx, ebx
    jz .no_autoclose
    API SetTimer, [rel g_hwnd], AUTOCLOSE_TIMER_ID, rbx, 0
    test rax, rax
    jnz .timer_ok
    LOG_WARN "SetTimer for autoclose failed"
    jmp .no_autoclose
.timer_ok:
    LOG_VAL LOG_LEVEL_INFO, "autoclose armed, ms =", rbx
.no_autoclose:
    mov eax, 1
    RETURN
ENDPROC

[section .rdata]
str_created:        db "window created, client area ", 0
str_x:              db " x ", 0
str_resized:        db "window resized to ", 0
__?SECT?__

; -----------------------------------------------------------------------------
; window_pump — dispatch all pending messages without blocking.
;   in:  none
;   out: eax = 1 to keep running, 0 if a close was requested or WM_QUIT was
;        received (g_exit_code set for WM_QUIT)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC window_pump, MSG_size, rbx
    lea rbx, [LOCAL(0)]
.next:
    API PeekMessageA, rbx, 0, 0, 0, PM_REMOVE
    test eax, eax
    jz .idle
    cmp dword [rbx + MSG.message], WM_QUIT
    je .quit
    API TranslateMessage, rbx
    API DispatchMessageA, rbx
    jmp .next
.quit:
    mov eax, [rbx + MSG.wParam]
    mov [rel g_exit_code], eax
    xor eax, eax
    RETURN
.idle:
    xor eax, eax
    cmp dword [rel g_close_requested], 0
    sete al
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; window_shutdown — destroy the window if it still exists and unregister the
; window class, and free the background brush.
;   in/out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC window_shutdown, 0
    mov rcx, [rel g_hwnd]
    test rcx, rcx
    jz .no_window
    API DestroyWindow, rcx
    mov qword [rel g_hwnd], 0
.no_window:
    lea rcx, [rel window_class_name]
    API UnregisterClassA, rcx, [rel g_hinstance]
    mov rcx, [rel g_background_brush]
    test rcx, rcx
    jz .no_brush
    API DeleteObject, rcx
    mov qword [rel g_background_brush], 0
.no_brush:
    LOG_INFO "window shut down"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; window_proc — WNDPROC for the main window (called by Windows).
;   in:  rcx = hwnd, edx = message, r8 = wParam, r9 = lParam
;   out: rax = message result
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC window_proc, 0, rbx, rsi, rdi, r12
    mov rbx, rcx                        ; hwnd
    mov esi, edx                        ; message
    mov rdi, r8                         ; wParam
    mov r12, r9                         ; lParam

    cmp esi, WM_CLOSE
    je .on_close
    cmp esi, WM_DESTROY
    je .on_destroy
    cmp esi, WM_SIZE
    je .on_size
    cmp esi, WM_INPUT
    je .on_input
    cmp esi, WM_KEYDOWN
    je .on_keydown
    cmp esi, WM_KEYUP
    je .on_keyup
    cmp esi, WM_SYSKEYDOWN
    je .on_syskeydown
    cmp esi, WM_SYSKEYUP
    je .on_syskeyup
    cmp esi, WM_LBUTTONDOWN
    jb .not_mouse
    cmp esi, WM_MBUTTONUP
    jbe .on_mouse_button
.not_mouse:
    cmp esi, WM_KILLFOCUS
    je .on_killfocus
    cmp esi, WM_TIMER
    je .on_timer
    cmp esi, WM_ACTIVATE
    je .on_activate
    cmp esi, WM_DPICHANGED
    je .on_dpichanged
.default:
    API DefWindowProcA, rbx, rsi, rdi, r12
    RETURN

.on_close:
    LOG_INFO "close requested"
    mov dword [rel g_close_requested], 1
    xor eax, eax
    RETURN

.on_destroy:
    LOG_INFO "window destroyed"
    API KillTimer, rbx, AUTOCLOSE_TIMER_ID
    mov qword [rel g_hwnd], 0
    API PostQuitMessage, 0
    xor eax, eax
    RETURN

.on_size:
    movzx eax, r12w
    mov [rel g_client_w], eax
    mov rax, r12
    shr eax, 16
    movzx eax, ax
    mov [rel g_client_h], eax
%if BUILD_DEBUG
    mov ecx, LOG_LEVEL_DEBUG
    call log_begin
    lea rcx, [rel str_resized]
    call log_append_str
    mov ecx, [rel g_client_w]
    call log_append_dec
    lea rcx, [rel str_x]
    call log_append_str
    mov ecx, [rel g_client_h]
    call log_append_dec
    call log_end
%endif
    xor eax, eax
    RETURN

.on_input:
    mov rcx, r12
    call input_on_raw_input
    jmp .default                        ; DefWindowProc must see WM_INPUT

.on_keydown:
    INVOKE input_on_key, rdi, 1
    xor eax, eax
    RETURN

.on_keyup:
    INVOKE input_on_key, rdi, 0
    xor eax, eax
    RETURN

.on_syskeydown:
    ; Alt/F10 combos: track them, but only Alt+F4 goes to DefWindowProc
    ; (closing); anything else would open the (nonexistent) system menu
    ; and pause the game.
    INVOKE input_on_key, rdi, 1
    cmp rdi, VK_F4
    je .default
    xor eax, eax
    RETURN

.on_syskeyup:
    INVOKE input_on_key, rdi, 0
    xor eax, eax
    RETURN

.on_mouse_button:
    ; WM_LBUTTONDOWN 0x201 .. WM_MBUTTONUP 0x208: map to VK_L/R/MBUTTON
    lea eax, [rsi - WM_LBUTTONDOWN]     ; 0..7
    cmp eax, 6                          ; 0x207 WM_MBUTTONDOWN
    je .mbutton_down
    cmp eax, 7
    je .mbutton_up
    cmp eax, 3
    je .rbutton_down
    cmp eax, 4
    je .rbutton_up
    cmp eax, 0
    je .lbutton_down
    cmp eax, 1
    je .lbutton_up
    jmp .default                        ; double-clicks (not enabled)
.lbutton_down:
    INVOKE input_on_key, VK_LBUTTON, 1
    jmp .button_done
.lbutton_up:
    INVOKE input_on_key, VK_LBUTTON, 0
    jmp .button_done
.rbutton_down:
    INVOKE input_on_key, VK_RBUTTON, 1
    jmp .button_done
.rbutton_up:
    INVOKE input_on_key, VK_RBUTTON, 0
    jmp .button_done
.mbutton_down:
    INVOKE input_on_key, VK_MBUTTON, 1
    jmp .button_done
.mbutton_up:
    INVOKE input_on_key, VK_MBUTTON, 0
.button_done:
    xor eax, eax
    RETURN

.on_killfocus:
    call input_on_focus_lost
    jmp .default

.on_timer:
    cmp rdi, AUTOCLOSE_TIMER_ID
    jne .default
    LOG_INFO "autoclose timer fired, closing"
    API KillTimer, rbx, AUTOCLOSE_TIMER_ID
    API PostMessageA, rbx, WM_CLOSE, 0, 0
    xor eax, eax
    RETURN

.on_activate:
    xor eax, eax
    test di, di                         ; LOWORD(wParam) = WA_INACTIVE (0)?
    setnz al
    mov [rel g_window_active], eax
    LOG_VAL LOG_LEVEL_DEBUG, "window active =", rax
    jmp .default

.on_dpichanged:
    ; lParam -> RECT with the suggested new window rectangle
    movzx eax, di
    LOG_VAL LOG_LEVEL_INFO, "DPI changed to", rax
    mov eax, [r12 + RECT.right]
    sub eax, [r12 + RECT.left]
    mov ecx, [r12 + RECT.bottom]
    sub ecx, [r12 + RECT.top]
    movsxd r8, dword [r12 + RECT.left]
    movsxd r9, dword [r12 + RECT.top]
    mov [rsp + 32], rax                 ; arg5 width
    mov [rsp + 40], rcx                 ; arg6 height
    mov qword [rsp + 48], SWP_NOZORDER | SWP_NOACTIVATE
    API SetWindowPos, rbx, 0
    xor eax, eax
    RETURN
ENDPROC
