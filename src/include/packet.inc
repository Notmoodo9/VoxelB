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
%define PKT_QUEUE_SLOTS     2048        ; power of two (up to 10 ticks of packets a frame, M20)

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
%define PKT_C_WINDOW        9           ; WIN_PKT: open (WIN_INVENTORY / WIN_USE a block) or close (WIN_NONE)
%define PKT_C_RECIPE        10          ; INV_PKT .slot: recipe to lay out in the grid, .arg INVB_SHIFT: as many as possible
%define PKT_C_SWAP_HANDS    11          ; the main and the off hand trade items (no payload)
%define PKT_C_INV_DRAG      12          ; DRAG_PKT: a stack spread over slots (Shift+drag / right-drag)
%define PKT_C_ATTACK        13          ; ENT_PKT .id: hit an animal (milestone 19)
%define PKT_C_INTERACT      14          ; ENT_PKT .id: use the item in hand on an animal (feed it)
%define PKT_C_USE           15          ; use the item in hand on what is looked at (a bucket scoops; part 3b)
%define PKT_C_TIE           16          ; BLOCK_PKT: tie the animals the player leads to this fence
%define PKT_C_NAME          17          ; NAME_PKT: the name tag in hand names this animal
%define PKT_C_RESPAWN       18          ; a dead player comes back (milestone 20; no payload)
%define PKT_C_SPECTATE      19          ; a dead Hardcore player watches on as a spectator (no payload)

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
; the open window's slots (milestone 18 part 3): the crafting grid (3 x 3,
; row by row; a 2 x 2 grid uses its top-left cells), the crafting result,
; then a container (a chest: 27, a double chest 54)
%define INV_GRID            37
%define INV_RESULT          46
%define INV_CONTAINER       47
%define INV_CONTAINER_MAX   54
%define INV_OFFHAND         (INV_CONTAINER + INV_CONTAINER_MAX) ; 101: the off hand (part 5)
%define INV_ALL             (INV_OFFHAND + 1) ; 102
%define INV_SAVED           46          ; player.dat keeps 0..45 (a grid left
                                        ; full when the game quits comes back)

; PKT_C_INV_DRAG: the carried stack spread over slots
struc DRAG_PKT
    .mode       resd 1                  ; DRAG_EVEN: split evenly; DRAG_ONE: one each
    .count      resd 1                  ; slots
    .slots      resb 48                 ; slot numbers
endstruc
%define DRAG_EVEN           0
%define DRAG_ONE            1
%define DRAG_MAX            48

; windows: what the inventory screen shows besides the player's slots
%define WIN_NONE            0           ; (C_WINDOW: close)
%define WIN_INVENTORY       1           ; E: 2 x 2 crafting by hand
%define WIN_CRAFTING        2           ; a crafting station (S_WINDOW .grid 3)
%define WIN_CHEST           3           ; a container (S_WINDOW .slots)
%define WIN_FURNACE         4           ; a furnace: input, fuel, output (container slots 0-2)
%define WIN_USE             15          ; C_WINDOW: use the block at .pos
struc WIN_PKT
    .kind       resd 1                  ; WIN_*
    .pos        resd 3                  ; i32 the block (WIN_USE, S_WINDOW)
    .grid       resd 1                  ; S_WINDOW: grid width 0 / 2 / 3
    .slots      resd 1                  ; S_WINDOW: container slots
    .station    resd 1                  ; S_WINDOW: station (recipes; 0 by hand)
endstruc

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
%define INB_USE             32          ; the use button held (eating; milestone 20)

; ---- simulation -> client ------------------------------------------------------
%define PKT_S_PLAYER        64          ; PLAYER_PKT, every tick
%define PKT_S_TIME          65          ; TIME_PKT, every tick
%define PKT_S_BLOCK         66          ; BLOCK_PKT: a block changed
%define PKT_S_SLOT          67          ; INV_PKT: a slot's contents (0 .. INV_ALL - 1)
%define PKT_S_SELECT        68          ; INV_PKT .slot: the hotbar slot in hand
%define PKT_S_DIG           69          ; DIG_PKT: how far a block is mined
%define PKT_S_DROP          70          ; DROP_PKT: a dropped item appeared / moved
%define PKT_S_DROP_GONE     71          ; DROP_PKT .id: picked up or gone
%define PKT_S_WINDOW        72          ; WIN_PKT: the window opened / closed (WIN_NONE)
%define PKT_S_FURNACE       73          ; FURNACE_PKT: the open furnace's progress (every tick)
%define PKT_S_ENTITY        74          ; ENT_PKT: an animal appeared / moved / changed (milestone 19)
%define PKT_S_ENTITY_GONE   75          ; ENT_PKT .id: out of sight, dead or unloaded
%define PKT_S_ENTITY_NAME   76          ; NAME_PKT: an animal's name tag (after its PKT_S_ENTITY)
%define PKT_S_SURVIVAL      77          ; SURV_PKT: health, hunger, air ... every tick (milestone 20)
%define PKT_S_GRAVE         78          ; GRAVE_PKT: a gravestone appeared / was emptied (milestone 20)

; a gravestone (milestone 20 part 2): the client keeps a list by .index
struc GRAVE_PKT
    .index      resw 1                  ; 0 .. MAX_GRAVES - 1
    .used       resw 1                  ; 0: emptied (gone)
    .pos        resd 3                  ; i32 its block
    .day        resd 1                  ; the day its owner died
    .name       resb 24                 ; whose (zero-terminated; ENT_NAME_MAX)
endstruc
%define MAX_GRAVES          64

; the player's survival state (milestone 20)
struc SURV_PKT
    .health     resw 1                  ; points (20 = 10 hearts)
    .hunger     resw 1
    .sat        resd 1                  ; f32 saturation
    .air        resw 1                  ; ticks of air left
    .air_max    resw 1
    .flags      resw 1                  ; SVF_*
    .hurt       resw 1                  ; hits taken so far (a change: flash)
    .cause      resw 1                  ; CAUSE_* of the last damage
    .cause_mob  resw 1                  ; the animal (CAUSE_RAM)
    .eat        resw 1                  ; ticks into eating (0: not eating)
    .eat_total  resw 1                  ; ticks the food takes
    .death      resd 3                  ; i32 where the player died
    .day        resd 1                  ; the day (from 1; part 2)
    .grave      resd 3                  ; i32 the gravestone with the items (SVF_GRAVE)
endstruc
%define SVF_POISON          1           ; food poisoning
%define SVF_BURNING         2
%define SVF_DEAD            4
%define SVF_ACTIVE          8           ; Survival / Adventure (health and hunger shown)
%define SVF_GRAVE           16          ; the items wait in a gravestone (.grave)
%define SVF_KEPT            32          ; the player kept the items (keep inventory)
%define SVF_SPECTATE        64          ; a Hardcore death: only spectating is left
%define CAUSE_NONE          0
%define CAUSE_FALL          1
%define CAUSE_DROWN         2
%define CAUSE_LAVA          3
%define CAUSE_FIRE          4
%define CAUSE_SUFFOCATE     5
%define CAUSE_CACTUS        6
%define CAUSE_VOID          7
%define CAUSE_RAM           8
%define CAUSE_STARVE        9
%define CAUSE_COUNT         10

; an animal's name (milestone 19 part 3b): both ways
%define ENT_NAME_MAX        24          ; 23 characters + 0
struc NAME_PKT
    .id         resd 1
    .name       resb ENT_NAME_MAX       ; zero-terminated
endstruc
; animals (milestone 19): the simulation's entity table slot is the id
struc ENT_PKT
    .pos        resq 3                  ; f64 feet centre
    .id         resd 1
    .yaw        resd 1                  ; f32 body (radians, 0 north, + east)
    .head_yaw   resd 1                  ; f32 the head, from the body
    .head_pitch resd 1                  ; f32 + up
    .variant    resw 1
    .flags      resw 1                  ; EPF_*
    .knot       resd 3                  ; i32: the fence it is tied to (EPF_KNOT; part 3b)
endstruc
%define EPF_BABY            1
%define EPF_HURT            2           ; flashes red
%define EPF_DYING           4           ; falls over
%define EPF_WATER           8           ; swimming
%define EPF_SLEEP           16          ; lying down (part 2)
%define EPF_LOVE            32          ; fed, looking for a mate (part 2)
%define EPF_AIR             64          ; off the ground (wings flap; part 3)
%define EPF_SHEARED         128         ; its coat was shorn (part 3)
%define EPF_MALE            256         ; a male: antler parts shown (part 3b)
%define EPF_LEASH           512         ; on a lead the player holds (part 3b)
%define EPF_KNOT            1024        ; on a lead tied to a fence (.knot)
%define MAX_ENTITIES        8192

struc FURNACE_PKT
    .cook       resd 1                  ; f32 0..1: the item being smelted
    .burn       resd 1                  ; f32 0..1: fuel left (0: not burning)
endstruc

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
%define GAMEMODE_SPECTATOR  3           ; (milestone 20: a Hardcore world after its death)

struc TIME_PKT
    .time       resd 1                  ; f32 time of day 0..1 (0 midnight)
    .tick       resd 1                  ; u32 simulation tick
endstruc

%ifndef PACKET_IMPL
extern pkt_send, pkt_recv, g_to_sim, g_to_client
extern g_pkt_sent_sim, g_pkt_sent_client, g_pkt_dropped
%endif
%endif
