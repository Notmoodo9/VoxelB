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
%define PKT_C_PLACE         4           ; BLOCK_PKT: place id at x, y, z

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
endstruc
%define INB_JUMP            1           ; jump / swim up / fly up / climb
%define INB_SNEAK           2           ; sneak / fly down
%define INB_SPRINT          4
%define INB_TIME_FORWARD    8           ; debug: the clock runs fast

; ---- simulation -> client ------------------------------------------------------
%define PKT_S_PLAYER        64          ; PLAYER_PKT, every tick
%define PKT_S_TIME          65          ; TIME_PKT, every tick
%define PKT_S_BLOCK         66          ; BLOCK_PKT: a block changed

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

struc TIME_PKT
    .time       resd 1                  ; f32 time of day 0..1 (0 midnight)
    .tick       resd 1                  ; u32 simulation tick
endstruc

%ifndef PACKET_IMPL
extern pkt_send, pkt_recv, g_to_sim, g_to_client
extern g_pkt_sent_sim, g_pkt_sent_client, g_pkt_dropped
%endif
%endif
