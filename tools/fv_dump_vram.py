#!/usr/bin/env python3
"""Phase 2 VRAM capture — dump TMS9918 VRAM at three checkpoints so the static
tables (pattern/sprite generators, colour table) can be told apart from the
per-frame state (name table scroll, OAM).

  1. title    — a few frames after the first arrival at the main loop $B5B5
  2. gamestart — a few frames after $BD60 InitPlayer runs in a real session
                 (started by holding '6' — left controller matrix col 13)
  3. attract  — the running attract demo (~700 frames), = build/re/vram_attract.bin

Writes build/re/vram_{title,gamestart}.bin and prints R0-R7 + table bases at each.
Drives frames exactly the way fv_emu.Funvision.run() does (vblank + mpu.irq()).
"""
import sys
from fv_emu import Funvision

CART = "funvision-reference/PlanetDefender.rom"
BIOS = "funvision-reference/FunvisionBIOS.rom"
OUT = "build/re"


def bases(fv):
    b = fv.table_bases()
    return (f"R={' '.join(f'{x:02X}' for x in fv.vdp_reg)}  "
            f"name={b['name']:04X} colour={b['colour']:04X} "
            f"pattern={b['pattern']:04X} sprite_attr={b['sprite_attr']:04X} "
            f"sprite_gen={b['sprite_gen']:04X}")


def main():
    fv = Funvision(open(CART, "rb").read(), open(BIOS, "rb").read())
    mpu = fv.mpu

    # --- 1. boot to the main loop, let the title settle ---
    fv.run(until=0xB5B5, max_frames=250)
    for _ in range(120):
        step_frame(fv)
    open(f"{OUT}/vram_title.bin", "wb").write(fv.vram)
    print(f"[title]     frame {fv._frame}  {bases(fv)}")

    # --- 2. start a session; snapshot once it is well underway ---
    # hold '6' (col 13, mask 0xAF) until $4C bit6 (session active) is set
    started = False
    for i in range(400):
        step_frame(fv, hold={13: 0xAF} if i % 2 == 0 else None)
        if fv.ram[0x4C] & 0x40:
            started = True
            break
    if not started:
        print("!! session never started (attract auto-start expected ~frame 300)")
    run_until_pc(fv, 0xBD60, max_frames=120)   # InitPlayer if a death happens
    for _ in range(150):                        # let terrain + sprites populate
        step_frame(fv)
    open(f"{OUT}/vram_gamestart.bin", "wb").write(fv.vram)
    print(f"[gamestart]  frame {fv._frame}  $4C={fv.ram[0x4C]:02X}  {bases(fv)}")

    print(f"\nwrote {OUT}/vram_title.bin, {OUT}/vram_gamestart.bin")
    print(f"(attract dump already at {OUT}/vram_attract.bin)")


def step_frame(fv, hold=None):
    mpu = fv.mpu
    hold = hold or {}
    for c in range(16):
        fv.keytbl[c] = 0xFF
    for c, m in hold.items():
        fv.keytbl[c] &= m
    target = mpu.processorCycles + fv.CYCLES_PER_FRAME
    while mpu.processorCycles < target:
        fv._pc = mpu.pc
        mpu.step()
    fv.vdp_status = (fv.vdp_status & 0xDF) | 0x80
    if fv.vkey and (fv.vdp_reg[1] & 0x20):
        mpu.irq()
    fv._frame += 1


def run_until_pc(fv, addr, max_frames=400):
    mpu = fv.mpu
    end = fv._frame + max_frames
    while fv._frame < end:
        for c in range(16):
            fv.keytbl[c] = 0xFF
        target = mpu.processorCycles + fv.CYCLES_PER_FRAME
        while mpu.processorCycles < target:
            fv._pc = mpu.pc
            mpu.step()
            if mpu.pc == addr:
                return True
        fv.vdp_status = (fv.vdp_status & 0xDF) | 0x80
        if fv.vkey and (fv.vdp_reg[1] & 0x20):
            mpu.irq()
        fv._frame += 1
    return False


if __name__ == "__main__":
    main()
