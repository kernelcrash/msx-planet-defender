#!/usr/bin/env python3
"""Watch life / death / score / phase bytes across a long attract-demo run and
print every frame where one of them changes. Used to pin down $4C flags, $56/$5E
(lives vs enemy-count) and the $68/$69 death-explosion state machine."""
from fv_emu import Funvision

WATCH = {
    0x4C: "flags", 0x4D: "livesCfg", 0x4E: "curPlr",
    0x50: "sc0", 0x51: "sc1", 0x56: "h56", 0x5E: "x5E",
    0x68: "phase", 0x69: "phCt", 0x20: "sfxExpl",
}

cart = open("funvision-reference/PlanetDefender.rom", "rb").read()
bios = open("funvision-reference/FunvisionBIOS.rom", "rb").read()
fv = Funvision(cart, bios)
fv.run(until=0xB5B5, max_frames=200)

prev = {a: None for a in WATCH}
enemy_prev = None
for _ in range(6000):
    fv.run(max_frames=fv._frame + 1)
    r = fv.ram
    cur = {a: r[a] for a in WATCH}
    n_en = sum(1 for i in range(0, 0x20, 4) if r[0x320 + i] & 0x80)  # active/dying
    changed = [f"{WATCH[a]}={cur[a]:02X}(<{prev[a]:02X})" for a in WATCH
              if prev[a] is not None and cur[a] != prev[a]]
    if n_en != enemy_prev:
        changed.append(f"nEnemyNeg={n_en}")
    if changed:
        print(f"f{fv._frame:5d}: " + "  ".join(changed))
    prev = cur
    enemy_prev = n_en
