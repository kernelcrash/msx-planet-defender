#!/usr/bin/env python3
"""Carve the HUD VDP-script blobs the MSX port INCBINs (Phase 4f).

The original's DrawHUD ($BBFA) and game-over path feed short "$FD53" VDP
scripts — {addrHi, addrLo, count, byte*count} blocks, 0-terminated — straight
to the VDP.  The port reimplements $FD53 (src/vdp.asm VdpRunScript) and reuses
these raw blocks verbatim.  They live at four non-contiguous spots in
PlanetDefender.rom; this concatenates them, in a fixed layout, to
assets/hud_scripts.bin.

Layout (offset : source : bytes : meaning):
   0 : $A440 : 20 : ramp meter, RAMPSTATE 0 & 4 — restore the default colour
                    table (identical to assets/colour_table.bin entries 0-15)
  20 : $BE19 : 16 : ramp meter, RAMPSTATE 2 — colour entries 0-11 -> $70.. / $77
  36 : $BE29 : 16 : ramp meter, RAMPSTATE 6 — colour entries 0-11 -> $80.. / $88
  52 : $BFC0 :  7 : blank name cells $0403-$0405 (P1 label gutter, 1-player)
  59 : $BFDE :  8 : redraw the "HIGH" label at name cells $0418-$041B
  67 : $BFB1 : 15 : write " GAME OVER " (11 tiles) at name $058A (row 12, col 10)
total 82 bytes.
"""
import os
import sys

ROM = os.path.join(os.path.dirname(__file__), "..",
                   "funvision-reference", "PlanetDefender.rom")
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "hud_scripts.bin")
BASE = 0xA000

BLOCKS = [
    (0xA440, 20),
    (0xBE19, 16),
    (0xBE29, 16),
    (0xBFC0, 7),
    (0xBFDE, 8),
    (0xBFB1, 15),
]


def main():
    rom = open(ROM, "rb").read()
    out = bytearray()
    for addr, n in BLOCKS:
        o = addr - BASE
        chunk = rom[o:o + n]
        assert len(chunk) == n
        assert chunk[-1] == 0x00, f"${addr:04X} block not 0-terminated"
        out += chunk
    if "--report" in sys.argv:
        print(" ".join("%02X" % b for b in out), f"({len(out)} B)")
        return
    open(OUT, "wb").write(out)
    print(f"wrote {OUT} ({len(out)} B)")


if __name__ == "__main__":
    main()
