#!/usr/bin/env python3
"""Build the debug-overlay font atlas from an X11 misc-fixed PCF font.

Usage: tools/make_font.py [src.pcf.gz] [out.vxf]
Default source: /usr/share/fonts/X11/misc/8x13.pcf.gz (misc-fixed, public domain;
Debian/Ubuntu package xfonts-base). Output format (.vxf, little endian):
    0  char[4]  magic "VXF1"
    4  u16      cell width  (pixels)
    6  u16      cell height (pixels)
    8  u16      atlas columns (glyphs per row)
   10  u16      atlas rows
   12  u8       first character code
   13  u8       glyph count
   14  u16      reserved (0)
   16  u8[w*h]  atlas pixels, 0 or 255, row-major, top row first;
                w = columns * cell width, h = rows * cell height
"""
import gzip, io, struct, sys
from PIL import Image, PcfFontFile

src = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/fonts/X11/misc/8x13.pcf.gz"
out = sys.argv[2] if len(sys.argv) > 2 else "assets/fonts/debug_8x13.vxf"
FIRST, COUNT, COLS = 32, 95, 16

data = open(src, "rb").read()
if src.endswith(".gz"):
    data = gzip.decompress(data)
pcf = PcfFontFile.PcfFontFile(io.BytesIO(data))

# metrics: glyph[ch] = (offset(dx,dy), bbox(x0,y0,x1,y1), src box, image)
glyphs = {ch: pcf.glyph[ch] for ch in range(FIRST, FIRST + COUNT) if pcf.glyph[ch]}
ascent = max(-g[1][1] for g in glyphs.values())
descent = max(g[1][3] for g in glyphs.values())
cw = max(g[0][0] for g in glyphs.values())
ch_h = ascent + descent
rows = (COUNT + COLS - 1) // COLS
atlas = Image.new("L", (COLS * cw, rows * ch_h), 0)
for i in range(COUNT):
    g = glyphs.get(FIRST + i)
    if not g:
        continue
    (dx, dy), (x0, y0, x1, y1), sbox, im = g
    cx, cy = (i % COLS) * cw, (i // COLS) * ch_h
    glyph_img = im.crop(sbox).convert("L").point(lambda v: 255 if v else 0)
    atlas.paste(glyph_img, (cx + x0, cy + ascent + y0))

with open(out, "wb") as f:
    f.write(b"VXF1" + struct.pack("<HHHHBBH", cw, ch_h, COLS, rows, FIRST, COUNT, 0))
    f.write(atlas.tobytes())
print(f"{out}: cell {cw}x{ch_h}, atlas {atlas.size[0]}x{atlas.size[1]}")
