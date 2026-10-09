# Progress

## Current state
**Milestone 5: Chunk/section data structures (palette compression), flat
test world, mesher, render: DONE** (pending green Windows CI)

Next: **Milestone 6: Infinite streaming: load/unload around the player on
worker threads, no stutter.**

---

## Milestone 5 — done (2026-10-09)

### What was built
* **Sections** (`src/world/section.asm`, D27): 32³ palette-compressed
  storage: uniform (no data), 1/2/4/8-bit palette, or raw 16-bit. Build from
  an array, get, set (with palette growth), decode, and free. All storage
  comes from lock-free pools.
* **World** (`src/world/world.asm`): a column hash map, and a fixed test
  world of (2·radius)² columns × 40 sections (Y −256…1023). Generation and
  meshing run as parallel jobs (`job_dispatch`), with timing stats.
  `world_block_at` and `world_section_at` queries.
* **Debug test world** (`data/world/flat_test.cfg`, D30): placeholder
  `debug_*` blocks with flat colours, layers stone/dirt/grass (surface at
  y 100), radius 12 chunks (768 × 768 blocks), and debug hills and pillars
  that cross section borders. **Not game content**: the real blocks come
  from the M7 design interview.
* **Greedy mesher** (`src/render/mesher.asm`, D28): 34³ padded volume with
  neighbour borders, 6 directions × 32 slices, greedy rectangles, 8-byte
  packed quads, and a skip for enclosed uniform sections.
* **World rendering** (`src/render/world_render.asm`, `shaders/chunk.*`,
  D29): one quad SSBO, vertex pulling, CPU frustum culling (5 planes ×
  bounding sphere), back-face culling, flat block colours with per-block
  jitter and edge lines (so single blocks show inside merged quads), face
  shading and distance fog.
* Debug block table (`src/world/block.asm`), replaced by the registry in M7.
* Shared data-file parser (`src/core/cfg.asm`, D31); controls.cfg now uses
  it too.
* `arena_alloc_shared` (thread-safe bump allocation) for mesh staging.
* Overlay: world (columns, sections + MB, sections with geometry, quads,
  GPU MB), draw (visible sections and quads), gen and mesh times (wall, avg,
  max), chunk coordinates and the ground block below the camera.
* Self test: sections (all bit widths, get/decode round trips, 3000
  random sets growing 0 → 16 bit) and the mesher (6 cases with exact
  quad counts, including real neighbour sections). The M3 test scene is
  removed.

### Bugs found and fixed while testing
* `arena_alloc_shared` returned `VirtualAlloc`'s page-rounded address
  instead of base + offset, so mesh jobs overwrote each other's quads and the
  world rendered with holes. The mesher unit tests proved the mesher right,
  and dumping the quad contents led to the allocator. Fixed, and covered by
  a self-test check.
* Debug text disappeared once back-face culling was on: its screen-space
  quads wind clockwise. Text now draws with culling off.

### Verified (Wine 9 + Xvfb + Mesa llvmpipe)
* 0 errors and 0 warnings in both configs. The headless test passes for both
  (now also requires the world upload). The self test passes (arenas incl.
  shared allocs, jobs, pools, sections, mesher).
* Screenshots from 4 viewpoints (start, flown forward, turned 90°, low among
  the hills): continuous grass ground, banded hills with correct sides and
  steps, pillars spanning several sections, no missing or inverted faces.
  The overlay reads `ground below: debug_grass at y 99` at the start point.
* Clean exit (code 0).

### Performance (4-core Xeon 2.8 GHz; rendering on llvmpipe, no GPU)
| Measure | Value |
|---|---|
| World | 576 columns, 7074 stored sections (6.6 MB), 1750 with geometry |
| Quads | 107,924 (0.84 MB on the GPU, 8 bytes each) |
| Generation | 40–46 ms wall for all columns; avg 275–316 µs, max 1.6–11.7 ms per column |
| Meshing | 284–370 ms wall for all sections; avg 159–208 µs, max 2.0–6.8 ms per section |
| Frame (start view, ~970 visible sections, ~107k quads) | 16–19 FPS, 52–61 ms on llvmpipe |
Software rasterisation of about 640k vertices per frame is the whole frame
cost here. A real GPU draws this in well under a millisecond (still to be
confirmed on your PC).

### Known issues
* Not yet seen on a real GPU (CI uses software GL).
* Meshing a detailed section costs up to a few ms (scalar greedy). Fine on
  workers, and the binary greedy / AVX2 variant stays available if M6
  streaming needs it.

### Deferred
* The real block set, textures and registry: M7 (design interview).
* Streaming and unloading: M6. The world is fixed-size and generated at
  start-up.
* Persistent buffers, MDI and GPU culling: M11. Light/AO-aware merging: M13.
* Binary greedy meshing with AVX2: an optimisation, only if needed.

---

## Milestone 4 — done (2026-10-08)

### What was built
* **Memory** (`src/core/memory.asm`, D23): virtual-memory **arenas**
  (reserve big, commit in 64 KB steps, bump allocation, mark/reset) and
  lock-free fixed-size **pools** (`cmpxchg16b` Treiber stack with an ABA
  tag, atomic bump for fresh blocks). Global arenas: perm 1 GB, frame 64 MB
  (reset every frame), scratch 256 MB (mark/reset temporaries), plus 64 MB
  scratch per worker. The committed total is tracked.
* **Jobs** (`src/core/jobs.asm`, D24): worker threads (CPUs − 1, or
  `--workers N`), a lock-free MPMC job queue, `job_submit`,
  `job_dispatch` (parallel-for), counters, and `job_wait`, where the main
  thread helps. Idle workers spin, then sleep on a semaphore. Wake-ups are
  claimed and batched. Threads are named.
* **CPU detection** (`src/core/cpu.asm`, D25): requires SSE4.2, detects AVX2
  (CPU + OS), logs the brand and thread count.
* **Self test** (`src/core/selftest.asm`, D26): arenas, parallel compute
  (checked against a serial run, speed-up logged), and a concurrent pool
  storm. It runs in debug builds and with `--selftest`; CI and the headless
  test require "selftest: PASS".
* The M3 static buffers now use arenas: controls.cfg, shader sources and
  compiler logs, and the font file are loaded into the scratch arena
  (`file_load`, sized from the file, so no fixed cap). The glyph buffer is
  in perm, and the overlay text is in the frame arena.
* Overlay: new **memory** line (committed MB, perm MB, frame KB and peak)
  and **jobs** line (workers, completed, queued).

### Verified (Wine 9 + Xvfb, 4-core Xeon, AVX2)
* 0 errors and 0 warnings in both configs. The headless test passes for both.
* **10 of 10** repeated self-test runs pass with 1–4 workers. Parallel
  results always equal serial.
* **Scaling** (release, 4096 jobs ≈ 15 µs each, 61 ms serial):

  | Threads (workers + main) | 2 | 3 | 4 | 5 (oversubscribed) |
  |---|---|---|---|---|
  | Speed-up | 1.96–2.12× | 2.25–2.91× | 3.46–3.62× | 3.46–3.59× |
* **Pool storm**: 8192 jobs × 8 blocks, submitted one by one: 11–32 ms,
  no corruption, 0 blocks in use afterwards. Only 10–31 fresh blocks were
  ever needed, so the free list recycles under contention.
* A bug found and fixed while testing: one semaphore wake per submitted job
  made the parallel run 8× *slower* than serial under Wine. Claimed,
  batched wake-ups fixed it (D24).
* Memory at run time: 0.6 MB committed. Arena peaks: perm 256 KB, frame
  4 KB, scratch 32 KB.

### Verified on Windows (GitHub Actions, AMD EPYC 7763, 4 logical CPUs)
* CI run https://github.com/Notmoodo9/VoxelB/actions/runs/37859514598 is
  green. Both smoke tests require "selftest: PASS".
* **Speed-up 3.94× with 4 threads** (61.3 ms serial → 15.6 ms parallel),
  which is close to ideal. Results match serial.
* Pool storm: 8192 jobs in 12.2 ms, no corruption, no leaks, 32 fresh
  blocks.
* Even load: main + 3 workers ran 3031 / 3149 / 3058 / 3050 jobs.

### Performance
Frame cost is unchanged from M3 (rendering is still the llvmpipe-bound test
scene). The job system is idle during frames until M5/M6 give it chunk
work.

### Known issues
* Not yet seen on a real GPU (CI uses software GL).

### Deferred
* Job priorities / distance-ordered scheduling: with chunk streaming (M6).
* A per-thread frame arena for workers (each worker has a per-job scratch
  arena today, which covers the planned uses).

---

## Milestone 3 — done (2026-10-08)

### What was built
* **Input** (`src/platform/input.asm`): key/button state, a per-frame
  "pressed" latch, **Raw Input** mouse deltas, mouse capture (hide + clip
  cursor, released on focus loss), and an **action** layer with up to 2 keys
  per action loaded from **`data/config/controls.cfg`**. The parser has
  `#` comments, case-insensitive names and a named key table (A–Z, 0–9,
  F1–F12, arrows, modifiers, Mouse1–3, …), plus mouse sensitivity, invert
  Y, fly speed and sprint multiplier. Bad lines are warned about and
  skipped. Format documented in **DATA_FORMAT.md**.
* **Fly camera** (`src/render/camera.asm`): mouse look (pitch clamped to
  ±89°), WASD/arrows, Space/Shift up/down, Ctrl ×5, frame-rate independent
  (dt clamped). Reverse-Z infinite projection, camera-relative rendering
  (DECISIONS.md D20).
* **Shaders** (`src/render/shader.asm`): programs loaded from `shaders/`,
  **hot reload** on file change (250 ms poll) plus F5. A failed compile
  keeps the old program; errors go to the log and the overlay.
* **Debug text overlay** (`src/ui/debug_overlay.asm`, `src/render/text.asm`):
  our own bitmap font (misc-fixed 8×13 → `assets/fonts/debug_8x13.vxf` via
  `tools/make_font.py`), drawn from SSBO glyph records. Shows FPS and frame
  times, vsync, GL version and renderer, position, yaw/pitch/facing, mouse
  state, shader status and the live key bindings. F3 toggles it.
* **Debug test scene** (`shaders/test_scene.*`): 32×32 coloured block
  columns on a checkered ground, generated in the vertex shader (removed
  in M5).
* Files and paths (`src/platform/file.asm`): finds the data root (release
  or dev layout), whole-file reads, file timestamps.
* `SETARGS` now catches call-argument register clobbers at assemble time
  (D21). It caught one real bug.
* GL loader: 49 functions. New string helpers: case-insensitive compare,
  float parse, signed fixed-point formatting, string-builder appends.

### Verified (Wine 9 + Xvfb + Mesa llvmpipe, scripted with xdotool)
* 0 errors and 0 warnings in both configs. The headless test passes for both
  (window, GL context, shaders + text renderer, perf line, clean exit).
* Start view as designed (yaw 0, pitch −20°). Holding **W** for 1 s moved
  the camera 12.8 blocks (12 blocks/s). **Mouse** motion turned it to
  yaw 36°, pitch −24.9°. Positions are shown live in the overlay.
* **F3** hides and shows the overlay, **F8** toggles vsync, **Esc** releases
  the mouse, and **Esc** again quits cleanly (exit code 0).
* **Hot reload**: editing `test_scene.frag` reloaded within about 1 s, and
  the tint was visible. Appending invalid GLSL logged both compiler errors
  and kept the previous program ("reload failed, keeping the previous
  version"). Restoring the file reloaded again.
* **Bad config lines** (unknown action, a third key, an unknown key name,
  a line without `=`, a non-number) each give one warning; the game runs
  normally.
* The **release zip layout** (exe + data/shaders/assets in one folder) finds
  its data next to the exe. A lone exe shows "data folder not found" and
  exits.

### Verified on Windows (GitHub Actions, Mesa 26.2.4 llvmpipe, GL 4.6 core)
* CI run https://github.com/Notmoodo9/VoxelB/actions/runs/37852698522 is
  green. Both smoke tests pass, and they now fail on any ERROR line in the
  log. The game root was found in the dev layout, all 11 bindings loaded,
  49 GL functions resolved, both shader programs built, the text renderer
  started, the mouse was captured, and it exited cleanly with code 0.
* The "Latest build" release was republished from this commit.

### Performance (software rendering via llvmpipe; no GPU here)
| Scene (1280×720, test field ≈ 37k vertices) | FPS | Frame avg |
|---|---|---|
| Windows CI start view (1028×720, llvmpipe) | 36–38 | 26.1 ms |
| Start view, vsync on (Xvfb, no vblank) | 51–57 | 17.5–19.6 ms |
| Inside the field, most of the screen covered | 26–29 | 34–39 ms |
On llvmpipe, the frame time is all CPU rasterisation of the test scene.
On a real GPU this scene costs well under 1 ms. Chunk gen/mesh times start
in M5.

### Known issues
* Not yet seen on a real GPU (CI uses software GL).

### Deferred
* Rebinding from inside the game (settings menu, M17). For now, edit
  `controls.cfg` and restart.
* Pause menu (M17). Until then, Esc with the mouse free quits.
* Static buffers (shader source 256 KB, config 64 KB, font 64 KB) become
  arena allocations in M4.
* SDF font for the in-game UI (M17). The debug overlay keeps the bitmap
  font.

---

## Milestone 2 — done (2026-10-08)

### What was built
* `src/render/gl_context.asm`: WGL bootstrap (a hidden dummy window and
  legacy context to fetch the ARB entry points), `wglChoosePixelFormatARB`
  (RGBA8 / D24S8, double buffered, full acceleration preferred), a
  **4.6 core** context with a 4.5 core fallback, a debug context in debug
  builds. Also the GL loader driven by `src/include/gl_funcs.inc` (12
  functions so far), `KHR_debug` messages routed into the log, vsync via
  `WGL_EXT_swap_control`, swap, and shutdown.
* `src/render/renderer.asm`: viewport tracking on resize; clears to a vivid
  sky blue each frame.
* `src/core/timing.asm`: QPC frame timer with 0.5 s stats windows (FPS, and
  avg/min/max frame time).
* `src/core/entry.asm`: frame loop (pump → requests → render → swap →
  timing), FPS and frame times in the title bar, a `perf:` log line every
  2 s, a run summary on exit, and `--novsync`.
* Window: `WM_CLOSE` is now a request, so GL is released before the window
  is destroyed. F8 toggles vsync. Minimised windows don't render.
* `str_copy`, `fmt_decimal` string helpers.
* CI: Mesa llvmpipe is installed for the GPU-less runner's smoke test, the
  smoke test checks for the GL context and the perf line, and game logs are
  printed at the end of every run.

### Verified (Wine 9 + Xvfb + Mesa 25.2 llvmpipe)
* 0 errors and 0 warnings in both configs.
* Context: llvmpipe offers no 4.6, so the logged warning and the 4.5 core
  fallback worked as designed. Pixel format 3, all 12 functions resolved,
  debug output enabled, vsync set.
* The window shows the clear colour: pixel sampled as rgb(84,158,250), which
  is exactly (0.33, 0.62, 0.98). The title shows live stats.
* F8 toggles vsync off/on (logged and shown in the title). Resizing the
  window to 800×500 updated the viewport. `--novsync` works. The release
  build runs, and both configs exit cleanly with code 0.

### Verified on Windows (GitHub Actions `windows-latest`, Mesa 26.2.4 llvmpipe)
* CI run https://github.com/Notmoodo9/VoxelB/actions/runs/37849222432 is green:
  build.bat debug and release, and both smoke tests passed.
* Got an **OpenGL 4.6 core** context (pixel format 123, GLSL 4.60), with
  debug output on in the debug build.
* **Vsync on gave 62–63 FPS** (16.0 ms average), so vsync really caps the rate.
* Per-monitor-v2 DPI awareness succeeded. Closing took about 4 ms (the 2 s
  delay seen under Wine is Wine-only). Exit code 0.
* The runner's screen is 1024×768, so Windows shrank the window to a
  1028×720 client area. That is expected; the window isn't clamped to the
  screen yet (see Deferred).

### Performance (software rendering; no GPU in this environment)
| Case | FPS | Frame time avg (min / max) |
|---|---|---|
| 1280×720, vsync off (llvmpipe) | ~333–391 | 2.6–3.0 ms (1.5 / 7.5) |
| 800×500, vsync off (llvmpipe) | ~893 | 1.12 ms (0.70 / 2.67) |

Xvfb has no vblank, so "vsync on" doesn't cap the rate here. On a real GPU,
expect a locked refresh rate with vsync on and thousands of FPS with it off
for a clear-only frame. Chunk gen/mesh timings start in M5.

### Known issues
* Not yet run on a real GPU (CI uses software GL). Please run the game on
  your PC and read the title bar.

### Deferred
* Debug text overlay: M3 (stats are in the title bar until then).
* F8/Esc become rebindable bindings in M3.
* Fit the default window size to small screens (currently Windows clips
  it). This will come with window settings in M17.
* Multisampling and an sRGB back buffer are intentionally not used (HDR
  pipeline in M14, DECISIONS.md D12).

---

## Milestone 1 — done (2026-10-08)

### What was built
* `build.bat`: debug/release/clean/run; checks that NASM and lld-link are
  present; builds import libs from `tools/implib/*.def` (no Windows SDK
  needed); assembles every `src/**/*.asm`; links with lld-link.
* `src/include/macros.inc`: Win64 ABI `PROC`/`RETURN`/`ENDPROC`, `INVOKE`,
  `API`, `IMPORT`, `ASSERT` (debug only, reports the call site's file:line).
* `src/include/win32.inc`: Win32 constants and struct layouts.
* `src/core/log.asm`: thread-safe logger writing to `voxel.log`, the console
  and the debugger, with timestamps and levels; `log_fatal`; `assert_fail`.
* `src/core/str.asm`: `str_len`, `str_find`, `str_parse_u64`, `fmt_u64`,
  `fmt_hex64`.
* `src/platform/window.asm`: window class and window (1280×720 client,
  centred, DPI-aware), non-blocking message pump, WndProc (close, destroy,
  size, Esc, activate, DPI change, autoclose timer), clean teardown.
* `src/core/entry.asm`: entry point, command-line parsing (`--autoclose
  <ms>`), main loop, shutdown, `ExitProcess` with the `WM_QUIT` code.
* `tools/build.sh` (Linux mirror of build.bat) and `tools/test_headless.sh`
  (Wine + Xvfb smoke test).

### Verified
* Debug and release both build from clean with **0 errors, 0 warnings**
  (NASM 2.16.01, LLD 18.1.3). Exe size: 8.0 KB debug, 7.5 KB release.
* Under Wine 9 + Xvfb: the window appears with a 1280×720 client area
  (screenshot checked). Esc closes it, and so does `--autoclose`. The log
  shows the full shutdown sequence. Exit code is 0 for both configs.
* Assertion path (tested on a throwaway patched copy): the message box
  appears, the log line names `src/platform/window.asm:86`, and the exit
  code is 3.
* Missing-tool check and usage error of `build.bat` were checked under
  Wine's `cmd`, and the commands it generates match `tools/build.sh`.

### Performance
No rendering yet. The idle main loop runs about 270–450 iterations/s under Wine (1 ms
`Sleep` per iteration), with negligible CPU use. Frame-time/FPS measurement
starts in M2.

### Known issues
* Under Wine/Xvfb (no window manager), `DestroyWindow` takes about 2 s.
  This is Wine-only; on Windows CI it takes about 4 ms.
* Since confirmed on real Windows by CI (window, Esc/autoclose path, exit
  code 0).

### Deferred
* SEH unwind info (`.pdata`) for our procedures; see DECISIONS.md D4.
* Rebindable keys: M3. Esc-to-quit is hardwired until the input system
  exists. Once there is a pause menu, Esc will open it instead.
* Window settings (size, fullscreen) from a config file: settings menus (M17).
