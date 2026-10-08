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
Pushes to `main` replace the public **"Latest build"** release (tag `latest`)
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

## D15 — Temporary hardwired keys (M2)
F8 toggles vsync and Esc quits. Both are hardwired in the WndProc until M3's
rebindable input system replaces them with bindings. `--novsync` starts with
vsync off.
