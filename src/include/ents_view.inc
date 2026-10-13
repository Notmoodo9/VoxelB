; =============================================================================
; ents_view.inc — the client's view of the animals (src/client/ents_view.asm),
; drawn by src/render/mob_render.asm. Milestone 19.
; =============================================================================
%ifndef ENTS_VIEW_INC
%define ENTS_VIEW_INC

struc VENT
    .target     resq 3                  ; f64 latest position (feet centre)
    .shown      resq 3                  ; f64 drawn position (glides to the target)
    .yaw_t      resd 1                  ; f32 latest body yaw
    .yaw        resd 1                  ; f32 drawn
    .head_t     resd 1                  ; f32 head yaw (from the body)
    .head       resd 1
    .pitch_t    resd 1                  ; f32 head pitch
    .pitch      resd 1
    .phase      resd 1                  ; f32 walking: leg phase (radians)
    .amp        resd 1                  ; f32 walking: 0 standing .. 1 striding
    .roll       resd 1                  ; f32 dying: tipped over 0 .. pi/2
    .sky        resd 1                  ; f32 open sky above 0 .. 1
    .hurt       resd 1                  ; f32 red tint 0 .. 1
    .variant    resw 1
    .flags      resw 1                  ; EPF_*
    .active     resd 1
    .sky_wait   resd 1                  ; frames until the sky is looked at again
    .sleep      resd 1                  ; f32 lying down 0 .. 1 (part 2)
    .pad        resb 20
endstruc                                ; 128 bytes

%ifndef ENTS_VIEW_IMPL
extern ents_view_reset, ents_view_packet, ents_view_update, ents_pick
extern g_vents, g_ents_shown, g_ent_target, g_vlist
%endif
%endif
