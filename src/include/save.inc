; =============================================================================
; save.inc — world metadata shared by save.asm, the menus and game.asm
; (milestone 17).
; =============================================================================
%ifndef SAVE_INC
%define SAVE_INC

; game modes (world.dat game_mode = creative / survival / adventure / spectator)
%define MODE_CREATIVE       0
%define MODE_SURVIVAL       1
%define MODE_ADVENTURE      2
%define MODE_SPECTATOR      3
%define MODE_COUNT          4

; difficulties (world.dat difficulty = peaceful / normal / hard / extreme / ultra)
%define DIFF_PEACEFUL       0
%define DIFF_NORMAL         1
%define DIFF_HARD           2
%define DIFF_EXTREME        3
%define DIFF_ULTRA          4
%define DIFF_COUNT          5

; what the world list shows about a saved world (save_peek + menu.asm)
struc WORLD_INFO
    .name       resb 64                 ; the folder name
    .played     resb 24                 ; last_played "YYYY-MM-DD HH:MM" or ""
    .mode       resd 1
    .difficulty resd 1
    .hardcore   resd 1
    .thumb      resd 1                  ; 1 + atlas slot, 0 = no picture
    .size       resq 1                  ; bytes on disk
    .seed       resd 1
    .pad        resb 12
endstruc
%endif
