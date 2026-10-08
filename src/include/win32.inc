; =============================================================================
; win32.inc — Win32 constants and structure layouts (x64).
; Only what the engine uses; extend as new APIs are needed.
; =============================================================================
%ifndef WIN32_INC
%define WIN32_INC

; ---- general ---------------------------------------------------------------
%define NULL                        0
%define INVALID_HANDLE_VALUE        -1
%define ERROR_ACCESS_DENIED         5

; ---- files / console -------------------------------------------------------
%define GENERIC_WRITE               0x40000000
%define FILE_SHARE_READ             0x00000001
%define CREATE_ALWAYS               2
%define FILE_ATTRIBUTE_NORMAL       0x00000080
%define STD_OUTPUT_HANDLE           -11
%define ATTACH_PARENT_PROCESS       0xFFFFFFFF
%define MAX_PATH                    260

; ---- window classes / styles -----------------------------------------------
%define CS_VREDRAW                  0x0001
%define CS_HREDRAW                  0x0002
%define CS_OWNDC                    0x0020
%define WS_OVERLAPPEDWINDOW         0x00CF0000
%define WS_VISIBLE                  0x10000000
%define CW_USEDEFAULT               0x80000000
%define IDC_ARROW                   32512
%define IDI_APPLICATION             32512
%define SW_SHOW                     5
%define SM_CXSCREEN                 0
%define SM_CYSCREEN                 1
%define SWP_NOZORDER                0x0004
%define SWP_NOACTIVATE              0x0010
%define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE     -3
%define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2  -4

; ---- messages --------------------------------------------------------------
%define WM_DESTROY                  0x0002
%define WM_SIZE                     0x0005
%define WM_ACTIVATE                 0x0006
%define WM_CLOSE                    0x0010
%define WM_QUIT                     0x0012
%define WM_KILLFOCUS                0x0008
%define WM_INPUT                    0x00FF
%define WM_KEYDOWN                  0x0100
%define WM_KEYUP                    0x0101
%define WM_SYSKEYDOWN               0x0104
%define WM_SYSKEYUP                 0x0105
%define WM_LBUTTONDOWN              0x0201
%define WM_MBUTTONUP                0x0208
%define WM_TIMER                    0x0113
%define WM_DPICHANGED               0x02E0
%define PM_REMOVE                   0x0001
%define VK_ESCAPE                   0x1B
%define VK_F4                       0x73

; ---- message boxes ---------------------------------------------------------
%define MB_OK                       0x00000000
%define MB_ICONERROR                0x00000010

; ---- structures ------------------------------------------------------------
struc WNDCLASSEXA
    .cbSize         resd 1
    .style          resd 1
    .lpfnWndProc    resq 1
    .cbClsExtra     resd 1
    .cbWndExtra     resd 1
    .hInstance      resq 1
    .hIcon          resq 1
    .hCursor        resq 1
    .hbrBackground  resq 1
    .lpszMenuName   resq 1
    .lpszClassName  resq 1
    .hIconSm        resq 1
endstruc

struc POINT
    .x              resd 1
    .y              resd 1
endstruc

struc MSG
    .hwnd           resq 1
    .message        resd 1
    .pad0           resd 1
    .wParam         resq 1
    .lParam         resq 1
    .time           resd 1
    .pt             resb POINT_size
    .lPrivate       resd 1
endstruc

struc RECT
    .left           resd 1
    .top            resd 1
    .right          resd 1
    .bottom         resd 1
endstruc

%endif
