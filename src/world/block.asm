; =============================================================================
; block.asm — data-driven block registry (DATA_FORMAT.md, "Block files").
;
; Every *.blocks file in data/blocks/ is read at start-up, in file-name order
; (so block ids are deterministic). A file holds records:
;   [block <name>]      define a block, or change an existing one
;   [template <name>]   a reusable set of block settings; "{}" in any value
;                       (and in its `name` pattern) stands for a member
;   [family <name>]     templates = t1, t2 ...   members = m1, m2 ...
;                       creates one block per (member, template)
;   [texture <name>]    animation / glow settings of one texture
; Block settings: textures, render, light, sway. Textures are PNG files in
; assets/textures/blocks/<name>.png, loaded by render/block_textures.asm.
; Adding blocks never needs assembly changes.
;
; Public API (include/block.inc):
;   blocks_load() -> eax 1/0         read every block file (after settings_load)
;   block_find(name) -> eax id or -1 ("air" is 0)
;   tex_find(name) -> eax texture index or -1 (0 is the built-in "missing")
;   Tables, indexed by block id (ids are u16, capacity MAX_BLOCK_TYPES):
;     g_block_count, g_block_names (char*), g_block_colors (RGBA8 average of
;     the top texture, set by the texture loader), g_block_light (u16:
;     r | g << 4 | b << 8, 0..15 each), g_block_flags (BLOCKF_*),
;     g_block_tex (u16 texture index per face: -X +X -Y +Y -Z +Z)
;   Mesher tables, 64 K entries so any u16 id can be looked up:
;     g_block_opaque (hides neighbour faces), g_block_layer (LAYER_*),
;     g_block_cullself (faces between two equal blocks are hidden)
;   Textures: g_tex_count, g_tex_names, g_tex_frame_ms (u32, 0 = default),
;     g_tex_glow (u16 glow texture + 1, 0 = none), g_tex_interp (u8)
; =============================================================================
%define BLOCK_IMPL
%include "macros.inc"
%include "log.inc"
%include "memory.inc"
%include "file.inc"
%include "cfg.inc"
%include "block.inc"

global blocks_load, block_find, tex_find
global g_block_count, g_block_names, g_block_colors, g_block_opaque
global g_block_layer, g_block_cullself, g_block_light, g_block_flags, g_block_tex
global g_tex_count, g_tex_names, g_tex_frame_ms, g_tex_glow, g_tex_interp

extern str_ieq, str_len, str_copy, str_parse_u64
extern g_opaque_leaves

IMPORT FindFirstFileA, FindNextFileA, FindClose

%define MAX_TEMPLATES       128
%define MAX_TPL_PAIRS       32
%define MAX_FAM_TEMPLATES   32
%define MAX_FAM_MEMBERS     128
%define MAX_FILES           256
%define SUBST_CAP           256
%define TEX_UNSET           0xFFFF

; record kinds
%define REC_NONE            0
%define REC_BLOCK           1
%define REC_TEMPLATE        2
%define REC_FAMILY          3
%define REC_TEXTURE         4

; WIN32_FIND_DATAA
%define FD_SIZE             320
%define FD_ATTR             0
%define FD_NAME             44
%define FILE_ATTRIBUTE_DIRECTORY 0x10

section .rdata
str_air:        db "air", 0
str_missing:    db "missing", 0
str_pattern:    db "data\blocks\*.blocks", 0
str_dir:        db "data\blocks\", 0
k_block:        db "block", 0
k_template:     db "template", 0
k_family:       db "family", 0
k_texture:      db "texture", 0
k_name:         db "name", 0
k_textures:     db "textures", 0
k_render:       db "render", 0
k_light:        db "light", 0
k_sway:         db "sway", 0
k_templates:    db "templates", 0
k_members:      db "members", 0
k_frame_ms:     db "frame_ms", 0
k_interp:       db "interpolate", 0
k_glow:         db "glow", 0
v_opaque:       db "opaque", 0
v_cutout:       db "cutout", 0
v_translucent:  db "translucent", 0
; face names and their face masks (bit f = face f: -X +X -Y +Y -Z +Z)
f_all:          db "all", 0
f_side:         db "side", 0
f_top:          db "top", 0
f_bottom:       db "bottom", 0
f_end:          db "end", 0
f_west:         db "west", 0
f_east:         db "east", 0
f_north:        db "north", 0
f_south:        db "south", 0
align 8
face_names:     dq f_all, f_side, f_top, f_bottom, f_end, f_west, f_east, f_north, f_south
face_masks:     db 0x3F, 0x33, 0x08, 0x04, 0x0C, 0x01, 0x02, 0x10, 0x20
%define FACE_NAME_COUNT 9
str_unknown_rec:    db "unknown record type: ", 0
str_unknown_key:    db "unknown setting: ", 0
str_bad_value:      db "bad value for: ", 0
str_outside:        db "setting outside a record: ", 0
str_no_template:    db "unknown template: ", 0
str_tpl_no_name:    db "template has no name pattern: ", 0
str_bad_face:       db "unknown face: ", 0
str_too_many:       db "too many entries in: ", 0
str_loaded:         db "blocks: ", 0
str_loaded2:        db " blocks, ", 0
str_loaded3:        db " textures, from files ", 0
str_reading:        db "blocks: reading ", 0

section .bss
alignb 4
g_block_count:      resd 1
g_tex_count:        resd 1
g_tpl_count:        resd 1
g_kind:             resd 1
g_rec:              resd 1
g_fam_tpl_count:    resd 1
g_fam_mem_count:    resd 1
g_file_count:       resd 1
alignb 8
g_label:            resq 1
g_block_names:      resq MAX_BLOCK_TYPES
g_tex_names:        resq MAX_TEXTURES
g_tpl_names:        resq MAX_TEMPLATES
g_tpl_pattern:      resq MAX_TEMPLATES
g_tpl_pairs:        resq MAX_TEMPLATES * MAX_TPL_PAIRS * 2
g_fam_mem:          resq MAX_FAM_MEMBERS
g_file_names:       resq MAX_FILES
alignb 16
g_block_colors:     resd MAX_BLOCK_TYPES
g_tex_frame_ms:     resd MAX_TEXTURES
g_tpl_pair_count:   resd MAX_TEMPLATES
g_fam_tpl:          resd MAX_FAM_TEMPLATES
g_block_light:      resw MAX_BLOCK_TYPES
g_tex_glow:         resw MAX_TEXTURES
g_block_tex:        resw MAX_BLOCK_TYPES * 6
g_block_flags:      resb MAX_BLOCK_TYPES
g_tex_interp:       resb MAX_TEXTURES
alignb 16
g_block_opaque:     resb 65536
g_block_layer:      resb 65536
g_block_cullself:   resb 65536
g_subst_name:       resb SUBST_CAP
g_subst_val:        resb SUBST_CAP * 2
g_path:             resb PATH_CAP
g_rel:              resb PATH_CAP
alignb 8
g_find_data:        resb FD_SIZE

section .text

; -----------------------------------------------------------------------------
; warn — log "<current file>: <message><detail>".
;   in:  rcx = message, rdx = detail
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC warn, 0
    mov r8, rdx
    mov rdx, rcx
    mov rcx, [rel g_label]
    call cfg_warn
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; str_dup — copy a string into the permanent arena.
;   in:  rcx = string     out: rax = copy (0 if out of memory)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC str_dup, 0, rbx
    mov rbx, rcx
    call str_len
    lea rdx, [rax + 1]
    lea rcx, [rel g_arena_perm]
    INVOKE arena_alloc, rcx, rdx, 1
    test rax, rax
    jz .done
    mov rcx, rax
    mov rdx, rbx
    mov rbx, rax
    call str_copy
    mov rax, rbx
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; find_name — linear case-insensitive search in a table of char*.
;   in:  rcx = table, edx = count, r8 = name
;   out: eax = index or -1
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC find_name, 0, rbx, rsi, rdi, r12
    mov rsi, rcx
    mov edi, edx
    mov r12, r8
    xor ebx, ebx
.next:
    cmp ebx, edi
    jae .none
    INVOKE str_ieq, [rsi + rbx * 8], r12
    test eax, eax
    jnz .found
    inc ebx
    jmp .next
.found:
    mov eax, ebx
    RETURN
.none:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; block_find — id of a block by name (case-insensitive).
;   in:  rcx = name      out: eax = id, or -1 if unknown
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC block_find, 0
    mov r8, rcx
    lea rcx, [rel g_block_names]
    mov edx, [rel g_block_count]
    call find_name
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; tex_find — texture index by name.
;   in:  rcx = name      out: eax = index, or -1 if unknown
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC tex_find, 0
    mov r8, rcx
    lea rcx, [rel g_tex_names]
    mov edx, [rel g_tex_count]
    call find_name
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; tex_intern — texture index by name, created on first use.
;   in:  rcx = name      out: eax = index (0 = "missing" if the table is full)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC tex_intern, 0, rbx, rsi
    mov rsi, rcx
    call tex_find
    cmp eax, -1
    jne .done
    mov ebx, [rel g_tex_count]
    cmp ebx, MAX_TEXTURES
    jae .full
    mov rcx, rsi
    call str_dup
    test rax, rax
    jz .full
    lea rcx, [rel g_tex_names]
    mov [rcx + rbx * 8], rax
    lea rcx, [rel g_tex_frame_ms]
    mov dword [rcx + rbx * 4], 0
    lea rcx, [rel g_tex_glow]
    mov word [rcx + rbx * 2], 0
    lea rcx, [rel g_tex_interp]
    mov byte [rcx + rbx], 0
    inc dword [rel g_tex_count]
    mov eax, ebx
.done:
    RETURN
.full:
    lea rcx, [rel str_too_many]
    lea rdx, [rel k_textures]
    call warn
    xor eax, eax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; block_get — block id by name, created with defaults if new.
;   in:  rcx = name      out: eax = id, or -1 if the registry is full
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC block_get, 0, rbx, rsi
    mov rsi, rcx
    call block_find
    cmp eax, -1
    jne .done
    mov ebx, [rel g_block_count]
    cmp ebx, MAX_BLOCK_TYPES
    jae .full
    mov rcx, rsi
    call str_dup
    test rax, rax
    jz .full
    lea rcx, [rel g_block_names]
    mov [rcx + rbx * 8], rax
    lea rcx, [rel g_block_light]
    mov word [rcx + rbx * 2], 0
    lea rcx, [rel g_block_flags]
    mov byte [rcx + rbx], 0
    lea rcx, [rel g_block_layer]
    mov byte [rcx + rbx], LAYER_OPAQUE
    lea rcx, [rel g_block_tex]
    imul rax, rbx, 12
    mov dword [rcx + rax], (TEX_UNSET << 16) | TEX_UNSET
    mov dword [rcx + rax + 4], (TEX_UNSET << 16) | TEX_UNSET
    mov dword [rcx + rax + 8], (TEX_UNSET << 16) | TEX_UNSET
    inc dword [rel g_block_count]
    mov eax, ebx
.done:
    RETURN
.full:
    lea rcx, [rel str_too_many]
    lea rdx, [rel k_block]
    call warn
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; subst — copy src to dst, replacing every "{}" with member.
;   in:  rcx = dst, edx = capacity, r8 = src, r9 = member (0: copy as is)
;   clobbers: rax, rcx, rdx, r8, r10, r11
; -----------------------------------------------------------------------------
subst:
    lea r10, [rcx + rdx - 1]            ; last byte reserved for the terminator
.loop:
    mov al, [r8]
    test al, al
    jz .end
    cmp al, '{'
    jne .plain
    cmp byte [r8 + 1], '}'
    jne .plain
    test r9, r9
    jz .plain
    add r8, 2
    mov r11, r9
.member:
    mov al, [r11]
    test al, al
    jz .loop
    cmp rcx, r10
    jae .end
    mov [rcx], al
    inc rcx
    inc r11
    jmp .member
.plain:
    cmp rcx, r10
    jae .end
    mov [rcx], al
    inc rcx
    inc r8
    jmp .loop
.end:
    mov byte [rcx], 0
    ret

; -----------------------------------------------------------------------------
; parse_small — parse an unsigned number, require digits and <= max.
;   in:  rcx = text, edx = max     out: eax = value, or -1 if invalid
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC parse_small, 0, rbx
    mov ebx, edx
    call str_parse_u64
    test r8, r8
    jz .bad
    cmp rax, rbx
    ja .bad
    RETURN
.bad:
    mov eax, -1
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; set_textures — apply "face: texture, face: texture, ..." or "texture".
;   in:  ecx = block id, rdx = value (modified: tokens are terminated)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC set_textures, 0, rbx, rsi, rdi, r12, r13
    mov ebx, ecx
    mov rsi, rdx                        ; cursor
.token:
    test rsi, rsi
    jz .done
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    mov rdi, rax                        ; token
    cmp byte [rdi], 0
    je .token
    ; "face: name" or "name"
    mov r12d, 0x3F                      ; mask: all
    mov rcx, rdi
.colon:
    mov al, [rcx]
    test al, al
    jz .have_mask
    cmp al, ':'
    je .split
    inc rcx
    jmp .colon
.split:
    mov r13, rcx                        ; ':'
    mov rdx, rcx
    mov rcx, rdi
    call cfg_trim                       ; terminates the face name at ':'
    mov rdi, rax                        ; face name
    lea rcx, [r13 + 1]
    call str_len
    lea rdx, [r13 + 1 + rax]
    lea rcx, [r13 + 1]
    call cfg_trim
    mov r13, rax                        ; texture name
    xor r12d, r12d
.face_lookup:
    cmp r12d, FACE_NAME_COUNT
    jae .bad_face
    lea rax, [rel face_names]
    INVOKE str_ieq, [rax + r12 * 8], rdi
    test eax, eax
    jnz .face_found
    inc r12d
    jmp .face_lookup
.face_found:
    lea rax, [rel face_masks]
    movzx r12d, byte [rax + r12]
    mov rdi, r13
.have_mask:
    mov rcx, rdi
    call tex_intern
    ; store into every face of the mask
    lea rcx, [rel g_block_tex]
    imul rdx, rbx, 12
    add rcx, rdx
    xor edx, edx
.store:
    bt r12d, edx
    jnc .store_next
    mov [rcx + rdx * 2], ax
.store_next:
    inc edx
    cmp edx, 6
    jb .store
    jmp .token
.bad_face:
    lea rcx, [rel str_bad_face]
    mov rdx, rdi
    call warn
    jmp .token
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; block_apply — apply one setting to a block.
;   in:  ecx = block id, rdx = key, r8 = value (modifiable copy)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC block_apply, 0, rbx, rsi, rdi, r12, r13
    mov ebx, ecx
    mov rsi, rdx
    mov rdi, r8
    lea rdx, [rel k_textures]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jnz .textures
    lea rdx, [rel k_render]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jnz .render
    lea rdx, [rel k_light]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jnz .light
    lea rdx, [rel k_sway]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jnz .sway
    lea rcx, [rel str_unknown_key]
    mov rdx, rsi
    call warn
    RETURN

.textures:
    INVOKE set_textures, rbx, rdi
    RETURN

.render:
    xor r12d, r12d
    lea rdx, [rel v_opaque]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jnz .set_layer
    mov r12d, LAYER_CUTOUT
    lea rdx, [rel v_cutout]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jnz .set_layer
    mov r12d, LAYER_TRANSLUCENT
    lea rdx, [rel v_translucent]
    INVOKE str_ieq, rdi, rdx
    test eax, eax
    jz .bad
.set_layer:
    lea rax, [rel g_block_layer]
    mov [rax + rbx], r12b
    RETURN

.light:                                 ; light = r, g, b (0..15 each)
    xor r12d, r12d                      ; packed
    xor r13d, r13d                      ; channel
.light_ch:
    test rdi, rdi
    jz .bad
    mov rcx, rdi
    call cfg_next_token
    mov rdi, rdx
    mov rcx, rax
    mov edx, 15
    call parse_small
    cmp eax, -1
    je .bad
    lea ecx, [r13d * 4]
    shl eax, cl
    or r12d, eax
    inc r13d
    cmp r13d, 3
    jb .light_ch
    lea rax, [rel g_block_light]
    mov [rax + rbx * 2], r12w
    RETURN

.sway:
    mov rcx, rdi
    mov edx, 1
    call parse_small
    cmp eax, -1
    je .bad
    lea rcx, [rel g_block_flags]
    and byte [rcx + rbx], ~BLOCKF_SWAY
    or [rcx + rbx], al                  ; BLOCKF_SWAY = 1
    RETURN

.bad:
    lea rcx, [rel str_bad_value]
    mov rdx, rsi
    call warn
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; texture_apply — apply one setting of a [texture] record.
;   in:  ecx = texture index, rdx = key, r8 = value
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC texture_apply, 0, rbx, rsi, rdi
    mov ebx, ecx
    mov rsi, rdx
    mov rdi, r8
    lea rdx, [rel k_frame_ms]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jnz .frame_ms
    lea rdx, [rel k_interp]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jnz .interp
    lea rdx, [rel k_glow]
    INVOKE str_ieq, rsi, rdx
    test eax, eax
    jnz .glow
    lea rcx, [rel str_unknown_key]
    mov rdx, rsi
    call warn
    RETURN
.frame_ms:
    mov rcx, rdi
    mov edx, 60000
    call parse_small
    cmp eax, 1
    jl .bad
    lea rcx, [rel g_tex_frame_ms]
    mov [rcx + rbx * 4], eax
    RETURN
.interp:
    mov rcx, rdi
    mov edx, 1
    call parse_small
    cmp eax, -1
    je .bad
    lea rcx, [rel g_tex_interp]
    mov [rcx + rbx], al
    RETURN
.glow:
    mov rcx, rdi
    call tex_intern
    inc eax
    lea rcx, [rel g_tex_glow]
    mov [rcx + rbx * 2], ax
    RETURN
.bad:
    lea rcx, [rel str_bad_value]
    mov rdx, rsi
    call warn
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; expand_family — create the blocks of the current [family] record.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC expand_family, 0, rbx, rsi, rdi, r12, r13, r14, r15
    xor r12d, r12d                      ; member index
.member:
    cmp r12d, [rel g_fam_mem_count]
    jae .done
    lea rax, [rel g_fam_mem]
    mov r13, [rax + r12 * 8]            ; member name
    xor r14d, r14d                      ; template slot
.template:
    cmp r14d, [rel g_fam_tpl_count]
    jae .next_member
    lea rax, [rel g_fam_tpl]
    mov r15d, [rax + r14 * 4]           ; template index
    ; block name from the template's pattern
    lea rcx, [rel g_subst_name]
    lea rax, [rel g_tpl_pattern]
    mov r8, [rax + r15 * 8]
    mov edx, SUBST_CAP
    mov r9, r13
    call subst
    lea rcx, [rel g_subst_name]
    call block_get
    cmp eax, -1
    je .done                            ; registry full (warned)
    mov ebx, eax
    ; apply the template's pairs with the member substituted
    imul rsi, r15, MAX_TPL_PAIRS * 16
    lea rax, [rel g_tpl_pairs]
    add rsi, rax                        ; pair array
    lea rax, [rel g_tpl_pair_count]
    mov edi, [rax + r15 * 4]            ; pair count
.pair:
    test edi, edi
    jz .next_template
    lea rcx, [rel g_subst_val]
    mov edx, SUBST_CAP * 2
    mov r8, [rsi + 8]
    mov r9, r13
    call subst
    lea r8, [rel g_subst_val]
    INVOKE block_apply, rbx, [rsi], r8
    add rsi, 16
    dec edi
    jmp .pair
.next_template:
    inc r14d
    jmp .template
.next_member:
    inc r12d
    jmp .member
.done:
    mov dword [rel g_fam_tpl_count], 0
    mov dword [rel g_fam_mem_count], 0
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; finish_record — close the current record (expands a family).
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC finish_record, 0
    cmp dword [rel g_kind], REC_FAMILY
    jne .done
    call expand_family
.done:
    mov dword [rel g_kind], REC_NONE
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; begin_record — handle a "[kind name]" header.
;   in:  rcx = header text (modifiable)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC begin_record, 0, rbx, rsi, rdi
    mov rbx, rcx
    call finish_record
    ; split "kind name" at the first blank
    mov rcx, rbx
.find_blank:
    mov al, [rcx]
    test al, al
    jz .no_name
    cmp al, ' '
    je .split
    cmp al, 9
    je .split
    inc rcx
    jmp .find_blank
.split:
    mov byte [rcx], 0
    lea rsi, [rcx + 1]
    mov rcx, rsi
    call str_len
    lea rdx, [rsi + rax]
    mov rcx, rsi
    call cfg_trim
    mov rsi, rax                        ; name
    cmp byte [rsi], 0
    je .no_name
    lea rdx, [rel k_block]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .block
    lea rdx, [rel k_template]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .template
    lea rdx, [rel k_family]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .family
    lea rdx, [rel k_texture]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .texture
.no_name:
    lea rcx, [rel str_unknown_rec]
    mov rdx, rbx
    call warn
    RETURN

.block:
    mov rcx, rsi
    call block_get
    cmp eax, -1
    je .done
    mov [rel g_rec], eax
    mov dword [rel g_kind], REC_BLOCK
    RETURN

.template:
    lea rcx, [rel g_tpl_names]
    mov edx, [rel g_tpl_count]
    mov r8, rsi
    call find_name
    cmp eax, -1
    jne .tpl_have                       ; redefinition: start over
    mov eax, [rel g_tpl_count]
    cmp eax, MAX_TEMPLATES
    jae .tpl_full
    lea rcx, [rel g_tpl_names]
    mov [rcx + rax * 8], rsi            ; (file text stays in the perm arena)
    inc dword [rel g_tpl_count]
.tpl_have:
    lea rcx, [rel g_tpl_pair_count]
    mov dword [rcx + rax * 4], 0
    lea rcx, [rel g_tpl_pattern]
    mov qword [rcx + rax * 8], 0
    mov [rel g_rec], eax
    mov dword [rel g_kind], REC_TEMPLATE
    RETURN
.tpl_full:
    lea rcx, [rel str_too_many]
    lea rdx, [rel k_template]
    call warn
    RETURN

.family:
    mov dword [rel g_fam_tpl_count], 0
    mov dword [rel g_fam_mem_count], 0
    mov dword [rel g_kind], REC_FAMILY
    RETURN

.texture:
    mov rcx, rsi
    call tex_intern
    mov [rel g_rec], eax
    mov dword [rel g_kind], REC_TEXTURE
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; blocks_pair — cfg_parse_ex callback for block files.
;   in:  rcx = name (or header text), rdx = value (0 for a header)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC blocks_pair, 0, rbx, rsi, rdi, r12
    test rdx, rdx
    jnz .pair
    call begin_record
    RETURN
.pair:
    mov rbx, rcx                        ; key
    mov rsi, rdx                        ; value
    mov eax, [rel g_kind]
    cmp eax, REC_BLOCK
    je .block
    cmp eax, REC_TEMPLATE
    je .template
    cmp eax, REC_FAMILY
    je .family
    cmp eax, REC_TEXTURE
    je .texture
    lea rcx, [rel str_outside]
    mov rdx, rbx
    call warn
    RETURN

.block:
    INVOKE block_apply, [rel g_rec], rbx, rsi
    RETURN

.texture:
    INVOKE texture_apply, [rel g_rec], rbx, rsi
    RETURN

.template:
    mov edi, [rel g_rec]
    lea rdx, [rel k_name]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jz .tpl_pair
    lea rax, [rel g_tpl_pattern]
    mov [rax + rdi * 8], rsi
    RETURN
.tpl_pair:
    lea rax, [rel g_tpl_pair_count]
    mov ecx, [rax + rdi * 4]
    cmp ecx, MAX_TPL_PAIRS
    jae .too_many
    inc dword [rax + rdi * 4]
    imul rdx, rdi, MAX_TPL_PAIRS * 16
    shl ecx, 4
    add rdx, rcx
    lea rax, [rel g_tpl_pairs]
    mov [rax + rdx], rbx
    mov [rax + rdx + 8], rsi
    RETURN

.family:
    lea rdx, [rel k_templates]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .fam_templates
    lea rdx, [rel k_members]
    INVOKE str_ieq, rbx, rdx
    test eax, eax
    jnz .fam_members
    lea rcx, [rel str_unknown_key]
    mov rdx, rbx
    call warn
    RETURN
.fam_templates:
    test rsi, rsi
    jz .done
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    cmp byte [rax], 0
    je .fam_templates
    mov rdi, rax
    lea rcx, [rel g_tpl_names]
    mov edx, [rel g_tpl_count]
    mov r8, rdi
    call find_name
    cmp eax, -1
    je .no_template
    lea rcx, [rel g_tpl_pattern]
    cmp qword [rcx + rax * 8], 0
    je .tpl_no_name
    mov ecx, [rel g_fam_tpl_count]
    cmp ecx, MAX_FAM_TEMPLATES
    jae .too_many
    lea rdx, [rel g_fam_tpl]
    mov [rdx + rcx * 4], eax
    inc dword [rel g_fam_tpl_count]
    jmp .fam_templates
.no_template:
    lea rcx, [rel str_no_template]
    mov rdx, rdi
    call warn
    jmp .fam_templates
.tpl_no_name:
    lea rcx, [rel str_tpl_no_name]
    mov rdx, rdi
    call warn
    jmp .fam_templates
.fam_members:
    test rsi, rsi
    jz .done
    mov rcx, rsi
    call cfg_next_token
    mov rsi, rdx
    cmp byte [rax], 0
    je .fam_members
    mov ecx, [rel g_fam_mem_count]
    cmp ecx, MAX_FAM_MEMBERS
    jae .too_many
    lea rdx, [rel g_fam_mem]
    mov [rdx + rcx * 8], rax
    inc dword [rel g_fam_mem_count]
    jmp .fam_members
.too_many:
    lea rcx, [rel str_too_many]
    mov rdx, rbx
    call warn
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; load_file — parse one block file (kept in the permanent arena: templates
; point into its text).
;   in:  rcx = file name (inside data\blocks\)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC load_file, 0, rbx
    mov rbx, rcx
    mov [rel g_label], rbx
    lea rcx, [rel g_rel]
    lea rdx, [rel str_dir]
    call str_copy
    INVOKE str_copy, rax, rbx
    lea rcx, [rel g_path]
    lea rdx, [rel g_rel]
    call path_make
%if BUILD_DEBUG
    mov ecx, LOG_LEVEL_DEBUG
    call log_begin
    lea rcx, [rel str_reading]
    call log_append_str
    mov rcx, rbx
    call log_append_str
    call log_end
%endif
    lea rcx, [rel g_path]
    lea rdx, [rel g_arena_perm]
    call file_load
    test rax, rax
    jz .fail
    lea rdx, [rel blocks_pair]
    INVOKE cfg_parse_ex, rax, rdx, 0, rbx, CFG_SECTIONS
    call finish_record
    RETURN
.fail:
    LOG_WARN "blocks: could not read a block file"
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; collect_files — list data\blocks\*.blocks, sorted by name.
;   out: g_file_names / g_file_count
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC collect_files, 0, rbx, rsi, rdi, r12
    mov dword [rel g_file_count], 0
    lea rcx, [rel g_path]
    lea rdx, [rel str_pattern]
    call path_make
    lea rcx, [rel g_path]
    lea rdx, [rel g_find_data]
    API FindFirstFileA, rcx, rdx
    cmp rax, -1
    je .done
    mov rbx, rax
.entry:
    lea rax, [rel g_find_data]
    test dword [rax + FD_ATTR], FILE_ATTRIBUTE_DIRECTORY
    jnz .next
    mov ecx, [rel g_file_count]
    cmp ecx, MAX_FILES
    jae .next
    lea rcx, [rel g_find_data + FD_NAME]
    call str_dup
    test rax, rax
    jz .next
    ; insertion sort (case-insensitive byte order)
    mov esi, [rel g_file_count]         ; insert position
    lea rdi, [rel g_file_names]
.shift:
    test esi, esi
    jz .place
    mov r8, [rdi + rsi * 8 - 8]
    mov rcx, rax
    mov rdx, r8
    mov r12, rax
    call name_less
    mov rcx, rax
    mov rax, r12
    test ecx, ecx
    jz .place
    mov r8, [rdi + rsi * 8 - 8]
    mov [rdi + rsi * 8], r8
    dec esi
    jmp .shift
.place:
    mov [rdi + rsi * 8], rax
    inc dword [rel g_file_count]
.next:
    lea rdx, [rel g_find_data]
    API FindNextFileA, rbx, rdx
    test eax, eax
    jnz .entry
    API FindClose, rbx
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; name_less — case-insensitive "a < b".
;   in:  rcx = a, rdx = b      out: eax = 1 if a sorts before b
;   clobbers: rax, rcx, rdx, r8, r9
; -----------------------------------------------------------------------------
name_less:
.loop:
    movzx r8d, byte [rcx]
    movzx r9d, byte [rdx]
    lea eax, [r8 - 'A']
    cmp eax, 25
    ja .a_ok
    add r8d, 32
.a_ok:
    lea eax, [r9 - 'A']
    cmp eax, 25
    ja .b_ok
    add r9d, 32
.b_ok:
    cmp r8d, r9d
    jb .less
    ja .not_less
    test r8d, r8d
    jz .not_less
    inc rcx
    inc rdx
    jmp .loop
.less:
    mov eax, 1
    ret
.not_less:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; finalize — defaults and the mesher tables.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC finalize, 0, rbx, rsi, rdi
    mov ebx, 1
.block:
    cmp ebx, [rel g_block_count]
    jae .done
    ; faces without a texture use the texture named like the block
    lea rsi, [rel g_block_tex]
    imul rax, rbx, 12
    add rsi, rax
    xor edi, edi
.face:
    cmp word [rsi + rdi * 2], TEX_UNSET
    jne .face_next
    lea rax, [rel g_block_names]
    mov rcx, [rax + rbx * 8]
    call tex_intern
    mov [rsi + rdi * 2], ax
.face_next:
    inc edi
    cmp edi, 6
    jb .face
    ; layers
    lea rax, [rel g_block_layer]
    movzx ecx, byte [rax + rbx]
    cmp ecx, LAYER_CUTOUT
    jne .layer_ok
    cmp dword [rel g_opaque_leaves], 0
    je .layer_ok
    mov byte [rax + rbx], LAYER_OPAQUE
    xor ecx, ecx
.layer_ok:
    lea rax, [rel g_block_opaque]
    xor edx, edx
    cmp ecx, LAYER_OPAQUE
    sete dl
    mov [rax + rbx], dl
    lea rax, [rel g_block_cullself]
    xor edx, edx
    cmp ecx, LAYER_TRANSLUCENT
    sete dl
    mov [rax + rbx], dl
    inc ebx
    jmp .block
.done:
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; blocks_load — build the registry from data/blocks/*.blocks.
;   out: eax = 1 on success, 0 if no blocks were defined (logged)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC blocks_load, 0, rbx, rdi
    ; reset: air (id 0) and the built-in "missing" texture (index 0)
    lea rdi, [rel g_block_opaque]
    xor eax, eax
    mov ecx, 65536 * 3 / 8
    rep stosq                           ; opaque, layer, cullself
    lea rax, [rel g_block_opaque]
    mov byte [rax + 0xFFFF], 1          ; mesher's "solid boundary" id
    lea rax, [rel str_air]
    mov [rel g_block_names], rax
    mov dword [rel g_block_colors], 0
    mov word [rel g_block_light], 0
    mov byte [rel g_block_flags], 0
    lea rdi, [rel g_block_tex]
    xor eax, eax
    mov ecx, 3
    rep stosd
    mov dword [rel g_block_count], 1
    lea rax, [rel str_missing]
    mov [rel g_tex_names], rax
    mov dword [rel g_tex_frame_ms], 0
    mov word [rel g_tex_glow], 0
    mov byte [rel g_tex_interp], 0
    mov dword [rel g_tex_count], 1
    mov dword [rel g_tpl_count], 0
    mov dword [rel g_kind], REC_NONE

    call collect_files
    xor ebx, ebx
.file:
    cmp ebx, [rel g_file_count]
    jae .files_done
    lea rax, [rel g_file_names]
    mov rcx, [rax + rbx * 8]
    call load_file
    inc ebx
    jmp .file
.files_done:
    call finalize
    mov ecx, LOG_LEVEL_INFO
    call log_begin
    lea rcx, [rel str_loaded]
    call log_append_str
    mov ecx, [rel g_block_count]
    dec ecx
    call log_append_dec
    lea rcx, [rel str_loaded2]
    call log_append_str
    mov ecx, [rel g_tex_count]
    dec ecx
    call log_append_dec
    lea rcx, [rel str_loaded3]
    call log_append_str
    mov ecx, [rel g_file_count]
    call log_append_dec
    call log_end
    cmp dword [rel g_block_count], 1
    jbe .none
    mov eax, 1
    RETURN
.none:
    LOG_ERROR "blocks: no blocks defined (data/blocks/*.blocks)"
    xor eax, eax
    RETURN
ENDPROC
