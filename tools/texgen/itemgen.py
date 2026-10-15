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


# ---- weapons (milestone 21): the same diagonal as the tools, coloured by
# tier; a sword's blade with a cross-guard, a spear's long shaft and leaf
# head, a mace's studded ball.
def weapon(kind, tier):
    metal = ramp(TIER_COLOURS[tier], n=6, spread=0.2)
    wood = ramp("8a5a30", n=6, spread=0.18)
    grip = ramp("5a3a28", n=6, spread=0.18)
    img = np.zeros((N, N, 4))
    for y in range(N):
        for x in range(N):
            r, a = polar(x, y)
            d = (a - 45) * r / 57.3                  # across the line
            col = None
            if kind == "sword":
                if 4.8 <= r <= 14.2 and abs(d) <= (1.7 if r < 12.6 else 1.7 * (14.2 - r) / 1.6):
                    col = metal[4 if d > 0.4 else (1 if d < -0.4 else 5)]
                    if abs(d) < 0.4 and r < 12.2:
                        col = metal[3]               # the fuller
                elif 3.4 <= r < 4.8 and abs(d) <= 3.2:
                    col = grip[4] if abs(d) < 0.8 else metal[0]   # cross-guard
                elif r < 3.4 and abs(d) < 0.8 and r >= 0.4:
                    col = grip[3 if d > 0 else 1]
            elif kind == "spear":
                if 10.4 <= r <= 15.2 and abs(d) <= 1.7 * min(1.0, (15.2 - r) / 2.4, (r - 10.0) / 1.2):
                    col = metal[4 if d > 0 else 2]
                elif abs(d) < 0.6 and 0.4 <= r < 10.4:
                    col = wood[3 if d > 0 else 1]
                    if 9.6 <= r < 10.4:
                        col = metal[1]               # the socket
            elif kind == "mace":
                cx, cy = FOOT[0] + 9.6 * 0.7071, FOOT[1] - 9.6 * 0.7071
                dd = ((x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2) ** 0.5
                if dd <= 3.0:
                    k = int(np.clip(5 - (dd / 3.0) * 3.0 - (0 if x + 0.5 > cx else 1), 0, 5))
                    col = metal[k]
                elif dd <= 3.9 and (x + y) % 2 == 0 and abs((x - y) % 3) == 0:
                    col = metal[1]                   # studs
                elif abs(d) < 0.75 and 0.4 <= r < 7.6:
                    col = wood[3 if d > 0 else 1]
                    if r < 2.4:
                        col = grip[2]
            if col is not None:
                img[y, x, :3] = col
                img[y, x, 3] = 1.0
    if tier == "star_crystal":
        for y in range(N):
            for x in range(N):
                if img[y, x, 3] > 0 and (x + y) % 5 == 0 and polar(x, y)[0] > 6:
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



# ---- repair materials and bindings (milestone 18 part 4) ----
def plant_fibre():
    pal = ramp("7cbf3a", n=6, spread=0.2)
    img = np.zeros((N, N, 4))
    for k, (x0, ph) in enumerate(((5, 0.0), (8, 1.3), (11, 2.4))):
        for y in range(2, 14):
            x = int(round(x0 + 1.4 * np.sin(y * 0.55 + ph)))
            img[y, x, :3] = pal[2 + (k + y) % 3]
            img[y, x, 3] = 1.0
    return outline(img, (0.1, 0.18, 0.05))


def resin():
    m = shape_mask([
        "................",
        "................",
        ".......4........",
        "......445.......",
        "......4455......",
        ".....344555.....",
        ".....3445555....",
        "....33445555....",
        "....23344555....",
        "....22334455....",
        "....22233444....",
        ".....222333.....",
        "......2222......",
        "................",
        "................",
        "................",
    ])
    pal = ramp("e89a2a", n=6, spread=0.22)
    img = paint(m, pal)
    img[6, 8, :3] = (1.0, 0.95, 0.75)
    return outline(img, (0.3, 0.14, 0.02))


def crystal_shard():
    m = shape_mask([
        "................",
        "..........5.....",
        ".........45.....",
        "........445.....",
        ".......3445.....",
        "......33445.....",
        ".....233444.....",
        ".....2334.......",
        "....22334.......",
        "....2233........",
        "...1223.........",
        "...122..........",
        "...11...........",
        "................",
        "................",
        "................",
    ])
    pal = ramp("b07af0", n=6, spread=0.22)
    pal[5] = (0.95, 0.9, 1.0)
    return outline(paint(m, pal), (0.15, 0.06, 0.25))


def fibre_binding():
    # a coil of cord, wound round and tied
    pal = ramp("b8a060", n=6, spread=0.2)
    img = np.zeros((N, N, 4))
    for y in range(N):
        for x in range(N):
            dx, dy = x - 7.5, (y - 8.0) * 1.3
            r = (dx * dx + dy * dy) ** 0.5
            if 2.0 <= r <= 6.2:
                band = int(r * 1.6) % 2
                img[y, x, :3] = pal[3 + band] if dy < 0 else pal[1 + band]
                img[y, x, 3] = 1.0
    img[7:10, 12:15, :3] = pal[4]                 # the loose end
    img[7:10, 12:15, 3] = 1.0
    return outline(img, (0.2, 0.14, 0.06))


def flux():
    # a little heap of pale powder with blue-white grains
    m = shape_mask([
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        ".......55.......",
        ".....445554.....",
        "....34455554....",
        "...3344555543...",
        "..233444555432..",
        "..223334444332..",
        "...1122233211...",
        "................",
        "................",
        "................",
    ])
    pal = ramp("c8d8e8", n=6, spread=0.18, sat_boost=0.8)
    img = paint(m, pal, rng("flux"), jitter=1)
    for y, x in ((8, 6), (9, 10), (10, 5), (11, 9)):
        img[y, x, :3] = (0.55, 0.75, 1.0)
    return outline(img, (0.1, 0.12, 0.18))


def star_essence():
    # a small stoppered vial holding a gold-white glow
    m = shape_mask([
        "................",
        "......2222......",
        "......2332......",
        ".......11.......",
        "......1001......",
        ".....155551.....",
        "....15555551....",
        "....15544551....",
        "....15544551....",
        "....15555551....",
        ".....155551.....",
        "......1111......",
        "................",
        "................",
        "................",
        "................",
    ])
    img = np.zeros((N, N, 4))
    cols = {0: (0.6, 0.75, 0.85), 1: (0.55, 0.7, 0.85), 2: (0.45, 0.3, 0.18), 3: (0.6, 0.42, 0.25),
            4: (1.0, 1.0, 0.92), 5: (1.0, 0.82, 0.3)}
    for y in range(N):
        for x in range(N):
            k = m[y, x]
            if k >= 0:
                img[y, x, :3] = cols[k]
                img[y, x, 3] = 1.0
    return outline(img, (0.12, 0.1, 0.18))


def meat(raw):
    """A cut of meat with its bone: red and marbled raw, browned when cooked."""
    r = rng("beef_raw" if raw else "beef_cooked")
    m = shape_mask([
        "................",
        "................",
        "......4455......",
        "....34455554....",
        "...3445555554...",
        "..234455555543..",
        "..2334455555432.",
        "..12334455543321",
        "...1223344433211",
        "....112233322199",
        "......11122219.9",
        "...........99...",
        "................",
        "................",
        "................",
        "................",
    ])
    base = "c8303a" if raw else "8a4a24"
    pal = list(ramp(base, n=6, spread=0.22))
    pal = pal + [pal[0]] * 3 + [np.array((0.94, 0.9, 0.82))]
    img = paint(m, np.array(pal), r, jitter=1)
    # fat marbling (raw) or a seared crust (cooked)
    for y in range(16):
        for x in range(16):
            if img[y, x, 3] > 0 and m[y, x] < 9 and r.random() < 0.07:
                img[y, x, :3] = (0.98, 0.86, 0.84) if raw else pal[1] * 0.8
    img = np.roll(img, 2, axis=0)
    return outline(img, (0.16, 0.05, 0.05) if raw else (0.12, 0.06, 0.03))


def leather():
    r = rng("leather")
    m = shape_mask([
        "................",
        "................",
        "...33.....33....",
        "..3445...5443...",
        "..34455555543...",
        "...445555554....",
        "...344555543....",
        "...344555443....",
        "..2344455443....",
        "..23344554432...",
        "..22333443322...",
        "...22.2332.22...",
        "................",
        "................",
        "................",
        "................",
    ])
    pal = ramp("a0602e", n=6, spread=0.2)
    img = paint(m, pal, r, jitter=1)
    for y, x in ((5, 7), (7, 6), (8, 9)):       # stitching marks
        img[y + 0, x, :3] = pal[1]
    img = np.roll(img, 1, axis=0)
    return outline(img, (0.14, 0.07, 0.03))


def wheat():
    """A bound sheaf of golden wheat ears."""
    r = rng("wheat_item")
    m = shape_mask([
        "................",
        "...5..5...5.....",
        "..454.45.454....",
        "..4544545454....",
        "...44454544.....",
        "....4445444.....",
        ".....44544......",
        "......444.......",
        "......777.......",
        ".....2.2.2......",
        "....2..2..2.....",
        "...2...2...2....",
        "..2....2....2...",
        "..1....1....1...",
        "................",
        "................",
    ])
    pal = list(ramp("e0b04a", n=6, spread=0.22))
    pal += [pal[0]] + [np.array((0.55, 0.32, 0.16))]
    img = paint(m, np.array(pal), r, jitter=1)
    return outline(img, (0.2, 0.12, 0.04))


def hide(base, salted, name):
    """A stretched hide; salted ones are speckled white."""
    r = rng(name)
    m = shape_mask([
        "................",
        "................",
        "...33.....33....",
        "..3445...5443...",
        "..34455555543...",
        "...445555554....",
        "...344555543....",
        "...344555443....",
        "..2344455443....",
        "..23344554432...",
        "..22333443322...",
        "...22.2332.22...",
        "................",
        "................",
        "................",
        "................",
    ])
    pal = ramp(base, n=6, spread=0.2)
    img = paint(m, pal, r, jitter=1)
    if salted:
        for y in range(16):
            for x in range(16):
                if img[y, x, 3] > 0 and r.random() < 0.18:
                    img[y, x, :3] = (0.95, 0.94, 0.9)
    img = np.roll(img, 1, axis=0)
    return outline(img, (0.16, 0.08, 0.06))


def shears():
    m = shape_mask([
        "................",
        "...........55...",
        "..........5445..",
        ".........544.5..",
        "........544..5..",
        ".......5445.5...",
        "......5445.55...",
        ".....4445.......",
        "....2224........",
        "...2.2.24.......",
        "..2..2..44......",
        "..2..2...44.....",
        "...22.....4.....",
        "................",
        "................",
        "................",
    ])
    pal = list(ramp("c0c8d0", n=6, spread=0.2))
    pal[2] = np.array((0.55, 0.22, 0.16))
    return outline(paint(m, np.array(pal)))


def seeds():
    r = rng("seeds")
    img = np.zeros((16, 16, 4))
    pal = ramp("c8b060", n=4, spread=0.25)
    for (y, x) in ((5, 5), (6, 9), (8, 6), (9, 10), (10, 4), (11, 8), (7, 12), (12, 11), (4, 8)):
        img[y, x, :3] = pal[2]; img[y, x, 3] = 1
        img[y + 1, x, :3] = pal[1]; img[y + 1, x, 3] = 1
    return outline(img, (0.25, 0.18, 0.08))


def carrot():
    m = shape_mask([
        "................",
        "..........7.7...",
        "...........77...",
        "..........777...",
        ".........45.....",
        "........4554....",
        ".......45543....",
        "......45543......",
        ".....45543.......",
        "....45543.......",
        "...4543.........",
        "..443...........",
        "..3.............",
        "................",
        "................",
        "................",
    ])
    pal = list(ramp("f07820", n=6, spread=0.22)) + [np.array((0.2, 0.6, 0.2))] * 2
    return outline(paint(m, np.array(pal)))


def berries():
    img = np.zeros((16, 16, 4))
    pal = ramp("d82848", n=5, spread=0.25)
    for (cy, cx) in ((6, 6), (8, 10), (10, 5), (11, 9)):
        for dy in range(-1, 2):
            for dx in range(-1, 2):
                if abs(dy) + abs(dx) < 2:
                    img[cy + dy, cx + dx, :3] = pal[2 + (dy < 0) + (dx < 0)]; img[cy + dy, cx + dx, 3] = 1
        img[cy - 1, cx - 1, :3] = (1, 0.85, 0.85)
    for (y, x) in ((3, 8), (4, 8), (4, 7), (5, 9)):
        img[y, x, :3] = (0.25, 0.55, 0.2); img[y, x, 3] = 1
    return outline(img, (0.22, 0.05, 0.08))


def chunk_meat(base, raw, name):
    """A plain cut (pork, mutton): marbled raw, browned cooked."""
    r = rng(name)
    m = shape_mask([
        "................",
        "................",
        "................",
        "....3445554.....",
        "...344555554....",
        "..23445555543...",
        "..233445555432..",
        "..123344555332..",
        "...12233444321..",
        "....112233221...",
        "......11111.....",
        "................",
        "................",
        "................",
        "................",
        "................",
    ])
    pal = ramp(base, n=6, spread=0.22)
    img = paint(m, pal, r, jitter=1)
    for y in range(16):
        for x in range(16):
            if img[y, x, 3] > 0 and r.random() < (0.12 if raw else 0.06):
                img[y, x, :3] = (0.98, 0.9, 0.86) if raw else pal[1] * 0.8
    img = np.roll(img, 2, axis=0)
    return outline(img, (0.16, 0.05, 0.05) if raw else (0.12, 0.06, 0.03))


def drumstick(raw):
    r = rng("chicken_raw" if raw else "chicken_cooked")
    m = shape_mask([
        "................",
        "................",
        ".....3445.......",
        "....344554......",
        "...34455554.....",
        "...344555543....",
        "...2344555432...",
        "....23345543....",
        ".....2233432....",
        "........2.99....",
        ".........9.99...",
        "..........999...",
        "...........9....",
        "................",
        "................",
        "................",
    ])
    base = "f0b8a0" if raw else "c07838"
    pal = list(ramp(base, n=6, spread=0.2)) + [ramp(base, 6)[0]] * 3 + [np.array((0.95, 0.92, 0.85))]
    img = paint(m, np.array(pal), r, jitter=1)
    return outline(img, (0.2, 0.1, 0.06))


def egg():
    m = shape_mask([
        "................",
        "................",
        "......4455......",
        ".....445555.....",
        "....44555555....",
        "....34455555....",
        "...3444555554...",
        "...3344455554...",
        "...2334444443...",
        "...2233344433...",
        "....22333332....",
        ".....112221.....",
        "................",
        "................",
        "................",
        "................",
    ])
    pal = ramp("e8d4b0", n=6, spread=0.16)
    img = paint(m, pal, rng("egg"), jitter=0)
    img[4, 7, :3] = (1, 1, 0.98)
    return outline(img, (0.3, 0.22, 0.14))


def feather():
    img = np.zeros((16, 16, 4))
    pal = ramp("f4f0e8", n=5, spread=0.12)
    for i in range(11):
        y, x = 13 - i, 3 + i
        img[y, x, :3] = (0.6, 0.55, 0.5); img[y, x, 3] = 1      # the quill
        if i > 2:
            for d in (1, 2):
                if y - d >= 0:
                    img[y - d, x, :3] = pal[2 + (d == 1)]; img[y - d, x, 3] = 1
                if x + d < 16:
                    img[y, x + d, :3] = pal[1 + (d == 1)]; img[y, x + d, 3] = 1
    return outline(img, (0.35, 0.32, 0.3))


def bucket(fill):
    """An iron pail with a handle; filled with water, lava or milk."""
    m = shape_mask([
        "................",
        "....44444444....",
        "...4........4...",
        "..455555555554..",
        "..5999999999935.",
        "..4999999999924.",
        "..34444444444...",
        "...4444444443...",
        "...3444444433...",
        "...3344444433...",
        "....33444433....",
        "....33344333....",
        "....23333332....",
        ".....222222.....",
        "................",
        "................",
    ])
    pal = list(ramp("b8c0c8", n=6, spread=0.24))
    fills = {None: None, "water": "3060d0", "lava": "f06018", "milk": "f0eee4"}
    fc = fills[fill]
    inside = ramp(fc, 4, spread=0.12) if fc else ramp("3a3e46", 4, spread=0.1)
    pal += [inside[1], inside[2], inside[3], inside[2]]
    img = paint(m, np.array(pal))
    # a glint on the liquid
    if fc:
        img[4, 5, :3] = np.minimum(inside[3] * 1.2, 1.0)
        img[4, 6, :3] = np.minimum(inside[3] * 1.2, 1.0)
    return outline(img, (0.1, 0.1, 0.12))


def small_hide(base, salted, name):
    """A small stretched pelt (rabbit)."""
    r = rng(name)
    m = shape_mask([
        "................",
        "................",
        "................",
        "................",
        "....33....33....",
        "....345..543....",
        ".....455554.....",
        ".....345543.....",
        ".....344543.....",
        "....23445432....",
        "....22.33.22....",
        "................",
        "................",
        "................",
        "................",
        "................",
    ])
    pal = ramp(base, n=6, spread=0.2)
    img = paint(m, pal, r, jitter=1)
    if salted:
        for y in range(16):
            for x in range(16):
                if img[y, x, 3] > 0 and r.random() < 0.2:
                    img[y, x, :3] = (0.95, 0.94, 0.9)
    return outline(img, (0.16, 0.08, 0.06))


def antler():
    m = shape_mask([
        "................",
        "..4.....4.......",
        "..4..4..4..4....",
        "...4.4...4.4....",
        "...44.....44....",
        "....4.4....4..4.",
        "....44.....4.4..",
        ".....4.....44...",
        ".....44...44....",
        "......4..44.....",
        "......4444......",
        ".......43.......",
        ".......32.......",
        ".......22.......",
        "................",
        "................",
    ])
    pal = ramp("d8c8a0", n=6, spread=0.2)
    return outline(paint(m, pal), (0.25, 0.2, 0.12))


def goat_horn():
    m = shape_mask([
        "................",
        "................",
        "..........55....",
        ".........5445...",
        "........54..4...",
        ".......544..4...",
        "......5443..3...",
        ".....5443...3...",
        "....5443...3....",
        "...4443...3.....",
        "..4433..33......",
        "..33.333........",
        "..22............",
        "................",
        "................",
        "................",
    ])
    pal = ramp("b8a888", n=6, spread=0.24)
    return outline(paint(m, pal), (0.2, 0.17, 0.12))


def rabbits_foot():
    m = shape_mask([
        "................",
        "................",
        "................",
        "......55........",
        ".....5445.......",
        ".....4444.......",
        ".....3443.......",
        "......33........",
        "......33........",
        ".....3443.......",
        "....344443......",
        "....3444433.....",
        ".....22.22......",
        "................",
        "................",
        "................",
    ])
    pal = ramp("b08a60", n=6, spread=0.2)
    img = paint(m, pal, rng("rabbits_foot"), jitter=1)
    for (y, x) in ((7, 6), (8, 7)):          # the cord
        img[y, x, :3] = (0.7, 0.18, 0.15)
    return outline(img, (0.2, 0.12, 0.06))


def lead():
    """A coiled rope with a loop."""
    img = np.zeros((16, 16, 4))
    pal = ramp("c89a5a", n=5, spread=0.22)
    for i, (cy, cx, rr) in enumerate(((8, 7, 4.5), (8, 7, 3.0))):
        for a in np.linspace(0, 2 * np.pi, 48, endpoint=False):
            y = int(round(cy + rr * np.sin(a))); x = int(round(cx + rr * np.cos(a)))
            img[y, x, :3] = pal[2 + ((int(a * 3)) % 2)]; img[y, x, 3] = 1
    for i in range(5):                        # the loose end
        img[11 + i // 2, 11 + i // 2 + (i % 2), :3] = pal[3]; img[11 + i // 2, 11 + i // 2 + (i % 2), 3] = 1
    img[4, 7, :3] = (0.6, 0.62, 0.66)         # the iron clip
    img[3, 7, :3] = (0.8, 0.82, 0.86); img[3, 7, 3] = 1
    return outline(img, (0.18, 0.12, 0.06))


def name_tag():
    m = shape_mask([
        "................",
        "................",
        "................",
        "...........44...",
        "..........4..4..",
        ".........45..4..",
        "........4554.4..",
        ".......455554...",
        "......45555554..",
        ".....45555554...",
        "....4555555.....",
        "...455555.......",
        "...45554........",
        "....444.........",
        "................",
        "................",
    ])
    pal = list(ramp("d8a868", n=6, spread=0.2))
    img = paint(m, np.array(pal))
    for (y, x) in ((9, 7), (9, 8), (10, 6), (8, 9)):     # writing lines
        img[y, x, :3] = pal[1]
    img[6, 9, :3] = (0.55, 0.57, 0.62)                    # the eyelet
    return outline(img, (0.2, 0.12, 0.05))


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
    "plant_fibre": plant_fibre,
    "resin": resin,
    "crystal_shard": crystal_shard,
    "fibre_binding": fibre_binding,
    "flux": flux,
    "star_essence": star_essence,
    "beef": lambda: meat(True),
    "cooked_beef": lambda: meat(False),
    "leather": leather,
    "wheat": wheat,
    "raw_leather": lambda: hide("c88a74", False, "raw_leather"),
    "salted_leather": lambda: hide("c88a74", True, "salted_leather"),
    "shears": shears,
    "seeds": seeds,
    "carrot": carrot,
    "berries": berries,
    "pork": lambda: chunk_meat("f08a90", True, "pork_raw"),
    "cooked_pork": lambda: chunk_meat("b0683a", False, "pork_cooked"),
    "mutton": lambda: chunk_meat("c83a44", True, "mutton_raw"),
    "cooked_mutton": lambda: chunk_meat("8a4a2a", False, "mutton_cooked"),
    "chicken": lambda: drumstick(True),
    "cooked_chicken": lambda: drumstick(False),
    "egg": egg,
    "feather": feather,
    # part 3b
    "venison": lambda: chunk_meat("a82a30", True, "venison_raw"),
    "cooked_venison": lambda: chunk_meat("703a22", False, "venison_cooked"),
    "rabbit": lambda: chunk_meat("e8a098", True, "rabbit_raw"),
    "cooked_rabbit": lambda: chunk_meat("b87848", False, "rabbit_cooked"),
    "raw_deer_hide": lambda: hide("b07850", False, "raw_deer_hide"),
    "salted_deer_hide": lambda: hide("b07850", True, "salted_deer_hide"),
    "raw_rabbit_hide": lambda: small_hide("c0a080", False, "raw_rabbit_hide"),
    "salted_rabbit_hide": lambda: small_hide("c0a080", True, "salted_rabbit_hide"),
    "dried_rabbit_hide": lambda: small_hide("9a7448", False, "dried_rabbit_hide"),
    "antler": antler,
    "goat_horn": goat_horn,
    "rabbits_foot": rabbits_foot,
    "bucket": lambda: bucket(None),
    "water_bucket": lambda: bucket("water"),
    "lava_bucket": lambda: bucket("lava"),
    "milk_bucket": lambda: bucket("milk"),
    "lead": lead,
    "name_tag": name_tag,
}
for _tier in TIER_COLOURS:
    for _kind in ("pickaxe", "axe", "shovel", "hoe"):
        ITEMS[f"{_tier}_{_kind}"] = (lambda k=_kind, t=_tier: tool(k, t))
    for _kind in ("sword", "spear", "mace"):
        ITEMS[f"{_tier}_{_kind}"] = (lambda k=_kind, t=_tier: weapon(k, t))


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
