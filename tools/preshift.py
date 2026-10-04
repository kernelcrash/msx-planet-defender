#!/usr/bin/env python3
"""Phase 4b — pre-shifted pattern-bank generator (Planet Defender -> MSX).

The 8 pre-shifted pattern banks do NOT exist as raw bytes in the cartridge.
The original builds them at boot from a compact base set + two small routines:

  $B514  HUD/font upload    8 banks x 8 records ({dsthi,dstlo,srchi,srclo,ystart},
                            copy 256-ystart bytes).  Sources: cart $B038/$B078/
                            $B0C8 and Funvision BIOS $F7D0/$F850/$F870/$F8A0/$F8B8.
                            Writes the SAME bytes into every bank (tiles $59-$7F,
                            $E0-$FF: font, digits, HUD chrome, scanner).

  $B547  terrain pre-shift  slot = $58..0.  For each slot load the tile's 8-byte
                            base pattern (E) from  $B000 + 8*B1C8[slot]  and its
                            left-neighbour (F) from  $B000 + 8*B1C8[B221[slot]].
                            8 passes: write E[0..7] to the current bank, then
                            per row  {E:F} <<= 1  (16-bit, E high / F low), and
                            step the bank +$0800.  Banks run $0000 (7px) .. $3800
                            (0px).  Covers tiles $01-$58 (the scrolling terrain).

This module carves the raw ROM/BIOS inputs the Z80 port INCBINs, and emits a
byte-exact golden image of the pattern region for the port's tests to diff
against.  Verified: the model reproduces every name-table-referenced tile
($01-$7F + $E0-$FF) in all 8 banks exactly (tiles $80-$DF are unreferenced
overlap garbage and are not reproduced).

  assets/preshift_rom.bin    PlanetDefender.rom $B000-$B2A1  (base patterns +
                             B1C8 + B221 index tables + B27A upload records)
  assets/bios_font.bin       FunvisionBIOS.rom $F7D0-$F9BF   (glyph windows the
                             B27A records read; linear, wrap unrolled)
  build/re/pattern_banks_golden.bin   16 KB, all 8 banks, tests only (not shipped)

The Z80 side of this (Phase 4b) lives in src/vdp.asm PreShiftHudFont /
PreShiftTerrain; assets/terrain_map.bin (cart $A000-$A217) feeds DrawTerrain.
"""
import os
import sys

ROM = "funvision-reference/PlanetDefender.rom"
BIOS = "funvision-reference/FunvisionBIOS.rom"
OUT = "assets"
GOLD = "build/re/pattern_banks_golden.bin"

PRESHIFT_LO, PRESHIFT_HI = 0xB000, 0xB2A2     # cart window -> preshift_rom.bin
#   BIOS window: the B27A records read  (srchi:srclo) + ystart .. + (256-ystart);
#   effective span is $F880-$F9B7, but the Z80 port keys the blob origin to the
#   record's raw srchi:srclo ($F7D0 low), so carve from there.
BIOS_LO, BIOS_HI = 0xF7D0, 0xF9C0             # bios window -> bios_font.bin


def main():
    cart = open(ROM, "rb").read()
    bios = open(BIOS, "rb").read()

    def rd(a):
        a &= 0xFFFF
        if a >= 0xC000:
            return bios[a & 0x07FF]
        if a >= 0x8000:                        # 8 KB cart at $8000 and mirror $A000
            return cart[a & 0x1FFF]
        return 0xFF

    vram = bytearray(0x4000)

    # --- $B514: HUD / font / chrome, identical in every bank -----------------
    for o5 in range(0x40, 0x80, 8):            # bank select: $40,$48 .. $78
        for x in range(0x23, -1, -5):          # 8 records, index steps -5
            hi, lo, srchi, srclo, ys = (rd(0xB27A + x), rd(0xB27B + x),
                                        rd(0xB27C + x), rd(0xB27D + x),
                                        rd(0xB27E + x))
            dest = (((hi | o5) & 0x3F) << 8) | lo
            ptr = (srchi << 8) | srclo
            y, n = ys, 0
            while True:
                vram[(dest + n) & 0x3FFF] = rd((ptr + y) & 0xFFFF)
                n += 1
                y = (y + 1) & 0xFF
                if y == 0:
                    break

    # --- $B547: scrolling-terrain tiles, pre-shifted 0..7 px ----------------
    def base_ptr(idx):                         # BC5D: ($16<<8 | B1C8[idx]) << 3
        return (((0x16 << 8) | rd(0xB1C8 + idx)) << 3) & 0xFFFF

    def load8(p):                              # BC78: 8 bytes, straight order
        return [rd((p + y) & 0xFFFF) for y in range(8)]

    for slot in range(0x58, -1, -1):
        e = load8(base_ptr(slot))
        f = load8(base_ptr(rd(0xB221 + slot)))
        a, o5 = slot, 0x30                     # dest low byte / hi accumulator
        a = (a << 1) & 0xFF
        t = a << 1; c = (t >> 8) & 1; a = t & 0xFF; o5 = ((o5 << 1) | c) & 0xFF
        t = a << 1; c = (t >> 8) & 1; a = t & 0xFF; o5 = ((o5 << 1) | c) & 0xFF
        low = a
        for _ in range(8):
            va = ((o5 & 0x3F) << 8) | low
            for k in range(8):
                vram[(va + k) & 0x3FFF] = e[k]
            o5 = (o5 + 8) & 0xFF
            for k in range(8):                 # {E:F} <<= 1, per row
                f[k] <<= 1
                carry = (f[k] >> 8) & 1
                f[k] &= 0xFF
                e[k] = ((e[k] << 1) | carry) & 0xFF

    # --- verify against the reference emulator capture ---------------------
    ref_path = "build/re/vram_attract.bin"
    if os.path.exists(ref_path):
        ref = open(ref_path, "rb").read()
        drawn = list(range(0x01, 0x80)) + list(range(0xE0, 0x100))
        bad = 0
        for b in range(0, 0x4000, 0x800):
            for t in drawn:
                if vram[b + t * 8:b + t * 8 + 8] != ref[b + t * 8:b + t * 8 + 8]:
                    bad += 1
        if bad:
            sys.exit(f"MODEL MISMATCH: {bad} referenced tiles differ from {ref_path}")
        print(f"model verified byte-exact vs {ref_path} "
              f"({len(drawn) * 8} referenced tiles x 8 banks)")
    else:
        print(f"note: {ref_path} absent - skipping self-check "
              f"(python3 tools/fv_emu.py --frames 700 --dump-vram {ref_path})")

    # --- carve -----------------------------------------------------------
    os.makedirs(OUT, exist_ok=True)
    os.makedirs("build/re", exist_ok=True)

    a = cart[PRESHIFT_LO & 0x1FFF:(PRESHIFT_HI & 0x1FFF)]
    open(f"{OUT}/preshift_rom.bin", "wb").write(a)
    print(f"  {OUT}/preshift_rom.bin   {len(a):4} B   "
          f"cart ${PRESHIFT_LO:04X}-${PRESHIFT_HI - 1:04X} "
          f"(base patterns + B1C8/B221 tables + B27A records)")

    bf = bytes(rd(BIOS_LO + i) for i in range(BIOS_HI - BIOS_LO))
    open(f"{OUT}/bios_font.bin", "wb").write(bf)
    print(f"  {OUT}/bios_font.bin      {len(bf):4} B   "
          f"BIOS ${BIOS_LO:04X}-${BIOS_HI - 1:04X} (glyph windows, wrap unrolled)")

    open(GOLD, "wb").write(vram)
    print(f"  {GOLD}   {len(vram)} B   golden 8-bank image (tests only)")


if __name__ == "__main__":
    main()
