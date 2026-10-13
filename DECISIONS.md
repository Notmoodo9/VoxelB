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

## D44 — Noise: seeded gradient noise in asm (M8)
`src/core/noise.asm`: 2D and 3D gradient noise (Perlin-style lattice,
quintic fade, 8 / 12 gradient directions) with a 32-bit integer hash of
cell, world seed and a per-field salt, plus fractal sums (`fbm2/fbm3`,
optionally ridged). Inputs are doubles split into an exact cell and a float
fraction, so the terrain stays identical far from the origin.
OpenSimplex2 would remove the slight grid-aligned bias. The splines and
heavy smoothing make that invisible for heights, so it was not worth the
extra code now; noise.asm can swap the kernel later without changing
callers.

## D45 — Terrain model: fields → splines → height (M8)
All shapes come from data (`data/world/terrain.cfg`): 11 noise fields
(continentalness, erosion, peaks, high, giant, ridges, jag, rolling, river,
detail, 3D overhang) and 6 splines. The combination (src/world/terrain.asm
header) is engine code:
* base height from continentalness;
* hills/mountains = peaks × mountain factor × (1 + high factor), fading
  out towards the sea;
* giant ranges = a rare large-scale mask × ridged noise cubed (continuous
  ridgelines, never lone peaks) plus jagged spires on the ridges;
* rivers pull the height down to the riverbed near zero crossings of the
  river noise, with valley width depending on the mountain factor;
* overhangs: in mountains, a 3D noise term (±amplitude) on a coarse grid
  (4×8×4 blocks, trilinear), added to the height field's density.

A survey of 25.6 × 25.6 km (`--survey`) for the default seed gives: ocean
33.0%, lowland 52.2%, hills 7.4%, mountains 5.9%, high mountains 1.0%,
giant 550+ 0.1%; highest point 993.

## D46 — Generation cost: coarse grid + per-block detail (M8)
Sampling all fields at every block cost 4.6 ms per column (release). The
large-scale fields are smooth, so the height and the overhang amplitude
are sampled every 4 blocks (10×10 per column, including the border) and
interpolated bilinearly. Only the detail noise is evaluated per block.
That brought generation to 2.2 ms per column. Uniform sections (all
stone, all deep stone, all water, all air) are detected from the column's
height range and never filled voxel by voxel.

## D47 — Still water and lighter fog (M8)
A `water` block (translucent, cull-self, 16-frame animated texture) fills
air at or below sea level. That covers oceans, lakes and rivers (river
beds sit below sea level). Flow and real water rendering are M15. The
distance fog was thinned (density 0.0028 → 0.0013) so mountains stay
readable across the 512-block view. Real height/distance fog is M14.

## D48 — Cave model: fields on a coarse grid, columns, regions (M9)
`src/world/caves.asm`, data in `data/world/caves.cfg`
(`design/terrain/underground.md`). It works in three layers:
* **Per column** (`caves_column`, CCOL records): crust height (caves stay
  `cave_crust` below the surface except at `entrance` spots), sky cavern
  mask, natural pillar, flooded (surface at most sea level + 3), floor patch
  block, ravine depth/ratio, shaft top/bottom, and the lake and lava levels
  of its aquifer region (64×64, levels from a hash of region and seed).
* **Per section** (`caves_grid`): cavern ("cheese") and tunnel fields on a
  9×5×9 grid (every 4 blocks in x/z, every 8 in y), interpolated per block
  column (`caves_profile`) and per block. The grid's min/max decide whether
  a section can contain a cave at all.
* **Per block** (`caves_carve`): fast reject in the fill loop (tunnel value
  ≥ 0, cheese below the height's threshold, plain column), then ravine,
  shaft, sky bowl, tunnel, cavern; the fluid comes from the column's levels.

Ores, dripstone and floor patches run per section after the fill
(`caves_finish`). Every section below the surface is now filled voxel by
voxel (no more uniform stone sections underground), which is why
generation went from 2.2 to about 10 ms per column, and meshing from 1.5
to about 12 ms. Both run on the workers. The streamer's in-flight job cap
scales with frame time (`g_frame_us >> 14`, 1..8) so slow frames are not
made slower.

## D49 — Aquifer barrier instead of fluid walls (M9)
Fluid levels are per region (and flooding per column), so two neighbours
can disagree: one side water up to y 50, the other air. Without care the
water stands as a vertical wall. Like Minecraft's aquifers, `caves_carve`
keeps the rock wherever a side neighbour's fluid (air / water / lava) at
that height differs from the cell's own. Neighbours outside the chunk come
from a ring of 4×32 extra column records computed in `caves_column`.
Lakes are switched off inside sky cavern bowls, otherwise the barriers
formed dam walls across the open bowl.

## D50 — Sky caverns as bowls, shafts as hashed cells (M9)
A lowered cavern threshold alone made only small pits. Sky caverns now
also carve an open bowl from the surface down to
`sky_cavern_depth × m × (2 − m)` (m = the 0..1 mask), so the cavern below
is visible from far away. Shafts were contour lines of a 2D field (long
thin cracks); they are now round pipes: one possible shaft per
`shaft_spacing` cell, its centre, radius and depth from a hash.

## D51 — Cave culling: section connectivity + visibility walk (M9)
With every underground section meshed, the view holds ~4M quads, mostly
inside rock and caves you cannot see. The mesher flood-fills each section's
open cells and stores which of its 6 faces are connected (15 pair bits,
`SECT.vis`). The renderer walks sections breadth-first from the camera's
section (Minecraft's approach):
* go from a section through face d only if a face it was entered through
  connects to d;
* never go against a direction already taken on the path;
* only into sections inside the frustum.

Every path to a section has the same length (no turning back), so all paths
arrive while it is still queued. Its entry faces and allowed directions are
the union over those paths. Without that, the first path's directions hid
caves that another path could see. The camera's section and its 26
neighbours pass everything (32-block sections are coarse up close).

Results (llvmpipe): spawn view 446 of ~11,000 sections, 262k of 4.0M
quads. Inside the sky cavern 543 sections / 332k quads, against 1062 /
695k for a looser "any open face" rule, with the same image. A camera
inside solid rock sees through it (faces between solid blocks are never
built) and the walk then shows holes. That is expected (spectator-like
views) and is not a culling bug. Hi-Z occlusion culling (M11) is the next
step.

## D52 — Ores: hashed clusters per section (M9)
For each ore whose range overlaps a section, `per_section ×
(1 + mountain_bonus)` attempts plus `ore_wall_bonus` extra attempts that
must touch a cave. Each attempt has a hash-chosen position, a triangular
density test around `peak_y`, and a random-walk cluster of `size_min..max`
blocks that replaces only stone (normal ore) or deep stone (`deep_block`).
Rare long veins snake through a section. All randomness is a hash of world
seed, section and ore, so chunks are reproducible in any order.

## D53 — Biomes: climate boxes and a blurred blend map (M10)
`src/world/biome.asm`, data in `data/biomes/*.biome`
(`design/biomes/biome_system.md`). Temperature and humidity come from two
large-scale noise fields (0..1). A biome declares a climate box and a height
range. The box containing the sample wins (nearest centre on overlap);
nothing → biome 0, "none" (plain M8 terrain, untinted). Box size controls
biome size and rarity per biome, as the owner asked ("some smaller, some
massive").

Per chunk, biomes are picked every 16 blocks over -64..+96 and blurred
with a 5×5 tent filter (radius 32), giving a weight vector per biome on a
7×7 grid, interpolated per block. The weights drive:
* the hill factor (hills = height above the base × blended `hill_scale`,
  applied on the coarse height grid);
* the grass/foliage colour (blended RGB factors);
* vegetation density (0 at weight 0.5 = the border, full at 0.85).

This gives the requested 30–60 block soft borders with vegetation thinning
out. Sharp borders at rivers and cliffs come naturally from the terrain
(rivers cut to the bed, steep slopes are stone).

## D54 — Biome tint map instead of per-vertex colours (M10)
Tinted faces (grass tops, oak leaves, plants: `tint = grass|foliage`) look
up a world-space RGBA8 texture: 2 layers (grass, foliage) of 1024×1024
texels, one per 4×4 blocks, wrapping every 4096 blocks (the loaded world is
smaller). Each column writes its 8×8 texels when it becomes ready. The
texture is linearly filtered, so colours blend smoothly with no quad
format change and no mesh cost. The texel is a factor (64 = ×1.0, up to ×4 since part 6 — see D63) relative
to the texture's own colour (`grass_reference`), so the existing vibrant
textures stay as authored outside biomes.

## D55 — Plants as crossed planes in the model-quad stream (M10)
New shapes `plant` and `tall_plant` (2 states). shapes.asm emits two model
quads with face codes 6 and 7 (diagonals). The vertex shader builds the
diagonal plane, uses face 0's texture, and bends the top with the wind
(lower half of a tall plant moves only at its top, the upper half
continues the bend: hi bit 28). The cutout pass disables back-face culling.
That costs nothing for cubes (their back faces are never emitted).

## D56 — Flora: hashed candidates that cross chunk borders (M10)
`src/world/flora.asm`. The terrain heightmap now has a 16-block border
(HB), so features spilling into neighbours are computed identically by
every chunk:
* ponds (one candidate per 128² cell, radius ≤ 6, a flat rim of ≤ 3 height
  difference) are dug into the heightmap before surfaces are chosen;
* trees and bushes are candidates per 4×4 cell (chance = density × 16 ×
  blend density), listed if their trunk is within 8 blocks of the chunk and
  grown section by section;
* plants are decided per column: meadow (one candidate per 512² cell,
  ragged radius), flower clusters (8×8 cells), then ground cover.

Pond banks ignore the pond's own height drop when picking slope blocks, so
they stay grassy. Logs do not yet have an axis, so branch logs show their
end grain.

## D57 — Log axis states (M10 part 2)
`shape = axis` on a cube block reserves 3 states: upright, along X, along Z.
The registry swaps the `end` texture onto the faces along the axis (no
mesher change: they are ordinary cubes with their own face textures).
Fallen logs, giant roots and branches pick the axis from their direction,
which also fixed the end grain on the big-oak branches from part 1.

## D58 — Rare pockets: weirdness + priority (M10 part 2)
A third climate field, weirdness (0..1), and a per-biome `priority` let a
biome sit inside another one's climate box as a rare pocket. Old-growth
forest uses the forest's box with weirdness 0.8–1 and priority 1. About 1 in
6 forest areas gets one, as designed (the survey gives forest 13.8% and
old-growth 1.8% of land near the origin).

## D59 — Giant trees as tapering discs (M10 part 2)
The owner asked for realistic giants: "a giant trunk then it gets to a 3x3
or something and then branches". `giant` trees stack discs whose radius
follows 1.5 + (R0 − 1.5)(1 − t/0.55)² up to the crown base, then tapers to
0.8, with a flare of +0.4 per block near the ground. 4–7 roots arch out and
down, 6–10 heavy branches (two logs thick near the trunk) rise from 45–87%
of the height and end in leaf clusters, and a crown sits on top. Trees now
reach 20 blocks beyond their trunk, so the heightmap border (HB) grew to 22
blocks (it must be ≥ reach + 2 for neighbours to agree).

## D60 — Meadow cells and flower lists per biome (M10 part 3)
The bluebell carpets of birch groves reuse the meadow feature with two new
biome settings: `meadow_cell` (candidate cell size, power of two, default
512 as before) and `meadow_flowers` (a separate flower list). Birch groves
use 128-block cells with only bluebells, so small groves still get carpets.

## D61 — Desert: dunes, new generator kinds, ponds (M10 part 4)
* Dunes: a ridged `dunes` noise field (scale 90) times the biome's blended
  `dune_height` is added to the coarse height grid, so dunes blend out at
  desert borders like hills.
* Five new generator kinds share the tree machinery (candidates per 4×4
  cell, hashed, consistent across chunks): `cactus`, `rock`, `arch`,
  `fossil`, `palm`. Rocks, arches and fossils use a new placement mode that
  replaces terrain blocks (`PUT_SOLID`), so they sink into the sand.
* Pond cells shrank from 128 to 64 blocks (chances in plains and forest
  scaled by 1/4 to keep their frequency) so small oasis pockets can hold
  pools. A per-biome `pond_slope` lets oasis pools cut into uneven ground,
  and ponds may now sit at beach height, as long as the water stays at or
  above sea level.

## D62 — Conifers and the cold biomes (M10 part 5)
`conifer` trees stack needle discs whose radius falls linearly from the
crown radius to 0 at the tip, with every second layer 0.8 smaller, for the
layered spruce look. The trunk stops 3 below the tip, so the top is
needles. Snowy taiga is a separate colder biome (temperature 0–0.15) with
snow as its top block and `spruce_snowy_leaves`. Rocks can take a second
block for their upper half (mossy cobblestone boulders).

## D63 — Savanna: plateaus, acacias, baobabs, and the tint fix (M10 part 6)
* Plateaus: a fifth climate field, `plateaus` (scale 300), becomes a mask
  `clamp((n − 0.22) × 14, 0, 1)`: mostly 0, with a narrow ramp up to 1.
  The mask × the biome's blended `plateau_height` is added to the coarse
  height grid on land above the beach. The result is a rare flat top with
  steep sides, which get the biome's `steep_block`.
* Two new generator kinds:
  * `acacia`: a trunk that forks twice plus 2–4 diagonal limbs, each
    ending in a flat two-layer leaf pad;
  * `baobab`: stacked discs bulging as f = 1 + 0.6t − t², with stubby
    branches leaving the rim and small leaf blobs.
* Desert got priority 1 and oasis priority 2, so the wide savanna box
  never takes desert land.
* **Tint fix.** Biome colours had never shown in any biome:
  * `draw_range` passed the section's world origin from entry offset 12,
    but entries store it at offset 16 (after a padding dword). The shader
    got (0, x, y) instead of (x, y, z), so the tint map was sampled in the
    wrong place. This also skewed animation phases.
  * The tint factor is now encoded as 64 = ×1.0 (up to ×4) instead of
    128 = ×1.0. The old encoding capped the factor at ×2, so gold over a
    green texture could not reach its red value.
  * Plains, forest, birch grove, oasis, taiga and snowy taiga now show the
    grass and foliage colours from their design docs.
* The `--survey` run now also logs the nearest plateau top.

## D64 — Jungle: kapoks, trunk decorations, strands, groves (M10 part 7)
* Trees can carry decorations, all set per tree in data:
  * `vines`, `fungus` and `pods` go on the side faces of the trunk disc,
    using a new helper `trunk_deco`;
  * `hanging_vines` hang from leaves inside `blob`.
  * Vines and pods use the `ladder` shape (state = the side the trunk is
    on). Shelf fungi use the pressure-plate plate. Strands are crossed
    planes.
  * Every random draw depends only on the tree's seed, never on what is
    already placed, so trees stay identical across sections and chunks.
  * Strands stop at the column's ground from the heightmap. They are only
    placed for columns inside the chunk; the rng is still consumed for the
    others.
* `kapok` kind:
  * a round trunk (r² = base_r² + 0.5: a plus or 3×3);
  * buttress fins: walls of logs falling linearly from 2·r+3 high to 1;
  * 4–7 branches spread evenly over 16 directions, rising 0.5 per block;
  * flat clusters (down 0.35, up 0.55);
  * vines and fungi on the bare trunk between the fins and the branches.
* `grove` kind: a whole bamboo grove is one tree candidate (radius up to
  20, within TREE_REACH). Each stalk stands on its own column's ground and
  gets shorter and sparser towards the edge. Groves are rare by weight in
  the jungle's tree list.
* New shape `stalk`: a 4/16 post that joins nothing (fences would grow
  rails between packed bamboo).
* MAX_CANDS went from 320 to 640: a dense jungle lists ~400 trees and
  bushes per chunk.
* Jungle leaves are now foliage-tinted (emerald 1FB52A in the jungle).

## D65 — Snowy tundra: low patches, frozen ponds, more trees (M10 part 8)
* `top_patch_low` uses the same detail noise as `top_patch`, from its
  other end, so two patch kinds (gravel and frozen dirt) never overlap and
  share no new noise field.
* `pond_top`: the top layer of pond water (y = the pond level) becomes the
  biome's block. It is checked per column from INFO_BIOME where the
  terrain fills water. Frozen ponds keep water under the ice.
* Snow caps on boulders reuse the rock's upper-half block. Snow drifts
  are low, wide snow rocks.
* MAX_TREES went from 32 to 64 (the tree registry was full).

## D66 — Badlands: mesas, bands, washes, ragged biome borders (M10 part 9)
* Mesas: a `mesas` noise (scale 200) is ramped to a mask m =
  clamp((n + 0.05) × 4). It is cut into 3 terraces: each step is flat for
  3/4 and rises over the last 1/4. The result × the blended `mesa_height`
  is added to the coarse height grid (every 4 blocks, bilinear), so the
  risers become near-sheer cliffs.
* Bands:
  * one 128-entry u16 table per biome (`g_strata`), built at load from
    the biome's `strata` list in seeded random order, never the same
    block twice in a row, with thicknesses from `strata_thickness`;
  * a block's band is `table[(y + wave) & 127]`;
  * `wave` is a per-column i8 from a slow `strata` noise (×4), stored in
    INFO (INFO_SIZE went from 16 to 20: INFO_WAVE, INFO_SFLAG).
  * The marker id `BLOCK_STRATA` (0xFFFE) stands for "the band here". It
    is accepted as `steep_block` (cliff tops) and as a tree `log` (striped
    hoodoos and arches). `put_block` and the terrain fill resolve it.
* Washes: the dune field's ridged crest lines, only where the mesa shape
  is ~0 (canyon floors). No new noise.
* Ores: an ore with `strata = 1` only starts clusters in banded columns
  (CAVECTX now points at the column INFO), and may replace any band block
  (`g_is_strata`, one byte per block id).
* Ragged biome borders (all biomes): a column's biome is the strongest
  one, unless the gap to the second is below `detail noise × 1.5`; then
  the second wins. Top blocks follow the column biome, so snow, sand and
  red-sand edges now fray instead of running in straight lines along the
  16-block blend lattice. Weights for colours, heights and vegetation are
  unchanged.
* `beach_block`: the shore band can be the biome's own block (red sand).

## D67 — Steppe: dry hollows, lean, stone rings (M10 part 10)
* Dry hollows reuse the pond machinery. A pond whose hash falls under the
  biome's `dry_ponds` share is dug as a flat pan one block below its
  lowest rim. Its columns get the level `POND_DRY` (−32767), not a water
  level. Everything that checks "pond != POND_NONE" (no plants, no trees,
  banks stay grassy) treats it like a pond; the water fill never matches
  it; the surface pass puts the biome's dry block (salt) on top.
* `lean`: the trunk of round and branching trees moves east by
  `lean × height` blocks, and the crown follows: one prevailing wind
  direction, the same everywhere.
* `stone_ring`: stones are spaced over 16 directions (even for 6–10
  stones, up to one direction of slack). Each stone draws its size from
  the rng before its position is checked, so a ring is identical in every
  chunk it touches.

## D68 — Swamp: water colour, flatten, own shores, floating plants, cypress; tint fix for cutout/translucent (M10 part 11)
* **Draw-list fix**: the cutout and translucent pass lists stored each
  section's world origin as only (x, y). The section pointer at +24
  overwrote world z. Every leaf, plant and water face therefore sampled
  the tint map at a garbage z, and their biome colours were effectively
  random (opaque faces such as grass tops were right).
  * The entry is now rel xyz (0), world xyz (12), SECT* (24): 32 bytes,
    no padding.
  * `g_vec_tmp`/`g_vec_tmp2` are laid out the same way, so the opaque
    pass passes them directly.
  * Since then, every biome's leaves and plants show their designed
    foliage colours.
* **Water tint**: a third tint layer (texture depth 3, COLUMN.tint
  3×64). `tint = water` sets both tint bits (mode 3). The shader recolours
  water: `WATER_REF × factor × luma(texel) / luma(WATER_REF)`, which keeps
  ripples and sparkles light under a strong factor instead of turning
  them yellow. Biomes without `water_color` get the reference, i.e. the
  usual blue.
* **flatten** (`level, pull`, blended through a separate `bmap_flatten`)
  pulls the coarse height grid towards a level. Swamps use 96.6 (sea level
  96): the ±2 detail bumps then give a natural pool-and-island maze, with
  water filled to sea level.
* **own_shore**: the shore band uses the biome's ground above the sea and
  its pond floor (mud) below.
* **Swamp trees** are allowed on low ground down to 2 blocks under the
  sea. `put_block` lets logs replace water, so trunks and knees stand in
  it.
* **Water plants**: per column, on a pond's level or the sea over low
  ground, one hash picks from the biome's `water_plant` list. Lily pads
  use the pressure-plate plate shape.
* **cypress** kind:
  * a disc trunk with radius 0.5 + (R0 − 0.5)·max(0, 1 − y/3) from 2
    below the ground;
  * 3 flat blobs (down 0.25, up 0.35) 3 apart, widening downwards;
  * knees: log stubs up to just above the water, inside-chunk columns
    only (the rng is consumed in the same order everywhere).

## D69 — Dark forest: the gnarled kind (M10 part 12)
* `gnarled`:
  * the trunk is a disc around a float centre that starts at the
    candidate and, from 2 blocks up, moves 0.3 blocks per block along a
    heading, which turns by −2..2 of 16 directions every 4 blocks;
  * the radius tapers to ×0.55 at the top, at least 0.6;
  * the centre at every height is kept (≤ 40 entries) so branches leave
    the bent trunk where it really is;
  * branches turn by −1..1 every 2 blocks and rise 0.4 per block.
* The dark forest is a weirdness pocket of the forest climate (0.21–0.40)
  between the birch groves (0–0.21) and the plain forest. Old growth
  stays at 0.80–1.00.
* Glowcaps go both in meadow-style clusters on the open floor and as a
  litter `shade_plant`, so they appear near trunks and roots too.

## D70 — Glowing forest: a rarity field (M10 part 13)
* The forest climate's weirdness axis was already split into bands
  (birch 0–0.21, dark forest 0.21–0.40, old growth 0.80–1.00). A
  glowing-forest band of 0.44–0.52 took the place of forests and broke up
  their pockets.
* So biomes got a fourth, independent climate value, `rarity` (its own
  noise, scale 450). A biome with a `rarity` range only exists there, on
  top of whatever weirdness band the land is in. The glowing forest uses
  0.70–1.00 at priority 2: ~1.2% of land, in pockets of a few hundred
  blocks.
* Weeping glowwoods reuse the `round` kind. `hanging_vines` = the glowwood
  leaves themselves (4.5% of leaves, 2–6 long) gives curtains of glowing
  leaves without a new generator.

## D71 — Floating islands (M10 part 14)
* Islands are terrain, not flora. One candidate per 48×48 cell (centre
  8–40 inside it), hashed from the cell alone. A candidate exists where
  the blended biome at its centre has `island_chance` (× density); the
  blend map covers −32..63 around the chunk, which contains every centre
  that can reach it.
* `flora_islands` lists the candidates once per chunk (up to 16, with
  tree reach) and writes each interior column's island top and bottom
  into INFO (INFO_SIZE 24: INFO_ISLE_TOP / INFO_ISLE_BOT; the highest
  island wins).
* The terrain fill checks this before air and water, so islands cost
  nothing in columns without them. Sections up to the highest island top
  (+3) are filled block by block.
* Shape at relative distance t (rim wobble ±15% from the detail noise):
  * top = yc + 2.5·(1 − t²);
  * bottom = yc − 1 − 0.9·r·(1 − t)^1.5, minus a 1-block hash jitter.
* Island trees are ordinary tree candidates (CAND.y = the dome top), so
  they stay consistent across chunks like every other tree. Plants use
  the column's biome rules; root strands use `island_roots`.
* Island ores use an inline position hash in the fill, from the biome's
  `island_ore` list.

## D72 — Mushroom fields: islands lifted out of the sea (M10 part 15)
* Ocean columns had no biome. The mushroom fields biome takes only
  ocean-floor heights (≤ 86) in the rarity field (0.66–1.00, any
  climate) and lifts its land with `flatten = 110, 0.9`. The blended
  weight fades at the pocket's edge, so the lift becomes a natural
  shoreline with ordinary beach sand.
* Pockets must be large to beat the surrounding "none" (ocean) weight in
  the 32-block blend. At rarity 0.80+ and depth ≤ 78 they vanished, so
  the range was widened.
* `mushroom` kind:
  * a stem of discs;
  * a cap blob (dome: down 0.15, up 0.75; flat: up 0.25);
  * a gills disc (radius − 1) under the cap;
  * shelf fungi on the stem (trunk_deco).
* The survey logs the nearest "island lifted from the sea": an ocean
  sample whose biome flattens well above sea level (+6).

## D73 — Ice spikes: the spike kind (M10 part 16)
* `spike`:
  * discs with radius R0·(1 − t)^1.3 (approximated as (1−t)·(1−t)^0.375
    with square roots) and a 0.35 r² slack, so the tip ends in single
    blocks;
  * placed with PUT_SOLID, so spires replace snow and plants;
  * the core (centre column and top 30%) is the `leaves` block.
* Ice spikes are a rarity pocket (0.72–1.00) of the snowy tundra's
  climate, priority 2, like the glowing forest and sky islands in theirs.

## D74 — Meadow: height bands and tree groves (M10 part 17)
* The meadow is two biome entries with one look: `meadow` (heights
  140–180) and `alpine_meadow` (181–230), in the temperate climates at
  priority 2. Height already picks biomes, so "alpine flowers only higher
  up" needs no new code, and the blend makes the change gradual.
* Sky islands and the glowing forest moved to priority 3, so the meadow
  never takes their rare pockets on the slopes.
* Groves (birch clumps): a biome may list `grove_tree`s with a
  `grove_chance` per 128×128 cell, a `grove_radius` and a
  `grove_density`. Inside a grove disc, the tree layer uses the grove's
  density and list.
* `in_clearing` became one routine, `in_disc` (cell size and hash salt
  as parameters), shared with `in_grove`. Clearings are unchanged:
  same 160 cell, salt and centre range.

## D75 — Frozen ocean: sea ice and icebergs (M10 part 18)
* The frozen ocean is a biome of ocean heights (≤ 99, which includes the
  low shore) in the cold climates (temperature ≤ 0.36), priority 1.
  Mushroom islands (priority 3) keep their pockets.
* Sea ice is decided per column in a new pass, `flora_sea_ice`, and kept
  in a new INFO byte (`INFO_ICE`: floe, snowy floe, ridge). The terrain
  fill puts it at the sea level (and ridges one block above).
  * Floes are Voronoi cells of a jittered grid. The sample point is
    shifted by the detail noise (±3 blocks) so the edges fray, and the
    channel width varies 0.5–1.5× per floe, so some floes touch and some
    have wide leads.
  * The frozen share fades over the warmest part of the biome's
    temperature range (`biome_climate` per column, only over open water
    of these biomes), so the pack opens toward warmer seas.
  * Ridges are decided per pair of floes (hash of both cells), so they
    form lines along shared edges rather than scattered blocks.
  * The ice is one block thick: the section below the sea level is a
    uniform water section and stays one.
* Icebergs are a tree kind (`iceberg`) and a third candidate layer in
  `flora_prepare`, on water 4+ deep, standing at the sea level.
  * Their underwater part needs the sections below the sea to be built
    block by block. `FCTX.bot` (the lowest y an iceberg may reach, at
    most 24 under the sea) turns those uniform water sections into
    detailed ones, only in chunks with icebergs.
  * Shape: the union of 1–4 lobes, peaked as (1 − t)^1.5 or flat-topped
    (min(1, 3(1 − t))); 0.6 × the height under water.
* Shores and sea floor are biome settings (`beach_patch`,
  `seabed_block`, `seabed_patch`). The shores of a frozen sea mostly
  belong to the cold land biomes (snowy tundra, snowy taiga, ice
  spikes), so they got the same snowy gravel shore.
* The survey logs the share of the sea that is frozen and the nearest
  open frozen sea (6+ deep).

## D76 — Glaciers: smoothed-height biomes and an ice layer (M10 part 19)
* Tongues: a biome can be picked by the smoothed surface height
  (`smooth_height`), the mean of the sample and 4 samples 24 blocks
  away. In a valley between high ridges it stays high, so the glacier
  reaches down the valley and ends where the mountain ends. The extra
  samples are taken only within 96 blocks below the lowest such biome, so
  lowland chunks pay nothing.
* The blend map also keeps its sample heights and a smoothed height per
  blend point (the same tent as the weights, ~32 blocks), read with
  bilinear interpolation (`bmap_hs`).
* Ice is a layer on the ground, laid by `glacier_pass` (new module
  `src/world/glacier.asm`) right after the heightmap. It raises the
  heightmap to the ice surface, so ponds, trees, plants, caves and the
  section bounds all see the ice as the ground.
  * Surface = max(ground + cap, smoothed height − fill), at most `max`
    above the ground. Ridges get a thin cap, valleys fill to a broad
    surface.
  * It ends abruptly where the glacier blend weight drops below
    `ice_edge`, giving sheer walls at the snout and edges. The band below
    is a moraine ridge.
  * Seracs where the smoothed height is steep.
  * Crevasses: depth per column (ridged noise in field masks).
  * Ice caves: 3D noise evaluated per block, only inside thick ice.
  * The ice columns have no overhang noise.
  * INFO grew to 40 bytes (ground, crevasse, flags, glacier biome, world
    x/z).
* `glacier_block` picks each block between the ground and the surface:
  air in crevasses and caves, snow on top above the snow height, packed
  ice, blue ice deeper.
* Bug found on the way: `andps xmm, [mem]` needs a 16-byte-aligned
  operand. A lone `dd` mask worked in debug by luck and faulted in
  release. Masks are now whole aligned xmm constants.

## D77 — Cave biomes (M10 part 20)
* Cave biomes are their own records (`[cave_biome]`), not surface
  biomes. They are picked by a depth range and a 3D region noise, and
  decorate a section after the normal cave decoration (new module
  `src/world/cavebiome.asm`). Adding another cave biome is a data file.
* The region and theme fields are evaluated on a 5×5×5 grid (every 8
  blocks) per section and interpolated. A section is skipped when the
  grid's maximum is below the region range (interpolation stays inside
  the grid's extremes). Sections outside the depth range cost nothing.
  The grotto chunks cost ~3% generation time.
* Decoration only reads and writes the section's own blocks. Floor and
  ceiling tests skip the top and bottom layer (ly 0 and 31). Stone is
  replaced everywhere inside the region, not only at the cave walls, so
  section borders show no seams.
* Pillars: a disc per 16×16 cell, kept inside the chunk, where every cave
  air block in the region becomes crystal. In a cavern that is a column
  from floor to ceiling across sections without any cross-section state.
  Tunnels through the disc are plugged (crystal can be mined).
* Pools are a translucent glowing block until fluids exist.
* Sprouts reuse the `spike` shape (state 0 up, 1 down) and the crystal's
  own texture and glow.
* One theme per area: the theme noise is large (scale 600), so most
  grottos are one colour. At 220 a single grotto showed 2–3 colours.
* The survey logs the region share of the deep volume (6.4% at y −16 to
  −176 within 1 km) and the nearest region point.

## D78 — Rivers: per-column river biomes (M10 part 21)
* The biome blend samples every 16 blocks, which misses rivers that are
  ~8 wide. So river columns are decided per column instead:
  * the coarse terrain grid (every 4 blocks, world-aligned) keeps the
    river value (0 at the river's edge, 1 at the valley's; 9 off land);
  * every heightmap column gets a class: *water* (under the sea level
    inside the valley) or *bank* (value < 0.6, at most 4 above the sea).
* River columns take their land biome's `river_biome` (default "river")
  for everything per column:
  * INFO biome: ground, shore, plants, water plants, bed plants, sea ice;
  * tree and water-feature candidates (the class map covers the whole
    heightmap, so neighbouring chunks agree);
  * the water tint of the 4×4 tint cell over the river (grass and
    foliage too with `own_colors`).
* Where a river meets a lake or the sea, the water colour changes at a
  4-block cell edge. That is accepted for now.
* `waterlogged` blocks (river weed): the mesher remaps the cell to the
  water block for face building and culling, and `shapes_emit` draws the
  plant inside it, so there are no air pockets. The border filler
  (0xFFFF) is skipped (the flag table is 4096 entries).
* The iceberg layer became a general water-feature layer, with a minimum
  depth. Icebergs float; other kinds (stepping stones) stand on the bed.
* `own_shore` biomes put trees in water only with `trees_in_water`
  (swamp, muddy river). Palms and willows had stood in the river.
* MAX_TREES 64 → 96.

## D79 — GPU-driven drawing (M11)
* The CPU keeps the visibility walk (cave culling through the sections'
  face-connectivity bits, plus a coarse sphere frustum test). It no
  longer draws: it writes one 32-byte record per section and layer
  (camera-relative origin, first quad, world origin, quad count) into a
  persistent, coherently mapped ring with 3 frame slots, each guarded by
  a fence.
* `shaders/cull.comp`, one thread per record:
  * an exact AABB frustum test;
  * a Hi-Z occlusion test: the box is projected with the previous frame's
    view-projection, moved by the camera's motion since then. It is hidden
    if its nearest depth is behind the farthest depth of the pyramid
    texels covering it, at the mip where the box spans at most 2 texels.
    Boxes off the previous screen or crossing the camera plane are kept.
  * It writes the record's DrawArraysIndirectCommand: instanceCount 1 or
    0, first = first quad × 6, baseInstance = the record's index. The
    order is kept, so translucent records stay sorted back to front.
* Each pass (opaque, cutout, translucent) is one
  `glMultiDrawArraysIndirect`. The vertex shader takes the quad from
  `gl_VertexID` (which counts from the command's first vertex). The
  record ring is also an instanced vertex buffer (stride 32, divisor 1),
  so `baseInstance` selects the draw's origins as attributes.
  * The first version read the record from an SSBO per vertex. Under
    llvmpipe that cost ~50% frame time (2.4 M vertices per frame), so it
    was replaced. It also needs no draw-ID buffer or `gl_DrawID`, so it
    works on GL 4.5.
* `shaders/hiz.comp` builds an R32F pyramid (level 0 = half the scene,
  each texel the farthest = minimum reverse-Z depth; odd sizes fold the
  extra row and column in) after the frame's draws. That needs the scene
  in an offscreen framebuffer with a depth texture (renderer.asm), which
  is blitted to the window; post-processing (M14) will use it too.
* Stats (records drawn, quads, Hi-Z culled) are counted with atomics into
  a mapped buffer per slot and read when the slot comes round again, 3
  frames later.
* Settings: `gpu_culling` and `occlusion_culling` in graphics.cfg.
* Not done here:
  * the quad uploads still use `glNamedBufferSubData` from the streamer;
  * Hi-Z is single-phase (the previous frame's depth), so a section that
    becomes visible from behind an occluder can appear one frame late.

## D80 — Distant terrain: LOD tiles (M12)
* **Tiles.** A tile of level L (1–5) is 32 × 32 cells of 2^L × 2^L
  blocks, so it is 2^L chunks wide. Each cell is one column of whole
  blocks: a height, a top block and side faces. Tiles are world-aligned,
  so neighbours of the same level share their border heights exactly and
  need no skirts.
* **Rings.** r0 = (render_distance − 2) × 32 blocks (inside the columns
  the streamer always has). r[L] = min(r0 × 2^L, lod_distance × 32), up
  to 5 levels. lod_distance 64 at render distance 16 gives 3 levels
  (448 / 896 / 1792 / 2048 blocks); 256 gives all 5.
* **Heights.** The terrain's own `terrain_sample` at the cell centre,
  without its detail part, scaled around the base by the biome's hill
  factor. Dunes, plateaus, mesas and flatten come from the biome
  settings, blended bilinearly from an 11 × 11 lattice (every 4 cells,
  biome by `biome_point`, as the columns pick it). Then the detail part
  is added back.
* **Surface rules** (a simplified `terrain_gen_column`):
  * under the sea level: the biome's seabed (else beach sand) plus a water
    quad at the sea level;
  * snow above the snow line (rock if steeper than twice the steep
    limit);
  * rock on steep cells (the step to a neighbour ≥ steep × cell size);
  * the beach band;
  * glacier snow or ice;
  * forests (tree density ≥ 0.006 with a leaf block): a leaf canopy
    5 blocks above the ground;
  * else the biome's top block.
  * Side faces: a band of the top block (the canopy's height for leaves),
    3 blocks of the biome's filler, then rock. Snow, sand, rock and sea
    floor sides keep one material.
  * Striped badlands rock becomes plain stone far away.
* **Mesh.** Greedy rectangles of equal (height, block) for the tops;
  one quad per cell side, from the cell's height down to a lower
  neighbour's; greedy water rectangles at the sea level. 8-byte quads:
  x, z (cells), y (blocks above the tile's lowest quad), face, width in
  cells; block, height (cells on tops, blocks on sides). Up to 16384
  per tile.
* **Jobs.** One job per tile on the worker threads (about 4 ms each).
  `lod_update` on the main thread:
  * walks every ring's tile range;
  * keeps tiles touching the ring ± one tile and requests those touching
    it;
  * caps the jobs in flight at 8 per worker, and only submits while the
    job queue is shorter than the number of workers, so full-detail
    columns always come first;
  * uploads at most 1 MB of quads per frame into the shared quad buffer
    (the buddy allocator);
  * frees tiles no ring needs.
  * Tiles are found through an open-addressed hash with backward-shift
    deletion (no tombstones).
* **Drawing.** Ready tiles add draw records to the M11 pipeline:
  * land after the walk's opaque records;
  * water before the sorted translucent records (coplanar water quads
    never overlap on screen, so no sorting is needed).
  * The record's count carries the level in its top byte and the world
    origin's y holds the tile's box height. `cull.comp` sizes the box
    from them. The vertex shader reads the level from a third instanced
    attribute and decodes LOD quads.
  * Tiles wholly inside their ring's inner edge, or beyond its outer
    edge, are skipped on the CPU.
* **Seams and transitions.** Every level, including the full-detail
  sections as level 0, is clipped to its ring in the fragment shader by
  horizontal distance. Across each boundary the two levels cross-fade
  over a band of 8% of the radius with a screen-door dither: interleaved
  gradient noise, with complementary thresholds, so each pixel shows
  exactly one of them. The overlap fills the cracks a height mismatch
  between levels would open, and the change of detail has no hard edge.
* **Colours.** A second tint map, 1024² × 3 layers (grass, foliage, water
  factors), one texel per 16 × 16 blocks, repeating every 16384 blocks.
  Each tile writes its biomes' factors into it when uploaded.
* **Fog** density is 2.3 / LOD radius (the far edge is about 90% sky).
  Without LOD it stays at 0.0013.
* **Settings:** `lod_distance` (0–256 chunks, default 64) in graphics.cfg.
* Driver robustness (after a blank screen on Intel UHD 630): the ring
  radii are two `vec4` uniforms (no indexed uniform array). The level
  attribute is a float conversion of the record's count (exact for the
  top byte, since counts stay below 2^23). A zero radius disables the
  clipping instead of discarding every pixel.

## D81 — Lighting: per-column light volumes baked into quad corners (M13)
* **Where light is computed.** In each column's mesh job (worker thread),
  just before meshing: a light volume covering the column plus a 16-block
  margin on every side (64 × 64 cells), from the world bottom to 16 above
  the highest stored section of the 9 columns. Light is not stored with
  the world. It is rebuilt whenever a column is meshed, so block edits
  (M16) only need a re-mesh of the columns within 16 blocks.
  * Meshing now waits for all 8 surrounding columns. The streamer
    generates two rings beyond the render distance (was one) and drops
    columns four rings out.
* **Cell data.** u16 light: r, g, b and sky, 4 bits each. A u8 per cell
  from `g_light_op`: opaque (stops light, counts for AO) and the
  `light_filter` (extra loss per block: leaves 1, water 1, set in the
  block files).
* **Skylight.** Straight down from the open sky at 15 without loss until
  the first opaque block; filtering blocks subtract their filter. Then a
  breadth-first flood fill sideways and down, losing 1 + filter per step.
  The seeds are only the full-sky cells next to a column whose full sky
  starts higher, so open plains cost almost nothing.
* **Block light.** A flood fill from every emitter (the `light` setting),
  all three channels at once: the channels as bytes, `psubusb` for the
  loss, `pmaxub` against the cell, re-queued only when a channel grew.
  Inside a uniform emitter section (lava lakes) only the boundary cells
  are queued.
  * Light that would leave the volume is lost. With a 16-block margin that
    only affects paths that go out and come back.
* **Faces.** For each visible face and each corner, take the cell in
  front of the face, its two side neighbours in the face plane and the
  diagonal one. The diagonal is skipped when both sides are solid.
  * Corner light = the mean of the open cells, per channel.
  * AO = 3 − (side1 + side2 + corner), or 0 when both sides are solid.
  * Emitting blocks light their own faces at least to their emission.
  * Shaped blocks and plants use the flat light of their cell (the cell
    above if it counts as solid).
* **Storage.** Each quad gets a light word (4 corners × 16 bits) in a
  buffer parallel to the quad buffer: same index, SSBO binding 6. AO
  (2 bits per corner) goes into bits 48–55 of cube quads.
  * Greedy merging joins faces only when block, light word and AO are all
    equal. That costs about 2× the quads (5.9 M → 11.8 M at render
    distance 16), so the quad and light buffers are 256 MB each now.
  * Drawn quads at spawn: 525 k → 709 k.
* **Shading.**
  * The vertex shader passes the 4 corners flat plus the position inside
    the quad, and the fragment shader mixes them bilinearly. This is
    smoother than per-vertex interpolation, with no diagonal seams.
  * Brightness = max(sky × daylight, block RGB, held light), through a
    curve l^1.6 with an ambient floor of 0.03, times AO (0.45..1).
  * The held light falls off 1 level per block from the camera. It casts
    no shadows.
  * LOD tiles are lit as open sky.
  * The `daylight` uniform waits for the day/night cycle (M14). Until
    then the `--daylight` option previews it.
* **Settings:** `smooth_lighting`, `ambient_occlusion`, `held_light`
  (graphics.cfg); action `toggle_held_light` (L).

## D82 — Sky, day/night, fog, HDR and bloom (M14 part 1)
* **HDR scene.** The scene target's colour is RGBA16F. chunk.frag still
  works out lighting in the textures' own (sRGB) space, so the look of M13
  is kept, then converts to linear (^2.2). Glow layers are added in linear
  at 2.5× (above white, so they bloom).
  * `post.frag` (fullscreen triangle into the window) adds bloom, applies
    exposure and ACES (Narkowicz fit), then a grade: saturation 1.12 plus
    vibrance 0.25 for duller colours. Then gamma 1/2.2.
* **Bloom** (`bloom.comp`): one RGBA16F texture with up to 6 mips at half
  size.
  * Prefilter: the highlights above 1.0 with a soft knee, a 2×2 box from
    the scene.
  * Downsample: 2×2 boxes down the chain.
  * Upsample: in place, level n += bilinear(level n + 1).
  * Images only, one level read and another written, like Hi-Z.
  * The final pass adds 7% of level 0.
* **Sky** (`sky.frag`, drawn first at the far plane with no depth test).
  An analytic model in linear colour, not a full scattering simulation:
  * zenith-to-horizon gradient that blends from day to night with the
    sun's height;
  * warm glow on the sun's side and pink opposite while the sun is near
    the horizon;
  * sun disk (HDR 40×) with a tight and a wide halo; the moon opposite the
    sun;
  * hashed twinkling stars at night.
  * `sky_color()` is duplicated in chunk.frag for the fog colour (no
    shader includes yet). Keep them the same.
* **Day/night** (`daycycle.asm`): `day_length` minutes and `start_time`
  in world.cfg, `--time`, and T to run the clock 240× faster.
  * The sun rises in the east (+X) at 6:00 and peaks at noon, its path
    tilted 25° towards +Z. It moves continuously.
  * Surfaces get the sky light × a sun colour: white at noon, warm near
    the horizon, dim blue moonlight at night.
* **Fog**: the colour is the sky's colour in the view direction, so it
  matches sunsets and nights.
  * Distance fog: density 1.8 / LOD radius.
  * Height fog: integrated along the ray, 0.0012 per block at the base
    (sea level + 8), thinning by e every 30 blocks, no thicker below the
    base.
  * Near surfaces without sky light (caves) get dark fog. Beyond 160
    blocks the sky colour wins.
* Settings `bloom`, `height_fog` (graphics.cfg).
* Not yet: cascaded shadows and clouds (part 2); biome-tinted fog;
  auto-exposure.

## D83 — Cascaded shadows and clouds (M14 part 2)
* **Cascades.** Three of them, splitting `shadow_distance` (default 160)
  at 12%, 38% and 100%. `shaders/shadow_setup.comp` (one thread per
  frame) writes the light-space matrices into a 368-byte storage buffer
  (binding 7), which chunk.vert, chunk.frag and cull.comp read. No
  uniform arrays: those failed on Intel (D80).
  * Each cascade is the bounding sphere of its view slice, so its size
    never changes with the view.
  * Its centre is snapped to whole texels in world-anchored light space
    (camera position mod 4096), so the edges don't shimmer.
  * Orthographic, reverse-Z (depth 1 nearest the light), ±640 blocks of
    depth, with depth clamping for casters outside that.
  * The light is the sun by day and the moon (half strength) by night,
    kept at least ~7° high, and fades out near the horizon.
* **Casters.** Every section with geometry within the shadow distance
  (+1 chunk) gets one draw record after the frame's own records (opaque
  and cut-out ranges are contiguous, so one record each).
  * cull.comp has a light-space mode (`u_cascade` > 0): it tests the box's
    8 corners against the cascade square and writes that cascade's own
    command buffer. No stats, no Hi-Z.
  * Each cascade is one `glMultiDrawArraysIndirect` with chunk.vert (it
    picks the cascade matrix) and `shadow.frag` (alpha test only), face
    culling off, into one layer of a 2048² DEPTH32F array.
  * **Alternating cascades:** cascade 0 is drawn every frame, cascades 1
    and 2 on alternate frames. The buffer keeps each cascade's matrix and
    the camera position it was drawn from, and chunk.frag shifts into that
    space (mod-4096 difference). This halves the shadow cost.
* **Sampling** (chunk.frag): cascade by distance; normal offset of 1.5
  texels plus a tiny constant bias; 4 taps half a texel apart through
  `sampler2DArrayShadow` (hardware 2×2 PCF each, so 16 effective taps)
  for soft edges; fade out over the last 10% of the distance.
  * Direct light = facing (smoothstep of N·L) × shadow.
  * The sky-light term is scaled by mix(0.48, 1, direct), so shadowed and
    averted faces keep the sky's fill light.
  * This also gives the sun a direction even with `shadows = 0` (the
    matrices are still computed).
* **Clouds** (post.frag, before tonemapping): a layer `cloud_height` ..
  +48 blocks.
  * 6 jittered steps along each pixel's ray, up to the scene depth (from
    the depth texture), so terrain hides clouds behind it and clouds hide
    terrain below.
  * Density: 3-octave value-noise fbm plus detail, against `cloud_cover`,
    with a vertical profile; drifting with a constant wind.
  * Lighting: one sample 18 blocks towards the sun or moon per step
    (Beer-like), between an underside colour and a sunlit colour that
    follow the time of day.
  * They fade into the sky from 2500 to 6000 blocks.
* **Streaming fix found here:** the per-frame upload budget now scales
  with slow frames, like the job cap already did, so streaming no longer
  stalls on slow renderers.
* Settings: `shadows`, `shadow_resolution`, `shadow_distance`, `clouds`
  (graphics.cfg); `cloud_cover`, `cloud_height` (world.cfg).
* Not done: cloud shadows on the ground, LOD tiles casting shadows,
  translucent coloured shadows.

## D84 — Water rendering (M15 part 1)
* **Water is drawn last, opaque, over a copy of the scene.** Before the
  translucent pass the opaque + cut-out scene (colour and depth) is
  blitted into a refraction target (`refraction_copy`, texture units 8
  and 9). The water fragment then works out everything itself and writes
  alpha 1. No second geometry pass, no extra render of the world.
* **Surface normal:** 4 moving sine swells/ripples evaluated per pixel
  from the world x, z (no normal texture, no vertex displacement, so the
  meshes stay untouched and greedy-merged quads stay correct).
* **Thickness:** from the copied depth behind the surface (reverse-Z,
  infinite far: view z = near / depth), converted to the distance along
  the ray.
* **Refraction:** the copied colour, offset by the normal, scaled by
  thickness and shrinking with distance; offsets that would land on
  something in front of the water fall back to the straight sample.
* **Depth colour:** Beer–Lambert absorption per channel (red goes first)
  plus in-scattered light in the biome's water tint, lit like a block
  (sky light, block light, sun direction).
* **Reflection:** Schlick Fresnel between the underwater colour and the
  reflection. The reflection is a screen-space march (28 growing steps
  against the copied depth, faded at the screen edges), falling back to
  the analytic sky colour, dimmed where the surface sees little sky (so
  cave pools don't mirror a bright sky). Plus a sharp sun/moon glint.
* **Foam:** where the water is thinner than ~0.7 blocks, a blocky noise
  pattern that pulses slowly.
* **From below:** water faces are two-sided (face culling off for the
  translucent pass; other translucent faces discard back faces). From
  below there is no reflection, only refraction.
* **Underwater:** the camera's block is tested each frame
  (`water_camera`); post.frag then covers the scene with a dense
  blue-green fog by distance, dimmed at night.
* `water_quality` (graphics.cfg): 0 = the old alpha-blended water, 1 =
  refraction/depth colour/foam, 2 = also screen-space reflections.
* **Flowing water is deferred** until the world can change (block edits
  arrive with the sim split in M16). Generated water is static and level,
  so a flow simulation would have nothing to do before then. It will run
  on the 20 TPS simulation tick and remesh the touched sections.

## D85 — Simulation / client split, packets, player physics (M16 part 1)
* **Two sides, one process.** `src/sim/` is the server side (the world's
  changing state: the player's body, the clock), `src/client/` plus the
  renderer, input and UI are the client. They talk only through two packet
  queues (`src/core/packet.asm`): fixed 64-byte packets in lock-free
  single-producer single-consumer rings, plain data with no pointers, so a
  network transport or a simulation thread can replace the hand-off later.
  * Client → sim: `INPUT` every frame (movement axes, view yaw/pitch,
    buttons), `TOGGLE_FLY` (double tap of move_up, detected on the client
    where frame timing is exact).
  * Sim → client: `PLAYER` and `TIME` every tick.
  * World storage is shared for now (an integrated server): the client
    renders the chunks the sim reads. Block changes (part 2) will still go
    as requests and change notices through the queues.
* **Fixed 20 TPS** on the main thread: an accumulator runs the due ticks
  each frame (at most 10; a slower machine runs the simulation slower
  rather than spiralling). Within a tick, all inputs since the last tick
  are read and their buttons OR-ed, so a short tap is never lost.
* **Interpolation:** the client keeps the last two `PLAYER` / `TIME` states
  and draws between them by the accumulator's fraction, so motion is
  smooth at any frame rate (the view trails by up to one tick, 50 ms;
  mouse look is immediate, it stays on the client).
* **The clock moved to the simulation** (time_forward is an input button);
  daycycle.asm now only turns the client's time into the sun direction.
* **Collision** (`src/sim/physics.asm`), all in doubles (exact far from
  the origin):
  * every block id resolves to none / full cube / boxes by shape+state
    (1/16 units, rotated by facing, fences/walls connect like the mesher
    draws them, 1.5 high so they can't be jumped); data overrides with
    `collision`, `climbable`, `liquid` in the block files;
  * per tick the solid boxes around body + move (+ margins) are gathered
    once (unknown columns count as solid), then the move is clipped axis by
    axis (Y, X, Z, Minecraft's order) against them; boxes already
    overlapping are ignored so a body inside a block can walk out;
  * step-up: when blocked sideways on the ground, try up `step_height`,
    across, back down, and keep it if it went farther;
  * sneak edge guard: on the ground while sneaking, shorten x, z and the
    diagonal move in 0.05 steps until the body would still have support
    within `step_height` below.
* **Movement model:** horizontal velocity approaches the wanted velocity by
  a share per tick (ground / air / water / flight rates), vertical by
  gravity (world.cfg, per realm later) with a terminal speed; swimming
  approaches a sink / swim-up target; ladders clamp the fall and climb on
  jump or when pushing against the wall. The body is always 1.8 high
  (sneaking only lowers the eyes; crawling under 1.5-high gaps is not
  modelled). Liquids count when the lower third of the body is in them.
* The player waits (frozen) until the column under it is generated.
* **Spawn:** the terrain's spawn point, walking (falls to the ground);
  `--pos` starts flying there (so screenshot positions stay valid);
  `--flytest` is noclip flight at `flytest_speed`.
* All movement numbers are in `data/entities/player.cfg` (Minecraft-like
  defaults; the owner can tune the feel).

## D86 — Breaking and placing blocks (M16 part 2)
* **Requests, not edits, from the client.** `interact.asm` casts a ray
  (Amanatides–Woo voxel walk, doubles) from the eyes each frame and finds
  the first block within `reach` (plain liquids are looked through,
  shaped blocks and plants count as their whole cell). Break / place send
  `PKT_C_BREAK` / `PKT_C_PLACE` with the cell (place: the cell beside the
  hit face); holding repeats every 0.25 s. The click that captures the
  mouse is not an action.
* **The simulation decides** (`src/sim/edit.asm`): within reach + 1 of the
  eyes, column generated; break anything but air and plain liquids
  (Creative: instantly), taking the other half of a door or tall plant and
  a plant standing on top along; place into air, a liquid or a plant, not
  inside the player's body unless the block has no collision. Accepted
  changes go into an ordered queue.
* **Applying safely:** `world_set_block` only touches a column while no
  job reads it (`busy == 0`: no mesh job of it or of a neighbour, which
  raise its counter), so `section_set` may rebuild the section storage;
  an all-air section is created on demand. Otherwise the change waits in
  the queue (order kept) for up to 5 s. Each applied change is announced
  with `PKT_S_BLOCK`.
* **Remeshing (client):** `stream_block_changed` marks the column dirty,
  and each neighbour the change can reach with light (the change within 15
  blocks of that side). A dirty READY column runs the normal mesh job
  (light volume + mesh) while it **keeps drawing its old mesh**: the job
  writes its per-section results into the column (`COLUMN.minfo`) instead
  of the sections, and the upload frees the old GPU ranges and swaps the
  new ones in on the main thread. Edits during a remesh set dirty again.
* **Outline:** 12 edges of the target cell as `GL_LINES` (vertex pulling),
  drawn into the scene after the water pass with a tiny depth bias, no
  depth writes. **HUD** (`src/ui/hud.asm`): a crosshair and the held
  block's name.
* The held block is a stand-in for the hotbar (items, milestone 18):
  `stone` at start, `pick_block` copies the target (with its state, so
  stairs keep their facing). Placement doesn't orient blocks by the
  player's facing yet.
* Edits live in the loaded columns only: a column that unloads (beyond
  render distance + 4) is generated fresh when it comes back. Saving
  edited columns arrives with region files (milestone 17).

## D87 — Flowing liquids (M16 part 3; M15 part 2)
* **Data:** a liquid is a source block (`water`, `lava`: plain cubes) and
  a flowing block with the new `fluid` shape (8 states: levels 1–7,
  falling) naming its `source`, with `flow_range` and `flow_delay`. Lava
  flows too (range 3, 30 ticks per step).
* **Rules (Minecraft-like, in the simulation, `src/sim/fluid.asm`):** a
  cell holds falling liquid if the same liquid is directly above it, else
  the lowest neighbouring level + 1, where a source (or a waterlogged block,
  for water) is level 0 and a flowing/falling neighbour only counts where it
  rests on something (liquid over air falls instead of spreading; resting
  falling liquid counts as a source). Beyond `flow_range` it dries up. Only
  air, plants and flowing liquid are replaced; sources never change, so
  generated oceans and lakes stay as they are until something next to them
  changes.
* **Event driven:** nothing is scanned. Every block change (edits and the
  liquid's own changes, through `edit_apply`) schedules the cell and its 6
  neighbours `flow_delay` ticks later in a 128-bucket ring by tick (4096
  cells per bucket, 2048 updates per tick at most, the rest move on). A
  change into a busy column retries next tick.
* **Rendering** (`shapes.asm`, with exact face masks per box): a flowing
  block is a box as high as its level (14/16 … 2/16; falling or covered by
  the same liquid: full). Top unless the liquid continues above, bottom
  over non-liquid, sides next to non-opaque non-liquid blocks; where a
  neighbouring liquid cell is lower, a strip from its height up to ours;
  where the source cube next to us is higher, its strip above us, facing
  us. The cube mesher treats a flowing neighbour as its source, so a
  source's faces into flowing liquid are hidden. Water states take the
  water shader (refraction, reflections) like the source.
* Not done: currents pushing the player, Minecraft's preference for the
  nearest drop, new sources from two neighbours, lava + water making
  stone.
* `--held <block>` (command line) starts with any block in hand, e.g.
  water or lava, since liquids can't be targeted for pick_block.

## D88 — Saving: region files of changed columns (M17 part 1)
* **Only changed columns are saved.** Generation is deterministic, so a
  column that was never edited is generated again instead of read; a
  world's save is tiny (a few KB per edited column) and saving costs
  nothing while exploring. `COLUMN.modified` is set by `world_set_block`
  (edits and flowing liquids) and cleared when the column is written.
* **Region files** of 32 × 32 columns (Minecraft-like): a 3-sector header
  table, records in whole 4 KB sectors; a record that no longer fits its
  sectors moves to the end of the file (the old space is not reused yet);
  the table entry is written after the record. One SRW lock serialises all
  region access; a 16-slot cache keeps headers.
* **Compression:** our own LZ77 (LZ4-like token format, greedy, 4096-entry
  hash), in asm (`src/core/lz.asm`); sections are first written as a
  palette + one byte per block when they have ≤ 256 kinds of block. A
  typical edited column: 25 KB.
* **When:** an edited column is written on the main thread as it unloads
  (so edits survive moving away, fixing M16's known issue), every
  `autosave_minutes` (world.cfg, default 5) together with `world.dat` and
  `player.dat`, and on exit. Saving one column takes ~1–3 ms.
* **Loading** happens in the generation job: the column is generated as
  usual (biome tints and everything else derived from it exist), then its
  saved sections replace the generated ones before it is published. A
  damaged record or region file is logged and the column is generated.
* **Text for metadata:** `world.dat` / `player.dat` use the data-file
  format (readable, versioned with `format_version`), written to a
  `.tmp` file and renamed over the old one.
* The save system reads the simulation's state (player, clock) directly;
  with a separate server this moves to the server side as is.
* Not done yet: reusing freed sectors, saving liquid updates still
  pending, saving in a background job.

## D89 — Menus: SDF text, glass panels, immediate-mode widgets, game states (M17 part 2a)
* **Font:** a signed-distance-field atlas (Inter SemiBold, OFL) made by
  `tools/make_sdf_font.py`: printable ASCII in 48 px cells at 34 px/em, 6 px
  of distance on each side, distances computed against the outline at 8×
  resolution (numpy only). The shader thresholds at 0.5 with `fwidth`
  antialiasing, so one atlas is crisp from 12 to 150 px; bold = a lower
  threshold, shadows = the same glyph offset with a soft ramp.
* **One renderer for menus and HUD** (`ui_draw.asm`, `ui.vert/frag`): a
  per-frame batch of 64-byte quads in a storage buffer (vertex pulling, one
  draw): rounded rectangles (SDF box: gradients, borders), glyphs, glass
  panels, soft glows/shadows, images. UI units: a 1280 × 720 design canvas
  scaled to the window (the canvas widens with the aspect ratio).
* **Glass:** the finished frame is blitted down to 1/4 and 1/16 size (linear
  filtering) only when a glass quad is queued; the panel samples it with a
  5 × 5 tent, darkens and tints it, adds a sheen and a light border. Cheap
  (two small blits) and shows clouds and bloom too.
* **Widgets** are immediate mode (`ui.asm`): a screen calls `ui_button`
  etc. every frame; a widget id keeps only its hover animation. Clicks act
  on press. The menus never act themselves: `menu_frame` returns an action
  (`MA_*`) for `game.asm`.
* **Game states** (`game.asm`): the menus run over a real world (seed, time
  and camera path from `data/ui/menu.cfg`, never saved, no simulation); a
  world being played can be paused (no ticks, the world blurred behind the
  pause menu). Switching worlds = save, `stream_reset` (unload every column;
  changed ones are saved), `lod_reset` (tables kept, tiles freed), empty the
  liquid / edit queues and the packet queues, then open the next world
  (seed, spawn or saved player, time) — no restart needed. Command-line
  development options still start straight in a world, so tests and
  screenshots are unchanged.
* The HUD (crosshair, held block on a glass pill) moved to the same renderer.

## D90 — World list, thumbnails, world creation, deleting (M17 part 2b)
* **Thumbnails:** while a world is played (not paused) the finished frame,
  before the HUD, is blitted every 2 s into a 256 × 144 texture
  (`thumb.asm`); every save reads it back (`glGetTextureImage`) and writes
  `thumb.png` into the world folder. Our own PNG writer (`png_write.asm`)
  uses *stored* deflate blocks: no compressor needed, any viewer opens it,
  and the 110 KB per world is cheap next to region files. The world list
  decodes each picture with the existing PNG decoder into one 2048 × 1152
  atlas (8 × 8 cells, `g_ui_images_tex`), so the whole list is still one
  UI draw.
* **World metadata** lives in `world.dat` (new keys `difficulty`,
  `hardcore`, `last_played`; `game_mode` now read back). The world list
  reads only `world.dat` per world (`save_peek`), walks the folder for its
  size on disk and sorts newest `last_played` first (ISO-like
  `YYYY-MM-DD HH:MM` sorts as text). Older saves without the keys show as
  Creative / Normal and sort last.
* **Rules not built yet** (survival modes, difficulties, hardcore) are
  shown greyed out as the design asks, but the world still stores them, so
  worlds made now keep their settings when those modes arrive.
* **Folder names:** the typed name becomes the folder name: printable
  ASCII without `< > : " / \ | ? *`, no leading/trailing spaces or
  trailing dots, at most 32 characters, Windows device names (`CON`,
  `COM1` …) get a `_`; an empty name becomes "World N"; a taken name gets
  " (2)", " (3)" ….
* **Seeds:** empty = random (clock); a whole number (optionally negative)
  = that number (32 bits); any other text = its FNV-1a hash, so a word
  always gives the same world.
* **Deleting** asks first (a modal question over the dimmed list; the list
  behind it takes no mouse), then removes every file and folder of the
  world recursively (`DeleteFileA` / `RemoveDirectoryA`).
* **Text fields** (`ui_textfield`): immediate mode like the buttons; a
  click gives the keyboard focus, typed characters (WM_CHAR, printable
  ASCII = the font's range) and Backspace edit, Enter reports back; a
  blinking caret.

## D91 — Settings screen: live apply, write-back keeping comments (M17 part 2c)
* **Rows are data** (`settings_screen.asm`, `SROW` tables): a label, the
  variable and its kind (toggle, range with a step, a list of allowed
  values with names, hundredths of a float, float toggle) and what a change
  touches. One stepper/toggle widget draws them all; adding a setting is a
  table line plus its key in the file's parser.
* **Live apply:** everything read per frame changes at once (effects,
  culling, water, fog, lighting flags, FOV, keys, sensitivity). Shadows
  are rebuilt on the spot (`shadow_apply`: the program and maps are made on
  first need, the maps again when the resolution changes; off just stops
  the passes). Render and LOD distance apply when the screen closes, once,
  instead of on every click: the streamer rebuilds its spiral (made once
  for the largest distance, so no memory is lost) and lets columns stream
  in or out; the LOD rings are reset (they start at the render distance).
  `opaque_leaves` is baked into the block registry and the meshes, so it
  says it needs a restart.
* **Presets** (Low / Medium / High / Ultra) set 11 values; the matching
  preset is highlighted, otherwise "Custom". High = the old defaults; Ultra
  = 24 chunks + 128 LOD + 4096 shadows. They will be tuned against the FPS
  targets in milestone 33.
* **Write-back** (`cfg_rewrite`): the file is read line by line and only
  the value text of known keys is replaced (a comment after a value
  stays); missing keys are appended; written via `.tmp` + rename. So the
  hand-written explanations in the cfg files survive the settings screen.
* **Rebinding:** two keys per action as in `controls.cfg`; a click on a
  slot waits for the next key or mouse button that has a name (starting
  the frame after the click, so the click is not taken as the key); Delete
  unbinds, Esc cancels. Esc can therefore not be bound from the screen
  (it stays the menu key unless edited in the file).
* **game.cfg** is new for player-facing game options (FOV, autosave, HUD);
  `autosave_minutes` moved there from `world.cfg`, which describes the
  world, not the player's preferences.

## D92 — Versions and named releases
* `data/version.cfg` holds the version, `0.<milestone>.<part>` (part 0 =
  the whole milestone; parts as in PROGRESS.md), and a short title. It is
  bumped with every milestone part that changes the game.
* CI (`build.yml`) publishes, on the default branch, a permanent release
  `VoxelB v<version> - <title>` (tag `v<version>`, zip
  `voxelb-v<version>-windows.zip`, notes = the commits since the previous
  version) the first time a version number appears; "Latest build" stays
  the rolling newest build. Versioned releases are not marked "latest",
  so GitHub's Latest still means the newest build.
* Past milestones were rebuilt from their last commits by the
  `release-history.yml` workflow (list in `tools/release_history.txt`,
  v0.1.0 – v0.16.0); it skips versions that already have a release.
* The main menu's footer shows "v<version> - <title>".

## D93 — Items, inventory, icons, the item in hand (M18 part 1)
* **Every block is an item** automatically (zero data needed for 600+
  block items); `data/items/*.items` add non-block items and Creative tabs.
  Tabs pick block items by name patterns, so a new block lands in a tab
  without touching item files; anything unmatched goes to the last tab.
* **The inventory belongs to the simulation** (D85): 36 slots + the
  carried stack, slot = 8 bytes (item, count, durability). The client sends
  intents (select, pick, click, Creative set) and draws its copy, which the
  simulation updates with one packet per changed slot at the end of a
  tick. Placing uses the simulation's item in hand (the client's block id
  is ignored), so a networked client cannot place what it doesn't hold.
* **Icons are drawn once** at start-up into a 2048 × 1280 atlas
  (64 px cells) with a small vertex-pulling shader that reads the same face
  and texture buffers as the chunks: isometric cubes, half-height slabs,
  flat pictures for plant-like shapes; ~15 ms for 639 items. The UI draws
  them as a new quad kind from that atlas (still one draw call).
* **The item in hand** is drawn over the finished frame with its own fixed
  70° projection (so the FOV setting doesn't stretch it); only faces
  turned to the eye are emitted, so no depth buffer is needed. Light =
  daylight (or the held light), sway by walking speed, a 0.25 s swing on
  break / place.
* **Creative inventory:** icon tabs + search (substring of the shown
  name, across all tabs) + a 12 × 5 scrolling grid; the world keeps
  running behind the screen, the player stands still.

## D94 — Mining, drops, Survival before M20 (M18 part 2)
* **Mining data is pattern-based** (`data/items/mining.cfg`): ~26
  materials cover 2288 block ids by name pattern or shape, so new blocks
  get sensible hardness without data changes; per-block drop overrides in
  one `[drops]` list. The rules are Minecraft's (hardness × 1.5, × 5 when
  not harvestable, ÷ the right tool's speed) because the design asked for
  the classic pace and those numbers are proven.
* **The simulation mines** (dig.asm): the client only says "break is held
  on block x, y, z" in its input packet each tick; the simulation counts
  the time with the item in hand, breaks the block through the normal edit
  path (reach, liquids, door halves) and spawns the drop. Progress goes to
  the client for the cracks (a procedural shader: iso-lines of a pixel-grid
  value noise that widen with progress; no crack textures needed).
* **Dropped items** (drops.asm) are simulation entities in a fixed table of
  512: points with a small radius against block collision (any colliding
  block counts as a cube), gravity, drag, ground friction, rest detection
  (resting drops cost nothing and send nothing), merging of resting stacks,
  a 3-block magnet and a 1.5-block pickup into the inventory, 5-minute
  lifetime. Moving drops send their position each tick; the client glides
  to it and draws a spinning, bobbing cube or picture (one draw per drop,
  lit like the terrain, depth-tested in the scene). Not saved with the
  world (they would have despawned anyway on most reloads).
* **Survival before milestone 20** (owner's choice): selectable in world
  creation; no flying, real mining times, drops, placing uses items,
  Creative-only packets are refused; health and hunger come in M20.
* `--world "Name with spaces"` is now parsed with its quotes (a quote in a
  folder name made the region files unwritable).


## D95 — Recipes, crafting windows, chests (M18 part 3)
* **Recipe files** (`data/recipes/*.recipes`, DATA_FORMAT.md): shaped
  recipes (letter keys, `.` empty, matched anywhere in the grid and
  mirrored), shapeless `ingredients`, a `station` that limits a recipe to
  one crafting block. Every ingredient is an item **name pattern**, so
  "any planks" is `*_planks` and needs no tag system. One record with
  `each = *_planks` becomes one recipe per kind of planks, `{}` standing
  for the wood (`only` narrows it): the 19 woods' slabs, stairs, fences,
  doors ... are 12 records, not 228, and a new wood gets its recipes with
  no recipe changes. Copies that name a block a wood doesn't have drop out
  silently. 317 recipes come from 3 small files; reading them takes ~16 ms.
  Debug builds check 11 known grids (mirrored stairs, shapeless, `each`,
  no match) at start.
* **Windows are inventory slots.** The crafting grid (37–45), the result
  (46) and a container's slots (47–100) are slots of the simulation's
  inventory, so every click (take, put, half, one, shift) works on them
  without new code and reaches the client as the usual slot packets. The
  simulation owns which window is open (2 × 2 by hand on E, a station's
  3 × 3 on right click, a chest) and closes it when the player walks more
  than 8 blocks away or the block is gone. Closing puts the grid and the
  carried stack back into the slots (dropping what doesn't fit). They are
  also saved in player.dat (slots 36–45), so quitting with a full grid
  loses nothing.
* **Crafting is checked by the simulation**: the result slot shows what the
  grid makes; taking it uses one of each grid item; shift takes as many as
  fit. The **recipe book** lists what the grid and station allow and can be
  made from what you have (slots + grid; rebuilt only when a slot
  changes). A click asks the simulation to lay the recipe out (it plans on
  a copy of the counts first, so a set is placed whole or not at all);
  shift lays out as many sets as there is material and stack room.
* **Containers** (`[container]` records next to the stations): a chest's
  contents live in the simulation keyed by block position (4096 entries,
  made when first opened), saved in `saves/<world>/containers.dat` (text)
  while they hold anything. The open window shows a copy that is written
  back on close and before every save. Two chests side by side with the
  same facing open as one 54-slot chest, the lower x / z first whichever
  half is clicked. Breaking a chest (Survival or Creative) closes its
  window and drops its items.
* **`shape = facing`**: a cube with 4 states whose side textures are
  turned at load time (the `north` texture is the front), so the mesher,
  culling and LOD still see a plain cube. Placing one turns the front to
  the player (the simulation uses the yaw of the latest input). Stairs,
  doors etc. still place in their first state (known issue since M16).

## D96 — Tools, smelting, repair (M18 part 4)
* **Tools are item data**: 32 records (4 types × 8 tiers) with speed, tier,
  durability, repair material and binding; recipes are the familiar shapes.
  A slot's durability field is the **wear** (uses spent, 0 = new), so a new
  tool needs no setup and every item without durability ignores it. Wear
  grows by one per block broken that took time; at the tool's durability it
  breaks. Wear travels with the item everywhere it moves (cursor, grids,
  chests, dropped items, player.dat): a worn tool never joins a stack.
* **Furnaces are containers with a fire** (`[furnace]` records; slots
  input / fuel / output in the container store, plus burn and cook
  counters). Every used furnace ticks in the simulation each tick, near or
  far, so it keeps working while you're away (as designed); the open
  window shows the live slots (no copy) and gets the progress each tick.
  Speed multiplies cooking and burning, so the blast furnace is twice as
  fast for the same fuel per item. A burning furnace swaps to its `lit`
  block (same facing; light 13/14 warm orange, a glowing mouth texture), so
  the world shows which furnaces are working; an unloaded one swaps when it
  is next loaded.
* **Smelting and fuels are data** (`[smelt]`, `[fuel]`): 10 smelts (six
  bars, glass, stone, smooth stone, bricks), fuels coal 80 s, wood 15 s,
  sticks 5 s (the design's numbers). Mythril and adamantite need the blast
  furnace; gem ores drop the gem.
* **Repair happens in the Tinker's table's crafting grid** (`repair = 1`):
  one worn tool plus 1–3 pairs of its material and binding (one item per
  cell) show the repaired tool as the result — no separate repair screen,
  and the table still crafts like a workbench (star essence is made only
  there). A third of the durability per pair, rounded up.
* **Chance drops** (`[bonus]` in mining.cfg) give the binding materials:
  plant fibre 20 % from grasses / 35 % from vines and reeds, resin 10 %
  from logs; crystal sprouts always drop a crystal shard. The dice are the
  simulation's own (xorshift), not the client's.

## D97 — The adventurer's journal UI, off hand, dragging (M18 part 5)
* **The owner's art direction** (design/ui/journal_ui.md): every screen is
  a leather-bound journal with cream parchment pages, sepia ink and brass,
  the smooth font kept. Implemented as a **skin**, not per-screen art: a
  generated pixel-art atlas (`tools/texgen/uigen.py` → `journal.png` +
  `journal.cfg`) and one new quad kind in the UI renderer, a textured
  9-slice whose border keeps its size and whose middle tiles at the
  piece's scale (nearest sampling: crisp pixels at any window size). The
  widgets (`ui_panel`, `ui_button`, `ui_textfield`, new `ui_book`,
  `ui_page`, `ui_checkbox`) draw with it, so every menu changed at once;
  the palette constants became ink / leather / wax / brass. Text shadows
  adapt: dark ink gets a pale "pressed into paper" highlight, light text a
  dark shadow.
* **The inventory is a two-page book**: the right page is always the
  player's (title, crafting area with the off-hand slot, inventory,
  hotbar); the left page holds the recipe book, the Creative catalog
  (tabs as ribbon bookmarks over the book's edge), a chest or a furnace —
  or there is no left page (recipe book closed). The recipe book's
  open/closed state is a game.cfg setting the game writes when toggled.
* **Off hand = slot 101**, after the window slots (the existing slot
  numbers in saves stay valid). Placing takes the main hand's block, else
  the off hand's; the held light takes the brightest of both hands' block
  light (the old debug light still works); the first-person view draws
  the off-hand item mirrored to the lower left without the swing.
* **Dragging is decided by the client, done by the simulation**: the
  screen collects the slots the mouse passes while the button is held
  (Shift + left: even split; right: one each) and sends one
  PKT_C_INV_DRAG on release; the simulation skips slots that can't take
  the item (full, other item, result, furnace output) and splits what is
  carried among the rest. A drag over a single slot is a plain click.

## D98 — Animals: entities, regions on disk, box models (M19)
* **One entity table in the simulation** (8192 slots, 128 bytes each; the
  slot is the id the client knows). An animal belongs to the **entity
  region** it stands in (32 × 32 columns, like the block region files),
  kept in memory while needed and saved as its own small file
  (`e.<rx>.<rz>.vxe`): block regions only store edited columns, but
  animals must always persist (owner: "always saved, nothing despawns"),
  and a per-region file keeps saving proportional to where the player has
  been. Regions load on demand (an animal walks in; the land near the
  player is checked for herds) and are saved and dropped 768 blocks away.
* **Herds are placed once per column**, when it is first generated near
  the player (6 columns), seeded by the world seed and the column, so the
  same world gets the same herds; a bit per column in the region file
  remembers it. Biome: the blend map's biome at the column's centre. A
  slow trickle (every 30 s, a column 3–6 away with no animals around)
  rolls again so hunted land refills. Herds stand on the first opaque
  ground from the top (not on leaves, not in water).
* **Awake within 128 blocks** of the player on generated ground: think,
  move, sent to the client when they change; the rest are frozen and the
  client forgets them (ids are reused only after a "gone" packet).
* **Bodies use the player's block collision** (physics.asm boxes): a box
  of the mob's size, gravity, a jump into 1-block steps, floating in
  water. Part 1 thinking is local (idle / wander a few blocks / flee),
  with a look-ahead that refuses drops of more than 3 blocks and lava;
  paths (A*) come in part 2.
* **Models are boxes from data files**, drawn by **vertex pulling**: each
  box is a 96-byte record (position, yaws, pivot, corner, size, skin
  place, light) in a ring of three storage buffers; mob.vert builds the
  36 vertices (one draw for every animal, and the same records into the
  shadow cascades). Skins are one 64 × 64 texture array, a layer per
  variant, painted by a generator that works in model space so spots run
  across boxes.
* **Animal light without a CPU light grid**: the world's light lives in
  per-quad GPU words, so the client looks at the blocks above an animal
  every 16 frames (open sky, leaves, roof with open sky beside, closed)
  for its sky light; sun shadows come from the cascades as for blocks;
  block light only from the held light (torches near animals: later).
* **The client glides and animates**: positions and angles glide to the
  latest tick, the stride follows the walking speed, the legs the
  distance walked; a dying animal tips over red for a second, then drops
  its loot. Clicking an animal nearer than the targeted block hits it
  (PKT_C_ATTACK); the simulation checks the reach.

## D99 — Animal paths and behaviour (M19 part 2)
* **A\* over block cells** (pathfind.asm): a cell is where feet can be (the
  body's height in blocks free of collision and lava, ground below or water
  at the feet). 8 directions without corner cutting, 1-block step-ups (room
  above the head first), drops of up to 3; costs 10 / 14 / +6 up / +2 per
  block down / +20 in water; octile + height estimate; a binary heap of
  `f << 12 | node` dwords and an open-addressing cell hash. Bounded: 480
  cells, 24 blocks from the start; if the goal isn't reached the path
  leads to the cell that got closest (a flight, a chase or a wander still
  progresses). Paths keep 16 waypoints and are worked out again on a timer
  for moving targets; **at most 3 paths per tick** — the others wait a
  tick, so a crowd never makes a tick slow. This replaces part 1's cliff
  look-ahead.
* **Behaviour is a priority list** evaluated every tick (behave.asm):
  running away, sleeping, love, following food, gathering at night, a baby
  near a grown-up, then idle / wander / graze. Love outranks following a
  player who holds food, so fed animals pair up even while the player
  still holds wheat.
* **Herds have ids** given when a herd is placed (random, never 0), saved
  in the entity record; babies get their parents'. Herd centres are summed
  once a second over the awake animals (hash of 512 herds). Strays wander
  back, everyone gathers at night, a hurt animal's herd within 16 blocks
  runs too.
* **Grazing edits the world** through the simulation's own block edits
  (edit_apply, so the client remeshes as for any edit): grass block →
  dirt; a list (512) brings the grass back after 1–3 minutes if it is
  still dirt. The list is not saved: a patch grazed just before quitting
  stays dirt until the player changes it.
* **Wheat before farming**: wild wheat, a new plant in plains, meadows and
  the steppe, drops wheat (the cows' food, design doc "forage").
* **Testing breeding without aiming**: `--breed-test` feeds every awake
  grown-up 5 seconds in (logged); births are logged at INFO.

## D100 — Hides, drying racks, sheep, pigs, boars, chickens (M19 part 3a)
* **Drying racks are a station kind** (`[rack]` in the recipe files,
  STATION_RACK): the rack's look is the state of the work — an empty
  rack, a rack with a wet hide, a rack with a dry one are three blocks
  named in `hang` lines, so the world itself (and its region files) shows
  and keeps what hangs. Only the timer lives in racks.asm (256 racks), is
  advanced once a second and saved in `racks.dat` by input item name; a
  rack whose block changed (broken) is simply forgotten — the block's own
  `[drops]` give the hide back. Any number of hide kinds can share a rack
  (deer and rabbit hides in part 3b are data lines).
* **Two bonus lines per block** in `mining.cfg` (grass: plant fibre and
  seeds), rolled independently; a second table rather than a general list,
  since no block needs three.
* **Coats are parts, not skins**: a sheep's fleece is a `coat`-motion box
  around a smaller shorn body. Shearing sets one flag (EF_SHEARED, sent to
  the client as EPF_SHEARED, saved as bit 2 of the record flags) and the
  renderer skips coat boxes — no second skin per sheep. The wool given is
  the variant's `coat` item; the death drop `coat` reuses it, so one
  data line ties look and wool together. The coat grows back on the
  next successful graze (the design's "regrows after grazing").
* **Mixed herds** (`mix` in a spawn rule): each placed animal rolls for
  another look of the same mob by percent, from the column's seeded
  random numbers — still deterministic per seed. Breeding already keeps a
  parent's look, so mixed flocks stay mixed.
* **Fierce animals** (boars) get a seventh AI state, CHARGE, taking
  priority over everything for up to 6 s after a hit: a path to the
  player at 2.4 × speed (straight at them when no path), and within 1.4
  blocks a knock-back of the player (9 blocks/s away, 5.5 up) through the
  player's velocity, then a 1.5 s back-off. No damage until survival
  health (M20); the herd does not join in (a sounder that all charges
  would make boars unapproachable).
* **Wings are a per-box roll**: the instance record grew from 96 to 112
  bytes (a seventh vec4: the box's roll about its pivot's Z axis), used by
  `wing0`/`wing1` parts while the animal is off the ground (EPF_AIR).
  `glide` clamps the fall speed in the simulation.
* **Laying is a per-animal countdown** (EntT.lay, not saved: after a load
  each layer starts a fresh 5–10 minute wait), dropping the item as a
  normal item drop at the animal.
* **Pigs and boars are two mobs**, not variants: temper is per mob, and
  pigs and boars should not breed into each other.
* **`--mob-gallery [name]`** places one of every look (or one animal's /
  one look's) in a row in front of the player — for screenshots and for
  tests that need an animal within reach without aiming the mouse.
