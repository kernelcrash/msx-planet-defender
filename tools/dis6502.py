import sys

# minimal 6502 disassembler
opc = {}
def d(o,m,md): opc[o]=(m,md)
# addressing: imp, imm, zp, zpx, zpy, abs, abx, aby, ind, izx, izy, rel, acc
T=[
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
(0xF0,"BEQ","rel"),(0xF1,"SBC","izy"),(0xF5,"SBC","zpx"),(0xF6,"DEC","zpx"),(0xF8,"SED","imp"),(0xF9,"SBC","aby"),(0xFD,"SBC","abx"),(0xFE,"INC","abx"),
]
for o,m,md in T: d(o,m,md)
sz={"imp":1,"acc":1,"imm":2,"zp":2,"zpx":2,"zpy":2,"izx":2,"izy":2,"rel":2,"abs":3,"abx":3,"aby":3,"ind":3}

data=open(sys.argv[1],'rb').read()
org=int(sys.argv[2],16)
start=int(sys.argv[3],16) if len(sys.argv)>3 else org
end=int(sys.argv[4],16) if len(sys.argv)>4 else org+len(data)
pc=start
while pc<end:
    b=data[pc-org]
    if b not in opc:
        print(f"{pc:04X}: {b:02X}          .byte ${b:02X}"); pc+=1; continue
    m,md=opc[b]; n=sz[md]
    raw=data[pc-org:pc-org+n]
    if len(raw)<n:
        print(f"{pc:04X}: {b:02X}          .byte ${b:02X}  ; (truncated at EOF)"); pc+=1; continue
    hexs=" ".join(f"{x:02X}" for x in raw)
    if md=="imp": arg=""
    elif md=="acc": arg="A"
    elif md=="imm": arg=f"#${raw[1]:02X}"
    elif md in ("zp",): arg=f"${raw[1]:02X}"
    elif md=="zpx": arg=f"${raw[1]:02X},X"
    elif md=="zpy": arg=f"${raw[1]:02X},Y"
    elif md=="izx": arg=f"(${raw[1]:02X},X)"
    elif md=="izy": arg=f"(${raw[1]:02X}),Y"
    elif md=="rel":
        tgt=pc+2+((raw[1]^0x80)-0x80); arg=f"${tgt:04X}"
    elif md=="abs":
        a=raw[1]|(raw[2]<<8); arg=f"${a:04X}"
    elif md=="abx":
        a=raw[1]|(raw[2]<<8); arg=f"${a:04X},X"
    elif md=="aby":
        a=raw[1]|(raw[2]<<8); arg=f"${a:04X},Y"
    elif md=="ind":
        a=raw[1]|(raw[2]<<8); arg=f"(${a:04X})"
    print(f"{pc:04X}: {hexs:12s} {m} {arg}")
    pc+=n
