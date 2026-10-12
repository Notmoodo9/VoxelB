; =============================================================================
; menu.asm — the menu screens (milestone 17, design/ui/menus.md):
;   main      the title over the flyover; Play, Settings, Credits, Quit
;   worlds    the saved worlds (saves/*); choose one and Play, or New world
;   credits   data/ui/credits.txt
;   pause     Resume, Settings, Save & quit to menu, Save & quit game
; Screens slide and fade in (~150 ms). The menus only ask; game.asm acts
; (menu.inc: MA_*).
;
; Public API:
;   menu_open(ecx = SCREEN_*)
;   menu_back()                         Esc: the previous screen
;   menu_frame(ecx = w, edx = h) -> eax MA_*, rdx = world name, r8d = seed
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "file.inc"
%include "memory.inc"
%include "ui.inc"
%include "menu.inc"

global menu_open, menu_back, menu_frame

extern ui_frame, ui_end, ui_button, ui_panel, ui_label, ui_rect, ui_text
extern g_ui_vw, g_ui_vh, g_ui_alpha, g_ui_oy, g_ui_dt, g_ui_click, g_ui_mx
extern g_ui_my, g_menu_fade, g_game_state, g_mouse_wheel
extern str_copy, str_append_dec, str_ieq, timer_elapsed_us

IMPORT FindFirstFileA, FindNextFileA, FindClose

%define MAX_WORLDS      64
%define NAME_CAP        64
%define MAX_CREDIT_LINES 32
%define ROWS_VISIBLE    7
%define ROW_H           50
%define FIND_DATA_SIZE  320
%define FD_ATTR         0
%define FD_NAME         44
%define ATTR_DIRECTORY  0x10
%define TRANSITION_S    0.15

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
s_no_worlds:    db "No worlds yet: make a new one", 0
s_paused:       db "Paused", 0
s_resume:       db "Resume", 0
s_to_menu:      db "Save & quit to menu", 0
s_save_quit:    db "Save & quit game", 0
s_version:      db "Milestone 17", 0
s_settings_soon: db "(settings arrive with the next update)", 0
s_world_n:      db "World ", 0
s_saves_glob:   db "saves\*", 0
s_dot:          db ".", 0
s_dotdot:       db "..", 0
s_credits_file: db "data/ui/credits.txt", 0
align 4
c_trans:        dd TRANSITION_S
c_one:          dd 1.0
c_offset:       dd 24.0
c_three:        dd 3.0
c_two:          dd 2.0
c_255:          dd 255.0

section .bss
alignb 4
g_screen:       resd 1
g_prev_screen:  resd 1
g_trans_t:      resd 1                  ; f32 0..1 since the screen opened
g_world_count:  resd 1
g_selected:     resd 1                  ; -1 none
g_scroll:       resd 1
g_credit_n:     resd 1
g_credits_done: resd 1
alignb 8
g_credit_lines: resq MAX_CREDIT_LINES
g_world_names:  resb MAX_WORLDS * NAME_CAP
g_new_name:     resb NAME_CAP
g_find:         resb FIND_DATA_SIZE
g_path:         resb PATH_CAP

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
    cmp ecx, SCREEN_WORLDS
    jne .done
    call list_worlds
.done:
    RETURN
ENDPROC

; menu_back — Esc on a menu screen: back to the main menu
PROC menu_back, 0
    cmp dword [rel g_screen], SCREEN_MAIN
    je .done
    cmp dword [rel g_screen], SCREEN_PAUSE
    je .done
    mov ecx, SCREEN_MAIN
    call menu_open
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; list_worlds — the folders in saves\ (each a world).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC list_worlds, 0, rbx, rsi
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
    je .done
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
    shl eax, 6                          ; * NAME_CAP
    lea rcx, [rel g_world_names]
    add rcx, rax
    ; (names longer than NAME_CAP - 1 are cut)
    lea rsi, [rel g_find + FD_NAME]
    xor edx, edx
.copy:
    mov al, [rsi + rdx]
    mov [rcx + rdx], al
    test al, al
    jz .next
    inc edx
    cmp edx, NAME_CAP - 1
    jb .copy
    mov byte [rcx + rdx], 0
.next:
    lea rdx, [rel g_find]
    API FindNextFileA, rbx, rdx
    test eax, eax
    jnz .entry
    API FindClose, rbx
.done:
    RETURN
ENDPROC

; world_name — rax = name of world ecx
world_name:
    mov eax, ecx
    shl eax, 6
    lea rcx, [rel g_world_names]
    add rax, rcx
    ret

; -----------------------------------------------------------------------------
; new_world_name — "World N" with the first N not taken; a seed from the
; clock.
;   out: rax = name, edx = seed
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC new_world_name, 0, rbx, rsi
    mov ebx, 1
.try:
    lea rcx, [rel g_new_name]
    lea rdx, [rel s_world_n]
    call str_copy
    INVOKE str_append_dec, rax, rbx, 0
    xor esi, esi
.cmp:
    cmp esi, [rel g_world_count]
    jae .free
    mov ecx, esi
    call world_name
    lea rcx, [rel g_new_name]
    mov rdx, rax
    call str_ieq
    test eax, eax
    jnz .taken
    inc esi
    jmp .cmp
.taken:
    inc ebx
    jmp .try
.free:
    rdtsc
    mov ebx, eax
    call timer_elapsed_us
    xor eax, ebx
    imul eax, eax, 0x9E3779B1
    shr eax, 1                          ; (a positive 31-bit seed)
    mov edx, eax
    lea rax, [rel g_new_name]
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
PROC menu_frame, 32, rbx, rsi, rdi, r12, r13
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
    mov qword [rsp + 48], UIW_DISABLED
    INVOKE ui_button, 1, rdi, rsi, 320
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
    lea rcx, [rel s_version]
    INVOKE ui_label, rcx, 20, r8, 16
    jmp .end

    ; ---- worlds ----------------------------------------------------------------------
.worlds:
    mov edi, [LOCAL(M_CX)]
    sub edi, 320                        ; panel left
    mov esi, [rel g_ui_vh]
    sub esi, 600
    sar esi, 1                          ; panel top (600 tall)
    INVOKE ui_panel, rdi, rsi, 640, 600
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
    lea r8d, [esi + 200]
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
    mov ecx, r12d
    call world_name
    mov [rsp + 40], rax
    mov qword [rsp + 32], ROW_H - 6
    xor eax, eax
    cmp r12d, [rel g_selected]
    jne .w_flags
    mov eax, UIW_SELECTED
.w_flags:
    mov [rsp + 48], rax
    imul r8d, ebx, ROW_H
    add r8d, esi
    add r8d, 84
    lea edx, [edi + 40]
    lea ecx, [ebx + 10]
    INVOKE ui_button, rcx, rdx, r8, 560
    test eax, eax
    jz .w_next
    ; a click selects; a click on the selected world plays it
    cmp r12d, [rel g_selected]
    jne .w_select
    mov ecx, r12d
    call world_name
    mov [LOCAL(M_ARG)], rax
    mov dword [LOCAL(M_ACTION)], MA_PLAY
    jmp .w_next
.w_select:
    mov [rel g_selected], r12d
.w_next:
    inc ebx
    jmp .w_row
.w_buttons:
    ; Play world / New world / Back along the bottom
    lea r12d, [esi + 600 - 24 - 52]
    mov qword [rsp + 32], 52
    lea rax, [rel s_play_world]
    mov [rsp + 40], rax
    mov eax, UIW_PRIMARY
    cmp dword [rel g_selected], 0
    jge .w_play_ok
    mov eax, UIW_DISABLED
.w_play_ok:
    mov [rsp + 48], rax
    lea edx, [edi + 40]
    INVOKE ui_button, 4, rdx, r12, 180
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
    lea edx, [edi + 230]
    INVOKE ui_button, 5, rdx, r12, 180
    test eax, eax
    jz .w_back
    call new_world_name
    mov [LOCAL(M_ARG)], rax
    mov [LOCAL(M_SEED)], edx
    mov dword [LOCAL(M_ACTION)], MA_CREATE
.w_back:
    mov qword [rsp + 32], 52
    lea rax, [rel s_back]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    lea edx, [edi + 420]
    INVOKE ui_button, 6, rdx, r12, 180
    test eax, eax
    jz .end
    mov ecx, SCREEN_MAIN
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
    mov qword [rsp + 48], UIW_DISABLED
    INVOKE ui_button, 21, rdi, rsi, 340
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
