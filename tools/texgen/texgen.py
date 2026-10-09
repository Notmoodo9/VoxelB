#!/usr/bin/env python3
"""VoxelB block texture generator.

Draws every block texture of the v1 block set (design/blocks/block_set.md)
as 16x16 pixel art in a vibrant, hand-shaded style, and writes them to
assets/textures/blocks/<name>.png. Animated textures are vertical strips of
16x16 frames; glowing parts go into <name>_glow.png (alpha = glow strength).

The PNGs are committed, so building the game never needs Python. Run this
again only to regenerate textures (it overwrites them, including any you
repainted by hand, unless you pass the names you want to (re)generate):

    python3 tools/texgen/texgen.py              # everything
    python3 tools/texgen/texgen.py oak_planks   # only these textures
    python3 tools/texgen/texgen.py --list       # print all texture names

Deterministic: the same script always produces the same pixels.
"""
import colorsys
import os
import sys
import zlib

import numpy as np
from PIL import Image

N = 16
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "textures", "blocks")

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def rng(name):
    return np.random.default_rng(zlib.crc32(name.encode()))


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=float) / 255.0


def ramp(base, n=6, spread=0.16, hue_shift=0.018, sat_boost=1.12):
    """Shades dark -> light around a base colour, with hue shifting: shadows
    lean cooler and more saturated, highlights warmer and lighter (the usual
    pixel-art trick that keeps colours vibrant instead of muddy)."""
    r, g, b = hexrgb(base) if isinstance(base, str) else base
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    out = []
    mid = (n - 1) / 2.0
    for i in range(n):
        k = i - mid
        hh = (h - hue_shift * k) % 1.0
        ss = min(1.0, max(0.0, s * sat_boost * (1.0 - 0.07 * k)))
        vv = min(1.0, max(0.0, v * (1.0 + spread * k)))
        out.append(colorsys.hsv_to_rgb(hh, ss, vv))
    return np.array(out)


def noise(r, cells=4, octaves=3, persistence=0.5):
    """Tileable value noise in [0, 1]."""
    total = np.zeros((N, N))
    amp, norm = 1.0, 0.0
    c = cells
    for _ in range(octaves):
        grid = r.random((c, c))
        ys = np.arange(N) * c / N
        xs = np.arange(N) * c / N
        y0 = np.floor(ys).astype(int)
        x0 = np.floor(xs).astype(int)
        fy = ys - y0
        fx = xs - x0
        fy = fy * fy * (3 - 2 * fy)
        fx = fx * fx * (3 - 2 * fx)
        y1 = (y0 + 1) % c
        x1 = (x0 + 1) % c
        a = grid[np.ix_(y0, x0)]
        b = grid[np.ix_(y0, x1)]
        cc = grid[np.ix_(y1, x0)]
        d = grid[np.ix_(y1, x1)]
        top = a + (b - a) * fx[None, :]
        bot = cc + (d - cc) * fx[None, :]
        total += amp * (top + (bot - top) * fy[:, None])
        norm += amp
        amp *= persistence
        c = min(c * 2, N)
    return total / norm


def stretch(v):
    lo, hi = v.min(), v.max()
    return (v - lo) / (hi - lo + 1e-9)


def shade(v, pal):
    """Map a value field in [0, 1] onto a palette (pixel-art banding)."""
    idx = np.clip((v * len(pal)).astype(int), 0, len(pal) - 1)
    return pal[idx]


def rgba(rgb, alpha=None):
    a = np.ones((N, N, 1)) if alpha is None else alpha[..., None]
    return np.concatenate([rgb, a], axis=2)


def save(name, frames):
    """frames: one or more (16, 16, 4) float arrays."""
    if not isinstance(frames, list):
        frames = [frames]
    strip = np.concatenate(frames, axis=0)
    arr = (np.clip(strip, 0, 1) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(arr, "RGBA").save(os.path.join(OUT, name + ".png"), optimize=True)


def outline_rect(img, color, x0, y0, x1, y1):
    img[y0, x0:x1 + 1, :3] = color
    img[y1, x0:x1 + 1, :3] = color
    img[y0:y1 + 1, x0, :3] = color
    img[y0:y1 + 1, x1, :3] = color


VIBRANT = ["e8402a", "f09a1c", "f2d02a", "6cc23a", "2a9de8", "7a4ae8", "d03a9a", "2ac2b0",
           "c8302a", "3a6ae0", "e8e0c8", "8a5a2a"]

# ---------------------------------------------------------------------------
# woods
# ---------------------------------------------------------------------------

WOODS = {
    # name: bark, planks, leaves, bark style, leaf style, seasonal (kind, colours)
    "oak":         ("6b5a45", "b8864b", "3f9b2f", "furrow", "broad",  ("autumn", ["e0521e", "f0a020", "c8301e"])),
    "birch":       ("e8e4d8", "e3d3a0", "7cc142", "birch",  "broad",  ("autumn", ["f2c21e", "f0e040", "d89a1a"])),
    "spruce":      ("4a3523", "7a4a2e", "2e6b4f", "rough",  "needle", ("snowy", None)),
    "jungle":      ("7a6a3a", "c08a6a", "2fbf2f", "mossy",  "broad",  ("flowering", ["ff7a2a", "ff5fa8"])),
    "acacia":      ("7d7468", "d8692b", "7f9a2e", "flaky",  "broad",  ("flowering", ["ffe03a", "fff07a"])),
    "dark_oak":    ("3a2a1c", "5a3a22", "2a6b24", "furrow", "broad",  ("autumn", ["a01e2a", "c8302a", "701a24"])),
    "cherry":      ("4a2a38", "e7a9b4", "f08cb8", "smooth", "blossom", ("fruiting", ["d8102a", "ff3040"])),
    "redwood":     ("7a3524", "a8432c", "2c5e36", "groove", "needle", ("snowy", None)),
    "palm":        ("b08f5f", "e0c070", "4fc23a", "ringed", "frond",  ("fruiting", ["6a4020", "8a5a2a"])),
    "mangrove":    ("6e3b2a", "a8483a", "2f6e3a", "rough",  "broad",  ("flowering", ["fff8f0", "f8e8ff"])),
    "willow":      ("6e7560", "bfc08a", "9ccf4a", "furrow", "hanging", ("autumn", ["f2d03a", "e8b828", "f8e868"])),
    "maple":       ("6a5a4c", "d9a25e", "4aa83a", "furrow", "broad",  ("autumn", ["f0401a", "ff7a1a", "d81e1e"])),
    "glowwood":    ("1e4a4f", "2f8c88", "3fd8a8", "veins",  "broad",  ("blooming", ["c8fff0", "7affd8"])),
    "crystalwood": ("b8a8d8", "c8a8e8", "8a7cff", "facets", "crystal", ("prismatic", None)),
    "frostwood":   ("c8dcec", "e0eef8", "a8d8f0", "frost",  "broad",  ("frozen", None)),
    "emberwood":   ("2a2424", "6a2a1e", "b8401a", "embers", "broad",  ("smouldering", None)),
}
SEASONAL_NAMES = {
    "oak": "oak_autumn_leaves", "birch": "birch_autumn_leaves", "spruce": "spruce_snowy_leaves",
    "jungle": "jungle_flowering_leaves", "acacia": "acacia_flowering_leaves",
    "dark_oak": "dark_oak_autumn_leaves", "cherry": "cherry_fruiting_leaves",
    "redwood": "redwood_snowy_leaves", "palm": "palm_fruiting_leaves",
    "mangrove": "mangrove_flowering_leaves", "willow": "willow_autumn_leaves",
    "maple": "maple_autumn_leaves", "glowwood": "glowwood_blooming_leaves",
    "crystalwood": "crystalwood_prismatic_leaves", "frostwood": "frostwood_frozen_leaves",
    "emberwood": "emberwood_smouldering_leaves",
}
FRAMES = 8


def bark(name, base, style, r):
    pal = ramp(base, 6, spread=0.2)
    n = noise(r, 2, 3)
    x = np.arange(N)
    col = noise(r, 8, 2)[0]                     # per-column variation
    v = 0.55 * stretch(col)[None, :] + 0.45 * n
    if style in ("furrow", "rough", "groove", "mossy", "veins", "embers"):
        # vertical furrows with a wobble
        for _ in range({"groove": 5, "rough": 4}.get(style, 3)):
            cx = r.integers(0, N)
            for y in range(N):
                xx = (cx + (1 if r.random() < 0.25 else 0) * r.choice([-1, 1])) % N
                cx = xx
                v[y, xx] *= 0.35
                v[y, (xx + 1) % N] = min(1.0, v[y, (xx + 1) % N] * 1.25)
    if style == "flaky":
        for _ in range(6):
            x0, y0 = r.integers(0, N, 2)
            w, h = r.integers(2, 5), r.integers(2, 4)
            for yy in range(h):
                for xx in range(w):
                    v[(y0 + yy) % N, (x0 + xx) % N] = 0.8 if yy == 0 else 0.62
            v[(y0 + h) % N, x0 % N:(x0 + w) % N] = 0.15
    if style == "smooth":
        v = 0.5 + 0.35 * (n - 0.5)
        for y in range(0, N, 4):                # horizontal lenticels
            xs = r.integers(0, N, 3)
            for xx in xs:
                v[(y + r.integers(0, 3)) % N, xx:xx + 2] = 0.12
    if style == "ringed":
        v = 0.45 + 0.5 * stretch(col)[None, :] * 0.6 + 0.2 * (n - 0.5)
        v = np.repeat(v[:1], N, axis=0) + 0.1 * (n - 0.5)
        for y in (3, 7, 11, 15):
            v[y, :] = 0.12
            v[(y - 1) % N, :] = np.minimum(1.0, v[(y - 1) % N, :] + 0.25)
    if style == "birch":
        img = shade(0.62 + 0.38 * n, ramp(base, 4, spread=0.06))
        dark = ramp("2a2420", 3)
        for _ in range(7):
            y0 = r.integers(0, N)
            x0 = r.integers(0, N)
            w = r.integers(2, 6)
            for xx in range(w):
                img[y0, (x0 + xx) % N] = dark[1]
                if r.random() < 0.5:
                    img[(y0 + 1) % N, (x0 + xx) % N] = dark[0]
        return rgba(img)
    if style == "facets":
        img = shade(0.4 + 0.5 * n, pal)
        for _ in range(5):
            cx, cy = r.integers(1, N - 1, 2)
            img[cy, cx] = hexrgb("f4ecff")
            img[(cy + 1) % N, cx] = hexrgb("d8c8ff")
            img[cy, (cx + 1) % N] = hexrgb("a890e8")
        return rgba(img)
    if style == "frost":
        img = shade(stretch(v), pal)
        for _ in range(10):
            img[r.integers(0, N), r.integers(0, N)] = hexrgb("ffffff")
        return rgba(img)
    if style == "mossy":
        img = shade(stretch(v), pal)
        m = noise(r, 4, 2)
        moss = ramp("5a8a2a", 4)
        mask = m > 0.62
        img[mask] = shade(stretch(m)[mask], moss)
        return rgba(img)
    return rgba(shade(stretch(v), pal))


def veins_mask(r, count=4):
    m = np.zeros((N, N))
    for _ in range(count):
        x = r.integers(0, N)
        for y in range(N):
            m[y, x] = 1.0
            if r.random() < 0.35:
                x = (x + r.choice([-1, 1])) % N
                m[y, x] = 1.0
    return m


def log_top(base_wood, base_bark, r, rings=True):
    pal = ramp(base_wood, 5, spread=0.14)
    yy, xx = np.mgrid[0:N, 0:N]
    d = np.sqrt((xx - 7.5) ** 2 + (yy - 7.5) ** 2)
    n = noise(r, 4, 2)
    ring = (np.floor(d + 0.6 * n) % 2.0) * 0.35 + 0.45 + 0.2 * (n - 0.5)
    img = shade(np.clip(ring, 0, 0.999), pal)
    if rings:
        img[np.floor(d + 0.6 * n) % 3 == 0] = pal[1]
    # bark rim
    bark_pal = ramp(base_bark, 4)
    rim = (xx == 0) | (yy == 0) | (xx == N - 1) | (yy == N - 1)
    img[rim] = shade(n[rim], bark_pal)
    inner = ((xx == 1) | (yy == 1) | (xx == N - 2) | (yy == N - 2)) & ~rim
    img[inner] = pal[0]
    img[7:9, 7:9] = pal[1]
    return rgba(img)


def stripped_side(base_wood, r):
    pal = ramp(base_wood, 5, spread=0.12)
    n = noise(r, 2, 2)
    col = noise(r, 16, 1)[0]
    v = 0.6 * stretch(col)[None, :] + 0.4 * n
    img = shade(stretch(v), pal)
    for _ in range(3):
        x = r.integers(0, N)
        img[:, x] = pal[1]
    return rgba(img)


def planks(base, r, variant=0):
    pal = ramp(base, 6, spread=0.13)
    img = np.zeros((N, N, 3))
    for b in range(4):
        y0 = b * 4
        n = noise(np.random.default_rng(r.integers(1 << 30)), 4, 2)
        grain = noise(np.random.default_rng(r.integers(1 << 30)), 2, 2)
        tone = 0.45 + 0.25 * (r.random() - 0.5)
        for y in range(y0, y0 + 4):
            row = tone + 0.35 * (grain[y] - 0.5) + 0.25 * (n[y] - 0.5)
            img[y] = shade(np.clip(row + 0.08, 0, 0.999), pal)
        img[y0 + 3] = pal[0]                    # seam below the board
        img[y0, :] = np.minimum(1.0, img[y0, :] * 1.08)
        cut = (r.integers(3, 13) + b * 5) % N   # board end
        img[y0:y0 + 3, cut] = pal[1]
        if r.random() < 0.6:
            img[y0 + 1, (cut + r.integers(2, 6)) % N] = pal[1]   # nail
    return rgba(img)


def carved_planks(base, r):
    pal = ramp(base, 6, spread=0.15)
    p = planks(base, r)
    img = p[..., :3].copy()
    # recessed frame + carved diamond with bevel light (top-left) / shadow
    outline_rect(img, pal[0], 0, 0, N - 1, N - 1)
    outline_rect(img, pal[5], 1, 1, N - 2, N - 2)
    img[2:14, 2:14] = shade(0.35 + 0.3 * noise(r, 4, 2)[2:14, 2:14], pal)
    yy, xx = np.mgrid[0:N, 0:N]
    d = np.abs(xx - 7.5) + np.abs(yy - 7.5)
    img[(d > 4.5) & (d < 5.6)] = pal[0]
    edge = (d > 3.5) & (d <= 4.5)
    img[edge & (yy < 8)] = pal[5]
    img[edge & (yy >= 8)] = pal[1]
    img[d <= 1.6] = pal[4]
    img[(d <= 0.8)] = pal[2]
    return rgba(img)


def mossy(base_img, r, amount=0.42):
    img = base_img[..., :3].copy()
    m = noise(r, 4, 3)
    yy = np.mgrid[0:N, 0:N][0]
    m = m + 0.35 * (1.0 - yy / N)               # more moss on top
    moss = ramp("4f9a2a", 5, spread=0.2)
    mask = m > (1.15 - amount)
    img[mask] = shade(stretch(m)[mask] * 0.999, moss)
    # a few light tips
    tips = mask & (r.random((N, N)) < 0.12)
    img[tips] = hexrgb("9ad84a")
    return rgba(img)


def bookshelf(base, r):
    pal = ramp(base, 6, spread=0.13)
    p = planks(base, r)
    img = p[..., :3].copy()
    for shelf_top in (2, 9):
        x = 1
        while x < N - 1:
            w = int(r.integers(1, 3))
            h = int(r.integers(4, 6))
            col = ramp(VIBRANT[r.integers(len(VIBRANT))], 4, spread=0.25)
            for xx in range(x, min(x + w, N - 1)):
                for yy in range(shelf_top + (6 - h), shelf_top + 6):
                    img[yy, xx] = col[2] if xx == x else col[1]
                img[shelf_top + (6 - h), xx] = col[3]
                img[shelf_top + 4, xx] = col[0]          # band on the spine
            x += w + (1 if r.random() < 0.25 else 0)
        img[shelf_top + 6] = pal[0]
    img[0:2] = p[0:2, :, :3]
    img[15] = pal[0]
    img[:, 0] = pal[1]
    img[:, 15] = pal[1]
    return rgba(img)


def leaf_field(r, density=0.78):
    """Leaf clusters: value field + alpha holes."""
    n = noise(r, 4, 3)
    fine = r.random((N, N))
    v = 0.6 * stretch(n) + 0.4 * fine
    alpha = (stretch(n) * 0.55 + fine * 0.45) > (1.0 - density)
    return v, alpha.astype(float)


def leaves(base, style, r):
    pal = ramp(base, 6, spread=0.22)
    v, a = leaf_field(r, 0.7 if style != "needle" else 0.76)
    img = shade(v, pal)
    if style == "needle":
        img = shade(0.25 + 0.5 * v, pal)
        for _ in range(26):
            x, y = r.integers(0, N, 2)
            for k in range(3):
                img[(y + k) % N, (x + k) % N] = pal[4 + (k == 1)]
        a = np.maximum(a, (r.random((N, N)) > 0.4).astype(float))
    elif style == "frond":
        img = shade(0.3 + 0.5 * v, pal)
        for row in range(1, N, 4):
            for x in range(N):
                img[(row + (x // 4) % 2) % N, x] = pal[4]
        a = np.maximum(a, (r.random((N, N)) > 0.35).astype(float))
    elif style == "hanging":
        img = shade(0.2 + 0.6 * v, pal)
        a = np.zeros((N, N))
        for x in range(N):
            length = r.integers(6, N + 1)
            start = r.integers(0, N)
            for k in range(length):
                a[(start + k) % N, x] = 1.0
            img[(start + length - 1) % N, x] = pal[5]
    elif style == "blossom":
        img = shade(0.3 + 0.6 * v, pal)
        for _ in range(10):
            x, y = r.integers(0, N, 2)
            img[y, x] = hexrgb("fff0f6")
    # highlights on the upper-left of clusters
    hl = (v > 0.82) & (a > 0)
    img[hl] = pal[5]
    # transparent pixels keep a dark leaf colour (used by opaque_leaves = 1)
    img[a == 0] = pal[0] * 0.8
    return img, a


def crystal_leaves(r, phase=0.0):
    pal = ramp("8a7cff", 6, spread=0.25)
    yy, xx = np.mgrid[0:N, 0:N]
    n = noise(r, 4, 2)
    facet = ((xx + yy) // 3 % 3) / 3.0 + 0.35 * n
    img = shade(stretch(facet) * 0.999, pal)
    a = 0.55 + 0.25 * stretch(n)
    pulse = 0.5 + 0.5 * np.sin(phase * 2 * np.pi + (xx + yy) * 0.35)
    img = img * (0.85 + 0.3 * pulse[..., None])
    sparkle = r.random((N, N)) > 0.93
    img[sparkle] = hexrgb("ffffff")
    return np.clip(img, 0, 1), a


def seasonal(wood, kind, cols, leaf_base, style, r):
    """Returns a list of frames (most are one frame)."""
    if kind == "autumn":
        img, a = leaves(leaf_base, "broad" if style != "hanging" else "hanging", r)
        m = noise(r, 4, 2)
        palettes = [ramp(c, 5, spread=0.22) for c in cols]
        v = r.random((N, N))
        pick = (stretch(m) * len(palettes) * 0.999).astype(int)
        for i, p in enumerate(palettes):
            sel = pick == i
            img[sel] = shade(v[sel] * 0.6 + 0.3, p)
        img[a == 0] = palettes[-1][0] * 0.7
        return [rgba(img, a)]
    if kind == "snowy":
        img, a = leaves(leaf_base, "needle", r)
        snow = ramp("eef6ff", 4, spread=0.06)
        yy = np.mgrid[0:N, 0:N][0]
        m = noise(r, 4, 2) + 0.5 * (1 - yy / N)
        sel = (m > 0.75) & (a > 0)
        img[sel] = shade(r.random((N, N))[sel], snow)
        return [rgba(img, a)]
    if kind in ("flowering", "blooming"):
        img, a = leaves(leaf_base, style, r)
        petal = [ramp(c, 4, spread=0.15) for c in cols]
        for i in range(9):
            x, y = r.integers(1, N - 1, 2)
            p = petal[i % len(petal)]
            for dx, dy in ((0, -1), (-1, 0), (1, 0), (0, 1)):
                img[y + dy, x + dx] = p[2]
                a[y + dy, x + dx] = 1
            img[y, x] = hexrgb("ffd83a") if kind == "flowering" else hexrgb("ffffff")
            a[y, x] = 1
        return [rgba(img, a)]
    if kind == "fruiting":
        img, a = leaves(leaf_base if wood != "cherry" else "4fa83a", style if wood != "cherry" else "broad", r)
        fruit = ramp(cols[0], 4, spread=0.25)
        for i in range(5 if wood == "cherry" else 3):
            x, y = r.integers(1, N - 2, 2)
            if wood == "cherry":
                img[y, x] = fruit[2]; img[y, x + 1] = fruit[2]
                img[y + 1, x] = fruit[1]; img[y + 1, x + 1] = fruit[1]
                img[y, x] = fruit[3]
                a[y:y + 2, x:x + 2] = 1
                img[y - 1, x] = hexrgb("3a6a1a"); a[y - 1, x] = 1
            else:  # coconuts: 3x3 brown balls
                for dy in range(3):
                    for dx in range(3):
                        if (dx, dy) in ((0, 0), (2, 0), (0, 2), (2, 2)):
                            continue
                        yy_, xx_ = (y + dy) % N, (x + dx) % N
                        img[yy_, xx_] = fruit[1 + (dx + dy < 2)]
                        a[yy_, xx_] = 1
        return [rgba(img, a)]
    if kind == "prismatic":
        frames = []
        for f in range(FRAMES):
            img, a = crystal_leaves(np.random.default_rng(7), f / FRAMES)
            yy, xx = np.mgrid[0:N, 0:N]
            hue = ((xx + yy) / 30.0 + f / FRAMES) % 1.0
            rainbow = np.array([colorsys.hsv_to_rgb(h, 0.55, 1.0) for h in hue.ravel()]).reshape(N, N, 3)
            img = img * 0.55 + rainbow * 0.45
            frames.append(rgba(img, a))
        return frames
    if kind == "frozen":
        img, a = leaves(leaf_base, "broad", r)
        ice = ramp("dff4ff", 4, spread=0.08)
        for _ in range(5):
            x = r.integers(0, N)
            y = r.integers(4, 10)
            for k in range(r.integers(3, 7)):
                img[(y + k) % N, x] = ice[3 - min(k, 2)]
                a[(y + k) % N, x] = 1
        frost = r.random((N, N)) > 0.8
        img[frost & (a > 0)] = ice[3]
        return [rgba(img, a)]
    if kind == "smouldering":
        frames = []
        base_img, a = leaves("8a2a14", "broad", np.random.default_rng(11))
        embers = np.random.default_rng(12).random((N, N))
        for f in range(FRAMES):
            img = base_img.copy()
            phase = (embers * 7.0 + f / FRAMES) % 1.0
            glow = np.clip(1.0 - np.abs(phase - 0.5) * 3.0, 0, 1) * (embers > 0.7)
            ember_col = np.array([1.0, 0.55, 0.12])
            img = img * (1 - glow[..., None]) + ember_col * glow[..., None]
            frames.append(rgba(img, a))
        return frames
    raise ValueError(kind)


def glow_layer(mask, color, intensity):
    img = np.zeros((N, N, 4))
    img[..., :3] = hexrgb(color)
    img[..., 3] = np.clip(mask * intensity, 0, 1)
    return img


def make_woods(out):
    for wood, (bark_c, plank_c, leaf_c, bstyle, lstyle, (skind, scols)) in WOODS.items():
        r = rng(wood)
        side = bark(wood, bark_c, bstyle, r)
        if bstyle == "veins":
            # glowwood: veins shimmer (animated, glow layer)
            vm = veins_mask(np.random.default_rng(5), 4)
            frames, gframes = [], []
            for f in range(FRAMES):
                img = side.copy()
                wave = 0.55 + 0.45 * np.sin(2 * np.pi * (f / FRAMES) + np.arange(N)[:, None] * 0.6)
                col = hexrgb("4fffd0")
                img[..., :3] = img[..., :3] * (1 - vm[..., None]) + (col * wave)[..., :] * vm[..., None]
                frames.append(img)
                gframes.append(glow_layer(vm * wave, "4fffd0", 0.9))
            out[f"{wood}_log"] = frames
            out[f"{wood}_log_glow"] = gframes
        elif bstyle == "embers":
            cm = veins_mask(np.random.default_rng(9), 5)
            frames, gframes = [], []
            for f in range(FRAMES):
                img = side.copy()
                flick = 0.6 + 0.4 * np.sin(2 * np.pi * f / FRAMES + np.random.default_rng(f).random((N, N)) * 1.5)
                col = np.array([1.0, 0.48, 0.1])
                img[..., :3] = img[..., :3] * (1 - cm[..., None]) + col * flick[..., None] * cm[..., None]
                frames.append(img)
                gframes.append(glow_layer(cm * flick, "ff7a1a", 1.0))
            out[f"{wood}_log"] = frames
            out[f"{wood}_log_glow"] = gframes
        elif bstyle == "facets":
            frames = []
            for f in range(FRAMES):
                img = side.copy()
                yy, xx = np.mgrid[0:N, 0:N]
                pulse = 0.5 + 0.5 * np.sin(2 * np.pi * f / FRAMES - (yy * 0.4))
                img[..., :3] = np.clip(img[..., :3] * (0.9 + 0.2 * pulse[..., None]), 0, 1)
                frames.append(img)
            out[f"{wood}_log"] = frames
        else:
            out[f"{wood}_log"] = side
        out[f"{wood}_log_top"] = log_top(plank_c, bark_c, r)
        out[f"stripped_{wood}_log"] = stripped_side(plank_c, r)
        out[f"stripped_{wood}_log_top"] = log_top(plank_c, plank_c, r)
        out[f"{wood}_planks"] = planks(plank_c, rng(wood + "p"))
        out[f"carved_{wood}_planks"] = carved_planks(plank_c, rng(wood + "c"))
        out[f"mossy_{wood}_planks"] = mossy(planks(plank_c, rng(wood + "p")), rng(wood + "m"))
        out[f"{wood}_bookshelf"] = bookshelf(plank_c, rng(wood + "b"))
        if lstyle == "crystal":
            frames = []
            for f in range(FRAMES):
                img, a = crystal_leaves(rng(wood + "l"), f / FRAMES)
                frames.append(rgba(img, a))
            out[f"{wood}_leaves"] = frames
        elif wood == "glowwood":
            img, a = leaves(leaf_c, lstyle, rng(wood + "l"))
            frames, gframes = [], []
            sp = np.random.default_rng(3).random((N, N))
            for f in range(FRAMES):
                phase = (sp * 5.0 + f / FRAMES) % 1.0
                tw = np.clip(1.0 - np.abs(phase - 0.5) * 4.0, 0, 1) * (sp > 0.8) * a
                fr = img * (1 - tw[..., None]) + hexrgb("e0fff4") * tw[..., None]
                frames.append(rgba(fr, a))
                gframes.append(glow_layer(np.maximum(tw, 0.25 * a), "7affd8", 1.0))
            out[f"{wood}_leaves"] = frames
            out[f"{wood}_leaves_glow"] = gframes
        else:
            img, a = leaves(leaf_c, lstyle, rng(wood + "l"))
            out[f"{wood}_leaves"] = rgba(img, a)
        sname = SEASONAL_NAMES[wood]
        sframes = seasonal(wood, skind, scols, leaf_c, lstyle, rng(sname))
        out[sname] = sframes if len(sframes) > 1 else sframes[0]
        if skind == "smouldering":
            out[sname + "_glow"] = [glow_layer((fr[..., 0] > 0.8).astype(float) * fr[..., 3], "ff8a2a", 1.0)
                                    for fr in sframes]
        if skind == "blooming":
            fr = sframes[0]
            out[sname + "_glow"] = glow_layer(((fr[..., 0] > 0.75) & (fr[..., 1] > 0.9)).astype(float) * 0.9
                                              + 0.2 * fr[..., 3], "c8fff0", 1.0)

# ---------------------------------------------------------------------------
# mushrooms
# ---------------------------------------------------------------------------

MUSHROOMS = {
    # name: stem, cap, cap spots, gills, planks
    "red_mushroom":     ("e8dcc0", "d8202a", "fff4e8", "f0d8c0", "d89a8a"),
    "brown_mushroom":   ("e0d0b0", "9a6a44", None,     "d8c0a0", "b08a68"),
    "glowing_mushroom": ("a8d8e8", "1e5ad8", "7af0ff", "8ac8e8", "4a8ab8"),
}


def make_mushrooms(out):
    for m, (stem_c, cap_c, spot_c, gill_c, plank_c) in MUSHROOMS.items():
        r = rng(m)
        pal = ramp(stem_c, 5, spread=0.1)
        n = noise(r, 2, 2)
        col = noise(r, 16, 1)[0]
        v = 0.6 * stretch(col)[None, :] + 0.4 * n
        stem = shade(stretch(v) * 0.999, pal)
        for _ in range(4):
            stem[:, r.integers(0, N)] = pal[1]
        out[f"{m}_stem"] = rgba(stem)
        yy, xx = np.mgrid[0:N, 0:N]
        d = np.sqrt((xx - 7.5) ** 2 + (yy - 7.5) ** 2)
        top = shade(np.clip(0.4 + 0.12 * np.cos(d * 1.4) + 0.2 * (n - 0.5), 0, 0.999), pal)
        rim = (xx == 0) | (yy == 0) | (xx == N - 1) | (yy == N - 1)
        top[rim] = pal[2]
        out[f"{m}_stem_top"] = rgba(top)
        out[f"stripped_{m}_stem"] = rgba(shade(0.45 + 0.4 * stretch(v) * 0.6, ramp(stem_c, 5, spread=0.06)))
        out[f"stripped_{m}_stem_top"] = rgba(shade(np.clip(0.5 + 0.1 * np.cos(d * 1.4), 0, 0.999),
                                                    ramp(stem_c, 5, spread=0.06)))
        # cap
        cpal = ramp(cap_c, 6, spread=0.2)
        cn = noise(rng(m + "cap"), 4, 3)
        cap = shade(stretch(cn) * 0.6 + 0.25, cpal)
        glow = np.zeros((N, N))
        if spot_c:
            spal = ramp(spot_c, 3, spread=0.08)
            sr = rng(m + "spots")
            for _ in range(6):
                x, y = sr.integers(0, N, 2)
                s = sr.integers(2, 4)
                for dy in range(s):
                    for dx in range(s):
                        if s == 3 and (dx, dy) in ((0, 0), (2, 0), (0, 2), (2, 2)):
                            continue
                        cap[(y + dy) % N, (x + dx) % N] = spal[1 + (dx + dy == 0)]
                        glow[(y + dy) % N, (x + dx) % N] = 1.0
        if m == "glowing_mushroom":
            frames, gframes = [], []
            for f in range(FRAMES):
                tw = 0.65 + 0.35 * np.sin(2 * np.pi * f / FRAMES + (xx * 0.5 + yy * 0.3))
                img = cap.copy()
                img = img * (1 - glow[..., None]) + hexrgb(spot_c) * (tw * glow)[..., None] \
                    + img * (glow * (1 - tw))[..., None] * 0.3
                frames.append(rgba(np.clip(img, 0, 1)))
                gframes.append(glow_layer(glow * tw, spot_c, 1.0))
            out[f"{m}_cap"] = frames
            out[f"{m}_cap_glow"] = gframes
        else:
            out[f"{m}_cap"] = rgba(cap)
        # gills: radial lines
        gpal = ramp(gill_c, 4, spread=0.15)
        ang = np.arctan2(yy - 7.5, xx - 7.5)
        gills = shade(np.clip(0.5 + 0.45 * np.sign(np.sin(ang * 12)) * 0.5 + 0.15 * (n - 0.5), 0, 0.999), gpal)
        gills[d < 2.2] = ramp(stem_c, 3)[1]
        out[f"{m}_gills"] = rgba(gills)
        out[f"{m}_planks"] = planks(plank_c, rng(m + "p"))
        out[f"carved_{m}_planks"] = carved_planks(plank_c, rng(m + "c"))
        out[f"mossy_{m}_planks"] = mossy(planks(plank_c, rng(m + "p")), rng(m + "m"))
        out[f"{m}_bookshelf"] = bookshelf(plank_c, rng(m + "b"))

# ---------------------------------------------------------------------------
# soils, stone, glass, ice
# ---------------------------------------------------------------------------

def speckle(base, r, cells=4, spread=0.18, n_colors=5, pebbles=0, pebble_color=None):
    pal = ramp(base, n_colors, spread=spread)
    v = 0.55 * noise(r, cells, 3) + 0.45 * r.random((N, N))
    img = shade(stretch(v) * 0.999, pal)
    if pebbles:
        pp = ramp(pebble_color or base, 4, spread=0.25)
        for _ in range(pebbles):
            x, y = r.integers(0, N, 2)
            img[y, x] = pp[3]
            img[y, (x + 1) % N] = pp[2]
            img[(y + 1) % N, x] = pp[1]
    return img


def grass_top(r):
    pal = ramp("4fbf45", 6, spread=0.2)
    v = 0.5 * noise(r, 4, 3) + 0.5 * r.random((N, N))
    img = shade(stretch(v) * 0.999, pal)
    for _ in range(14):                            # blade tips
        x, y = r.integers(0, N, 2)
        img[y, x] = pal[5]
        img[(y + 1) % N, x] = pal[3]
    return img


def fringe_side(soil_img, top_img, r, depth=(2, 5)):
    img = soil_img.copy()
    for x in range(N):
        d = r.integers(depth[0], depth[1])
        img[:d, x] = top_img[:d, x]
        img[d - 1, x] = top_img[d - 1, x] * 0.82    # shadow line under the fringe
    return img


def stone(r, base="7e8794"):
    pal = ramp(base, 6, spread=0.17, hue_shift=0.01)
    v = 0.6 * noise(r, 4, 3) + 0.4 * r.random((N, N))
    img = shade(stretch(v) * 0.999, pal)
    for _ in range(3):                             # cracks
        x, y = r.integers(0, N, 2)
        for k in range(r.integers(3, 6)):
            img[y % N, x % N] = pal[0]
            x += r.choice([0, 1]); y += r.choice([0, 1])
    return img


def cobble(r, base="7e8794", mossy_amt=0.0):
    pal = ramp(base, 6, spread=0.2, hue_shift=0.01)
    # jittered Voronoi stones
    pts = []
    for gy in range(3):
        for gx in range(3):
            pts.append(((gx + r.random()) * N / 3, (gy + r.random()) * N / 3, r.random()))
    yy, xx = np.mgrid[0:N, 0:N]
    best = np.full((N, N), 1e9)
    second = np.full((N, N), 1e9)
    tone = np.zeros((N, N))
    for px, py, t in pts:
        for ox in (-N, 0, N):
            for oy in (-N, 0, N):
                d = np.sqrt((xx - px - ox) ** 2 + (yy - py - oy) ** 2)
                upd = d < best
                second = np.where(upd, best, np.minimum(second, d))
                tone = np.where(upd, t, tone)
                best = np.where(upd, d, best)
    edge = second - best
    v = 0.25 + 0.5 * tone + 0.25 * np.clip(1.0 - best / 6.0, 0, 1)
    img = shade(np.clip(v, 0, 0.999), pal)
    img[edge < 1.0] = pal[0]
    hl = (edge >= 1.0) & (edge < 2.0) & ((yy - 0) % N < N) & (r.random((N, N)) < 0.5)
    img[hl] = pal[4]
    out = rgba(img)
    if mossy_amt:
        out = mossy(out, rng("mossy_cobble"), mossy_amt)
    return out


def bricks(r, base, mortar, rows=4, offset=True):
    pal = ramp(base, 6, spread=0.18)
    mpal = ramp(mortar, 3, spread=0.1)
    img = np.zeros((N, N, 3))
    h = N // rows
    for row in range(rows):
        y0 = row * h
        shift = (h if row % 2 else 0) if offset else 0
        for bx in range(-1, 3):
            x0 = bx * 8 + shift
            tone = 0.3 + 0.5 * r.random()
            for y in range(y0, y0 + h):
                for x in range(x0, x0 + 8):
                    if 0 <= x < N:
                        img[y, x] = shade(np.clip(np.array([tone + 0.25 * (r.random() - 0.5)]), 0, 0.999), pal)[0]
            if 0 <= x0 < N:
                img[y0:y0 + h, x0] = mpal[1]
        img[y0 + h - 1, :] = mpal[0]
        img[y0, :] = np.where(img[y0, :] == mpal[1], img[y0, :], np.minimum(1, img[y0, :] * 1.1))
    return img


def make_terrain(out):
    r = rng("dirt")
    dirt = speckle("8c5a33", r, pebbles=5, pebble_color="b08a6a")
    out["dirt"] = rgba(dirt)
    gt = grass_top(rng("grass"))
    out["grass_block_top"] = rgba(gt)
    out["grass_block_side"] = rgba(fringe_side(dirt, gt, rng("grass_side")))
    out["coarse_dirt"] = rgba(speckle("7a4e2c", rng("coarse"), pebbles=14, pebble_color="9a9a9a"))
    out["sand"] = rgba(speckle("f0d890", rng("sand"), cells=8, spread=0.08))
    out["red_sand"] = rgba(speckle("d8722e", rng("red_sand"), cells=8, spread=0.1))
    gr = rng("gravel")
    g = speckle("8a8580", gr, cells=8, spread=0.22)
    for _ in range(12):
        x, y = gr.integers(0, N, 2)
        c = ramp(["a09a94", "6a6460", "b8a890"][gr.integers(3)], 3)
        g[y, x] = c[2]; g[y, (x + 1) % N] = c[1]; g[(y + 1) % N, x] = c[1]; g[(y + 1) % N, (x + 1) % N] = c[0]
    out["gravel"] = rgba(g)
    cl = speckle("9aa6b8", rng("clay"), cells=2, spread=0.08)
    for y in (4, 11):
        cl[y] = cl[y] * 0.93
    out["clay"] = rgba(cl)
    md = speckle("4a3426", rng("mud"), cells=4, spread=0.2)
    wet = rng("mudwet").random((N, N)) > 0.92
    md[wet] = hexrgb("8a7058")
    out["mud"] = rgba(md)
    out["snow"] = rgba(speckle("eef6ff", rng("snow"), cells=4, spread=0.05))
    ff = speckle("6a4224", rng("forest_floor"), cells=4, spread=0.22)
    fr = rng("forest_floor_litter")
    for _ in range(18):                             # needles and leaf litter
        x, y = fr.integers(0, N, 2)
        c = ramp(["a8642a", "c8862a", "7a5a2a", "5a7a2a"][fr.integers(4)], 3)[2]
        ff[y, x] = c
        ff[y, (x + 1) % N] = c * 0.9
    out["forest_floor_top"] = rgba(ff)
    out["forest_floor_side"] = rgba(fringe_side(dirt, ff, rng("forest_floor_side"), (2, 4)))

    out["stone"] = rgba(stone(rng("stone")))
    out["cobblestone"] = cobble(rng("cobblestone"))
    out["mossy_cobblestone"] = cobble(rng("cobblestone"), mossy_amt=0.5)
    sm = speckle("a8acb4", rng("smooth"), cells=2, spread=0.05)
    outline_rect(sm, ramp("a8acb4", 3)[0], 0, 0, N - 1, N - 1)
    sm[1, 1:N - 1] = ramp("a8acb4", 3)[2]
    out["smooth_stone"] = rgba(sm)
    out["stone_bricks"] = rgba(bricks(rng("stone_bricks"), "8a909a", "5a5e66", rows=2))
    ds = stone(rng("deep_stone"), base="4a4e62")
    for y in range(0, N, 5):
        ds[y] = ds[y] * 0.85
    out["deep_stone"] = rgba(ds)
    br = rng("bedrock")
    b = speckle("3a3a3e", br, cells=4, spread=0.45)
    out["bedrock"] = rgba(b)
    sp = ramp("e8d08a", 6, spread=0.1)
    ss = np.zeros((N, N, 3))
    sn = noise(rng("sandstone"), 4, 2)
    for y in range(N):
        band = 0.55 + 0.3 * np.sin(y * 0.9) + 0.15 * (sn[y] - 0.5)
        ss[y] = shade(np.clip(band, 0, 0.999), sp)
    ss[0:2] = sp[4]; ss[2] = sp[1]; ss[13] = sp[1]; ss[14:] = sp[3]
    out["sandstone"] = rgba(ss)
    out["sandstone_top"] = rgba(speckle("ecd696", rng("sandstone_top"), cells=4, spread=0.06))
    out["sandstone_bottom"] = rgba(speckle("dcc27a", rng("sandstone_bottom"), cells=4, spread=0.1))

    out["bricks"] = rgba(bricks(rng("bricks"), "b84a32", "c8beb0"))


def glass_tex(tint, frame_alpha, inner_alpha, streak_alpha, r):
    pal = ramp(tint, 4, spread=0.15)
    img = np.zeros((N, N, 3)) + pal[2]
    a = np.full((N, N), inner_alpha)
    yy, xx = np.mgrid[0:N, 0:N]
    rim = (xx == 0) | (yy == 0) | (xx == N - 1) | (yy == N - 1)
    img[rim] = pal[3]
    a[rim] = frame_alpha
    img[(xx == 1) & ~rim] = pal[3]
    a[(xx == 1) & ~rim] = frame_alpha * 0.6
    for k in range(3):                              # diagonal streaks
        d = 3 + k * 4
        m = ((xx + yy) == d + 4) & ~rim
        img[m] = 1.0
        a[m] = streak_alpha
    return rgba(img, a)


def make_glass(out):
    out["glass"] = glass_tex("d8f0ff", 0.92, 0.08, 0.5, rng("glass"))
    out["tinted_glass"] = glass_tex("3a2e48", 0.95, 0.6, 0.7, rng("tinted"))
    r = rng("ice")
    ip = ramp("9ad0ff", 5, spread=0.12)
    v = noise(r, 2, 2)
    img = shade(0.3 + 0.5 * v, ip)
    a = np.full((N, N), 0.62)
    for _ in range(9):                              # bubbles
        x, y = r.integers(1, N - 1, 2)
        img[y, x] = hexrgb("ffffff"); a[y, x] = 0.85
    for _ in range(2):                              # cracks
        x, y = r.integers(0, N, 2)
        for k in range(7):
            img[y % N, x % N] = hexrgb("e8f8ff"); a[y % N, x % N] = 0.8
            x += 1; y += r.choice([0, 1, -1])
    out["ice"] = rgba(img, a)
    r = rng("packed_ice")
    pp = ramp("8ab8f0", 6, spread=0.12)
    pi = shade(stretch(0.6 * noise(r, 4, 2) + 0.4 * r.random((N, N))) * 0.999, pp)
    for _ in range(3):
        x, y = r.integers(0, N, 2)
        for k in range(8):
            pi[y % N, x % N] = pp[5]
            x += 1; y += r.choice([0, 1])
    out["packed_ice"] = rgba(pi)

# ---------------------------------------------------------------------------
# colours and lights
# ---------------------------------------------------------------------------

COLORS = {
    "white": "f4f4f0", "light_gray": "a8aab0", "gray": "5a5e66", "black": "26262e",
    "brown": "8a5430", "red": "d8282a", "orange": "f87a1a", "yellow": "fad02a",
    "lime": "8ae02a", "green": "3a9a2a", "cyan": "1aa8b8", "light_blue": "4ab8f8",
    "blue": "2a4ae0", "purple": "8a2ad8", "magenta": "d830c0", "pink": "f88ab8",
}
CRYSTALS = {"blue": "3a8aff", "purple": "a04aff", "green": "3ae88a", "pink": "ff6ac8", "amber": "ffb02a"}


def terracotta(c, r):
    base = hexrgb(c) * 0.82 + hexrgb("a0583a") * 0.18      # earthy, still saturated
    return rgba(speckle(base, r, cells=2, spread=0.07, n_colors=4))


def wool(c, r):
    pal = ramp(c, 5, spread=0.12)
    yy, xx = np.mgrid[0:N, 0:N]
    weave = ((xx + yy) % 4 < 2).astype(float) * 0.3 + ((xx - yy) % 4 < 2).astype(float) * 0.3
    v = 0.25 + weave * 0.6 + 0.25 * (r.random((N, N)) - 0.5)
    return rgba(shade(np.clip(v, 0, 0.999), pal))


def lamp(c, r, frame_c="5a4a3a"):
    fpal = ramp(frame_c, 4, spread=0.2)
    lpal = ramp(c, 5, spread=0.12, sat_boost=1.0)
    img = np.zeros((N, N, 3))
    yy, xx = np.mgrid[0:N, 0:N]
    img[:] = fpal[1]
    outline_rect(img, fpal[0], 0, 0, N - 1, N - 1)
    outline_rect(img, fpal[3], 1, 1, N - 2, N - 2)
    inner = (xx >= 3) & (xx <= 12) & (yy >= 3) & (yy <= 12)
    d = np.sqrt((xx - 7.5) ** 2 + (yy - 7.5) ** 2)
    v = np.clip(1.0 - d / 9.0 + 0.1 * r.random((N, N)), 0, 0.999)
    img[inner] = shade(v[inner] * 0.6 + 0.4, lpal)
    # cross bars
    img[(xx == 7) & inner] = fpal[2]
    img[(yy == 7) & inner] = fpal[2]
    glow = inner.astype(float) * (0.65 + 0.35 * v)
    glow[(xx == 7) | (yy == 7)] = 0
    return rgba(img), glow_layer(glow, c, 0.95)


def crystal_block(c, r):
    pal = ramp(c, 6, spread=0.25)
    yy, xx = np.mgrid[0:N, 0:N]
    frames, gframes = [], []
    facet = ((xx // 4 + yy // 4) % 3) / 3.0
    tri = ((xx % 4) > (yy % 4)).astype(float) * 0.25
    base_v = np.clip(facet + tri + 0.1 * noise(r, 4, 2), 0, 0.999)
    for f in range(FRAMES):
        pulse = 0.5 + 0.5 * np.sin(2 * np.pi * f / FRAMES - (xx + yy) * 0.25)
        img = shade(np.clip(base_v * 0.7 + pulse * 0.3, 0, 0.999), pal)
        edges = ((xx % 4 == 0) | (yy % 4 == 0))
        img[edges] = pal[1]
        sparkle = (r.random((N, N)) > 0.96)
        img[sparkle] = 1.0
        frames.append(rgba(img))
        gframes.append(glow_layer(np.clip(0.35 + 0.65 * pulse * (~edges), 0, 1), c, 0.85))
    return frames, gframes


def make_colors_lights(out):
    for name, c in COLORS.items():
        out[f"{name}_terracotta"] = terracotta(c, rng(name + "t"))
        out[f"{name}_stained_glass"] = glass_tex(c, 0.9, 0.42, 0.62, rng(name + "g"))
        out[f"{name}_wool"] = wool(c, rng(name + "w"))
        img, glow = lamp(c, rng(name + "l"))
        out[f"{name}_lamp"] = img
        out[f"{name}_lamp_glow"] = glow
    img, glow = lamp("fff0c8", rng("lamp"), frame_c="6a5038")
    out["lamp"] = img
    out["lamp_glow"] = glow
    for name, c in CRYSTALS.items():
        frames, gframes = crystal_block(c, rng(name + "crystal"))
        out[f"{name}_crystal"] = frames
        out[f"{name}_crystal_glow"] = gframes
    r = rng("glowstone")
    pal = ramp("ffc83a", 6, spread=0.2, sat_boost=1.0)
    v = 0.5 * noise(r, 4, 3) + 0.5 * r.random((N, N))
    img = shade(stretch(v) * 0.999, pal)
    gaps = noise(rng("glowstone_gaps"), 4, 2) < 0.3
    img[gaps] = hexrgb("6a4a1a")
    out["glowstone"] = rgba(img)
    out["glowstone_glow"] = glow_layer((~gaps).astype(float) * (0.5 + 0.5 * stretch(v)), "ffd85a", 0.9)


def build_all():
    out = {}
    make_terrain(out)
    make_glass(out)
    make_woods(out)
    make_mushrooms(out)
    make_colors_lights(out)
    return out


def main(argv):
    os.makedirs(OUT, exist_ok=True)
    textures = build_all()
    if "--list" in argv:
        for k in sorted(textures):
            print(k)
        return
    wanted = set(a for a in argv if not a.startswith("-"))
    count = 0
    for name, frames in textures.items():
        if wanted and name not in wanted:
            continue
        save(name, frames)
        count += 1
    print(f"texgen: wrote {count} textures to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main(sys.argv[1:])
