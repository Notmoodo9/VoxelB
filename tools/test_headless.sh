#!/usr/bin/env bash
# Headless smoke test (Linux + Wine + Xvfb): launches the game with
# --autoclose, takes a screenshot, and checks for a clean exit.
# Usage: tools/test_headless.sh [debug|release] [autoclose_ms]
# Needs: wine, Xvfb, ImageMagick `import` (optional, for the screenshot).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-debug}
MS=${2:-20000}
EXE=build/$CONFIG/voxelb.exe
LOG=build/$CONFIG/voxel.log
[ -f "$EXE" ] || { echo "missing $EXE - run tools/build.sh $CONFIG" >&2; exit 1; }

export WINEDEBUG=-all
if [ -z "${DISPLAY:-}" ]; then
    export DISPLAY=:99
    if ! xdpyinfo >/dev/null 2>&1; then
        Xvfb :99 -screen 0 1920x1080x24 >/dev/null 2>&1 &
        XVFB_PID=$!
        trap 'kill $XVFB_PID 2>/dev/null || true' EXIT
        sleep 1
    fi
fi

timeout 120 wine "$EXE" --selftest --autoclose "$MS" >/dev/null 2>&1 &
PID=$!
sleep "$(awk "BEGIN{print ($MS/1000)*0.8}")"
if command -v import >/dev/null; then
    import -window root "build/$CONFIG/screenshot.png" && echo "screenshot: build/$CONFIG/screenshot.png"
fi
set +e
wait $PID
RC=$?
set -e

echo "exit code: $RC"
grep -q "window created, client area" "$LOG" || { echo "FAIL: window was not created"; exit 1; }
grep -q "OpenGL core context created" "$LOG" || { echo "FAIL: no OpenGL context"; exit 1; }
grep -q "selftest: PASS" "$LOG"           || { echo "FAIL: self test"; exit 1; }
grep -q "world: quad buffer created" "$LOG" || { echo "FAIL: world GPU buffer not created"; exit 1; }
grep -Eq "blocks: [0-9]+ blocks" "$LOG" || { echo "FAIL: block registry not loaded"; exit 1; }
grep -q "missing or invalid 0" "$LOG" || { echo "FAIL: block textures missing or invalid"; exit 1; }
grep -q "terrain: generator ready" "$LOG" || { echo "FAIL: terrain generator not loaded"; exit 1; }
grep -q "stream: view complete" "$LOG" || { echo "FAIL: streamer never finished the view"; exit 1; }
grep -q "text renderer ready" "$LOG"       || { echo "FAIL: text renderer/shaders did not start"; exit 1; }
grep -q "perf: " "$LOG"                     || { echo "FAIL: no frame timing (perf) line"; exit 1; }
grep -q "clean exit, code = 0" "$LOG"        || { echo "FAIL: no clean exit in log"; exit 1; }
[ "$RC" = 0 ]                                 || { echo "FAIL: exit code $RC"; exit 1; }
echo "PASS ($CONFIG)"
