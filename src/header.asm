;; ---------------------------------------------------------------------------
;; Planet Defender (MSX port) — 16KB cartridge header
;; Cartridge is mapped at $4000-$7FFF (MSX pages 1-2).
;; ---------------------------------------------------------------------------

ROM_BASE        equ $4000
ROM_SIZE        equ $4000               ; exactly 16384 bytes

;; --- MSX BIOS entry points used (smoke test / bring-up only) ---------------
BIOS_CHGMOD     equ $005F               ; A = screen mode
BIOS_CHPUT      equ $00A2               ; A = char
BIOS_CHGCLR     equ $0062               ; set colours from FORCLR/BAKCLR/BDRCLR
BIOS_LDIRVM     equ $005C               ; HL->DE, BC bytes  (RAM -> VRAM)
BIOS_FILVRM     equ $0056               ; fill VRAM: HL addr, BC len, A byte
BIOS_WRTVDP     equ $0047               ; B = value, C = register
BIOS_WRTPSG     equ $0093               ; A = reg, E = data
BIOS_GTSTCK     equ $00D5               ; A = stick# -> A direction
BIOS_GTTRIG     equ $00D8               ; A = trigger# -> A ($FF/$00)

;; --- MSX system work area ------------------------------------------------
FORCLR          equ $F3E9
BAKCLR          equ $F3EA
BDRCLR          equ $F3EB

                org ROM_BASE

                db  "AB"                ; cartridge signature
                dw  Init                ; INIT   — entry point
                dw  0                   ; STATEMENT
                dw  0                   ; DEVICE
                dw  0                   ; TEXT (BASIC program)
                db  0,0,0,0,0,0         ; reserved
