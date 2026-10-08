; =============================================================================
; timing.asm — high-resolution frame timer and rolling performance stats.
;
; Stats are gathered over windows of STATS_WINDOW_US; when a window closes,
; timer_frame returns 1 and the g_stat_* values hold that window's results.
;
; Public API:
;   timer_init()            start the clock
;   timer_frame() -> eax    call once per presented frame; 1 = new stats
;   timer_reset()           restart frame timing after idle (no dt spike)
;   g_frame_us              last frame time (microseconds)
;   g_total_frames          frames since timer_init
;   g_stat_fps_x10          frames per second * 10 (last window)
;   g_stat_avg_us / g_stat_min_us / g_stat_max_us   frame times (last window)
;   timer_elapsed_us() -> rax   microseconds since timer_init
; =============================================================================
%include "macros.inc"

global timer_init, timer_frame, timer_reset, timer_elapsed_us
global g_frame_us, g_total_frames
global g_stat_fps_x10, g_stat_avg_us, g_stat_min_us, g_stat_max_us

IMPORT QueryPerformanceFrequency, QueryPerformanceCounter

%define STATS_WINDOW_US     500000

section .bss
alignb 8
g_qpf:              resq 1
g_t_start:          resq 1
g_t_last:           resq 1
g_frame_us:         resq 1
g_total_frames:     resq 1
g_win_frames:       resq 1
g_win_us:           resq 1
g_win_min:          resq 1
g_win_max:          resq 1
g_stat_fps_x10:     resq 1
g_stat_avg_us:      resq 1
g_stat_min_us:      resq 1
g_stat_max_us:      resq 1

section .text

; -----------------------------------------------------------------------------
; ticks_to_us — convert a QPC tick count to microseconds.
;   in:  rax = ticks
;   out: rax = microseconds
;   clobbers: rax, rcx, rdx
; -----------------------------------------------------------------------------
ticks_to_us:
    mov rcx, 1000000
    mul rcx
    div qword [rel g_qpf]
    ret

; -----------------------------------------------------------------------------
; timer_init — start the clock and clear all statistics.
;   in/out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC timer_init, 0
    lea rcx, [rel g_qpf]
    API QueryPerformanceFrequency, rcx
    lea rcx, [rel g_t_start]
    API QueryPerformanceCounter, rcx
    mov rax, [rel g_t_start]
    mov [rel g_t_last], rax
    xor eax, eax
    mov [rel g_frame_us], rax
    mov [rel g_total_frames], rax
    mov [rel g_win_frames], rax
    mov [rel g_win_us], rax
    mov [rel g_win_max], rax
    mov [rel g_stat_fps_x10], rax
    mov [rel g_stat_avg_us], rax
    mov [rel g_stat_min_us], rax
    mov [rel g_stat_max_us], rax
    dec rax
    mov [rel g_win_min], rax
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; timer_reset — make the next frame's dt start now (use after idling).
;   in/out: none
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC timer_reset, 0
    lea rcx, [rel g_t_last]
    API QueryPerformanceCounter, rcx
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; timer_elapsed_us — microseconds since timer_init.
;   in:  none
;   out: rax = microseconds
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC timer_elapsed_us, 16
    lea rcx, [LOCAL(0)]
    API QueryPerformanceCounter, rcx
    mov rax, [LOCAL(0)]
    sub rax, [rel g_t_start]
    call ticks_to_us
    RETURN
ENDPROC

; -----------------------------------------------------------------------------
; timer_frame — record one frame.
;   in:  none
;   out: eax = 1 if a stats window just closed (g_stat_* updated), else 0
;   clobbers: volatile registers
; -----------------------------------------------------------------------------
PROC timer_frame, 16
    lea rcx, [LOCAL(0)]
    API QueryPerformanceCounter, rcx
    mov rax, [LOCAL(0)]
    mov rdx, [rel g_t_last]
    mov [rel g_t_last], rax
    sub rax, rdx                        ; ticks since last frame
    call ticks_to_us
    mov [rel g_frame_us], rax
    inc qword [rel g_total_frames]
    inc qword [rel g_win_frames]
    add [rel g_win_us], rax
    cmp rax, [rel g_win_min]
    jae .not_min
    mov [rel g_win_min], rax
.not_min:
    cmp rax, [rel g_win_max]
    jbe .not_max
    mov [rel g_win_max], rax
.not_max:
    mov rcx, [rel g_win_us]
    cmp rcx, STATS_WINDOW_US
    jae .publish
    xor eax, eax
    RETURN
.publish:
    ; fps*10 = frames * 10e6 / window_us ; avg = window_us / frames
    mov rax, [rel g_win_frames]
    imul rax, rax, 10000000
    xor edx, edx
    div rcx
    mov [rel g_stat_fps_x10], rax
    mov rax, rcx
    xor edx, edx
    div qword [rel g_win_frames]
    mov [rel g_stat_avg_us], rax
    mov rax, [rel g_win_min]
    mov [rel g_stat_min_us], rax
    mov rax, [rel g_win_max]
    mov [rel g_stat_max_us], rax
    xor eax, eax
    mov [rel g_win_frames], rax
    mov [rel g_win_us], rax
    mov [rel g_win_max], rax
    dec rax
    mov [rel g_win_min], rax
    mov eax, 1
    RETURN
ENDPROC
