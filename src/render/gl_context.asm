; =============================================================================
; gl_context.asm — OpenGL context creation through WGL, and the GL loader.
;
; Steps (gl_init):
;   1. Bootstrap: a hidden dummy window + legacy context, just long enough to
;      fetch wglCreateContextAttribsARB / wglChoosePixelFormatARB.
;   2. Choose a pixel format for the real window with wglChoosePixelFormatARB
;      (full acceleration preferred) and set it.
;   3. Create a 4.6 core context (debug context in debug builds); fall back
;      to 4.5 core with a warning (software renderers such as Mesa llvmpipe
;      stop at 4.5; see DECISIONS.md D10).
;   4. Load every function in gl_funcs.inc (wglGetProcAddress, falling back
;      to opengl32.dll exports for GL 1.1 entry points).
;   5. Debug builds: route KHR_debug messages into the log.
;
; Public API (see include/gl.inc):
;   gl_init() -> eax 1 ok / 0 fail      gl_shutdown()
;   gl_swap()                           gl_set_vsync(ecx = 0/1)
;   g_gl_major, g_gl_minor, g_vsync_on, g_vsync_supported, and one pointer per
;   GL function named exactly like the function (glClear, ...).
; =============================================================================
%define GL_LOADER_IMPL
%include "macros.inc"
%include "win32.inc"
%include "log.inc"
%include "gl.inc"
%include "window.inc"

global gl_init, gl_shutdown, gl_swap, gl_set_vsync
global g_gl_major, g_gl_minor, g_vsync_on, g_vsync_supported, g_gl_renderer

IMPORT GetModuleHandleA, GetProcAddress, GetLastError
IMPORT RegisterClassExA, UnregisterClassA, CreateWindowExA, DestroyWindow
IMPORT GetDC, ReleaseDC, DefWindowProcA
IMPORT ChoosePixelFormat, SetPixelFormat, DescribePixelFormat, SwapBuffers
IMPORT wglCreateContext, wglDeleteContext, wglMakeCurrent, wglGetProcAddress

; ---- function pointer slots, one per GLFN entry -----------------------------
section .bss
alignb 8
%macro GLFN 2
    global %1
    %1: resq 1
%endmacro
%include "gl_funcs.inc"
%unmacro GLFN 2

alignb 8
g_hdc:                          resq 1
g_hglrc:                        resq 1
p_wglCreateContextAttribsARB:   resq 1
p_wglChoosePixelFormatARB:      resq 1
p_wglSwapIntervalEXT:           resq 1
g_gl_major:                     resd 1
g_gl_minor:                     resd 1
g_vsync_on:                     resd 1
g_vsync_supported:              resd 1
alignb 8
g_gl_renderer:                  resq 1      ; glGetString(GL_RENDERER)

; ---- loader table: { name, slot, required } per GLFN entry ------------------------
section .rdata
%macro GLFN 2
    %defstr GLFN_NAME %1
    glname_%1: db GLFN_NAME, 0
%endmacro
%include "gl_funcs.inc"
%unmacro GLFN 2

align 8
gl_func_table:
%macro GLFN 2
    dq glname_%1, %1, %2
%endmacro
%include "gl_funcs.inc"
%unmacro GLFN 2
gl_func_count equ ($ - gl_func_table) / 24

str_dummy_class:        db "VoxelBGLBootstrap", 0
str_opengl32:           db "opengl32.dll", 0
str_wglCreateContextAttribsARB: db "wglCreateContextAttribsARB", 0
str_wglChoosePixelFormatARB:    db "wglChoosePixelFormatARB", 0
str_wglSwapIntervalEXT:         db "wglSwapIntervalEXT", 0
str_missing_req:        db "missing required GL function: ", 0
str_missing_opt:        db "optional GL function not available: ", 0
str_vendor:             db "GL vendor:   ", 0
str_renderer:           db "GL renderer: ", 0
str_version:            db "GL version:  ", 0
str_glsl:               db "GLSL:        ", 0
str_ctx_version:        db "OpenGL core context created, version ", 0
str_dot:                db ".", 0
str_gl_debug:           db "GL debug: ", 0
str_id_open:            db " (id ", 0
str_id_close:           db ")", 0

; Pixel format: the acceleration pair comes first so that pf_attribs + 8 is
; the same list without the acceleration requirement.
align 4
pf_attribs:
    dd WGL_ACCELERATION_ARB,    WGL_FULL_ACCELERATION_ARB
    dd WGL_DRAW_TO_WINDOW_ARB,  1
    dd WGL_SUPPORT_OPENGL_ARB,  1
    dd WGL_DOUBLE_BUFFER_ARB,   1
    dd WGL_PIXEL_TYPE_ARB,      WGL_TYPE_RGBA_ARB
    dd WGL_COLOR_BITS_ARB,      24
    dd WGL_ALPHA_BITS_ARB,      8
    dd WGL_DEPTH_BITS_ARB,      24
    dd WGL_STENCIL_BITS_ARB,    8
    dd 0

%if BUILD_DEBUG
    %define CTX_FLAGS WGL_CONTEXT_DEBUG_BIT_ARB
%else
    %define CTX_FLAGS 0
%endif
%macro CTX_ATTRIBS 2
    dd WGL_CONTEXT_MAJOR_VERSION_ARB, %1
    dd WGL_CONTEXT_MINOR_VERSION_ARB, %2
    dd WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB
    dd WGL_CONTEXT_FLAGS_ARB,         CTX_FLAGS
    dd 0
%endmacro
ctx_attribs_46: CTX_ATTRIBS 4, 6
ctx_attribs_45: CTX_ATTRIBS 4, 5

section .text

; -----------------------------------------------------------------------------
; gl_get_proc — resolve a GL/WGL entry point by name.
;   in:  rcx = zero-terminated function name
;   out: rax = function address, or 0 if unavailable
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gl_get_proc, 0, rbx
    mov rbx, rcx
    API wglGetProcAddress, rbx
    cmp rax, 3                          ; 0,1,2,3 are failure values
    jbe .fallback
    cmp rax, -1                         ; and so is -1
    je .fallback
    RETURN
.fallback:
    lea rcx, [rel str_opengl32]
    API GetModuleHandleA, rcx
    test rax, rax
    jz .none
    API GetProcAddress, rax, rbx
    RETURN
.none:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gl_bootstrap_wgl — create a throwaway window + legacy context and fetch the
; WGL extension entry points needed to create the real context.
;   in:  none (uses g_hinstance)
;   out: eax = 1 if wglCreateContextAttribsARB and wglChoosePixelFormatARB
;        were found, 0 otherwise
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define BS_WC   0
%define BS_PFD  WNDCLASSEXA_size
PROC gl_bootstrap_wgl, WNDCLASSEXA_size + PIXELFORMATDESCRIPTOR_size, rbx, rsi, rdi, r12
    xor ebx, ebx                        ; rbx = dummy hwnd
    xor esi, esi                        ; rsi = dummy hdc
    xor edi, edi                        ; rdi = legacy context
    xor r12d, r12d                      ; r12 = result

    lea rdi, [LOCAL(BS_WC)]
    xor eax, eax
    mov ecx, WNDCLASSEXA_size + PIXELFORMATDESCRIPTOR_size
    rep stosb
    xor edi, edi
    lea rcx, [LOCAL(BS_WC)]
    mov dword [rcx + WNDCLASSEXA.cbSize], WNDCLASSEXA_size
    mov dword [rcx + WNDCLASSEXA.style], CS_OWNDC
    mov rax, [rel __imp_DefWindowProcA]
    mov [rcx + WNDCLASSEXA.lpfnWndProc], rax
    mov rax, [rel g_hinstance]
    mov [rcx + WNDCLASSEXA.hInstance], rax
    lea rax, [rel str_dummy_class]
    mov [rcx + WNDCLASSEXA.lpszClassName], rax
    API RegisterClassExA, rcx
    test ax, ax
    jnz .class_ok
    LOG_ERROR "GL bootstrap: RegisterClassExA failed"
    xor eax, eax
    RETURN
.class_ok:
    lea rdx, [rel str_dummy_class]
    mov r8, rdx                         ; window title = class name
    API CreateWindowExA, 0, rdx, r8, WS_OVERLAPPEDWINDOW, 0, 0, 16, 16, 0, 0, [rel g_hinstance], 0
    mov rbx, rax
    test rbx, rbx
    jnz .wnd_ok
    LOG_ERROR "GL bootstrap: CreateWindowExA failed"
    jmp .cleanup
.wnd_ok:
    API GetDC, rbx
    mov rsi, rax

    lea rdx, [LOCAL(BS_PFD)]
    mov word [rdx + PIXELFORMATDESCRIPTOR.nSize], PIXELFORMATDESCRIPTOR_size
    mov word [rdx + PIXELFORMATDESCRIPTOR.nVersion], 1
    mov dword [rdx + PIXELFORMATDESCRIPTOR.dwFlags], PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER
    mov byte [rdx + PIXELFORMATDESCRIPTOR.iPixelType], PFD_TYPE_RGBA
    mov byte [rdx + PIXELFORMATDESCRIPTOR.cColorBits], 32
    mov byte [rdx + PIXELFORMATDESCRIPTOR.cDepthBits], 24
    mov byte [rdx + PIXELFORMATDESCRIPTOR.cStencilBits], 8
    API ChoosePixelFormat, rsi, rdx
    test eax, eax
    jnz .pf_ok
    LOG_ERROR "GL bootstrap: ChoosePixelFormat failed"
    jmp .cleanup
.pf_ok:
    lea r8, [LOCAL(BS_PFD)]
    API SetPixelFormat, rsi, rax, r8
    test eax, eax
    jnz .spf_ok
    LOG_ERROR "GL bootstrap: SetPixelFormat failed"
    jmp .cleanup
.spf_ok:
    API wglCreateContext, rsi
    mov rdi, rax
    test rdi, rdi
    jnz .ctx_ok
    LOG_ERROR "GL bootstrap: wglCreateContext failed"
    jmp .cleanup
.ctx_ok:
    API wglMakeCurrent, rsi, rdi
    test eax, eax
    jnz .current_ok
    LOG_ERROR "GL bootstrap: wglMakeCurrent failed"
    jmp .cleanup
.current_ok:
    lea rcx, [rel str_wglCreateContextAttribsARB]
    call gl_get_proc
    mov [rel p_wglCreateContextAttribsARB], rax
    lea rcx, [rel str_wglChoosePixelFormatARB]
    call gl_get_proc
    mov [rel p_wglChoosePixelFormatARB], rax
    cmp qword [rel p_wglCreateContextAttribsARB], 0
    je .cleanup
    cmp qword [rel p_wglChoosePixelFormatARB], 0
    je .cleanup
    mov r12d, 1

.cleanup:
    API wglMakeCurrent, 0, 0
    test rdi, rdi
    jz .no_ctx
    API wglDeleteContext, rdi
.no_ctx:
    test rbx, rbx
    jz .no_wnd
    API ReleaseDC, rbx, rsi
    API DestroyWindow, rbx
.no_wnd:
    lea rcx, [rel str_dummy_class]
    API UnregisterClassA, rcx, [rel g_hinstance]
    mov eax, r12d
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; log_gl_string — log "<prefix><glGetString(name)>".
;   in:  rcx = prefix string, edx = GL string enum
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC log_gl_string, 0, rbx, rsi
    mov rbx, rcx
    GL glGetString, rdx
    mov rsi, rax
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    mov rcx, rbx
    call log_append_str
    mov rcx, rsi
    call log_append_str
    call log_end
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gl_load_functions — fill every pointer slot listed in gl_funcs.inc.
;   in:  none (a context must be current)
;   out: eax = 1 if all required functions were found, 0 otherwise
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gl_load_functions, 0, rbx, rsi, rdi
    lea rbx, [rel gl_func_table]
    mov esi, gl_func_count
    mov edi, 1                          ; rdi = result
.next:
    mov rcx, [rbx]
    call gl_get_proc
    mov rcx, [rbx + 8]
    mov [rcx], rax
    test rax, rax
    jnz .advance
    ; missing
    cmp qword [rbx + 16], 0
    je .optional
    xor edi, edi
    mov ecx, LOG_LEVEL_ERROR
    call log_begin
    lea rcx, [rel str_missing_req]
    jmp .log_name
.optional:
    mov ecx, LOG_LEVEL_WARN
    call log_begin
    lea rcx, [rel str_missing_opt]
.log_name:
    call log_append_str
    mov rcx, [rbx]
    call log_append_str
    call log_end
.advance:
    add rbx, 24
    dec esi
    jnz .next
    LOG_VAL LOG_LEVEL_INFO, "GL functions resolved:", gl_func_count
    mov eax, edi
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gl_init — create the OpenGL context for the main window (g_hwnd) and load
; all GL functions.
;   in:  none
;   out: eax = 1 on success, 0 on failure (reason logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define GI_PFD      0
%define GI_FORMAT   PIXELFORMATDESCRIPTOR_size
%define GI_COUNT    PIXELFORMATDESCRIPTOR_size + 8
PROC gl_init, PIXELFORMATDESCRIPTOR_size + 16, rbx, rsi, rdi
    call gl_bootstrap_wgl
    test eax, eax
    jnz .bootstrap_ok
    LOG_ERROR "WGL_ARB_create_context / WGL_ARB_pixel_format not available (no OpenGL 3+ driver?)"
    xor eax, eax
    RETURN
.bootstrap_ok:
    API GetDC, [rel g_hwnd]
    mov [rel g_hdc], rax
    mov rbx, rax                        ; rbx = hdc

    ; ---- pixel format ----------------------------------------------------------
    lea rdx, [rel pf_attribs]
    lea r11, [LOCAL(GI_FORMAT)]
    mov [rsp + 32], r11
    lea r11, [LOCAL(GI_COUNT)]
    mov [rsp + 40], r11
    mov dword [LOCAL(GI_COUNT)], 0
    INVOKE [rel p_wglChoosePixelFormatARB], rbx, rdx, 0, 1
    test eax, eax
    jz .pf_retry
    cmp dword [LOCAL(GI_COUNT)], 0
    jne .pf_found
.pf_retry:
    LOG_WARN "no fully accelerated pixel format; retrying without that requirement"
    lea rdx, [rel pf_attribs + 8]
    lea r11, [LOCAL(GI_FORMAT)]
    mov [rsp + 32], r11
    lea r11, [LOCAL(GI_COUNT)]
    mov [rsp + 40], r11
    mov dword [LOCAL(GI_COUNT)], 0
    INVOKE [rel p_wglChoosePixelFormatARB], rbx, rdx, 0, 1
    test eax, eax
    jz .pf_fail
    cmp dword [LOCAL(GI_COUNT)], 0
    jne .pf_found
.pf_fail:
    LOG_ERROR "wglChoosePixelFormatARB found no usable pixel format"
    xor eax, eax
    RETURN
.pf_found:
    mov esi, [LOCAL(GI_FORMAT)]         ; rsi = pixel format index
    lea r9, [LOCAL(GI_PFD)]
    API DescribePixelFormat, rbx, rsi, PIXELFORMATDESCRIPTOR_size, r9
    lea r8, [LOCAL(GI_PFD)]
    API SetPixelFormat, rbx, rsi, r8
    test eax, eax
    jnz .spf_ok
    API GetLastError
    LOG_VAL LOG_LEVEL_ERROR, "SetPixelFormat failed, GetLastError =", rax
    xor eax, eax
    RETURN
.spf_ok:
    LOG_VAL LOG_LEVEL_INFO, "pixel format selected:", rsi

    ; ---- context: 4.6 core, else 4.5 core ----------------------------------------
    lea r8, [rel ctx_attribs_46]
    INVOKE [rel p_wglCreateContextAttribsARB], rbx, 0, r8
    test rax, rax
    jnz .ctx_ok
    LOG_WARN "OpenGL 4.6 core context unavailable; trying 4.5 core"
    lea r8, [rel ctx_attribs_45]
    INVOKE [rel p_wglCreateContextAttribsARB], rbx, 0, r8
    test rax, rax
    jnz .ctx_ok
    LOG_ERROR "could not create an OpenGL 4.5+ core context"
    xor eax, eax
    RETURN
.ctx_ok:
    mov [rel g_hglrc], rax
    API wglMakeCurrent, rbx, rax
    test eax, eax
    jnz .current_ok
    LOG_ERROR "wglMakeCurrent failed for the main context"
    xor eax, eax
    RETURN
.current_ok:

    ; ---- functions ----------------------------------------------------------------
    call gl_load_functions
    test eax, eax
    jnz .funcs_ok
    xor eax, eax
    RETURN
.funcs_ok:
    lea rcx, [rel str_wglSwapIntervalEXT]
    call gl_get_proc
    mov [rel p_wglSwapIntervalEXT], rax
    xor ecx, ecx
    test rax, rax
    setnz cl
    mov [rel g_vsync_supported], ecx

    ; ---- report ---------------------------------------------------------------
    lea rdx, [rel g_gl_major]
    GL glGetIntegerv, GL_MAJOR_VERSION, rdx
    lea rdx, [rel g_gl_minor]
    GL glGetIntegerv, GL_MINOR_VERSION, rdx
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_ctx_version]
    call log_append_str
    mov ecx, [rel g_gl_major]
    call log_append_dec
    lea rcx, [rel str_dot]
    call log_append_str
    mov ecx, [rel g_gl_minor]
    call log_append_dec
    call log_end
    lea rcx, [rel str_vendor]
    INVOKE log_gl_string, rcx, GL_VENDOR
    lea rcx, [rel str_renderer]
    INVOKE log_gl_string, rcx, GL_RENDERER
    GL glGetString, GL_RENDERER
    mov [rel g_gl_renderer], rax
    lea rcx, [rel str_version]
    INVOKE log_gl_string, rcx, GL_VERSION
    lea rcx, [rel str_glsl]
    INVOKE log_gl_string, rcx, GL_SHADING_LANGUAGE_VERSION

%if BUILD_DEBUG
    ; ---- debug output into the log -------------------------------------------------
    cmp qword [rel glDebugMessageCallback], 0
    je .no_debug
    GL glEnable, GL_DEBUG_OUTPUT
    GL glEnable, GL_DEBUG_OUTPUT_SYNCHRONOUS
    lea rcx, [rel gl_debug_callback]
    GL glDebugMessageCallback, rcx, 0
    cmp qword [rel glDebugMessageControl], 0
    je .debug_on
    ; drop NOTIFICATION severity at the driver (also filtered in the callback)
    GL glDebugMessageControl, GL_DONT_CARE, GL_DONT_CARE, GL_DEBUG_SEVERITY_NOTIFICATION, 0, 0, 0
.debug_on:
    LOG_INFO "GL debug output enabled"
.no_debug:
%endif
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gl_set_vsync — enable/disable vertical sync (swap interval 1/0).
;   in:  ecx = 1 for on, 0 for off
;   out: none (g_vsync_on reflects the applied state)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gl_set_vsync, 0, rbx
    mov ebx, ecx
    mov rax, [rel p_wglSwapIntervalEXT]
    test rax, rax
    jnz .supported
    LOG_WARN "WGL_EXT_swap_control unavailable; vsync is controlled by the driver"
    RETURN
.supported:
    INVOKE rax, rbx
    test eax, eax
    jz .failed
    mov [rel g_vsync_on], ebx
    LOG_VAL LOG_LEVEL_INFO, "vsync =", rbx
    RETURN
.failed:
    LOG_WARN "wglSwapIntervalEXT failed"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gl_swap — present the back buffer.
;   in/out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gl_swap, 0
    API SwapBuffers, [rel g_hdc]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gl_shutdown — release the context and the window DC.
;   in/out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gl_shutdown, 0
    API wglMakeCurrent, 0, 0
    mov rcx, [rel g_hglrc]
    test rcx, rcx
    jz .no_ctx
    API wglDeleteContext, rcx
    mov qword [rel g_hglrc], 0
.no_ctx:
    mov rdx, [rel g_hdc]
    test rdx, rdx
    jz .no_dc
    API ReleaseDC, [rel g_hwnd], rdx
    mov qword [rel g_hdc], 0
.no_dc:
    LOG_INFO "OpenGL context released"
    RETURN
ENDPROC

%if BUILD_DEBUG
; -----------------------------------------------------------------------------
; gl_debug_callback — GLDEBUGPROC; logs driver messages (debug builds only).
;   in:  ecx = source, edx = type, r8d = id, r9d = severity,
;        ARG(5) = length, ARG(6) = message, ARG(7) = user param
;   out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gl_debug_callback, 0, rbx, rsi, rdi
    mov esi, r8d                        ; id
    mov edi, r9d                        ; severity
    mov rbx, [ARG(6)]                   ; message
    cmp edi, GL_DEBUG_SEVERITY_NOTIFICATION
    je .done
    mov ecx, LOG_LEVEL_WARN
    cmp edi, GL_DEBUG_SEVERITY_HIGH
    jne .level_ok
    mov ecx, LOG_LEVEL_ERROR
.level_ok:
    call log_begin
    lea rcx, [rel str_gl_debug]
    call log_append_str
    mov rcx, rbx
    call log_append_str
    lea rcx, [rel str_id_open]
    call log_append_str
    mov ecx, esi
    call log_append_dec
    lea rcx, [rel str_id_close]
    call log_append_str
    call log_end
.done:
    RETURN
ENDPROC
%endif
