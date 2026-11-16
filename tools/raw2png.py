"""Convert raw Playdate 1-bit framebuffer dumps (52 bytes/row x 240 rows) to PNG."""
import sys
from PIL import Image

ROW = 52
W, H = 400, 240


def convert(path, scale=2):
    data = open(path, "rb").read()
    img = Image.new("1", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            px[x, y] = (data[y * ROW + (x >> 3)] >> (7 - (x & 7))) & 1
    img = img.resize((W * scale, H * scale), Image.NEAREST)
    out = path.rsplit(".", 1)[0] + ".png"
    img.save(out)
    print(out)


for p in sys.argv[1:]:
    convert(p)
