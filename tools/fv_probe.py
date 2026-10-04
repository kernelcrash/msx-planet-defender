#!/usr/bin/env python3
"""Ad-hoc dynamic probe: run PlanetDefender in fv_emu into the attract demo and
dump the stride-4 object arrays for a frame with several enemies active.

Enemy iterator is `LDX #$1C : ... : JSR $FD30 (X-=4) : BPL` -> 8 slots at
X in {0,4,8,$0C,$10,$14,$18,$1C}."""
from fv_emu import Funvision

SLOTS = list(range(0, 0x20, 4))  # 0,4,8,C,10,14,18,1C

cart = open("funvision-reference/PlanetDefender.rom", "rb").read()
bios = open("funvision-reference/FunvisionBIOS.rom", "rb").read()
fv = Funvision(cart, bios)
fv.run(until=0xB5B5, max_frames=200)
fv.run(max_frames=1600)

best = None
for _ in range(600):
    fv.run(max_frames=fv._frame + 1)
    r = fv.ram
    st = [r[0x320 + i] for i in SLOTS]
    n = sum(1 for v in st if v)
    if best is None or n > best[0]:
        best = (n, fv._frame, bytes(r[:0x400]))
    if n >= 7:
        break

n, frame, ram = best
print(f"frame {frame}: {n}/8 enemy slots non-zero")
print(f"  $0320-$033F: {ram[0x320:0x340].hex(' ')}")
for i in SLOTS:
    s = ram[0x320 + i:0x324 + i].hex(" ")
    oam = ram[0x80 + i:0x84 + i].hex(" ")
    pos = ram[0xE0 + i:0xE4 + i].hex(" ")
    spd = ram[0x300 + i:0x304 + i].hex(" ")
    anim = ram[0x340 + i:0x344 + i].hex(" ")
    print(f"  slot @{i:02X}: st[{s}] oam[{oam}] pos[{pos}] spd[{spd}] anim[{anim}]")
print(f"  player DA/DB={ram[0xDA]:02x} {ram[0xDB]:02x}  46/47={ram[0x46]:02x} {ram[0x47]:02x}")
print(f"  ebul  $A0-$AF: {ram[0xA0:0xB0].hex(' ')}")
print(f"  pbul  $C0-$CF: {ram[0xC0:0xD0].hex(' ')}")
print(f"  $4C={ram[0x4C]:02x} $4E={ram[0x4E]:02x} $49(frameCtr)={ram[0x49]:02x}")
