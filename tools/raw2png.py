"""Convert raw Playdate 1-bit framebuffer dumps to PNG.

The terrain host test (tools/hosttest.c) writes frames exactly as the Playdate stores them:
52 bytes per row (400 pixels, most significant bit first), 240 rows, 1 = white. This script
expands each dump into an image and writes it next to the input with a .png extension, scaled
up 2x with nearest-neighbour so the dither pattern stays crisp.

Usage: python tools/raw2png.py build/host_center.raw [more.raw ...]
Requires Pillow.
"""
import sys

from PIL import Image

ROW = 52          # bytes per row in the Playdate frame buffer
W, H = 400, 240   # screen size in pixels


def convert(path, scale=2):
    """Writes <path minus extension>.png and prints its name."""
    data = open(path, "rb").read()
    img = Image.new("1", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            # pixel x lives in byte x//8; bit 7 is the leftmost pixel of that byte
            px[x, y] = (data[y * ROW + (x >> 3)] >> (7 - (x & 7))) & 1
    img = img.resize((W * scale, H * scale), Image.NEAREST)
    out = path.rsplit(".", 1)[0] + ".png"
    img.save(out)
    print(out)


for p in sys.argv[1:]:
    convert(p)
