; =============================================================================
; packet.inc — the message queues between the simulation (server side) and
; the client (src/core/packet.asm; DECISIONS D85).
;
; The client and the simulation never call each other: the client sends
; packets to g_to_sim, the simulation to g_to_client. Each queue is a
; single-producer single-consumer ring of fixed 64-byte packets, so a
; network transport (or a simulation thread) can replace the direct hand-off
; later without changing either side. Payloads are plain data: no pointers.
; =============================================================================
%ifndef PACKET_INC
%define PACKET_INC

%define PKT_SIZE            64
%define PKT_PAYLOAD_MAX     56
%define PKT_QUEUE_SLOTS     256         ; power of two

struc PKT
    .type       resw 1
    .size       resw 1                  ; payload bytes
    .pad        resd 1
    .data       resb PKT_PAYLOAD_MAX
endstruc

struc PKTQ
    .head       resq 8                  ; packets written (producer; own cache line)
    .tail       resq 8                  ; packets read (consumer; own cache line)
    .slots      resb PKT_QUEUE_SLOTS * PKT_SIZE
endstruc

; ---- client -> simulation -----------------------------------------------------
%define PKT_C_INPUT         1           ; INPUT_PKT: movement keys and view
%define PKT_C_TOGGLE_FLY    2           ; ask to start / stop flying (Creative)
%define PKT_C_BREAK         3           ; BLOCK_PKT: break the block at x, y, z
%define PKT_C_PLACE         4           ; BLOCK_PKT: place the selected item's block at x, y, z
%define PKT_C_SELECT        5           ; INV_PKT .slot: the hotbar slot in hand (0-8)
%define PKT_C_PICK          6           ; INV_PKT .item: a block id: bring its item to hand
%define PKT_C_INV_CLICK     7           ; INV_PKT .slot (INV_CURSOR..), .arg INVB_*
%define PKT_C_CREATIVE_SET  8           ; INV_PKT .slot, .item, .count (Creative only)

; inventory (milestone 18): slots 0-8 are the hotbar, 9-35 the inventory
struc INV_PKT
    .slot       resd 1
    .item       resd 1
    .count      resd 1
    .arg        resd 1                  ; S_SLOT: durability; C_INV_CLICK: INVB_*
endstruc
%define INV_SLOTS           36
%define INV_HOTBAR          9
%define INV_CURSOR          36          ; the stack carried by the mouse
%define INVB_RIGHT          1           ; right button: half / one
%define INVB_SHIFT          2           ; shift-click: move to the other part

struc BLOCK_PKT
    .x          resd 1                  ; i32 world block position
    .y          resd 1
    .z          resd 1
    .id         resd 1                  ; the block (place; S_BLOCK: the new block)
endstruc

struc INPUT_PKT
    .forward    resd 1                  ; f32 -1..1
    .strafe     resd 1                  ; f32 -1..1 (+ right)
    .yaw        resd 1                  ; f32 radians (0 north, + east)
    .pitch      resd 1                  ; f32 radians
    .buttons    resd 1                  ; INB_*
    .seq        resd 1
    .dig        resd 3                  ; i32 the block being dug (INB_DIG)
endstruc
%define INB_JUMP            1           ; jump / swim up / fly up / climb
%define INB_SNEAK           2           ; sneak / fly down
%define INB_SPRINT          4
%define INB_TIME_FORWARD    8           ; debug: the clock runs fast
%define INB_DIG             16          ; Survival: mining the block at .dig

; ---- simulation -> client ------------------------------------------------------
%define PKT_S_PLAYER        64          ; PLAYER_PKT, every tick
%define PKT_S_TIME          65          ; TIME_PKT, every tick
%define PKT_S_BLOCK         66          ; BLOCK_PKT: a block changed
%define PKT_S_SLOT          67          ; INV_PKT: a slot's contents (0-35, INV_CURSOR)
%define PKT_S_SELECT        68          ; INV_PKT .slot: the hotbar slot in hand
%define PKT_S_DIG           69          ; DIG_PKT: how far a block is mined
%define PKT_S_DROP          70          ; DROP_PKT: a dropped item appeared / moved
%define PKT_S_DROP_GONE     71          ; DROP_PKT .id: picked up or gone

struc DIG_PKT
    .pos        resd 3                  ; i32 block
    .progress   resd 1                  ; f32 0..1; < 0: not mining
endstruc

struc DROP_PKT
    .pos        resq 3                  ; f64 centre
    .id         resd 1                  ; slot in the simulation's drop table
    .item       resw 1
    .count      resw 1
endstruc
%define MAX_DROPS           512         ; dropped items in the world at once

struc PLAYER_PKT
    .pos        resq 3                  ; f64 feet (x, y, z); x, z = centre
    .vel        resd 3                  ; f32 blocks/s
    .eye        resd 1                  ; f32 eye height above the feet
    .flags      resd 1                  ; PF_*
    .mode       resd 1                  ; GAMEMODE_*
    .reach      resd 1                  ; f32 how far blocks can be reached
endstruc
%define PF_ON_GROUND        1
%define PF_FLYING           2
%define PF_NOCLIP           4
%define PF_IN_WATER         8
%define PF_IN_LAVA          16
%define PF_CLIMBING         32
%define PF_SNEAKING         64
%define PF_SPRINTING        128
%define PF_FROZEN           256         ; the ground is not generated yet

%define GAMEMODE_CREATIVE   1
%define GAMEMODE_SURVIVAL   2

struc TIME_PKT
    .time       resd 1                  ; f32 time of day 0..1 (0 midnight)
    .tick       resd 1                  ; u32 simulation tick
endstruc

%ifndef PACKET_IMPL
extern pkt_send, pkt_recv, g_to_sim, g_to_client
extern g_pkt_sent_sim, g_pkt_sent_client, g_pkt_dropped
%endif
%endif
