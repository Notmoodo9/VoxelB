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



# ---------------------------------------------------------------------------
# shaped blocks: doors, trapdoors, ladders (M7b), pillars
# ---------------------------------------------------------------------------

DOOR_STYLES = {
    "oak": "panels", "birch": "window4", "spruce": "straps", "jungle": "vine",
    "acacia": "diamond", "dark_oak": "carved", "cherry": "blossom", "redwood": "arched",
    "palm": "shutter", "mangrove": "cross", "willow": "willow_leaf", "maple": "maple_leaf",
    "glowwood": "veins", "crystalwood": "crystal", "frostwood": "frost", "emberwood": "cracks",
    "red_mushroom": "porthole", "brown_mushroom": "porthole", "glowing_mushroom": "porthole_glow",
}


def tall_boards(base, r, h=32, vertical=True):
    """Door-sized plank field (h x 16), boards vertical or horizontal."""
    pal = ramp(base, 6, spread=0.13)
    img = np.zeros((h, N, 3))
    if vertical:
        for b in range(4):
            x0 = b * 4
            tone = 0.42 + 0.25 * (r.random() - 0.5)
            for x in range(x0, x0 + 4):
                col = tone + 0.18 * (r.random((h,)) - 0.5) + 0.1 * np.sin(np.arange(h) * 0.7 + x)
                img[:, x] = shade(np.clip(col + 0.05, 0, 0.999), pal)
            img[:, x0 + 3] = pal[1]
    else:
        for b in range(h // 2):
            tone = 0.42 + 0.25 * (r.random() - 0.5)
            row = tone + 0.18 * (r.random((N,)) - 0.5)
            img[b * 2] = shade(np.clip(row + 0.1, 0, 0.999), pal)
            img[b * 2 + 1] = pal[1]
    return img, pal


def frame(img, a, pal, w=1):
    h = img.shape[0]
    img[:w, :] = pal[0]; img[h - w:, :] = pal[0]
    img[:, :w] = pal[0]; img[:, N - w:] = pal[0]
    a[:w, :] = 1; a[h - w:, :] = 1; a[:, :w] = 1; a[:, N - w:] = 1


def panel(img, pal, x0, y0, x1, y1):
    img[y0:y1 + 1, x0:x1 + 1] = pal[3]
    img[y0, x0:x1 + 1] = pal[5]; img[y0:y1 + 1, x0] = pal[5]
    img[y1, x0:x1 + 1] = pal[1]; img[y0:y1 + 1, x1] = pal[1]
    img[y0 + 1:y1, x0 + 1:x1] = pal[3] * 0.97


def door_design(name, base, style):
    r = rng(name + "_door")
    h = 32
    vertical = style not in ("shutter", "vine")
    img, pal = tall_boards(base, r, h, vertical)
    a = np.ones((h, N))
    glow = np.zeros((h, N))
    yy, xx = np.mgrid[0:h, 0:N]
    iron = ramp("6a6e78", 4, spread=0.25)
    if style == "panels":
        panel(img, pal, 3, 3, 12, 13)
        panel(img, pal, 3, 17, 12, 28)
    elif style == "window4":
        img[2:13, 3:13] = pal[1]
        a[3:12, 4:12] = 0
        img[7, 3:13] = pal[1]; a[7, 3:13] = 1
        img[2:13, 7:9] = pal[1]; a[2:13, 7:9] = 1
        panel(img, pal, 3, 17, 12, 28)
    elif style == "straps":
        for y in (5, 6, 24, 25):
            img[y, 1:15] = iron[1 + (y % 2)]
        for y in (5, 24):
            for x in (3, 8, 12):
                img[y, x] = iron[3]
    elif style == "vine":
        vine = ramp("3aa82a", 4, spread=0.25)
        for y in range(h):
            x = int(7 + 4 * np.sin(y * 0.35))
            img[y, x] = vine[2]; img[y, (x + 1) % N] = vine[1]
            if y % 5 == 0:
                img[y, (x + 2) % N] = vine[3]; img[y, (x - 1) % N] = vine[3]
    elif style == "diamond":
        img[:] = shade(np.clip(0.4 + 0.3 * (((xx + yy) // 3) % 2) + 0.1 * r.random((h, N)), 0, 0.999), pal)
        d = np.abs(xx - 7.5) + np.abs(yy - 8)
        img[(d > 3) & (d < 4.6)] = pal[0]
        a[d <= 3] = 0
    elif style == "carved":
        for k, (x0, y0, x1, y1) in enumerate(((2, 2, 13, 29), (4, 4, 11, 13), (4, 18, 11, 27))):
            img[y0, x0:x1 + 1] = pal[0]; img[y1, x0:x1 + 1] = pal[0]
            img[y0:y1 + 1, x0] = pal[0]; img[y0:y1 + 1, x1] = pal[0]
        knot = ((xx - 7.5) ** 2 / 4 + (yy - 8.5) ** 2 / 9) < 2
        img[knot] = pal[0]
        knot2 = ((xx - 7.5) ** 2 / 4 + (yy - 22.5) ** 2 / 9) < 2
        img[knot2] = pal[0]
    elif style == "blossom":
        d = np.sqrt((xx - 7.5) ** 2 + (yy - 8) ** 2)
        img[(d >= 4) & (d < 5.2)] = pal[1]
        a[d < 4] = 0
        petal = ramp("ff8ac8", 3, spread=0.2)
        for ang in range(0, 360, 60):
            px = int(7.5 + 5.5 * np.cos(np.radians(ang)))
            py = int(8 + 5.5 * np.sin(np.radians(ang)))
            img[py, px] = petal[2]
        panel(img, pal, 3, 17, 12, 28)
    elif style == "arched":
        win = ((yy >= 4) & (yy <= 12) & (xx >= 4) & (xx <= 11)) & ~((yy < 7) & ((xx - 7.5) ** 2 + (yy - 7) ** 2 > 14))
        img[win] = pal[0]
        inner = ((yy >= 5) & (yy <= 11) & (xx >= 5) & (xx <= 10)) & ~((yy < 8) & ((xx - 7.5) ** 2 + (yy - 7.5) ** 2 > 8))
        a[inner] = 0
    elif style == "shutter":
        for y in range(0, h, 2):
            img[y] = img[y] * 1.08
            img[y + 1] = pal[0]
    elif style == "cross":
        for t in range(N):
            for k in (0, 1):
                y = int(t * 28 / 15) + 2
                img[min(y + k, h - 1), t] = pal[1]
                img[min(y + k, h - 1), N - 1 - t] = pal[1]
        img[3:9, 5:11] = pal[0]
        a[4:8, 6:10] = 0
    elif style in ("willow_leaf", "maple_leaf"):
        leaf = np.zeros((h, N), bool)
        cy = 16
        if style == "willow_leaf":
            for y in range(6, 27):
                wdt = 3.0 * np.sin((y - 6) / 21 * np.pi)
                leaf[y, int(7.5 - wdt):int(8.5 + wdt)] = True
            leaf[6:27, 7:9] = False
            leaf[6:28, 7] = True
        else:
            d = np.sqrt((xx - 7.5) ** 2 + (yy - cy) ** 2)
            ang = np.arctan2(yy - cy, xx - 7.5)
            leaf = d < (4 + 2.5 * np.abs(np.cos(ang * 2.5)))
            leaf[cy:cy + 10, 7] = True
        img[leaf] = pal[0]
        edge = leaf & ~np.roll(leaf, 1, axis=0)
        img[edge] = pal[1]
    elif style == "veins":
        vm = np.zeros((h, N))
        for x0 in (3, 8, 12):
            x = x0
            for y in range(h):
                vm[y, x] = 1
                if r.random() < 0.3:
                    x = int(np.clip(x + r.choice([-1, 1]), 1, 14))
        img = img * (1 - vm[..., None]) + hexrgb("4fffd0") * vm[..., None]
        glow = vm * 0.9
    elif style == "crystal":
        cr = ramp("d8c8ff", 4, spread=0.15)
        for (x0, y0, x1, y1) in ((3, 3, 7, 13), (8, 3, 12, 13), (3, 17, 7, 28), (8, 17, 12, 28)):
            img[y0:y1 + 1, x0:x1 + 1] = cr[2]
            for k in range(y1 - y0):
                img[y0 + k, x0 + (k % (x1 - x0 + 1))] = cr[3]
            img[y0, x0:x1 + 1] = pal[0]; img[y1, x0:x1 + 1] = pal[0]
            img[y0:y1 + 1, x0] = pal[0]; img[y0:y1 + 1, x1] = pal[0]
    elif style == "frost":
        fr = ramp("eaf6ff", 4, spread=0.08)
        img[3:13, 3:13] = fr[2]
        sp = r.random((10, 10)) > 0.6
        sub = img[3:13, 3:13]
        sub[sp] = fr[3]
        img[3:13, 7] = pal[1]; img[7, 3:13] = pal[1]
        panel(img, pal, 3, 17, 12, 28)
    elif style == "cracks":
        cm = np.zeros((h, N))
        for x0 in (4, 11):
            x = x0
            for y in range(1, h - 1):
                cm[y, x] = 1
                if r.random() < 0.4:
                    x = int(np.clip(x + r.choice([-1, 1]), 1, 14))
        img = img * (1 - cm[..., None]) + np.array([1.0, 0.48, 0.1]) * cm[..., None]
        glow = cm
    elif style.startswith("porthole"):
        d = np.sqrt((xx - 7.5) ** 2 + (yy - 9) ** 2)
        ring = (d >= 3.5) & (d < 5.2)
        img[ring] = ramp("8a8a92", 3)[1]
        a[d < 3.5] = 0
        panel(img, pal, 3, 18, 12, 28)
        if style == "porthole_glow":
            img[ring] = hexrgb("7af0ff")
            glow = ring.astype(float)
    if style not in ("straps", "panels", "porthole", "porthole_glow", "veins", "cracks"):
        img[16, 12:14] = iron[2]                       # handle
    else:
        img[16:18, 12] = iron[2]
    frame(img, a, pal)
    rgbA = np.concatenate([img, a[..., None]], axis=2)
    gl = np.zeros((h, N, 4))
    col = {"veins": "4fffd0", "cracks": "ff7a1a", "porthole_glow": "7af0ff"}.get(style)
    if col:
        gl[..., :3] = hexrgb(col)
        gl[..., 3] = glow
    return rgbA, (gl if col else None)


def trapdoor_design(name, base, style):
    r = rng(name + "_trapdoor")
    img, pal = tall_boards(base, r, N, style not in ("shutter", "vine"))
    a = np.ones((N, N))
    if style in ("window4", "blossom", "arched", "diamond", "cross", "porthole", "porthole_glow"):
        for (x0, y0) in ((3, 3), (9, 3), (3, 9), (9, 9)):
            a[y0:y0 + 4, x0:x0 + 4] = 0
    elif style in ("crystal", "frost"):
        cr = ramp("d8c8ff" if style == "crystal" else "eaf6ff", 3)
        for (x0, y0) in ((3, 3), (9, 3), (3, 9), (9, 9)):
            img[y0:y0 + 4, x0:x0 + 4] = cr[1]
            img[y0, x0:x0 + 4] = cr[2]
    else:
        panel(img, pal, 3, 3, 12, 12)
    img[7:9, :] = pal[1]
    img[:, 7:9] = pal[1]
    a[7:9, :] = 1
    a[:, 7:9] = 1
    frame(img, a, pal)
    return np.concatenate([img, a[..., None]], axis=2)


def make_jungle(out):
    yy, xx = np.mgrid[0:N, 0:N]
    # vine: leafy strands hanging down a trunk face (foliage-tinted, ladder shape)
    r = rng("vine")
    lp = ramp("389d24", 6, spread=0.24)
    img = np.zeros((N, N, 4))
    for sx in (1, 4, 7, 10, 13):
        x = sx + int(r.integers(0, 2))
        end = int(r.integers(8, N + 1))
        for y in range(end):
            x2 = min(N - 1, max(0, x + (1 if (y // 5) % 2 and r.random() < 0.5 else 0)))
            img[y, x2, :3] = lp[1]; img[y, x2, 3] = 1.0
            if r.random() < 0.55:
                lx = min(N - 1, max(0, x2 + int(r.choice([-1, 1]))))
                img[y, lx, :3] = lp[int(r.integers(2, 6))]; img[y, lx, 3] = 1.0
    out["vine"] = img
    # hanging vine: one strand with leaves down the middle (plant sprite)
    r = rng("hanging_vine")
    img = np.zeros((N, N, 4))
    for strand, x0 in ((0, 6), (1, 9)):
        x = x0
        for y in range(N):
            if r.random() < 0.15:
                x = min(11, max(4, x + int(r.choice([-1, 1]))))
            img[y, x, :3] = lp[1 + strand]; img[y, x, 3] = 1.0
            if y % 3 == strand:
                for dx in (-1, 1):
                    if r.random() < 0.8:
                        img[y, x + dx, :3] = lp[int(r.integers(3, 6))]; img[y, x + dx, 3] = 1.0
    out["hanging_vine"] = img
    # shelf fungus: a bracket with orange-tan growth rings (pressure-plate shape)
    r = rng("shelf_fungus")
    fp = ramp("c8803a", 6, spread=0.22, hue_shift=0.01)
    d = np.sqrt(((xx - 7.5) / 7.5) ** 2 + ((yy - 15.0) / 13.0) ** 2)
    ring = (d * 7).astype(int)
    top = np.zeros((N, N, 3)) + fp[1]
    for k in range(8):
        top[ring == k] = fp[[5, 4, 3, 4, 2, 3, 1, 2][k]]
    top += (r.random((N, N, 1)) - 0.5) * 0.06
    out["shelf_fungus"] = rgba(np.clip(top, 0, 1))
    # cocoa pod: ridged orange-brown pods hanging from short stems (ladder shape)
    img = np.zeros((N, N, 4))
    cp = ramp("c06a24", 5, spread=0.22)
    for (cx, cy) in ((4, 7), (11, 10)):
        for y in range(cy - 4, cy + 5):
            for x in range(cx - 3, cx + 4):
                e = ((x - cx) / 2.6) ** 2 + ((y - cy) / 4.2) ** 2
                if e <= 1.0:
                    c = cp[3 if x < cx else 2] if (x - cx) % 2 == 0 else cp[1]
                    img[y, x, :3] = c; img[y, x, 3] = 1.0
        for y in range(0, cy - 4):
            img[y, cx, :3] = hexrgb("5a7a2a"); img[y, cx, 3] = 1.0
    out["cocoa_pod"] = img
    # melon: dark and light green stripes, a pale top with a stem
    r = rng("melon")
    mp = ramp("3a9a2a", 6, spread=0.2)
    side = np.zeros((N, N, 3))
    for x in range(N):
        side[:, x] = mp[1 if (x // 2) % 2 else 3]
    side += (r.random((N, N, 1)) - 0.5) * 0.08
    out["melon_side"] = rgba(np.clip(side, 0, 1))
    dd = np.sqrt((xx - 7.5) ** 2 + (yy - 7.5) ** 2)
    top = np.zeros((N, N, 3))
    top[:] = mp[2]
    for a in range(8):
        ang = a * np.pi / 4
        for k in range(1, 9):
            x = int(round(7.5 + np.cos(ang) * k)); y = int(round(7.5 + np.sin(ang) * k))
            if 0 <= x < N and 0 <= y < N:
                top[y, x] = mp[4]
    top[dd < 2] = hexrgb("6a8a2a")
    top[dd < 1] = hexrgb("4a5a1a")
    out["melon_top"] = rgba(top)
    # bamboo: a green stalk in the middle 4 columns with pale node rings
    bp = ramp("6ab82a", 6, spread=0.2)
    img = np.zeros((N, N, 3)) + bp[2]
    for x in range(N):
        img[:, x] = bp[[1, 2, 4, 3][x % 4]]
    for y in (3, 11):
        img[y] = hexrgb("c8d86a")
        img[y + 1] = bp[0]
    out["bamboo"] = rgba(img)
    top = np.zeros((N, N, 3)) + bp[3]
    top[(dd > 5) & (dd < 8)] = bp[1]
    top[dd < 3] = hexrgb("c8d86a")
    out["bamboo_top"] = rgba(top)
    # bamboo leaves: a tuft of long narrow leaves (plant sprite on top of a stalk)
    r = rng("bamboo_leaves")
    img = np.zeros((N, N, 4))
    for (ang, ln) in ((-2.7, 9), (-2.2, 10), (-1.8, 9), (-1.35, 10), (-0.9, 9), (-0.45, 10), (-3.0, 7), (0.0, 7)):
        for k in range(ln):
            x = int(round(7.5 + np.cos(ang) * k)); y = int(round(11 + np.sin(ang) * k + k * k * 0.07))
            if 0 <= x < N and 0 <= y < N:
                img[y, x, :3] = bp[2 + k * 3 // ln]; img[y, x, 3] = 1.0
    for y in range(11, N):
        img[y, 7, :3] = bp[1]; img[y, 7, 3] = 1.0; img[y, 8, :3] = bp[2]; img[y, 8, 3] = 1.0
    out["bamboo_leaves"] = img
    # heliconia: big paddle leaves below, red lobster-claw bracts with yellow tips above
    r = rng("heliconia")
    gp = ramp("2f9a2a", 6, spread=0.22)
    low = np.zeros((N, N, 4))
    for (bx, lean) in ((4, -1), (8, 0), (12, 1)):
        for i in range(N):
            y = N - 1 - i
            x = bx + (lean * i) // 6
            w = 2 if 4 < i < 14 else 0
            for dx in range(-w, w + 1):
                if 0 <= x + dx < N:
                    low[y, x + dx, :3] = gp[2 + (dx == 0) + (i > 8)]; low[y, x + dx, 3] = 1.0
    out["heliconia_lower"] = low
    up = np.zeros((N, N, 4))
    rp = ramp("e0242a", 4, spread=0.2)
    for y in range(4, N):
        up[y, 8, :3] = gp[2]; up[y, 8, 3] = 1.0
    for k in range(5):
        y = 5 + k * 2
        side = -1 if k % 2 else 1
        for j in range(4):
            x = 8 + side * (j + 1)
            yj = y + (j // 2)
            up[yj, x, :3] = rp[2 if j < 3 else 1]; up[yj, x, 3] = 1.0
        x = 8 + side * 4
        up[y + 1, x, :3] = hexrgb("ffd030"); up[y + 1, x, 3] = 1.0
    out["heliconia_upper"] = up
    # orchid: arching stem with pink-purple blooms
    img = np.zeros((N, N, 4))
    op = ramp("d050d0", 4, spread=0.22)
    for y in range(6, N):
        img[y, 5 + (N - y) // 5, :3] = gp[2]; img[y, 5 + (N - y) // 5, 3] = 1.0
    for (cx, cy) in ((7, 5), (10, 7), (12, 10)):
        for (dx, dy) in ((0, 0), (-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1)):
            img[cy + dy, cx + dx, :3] = op[2 if (dx, dy) != (0, 0) else 3]; img[cy + dy, cx + dx, 3] = 1.0
        img[cy + 1, cx, :3] = hexrgb("ffe8ff")
    for (lx, ly) in ((4, N - 2), (3, N - 3), (8, N - 2), (9, N - 3)):
        img[ly, lx, :3] = gp[3]; img[ly, lx, 3] = 1.0
    out["orchid"] = img
    # bird of paradise: orange crest and a blue tongue on a beak-like bract
    img = np.zeros((N, N, 4))
    for y in range(7, N):
        img[y, 7, :3] = gp[2]; img[y, 7, 3] = 1.0
    for x in range(3, 12):
        img[8 + (x - 3) // 4, x, :3] = hexrgb("3a6a3a"); img[8 + (x - 3) // 4, x, 3] = 1.0
    for (x, y) in ((5, 7), (6, 6), (6, 5), (7, 4), (7, 6), (8, 5), (8, 3), (9, 4), (9, 6), (10, 5), (10, 3)):
        img[y, x, :3] = hexrgb(["ff8a1a", "ffb030"][(x + y) % 2]); img[y, x, 3] = 1.0
    for (x, y) in ((9, 7), (10, 7), (11, 8)):
        img[y, x, :3] = hexrgb("3050e0"); img[y, x, 3] = 1.0
    for (lx, ly) in ((5, N - 3), (9, N - 4), (4, N - 4), (10, N - 5)):
        img[ly, lx, :3] = gp[3]; img[ly, lx, 3] = 1.0
    out["bird_of_paradise"] = img
    # hibiscus: one big open red bloom with a long yellow stamen
    img = flower("hibiscus", "e82030", "ffd040", "cup")
    for dx in range(-3, 4):
        for dy in range(-3, 2):
            if dx * dx + dy * dy <= 10 and img[5 + dy, 8 + dx, 3] == 0:
                img[5 + dy, 8 + dx, :3] = ramp("e82030", 4)[1]; img[5 + dy, 8 + dx, 3] = 1.0
    img[3, 9, :3] = hexrgb("ffd040"); img[2, 10, :3] = hexrgb("ffd040"); img[2, 10, 3] = 1.0
    out["hibiscus"] = img


def make_tundra(out):
    # dwarf shrub: low, scraggly brown twigs fanning out of the ground
    def twigs(name, berries):
        r = rng(name)
        img = np.zeros((N, N, 4))
        bp = ramp("7a5234", 4, spread=0.22)

        def branch(x, y, dx, n, depth):
            for i in range(n):
                if 0 <= x < N and 0 <= y < N:
                    img[y, x, :3] = bp[1 + (i + depth) % 3]
                    img[y, x, 3] = 1.0
                y -= 1
                if i % 2 == 0:
                    x += dx
                if depth < 2 and i == n // 2:
                    branch(x, y, -dx if r.random() < 0.5 else dx, max(2, n - 3), depth + 1)
        for (x0, dx, n) in ((4, -1, 6), (6, -1, 8), (8, 0, 9), (9, 1, 8), (11, 1, 6)):
            branch(x0, N - 1, dx, n, 0)
        if berries:
            for (x, y) in ((3, 10), (7, 9), (10, 8), (12, 11), (6, 12), (9, 12), (5, 8)):
                img[y, x, :3] = hexrgb("e01c2c"); img[y, x, 3] = 1.0
                if x + 1 < N and img[y, x + 1, 3] == 0:
                    img[y, x + 1, :3] = hexrgb("9a0c1a"); img[y, x + 1, 3] = 1.0
            for (x, y) in ((4, 11), (8, 10), (11, 9), (10, 12)):
                img[y, x, :3] = hexrgb("3a6a2a"); img[y, x, 3] = 1.0
        return img
    out["dwarf_shrub"] = twigs("dwarf_shrub", False)
    out["lingonberry_shrub"] = twigs("lingonberry_shrub", True)


def make_badlands(out):
    # dead wood: bleached, sun-cracked grey-white bark with dark splits
    r = rng("dead_wood")
    out["dead_wood"] = bark("dead_wood", "c8c2b4", "groove", r)
    out["dead_wood_top"] = log_top("d8d0c0", "b0a898", rng("dead_wood_top"))


def make_steppe(out):
    # feather grass: tall silvery plumes arching over thin stems (not tinted)
    r = rng("feather_grass")
    sp = ramp("8a9a6a", 4, spread=0.2)
    pp = ramp("e8e8dc", 4, spread=0.1)
    low = np.zeros((N, N, 4))
    for x0 in (2, 4, 6, 8, 10, 12, 14):
        x = x0 + int(r.integers(-1, 2))
        for y in range(N):
            xx = min(N - 1, max(0, x + (1 if y < 4 and x0 > 8 else 0)))
            low[y, xx, :3] = sp[1 + (y % 2)]
            low[y, xx, 3] = 1.0
    out["feather_grass_lower"] = low
    up = np.zeros((N, N, 4))
    for i, (x0, lean) in enumerate(((3, 1), (6, -1), (9, 1), (12, -1), (7, 1))):
        for k in range(N - 1 - i % 2):
            y = N - 1 - k
            x = int(round(x0 + lean * (k * k) / 40.0))
            if not 0 <= x < N:
                break
            if k < 5:
                up[y, x, :3] = sp[2]; up[y, x, 3] = 1.0
                continue
            up[y, x, :3] = pp[1]; up[y, x, 3] = 1.0      # plume core
            for dx in (-1, 1):                              # silky hairs
                if 0 <= x + dx < N and r.random() < 0.7:
                    up[y, x + dx, :3] = pp[3 if dx == lean else 2]; up[y, x + dx, 3] = 1.0
    out["feather_grass_upper"] = up
    # sagebrush: a low, rounded grey-green shrub
    img = np.zeros((N, N, 4))
    r = rng("sagebrush")
    gp = ramp("8a9e80", 5, spread=0.2)
    yy, xx = np.mgrid[0:N, 0:N]
    d = np.sqrt(((xx - 7.5) / 7.0) ** 2 + ((yy - 11.0) / 5.5) ** 2)
    mask = (d < 1.0) & (r.random((N, N)) < 0.8)
    v = noise(r, 4, 2)
    img[mask, :3] = shade(stretch(v)[mask] * 0.999, gp)
    img[mask, 3] = 1.0
    for x in (6, 8, 10):
        for y in range(13, N):
            img[y, x, :3] = hexrgb("6a5a40"); img[y, x, 3] = 1.0
    out["sagebrush"] = img
    # steppe flowers
    def spike(name, color):
        img = np.zeros((N, N, 4))
        cp = ramp(color, 4, spread=0.22)
        gp2 = ramp("5a8a3a", 4)
        for y in range(5, N):
            img[y, 8, :3] = gp2[2]; img[y, 8, 3] = 1.0
        for y in range(2, 10):
            for dx in ((-1, 1) if y % 2 else (0,)):
                img[y, 8 + dx, :3] = cp[1 + y % 3]; img[y, 8 + dx, 3] = 1.0
            img[y, 8, :3] = cp[2]; img[y, 8, 3] = 1.0
        for (lx, ly) in ((7, N - 3), (9, N - 4), (6, N - 2), (10, N - 3)):
            img[ly, lx, :3] = gp2[3]; img[ly, lx, 3] = 1.0
        return img
    out["blue_sage"] = spike("blue_sage", "5a6ae8")
    img = np.zeros((N, N, 4))           # yarrow: flat-topped cluster of tiny yellow florets
    yp = ramp("f0d040", 4, spread=0.2)
    gp2 = ramp("5a8a3a", 4)
    for x in (6, 8, 10):
        for y in range(6, N):
            img[y, x, :3] = gp2[2]; img[y, x, 3] = 1.0
    r = rng("yarrow")
    for x in range(3, 13):
        for y in range(3, 6):
            if r.random() < 0.8 and abs(x - 7.5) < 5.5 - (5 - y):
                img[y, x, :3] = yp[int(r.integers(1, 4))]; img[y, x, 3] = 1.0
    out["yarrow"] = img
    out["pasqueflower"] = flower("pasqueflower", "b050d0", "ffd040", "tulip")
    # salt crust: bright white with faint polygon cracks
    r = rng("salt")
    sp2 = ramp("f4f2ec", 4, spread=0.06)
    v = 0.6 + 0.4 * noise(r, 4, 2)
    img = shade(np.clip(v, 0, 0.999), sp2)
    for _ in range(5):
        x, y = r.integers(0, N, 2)
        L = int(r.integers(3, 7))
        dx, dy = [(1, 0), (0, 1), (1, 1), (1, -1)][r.integers(4)]
        for k in range(L):
            img[(y + dy * k) % N, (x + dx * k) % N] = hexrgb("d8d2c4")
    out["salt"] = rgba(img)


def make_swamp(out):
    yy, xx = np.mgrid[0:N, 0:N]
    # spanish moss: grey-green wispy strands hanging down (plant sprite)
    r = rng("spanish_moss")
    mp = ramp("8a9a78", 5, spread=0.2)
    img = np.zeros((N, N, 4))
    for x0 in range(1, N, 2):
        x = x0
        L = int(r.integers(8, N + 1))
        for y in range(L):
            if r.random() < 0.2:
                x = min(N - 1, max(0, x + int(r.choice([-1, 1]))))
            if r.random() < 0.85:
                img[y, x, :3] = mp[int(r.integers(1, 5))]; img[y, x, 3] = 1.0
    out["spanish_moss"] = img
    # lily pad: a round green pad with a notch and veins (plate shape, top)
    def pad(name, flower):
        r = rng(name)
        lp = ramp("3a8a2a", 5, spread=0.2)
        img = np.zeros((N, N, 4))
        d = np.sqrt((xx - 7.5) ** 2 + (yy - 7.5) ** 2)
        ang = np.arctan2(yy - 7.5, xx - 7.5)
        mask = (d < 7.2) & ~((np.abs(ang - 0.6) < 0.32) & (d > 1.5))
        img[mask, :3] = lp[2]
        img[mask, 3] = 1.0
        for a in range(6):
            t = a * np.pi / 3 + 0.2
            for k in range(1, 7):
                x = int(round(7.5 + np.cos(t) * k)); y = int(round(7.5 + np.sin(t) * k))
                if 0 <= x < N and 0 <= y < N and img[y, x, 3] > 0:
                    img[y, x, :3] = lp[3]
        rim = mask & (d > 6.2)
        img[rim, :3] = lp[1]
        if flower:
            fp = ramp("f0e8f0" if r.random() < 0.5 else "f0a0c8", 4, spread=0.15)
            for (dx, dy) in ((0, 0), (-1, 0), (1, 0), (0, -1), (0, 1), (-2, 0), (2, 0), (0, -2), (0, 2), (-1, -1), (1, 1), (1, -1), (-1, 1)):
                img[8 + dy, 6 + dx, :3] = fp[2 if abs(dx) + abs(dy) > 1 else 3]; img[8 + dy, 6 + dx, 3] = 1.0
            img[8, 6, :3] = hexrgb("ffd040")
        return img
    out["lily_pad"] = pad("lily_pad", False)
    out["flowering_lily_pad"] = pad("flowering_lily_pad", True)
    # cattail: tall leaves with a brown velvet head (2 tall)
    gp = ramp("4a7a2a", 5, spread=0.2)
    low = blades(rng("cattail_lower"), 10, N, N, gp, full=True, taper=False)
    out["cattail_lower"] = low
    up = np.zeros((N, N, 4))
    for (x, top, head) in ((5, 2, True), (9, 4, True), (12, 7, False), (3, 8, False)):
        for y in range(top, N):
            up[y, x, :3] = gp[2]; up[y, x, 3] = 1.0
        if head:
            for y in range(top + 1, top + 6):
                for dx in (0, 1):
                    up[y, x + dx - 0, :3] = hexrgb(["6a4020", "7a4a26"][(y + dx) % 2]); up[y, x + dx, 3] = 1.0
    out["cattail_upper"] = up
    # reeds: thin pale-green stalks with tufted tips
    r = rng("reeds")
    rp = ramp("8aa04a", 4, spread=0.2)
    img = np.zeros((N, N, 4))
    for x0 in (2, 5, 7, 10, 13):
        top = int(r.integers(1, 6))
        for y in range(top, N):
            img[y, x0, :3] = rp[1 + (y % 2)]; img[y, x0, 3] = 1.0
        for dx in (-1, 1):
            if 0 <= x0 + dx < N:
                img[top, x0 + dx, :3] = hexrgb("c8b878"); img[top, x0 + dx, 3] = 1.0
        img[top - 1 if top > 0 else 0, x0, :3] = hexrgb("c8b878"); img[top - 1 if top > 0 else 0, x0, 3] = 1.0
    out["reeds"] = img


def make_dark_forest(out):
    # glowcap: a cluster of small pale-blue mushrooms; the caps glow
    img = np.zeros((N, N, 4))
    mask = np.zeros((N, N))
    cp = ramp("7ad8f0", 4, spread=0.2)
    st = ramp("d8e0e8", 3, spread=0.12)
    for (cx, base, h, w) in ((4, N - 1, 5, 2), (9, N - 1, 8, 3), (12, N - 1, 4, 2), (7, N - 1, 3, 1)):
        for y in range(base - h + 1, base + 1):
            img[y, cx, :3] = st[1]; img[y, cx, 3] = 1.0
        top = base - h
        for dy in range(-1, 1):
            ww = w if dy == 0 else w - 1
            for dx in range(-ww, ww + 1):
                x, y = cx + dx, top + dy
                if 0 <= x < N and 0 <= y < N:
                    img[y, x, :3] = cp[2 if dy < 0 else 1]; img[y, x, 3] = 1.0
                    mask[y, x] = 1.0
        if 0 <= top - 1 < N:
            img[top - 1, cx, :3] = cp[3]; mask[top - 1, cx] = 1.0
    out["glowcap"] = img
    out["glowcap_glow"] = glow_layer(mask, "a8f0ff", 0.85)


def make_glowing_forest(out):
    # glow flowers: cyan bells and teal stars; the blooms glow
    def glowing(img, color):
        mask = np.zeros((N, N))
        c = np.array(hexrgb(color))
        for y in range(N):
            for x in range(N):
                if img[y, x, 3] > 0 and np.abs(img[y, x, :3] - c).sum() < 0.9 and img[y, x, :3].sum() > 1.2:
                    mask[y, x] = 1.0
        return mask
    bell = flower("glow_bellflower", "58e8f0", "e8ffff", "bells")
    out["glow_bellflower"] = bell
    out["glow_bellflower_glow"] = glow_layer(glowing(bell, "58e8f0"), "a0f8ff", 0.9)
    star = flower("star_bloom", "40e0b0", "f0fff0", "star")
    out["star_bloom"] = star
    out["star_bloom_glow"] = glow_layer(glowing(star, "40e0b0"), "90ffd8", 0.9)
    # glow fern: dark teal fronds with luminous tips
    img = np.zeros((N, N, 4))
    mask = np.zeros((N, N))
    gp = ramp("2a7a6a", 6, spread=0.22)
    r = rng("glow_fern")
    for k, (bx, lean) in enumerate(((3, -1), (6, 0), (9, 0), (12, 1), (8, 1), (5, -1))):
        h = int(r.integers(9, 15))
        for i in range(h):
            y = N - 1 - i
            x = bx + (lean * (i * i) // 40)
            if 0 <= x < N:
                tip = i >= h - 3
                img[y, x, :3] = hexrgb("90fff0") if tip else gp[1 + (i * 3) // h]
                img[y, x, 3] = 1.0
                if tip:
                    mask[y, x] = 1.0
                if i > 2 and i % 2 == 0:
                    for dx in (-1, 1):
                        xx = x + dx
                        if 0 <= xx < N:
                            img[y, xx, :3] = gp[2 + (i * 3) // h]
                            img[y, xx, 3] = 1.0
    out["glow_fern"] = img
    out["glow_fern_glow"] = glow_layer(mask, "90fff0", 0.8)
    # glow moss: deep teal moss with bright cyan specks
    r = rng("glow_moss")
    mp = ramp("1e5a50", 6, spread=0.2, hue_shift=0.01)
    v = 0.6 * noise(r, 4, 3) + 0.4 * r.random((N, N))
    m = shade(stretch(v) * 0.999, mp)
    specks = r.random((N, N)) < 0.12
    m[specks] = hexrgb("7af8e8")
    out["glow_moss"] = rgba(m)
    out["glow_moss_glow"] = glow_layer(specks.astype(float), "7af8e8", 0.9)


def make_sky_islands(out):
    # hanging roots: brown root strands with thin rootlets (plant sprite)
    r = rng("hanging_roots")
    rp = ramp("7a5230", 5, spread=0.22)
    img = np.zeros((N, N, 4))
    for x0 in (3, 7, 10, 13):
        x = x0
        L = int(r.integers(10, N + 1))
        for y in range(L):
            if r.random() < 0.18:
                x = min(N - 1, max(0, x + int(r.choice([-1, 1]))))
            img[y, x, :3] = rp[1 + (y % 3)]; img[y, x, 3] = 1.0
            if r.random() < 0.25:
                xx = min(N - 1, max(0, x + int(r.choice([-1, 1]))))
                img[y, xx, :3] = rp[3]; img[y, xx, 3] = 1.0
    out["hanging_roots"] = img


def ladder_design(name, base):
    pal = ramp(base, 5, spread=0.15)
    img = np.zeros((N, N, 3)) + pal[1]
    a = np.zeros((N, N))
    for x in (2, 3, 12, 13):
        img[:, x] = pal[2 if x in (2, 12) else 1]
        a[:, x] = 1
    for y in (1, 5, 9, 13):
        img[y, 2:14] = pal[3]
        img[y + 1, 2:14] = pal[1]
        a[y:y + 2, 2:14] = 1
    return rgba(img, a)


PILLAR_MATERIALS = {
    "stone": "7e8794", "cobblestone": "7a8088", "mossy_cobblestone": "6a7a6a",
    "smooth_stone": "a8acb4", "stone_bricks": "8a909a", "deep_stone": "4a4e62",
    "sandstone": "e8d08a", "bricks": "b84a32",
}


def pillar(name, base):
    r = rng(name + "_pillar")
    pal = ramp(base, 6, spread=0.16)
    yy, xx = np.mgrid[0:N, 0:N]
    flute = 0.55 + 0.3 * np.cos((xx + 0.5) * np.pi / 2.0)
    v = flute + 0.12 * (r.random((N, N)) - 0.5)
    side = shade(np.clip(v, 0, 0.999), pal)
    side[:, (xx[0] % 4) == 0] = pal[1]
    d = np.maximum(np.abs(xx - 7.5), np.abs(yy - 7.5))
    top = shade(np.clip(0.45 + 0.3 * ((d.astype(int) // 2) % 2) + 0.1 * r.random((N, N)), 0, 0.999), pal)
    top[d > 6.5] = pal[1]
    return rgba(side), rgba(top)


def make_shapes(out):
    planks_of = {w: v[1] for w, v in WOODS.items()}
    planks_of.update({m: v[4] for m, v in MUSHROOMS.items()})
    for wood, base in planks_of.items():
        style = DOOR_STYLES[wood]
        door, glow = door_design(wood, base, style)
        out[f"{wood}_door_top"] = door[:16]
        out[f"{wood}_door_bottom"] = door[16:]
        if glow is not None:
            out[f"{wood}_door_top_glow"] = glow[:16]
            out[f"{wood}_door_bottom_glow"] = glow[16:]
        out[f"{wood}_trapdoor"] = trapdoor_design(wood, base, style)
        out[f"{wood}_ladder"] = ladder_design(wood, base)
    for mat, base in PILLAR_MATERIALS.items():
        side, top = pillar(mat, base)
        out[f"{mat}_pillar"] = side
        out[f"{mat}_pillar_top"] = top


def make_water(out):
    """Still water (M8): vibrant blue, translucent, 16 looping wave frames."""
    pal = ramp("2a7ae8", 6, spread=0.14, hue_shift=0.01)
    yy, xx = np.mgrid[0:N, 0:N]
    frames = []
    for f in range(16):
        t = 2 * np.pi * f / 16
        v = (0.5 + 0.22 * np.sin(xx * 2 * np.pi / 16 * 2 + t)
             + 0.18 * np.sin((xx + yy) * 2 * np.pi / 16 + 2 * t)
             + 0.12 * np.sin(yy * 2 * np.pi / 16 * 3 - t))
        img = shade(np.clip(v * 0.75, 0, 0.999), pal)
        crest = v > 0.95
        img[crest] = hexrgb("bfe6ff")
        a = np.full((N, N), 0.72)
        a[crest] = 0.85
        frames.append(rgba(img, a))
    out["water"] = frames


# ---------------------------------------------------------------------------
# underground (M9): lava, dripstone, ores
# ---------------------------------------------------------------------------

ORES = {
    # name: (fleck colour, host, style)
    "coal_ore": ("2a2a30", "stone", "chunks"),
    "copper_ore": ("e07a3a", "stone", "veins"),
    "deep_copper_ore": ("e07a3a", "deep_stone", "veins"),
    "iron_ore": ("d8a882", "stone", "chunks"),
    "deep_iron_ore": ("d8a882", "deep_stone", "chunks"),
    "silver_ore": ("e8ecf4", "stone", "chunks"),
    "deep_silver_ore": ("e8ecf4", "deep_stone", "chunks"),
    "gold_ore": ("ffd23a", "stone", "chunks"),
    "deep_gold_ore": ("ffd23a", "deep_stone", "chunks"),
    "emerald_ore": ("2ae87a", "stone", "gems"),
    "diamond_ore": ("6af0f0", "deep_stone", "gems"),
    "mythril_ore": ("3a8aff", "deep_stone", "veins"),
    "adamantite_ore": ("ff3a3a", "deep_stone", "gems"),
    "star_crystal_ore": ("fff0a8", "deep_stone", "stars"),
}


def make_underground(out):
    # lava: bright, slowly churning, 16 frames
    pal = ramp("ff6a1a", 6, spread=0.22, hue_shift=0.03, sat_boost=1.0)
    yy, xx = np.mgrid[0:N, 0:N]
    frames, gframes = [], []
    base = noise(rng("lava"), 4, 3)
    for f in range(16):
        t = 2 * np.pi * f / 16
        v = 0.55 * base + 0.25 * np.sin(xx * 0.8 + t + base * 4) + 0.2 * np.sin(yy * 0.6 - t * 2 + base * 3)
        img = shade(np.clip(stretch(v) * 0.999, 0, 0.999), pal)
        crust = stretch(v) < 0.15
        img[crust] = hexrgb("6a1a0a")
        frames.append(rgba(img))
        gframes.append(glow_layer((~crust).astype(float) * (0.6 + 0.4 * stretch(v)), "ff9a3a", 1.0))
    out["lava"] = frames
    out["lava_glow"] = gframes
    # dripstone: warm brown-grey with vertical streaks
    dp = ramp("8a7464", 6, spread=0.18)
    r = rng("dripstone")
    col = noise(r, 16, 1)[0]
    v = 0.55 * stretch(col)[None, :] + 0.45 * noise(r, 4, 2)
    out["dripstone_block"] = rgba(shade(stretch(v) * 0.999, dp))
    pd = shade(stretch(v) * 0.999, dp)
    out["pointed_dripstone"] = rgba(pd)
    # ores: host stone with coloured flecks
    stone_img = {"stone": stone(rng("stone")), "deep_stone": stone(rng("deep_stone"), base="4a4e62")}
    for y in range(0, N, 5):
        stone_img["deep_stone"][y] = stone_img["deep_stone"][y] * 0.85
    for name, (col_hex, host, style) in ORES.items():
        r = rng(name)
        img = stone_img[host].copy()
        op = ramp(col_hex, 4, spread=0.28, sat_boost=1.15)
        glow = np.zeros((N, N))
        spots = 9 if style != "gems" else 7
        for _ in range(spots):
            x, y = r.integers(1, N - 2, 2)
            if style == "chunks":
                cells = [(0, 0), (1, 0), (0, 1), (1, 1), (2, 1)][: r.integers(3, 6)]
            elif style == "gems":
                cells = [(0, 0), (1, 1), (0, 1)][: r.integers(1, 4)]
            elif style == "stars":
                cells = [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)]
            else:  # veins
                cells = [(k, int(np.round(np.sin(k)))) for k in range(r.integers(2, 4))]
            for i, (dx, dy) in enumerate(cells):
                px, py = (x + dx) % N, (y + dy) % N
                img[py, px] = op[3] if i == 0 else op[2]
                glow[py, px] = 1.0
            img[(y + 1) % N, (x + 1) % N] = op[0] * 0.7     # shadow under the fleck
        out[name] = rgba(img)
        if name == "star_crystal_ore":
            out[name + "_glow"] = glow_layer(glow, col_hex, 1.0)


# ---------------------------------------------------------------------------
# plants (Milestone 10): crossed-plane sprites with transparent background.
# Grass is drawn in the grass texture's own green so the biome tint factor
# applies to it the same way as to the grass block.
# ---------------------------------------------------------------------------
FLOWERS = {
    # name: (petal colour, centre colour, style)
    "poppy": ("e8322a", "2a1a14", "cup"),
    "dandelion": ("ffd21f", "e8a010", "puff"),
    "cornflower": ("3f6fe8", "26318c", "spiky"),
    "oxeye_daisy": ("f4f4ee", "f2c21c", "daisy"),
    "allium": ("b56ae8", "7f3fb8", "ball"),
    "red_tulip": ("e8323a", "9a1a20", "tulip"),
    "orange_tulip": ("ff8a24", "c45a10", "tulip"),
    "white_tulip": ("f2f2f0", "c8d0c8", "tulip"),
    "pink_tulip": ("ff8fc0", "d0508a", "tulip"),
    "lily_of_the_valley": ("fbfbf4", "d8e0c8", "bells"),
    "bluebell": ("4a6cf0", "2c3fa8", "bells"),
    "wood_anemone": ("faf6fa", "f0d040", "star"),
}


def blades(r, n, hmin, hmax, pal, full=False, taper=True):
    img = np.zeros((N, N, 4))
    for _ in range(n):
        x = int(r.integers(1, N - 1))
        h = N if full else int(r.integers(hmin, hmax + 1))
        lean = r.choice([-1, 0, 0, 1])
        for k in range(h):
            y = N - 1 - k
            xx = x + (lean if k > h * 0.6 else 0)
            if not 0 <= xx < N:
                continue
            shade_i = min(len(pal) - 1, 1 + k * (len(pal) - 2) // max(h, 1))
            img[y, xx, :3] = pal[shade_i]
            img[y, xx, 3] = 1.0
            if not taper and k < h - 1 and xx + 1 < N and r.random() < 0.25:
                img[y, xx + 1, :3] = pal[max(0, shade_i - 1)]
                img[y, xx + 1, 3] = 1.0
    return img


def stem(img, x, top, pal):
    for y in range(top, N):
        img[y, x, :3] = pal[2]
        img[y, x, 3] = 1.0
    # two small leaves
    for (dx, y) in ((-1, N - 4), (1, N - 6)):
        if 0 <= x + dx < N:
            img[y, x + dx, :3] = pal[3]
            img[y, x + dx, 3] = 1.0


def flower(name, petal, centre, style):
    r = rng(name)
    sp = ramp("3f9a32", 6, spread=0.2)
    pp = ramp(petal, 4, spread=0.22)
    cp = hexrgb(centre)
    img = np.zeros((N, N, 4))
    cx = 8
    top = {"ball": 3, "tulip": 6}.get(style, 5)
    if style == "bells":          # an arching stem with hanging bells
        for y in range(6, N):
            img[y, cx, :3] = sp[2]; img[y, cx, 3] = 1.0
        for x in range(cx, cx + 4):
            img[5, x, :3] = sp[3]; img[5, x, 3] = 1.0
        for (lx, ly) in ((6, N - 3), (9, N - 5)):
            img[ly, lx, :3] = sp[3]; img[ly, lx, 3] = 1.0
        for i, bx in enumerate((cx + 1, cx + 3, cx + 5, cx - 1)):
            by = 6 + (i % 2)
            for dy in range(3):
                for dx in (-1, 0) if dy else (0,):
                    xx, yy = bx + dx, by + dy
                    if 0 <= xx < N:
                        img[yy, xx, :3] = pp[2 if dy < 2 else 3]
                        img[yy, xx, 3] = 1.0
            img[by + 2, bx, :3] = hexrgb(centre); img[by + 2, bx, 3] = 1.0
        return img
    stem(img, cx, top + 2, sp)

    def px(x, y, c):
        if 0 <= x < N and 0 <= y < N:
            img[y, x, :3] = c
            img[y, x, 3] = 1.0
    cy = top
    if style == "cup":            # poppy: four broad petals, dark heart
        for dx in range(-2, 3):
            for dy in range(-2, 2):
                if abs(dx) + abs(dy) <= 3:
                    px(cx + dx, cy + dy, pp[2 if dy < 0 else 1])
        px(cx, cy, cp); px(cx - 1, cy - 1, pp[3]); px(cx + 1, cy - 2, pp[3])
    elif style == "puff":         # dandelion: round yellow head
        for dx in range(-2, 3):
            for dy in range(-2, 2):
                if dx * dx + dy * dy <= 5:
                    px(cx + dx, cy + dy, pp[1 + (dx + dy) % 3])
        px(cx, cy, cp)
    elif style == "spiky":        # cornflower: ragged petals
        for a in range(10):
            ang = a * 2 * np.pi / 10
            for d in (1, 2, 3 if a % 2 else 2):
                px(int(round(cx + np.cos(ang) * d)), int(round(cy + np.sin(ang) * d * 0.7)), pp[1 + a % 3])
        px(cx, cy, cp)
    elif style == "daisy":        # oxeye daisy: white ring, yellow centre
        for a in range(12):
            ang = a * 2 * np.pi / 12
            for d in (2, 3):
                px(int(round(cx + np.cos(ang) * d)), int(round(cy + np.sin(ang) * d * 0.75)), pp[2 + a % 2])
        for dx in (-1, 0, 1):
            px(cx + dx, cy, cp)
        px(cx, cy - 1, cp)
    elif style == "star":         # wood anemone: small five-petal star
        for (dx, dy) in ((0, -2), (-2, -1), (2, -1), (-1, 1), (1, 1), (0, -1), (-1, 0), (1, 0), (0, 1), (-1, -1), (1, -1)):
            px(cx + dx, cy + dy, pp[2 if abs(dx) + abs(dy) > 1 else 3])
        px(cx, cy, cp)
    elif style == "ball":         # allium: purple sphere of florets
        for dx in range(-3, 4):
            for dy in range(-3, 3):
                if dx * dx + dy * dy <= 9 and r.random() < 0.85:
                    px(cx + dx, cy + dy, pp[int(r.integers(0, 4))])
    elif style == "tulip":        # tulip: closed cup
        for dy in range(-3, 1):
            w = 2 if dy > -3 else 1
            for dx in range(-w, w + 1):
                px(cx + dx, cy + dy, pp[3 if dx < 0 else 1])
        px(cx - 1, cy - 4, pp[2]); px(cx + 1, cy - 4, pp[2])
        px(cx, cy - 1, hexrgb(centre))
    return img


def mushroom_sprite(name, cap, spots, stem_c="e8dcc4", style="red"):
    r = rng(name)
    img = np.zeros((N, N, 4))
    cp = ramp(cap, 4, spread=0.22)
    st = ramp(stem_c, 3, spread=0.15)

    def px(x, y, c):
        if 0 <= x < N and 0 <= y < N:
            img[y, x, :3] = c
            img[y, x, 3] = 1.0
    for y in range(N - 5, N):           # stem
        px(7, y, st[1]); px(8, y, st[2])
    if style == "red":                  # round dome with white spots
        for y in range(N - 10, N - 5):
            w = [2, 4, 5, 5, 5][y - (N - 10)]
            for x in range(8 - w, 8 + w):
                px(x, y, cp[2 if y < N - 7 else 1])
        for (x, y) in ((5, N - 8), (9, N - 9), (10, N - 7), (7, N - 9), (4, N - 7)):
            px(x, y, hexrgb(spots))
    else:                               # flat brown cap
        for y in range(N - 8, N - 5):
            w = [3, 5, 6][y - (N - 8)]
            for x in range(8 - w, 8 + w):
                px(x, y, cp[2 if y == N - 8 else 1])
        px(6, N - 8, cp[3]); px(9, N - 8, cp[3])
    return img


def make_forest(out):
    gp = ramp("56ca42", 6, spread=0.22)
    # fern: arching fronds with leaflets (grass-tinted like the grass)
    img = np.zeros((N, N, 4))
    r = rng("fern")
    for k, (bx, lean) in enumerate(((3, -1), (6, 0), (9, 0), (12, 1), (8, 1), (5, -1))):
        h = int(r.integers(9, 15))
        for i in range(h):
            y = N - 1 - i
            x = bx + (lean * (i * i) // 40)
            if 0 <= x < N:
                img[y, x, :3] = gp[1 + (i * 3) // h]
                img[y, x, 3] = 1.0
                if i > 2 and i % 2 == 0:
                    for dx in (-1, 1):
                        xx = x + dx
                        if 0 <= xx < N:
                            img[y, xx, :3] = gp[2 + (i * 3) // h]
                            img[y, xx, 3] = 1.0
    out["fern"] = img
    out["red_mushroom"] = mushroom_sprite("red_mushroom", "e02a24", "fff6f0", style="red")
    out["brown_mushroom"] = mushroom_sprite("brown_mushroom", "a87650", "", style="brown")
    # moss block: soft, deep green, fine texture
    r = rng("moss_block")
    mp = ramp("8aa832", 6, spread=0.2, hue_shift=0.01)
    v = 0.6 * noise(r, 4, 3) + 0.4 * r.random((N, N))
    m = shade(stretch(v) * 0.999, mp)
    tips = r.random((N, N)) < 0.08
    m[tips] = hexrgb("8fd85a")
    out["moss_block"] = rgba(m)
    # mossy oak log: the oak bark with moss creeping up from the bottom
    base = out["oak_log"]
    base = base[0] if isinstance(base, list) else base
    out["mossy_oak_log"] = mossy(base[::-1], rng("mossy_oak_log"), amount=0.55)[::-1]


def make_plants(out):
    gp = ramp("56ca42", 6, spread=0.22)
    out["short_grass"] = blades(rng("short_grass"), 18, 4, 12, gp, taper=False)
    lower = blades(rng("tall_grass_lower"), 14, N, N, gp, full=True, taper=False)
    upper = blades(rng("tall_grass_upper"), 13, 5, 15, gp, taper=False)
    out["tall_grass_lower"] = lower
    out["tall_grass_upper"] = upper
    for name, (petal, centre, style) in FLOWERS.items():
        out[name] = flower(name, petal, centre, style)
    # flowering oak leaves: the oak leaves with small white-pink blossoms
    base = out["oak_leaves"]
    base = base[0] if isinstance(base, list) else base
    img = base.copy()
    r = rng("flowering_oak_leaves")
    bp = [hexrgb("fff4f8"), hexrgb("ffc8dc"), hexrgb("ff9ec2")]
    for _ in range(9):
        x, y = r.integers(0, N, 2)
        if img[y, x, 3] < 0.5:
            continue
        for (dx, dy) in ((0, 0), (1, 0), (0, 1), (-1, 0), (0, -1)):
            xx, yy = (x + dx) % N, (y + dy) % N
            img[yy, xx, :3] = bp[0 if (dx, dy) == (0, 0) else int(r.integers(1, 3))]
            img[yy, xx, 3] = 1.0
    out["flowering_oak_leaves"] = img


def make_desert(out):
    # cactus: green ribs with darker grooves and pale spines
    r = rng("cactus")
    cp = ramp("4fa83a", 6, spread=0.2)
    img = np.zeros((N, N, 3))
    for x in range(N):
        rib = (x % 4)
        v = [1, 3, 4, 2][rib]
        for y in range(N):
            img[y, x] = cp[v] if r.random() > 0.12 else cp[max(0, v - 1)]
    for _ in range(14):
        x, y = r.integers(0, N, 2)
        if x % 4 == 2:
            img[y, x] = hexrgb("f4ecc8")
    out["cactus"] = rgba(img)
    top = np.zeros((N, N, 3))
    yy, xx = np.mgrid[0:N, 0:N]
    d = np.sqrt((xx - 7.5) ** 2 + (yy - 7.5) ** 2)
    top[:] = cp[3]
    top[d < 5] = cp[4]
    top[d < 2] = cp[5]
    for a in range(8):
        ang = a * np.pi / 4
        for k in range(2, 8):
            x = int(round(7.5 + np.cos(ang) * k))
            y = int(round(7.5 + np.sin(ang) * k))
            if 0 <= x < N and 0 <= y < N:
                top[y, x] = cp[1]
    out["cactus_top"] = rgba(top)
    # cactus flower: a small pink bloom (plant sprite, sits on the cactus)
    img = np.zeros((N, N, 4))
    fp = ramp("ff5fa8", 4, spread=0.22)
    for (dx, dy, c) in ((0, 0, 3), (-1, 0, 2), (1, 0, 2), (0, -1, 2), (-2, 1, 1), (2, 1, 1), (-1, 1, 2), (1, 1, 2),
                        (0, 1, 3), (-1, -1, 1), (1, -1, 1), (0, -2, 1)):
        x, y = 8 + dx, N - 3 + dy
        img[y, x, :3] = fp[c]
        img[y, x, 3] = 1.0
    img[N - 3, 8, :3] = hexrgb("ffe060")
    for y in range(N - 1, N):
        for x in range(6, 11):
            img[y, x, :3] = cp[2]
            img[y, x, 3] = 1.0
    out["cactus_flower"] = img
    # dead bush: twiggy brown branches
    img = np.zeros((N, N, 4))
    r = rng("dead_bush")
    bp = ramp("8a6236", 4, spread=0.2)

    def branch(x, y, dx, n, depth):
        for i in range(n):
            if 0 <= x < N and 0 <= y < N:
                img[y, x, :3] = bp[1 + (i % 2)]
                img[y, x, 3] = 1.0
            y -= 1
            if i % 2 == 1:
                x += dx
            if depth < 2 and i == n // 2:
                branch(x, y, -dx if r.random() < 0.5 else dx, n - 2, depth + 1)
    branch(7, N - 1, -1, 9, 0)
    branch(8, N - 1, 1, 10, 0)
    branch(8, N - 2, 0, 6, 1)
    out["dead_bush"] = img
    # bone block: off-white with fine grain, ring ends
    r = rng("bone_block")
    bp = ramp("e8e0c8", 5, spread=0.12)
    v = 0.6 * noise(r, 2, 2) + 0.4 * r.random((N, N))
    side = shade(stretch(v) * 0.999, bp)
    for y in range(0, N, 5):
        side[y] = side[y] * 0.9
    out["bone_block"] = rgba(side)
    top = np.zeros((N, N, 3))
    top[:] = bp[3]
    top[(d > 5.5) & (d < 7)] = bp[1]
    top[d < 3] = bp[2]
    top[d < 1.5] = hexrgb("b8ae94")
    out["bone_block_top"] = rgba(top)


def make_taiga(out):
    # spruce needle floor: dark brown with short orange-brown needle strokes
    r = rng("spruce_needle_floor")
    nf = speckle("4e3420", r, cells=4, spread=0.2)
    for _ in range(26):
        x, y = r.integers(0, N, 2)
        c = ramp(["b0682a", "8a5226", "c88838"][r.integers(3)], 3)[2]
        dx, dy = [(1, 0), (0, 1), (1, 1), (1, -1)][r.integers(4)]
        nf[y, x] = c
        nf[(y + dy) % N, (x + dx) % N] = c * 0.85
    out["spruce_needle_floor_top"] = rgba(nf)
    dirt = out["dirt"]
    dirt = dirt[0] if isinstance(dirt, list) else dirt
    out["spruce_needle_floor_side"] = rgba(fringe_side(dirt[..., :3], nf, rng("snf_side"), (2, 4)))
    # berry bush: a low round leafy bush with red berries
    img = np.zeros((N, N, 4))
    r = rng("berry_bush")
    lp = ramp("3c8a34", 5, spread=0.22)
    yy, xx = np.mgrid[0:N, 0:N]
    d = np.sqrt(((xx - 7.5) / 7.5) ** 2 + ((yy - 10.0) / 6.0) ** 2)
    mask = (d < 1.0) & (r.random((N, N)) < 0.85)
    v = noise(r, 4, 2)
    img[mask, :3] = shade(stretch(v)[mask] * 0.999, lp)
    img[mask, 3] = 1.0
    for _ in range(9):
        x = int(r.integers(2, 14)); y = int(r.integers(6, 15))
        if img[y, x, 3] > 0:
            img[y, x, :3] = hexrgb("e0242a"); img[y, x, 3] = 1.0
            if x + 1 < N:
                img[y, x + 1, :3] = hexrgb("a01418"); img[y, x + 1, 3] = 1.0
    out["berry_bush"] = img


def make_savanna(out):
    # termite mound: packed reddish-brown earth with darker tunnels
    r = rng("termite_mound")
    img = speckle("a2603a", r, cells=4, spread=0.2)
    for _ in range(10):
        x, y = r.integers(0, N, 2)
        img[y, x] = hexrgb("5a2e1a")
        img[(y + 1) % N, x] = hexrgb("6e3a22")
    for y in range(0, N, 4):
        img[y] = img[y] * 0.93
    out["termite_mound"] = rgba(img)


def build_all():
    out = {}
    make_terrain(out)
    make_glass(out)
    make_woods(out)
    make_mushrooms(out)
    make_colors_lights(out)
    make_shapes(out)
    make_water(out)
    make_underground(out)
    make_plants(out)
    make_forest(out)
    make_desert(out)
    make_taiga(out)
    make_savanna(out)
    make_jungle(out)
    make_tundra(out)
    make_badlands(out)
    make_steppe(out)
    make_swamp(out)
    make_dark_forest(out)
    make_glowing_forest(out)
    make_sky_islands(out)
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
