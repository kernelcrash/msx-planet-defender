#!/usr/bin/env python3
"""Render a 16 KB TMS9918 VRAM dump (from tools/fv_emu.py) to PNGs for eyeballing.

Uses the Planet Defender table layout (dynamic trace): name $0400, colour $1400,
sprite-attr $1C00, sprite-pattern $2000, pattern-gen $2800, 16x16 sprites.

    view_vram.py build/re/vram_attract.bin build/re/
"""
import sys
from PIL import Image

TMS_PALETTE = [
    (0, 0, 0, 0), (0, 0, 0), (33, 200, 66), (94, 220, 120),
    (84, 85, 237), (125, 118, 252), (212, 82, 77), (66, 235, 245),
    (252, 85, 84), (255, 121, 120), (212, 193, 84), (230, 206, 128),
    (33, 176, 59), (201, 91, 186), (204, 204, 204), (255, 255, 255),
]


def tiles_png(data, base, count, path, cols=16, colours=None):
    rows = (count + cols - 1) // cols
    img = Image.new("RGB", (cols * 8, rows * 8), (30, 30, 30))
    px = img.load()
    for t in range(count):
        ox, oy = (t % cols) * 8, (t // cols) * 8
        fg, bg = (15, 4)
        if colours:
            c = colours[t // 8] if t // 8 < len(colours) else 0xF0
            fg, bg = c >> 4, c & 0x0F
        for y in range(8):
            b = data[base + t * 8 + y]
            for x in range(8):
                idx = fg if (b >> (7 - x)) & 1 else bg
                col = TMS_PALETTE[idx if idx else 1][:3]
                px[ox + x, oy + y] = col
    img.resize((img.width * 4, img.height * 4), Image.NEAREST).save(path)
    print("wrote", path)


def sprites_png(data, base, count, path, cols=8):
    """16x16 sprites = 4 consecutive 8x8 quarters (TL, BL, TR, BR)."""
    rows = (count + cols - 1) // cols
    img = Image.new("RGB", (cols * 16, rows * 16), (30, 30, 30))
    px = img.load()
    for s in range(count):
        ox, oy = (s % cols) * 16, (s // cols) * 16
        for q, (qx, qy) in enumerate([(0, 0), (0, 8), (8, 0), (8, 8)]):
            for y in range(8):
                b = data[base + s * 32 + q * 8 + y]
                for x in range(8):
                    if (b >> (7 - x)) & 1:
                        px[ox + qx + x, oy + qy + y] = (255, 255, 255)
    img.resize((img.width * 4, img.height * 4), Image.NEAREST).save(path)
    print("wrote", path)


def main():
    src, outdir = sys.argv[1], sys.argv[2].rstrip("/")
    d = open(src, "rb").read()
    colours = list(d[0x1400:0x1420])
    tiles_png(d, 0x2800, 256, f"{outdir}/patterns.png", colours=colours)
    sprites_png(d, 0x2000, 16, f"{outdir}/sprites.png")
    # name table as a coarse image (tile index brightness)
    nt = Image.new("L", (32, 24))
    nt.putdata([min(255, v) for v in d[0x0400:0x0400 + 32 * 24]])
    nt.resize((32 * 8, 24 * 8), Image.NEAREST).save(f"{outdir}/nametable.png")
    print("wrote", f"{outdir}/nametable.png")


if __name__ == "__main__":
    main()
