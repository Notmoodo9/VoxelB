; =============================================================================
; terrain.inc — terrain generator interface (src/world/terrain.asm).
; =============================================================================
%ifndef TERRAIN_INC
%define TERRAIN_INC

struc TSAMPLE                           ; terrain_sample output (floats)
    .fields     resd 11                 ; noise fields (continentalness, ...)
    .height     resd 1                  ; surface height (first air block)
    .land       resd 1                  ; 0 ocean .. 1 inland
    .mount      resd 1                  ; mountain factor
    .extra      resd 1                  ; hills + rolling (internal)
    .giant      resd 1                  ; giant-range mask 0..1
    .river      resd 1                  ; river distance (< 0: in the river)
    .overhang   resd 1                  ; overhang amplitude (blocks)
endstruc

%endif
