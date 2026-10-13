; =============================================================================
; drops_view.asm — the client's view of dropped items (milestone 18): the
; simulation's PKT_S_DROP / PKT_S_DROP_GONE kept in a table, and drawn in the
; world pass as small spinning, bobbing items (shaders/drop.*) that glide to
; their latest position.
;
; Public API:
;   drops_view_reset()
;   drops_view_packet(ecx = type, rdx = DROP_PKT*)
;   drops_view_draw()                   in the scene pass (world_render)
;   g_drops_shown                       how many (overlay)
; =============================================================================
%include "macros.inc"
%include "log.inc"
%include "gl.inc"
%include "packet.inc"

global drops_view_reset, drops_view_packet, drops_view_draw, g_drops_shown

extern shader_create, shader_program, block_textures_bind, icon_uv, icon_kind
extern timer_elapsed_us
extern g_cam_pos, g_cam_viewproj, g_item_block, g_icon_tex, g_daylight
extern g_frame_us

struc VDROP
    .target resq 3                      ; f64 latest position
    .shown  resq 3                      ; f64 drawn position
    .active resd 1
    .item   resw 1
    .count  resw 1
    .pad    resb 8
endstruc

section .rdata
str_vs:         db "shaders/drop.vert", 0
str_fs:         db "shaders/drop.frag", 0
align 8
c_follow:       dq 15.0                 ; glide rate (per second)
c_us:           dq 0.000001
c_one:          dq 1.0
c_spin:         dq 1.6                  ; radians per second
c_bob_rate:     dq 2.5
c_bob:          dq 0.06
c_lift:         dq 0.1                  ; float a little above the ground
c_light0:       dd 0.2
c_light1:       dd 0.8
c_two:          dd 2.0
c_offset:       dq 0.09                 ; a second item for a stack

section .bss
alignb 16
g_vdrops:       resb MAX_DROPS * VDROP_size
g_drops_shown:  resd 1
g_prog:         resd 1
g_vao:          resd 1
g_tried:        resd 1
g_uni:          resd 4

section .text

; drops_view_reset — forget every drop
PROC drops_view_reset, 0, rdi
    lea rdi, [rel g_vdrops]
    xor eax, eax
    mov ecx, MAX_DROPS * VDROP_size / 8
    rep stosq
    mov dword [rel g_drops_shown], 0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; drops_view_packet — a drop appeared / moved, or is gone.
;   in:  ecx = PKT_S_DROP / PKT_S_DROP_GONE, rdx = DROP_PKT*
;   clobbers: rax, rcx, rdx, r8
; -----------------------------------------------------------------------------
drops_view_packet:
    mov eax, [rdx + DROP_PKT.id]
    cmp eax, MAX_DROPS
    jae .done
    imul eax, eax, VDROP_size
    lea r8, [rel g_vdrops]
    add r8, rax
    cmp ecx, PKT_S_DROP_GONE
    jne .update
    cmp dword [r8 + VDROP.active], 0
    je .done
    mov dword [r8 + VDROP.active], 0
    dec dword [rel g_drops_shown]
    ret
.update:
    mov rax, [rdx + DROP_PKT.pos]
    mov [r8 + VDROP.target], rax
    mov rax, [rdx + DROP_PKT.pos + 8]
    mov [r8 + VDROP.target + 8], rax
    mov rax, [rdx + DROP_PKT.pos + 16]
    mov [r8 + VDROP.target + 16], rax
    mov ax, [rdx + DROP_PKT.item]
    mov [r8 + VDROP.item], ax
    mov ax, [rdx + DROP_PKT.count]
    mov [r8 + VDROP.count], ax
    cmp dword [r8 + VDROP.active], 0
    jne .done
    ; new: drawn where it is
    mov rax, [r8 + VDROP.target]
    mov [r8 + VDROP.shown], rax
    mov rax, [r8 + VDROP.target + 8]
    mov [r8 + VDROP.shown + 8], rax
    mov rax, [r8 + VDROP.target + 16]
    mov [r8 + VDROP.shown + 16], rax
    mov dword [r8 + VDROP.active], 1
    inc dword [rel g_drops_shown]
.done:
    ret

; -----------------------------------------------------------------------------
; drops_view_draw — every drop, in the scene pass (depth test on).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
%define D_T     0                       ; f64 seconds
%define D_K     8                       ; f64 glide factor this frame
%define D_ID    16
%define D_N     20                      ; second item of a stack: 1
PROC drops_view_draw, 32, rbx, rsi, rdi
    cmp dword [rel g_drops_shown], 0
    je .done
    cmp dword [rel g_prog], 0
    jne .ready
    cmp dword [rel g_tried], 0
    jne .done
    mov dword [rel g_tried], 1
    lea rcx, [rel str_vs]
    lea rdx, [rel str_fs]
    call shader_create
    cmp eax, -1
    je .done
    mov ecx, eax
    call shader_program
    mov [rel g_prog], eax
    lea rdx, [rel g_vao]
    GL glCreateVertexArrays, 1, rdx
.ready:
    call timer_elapsed_us
    cvtsi2sd xmm0, rax
    mulsd xmm0, [rel c_us]
    movsd [LOCAL(D_T)], xmm0
    mov rax, [rel g_frame_us]
    cvtsi2sd xmm0, rax
    mulsd xmm0, [rel c_us]
    mulsd xmm0, [rel c_follow]
    minsd xmm0, [rel c_one]
    movsd [LOCAL(D_K)], xmm0
    GL glUseProgram, [rel g_prog]
    GL glBindVertexArray, [rel g_vao]
    call block_textures_bind
    GL glBindTextureUnit, 5, [rel g_icon_tex]
    GL glDisable, GL_CULL_FACE
    lea rax, [rel g_cam_viewproj]
    mov [rsp + 32], rax
    GL glProgramUniformMatrix4fv, [rel g_prog], 0, 1, GL_FALSE
    ; light: by the time of day
    movss xmm2, [rel g_daylight]
    mulss xmm2, [rel c_light1]
    addss xmm2, [rel c_light0]
    GL glProgramUniform1f, [rel g_prog], 6
    lea rbx, [rel g_vdrops]
    xor esi, esi
.drop:
    cmp esi, MAX_DROPS
    jae .drawn
    cmp dword [rbx + VDROP.active], 0
    je .next
    mov [LOCAL(D_ID)], esi
    ; glide towards the latest position
    xor ecx, ecx
.axis:
    movsd xmm0, [rbx + VDROP.target + rcx * 8]
    subsd xmm0, [rbx + VDROP.shown + rcx * 8]
    mulsd xmm0, [LOCAL(D_K)]
    addsd xmm0, [rbx + VDROP.shown + rcx * 8]
    movsd [rbx + VDROP.shown + rcx * 8], xmm0
    inc ecx
    cmp ecx, 3
    jb .axis
    ; what it is
    movzx edi, word [rbx + VDROP.item]
    mov ecx, edi
    call icon_kind
    xor r9d, r9d
    cmp eax, 2
    jne .kind
    mov r9d, 1
.kind:
    GL glProgramUniform1i, [rel g_prog], 4, r9
    lea rax, [rel g_item_block]
    movzx r9d, word [rax + rdi * 2]
    GL glProgramUniform1ui, [rel g_prog], 3, r9
    mov ecx, edi
    lea rdx, [rel g_uni]
    call icon_uv
    lea r9, [rel g_uni]
    GL glProgramUniform4fv, [rel g_prog], 5, 1, r9
    ; spin (each drop its own phase)
    cvtsi2sd xmm2, esi
    movsd xmm0, [LOCAL(D_T)]
    mulsd xmm0, [rel c_spin]
    addsd xmm2, xmm0
    cvtsd2ss xmm2, xmm2
    GL glProgramUniform1f, [rel g_prog], 2
    ; one item, or two side by side for a stack
    mov dword [LOCAL(D_N)], 0
.copy:
    ; centre: camera-relative, bobbing
    movsd xmm0, [LOCAL(D_T)]
    mulsd xmm0, [rel c_bob_rate]
    cvtsi2sd xmm1, esi
    addsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    call sinf_approx
    cvtss2sd xmm0, xmm0
    mulsd xmm0, [rel c_bob]
    addsd xmm0, [rel c_lift]            ; xmm0 = the bob
    xor ecx, ecx
.rel:
    movsd xmm1, [rbx + VDROP.shown + rcx * 8]
    lea rax, [rel g_cam_pos]
    subsd xmm1, [rax + rcx * 8]
    cmp ecx, 1
    jne .no_bob
    addsd xmm1, xmm0
.no_bob:
    cmp dword [LOCAL(D_N)], 0
    je .no_offset
    addsd xmm1, [rel c_offset]
.no_offset:
    cvtsd2ss xmm1, xmm1
    lea rax, [rel g_uni]
    movss [rax + rcx * 4], xmm1
    inc ecx
    cmp ecx, 3
    jb .rel
    lea r9, [rel g_uni]
    GL glProgramUniform3fv, [rel g_prog], 1, 1, r9
    GL glDrawArrays, GL_TRIANGLES, 0, 36
    cmp dword [LOCAL(D_N)], 0
    jne .next
    cmp word [rbx + VDROP.count], 1
    jbe .next
    mov dword [LOCAL(D_N)], 1
    jmp .copy
.next:
    add rbx, VDROP_size
    inc esi
    jmp .drop
.drawn:
    GL glBindVertexArray, 0
    GL glEnable, GL_CULL_FACE
.done:
    RETURN
ENDPROC

; sinf_approx — xmm0 = sin(xmm0) (f32), good enough for a bob
;   clobbers: xmm0, xmm1, xmm2
sinf_approx:
    ; wrap to -pi..pi
    movss xmm1, xmm0
    mulss xmm1, [rel c_inv_2pi]
    roundss xmm1, xmm1, 0               ; nearest
    mulss xmm1, [rel c_2pi]
    subss xmm0, xmm1
    ; Bhaskara-like parabola: 4/pi x - 4/pi^2 x|x|
    movss xmm1, xmm0
    andps xmm1, [rel c_abs]
    mulss xmm1, xmm0
    mulss xmm1, [rel c_b]
    mulss xmm0, [rel c_a]
    subss xmm0, xmm1
    ret

section .rdata
align 16
c_abs:          dd 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF
c_inv_2pi:      dd 0.15915494
c_2pi:          dd 6.2831853
c_a:            dd 1.2732395                ; 4 / pi
c_b:            dd 0.40528473               ; 4 / pi^2
