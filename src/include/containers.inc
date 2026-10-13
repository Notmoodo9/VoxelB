; =============================================================================
; containers.inc — chests' contents (src/sim/containers.asm, milestone 18).
; =============================================================================
%ifndef CONTAINERS_INC
%define CONTAINERS_INC
%define MAX_CONTAINERS  4096
%define CONT_SLOTS      27              ; per block (a double chest: two entries)

struc CONT
    .x      resd 1
    .y      resd 1
    .z      resd 1
    .used   resd 1
    .slots  resq CONT_SLOTS             ; {u16 item, u16 count, u16 durability, u16 spare}
endstruc

%ifndef CONTAINERS_IMPL
extern cont_reset, cont_find, cont_get, cont_slots, cont_remove
extern g_conts, g_cont_count
%endif
%endif
