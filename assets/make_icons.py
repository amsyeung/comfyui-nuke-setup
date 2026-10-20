"""Draws the ComfyNuke icon (a small node graph: one node feeding two) and writes
comfynuke.ico (Windows shortcuts) and comfynuke.png (macOS). Needs Pillow.

    python assets/make_icons.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024                     # drawn large, then scaled down for smooth edges
BG = (33, 25, 39, 255)          # same dark tone as the ComfyUI icon, so the two read as a set
ACCENT = (242, 255, 89, 255)    # ComfyUI yellow
LIGHT = (236, 234, 242, 255)
WIRE = (150, 140, 170, 255)
OUT = Path(__file__).resolve().parent


def node(d, x, y, w, h, fill):
    d.rounded_rectangle((x, y, x + w, y + h), radius=56, fill=fill)
    d.rounded_rectangle((x, y, x + w, y + 70), radius=56, fill=tuple(int(c * 0.82) for c in fill[:3]) + (255,))
    d.rectangle((x, y + 40, x + w, y + 70), fill=tuple(int(c * 0.82) for c in fill[:3]) + (255,))


def wire(d, p0, p1, width=44):
    # cubic Bezier from an output port to an input port, like a node-graph connection
    (x0, y0), (x3, y3) = p0, p1
    x1, x2 = x0 + (x3 - x0) * 0.55, x3 - (x3 - x0) * 0.55
    r = width / 2
    for i in range(401):   # stamp discs along the curve: smoother than a thick polyline
        t = i / 400
        x = (1 - t) ** 3 * x0 + 3 * (1 - t) ** 2 * t * x1 + 3 * (1 - t) * t ** 2 * x2 + t ** 3 * x3
        y = (1 - t) ** 3 * y0 + 3 * (1 - t) ** 2 * t * y0 + 3 * (1 - t) * t ** 2 * y3 + t ** 3 * y3
        d.ellipse((x - r, y - r, x + r, y + r), fill=WIRE)


def port(d, x, y, r=38, fill=LIGHT):
    d.ellipse((x - r, y - r, x + r, y + r), fill=fill, outline=BG, width=14)


img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=230, fill=BG)

# source node (ComfyUI) on the left, two target nodes (Nuke) on the right
wire(d, (452, 512), (616, 300))
wire(d, (452, 512), (616, 724))
node(d, 130, 352, 322, 320, ACCENT)
node(d, 616, 170, 278, 260, LIGHT)
node(d, 616, 594, 278, 260, LIGHT)
port(d, 452, 512, fill=ACCENT)
port(d, 616, 300)
port(d, 616, 724)

img.save(OUT / "comfynuke.png")
img.save(OUT / "comfynuke.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print("wrote", OUT / "comfynuke.ico", "and", OUT / "comfynuke.png")
