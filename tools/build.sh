#!/usr/bin/env bash
# Linux/CI mirror of build.bat (same tools, same flags): cross-builds the
# Windows executable with NASM + lld-link. Usage: tools/build.sh [debug|release] [clean]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
CLEAN=0
for a in "$@"; do
    case "$a" in
        debug|release) CONFIG=$a ;;
        clean) CLEAN=1 ;;
        *) echo "usage: tools/build.sh [debug|release] [clean]" >&2; exit 2 ;;
    esac
done

OUT=build/$CONFIG
OBJ=$OUT/obj
LIBDIR=build/lib
[ "$CLEAN" = 1 ] && rm -rf "$OUT" "$LIBDIR"
mkdir -p "$OBJ" "$LIBDIR"

if [ "$CONFIG" = debug ]; then
    NASMFLAGS="-f win64 -g -F cv8 -DBUILD_DEBUG=1"
    LINKFLAGS="/debug /pdb:$OUT/voxelb.pdb"
else
    NASMFLAGS="-f win64 -DBUILD_DEBUG=0"
    LINKFLAGS="/release /opt:ref /opt:icf"
fi

LIBS=()
for def in tools/implib/*.def; do
    lib="$LIBDIR/$(basename "${def%.def}").lib"
    lld-link /lib /nologo /machine:x64 /def:"$def" /out:"$lib"
    LIBS+=("$lib")
done

: > "$OBJ/link.rsp"
while IFS= read -r src; do
    obj="$OBJ/$(basename "${src%.asm}").obj"
    echo "nasm $src"
    nasm $NASMFLAGS -I src/include/ -o "$obj" "$src"
    echo "\"$obj\"" >> "$OBJ/link.rsp"
done < <(find src -name '*.asm' | sort)

lld-link /nologo /machine:x64 /subsystem:windows /entry:main_entry /nodefaultlib \
    $LINKFLAGS /out:"$OUT/voxelb.exe" @"$OBJ/link.rsp" "${LIBS[@]}"
echo "BUILD OK: $OUT/voxelb.exe"
