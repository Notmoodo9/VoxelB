; =============================================================================
; menu.asm — the menu screens (milestone 17, design/ui/menus.md):
;   main      the title over the flyover; Play, Settings, Credits, Quit
;   worlds    the saved worlds (saves/*), newest first: a picture, the name,
;             mode, difficulty, last played and size on disk; Play world,
;             New world, Delete (asks first), Back
;   create    a new world: name, seed (a number, any text, or empty for a
;             random one), game mode, difficulty, hardcore (what isn't built
;             yet is shown greyed out)
;   settings  settings_screen.asm (from the main menu and the pause menu)
;   credits   data/ui/credits.txt
;   pause     Resume, Settings, Save & quit to menu, Save & quit game
; Screens slide and fade in (~150 ms). The menus only ask; game.asm acts
; (menu.inc: MA_*).
;
; Public API:
;   menu_open(ecx = SCREEN_*)
;   menu_back()                         Esc: the previous screen
;   menu_screen() -> eax SCREEN_*       the screen showing
;   menu_frame(ecx = w, edx = h) -> eax MA_*, rdx = world name, r8d = seed
;   g_new_mode, g_new_difficulty, g_new_hardcore, g_new_death (DEATH_*): the
;   rules of the world
;   MA_CREATE asks for (save.inc MODE_* / DIFF_*)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "file.inc"
%include "memory.inc"
%include "gl.inc"
%include "ui.inc"
%include "menu.inc"
%include "save.inc"
%include "cfg.inc"

global menu_open, menu_back, menu_frame, menu_screen
global g_new_mode, g_new_difficulty, g_new_hardcore, g_new_death, menu_delete_world

extern ui_frame, ui_end, ui_button, ui_panel, ui_label, ui_rect, ui_text
extern ui_image, ui_textfield, ui_focus, ui_skin, ui_checkbox
extern g_ui_vw, g_ui_vh, g_ui_alpha, g_ui_oy, g_ui_dt, g_ui_click, g_ui_mx
extern g_ui_my, g_menu_fade, g_game_state, g_mouse_wheel, g_ui_images_tex
extern str_copy, str_append_dec, str_ieq, str_len, str_parse_u64
extern timer_elapsed_us, save_peek, png_decode
extern settings_screen_open, settings_screen_frame, settings_screen_back
extern settings_screen_close

IMPORT FindFirstFileA, FindNextFileA, FindClose, DeleteFileA, RemoveDirectoryA

%define MAX_WORLDS      64              ; (8 x 8 pictures in the atlas)
%define NAME_CAP        64
%define CREATE_H        700             ; the new-world page's height
%define NAME_TYPED      33              ; the name field: 32 characters
%define SEED_TYPED      33
%define DETAILS_CAP     96
%define MAX_CREDIT_LINES 32
%define ROWS_VISIBLE    5
%define ROW_H           88
%define FIND_DATA_SIZE  320
%define FD_ATTR         0
%define FD_SIZE_HIGH    28
%define FD_SIZE_LOW     32
%define FD_NAME         44
%define ATTR_DIRECTORY  0x10
%define TRANSITION_S    0.15
%define THUMB_W         256             ; (thumb.asm)
%define THUMB_H         144
%define ATLAS_COLS      8
%define ATLAS_W         (THUMB_W * ATLAS_COLS)
%define ATLAS_H         (THUMB_H * ATLAS_COLS)
%define FIELD_NAME      30              ; widget ids
%define FIELD_SEED      31

section .rdata
s_title:        db "VoxelB", 0
s_tagline:      db "A voxel world, built in x86-64 assembly", 0
s_play:         db "Play", 0
s_settings:     db "Settings", 0
s_credits:      db "Credits", 0
s_quit:         db "Quit", 0
s_back:         db "Back", 0
s_worlds:       db "Worlds", 0
s_new_world:    db "New world", 0
s_play_world:   db "Play world", 0
s_delete:       db "Delete", 0
s_cancel:       db "Cancel", 0
s_no_worlds:    db "No worlds yet: make a new one", 0
s_confirm:      db "Delete this world?", 0
s_confirm2:     db "It will be gone for good.", 0
s_create_title: db "New world", 0
s_create:       db "Create world", 0
s_l_name:       db "Name", 0
s_l_seed:       db "Seed", 0
s_seed_hint:    db "Empty: a random seed", 0
s_l_mode:       db "Game mode", 0
s_mode_note:    db "Survival: health, hunger and dangers. Adventure and Spectator: later", 0
s_l_diff:       db "Difficulty", 0
s_hardcore_word: db "Hardcore", 0
s_diff_note:    db "One life: a death ends the world (Hard and above)", 0
s_l_death:      db "When you die", 0
death_0:        db "Drop everything", 0
death_1:        db "Gravestone", 0
death_2:        db "Keep inventory", 0
dnote_0:        db "What you carry falls where you die (5 minutes to pick it up)", 0
dnote_1:        db "A mossy gravestone keeps your things; right click it to take them back", 0
dnote_2:        db "Nothing is lost (below Hard only)", 0
s_paused:       db "Paused", 0
s_resume:       db "Resume", 0
s_to_menu:      db "Save & quit to menu", 0
s_save_quit:    db "Save & quit game", 0
s_version_file: db "data/version.cfg", 0
s_version_lbl:  db "version.cfg", 0
s_v:            db "v", 0
s_dash:         db "  -  ", 0
k_version:      db "version", 0
k_title:        db "title", 0
s_world_n:      db "World ", 0
s_saves_glob:   db "saves\*", 0
s_saves_bs:     db "saves\", 0
s_thumb:        db "\thumb.png", 0
s_star:         db "\*", 0
s_dot:          db ".", 0
s_dotdot:       db "..", 0
s_empty:        db 0
s_sep:          db "   -   ", 0
s_kb:           db " KB", 0
s_mb:           db " MB", 0
s_hardcore:     db " Hardcore", 0
s_hc_ended:     db " Hardcore, ended", 0
s_paren:        db " (", 0
s_paren_end:    db ")", 0
s_credits_file: db "data/ui/credits.txt", 0
mode_0:         db "Creative", 0
mode_1:         db "Survival", 0
mode_2:         db "Adventure", 0
mode_3:         db "Spectator", 0
diff_0:         db "Peaceful", 0
diff_1:         db "Normal", 0
diff_2:         db "Hard", 0
diff_3:         db "Extreme", 0
diff_4:         db "Ultra", 0
align 8
mode_names:     dq mode_0, mode_1, mode_2, mode_3
diff_names:     dq diff_0, diff_1, diff_2, diff_3, diff_4
death_names:    dq death_0, death_1, death_2
death_notes:    dq dnote_0, dnote_1, dnote_2
align 4
c_trans:        dd TRANSITION_S
c_one:          dd 1.0
c_offset:       dd 24.0
c_three:        dd 3.0
c_two:          dd 2.0
c_255:          dd 255.0
c_cell:         dd 0.125                ; 1 / ATLAS_COLS
c_inset:        dd 0.0005               ; (half a texel: no bleeding)

section .data
align 4
g_new_mode:       dd MODE_CREATIVE
g_new_difficulty: dd DIFF_NORMAL
g_new_hardcore:   dd 0
g_new_death:      dd DEATH_DROP

section .bss
alignb 4
g_screen:       resd 1
g_prev_screen:  resd 1
g_trans_t:      resd 1                  ; f32 0..1 since the screen opened
g_world_count:  resd 1
g_selected:     resd 1                  ; -1 none
g_scroll:       resd 1
g_confirm:      resd 1                  ; the delete question is open
g_credit_n:     resd 1
g_credits_done: resd 1
g_atlas:        resd 1                  ; the pictures' texture
g_settings_return: resd 1               ; the screen Settings goes back to
g_version_done: resd 1
g_version_text: resb 96                 ; "v0.17.0  -  Saves, menus and settings"
g_ver_num:      resb 24
g_ver_title:    resb 64
alignb 16
g_worlds:       resb MAX_WORLDS * WORLD_INFO_size
g_tmp_info:     resb WORLD_INFO_size
g_details:      resb MAX_WORLDS * DETAILS_CAP
alignb 8
g_credit_lines: resq MAX_CREDIT_LINES
g_new_name:     resb NAME_CAP
g_folder:       resb NAME_CAP + 8
g_seed_text:    resb SEED_TYPED
g_find:         resb FIND_DATA_SIZE
g_png_info:     resd 4
g_path:         resb PATH_CAP
g_walk:         resb PATH_CAP

section .text

; -----------------------------------------------------------------------------
; menu_open — show a screen (with its transition).
;   in:  ecx = SCREEN_*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC menu_open, 0
    mov eax, [rel g_screen]
    mov [rel g_prev_screen], eax
    mov [rel g_screen], ecx
    mov dword [rel g_trans_t], 0
    mov dword [rel g_confirm], 0
    cmp ecx, SCREEN_WORLDS
    jne .not_worlds
    call list_worlds
    RETURN
.not_worlds:
    cmp ecx, SCREEN_CREATE
    jne .done
    ; a fresh form: "World N", no seed, the name field typing
    call new_world_name
    mov byte [rel g_seed_text], 0
    mov dword [rel g_new_mode], MODE_CREATIVE
    mov dword [rel g_new_difficulty], DIFF_NORMAL
    mov dword [rel g_new_hardcore], 0
    mov dword [rel g_new_death], DEATH_DROP
    mov ecx, FIELD_NAME + 1
    call ui_focus
    RETURN
.done:
    xor ecx, ecx
    call ui_focus
    RETURN
ENDPROC

; menu_screen — eax = the screen showing (SCREEN_*)
menu_screen:
    mov eax, [rel g_screen]
    ret

; open_settings — the settings screen; back to the current one afterwards
PROC open_settings, 0
    mov eax, [rel g_screen]
    mov [rel g_settings_return], eax
    call settings_screen_open
    mov ecx, SCREEN_SETTINGS
    call menu_open
    RETURN
ENDPROC

; close_settings — apply and write the settings, back to where they opened
PROC close_settings, 0
    call settings_screen_close
    mov ecx, [rel g_settings_return]
    call menu_open
    RETURN
ENDPROC

; menu_back — Esc on a menu screen: close the question, or go back a screen
PROC menu_back, 0
    cmp dword [rel g_confirm], 0
    je .screen
    mov dword [rel g_confirm], 0
    RETURN
.screen:
    cmp dword [rel g_screen], SCREEN_SETTINGS
    jne .not_settings
    call settings_screen_back           ; (Esc cancels a key being rebound)
    test eax, eax
    jnz .done
    call close_settings
    RETURN
.not_settings:
    mov eax, [rel g_screen]
    cmp eax, SCREEN_MAIN
    je .done
    cmp eax, SCREEN_PAUSE
    je .done
    mov ecx, SCREEN_MAIN
    cmp eax, SCREEN_CREATE
    jne .open
    mov ecx, SCREEN_WORLDS
.open:
    call menu_open
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; list_worlds — the folders in saves\ (each a world): their details
; (save_peek), size on disk, newest first, and their pictures.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC list_worlds, 0, rbx, rsi, rdi
    mov dword [rel g_world_count], 0
    mov dword [rel g_selected], -1
    mov dword [rel g_scroll], 0
    lea rcx, [rel g_path]
    lea rdx, [rel s_saves_glob]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_find]
    API FindFirstFileA, rcx, rdx
    cmp rax, -1
    je .sort
    mov rbx, rax
.entry:
    test dword [rel g_find + FD_ATTR], ATTR_DIRECTORY
    jz .next
    lea rcx, [rel g_find + FD_NAME]
    lea rdx, [rel s_dot]
    call str_ieq
    test eax, eax
    jnz .next
    lea rcx, [rel g_find + FD_NAME]
    lea rdx, [rel s_dotdot]
    call str_ieq
    test eax, eax
    jnz .next
    mov eax, [rel g_world_count]
    cmp eax, MAX_WORLDS
    jae .next
    inc dword [rel g_world_count]
    imul eax, eax, WORLD_INFO_size
    lea rdi, [rel g_worlds]
    add rdi, rax
    ; the name (longer names are cut: such a folder is not ours)
    lea rsi, [rel g_find + FD_NAME]
    xor edx, edx
.copy:
    mov al, [rsi + rdx]
    mov [rdi + WORLD_INFO.name + rdx], al
    test al, al
    jz .copied
    inc edx
    cmp edx, NAME_CAP - 1
    jb .copy
    mov byte [rdi + WORLD_INFO.name + rdx], 0
.copied:
    mov dword [rdi + WORLD_INFO.thumb], 0
    mov rcx, rdi
    mov rdx, rdi
    call save_peek
    mov rcx, rdi
    call world_folder                   ; rax = end of g_walk
    xor edx, edx
    mov rcx, rax
    call walk
    mov [rdi + WORLD_INFO.size], rax
.next:
    lea rdx, [rel g_find]
    API FindNextFileA, rbx, rdx
    test eax, eax
    jnz .entry
    API FindClose, rbx
.sort:
    call sort_worlds
    xor ebx, ebx
.details:
    cmp ebx, [rel g_world_count]
    jae .pictures
    mov ecx, ebx
    call make_details
    inc ebx
    jmp .details
.pictures:
    call load_pictures
    RETURN
ENDPROC

; world_folder — g_walk = the world's folder (no trailing separator)
;   in:  rcx = WORLD_INFO*
;   out: rax = the terminator of g_walk
;   clobbers: volatile registers
PROC world_folder, 0, rbx
    mov rbx, rcx
    lea rcx, [rel g_walk]
    lea rdx, [rel s_saves_bs]
    call path_make
    mov rcx, rax
    lea rdx, [rbx + WORLD_INFO.name]
    call str_copy
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; walk — the bytes of every file under a folder; optionally delete them all
; (files, then each emptied subfolder; not the folder itself).
;   in:  rcx = the terminator of the folder's path in g_walk, edx = 1 delete
;   out: rax = bytes (before deleting)
;   clobbers: volatile registers (g_walk is restored)
; -----------------------------------------------------------------------------
%define K_FIND      0
%define K_TOTAL     FIND_DATA_SIZE
PROC walk, FIND_DATA_SIZE + 16, rbx, rsi, rdi, r12
    mov rsi, rcx
    mov r12d, edx
    mov qword [LOCAL(K_TOTAL)], 0
    mov rcx, rsi
    lea rdx, [rel s_star]
    call str_copy
    lea rcx, [rel g_walk]
    lea rdx, [LOCAL(K_FIND)]
    API FindFirstFileA, rcx, rdx
    cmp rax, -1
    je .done
    mov rbx, rax
.entry:
    lea rcx, [LOCAL(K_FIND + FD_NAME)]
    lea rdx, [rel s_dot]
    call str_ieq
    test eax, eax
    jnz .next
    lea rcx, [LOCAL(K_FIND + FD_NAME)]
    lea rdx, [rel s_dotdot]
    call str_ieq
    test eax, eax
    jnz .next
    ; g_walk = folder\entry
    lea rcx, [rsi + 1]
    lea rdx, [LOCAL(K_FIND + FD_NAME)]
    call str_copy
    mov rdi, rax
    test dword [LOCAL(K_FIND + FD_ATTR)], ATTR_DIRECTORY
    jz .file
    mov rcx, rdi
    mov edx, r12d
    call walk
    add [LOCAL(K_TOTAL)], rax
    test r12d, r12d
    jz .next
    lea rcx, [rel g_walk]
    API RemoveDirectoryA, rcx
    jmp .next
.file:
    mov eax, [LOCAL(K_FIND + FD_SIZE_HIGH)]
    shl rax, 32
    mov ecx, [LOCAL(K_FIND + FD_SIZE_LOW)]
    or rax, rcx
    add [LOCAL(K_TOTAL)], rax
    test r12d, r12d
    jz .next
    lea rcx, [rel g_walk]
    API DeleteFileA, rcx
.next:
    lea rdx, [LOCAL(K_FIND)]
    API FindNextFileA, rbx, rdx
    test eax, eax
    jnz .entry
    API FindClose, rbx
.done:
    mov byte [rsi], 0
    mov rax, [LOCAL(K_TOTAL)]
    RETURN
ENDPROC

; copy_info — copy a WORLD_INFO: rcx = dst, rdx = src   clobbers: xmm0
copy_info:
%assign i 0
%rep WORLD_INFO_size / 16
    movups xmm0, [rdx + i]
    movups [rcx + i], xmm0
%assign i i + 16
%endrep
    ret

; played_after — eax = 1 if [rcx] (a last_played text) sorts after [rdx]
;   clobbers: rax, rcx, rdx, r8
played_after:
.cmp:
    movzx eax, byte [rcx]
    movzx r8d, byte [rdx]
    cmp eax, r8d
    ja .yes
    jb .no
    test eax, eax
    jz .no
    inc rcx
    inc rdx
    jmp .cmp
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; sort_worlds — newest last_played first (insertion sort; a few worlds)
;   clobbers: volatile registers
PROC sort_worlds, 0, rbx, rsi, rdi
    mov ebx, 1
.outer:
    cmp ebx, [rel g_world_count]
    jae .done
    imul eax, ebx, WORLD_INFO_size
    lea rdx, [rel g_worlds]
    add rdx, rax
    lea rcx, [rel g_tmp_info]
    call copy_info
    mov esi, ebx                        ; the hole
.inner:
    test esi, esi
    jz .place
    lea eax, [esi - 1]
    imul eax, eax, WORLD_INFO_size
    lea rdi, [rel g_worlds]
    add rdi, rax                        ; the one before the hole
    lea rcx, [rel g_tmp_info + WORLD_INFO.played]
    lea rdx, [rdi + WORLD_INFO.played]
    call played_after
    test eax, eax
    jz .place
    lea rcx, [rdi + WORLD_INFO_size]
    mov rdx, rdi
    call copy_info
    dec esi
    jmp .inner
.place:
    imul eax, esi, WORLD_INFO_size
    lea rcx, [rel g_worlds]
    add rcx, rax
    lea rdx, [rel g_tmp_info]
    call copy_info
    inc ebx
    jmp .outer
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; make_details — world ecx's second line: "Creative - Normal - 2026-10-12
; 21:20 - 3.2 MB" (with " Hardcore" after the difficulty when it is on).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC make_details, 0, rbx, rsi, rdi
    mov eax, ecx
    imul eax, eax, DETAILS_CAP
    lea rdi, [rel g_details]
    add rdi, rax
    imul ecx, ecx, WORLD_INFO_size
    lea rbx, [rel g_worlds]
    add rbx, rcx
    mov eax, [rbx + WORLD_INFO.mode]
    lea rcx, [rel mode_names]
    mov rdx, [rcx + rax * 8]
    mov rcx, rdi
    call str_copy
    lea rdx, [rel s_sep]
    mov rcx, rax
    call str_copy
    mov ecx, [rbx + WORLD_INFO.difficulty]
    lea rdx, [rel diff_names]
    mov rdx, [rdx + rcx * 8]
    mov rcx, rax
    call str_copy
    cmp dword [rbx + WORLD_INFO.hardcore], 0
    je .played
    lea rdx, [rel s_hardcore]
    cmp dword [rbx + WORLD_INFO.hc_dead], 0
    je .hc_mark
    lea rdx, [rel s_hc_ended]           ; (milestone 20: only spectated now)
.hc_mark:
    mov rcx, rax
    call str_copy
.played:
    cmp byte [rbx + WORLD_INFO.played], 0
    je .size
    lea rdx, [rel s_sep]
    mov rcx, rax
    call str_copy
    lea rdx, [rbx + WORLD_INFO.played]
    mov rcx, rax
    call str_copy
.size:
    lea rdx, [rel s_sep]
    mov rcx, rax
    call str_copy
    mov rsi, rax
    mov rax, [rbx + WORLD_INFO.size]
    cmp rax, 1024 * 1024
    jae .mb
    add rax, 1023
    shr rax, 10
    INVOKE str_append_dec, rsi, rax, 0
    lea rdx, [rel s_kb]
    jmp .unit
.mb:
    imul rax, rax, 10
    shr rax, 20                         ; tenths of a MB
    INVOKE str_append_dec, rsi, rax, 1
    lea rdx, [rel s_mb]
.unit:
    mov rcx, rax
    call str_copy
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; load_pictures — each world's thumb.png into its cell of the picture atlas
; (made the first time).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define L_MARK      0
PROC load_pictures, 16, rbx, rsi, rdi
    cmp dword [rel g_atlas], 0
    jne .have
    lea r8, [rel g_atlas]
    GL glCreateTextures, GL_TEXTURE_2D, 1, r8
    GL glTextureStorage2D, [rel g_atlas], 1, GL_RGBA8, ATLAS_W, ATLAS_H
    GL glTextureParameteri, [rel g_atlas], GL_TEXTURE_MIN_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_atlas], GL_TEXTURE_MAG_FILTER, GL_LINEAR
    GL glTextureParameteri, [rel g_atlas], GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE
    GL glTextureParameteri, [rel g_atlas], GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE
    mov eax, [rel g_atlas]
    mov [rel g_ui_images_tex], eax
.have:
    xor ebx, ebx
.world:
    cmp ebx, [rel g_world_count]
    jae .done
    imul eax, ebx, WORLD_INFO_size
    lea rsi, [rel g_worlds]
    add rsi, rax
    mov rcx, rsi
    call world_folder
    mov rcx, rax
    lea rdx, [rel s_thumb]
    call str_copy
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(L_MARK)], rax
    lea rcx, [rel g_walk]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .reset
    lea r8, [rel g_png_info]
    lea r9, [rel g_arena_scratch]
    mov rcx, rax
    call png_decode
    test rax, rax
    jz .reset
    cmp dword [rel g_png_info], THUMB_W
    jne .reset
    cmp dword [rel g_png_info + 4], THUMB_H
    jne .reset
    mov [rsp + 64], rax                 ; pixels
    mov qword [rsp + 56], GL_UNSIGNED_BYTE
    mov qword [rsp + 48], GL_RGBA
    mov qword [rsp + 40], THUMB_H
    mov qword [rsp + 32], THUMB_W
    mov eax, ebx
    and eax, ATLAS_COLS - 1
    imul r8d, eax, THUMB_W
    mov eax, ebx
    shr eax, 3
    imul r9d, eax, THUMB_H
    mov ecx, [rel g_atlas]
    xor edx, edx
    call [rel glTextureSubImage2D]
    lea eax, [ebx + 1]
    mov [rsi + WORLD_INFO.thumb], eax
.reset:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(L_MARK)]
    inc ebx
    jmp .world
.done:
    RETURN
ENDPROC

; world_name — rax = name of world ecx
world_name:
    imul eax, ecx, WORLD_INFO_size
    lea rcx, [rel g_worlds]
    add rax, rcx
    ret

; name_taken — eax = 1 if a world folder is called [rcx] (ignoring case)
PROC name_taken, 0, rbx, rsi
    mov rbx, rcx
    xor esi, esi
.cmp:
    cmp esi, [rel g_world_count]
    jae .free
    mov ecx, esi
    call world_name
    mov rcx, rbx
    mov rdx, rax
    call str_ieq
    test eax, eax
    jnz .taken
    inc esi
    jmp .cmp
.taken:
    mov eax, 1
    RETURN
.free:
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; new_world_name — g_new_name = "World N" with the first N not taken.
;   out: rax = g_new_name
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC new_world_name, 0, rbx
    mov ebx, 1
.try:
    lea rcx, [rel g_new_name]
    lea rdx, [rel s_world_n]
    call str_copy
    INVOKE str_append_dec, rax, rbx, 0
    lea rcx, [rel g_new_name]
    call name_taken
    test eax, eax
    jz .free
    inc ebx
    jmp .try
.free:
    lea rax, [rel g_new_name]
    RETURN
ENDPROC

; random_seed — eax = a seed from the clock (positive, 31 bits)
PROC random_seed, 0, rbx
    rdtsc
    mov ebx, eax
    call timer_elapsed_us
    xor eax, ebx
    imul eax, eax, 0x9E3779B1
    shr eax, 1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; seed_from_text — the seed field: empty = random; a whole number (optional
; '-') = that number; any other text = its FNV-1a hash (so "mountains" is
; always the same world).
;   in:  rcx = text
;   out: eax = seed
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC seed_from_text, 0, rbx, rsi
    mov rbx, rcx
.skip:
    cmp byte [rbx], ' '
    jne .skipped
    inc rbx
    jmp .skip
.skipped:
    cmp byte [rbx], 0
    jne .given
    call random_seed
    RETURN
.given:
    ; a number?
    mov rcx, rbx
    xor esi, esi                        ; negative
    cmp byte [rcx], '-'
    jne .digits
    inc rcx
    mov esi, 1
.digits:
    call str_parse_u64                  ; rdx = after, r8 = digits
    test r8, r8
    jz .hash
.trail:
    cmp byte [rdx], ' '
    jne .end
    inc rdx
    jmp .trail
.end:
    cmp byte [rdx], 0
    jne .hash
    test esi, esi
    jz .number
    neg eax
.number:
    RETURN
.hash:
    mov eax, 0x811C9DC5
.byte:
    movzx ecx, byte [rbx]
    test ecx, ecx
    jz .hashed
    xor eax, ecx
    imul eax, eax, 0x01000193
    inc rbx
    jmp .byte
.hashed:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; sanitize_name — a typed world name as a safe folder name: printable ASCII
; without < > : " / \ | ? *, no spaces or dots at the ends, not a reserved
; device name (CON, PRN, AUX, NUL, COM1.., LPT1..).
;   in:  rcx = typed name, rdx = destination (NAME_CAP)
;   out: eax = length
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC sanitize_name, 0, rbx, rsi, rdi
    mov rsi, rcx
    mov rdi, rdx
    xor ebx, ebx                        ; length
.lead:
    cmp byte [rsi], ' '
    jne .copy
    inc rsi
    jmp .lead
.copy:
    movzx eax, byte [rsi]
    test eax, eax
    jz .trim
    inc rsi
    cmp eax, ' '
    jb .copy
    cmp eax, 126
    ja .copy
    cmp eax, '<'
    je .copy
    cmp eax, '>'
    je .copy
    cmp eax, ':'
    je .copy
    cmp eax, '"'
    je .copy
    cmp eax, '/'
    je .copy
    cmp eax, '\'
    je .copy
    cmp eax, '|'
    je .copy
    cmp eax, '?'
    je .copy
    cmp eax, '*'
    je .copy
    cmp ebx, NAME_TYPED - 1
    jae .trim
    mov [rdi + rbx], al
    inc ebx
    jmp .copy
.trim:
    test ebx, ebx
    jz .end
    movzx eax, byte [rdi + rbx - 1]
    cmp eax, ' '
    je .cut
    cmp eax, '.'
    jne .end
.cut:
    dec ebx
    jmp .trim
.end:
    mov byte [rdi + rbx], 0
    ; reserved device names get a '_'
    cmp ebx, 3
    je .three
    cmp ebx, 4
    jne .done
    movzx eax, byte [rdi + 3]
    cmp eax, '1'
    jb .done
    cmp eax, '9'
    ja .done
    mov eax, [rdi]
    and eax, 0x00DFDFDF                 ; (upper case)
    cmp eax, 'COM'
    je .reserved
    cmp eax, 'LPT'
    je .reserved
    jmp .done
.three:
    mov eax, [rdi]
    and eax, 0x00DFDFDF
    cmp eax, 'CON'
    je .reserved
    cmp eax, 'PRN'
    je .reserved
    cmp eax, 'AUX'
    je .reserved
    cmp eax, 'NUL'
    jne .done
.reserved:
    mov byte [rdi + rbx], '_'
    inc ebx
    mov byte [rdi + rbx], 0
.done:
    mov eax, ebx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; new_rules_fit — the form's rules agree with the difficulty: Hardcore only
; on Hard and above, keep inventory only below Hard (a gravestone instead)
;   clobbers: rax
new_rules_fit:
    cmp dword [rel g_new_difficulty], DIFF_HARD
    jae .hard
    mov dword [rel g_new_hardcore], 0
    ret
.hard:
    cmp dword [rel g_new_death], DEATH_KEEP
    jne .done
    mov dword [rel g_new_death], DEATH_GRAVE
.done:
    ret

; create_world — the creation form's answer: the folder name (sanitised,
; "World N" if nothing is left, " (2)", " (3)".. if taken), the seed and the
; rules (only what is built so far: creative, normal, no hardcore).
;   out: rax = folder name, edx = seed
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC create_world, 0, rbx, rsi
    lea rcx, [rel g_new_name]
    lea rdx, [rel g_folder]
    call sanitize_name
    test eax, eax
    jnz .named
    call new_world_name
    lea rcx, [rel g_new_name]
    lea rdx, [rel g_folder]
    call sanitize_name
.named:
    mov esi, eax                        ; base length
    mov ebx, 2
.unique:
    lea rcx, [rel g_folder]
    call name_taken
    test eax, eax
    jz .seed
    lea rcx, [rel g_folder]
    add rcx, rsi
    lea rdx, [rel s_paren]
    call str_copy
    INVOKE str_append_dec, rax, rbx, 0
    lea rdx, [rel s_paren_end]
    mov rcx, rax
    call str_copy
    inc ebx
    jmp .unique
.seed:
    ; (the rules chosen on the form)
    call new_rules_fit
    lea rcx, [rel g_seed_text]
    call seed_from_text
    mov edx, eax
    lea rax, [rel g_folder]
    RETURN
ENDPROC

; delete_selected — remove the selected world's folder, list again
PROC delete_selected, 0, rbx
    mov ecx, [rel g_selected]
    test ecx, ecx
    js .done
    call world_name
    mov rbx, rax
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel s_log_delete]
    call log_append_str
    mov rcx, rbx
    call log_append_str
    call log_end
    mov rcx, rbx
    call world_folder
    mov rcx, rax
    mov edx, 1
    call walk
    lea rcx, [rel g_walk]
    API RemoveDirectoryA, rcx
    call list_worlds
.done:
    RETURN
ENDPROC

section .rdata
s_log_delete:   db "menu: deleted world ", 0
section .text

; -----------------------------------------------------------------------------
; menu_delete_world — remove a world's folder (game.asm: a Hardcore world
; deleted from its death page, after leaving it).
;   in:  rcx = the world's folder name in saves;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC menu_delete_world, 0, rbx
    mov rbx, rcx
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel s_log_delete]
    call log_append_str
    mov rcx, rbx
    call log_append_str
    call log_end
    mov rcx, rbx                        ; (WORLD_INFO.name is at offset 0)
    call world_folder
    mov rcx, rax
    mov edx, 1
    call walk
    lea rcx, [rel g_walk]
    API RemoveDirectoryA, rcx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; load_version — data/version.cfg into "v<version>  -  <title>" (once), for
; the main menu's footer.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC load_version, 16, rbx
    cmp dword [rel g_version_done], 0
    jne .done
    mov dword [rel g_version_done], 1
    lea rcx, [rel g_arena_scratch]
    call arena_mark
    mov [LOCAL(0)], rax
    lea rcx, [rel g_path]
    lea rdx, [rel s_version_file]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_scratch]
    call file_load
    test rax, rax
    jz .reset
    lea rdx, [rel version_pair]
    lea r9, [rel s_version_lbl]
    INVOKE cfg_parse, rax, rdx, 0, r9
.reset:
    lea rcx, [rel g_arena_scratch]
    INVOKE arena_reset_to, rcx, [LOCAL(0)]
    cmp byte [rel g_ver_num], 0
    je .done
    lea rcx, [rel g_version_text]
    lea rdx, [rel s_v]
    call str_copy
    mov rcx, rax
    lea rdx, [rel g_ver_num]
    call str_copy
    cmp byte [rel g_ver_title], 0
    je .done
    mov rcx, rax
    lea rdx, [rel s_dash]
    call str_copy
    mov rcx, rax
    lea rdx, [rel g_ver_title]
    call str_copy
.done:
    RETURN
ENDPROC

; version.cfg callback: rcx = name, rdx = value
PROC version_pair, 0, rbx, rsi, rdi
    mov rbx, rcx
    mov rsi, rdx
    lea rdx, [rel k_version]
    INVOKE str_ieq, rbx, rdx
    lea rdi, [rel g_ver_num]
    mov ecx, 23
    test eax, eax
    jnz .copy
    lea rdx, [rel k_title]
    INVOKE str_ieq, rbx, rdx
    lea rdi, [rel g_ver_title]
    mov ecx, 63
    test eax, eax
    jz .done
.copy:
    mov al, [rsi]
    test al, al
    jz .end
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .copy
.end:
    mov byte [rdi], 0
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; load_credits — data/ui/credits.txt into lines (once).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC load_credits, 0, rbx
    cmp dword [rel g_credits_done], 0
    jne .done
    mov dword [rel g_credits_done], 1
    lea rcx, [rel g_path]
    lea rdx, [rel s_credits_file]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_perm]
    call file_load
    test rax, rax
    jz .done
    mov rbx, rax
.line:
    cmp byte [rbx], 0
    je .done
    mov eax, [rel g_credit_n]
    cmp eax, MAX_CREDIT_LINES
    jae .done
    inc dword [rel g_credit_n]
    lea rcx, [rel g_credit_lines]
    mov [rcx + rax * 8], rbx
.scan:
    mov al, [rbx]
    test al, al
    jz .done
    inc rbx
    cmp al, 13
    je .cr
    cmp al, 10
    jne .scan
    mov byte [rbx - 1], 0
    jmp .line
.cr:
    mov byte [rbx - 1], 0
    cmp byte [rbx], 10
    jne .line
    inc rbx
    jmp .line
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; menu_frame — draw the current screen and handle its buttons.
;   in:  ecx = width, edx = height
;   out: eax = MA_*, rdx = world name (MA_PLAY / MA_CREATE), r8d = seed
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define M_ACTION    0
%define M_ARG       8
%define M_SEED      16
%define M_W         20
%define M_H         24
%define M_CX        28                  ; canvas centre x (units)
%define M_SAVE_MX   32                  ; (the delete question: the real mouse)
%define M_SAVE_CLICK 36
PROC menu_frame, 48, rbx, rsi, rdi, r12, r13, r14, r15
    mov [LOCAL(M_W)], ecx
    mov [LOCAL(M_H)], edx
    mov dword [LOCAL(M_ACTION)], MA_NONE
    mov qword [LOCAL(M_ARG)], 0
    mov dword [LOCAL(M_SEED)], 0
    call ui_frame
    mov eax, [rel g_ui_vw]
    shr eax, 1
    mov [LOCAL(M_CX)], eax

    ; the flyover fades in from black at each turn of its path
    cmp dword [rel g_game_state], 0     ; (GS_MENU)
    jne .pause_dim
    movss xmm0, [rel g_menu_fade]
    mulss xmm0, [rel c_255]
    cvttss2si eax, xmm0
    shl eax, 24
    test eax, eax
    jz .trans
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    INVOKE ui_rect, -8, -8, [rel g_ui_vw], [rel g_ui_vh]
    jmp .trans
.pause_dim:
    ; paused: the world darkens a little behind the glass
    mov qword [rsp + 32], 0x50000000
    mov qword [rsp + 40], 0x70000000
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov r8d, [rel g_ui_vw]
    add r8d, 16
    mov r9d, [rel g_ui_vh]
    add r9d, 16
    INVOKE ui_rect, -8, -8, r8, r9

.trans:
    ; transition: fade + slide up, smoothstepped
    movss xmm0, [rel g_ui_dt]
    divss xmm0, [rel c_trans]
    addss xmm0, [rel g_trans_t]
    minss xmm0, [rel c_one]
    movss [rel g_trans_t], xmm0
    movss xmm1, xmm0
    mulss xmm1, xmm0                    ; t^2
    movss xmm2, [rel c_three]
    movss xmm3, xmm0
    mulss xmm3, [rel c_two]
    subss xmm2, xmm3                    ; 3 - 2t
    mulss xmm1, xmm2                    ; smoothstep
    movss [rel g_ui_alpha], xmm1
    movss xmm0, [rel c_one]
    subss xmm0, xmm1
    mulss xmm0, [rel c_offset]
    cvttss2si eax, xmm0
    mov [rel g_ui_oy], eax

    mov eax, [rel g_screen]
    cmp eax, SCREEN_MAIN
    je .main
    cmp eax, SCREEN_WORLDS
    je .worlds
    cmp eax, SCREEN_CREDITS
    je .credits
    cmp eax, SCREEN_CREATE
    je .create
    cmp eax, SCREEN_SETTINGS
    je .settings
    jmp .pause

    ; ---- main ---------------------------------------------------------------------------
.main:
    ; title: big, white into teal, with a shadow
    mov eax, [rel g_ui_vh]
    imul eax, eax, 15
    xor edx, edx
    mov ecx, 100
    div ecx
    mov ebx, eax                        ; title top
    mov dword [rsp + 32], COL_TEXT
    mov dword [rsp + 40], COL_ACCENT
    mov qword [rsp + 48], UI_CENTER | UI_SHADOW | UI_BOLD
    lea rcx, [rel s_title]
    INVOKE ui_text, rcx, [LOCAL(M_CX)], rbx, 120
    lea r8d, [ebx + 150]
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel s_tagline]
    INVOKE ui_label, rcx, [LOCAL(M_CX)], r8, 22
    ; the buttons on a glass panel
    lea esi, [ebx + 220]                ; panel top
    mov edi, [LOCAL(M_CX)]
    sub edi, 190                        ; panel left
    INVOKE ui_panel, rdi, rsi, 380, 4 * 56 + 3 * 12 + 48
    add edi, 30
    add esi, 24
    mov qword [rsp + 32], 56
    lea rax, [rel s_play]
    mov [rsp + 40], rax
    mov qword [rsp + 48], UIW_PRIMARY
    INVOKE ui_button, 0, rdi, rsi, 320
    test eax, eax
    jz .m_settings
    mov ecx, SCREEN_WORLDS
    call menu_open
.m_settings:
    add esi, 68
    mov qword [rsp + 32], 56
    lea rax, [rel s_settings]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    INVOKE ui_button, 1, rdi, rsi, 320
    test eax, eax
    jz .m_credits
    call open_settings
.m_credits:
    add esi, 68
    mov qword [rsp + 32], 56
    lea rax, [rel s_credits]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    INVOKE ui_button, 2, rdi, rsi, 320
    test eax, eax
    jz .m_quit
    call load_credits
    mov ecx, SCREEN_CREDITS
    call menu_open
.m_quit:
    add esi, 68
    mov qword [rsp + 32], 56
    lea rax, [rel s_quit]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    INVOKE ui_button, 3, rdi, rsi, 320
    test eax, eax
    jz .m_footer
    mov dword [LOCAL(M_ACTION)], MA_QUIT
.m_footer:
    mov r8d, [rel g_ui_vh]
    sub r8d, 36
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], 0
    call load_version
    lea rcx, [rel g_version_text]
    INVOKE ui_label, rcx, 20, r8, 16
    jmp .end

    ; ---- worlds ----------------------------------------------------------------------
.worlds:
    ; with the delete question open, the screen behind it takes no mouse
    mov dword [LOCAL(M_SAVE_MX)], -100000
    cmp dword [rel g_confirm], 0
    je .w_live
    mov eax, [rel g_ui_mx]
    mov [LOCAL(M_SAVE_MX)], eax
    mov eax, [rel g_ui_click]
    mov [LOCAL(M_SAVE_CLICK)], eax
    mov dword [rel g_ui_mx], -100000
    mov dword [rel g_ui_click], 0
.w_live:
    mov edi, [LOCAL(M_CX)]
    sub edi, 380                        ; panel left
    mov esi, [rel g_ui_vh]
    sub esi, 620
    sar esi, 1                          ; panel top (620 tall)
    INVOKE ui_panel, rdi, rsi, 760, 620
    lea r8d, [esi + 22]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], UI_CENTER | UI_BOLD
    lea rcx, [rel s_worlds]
    INVOKE ui_label, rcx, [LOCAL(M_CX)], r8, 34
    ; the list (scrolls with the wheel)
    mov eax, [rel g_mouse_wheel]
    test eax, eax
    jz .w_scrolled
    mov ecx, [rel g_scroll]
    cmp eax, 0
    jg .w_up
    inc ecx
    jmp .w_clamp
.w_up:
    dec ecx
.w_clamp:
    mov eax, [rel g_world_count]
    sub eax, ROWS_VISIBLE
    cmp ecx, eax
    jle .w_c1
    mov ecx, eax
.w_c1:
    test ecx, ecx
    jns .w_c2
    xor ecx, ecx
.w_c2:
    mov [rel g_scroll], ecx
.w_scrolled:
    cmp dword [rel g_world_count], 0
    jne .w_rows
    lea r8d, [esi + 240]
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel s_no_worlds]
    INVOKE ui_label, rcx, [LOCAL(M_CX)], r8, 22
    jmp .w_buttons
.w_rows:
    xor ebx, ebx                        ; visible row
.w_row:
    cmp ebx, ROWS_VISIBLE
    jae .w_buttons
    mov r12d, ebx
    add r12d, [rel g_scroll]            ; world index
    cmp r12d, [rel g_world_count]
    jae .w_buttons
    imul r13d, ebx, ROW_H
    add r13d, esi
    add r13d, 82                        ; row top
    ; the row is a button: a click selects, a click on the selected plays
    lea rax, [rel s_empty]
    mov [rsp + 40], rax
    mov qword [rsp + 32], ROW_H - 6
    xor eax, eax
    cmp r12d, [rel g_selected]
    jne .w_flags
    mov eax, UIW_SELECTED
.w_flags:
    mov [rsp + 48], rax
    lea edx, [edi + 30]
    lea ecx, [ebx + 10]
    INVOKE ui_button, rcx, rdx, r13, 700
    test eax, eax
    jz .w_draw
    cmp r12d, [rel g_selected]
    jne .w_select
    mov ecx, r12d
    call world_name
    mov [LOCAL(M_ARG)], rax
    mov dword [LOCAL(M_ACTION)], MA_PLAY
    jmp .w_draw
.w_select:
    mov [rel g_selected], r12d
.w_draw:
    mov ecx, r12d
    call world_name
    mov r14, rax                        ; WORLD_INFO*
    ; the picture (or a dark frame)
    lea r15d, [r13d + 7]
    mov eax, [r14 + WORLD_INFO.thumb]
    test eax, eax
    jz .w_no_pic
    dec eax
    mov ecx, eax
    and ecx, ATLAS_COLS - 1
    shr eax, 3
    cvtsi2ss xmm0, ecx
    mulss xmm0, [rel c_cell]
    cvtsi2ss xmm1, eax
    mulss xmm1, [rel c_cell]
    movss xmm2, xmm0
    addss xmm2, [rel c_cell]
    movss xmm3, xmm1
    addss xmm3, [rel c_cell]
    addss xmm0, [rel c_inset]
    addss xmm1, [rel c_inset]
    subss xmm2, [rel c_inset]
    subss xmm3, [rel c_inset]
    movss [rsp + 32], xmm0
    movss [rsp + 40], xmm1
    movss [rsp + 48], xmm2
    movss [rsp + 56], xmm3
    mov dword [rsp + 64], 0xFFFFFFFF
    lea ecx, [edi + 40]
    INVOKE ui_image, rcx, r15, 128, 72
    jmp .w_text
.w_no_pic:
    mov dword [rsp + 32], 0x60000000
    mov dword [rsp + 40], 0x30FFFFFF
    mov qword [rsp + 48], 6
    mov qword [rsp + 56], 1
    lea ecx, [edi + 40]
    INVOKE ui_rect, rcx, r15, 128, 72
.w_text:
    lea r8d, [r13d + 14]
    lea edx, [edi + 190]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], UI_BOLD
    lea rcx, [r14 + WORLD_INFO.name]
    INVOKE ui_label, rcx, rdx, r8, 25
    imul eax, r12d, DETAILS_CAP
    lea rcx, [rel g_details]
    add rcx, rax
    lea r8d, [r13d + 50]
    lea edx, [edi + 190]
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], 0
    INVOKE ui_label, rcx, rdx, r8, 17
    inc ebx
    jmp .w_row
.w_buttons:
    ; Play world / New world / Delete / Back along the bottom
    lea r12d, [esi + 620 - 24 - 52]
    mov r10d, UIW_PRIMARY
    cmp dword [rel g_selected], 0
    jge .w_play_ok
    mov r10d, UIW_DISABLED
.w_play_ok:
    mov [rsp + 48], r10
    mov qword [rsp + 32], 52
    lea rax, [rel s_play_world]
    mov [rsp + 40], rax
    lea edx, [edi + 40]
    INVOKE ui_button, 4, rdx, r12, 160
    test eax, eax
    jz .w_new
    mov ecx, [rel g_selected]
    call world_name
    mov [LOCAL(M_ARG)], rax
    mov dword [LOCAL(M_ACTION)], MA_PLAY
.w_new:
    mov qword [rsp + 32], 52
    lea rax, [rel s_new_world]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    lea edx, [edi + 40 + 173]
    INVOKE ui_button, 5, rdx, r12, 160
    test eax, eax
    jz .w_delete
    mov ecx, SCREEN_CREATE
    call menu_open
    jmp .end
.w_delete:
    mov r10d, 0
    cmp dword [rel g_selected], 0
    jge .w_del_ok
    mov r10d, UIW_DISABLED
.w_del_ok:
    mov [rsp + 48], r10
    mov qword [rsp + 32], 52
    lea rax, [rel s_delete]
    mov [rsp + 40], rax
    lea edx, [edi + 40 + 2 * 173]
    INVOKE ui_button, 8, rdx, r12, 160
    test eax, eax
    jz .w_back
    mov dword [rel g_confirm], 1
.w_back:
    mov qword [rsp + 32], 52
    lea rax, [rel s_back]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    lea edx, [edi + 40 + 3 * 173]
    INVOKE ui_button, 6, rdx, r12, 160
    test eax, eax
    jz .w_confirm
    mov ecx, SCREEN_MAIN
    call menu_open
    jmp .end
.w_confirm:
    ; ---- the delete question, over the dimmed list ----
    cmp dword [rel g_confirm], 0
    je .end
    cmp dword [LOCAL(M_SAVE_MX)], -100000
    je .end                             ; (opened this frame: from next frame)
    mov eax, [LOCAL(M_SAVE_MX)]
    mov [rel g_ui_mx], eax
    mov eax, [LOCAL(M_SAVE_CLICK)]
    mov [rel g_ui_click], eax
    mov dword [rsp + 32], 0x80000000
    mov dword [rsp + 40], 0x80000000
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov r8d, [rel g_ui_vw]
    add r8d, 16
    mov r9d, [rel g_ui_vh]
    add r9d, 16
    INVOKE ui_rect, -8, -8, r8, r9
    mov edi, [LOCAL(M_CX)]
    sub edi, 260
    mov esi, [rel g_ui_vh]
    sub esi, 250
    sar esi, 1
    INVOKE ui_panel, rdi, rsi, 520, 250
    lea r8d, [esi + 26]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], UI_CENTER | UI_BOLD
    lea rcx, [rel s_confirm]
    INVOKE ui_label, rcx, [LOCAL(M_CX)], r8, 30
    mov ecx, [rel g_selected]
    call world_name
    mov rcx, rax
    lea r8d, [esi + 78]
    mov dword [rsp + 32], COL_ACCENT
    mov qword [rsp + 40], UI_CENTER
    INVOKE ui_label, rcx, [LOCAL(M_CX)], r8, 24
    lea r8d, [esi + 114]
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel s_confirm2]
    INVOKE ui_label, rcx, [LOCAL(M_CX)], r8, 19
    lea r12d, [esi + 250 - 24 - 52]
    mov qword [rsp + 32], 52
    lea rax, [rel s_delete]
    mov [rsp + 40], rax
    mov qword [rsp + 48], UIW_DANGER
    lea edx, [edi + 30]
    INVOKE ui_button, 40, rdx, r12, 220
    test eax, eax
    jz .w_cancel
    mov dword [rel g_confirm], 0
    call delete_selected
    jmp .end
.w_cancel:
    mov qword [rsp + 32], 52
    lea rax, [rel s_cancel]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    lea edx, [edi + 270]
    INVOKE ui_button, 41, rdx, r12, 220
    test eax, eax
    jz .end
    mov dword [rel g_confirm], 0
    jmp .end

    ; ---- settings --------------------------------------------------------------------
.settings:
    mov ecx, [LOCAL(M_CX)]
    call settings_screen_frame
    test eax, eax
    jz .end
    call close_settings
    jmp .end

    ; ---- create ----------------------------------------------------------------------
.create:
    mov edi, [LOCAL(M_CX)]
    sub edi, 360                        ; panel left (720 wide)
    mov esi, [rel g_ui_vh]
    sub esi, CREATE_H
    sar esi, 1                          ; panel top
    INVOKE ui_panel, rdi, rsi, 720, CREATE_H
    lea r8d, [esi + 22]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], UI_CENTER | UI_BOLD
    lea rcx, [rel s_create_title]
    INVOKE ui_label, rcx, [LOCAL(M_CX)], r8, 34
    lea r12d, [edi + 40]                ; content left
    xor r15d, r15d                      ; Enter pressed in a field
%macro CAPTION 2                        ; text, y offset
    lea r8d, [esi + %2]
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], 0
    lea rcx, [rel %1]
    INVOKE ui_label, rcx, r12, r8, 18
%endmacro
    ; name
    CAPTION s_l_name, 84
    mov qword [rsp + 32], 50
    lea rax, [rel g_new_name]
    mov [rsp + 40], rax
    mov qword [rsp + 48], NAME_TYPED
    mov qword [rsp + 56], 0
    lea r8d, [esi + 110]
    INVOKE ui_textfield, FIELD_NAME, r12, r8, 640
    cmp eax, 2
    jne .c_seed
    mov r15d, 1
.c_seed:
    CAPTION s_l_seed, 174
    mov qword [rsp + 32], 50
    lea rax, [rel g_seed_text]
    mov [rsp + 40], rax
    mov qword [rsp + 48], SEED_TYPED
    lea rax, [rel s_seed_hint]
    mov [rsp + 56], rax
    lea r8d, [esi + 200]
    INVOKE ui_textfield, FIELD_SEED, r12, r8, 640
    cmp eax, 2
    jne .c_mode
    mov r15d, 1
.c_mode:
    ; game mode: Creative; the others are coming later
    CAPTION s_l_mode, 266
    xor ebx, ebx
.c_mode_b:
    cmp ebx, MODE_COUNT
    jae .c_mode_note
    lea rax, [rel mode_names]
    mov rax, [rax + rbx * 8]
    mov [rsp + 40], rax
    mov qword [rsp + 32], 46
    xor r10d, r10d
    cmp ebx, MODE_SURVIVAL
    jbe .c_mode_on
    mov r10d, UIW_DISABLED              ; (not built yet)
.c_mode_on:
    cmp ebx, [rel g_new_mode]
    jne .c_mode_f
    or r10d, UIW_SELECTED
.c_mode_f:
    mov [rsp + 48], r10
    imul edx, ebx, 162
    add edx, r12d
    lea r8d, [esi + 292]
    lea ecx, [ebx + 32]
    INVOKE ui_button, rcx, rdx, r8, 152
    test eax, eax
    jz .c_mode_next
    mov [rel g_new_mode], ebx
.c_mode_next:
    inc ebx
    jmp .c_mode_b
.c_mode_note:
    lea r8d, [esi + 344]
    mov dword [rsp + 32], COL_TEXT_OFF
    mov qword [rsp + 40], 0
    lea rcx, [rel s_mode_note]
    INVOKE ui_label, rcx, r12, r8, 15
    ; difficulty (milestone 20: Survival scales by it)
    CAPTION s_l_diff, 374
    xor ebx, ebx
.c_diff_b:
    cmp ebx, DIFF_COUNT
    jae .c_hardcore
    lea rax, [rel diff_names]
    mov rax, [rax + rbx * 8]
    mov [rsp + 40], rax
    mov qword [rsp + 32], 44
    xor r10d, r10d
    cmp ebx, [rel g_new_difficulty]
    jne .c_diff_f
    mov r10d, UIW_SELECTED
.c_diff_f:
    mov [rsp + 48], r10
    imul edx, ebx, 130
    add edx, r12d
    lea r8d, [esi + 400]
    lea ecx, [ebx + 48]
    INVOKE ui_button, rcx, rdx, r8, 120
    test eax, eax
    jz .c_diff_next
    mov [rel g_new_difficulty], ebx
    call new_rules_fit
.c_diff_next:
    inc ebx
    jmp .c_diff_b
.c_hardcore:
    ; Hardcore: one life (Hard and above; faded below)
    cmp dword [rel g_new_difficulty], DIFF_HARD
    jb .c_hc_off
    lea r8d, [esi + 462]
    mov ecx, r12d
    mov edx, r8d
    mov r8d, 28
    mov r9d, [rel g_new_hardcore]
    call ui_checkbox
    test eax, eax
    jz .c_hc_label
    xor dword [rel g_new_hardcore], 1
.c_hc_label:
    mov eax, COL_TEXT
    jmp .c_hc_text
.c_hc_off:
    mov dword [rsp + 40], 0x60FFFFFF
    mov qword [rsp + 32], SKIN_CHECK_OFF
    lea r8d, [esi + 462]
    INVOKE ui_skin, r12, r8, 28, 28
    mov eax, COL_TEXT_OFF
.c_hc_text:
    lea edx, [r12d + 38]
    lea r8d, [esi + 464]
    mov [rsp + 32], eax
    mov qword [rsp + 40], 0
    lea rcx, [rel s_hardcore_word]
    INVOKE ui_label, rcx, rdx, r8, 20
    lea r8d, [esi + 467]
    lea edx, [r12d + 180]
    mov dword [rsp + 32], COL_TEXT_OFF
    mov qword [rsp + 40], 0
    lea rcx, [rel s_diff_note]
    INVOKE ui_label, rcx, rdx, r8, 15
    ; when you die: drop everything / a gravestone / keep inventory (below Hard)
    CAPTION s_l_death, 512
    xor ebx, ebx
.c_death_b:
    cmp ebx, DEATH_COUNT
    jae .c_death_note
    lea rax, [rel death_names]
    mov rax, [rax + rbx * 8]
    mov [rsp + 40], rax
    mov qword [rsp + 32], 44
    xor r10d, r10d
    cmp ebx, DEATH_KEEP
    jne .c_death_on
    cmp dword [rel g_new_difficulty], DIFF_HARD
    jb .c_death_on
    mov r10d, UIW_DISABLED
.c_death_on:
    cmp ebx, [rel g_new_death]
    jne .c_death_f
    or r10d, UIW_SELECTED
.c_death_f:
    mov [rsp + 48], r10
    imul edx, ebx, 216
    add edx, r12d
    lea r8d, [esi + 538]
    lea ecx, [ebx + 56]
    INVOKE ui_button, rcx, rdx, r8, 208
    test eax, eax
    jz .c_death_next
    mov [rel g_new_death], ebx
.c_death_next:
    inc ebx
    jmp .c_death_b
.c_death_note:
    mov eax, [rel g_new_death]
    lea rcx, [rel death_notes]
    mov rcx, [rcx + rax * 8]
    lea r8d, [esi + 590]
    mov dword [rsp + 32], COL_TEXT_OFF
    mov qword [rsp + 40], 0
    INVOKE ui_label, rcx, r12, r8, 15
    ; Create world / Cancel
    lea r13d, [esi + CREATE_H - 24 - 52]
    mov qword [rsp + 32], 52
    lea rax, [rel s_create]
    mov [rsp + 40], rax
    mov qword [rsp + 48], UIW_PRIMARY
    INVOKE ui_button, 54, r12, r13, 310
    or eax, r15d
    jz .c_cancel
    call create_world
    mov [LOCAL(M_ARG)], rax
    mov [LOCAL(M_SEED)], edx
    mov dword [LOCAL(M_ACTION)], MA_CREATE
    xor ecx, ecx
    call ui_focus
    jmp .end
.c_cancel:
    mov qword [rsp + 32], 52
    lea rax, [rel s_cancel]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    lea edx, [r12d + 330]
    INVOKE ui_button, 55, rdx, r13, 310
    test eax, eax
    jz .end
    mov ecx, SCREEN_WORLDS
    call menu_open
    jmp .end

    ; ---- credits ---------------------------------------------------------------------
.credits:
    mov edi, [LOCAL(M_CX)]
    sub edi, 330
    mov esi, [rel g_ui_vh]
    sub esi, 520
    sar esi, 1
    INVOKE ui_panel, rdi, rsi, 660, 520
    xor ebx, ebx
    lea r12d, [esi + 30]
.c_line:
    cmp ebx, [rel g_credit_n]
    jae .c_back
    lea rax, [rel g_credit_lines]
    mov rcx, [rax + rbx * 8]
    ; the first line is the heading
    mov edx, 20
    mov eax, COL_TEXT_DIM
    xor r13d, r13d
    test ebx, ebx
    jnz .c_draw
    mov edx, 36
    mov eax, COL_TEXT
    mov r13d, UI_BOLD
.c_draw:
    mov [rsp + 32], rax
    or r13d, UI_CENTER
    mov [rsp + 40], r13
    mov r9d, edx
    INVOKE ui_label, rcx, [LOCAL(M_CX)], r12, r9
    add r12d, 34
    test ebx, ebx
    jnz .c_next
    add r12d, 18
.c_next:
    inc ebx
    jmp .c_line
.c_back:
    lea r12d, [esi + 520 - 24 - 52]
    mov qword [rsp + 32], 52
    lea rax, [rel s_back]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    mov edx, [LOCAL(M_CX)]
    sub edx, 110
    INVOKE ui_button, 7, rdx, r12, 220
    test eax, eax
    jz .end
    mov ecx, SCREEN_MAIN
    call menu_open
    jmp .end

    ; ---- pause -----------------------------------------------------------------------
.pause:
    mov edi, [LOCAL(M_CX)]
    sub edi, 200
    mov esi, [rel g_ui_vh]
    sub esi, 4 * 56 + 3 * 12 + 48 + 80
    sar esi, 1
    INVOKE ui_panel, rdi, rsi, 400, 4 * 56 + 3 * 12 + 48 + 80
    lea r8d, [esi + 24]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], UI_CENTER | UI_BOLD
    lea rcx, [rel s_paused]
    INVOKE ui_label, rcx, [LOCAL(M_CX)], r8, 34
    add edi, 30
    add esi, 24 + 80
    mov qword [rsp + 32], 56
    lea rax, [rel s_resume]
    mov [rsp + 40], rax
    mov qword [rsp + 48], UIW_PRIMARY
    INVOKE ui_button, 20, rdi, rsi, 340
    test eax, eax
    jz .p_settings
    mov dword [LOCAL(M_ACTION)], MA_RESUME
.p_settings:
    add esi, 68
    mov qword [rsp + 32], 56
    lea rax, [rel s_settings]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    INVOKE ui_button, 21, rdi, rsi, 340
    test eax, eax
    jz .p_menu
    call open_settings
.p_menu:
    add esi, 68
    mov qword [rsp + 32], 56
    lea rax, [rel s_to_menu]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    INVOKE ui_button, 22, rdi, rsi, 340
    test eax, eax
    jz .p_quit
    mov dword [LOCAL(M_ACTION)], MA_TO_MENU
.p_quit:
    add esi, 68
    mov qword [rsp + 32], 56
    lea rax, [rel s_save_quit]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    INVOKE ui_button, 23, rdi, rsi, 340
    test eax, eax
    jz .end
    mov dword [LOCAL(M_ACTION)], MA_SAVE_QUIT

.end:
    mov ecx, [LOCAL(M_W)]
    mov edx, [LOCAL(M_H)]
    call ui_end
    mov eax, [LOCAL(M_ACTION)]
    mov rdx, [LOCAL(M_ARG)]
    mov r8d, [LOCAL(M_SEED)]
    RETURN
ENDPROC
