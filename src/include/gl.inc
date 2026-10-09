; =============================================================================
; gl.inc — OpenGL / WGL constants, function pointers and the GL call macro.
; Implementation: src/render/gl_context.asm (context + loader).
;
;   GL glClear, GL_COLOR_BUFFER_BIT     call through the loaded pointer
; Float arguments go in xmm0-xmm3 by position (Win64); load them yourself
; before GL, it only moves integer/pointer arguments.
; =============================================================================
%ifndef GL_INC
%define GL_INC

; ---- GL ----------------------------------------------------------------------
%define GL_NO_ERROR                     0
%define GL_DEPTH_BUFFER_BIT             0x00000100
%define GL_STENCIL_BUFFER_BIT           0x00000400
%define GL_COLOR_BUFFER_BIT             0x00004000
%define GL_VENDOR                       0x1F00
%define GL_RENDERER                     0x1F01
%define GL_VERSION                      0x1F02
%define GL_EXTENSIONS                   0x1F03
%define GL_SHADING_LANGUAGE_VERSION     0x8B8C
%define GL_MAJOR_VERSION                0x821B
%define GL_MINOR_VERSION                0x821C
%define GL_NUM_EXTENSIONS               0x821D
%define GL_CONTEXT_FLAGS                0x821E
%define GL_CONTEXT_FLAG_DEBUG_BIT       0x00000002
%define GL_DEBUG_OUTPUT_SYNCHRONOUS     0x8242
%define GL_DEBUG_OUTPUT                 0x92E0
%define GL_DEBUG_SEVERITY_HIGH          0x9146
%define GL_DEBUG_SEVERITY_MEDIUM        0x9147
%define GL_DEBUG_SEVERITY_LOW           0x9148
%define GL_DEBUG_SEVERITY_NOTIFICATION  0x826B
%define GL_DONT_CARE                    0x1100
%define GL_FALSE                        0
%define GL_TRUE                         1
%define GL_TRIANGLES                    0x0004
%define GL_DEPTH_TEST                   0x0B71
%define GL_CULL_FACE                    0x0B44
%define GL_BLEND                        0x0BE2
%define GL_GREATER                      0x0204
%define GL_SRC_ALPHA                    0x0302
%define GL_ONE_MINUS_SRC_ALPHA          0x0303
%define GL_LOWER_LEFT                   0x8CA1
%define GL_ZERO_TO_ONE                  0x935F
%define GL_UNPACK_ALIGNMENT             0x0CF5
%define GL_TEXTURE_2D                   0x0DE1
%define GL_TEXTURE_MAG_FILTER           0x2800
%define GL_TEXTURE_MIN_FILTER           0x2801
%define GL_TEXTURE_WRAP_S               0x2802
%define GL_TEXTURE_WRAP_T               0x2803
%define GL_NEAREST                      0x2600
%define GL_LINEAR                       0x2601
%define GL_CLAMP_TO_EDGE                0x812F
%define GL_REPEAT                       0x2901
%define GL_NEAREST_MIPMAP_LINEAR        0x2702
%define GL_LINEAR_MIPMAP_LINEAR         0x2703
%define GL_TEXTURE_2D_ARRAY             0x8C1A
%define GL_TEXTURE_MAX_ANISOTROPY       0x84FE
%define GL_MAX_ARRAY_TEXTURE_LAYERS     0x88FF
%define GL_RGBA                         0x1908
%define GL_RGBA8                        0x8058
%define GL_RED                          0x1903
%define GL_R8                           0x8229
%define GL_UNSIGNED_BYTE                0x1401
%define GL_FRAGMENT_SHADER              0x8B30
%define GL_VERTEX_SHADER                0x8B31
%define GL_COMPILE_STATUS               0x8B81
%define GL_LINK_STATUS                  0x8B82
%define GL_INFO_LOG_LENGTH              0x8B84
%define GL_SHADER_STORAGE_BUFFER        0x90D2
%define GL_DYNAMIC_STORAGE_BIT          0x0100

; ---- WGL_ARB_pixel_format / create_context ----------------------------------------
%define WGL_DRAW_TO_WINDOW_ARB          0x2001
%define WGL_ACCELERATION_ARB            0x2003
%define WGL_SUPPORT_OPENGL_ARB          0x2010
%define WGL_DOUBLE_BUFFER_ARB           0x2011
%define WGL_PIXEL_TYPE_ARB              0x2013
%define WGL_COLOR_BITS_ARB              0x2014
%define WGL_ALPHA_BITS_ARB              0x201B
%define WGL_DEPTH_BITS_ARB              0x2022
%define WGL_STENCIL_BITS_ARB            0x2023
%define WGL_FULL_ACCELERATION_ARB       0x2027
%define WGL_TYPE_RGBA_ARB               0x202B
%define WGL_CONTEXT_MAJOR_VERSION_ARB   0x2091
%define WGL_CONTEXT_MINOR_VERSION_ARB   0x2092
%define WGL_CONTEXT_FLAGS_ARB           0x2094
%define WGL_CONTEXT_DEBUG_BIT_ARB       0x0001
%define WGL_CONTEXT_PROFILE_MASK_ARB    0x9126
%define WGL_CONTEXT_CORE_PROFILE_BIT_ARB 0x0001

; ---- legacy pixel format descriptor (gdi32) -----------------------------------------
%define PFD_DOUBLEBUFFER                0x00000001
%define PFD_DRAW_TO_WINDOW              0x00000004
%define PFD_SUPPORT_OPENGL              0x00000020
%define PFD_TYPE_RGBA                   0

struc PIXELFORMATDESCRIPTOR
    .nSize          resw 1
    .nVersion       resw 1
    .dwFlags        resd 1
    .iPixelType     resb 1
    .cColorBits     resb 1
    .cRedBits       resb 1
    .cRedShift      resb 1
    .cGreenBits     resb 1
    .cGreenShift    resb 1
    .cBlueBits      resb 1
    .cBlueShift     resb 1
    .cAlphaBits     resb 1
    .cAlphaShift    resb 1
    .cAccumBits     resb 1
    .cAccumRedBits  resb 1
    .cAccumGreenBits resb 1
    .cAccumBlueBits resb 1
    .cAccumAlphaBits resb 1
    .cDepthBits     resb 1
    .cStencilBits   resb 1
    .cAuxBuffers    resb 1
    .iLayerType     resb 1
    .bReserved      resb 1
    .dwLayerMask    resd 1
    .dwVisibleMask  resd 1
    .dwDamageMask   resd 1
endstruc

; ---- function pointers -------------------------------------------------------
%ifndef GL_LOADER_IMPL
    %macro GLFN 2
        extern %1
    %endmacro
    %include "gl_funcs.inc"
    %unmacro GLFN 2

    extern gl_init, gl_shutdown, gl_swap, gl_set_vsync
    extern g_gl_major, g_gl_minor, g_vsync_on, g_vsync_supported, g_gl_renderer
%endif

%macro GL 1-*
    %if %0 > 1
        SETARGS %{2:-1}
    %endif
    call [rel %1]
%endmacro

%endif
