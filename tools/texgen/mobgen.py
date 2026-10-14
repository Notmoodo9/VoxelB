#!/usr/bin/env python3
"""VoxelB animal skin generator (milestone 19, design/mobs/passive_animals.md).

Reads the models (box parts and their skin positions) from data/mobs/*.mob
and paints every skin listed below as hand-shaded pixel art into
assets/textures/mobs/<skin>.png. Patterns (spots, blazes, shaggy coats) are
worked out at each texel's 3D point on the model, so they continue across
the faces of a box and from one box to the next.

The box layout in a skin (pixels, the same as shaders/mob.vert):
    top    (u + d,         v)      w x d      bottom (u + d + w, v)  w x d
    -X     (u,             v + d)  d x h      front  (u + d, v + d)  w x h
    +X     (u + d + w,     v + d)  d x h      back   (u + 2d + w, v + d)  w x h

    python3 tools/texgen/mobgen.py            # every skin
    python3 tools/texgen/mobgen.py cow_brown   # only these
    python3 tools/texgen/mobgen.py --list

Deterministic: the same script always produces the same pixels.
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
from texgen import hexrgb, ramp  # noqa: E402

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
OUT = os.path.join(ROOT, "assets", "textures", "mobs")


# ---- the models (data/mobs/*.mob) ------------------------------------------------------
def load_models():
    models = {}
    cur = None
    for path in sorted(glob.glob(os.path.join(ROOT, "data", "mobs", "*.mob"))):
        for line in open(path, encoding="utf-8"):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("["):
                head = line[1:-1].split()
                cur = None
                if head[0] == "model":
                    cur = {"size": (64, 64), "parts": []}
                    models[head[1]] = cur
                continue
            if cur is None or "=" not in line:
                continue
            key, val = (s.strip() for s in line.split("=", 1))
            if key == "skin_size":
                w, h = val.split()
                cur["size"] = (int(w), int(h))
            elif key == "part":
                f = [s.strip() for s in val.split(",")]
                piv = [float(x) for x in f[2].split()]
                box = [float(x) for x in f[3].split()]
                size = [int(float(x)) for x in f[4].split()]
                uv = [int(x) for x in f[5].split()]
                cur["parts"].append({"name": f[0], "motion": f[1], "pivot": piv,
                                     "box": box, "size": size, "uv": uv})
    return models


FACES = ("top", "bottom", "west", "front", "east", "back")


def face_rect(p, face):
    w, h, d = p["size"]
    u, v = p["uv"]
    return {"top": (u + d, v, w, d), "bottom": (u + d + w, v, w, d),
            "west": (u, v + d, d, h), "front": (u + d, v + d, w, h),
            "east": (u + d + w, v + d, d, h), "back": (u + 2 * d + w, v + d, w, h)}[face]


def face_point(p, face, s, t):
    """The model-space point (pixels) of face coordinates s, t (0..1, t down)."""
    w, h, d = p["size"]
    ox = p["pivot"][0] + p["box"][0]
    oy = p["pivot"][1] + p["box"][1]
    oz = p["pivot"][2] + p["box"][2]
    q = {"top": (s, 1.0, t), "bottom": (s, 0.0, t), "west": (0.0, 1.0 - t, s),
         "front": (1.0 - s, 1.0 - t, 0.0), "east": (1.0, 1.0 - t, 1.0 - s),
         "back": (s, 1.0 - t, 1.0)}[face]
    return np.array([ox + q[0] * w, oy + q[1] * h, oz + q[2] * d])


# ---- 3D value noise ----------------------------------------------------------------------
def hash3(ix, iy, iz, seed):
    h = (ix * 374761393 + iy * 668265263 + iz * 2147483647 + seed * 1442695041) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF) / 65535.0


def vnoise(p, scale, seed):
    x, y, z = p / scale
    ix, iy, iz = int(np.floor(x)), int(np.floor(y)), int(np.floor(z))
    fx, fy, fz = x - ix, y - iy, z - iz
    fx, fy, fz = (f * f * (3 - 2 * f) for f in (fx, fy, fz))
    acc = 0.0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                wgt = (fx if dx else 1 - fx) * (fy if dy else 1 - fy) * (fz if dz else 1 - fz)
                acc += wgt * hash3(ix + dx, iy + dy, iz + dz, seed)
    return acc


def fbm(p, scale, seed, octaves=3):
    total, amp, norm = 0.0, 1.0, 0.0
    for o in range(octaves):
        total += amp * vnoise(p, scale / (2 ** o), seed + o * 17)
        norm += amp
        amp *= 0.5
    return total / norm


def shade(pal, k):
    """A ramp colour by a 0..1 brightness."""
    i = int(np.clip(k, 0.0, 0.999) * len(pal))
    return pal[i]


# ---- painters: (part, face, point, s, t) -> rgba ----------------------------------------
class Cow:
    def __init__(self, coat, dark=None, spots=0.0, blaze=None, belly=None, muzzle="#d89a8e",
                 horn="#e8dcc0", hoof="#2a2420", shaggy=False, hump=None, seed=1):
        self.coat = ramp(coat, 6, 0.10)
        self.dark = ramp(dark, 6, 0.10) if dark else None
        self.spots = spots
        self.blaze = ramp(blaze, 6, 0.08) if blaze else None
        self.belly = ramp(belly, 6, 0.08) if belly else None
        self.muzzle = ramp(muzzle, 4, 0.10)
        self.horn = ramp(horn, 4, 0.12)
        self.hoof = hexrgb(hoof)
        self.shaggy = shaggy
        self.hump = ramp(hump, 6, 0.10) if hump else None
        self.seed = seed

    def fur(self, pal, p, face):
        n = fbm(p, 3.0, self.seed, 2)
        if self.shaggy:
            # long strands: noise stretched along y
            q = np.array([p[0] * 1.6, p[1] * 0.25, p[2] * 1.6])
            n = 0.35 * n + 0.9 * (vnoise(q, 1.0, self.seed + 5) - 0.5) + 0.5
        light = {"top": 0.62, "bottom": 0.28, "front": 0.5, "back": 0.48,
                 "west": 0.5, "east": 0.5}[face]
        return shade(pal, light + (n - 0.5) * 0.7)

    def __call__(self, part, face, p, s, t):
        name = part["name"]
        if name.startswith("horn") or name.startswith("tip"):
            if name.startswith("tip") or (name.startswith("horn") and face == "top" and not self.shaggy):
                return (*self.horn[0] * 0.55, 1.0)
            return (*shade(self.horn, 0.75 - t * 0.5), 1.0)
        if name.startswith("leg") and p[1] < 2.0:
            return (*self.hoof, 1.0)
        if name == "muzzle":
            c = shade(self.muzzle, 0.6 - 0.3 * t)
            if face == "front" and t > 0.35 and (s < 0.3 or s > 0.7) and t < 0.75:
                c = self.muzzle[0] * 0.45   # nostrils
            return (*c, 1.0)
        pal = self.coat
        if self.dark is not None and self.spots > 0.0:
            if fbm(p, 7.0, self.seed + 101, 3) > 1.0 - self.spots:
                pal = self.dark
        if self.hump is not None and (name in ("hump", "dewlap") or
                                      (name == "body" and p[2] < -2 and p[1] > 18)):
            pal = self.hump
        if self.belly is not None and name == "body" and p[1] < 15.5:
            pal = self.belly
        if name == "tail" and p[1] < 15.0:
            pal = self.dark if self.dark is not None else self.coat
            return (*shade(pal, 0.25), 1.0)
        if name == "head" and face == "front":
            if self.blaze is not None and abs(s - 0.5) < 0.22 and t < 0.75:
                pal = self.blaze
            # eyes: two dark pixels with a light glint above
            if 0.3 < t < 0.48 and (0.06 < s < 0.24 or 0.76 < s < 0.94):
                if t < 0.39 and (0.06 < s < 0.15 or 0.85 < s < 0.94):
                    return (0.95, 0.95, 0.92, 1.0)
                return (0.06, 0.05, 0.06, 1.0)
        if name == "fringe":
            pal = self.coat
            c = self.fur(pal, p, face)
            return (*c * (0.85 + 0.3 * vnoise(np.array([p[0] * 3, 0, 0]), 1.0, 9)), 1.0)
        if name.startswith("ear"):
            if face == "front":
                return (*self.muzzle[1], 1.0)
        return (*self.fur(pal, p, face), 1.0)


class Sheep:
    """A fleece (the `coat` box) over a pale shorn body; face and legs by breed."""
    def __init__(self, wool, face, skin="#e8c8b4", hoof="#2e2622", horn=None, seed=1):
        self.wool = ramp(wool, 6, 0.10)
        self.face = ramp(face, 6, 0.10)
        self.skin = ramp(skin, 6, 0.08)
        self.hoof = hexrgb(hoof)
        self.horn = ramp(horn, 5, 0.12) if horn else None
        self.seed = seed

    def __call__(self, part, face, p, s, t):
        name = part["name"]
        light = {"top": 0.66, "bottom": 0.3, "front": 0.52, "back": 0.5,
                 "west": 0.52, "east": 0.52}[face]
        if name == "coat" or name == "tail":
            # curly fleece: small bumpy clumps
            n = 0.6 * fbm(p * 1.7, 1.6, self.seed, 2) + 0.4 * vnoise(p * 2.3, 1.0, self.seed + 3)
            return (*shade(self.wool, light + (n - 0.5) * 0.9), 1.0)
        if name.startswith("horn") or name.startswith("curl"):
            ridge = 0.12 * np.sin((p[1] + p[2]) * 2.6)
            return (*shade(self.horn, 0.55 + ridge - 0.25 * t), 1.0)
        if name == "head":
            if face == "top" or (face != "front" and t < 0.3):
                n = fbm(p * 1.7, 1.6, self.seed, 2)
                return (*shade(self.wool, light + (n - 0.5) * 0.8), 1.0)   # a wool cap
            if face == "front" and 0.35 < t < 0.55 and (0.08 < s < 0.28 or 0.72 < s < 0.92):
                if t < 0.44 and (0.08 < s < 0.17 or 0.83 < s < 0.92):
                    return (0.95, 0.93, 0.85, 1.0)
                return (0.06, 0.05, 0.05, 1.0)
            if face == "front" and t > 0.78 and 0.35 < s < 0.65:
                return (*self.face[0] * 0.6, 1.0)                           # the nose
            return (*shade(self.face, light + (fbm(p, 3.0, self.seed + 7, 2) - 0.5) * 0.4), 1.0)
        if name.startswith("ear"):
            return (*shade(self.face, light - 0.05), 1.0)
        if name.startswith("leg"):
            if p[1] < 1.6:
                return (*self.hoof, 1.0)
            return (*shade(self.face, light + (fbm(p, 2.0, self.seed + 9, 2) - 0.5) * 0.4), 1.0)
        # the shorn body: short pale stubble
        n = fbm(p, 2.0, self.seed + 11, 2)
        return (*shade(self.skin, light + (n - 0.5) * 0.35), 1.0)


class Pig:
    def __init__(self, coat, snout, bristles=False, stripe=None, tusk="#efe6cf",
                 hoof="#3a2a26", seed=1):
        self.coat = ramp(coat, 6, 0.10)
        self.snout = ramp(snout, 5, 0.10)
        self.bristles = bristles
        self.stripe = ramp(stripe, 6, 0.10) if stripe else None
        self.tusk = ramp(tusk, 4, 0.10)
        self.hoof = hexrgb(hoof)
        self.seed = seed

    def __call__(self, part, face, p, s, t):
        name = part["name"]
        light = {"top": 0.64, "bottom": 0.3, "front": 0.52, "back": 0.5,
                 "west": 0.52, "east": 0.52}[face]
        if name.startswith("tusk"):
            return (*shade(self.tusk, 0.8 - 0.4 * t), 1.0)
        if name.startswith("leg") and p[1] < 1.6:
            return (*self.hoof, 1.0)
        if name == "snout":
            if face == "front" and 0.3 < t < 0.75 and (0.15 < s < 0.38 or 0.62 < s < 0.85):
                return (*self.snout[0] * 0.5, 1.0)                          # nostrils
            return (*shade(self.snout, 0.6 - 0.2 * t), 1.0)
        if name == "head" and face == "front" and 0.25 < t < 0.42 and \
                (0.1 < s < 0.26 or 0.74 < s < 0.9):
            if t < 0.33 and (0.1 < s < 0.17 or 0.83 < s < 0.9):
                return (0.95, 0.93, 0.85, 1.0)
            return (0.05, 0.04, 0.04, 1.0)
        pal = self.coat
        if self.stripe is not None and (name == "mane" or (name == "body" and p[1] > 13 and abs(p[0]) < 2)):
            pal = self.stripe
        n = fbm(p, 3.0, self.seed, 2)
        if self.bristles:
            # coarse hair: streaks along the body
            q = np.array([p[0] * 2.2, p[1] * 2.2, p[2] * 0.35])
            n = 0.4 * n + 0.8 * (vnoise(q, 1.0, self.seed + 5) - 0.5) + 0.5
        if name.startswith("ear") and face == "front":
            return (*shade(self.snout, 0.45), 1.0)
        return (*shade(pal, light + (n - 0.5) * 0.6), 1.0)


class Chicken:
    def __init__(self, feather, wing=None, tail=None, speckle=None, neck=None,
                 comb="#d8282a", beak="#f0b02a", leg="#e8a838", seed=1):
        self.feather = ramp(feather, 6, 0.10)
        self.wing = ramp(wing, 6, 0.10) if wing else self.feather
        self.tail = ramp(tail, 6, 0.12) if tail else self.feather
        self.speckle = ramp(speckle, 5, 0.10) if speckle else None
        self.neck = ramp(neck, 6, 0.10) if neck else None
        self.comb = ramp(comb, 4, 0.10)
        self.beak = ramp(beak, 4, 0.10)
        self.leg = ramp(leg, 4, 0.10)
        self.seed = seed

    def __call__(self, part, face, p, s, t):
        name = part["name"]
        light = {"top": 0.66, "bottom": 0.3, "front": 0.52, "back": 0.5,
                 "west": 0.52, "east": 0.52}[face]
        if name in ("comb", "wattle"):
            return (*shade(self.comb, light), 1.0)
        if name == "beak":
            return (*shade(self.beak, light), 1.0)
        if name.startswith("leg"):
            return (*shade(self.leg, 0.55), 1.0)
        if name == "head" and face in ("west", "east") and 0.3 < t < 0.45 and 0.15 < s < 0.5:
            return (0.05, 0.04, 0.04, 1.0)                                  # eyes
        pal = self.feather
        if name.startswith("wing"):
            pal = self.wing
        elif name == "tail":
            pal = self.tail
        elif name == "head" and self.neck is not None:
            pal = self.neck
        n = fbm(p, 2.0, self.seed, 2)
        if self.speckle is not None and name in ("body", "wing_l", "wing_r") and \
                vnoise(p * 1.9, 1.0, self.seed + 21) > 0.72:
            return (*shade(self.speckle, light), 1.0)
        if name.startswith("wing") or name == "tail":
            # feather rows
            n = 0.5 * n + 0.35 * (0.5 + 0.5 * np.sin(p[1] * 3.0 + p[2] * 1.2))
        return (*shade(pal, light + (n - 0.5) * 0.6), 1.0)


class Deer:
    """Deer, reindeer and their young: a coat with a pale belly, rump and
    throat, a dark muzzle, antlers; `spots` paints a fawn's white dapples."""
    def __init__(self, coat, belly, muzzle="#2a2220", antler="#d8c8a4", hoof="#2a221c",
                 tail=None, spots=False, ruff=None, shaggy=False, seed=1):
        self.coat = ramp(coat, 6, 0.10)
        self.belly = ramp(belly, 6, 0.08)
        self.muzzle = ramp(muzzle, 4, 0.10)
        self.antler = ramp(antler, 5, 0.12)
        self.hoof = hexrgb(hoof)
        self.tail = ramp(tail, 6, 0.08) if tail else self.belly
        self.spots = spots
        self.ruff = ramp(ruff, 6, 0.08) if ruff else None
        self.shaggy = shaggy
        self.seed = seed

    def __call__(self, part, face, p, s, t):
        name = part["name"]
        light = {"top": 0.64, "bottom": 0.3, "front": 0.52, "back": 0.5,
                 "west": 0.52, "east": 0.52}[face]
        if name[:4] in ("beam", "tine", "brow") or name.startswith("top_"):
            ridge = 0.1 * np.sin(p[1] * 3.1 + p[0])
            return (*shade(self.antler, 0.62 + ridge - 0.2 * t), 1.0)
        if name.startswith("leg") and p[1] < 1.6:
            return (*self.hoof, 1.0)
        if name == "snout":
            if face == "front" and t > 0.3:
                return (*shade(self.muzzle, 0.4 + 0.2 * (1 - t)), 1.0)
            return (*shade(self.coat, light - 0.05), 1.0)
        if name == "head" and face == "front" and 0.3 < t < 0.55 and (s < 0.2 or s > 0.8):
            return (0.05, 0.04, 0.04, 1.0)                                  # eyes
        if name == "head" and face in ("west", "east") and 0.25 < t < 0.5 and \
                ((face == "west" and s < 0.3) or (face == "east" and s > 0.7)):
            return (0.05, 0.04, 0.04, 1.0)                                  # eyes, from the side
        if name.startswith("ear") and face == "front":
            return (*shade(self.belly, 0.45), 1.0)
        pal = self.coat
        if name == "tail":
            pal = self.tail
            if face == "back" or face == "bottom":
                pal = self.belly
        elif name == "ruff":
            pal = self.ruff if self.ruff is not None else self.belly
        elif name == "body" and (p[1] < 14.5 or (face == "back" and abs(p[0]) < 2.6 and p[1] < 20)):
            pal = self.belly                                                # belly and rump patch
        elif name == "neck" and face == "front" and t > 0.45:
            pal = self.belly                                                # the throat
        n = fbm(p, 3.0, self.seed, 2)
        if self.shaggy:
            q = np.array([p[0] * 1.8, p[1] * 0.3, p[2] * 1.8])
            n = 0.4 * n + 0.8 * (vnoise(q, 1.0, self.seed + 5) - 0.5) + 0.5
        if self.spots and name == "body" and pal is self.coat and p[1] > 15.5 and \
                vnoise(p * 1.3, 1.0, self.seed + 31) > 0.7:
            return (*shade(self.belly, light + 0.12), 1.0)                  # a fawn's dapples
        if name == "body" and face == "top" and pal is self.coat and abs(p[0]) < 0.6:
            n -= 0.25                                                       # a dark line down the back
        return (*shade(pal, light + (n - 0.5) * 0.55), 1.0)


class Rabbit:
    def __init__(self, coat, belly, ear="#e8b0a8", tail="#f4f2ec", seed=1):
        self.coat = ramp(coat, 6, 0.10)
        self.belly = ramp(belly, 6, 0.08)
        self.ear = ramp(ear, 4, 0.08)
        self.tail = ramp(tail, 4, 0.06)
        self.seed = seed

    def __call__(self, part, face, p, s, t):
        name = part["name"]
        light = {"top": 0.66, "bottom": 0.32, "front": 0.52, "back": 0.5,
                 "west": 0.52, "east": 0.52}[face]
        if name == "tail":
            return (*shade(self.tail, light + 0.1), 1.0)
        if name.startswith("ear") and face == "front":
            return (*shade(self.ear, 0.55), 1.0)
        if name == "head" and face == "front":
            if 0.25 < t < 0.5 and (s < 0.25 or s > 0.75):
                return (0.05, 0.04, 0.04, 1.0)                              # eyes
            if t > 0.65 and 0.35 < s < 0.65:
                return (*shade(self.ear, 0.4), 1.0)                         # the nose
        if name == "head" and face in ("west", "east") and 0.25 < t < 0.5 and \
                ((face == "west" and s < 0.35) or (face == "east" and s > 0.65)):
            return (0.05, 0.04, 0.04, 1.0)
        pal = self.coat
        if name == "body" and (face == "bottom" or p[1] < 4.2):
            pal = self.belly
        n = fbm(p * 1.6, 2.0, self.seed, 2)
        return (*shade(pal, light + (n - 0.5) * 0.55), 1.0)


class Goat:
    """The white mountain goat: a shaggy coat, black horns, hooves and nose."""
    def __init__(self, coat, horn="#2a2624", hoof="#262220", nose="#3a3230", seed=1):
        self.coat = ramp(coat, 6, 0.09)
        self.horn = ramp(horn, 4, 0.12)
        self.hoof = hexrgb(hoof)
        self.nose = ramp(nose, 4, 0.10)
        self.seed = seed

    def __call__(self, part, face, p, s, t):
        name = part["name"]
        light = {"top": 0.68, "bottom": 0.34, "front": 0.54, "back": 0.52,
                 "west": 0.54, "east": 0.54}[face]
        if name.startswith("horn") or name.startswith("tip"):
            ridge = 0.12 * np.sin(p[1] * 3.4)
            return (*shade(self.horn, 0.55 + ridge), 1.0)
        if name.startswith("leg") and p[1] < 1.6:
            return (*self.hoof, 1.0)
        if name == "muzzle" and face == "front" and t > 0.4:
            return (*shade(self.nose, 0.5), 1.0)
        if name == "head" and face in ("west", "east") and 0.3 < t < 0.5 and \
                ((face == "west" and s < 0.35) or (face == "east" and s > 0.65)):
            return (0.12, 0.09, 0.04, 1.0)                                  # amber-dark eyes
        if name == "head" and face == "front" and 0.3 < t < 0.5 and (s < 0.2 or s > 0.8):
            return (0.12, 0.09, 0.04, 1.0)
        n = fbm(p, 2.5, self.seed, 2)
        if name in ("body", "beard") or (name.startswith("leg") and p[1] > 6):
            # long shaggy hair: streaks hanging down
            q = np.array([p[0] * 1.9, p[1] * 0.28, p[2] * 1.9])
            n = 0.35 * n + 0.9 * (vnoise(q, 1.0, self.seed + 5) - 0.5) + 0.5
        return (*shade(self.coat, light + (n - 0.5) * 0.5), 1.0)


class Chick(Chicken):
    """A chick: soft yellow fluff all over, small dark eyes."""
    def __init__(self, fluff, wing=None, seed=1):
        super().__init__(fluff, wing=wing, comb="#f0c860", beak="#e89a2a", leg="#e8a838",
                         seed=seed)

    def __call__(self, part, face, p, s, t):
        if part["name"] in ("comb", "wattle"):
            return super().__call__({**part, "name": "body"}, face, p, s, t)
        return super().__call__(part, face, p, s, t)


SKINS = {
    # black-and-white spotted, plains and meadows
    "cow_spotted": ("cow", Cow("#f2efe6", dark="#26232a", spots=0.42, muzzle="#e3a79c",
                               seed=11)),
    # chestnut with a white blaze and a pale belly, forests and taiga
    "cow_brown": ("cow", Cow("#8c4a24", blaze="#f0e8da", belly="#c98f5c", muzzle="#c88a76",
                             seed=23)),
    # the shaggy red highland cow, cold places and the steppe
    "cow_highland": ("cow_highland", Cow("#c0602a", muzzle="#9a5a46", horn="#efe2c2",
                                         hoof="#33241a", shaggy=True, seed=37)),
    # the pale zebu with a darker hump, savanna
    "cow_zebu": ("cow_zebu", Cow("#ddd5c4", hump="#8e877d", muzzle="#9f8d86", horn="#3a3430",
                                 seed=41)),
    # sheep in natural wool shades (the face and legs by breed)
    "sheep_white": ("sheep", Sheep("#f4f1e8", face="#e8d8c8", seed=51)),
    "sheep_cream": ("sheep", Sheep("#ecdcb8", face="#c8a888", seed=53)),
    "sheep_grey": ("sheep", Sheep("#b4b2ae", face="#3a3634", seed=55)),
    "sheep_brown": ("sheep", Sheep("#7a5236", face="#4a3022", seed=57)),
    "sheep_black": ("sheep", Sheep("#2e2a2c", face="#1e1a1c", skin="#8a7468", seed=59)),
    "sheep_russet": ("sheep", Sheep("#b0582c", face="#5a3020", seed=61)),
    # the mountain ram: a cream fleece, a tan face, ridged curling horns
    "sheep_ram": ("sheep_ram", Sheep("#efe8d6", face="#b88a5c", horn="#cdbb92", seed=63)),
    # pigs and boars
    "pig_pink": ("pig", Pig("#f0a8a4", snout="#e88a8a", seed=71)),
    "boar_wild": ("boar", Pig("#5a3e2a", snout="#3a2a24", bristles=True, stripe="#2a1e16",
                              seed=73)),
    # chickens
    "chicken_white": ("chicken", Chicken("#f6f4ee", wing="#e8e4da", seed=81)),
    "chicken_speckled": ("chicken", Chicken("#8a5a34", speckle="#efe2c8", tail="#3a2a20",
                                            seed=83)),
    "chicken_jungle": ("chicken", Chicken("#9a3e1e", wing="#5a2a16", tail="#1e5a3a",
                                          neck="#e8902a", seed=85)),
    # deer: the red deer of the forests, the white-tailed deer of the birch
    # groves, the reindeer of the cold forests and tundra; fawns spotted
    "deer_red": ("deer", Deer("#9a5430", belly="#e0c8a4", tail="#9a5430", seed=91)),
    "deer_whitetail": ("deer", Deer("#a8784a", belly="#efe6d6", tail="#efe8dc", seed=93)),
    "deer_reindeer": ("reindeer", Deer("#7a6654", belly="#e4dccc", ruff="#ece6da",
                                       antler="#c8b48c", shaggy=True, seed=95)),
    "fawn_red": ("deer", Deer("#b0643a", belly="#f0e2c8", tail="#b0643a", spots=True, seed=97)),
    "fawn_whitetail": ("deer", Deer("#b88a5a", belly="#f4ecdc", tail="#f4ece0", spots=True,
                                    seed=99)),
    "fawn_reindeer": ("reindeer", Deer("#5e4e40", belly="#9a8a78", ruff="#a89a88", seed=101)),
    # rabbits: brown, sandy, white
    "rabbit_brown": ("rabbit", Rabbit("#8a6a4a", belly="#d8c4a8", seed=111)),
    "rabbit_sandy": ("rabbit", Rabbit("#d8b47c", belly="#f0e2c4", seed=113)),
    "rabbit_white": ("rabbit", Rabbit("#f2f0ea", belly="#e6e2da", ear="#f0b8b0", seed=115)),
    # the mountain goat
    "goat_white": ("goat", Goat("#f0ece0", seed=121)),
    # chicks: yellow fluff (the jungle fowl's chick striped brown)
    "chick": ("chicken", Chick("#f6dc5a", wing="#f0cc48", seed=131)),
    "chick_jungle": ("chicken", Chick("#c8a050", wing="#8a6030", seed=133)),
}


def check_layout(name, model):
    """Every box's skin area inside the skin, and no two boxes overlapping
    (boxes with the same u, v share their pixels on purpose)."""
    W, H = model["size"]
    owner = {}
    for part in model["parts"]:
        key = tuple(part["uv"]) + tuple(part["size"])
        for face in FACES:
            u, v, rw, rh = face_rect(part, face)
            if u < 0 or v < 0 or u + rw > W or v + rh > H:
                raise SystemExit(f"{name}: {part['name']} {face} leaves the skin")
            for j in range(rh):
                for i in range(rw):
                    o = owner.setdefault((u + i, v + j), key)
                    if o != key:
                        raise SystemExit(f"{name}: {part['name']} {face} overlaps another box at "
                                         f"{u + i}, {v + j}")


def paint(model, painter):
    W, H = model["size"]
    img = np.zeros((H, W, 4))
    for part in model["parts"]:
        for face in FACES:
            u, v, rw, rh = face_rect(part, face)
            for j in range(rh):
                for i in range(rw):
                    s, t = (i + 0.5) / rw, (j + 0.5) / rh
                    p = face_point(part, face, s, t)
                    img[v + j, u + i] = painter(part, face, p, s, t)
    return img


def save(name, img):
    os.makedirs(OUT, exist_ok=True)
    a = (np.clip(img, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    Image.fromarray(a, "RGBA").save(os.path.join(OUT, name + ".png"))


def rope():
    """The lead's rope (drawn as thin boxes, src/render/mob_render.asm): a
    twisted brown cord over the whole 64 x 64 layer, so every face of any
    box finds rope wherever it samples."""
    pal = ramp("#8a6038", 6, 0.12)
    img = np.zeros((64, 64, 4))
    for y in range(64):
        for x in range(64):
            k = 0.45 + 0.35 * np.sin((x + y) * 1.6) + 0.1 * (hash3(x, y, 0, 7) - 0.5)
            img[y, x] = (*shade(pal, k), 1.0)
    return img


def main(args):
    if "--list" in args:
        print("\n".join(sorted(SKINS) + ["lead_rope"]))
        return
    models = load_models()
    for mname, model in models.items():
        check_layout(mname, model)
    names = [a for a in args if not a.startswith("-")] or sorted(SKINS) + ["lead_rope"]
    for name in names:
        if name == "lead_rope":
            save(name, rope())
            print("skin", name)
            continue
        model_name, painter = SKINS[name]
        save(name, paint(models[model_name], painter))
        print("skin", name)


if __name__ == "__main__":
    main(sys.argv[1:])
