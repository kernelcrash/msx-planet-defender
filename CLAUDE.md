Port Planet Defender for the Funvision to MSX
- Planet Defender is a Defender like game for the Funvision video console
- The Funvision used a 6502A, a 9918/9929 VDP and a 76489 sound chip.
- The Funvision had a 2KB boot rom, and cartridges were of various sizes. Planet Defender is 8KB.
- I want to port the Planet Defender game to MSX. So this requires a conversion from 6502 to Z80 assembly. The VDP chip is the same. The Sound chip is slightly different.
- The Planet Defender ROM image is in funvision-reference/PlanetDefender.rom. The Funvision 2KB BIOS is in funvision-reference/FunvisionBIOS.rom. There is no intent to prort the FunvisionBIOS. It is purely for reference. There is a reference emulator in funnymu-0.44. It contains a technical document that may be useful funvision-reference/funnymu-0.44/funvision-tech.txt
- Use pasmo for assembling Z80 code.
- Use a standard 16KB cartridge format for MSX
- Use openmsx for testing.
- Break this up in to phases

