#!/usr/bin/env python3
"""Dynamic confirmation of collision loop 1 (§7a): start a real game, fly around
firing, and log every AddScore ($BB93) with the enemy class that was hit, to check
the static per-class score table ($02/$03/$05 for $81&$30 = $00/$10/$20).

Drives frames the way fv.run() does (vblank + mpu.irq() each frame) so the BIOS
IRQ — and thus $FA00 input decode — actually runs.
"""
from fv_emu import Funvision

CART = "funvision-reference/PlanetDefender.rom"
BIOS = "funvision-reference/FunvisionBIOS.rom"
SLOTS = list(range(0, 0x20, 4))

fv = Funvision(open(CART, "rb").read(), open(BIOS, "rb").read())
fv.run(until=0xB5B5, max_frames=250)
mpu = fv.mpu

# This cart cold-boots into the ATTRACT demo ($4C bit7 = 0 -> $BCF2 drives $11/$16).
# Force bit7 so player input ($FA00 -> $11-$17) is honoured (= the "warm" boot path).
fv.ram[0x4C] |= 0x80


def press(col, mask, frames):
    for _ in range(frames):
        step_frame(hold={col: mask})


HITS = []
last_score = [0, 0]


def step_frame(hold=None):
    hold = hold or {}
    for c in range(16):
        fv.keytbl[c] = 0xFF
    for c, m in hold.items():
        fv.keytbl[c] &= m
    target = mpu.processorCycles + fv.CYCLES_PER_FRAME
    while mpu.processorCycles < target:
        pc = mpu.pc
        if pc == 0xBA28:                     # JSR $BB93  (A = $BDFF[Y] = points)
            y = mpu.y
            x = mpu.x
            cls = fv.ram[0x81 + x] & 0x30
            HITS.append((fv._frame, y, cls, mpu.a,
                         f"loop1 sc={fv.ram[0x50]:02X}{fv.ram[0x51]:02X}"))
        elif pc == 0xBA5F:                   # JSR $BB91  (loop-2 tile hit, +1)
            HITS.append((fv._frame, None, None, 1, "loop2"))
        elif pc == 0xBA9B:
            HITS.append((fv._frame, None, None, 0, "PLAYER-DEATH"))
        fv._pc = pc
        mpu.step()
    fv.vdp_status = (fv.vdp_status & 0xDF) | 0x80
    if fv.vkey and (fv.vdp_reg[1] & 0x20):
        mpu.irq()
    fv._frame += 1


# --- start the game: hold '6' (col 13, mask $AF) a while ---
for _ in range(40):
    step_frame(hold={13: 0xAF})
    step_frame()
for _ in range(60):
    step_frame()
print(f"after start: frame {fv._frame}  $4C={fv.ram[0x4C]:02X} $56={fv.ram[0x56]:02X} "
      f"$68={fv.ram[0x68]:02X}")

# --- play ~4000 frames: pulse fire (col 14 b7) every 3rd frame, weave the stick ---
import itertools
dirs = itertools.cycle([(14, 0xDF), (14, 0xFB), (14, 0xF7), (14, 0xFD)])  # L R U D
for i in range(4000):
    hold = {}
    d = next(dirs)
    if i % 8 < 4:
        hold[d[0]] = hold.get(d[0], 0xFF) & d[1]
    if i % 3 == 0:                          # fire pulse (needs release between)
        hold[14] = hold.get(14, 0xFF) & 0x7F
    step_frame(hold=hold)

print(f"\nplayed to frame {fv._frame}. score $50/$51 = "
      f"{fv.ram[0x50]:02X}{fv.ram[0x51]:02X}  lives $56={fv.ram[0x56]:02X}")
print(f"{len(HITS)} collision events:")
from collections import Counter
by_cls = Counter()
for frm, y, cls, a, tag in HITS[:40]:
    cs = f"cls={cls:02X}" if cls is not None else "     "
    print(f"  f{frm:<5d} {tag:12s} {cs} Y={y if y is None else f'{y:02X}'} score+={a:02X}")
pts = {}
for frm, y, cls, a, tag in HITS:
    if tag.startswith("loop1"):
        by_cls[cls] += 1
        pts.setdefault(cls, set()).add(a)
print("loop1 kills by class:", {f'{k:02X}': v for k, v in by_cls.items()})
print("loop1 class -> points (BCD):", {f'{k:02X}': sorted(v) for k, v in pts.items()})
