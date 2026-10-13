#!/usr/bin/env python3
"""VoxelB journal UI art (milestone 18 part 5, design/ui/journal_ui.md).

Draws the pieces of the adventurer's-journal look into one atlas,
assets/textures/ui/journal.png, and writes assets/textures/ui/journal.cfg
naming each piece (x, y, w, h, border, scale):

  leather    the stitched dark red-brown cover (9-slice, tiling centre)
  page       cream parchment, darker towards its edges (9-slice)
  slot       an inked box drawn on the page; slot_hi a bolder one
  button     an inked frame; button_hi with an ink wash (hover / chosen)
  field      an inked writing line (text fields)
  strip      the leather hotbar strip; strip_slot a parchment pocket in it
  seal       a red wax seal; corner_tl/tr/bl/br brass corner pieces
  ribbon     a red bookmark ribbon; book the recipe book icon
  check_off / check_on   inked check boxes; knob a brass knob
  tip        a small parchment slip (tooltips)

Pixel art at 2 UI units per atlas pixel (the `scale` column), crisp with
nearest sampling. Deterministic.

    python3 tools/texgen/uigen.py
"""
import os
import sys
import zlib

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
from texgen import ramp, hexrgb  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "textures", "ui")
W = H = 256
INK = hexrgb("3b2414")
CREAM = hexrgb("f1e3c0")


def rng(name):
    return np.random.default_rng(zlib.crc32(name.encode()))


def tile_noise(r, n, cells, octaves=3):
    """Tileable value noise n x n in [0, 1]."""
    total = np.zeros((n, n))
    amp, norm, c = 1.0, 0.0, cells
    for _ in range(octaves):
        g = r.random((c, c))
        xs = np.arange(n) * c / n
        i0 = np.floor(xs).astype(int)
        f = xs - i0
        f = f * f * (3 - 2 * f)
        i1 = (i0 + 1) % c
        a = g[np.ix_(i0, i0)]
        b = g[np.ix_(i0, i1)]
        cc = g[np.ix_(i1, i0)]
        d = g[np.ix_(i1, i1)]
        top = a + (b - a) * f[None, :]
        bot = cc + (d - cc) * f[None, :]
        total += amp * (top + (bot - top) * f[:, None])
        norm += amp
        amp *= 0.5
        c = min(c * 2, n)
    return total / norm


class Atlas:
    def __init__(self):
        self.img = np.zeros((H, W, 4))
        self.pieces = []

    def put(self, name, x, y, piece, border, scale=2):
        h, w = piece.shape[:2]
        self.img[y:y + h, x:x + w] = piece
        self.pieces.append((name, x, y, w, h, border, scale))


def leather(n=64, border=16):
    r = rng("leather")
    pal = ramp("6b2e1e", n=6, spread=0.2, hue_shift=0.01)
    m = n - 2 * border                              # the tiling middle
    t = tile_noise(r, m, 4, 3) * 0.6 + r.random((m, m)) * 0.4
    yy, xx = np.mgrid[0:n, 0:n]
    grain = t[(yy - border) % m, (xx - border) % m]
    img = pal[np.clip((grain * 0.999 * 4 + 1).astype(int), 0, 5)]
    img = np.concatenate([img, np.ones((n, n, 1))], axis=2)
    # a darker worn rim and a lighter bevel inside it
    for k in range(3):
        shade = 0.55 + 0.12 * k
        img[k, :, :3] *= shade
        img[n - 1 - k, :, :3] *= shade
        img[:, k, :3] *= shade
        img[:, n - 1 - k, :3] *= shade
    # stitching: cream thread dashes along the border
    thread = hexrgb("e8d4a8")
    s = 7
    for i in range(s, n - s):
        if (i // 3) % 2 == 0:
            for (y, x) in ((s, i), (n - 1 - s, i), (i, s), (i, n - 1 - s)):
                img[y, x, :3] = thread
                img[min(y + 1, n - 1), x, :3] *= 0.6      # thread shadow
    return img


def page(n=64, border=12, seed="page"):
    r = rng(seed)
    base = CREAM
    m = max(n - 2 * border, 1)                      # the tiling middle
    yy, xx = np.mgrid[0:n, 0:n]
    fib = tile_noise(r, m, 4, 4)[(yy - border) % m, (xx - border) % m]
    speck = r.random((m, m))[(yy - border) % m, (xx - border) % m]
    img = np.zeros((n, n, 4))
    img[..., :3] = base * (0.95 + 0.07 * fib[..., None])
    img[speck > 0.985, :3] *= 0.88                  # fibres / specks
    # darker, warmer towards the edges (aged)
    yy, xx = np.mgrid[0:n, 0:n]
    d = np.minimum(np.minimum(xx, n - 1 - xx), np.minimum(yy, n - 1 - yy))
    edge = np.clip(1.0 - d / border, 0, 1) ** 1.6
    tan = hexrgb("c9a46a")
    img[..., :3] = img[..., :3] * (1 - edge[..., None] * 0.55) + tan * edge[..., None] * 0.55
    img[..., 3] = 1.0
    img[d == 0, :3] *= 0.75                          # a thin dark rim
    return img


def ink_box(w, h, thick, wash, seed):
    """A hand-inked rectangle: lines that drift by a pixel now and then
    (long runs, so they read as pen strokes, not dashes), a faint wash."""
    r = rng(seed)
    img = np.zeros((h, w, 4))
    img[..., :3] = INK
    img[..., 3] = wash

    def drift(n):
        j, out = 0, []
        for _ in range(n):
            if r.random() < 0.08:
                j = 1 - j if j else (1 if r.random() < 0.5 else 0)
            out.append(j)
        return out
    for t in range(thick):
        a = 0.95 - 0.25 * t
        top, bot = drift(w), drift(w)
        for x in range(w):
            img[t + top[x], x, 3] = max(img[t + top[x], x, 3], a)
            img[h - 1 - t - bot[x], x, 3] = max(img[h - 1 - t - bot[x], x, 3], a)
        lef, rig = drift(h), drift(h)
        for y in range(h):
            img[y, t + lef[y], 3] = max(img[y, t + lef[y], 3], a)
            img[y, w - 1 - t - rig[y], 3] = max(img[y, w - 1 - t - rig[y], 3], a)
    # a soft inner shadow at the top-left (drawn into the page)
    for k in range(2):
        img[thick + 1 + k, thick + 1:w - thick - 1, 3] = np.maximum(img[thick + 1 + k, thick + 1:w - thick - 1, 3], 0.10 - 0.04 * k)
        img[thick + 1:h - thick - 1, thick + 1 + k, 3] = np.maximum(img[thick + 1:h - thick - 1, thick + 1 + k, 3], 0.10 - 0.04 * k)
    return img


def field(w=48, h=16):
    img = np.zeros((h, w, 4))
    img[..., :3] = INK
    img[..., 3] = 0.05
    img[h - 3, :, 3] = 0.9                          # the writing line
    img[h - 2, :, 3] = 0.35
    return img


def seal(n=24):
    pal = ramp("a8201c", n=6, spread=0.25)
    img = np.zeros((n, n, 4))
    c = (n - 1) / 2
    r = rng("seal")
    for y in range(n):
        for x in range(n):
            ang = np.arctan2(y - c, x - c)
            rad = c - 0.6 + 0.9 * np.sin(ang * 7 + 0.5) * (0.6 + 0.4 * r.random())
            d = ((x - c) ** 2 + (y - c) ** 2) ** 0.5
            if d <= rad:
                k = 3
                if d > rad - 1.5:
                    k = 1                            # the squashed rim
                elif d < c * 0.55:
                    k = 4                            # the pressed face
                # light from the top-left
                if (x - c) + (y - c) < -c * 0.6:
                    k = min(5, k + 1)
                img[y, x, :3] = pal[k]
                img[y, x, 3] = 1.0
    # an embossed star
    for (dx, dy) in ((0, -4), (0, -3), (0, 3), (0, 4), (-4, 0), (-3, 0), (3, 0), (4, 0),
                     (0, -2), (0, 2), (-2, 0), (2, 0), (-1, -1), (1, 1), (-1, 1), (1, -1), (0, 0)):
        img[int(c) + dy, int(c) + dx, :3] = pal[2]
    return img


def corner(n=16):
    pal = ramp("c9a23a", n=6, spread=0.22)
    img = np.zeros((n, n, 4))
    for y in range(n):
        for x in range(n):
            if x + y < n - 2 and (x < 5 or y < 5 or x + y < 9):
                k = 3 if x + y > 6 else 4
                if x == 0 or y == 0:
                    k = 5
                if x + y >= n - 4 or (x >= 4 and y >= 4):
                    k = 1
                img[y, x, :3] = pal[k]
                img[y, x, 3] = 1.0
    img[2, 2, :3] = pal[0]                          # a rivet
    img[2, 3, :3] = pal[5]
    return img


def ribbon(w=12, h=32):
    pal = ramp("b0262a", n=6, spread=0.2)
    img = np.zeros((h, w, 4))
    for y in range(h):
        for x in range(w):
            notch = y > h - 6 and abs(x - (w - 1) / 2) < (y - (h - 6)) * 1.0
            if not notch:
                img[y, x, :3] = pal[2 if x in (0, w - 1) else (4 if x < w // 2 else 3)]
                img[y, x, 3] = 1.0
    return img


def book_icon(n=20):
    cover = ramp("6b2e1e", n=6, spread=0.25)
    img = np.zeros((n, n, 4))
    for y in range(3, n - 3):
        for x in range(3, n - 2):
            img[y, x, :3] = cover[3]
            img[y, x, 3] = 1.0
    img[3:n - 3, 3:5, :3] = cover[1]                 # the spine
    img[n - 4, 5:n - 3, :3] = CREAM                  # the pages' edge
    img[n - 5, 5:n - 3, :3] = CREAM * 0.85
    img[7:9, 8:n - 5, :3] = hexrgb("c9a23a")         # a brass title plate
    img[3, 3:n - 2, :3] *= 1.25
    return img


def check(n=12, on=False):
    img = ink_box(n, n, 1, 0.06, "check")
    if on:
        for (x, y) in ((2, 6), (3, 7), (4, 8), (5, 7), (6, 6), (7, 5), (8, 4), (9, 3), (3, 6), (4, 7), (5, 8)):
            img[y, x, 3] = 1.0
    return img


def knob(n=12):
    pal = ramp("c9a23a", n=6, spread=0.25)
    img = np.zeros((n, n, 4))
    c = (n - 1) / 2
    for y in range(n):
        for x in range(n):
            d = ((x - c) ** 2 + (y - c) ** 2) ** 0.5
            if d <= c:
                k = 2 if d > c - 1.2 else (5 if (x + y) < n * 0.7 else 3)
                img[y, x, :3] = pal[k]
                img[y, x, 3] = 1.0
    return img


def strip(w=64, h=32, border=10):
    img = leather(64, 16)[:h, :w].copy()
    img[h - 3:, :] = leather(64, 16)[64 - 3:, :w]   # bottom rim
    return img


def strip_slot(n=24):
    img = page(n, 5, "strip_slot")
    # a stitched pocket edge
    thread = hexrgb("5a3a22")
    for i in range(1, n - 1):
        if i % 3 != 0:
            img[1, i, :3] = thread
            img[n - 2, i, :3] = thread
            img[i, 1, :3] = thread
            img[i, n - 2, :3] = thread
    return img


def main():
    a = Atlas()
    a.put("leather", 0, 0, leather(), 16)
    a.put("page", 64, 0, page(), 12)
    a.put("slot", 128, 0, ink_box(24, 24, 1, 0.07, "slot"), 6)
    a.put("slot_hi", 152, 0, ink_box(24, 24, 2, 0.16, "slot_hi"), 6)
    a.put("seal", 176, 0, seal(), 0)
    a.put("corner_tl", 200, 0, corner(), 0)
    c = corner()
    a.put("corner_tr", 216, 0, c[:, ::-1].copy(), 0)
    a.put("corner_bl", 200, 16, c[::-1, :].copy(), 0)
    a.put("corner_br", 216, 16, c[::-1, ::-1].copy(), 0)
    a.put("ribbon", 232, 0, ribbon(), 0)
    a.put("button", 128, 24, ink_box(48, 24, 1, 0.04, "button"), 8)
    a.put("button_hi", 176, 32, ink_box(48, 24, 2, 0.18, "button_hi"), 8)
    a.put("field", 128, 48, field(), 4)
    a.put("book", 176, 56, book_icon(), 0)
    a.put("check_off", 196, 56, check(), 0)
    a.put("check_on", 208, 56, check(on=True), 0)
    a.put("knob", 220, 56, knob(), 0)
    a.put("strip", 0, 64, strip(), 10)
    a.put("strip_slot", 64, 64, strip_slot(), 5)
    a.put("tip", 88, 64, page(32, 6, "tip"), 6)
    a.put("page_tile", 0, 128, page(128, 1, "page_big"), 0)
    os.makedirs(OUT, exist_ok=True)
    arr = (np.clip(a.img, 0, 1) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(arr, "RGBA").save(os.path.join(OUT, "journal.png"), optimize=True)
    with open(os.path.join(OUT, "journal.cfg"), "w") as f:
        f.write("# The journal UI's pieces in journal.png (written by tools/texgen/uigen.py):\n")
        f.write("# name = x, y, w, h, border (9-slice edge, atlas pixels), scale (UI units per pixel)\n")
        for name, x, y, w, h, b, s in a.pieces:
            f.write(f"{name} = {x}, {y}, {w}, {h}, {b}, {s}\n")
    print(f"uigen: {len(a.pieces)} pieces")


if __name__ == "__main__":
    main()
