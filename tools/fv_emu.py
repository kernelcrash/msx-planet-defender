#!/usr/bin/env python3
"""
Headless Funvision (VTech CreatiVision) machine harness on top of py65.

Models just enough hardware to boot PlanetDefender.rom through the 2KB BIOS and
run the game: 1KB mirrored RAM, the 6821 PIA (keyboard/joystick + SN76489 strobe
port), and a TMS9918 VDP (address latch + 16KB VRAM + vblank status/IRQ).

It is a *reference* tool for the port's reverse-engineering phase, not an
accurate emulator -- no video output, no cycle-exact sound. Its job is to let us
run the real game to a chosen PC and read ground-truth RAM / VRAM.

Semantics mirror funvision-reference/funnymu-0.44/funny.c (Wr6502 / Rd6502 /
Loop6502 / VDPOut).

Usage:
    fv_emu.py --until 0xB5B5 --frames 600 --dump-vram out/vram.bin
    fv_emu.py --until 0xB5B5 --watch 0x11:4 --watch 0x4C:1 --trace-calls
"""
import argparse, sys

from py65.devices.mpu6502 import MPU

ROM_DIR = "funvision-reference"


class Funvision:
    CYCLES_PER_FRAME = 40000  # PAL 50 Hz: funnymu VPeriod (2 MHz 6502 / 50); coarse

    def __init__(self, cart: bytes, bios: bytes, keytbl=None):
        assert len(bios) == 0x800, "BIOS must be 2KB"
        self.cart = bytearray(cart)
        self.bios = bytearray(bios)
        self.ram = bytearray(0x400)
        self.vram = bytearray(0x4000)

        # VDP
        self.vdp_reg = bytearray(8)
        self.vkey = 1            # address-latch key (1 = expecting first byte)
        self.vlatch = 0          # first (low) byte held during latch
        self.wvaddr = 0          # write auto-increment address
        self.rvaddr = 0          # read auto-increment address
        self.vdp_status = 0x9F

        # PIA
        self.pia_a_ddr = 0
        self.pia_a_io = 0
        self.pia_a_ctl = 0
        self.pia_b_ddr = 0
        self.pia_b_io = 0
        self.pia_b_ctl = 0

        # keyboard/joystick matrix as the BIOS sees it after EOR #$FF:
        # value returned on a $1002 read for column PIAAIO&0x0f. 0xFF = idle.
        self.keytbl = bytearray([0xFF] * 16)
        if keytbl:
            for i, v in keytbl.items():
                self.keytbl[i] = v

        # instrumentation
        self.sound_writes = []          # (frame, byte)
        self.call_log = []              # (pc_from, target) for JSR
        self._frame = 0

        self.mpu = MPU(memory=self, pc=None)  # pc=None -> use reset vector
        self.mpu.reset()

    # ---- memory bus -------------------------------------------------------
    def __getitem__(self, addr):
        if isinstance(addr, slice):
            return bytes(self[i] for i in range(*addr.indices(0x10000)))
        a = addr & 0xFFFF
        region = a & 0xF000
        if a < 0x1000:
            return self.ram[a & 0x3FF]
        if region == 0x1000:                       # PIA
            sel = a & 3
            if sel == 2:                           # PIA-B data (keyboard in)
                if (self.pia_b_ctl & 0x04) == 0:
                    return self.pia_b_ddr
                if self.pia_b_ddr == 0xFF:
                    return 0x9F
                col = self.pia_a_io & 0x0F
                if col == 0:
                    x = self.keytbl[7] ^ self.keytbl[11] ^ 0xFF
                    y = self.keytbl[13] ^ self.keytbl[14] ^ 0xFF
                    return x ^ y ^ 0xFF
                return self.keytbl[col]
            if sel == 3:                           # PIA-B control: ready bit
                return self.pia_b_ctl | 0x80
            if sel == 0:
                return self.pia_a_io if (self.pia_a_ctl & 0x04) else self.pia_a_ddr
            return self.pia_a_ctl
        if region == 0x2000:                       # VDP read
            if a & 1:
                v = self.vdp_status
                self.vdp_status &= 0x5F
                self.vkey = 1
                return v
            v = self.vram[self.rvaddr]
            self.rvaddr = (self.rvaddr + 1) & 0x3FFF
            return v
        if region == 0x3000:                       # VDP write port (read -> junk)
            return 0xFF
        if a < 0x8000:                             # 2nd cart slot: absent
            return 0xFF
        if a < 0xC000:                             # cart, 8KB mirrored in both halves
            return self.cart[a & 0x1FFF]
        return self.bios[a & 0x07FF]               # 2KB BIOS mirrored x8

    def __setitem__(self, addr, value):
        a = addr & 0xFFFF
        v = value & 0xFF
        region = a & 0xF000
        if a < 0x1000:
            self.ram[a & 0x3FF] = v
            return
        if region == 0x3000:
            if a & 1:                              # control / address latch
                if self.vkey:
                    self.vlatch = v
                    self.vkey = 0
                else:
                    self.vkey = 1
                    cmd = v & 0xC0
                    if cmd == 0x80:
                        self._vdp_out(v & 0x07, self.vlatch)
                    elif cmd == 0x40:
                        self.wvaddr = ((v & 0x3F) << 8) | self.vlatch
                    else:
                        self.rvaddr = ((v & 0x3F) << 8) | self.vlatch
            else:                                  # data
                if self.vkey:
                    self.vram[self.wvaddr] = v
                    self.wvaddr = (self.wvaddr + 1) & 0x3FFF
            return
        if region == 0x1000:
            sel = a & 3
            if sel == 0:
                if (self.pia_a_ctl & 0x04) == 0:
                    self.pia_a_ddr = v
                else:
                    self.pia_a_io = v
            elif sel == 1:
                self.pia_a_ctl = v
            elif sel == 2:
                if (self.pia_b_ctl & 0x04) == 0:
                    self.pia_b_ddr = v
                else:
                    self.pia_b_io = v
                    if v != 0x90:
                        self.sound_writes.append(
                            (self._frame, v, getattr(self, "_pc", 0)))
            else:
                self.pia_b_ctl = v
            return
        # writes to ROM / 2nd slot / $2000 ignored

    def _vdp_out(self, reg, val):
        self.vdp_reg[reg] = val

    # ---- run ------------------------------------------------------------
    def table_bases(self):
        r = self.vdp_reg
        return {
            "name":       (r[2] & 0x0F) << 10,
            "colour":     (r[3] & 0xFF) << 6,
            "pattern":    (r[4] & 0x07) << 11,
            "sprite_attr":(r[5] & 0x7F) << 7,
            "sprite_gen": (r[6] & 0x07) << 11,
        }

    def run(self, until=None, max_frames=1200, trace_calls=False,
            watch=None, stop_on_watch=False):
        mpu = self.mpu
        watch = watch or []
        prev_watch = {}
        while self._frame < max_frames:
            # one frame worth of execution
            target = mpu.processorCycles + self.CYCLES_PER_FRAME
            while mpu.processorCycles < target:
                pc = mpu.pc
                op = self[pc]
                if trace_calls and op == 0x20:  # JSR abs
                    tgt = self[(pc + 1) & 0xFFFF] | (self[(pc + 2) & 0xFFFF] << 8)
                    self.call_log.append((pc, tgt))
                self._pc = pc
                mpu.step()
                if until is not None and mpu.pc == until:
                    return "until", mpu.pc
            # vblank + IRQ, mirroring Loop6502
            self.vdp_status = (self.vdp_status & 0xDF) | 0x80
            if self.vkey and (self.vdp_reg[1] & 0x20):
                mpu.irq()
            self._frame += 1
            for w in watch:
                base, ln = w
                cur = bytes(self.ram[base + i] for i in range(ln)) \
                    if base < 0x400 else self[base:base + ln]
                if w in prev_watch and prev_watch[w] != cur and stop_on_watch:
                    return "watch", (base, cur)
                prev_watch[w] = cur
        return "frames", self._frame


def parse_watch(s):
    if ":" in s:
        a, n = s.split(":")
        return (int(a, 16), int(n))
    return (int(s, 16), 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cart", default=f"{ROM_DIR}/PlanetDefender.rom")
    ap.add_argument("--bios", default=f"{ROM_DIR}/FunvisionBIOS.rom")
    ap.add_argument("--until", help="stop when PC == this hex address")
    ap.add_argument("--frames", type=int, default=1200)
    ap.add_argument("--dump-vram")
    ap.add_argument("--dump-ram")
    ap.add_argument("--watch", action="append", default=[],
                    help="ADDR[:LEN] in hex - report value at end")
    ap.add_argument("--trace-calls", action="store_true")
    ap.add_argument("--sound-log", help="write frame/PC/byte of every SN76489 write")
    ap.add_argument("--call-summary", action="store_true")
    a = ap.parse_args()

    cart = open(a.cart, "rb").read()
    bios = open(a.bios, "rb").read()
    fv = Funvision(cart, bios)

    until = int(a.until, 16) if a.until else None
    watch = [parse_watch(w) for w in a.watch]
    why, info = fv.run(until=until, max_frames=a.frames,
                       trace_calls=a.trace_calls or a.call_summary, watch=watch)

    print(f"; stopped: {why} {info!r}  frame={fv._frame}  "
          f"PC={fv.mpu.pc:04X}  cycles={fv.mpu.processorCycles}")
    print(f"; VDP regs: {' '.join(f'{x:02X}' for x in fv.vdp_reg)}")
    for k, v in fv.table_bases().items():
        print(f";   {k:12s} ${v:04X}")
    print(f"; A={fv.mpu.a:02X} X={fv.mpu.x:02X} Y={fv.mpu.y:02X} "
          f"SP={fv.mpu.sp:02X} P={fv.mpu.p:02X}")
    print(f"; sound writes: {len(fv.sound_writes)}  "
          f"first 24: {[f'{w[1]:02X}' for w in fv.sound_writes[:24]]}")
    if a.sound_log:
        with open(a.sound_log, "w") as fh:
            for frm, b, pc in fv.sound_writes:
                fh.write(f"{frm:6d}  {pc:04X}  {b:02X}\n")
        print(f"; wrote {a.sound_log} ({len(fv.sound_writes)} SN76489 writes)")

    for base, ln in watch:
        data = bytes(fv.ram[base + i] for i in range(ln)) if base < 0x400 \
            else fv[base:base + ln]
        print(f"; watch ${base:04X}: {' '.join(f'{x:02X}' for x in data)}")

    if a.call_summary:
        seen = {}
        for frm, tgt in fv.call_log:
            seen[tgt] = seen.get(tgt, 0) + 1
        print("; --- JSR targets (target: count) ---")
        for tgt in sorted(seen):
            print(f";   ${tgt:04X}: {seen[tgt]}")

    if a.dump_vram:
        open(a.dump_vram, "wb").write(fv.vram)
        print(f"; wrote {a.dump_vram} (16384 bytes VRAM)")
    if a.dump_ram:
        open(a.dump_ram, "wb").write(fv.ram)
        print(f"; wrote {a.dump_ram} (1024 bytes RAM)")


if __name__ == "__main__":
    main()
