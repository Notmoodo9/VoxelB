; =============================================================================
; noise.inc — noise field parameters and API (src/core/noise.asm).
; =============================================================================
%ifndef NOISE_INC
%define NOISE_INC

struc NOISE
    .freq        resq 1                 ; double: 1 / scale (blocks)
    .octaves     resd 1
    .persistence resd 1                 ; float: amplitude factor per octave
    .salt        resd 1                 ; per-field seed offset
    .ridged      resd 1                 ; 1 = ridged sum
endstruc

%ifndef NOISE_IMPL
extern noise2, noise3, fbm2, fbm3
%endif
%endif
