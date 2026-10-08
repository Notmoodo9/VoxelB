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
build\debug\voxelb.exe                    normal run; Esc or the close button quits
build\debug\voxelb.exe --autoclose 3000   closes itself after 3 s (automated tests)
build\debug\voxelb.exe --novsync          start with vsync off
```

Keys (temporary until rebindable input in M3): **F8** toggles vsync, **Esc** quits.
The title bar shows FPS and frame time (avg/min/max over 0.5 s), the vsync
state and the OpenGL version. Requires an OpenGL 4.6 driver (4.5 is accepted
with a warning, e.g. for software renderers).

Every run writes `voxel.log` next to the executable. When started from a
console, the same lines are echoed to it. They also go to the debugger
(e.g. DebugView or Visual Studio's Output window).

Exit codes: `0` clean exit, `1` fatal error (message box + log), `3` assertion
failure (debug builds).

## Adding things

* **New module:** drop a `.asm` file anywhere under `src/`. `build.bat` picks up
  every `*.asm` recursively. File names must be unique across `src/`, because
  all objects go into one folder.
* **New Win32 import:** add the function name to the matching
  `tools/implib/<dll>.def`, then `IMPORT` it in the module. For a new DLL, add a
  new `.def` file; it is linked automatically.

## Continuous integration

Every push and pull request runs `.github/workflows/build.yml` on a Windows
runner. It builds debug and release with `build.bat`, smoke-tests both
(`tools/smoke_test.ps1`, using Mesa's software OpenGL because the runner has
no GPU), and uploads a `voxelb-<sha>` artifact. Pushes to `main` also update
the public **Latest build** release:
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
