#!/usr/bin/env python3
"""Carve the Phase-6 sound data blobs from the original ROMs.

Two outputs, both raw byte copies (per the "reuse original data" directive):

  assets/sound_sfx.bin      70 B  — cart $BD9C-$BDE1, the SoundDispatch ($BC83)
                                    lookup tables (spawn atten / explosion-noise
                                    atten / fire freq / ground reload / ground byte)

  assets/sound_jingle.bin  167 B  — the PlaySfx ($FBD6) data:
      off  0  +8   BIOS $FC79  note-duration table
      off  8  +42  BIOS $FC80  freq low-nibble table
      off 50  +42  BIOS $FCAA  freq data-byte table
      off 92  +17  BIOS $FCD5  amplitude envelope (loud->silent)
      off109  +9   cart $BF00  the 3 {seqLo,seqHi,startIdx} records (id 0/3/6)
      off118  +53  cart $BF20  id 0 (game-start) sequence   [startIdx $34]
      off171  ...  -- see below, offsets continue --

  (final layout printed by --report)
"""
import sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CART = (ROOT / "funvision-reference/PlanetDefender.rom").read_bytes()
BIOS = (ROOT / "funvision-reference/FunvisionBIOS.rom").read_bytes()
CART_BASE = 0xA000
BIOS_BASE = 0x10000 - len(BIOS)

def cart(a, n): return CART[a - CART_BASE : a - CART_BASE + n]
def bios(a, n): return BIOS[a - BIOS_BASE : a - BIOS_BASE + n]

# --- SoundDispatch tables: one contiguous span -----------------------------
SFX = cart(0xBD9C, 0xBDE1 - 0xBD9C + 1)          # 70 bytes
assert len(SFX) == 70

# --- PlaySfx data ---------------------------------------------------------
DUR  = bios(0xFC79, 8)
FLO  = bios(0xFC80, 42)
DAT  = bios(0xFCAA, 42)
ENV  = bios(0xFCD5, 17)
RECS = cart(0xBF00, 9)                            # id0 @0..2, id3 @3..5, id6 @6..8
SEQ0 = cart(0xBF20, 0x34 + 1)                     # read backwards from idx $34
SEQ3 = cart(0xBEC0, 0x0F + 1)                     # idx $0F
SEQ6 = cart(0xBF80, 0x2A + 1)                     # idx $2A

JINGLE = b"".join([DUR, FLO, DAT, ENV, RECS, SEQ0, SEQ3, SEQ6])

def main():
    if "--report" in sys.argv:
        o = 0
        for tag, b in [("FC79 dur", DUR), ("FC80 flo", FLO), ("FCAA dat", DAT),
                       ("FCD5 env", ENV), ("BF00 recs", RECS),
                       ("BF20 seq id0", SEQ0), ("BEC0 seq id3", SEQ3),
                       ("BF80 seq id6", SEQ6)]:
            print(f"  +{o:3d}  {len(b):3d}  {tag}")
            o += len(b)
        print(f"  sound_jingle.bin = {len(JINGLE)} bytes")
        print(f"  sound_sfx.bin    = {len(SFX)} bytes")
        return
    (ROOT / "assets/sound_sfx.bin").write_bytes(SFX)
    (ROOT / "assets/sound_jingle.bin").write_bytes(JINGLE)
    print(f"wrote assets/sound_sfx.bin ({len(SFX)} B), "
          f"assets/sound_jingle.bin ({len(JINGLE)} B)")

if __name__ == "__main__":
    main()
