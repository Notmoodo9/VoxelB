; =============================================================================
; window.inc — main window interface (implementation: src/platform/window.asm).
; =============================================================================
%ifndef WINDOW_INC
%define WINDOW_INC

extern window_init, window_pump, window_shutdown
extern g_hwnd, g_hinstance, g_client_w, g_client_h, g_window_active, g_exit_code
extern g_close_requested

%endif
