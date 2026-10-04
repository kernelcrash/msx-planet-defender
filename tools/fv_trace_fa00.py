#!/usr/bin/env python3
"""Trace one BIOS $FA00 call with '6' held, driving frames the same way fv.run()
does (VDP vblank + mpu.irq() at each frame boundary) so the IRQ actually fires."""
from fv_emu import Funvision

CART = "funvision-reference/PlanetDefender.rom"
BIOS = "funvision-reference/FunvisionBIOS.rom"

fv = Funvision(open(CART, "rb").read(), open(BIOS, "rb").read())
fv.run(until=0xB5B5, max_frames=250)
mpu = fv.mpu
fv.keytbl[13] &= 0xAF                       # hold '6'

TRACE = set(range(0xFA33, 0xFA62)) | {0xFA00, 0xFA25, 0xFA4C, 0xFF4C}
hits = 0
seen_fa00 = False
for frame in range(6):
    target = mpu.processorCycles + fv.CYCLES_PER_FRAME
    while mpu.processorCycles < target:
        pc = mpu.pc
        if pc == 0xFA00:
            seen_fa00 = True
        if seen_fa00 and pc in TRACE and hits < 120:
            r = fv.ram
            print(f"  {pc:04X} A={mpu.a:02X} X={mpu.x:02X} Y={mpu.y:02X} P={mpu.p:02X} "
                  f"| $00/01={r[1]:02X}{r[0]:02X} $18-1B={r[0x18]:02X}{r[0x19]:02X}"
                  f"{r[0x1A]:02X}{r[0x1B]:02X} $11-14={r[0x11]:02X}{r[0x12]:02X}"
                  f"{r[0x13]:02X}{r[0x14]:02X} $15={r[0x15]:02X}")
            hits += 1
        fv._pc = pc
        mpu.step()
    fv.vdp_status = (fv.vdp_status & 0xDF) | 0x80
    if fv.vkey and (fv.vdp_reg[1] & 0x20):
        mpu.irq()
    else:
        print(f"[frame {frame}] IRQ NOT fired: vkey={fv.vkey} vdpreg1={fv.vdp_reg[1]:02X}")
    fv._frame += 1
    r = fv.ram
    print(f"[end frame {frame}] $11-14={r[0x11]:02X} {r[0x12]:02X} {r[0x13]:02X} "
          f"{r[0x14]:02X}  $15={r[0x15]:02X} $16={r[0x16]:02X} $17={r[0x17]:02X}  "
          f"seen_fa00={seen_fa00}")
