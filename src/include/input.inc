; =============================================================================
; input.inc — input actions and interface (implementation: src/platform/input.asm).
;
; Actions are what the game asks about ("is move_forward down?"). Keys are
; bound to actions in data/config/controls.cfg (up to 2 keys per action); the
; names in that file are the strings in input.asm's action_name_table, in the
; same order as these IDs.
; =============================================================================
%ifndef INPUT_INC
%define INPUT_INC

%define ACT_MOVE_FORWARD        0
%define ACT_MOVE_BACK           1
%define ACT_MOVE_LEFT           2
%define ACT_MOVE_RIGHT          3
%define ACT_MOVE_UP             4
%define ACT_MOVE_DOWN           5
%define ACT_SPRINT              6
%define ACT_TOGGLE_OVERLAY      7
%define ACT_TOGGLE_VSYNC        8
%define ACT_RELOAD_SHADERS      9
%define ACT_MENU                10      ; Esc: release the mouse, or quit if free
%define ACT_COUNT               11
%define BINDS_PER_ACTION        2

%define VK_LBUTTON              0x01
%define VK_RBUTTON              0x02
%define VK_MBUTTON              0x04

%ifndef INPUT_IMPL
extern input_init, input_load_bindings, input_new_frame
extern input_on_key, input_on_raw_input, input_on_focus_lost
extern input_down, input_pressed, input_vk_pressed
extern input_set_capture, input_update_capture, input_key_name, input_action_name
extern g_mouse_dx, g_mouse_dy, g_mouse_captured, g_bindings
extern g_mouse_sensitivity, g_invert_mouse_y, g_fly_speed, g_fly_sprint_mult
%endif

%endif
