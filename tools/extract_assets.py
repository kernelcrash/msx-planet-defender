#!/usr/bin/env python3
"""Phase 2 — asset extraction (Planet Defender -> MSX).

Planet Defender assembles its VRAM at run time (small cart tile-unpacker + a
tile-by-tile terrain draw), so instead of decoding the packer we carve
*ground-truth VRAM* captured by tools/fv_dump_vram.py at three checkpoints:

    build/re/vram_title.bin       first main-loop frame (title)
    build/re/vram_gamestart.bin   fresh session, just after $BD60 InitPlayer
    build/re/vram_attract.bin     attract demo (~700 frames)

Diffing them shows the graphics data is fully static; only the name table,
4 colour-table entries (terrain flash) and the OAM change per frame.

Horizontal smooth scroll is done with **8 pre-shifted copies** of the pattern
generator, 2 KB apart, selected each frame by R4 = 7 - (($44>>5) & 7):

    $3800 = shift 0 px   $3000 = 1 px   $2800 = 2   $2000 = 3
    $1800 = 4            $1000 = 5      $0800 = 6   $0000 = 7

169 of 256 tiles differ between banks, but only $01-$58 are name-table-
referenced scrolling terrain; the rest (font, digits, ship, HUD, plus the
$80-$DF overlap garbage) are identical in every bank or never drawn.  $3800
(shift 0) is the canonical full generator -> patterns.bin; the other sub-pixel
banks are stored as 704-byte terrain-tile slices (terrain_shift{1,2,4,5,6,7}.bin
— shift 3 is omitted, it lands wholly inside the sprite generator and the
runtime remaps it to shift 2).

Outputs assets/*.bin + assets/manifest.txt.  `--report` = diff only, no carve.
"""
import os
import sys

RE = "build/re"
OUT = "assets"
DUMPS = ["vram_title.bin", "vram_gamestart.bin", "vram_attract.bin"]
SHIFT_BANKS = [0x3800, 0x3000, 0x2800, 0x2000, 0x1800, 0x1000, 0x0800, 0x0000]

# Only tiles $01..$58 are name-table-referenced scrolling terrain (rows 16-23);
# the $80-$DF "varying" slots are overlap garbage and never drawn.  The shift is
# multi-tile-aware (bits scroll in from the neighbour), so these slices are
# carved from the real VRAM rather than generated.  $59-$7F etc. are byte-
# identical across every bank -> fanned out from bank 0 at init, not stored here.
TERRAIN_LO, TERRAIN_HI = 0x01, 0x58            # inclusive; 88 tiles = 704 B/bank
# Banks to emit: skip 0 (== patterns.bin) and 3 ($2000, wholly inside the sprite
# generator — the runtime R4 calc remaps shift 3 -> shift 2, a 1px stutter on
# one of eight sub-pixel phases).
TERRAIN_SHIFTS = [1, 2, 4, 5, 6, 7]


def load():
    out = []
    for n in DUMPS:
        p = f"{RE}/{n}"
        if not os.path.exists(p):
            sys.exit(f"missing {p} — run: python3 tools/fv_dump_vram.py")
        out.append(open(p, "rb").read())
    return out


def report(ds):
    t, g, a = ds
    print("== per-frame vs static ==")
    for name, base, size in [("name_table", 0x0400, 0x300),
                             ("colour_table", 0x1400, 0x20),
                             ("sprite_attr(OAM)", 0x1C00, 0x80),
                             ("sprite_gen", 0x2000, 0x800),
                             ("pattern $3800", 0x3800, 0x800)]:
        nd = sum(1 for i in range(size)
                 if not (t[base + i] == g[base + i] == a[base + i]))
        print(f"  {name:18} ${base:04X}+{size:<4X}  {'STATIC' if nd == 0 else f'{nd} bytes differ'}")

    print("\n== 8 shift banks (from vram_attract) ==")
    tiles_vary = [tn for tn in range(256)
                  if len({a[b + tn * 8:b + tn * 8 + 8] for b in SHIFT_BANKS}) > 1]
    print(f"  {len(tiles_vary)}/256 tile slots differ between banks (terrain);"
          f" {256 - len(tiles_vary)} identical (font/ship/HUD)")
    for i, b in enumerate(SHIFT_BANKS):
        overlap = {0x0000: "name $0400", 0x1000: "colour $1400",
                   0x1800: "OAM $1C00", 0x2000: "sprite gen $2000"}.get(b, "-")
        print(f"  shift {i}px  ${b:04X}  overlaps: {overlap}")


def carve(ds):
    t, g, a = ds
    os.makedirs(OUT, exist_ok=True)
    man = ["# Planet Defender — Phase 2 extracted assets",
           "# Ground-truth VRAM (tools/fv_dump_vram.py), verified static across",
           "# title / gamestart / attract captures. TMS9918 format, ready to INCBIN.",
           ""]

    def w(fn, data, note):
        open(f"{OUT}/{fn}", "wb").write(data)
        man.append(f"{fn:28} {len(data):5} B   {note}")
        print(f"  {OUT}/{fn:28} {len(data):5} B   {note}")

    # canonical pattern generator (shift 0) — clean, no table overlap
    w("patterns.bin", a[0x3800:0x4000],
      "256-tile pattern generator, scroll offset 0 (VRAM $3800)")

    # pre-shifted scrolling-terrain slices (tiles $01..$58 only) for the sub-
    # pixel banks.  VdpInit copies patterns.bin into each bank then overlays
    # these 704-byte slices onto the terrain-tile window.
    lo = (TERRAIN_LO) * 8
    hi = (TERRAIN_HI + 1) * 8
    for i in TERRAIN_SHIFTS:
        b = SHIFT_BANKS[i]
        w(f"terrain_shift{i}.bin", a[b + lo:b + hi],
          f"terrain tiles ${TERRAIN_LO:02X}-${TERRAIN_HI:02X} shifted {i}px "
          f"(VRAM ${b + lo:04X}-${b + hi:04X})")

    # sprite pattern generator ($2000, 64x 16x16) — static
    assert t[0x2000:0x2800] == g[0x2000:0x2800] == a[0x2000:0x2800]
    w("sprite_patterns.bin", a[0x2000:0x2800],
      "sprite pattern generator, 64 x 16x16 (VRAM $2000)")

    # colour table — capture the un-flashed state (title == gamestart)
    assert t[0x1400:0x1420] == g[0x1400:0x1420]
    w("colour_table.bin", t[0x1400:0x1420],
      "TMS colour table, 32 x (fg<<4|bg); entries 7-10 flash in-game")

    # static name-table chrome: cells identical across all three captures
    nt = bytearray(a[0x0400:0x0700])
    for i in range(len(nt)):
        if not (t[0x400 + i] == g[0x400 + i] == a[0x400 + i]):
            nt[i] = 0
    kept = sum(1 for x in nt if x)
    w("nametable_chrome.bin", bytes(nt),
      f"name-table cells constant across all 3 dumps ({kept} non-zero; rest scrolls)")

    # full title-screen frame (title == gamestart name table) for Phase 3 verify
    assert t[0x0400:0x0700] == g[0x0400:0x0700]
    w("nametable_title.bin", t[0x0400:0x0700],
      "complete title/game-start name table (32x24) — Phase 3 reference frame")
    w("oam_title.bin", t[0x1C00:0x1C80],
      "sprite attribute table at the title screen (mostly parked)")

    open(f"{OUT}/manifest.txt", "w").write("\n".join(man) + "\n")
    print(f"  {OUT}/manifest.txt")


def main():
    ds = load()
    report(ds)
    if "--report" not in sys.argv:
        print("\ncarving -> assets/ ...")
        carve(ds)


if __name__ == "__main__":
    main()
