; =============================================================================
; name_screen.asm — name tags (milestone 19 part 3b,
; design/mobs/passive_animals.md): the journal page that names an animal,
; and the names floating over named animals.
;
; Right-clicking an animal with a name tag in hand (interact.asm sets
; g_name_request) opens a small journal page with a text field; Enter or
; "Name it" sends PKT_C_NAME (the simulation checks the tag is still in
; hand, names the animal and uses the tag up in Survival), Esc or "Cancel"
; closes it. While the page is open the player stands still and the mouse
; is free (game.asm).
; Named animals within NAME_RANGE blocks show their name over their head,
; on a dark band, smaller further away.
;
; Public API:
;   name_screen_open(ecx = animal id)
;   name_screen_frame(ecx = w, edx = h) -> eax 1 once the page closed
;   names_draw(ecx = w, edx = h)        the floating names (with the HUD)
;   g_name_request                      interact.asm: animal id + 1 (0 none)
;   graves_view_reset(), graves_view_packet(rcx = GRAVE_PKT*)
;                                       the gravestones (milestone 20 part 2):
;                                       "Here lies <name>, day <n>" floats over
;                                       each one within NAME_RANGE (names_draw)
;   use_test_frame()                    --use-test: g_use_test frames in, a right
;                                       click on the nearest grown-up (once one
;                                       is within 4 blocks) with what is in hand
; =============================================================================
%include "macros.inc"
%include "ui.inc"
%include "packet.inc"
%include "mobs.inc"
%include "ents_view.inc"

global name_screen_open, name_screen_frame, names_draw, g_name_request
global use_test_frame, g_use_test, graves_view_reset, graves_view_packet

extern ui_frame, ui_end, ui_button, ui_panel, ui_label, ui_rect, ui_text
extern ui_text_width, ui_textfield, ui_focus, ui_draw_begin, ui_draw_flush
extern pkt_send, g_to_sim, g_ui_vw, g_ui_vh, g_cam_pos, g_cam_viewproj
extern use_on_animal, str_copy, str_append_dec

%define FIELD_ID        0
%define PAGE_W          560
%define PAGE_H          270
%define NAME_RANGE      24              ; blocks: names further away are not shown (c_range2)

section .rdata
s_title:        db "A name tag", 0
s_ask:          db "What shall this animal be called?", 0
s_hint:         db "a name", 0
s_ok:           db "Name it", 0
s_cancel:       db "Cancel", 0
s_here_lies:    db "Here lies ", 0
s_day:          db ", day ", 0
align 4
c_range2:       dd 576.0                ; NAME_RANGE squared
c_above:        dd 0.45                 ; blocks over the head
c_baby:         dd 0.5
c_near_w:       dd 0.1
c_half:         dd 0.5
c_size_k:       dd 150.0                ; size = 150 / distance ...
c_size_min:     dd 12.0
c_size_max:     dd 26.0
align 8
c_far:          dq 1.0e30
c_half_d:       dq 0.5
c_grave_above:  dq 1.35                 ; the label over a gravestone's block
c_close2:       dq 16.0                 ; --use-test: an animal within 4 blocks

section .bss
alignb 4
g_name_request: resd 1                  ; animal id + 1 (interact.asm)
g_use_test:    resd 1                  ; --use-test: frames left (0: off)
g_name_id:      resd 1
g_name_buf:     resb ENT_NAME_MAX
g_name_pkt:     resb NAME_PKT_size
g_proj:         resd 4                  ; names_draw: x, y, w, distance
; the gravestones the simulation told about (PKT_S_GRAVE)
struc CGRAVE
    .used   resd 1
    .pos    resd 3
    .text   resb 64                     ; "Here lies <name>, day <n>"
endstruc
alignb 8
g_cgraves:      resb MAX_GRAVES * CGRAVE_size

section .text

; -----------------------------------------------------------------------------
; name_screen_open — the page for animal ecx: an empty field with the keyboard.
;   clobbers: rax, rcx
; -----------------------------------------------------------------------------
name_screen_open:
    mov [rel g_name_id], ecx
    xor eax, eax
    lea rcx, [rel g_name_buf]
    mov [rcx], rax
    mov [rcx + 8], rax
    mov [rcx + 16], rax
    mov ecx, FIELD_ID + 1
    jmp ui_focus

; -----------------------------------------------------------------------------
; name_screen_frame — draw the page, handle its field and buttons.
;   in:  ecx = w, edx = h
;   out: eax = 1 the page closed this frame (named or cancelled), 0 open
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define N_W     0
%define N_H     4
%define N_X     8
%define N_Y     12
%define N_DONE  16
PROC name_screen_frame, 32, rbx, rsi
    mov [LOCAL(N_W)], ecx
    mov [LOCAL(N_H)], edx
    mov dword [LOCAL(N_DONE)], 0
    call ui_frame
    ; the world dims behind
    mov dword [rsp + 32], 0x50000000
    mov dword [rsp + 40], 0x70000000
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov r8d, [rel g_ui_vw]
    add r8d, 16
    mov r9d, [rel g_ui_vh]
    add r9d, 16
    INVOKE ui_rect, -8, -8, r8, r9
    ; the page, centred
    mov eax, [rel g_ui_vw]
    sub eax, PAGE_W
    sar eax, 1
    mov [LOCAL(N_X)], eax
    mov eax, [rel g_ui_vh]
    sub eax, PAGE_H
    sar eax, 1
    mov [LOCAL(N_Y)], eax
    INVOKE ui_panel, [LOCAL(N_X)], [LOCAL(N_Y)], PAGE_W, PAGE_H
    mov ebx, [LOCAL(N_X)]
    add ebx, 44
    mov esi, [LOCAL(N_Y)]
    ; title and question
    lea r8d, [esi + 34]
    mov dword [rsp + 32], COL_TEXT
    mov qword [rsp + 40], UI_BOLD
    lea rcx, [rel s_title]
    INVOKE ui_label, rcx, rbx, r8, 28
    lea r8d, [esi + 78]
    mov dword [rsp + 32], COL_TEXT_DIM
    mov qword [rsp + 40], 0
    lea rcx, [rel s_ask]
    INVOKE ui_label, rcx, rbx, r8, 19
    ; the field: Enter names it
    mov qword [rsp + 32], 50
    lea rax, [rel g_name_buf]
    mov [rsp + 40], rax
    mov qword [rsp + 48], ENT_NAME_MAX
    lea rax, [rel s_hint]
    mov [rsp + 56], rax
    lea r8d, [esi + 112]
    INVOKE ui_textfield, FIELD_ID, rbx, r8, PAGE_W - 88
    cmp eax, 2
    je .name
    ; the buttons
    lea r8d, [esi + 190]
    mov qword [rsp + 32], 50
    lea rax, [rel s_ok]
    mov [rsp + 40], rax
    mov qword [rsp + 48], UIW_PRIMARY
    cmp byte [rel g_name_buf], 0
    jne .ok_flags
    mov qword [rsp + 48], UIW_PRIMARY | UIW_DISABLED
.ok_flags:
    INVOKE ui_button, 1, rbx, r8, 220
    test eax, eax
    jnz .name
    lea edx, [ebx + PAGE_W - 88 - 220]
    lea r8d, [esi + 190]
    mov qword [rsp + 32], 50
    lea rax, [rel s_cancel]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    INVOKE ui_button, 2, rdx, r8, 220
    test eax, eax
    jz .drawn
    mov dword [LOCAL(N_DONE)], 1
    jmp .drawn
.name:
    cmp byte [rel g_name_buf], 0
    je .drawn                           ; (nothing typed yet)
    mov eax, [rel g_name_id]
    mov [rel g_name_pkt + NAME_PKT.id], eax
    lea rcx, [rel g_name_buf]
    mov rax, [rcx]
    mov [rel g_name_pkt + NAME_PKT.name], rax
    mov rax, [rcx + 8]
    mov [rel g_name_pkt + NAME_PKT.name + 8], rax
    mov rax, [rcx + 16]
    mov [rel g_name_pkt + NAME_PKT.name + 16], rax
    mov byte [rel g_name_pkt + NAME_PKT.name + ENT_NAME_MAX - 1], 0
    lea rcx, [rel g_to_sim]
    lea r8, [rel g_name_pkt]
    INVOKE pkt_send, rcx, PKT_C_NAME, r8, NAME_PKT_size
    mov dword [LOCAL(N_DONE)], 1
.drawn:
    mov ecx, [LOCAL(N_W)]
    mov edx, [LOCAL(N_H)]
    call ui_end
    mov eax, [LOCAL(N_DONE)]
    test eax, eax
    jz .done
    xor ecx, ecx
    call ui_focus
    mov eax, 1
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; names_draw — every named animal in sight within NAME_RANGE blocks: its
; name over its head (projected with the camera), on a dark band.
;   in:  ecx = w, edx = h
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define D_REL   0                       ; f32 x 3: the label's point - camera
%define D_SIZE  12
%define D_TW    16
%define D_I     20
%define D_W     24                      ; the frame's size (for the flush)
%define D_H     28
%define D_TEXT  32                      ; the label's text
%define D_GRAVE 40                      ; -1 animals, else the gravestone looked at next
PROC names_draw, 48, rbx, rsi, rdi
    mov [LOCAL(D_W)], ecx
    mov [LOCAL(D_H)], edx
    mov dword [LOCAL(D_GRAVE)], -1
    call ui_draw_begin
    xor esi, esi
.ent:
    cmp esi, [rel g_ents_shown]
    jae .graves
    lea rax, [rel g_vlist]
    movzx eax, word [rax + rsi * 2]
    inc esi
    imul eax, eax, VENT_size
    lea rbx, [rel g_vents]
    add rbx, rax
    cmp byte [rbx + VENT.name], 0
    je .ent
    test word [rbx + VENT.flags], EPF_DYING
    jnz .ent
    movzx eax, word [rbx + VENT.variant]
    cmp eax, [rel g_variant_count]
    jae .ent
    ; the point over its head
    imul eax, eax, VARIANT_size
    lea rcx, [rel g_variants]
    mov eax, [rcx + rax + VARIANT.mob]
    imul eax, eax, MOB_size
    lea rcx, [rel g_mobs]
    movss xmm3, [rcx + rax + MOB.height]
    test word [rbx + VENT.flags], EPF_BABY
    jz .adult
    mulss xmm3, [rel c_baby]
.adult:
    addss xmm3, [rel c_above]
    movsd xmm0, [rbx + VENT.shown]
    subsd xmm0, [rel g_cam_pos]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(D_REL)], xmm0
    movsd xmm1, [rbx + VENT.shown + 8]
    subsd xmm1, [rel g_cam_pos + 8]
    cvtsd2ss xmm1, xmm1
    addss xmm1, xmm3
    movss [LOCAL(D_REL + 4)], xmm1
    movsd xmm2, [rbx + VENT.shown + 16]
    subsd xmm2, [rel g_cam_pos + 16]
    cvtsd2ss xmm2, xmm2
    movss [LOCAL(D_REL + 8)], xmm2
    lea rax, [rbx + VENT.name]
    mov [LOCAL(D_TEXT)], rax
.label:
    ; near enough?
    movss xmm4, xmm0
    mulss xmm4, xmm4
    movss xmm5, xmm1
    mulss xmm5, xmm5
    addss xmm4, xmm5
    movss xmm5, xmm2
    mulss xmm5, xmm5
    addss xmm4, xmm5
    comiss xmm4, [rel c_range2]
    ja .next
    sqrtss xmm4, xmm4
    movss [rel g_proj + 12], xmm4
    ; clip = M * (rel, 1) (column-major): x, y, w
    lea rcx, [rel g_cam_viewproj]
    xor edx, edx
.row:
    movss xmm5, [rcx + rdx * 4]
    mulss xmm5, xmm0
    movss xmm4, [rcx + rdx * 4 + 16]
    mulss xmm4, xmm1
    addss xmm5, xmm4
    movss xmm4, [rcx + rdx * 4 + 32]
    mulss xmm4, xmm2
    addss xmm5, xmm4
    addss xmm5, [rcx + rdx * 4 + 48]
    lea r8, [rel g_proj]
    cmp edx, 3
    jne .store
    movss [r8 + 8], xmm5                ; w
    jmp .row_next
.store:
    cmp edx, 2
    je .row_next                        ; (z: not needed)
    movss [r8 + rdx * 4], xmm5
.row_next:
    inc edx
    cmp edx, 4
    jb .row
    movss xmm5, [rel g_proj + 8]
    comiss xmm5, [rel c_near_w]
    jb .next                            ; (behind the camera)
    ; screen units: x = (ndc x / 2 + 1/2) vw, y = (1/2 - ndc y / 2) vh
    movss xmm0, [rel g_proj]
    divss xmm0, xmm5
    mulss xmm0, [rel c_half]
    addss xmm0, [rel c_half]
    cvtsi2ss xmm1, dword [rel g_ui_vw]
    mulss xmm0, xmm1
    cvttss2si edi, xmm0                 ; x (centre)
    movss xmm0, [rel g_proj + 4]
    divss xmm0, xmm5
    mulss xmm0, [rel c_half]
    movss xmm1, [rel c_half]
    subss xmm1, xmm0
    cvtsi2ss xmm0, dword [rel g_ui_vh]
    mulss xmm1, xmm0
    cvttss2si eax, xmm1
    mov [LOCAL(D_I)], eax               ; y (the band's bottom)
    ; its size by the distance
    movss xmm0, [rel c_size_k]
    divss xmm0, [rel g_proj + 12]
    maxss xmm0, [rel c_size_min]
    minss xmm0, [rel c_size_max]
    cvttss2si eax, xmm0
    mov [LOCAL(D_SIZE)], eax
    mov rcx, [LOCAL(D_TEXT)]
    mov edx, eax
    call ui_text_width
    mov [LOCAL(D_TW)], eax
    ; the band
    mov dword [rsp + 32], 0x78000000
    mov dword [rsp + 40], 0x78000000
    mov qword [rsp + 48], 4
    mov qword [rsp + 56], 0
    mov ecx, edi
    mov eax, [LOCAL(D_TW)]
    shr eax, 1
    sub ecx, eax
    sub ecx, 8
    mov edx, [LOCAL(D_I)]
    mov eax, [LOCAL(D_SIZE)]
    sub edx, eax
    sub edx, 8
    mov r8d, [LOCAL(D_TW)]
    add r8d, 16
    mov r9d, [LOCAL(D_SIZE)]
    add r9d, 10
    INVOKE ui_rect, rcx, rdx, r8, r9
    ; the name
    mov r8d, [LOCAL(D_I)]
    sub r8d, [LOCAL(D_SIZE)]
    sub r8d, 4
    mov dword [rsp + 32], COL_LIGHT
    mov dword [rsp + 40], COL_LIGHT
    mov qword [rsp + 48], UI_CENTER | UI_SHADOW
    mov rcx, [LOCAL(D_TEXT)]
    INVOKE ui_text, rcx, rdi, r8, [LOCAL(D_SIZE)]
.next:
    cmp dword [LOCAL(D_GRAVE)], -1
    je .ent
    ; ---- the gravestones: the label a little over the stone ----
.grave:
    inc dword [LOCAL(D_GRAVE)]
.graves:
    mov eax, [LOCAL(D_GRAVE)]
    cmp eax, -1
    jne .grave_at
    xor eax, eax
    mov [LOCAL(D_GRAVE)], eax
.grave_at:
    cmp eax, MAX_GRAVES
    jae .flush
    imul eax, eax, CGRAVE_size
    lea rbx, [rel g_cgraves]
    add rbx, rax
    cmp dword [rbx + CGRAVE.used], 0
    je .grave
    cvtsi2sd xmm0, dword [rbx + CGRAVE.pos]
    addsd xmm0, [rel c_half_d]
    subsd xmm0, [rel g_cam_pos]
    cvtsd2ss xmm0, xmm0
    movss [LOCAL(D_REL)], xmm0
    cvtsi2sd xmm1, dword [rbx + CGRAVE.pos + 4]
    addsd xmm1, [rel c_grave_above]
    subsd xmm1, [rel g_cam_pos + 8]
    cvtsd2ss xmm1, xmm1
    movss [LOCAL(D_REL + 4)], xmm1
    cvtsi2sd xmm2, dword [rbx + CGRAVE.pos + 8]
    addsd xmm2, [rel c_half_d]
    subsd xmm2, [rel g_cam_pos + 16]
    cvtsd2ss xmm2, xmm2
    movss [LOCAL(D_REL + 8)], xmm2
    lea rax, [rbx + CGRAVE.text]
    mov [LOCAL(D_TEXT)], rax
    jmp .label
.flush:
    mov ecx, [LOCAL(D_W)]
    mov edx, [LOCAL(D_H)]
    call ui_draw_flush
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; use_test_frame — --use-test: counts g_use_test down; at 1 the animal in
; sight nearest the camera (a grown-up) is right-clicked with what is in
; hand (tests the name page, milking, leads ... without aiming).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC use_test_frame, 0, rbx, rsi, rdi
    cmp dword [rel g_use_test], 0
    je .done
    dec dword [rel g_use_test]
    cmp dword [rel g_use_test], 1
    jne .done
    mov edi, -1                         ; the nearest
    movsd xmm3, [rel c_far]
    xor esi, esi
.ent:
    cmp esi, [rel g_ents_shown]
    jae .picked
    lea rax, [rel g_vlist]
    movzx ebx, word [rax + rsi * 2]
    inc esi
    imul eax, ebx, VENT_size
    lea rcx, [rel g_vents]
    add rcx, rax
    test word [rcx + VENT.flags], EPF_BABY
    jnz .ent                            ; (grown-ups only: they can be milked)
    movsd xmm0, [rcx + VENT.shown]
    subsd xmm0, [rel g_cam_pos]
    mulsd xmm0, xmm0
    movsd xmm1, [rcx + VENT.shown + 16]
    subsd xmm1, [rel g_cam_pos + 16]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    comisd xmm0, xmm3
    jae .ent
    movsd xmm3, xmm0
    mov edi, ebx
    jmp .ent
.picked:
    comisd xmm3, [rel c_close2]
    ja .wait                            ; (none within 4 blocks yet: next frame)
    mov dword [rel g_use_test], 0
    mov ecx, edi
    call use_on_animal
    RETURN
.wait:
    mov dword [rel g_use_test], 2     ; (tries again next frame)
    RETURN
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; graves_view_reset — no gravestones known (a world starts)
;   clobbers: rax, rcx, rdi
; -----------------------------------------------------------------------------
PROC graves_view_reset, 0, rdi
    lea rdi, [rel g_cgraves]
    xor eax, eax
    mov ecx, MAX_GRAVES * CGRAVE_size / 8
    rep stosq
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; graves_view_packet — PKT_S_GRAVE: a gravestone appeared (its label made
; here) or was emptied.
;   in:  rcx = GRAVE_PKT*
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC graves_view_packet, 0, rbx, rsi
    mov rsi, rcx
    movzx eax, word [rsi + GRAVE_PKT.index]
    cmp eax, MAX_GRAVES
    jae .done
    imul eax, eax, CGRAVE_size
    lea rbx, [rel g_cgraves]
    add rbx, rax
    movzx eax, word [rsi + GRAVE_PKT.used]
    mov [rbx + CGRAVE.used], eax
    mov eax, [rsi + GRAVE_PKT.pos]
    mov [rbx + CGRAVE.pos], eax
    mov eax, [rsi + GRAVE_PKT.pos + 4]
    mov [rbx + CGRAVE.pos + 4], eax
    mov eax, [rsi + GRAVE_PKT.pos + 8]
    mov [rbx + CGRAVE.pos + 8], eax
    mov byte [rsi + GRAVE_PKT.name + ENT_NAME_MAX - 1], 0
    lea rcx, [rbx + CGRAVE.text]
    lea rdx, [rel s_here_lies]
    call str_copy
    mov rcx, rax
    lea rdx, [rsi + GRAVE_PKT.name]
    call str_copy
    mov rcx, rax
    lea rdx, [rel s_day]
    call str_copy
    mov edx, [rsi + GRAVE_PKT.day]
    INVOKE str_append_dec, rax, rdx, 0
.done:
    RETURN
ENDPROC
