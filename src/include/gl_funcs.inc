; =============================================================================
; gl_funcs.inc — X-macro list of every OpenGL entry point the engine loads.
;   GLFN name, required    (required = 1: missing -> startup fails;
;                           required = 0: missing -> pointer stays 0, warn)
; The includer defines GLFN before including this file. Add new functions
; here; the loader (src/render/gl_context.asm) picks them up automatically.
; =============================================================================
GLFN glGetError,                1
GLFN glGetString,               1
GLFN glGetStringi,              1
GLFN glGetIntegerv,             1
GLFN glEnable,                  1
GLFN glDisable,                 1
GLFN glViewport,                1
GLFN glClearColor,              1
GLFN glClear,                   1
GLFN glFinish,                  1
GLFN glDebugMessageCallback,    0
GLFN glDebugMessageControl,     0
