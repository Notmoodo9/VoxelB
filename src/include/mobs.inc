; =============================================================================
; mobs.inc — the data-driven animal registry (src/world/mobs.asm, milestone
; 19, design/mobs/passive_animals.md, DATA_FORMAT.md "Mob files").
; =============================================================================
%ifndef MOBS_INC
%define MOBS_INC

%define MAX_MODELS      64
%define MAX_PARTS       1024            ; all models together
%define MAX_MODEL_PARTS 32
%define MAX_MOBS        64
%define MAX_VARIANTS    256
%define MAX_SPAWNS      256
%define MAX_MOB_DROPS   4
%define SKIN_PX         64              ; every skin is 64 x 64 (one texture array)

; part motions
%define MOTION_NONE     0
%define MOTION_HEAD     1               ; turns with the head's look
%define MOTION_LEG0     2               ; walking: swings forward first
%define MOTION_LEG1     3               ; walking: swings back first
%define MOTION_TAIL     4               ; sways

; tempers
%define TEMPER_CALM     0               ; wanders, runs when hurt
%define TEMPER_WILD     1               ; also runs when the player comes close

; a box of a model, in pixels (16 = a block); the model faces north (-Z)
struc MPART
    .pivot      resd 3                  ; f32 where it turns, from the feet centre
    .box        resd 3                  ; f32 the box's low corner, from the pivot
    .size       resd 3                  ; f32 (whole pixels)
    .u          resw 1                  ; skin position (pixels)
    .v          resw 1
    .motion     resd 1                  ; MOTION_*
    .pad        resd 1
endstruc                                ; 48 bytes

struc MODEL
    .name       resq 1
    .first      resd 1                  ; first MPART
    .count      resd 1
endstruc

struc MOB
    .name       resq 1
    .title      resq 1
    .health     resd 1                  ; hit points
    .width      resd 1                  ; f32 blocks (the body is square)
    .height     resd 1                  ; f32 blocks
    .speed      resd 1                  ; f32 walking speed, blocks per second
    .temper     resd 1                  ; TEMPER_*
    .first_var  resd 1                  ; its variants
    .var_count  resd 1
    .drops      resd 1
    .drop_item  resw MAX_MOB_DROPS
    .drop_min   resb MAX_MOB_DROPS
    .drop_max   resb MAX_MOB_DROPS
endstruc

struc VARIANT
    .name       resq 1
    .skin       resq 1                  ; texture name (assets/textures/mobs/<skin>.png)
    .mob        resd 1
    .model      resd 1
endstruc

struc SPAWN
    .biomes     resd 1                  ; bit per biome index
    .variant    resd 1
    .chance     resd 1                  ; f32: % of the biome's columns with a herd
    .herd_min   resd 1
    .herd_max   resd 1
endstruc

%ifndef MOBS_IMPL
extern mobs_load
extern g_models, g_model_count, g_parts, g_part_count
extern g_mobs, g_mob_count, g_variants, g_variant_count, g_spawns, g_spawn_count
%endif
%endif
