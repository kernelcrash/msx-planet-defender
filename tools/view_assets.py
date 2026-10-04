#!/usr/bin/env python3
"""Render the Phase 2 extracted assets (assets/*.bin) to PNGs for eyeball
verification against funnymu screenshots.

    python3 tools/view_assets.py            # -> assets/preview/*.png
"""
import os
from PIL import Image

ASSETS = "assets"
OUTDIR = f"{ASSETS}/preview"

TMS = [
    (0, 0, 0), (0, 0, 0), (33, 200, 66), (94, 220, 120),
    (84, 85, 237), (125, 118, 252), (212, 82, 77), (66, 235, 245),
    (252, 85, 84), (255, 121, 120), (212, 193, 84), (230, 206, 128),
    (33, 176, 59), (201, 91, 186), (204, 204, 204), (255, 255, 255),
]


def tiles(data, path, cols=16, colours=None, scale=5):
    n = len(data) // 8
    rows = (n + cols - 1) // cols
    img = Image.new("RGB", (cols * 8, rows * 8), (28, 28, 34))
    px = img.load()
    for t in range(n):
        ox, oy = (t % cols) * 8, (t // cols) * 8
        fg, bg = 15, 4
        if colours and t // 8 < len(colours):
            c = colours[t // 8]
            fg, bg = c >> 4, c & 0x0F
        for y in range(8):
            b = data[t * 8 + y]
            for x in range(8):
                on = (b >> (7 - x)) & 1
                idx = fg if on else bg
                px[ox + x, oy + y] = TMS[idx] if idx else (28, 28, 34)
    img.resize((img.width * scale, img.height * scale), Image.NEAREST).save(path)
    print("wrote", path)


def sprites(data, path, cols=8, scale=4):
    n = len(data) // 32
    rows = (n + cols - 1) // cols
    img = Image.new("RGB", (cols * 16, rows * 16), (28, 28, 34))
    px = img.load()
    for s in range(n):
        ox, oy = (s % cols) * 16, (s // cols) * 16
        for q, (qx, qy) in enumerate([(0, 0), (0, 8), (8, 0), (8, 8)]):
            for y in range(8):
                b = data[s * 32 + q * 8 + y]
                for x in range(8):
                    if (b >> (7 - x)) & 1:
                        px[ox + qx + x, oy + qy + y] = (255, 255, 255)
    img.resize((img.width * scale, img.height * scale), Image.NEAREST).save(path)
    print("wrote", path)


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    col = open(f"{ASSETS}/colour_table.bin", "rb").read()
    tiles(open(f"{ASSETS}/patterns.bin", "rb").read(),
          f"{OUTDIR}/patterns.png", colours=col)
    tiles(open(f"{ASSETS}/patterns.bin", "rb").read(),
          f"{OUTDIR}/patterns_mono.png")
    sprites(open(f"{ASSETS}/sprite_patterns.bin", "rb").read(),
            f"{OUTDIR}/sprite_patterns.png")

    # 8 shift banks stacked, terrain tiles only (tile 1..88)
    strip = Image.new("RGB", (88 * 8, 8 * 9), (28, 28, 34))
    for i in range(8):
        b = open(f"{ASSETS}/patterns_shift{i}.bin", "rb").read()
        for t in range(1, 89):
            for y in range(8):
                byte = b[t * 8 + y]
                for x in range(8):
                    if (byte >> (7 - x)) & 1:
                        strip.putpixel(((t - 1) * 8 + x, i * 8 + y), TMS[7])
    strip.resize((strip.width * 4, strip.height * 4), Image.NEAREST).save(
        f"{OUTDIR}/shift_banks.png")
    print("wrote", f"{OUTDIR}/shift_banks.png")

    # static name-table chrome as a coarse map
    nt = open(f"{ASSETS}/nametable_chrome.bin", "rb").read()
    im = Image.new("L", (32, 24))
    im.putdata([0 if v == 0 else min(255, 40 + v) for v in nt])
    im.resize((32 * 10, 24 * 10), Image.NEAREST).save(f"{OUTDIR}/nametable_chrome.png")
    print("wrote", f"{OUTDIR}/nametable_chrome.png")


if __name__ == "__main__":
    main()
