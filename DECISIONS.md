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
