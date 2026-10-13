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


def stick():
    # a diagonal twig, light wood with a darker underside
    rows = ["................"] * N
    rows = [list(r) for r in rows]
    for i in range(10):
        x, y = 3 + i, 12 - i
        rows[y][x] = "4"
        rows[y + 1][x] = "2"
        if i % 4 == 1:
            rows[y][x] = "5"
    pal = ramp("a8794a", n=6, spread=0.16)
    return outline(paint(shape_mask(["".join(r) for r in rows]), pal), (0.18, 0.1, 0.05))



# ---- tools (milestone 18 part 4): a diagonal handle with a head per type,
# coloured by tier. Polar shapes around the handle's foot keep the four
# types consistent.
TIER_COLOURS = {
    "wooden": "b8864b", "stone": "8d939b", "copper": "e07a3a", "iron": "d0d6de",
    "diamond": "4ae0e8", "mythril": "3a8aff", "adamantite": "e8343a",
    "star_crystal": "f2c94c",
}
FOOT = (3.0, 12.0)                     # the handle's lower end (x, y down)


def polar(x, y):
    dx = x + 0.5 - FOOT[0]
    dy = FOOT[1] - (y + 0.5)
    r = (dx * dx + dy * dy) ** 0.5
    a = np.degrees(np.arctan2(dy, dx))
    return r, a


def tool(kind, tier):
    head = ramp(TIER_COLOURS[tier], n=6, spread=0.2)
    wood = ramp("8a5a30", n=6, spread=0.18)
    img = np.zeros((N, N, 4))
    reach = {"pickaxe": 10.4, "axe": 10.6, "shovel": 7.0, "hoe": 10.8}[kind]
    for y in range(N):
        for x in range(N):
            r, a = polar(x, y)
            on_handle = abs(a - 45) * r / 57.3 < 0.75 and r <= reach
            h = None
            if kind == "pickaxe":
                if 8.6 <= r <= 10.9 and 8 <= a <= 82:
                    h = (r - 8.6) / 2.3
                    if abs(a - 45) > 30 and r > 10.0:
                        h = None             # tapered points
            elif kind == "axe":
                if 6.0 <= r <= 11.2 and 47 <= a <= 47 + (r - 4.0) * 5.2:
                    h = (a - 47) / 40
            elif kind == "shovel":
                # a rounded blade on the handle's line
                cx, cy = FOOT[0] + 7.6 * 0.7071, FOOT[1] - 7.6 * 0.7071
                u = (x + 0.5 - cx) * 0.7071 - (y + 0.5 - cy) * 0.7071   # along
                v = (x + 0.5 - cx) * 0.7071 + (y + 0.5 - cy) * 0.7071   # across
                if abs(v) <= 2.7 and -1.2 <= u <= 4.4 and (u < 2.6 or abs(v) < 4.6 - u):
                    h = (u + 1.2) / 5.6
            elif kind == "hoe":
                if 9.4 <= r <= 11.2 and 45 <= a <= 74:
                    h = (a - 45) / 29
                elif 7.6 <= r <= 9.4 and 68 <= a <= 76:
                    h = 0.9                  # the blade's tip bends down
            if h is not None:
                k = int(np.clip(5 - h * 4.2, 0, 5))
                img[y, x, :3] = head[k]
                img[y, x, 3] = 1.0
            elif on_handle and r >= 0.4:
                d = (a - 45) * r / 57.3      # across the handle
                img[y, x, :3] = wood[3 if d > 0 else 1]
                img[y, x, 3] = 1.0
    if tier == "star_crystal":
        for y in range(N):
            for x in range(N):
                if img[y, x, 3] > 0 and (x + y) % 5 == 0 and polar(x, y)[0] > 7:
                    img[y, x, :3] = (1.0, 0.98, 0.9)
    return outline(img, (0.1, 0.07, 0.06))


def bar(base):
    # an ingot seen at an angle: a lit top face and a darker front
    pal = ramp(base, n=6, spread=0.22)
    m = shape_mask([
        "................",
        "................",
        "................",
        "................",
        "................",
        ".....55555555...",
        "....5444444445..",
        "...544444444452.",
        "..3333333333322.",
        "..3333333333321.",
        "..2222222222221.",
        "..111111111111..",
        "................",
        "................",
        "................",
        "................",
    ])
    img = paint(m, pal)
    img[6, 6:9, :3] = np.minimum(1.0, pal[5] * 1.15)   # a glint
    return outline(img)


ITEMS = {
    "coal": coal,
    "diamond": lambda: gem("diamond", "37d6e0"),
    "emerald": lambda: gem("emerald", "2fcf6a"),
    "star_crystal": star_crystal,
    "stick": stick,
    "copper_bar": lambda: bar("e07a3a"),
    "iron_bar": lambda: bar("d0d6de"),
    "silver_bar": lambda: bar("e8ecf4"),
    "gold_bar": lambda: bar("ffd23a"),
    "mythril_bar": lambda: bar("3a8aff"),
    "adamantite_bar": lambda: bar("e8343a"),
}
for _tier in TIER_COLOURS:
    for _kind in ("pickaxe", "axe", "shovel", "hoe"):
        ITEMS[f"{_tier}_{_kind}"] = (lambda k=_kind, t=_tier: tool(k, t))


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
