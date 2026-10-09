; =============================================================================
; caves.inc — cave generation context (src/world/caves.asm).
; =============================================================================
%ifndef CAVES_INC
%define CAVES_INC

struc CCOL                              ; per column (x, z) of a chunk column
    .crust_top      resd 1              ; caves allowed at or below this y
    .sky            resd 1              ; float 0..1: sky-cavern mask
    .pillar         resb 1              ; 1 = natural pillar: no cavern here
    .flooded        resb 1              ; 1 = under the sea: flood to sea level
    .patch          resw 1              ; cave floor block (0 = plain)
    .ravine_depth   resd 1              ; 0 = no ravine
    .ravine_ratio   resd 1              ; float |ravine| / width
    .shaft_top      resd 1              ; shaft from top down to bottom
    .shaft_bottom   resd 1
    .water_level    resw 1              ; lake level (-32000 = none)
    .lava_level     resw 1
endstruc

struc CAVECTX
    .cx             resd 1
    .cz             resd 1
    .cx_blocks      resd 1              ; cx * 32
    .cz_blocks      resd 1
    .heights        resq 1              ; i32[34*34] surface heights
    .cols           resq 1              ; CCOL[32*32]
    .grid_c         resq 1              ; f32[9^3] cavern noise
    .grid_t         resq 1              ; f32[9^3] tunnel distance
    .y0             resd 1
    .active         resd 1              ; section may contain noise caves
    .columns_special resd 1             ; some column has a ravine or shaft
    .pad            resd 1
    .thr            resd 32             ; cavern threshold per local y
    .colc           resd 9              ; cavern noise at the grid heights
    .colt           resd 9              ;   (one block column: caves_profile)
    .cur_c          resd 1              ; values at the block being tested
    .cur_t          resd 1
    .col_special    resd 1              ; column has a ravine, shaft or sky cavern
endstruc

%ifndef CAVES_IMPL
extern caves_column, caves_grid, caves_carve, caves_finish, caves_profile, caves_survey
%endif
%endif
