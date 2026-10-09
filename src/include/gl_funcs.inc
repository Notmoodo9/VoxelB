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
GLFN glDepthFunc,               1
GLFN glClearDepthf,             1
GLFN glClipControl,             1
GLFN glBlendFunc,               1
GLFN glPixelStorei,             1
GLFN glCreateShader,            1
GLFN glShaderSource,            1
GLFN glCompileShader,           1
GLFN glGetShaderiv,             1
GLFN glGetShaderInfoLog,        1
GLFN glDeleteShader,            1
GLFN glCreateProgram,           1
GLFN glAttachShader,            1
GLFN glLinkProgram,             1
GLFN glGetProgramiv,            1
GLFN glGetProgramInfoLog,       1
GLFN glDeleteProgram,           1
GLFN glUseProgram,              1
GLFN glProgramUniformMatrix4fv, 1
GLFN glProgramUniform4fv,       1
GLFN glProgramUniform3fv,       1
GLFN glProgramUniform2fv,       1
GLFN glCreateVertexArrays,      1
GLFN glBindVertexArray,         1
GLFN glDeleteVertexArrays,      1
GLFN glDrawArrays,              1
GLFN glCreateBuffers,           1
GLFN glNamedBufferStorage,      1
GLFN glNamedBufferSubData,      1
GLFN glBindBufferBase,          1
GLFN glDeleteBuffers,           1
GLFN glCreateTextures,          1
GLFN glTextureStorage2D,        1
GLFN glTextureSubImage2D,       1
GLFN glTextureParameteri,       1
GLFN glBindTextureUnit,         1
GLFN glDeleteTextures,          1
GLFN glProgramUniform1ui,       1
GLFN glTextureStorage3D,        1
GLFN glTextureSubImage3D,       1
GLFN glClearTexImage,           1
GLFN glGenerateTextureMipmap,   1
GLFN glDepthMask,               1
GLFN glProgramUniform1f,        1
GLFN glProgramUniform1i,        1
