; =============================================================================
; entity.inc — the simulation's animals (src/sim/entities.asm, the table and
; their life; src/sim/ent_store.asm, regions on disk and spawning).
; Milestone 19, design/mobs/passive_animals.md, DECISIONS D98.
; =============================================================================
%ifndef ENTITY_INC
%define ENTITY_INC

%define SIM_RADIUS      128             ; blocks: animals this close live and are seen
%define POP_RADIUS      6               ; chunk columns: herds are placed this close
%define EREGION_SHIFT   10              ; an entity region is 32 x 32 columns (1024 blocks)
%define MAX_EREGIONS    64

; EntT.flags
%define EF_ACTIVE       1
%define EF_BABY         2
%define EF_GROUND       4
%define EF_WATER        8
%define EF_SENT         16              ; the client knows it
%define EF_DIRTY        32              ; send it this tick
%define EF_DYING        64
%define EF_AWAKE        128             ; within SIM_RADIUS this tick
%define EF_BUMPED       256             ; walked into something last tick
%define EF_SLEEP        512             ; lying down for the night
%define EF_SHEARED      1024            ; part 3: its coat was shorn (saved)
%define EF_MALE         2048            ; part 3b: a male (bucks: antlers; saved)

; AI states
%define AI_IDLE         0
%define AI_WANDER       1
%define AI_FLEE         2
%define AI_FOLLOW       3               ; after a player holding its food
%define AI_SEEK         4               ; to a mate, its mother or its herd
%define AI_GRAZE        5               ; eating grass
%define AI_SLEEP        6
%define AI_CHARGE       7               ; part 3: a fierce animal after the player
%define AI_EAT          8               ; part 3b: to a block it eats (a flower), then eats it

%define PATH_MAX        16              ; waypoints kept (pathfind.asm)
%define WP_BYTES        12              ; i32 x, y, z
%define GROW_TICKS      24000           ; babies grow up in 20 minutes
%define LOVE_TICKS      600             ; fed: looks for a mate for 30 s
%define BREED_COOLDOWN  6000            ; 5 minutes between babies

%define LEASH_NONE      0
%define LEASH_PLAYER    1               ; held by the player
%define LEASH_KNOT      2               ; tied to a fence post (EntT.knot)
%define NAME_MAX        ENT_NAME_MAX    ; a name tag: 23 characters + 0 (packet.inc)

struc EntT
    .pos        resq 3                  ; f64 feet centre
    .vel        resq 3                  ; f64 blocks per tick
    .goal       resq 2                  ; f64 x, z: where its path leads
    .yaw        resd 1                  ; f32 body
    .head_yaw   resd 1                  ; f32 from the body
    .head_pitch resd 1
    .look_yaw   resd 1                  ; what the head turns towards
    .look_pitch resd 1
    .flags      resd 1                  ; EF_*
    .variant    resw 1
    .mob        resw 1
    .health     resw 1
    .hurt       resw 1                  ; ticks left of the red flash
    .timer      resw 1                  ; ticks left in this AI state
    .state      resb 1                  ; AI_*
    .death      resb 1                  ; ticks since it died
    .stuck      resw 1                  ; ticks without getting closer
    .region     resw 1                  ; entity region slot
    .age        resd 1                  ; ticks lived (babies grow up)
    .best       resd 1                  ; f32 closest it got to the waypoint
    .herd       resd 1                  ; herd id (0: none; saved)
    .target     resd 1                  ; an animal it goes to (mate, mother), -1
    .love       resw 1                  ; ticks left wanting a mate
    .cooldown   resw 1                  ; ticks before it can breed again
    .repath     resw 1                  ; ticks before the path is worked out again
    .path_len   resb 1
    .path_i     resb 1                  ; the next waypoint
    .lay        resd 1                  ; part 3: ticks until it lays (0: not counting yet)
    .food       resd 3                  ; part 3b: the block it goes to eat (i32 x, y, z)
    .leash      resd 1                  ; part 3b: LEASH_* (on a lead: who holds it)
    .knot       resd 3                  ; the fence it is tied to (i32 x, y, z)
    .name       resb NAME_MAX           ; its name tag (0-terminated; empty: none)
    .pad        resb 16
endstruc                                ; 192 bytes

; an entity region: 32 x 32 columns, saved as overworld\entities\e.<rx>.<rz>.vxe
struc EREG
    .rx         resd 1
    .rz         resd 1
    .used       resd 1
    .count      resd 1                  ; animals in it
    .pop        resb 128                ; bit per column: herds placed already
endstruc

%ifndef ENTITIES_IMPL
extern ents_reset, ents_tick, ents_hit, ent_new, ent_remove, g_ents, g_ent_count
extern g_ent_awake, g_ent_tick_us, g_ent_sent, g_paths, ent_send_name
%endif
%ifndef BEHAVE_IMPL
extern behave_reset, behave_tick, behave, behave_hurt, behave_interact
extern lead_tie, lead_drop, g_lead_item, behave_name
extern g_herd_count, g_regrow_count
%endif
%ifndef ENT_STORE_IMPL
extern store_reset, store_open, store_update, store_save_all, store_region_of
extern g_eregs, g_store_pop_us, g_store_pop_count
%endif
%endif
