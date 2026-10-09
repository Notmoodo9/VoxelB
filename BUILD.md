# Building VoxelB

## Toolchain (Windows)

| Tool | Version | Get it |
|---|---|---|
| NASM | 2.15 or newer (tested 2.16.01) | https://www.nasm.us/ — add its folder to `PATH` |
| lld-link | LLVM 15 or newer (tested 18.1.3) | https://github.com/llvm/llvm-project/releases — Windows installer, tick **"Add LLVM to the system PATH"** |
| git | any | https://git-scm.com/ |

**Linker choice:** `lld-link` (LLVM). MSVC `link.exe` is not used. You do **not** need
Visual Studio or the Windows SDK: `build.bat` generates the import libraries for
`kernel32`, `user32`, `gdi32` and `opengl32` from the `.def` files in `tools/implib/`.

Check your tools from a fresh terminal:

```
nasm -v
lld-link --version
git --version
```

## Build

From the repository root, in `cmd` or PowerShell:

```
build.bat                  debug build   -> build\debug\voxelb.exe (+ voxelb.pdb)
build.bat release          release build -> build\release\voxelb.exe
build.bat clean            wipe that config's output first
build.bat run              build, then launch
build.bat release clean run
```

Debug builds define `BUILD_DEBUG=1`: `ASSERT`s are active, `LOG_DEBUG` lines
are emitted, and CodeView debug info plus a PDB are produced. Release builds
compile all of that out and link with `/opt:ref /opt:icf`.

## Run

```
build\debug\voxelb.exe                    normal run (Esc twice, Alt+F4 or the close button quits)
build\debug\voxelb.exe --autoclose 3000   closes itself after 3 s (automated tests)
build\debug\voxelb.exe --novsync          start with vsync off
build\debug\voxelb.exe --workers 2        use 2 job worker threads (default: CPU threads - 1)
build\debug\voxelb.exe --selftest         run the memory/job self test (always on in debug builds)
build\debug\voxelb.exe --flytest          fly straight ahead at 60 blocks/s (streaming stress test)
build\debug\voxelb.exe --pos 10 105 190    start the camera at x y z (blocks)
build\debug\voxelb.exe --look -30 -20      start view: yaw (0 north, 90 east), pitch (degrees, + up)
```

Default controls (rebind in `data/config/controls.cfg`, format in `DATA_FORMAT.md`):

| Key | Action |
|---|---|
| Mouse | look (while captured) |
| W A S D / arrows | fly |
| Space / Shift | up / down |
| Ctrl | fly faster |
| F3 | debug overlay on/off |
| F5 | reload all shaders (they also reload automatically when saved) |
| F8 | vsync on/off |
| Esc | release the mouse; press again (mouse free) to quit |
| Left click | capture the mouse again |

Render distance is set in `data/config/graphics.cfg` (`render_distance`, 2–48
chunks, default 16). Restart after editing.

The game needs its `data`, `shaders` and `assets` folders. It looks for them
next to `voxelb.exe` (the release zip layout) or two folders up (the
`build\<config>\` dev layout). Edit any file in `shaders/` while the game
runs and it reloads within a quarter second. Errors are shown in the overlay
and written to the log, and the last good version keeps running.

Requires an OpenGL 4.6 driver (4.5 is accepted with a warning, e.g. for
software renderers).

Every run writes `voxel.log` next to the executable. When started from a
console, the same lines are echoed to it. They also go to the debugger
(e.g. DebugView or Visual Studio's Output window).

Exit codes: `0` clean exit, `1` fatal error (message box + log), `3` assertion
failure (debug builds), `4` self test failed (see log).

## Adding things

* **New module:** drop a `.asm` file anywhere under `src/`. `build.bat` picks up
  every `*.asm` recursively. File names must be unique across `src/`, because
  all objects go into one folder.
* **New Win32 import:** add the function name to the matching
  `tools/implib/<dll>.def`, then `IMPORT` it in the module. For a new DLL, add a
  new `.def` file; it is linked automatically.

## Textures and blocks

Blocks are defined in `data/blocks/*.blocks` and textured from
`assets/textures/blocks/*.png` (format: `DATA_FORMAT.md`). Edit a PNG while
the game runs and it reloads within a second.

The built-in textures were drawn by a generator script, and the PNGs are
committed, so building never needs Python. To regenerate them (Python 3 with
Pillow and NumPy):

```
python3 tools/texgen/texgen.py              # all textures (overwrites!)
python3 tools/texgen/texgen.py oak_planks   # only the named ones
python3 tools/texgen/texgen.py --list       # list every texture name
```

`tools/make_png_tests.py` regenerates the PNG decoder's self-test images
(`src/include/png_tests.inc`).

## Continuous integration

Every push and pull request runs `.github/workflows/build.yml` on a Windows
runner. It builds debug and release with `build.bat`, smoke-tests both
(`tools/smoke_test.ps1`, using Mesa's software OpenGL because the runner has
no GPU), and uploads a `voxelb-<sha>` artifact. Pushes to the default branch
(currently `claude/keen-lovelace-3ysglx`) also update the public **Latest build** release:
https://github.com/Notmoodo9/VoxelB/releases/download/latest/voxelb-windows.zip

Locally on Windows: `powershell -ExecutionPolicy Bypass -File tools\smoke_test.ps1 -Config debug`.

## Linux (cross-build and headless test)

The same build runs on Linux with the Linux builds of NASM and lld-link:

```
tools/build.sh [debug|release] [clean]
tools/test_headless.sh [debug|release] [ms]   # needs wine + Xvfb + Mesa; checks window, GL context, perf line, clean exit; takes a screenshot
```

`tools/build.sh` mirrors `build.bat` flag for flag. If you change one, change
the other.
