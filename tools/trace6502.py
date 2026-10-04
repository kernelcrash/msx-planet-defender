#!/usr/bin/env python3
"""
Recursive-descent 6502 disassembler for the Planet Defender ROM.

Follows flow from entry points (and any -e addr given), marking reachable bytes as
code. Everything else in the cart's code window is reported as data runs. Produces
an annotated listing with labels for every branch/call target.

Usage:
    trace6502.py PlanetDefender.rom [-e ADDR ...]
"""
import sys, argparse

# opcode table: byte -> (mnemonic, mode)
OPS = {}
def _add(rows):
    for o, m, md in rows:
        OPS[o] = (m, md)
_add([
 (0x00,"BRK","imp"),(0x01,"ORA","izx"),(0x05,"ORA","zp"),(0x06,"ASL","zp"),(0x08,"PHP","imp"),(0x09,"ORA","imm"),(0x0A,"ASL","acc"),(0x0D,"ORA","abs"),(0x0E,"ASL","abs"),
 (0x10,"BPL","rel"),(0x11,"ORA","izy"),(0x15,"ORA","zpx"),(0x16,"ASL","zpx"),(0x18,"CLC","imp"),(0x19,"ORA","aby"),(0x1D,"ORA","abx"),(0x1E,"ASL","abx"),
 (0x20,"JSR","abs"),(0x21,"AND","izx"),(0x24,"BIT","zp"),(0x25,"AND","zp"),(0x26,"ROL","zp"),(0x28,"PLP","imp"),(0x29,"AND","imm"),(0x2A,"ROL","acc"),(0x2C,"BIT","abs"),(0x2D,"AND","abs"),(0x2E,"ROL","abs"),
 (0x30,"BMI","rel"),(0x31,"AND","izy"),(0x35,"AND","zpx"),(0x36,"ROL","zpx"),(0x38,"SEC","imp"),(0x39,"AND","aby"),(0x3D,"AND","abx"),(0x3E,"ROL","abx"),
 (0x40,"RTI","imp"),(0x41,"EOR","izx"),(0x45,"EOR","zp"),(0x46,"LSR","zp"),(0x48,"PHA","imp"),(0x49,"EOR","imm"),(0x4A,"LSR","acc"),(0x4C,"JMP","abs"),(0x4D,"EOR","abs"),(0x4E,"LSR","abs"),
 (0x50,"BVC","rel"),(0x51,"EOR","izy"),(0x55,"EOR","zpx"),(0x56,"LSR","zpx"),(0x58,"CLI","imp"),(0x59,"EOR","aby"),(0x5D,"EOR","abx"),(0x5E,"LSR","abx"),
 (0x60,"RTS","imp"),(0x61,"ADC","izx"),(0x65,"ADC","zp"),(0x66,"ROR","zp"),(0x68,"PLA","imp"),(0x69,"ADC","imm"),(0x6A,"ROR","acc"),(0x6C,"JMP","ind"),(0x6D,"ADC","abs"),(0x6E,"ROR","abs"),
 (0x70,"BVS","rel"),(0x71,"ADC","izy"),(0x75,"ADC","zpx"),(0x76,"ROR","zpx"),(0x78,"SEI","imp"),(0x79,"ADC","aby"),(0x7D,"ADC","abx"),(0x7E,"ROR","abx"),
 (0x81,"STA","izx"),(0x84,"STY","zp"),(0x85,"STA","zp"),(0x86,"STX","zp"),(0x88,"DEY","imp"),(0x8A,"TXA","imp"),(0x8C,"STY","abs"),(0x8D,"STA","abs"),(0x8E,"STX","abs"),
 (0x90,"BCC","rel"),(0x91,"STA","izy"),(0x94,"STY","zpx"),(0x95,"STA","zpx"),(0x96,"STX","zpy"),(0x98,"TYA","imp"),(0x99,"STA","aby"),(0x9A,"TXS","imp"),(0x9D,"STA","abx"),
 (0xA0,"LDY","imm"),(0xA1,"LDA","izx"),(0xA2,"LDX","imm"),(0xA4,"LDY","zp"),(0xA5,"LDA","zp"),(0xA6,"LDX","zp"),(0xA8,"TAY","imp"),(0xA9,"LDA","imm"),(0xAA,"TAX","imp"),(0xAC,"LDY","abs"),(0xAD,"LDA","abs"),(0xAE,"LDX","abs"),
 (0xB0,"BCS","rel"),(0xB1,"LDA","izy"),(0xB4,"LDY","zpx"),(0xB5,"LDA","zpx"),(0xB6,"LDX","zpy"),(0xB8,"CLV","imp"),(0xB9,"LDA","aby"),(0xBA,"TSX","imp"),(0xBC,"LDY","abx"),(0xBD,"LDA","abx"),(0xBE,"LDX","aby"),
 (0xC0,"CPY","imm"),(0xC1,"CMP","izx"),(0xC4,"CPY","zp"),(0xC5,"CMP","zp"),(0xC6,"DEC","zp"),(0xC8,"INY","imp"),(0xC9,"CMP","imm"),(0xCA,"DEX","imp"),(0xCC,"CPY","abs"),(0xCD,"CMP","abs"),(0xCE,"DEC","abs"),
 (0xD0,"BNE","rel"),(0xD1,"CMP","izy"),(0xD5,"CMP","zpx"),(0xD6,"DEC","zpx"),(0xD8,"CLD","imp"),(0xD9,"CMP","aby"),(0xDD,"CMP","abx"),(0xDE,"DEC","abx"),
 (0xE0,"CPX","imm"),(0xE1,"SBC","izx"),(0xE4,"CPX","zp"),(0xE5,"SBC","zp"),(0xE6,"INC","zp"),(0xE8,"INX","imp"),(0xE9,"SBC","imm"),(0xEA,"NOP","imp"),(0xEC,"CPX","abs"),(0xED,"SBC","abs"),(0xEE,"INC","abs"),
 (0xF0,"BEQ","rel"),(0xF1,"SBC","izy"),(0xF5,"SBC","zpx"),(0xF6,"INC","zpx"),(0xF8,"SED","imp"),(0xF9,"SBC","aby"),(0xFD,"SBC","abx"),(0xFE,"INC","abx"),
])
SZ = {"imp":1,"acc":1,"imm":2,"zp":2,"zpx":2,"zpy":2,"izx":2,"izy":2,"rel":2,"abs":3,"abx":3,"aby":3,"ind":3}
BRANCH = {"BPL","BMI","BVC","BVS","BCC","BCS","BNE","BEQ"}
STOP = {"RTS","RTI","JMP","BRK"}  # unconditional end of a linear run (JMP handled specially)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("-e","--entry",action="append",default=[],help="extra entry addr (hex)")
    ap.add_argument("--org",default="A000")
    ap.add_argument("--lo",default="B300",help="code-window low (hex)")
    ap.add_argument("--hi",default="BFE0",help="code-window high (hex)")
    a = ap.parse_args()

    data = open(a.rom,"rb").read()
    org = int(a.org,16)
    lo  = int(a.lo,16)
    hi  = int(a.hi,16)
    end = org + len(data)
    def rd(addr): return data[addr-org] if org <= addr < end else None

    # entry points: game entry + IRQ continuation table + user-provided
    entries = set(int(x,16) for x in a.entry)
    # $BFE8 -> game entry
    if rd(0xBFE8) is not None:
        entries.add(rd(0xBFE8) | (rd(0xBFE9)<<8))
    entries = {e for e in entries if lo <= e < hi}

    code = set()      # addr -> True if start of an instruction
    covered = set()   # every byte that is part of an instruction
    targets = set()   # label targets
    calls = set()     # JSR targets (subroutine starts)
    bad = set()

    work = list(entries)
    targets |= entries
    while work:
        pc = work.pop()
        while True:
            if not (lo <= pc < hi):
                break
            if pc in code:
                break
            b = rd(pc)
            ent = OPS.get(b)
            if ent is None:
                bad.add(pc); break
            m, md = ent
            n = SZ[md]
            if any((pc+i) in covered for i in range(n)):
                bad.add(pc); break
            code.add(pc)
            for i in range(n): covered.add(pc+i)
            if md in ("abs","abx","aby","ind"):
                opnd = rd(pc+1) | (rd(pc+2)<<8)
            elif md == "rel":
                opnd = (pc+2 + ((rd(pc+1)^0x80)-0x80)) & 0xFFFF
            else:
                opnd = rd(pc+1)

            if m == "JSR":
                calls.add(opnd); targets.add(opnd)
                if lo <= opnd < hi: work.append(opnd)
                pc += n; continue
            if m in BRANCH:
                targets.add(opnd)
                if lo <= opnd < hi: work.append(opnd)
                pc += n; continue
            if m == "JMP":
                if md == "abs":
                    targets.add(opnd)
                    if lo <= opnd < hi: work.append(opnd)
                break  # end of linear run
            if m in ("RTS","RTI","BRK"):
                break
            pc += n

    # ---- render ----
    def lbl(addr): return f"L{addr:04X}"
    out = []
    pc = lo
    while pc < hi:
        if pc in code:
            b = rd(pc); m, md = OPS[b]; n = SZ[md]
            raw = data[pc-org:pc-org+n]
            hexs = " ".join(f"{x:02X}" for x in raw)
            if md=="imp": arg=""
            elif md=="acc": arg="A"
            elif md=="imm": arg=f"#${raw[1]:02X}"
            elif md=="zp": arg=f"${raw[1]:02X}"
            elif md=="zpx": arg=f"${raw[1]:02X},X"
            elif md=="zpy": arg=f"${raw[1]:02X},Y"
            elif md=="izx": arg=f"(${raw[1]:02X},X)"
            elif md=="izy": arg=f"(${raw[1]:02X}),Y"
            elif md=="rel":
                t=(pc+2+((raw[1]^0x80)-0x80))&0xFFFF; arg=lbl(t)
            elif md in ("abs","abx","aby","ind"):
                t=raw[1]|(raw[2]<<8)
                base=lbl(t) if (lo<=t<hi) else f"${t:04X}"
                arg={"abs":base,"abx":base+",X","aby":base+",Y","ind":f"({base})"}[md]
            tag = ""
            if pc in calls: tag = "  ; --- SUBROUTINE ---"
            if pc in targets:
                out.append(f"{lbl(pc)}:{tag}")
            out.append(f"    {pc:04X}: {hexs:11s} {m} {arg}")
            pc += n
        else:
            run_start = pc
            while pc < hi and pc not in code:
                pc += 1
            chunk = data[run_start-org:pc-org]
            out.append(f"{lbl(run_start)}:  ; DATA {len(chunk)} bytes ({run_start:04X}-{pc-1:04X})")
            for i in range(0, len(chunk), 16):
                row = chunk[i:i+16]
                hexs = " ".join(f"{x:02X}" for x in row)
                asc  = "".join(chr(x) if 32<=x<127 else "." for x in row)
                out.append(f"    {run_start+i:04X}: {hexs:<47} |{asc}|")

    print(f"; entries: {sorted(hex(e) for e in entries)}")
    print(f"; code bytes: {len(covered)}  subroutines: {len(calls)}  bad-decode points: {sorted(hex(x) for x in bad)}")
    print()
    print("\n".join(out))

if __name__ == "__main__":
    main()
