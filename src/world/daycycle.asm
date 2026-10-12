; =============================================================================
; daycycle.asm — the time of day and the sun's direction (milestone 14).
;
; The day lasts day_length minutes (data/world/world.cfg) and starts at
; start_time (hours, 0..24; the command line's --time overrides it). The
; clock runs in the simulation (sim.asm, milestone 16; time_forward runs it
; 240 times faster); the client sets the time it was sent. The sun rises in the
; east (+X) at 6:00, stands highest at 12:00 (tilted 25 degrees towards +Z),
; and sets in the west at 18:00; the moon is opposite it.
;
; Public API:
;   daycycle_init()         after world.cfg is read
;   daycycle_set(xmm0 = t)  the client's time of day (0..1) -> sun
;   g_time_of_day           f32 0..1 (0 midnight, 0.5 noon)
;   g_sun_dir               f32 x, y, z (unit, towards the sun)
;   g_day_length, g_start_hour   f32 settings (world.cfg)
;   g_time_override         f32 start hour from --time, or -1
;   g_cloud_cover, g_cloud_height   f32 cloud layer settings (world.cfg; the
;                           sky's state lives here until weather, M25)
; =============================================================================
%include "macros.inc"
%include "log.inc"

global daycycle_init, daycycle_set
global g_time_of_day, g_sun_dir, g_day_length, g_start_hour, g_time_override
global g_cloud_cover, g_cloud_height

section .rdata
align 4
c_two_pi:       dd 6.28318530718
c_quarter:      dd 0.25
c_24:           dd 24.0
c_cos_tilt:     dd 0.906307787              ; cos 25 degrees
c_sin_tilt:     dd 0.422618262              ; sin 25 degrees

section .data
align 4
g_day_length:       dd 20.0             ; minutes per day
g_start_hour:       dd 8.0
g_time_override:    dd -1.0
g_cloud_cover:      dd 0.45             ; share of the sky (world.cfg)
g_cloud_height:     dd 230.0            ; bottom of the cloud layer (world y)

section .bss
alignb 16
g_sun_dir:          resd 4
g_time_of_day:      resd 1
g_dc_tmp:           resd 2

section .text

; -----------------------------------------------------------------------------
; daycycle_init — the clock at the start hour.
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC daycycle_init, 0
    movss xmm0, [rel g_start_hour]
    xorps xmm1, xmm1
    comiss xmm1, [rel g_time_override]
    ja .no_override
    movss xmm0, [rel g_time_override]
.no_override:
    divss xmm0, [rel c_24]
    call wrap_time
    movss [rel g_time_of_day], xmm0
    call sun_from_time
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; daycycle_set — the client's time of day (from the simulation's packets,
; interpolated between ticks), and the sun's direction for it.
;   in:  xmm0 = time of day (f32, wrapped to 0..1)
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC daycycle_set, 0
    call wrap_time
    movss [rel g_time_of_day], xmm0
    call sun_from_time
    RETURN
ENDPROC

; wrap_time: xmm0 = frac(xmm0)   clobbers xmm1
wrap_time:
    roundss xmm1, xmm0, 9               ; floor
    subss xmm0, xmm1
    ret

; sun_from_time: g_sun_dir from g_time_of_day   clobbers rax, xmm0, x87
sun_from_time:
    movss xmm0, [rel g_time_of_day]
    subss xmm0, [rel c_quarter]
    mulss xmm0, [rel c_two_pi]          ; 0 at sunrise
    movss [rel g_dc_tmp], xmm0
    fld dword [rel g_dc_tmp]
    fsincos                             ; st0 = cos, st1 = sin
    fstp dword [rel g_dc_tmp]           ; cos
    fstp dword [rel g_dc_tmp + 4]       ; sin
    movss xmm0, [rel g_dc_tmp]
    movss [rel g_sun_dir], xmm0         ; x: east at sunrise
    movss xmm0, [rel g_dc_tmp + 4]
    mulss xmm0, [rel c_cos_tilt]
    movss [rel g_sun_dir + 4], xmm0     ; y: height
    movss xmm0, [rel g_dc_tmp + 4]
    mulss xmm0, [rel c_sin_tilt]
    movss [rel g_sun_dir + 8], xmm0     ; z: the tilt of the sun's path
    mov dword [rel g_sun_dir + 12], 0
    ret
