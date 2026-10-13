; =============================================================================
; containers.inc — chests' contents (src/sim/containers.asm, milestone 18).
; =============================================================================
%ifndef CONTAINERS_INC
%define CONTAINERS_INC
%define MAX_CONTAINERS  4096
%define CONT_SLOTS      27              ; per block (a double chest: two entries)
%define FURNACE_IN      0               ; a furnace's slots
%define FURNACE_FUEL    1
%define FURNACE_OUT     2

struc CONT
    .x      resd 1
    .y      resd 1
    .z      resd 1
    .used   resd 1
    .station resb 1                     ; its station + 1 (0: not known yet)
    .lit    resb 1                      ; a furnace: shown burning
    .pad    resw 1
    .burn   resd 1                      ; a furnace: fuel ticks left
    .burn_max resd 1                    ;            of this fuel item
    .cook   resd 1                      ;            progress (ticks)
    .slots  resq CONT_SLOTS             ; {u16 item, u16 count, u16 durability, u16 spare}
endstruc

%ifndef CONTAINERS_IMPL
extern cont_reset, cont_find, cont_get, cont_slots, cont_remove
extern g_conts, g_cont_count
%endif
%endif
