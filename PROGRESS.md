# Progress

## Current state
**Milestone 1 — Toolchain + build.bat; Win32 window, message loop, clean exit; logging: DONE**

Next: **Milestone 2: OpenGL 4.6 core context via WGL, GL loader, clear color,
vsync toggle, timing/FPS.**

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
* Under Wine/Xvfb (no window manager), `DestroyWindow` takes about 2 s. This
  is a Wine/X11 quirk; it is not expected on Windows. Confirm on real Windows.
* Not yet run on real Windows. Please run `build.bat run` once and check
  that the window opens and Esc closes it.

### Deferred
* SEH unwind info (`.pdata`) for our procedures; see DECISIONS.md D4.
* Rebindable keys: M3. Esc-to-quit is hardwired until the input system
  exists. Once there is a pause menu, Esc will open it instead.
* Window settings (size, fullscreen) from a config file: settings menus (M17).
