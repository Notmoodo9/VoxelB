; =============================================================================
; menu.inc — what the menus ask the game to do (src/ui/menu.asm -> game.asm).
; =============================================================================
%ifndef MENU_INC
%define MENU_INC
%define MA_NONE         0
%define MA_QUIT         1               ; leave the game (from the main menu)
%define MA_RESUME       2               ; close the pause menu
%define MA_PLAY         3               ; rdx = world name: load it
%define MA_CREATE       4               ; rdx = name, r8d = seed: a new world
%define MA_TO_MENU      5               ; save and go to the main menu
%define MA_SAVE_QUIT    6               ; save and leave the game

%define SCREEN_MAIN     0
%define SCREEN_WORLDS   1
%define SCREEN_CREDITS  2
%define SCREEN_PAUSE    3
%endif
