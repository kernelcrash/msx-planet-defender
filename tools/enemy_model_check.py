#!/usr/bin/env python3
"""Validate tools/enemy_model.enemy_update() against the real ROM.

Boots fv_emu into a live session (see fv-emu-boot-into-session), then runs a
per-frame CPU loop that mirrors fv_emu.run() but adds PC checkpoints at
$B730 (enemy-update entry) and $B918 (exit).  Each frame the $B730 snapshot is
fed to the Python model and diffed against the real $B918 snapshot.
"""
import sys
from fv_emu import Funvision
from enemy_model import enemy_update

CART = "funvision-reference/PlanetDefender.rom"
BIOS = "funvision-reference/FunvisionBIOS.rom"
ENTRY, EXIT = 0xB730, 0xB918
CPF = 40000
CMP_RANGES = [(0x00, 0x100), (0x300, 0x100)]


def snap(fv):
    return bytearray(fv.ram[i] for i in range(0x400))


def diff(a, b):
    out = []
    for base, ln in CMP_RANGES:
        for i in range(base, base + ln):
            if a[i] != b[i] and not (0x04 <= i <= 0x0A):
                out.append((i, a[i], b[i]))
    return out


def boot(fv):
    fv.run(until=0xB5B5, max_frames=250)
    for _ in range(20):
        fv.keytbl[7] &= 0x7F; fv.keytbl[13] &= 0x7F
        fv.run(max_frames=fv._frame + 1)
        fv.keytbl[7] = 0xFF; fv.keytbl[13] = 0xFF
        fv.run(max_frames=fv._frame + 1)
    for _ in range(40):
        fv.keytbl[13] &= 0xAF
        fv.run(max_frames=fv._frame + 1)
        fv.keytbl[13] = 0xFF
        fv.run(max_frames=fv._frame + 1)
    while fv.ram[0x68] != 0xFF and fv._frame < 1500:   # wait for ship-alive
        fv.run(max_frames=fv._frame + 20)


def main():
    nframes = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    verbose = "-v" in sys.argv
    fv = Funvision(open(CART, "rb").read(), open(BIOS, "rb").read())
    boot(fv)
    mpu = fv.mpu
    print(f"; booted frame={fv._frame} $68={fv.ram[0x68]:02X} $4C={fv.ram[0x4C]:02X}")

    def run_until(pc, limit=400000):
        n = 0
        while n < limit:
            mpu.step(); n += 1
            if mpu.processorCycles >= fv._nextirq:
                fv.vdp_status = (fv.vdp_status & 0xDF) | 0x80
                if fv.vkey and (fv.vdp_reg[1] & 0x20):
                    mpu.irq()
                fv._nextirq += CPF
                fv._frame += 1
            if mpu.pc == pc:
                return True
        return False

    fv._nextirq = mpu.processorCycles + CPF
    ok = bad = 0
    last_en = None
    for f in range(nframes):
        if not run_until(ENTRY):
            print(f"; frame {f}: lost $B730"); break
        before = snap(fv)
        if not run_until(EXIT):
            print(f"; frame {f}: lost $B918"); break
        after = snap(fv)
        model = bytearray(before)
        enemy_update(model)
        d = diff(model, after)
        en = " ".join(f"{after[0x320 + 4 * s]:02X}" for s in range(8))
        if d:
            bad += 1
            if bad <= 15:
                desc = " ".join(f"{a:03X}:m={x:02X}/r={y:02X}" for a, x, y in d[:10])
                print(f"F{f} en=[{en}] {desc}")
        else:
            ok += 1
            if verbose and en != last_en:
                print(f"F{f} en=[{en}] OK")
        last_en = en
    print(f"; ok={ok} mismatch={bad}")


if __name__ == "__main__":
    main()
