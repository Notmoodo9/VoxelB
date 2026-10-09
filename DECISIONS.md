# Technical decisions

Each entry: decision, why, and what it would cost to change.

## D1 — Linker: lld-link, import libs from `.def` files (M1)
`lld-link` instead of MSVC `link.exe`. It is one LLVM install, works the same
on Windows and Linux (so CI and the agent can cross-build), and with
`lld-link /lib /def:` we build our own import libraries from
`tools/implib/*.def`. That removes any dependency on Visual Studio or the
Windows SDK. Cost to change: small; only `build.bat` changes.

## D2 — No C runtime (M1)
Entry point `main_entry` (`/entry`, `/nodefaultlib`), only Win32 APIs. This
gives a tiny exe (~8 KB) and full control. Consequences: no `__chkstk`, so
stack frames must stay under 4 KB (big buffers go in `.bss` or arenas), and
no CRT math or string functions; we write our own (`src/core/str.asm`).

## D3 — Calling-convention macros (M1)
`PROC name, locals, saved-regs...` / `RETURN` / `ENDPROC` build a fixed frame:
`rbp` frame pointer, pushed nonvolatiles, locals, then a 96-byte outgoing area
(32-byte shadow space + 8 stack-argument slots). `rsp` stays 16-byte aligned
and does not move inside the body, so any call is ABI-correct without
per-call stack fixes. `INVOKE`/`API` load stack arguments first (through
`r11`), then `rcx/rdx/r8/r9`. That costs a few bytes of stack per frame,
which is negligible. Details are in `src/include/macros.inc`.

## D4 — No SEH unwind tables yet (M1)
Procedures do not emit `.pdata`/`.xdata`. We never raise or catch SEH
exceptions, so this only affects debugger stack walks across our frames and
crash dumps. Revisit when we add a crash handler (it is cheap to emit
`UNWIND_INFO` from the `PROC` macro later).

## D5 — Logging (M1)
A single line logger guarded by an SRWLOCK (already thread-safe for the
M4 job system). Each line is written immediately with `WriteFile`, with no
buffering, so a crash never loses the last lines. Lines go to `voxel.log`
next to the exe, the console (redirected stdout or the parent console via
`AttachConsole`), and `OutputDebugStringA`. Timestamps are seconds since
start, from QPC. If per-line `WriteFile` ever shows up in a profile, switch
to a ring buffer flushed by a background thread.

## D6 — Debug vs release (M1)
`BUILD_DEBUG` (0/1) is set by the build script. Debug-only code (`ASSERT`,
`LOG_DEBUG`, `LOG_VAL/LOG_HEX` at debug level, resize logging) is removed
at assembly time, not tested at runtime. Asserts report the call site's
file and line through a single-line `%define` wrapper.

## D7 — Window and message loop (M1)
* A non-blocking `PeekMessage` loop (a game loop, not `GetMessage`). M1 has
  nothing to render, so the loop yields with `Sleep(1)`. M2 replaces this
  with render + swap/vsync.
* `CS_OWNDC` on the window class, ready for the OpenGL context in M2.
* Per-monitor DPI awareness v2 (falls back to v1; if the system already
  set it, we keep it). The client area is in physical pixels, which is what
  the renderer wants. `WM_DPICHANGED` applies the size Windows suggests.
* Default client area 1280×720, centred on the primary monitor.
* Deep-navy background brush, so a window that is up but not yet rendering
  is easy to tell from a black/failed one (useful in headless screenshots).
* `--autoclose <ms>` posts `WM_CLOSE` from a timer. Test runs go through the
  exact same shutdown path as a user closing the window.
* Requires Windows 10 1703+ (for `SetProcessDpiAwarenessContext`). This is
  fine because OpenGL 4.6 drivers imply Windows 10/11 anyway.

## D8 — Verification without a Windows machine (M1)
The agent builds on Linux (`tools/build.sh`) and runs the exe under Wine +
Xvfb (`tools/test_headless.sh`), checking the log, exit code and a
screenshot. `build.bat` was exercised under Wine's `cmd`: argument parsing,
the toolchain check, the import-lib, assemble and link command lines, and
the usage error. A full end-to-end `build.bat` run still needs real Windows
(see PROGRESS.md).

## D9 — Continuous integration on GitHub Actions (CI setup)
`.github/workflows/build.yml` runs on every push and PR on `windows-latest`.
It installs NASM (`ilammy/setup-nasm`), sets up the MSVC developer
environment (`ilammy/msvc-dev-cmd`; not used by the build itself, but
available), and puts LLVM's `lld-link` on PATH. It runs `build.bat` for debug
and release, smoke-tests both with `tools/smoke_test.ps1`, and uploads
`voxelb-<short sha>` (the release exe plus `data/`, `shaders/`, `assets/`).
Pushes to the repository's **default branch** (currently
`claude/keen-lovelace-3ysglx`, by the owner's choice) replace the public
**"Latest build"** release (tag `latest`)
with `voxelb-windows.zip`, a stable name for the README link, and
`voxelb-<sha>.zip`.

## D10 — OpenGL 4.6 core, with a 4.5 core fallback (M2)
We ask for 4.6 core first. If the driver refuses, we take 4.5 core and log a
warning. Real GPUs on current drivers give 4.6. The fallback exists so the
game also runs on software renderers (Mesa llvmpipe stops at 4.5), which is
how CI and the headless tests render without a GPU. Rule for later
milestones: core rendering paths must only use 4.5 features or extensions
we check for (e.g. `ARB_indirect_parameters`, `ARB_gl_spirv`). Cost to
change: none; it is one attribute list.

## D11 — GL loader as an X-macro list (M2)
`src/include/gl_funcs.inc` lists every GL function once, with a
required/optional flag. The loader generates the pointer slots, the name
strings and a `{name, slot, required}` table from it. Other modules call
`GL glFoo, args` through the pointer of the same name. A missing required
function fails startup with a clear log line and message box. Optional ones
stay 0 and are checked before use. Only WGL entry points are imported from
`opengl32.dll`; GL 1.1 functions are resolved through `GetProcAddress`
because `wglGetProcAddress` returns NULL for them.

## D12 — Pixel format and framebuffer (M2)
`wglChoosePixelFormatARB` with RGBA8, 24-bit depth, 8-bit stencil, double
buffered, full acceleration preferred (retried without it). The back buffer
is **not** sRGB-capable: from M14 we render in HDR to our own targets and
the tonemap pass writes sRGB-encoded values itself. Until then, the clear
colour is given in sRGB directly.

## D13 — Frame timing and stats display (M2)
QPC-based frame timer (`src/core/timing.asm`). Stats are gathered over
0.5 s windows: FPS, plus average, min and max frame time in µs. They are
shown in the window title until the debug text overlay exists (M3), and
logged every 2 s as a `perf:` line. CI and the headless tests check for that
line. Minimised windows skip rendering and sleep 16 ms per loop. All maths
is integer: no floating point on the timing path.

## D14 — Shutdown ordering (M2)
`WM_CLOSE` only sets `g_close_requested`. The main loop exits, releases the
GL context while the window still exists, and only then destroys the window.
This avoids tearing down a context whose window is already gone.

## D15 — Temporary hardwired keys (M2; superseded by D16 in M3)
F8 toggled vsync and Esc quit, hardwired in the WndProc. M3 replaced both
with rebindable actions. `--novsync` still starts with vsync off.

## D16 — Input: actions, Raw Input mouse, per-frame press latch (M3)
* The game asks about **actions** (`move_forward`, `menu`, …), never keys.
  Each action has up to 2 keys or mouse buttons, loaded from
  `data/config/controls.cfg`. Adding an action means adding an `ACT_*` id
  and a name in `input.asm`'s table (an engine change); rebinding is data
  only.
* Keyboard comes from `WM_KEYDOWN/UP` (plus `WM_SYS*`, so Alt combos are
  seen; only Alt+F4 reaches DefWindowProc, so Alt/F10 never open a system
  menu that would pause the game). Mouse buttons come from `WM_*BUTTON*`.
  Mouse motion comes from **Raw Input** (`WM_INPUT`, relative), so mouse
  acceleration and the screen edges don't affect it.
* "Pressed" is a latch set on an up→down transition and cleared every
  frame. A tap shorter than one frame is still seen; auto-repeat is not a
  press.
* Capture: hide the cursor (`ShowCursor`) and confine it to the client area
  (`ClipCursor`, refreshed every frame). The mouse is captured at start and on
  a left click. The `menu` action (Esc) releases it; pressing `menu` again
  while the mouse is free quits (until the pause menu exists in M17). Focus
  loss releases it and clears held keys. Mouse deltas are ignored for 3
  frames after capturing, because some platforms (Wine) report the cursor
  jump as motion.

## D17 — Data root discovery (M3)
`paths_init` uses the exe's folder if it contains `data\` (the release
zip layout), else `..\..\` (the `build\<config>\` dev layout). All data,
shader and asset paths are built from that root. Without it the game shows
a clear error and exits.

## D18 — Shader hot reload (M3)
Programs are registered by (vertex, fragment) file path. Every 250 ms the
files' last-write times are checked. A changed program is recompiled and
relinked, and swapped in only if that succeeds. On failure, the compiler log
goes to `voxel.log`, the overlay shows a red "SHADER ERROR" line, and the old
program keeps rendering. `reload_shaders` (F5) forces a reload. Uniforms use
explicit `layout(location)` and `glProgramUniform*` (DSA), so no name
lookups are needed. Shader sources are read through a static 256 KB buffer
(arenas come in M4).

## D19 — Text rendering (M3)
Our own bitmap font: X11 misc-fixed 8×13 (public domain), converted by
`tools/make_font.py` into a tiny raw atlas (`assets/fonts/debug_8x13.vxf`,
format documented in the tool). Glyphs and solid rectangles are 32-byte
records in an SSBO, expanded to quads in the vertex shader (vertex pulling,
the same technique planned for chunk meshes). The fragment shader uses
`texelFetch` on an R8 atlas, so text is pixel-exact. One upload and one draw
call per frame. Integer scale is 1× below 1000 px tall, 2× up to 1999 px,
and so on. An SDF font can be added later for the in-game UI (M17).

## D20 — Camera conventions and projection (M3)
Right-handed, +Y up. Yaw 0 looks toward −Z ("north") and yaw grows turning
right (east = +X). The projection is **reverse-Z with an infinite far
plane** (`glClipControl(LOWER_LEFT, ZERO_TO_ONE)`, depth cleared to 0,
`GL_GREATER`), which gives the best depth precision at long view distances
(LOD terrain to 256 chunks). Rendering is **camera-relative**: the matrix
holds rotation and projection only, and shaders transform `world − cam_pos`.
This avoids float jitter far from the origin. Today `g_cam_pos` is a float.
It becomes chunk + local offset when the world streams (M6).
`sin`/`cos` use x87 `fsincos`: it runs once per frame, so precision beats
speed here.

## D21 — Assemble-time call-argument check (M3)
`SETARGS` (used by `INVOKE`/`API`/`GL`) now fails assembly if an argument
reads `rcx`/`rdx`/`r8` after an earlier argument has already overwritten it,
or if a stack argument uses `r11`. M3 hit this bug once
(`glCreateTextures`). Passing the same register for two slots is also
rejected; copy it to the target register first.

## D22 — Debug test scene (M3; removed in M5)
Until there is a world (M5), the renderer draws a 32×32 field of coloured
block columns on a checkered ground, generated entirely in the vertex
shader (no vertex data). It exists only to check the camera, depth,
shading and shader hot reload. It is not game content and is removed in M5.

## D23 — Memory: virtual-memory arenas and lock-free pools (M4)
* **Arenas** reserve a large address range up front (`VirtualAlloc
  MEM_RESERVE`) and commit it in 64 KB steps as the bump pointer grows. That
  gives us huge capacities (perm 1 GB, scratch 256 MB, frame 64 MB, 64 MB
  per worker) for free: untouched space costs no RAM, and pointers never
  move. Arenas are single-owner, not locked. They are freed wholesale with
  `arena_reset` or `arena_reset_to(mark)`; there is no per-object free.
  Allocations past the reserve fail cleanly (logged).
* Global arenas: **perm** (lives until exit), **frame** (reset at the
  start of every frame: per-frame scratch, no heap churn), **scratch**
  (main-thread temporaries via mark/reset: file loads, shader sources,
  compiler logs). Every worker has its own scratch arena, reset
  automatically after each job.
* **Pools**: fixed-size blocks for objects that come and go across threads
  (chunk sections in M5/M6). The free list is a Treiber stack updated with
  `lock cmpxchg16b` on a {pointer, tag} pair. The tag counter defeats ABA,
  and blocks are never decommitted, so reading a stale `next` is harmless.
  Fresh blocks come from an atomic bump index; blocks past the pre-committed
  part are committed individually (`VirtualAlloc` is idempotent and
  thread-safe, so two blocks sharing a page are fine).
* `g_mem_committed` tracks the total committed bytes for the overlay.
* No CRT `malloc`/`HeapAlloc` anywhere.

## D24 — Job system (M4)
* Workers: logical CPUs − 1 (at least 1, at most 31; `--workers N`
  overrides). The main thread is context 0 and runs jobs while it waits
  (`job_wait`), so waiting never idles a core or deadlocks.
* Queue: bounded lock-free MPMC ring (Vyukov), 4096 cells of 32 bytes,
  with head and tail on separate cache lines. If it's full, `job_submit` runs
  the job inline (back-pressure).
* Jobs are `fn(arg, WORKER*)` and get a per-thread scratch arena. Completion
  is tracked by counters (`lock dec` when done, so results are visible when
  a counter reads 0). The streaming code (M6) will *poll* counters; the main
  thread will never block on chunk work.
* Sleeping: after about 50–100 µs of spinning, workers wait on a semaphore.
  Submitters claim sleepers with a CAS on `g_sleeping` and release exactly
  that many tokens, and `job_dispatch` (parallel-for) wakes them in batches.
  The first version, with one wake per job, was 8× slower than serial under
  Wine; this one scales almost linearly (D26).
* Workers are named "VoxelB worker" (`SetThreadDescription`) for debuggers
  and profilers.
* No priorities yet. Distance-ordered scheduling of chunk work comes with
  streaming (M6).

## D25 — CPU baseline (M4)
`cpu_detect` uses CPUID/XGETBV: SSE4.2 is required (clear error otherwise).
AVX2 is used only if both the CPU and the OS (XCR0 YMM state) support it,
recorded in `g_cpu_avx2` for later fast paths (M5 meshing). The brand
string, logical CPU count and features are logged at start.

## D26 — Start-up self test (M4)
`src/core/selftest.asm` checks arenas (alignment, mark/reset, refusing
allocations past the reserve), the job system (4096 jobs of busy work via
`job_dispatch`; results must equal a serial run, and the speed-up is
logged), and pools (8192 jobs submitted one by one, each allocating,
stamping, verifying and freeing 8 blocks concurrently; there must be no
corruption and no leaked blocks). It runs in every debug start and with
`--selftest`, which CI and the headless test always pass. A failure exits
with code 4 and no dialog.

## D27 — Section storage: palette compression (M5)
A section is 32³ blocks, indexed `y<<10 | z<<5 | x`. It is stored in one
of three forms:
* **uniform** (bits 0): one id in the 64-byte header and no data at all.
  Most underground and sky sections are uniform; all-air sections are not
  stored (null pointer).
* **palette** (1/2/4/8 bits per block): a palette of up to 2^bits ids
  (512-byte block) plus packed indices (4–32 KB).
* **raw** (16 bits): more than 256 kinds of block in one section; ids are
  stored directly (64 KB).
Bit widths are powers of two, so an index never straddles a byte and
get/set/decode are just shifts. `section_set` appends to the palette and
regrows (decode → rebuild) only when the palette is full. The palette is
never shrunk in place; it is recomputed exactly on rebuild. All storage
comes from per-size lock-free pools (D23), so worker threads build and free
sections without locks. The flat test world (576 columns, 7074 stored
sections) takes 6.6 MB.

## D28 — Greedy mesher and the packed quad format (M5)
* Each section is expanded into a 34³ u16 volume, with a one-block border
  copied from its 6 neighbours (air if missing, "solid" below the world).
  This makes face culling exact across section borders, and meshing never
  touches other sections afterwards.
* For each of the 6 directions × 32 slices, a 32×32 mask of visible faces
  is built and merged greedily into rectangles of equal block id (light/AO
  equality joins in M13). A fully enclosed uniform opaque section is
  skipped without meshing.
* **Quad = 8 bytes**: block x, y, z (6 bits each), width−1 and height−1 (5
  bits each), face (3 bits), block id (16 bits). The vertex shader expands
  each quad from `gl_VertexID` (vertex pulling, no vertex buffers). Faces
  1/3/4 use mirrored corner order, so every face winds CCW from outside
  and back-face culling works.
* Plain scalar greedy meshing averages 160–210 µs per stored section on
  this 4-core Xeon, running on all worker threads. The spec's binary
  greedy / AVX2 variant is an optimisation for later if streaming (M6)
  needs it.
* Verified by self-test cases with exact quad counts and, for one case,
  checked quad contents.

## D29 — World rendering for M5 (M5)
All quads go into one immutable SSBO, uploaded once from a shared staging
arena that the mesh jobs append to with `arena_alloc_shared` (an atomic
bump). Each visible section is one `glDrawArrays` with three uniforms. The
CPU frustum test uses 5 planes from the camera-relative matrix and a
bounding sphere per section. Milestone 11 replaces this with persistent
buffers, multi-draw-indirect and GPU culling; Milestone 6 with streaming
uploads.

## D30 — Flat test world is debug content (M5)
`data/world/flat_test.cfg` declares placeholder blocks (`debug_*`, flat
colours), the layers (stone to y 95, dirt to 98, grass at 99, so the land
surface is at y ≈ 100 as in the spec), the world radius, and debug
structures (banded hills and pillars that cross section borders, to
exercise the mesher). None of this is game content. The real block set,
textures and terrain are designed with the owner (M7, M8).

## D31 — One data-file parser (M5)
`src/core/cfg.asm` implements the `name = value` format of DATA_FORMAT.md
(comments, trimming, `,` lists via `cfg_next_token`, warnings with a file
label). controls.cfg and flat_test.cfg both use it. Milestone 7 extends it
with sections/records for the registries.

## D32 — Column streaming pipeline (M6)
* A column (32 wide, 40 sections tall) moves through the states NEW →
  GENERATING → GENERATED → MESHING → MESHED → READY. Only the main thread
  changes the loaded set; a job publishes its result by writing the next
  state last (a release store), and the main thread reads it with an
  acquire load. No locks.
* Each frame, `stream_update` walks a precomputed spiral of chunk offsets
  sorted by distance, so the nearest missing work is always issued first.
  Generation runs out to R+1 and meshing to R. A column is meshed only once
  its 4 horizontal neighbours are generated, so edge faces are culled
  correctly the first time and never re-meshed.
* A column stays loaded until it is beyond R+3 (hysteresis), so flying
  back and forth across a border doesn't regenerate it.
* A `busy` counter on each column counts the mesh jobs that read it as a
  neighbour. A column is freed only when it is idle and its busy count is
  0, so a job never reads freed memory.
* At most `(workers+1)·16` gen jobs and as many mesh jobs are in flight.
  That is enough to keep every worker busy for a whole frame even at 15
  FPS, while keeping the queue short so a fast-moving camera re-prioritises
  quickly.
* Uploads are capped at 2 MB per frame. The main thread never waits for a
  job, only for its own small upload batch.
* Loaded columns are kept in an open-addressing hash (16384 slots, linear
  probing, backward-shift deletion) plus a dense list for iteration.

## D33 — GPU quad buffer: buddy allocator (M6)
The 128 MB quad SSBO is split into 2^18 units of 64 quads (512 B). Each
section's mesh gets a power-of-two run of units from a buddy allocator
(free lists per order, buddies merged on free). That means O(log n) alloc
and free, no compaction, and at most 2× internal waste, which is fine for
the M6–M10 interim. Milestone 11 replaces this with persistent mapped
buffers and multi-draw indirect. A full buffer is reported once and the
column stays unrendered; it is never a crash.

## D34 — Double-precision camera (M6)
The camera position is kept in doubles, so it is exact far from the origin.
Each section's origin is computed relative to the camera in double, then
converted to float for the shader. Rendering stays jitter-free at any
distance the 32-bit chunk coordinates can reach.

## D35 — Worker priority and frame-time spikes (M6)
Workers run at `THREAD_PRIORITY_BELOW_NORMAL`, so the render thread wins
whenever cores are oversubscribed. On the 4-core test box, occasional 4–12
ms spikes in `stream_update` turned out to be OS preemption: llvmpipe's
render threads compete with the workers there. With llvmpipe forced
single-threaded, the worst case fell to under 1.5 ms. Per-operation timing
showed every step (upload, submit, unload) at 1 ms or less. The average
update stays at 70–170 µs.

## D36 — Block registry: data files with templates and families (M7)
Blocks are defined in `data/blocks/*.blocks` with `[block]`, `[template]`,
`[family]` and `[texture]` records (DATA_FORMAT.md). The owner's block set
is about 262 blocks, mostly "same logic, different texture" (16 woods × 8
variants), so templates with a `{}` member placeholder keep the data short:
one family line creates 128 wood blocks. Files are read in file-name order,
so ids are deterministic (saves will store names → ids anyway, M17). The
registry keeps flat tables indexed by id (names, per-face texture, render
layer, light, flags) plus three 64 KB byte tables (opaque, layer,
cull-self) that the mesher reads with no bounds checks for any u16 id.
The parser is the shared `cfg.asm` with `[header]` lines added behind a
flag, so older files are unaffected.

## D37 — Textures: PNG files, our own decoder, one texture array (M7)
* The owner wants to repaint textures in any editor, so textures are
  ordinary PNG files. `src/core/png.asm` implements inflate (RFC 1951,
  canonical Huffman as in zlib's "puff") and every non-interlaced PNG
  variant. A self test decodes 5 reference images (all colour types, all
  5 filters, stored/fixed/dynamic blocks, split IDAT, tRNS) and checks
  their hashes.
* All block textures go into one `GL_TEXTURE_2D_ARRAY` (RGBA8, 16×16, 5
  mip levels). 317 textures with their animation frames are 479 layers
  (2 MB with mips); GL guarantees at least 2048 layers. Greedy quads tile
  their texture with `GL_REPEAT` (uv = block coordinates), so merged quads
  need no atlas padding and mipmaps have no seams.
* Sampling uses `NEAREST` magnification for crisp pixels and
  `NEAREST_MIPMAP_LINEAR` minification against distant shimmer. Cut-out
  alpha is boosted by the mip level (a coverage-preserving test), so
  distant leaves don't thin out.
* Animations are vertical strips; the frame is chosen in the vertex
  shader from a time uniform and a per-texture table (SSBO), with optional
  blending between frames. Glow layers are separate textures drawn at full
  brightness, which makes fantasy blocks glow before lighting exists (M13
  adds real light from the `light` values).
* Hot reload checks 32 file times per frame (all ~320 files every 10
  frames) and re-uploads changed PNGs in place.

## D38 — Render layers: opaque, cutout, translucent (M7)
The mesher orders each section's quads by layer (opaque, cutout,
translucent), and the section records the counts, so each layer of a
section is one contiguous range and one draw. Face culling: an opaque
neighbour hides a face; two equal "cull self" blocks (translucent) hide
the face between them; leaves don't cull each other (see-through leaves
show inner leaves). Draw order: opaque, then cutout (alpha test), then
translucent with blending and no depth writes, sections sorted back to
front. Quads inside one translucent section are not sorted (rare
artefacts between different glass colours in one section; per-quad
sorting can come with water in M15). `opaque_leaves = 1` (graphics.cfg)
turns cut-out blocks into opaque ones at load, for weak GPUs.

## D39 — Enclosed-section skip covers all-opaque palettes (M7)
The mesher already skipped uniform opaque sections enclosed by opaque
neighbours. With bedrock and deep stone layers, many buried sections are
mixed (bedrock + deep stone), and meshing them produced zero quads at full
cost (mesh time per column rose from about 1.7 ms to 6 ms). A section,
or a neighbour, now counts as all-opaque when every palette entry is
opaque. Mesh time per column is now about 1.3 ms.

## D40 — Texture generator (M7)
The owner chose "Claude draws them, you tweak". `tools/texgen/texgen.py`
draws all 317 textures procedurally with pixel-art conventions:
quantised shade ramps with hue shifting (cool, saturated shadows; warm
highlights), per-texture deterministic noise, and patterns per material
(bark styles, rings, boards, carvings, moss, books, leaf clusters,
Voronoi cobbles, bricks, glass frames, weave). The output PNGs are
committed and are the source of truth from now on; the script is a
starting point, not a build step.

## D41 — Block states as consecutive ids (M7b)
Shaped blocks need state (facing, half, open, hinge). A shape reserves one
id per state, right after its base id (Minecraft's "flattened" ids):
`base + state`. Sections stay plain u16 arrays, the mesher and the
renderer need no extra storage, and each state can have its own textures
(the door's upper half). States that depend only on neighbours (stair
corners, fence/wall/pane connections, pillar parts) are not stored; the
mesher works them out. The 272 shaped blocks use 1813 ids (2075 in all,
of 4096). Names are shared by all states; `block_find` returns the base.

## D42 — Model quads for shaped blocks (M7b)
Shapes are lists of boxes in 1/16 units, described for facing north and
rotated about Y (src/render/shapes.asm). They are engine code, like the
render layers; which blocks have which shape and texture is data. Each
visible box face is one "model quad" in the same 8-byte quad stream (bit 31
set; block position, box min and size in 4-bit fields). The vertex shader
expands both kinds, so there is still one buffer, one shader and one draw
per section and layer. Box faces on the block boundary are culled against
opaque neighbours; shaped blocks never count as opaque. Sections without
shaped blocks (checked from the palette) skip the shape pass entirely.
MESH_MAX_QUADS is now 131072 (greedy worst case 98304 plus room for
shapes); the shape pass stops at the cap instead of overflowing.

## D43 — Gallery shows states (M7b)
The debug gallery now lists base blocks only, and lays shaped blocks out
so their states and connections are visible: a 3×3 grid of states, a T of
fences/walls/panes, a stacked and a lone pillar, and doors with their upper
halves. It moved to z 440..270 (start position z 462), away from the hills.
