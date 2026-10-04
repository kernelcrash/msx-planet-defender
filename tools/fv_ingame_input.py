#!/usr/bin/env python3
"""Start a REAL game (press '6') then drive the CreatiVision matrix and watch how
BIOS $FA00 decodes each press into $11-$14 / $15, plus the ship/shot RAM, to build
the Phase-5 input->action map.

Real start sequence (from the user): reset -> pick mode with the controller side
(fire) buttons -> press 6 or B to start.  '6' and 'B' are both left-controller keys
in matrix column 13 (PA1 strobe $FD):
    '6'  -> KEYTBL[13] &= 0xAF   (clears PB bits 6+4)
    'B'  -> KEYTBL[13] &= 0xF9   (clears PB bits 2+1)
Left fire A = KEYTBL[7] &= 0x7F ; left fire B = KEYTBL[13] &= 0x7F.
"""
from fv_emu import Funvision

CART = "funvision-reference/PlanetDefender.rom"
BIOS = "funvision-reference/FunvisionBIOS.rom"

# (label, col, clear-mask) - masks straight from funnysdl.c keydown handler
PRESSES = [
    ("stick UP      ", 14, 0xF7),
    ("stick DOWN    ", 14, 0xFD),
    ("stick LEFT    ", 14, 0xDF),
    ("stick RIGHT   ", 14, 0xFB),
    ("L-fire A (CTRL)", 7, 0x7F),
    ("L-fire B (SHFT)", 13, 0x7F),
    ("R-stick UP    ", 11, 0xF7),
    ("R-stick DOWN  ", 11, 0xFD),
    ("R-stick LEFT  ", 11, 0xDF),
    ("R-stick RIGHT ", 11, 0xFB),
    ("key '6'       ", 13, 0xAF),
    ("key 'B'       ", 13, 0xF9),
]


def snap(fv):
    r = fv.ram
    return (f"$11-14={r[0x11]:02X} {r[0x12]:02X} {r[0x13]:02X} {r[0x14]:02X} "
            f"$15={r[0x15]:02X} $1D={r[0x1D]:02X} $1E={r[0x1E]:02X} | "
            f"$18-1B={r[0x18]:02X} {r[0x19]:02X} {r[0x1A]:02X} {r[0x1B]:02X} | "
            f"$4C={r[0x4C]:02X} $68={r[0x68]:02X} $42={r[0x42]:02X} $45={r[0x45]:02X} "
            f"$D4-D7={r[0xD4]:02X} {r[0xD5]:02X} {r[0xD6]:02X} {r[0xD7]:02X}")


def boot_into_game(hold6_frames=30, settle=90):
    fv = Funvision(open(CART, "rb").read(), open(BIOS, "rb").read())
    fv.run(until=0xB5B5, max_frames=250)
    # hold '6' for a while to get past the title / mode select
    for _ in range(hold6_frames):
        fv.keytbl[13] &= 0xAF
        fv.run(max_frames=fv._frame + 1)
        fv.keytbl[13] = 0xFF
        fv.run(max_frames=fv._frame + 1)
    fv.run(max_frames=fv._frame + settle)
    return fv


base = boot_into_game()
print(f"after '6' start:  {snap(base)}\n")

for label, col, mask in PRESSES:
    fv = boot_into_game()
    for _ in range(10):
        fv.keytbl[col] &= mask
        fv.run(max_frames=fv._frame + 1)
    print(f"{label} col{col:<2d}&{mask:02X}: {snap(fv)}")
