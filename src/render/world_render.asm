; =============================================================================
; world_render.asm — draws the meshed world.
;
; All section quads live in one 256 MB shader storage buffer (their light
; words in a parallel one, milestone 13); the streamer
; (src/world/stream.asm) uploads into ranges handed out by the buddy
; allocator (gpu_alloc.asm). A section's quads are ordered by render layer
; (opaque, cutout, translucent; see mesher.asm), so each layer is one
; glDrawArrays of count*6 vertices; shaders/chunk.vert pulls its quad from
; the buffer (vertex pulling, no vertex buffers). Sections are frustum-culled
; on the CPU (5 planes, bounding sphere).
; Passes: 1 opaque (front to back as the columns come), 2 cutout (alpha
; test, leaves), 3 translucent (blended, depth writes off, sections sorted
; back to front).
; GPU-driven (milestone 11, DECISIONS D79): the CPU's visibility walk (cave
; culling + a coarse frustum test) writes one 32-byte draw record per
; section and layer into a persistent, coherently mapped ring (3 frame
; slots, fenced). shaders/cull.comp tests every record (exact AABB frustum
; test, then Hi-Z occlusion against the previous frame's depth pyramid) and
; writes its indirect command; each pass is one glMultiDrawArraysIndirect.
; shaders/hiz.comp then builds the pyramid from this frame's depth.
; Distant terrain (milestone 12, D80): the ready LOD tiles (lod.asm) add
; records too: their land after the walk's opaque records, their water
; before the sorted translucent ones. A record's quad count carries the
; tile's level in its top byte (0 = a section); the shaders decode LOD
; quads and keep each level to its ring around the camera.
; Shadows (milestone 14 part 2, D83): shaders/shadow_setup.comp works out 3
; cascade matrices into a small buffer each frame; the sections within the
; shadow distance get draw records after the frame's own, which cull.comp
; tests against each cascade's square, and chunk.vert + shadow.frag draw
; them into one layer of a depth texture array each. chunk.frag samples it.
; Water (milestone 15, D84): before the translucent pass the opaque scene's
; colour and depth are copied (blit) into textures that chunk.frag's water
; shading samples for refraction, absorption, reflections and foam; that
; pass draws both sides (water is seen from below too). The camera's block
; decides g_cam_in_water (post.asm's underwater fog).
;
; Public API:
;   world_render_init() -> eax 1/0      world_render_shutdown()
;   world_render_draw()                 (camera matrices must be current)
;   tint_upload(COLUMN*)                copy a column's biome colours into the
;                                       tint map (main thread, when it becomes ready)
;   g_world_visible, g_world_drawn_quads, g_world_gpu_bytes, g_world_draws
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "memory.inc"
%include "shader.inc"
%include "world_api.inc"
%include "lod.inc"

extern icons_init, held_init
global world_render_init, world_render_draw, world_render_shutdown, tint_upload, shadow_apply
global g_world_visible, g_world_drawn_quads, g_world_gpu_bytes, g_quad_buffer
global g_light_buffer, g_held_on, g_daylight, g_shadow_records, g_cam_in_water
global g_world_draws, g_vis_visited, g_world_gpu_visible, g_world_occluded

extern g_cam_viewproj, g_cam_pos
extern g_loaded, g_loaded_count
extern block_textures_init, block_textures_bind, block_textures_shutdown
extern timer_elapsed_us, world_column, vis_pair_bit
extern g_scene_depth, g_viewport_w, g_viewport_h
extern g_gpu_culling, g_occlusion_culling
extern g_smooth_lighting, g_ambient_occlusion, g_held_light, g_height_fog
extern g_sun_dir, g_sea_level, g_scene_fbo
extern g_shadows, g_shadow_res, g_shadow_distance, g_water_quality
extern world_block_at, g_block_water
extern g_target_valid, g_target

global g_lod_tint_tex, g_lod_records

%define QUAD_BUFFER_BYTES   (1 << 28)   ; 256 MB = gpu_alloc's 2^19 x 512 B
%define MAX_PASS_ENTRIES    65536       ; per pass and frame (frame arena)
%define ENTRY_SIZE          32          ; rel xyz (0), world xyz (12), SECT* (24)
%define MAX_WALK            65536       ; sections the visibility walk visits
%define WALK_SIZE           16
struc WALK
    .col        resq 1
    .sy         resb 1
    .entry      resb 1                  ; faces it was entered through (mask;
                                        ; 0x40 = the start: every exit allowed)
    .dirs       resb 1                  ; directions taken on the way here
    .pad        resb 5
endstruc
; world_render_draw locals (LOCAL(0) is used by the translucent sort)
%define W_CX        8
%define W_CZ        12
%define W_ENTRY     16
%define W_DIRS      20
%define W_VIS       24
%define W_D         28
%define W_NSY       32
%define W_CSY       36                  ; camera section y

; uniform locations (shaders/chunk.vert / chunk.frag)
%define U_VIEWPROJ          0
%define U_ORIGIN_REL        1
%define U_QUAD_BASE         2
%define U_ORIGIN_WORLD      3
%define U_TIME              4
%define U_PASS              5
%define U_LOD_LEVELS        6           ; LOD: levels in use (0 = off)
%define U_LOD_RA            7           ;   ring radii r0..r3 (vec4)
%define U_LOD_RB            8           ;   r4, r5 (vec4)
%define U_FOG               9           ; fog density
%define U_HELD              10          ; held light: rgb levels, on
%define U_LIGHT_FLAGS       11          ; 1 smooth light, 2 ambient occlusion
%define U_DAYLIGHT          12          ; sky light multiplier (--daylight)
%define U_CAM_Y             13          ; camera height (height fog)
%define U_SUN_DIR           14          ; towards the sun (daycycle.asm)
%define U_FOG_BASE          15          ; height fog base (world y)
%define U_CASCADE           16          ; chunk.vert: shadow cascade + 1 (0: camera)
%define U_SHADOWS           17          ; chunk.frag: cascades in use
%define C_CASCADE           12          ; cull.comp: shadow cascade + 1
; shadows (milestone 14 part 2)
%define SHADOW_CASCADES     3
%define SHADOW_UNIT         7           ; texture unit of the shadow map
%define SHADOW_SSBO         7           ; binding of the shadow data
%define SHADOW_DATA_BYTES   368         ; mat4[4], splits, light, texel, origin[4]
%define S_VIEWPROJ          0           ; shadow_setup.comp uniforms
%define S_SUN               4
%define S_SPLITS            5
%define S_RES               6
%define S_CAM_MOD           7
%define S_CASCADES          8
%define S_UPDATE            9           ; cascades redrawn this frame (bits)
%define U_CAM_MOD           18          ; chunk.frag: camera position mod 4096
%define U_WATER             19          ; chunk.frag: water quality (0..2)
%define REFR_COLOR_UNIT     8
%define REFR_DEPTH_UNIT     9
%define LOD_TINT_SIZE       1024        ; LOD tint map texels per side (16 blocks each)
%define FOG_DEFAULT         0.0013      ; without LOD
%define FOG_LOD             1.8         ; / the LOD radius: the far edge ~85% fog
%define TINT_SIZE           1024        ; tint map texels per side (4 blocks each)

; GPU-driven drawing (milestone 11)
%define MAX_DRAWS           32768       ; draw records per frame slot
%define RING_SLOTS          3           ; frames in flight
%define RECORD_SIZE         32          ; rel xyz, first quad, world xyz, quads
%define RING_BYTES          (MAX_DRAWS * RING_SLOTS * RECORD_SIZE)
%define CMD_SIZE            16          ; DrawArraysIndirectCommand
%define STATS_PER_SLOT      4           ; drawn sections, quads, occluded, -
; cull.comp uniforms
%define C_COUNT             0
%define C_BASE              1
%define C_PLANES            2
%define C_PREV_VIEWPROJ     7
%define C_CAM_DELTA         8
%define C_HIZ_LEVELS        9
%define C_HIZ_SIZE          10
%define C_STATS             11
; hiz.comp uniforms
%define H_FROM_DEPTH        0
%define H_SRC_SIZE          1
%define H_DST_SIZE          2
%define HIZ_UNIT            5           ; texture unit of the pyramid (cull)
%define DEPTH_UNIT          6           ; of the scene depth (hiz)

section .rdata
str_vs:         db "shaders/chunk.vert", 0
str_fs:         db "shaders/chunk.frag", 0
str_cull:       db "shaders/cull.comp", 0
str_outline_vs: db "shaders/outline.vert", 0
str_outline_fs: db "shaders/outline.frag", 0
str_hiz:        db "shaders/hiz.comp", 0
str_shadow_fs:  db "shaders/shadow.frag", 0
str_shadow_cs:  db "shaders/shadow_setup.comp", 0
align 4
c_half:         dd 16.0                 ; section half size
c_radius:       dd 27.7128129           ; 16 * sqrt(3)
c_million:      dd 1000000.0
c_tint_default: dd 0xFF404040           ; factor 1.0
c_fog_default:  dd FOG_DEFAULT
c_fog_lod:      dd FOG_LOD
c_fade_in:      dd 0.92                 ; 1 - FADE (shaders/chunk.frag)
c_fog_lift:     dd 8.0                  ; height fog base above the sea level
align 16
c_split:        dd 0.12, 0.38, 1.0, 1.0 ; cascade far distances / shadow distance
c_mod4096:      dq 4096.0
align 16
c_abs_mask:     times 4 dd 0x7FFFFFFF
align 8
c_wrap_us:      dq 3600000000           ; animation clock wraps hourly

section .data
align 4
g_daylight:         dd 1.0              ; sky light strength 0..1 (M14: day/night)

section .bss
alignb 4
g_world_prog:       resd 1
g_outline_prog:     resd 1              ; the targeted block's outline (M16)
g_world_vao:        resd 1
g_quad_buffer:      resd 1
g_light_buffer:     resd 1              ; light words, one per quad (M13)
g_tint_tex:         resd 1              ; biome tint map (2D array, 3 layers)
g_lod_tint_tex:     resd 1              ; the LOD tiles' tint map (same layers)
g_held_on:          resd 1              ; the held light is on (toggle_held_light)
g_shadow_prog:      resd 1              ; chunk.vert + shadow.frag
g_shadow_setup:     resd 1              ; shadow_setup.comp
g_shadow_tex:       resd 1              ; depth array, one layer per cascade
g_shadow_fbo:       resd 1
g_shadow_ssbo:      resd 1
g_shadow_cmd:       resd SHADOW_CASCADES
g_shadow_on:        resd 1              ; cascades in use (0: off)
g_shadow_made_res:  resd 1              ; size the maps were made with
g_shadow_frame:     resd 1              ; frames drawn (the far cascades alternate)
g_shadow_mask:      resd 1              ; cascades drawn this frame
g_refr_fbo:         resd 1              ; copies of the opaque scene (water)
g_refr_color:       resd 1
g_refr_depth:       resd 1
g_refr_w:           resd 1
g_refr_h:           resd 1
g_cam_in_water:     resd 1              ; the camera's block is water
alignb 8
g_shadow_records:   resq 1              ; shadow casters this frame
g_shadow_base:      resq 1              ; their first record in the slot
alignb 16
g_shadow_tmp:       resd 8
g_cam_mod:          resd 4              ; camera position mod 4096 (this frame)
alignb 8
g_world_visible:    resq 1
g_world_drawn_quads: resq 1
g_world_gpu_bytes:  resq 1
g_world_draws:      resq 1
g_vis_visited:      resq 1              ; sections the walk visited this frame
g_vis_stamp:        resw 1
g_cut_list:         resq 1              ; entries this frame
g_cut_count:        resq 1
g_trans_list:       resq 1
g_trans_count:      resq 1
alignb 16
g_planes:           resd 5 * 4          ; normalised frustum planes (xyz, 0)
g_vec_tmp:          resd 3              ; rel xyz, then directly
g_vec_tmp2:         resd 5              ;   world xyz: one draw entry
alignb 8
g_cull_prog:        resd 1              ; shader handles
g_hiz_prog:         resd 1
g_ring:             resd 1              ; draw records (persistent, coherent)
g_cmd_buf:          resd 1              ; indirect commands (written by cull.comp)
g_stats_buf:        resd 1
g_hiz_tex:          resd 1
g_hiz_w:            resd 1              ; level 0 size (half the scene)
g_hiz_h:            resd 1
g_hiz_levels:       resd 1
g_hiz_valid:        resd 1              ; a pyramid of the previous frame exists
g_slot:             resd 1
alignb 8
g_ring_ptr:         resq 1
g_stats_ptr:        resq 1
g_fence:            resq RING_SLOTS
g_rec_ptr:          resq 1              ; this frame's records
g_rec_count:        resq 1
g_n_opaque:         resq 1
g_n_cutout:         resq 1
g_world_gpu_visible: resq 1             ; records drawn after GPU culling (3 frames ago)
g_world_occluded:   resq 1              ; records culled by Hi-Z (3 frames ago)
g_lod_records:      resq 1              ; LOD tile records this frame
g_prev_cam:         resq 3              ; camera of the pyramid's frame
alignb 16
g_prev_viewproj:    resd 16

section .text

; -----------------------------------------------------------------------------
; world_render_init — create the program, the quad buffer and the textures.
;   out: eax = 1 on success, 0 on failure (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_render_init, 0, rbx
    lea rcx, [rel str_vs]
    lea rdx, [rel str_fs]
    call shader_create
    cmp eax, -1
    je .fail
    mov [rel g_world_prog], eax
    lea rcx, [rel str_cull]
    call shader_create_compute
    cmp eax, -1
    je .fail
    mov [rel g_cull_prog], eax
    lea rcx, [rel str_hiz]
    call shader_create_compute
    cmp eax, -1
    je .fail
    mov [rel g_hiz_prog], eax
    lea rcx, [rel str_outline_vs]
    lea rdx, [rel str_outline_fs]
    call shader_create
    cmp eax, -1
    je .fail
    mov [rel g_outline_prog], eax
    lea rdx, [rel g_world_vao]
    GL glCreateVertexArrays, 1, rdx
    call gpu_draw_init
    test eax, eax
    jz .fail
    call shadow_init
    test eax, eax
    jz .fail

    ; quads: one buffer for the whole streamed world
    mov qword [rel g_world_gpu_bytes], QUAD_BUFFER_BYTES
    lea rdx, [rel g_quad_buffer]
    GL glCreateBuffers, 1, rdx
    GL glNamedBufferStorage, [rel g_quad_buffer], QUAD_BUFFER_BYTES, 0, GL_DYNAMIC_STORAGE_BIT
    LOG_INFO "world: quad buffer created (256 MB, + 256 MB light words)"
    ; light words: parallel to the quads (quad i's corners at word i)
    mov qword [rel g_world_gpu_bytes], 2 * QUAD_BUFFER_BYTES
    lea rdx, [rel g_light_buffer]
    GL glCreateBuffers, 1, rdx
    GL glNamedBufferStorage, [rel g_light_buffer], QUAD_BUFFER_BYTES, 0, GL_DYNAMIC_STORAGE_BIT

    call block_textures_init
    test eax, eax
    jz .fail
    call icons_init                     ; (milestone 18: no icons is not fatal)
    call held_init                      ; the item in hand (not fatal either)

    ; biome tint map: 1024 x 1024 texels per layer, one per 4 x 4 blocks,
    ; repeating every 4096 blocks (the loaded world is always smaller);
    ; linear filtering blends neighbouring columns smoothly
    lea r8, [rel g_tint_tex]
    GL glCreateTextures, GL_TEXTURE_2D_ARRAY, 1, r8
    mov qword [rsp + 40], 3             ; depth: 3 layers (grass, foliage, water)
    GL glTextureStorage3D, [rel g_tint_tex], 1, GL_RGBA8, TINT_SIZE, TINT_SIZE
    GL glTextureParameteri, [rel g_tint_tex], GL_TEXTURE_MIN_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_tint_tex], GL_TEXTURE_MAG_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_tint_tex], GL_TEXTURE_WRAP_S, GL_REPEAT
    GL glTextureParameteri, [rel g_tint_tex], GL_TEXTURE_WRAP_T, GL_REPEAT
    lea rax, [rel c_tint_default]
    mov [rsp + 32], rax
    GL glClearTexImage, [rel g_tint_tex], 0, GL_RGBA, GL_UNSIGNED_BYTE
    ; the LOD tiles' tint map: one texel per 16 x 16 blocks, repeating
    ; every 16384 blocks
    lea r8, [rel g_lod_tint_tex]
    GL glCreateTextures, GL_TEXTURE_2D_ARRAY, 1, r8
    mov qword [rsp + 40], 3
    GL glTextureStorage3D, [rel g_lod_tint_tex], 1, GL_RGBA8, LOD_TINT_SIZE, LOD_TINT_SIZE
    GL glTextureParameteri, [rel g_lod_tint_tex], GL_TEXTURE_MIN_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_lod_tint_tex], GL_TEXTURE_MAG_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_lod_tint_tex], GL_TEXTURE_WRAP_S, GL_REPEAT
    GL glTextureParameteri, [rel g_lod_tint_tex], GL_TEXTURE_WRAP_T, GL_REPEAT
    lea rax, [rel c_tint_default]
    mov [rsp + 32], rax
    GL glClearTexImage, [rel g_lod_tint_tex], 0, GL_RGBA, GL_UNSIGNED_BYTE

    GL glEnable, GL_CULL_FACE
    mov eax, 1
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; world_render_shutdown — free GL objects.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_render_shutdown, 0
    call gpu_draw_shutdown
    call block_textures_shutdown
    lea rdx, [rel g_tint_tex]
    GL glDeleteTextures, 1, rdx
    lea rdx, [rel g_lod_tint_tex]
    GL glDeleteTextures, 1, rdx
    lea rdx, [rel g_quad_buffer]
    GL glDeleteBuffers, 1, rdx
    lea rdx, [rel g_light_buffer]
    GL glDeleteBuffers, 1, rdx
    call shadow_shutdown
    lea rdx, [rel g_world_vao]
    GL glDeleteVertexArrays, 1, rdx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; build_planes — extract and normalise 5 frustum planes (left, right,
; bottom, top, front) from the camera-relative view-projection matrix.
; All planes pass through the camera (w = 0 in camera-relative space).
;   clobbers: rax, rcx, rdx, xmm0-xmm4
; -----------------------------------------------------------------------------
build_planes:
    lea rax, [rel g_cam_viewproj]
    lea rcx, [rel g_vec_tmp]
%macro ROW_TO 2                         ; dst xmm, row
    mov edx, [rax + %2 * 4]
    mov [rcx], edx
    mov edx, [rax + 16 + %2 * 4]
    mov [rcx + 4], edx
    mov edx, [rax + 32 + %2 * 4]
    mov [rcx + 8], edx
    mov dword [rcx + 12], 0
    movaps %1, [rcx]
%endmacro
    ROW_TO xmm0, 0
    ROW_TO xmm1, 1
    ROW_TO xmm3, 3
    lea rcx, [rel g_planes]
    movaps xmm2, xmm3
    addps xmm2, xmm0
    movaps [rcx], xmm2                  ; left
    movaps xmm2, xmm3
    subps xmm2, xmm0
    movaps [rcx + 16], xmm2             ; right
    movaps xmm2, xmm3
    addps xmm2, xmm1
    movaps [rcx + 32], xmm2             ; bottom
    movaps xmm2, xmm3
    subps xmm2, xmm1
    movaps [rcx + 48], xmm2             ; top
    movaps [rcx + 64], xmm3             ; front
    xor eax, eax
.norm:
    movaps xmm0, [rcx + rax]
    movaps xmm1, xmm0
    mulps xmm1, xmm1
    movaps xmm2, xmm1
    shufps xmm2, xmm2, 0b01_01_01_01
    addss xmm1, xmm2
    movaps xmm2, [rcx + rax]
    mulps xmm2, xmm2
    shufps xmm2, xmm2, 0b10_10_10_10
    addss xmm1, xmm2
    sqrtss xmm1, xmm1
    shufps xmm1, xmm1, 0
    divps xmm0, xmm1
    movaps [rcx + rax], xmm0
    add eax, 16
    cmp eax, 80
    jb .norm
    ret

; -----------------------------------------------------------------------------
; xyz_origins — camera-relative origin (exact: computed in double) and
; wrapped world origin (mod 65536, for animation phases) of a section,
; into g_vec_tmp (rel xyz) and g_vec_tmp2 (world xyz).
;   in:  ecx = cx, edx = sy, r8d = cz
;   clobbers: rax, rcx, rdx, xmm0
; -----------------------------------------------------------------------------
xyz_origins:
    mov eax, ecx
    shl eax, 5
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos]
    cvtsd2ss xmm0, xmm0
    movss [rel g_vec_tmp], xmm0
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    movss [rel g_vec_tmp2], xmm0
    mov eax, edx
    shl eax, 5
    add eax, WORLD_MIN_Y
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos + 8]
    cvtsd2ss xmm0, xmm0
    movss [rel g_vec_tmp + 4], xmm0
    cvtsi2ss xmm0, eax
    movss [rel g_vec_tmp2 + 4], xmm0
    mov eax, r8d
    shl eax, 5
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos + 16]
    cvtsd2ss xmm0, xmm0
    movss [rel g_vec_tmp + 8], xmm0
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    movss [rel g_vec_tmp2 + 8], xmm0
    ret

; -----------------------------------------------------------------------------
; sphere_in_frustum — is the section at g_vec_tmp (rel origin) inside the 5
; frustum planes (bounding sphere)?
;   out: eax = 1/0   clobbers: rax, rcx, xmm0-xmm3
; -----------------------------------------------------------------------------
sphere_in_frustum:
    lea rcx, [rel g_vec_tmp]
    movss xmm3, [rcx]
    movss xmm0, [rcx + 4]
    unpcklps xmm3, xmm0
    movss xmm0, [rcx + 8]
    movlhps xmm3, xmm0                  ; (x, y, z, 0)
    movss xmm0, [rel c_half]
    shufps xmm0, xmm0, 0
    addps xmm3, xmm0                    ; centre
    lea rax, [rel g_planes]
    xor ecx, ecx
.plane:
    movaps xmm0, [rax + rcx]
    mulps xmm0, xmm3
    movaps xmm1, xmm0
    shufps xmm1, xmm1, 0b01_01_01_01
    addss xmm0, xmm1
    movaps xmm1, [rax + rcx]
    mulps xmm1, xmm3
    shufps xmm1, xmm1, 0b10_10_10_10
    addss xmm0, xmm1                    ; signed distance
    addss xmm0, [rel c_radius]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jb .out
    add ecx, 16
    cmp ecx, 80
    jb .plane
    mov eax, 1
    ret
.out:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; tint_upload — copy a column's biome colours (COLUMN.tint, 8 x 8 texels per
; layer) into the tint map at its place (cx * 8, cz * 8, wrapped).
;   in:  rcx = COLUMN*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC tint_upload, 0, rbx
    mov rbx, rcx
    cmp dword [rbx + COLUMN.tint], 0
    je .done                            ; no biome data (flat world): default
    lea rax, [rbx + COLUMN.tint]
    mov [rsp + 80], rax                 ; pixels
    mov qword [rsp + 72], GL_UNSIGNED_BYTE
    mov qword [rsp + 64], GL_RGBA
    mov qword [rsp + 56], 3             ; depth (layers)
    mov qword [rsp + 48], 8
    mov qword [rsp + 40], 8
    mov qword [rsp + 32], 0             ; z offset
    mov r8d, [rbx + COLUMN.cx]
    shl r8d, 3
    and r8d, TINT_SIZE - 1
    mov r9d, [rbx + COLUMN.cz]
    shl r9d, 3
    and r9d, TINT_SIZE - 1
    GL glTextureSubImage3D, [rel g_tint_tex], 0, r8, r9
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gpu_draw_init — the GPU-driven drawing resources: the record ring
; (persistent, coherently mapped; also the instanced vertex buffer of the
; draws' origins), the command buffer, the stats buffer (mapped).
;   out: eax = 1/0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gpu_draw_init, 16, rdi
    ; record ring
    lea rdx, [rel g_ring]
    GL glCreateBuffers, 1, rdx
    GL glNamedBufferStorage, [rel g_ring], RING_BYTES, 0, GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT
    GL glMapNamedBufferRange, [rel g_ring], 0, RING_BYTES, GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT
    test rax, rax
    jz .fail
    mov [rel g_ring_ptr], rax
    ; commands
    lea rdx, [rel g_cmd_buf]
    GL glCreateBuffers, 1, rdx
    GL glNamedBufferStorage, [rel g_cmd_buf], MAX_DRAWS * CMD_SIZE, 0, GL_DYNAMIC_STORAGE_BIT
    ; stats (read back three frames later)
    lea rdx, [rel g_stats_buf]
    GL glCreateBuffers, 1, rdx
    GL glNamedBufferStorage, [rel g_stats_buf], RING_SLOTS * STATS_PER_SLOT * 4, 0, GL_MAP_READ_BIT | GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT
    GL glMapNamedBufferRange, [rel g_stats_buf], 0, RING_SLOTS * STATS_PER_SLOT * 4, GL_MAP_READ_BIT | GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT
    test rax, rax
    jz .fail
    mov [rel g_stats_ptr], rax
    mov rdi, rax
    xor eax, eax
    mov ecx, RING_SLOTS * STATS_PER_SLOT
    rep stosd
    ; the records are also an instanced vertex buffer (divisor 1): a
    ; command's base instance picks its record's origins as attributes
    GL glVertexArrayVertexBuffer, [rel g_world_vao], 0, [rel g_ring], 0, RECORD_SIZE
    GL glVertexArrayAttribFormat, [rel g_world_vao], 0, 3, GL_FLOAT, GL_FALSE, 0
    GL glVertexArrayAttribFormat, [rel g_world_vao], 1, 3, GL_FLOAT, GL_FALSE, 16
    GL glVertexArrayAttribBinding, [rel g_world_vao], 0, 0
    GL glVertexArrayAttribFormat, [rel g_world_vao], 2, 1, GL_UNSIGNED_INT, GL_FALSE, 28
    GL glVertexArrayAttribBinding, [rel g_world_vao], 1, 0
    GL glVertexArrayAttribBinding, [rel g_world_vao], 2, 0
    GL glVertexArrayBindingDivisor, [rel g_world_vao], 0, 1
    GL glEnableVertexArrayAttrib, [rel g_world_vao], 0
    GL glEnableVertexArrayAttrib, [rel g_world_vao], 1
    GL glEnableVertexArrayAttrib, [rel g_world_vao], 2
    mov dword [rel g_hiz_valid], 0
    LOG_INFO "world: GPU-driven drawing ready (record ring 3 MB, compute culling, Hi-Z)"
    mov eax, 1
    RETURN
.fail:
    LOG_ERROR "world: GPU-driven drawing resources failed"
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gpu_draw_shutdown — free them.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gpu_draw_shutdown, 0, rbx
    xor ebx, ebx
.f:
    lea rax, [rel g_fence]
    mov rcx, [rax + rbx * 8]
    test rcx, rcx
    jz .fn
    GL glDeleteSync, rcx
    lea rax, [rel g_fence]
    mov qword [rax + rbx * 8], 0
.fn:
    inc ebx
    cmp ebx, RING_SLOTS
    jb .f
    GL glUnmapNamedBuffer, [rel g_ring]
    GL glUnmapNamedBuffer, [rel g_stats_buf]
    lea rdx, [rel g_ring]
    GL glDeleteBuffers, 1, rdx
    lea rdx, [rel g_cmd_buf]
    GL glDeleteBuffers, 1, rdx
    lea rdx, [rel g_stats_buf]
    GL glDeleteBuffers, 1, rdx
    cmp dword [rel g_hiz_tex], 0
    je .done
    lea rdx, [rel g_hiz_tex]
    GL glDeleteTextures, 1, rdx
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; gpu_frame_begin — take the next ring slot: wait for the GPU to finish the
; frame that used it (3 frames ago), read that frame's culling stats, and
; point the record writer at it.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gpu_frame_begin, 0, rbx
    mov eax, [rel g_slot]
    inc eax
    cmp eax, RING_SLOTS
    jb .slot
    xor eax, eax
.slot:
    mov [rel g_slot], eax
    mov ebx, eax
    lea rax, [rel g_fence]
    mov rcx, [rax + rbx * 8]
    test rcx, rcx
    jz .free
.wait:
    lea rax, [rel g_fence]
    mov rcx, [rax + rbx * 8]
    mov r8, 1000000000                  ; 1 s
    GL glClientWaitSync, rcx, GL_SYNC_FLUSH_COMMANDS_BIT, r8
    cmp eax, GL_TIMEOUT_EXPIRED
    je .wait
    lea rax, [rel g_fence]
    mov rcx, [rax + rbx * 8]
    GL glDeleteSync, rcx
    lea rax, [rel g_fence]
    mov qword [rax + rbx * 8], 0
    ; that frame's stats
    imul eax, ebx, STATS_PER_SLOT * 4
    add rax, [rel g_stats_ptr]
    mov ecx, [rax]
    mov [rel g_world_gpu_visible], rcx
    mov ecx, [rax + 4]
    mov [rel g_world_drawn_quads], rcx
    mov ecx, [rax + 8]
    mov [rel g_world_occluded], rcx
.free:
    imul eax, ebx, STATS_PER_SLOT * 4
    add rax, [rel g_stats_ptr]
    mov qword [rax], 0
    mov qword [rax + 8], 0
    imul rax, rbx, MAX_DRAWS * RECORD_SIZE
    add rax, [rel g_ring_ptr]
    mov [rel g_rec_ptr], rax
    mov qword [rel g_rec_count], 0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; add_record — append a draw record to this frame's slot.
;   in:  rcx = entry (rel xyz, world xyz), edx = first quad, r8d = quads
;   clobbers: rax, rcx, rdx, r9, xmm0
; -----------------------------------------------------------------------------
add_record:
    mov rax, [rel g_rec_count]
    cmp rax, MAX_DRAWS
    jae .full
    shl rax, 5
    add rax, [rel g_rec_ptr]
    mov r9d, [rcx]
    mov [rax], r9d
    mov r9d, [rcx + 4]
    mov [rax + 4], r9d
    mov r9d, [rcx + 8]
    mov [rax + 8], r9d
    mov [rax + 12], edx
    mov r9d, [rcx + 12]
    mov [rax + 16], r9d
    mov r9d, [rcx + 16]
    mov [rax + 20], r9d
    mov r9d, [rcx + 20]
    mov [rax + 24], r9d
    mov [rax + 28], r8d
    inc qword [rel g_rec_count]
.full:
    ret

; -----------------------------------------------------------------------------
; gpu_cull — run cull.comp over this frame's records (writes the commands).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC gpu_cull, 32, rbx, rsi, rdi
    mov rsi, [rel g_rec_count]
    test rsi, rsi
    jz .done
    cmp dword [rel g_gpu_culling], 0
    jne .gpu
    ; gpu_culling = 0: the CPU writes every command (no further culling)
    lea rcx, [rel g_arena_frame]
    mov rdx, rsi
    shl rdx, 4
    INVOKE arena_alloc, rcx, rdx, 16
    test rax, rax
    jz .done
    mov rdi, rax
    mov eax, [rel g_slot]
    imul ebx, eax, MAX_DRAWS            ; base instance of record 0
    mov rcx, [rel g_rec_ptr]
    xor edx, edx
    xor r9d, r9d                        ; quads
.cpu:
    mov eax, [rcx + 28]
    and eax, 0xFFFFFF                   ; (LOD records: the level above)
    add r9, rax
    imul eax, eax, 6
    mov [rdi + rdx * 8], eax            ; count
    mov dword [rdi + rdx * 8 + 4], 1    ; instances
    mov eax, [rcx + 12]
    imul eax, eax, 6
    mov [rdi + rdx * 8 + 8], eax        ; first
    mov eax, edx
    shr eax, 1
    add eax, ebx
    mov [rdi + rdx * 8 + 12], eax       ; base instance
    add rcx, RECORD_SIZE
    add edx, 2                          ; (16 bytes per command)
    mov eax, edx
    shr eax, 1
    cmp rax, rsi
    jb .cpu
    mov [rel g_world_drawn_quads], r9
    mov [rel g_world_gpu_visible], rsi
    mov qword [rel g_world_occluded], 0
    mov r8, rsi
    shl r8, 4
    GL glNamedBufferSubData, [rel g_cmd_buf], 0, r8, rdi
    RETURN
.gpu:
    mov ecx, [rel g_cull_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    GL glProgramUniform1ui, rbx, C_COUNT, rsi
    GL glProgramUniform1i, rbx, C_CASCADE, 0
    mov eax, [rel g_slot]
    imul eax, eax, MAX_DRAWS
    GL glProgramUniform1ui, rbx, C_BASE, rax
    lea r9, [rel g_planes]
    GL glProgramUniform4fv, rbx, C_PLANES, 5, r9
    lea rax, [rel g_prev_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, rbx, C_PREV_VIEWPROJ, 1, GL_FALSE
    ; camera now - camera of the pyramid's frame
    movsd xmm0, [rel g_cam_pos]
    subsd xmm0, [rel g_prev_cam]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(0)], xmm0
    movsd xmm0, [rel g_cam_pos + 8]
    subsd xmm0, [rel g_prev_cam + 8]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(4)], xmm0
    movsd xmm0, [rel g_cam_pos + 16]
    subsd xmm0, [rel g_prev_cam + 16]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(8)], xmm0
    lea r9, [LOCAL(0)]
    GL glProgramUniform3fv, rbx, C_CAM_DELTA, 1, r9
    xor eax, eax
    cmp dword [rel g_hiz_valid], 0
    je .levels
    cmp dword [rel g_occlusion_culling], 0
    je .levels
    mov eax, [rel g_hiz_levels]
.levels:
    GL glProgramUniform1i, rbx, C_HIZ_LEVELS, rax
    GL glProgramUniform2i, rbx, C_HIZ_SIZE, [rel g_hiz_w], [rel g_hiz_h]
    mov eax, [rel g_slot]
    imul eax, eax, STATS_PER_SLOT
    GL glProgramUniform1ui, rbx, C_STATS, rax
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 3, [rel g_ring]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 4, [rel g_cmd_buf]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 5, [rel g_stats_buf]
    cmp dword [rel g_hiz_tex], 0
    je .no_tex
    GL glBindTextureUnit, HIZ_UNIT, [rel g_hiz_tex]
.no_tex:
    lea eax, [esi + 63]
    shr eax, 6
    GL glDispatchCompute, rax, 1, 1
    GL glMemoryBarrier, GL_COMMAND_BARRIER_BIT | GL_SHADER_STORAGE_BARRIER_BIT
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; hiz_build — build the depth pyramid from this frame's scene depth and
; remember this frame's view-projection and camera for the next frame.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define HB_W        0
%define HB_H        4
%define HB_SW       8
%define HB_SH       12
%define HB_L        16
PROC hiz_build, 32, rbx, rsi, rdi
    cmp dword [rel g_scene_depth], 0
    je .done
    ; level 0: half the scene (rounded up); (re)create on a size change
    mov eax, [rel g_viewport_w]
    inc eax
    shr eax, 1
    mov ecx, [rel g_viewport_h]
    inc ecx
    shr ecx, 1
    cmp eax, [rel g_hiz_w]
    jne .create
    cmp ecx, [rel g_hiz_h]
    jne .create
    cmp dword [rel g_hiz_tex], 0
    jne .have
.create:
    mov [rel g_hiz_w], eax
    mov [rel g_hiz_h], ecx
    mov dword [rel g_hiz_valid], 0
    ; levels: 1 + floor(log2(max(w, h)))
    cmp eax, ecx
    cmovb eax, ecx
    bsr eax, eax
    inc eax
    mov [rel g_hiz_levels], eax
    cmp dword [rel g_hiz_tex], 0
    je .new
    lea rdx, [rel g_hiz_tex]
    GL glDeleteTextures, 1, rdx
.new:
    lea r8, [rel g_hiz_tex]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    GL glTextureStorage2D, [rel g_hiz_tex], [rel g_hiz_levels], GL_R32F, [rel g_hiz_w], [rel g_hiz_h]
    GL glTextureParameteri, [rel g_hiz_tex], GL_TEXTURE_MIN_FILTER, GL_NEAREST_MIPMAP_NEAREST
    GL glTextureParameteri, [rel g_hiz_tex], GL_TEXTURE_MAG_FILTER, GL_NEAREST
.have:
    mov ecx, [rel g_hiz_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    GL glBindTextureUnit, DEPTH_UNIT, [rel g_scene_depth]
    ; level 0 from the depth
    mov eax, [rel g_viewport_w]
    mov [LOCAL(HB_SW)], eax
    mov eax, [rel g_viewport_h]
    mov [LOCAL(HB_SH)], eax
    mov eax, [rel g_hiz_w]
    mov [LOCAL(HB_W)], eax
    mov eax, [rel g_hiz_h]
    mov [LOCAL(HB_H)], eax
    mov dword [LOCAL(HB_L)], 0
.level:
    mov eax, [LOCAL(HB_L)]
    xor r8d, r8d
    test eax, eax
    sete r8b                            ; 1: from the depth
    GL glProgramUniform1i, rbx, H_FROM_DEPTH, r8
    GL glProgramUniform2i, rbx, H_SRC_SIZE, [LOCAL(HB_SW)], [LOCAL(HB_SH)]
    GL glProgramUniform2i, rbx, H_DST_SIZE, [LOCAL(HB_W)], [LOCAL(HB_H)]
    ; source level (n - 1; level 0 reads the depth, bind level 0 anyway)
    mov eax, [LOCAL(HB_L)]
    test eax, eax
    jz .src0
    dec eax
.src0:
    GL glBindImageTexture, 0, [rel g_hiz_tex], rax, GL_FALSE, 0, GL_READ_ONLY, GL_R32F
    GL glBindImageTexture, 1, [rel g_hiz_tex], [LOCAL(HB_L)], GL_FALSE, 0, GL_WRITE_ONLY, GL_R32F
    mov eax, [LOCAL(HB_W)]
    add eax, 7
    shr eax, 3
    mov edx, [LOCAL(HB_H)]
    add edx, 7
    shr edx, 3
    mov ecx, eax
    mov r8d, 1
    call [rel glDispatchCompute]
    GL glMemoryBarrier, GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | GL_TEXTURE_FETCH_BARRIER_BIT
    ; next level: half (rounded up)
    mov eax, [LOCAL(HB_W)]
    mov [LOCAL(HB_SW)], eax
    mov eax, [LOCAL(HB_H)]
    mov [LOCAL(HB_SH)], eax
    mov eax, [LOCAL(HB_W)]
    inc eax
    shr eax, 1
    mov [LOCAL(HB_W)], eax
    mov eax, [LOCAL(HB_H)]
    inc eax
    shr eax, 1
    mov [LOCAL(HB_H)], eax
    inc dword [LOCAL(HB_L)]
    mov eax, [LOCAL(HB_L)]
    cmp eax, [rel g_hiz_levels]
    jb .level
    ; this frame becomes the pyramid's frame
    lea rsi, [rel g_cam_viewproj]
    lea rdi, [rel g_prev_viewproj]
    mov ecx, 16
    rep movsd
    movsd xmm0, [rel g_cam_pos]
    movsd [rel g_prev_cam], xmm0
    movsd xmm0, [rel g_cam_pos + 8]
    movsd [rel g_prev_cam + 8], xmm0
    movsd xmm0, [rel g_cam_pos + 16]
    movsd [rel g_prev_cam + 16], xmm0
    mov dword [rel g_hiz_valid], 1
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; world_render_draw — cull, then draw the opaque, cutout and translucent
; layers of every visible section.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC world_render_draw, 64, rbx, rsi, rdi, r12, r13, r14, r15
    xor eax, eax
    mov [rel g_world_visible], rax
    mov [rel g_world_drawn_quads], rax
    mov [rel g_world_draws], rax
    mov [rel g_cut_count], rax
    mov [rel g_trans_count], rax
    call build_planes
    call gpu_frame_begin
    lea rcx, [rel g_arena_frame]
    INVOKE arena_alloc, rcx, MAX_PASS_ENTRIES * ENTRY_SIZE, 16
    mov [rel g_cut_list], rax
    lea rcx, [rel g_arena_frame]
    INVOKE arena_alloc, rcx, MAX_PASS_ENTRIES * ENTRY_SIZE, 16
    mov [rel g_trans_list], rax
    test rax, rax
    jz .done
    cmp qword [rel g_cut_list], 0
    je .done

    mov ecx, [rel g_world_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    lea rax, [rel g_cam_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, rbx, U_VIEWPROJ, 1, GL_FALSE
    ; animation clock (seconds, wraps hourly)
    call timer_elapsed_us
    xor edx, edx
    div qword [rel c_wrap_us]
    cvtsi2ss xmm2, rdx
    divss xmm2, [rel c_million]
    GL glProgramUniform1f, rbx, U_TIME
    GL glProgramUniform1i, rbx, U_PASS, 0
    ; LOD rings and the fog that hides their far edge
    GL glProgramUniform1i, rbx, U_LOD_LEVELS, [rel g_lod_levels]
    lea r9, [rel g_lod_r]
    GL glProgramUniform4fv, rbx, U_LOD_RA, 1, r9
    lea r9, [rel g_lod_r + 16]
    GL glProgramUniform4fv, rbx, U_LOD_RB, 1, r9
    movss xmm2, [rel c_fog_default]
    mov eax, [rel g_lod_levels]
    test eax, eax
    jz .fog
    lea rcx, [rel g_lod_r]
    movss xmm2, [rel c_fog_lod]
    divss xmm2, [rcx + rax * 4]
.fog:
    GL glProgramUniform1f, rbx, U_FOG
    ; lighting
    mov eax, [rel g_smooth_lighting]
    mov ecx, [rel g_ambient_occlusion]
    add ecx, ecx
    or eax, ecx
    mov ecx, [rel g_height_fog]
    shl ecx, 2
    or eax, ecx
    GL glProgramUniform1i, rbx, U_LIGHT_FLAGS, rax
    ; sky and fog (milestone 14)
    lea r9, [rel g_sun_dir]
    GL glProgramUniform3fv, rbx, U_SUN_DIR, 1, r9
    movsd xmm0, [rel g_cam_pos + 8]
    cvtsd2ss xmm2, xmm0
    GL glProgramUniform1f, rbx, U_CAM_Y
    cvtsi2ss xmm2, dword [rel g_sea_level]
    addss xmm2, [rel c_fog_lift]
    GL glProgramUniform1f, rbx, U_FOG_BASE
    GL glProgramUniform1i, rbx, U_SHADOWS, [rel g_shadow_on]
    GL glProgramUniform1i, rbx, U_CASCADE, 0
    GL glProgramUniform1i, rbx, U_WATER, [rel g_water_quality]
    call water_camera
    movss xmm2, [rel g_daylight]
    GL glProgramUniform1f, rbx, U_DAYLIGHT
    mov eax, [rel g_held_light]
    movzx ecx, al
    cvtsi2ss xmm0, ecx
    movss [LOCAL(0)], xmm0
    movzx ecx, ah
    cvtsi2ss xmm0, ecx
    movss [LOCAL(4)], xmm0
    shr eax, 16
    movzx ecx, al
    cvtsi2ss xmm0, ecx
    movss [LOCAL(8)], xmm0
    cvtsi2ss xmm0, dword [rel g_held_on]
    movss [LOCAL(12)], xmm0
    lea r9, [LOCAL(0)]
    GL glProgramUniform4fv, rbx, U_HELD, 1, r9
    GL glBindVertexArray, [rel g_world_vao]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 0, [rel g_quad_buffer]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 6, [rel g_light_buffer]
    call block_textures_bind
    GL glBindTextureUnit, 3, [rel g_tint_tex]
    GL glBindTextureUnit, 4, [rel g_lod_tint_tex]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, SHADOW_SSBO, [rel g_shadow_ssbo]
    cmp dword [rel g_shadow_tex], 0
    je .no_shadow_tex
    GL glBindTextureUnit, SHADOW_UNIT, [rel g_shadow_tex]
.no_shadow_tex:
    mov qword [rel g_lod_records], 0

    ; ---- pass 1: visibility walk from the camera's section (cave culling) -------
    ; Breadth-first over sections (DECISIONS D51): leave a section through
    ; face d only if one of the faces it was entered through connects to d
    ; (SECT.vis, the mesher's flood fill), never turn back against a direction
    ; the path already took, and only go into sections inside the frustum.
    ; A section reached by several paths keeps all their entry faces and
    ; allowed directions. The camera's section and its 26 neighbours pass
    ; everything. Visited sections with geometry are drawn (opaque now,
    ; cutout / translucent collected for passes 2 and 3).
    inc word [rel g_vis_stamp]
    jnz .stamp_ok
    inc word [rel g_vis_stamp]
.stamp_ok:
    mov qword [rel g_vis_visited], 0
    lea rcx, [rel g_arena_frame]
    INVOKE arena_alloc, rcx, MAX_WALK * WALK_SIZE, 16
    test rax, rax
    jz .pass2
    mov r14, rax                        ; queue
    xor r12d, r12d                      ; head
    xor r13d, r13d                      ; tail
    ; camera section
    movsd xmm0, [rel g_cam_pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    mov [LOCAL(W_CX)], eax
    movsd xmm0, [rel g_cam_pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    mov [LOCAL(W_CZ)], eax
    movsd xmm0, [rel g_cam_pos + 8]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sub rax, WORLD_MIN_Y
    sar rax, 5
    cmp rax, 0
    jge .sy_lo
    xor eax, eax
.sy_lo:
    cmp rax, SECTIONS_PER_COLUMN - 1
    jle .sy_hi
    mov eax, SECTIONS_PER_COLUMN - 1
.sy_hi:
    mov esi, eax
    mov [LOCAL(W_CSY)], eax
    mov ecx, [LOCAL(W_CX)]
    mov edx, [LOCAL(W_CZ)]
    call world_column
    test rax, rax
    jz .pass2                           ; camera column not loaded yet
    mov [r14 + WALK.col], rax
    mov [r14 + WALK.sy], sil
    mov byte [r14 + WALK.entry], 0x40
    mov byte [r14 + WALK.dirs], 0
    mov cx, [rel g_vis_stamp]
    mov [rax + COLUMN.vstamp + rsi * 2], cx
    mov dword [rax + COLUMN.vqueue + rsi * 4], 0
    mov r13d, 1
.walk:
    cmp r12d, r13d
    jae .pass2
    mov rax, r12
    shl rax, 4
    add rax, r14                        ; entry
    inc r12d
    mov rsi, [rax + WALK.col]
    movzx edi, byte [rax + WALK.sy]
    movzx ecx, byte [rax + WALK.entry]
    mov [LOCAL(W_ENTRY)], ecx
    movzx ecx, byte [rax + WALK.dirs]
    mov [LOCAL(W_DIRS)], ecx
    inc qword [rel g_vis_visited]
    ; ---- draw it (if meshed with quads) ----
    cmp dword [rsi + COLUMN.state], COL_READY
    jne .expand
    bt qword [rsi + COLUMN.geo_mask], rdi
    jnc .expand
    mov r15, [rsi + COLUMN.sections + rdi * 8]   ; SECT*
    INVOKE xyz_origins, [rsi + COLUMN.cx], rdi, [rsi + COLUMN.cz]
    call sphere_in_frustum
    test eax, eax
    jz .expand                          ; (the start section can be outside)
    inc qword [rel g_world_visible]
    mov eax, [r15 + SECT.quad_cutout]
    test eax, eax
    jz .no_cut
    mov rax, [rel g_cut_count]
    cmp rax, MAX_PASS_ENTRIES
    jae .no_cut
    shl rax, 5
    add rax, [rel g_cut_list]
    lea rcx, [rel g_vec_tmp]
    movups xmm0, [rcx]
    movups [rax], xmm0
    movq xmm0, [rcx + 16]
    movq [rax + 16], xmm0
    mov [rax + 24], r15
    inc qword [rel g_cut_count]
.no_cut:
    mov eax, [r15 + SECT.quad_count]
    sub eax, [r15 + SECT.quad_opaque]
    sub eax, [r15 + SECT.quad_cutout]
    jz .no_trans
    mov rax, [rel g_trans_count]
    cmp rax, MAX_PASS_ENTRIES
    jae .no_trans
    shl rax, 5
    add rax, [rel g_trans_list]
    lea rcx, [rel g_vec_tmp]
    movups xmm0, [rcx]
    movups [rax], xmm0
    movq xmm0, [rcx + 16]
    movq [rax + 16], xmm0
    mov [rax + 24], r15
    inc qword [rel g_trans_count]
.no_trans:
    ; its opaque range: a draw record (culled and drawn on the GPU later)
    mov r8d, [r15 + SECT.quad_opaque]
    test r8d, r8d
    jz .expand
    mov edx, [r15 + SECT.quad_first]
    lea rcx, [rel g_vec_tmp]
    call add_record
    ; ---- expand to the 6 neighbours ----
.expand:
    ; visibility bits of this section (unknown or empty: everything passes;
    ; also the sections right around the camera, where 32-block sections are
    ; too coarse for the walk's rules)
    mov eax, 0x7FFF
    mov ecx, [rsi + COLUMN.cx]
    sub ecx, [LOCAL(W_CX)]
    add ecx, 1
    cmp ecx, 2
    ja .far
    mov ecx, [rsi + COLUMN.cz]
    sub ecx, [LOCAL(W_CZ)]
    add ecx, 1
    cmp ecx, 2
    ja .far
    mov ecx, edi
    sub ecx, [LOCAL(W_CSY)]
    add ecx, 1
    cmp ecx, 2
    jbe .have_vis
.far:
    cmp dword [rsi + COLUMN.state], COL_MESHED
    jb .have_vis
    mov rcx, [rsi + COLUMN.sections + rdi * 8]
    test rcx, rcx
    jz .have_vis
    movzx eax, word [rcx + SECT.vis]
.have_vis:
    mov [LOCAL(W_VIS)], eax
    mov dword [LOCAL(W_D)], 0
.dir:
    mov ecx, [LOCAL(W_D)]
    cmp ecx, 6
    jae .walk
    ; never against a direction already taken
    mov eax, ecx
    xor eax, 1                          ; opposite face
    bt dword [LOCAL(W_DIRS)], eax
    jc .dir_next
    ; through this section from any entry face to face d?
    mov eax, [LOCAL(W_ENTRY)]
    test eax, 0x40
    jnz .passable                       ; the start section
    xor edx, edx                        ; faces connected to d
    xor r8d, r8d                        ; e
.conn:
    imul r9d, r8d, 6
    add r9d, ecx
    lea r10, [rel vis_pair_bit]
    movzx r9d, byte [r10 + r9]
    cmp r9d, 15
    jae .conn_next                      ; (e == d)
    bt dword [LOCAL(W_VIS)], r9d
    jnc .conn_next
    bts edx, r8d
.conn_next:
    inc r8d
    cmp r8d, 6
    jb .conn
    test eax, edx
    jnz .passable
    jmp .dir_next
.passable:
    ; neighbour section
    mov r8d, [rsi + COLUMN.cx]
    mov r9d, [rsi + COLUMN.cz]
    mov r10d, edi                       ; sy
    cmp ecx, 0
    jne .d1
    dec r8d
    jmp .lookup
.d1:
    cmp ecx, 1
    jne .d2
    inc r8d
    jmp .lookup
.d2:
    cmp ecx, 2
    jne .d3
    dec r10d
    js .dir_next
    mov r15, rsi
    jmp .have_col
.d3:
    cmp ecx, 3
    jne .d4
    inc r10d
    cmp r10d, SECTIONS_PER_COLUMN
    jae .dir_next
    mov r15, rsi
    jmp .have_col
.d4:
    cmp ecx, 4
    jne .d5
    dec r9d
    jmp .lookup
.d5:
    inc r9d
.lookup:
    mov [LOCAL(W_NSY)], r10d
    mov ecx, r8d
    mov edx, r9d
    call world_column
    test rax, rax
    jz .dir_next                        ; not loaded
    mov r15, rax
    mov r10d, [LOCAL(W_NSY)]
.have_col:
    mov [LOCAL(W_NSY)], r10d
    mov ax, [rel g_vis_stamp]
    cmp [r15 + COLUMN.vstamp + r10 * 2], ax
    jne .new_section
    ; reached again: if it is still waiting in the queue, remember this
    ; entry face too (a section can be seen through any of its entries)
    mov eax, [r15 + COLUMN.vqueue + r10 * 4]
    cmp eax, r12d
    jb .dir_next                        ; already processed
    shl rax, 4
    add rax, r14
    mov ecx, [LOCAL(W_D)]
    xor ecx, 1
    bts dword [rax + WALK.entry], ecx   ; (entry is the low byte)
    ; and allow what this path allows: every path to a section has the same
    ; length (no turning back), so all of them arrive while it is queued
    mov edx, [LOCAL(W_DIRS)]
    xor ecx, 1                          ; d
    bts edx, ecx
    and [rax + WALK.dirs], dl
    jmp .dir_next
.new_section:
    mov [r15 + COLUMN.vstamp + r10 * 2], ax
    mov dword [r15 + COLUMN.vqueue + r10 * 4], 0   ; (not queued)
    INVOKE xyz_origins, [r15 + COLUMN.cx], r10, [r15 + COLUMN.cz]
    call sphere_in_frustum
    test eax, eax
    jz .dir_next
    cmp r13d, MAX_WALK
    jae .dir_next
    mov r10d, [LOCAL(W_NSY)]
    mov [r15 + COLUMN.vqueue + r10 * 4], r13d
    mov rax, r13
    shl rax, 4
    add rax, r14
    inc r13d
    mov [rax + WALK.col], r15
    mov ecx, [LOCAL(W_NSY)]
    mov [rax + WALK.sy], cl
    mov ecx, [LOCAL(W_D)]
    xor ecx, 1
    mov r8d, 1
    shl r8d, cl                         ; entry face = opposite of d
    xor ecx, 1
    mov [rax + WALK.entry], r8b
    mov edx, [LOCAL(W_DIRS)]
    bts edx, ecx
    mov [rax + WALK.dirs], dl
.dir_next:
    inc dword [LOCAL(W_D)]
    jmp .dir

    ; ---- cutout records (alpha-tested) -------------------------------------------------
.pass2:
    mov ecx, 0                          ; LOD land
    call lod_records
    mov rax, [rel g_rec_count]
    mov [rel g_n_opaque], rax
    xor r12d, r12d
.cut:
    cmp r12, [rel g_cut_count]
    jae .cut_done
    mov rcx, r12
    shl rcx, 5
    add rcx, [rel g_cut_list]
    mov rax, [rcx + 24]
    mov edx, [rax + SECT.quad_first]
    add edx, [rax + SECT.quad_opaque]
    mov r8d, [rax + SECT.quad_cutout]
    call add_record
    inc r12
    jmp .cut
.cut_done:
    mov rax, [rel g_rec_count]
    sub rax, [rel g_n_opaque]
    mov [rel g_n_cutout], rax
    mov ecx, 1                          ; LOD water (coplanar: no sorting)
    call lod_records

    ; ---- translucent records, sorted back to front ----------------------------------------
    mov r15, [rel g_trans_count]
    test r15, r15
    jz .gpu
    ; insertion sort by distance to the section centre, far first
    mov r14, [rel g_trans_list]
    mov r12d, 1
.sort_outer:
    cmp r12, r15
    jae .sorted
    mov rax, r12
    shl rax, 5
    movups xmm4, [r14 + rax]            ; entry being inserted (32 bytes)
    movups xmm5, [r14 + rax + 16]
    lea rcx, [r14 + rax]
    call entry_dist
    movss [LOCAL(0)], xmm0              ; its distance
    mov r13, r12
.sort_inner:
    test r13, r13
    jz .sort_place
    lea rcx, [r13 - 1]
    shl rcx, 5
    add rcx, r14
    call entry_dist
    comiss xmm0, [LOCAL(0)]
    jae .sort_place                     ; previous is farther: stop
    lea rcx, [r13 - 1]
    shl rcx, 5
    add rcx, r14
    movups xmm0, [rcx]
    movups xmm1, [rcx + 16]
    movups [rcx + 32], xmm0
    movups [rcx + 48], xmm1
    dec r13
    jmp .sort_inner
.sort_place:
    mov rax, r13
    shl rax, 5
    movups [r14 + rax], xmm4
    movups [r14 + rax + 16], xmm5
    inc r12
    jmp .sort_outer
.sorted:
    xor r12d, r12d
.trans:
    cmp r12, r15
    jae .gpu
    mov rcx, r12
    shl rcx, 5
    add rcx, r14
    mov rax, [rcx + 24]
    mov edx, [rax + SECT.quad_first]
    add edx, [rax + SECT.quad_opaque]
    add edx, [rax + SECT.quad_cutout]
    mov r8d, [rax + SECT.quad_count]
    sub r8d, [rax + SECT.quad_opaque]
    sub r8d, [rax + SECT.quad_cutout]
    call add_record
    inc r12
    jmp .trans

    ; ---- GPU culling, then one indirect multi-draw per pass -------------------------------
.gpu:
    call shadow_pass
    lea r9, [rel g_cam_mod]
    GL glProgramUniform3fv, rbx, U_CAM_MOD, 1, r9
    call gpu_cull
    GL glUseProgram, rbx
    GL glBindVertexArray, [rel g_world_vao]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 3, [rel g_ring]
    GL glBindBuffer, GL_DRAW_INDIRECT_BUFFER, [rel g_cmd_buf]
    ; pass 1: opaque
    mov r9, [rel g_n_opaque]
    test r9, r9
    jz .p1_done
    GL glProgramUniform1i, rbx, U_PASS, 0
    GL glMultiDrawArraysIndirect, GL_TRIANGLES, 0, [rel g_n_opaque], 0
    inc qword [rel g_world_draws]
.p1_done:
    ; pass 2: cutout (plants are single planes seen from both sides)
    cmp qword [rel g_n_cutout], 0
    je .p2_done
    GL glProgramUniform1i, rbx, U_PASS, 1
    GL glDisable, GL_CULL_FACE
    mov r8, [rel g_n_opaque]
    shl r8, 4                           ; byte offset of its commands
    GL glMultiDrawArraysIndirect, GL_TRIANGLES, r8, [rel g_n_cutout], 0
    GL glEnable, GL_CULL_FACE
    inc qword [rel g_world_draws]
.p2_done:
    ; pass 3: translucent (blended, no depth writes)
    mov rax, [rel g_rec_count]
    sub rax, [rel g_n_opaque]
    sub rax, [rel g_n_cutout]
    jz .p3_done
    mov [LOCAL(W_D)], eax
    ; the opaque scene, for the water's refraction and reflections
    cmp dword [rel g_water_quality], 0
    je .no_copy
    call refraction_copy
    GL glBindTextureUnit, REFR_COLOR_UNIT, [rel g_refr_color]
    GL glBindTextureUnit, REFR_DEPTH_UNIT, [rel g_refr_depth]
.no_copy:
    GL glDisable, GL_CULL_FACE          ; (water from below; others discard back faces)
    GL glProgramUniform1i, rbx, U_PASS, 2
    GL glEnable, GL_BLEND
    GL glBlendFunc, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA
    GL glDepthMask, GL_FALSE
    mov r8, [rel g_n_opaque]
    add r8, [rel g_n_cutout]
    shl r8, 4
    mov r9d, [LOCAL(W_D)]
    GL glMultiDrawArraysIndirect, GL_TRIANGLES, r8, r9, 0
    GL glDepthMask, GL_TRUE
    GL glDisable, GL_BLEND
    GL glEnable, GL_CULL_FACE
    inc qword [rel g_world_draws]
.p3_done:
    call outline_draw
    ; the depth pyramid for the next frame's occlusion test
    cmp dword [rel g_gpu_culling], 0
    je .no_hiz
    cmp dword [rel g_occlusion_culling], 0
    je .no_hiz
    call hiz_build
.no_hiz:
    ; the GPU is done with this slot when this fence signals
    GL glFenceSync, GL_SYNC_GPU_COMMANDS_COMPLETE, 0
    mov ecx, [rel g_slot]
    lea rdx, [rel g_fence]
    mov [rdx + rcx * 8], rax
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; entry_dist — squared distance from the camera to a pass entry's section
; centre.
;   in:  rcx = entry (rel xyz first)    out: xmm0
;   clobbers: xmm0, xmm1, xmm2
; -----------------------------------------------------------------------------
entry_dist:
    movss xmm0, [rcx]
    addss xmm0, [rel c_half]
    mulss xmm0, xmm0
    movss xmm1, [rcx + 4]
    addss xmm1, [rel c_half]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [rcx + 8]
    addss xmm1, [rel c_half]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    ret

; -----------------------------------------------------------------------------
; lod_records — draw records of the ready LOD tiles (in slot order).
;   in:  ecx = 0 land (opaque quads), 1 water (translucent)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC lod_records, 0, rbx, rsi, rdi
    mov edi, ecx
    cmp dword [rel g_lod_levels], 0
    je .done
    mov rsi, [rel g_lod_tiles]
    xor ebx, ebx
.t:
    cmp rbx, [rel g_lod_used]
    jae .done
    cmp dword [rsi + LODTILE.state], LT_READY
    jne .next
    mov r8d, [rsi + LODTILE.n_opaque]
    mov edx, [rsi + LODTILE.first]
    test edi, edi
    jz .have
    add edx, r8d
    mov r8d, [rsi + LODTILE.n_water]
.have:
    test r8d, r8d
    jz .next
    ; origins: the tile corner at its lowest quad
    mov ecx, [rsi + LODTILE.level]
    mov eax, LOD_CELLS
    shl eax, cl
    mov r9d, eax
    imul eax, [rsi + LODTILE.tx]
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos]
    cvtsd2ss xmm0, xmm0
    movss [rel g_vec_tmp], xmm0
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    movss [rel g_vec_tmp2], xmm0
    cvtsi2sd xmm0, dword [rsi + LODTILE.min_y]
    subsd xmm0, [rel g_cam_pos + 8]
    cvtsd2ss xmm0, xmm0
    movss [rel g_vec_tmp + 4], xmm0
    cvtsi2ss xmm0, dword [rsi + LODTILE.span]
    movss [rel g_vec_tmp2 + 4], xmm0
    mov eax, r9d
    imul eax, [rsi + LODTILE.tz]
    cvtsi2sd xmm0, eax
    subsd xmm0, [rel g_cam_pos + 16]
    cvtsd2ss xmm0, xmm0
    movss [rel g_vec_tmp + 8], xmm0
    and eax, 0xFFFF
    cvtsi2ss xmm0, eax
    movss [rel g_vec_tmp2 + 8], xmm0
    ; skip tiles wholly inside the level's ring (under the finer levels)
    ; or beyond it: the shader would discard every pixel
    call tile_ring_test
    test eax, eax
    jz .next
    mov ecx, [rsi + LODTILE.level]
    shl ecx, 24
    or r8d, ecx                         ; count | level << 24
    lea rcx, [rel g_vec_tmp]
    call add_record
    inc qword [rel g_lod_records]
.next:
    add rsi, LODTILE_size
    inc rbx
    jmp .t
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; tile_ring_test — does a LOD tile reach into its level's ring (with the
; cross-fade band, FADE in shaders/chunk.frag)? Uses the tile's camera-
; relative corner in g_vec_tmp.
;   in:  rsi = LODTILE*, r9d = tile size (blocks)
;   out: eax = 1 draw / 0 skip      clobbers: rax, rcx, xmm0-xmm5
; -----------------------------------------------------------------------------
tile_ring_test:
    cvtsi2ss xmm4, r9d
    ; x: near = max(x0, -x1, 0), far = max(|x0|, |x1|) (camera at 0)
    movss xmm0, [rel g_vec_tmp]
    movss xmm1, xmm0
    addss xmm1, xmm4
    xorps xmm2, xmm2
    subss xmm2, xmm1
    maxss xmm2, xmm0
    xorps xmm3, xmm3
    maxss xmm2, xmm3                    ; near x
    andps xmm0, [rel c_abs_mask]
    andps xmm1, [rel c_abs_mask]
    maxss xmm0, xmm1                    ; far x
    mulss xmm2, xmm2
    mulss xmm0, xmm0
    movss xmm5, [rel g_vec_tmp + 8]
    movss xmm1, xmm5
    addss xmm1, xmm4
    xorps xmm3, xmm3
    subss xmm3, xmm1
    maxss xmm3, xmm5
    xorps xmm4, xmm4
    maxss xmm3, xmm4                    ; near z
    mulss xmm3, xmm3
    addss xmm2, xmm3                    ; near^2
    andps xmm5, [rel c_abs_mask]
    andps xmm1, [rel c_abs_mask]
    maxss xmm5, xmm1
    mulss xmm5, xmm5
    addss xmm0, xmm5                    ; far^2
    mov ecx, [rsi + LODTILE.level]
    lea rax, [rel g_lod_r]
    ; near beyond the ring's outer edge: skip
    movss xmm1, [rax + rcx * 4]
    mulss xmm1, xmm1
    comiss xmm2, xmm1
    jae .skip
    ; far inside the inner edge minus the fade band: skip
    movss xmm1, [rax + rcx * 4 - 4]
    mulss xmm1, [rel c_fade_in]
    mulss xmm1, xmm1
    comiss xmm0, xmm1
    jbe .skip
    mov eax, 1
    ret
.skip:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; shadow_init — the shadow programs, the shadow data buffer, and (shadows
; on) the depth array, its framebuffer and the cascades' command buffers.
;   out: eax = 1/0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC shadow_init, 0, rbx
    lea rcx, [rel str_shadow_cs]
    call shader_create_compute
    cmp eax, -1
    je .fail
    mov [rel g_shadow_setup], eax
    lea rdx, [rel g_shadow_ssbo]
    GL glCreateBuffers, 1, rdx
    GL glNamedBufferStorage, [rel g_shadow_ssbo], SHADOW_DATA_BYTES, 0, 0
    mov dword [rel g_shadow_on], 0
    call shadow_apply
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; shadow_apply — follow the shadow settings (start-up and the settings
; screen): shadows off = no passes (the maps are kept); on = make the
; program and the maps if missing, or new maps if the resolution changed.
;   out: eax = 1 (0 if the program failed to build: shadows stay off)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC shadow_apply, 0, rbx
    mov dword [rel g_shadow_on], 0
    cmp dword [rel g_shadows], 0
    je .done
    cmp dword [rel g_shadow_prog], 0
    jne .have_prog
    lea rcx, [rel str_vs]
    lea rdx, [rel str_shadow_fs]
    call shader_create
    cmp eax, -1
    je .fail
    mov [rel g_shadow_prog], eax
.have_prog:
    cmp dword [rel g_shadow_tex], 0
    je .create
    mov eax, [rel g_shadow_res]
    cmp eax, [rel g_shadow_made_res]
    je .on
    ; another size: new maps
    lea rdx, [rel g_shadow_tex]
    GL glDeleteTextures, 1, rdx
    lea rdx, [rel g_shadow_fbo]
    GL glDeleteFramebuffers, 1, rdx
    lea rdx, [rel g_shadow_cmd]
    GL glDeleteBuffers, SHADOW_CASCADES, rdx
    mov dword [rel g_shadow_tex], 0
.create:
    ; depth array: one layer per cascade, compared on sampling (reverse-Z:
    ; lit where the fragment is at least as near the light as the map)
    lea r8, [rel g_shadow_tex]
    GL glCreateTextures, GL_TEXTURE_2D_ARRAY, 1, r8
    mov qword [rsp + 40], SHADOW_CASCADES
    GL glTextureStorage3D, [rel g_shadow_tex], 1, GL_DEPTH_COMPONENT32F, [rel g_shadow_res], [rel g_shadow_res]
    GL glTextureParameteri, [rel g_shadow_tex], GL_TEXTURE_MIN_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_shadow_tex], GL_TEXTURE_MAG_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_shadow_tex], GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, [rel g_shadow_tex], GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, [rel g_shadow_tex], GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE
    GL glTextureParameteri, [rel g_shadow_tex], GL_TEXTURE_COMPARE_FUNC, GL_GEQUAL
    lea rdx, [rel g_shadow_fbo]
    GL glCreateFramebuffers, 1, rdx
    ; (attach a layer now: the FBO is bound before each cascade attaches its own)
    GL glNamedFramebufferTextureLayer, [rel g_shadow_fbo], GL_DEPTH_ATTACHMENT, [rel g_shadow_tex], 0, 0
    xor ebx, ebx
.cmd:
    lea rdx, [rel g_shadow_cmd]
    lea rdx, [rdx + rbx * 4]
    GL glCreateBuffers, 1, rdx
    lea rax, [rel g_shadow_cmd]
    GL glNamedBufferStorage, [rax + rbx * 4], MAX_DRAWS * CMD_SIZE, 0, 0
    inc ebx
    cmp ebx, SHADOW_CASCADES
    jb .cmd
    mov eax, [rel g_shadow_res]
    mov [rel g_shadow_made_res], eax
    LOG_VAL LOG_LEVEL_INFO, "shadows: cascades 3, map size", rax
.on:
    mov dword [rel g_shadow_on], SHADOW_CASCADES
.done:
    mov eax, 1
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; shadow_shutdown — free the shadow resources.   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC shadow_shutdown, 0
    lea rdx, [rel g_shadow_ssbo]
    GL glDeleteBuffers, 1, rdx
    cmp dword [rel g_shadow_tex], 0
    je .done
    lea rdx, [rel g_shadow_tex]
    GL glDeleteTextures, 1, rdx
    lea rdx, [rel g_shadow_fbo]
    GL glDeleteFramebuffers, 1, rdx
    lea rdx, [rel g_shadow_cmd]
    GL glDeleteBuffers, SHADOW_CASCADES, rdx
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; shadow_pass — the cascade matrices (always: chunk.frag's sun-facing
; shading reads the light from them), then (shadows on) the casters within
; the shadow distance into each cascade's depth layer. Runs after the
; frame's own records are written and before they are culled; leaves
; g_rec_count as it found it.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define SP_CX       0
%define SP_CZ       4
%define SP_R        8                   ; shadow distance in chunks
%define SP_MAIN     16                  ; the frame's own record count
%define SP_C        24                  ; cascade
%define SP_TMP      32                  ; 16 bytes
PROC shadow_pass, 48, rbx, rsi, rdi, r12, r13
    ; ---- 1. cascade matrices ----
    mov ecx, [rel g_shadow_setup]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    lea rax, [rel g_cam_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, rbx, S_VIEWPROJ, 1, GL_FALSE
    lea r9, [rel g_sun_dir]
    GL glProgramUniform3fv, rbx, S_SUN, 1, r9
    ; split distances
    cvtsi2ss xmm0, dword [rel g_shadow_distance]
    shufps xmm0, xmm0, 0
    mulps xmm0, [rel c_split]
    movaps [rel g_shadow_tmp], xmm0
    lea r9, [rel g_shadow_tmp]
    GL glProgramUniform4fv, rbx, S_SPLITS, 1, r9
    cvtsi2ss xmm2, dword [rel g_shadow_res]
    GL glProgramUniform1f, rbx, S_RES
    ; camera position mod 4096 (texel snapping anchored to the world)
    xor esi, esi
.mod:
    lea rax, [rel g_cam_pos]
    movsd xmm0, [rax + rsi * 8]
    movsd xmm1, xmm0
    divsd xmm1, [rel c_mod4096]
    roundsd xmm1, xmm1, 9
    mulsd xmm1, [rel c_mod4096]
    subsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    lea rax, [rel g_cam_mod]
    movss [rax + rsi * 4], xmm0
    inc esi
    cmp esi, 3
    jb .mod
    lea r9, [rel g_cam_mod]
    GL glProgramUniform3fv, rbx, S_CAM_MOD, 1, r9
    GL glProgramUniform1i, rbx, S_CASCADES, SHADOW_CASCADES
    ; cascade 0 every frame, the other two in turn (all of them at first)
    mov eax, 7
    mov ecx, [rel g_shadow_frame]
    cmp ecx, 2
    jb .mask
    mov eax, 1 | 2
    test ecx, 1
    jz .mask
    mov eax, 1 | 4
.mask:
    cmp dword [rel g_shadow_on], 0
    jne .mask_ok
    mov eax, 7                          ; (shadows off: the light only)
.mask_ok:
    mov [rel g_shadow_mask], eax
    inc dword [rel g_shadow_frame]
    GL glProgramUniform1i, rbx, S_UPDATE, [rel g_shadow_mask]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, SHADOW_SSBO, [rel g_shadow_ssbo]
    GL glDispatchCompute, 1, 1, 1
    GL glMemoryBarrier, GL_SHADER_STORAGE_BARRIER_BIT | GL_COMMAND_BARRIER_BIT
    mov qword [rel g_shadow_records], 0
    cmp dword [rel g_shadow_on], 0
    je .done

    ; ---- 2. caster records: every section with geometry within reach ----
    mov rax, [rel g_rec_count]
    mov [LOCAL(SP_MAIN)], rax
    mov [rel g_shadow_base], rax
    movsd xmm0, [rel g_cam_pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    mov [LOCAL(SP_CX)], eax
    movsd xmm0, [rel g_cam_pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si rax, xmm0
    sar rax, 5
    mov [LOCAL(SP_CZ)], eax
    mov eax, [rel g_shadow_distance]
    add eax, 31
    shr eax, 5
    inc eax                             ; (casters a little beyond)
    mov [LOCAL(SP_R)], eax
    xor r12d, r12d                      ; loaded column index
.col:
    cmp r12, [rel g_loaded_count]
    jae .cols_done
    mov rax, [rel g_loaded]
    mov rsi, [rax + r12 * 8]
    inc r12
    cmp dword [rsi + COLUMN.state], COL_READY
    jne .col
    mov eax, [rsi + COLUMN.cx]
    sub eax, [LOCAL(SP_CX)]
    mov ecx, eax
    neg ecx
    cmovs ecx, eax
    cmp ecx, [LOCAL(SP_R)]
    ja .col
    mov eax, [rsi + COLUMN.cz]
    sub eax, [LOCAL(SP_CZ)]
    mov ecx, eax
    neg ecx
    cmovs ecx, eax
    cmp ecx, [LOCAL(SP_R)]
    ja .col
    mov r13, [rsi + COLUMN.geo_mask]
.sect:
    test r13, r13
    jz .col
    bsf rdi, r13
    btr r13, rdi
    mov rbx, [rsi + COLUMN.sections + rdi * 8]
    mov r8d, [rbx + SECT.quad_opaque]
    add r8d, [rbx + SECT.quad_cutout]   ; (stored first: one range)
    test r8d, r8d
    jz .sect
    mov [LOCAL(SP_TMP)], r8d
    INVOKE xyz_origins, [rsi + COLUMN.cx], rdi, [rsi + COLUMN.cz]
    mov edx, [rbx + SECT.quad_first]
    mov r8d, [LOCAL(SP_TMP)]
    lea rcx, [rel g_vec_tmp]
    call add_record
    jmp .sect
.cols_done:
    mov rax, [rel g_rec_count]
    sub rax, [LOCAL(SP_MAIN)]
    mov [rel g_shadow_records], rax
    test rax, rax
    jz .restore

    ; ---- 3. per cascade: cull, then draw its depth layer ----
    GL glBindFramebuffer, GL_FRAMEBUFFER, [rel g_shadow_fbo]
    GL glViewport, 0, 0, [rel g_shadow_res], [rel g_shadow_res]
    GL glEnable, GL_DEPTH_CLAMP
    GL glDisable, GL_CULL_FACE
    GL glBindVertexArray, [rel g_world_vao]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 0, [rel g_quad_buffer]
    call block_textures_bind
    mov dword [LOCAL(SP_C)], 0
.cascade:
    mov ecx, [LOCAL(SP_C)]
    bt dword [rel g_shadow_mask], ecx
    jnc .cascade_next                   ; (kept from last frame)
    ; cull against this cascade's square
    mov ecx, [rel g_cull_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    GL glProgramUniform1ui, rbx, C_COUNT, [rel g_shadow_records]
    mov eax, [rel g_slot]
    imul eax, eax, MAX_DRAWS
    add eax, [rel g_shadow_base]
    GL glProgramUniform1ui, rbx, C_BASE, rax
    mov eax, [LOCAL(SP_C)]
    inc eax
    GL glProgramUniform1i, rbx, C_CASCADE, rax
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 3, [rel g_ring]
    mov eax, [LOCAL(SP_C)]
    lea rcx, [rel g_shadow_cmd]
    mov eax, [rcx + rax * 4]
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 4, rax
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, SHADOW_SSBO, [rel g_shadow_ssbo]
    mov rax, [rel g_shadow_records]
    add eax, 63
    shr eax, 6
    GL glDispatchCompute, rax, 1, 1
    GL glMemoryBarrier, GL_COMMAND_BARRIER_BIT | GL_SHADER_STORAGE_BARRIER_BIT
    ; draw
    GL glNamedFramebufferTextureLayer, [rel g_shadow_fbo], GL_DEPTH_ATTACHMENT, [rel g_shadow_tex], 0, [LOCAL(SP_C)]
    GL glClear, GL_DEPTH_BUFFER_BIT
    mov ecx, [rel g_shadow_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    mov eax, [LOCAL(SP_C)]
    inc eax
    GL glProgramUniform1i, rbx, U_CASCADE, rax
    GL glBindBufferBase, GL_SHADER_STORAGE_BUFFER, 0, [rel g_quad_buffer]
    mov eax, [LOCAL(SP_C)]
    lea rcx, [rel g_shadow_cmd]
    mov eax, [rcx + rax * 4]
    GL glBindBuffer, GL_DRAW_INDIRECT_BUFFER, rax
    GL glMultiDrawArraysIndirect, GL_TRIANGLES, 0, [rel g_shadow_records], 0
    inc qword [rel g_world_draws]
.cascade_next:
    inc dword [LOCAL(SP_C)]
    cmp dword [LOCAL(SP_C)], SHADOW_CASCADES
    jb .cascade
    ; back to the scene
    GL glDisable, GL_DEPTH_CLAMP
    GL glEnable, GL_CULL_FACE
    GL glBindFramebuffer, GL_FRAMEBUFFER, [rel g_scene_fbo]
    GL glViewport, 0, 0, [rel g_viewport_w], [rel g_viewport_h]
.restore:
    mov rax, [LOCAL(SP_MAIN)]
    mov [rel g_rec_count], rax
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; refraction_copy — copy the scene's colour and depth so far (the opaque
; world) into the refraction textures, (re)creating them at the scene size.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC refraction_copy, 0, rbx, rsi
    mov ebx, [rel g_viewport_w]
    mov esi, [rel g_viewport_h]
    cmp ebx, [rel g_refr_w]
    jne .create
    cmp esi, [rel g_refr_h]
    jne .create
    cmp dword [rel g_refr_fbo], 0
    jne .copy
.create:
    mov [rel g_refr_w], ebx
    mov [rel g_refr_h], esi
    cmp dword [rel g_refr_fbo], 0
    je .new
    lea rdx, [rel g_refr_fbo]
    GL glDeleteFramebuffers, 1, rdx
    lea rdx, [rel g_refr_color]
    GL glDeleteTextures, 1, rdx
    lea rdx, [rel g_refr_depth]
    GL glDeleteTextures, 1, rdx
.new:
    lea rdx, [rel g_refr_fbo]
    GL glCreateFramebuffers, 1, rdx
    lea r8, [rel g_refr_color]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    GL glTextureStorage2D, [rel g_refr_color], 1, GL_RGBA16F, rbx, rsi
    GL glTextureParameteri, [rel g_refr_color], GL_TEXTURE_MIN_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_refr_color], GL_TEXTURE_MAG_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_refr_color], GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, [rel g_refr_color], GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE
    lea r8, [rel g_refr_depth]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    GL glTextureStorage2D, [rel g_refr_depth], 1, GL_DEPTH_COMPONENT32F, rbx, rsi
    GL glTextureParameteri, [rel g_refr_depth], GL_TEXTURE_MIN_FILTER, GL_NEAREST
    GL glTextureParameteri, [rel g_refr_depth], GL_TEXTURE_MAG_FILTER, GL_NEAREST
    GL glTextureParameteri, [rel g_refr_depth], GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, [rel g_refr_depth], GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE
    GL glNamedFramebufferTexture, [rel g_refr_fbo], GL_COLOR_ATTACHMENT0, [rel g_refr_color], 0
    GL glNamedFramebufferTexture, [rel g_refr_fbo], GL_DEPTH_ATTACHMENT, [rel g_refr_depth], 0
.copy:
    GL glBlitNamedFramebuffer, [rel g_scene_fbo], [rel g_refr_fbo], 0, 0, rbx, rsi, 0, 0, rbx, rsi, GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT, GL_NEAREST
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; outline_draw — thin lines around the targeted block (milestone 16).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC outline_draw, 32, rbx
    cmp dword [rel g_target_valid], 0
    je .done
    ; corner (camera-relative), a hair outside the cell
    xor ebx, ebx
.corner:
    lea rax, [rel g_target]
    cvtsi2sd xmm0, dword [rax + rbx * 4]
    lea rax, [rel g_cam_pos]
    subsd xmm0, [rax + rbx * 8]
    subsd xmm0, [rel c_outline_pad]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(0) + rbx * 4], xmm0
    inc ebx
    cmp ebx, 3
    jb .corner
    mov ecx, [rel g_outline_prog]
    call shader_program
    mov ebx, eax
    GL glUseProgram, rbx
    lea rax, [rel g_cam_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, rbx, 0, 1, GL_FALSE
    lea r9, [LOCAL(0)]
    GL glProgramUniform3fv, rbx, 1, 1, r9
    lea r9, [rel c_outline_size]
    GL glProgramUniform3fv, rbx, 2, 1, r9
    GL glDepthMask, GL_FALSE
    GL glDrawArrays, GL_LINES, 0, 24
    GL glDepthMask, GL_TRUE
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; water_camera — is the camera's block water? (g_cam_in_water)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC water_camera, 0
    movsd xmm0, [rel g_cam_pos]
    roundsd xmm0, xmm0, 9
    cvttsd2si ecx, xmm0
    movsd xmm0, [rel g_cam_pos + 8]
    roundsd xmm0, xmm0, 9
    cvttsd2si edx, xmm0
    movsd xmm0, [rel g_cam_pos + 16]
    roundsd xmm0, xmm0, 9
    cvttsd2si r8d, xmm0
    call world_block_at
    xor ecx, ecx
    cmp eax, [rel g_block_water]
    sete cl
    mov [rel g_cam_in_water], ecx
    RETURN
ENDPROC

section .rdata
align 8
c_outline_pad:  dq 0.002
align 4
c_outline_size: dd 1.004, 1.004, 1.004
