; =============================================================================
; save.asm — saving and loading worlds (milestone 17, DECISIONS D88).
;
; A world lives in saves/<name>/ (next to data/):
;   world.dat               text (DATA_FORMAT.md): format_version, name,
;                           seed, generator, game_mode, difficulty,
;                           hardcore, last_played, time
;   thumb.png               a recent view of the world (thumb.asm)
;   player.dat              text: eye position, look, flying, the slot in
;                           hand and the inventory (slot = i, item, count, wear)
;   overworld/region/r.<rx>.<rz>.vxr   region files (the overworld realm)
; Only columns that changed (block edits, flowing liquids) are saved: every
; other column is generated again from the seed, identically. A region file
; holds 32 x 32 columns:
;   header (3 sectors of 4 KB): "VXRG", u32 version, 8 reserved bytes, then
;   1024 x {u32 first sector, u32 byte length} (index = lx + lz * 32)
;   records, each in whole sectors: "VXCZ", u32 raw length, u32 compressed
;   length, then the LZ-compressed column (lz.asm):
;     "VXCR", u32 version, i32 cx, i32 cz, u32 sections, then per section
;     u8 sy, u8 kind and its blocks: kind 0 one block (u16), kind 1 a
;     palette (u16 count, u16 ids) + one byte per block, kind 2 u16 per
;     block (32768 blocks, index y << 10 | z << 5 | x).
; A record that grows past its sectors moves to the end of the file; the
; header entry is written after the data.
;
; Columns are saved on the main thread: when an edited column unloads
; (stream.asm), every autosave_minutes (world.cfg) and on exit. They are
; loaded by the generation job: it generates the column as usual (so biome
; tints etc. exist), then replaces its sections with the saved ones. Region
; file access is serialised by one SRW lock; a small cache keeps region
; headers.
;
; Public API:
;   save_open(rcx = world name) -> eax 1   before world_init: reads
;       world.dat (seed, generator, time) or prepares a new world
;   save_load_player() -> eax 1 if player.dat was read (sets g_cam_pos,
;       g_cam_yaw/pitch, g_save_player_flags, g_save_held)
;   save_column(rcx = COLUMN*) -> eax 1    (main thread)
;   save_load_column(rcx = COLUMN*, rdx = ARENA*)   (generation job)
;   save_all() -> eax 1                    world, player, changed columns
;   save_update()                           once per frame: autosave
;   save_peek(rcx = folder name, rdx = WORLD_INFO*) -> eax 1 if world.dat
;       was read: the world list's details (save.inc)
;   g_world_mode, g_world_difficulty, g_world_hardcore (MODE_*, DIFF_*):
;       the world's rules, from world.dat (defaults: creative, normal, off)
;   g_save_enabled (0 with --nosave), g_save_exists, g_save_player_flags,
;   g_save_held (block id, 0 = none), statistics g_save_*
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "section.inc"
%include "world_api.inc"
%include "packet.inc"
%include "save.inc"
%include "items.inc"
%include "containers.inc"

global save_open, save_load_player, save_column, save_load_column, save_all
global save_load_containers
global save_update
global g_save_enabled, g_save_exists, g_save_player_flags, g_save_held
global g_save_inv, g_save_inv_loaded, g_save_inv_sel
global g_save_columns, g_save_bytes, g_save_loaded, g_save_last_ms
global g_world_name, g_autosave_minutes, save_peek
global g_world_mode, g_world_difficulty, g_world_hardcore

extern str_copy, str_append_dec, str_append_sdec, str_ieq, str_parse_u64
extern str_parse_float, str_len
extern lz_bound, lz_compress, lz_decompress
extern block_find, timer_elapsed_us, thumb_write
extern g_seed_override, g_seed_override_set, g_force_flat, g_generator
extern g_world_seed, g_time_override, g_sim_time
extern g_cam_pos, g_cam_yaw, g_cam_pitch, g_held_block, g_block_names
extern g_inv, g_inv_sel, craft_sync, station_find, g_station_names
extern g_pl_pos, g_pl_eye, g_pl_flags, g_loaded, g_loaded_count

IMPORT CreateFileA, ReadFile, WriteFile, CloseHandle, SetFilePointerEx
IMPORT GetFileSizeEx, CreateDirectoryA, MoveFileExA, GetLocalTime
IMPORT AcquireSRWLockExclusive, ReleaseSRWLockExclusive

%define GENERIC_READ            0x80000000
%define GENERIC_WRITE           0x40000000
%define FILE_SHARE_READ         1
%define OPEN_EXISTING           3
%define OPEN_ALWAYS             4
%define CREATE_ALWAYS           2
%define FILE_ATTRIBUTE_NORMAL   0x80
%define INVALID_HANDLE          -1
%define MOVEFILE_REPLACE_EXISTING 1

%define FORMAT_VERSION  1
%define SECTOR          4096
%define HEADER_SECTORS  3
%define HEADER_BYTES    (16 + 1024 * 8)
%define REGION_SLOTS    16
%define MAGIC_REGION    0x47525856      ; "VXRG"
%define MAGIC_ZIPPED    0x5A435856      ; "VXCZ"
%define MAGIC_COLUMN    0x52435856      ; "VXCR"
%define KIND_ONE        0
%define KIND_PALETTE    1
%define KIND_RAW        2
%define RAW_CAP         (64 + SECTIONS_PER_COLUMN * (4 + 512 + 65536))
%define LZ_TABLE_BYTES  (4 << 12)

struc REGION
    .rx         resd 1
    .rz         resd 1
    .used       resd 1                  ; slot holds this region
    .next       resd 1                  ; first free sector at the end
    .table      resd 2048               ; sector, length per column
endstruc

section .rdata
str_saves:      db "saves", 0
str_bs:         db "\", 0
str_overworld:  db "overworld", 0
str_region:     db "region", 0
str_world_dat:  db "world.dat", 0
str_player_dat: db "player.dat", 0
str_cont_dat:   db "containers.dat", 0
str_cont_lbl:   db "containers.dat", 0
k_container_h:  db "container ", 0
t_head_cont:    db "# VoxelB chests (written by the game; DATA_FORMAT.md)", 10, 0
t_container:    db 10, 10, "[container ", 0
t_space:        db " ", 0
t_bracket:      db "]", 0
t_station:      db 10, "station = ", 0
t_burn:         db 10, "burn = ", 0
t_cook:         db 10, "cook = ", 0
k_station_c:    db "station", 0
k_burn:         db "burn", 0
k_cook:         db "cook", 0
str_tmp:        db ".tmp", 0
str_r:          db "r.", 0
str_dot:        db ".", 0
str_vxr:        db ".vxr", 0
str_world_lbl:  db "world.dat", 0
str_player_lbl: db "player.dat", 0
str_default:    db "world", 0
str_thumb:      db "thumb.png", 0
str_saves_bs:   db "saves\", 0
; keys
k_version:      db "format_version", 0
k_name:         db "name", 0
k_seed:         db "seed", 0
k_generator:    db "generator", 0
k_mode:         db "game_mode", 0
k_time:         db "time", 0
k_eye:          db "eye_position", 0
k_look:         db "look", 0
k_flying:       db "flying", 0
k_held:         db "held_block", 0
k_selected:     db "selected", 0
k_slot:         db "slot", 0
k_difficulty:   db "difficulty", 0
k_hardcore:     db "hardcore", 0
k_played:       db "last_played", 0
v_terrain:      db "terrain", 0
v_flat:         db "flat_test", 0
mode_0:         db "creative", 0
mode_1:         db "survival", 0
mode_2:         db "adventure", 0
mode_3:         db "spectator", 0
diff_0:         db "peaceful", 0
diff_1:         db "normal", 0
diff_2:         db "hard", 0
diff_3:         db "extreme", 0
diff_4:         db "ultra", 0
align 8
mode_names:     dq mode_0, mode_1, mode_2, mode_3
diff_names:     dq diff_0, diff_1, diff_2, diff_3, diff_4
; text pieces
t_head_world:   db "# VoxelB world (written by the game; DATA_FORMAT.md)", 10, 0
t_head_player:  db "# VoxelB player (written by the game; DATA_FORMAT.md)", 10, 0
t_version:      db "format_version = ", 0
t_name:         db 10, "name = ", 0
t_seed:         db 10, "seed = ", 0
t_gen:          db 10, "generator = ", 0
t_mode:         db 10, "game_mode = ", 0
t_difficulty:   db 10, "difficulty = ", 0
t_hardcore:     db 10, "hardcore = ", 0
t_played:       db 10, "last_played = ", 0
t_time:         db 10, "time = ", 0
t_eye:          db 10, "eye_position = ", 0
t_look:         db 10, "look = ", 0
t_flying:       db 10, "flying = ", 0
t_selected:     db 10, "selected = ", 0
t_slot:         db 10, "slot = ", 0
t_comma:        db ", ", 0
t_nl:           db 10, 0
str_newer:      db "save: this world was saved by a newer version (format_version ", 0
str_bad_region: db "save: a region file is damaged; its columns are generated fresh: ", 0
str_saved:      db "save: world saved, columns ", 0
str_s_bytes:    db " bytes ", 0
str_s_ms:       db ", ms ", 0
str_s_total:    db "; this session: columns written ", 0
str_s_loaded:   db ", loaded ", 0
str_opened:     db "save: world folder ", 0
str_new:        db " (new world)", 0
str_existing:   db " (loaded)", 0
align 8
c_10000:        dq 10000.0
c_24:           dq 24.0
c_half:         dq 0.5

section .data
align 4
g_save_enabled:     dd 1
g_autosave_minutes: dd 5
g_world_mode:       dd MODE_CREATIVE
g_world_difficulty: dd DIFF_NORMAL
g_world_hardcore:   dd 0

section .bss
alignb 8
g_lock:             resq 1              ; SRWLOCK (zero = unlocked)
g_save_exists:      resd 1
g_save_player_flags: resd 1
g_save_held:        resd 1
g_save_inv_loaded:  resd 1
g_save_inv_sel:     resd 1
alignb 8
g_save_inv:         resq INV_SAVED + 1  ; player.dat's slots, for inv_init (the
                                        ; off hand last)
g_cur_cont:         resd 1              ; containers.dat: the entry being read
g_save_columns:     resq 1              ; columns written
g_save_bytes:       resq 1              ; compressed bytes written
g_save_loaded:      resq 1              ; columns loaded from regions
g_save_last_ms:     resq 1              ; duration of the last full save
g_last_autosave:    resq 1
g_region_clock:     resd 1
g_world_name:       resb 64
g_dir:              resb PATH_CAP       ; saves\<name>\  (absolute)
g_rdir:             resb PATH_CAP       ; ...\overworld\region\  (absolute)
g_path:             resb PATH_CAP
g_peek_path:        resb PATH_CAP
g_systime:          resw 8              ; SYSTEMTIME
g_path2:            resb PATH_CAP
g_cfg_mark:         resq 1
alignb 16
g_regions:          resb REGION_SLOTS * REGION_size
g_hdr:              resb HEADER_SECTORS * SECTOR    ; (under the lock)
g_rec_hdr:          resd 4

section .text

; -----------------------------------------------------------------------------
; Small file helpers (handles are qwords; -1 = failure).
; -----------------------------------------------------------------------------
; open_file(rcx = path, edx = 0 read / 1 read+write create) -> rax handle
PROC open_file, 0
    mov eax, GENERIC_READ
    mov r9d, OPEN_EXISTING
    test edx, edx
    jz .open
    mov eax, GENERIC_READ | GENERIC_WRITE
    mov r9d, OPEN_ALWAYS
.open:
    mov qword [rsp + 32], r9
    mov dword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov qword [rsp + 48], 0
    mov edx, eax
    mov r8d, FILE_SHARE_READ
    xor r9d, r9d
    call [rel __imp_CreateFileA]
    RETURN
ENDPROC

; seek(rcx = handle, rdx = offset)
PROC seek, 0
    xor r8d, r8d
    xor r9d, r9d                        ; FILE_BEGIN
    call [rel __imp_SetFilePointerEx]
    RETURN
ENDPROC

; write_at(rcx = handle, rdx = offset, r8 = buffer, r9 = bytes) -> eax 1/0
PROC write_at, 16, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, r8
    mov rdi, r9
    call seek
    lea r9, [LOCAL(0)]
    mov qword [rsp + 32], 0
    API WriteFile, rbx, rsi, rdi, r9
    test eax, eax
    jz .done
    xor eax, eax
    cmp [LOCAL(0)], edi
    jne .done
    mov eax, 1
.done:
    RETURN
ENDPROC

; read_at(rcx = handle, rdx = offset, r8 = buffer, r9 = bytes) -> eax 1/0
PROC read_at, 16, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, r8
    mov rdi, r9
    call seek
    lea r9, [LOCAL(0)]
    mov qword [rsp + 32], 0
    API ReadFile, rbx, rsi, rdi, r9
    test eax, eax
    jz .done
    xor eax, eax
    cmp [LOCAL(0)], edi
    jne .done
    mov eax, 1
.done:
    RETURN
ENDPROC

; write_text(rcx = path, rdx = text) -> eax 1/0: via <path>.tmp + rename
PROC write_text, 16, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    lea rcx, [rel g_path2]
    mov rdx, rbx
    call str_copy
    lea rdx, [rel str_tmp]
    mov rcx, rax
    call str_copy
    mov rcx, rsi
    call str_len
    mov rdi, rax
    lea rcx, [rel g_path2]
    mov qword [rsp + 32], CREATE_ALWAYS
    mov dword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov qword [rsp + 48], 0
    mov edx, GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    call [rel __imp_CreateFileA]
    cmp rax, INVALID_HANDLE
    je .fail
    mov [LOCAL(0)], rax
    INVOKE write_at, rax, 0, rsi, rdi
    mov [LOCAL(8)], eax
    API CloseHandle, [LOCAL(0)]
    cmp dword [LOCAL(8)], 0
    je .fail
    lea rcx, [rel g_path2]
    API MoveFileExA, rcx, rbx, MOVEFILE_REPLACE_EXISTING
    test eax, eax
    jz .fail
    mov eax, 1
    RETURN
.fail:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; fixed-point text for doubles: append x with 4 decimals / parse one
; -----------------------------------------------------------------------------
; append_d(rcx = cursor, xmm0 = value) -> rax cursor
PROC append_d, 0
    mulsd xmm0, [rel c_10000]
    roundsd xmm0, xmm0, 0               ; nearest
    cvtsd2si rdx, xmm0
    mov r8d, 4
    call str_append_sdec
    RETURN
ENDPROC

; parse_d(rcx = text) -> xmm0 double, rdx = after, eax = 1 if a number
PROC parse_d, 0, rbx, rsi
    mov rsi, rcx
.space:
    cmp byte [rsi], ' '
    jne .sign
    inc rsi
    jmp .space
.sign:
    xor ebx, ebx
    cmp byte [rsi], '-'
    jne .int
    mov ebx, 1
    inc rsi
.int:
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .fail
    cvtsi2sd xmm0, rax
    xorpd xmm1, xmm1                    ; fraction
    mov rsi, rdx
    cmp byte [rsi], '.'
    jne .sign_fix
    inc rsi
    ; fraction digits
    mov rax, __?float64?__(0.1)
    movq xmm2, rax
.frac:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .sign_fix
    cvtsi2sd xmm3, eax
    mulsd xmm3, xmm2
    addsd xmm1, xmm3
    mov rax, __?float64?__(0.1)
    movq xmm3, rax
    mulsd xmm2, xmm3
    inc rsi
    jmp .frac
.sign_fix:
    addsd xmm0, xmm1
    test ebx, ebx
    jz .ok
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movapd xmm0, xmm1
.ok:
    mov rdx, rsi
    mov eax, 1
    RETURN
.fail:
    xorpd xmm0, xmm0
    mov rdx, rsi
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; save_open — the world folder; read world.dat if it exists.
;   in:  rcx = world name (0: "world")
;   out: eax = 1 (0 with saving disabled)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC save_open, 0, rbx
    test rcx, rcx
    jnz .named
    lea rcx, [rel str_default]
.named:
    mov rdx, rcx
    lea rcx, [rel g_world_name]
    call str_copy
    cmp dword [rel g_save_enabled], 0
    je .off
    ; folders: saves, saves\<name>, ...\overworld, ...\overworld\region
    lea rcx, [rel g_dir]
    lea rdx, [rel str_saves]
    call path_make
    lea rcx, [rel g_dir]
    API CreateDirectoryA, rcx, 0
    lea rcx, [rel g_dir]
    call str_len
    lea rcx, [rel g_dir]
    add rcx, rax
    lea rdx, [rel str_bs]
    call str_copy
    lea rdx, [rel g_world_name]
    mov rcx, rax
    call str_copy
    lea rdx, [rel str_bs]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_dir]
    API CreateDirectoryA, rcx, 0
    lea rcx, [rel g_rdir]
    lea rdx, [rel g_dir]
    call str_copy
    lea rdx, [rel str_overworld]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_rdir]
    API CreateDirectoryA, rcx, 0
    lea rcx, [rel g_rdir]
    call str_len
    lea rcx, [rel g_rdir]
    add rcx, rax
    lea rdx, [rel str_bs]
    call str_copy
    lea rdx, [rel str_region]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_rdir]
    API CreateDirectoryA, rcx, 0
    lea rcx, [rel g_rdir]
    call str_len
    lea rcx, [rel g_rdir]
    add rcx, rax
    lea rdx, [rel str_bs]
    call str_copy
    ; world.dat (a world without the keys: creative, normal, no hardcore)
    mov dword [rel g_world_mode], MODE_CREATIVE
    mov dword [rel g_world_difficulty], DIFF_NORMAL
    mov dword [rel g_world_hardcore], 0
    lea rdx, [rel str_world_dat]
    call load_dat
    test rax, rax
    jz .new
    mov dword [rel g_save_exists], 1
    lea rdx, [rel world_pair]
    lea r9, [rel str_world_lbl]
    INVOKE cfg_parse, rax, rdx, 0, r9
    call release_dat
.new:
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_opened]
    call log_append_str
    lea rcx, [rel g_dir]
    call log_append_str
    lea rcx, [rel str_new]
    cmp dword [rel g_save_exists], 0
    je .log
    lea rcx, [rel str_existing]
.log:
    call log_append_str
    call log_end
    call timer_elapsed_us
    mov [rel g_last_autosave], rax
    mov eax, 1
    RETURN
.off:
    LOG_INFO "save: disabled (--nosave)"
    xor eax, eax
    RETURN
ENDPROC

; load_dat(rdx = file name in the world folder) -> rax text (0 = missing);
; the text lives in the scratch arena until release_dat
PROC load_dat, 0, rbx
    mov rbx, rdx
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [rel g_cfg_mark], rax
    lea rcx, [rel g_path]
    lea rdx, [rel g_dir]
    call str_copy
    mov rcx, rax
    mov rdx, rbx
    call str_copy
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    RETURN
ENDPROC

release_dat:
    sub rsp, 40
    lea rcx, [rel g_arena_scratch]
    mov rdx, [rel g_cfg_mark]
    call arena_reset_to
    add rsp, 40
    ret

; world.dat callback: rcx = name, rdx = value
PROC world_pair, 0, rbx, rsi
    mov rbx, rcx
    mov rsi, rdx
    lea rdx, [rel k_version]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_version
    mov rcx, rsi
    call str_parse_u64
    cmp rax, FORMAT_VERSION
    jbe .done
    mov rbx, rax
    mov ecx, LOG_LEVEL_WARN
    call log_begin
    lea rcx, [rel str_newer]
    call log_append_str
    mov rcx, rbx
    call log_append_dec
    call log_end
    RETURN
.not_version:
    lea rdx, [rel k_seed]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_seed
    mov rcx, rsi
    call str_parse_u64
    test r8, r8
    jz .done
    mov [rel g_seed_override], eax
    mov dword [rel g_seed_override_set], 1
    RETURN
.not_seed:
    lea rdx, [rel k_generator]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_gen
    lea rdx, [rel v_flat]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jz .done
    mov dword [rel g_force_flat], 1
    RETURN
.not_gen:
    lea r8, [rel g_world_mode]
    lea r9, [rel g_world_difficulty]
    lea rax, [rel g_world_hardcore]
    mov [rsp + 32], rax
    INVOKE rules_pair, rbx, rsi
    test eax, eax
    jnz .done
    lea rdx, [rel k_time]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .done
    mov rcx, rsi
    call parse_d
    test eax, eax
    jz .done
    mulsd xmm0, [rel c_24]
    cvtsd2ss xmm0, xmm0
    movss [rel g_time_override], xmm0   ; (--time still wins)
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; save_load_player — read player.dat.
;   out: eax = 1 if loaded
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC save_load_player, 0
    mov dword [rel g_save_held], 0
    mov dword [rel g_save_inv_loaded], 0
    mov dword [rel g_save_inv_sel], 0
    lea rcx, [rel g_save_inv]
    xor eax, eax
    mov edx, INV_SAVED + 1
.clear:
    mov [rcx], rax
    add rcx, 8
    dec edx
    jnz .clear
    cmp dword [rel g_save_enabled], 0
    je .none
    cmp dword [rel g_save_exists], 0
    je .none
    lea rdx, [rel str_player_dat]
    call load_dat
    test rax, rax
    jz .none
    mov dword [rel g_save_player_flags], 0
    lea rdx, [rel player_pair]
    lea r9, [rel str_player_lbl]
    INVOKE cfg_parse, rax, rdx, 0, r9
    call release_dat
    LOG_INFO "save: player position, look and flight restored"
    mov eax, 1
    RETURN
.none:
    xor eax, eax
    RETURN
ENDPROC

; player.dat callback: rcx = name, rdx = value
PROC player_pair, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    lea rdx, [rel k_eye]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_eye
    xor edi, edi
.coord:
    mov rcx, rsi
    call parse_d
    test eax, eax
    jz .done
    lea rax, [rel g_cam_pos]
    movsd [rax + rdi * 8], xmm0
    lea rsi, [rdx + 1]                  ; past the comma
    cmp byte [rdx], ','
    jne .done
    inc edi
    cmp edi, 3
    jb .coord
    RETURN
.not_eye:
    lea rdx, [rel k_look]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_look
    mov rcx, rsi
    call parse_d
    test eax, eax
    jz .done
    cvtsd2ss xmm0, xmm0
    movss [rel g_cam_yaw], xmm0
    cmp byte [rdx], ','
    jne .done
    lea rcx, [rdx + 1]
    call parse_d
    test eax, eax
    jz .done
    cvtsd2ss xmm0, xmm0
    movss [rel g_cam_pitch], xmm0
    RETURN
.not_look:
    lea rdx, [rel k_flying]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_flying
    cmp byte [rsi], '1'
    jne .done
    or dword [rel g_save_player_flags], PF_FLYING
    RETURN
.not_flying:
    lea rdx, [rel k_held]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_held
    mov rcx, rsi
    call block_find
    cmp eax, 0
    jle .done
    mov [rel g_save_held], eax          ; (saves from before milestone 18)
    RETURN
.not_held:
    lea rdx, [rel k_selected]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_selected
    mov rcx, rsi
    call str_parse_u64
    cmp rax, INV_HOTBAR
    jae .done
    mov [rel g_save_inv_sel], eax
    RETURN
.not_selected:
    lea rdx, [rel k_slot]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .done
    mov rcx, rsi
    lea rdx, [rel g_save_inv]
    mov r8d, INV_SAVED + 1
    call parse_slot
    test eax, eax
    jz .done
    mov dword [rel g_save_inv_loaded], 1
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; parse_slot — "slot = <index>, <item>, <count>[, <durability>]" into the
; inventory waiting for the simulation (g_save_inv). Unknown items (a data
; file changed) are left out.
;   in:  rcx = value text, rdx = the slots (SLOT[]), r8d = how many
;   out: eax = 1 if a slot was stored
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define PS_BASE     0
%define PS_BOUND    8
%define PS_STORED   12
PROC parse_slot, 16, rbx, rsi, rdi
    mov [LOCAL(PS_BASE)], rdx
    mov [LOCAL(PS_BOUND)], r8d
    mov dword [LOCAL(PS_STORED)], 0
    mov rsi, rcx
    call cfg_next_token
    mov rsi, rdx
    mov rcx, rax
    call str_parse_u64
    cmp rax, INV_OFFHAND
    jne .index
    mov eax, INV_SAVED                  ; (the off hand: after the others)
.index:
    mov ecx, [LOCAL(PS_BOUND)]
    cmp rax, rcx
    jae .done
    mov rbx, [LOCAL(PS_BASE)]
    lea rbx, [rbx + rax * 8]
    test rsi, rsi
    jz .done
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    mov rcx, rax
    call item_find
    cmp eax, 0
    jle .done
    mov edi, eax
    test rsi, rsi
    jz .done
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    mov rcx, rax
    call str_parse_u64
    test rax, rax
    jz .done
    cmp rax, 64
    jbe .count
    mov eax, 64
.count:
    mov [rbx], di
    mov [rbx + 2], ax
    mov word [rbx + 4], 0
    mov dword [LOCAL(PS_STORED)], 1
    test rsi, rsi
    jz .done
    mov rcx, rsi
    call cfg_next_token
    mov rcx, rax
    call str_parse_u64
    mov [rbx + 4], ax
.done:
    mov eax, [LOCAL(PS_STORED)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; region_path — g_path = <region dir>r.<rx>.<rz>.vxr
;   in:  ecx = rx, edx = rz      clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC region_path, 0, rbx, rsi
    mov ebx, ecx
    mov esi, edx
    lea rcx, [rel g_path]
    lea rdx, [rel g_rdir]
    call str_copy
    lea rdx, [rel str_r]
    mov rcx, rax
    call str_copy
    movsxd rdx, ebx
    INVOKE str_append_sdec, rax, rdx, 0
    lea rdx, [rel str_dot]
    mov rcx, rax
    call str_copy
    movsxd rdx, esi
    INVOKE str_append_sdec, rax, rdx, 0
    lea rdx, [rel str_vxr]
    mov rcx, rax
    call str_copy
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; region_get — the cached header of a region (lock held). A region without
; a file gets an empty table; a damaged one too (logged).
;   in:  ecx = rx, edx = rz
;   out: rax = REGION*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC region_get, 16, rbx, rsi, rdi, r12
    mov esi, ecx
    mov edi, edx
    lea rbx, [rel g_regions]
    xor r12d, r12d
.find:
    cmp dword [rbx + REGION.used], 0
    je .next
    cmp [rbx + REGION.rx], esi
    jne .next
    cmp [rbx + REGION.rz], edi
    jne .next
    mov rax, rbx
    RETURN
.next:
    add rbx, REGION_size
    inc r12d
    cmp r12d, REGION_SLOTS
    jb .find
    ; take a slot round-robin
    mov eax, [rel g_region_clock]
    inc dword [rel g_region_clock]
    and eax, REGION_SLOTS - 1
    imul eax, eax, REGION_size
    lea rbx, [rel g_regions]
    add rbx, rax
    mov [rbx + REGION.rx], esi
    mov [rbx + REGION.rz], edi
    mov dword [rbx + REGION.used], 1
    mov dword [rbx + REGION.next], HEADER_SECTORS
    lea rdi, [rbx + REGION.table]
    xor eax, eax
    mov ecx, 2048
    rep stosd
    mov ecx, esi
    mov edx, [rbx + REGION.rz]
    call region_path
    lea rcx, [rel g_path]
    xor edx, edx
    call open_file
    cmp rax, INVALID_HANDLE
    je .done                            ; no file yet
    mov r12, rax
    lea r8, [rel g_hdr]
    INVOKE read_at, r12, 0, r8, HEADER_BYTES
    test eax, eax
    jz .damaged
    cmp dword [rel g_hdr], MAGIC_REGION
    jne .damaged
    cmp dword [rel g_hdr + 4], FORMAT_VERSION
    ja .damaged
    lea rsi, [rel g_hdr + 16]
    lea rdi, [rbx + REGION.table]
    mov ecx, 2048
    rep movsd
    ; the end of the file, in sectors
    lea rdx, [LOCAL(0)]
    API GetFileSizeEx, r12, rdx
    mov rax, [LOCAL(0)]
    add rax, SECTOR - 1
    shr rax, 12
    cmp eax, HEADER_SECTORS
    jae .end_ok
    mov eax, HEADER_SECTORS
.end_ok:
    mov [rbx + REGION.next], eax
    API CloseHandle, r12
    jmp .done
.damaged:
    API CloseHandle, r12
    mov ecx, LOG_LEVEL_WARN
    call log_begin
    lea rcx, [rel str_bad_region]
    call log_append_str
    lea rcx, [rel g_path]
    call log_append_str
    call log_end
    lea rdi, [rbx + REGION.table]
    xor eax, eax
    mov ecx, 2048
    rep stosd
.done:
    mov rax, rbx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; serialize — a column's sections into the raw record format.
;   in:  rcx = COLUMN*, rdx = out (RAW_CAP), r8 = scratch (64 KB ids + 8 KB map)
;   out: rax = raw bytes
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC serialize, 32, rbx, rsi, rdi, r12, r13, r14, r15
    mov rbx, rcx
    mov rdi, rdx                        ; cursor
    mov [LOCAL(0)], rdx
    mov r14, r8                         ; ids
    lea r15, [r8 + 65536]               ; map: block id -> palette index + 1 (u16 x 4096)
    mov dword [rdi], MAGIC_COLUMN
    mov dword [rdi + 4], FORMAT_VERSION
    mov eax, [rbx + COLUMN.cx]
    mov [rdi + 8], eax
    mov eax, [rbx + COLUMN.cz]
    mov [rdi + 12], eax
    mov dword [rdi + 16], 0             ; sections (counted below)
    add rdi, 20
    xor r12d, r12d                      ; sy
.section:
    mov rcx, [rbx + COLUMN.sections + r12 * 8]
    test rcx, rcx
    jz .next
    mov rdx, r14
    call section_decode
    mov rax, [LOCAL(0)]
    inc dword [rax + 16]
    mov [rdi], r12b
    ; palette (stop past 256)
    mov r13, rdi
    mov rdi, r15
    xor eax, eax
    mov ecx, 4096 * 2 / 8
    rep stosq
    mov rdi, r13
    xor esi, esi                        ; distinct count
    xor ecx, ecx
.pal:
    movzx eax, word [r14 + rcx * 2]
    and eax, 4095
    cmp word [r15 + rax * 2], 0
    jne .pal_next
    inc esi
    mov [r15 + rax * 2], si
    cmp esi, 256
    ja .raw
.pal_next:
    inc ecx
    cmp ecx, SECTION_VOLUME
    jb .pal
    cmp esi, 1
    je .one
    ; palette: count, ids in order of first appearance, one byte each
    mov byte [rdi + 1], KIND_PALETTE
    mov [rdi + 2], si
    lea r8, [rdi + 4]                   ; palette ids
    xor ecx, ecx
.pal_ids:
    cmp ecx, 4096
    jae .pal_bytes
    movzx eax, word [r15 + rcx * 2]
    test eax, eax
    jz .pal_id_next
    mov [r8 + rax * 2 - 2], cx
.pal_id_next:
    inc ecx
    jmp .pal_ids
.pal_bytes:
    lea r9, [r8 + rsi * 2]              ; indices
    xor ecx, ecx
.idx:
    movzx eax, word [r14 + rcx * 2]
    and eax, 4095
    movzx eax, word [r15 + rax * 2]
    dec eax
    mov [r9 + rcx], al
    inc ecx
    cmp ecx, SECTION_VOLUME
    jb .idx
    lea rdi, [r9 + SECTION_VOLUME]
    jmp .next
.one:
    mov byte [rdi + 1], KIND_ONE
    mov ax, [r14]
    mov [rdi + 2], ax
    add rdi, 4
    jmp .next
.raw:
    mov byte [rdi + 1], KIND_RAW
    lea rdi, [rdi + 2]
    mov rsi, r14
    mov ecx, SECTION_VOLUME * 2 / 8
    rep movsq
.next:
    inc r12d
    cmp r12d, SECTIONS_PER_COLUMN
    jb .section
    mov rax, rdi
    sub rax, [LOCAL(0)]
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; save_column — write one column into its region file (main thread).
;   in:  rcx = COLUMN*
;   out: eax = 1 written
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define SC_MARK     0
%define SC_RAW      8
%define SC_ZIP      16
%define SC_ZLEN     24
%define SC_HANDLE   32
%define SC_SLOT     40
PROC save_column, 48, rbx, rsi, rdi, r12, r13
    mov rbx, rcx
    xor eax, eax
    cmp dword [rel g_save_enabled], 0
    je .out
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(SC_MARK)], rax
    ; raw record + ids/map scratch + compressed + LZ table
    mov rcx, RAW_CAP
    call lz_bound
    mov rsi, rax                        ; compressed capacity
    lea rdx, [rax + RAW_CAP + 65536 + 8192 + LZ_TABLE_BYTES + 64]
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, rdx, 64
    test rax, rax
    jz .fail
    mov [LOCAL(SC_RAW)], rax
    lea r8, [rax + RAW_CAP]             ; ids + map
    INVOKE serialize, rbx, rax, r8
    mov rdi, rax                        ; raw bytes
    mov rax, [LOCAL(SC_RAW)]
    lea r8, [rax + RAW_CAP + 65536 + 8192]      ; compressed (12-byte header first)
    mov [LOCAL(SC_ZIP)], r8
    lea r9, [r8 + 16]
    add r9, rsi                         ; LZ table after it
    add r8, 12
    INVOKE lz_compress, rax, rdi, r8, r9
    lea r12, [rax + 12]                 ; record bytes
    mov [LOCAL(SC_ZLEN)], r12
    mov rax, [LOCAL(SC_ZIP)]
    mov dword [rax], MAGIC_ZIPPED
    mov [rax + 4], edi
    lea ecx, [r12d - 12]
    mov [rax + 8], ecx

    lea rcx, [rel g_lock]
    API AcquireSRWLockExclusive, rcx
    mov ecx, [rbx + COLUMN.cx]
    sar ecx, 5
    mov edx, [rbx + COLUMN.cz]
    sar edx, 5
    call region_get
    mov r13, rax                        ; REGION*
    mov eax, [rbx + COLUMN.cx]
    and eax, 31
    mov ecx, [rbx + COLUMN.cz]
    and ecx, 31
    shl ecx, 5
    or eax, ecx
    mov [LOCAL(SC_SLOT)], rax
    ; where: in place if it fits its old sectors, else at the end
    mov ecx, [r13 + REGION.table + rax * 8]       ; first sector
    mov edx, [r13 + REGION.table + rax * 8 + 4]   ; old length
    add edx, SECTOR - 1
    shr edx, 12
    mov r8, r12
    add r8, SECTOR - 1
    shr r8, 12                          ; sectors needed
    test ecx, ecx
    jz .append
    cmp r8d, edx
    jbe .place
.append:
    mov ecx, [r13 + REGION.next]
    add [r13 + REGION.next], r8d
.place:
    mov esi, ecx                        ; first sector
    mov ecx, [r13 + REGION.rx]
    mov edx, [r13 + REGION.rz]
    call region_path
    lea rcx, [rel g_path]
    mov edx, 1
    call open_file
    cmp rax, INVALID_HANDLE
    je .unlock_fail
    mov [LOCAL(SC_HANDLE)], rax
    ; a new file: its header first
    cmp esi, HEADER_SECTORS
    jne .header_ok
    mov rax, [LOCAL(SC_SLOT)]
    cmp dword [r13 + REGION.table + rax * 8], 0
    jne .header_ok
    call write_header                   ; (whole header: also fresh files)
.header_ok:
    mov rdx, rsi
    shl rdx, 12
    INVOKE write_at, [LOCAL(SC_HANDLE)], rdx, [LOCAL(SC_ZIP)], r12
    test eax, eax
    jz .close_fail
    ; then its header entry
    mov rax, [LOCAL(SC_SLOT)]
    mov [r13 + REGION.table + rax * 8], esi
    mov [r13 + REGION.table + rax * 8 + 4], r12d
    lea r8, [r13 + REGION.table + rax * 8]
    lea rdx, [rax * 8 + 16]
    INVOKE write_at, [LOCAL(SC_HANDLE)], rdx, r8, 8
    test eax, eax
    jz .close_fail
    API CloseHandle, [LOCAL(SC_HANDLE)]
    lea rcx, [rel g_lock]
    API ReleaseSRWLockExclusive, rcx
    mov dword [rbx + COLUMN.modified], 0
    inc qword [rel g_save_columns]
    add [rel g_save_bytes], r12
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(SC_MARK)]
    mov eax, 1
.out:
    RETURN
.close_fail:
    API CloseHandle, [LOCAL(SC_HANDLE)]
.unlock_fail:
    lea rcx, [rel g_lock]
    API ReleaseSRWLockExclusive, rcx
.fail:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(SC_MARK)]
    LOG_WARN "save: could not write a column to its region file"
    xor eax, eax
    RETURN
ENDPROC

; write_header — the region's whole header (magic, version, table) into the
; open file; in: r13 = REGION*, [LOCAL(SC_HANDLE)] of save_column's frame
; (called from save_column only)
write_header:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    lea rdi, [rel g_hdr]
    xor eax, eax
    mov ecx, HEADER_SECTORS * SECTOR / 8
    rep stosq
    mov dword [rel g_hdr], MAGIC_REGION
    mov dword [rel g_hdr + 4], FORMAT_VERSION
    lea rsi, [r13 + REGION.table]
    lea rdi, [rel g_hdr + 16]
    mov ecx, 2048
    rep movsd
    ; (the caller's frame: rsp + 48 + 24 (pushes) + 8 (return) = its rsp)
    mov rcx, [rsp + 80 + OUTGOING_SIZE + SC_HANDLE]
    xor edx, edx
    lea r8, [rel g_hdr]
    mov r9d, HEADER_SECTORS * SECTOR
    call write_at
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret

; -----------------------------------------------------------------------------
; save_load_column — replace a freshly generated column's sections with its
; saved ones, if it was saved (generation job, any thread).
;   in:  rcx = COLUMN* (GENERATING), rdx = scratch ARENA* of the worker
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define LC_MARK     0
%define LC_BUF      8
%define LC_LEN      16
%define LC_RAW      24
%define LC_END      32
%define LC_IDS      40
PROC save_load_column, 48, rbx, rsi, rdi, r12, r13, r14, r15
    mov rbx, rcx
    mov r15, rdx
    cmp dword [rel g_save_enabled], 0
    je .out
    cmp dword [rel g_save_exists], 0    ; (a new world has no regions yet,
    jne .look                           ;  until something was saved)
    cmp qword [rel g_save_columns], 0
    je .out
.look:
    lea rcx, [rel g_lock]
    API AcquireSRWLockExclusive, rcx
    mov ecx, [rbx + COLUMN.cx]
    sar ecx, 5
    mov edx, [rbx + COLUMN.cz]
    sar edx, 5
    call region_get
    mov r13, rax
    mov eax, [rbx + COLUMN.cx]
    and eax, 31
    mov ecx, [rbx + COLUMN.cz]
    and ecx, 31
    shl ecx, 5
    or eax, ecx
    mov esi, [r13 + REGION.table + rax * 8]       ; sector
    mov edi, [r13 + REGION.table + rax * 8 + 4]   ; length
    test esi, esi
    jz .unlock_out
    cmp edi, 12
    jbe .unlock_out
    mov rcx, r15
    call arena_mark
    mov [LOCAL(LC_MARK)], rax
    mov edx, edi
    INVOKE arena_alloc, r15, rdx, 16
    test rax, rax
    jz .unlock_reset
    mov [LOCAL(LC_BUF)], rax
    mov ecx, [r13 + REGION.rx]
    mov edx, [r13 + REGION.rz]
    call region_path
    lea rcx, [rel g_path]
    xor edx, edx
    call open_file
    cmp rax, INVALID_HANDLE
    je .unlock_reset
    mov r12, rax
    mov rdx, rsi
    shl rdx, 12
    INVOKE read_at, r12, rdx, [LOCAL(LC_BUF)], rdi
    mov [LOCAL(LC_LEN)], eax
    API CloseHandle, r12
    lea rcx, [rel g_lock]
    API ReleaseSRWLockExclusive, rcx
    cmp dword [LOCAL(LC_LEN)], 0
    je .reset
    ; expand
    mov rsi, [LOCAL(LC_BUF)]
    cmp dword [rsi], MAGIC_ZIPPED
    jne .bad
    mov eax, [rsi + 8]
    add eax, 12
    cmp eax, edi
    ja .bad
    mov eax, [rsi + 4]                  ; raw length
    cmp eax, RAW_CAP
    ja .bad
    mov [LOCAL(LC_LEN)], eax
    mov edx, eax
    add edx, 65536 + 64
    INVOKE arena_alloc, r15, rdx, 16
    test rax, rax
    jz .reset
    mov [LOCAL(LC_RAW)], rax
    mov ecx, [LOCAL(LC_LEN)]
    lea rdx, [rax + rcx + 63]
    and rdx, -16
    mov [LOCAL(LC_IDS)], rdx
    mov edx, [rsi + 8]
    lea rcx, [rsi + 12]
    mov r9d, [LOCAL(LC_LEN)]
    INVOKE lz_decompress, rcx, rdx, [LOCAL(LC_RAW)], r9
    mov ecx, [LOCAL(LC_LEN)]
    cmp rax, rcx
    jne .bad
    ; parse
    mov rsi, [LOCAL(LC_RAW)]
    lea rax, [rsi + rcx]
    mov [LOCAL(LC_END)], rax
    cmp dword [rsi], MAGIC_COLUMN
    jne .bad
    mov eax, [rsi + 8]
    cmp eax, [rbx + COLUMN.cx]
    jne .bad
    mov eax, [rsi + 12]
    cmp eax, [rbx + COLUMN.cz]
    jne .bad
    mov r14d, [rsi + 16]                ; sections
    add rsi, 20
    ; the generated sections go
    xor r12d, r12d
.free:
    mov rcx, [rbx + COLUMN.sections + r12 * 8]
    mov qword [rbx + COLUMN.sections + r12 * 8], 0
    call section_free
    inc r12d
    cmp r12d, SECTIONS_PER_COLUMN
    jb .free
.sect:
    test r14d, r14d
    jz .loaded
    dec r14d
    lea rax, [rsi + 4]
    cmp rax, [LOCAL(LC_END)]
    ja .loaded                          ; (truncated: keep what was read)
    movzx r12d, byte [rsi]              ; sy
    cmp r12d, SECTIONS_PER_COLUMN
    jae .loaded
    movzx eax, byte [rsi + 1]
    mov rdi, [LOCAL(LC_IDS)]
    cmp eax, KIND_ONE
    je .k_one
    cmp eax, KIND_PALETTE
    je .k_pal
    cmp eax, KIND_RAW
    jne .loaded
    lea rax, [rsi + 2 + SECTION_VOLUME * 2]
    cmp rax, [LOCAL(LC_END)]
    ja .loaded
    add rsi, 2
    mov ecx, SECTION_VOLUME * 2 / 8
    rep movsq
    jmp .build
.k_one:
    movzx eax, word [rsi + 2]
    add rsi, 4
    mov ecx, SECTION_VOLUME
    rep stosw
    jmp .build
.k_pal:
    movzx ecx, word [rsi + 2]           ; palette count
    lea r8, [rsi + 4]                   ; palette
    lea r9, [r8 + rcx * 2]              ; indices
    lea rax, [r9 + SECTION_VOLUME]
    cmp rax, [LOCAL(LC_END)]
    ja .loaded
    mov r10d, ecx
    xor ecx, ecx
.k_pal_b:
    movzx eax, byte [r9 + rcx]
    cmp eax, r10d
    jb .k_pal_ok
    xor eax, eax                        ; (corrupt index: the first entry)
.k_pal_ok:
    movzx eax, word [r8 + rax * 2]
    mov [rdi + rcx * 2], ax
    inc ecx
    cmp ecx, SECTION_VOLUME
    jb .k_pal_b
    lea rsi, [r9 + SECTION_VOLUME]
.build:
    INVOKE section_build, [LOCAL(LC_IDS)], [rbx + COLUMN.cx], r12, [rbx + COLUMN.cz]
    mov [rbx + COLUMN.sections + r12 * 8], rax
    jmp .sect
.loaded:
    lock inc qword [rel g_save_loaded]
.reset:
    mov rcx, r15
    INVOKE arena_reset_to, rcx, [LOCAL(LC_MARK)]
.out:
    RETURN
.bad:
    LOG_WARN "save: a saved column is damaged; it is generated fresh"
    jmp .reset
.unlock_reset:
    mov rcx, r15
    INVOKE arena_reset_to, rcx, [LOCAL(LC_MARK)]
.unlock_out:
    lea rcx, [rel g_lock]
    API ReleaseSRWLockExclusive, rcx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; write_world_dat / write_player_dat — the text files (scratch arena text).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC write_world_dat, 16, rbx
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, 4096, 16
    test rax, rax
    jz .done
    mov rbx, rax
    mov rcx, rax
    lea rdx, [rel t_head_world]
    call str_copy
    lea rdx, [rel t_version]
    mov rcx, rax
    call str_copy
    INVOKE str_append_dec, rax, FORMAT_VERSION, 0
    lea rdx, [rel t_name]
    mov rcx, rax
    call str_copy
    lea rdx, [rel g_world_name]
    mov rcx, rax
    call str_copy
    lea rdx, [rel t_seed]
    mov rcx, rax
    call str_copy
    mov edx, [rel g_world_seed]
    INVOKE str_append_dec, rax, rdx, 0
    lea rdx, [rel t_gen]
    mov rcx, rax
    call str_copy
    lea rdx, [rel v_terrain]
    cmp dword [rel g_generator], 1
    je .gen
    lea rdx, [rel v_flat]
.gen:
    mov rcx, rax
    call str_copy
    lea rdx, [rel t_mode]
    mov rcx, rax
    call str_copy
    mov edx, [rel g_world_mode]
    lea rcx, [rel mode_names]
    mov rdx, [rcx + rdx * 8]
    mov rcx, rax
    call str_copy
    lea rdx, [rel t_difficulty]
    mov rcx, rax
    call str_copy
    mov edx, [rel g_world_difficulty]
    lea rcx, [rel diff_names]
    mov rdx, [rcx + rdx * 8]
    mov rcx, rax
    call str_copy
    lea rdx, [rel t_hardcore]
    mov rcx, rax
    call str_copy
    mov edx, [rel g_world_hardcore]
    INVOKE str_append_dec, rax, rdx, 0
    lea rdx, [rel t_played]
    mov rcx, rax
    call str_copy
    mov rcx, rax
    call append_now
    lea rdx, [rel t_time]
    mov rcx, rax
    call str_copy
    movsd xmm0, [rel g_sim_time]
    mov rcx, rax
    call append_d
    lea rdx, [rel t_nl]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_path]
    lea rdx, [rel g_dir]
    call str_copy
    lea rdx, [rel str_world_dat]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_path]
    mov rdx, rbx
    call write_text
.done:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    RETURN
ENDPROC

PROC write_player_dat, 16, rbx, rsi, rdi
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, 4096, 16
    test rax, rax
    jz .done
    mov rbx, rax
    mov rcx, rax
    lea rdx, [rel t_head_player]
    call str_copy
    lea rdx, [rel t_version]
    mov rcx, rax
    call str_copy
    INVOKE str_append_dec, rax, FORMAT_VERSION, 0
    ; eyes = feet + eye height
    lea rdx, [rel t_eye]
    mov rcx, rax
    call str_copy
    movsd xmm0, [rel g_pl_pos]
    mov rcx, rax
    call append_d
    lea rdx, [rel t_comma]
    mov rcx, rax
    call str_copy
    cvtss2sd xmm0, [rel g_pl_eye]
    addsd xmm0, [rel g_pl_pos + 8]
    mov rcx, rax
    call append_d
    lea rdx, [rel t_comma]
    mov rcx, rax
    call str_copy
    movsd xmm0, [rel g_pl_pos + 16]
    mov rcx, rax
    call append_d
    lea rdx, [rel t_look]
    mov rcx, rax
    call str_copy
    cvtss2sd xmm0, [rel g_cam_yaw]
    mov rcx, rax
    call append_d
    lea rdx, [rel t_comma]
    mov rcx, rax
    call str_copy
    cvtss2sd xmm0, [rel g_cam_pitch]
    mov rcx, rax
    call append_d
    lea rdx, [rel t_flying]
    mov rcx, rax
    call str_copy
    xor edx, edx
    test dword [rel g_pl_flags], PF_FLYING
    setnz dl
    INVOKE str_append_dec, rax, rdx, 0
    ; the inventory (milestone 18): the slot in hand, then every used slot
    lea rdx, [rel t_selected]
    mov rcx, rax
    call str_copy
    mov edx, [rel g_inv_sel]
    INVOKE str_append_dec, rax, rdx, 0
    xor esi, esi
.slot:
    cmp esi, INV_SAVED                  ; (with the carried stack and the grid,
    jb .slot_go                         ; then the off hand)
    cmp esi, INV_OFFHAND
    je .slot_go
    ja .slots_done
    mov esi, INV_OFFHAND
.slot_go:
    lea rcx, [rel g_inv]
    lea rdi, [rcx + rsi * 8]
    movzx ecx, word [rdi]
    test ecx, ecx
    jz .slot_next
    lea rdx, [rel t_slot]
    mov rcx, rax
    call str_copy
    INVOKE str_append_dec, rax, rsi, 0
    lea rdx, [rel t_comma]
    mov rcx, rax
    call str_copy
    movzx edx, word [rdi]
    lea rcx, [rel g_item_names]
    mov rdx, [rcx + rdx * 8]
    mov rcx, rax
    call str_copy
    lea rdx, [rel t_comma]
    mov rcx, rax
    call str_copy
    movzx edx, word [rdi + 2]
    INVOKE str_append_dec, rax, rdx, 0
    lea rdx, [rel t_comma]
    mov rcx, rax
    call str_copy
    movzx edx, word [rdi + 4]
    INVOKE str_append_dec, rax, rdx, 0
.slot_next:
    inc esi
    jmp .slot
.slots_done:
    lea rdx, [rel t_nl]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_path]
    lea rdx, [rel g_dir]
    call str_copy
    lea rdx, [rel str_player_dat]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_path]
    mov rdx, rbx
    call write_text
.done:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    RETURN
ENDPROC


; -----------------------------------------------------------------------------
; save_load_containers — containers.dat: what is in the chests (milestone 18;
; after cont_reset).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC save_load_containers, 0
    cmp dword [rel g_save_enabled], 0
    je .none
    cmp dword [rel g_save_exists], 0
    je .none
    lea rdx, [rel str_cont_dat]
    call load_dat
    test rax, rax
    jz .release
    mov dword [rel g_cur_cont], -1
    lea rdx, [rel cont_pair]
    lea r9, [rel str_cont_lbl]
    mov qword [rsp + 32], CFG_SECTIONS
    INVOKE cfg_parse_ex, rax, rdx, 0, r9
.release:
    call release_dat
.none:
    RETURN
ENDPROC

; cur_entry — rax = &g_conts[g_cur_cont]   clobbers: rax, rdx
cur_entry:
    mov eax, [rel g_cur_cont]
    imul eax, eax, CONT_size
    lea rdx, [rel g_conts]
    add rax, rdx
    ret

; parse_int — eax = the signed number at rcx (spaces skipped), rdx = past it
parse_int:
    xor eax, eax
    xor r8d, r8d                        ; negative
.space:
    cmp byte [rcx], ' '
    jne .sign
    inc rcx
    jmp .space
.sign:
    cmp byte [rcx], '-'
    jne .digit
    mov r8d, 1
    inc rcx
.digit:
    movzx edx, byte [rcx]
    sub edx, '0'
    cmp edx, 9
    ja .end
    imul eax, eax, 10
    add eax, edx
    inc rcx
    jmp .digit
.end:
    test r8d, r8d
    jz .out
    neg eax
.out:
    mov rdx, rcx
    ret

; containers.dat callback: rcx = name or header, rdx = value (0: header)
PROC cont_pair, 16, rbx, rsi
    mov rbx, rcx
    mov rsi, rdx
    test rsi, rsi
    jnz .setting
    ; "[container x y z]"
    mov dword [rel g_cur_cont], -1
    lea rdx, [rel k_container_h]
    xor ecx, ecx
.prefix:
    mov al, [rdx + rcx]
    test al, al
    jz .coords
    cmp al, [rbx + rcx]
    jne .done
    inc ecx
    jmp .prefix
.coords:
    lea rcx, [rbx + rcx]
    call parse_int
    mov [LOCAL(0)], eax
    mov rcx, rdx
    call parse_int
    mov [LOCAL(4)], eax
    mov rcx, rdx
    call parse_int
    mov r8d, eax
    mov ecx, [LOCAL(0)]
    mov edx, [LOCAL(4)]
    call cont_get
    mov [rel g_cur_cont], eax
    RETURN
.setting:
    cmp dword [rel g_cur_cont], -1
    je .done
    lea rdx, [rel k_station_c]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_station
    mov rcx, rsi
    call station_find
    cmp eax, 0
    jle .done
    mov ecx, eax
    call cur_entry
    mov [rax + CONT.station], cl
    RETURN
.not_station:
    lea rdx, [rel k_burn]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_burn
    mov rcx, rsi
    call parse_int
    mov [LOCAL(0)], eax
    lea rcx, [rdx + 1]                  ; past ','
    call parse_int
    mov ecx, eax
    call cur_entry
    mov [rax + CONT.burn_max], ecx
    mov ecx, [LOCAL(0)]
    mov [rax + CONT.burn], ecx
    RETURN
.not_burn:
    lea rdx, [rel k_cook]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_cook
    mov rcx, rsi
    call parse_int
    mov ecx, eax
    call cur_entry
    mov [rax + CONT.cook], ecx
    RETURN
.not_cook:
    lea rdx, [rel k_slot]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .done
    mov ecx, [rel g_cur_cont]
    call cont_slots
    mov rdx, rax
    mov rcx, rsi
    mov r8d, CONT_SLOTS
    call parse_slot
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; write_containers — containers.dat: every container that holds something.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC write_containers, 16, rbx, rsi, rdi, r12
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    ; room: a line per slot (48 bytes is plenty) and a header per container
    mov eax, [rel g_cont_count]
    imul eax, eax, CONT_SLOTS * 48 + 64
    add eax, 256
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_alloc, rcx, rax, 16
    test rax, rax
    jz .done
    mov rbx, rax
    mov rcx, rax
    lea rdx, [rel t_head_cont]
    call str_copy
    lea rdx, [rel t_version]
    mov rcx, rax
    call str_copy
    INVOKE str_append_dec, rax, FORMAT_VERSION, 0
    lea rdi, [rel g_conts]
    xor r12d, r12d
.cont:
    cmp r12d, [rel g_cont_count]
    jae .write
    cmp dword [rdi + CONT.used], 0
    je .cont_next
    ; anything in it?
    cmp dword [rdi + CONT.burn], 0
    jne .header
    xor ecx, ecx
.any:
    cmp ecx, CONT_SLOTS
    jae .cont_next
    cmp word [rdi + CONT.slots + rcx * 8], 0
    jne .header
    inc ecx
    jmp .any
.header:
    lea rdx, [rel t_container]
    mov rcx, rax
    call str_copy
    movsxd rdx, dword [rdi + CONT.x]
    INVOKE str_append_sdec, rax, rdx, 0
    lea rdx, [rel t_space]
    mov rcx, rax
    call str_copy
    movsxd rdx, dword [rdi + CONT.y]
    INVOKE str_append_sdec, rax, rdx, 0
    lea rdx, [rel t_space]
    mov rcx, rax
    call str_copy
    movsxd rdx, dword [rdi + CONT.z]
    INVOKE str_append_sdec, rax, rdx, 0
    lea rdx, [rel t_bracket]
    mov rcx, rax
    call str_copy
    ; a furnace: its station and fire
    movzx edx, byte [rdi + CONT.station]
    test edx, edx
    jz .slots
    lea rcx, [rel g_station_names]
    mov rsi, [rcx + rdx * 8 - 8]
    lea rdx, [rel t_station]
    mov rcx, rax
    call str_copy
    mov rdx, rsi
    mov rcx, rax
    call str_copy
    cmp dword [rdi + CONT.burn_max], 0
    je .slots
    lea rdx, [rel t_burn]
    mov rcx, rax
    call str_copy
    mov edx, [rdi + CONT.burn]
    INVOKE str_append_dec, rax, rdx, 0
    lea rdx, [rel t_comma]
    mov rcx, rax
    call str_copy
    mov edx, [rdi + CONT.burn_max]
    INVOKE str_append_dec, rax, rdx, 0
    lea rdx, [rel t_cook]
    mov rcx, rax
    call str_copy
    mov edx, [rdi + CONT.cook]
    INVOKE str_append_dec, rax, rdx, 0
.slots:
    xor esi, esi
.slot:
    cmp esi, CONT_SLOTS
    jae .cont_next
    movzx ecx, word [rdi + CONT.slots + rsi * 8]
    test ecx, ecx
    jz .slot_next
    mov rcx, rax
    lea rdx, [rdi + CONT.slots + rsi * 8]
    mov r8d, esi
    call append_slot
.slot_next:
    inc esi
    jmp .slot
.cont_next:
    add rdi, CONT_size
    inc r12d
    jmp .cont
.write:
    lea rdx, [rel t_nl]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_path]
    lea rdx, [rel g_dir]
    call str_copy
    lea rdx, [rel str_cont_dat]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_path]
    mov rdx, rbx
    call write_text
.done:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    RETURN
ENDPROC

; append_slot — "slot = i, item, count, durability" at cursor rcx
;   in:  rcx = cursor, rdx = SLOT*, r8d = index   out: rax = cursor
;   clobbers: volatile registers
PROC append_slot, 0, rbx, rsi
    mov rbx, rdx
    mov esi, r8d
    lea rdx, [rel t_slot]
    call str_copy
    INVOKE str_append_dec, rax, rsi, 0
    lea rdx, [rel t_comma]
    mov rcx, rax
    call str_copy
    movzx edx, word [rbx]
    lea rcx, [rel g_item_names]
    mov rdx, [rcx + rdx * 8]
    mov rcx, rax
    call str_copy
    lea rdx, [rel t_comma]
    mov rcx, rax
    call str_copy
    movzx edx, word [rbx + 2]
    INVOKE str_append_dec, rax, rdx, 0
    lea rdx, [rel t_comma]
    mov rcx, rax
    call str_copy
    movzx edx, word [rbx + 4]
    INVOKE str_append_dec, rax, rdx, 0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; save_all — world.dat, player.dat and every changed loaded column.
;   out: eax = 1
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC save_all, 16, rbx, rsi, rdi
    cmp dword [rel g_save_enabled], 0
    je .off
    call timer_elapsed_us
    mov [LOCAL(0)], rax
    mov rsi, [rel g_save_columns]
    mov rdi, [rel g_save_bytes]
    call write_world_dat
    call write_player_dat
    call craft_sync                     ; (an open chest's window)
    call write_containers
    mov dword [rel g_save_exists], 1
    lea rcx, [rel g_path]
    lea rdx, [rel g_dir]
    call str_copy
    lea rdx, [rel str_thumb]
    mov rcx, rax
    call str_copy
    lea rcx, [rel g_path]
    call thumb_write                    ; (nothing yet in a new world: skipped)
    xor ebx, ebx
.col:
    cmp rbx, [rel g_loaded_count]
    jae .done
    mov rax, [rel g_loaded]
    mov rcx, [rax + rbx * 8]
    cmp dword [rcx + COLUMN.modified], 0
    je .next
    call save_column
.next:
    inc rbx
    jmp .col
.done:
    call timer_elapsed_us
    mov [rel g_last_autosave], rax
    sub rax, [LOCAL(0)]
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rel g_save_last_ms], rax
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_saved]
    call log_append_str
    mov rcx, [rel g_save_columns]
    sub rcx, rsi
    call log_append_dec
    lea rcx, [rel str_s_bytes]
    call log_append_str
    mov rcx, [rel g_save_bytes]
    sub rcx, rdi
    call log_append_dec
    lea rcx, [rel str_s_ms]
    call log_append_str
    mov rcx, [rel g_save_last_ms]
    call log_append_dec
    lea rcx, [rel str_s_total]
    call log_append_str
    mov rcx, [rel g_save_columns]
    call log_append_dec
    lea rcx, [rel str_s_loaded]
    call log_append_str
    mov rcx, [rel g_save_loaded]
    call log_append_dec
    call log_end
.off:
    mov eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; save_update — autosave every autosave_minutes (0: never).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC save_update, 0
    cmp dword [rel g_save_enabled], 0
    je .done
    mov eax, [rel g_autosave_minutes]
    test eax, eax
    jz .done
    imul rax, rax, 60000000
    mov [rsp + 32], rax                 ; (spare slot)
    call timer_elapsed_us
    cmp rax, [rel g_last_autosave]
    jae .since
    mov [rel g_last_autosave], rax      ; (the clock was restarted)
.since:
    sub rax, [rel g_last_autosave]
    cmp rax, [rsp + 32]
    jb .done
    call save_all
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; rules_pair — the world's rules keys (game_mode, difficulty, hardcore), for
; world.dat and save_peek.
;   in:  rcx = name, rdx = value, r8 = mode*, r9 = difficulty*,
;        ARG5 = hardcore* (dwords)
;   out: eax = 1 if the key was one of them
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC rules_pair, 0, rbx, rsi, rdi, r12
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r12, r9
    lea rdx, [rel k_mode]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_mode
    lea rdx, [rel mode_names]
    INVOKE name_index, rsi, rdx, MODE_COUNT
    test eax, eax
    js .yes
    mov [rdi], eax
    jmp .yes
.not_mode:
    lea rdx, [rel k_difficulty]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_diff
    lea rdx, [rel diff_names]
    INVOKE name_index, rsi, rdx, DIFF_COUNT
    test eax, eax
    js .yes
    mov [r12], eax
    jmp .yes
.not_diff:
    lea rdx, [rel k_hardcore]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .no
    mov rcx, rsi
    call str_parse_u64
    xor ecx, ecx
    test rax, rax
    setnz cl
    mov rax, [ARG(5)]
    mov [rax], ecx
.yes:
    mov eax, 1
    RETURN
.no:
    xor eax, eax
    RETURN
ENDPROC

; name_index — eax = index of string rcx in the table rdx (r8d entries,
; ignoring case), -1 if absent.   clobbers: volatile registers
PROC name_index, 0, rbx, rsi, rdi, r12
    mov rbx, rcx
    mov rsi, rdx
    mov edi, r8d
    xor r12d, r12d
.next:
    cmp r12d, edi
    jae .none
    mov rdx, [rsi + r12 * 8]
    mov rcx, rbx
    call str_ieq
    test eax, eax
    jnz .found
    inc r12d
    jmp .next
.found:
    mov eax, r12d
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; append_now — the local date and time as "YYYY-MM-DD HH:MM".
;   in:  rcx = cursor
;   out: rax = new cursor (at the terminator)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC append_now, 0, rbx
    mov rbx, rcx
    lea rcx, [rel g_systime]
    API GetLocalTime, rcx
    movzx edx, word [rel g_systime]     ; year
    INVOKE str_append_dec, rbx, rdx, 0
    mov byte [rax], '-'
    lea rcx, [rax + 1]
    movzx edx, word [rel g_systime + 2] ; month
    call two_digits
    mov byte [rax], '-'
    lea rcx, [rax + 1]
    movzx edx, word [rel g_systime + 6] ; day (+4 is the weekday)
    call two_digits
    mov byte [rax], ' '
    lea rcx, [rax + 1]
    movzx edx, word [rel g_systime + 8] ; hour
    call two_digits
    mov byte [rax], ':'
    lea rcx, [rax + 1]
    movzx edx, word [rel g_systime + 10] ; minute
    call two_digits
    RETURN
ENDPROC

; two_digits — write edx (0..99) as two digits at rcx; rax = cursor after
;   them (zero-terminated).   clobbers: rax, rcx, rdx, r8
two_digits:
    mov r8, rcx
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    add dl, '0'
    mov [r8], al
    mov [r8 + 1], dl
    mov byte [r8 + 2], 0
    lea rax, [r8 + 2]
    ret

; -----------------------------------------------------------------------------
; save_peek — what the world list shows about a saved world: its rules,
; seed and last_played from world.dat. (Size and picture: menu.asm.)
;   in:  rcx = folder name in saves\, rdx = WORLD_INFO* (.name is not set)
;   out: eax = 1 if world.dat was read
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC save_peek, 16, rbx, rsi
    mov rsi, rcx
    mov rbx, rdx
    mov dword [rbx + WORLD_INFO.mode], MODE_CREATIVE
    mov dword [rbx + WORLD_INFO.difficulty], DIFF_NORMAL
    mov dword [rbx + WORLD_INFO.hardcore], 0
    mov dword [rbx + WORLD_INFO.seed], 0
    mov byte [rbx + WORLD_INFO.played], 0
    lea rcx, [rel g_peek_path]
    lea rdx, [rel str_saves_bs]
    call path_make
    mov rcx, rax
    mov rdx, rsi
    call str_copy
    mov byte [rax], '\'
    lea rcx, [rax + 1]
    lea rdx, [rel str_world_dat]
    call str_copy
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rcx, [rel g_peek_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .missing
    lea rdx, [rel peek_pair]
    lea r9, [rel str_world_lbl]
    INVOKE cfg_parse, rax, rdx, rbx, r9
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    mov eax, 1
    RETURN
.missing:
    xor eax, eax
    RETURN
ENDPROC

; save_peek's callback: rcx = name, rdx = value, r8 = WORLD_INFO*
PROC peek_pair, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    lea rax, [rdi + WORLD_INFO.hardcore]
    mov [rsp + 32], rax
    lea r8, [rdi + WORLD_INFO.mode]
    lea r9, [rdi + WORLD_INFO.difficulty]
    INVOKE rules_pair, rbx, rsi
    test eax, eax
    jnz .done
    lea rdx, [rel k_seed]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .not_seed
    mov rcx, rsi
    call str_parse_u64
    mov [rdi + WORLD_INFO.seed], eax
    jmp .done
.not_seed:
    lea rdx, [rel k_played]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .done
    xor ecx, ecx
.copy:
    mov al, [rsi + rcx]
    mov [rdi + WORLD_INFO.played + rcx], al
    test al, al
    jz .done
    inc ecx
    cmp ecx, 23
    jb .copy
    mov byte [rdi + WORLD_INFO.played + rcx], 0
.done:
    RETURN
ENDPROC
