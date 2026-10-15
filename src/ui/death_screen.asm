; =============================================================================
; death_screen.asm — the journal page shown when the player dies
; (milestone 20, design/survival/survival.md).
;
; The world behind fades to a sepia wash; a journal page reads "You died",
; how (from the simulation's CAUSE_* and, for a ram, the animal's name),
; the day and where, and what became of the things carried (part 2: the
; world's death rule — scattered, in a gravestone at x, y, z, or kept). "Respawn" asks the simulation to bring the player back at
; the world's spawn (PKT_C_RESPAWN); "Main menu" saves and leaves the
; world. game.asm opens it when PKT_S_SURVIVAL says the player is dead.
;
; Public API:
;   death_screen_open()
;   death_screen_frame(ecx = w, edx = h) -> eax DS_* (what was chosen)
; A Hardcore death (PKT_S_SURVIVAL .flags SVF_SPECTATE) offers "Spectate the
; world" (PKT_C_SPECTATE) and "Delete the world" (twice: "Really delete
; it?"; game.asm leaves the world and deletes its folder) instead.
; =============================================================================
%include "macros.inc"
%include "ui.inc"
%include "packet.inc"
%include "mobs.inc"

global death_screen_open, death_screen_frame

extern ui_frame, ui_end, ui_button, ui_panel, ui_label, ui_rect
extern str_copy, str_append_sdec, str_append_dec, pkt_send, g_to_sim
extern g_ui_vw, g_ui_vh, g_frame_us, g_csv

%define DS_NONE         0
%define DS_RESPAWN      1
%define DS_MENU         2
%define DS_SPECTATE     3               ; Hardcore: PKT_C_SPECTATE sent
%define DS_DELETE       4               ; Hardcore: delete the world (confirmed)
%define PAGE_W          600
%define PAGE_H          340

section .rdata
s_title:        db "You died", 0
s_respawn:      db "Respawn", 0
s_menu:         db "Main menu", 0
s_where:        db "on day ", 0
s_at:           db ", at ", 0
s_dropped:      db "Your things lie scattered where you fell.", 0
s_grave:        db "Your things wait in a gravestone at ", 0
s_kept:         db "You kept your things.", 0
s_hardcore:     db "Hardcore: this world's story has ended.", 0
s_spectate:     db "Spectate the world", 0
s_delete:       db "Delete the world", 0
s_really:       db "Really delete it?", 0
s_comma:        db ", ", 0
s_you:          db "You ", 0
s_rammed:       db "were rammed by a ", 0
s_animal:       db "an animal", 0
c_0:            db "died", 0
c_1:            db "fell from a high place", 0
c_2:            db "drowned", 0
c_3:            db "tried to swim in lava", 0
c_4:            db "burned to death", 0
c_5:            db "suffocated in a wall", 0
c_6:            db "were pricked to death by a cactus", 0
c_7:            db "fell out of the world", 0
c_8:            db "were rammed", 0
c_9:            db "starved to death", 0
align 8
causes:         dq c_0, c_1, c_2, c_3, c_4, c_5, c_6, c_7, c_8, c_9
align 4
c_fade_rate:    dd 0.0000015            ; the sepia wash: in over ~2/3 s (per microsecond)
c_fade_alpha:   dd 150.0

section .bss
alignb 4
g_fade:         resd 1                  ; f32 0 .. 1
g_line:         resb 128                ; how
g_where:        resb 64                 ; when and where
g_fate:         resb 96                 ; what became of the things
g_confirm:      resd 1                  ; Hardcore: "Delete" clicked once

section .text

; -----------------------------------------------------------------------------
; death_screen_open — the page for this death: its lines from g_csv.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
death_screen_open:
    mov dword [rel g_fade], 0
    mov dword [rel g_confirm], 0
; lines — the page's text from g_csv (every frame: the gravestone may be
; placed a few ticks after the death)
PROC lines, 0, rbx
    ; "You <how>"
    lea rcx, [rel g_line]
    lea rdx, [rel s_you]
    call str_copy
    movzx ebx, word [rel g_csv + SURV_PKT.cause]
    cmp ebx, CAUSE_COUNT
    jb .known
    xor ebx, ebx
.known:
    cmp ebx, CAUSE_RAM
    jne .plain
    ; "were rammed by a <animal>"
    mov rcx, rax
    lea rdx, [rel s_rammed]
    call str_copy
    movzx edx, word [rel g_csv + SURV_PKT.cause_mob]
    cmp edx, [rel g_mob_count]
    jae .no_mob
    imul edx, edx, MOB_size
    lea rcx, [rel g_mobs]
    mov rdx, [rcx + rdx + MOB.title]
    test rdx, rdx
    jnz .mob_name
.no_mob:
    lea rdx, [rel s_animal]
.mob_name:
    mov rcx, rax
    call str_copy
    jmp .where
.plain:
    mov rcx, rax
    lea rdx, [rel causes]
    mov rdx, [rdx + rbx * 8]
    call str_copy
.where:
    ; "on day N, at x, y, z"
    lea rcx, [rel g_where]
    lea rdx, [rel s_where]
    call str_copy
    mov edx, [rel g_csv + SURV_PKT.day]
    INVOKE str_append_dec, rax, rdx, 0
    mov rcx, rax
    lea rdx, [rel s_at]
    call str_copy
    mov rcx, rax
    lea rdx, [rel g_csv + SURV_PKT.death]
    call append_xyz
    ; the things
    movzx eax, word [rel g_csv + SURV_PKT.flags]
    test eax, SVF_SPECTATE
    jz .not_hardcore
    lea rcx, [rel g_fate]
    lea rdx, [rel s_hardcore]
    call str_copy
    RETURN
.not_hardcore:
    mov ecx, eax
    and ecx, SVF_KEPT | SVF_GRAVE
    cmp ecx, SVF_KEPT | SVF_GRAVE
    jne .settled
    mov byte [rel g_fate], 0            ; (the stone is still to come)
    RETURN
.settled:
    test eax, SVF_KEPT
    jnz .kept
    test eax, SVF_GRAVE
    jnz .grave
    lea rcx, [rel g_fate]
    lea rdx, [rel s_dropped]
    call str_copy
    RETURN
.kept:
    lea rcx, [rel g_fate]
    lea rdx, [rel s_kept]
    call str_copy
    RETURN
.grave:
    lea rcx, [rel g_fate]
    lea rdx, [rel s_grave]
    call str_copy
    mov rcx, rax
    lea rdx, [rel g_csv + SURV_PKT.grave]
    call append_xyz
    RETURN
ENDPROC

; append_xyz — "x, y, z" (i32 x 3 at rdx) at cursor rcx
;   out: rax = cursor   clobbers: volatile registers
PROC append_xyz, 0, rbx, rsi
    mov rsi, rdx
    mov rax, rcx
    xor ebx, ebx
.coord:
    test ebx, ebx
    jz .num
    mov rcx, rax
    lea rdx, [rel s_comma]
    call str_copy
.num:
    movsxd rdx, dword [rsi + rbx * 4]
    INVOKE str_append_sdec, rax, rdx, 0
    inc ebx
    cmp ebx, 3
    jb .coord
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; death_screen_frame — draw the page, handle its buttons.
;   in:  ecx = w, edx = h
;   out: eax = DS_NONE, DS_RESPAWN (PKT_C_RESPAWN sent) or DS_MENU
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define F_W     0
%define F_H     4
%define F_X     8
%define F_Y     12
%define F_OUT   16
PROC death_screen_frame, 32, rbx, rsi
    mov [LOCAL(F_W)], ecx
    mov [LOCAL(F_H)], edx
    mov dword [LOCAL(F_OUT)], DS_NONE
    call lines
    mov ecx, [LOCAL(F_W)]
    mov edx, [LOCAL(F_H)]
    call ui_frame
    ; the sepia wash, fading in
    mov rax, [rel g_frame_us]
    cvtsi2ss xmm0, rax
    mulss xmm0, [rel c_fade_rate]
    addss xmm0, [rel g_fade]
    minss xmm0, [rel c_one]
    movss [rel g_fade], xmm0
    mulss xmm0, [rel c_fade_alpha]
    cvttss2si eax, xmm0
    shl eax, 24
    or eax, 0x00183A5A                  ; (ABGR) warm brown
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov r8d, [rel g_ui_vw]
    add r8d, 16
    mov r9d, [rel g_ui_vh]
    add r9d, 16
    INVOKE ui_rect, -8, -8, r8, r9
    ; the page
    mov eax, [rel g_ui_vw]
    sub eax, PAGE_W
    sar eax, 1
    mov [LOCAL(F_X)], eax
    mov eax, [rel g_ui_vh]
    sub eax, PAGE_H
    sar eax, 1
    mov [LOCAL(F_Y)], eax
    INVOKE ui_panel, [LOCAL(F_X)], [LOCAL(F_Y)], PAGE_W, PAGE_H
    mov ebx, [LOCAL(F_X)]
    add ebx, PAGE_W / 2
    mov esi, [LOCAL(F_Y)]
    lea r8d, [esi + 40]
    mov dword [rsp + 32], COL_DANGER
    mov qword [rsp + 40], UI_CENTER | UI_BOLD
    lea rcx, [rel s_title]
    INVOKE ui_label, rcx, rbx, r8, 44
    lea r8d, [esi + 110]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel g_line]
    INVOKE ui_label, rcx, rbx, r8, 22
    lea r8d, [esi + 146]
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel g_where]
    INVOKE ui_label, rcx, rbx, r8, 18
    lea r8d, [esi + 184]
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], UI_CENTER
    lea rcx, [rel g_fate]
    INVOKE ui_label, rcx, rbx, r8, 18
    ; the buttons (Hardcore: spectate or delete)
    test word [rel g_csv + SURV_PKT.flags], SVF_SPECTATE
    jnz .hardcore
    mov edx, [LOCAL(F_X)]
    add edx, 50
    lea r8d, [esi + 250]
    mov qword [rsp + 32], 54
    lea rax, [rel s_respawn]
    mov [rsp + 40], rax
    mov qword [rsp + 48], UIW_PRIMARY
    INVOKE ui_button, 1, rdx, r8, 240
    test eax, eax
    jz .menu
    lea rcx, [rel g_to_sim]
    INVOKE pkt_send, rcx, PKT_C_RESPAWN, 0, 0
    mov dword [LOCAL(F_OUT)], DS_RESPAWN
.menu:
    mov edx, [LOCAL(F_X)]
    add edx, PAGE_W - 50 - 240
    lea r8d, [esi + 250]
    mov qword [rsp + 32], 54
    lea rax, [rel s_menu]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    INVOKE ui_button, 2, rdx, r8, 240
    test eax, eax
    jz .drawn
    mov dword [LOCAL(F_OUT)], DS_MENU
    jmp .drawn
.hardcore:
    mov edx, [LOCAL(F_X)]
    add edx, 50
    lea r8d, [esi + 250]
    mov qword [rsp + 32], 54
    lea rax, [rel s_spectate]
    mov [rsp + 40], rax
    mov qword [rsp + 48], UIW_PRIMARY
    INVOKE ui_button, 3, rdx, r8, 240
    test eax, eax
    jz .delete
    lea rcx, [rel g_to_sim]
    INVOKE pkt_send, rcx, PKT_C_SPECTATE, 0, 0
    mov dword [LOCAL(F_OUT)], DS_SPECTATE
.delete:
    mov edx, [LOCAL(F_X)]
    add edx, PAGE_W - 50 - 240
    lea r8d, [esi + 250]
    mov qword [rsp + 32], 54
    lea rax, [rel s_delete]
    cmp dword [rel g_confirm], 0
    je .delete_text
    lea rax, [rel s_really]
.delete_text:
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    INVOKE ui_button, 4, rdx, r8, 240
    test eax, eax
    jz .drawn
    cmp dword [rel g_confirm], 0
    jne .deleted
    mov dword [rel g_confirm], 1        ; (a second click deletes)
    jmp .drawn
.deleted:
    mov dword [LOCAL(F_OUT)], DS_DELETE
.drawn:
    mov ecx, [LOCAL(F_W)]
    mov edx, [LOCAL(F_H)]
    call ui_end
    mov eax, [LOCAL(F_OUT)]
    RETURN
ENDPROC

section .rdata
align 4
c_one:          dd 1.0
