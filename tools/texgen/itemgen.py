#!/usr/bin/env python3
"""VoxelB item picture generator (milestone 18).

Draws the pictures of items that are not blocks as 16x16 pixel art in the
same hand-shaded style as the block textures (texgen.py's palette ramps),
with a dark outline so they read well on any slot, and writes them to
assets/textures/items/<name>.png.

    python3 tools/texgen/itemgen.py            # everything
    python3 tools/texgen/itemgen.py coal       # only these
    python3 tools/texgen/itemgen.py --list

Deterministic: the same script always produces the same pixels.
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
from texgen import ramp, rng  # noqa: E402

N = 16
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "textures", "items")


def save(name, img):
    os.makedirs(OUT, exist_ok=True)
    a = (np.clip(img, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    Image.fromarray(a, "RGBA").save(os.path.join(OUT, name + ".png"))


def outline(img, color=(0.08, 0.06, 0.1)):
    """A 1-pixel dark outline around the opaque shape."""
    a = img[:, :, 3] > 0.5
    edge = np.zeros_like(a)
    for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        edge |= np.roll(np.roll(a, dy, 0), dx, 1)
    edge &= ~a
    img[edge] = (*color, 1.0)
    return img


def shape_mask(rows):
    """rows: strings of '.' (empty) and digits 0-9 (palette index)."""
    m = np.full((N, N), -1, dtype=int)
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch != ".":
                m[y, x] = int(ch)
    return m


def paint(mask, pal, r=None, jitter=0):
    img = np.zeros((N, N, 4))
    for y in range(N):
        for x in range(N):
            k = mask[y, x]
            if k < 0:
                continue
            if r is not None and jitter:
                k = int(np.clip(k + r.integers(-jitter, jitter + 1), 0, len(pal) - 1))
            img[y, x, :3] = pal[k]
            img[y, x, 3] = 1.0
    return img


# a cut gem, facets light (top left) to dark (bottom right)
GEM = [
    "................",
    "................",
    "....44445554....",
    "...4455555554...",
    "..445555555544..",
    "..334455554433..",
    "...3344554433...",
    "....33344333....",
    ".....233332.....",
    "......2332......",
    ".......22.......",
    "................",
    "................",
    "................",
    "................",
    "................",
]


def gem(name, base):
    pal = ramp(base, n=6, spread=0.22)
    m = shape_mask(GEM)
    img = paint(m, pal)
    # a sparkle on the upper facet
    img[3, 6, :3] = (1.0, 1.0, 1.0)
    img[4, 5, :3] = 0.85 + 0.15 * pal[5]
    img = np.roll(img, 2, axis=0)
    return outline(img)


def coal():
    r = rng("coal_item")
    m = shape_mask([
        "................",
        "................",
        "................",
        ".....3344.......",
        "....234455......",
        "...12344554.....",
        "...123345543....",
        "..11223344432...",
        "..112233343321..",
        "...1122333221...",
        "....11222211....",
        ".....11111......",
        "................",
        "................",
        "................",
        "................",
    ])
    pal = ramp("33343c", n=6, spread=0.35, sat_boost=0.6)
    img = paint(m, pal, r, jitter=1)
    for y, x in ((5, 7), (7, 9), (6, 5)):      # glints
        img[y, x, :3] = (0.62, 0.64, 0.7)
    return outline(img, (0.03, 0.03, 0.04))


def star_crystal():
    # a glowing four-pointed crystal, pale gold with a white core
    m = shape_mask([
        "................",
        ".......5........",
        ".......5........",
        "......454.......",
        "......454.......",
        ".....34543......",
        "..2334555433....",
        ".12345555543321.",
        "..2334555433....",
        ".....34543......",
        "......454.......",
        "......454.......",
        ".......5........",
        ".......5........",
        "................",
        "................",
    ])
    pal = ramp("f2c94c", n=6, spread=0.18)
    pal[5] = (1.0, 0.98, 0.9)
    return outline(paint(m, pal), (0.25, 0.14, 0.05))


ITEMS = {
    "coal": coal,
    "diamond": lambda: gem("diamond", "37d6e0"),
    "emerald": lambda: gem("emerald", "2fcf6a"),
    "star_crystal": star_crystal,
}


def main(argv):
    if "--list" in argv:
        print("\n".join(sorted(ITEMS)))
        return
    names = [a for a in argv if not a.startswith("-")] or sorted(ITEMS)
    for name in names:
        save(name, ITEMS[name]())
        print("item", name)


if __name__ == "__main__":
    main(sys.argv[1:])
