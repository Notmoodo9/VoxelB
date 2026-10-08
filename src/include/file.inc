; =============================================================================
; file.inc — file access and root-path interface (src/platform/file.asm).
; =============================================================================
%ifndef FILE_INC
%define FILE_INC

%define PATH_CAP    520                 ; bytes for any absolute path we build

%ifndef FILE_IMPL
extern paths_init, path_make, file_read_all, file_mtime, g_root_dir
%endif

%endif
