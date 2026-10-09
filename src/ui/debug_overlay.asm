; =============================================================================
; debug_overlay.asm — F3-style debug text overlay.
;
; Shows FPS and frame times, vsync, GL version/renderer, camera position and
; orientation, mouse capture state, shader status and the current key
; bindings. Toggled by the toggle_debug_overlay action; visible at start.
; World stats (chunk, biome, light, gen/mesh times, GPU memory) are added by
; the milestones that create them.
;
; Public API:
;   overlay_draw(ecx=w, edx=h)     draw if visible (uses the text batch)
;   overlay_toggle()
;   g_overlay_visible
; =============================================================================
%include "macros.inc"
%include "gl.inc"
%include "input.inc"
%include "shader.inc"
%include "text.inc"
%include "jobs.inc"
%include "world_api.inc"

global overlay_draw, overlay_toggle, g_overlay_visible

extern str_copy, str_append_dec, str_append_sdec
extern g_stat_fps_x10, g_stat_avg_us, g_stat_min_us, g_stat_max_us
extern g_cam_pos, g_cam_yaw, g_cam_pitch
extern g_sections_live, g_section_bytes
extern g_world_visible, g_world_drawn_quads, g_world_gpu_bytes
extern g_block_names

%define TEXT_CAP        6144
%define PAD             6               ; panel padding (unscaled pixels)
%define NAME_COLUMN     24              ; binding list: key column
%define COLOR_TEXT      0xFFFFFFFF
%define COLOR_PANEL     0xA8101010
%define COLOR_ERROR     0xFF4040FF      ; 0xAABBGGRR: bright red

section .rdata
s_title:        db "VoxelB debug overlay  (", 0
s_title_end:    db " hides)", 10, 0
s_fps:          db "FPS ", 0
s_frame:        db "   frame ", 0
s_min:          db " ms  (min ", 0
s_max:          db ", max ", 0
s_close:        db ")", 10, 0
s_vsync_on:     db "vsync on    OpenGL ", 0
s_vsync_off:    db "vsync off   OpenGL ", 0
s_dot:          db ".", 0
s_spaces:       db "   ", 0
s_nl:           db 10, 0
s_pos:          db "pos   x ", 0
s_y:            db "   y ", 0
s_z:            db "   z ", 0
s_yaw:          db "yaw ", 0
s_pitch:        db "   pitch ", 0
s_facing:       db "   facing ", 0
s_north:        db "north (-Z)", 0
s_east:         db "east (+X)", 0
s_south:        db "south (+Z)", 0
s_west:         db "west (-X)", 0
s_mouse_cap:    db "mouse captured  (menu key releases it)", 10, 0
s_mouse_free:   db "mouse free  (click to capture; menu key again quits)", 10, 0
s_shaders:      db "shaders ", 0
s_programs:     db " programs, ", 0
s_reloads:      db " reloads, last ", 0
s_ok:           db "ok", 10, 0
s_failed:       db "FAILED", 10, 0
s_memory:       db "memory  committed ", 0
s_mb:           db " MB   perm ", 0
s_frame_kb:     db " MB   frame ", 0
s_kb_peak:      db " KB (peak ", 0
s_kb_close:     db " KB)", 10, 0
s_jobs:         db "jobs    ", 0
s_workers:      db " workers + main   completed ", 0
s_queue:        db "   queued ", 0
s_world:        db "world   columns ", 0
s_w_sections:   db "  sections ", 0
s_w_mb_open:    db " (", 0
s_w_mb_close:   db " MB)  with geometry ", 0
s_w_quads:      db "  quads ", 0
s_w_gpu:        db "  GPU ", 0
s_w_mb_nl:      db " MB", 10, 0
s_draw:         db "draw    visible sections ", 0
s_d_quads:      db "  quads ", 0
s_gen:          db "gen     ", 0
s_ms_wall:      db " ms wall  avg ", 0
s_us_col:       db " us/column  max ", 0
s_us_nl:        db " us", 10, 0
s_mesh:         db "mesh    ", 0
s_us_sec:       db " us/section  max ", 0
s_chunk:        db "chunk   ", 0
s_sp:           db " ", 0
s_ground:       db "   ground below: ", 0
s_at_y:         db " at y ", 0
s_none:         db "none", 0
s_controls:     db 10, "controls (data/config/controls.cfg):", 10, 0
s_indent:       db "  ", 0
s_comma:        db ", ", 0
s_shader_err:   db "SHADER ERROR: last reload failed, see voxel.log", 0
align 8
facing_names:   dq s_north, s_east, s_south, s_west
align 4
c_100:          dd 100.0
c_rad2deg10:    dd 572.957795               ; degrees * 10
c_rad2deg:      dd 57.2957795
c_45:           dd 45.0

section .data
align 4
g_overlay_visible:  dd 1

section .bss
alignb 8
g_ov_text:      resq 1                  ; TEXT_CAP bytes from the frame arena

section .text

; -----------------------------------------------------------------------------
; overlay_toggle — show/hide the overlay.
;   clobbers: none
; -----------------------------------------------------------------------------
overlay_toggle:
    xor dword [rel g_overlay_visible], 1
    ret

; -----------------------------------------------------------------------------
; build_text — compose the overlay text into g_ov_text.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC build_text, 0, rbx, rsi, rdi, r12, r13
    mov rbx, [rel g_ov_text]            ; rbx = cursor
%macro PUT 1                            ; append a static string
    lea rdx, [rel %1]
    INVOKE str_copy, rbx, rdx
    mov rbx, rax
%endmacro
%macro PUTP 1                           ; append a string held in a register/memory
    INVOKE str_copy, rbx, %1
    mov rbx, rax
%endmacro
%macro PUTNUM 2                         ; append unsigned fixed-point: value, frac
    INVOKE str_append_dec, rbx, %1, %2
    mov rbx, rax
%endmacro
%macro PUTSNUM 2                        ; append signed fixed-point: value, frac
    INVOKE str_append_sdec, rbx, %1, %2
    mov rbx, rax
%endmacro

    ; title (with the actual toggle key)
    PUT s_title
    lea rax, [rel g_bindings]
    movzx ecx, byte [rax + ACT_TOGGLE_OVERLAY * BINDS_PER_ACTION]
    call input_key_name
    PUTP rax
    PUT s_title_end

    ; timing
    PUT s_fps
    PUTNUM [rel g_stat_fps_x10], 1
    PUT s_frame
    PUTNUM [rel g_stat_avg_us], 3
    PUT s_min
    PUTNUM [rel g_stat_min_us], 3
    PUT s_max
    PUTNUM [rel g_stat_max_us], 3
    PUT s_close

    ; vsync + GL
    lea rdx, [rel s_vsync_on]
    cmp dword [rel g_vsync_on], 0
    jne .vs
    lea rdx, [rel s_vsync_off]
.vs:
    INVOKE str_copy, rbx, rdx
    mov rbx, rax
    mov eax, [rel g_gl_major]
    PUTNUM rax, 0
    PUT s_dot
    mov eax, [rel g_gl_minor]
    PUTNUM rax, 0
    PUT s_spaces
    mov rax, [rel g_gl_renderer]
    test rax, rax
    jz .no_renderer
    PUTP rax
.no_renderer:
    PUT s_nl

    ; camera position (2 decimals)
    PUT s_pos
    movss xmm0, [rel g_cam_pos]
    mulss xmm0, [rel c_100]
    cvtss2si rax, xmm0
    PUTSNUM rax, 2
    PUT s_y
    movss xmm0, [rel g_cam_pos + 4]
    mulss xmm0, [rel c_100]
    cvtss2si rax, xmm0
    PUTSNUM rax, 2
    PUT s_z
    movss xmm0, [rel g_cam_pos + 8]
    mulss xmm0, [rel c_100]
    cvtss2si rax, xmm0
    PUTSNUM rax, 2
    PUT s_nl

    ; orientation (1 decimal, degrees)
    PUT s_yaw
    movss xmm0, [rel g_cam_yaw]
    mulss xmm0, [rel c_rad2deg10]
    cvtss2si rax, xmm0
    PUTSNUM rax, 1
    PUT s_pitch
    movss xmm0, [rel g_cam_pitch]
    mulss xmm0, [rel c_rad2deg10]
    cvtss2si rax, xmm0
    PUTSNUM rax, 1
    PUT s_facing
    movss xmm0, [rel g_cam_yaw]
    mulss xmm0, [rel c_rad2deg]
    addss xmm0, [rel c_45]
    cvttss2si eax, xmm0                 ; (deg + 45), >= 0 since yaw in [0, 2pi)
    xor edx, edx
    mov ecx, 90
    div ecx
    and eax, 3
    lea rdx, [rel facing_names]
    mov rdx, [rdx + rax * 8]
    INVOKE str_copy, rbx, rdx
    mov rbx, rax
    PUT s_nl

    ; mouse
    lea rdx, [rel s_mouse_cap]
    cmp dword [rel g_mouse_captured], 0
    jne .mouse
    lea rdx, [rel s_mouse_free]
.mouse:
    INVOKE str_copy, rbx, rdx
    mov rbx, rax

    ; shaders
    PUT s_shaders
    mov eax, [rel g_shader_count]
    PUTNUM rax, 0
    PUT s_programs
    mov eax, [rel g_shader_reloads]
    PUTNUM rax, 0
    PUT s_reloads
    lea rdx, [rel s_ok]
    cmp dword [rel g_shader_last_ok], 0
    jne .sh
    lea rdx, [rel s_failed]
.sh:
    INVOKE str_copy, rbx, rdx
    mov rbx, rax

    ; memory (MB with 1 decimal = bytes / 104858 as tenths)
    PUT s_memory
    mov rax, [rel g_mem_committed]
    xor edx, edx
    mov ecx, 104858
    div rcx
    PUTNUM rax, 1
    PUT s_mb
    mov rax, [rel g_arena_perm + ARENA.used]
    xor edx, edx
    mov ecx, 104858
    div rcx
    PUTNUM rax, 1
    PUT s_frame_kb
    mov rax, [rel g_arena_frame + ARENA.used]
    shr rax, 10
    PUTNUM rax, 0
    PUT s_kb_peak
    mov rax, [rel g_arena_frame + ARENA.peak]
    shr rax, 10
    PUTNUM rax, 0
    PUT s_kb_close

    ; jobs
    PUT s_jobs
    mov eax, [rel g_job_worker_count]
    PUTNUM rax, 0
    PUT s_workers
    PUTNUM [rel g_jobs_completed], 0
    PUT s_queue
    call job_queue_depth
    PUTNUM rax, 0
    PUT s_nl

    ; world
    PUT s_world
    PUTNUM [rel g_world_columns_n], 0
    PUT s_w_sections
    PUTNUM [rel g_sections_live], 0
    PUT s_w_mb_open
    mov rax, [rel g_section_bytes]
    xor edx, edx
    mov ecx, 104858
    div rcx
    PUTNUM rax, 1
    PUT s_w_mb_close
    PUTNUM [rel g_draw_count], 0
    PUT s_w_quads
    PUTNUM [rel g_world_quads], 0
    PUT s_w_gpu
    mov rax, [rel g_world_gpu_bytes]
    xor edx, edx
    mov ecx, 104858
    div rcx
    PUTNUM rax, 1
    PUT s_w_mb_nl
    PUT s_draw
    PUTNUM [rel g_world_visible], 0
    PUT s_d_quads
    PUTNUM [rel g_world_drawn_quads], 0
    PUT s_nl
    ; generation / meshing times
    PUT s_gen
    mov rax, [rel g_world_gen_wall_us]
    xor edx, edx
    mov ecx, 100
    div rcx
    PUTNUM rax, 1                       ; ms with 1 decimal
    PUT s_ms_wall
    mov rax, [rel g_world_gen_total_us]
    xor edx, edx
    mov rcx, [rel g_world_columns_n]
    test rcx, rcx
    jz .gen_div0
    div rcx
.gen_div0:
    PUTNUM rax, 0
    PUT s_us_col
    PUTNUM [rel g_world_gen_max_us], 0
    PUT s_us_nl
    PUT s_mesh
    mov rax, [rel g_world_mesh_wall_us]
    xor edx, edx
    mov ecx, 100
    div rcx
    PUTNUM rax, 1
    PUT s_ms_wall
    mov rax, [rel g_world_mesh_total_us]
    xor edx, edx
    mov rcx, [rel g_world_mesh_list_count]
    test rcx, rcx
    jz .mesh_div0
    div rcx
.mesh_div0:
    PUTNUM rax, 0
    PUT s_us_sec
    PUTNUM [rel g_world_mesh_max_us], 0
    PUT s_us_nl
    ; chunk + ground block below the camera
    movss xmm0, [rel g_cam_pos]
    roundss xmm0, xmm0, 9               ; floor
    cvttss2si esi, xmm0                 ; wx
    movss xmm0, [rel g_cam_pos + 4]
    roundss xmm0, xmm0, 9
    cvttss2si edi, xmm0                 ; wy
    movss xmm0, [rel g_cam_pos + 8]
    roundss xmm0, xmm0, 9
    cvttss2si r12d, xmm0                ; wz
    PUT s_chunk
    mov eax, esi
    sar eax, 5
    movsxd rax, eax
    PUTSNUM rax, 0
    PUT s_sp
    lea eax, [edi - WORLD_MIN_Y]
    sar eax, 5
    movsxd rax, eax
    PUTSNUM rax, 0
    PUT s_sp
    mov eax, r12d
    sar eax, 5
    movsxd rax, eax
    PUTSNUM rax, 0
    PUT s_ground
    ; scan down up to 256 blocks for the first non-air block
    mov r13d, 256
.scan:
    INVOKE world_block_at, rsi, rdi, r12
    test eax, eax
    jnz .found_ground
    dec edi
    dec r13d
    jnz .scan
    PUT s_none
    jmp .ground_done
.found_ground:
    lea rcx, [rel g_block_names]
    mov rdx, [rcx + rax * 8]
    INVOKE str_copy, rbx, rdx
    mov rbx, rax
    PUT s_at_y
    movsxd rax, edi
    PUTSNUM rax, 0
.ground_done:
    PUT s_nl

    ; bindings
    PUT s_controls
    xor esi, esi                        ; action
.action:
    mov rdi, rbx                        ; line start
    PUT s_indent
    mov ecx, esi
    call input_action_name
    PUTP rax
.pad:
    mov rax, rbx
    sub rax, rdi
    cmp rax, NAME_COLUMN
    jae .keys
    mov word [rbx], ' '
    inc rbx
    jmp .pad
.keys:
    lea r12, [rel g_bindings]
    lea r12, [r12 + rsi * BINDS_PER_ACTION]
    movzx ecx, byte [r12]
    call input_key_name
    PUTP rax
    movzx ecx, byte [r12 + 1]
    test ecx, ecx
    jz .one_key
    PUT s_comma
    movzx ecx, byte [r12 + 1]
    call input_key_name
    PUTP rax
.one_key:
    inc esi
    cmp esi, ACT_COUNT
    jae .done
    PUT s_nl
    jmp .action
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; measure_text — size of a text block in characters.
;   in:  rcx = text
;   out: eax = longest line (chars), edx = line count
;   clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
measure_text:
    xor eax, eax
    mov edx, 1
    xor r8d, r8d                        ; current line length
.next:
    movzx r9d, byte [rcx]
    inc rcx
    test r9d, r9d
    jz .end
    cmp r9d, 10
    je .newline
    inc r8d
    jmp .next
.newline:
    cmp r8d, eax
    cmova eax, r8d
    xor r8d, r8d
    inc edx
    jmp .next
.end:
    cmp r8d, eax
    cmova eax, r8d
    ret

; -----------------------------------------------------------------------------
; overlay_draw — draw the overlay (if visible) on top of the frame.
;   in:  ecx = framebuffer width, edx = framebuffer height
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC overlay_draw, 0, rbx, rsi, rdi, r12
    cmp dword [rel g_overlay_visible], 0
    je .hidden
    mov esi, ecx                        ; width
    mov edi, edx                        ; height
    ; pixel scale: 1 below 1000 px tall, 2 up to 1999, ...
    mov eax, edi
    xor edx, edx
    mov ecx, 1000
    div ecx
    inc eax
    mov [rel g_text_scale], eax
    mov r12d, eax                       ; r12 = scale

    lea rcx, [rel g_arena_frame]
    INVOKE arena_alloc, rcx, TEXT_CAP, 16
    test rax, rax
    jz .hidden
    mov [rel g_ov_text], rax
    call build_text
    call text_begin
    mov rcx, [rel g_ov_text]
    call measure_text
    mov ebx, edx                        ; lines
    ; panel: (chars * cell_w + 2*PAD) x (lines * cell_h + 2*PAD), scaled
    imul eax, [rel g_font_cell_w]
    add eax, 2 * PAD
    imul eax, r12d
    mov r8d, eax
    mov eax, ebx
    imul eax, [rel g_font_cell_h]
    add eax, 2 * PAD
    imul eax, r12d
    mov r9d, eax
    mov ebx, eax                        ; rbx = panel height (for the error line)
    mov dword [rsp + 32], COLOR_PANEL   ; arg 5 (read as a dword)
    xor ecx, ecx
    xor edx, edx
    call text_rect
    imul edx, r12d, PAD
    mov r8d, edx                        ; y = x = padding
    mov rcx, [rel g_ov_text]
    INVOKE text_add, rcx, rdx, r8, COLOR_TEXT

    cmp dword [rel g_shader_last_ok], 0
    jne .flush
    imul edx, r12d, PAD
    lea r8d, [rbx + rdx]
    lea rcx, [rel s_shader_err]
    INVOKE text_add, rcx, rdx, r8, COLOR_ERROR
.flush:
    INVOKE text_flush, rsi, rdi
.hidden:
    RETURN
ENDPROC
