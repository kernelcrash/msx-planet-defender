;; ===========================================================================
;; src/vdp.asm — native TMS9918 (MSX VDP) layer
;;
;; Reproduces the Planet Defender VRAM layout 1:1 (docs/reverse-engineering.md
;; §2). No MSX BIOS on any path. VDP ports: $98 = data, $99 = command/status.
;; ===========================================================================

VDP_DAT         equ $98                 ; VRAM data port (r/w, auto-increment)
VDP_CMD         equ $99                 ; register / address latch (w), status (r)

;; --- VRAM table bases (identical to the Funvision; MSX VDP is the same chip) -
VRAM_NAME       equ $0400               ; R2 = $01   32x24 name table (768)
VRAM_COLOUR     equ $1400               ; R3 = $50   colour table (32)
VRAM_SPRATTR    equ $1C00               ; R5 = $38   sprite attribute table (128)
VRAM_SPRGEN     equ $2000               ; R6 = $04   sprite pattern generator (2K)
VRAM_PATBANK0   equ $3800               ; R4 = $07   pattern gen, scroll shift 0
;; shift banks: bank n base = (7-n)<<11  ->  $3800,$3000,$2800,$2000,
;;                                           $1800,$1000,$0800,$0000

;; --- pre-shift generator: raw inputs carved straight from the originals -----
;; (tools/preshift.py; docs/reverse-engineering.md §2).  The 8 pre-shifted
;; pattern banks are NOT stored in the cart — the Funvision builds them at boot.
;; This port reproduces the two boot routines and INCBINs their raw source data.
PSROM_ORG       equ $B000               ; preshift_rom.bin represents cart $B000..
BIOS_ORG        equ $F7D0               ; bios_font.bin    represents BIOS $F7D0..
PS_B1C8         equ $01C8               ; offset in preshift_rom.bin: tile-base idx
PS_B221         equ $0221               ;   left-neighbour idx table
PS_REC          equ $027A               ;   $B514 upload records (8 x 5 bytes)

;; VdpInit scratch (page-3 RAM; GameInit wipes $C000-$C3FF afterwards)
PS_SLOT         equ $C3E0
PS_OFF          equ $C3E1               ; 2 bytes
PS_BANKHI       equ $C3E3
PS_BANKACC      equ $C3E4
PS_E            equ $C0E0               ; 8-byte tile row buffer  (Funvision $E0)
PS_F            equ $C0E8               ; 8-byte neighbour buffer (Funvision $E8)

;; ---------------------------------------------------------------------------
;; The whole port runs interrupts-off (main.asm `di`, polled vblank — see
;; docs/memory-map.md "Interrupt model").  These helpers therefore must NOT
;; touch the interrupt flag: an ISR firing between the two control-port writes
;; corrupts the VDP address latch (this cost one pattern tile before the
;; di/ei pair was removed here).
;; ---------------------------------------------------------------------------
;; VdpWriteReg — C = register (0-7), A = value
;; ---------------------------------------------------------------------------
VdpWriteReg:
                out     (VDP_CMD),a
                ld      a,c
                or      $80
                out     (VDP_CMD),a
                ret

;; ---------------------------------------------------------------------------
;; VdpSetWrite — HL = VRAM address; leaves the data port ready for OUT bytes
;; VdpSetRead  — HL = VRAM address; leaves the data port ready for IN  bytes
;; ---------------------------------------------------------------------------
VdpSetWrite:
                ld      a,l
                out     (VDP_CMD),a
                ld      a,h
                or      $40
                out     (VDP_CMD),a
                ret

VdpSetRead:
                ld      a,l
                out     (VDP_CMD),a
                ld      a,h
                out     (VDP_CMD),a
                ret

;; ---------------------------------------------------------------------------
;; VdpFill — HL = VRAM addr, BC = length, A = byte
;; ---------------------------------------------------------------------------
VdpFill:
                push    af
                call    VdpSetWrite
                pop     af
VdpFill_loop:
                out     (VDP_DAT),a
                dec     bc
                ld      d,a
                ld      a,b
                or      c
                ld      a,d
                jr      nz,VdpFill_loop
                ret

;; ---------------------------------------------------------------------------
;; VdpCopy — HL = source (RAM/ROM), DE = VRAM addr, BC = length
;;           (LDIRVM-equivalent; ~29 T/byte, fine outside the hot path)
;; ---------------------------------------------------------------------------
VdpCopy:
                push    hl
                ex      de,hl
                call    VdpSetWrite            ; HL = VRAM addr
                ex      de,hl
                pop     hl
VdpCopy_loop:
                ld      a,(hl)
                out     (VDP_DAT),a
                inc     hl
                dec     bc
                ld      a,b
                or      c
                jr      nz,VdpCopy_loop
                ret

;; ---------------------------------------------------------------------------
;; VdpRunScript — HL = script pointer.  Port of BIOS $FD53 (VdpRunScript2).
;;   Script = a run of blocks { addrHi, addrLo, count, byte*count }, ended by a
;;   0 where the next addrHi would be.  Per block: latch the VDP write address
;;   (addrLo, then addrHi EOR $80 — exactly what $FE1F does: for the HUD blocks
;;   $D4->$54 = colour table $1400, $C4->$44 = name table $0400, both with the
;;   write bit set), then stream `count` data bytes.  No di/ei (DI whole run).
;; ---------------------------------------------------------------------------
VdpRunScript:
                ld      a,(hl)                  ; addrHi
                or      a
                ret     z                       ; 0 -> end of script
                xor     $80
                ld      c,a                     ; c = latch high byte
                inc     hl
                ld      a,(hl)                  ; addrLo
                out     (VDP_CMD),a
                ld      a,c
                out     (VDP_CMD),a
                inc     hl
                ld      b,(hl)                  ; count
                inc     hl
VdpRunScript_d:
                ld      a,(hl)
                out     (VDP_DAT),a
                inc     hl
                djnz    VdpRunScript_d
                jr      VdpRunScript

;; ---------------------------------------------------------------------------
;; VdpInit — set registers + load the static tables from assets/.
;;   Enters with the display OFF, returns with it ON.
;; ---------------------------------------------------------------------------
VdpInit:
                ld      hl,VdpRegs
                ld      c,0
VdpInit_regloop:
                ld      a,(hl)
                push    hl
                push    bc
                call    VdpWriteReg
                pop     bc
                pop     hl
                inc     hl
                inc     c
                ld      a,c
                cp      8
                jr      nz,VdpInit_regloop

                ;; clear all 16K of VRAM first
                ld      hl,0
                ld      bc,$4000
                xor     a
                call    VdpFill

                ;; build the 8 pre-shifted pattern banks the way the ROM does:
                ;;   $B514  HUD / font / chrome, identical in every bank
                ;;   $B547  scrolling-terrain tiles, pre-shifted 0..7 px
                call    PreShiftHudFont
                call    PreShiftTerrain

                ;; sprite pattern generator  ($2000) — refines bank 4 above the
                ;; terrain window ($22C0+); its first $2C0 bytes equal the
                ;; shift-3 terrain the generator just wrote, so order is safe.
                ld      hl,SprData
                ld      de,VRAM_SPRGEN
                ld      bc,2048
                call    VdpCopy

                ;; colour table  ($1400)
                ld      hl,ColData
                ld      de,VRAM_COLOUR
                ld      bc,32
                call    VdpCopy

                ;; turn the display on: R1 = $E2
                ld      a,$E2
                ld      c,1
                call    VdpWriteReg
                ret

;; ---------------------------------------------------------------------------
;; PreShiftHudFont — port of $B514.  For each of the 8 banks, run the 8 upload
;;   records at PS_REC ({dsthi,dstlo,srchi,srclo,ystart}, copy 256-ystart bytes).
;;   Writes the same font / digit / HUD / scanner tiles into every bank.
;;   Record order is irrelevant (disjoint dest ranges) so this goes 0..7.
;; ---------------------------------------------------------------------------
PreShiftHudFont:
                ld      a,$40                   ; bank/write-flag accumulator
                ld      (PS_BANKACC),a          ;   $40,$48,...,$78
PHF_bank:
                ld      ix,PreShiftRom + PS_REC
                ld      b,8
PHF_rec:
                push    bc
                ;; --- VRAM destination address ---
                ld      a,(PS_BANKACC)
                or      (ix+0)                  ; dsthi | bankacc
                and     $3F
                ld      h,a
                ld      l,(ix+1)                ; dstlo
                ld      a,l
                out     (VDP_CMD),a
                ld      a,h
                or      $40
                out     (VDP_CMD),a
                ;; --- source pointer into our carved blobs ---
                ld      h,(ix+2)                ; srchi
                ld      l,(ix+3)                ; srclo
                ld      a,h
                cp      $C0                     ; $B0.. = cart, $F7/$F8.. = BIOS
                jr      c,PHF_cart
                ld      de,0 - BIOS_ORG
                add     hl,de
                ld      de,BiosFont
                add     hl,de
                jr      PHF_src
PHF_cart:
                ld      de,0 - PSROM_ORG
                add     hl,de
                ld      de,PreShiftRom
                add     hl,de
PHF_src:
                ld      a,(ix+4)                ; ystart
                ld      e,a
                ld      d,0
                add     hl,de                   ; source starts at ptr + ystart
                neg                             ; A = 256 - ystart  (ystart != 0)
                ld      b,a
PHF_copy:
                ld      a,(hl)
                out     (VDP_DAT),a
                inc     hl
                djnz    PHF_copy
                ld      de,5
                add     ix,de
                pop     bc
                djnz    PHF_rec
                ld      a,(PS_BANKACC)
                add     a,8
                ld      (PS_BANKACC),a
                cp      $80
                jr      c,PHF_bank
                ret

;; ---------------------------------------------------------------------------
;; PreShiftTerrain — port of $B547.  slot = $58..0.  E = tile base pattern from
;;   PreShiftRom + 8*B1C8[slot];  F = left neighbour from + 8*B1C8[B221[slot]].
;;   8 passes: write E[0..7] to the current bank, then {E:F} <<= 1 per row and
;;   step the bank +$0800.  Banks run $0000 (7 px) .. $3800 (0 px); covers the
;;   scrolling-terrain tile range $01-$58.
;; ---------------------------------------------------------------------------
PreShiftTerrain:
                ld      a,$58
                ld      (PS_SLOT),a
PST_slot:
                ;; --- E buffer: tile's own base pattern ---
                ld      a,(PS_SLOT)
                call    PST_baseptr             ; HL -> 8 base bytes
                ld      de,PS_E
                ld      bc,8
                ldir
                ;; --- F buffer: left-neighbour pattern (via B221) ---
                ld      a,(PS_SLOT)
                ld      e,a
                ld      d,0
                ld      hl,PreShiftRom + PS_B221
                add     hl,de
                ld      a,(hl)                  ; B221[slot]
                call    PST_baseptr
                ld      de,PS_F
                ld      bc,8
                ldir
                ;; --- 8 passes ---
                ld      a,(PS_SLOT)             ; in-bank offset = slot*8
                ld      l,a
                ld      h,0
                add     hl,hl
                add     hl,hl
                add     hl,hl
                ld      (PS_OFF),hl
                xor     a
                ld      (PS_BANKHI),a           ; $00,$08,...,$38
                ld      c,8
PST_pass:
                ld      hl,(PS_OFF)
                ld      a,(PS_BANKHI)
                add     a,h
                ld      h,a
                ld      a,l
                out     (VDP_CMD),a
                ld      a,h
                or      $40
                out     (VDP_CMD),a
                ld      hl,PS_E
                ld      b,8
PST_wr:
                ld      a,(hl)
                out     (VDP_DAT),a
                inc     hl
                djnz    PST_wr
                ld      a,(PS_BANKHI)
                add     a,8
                ld      (PS_BANKHI),a
                ld      hl,PS_E
                ld      de,PS_F
                ld      b,8
PST_sh:
                ld      a,(de)                  ; F[k] <<= 1  (carry = old bit7)
                add     a,a
                ld      (de),a
                ld      a,(hl)                  ; E[k] = E[k]<<1 | carry
                adc     a,a
                ld      (hl),a
                inc     hl
                inc     de
                djnz    PST_sh
                dec     c
                jr      nz,PST_pass
                ld      a,(PS_SLOT)
                or      a
                ret     z
                dec     a
                ld      (PS_SLOT),a
                jr      PST_slot

;; PST_baseptr — A = slot / neighbour index (port of BC5D)
;;   -> HL = PreShiftRom + 8 * B1C8[A]   (8-byte base pattern)
PST_baseptr:
                ld      e,a
                ld      d,0
                ld      hl,PreShiftRom + PS_B1C8
                add     hl,de
                ld      l,(hl)                  ; B1C8[A]
                ld      h,0
                add     hl,hl
                add     hl,hl
                add     hl,hl                   ; * 8
                ld      de,PreShiftRom
                add     hl,de
                ret

;; ---------------------------------------------------------------------------
;; SetScrollShift — A = sub-tile shift 0..7  ->  R4 = (7 - A)
;;   (the per-frame smooth-scroll write; see reverse-engineering.md §2)
;; ---------------------------------------------------------------------------
SetScrollShift:
                and     $07
                ld      b,a
                ld      a,$07
                sub     b
                ld      c,4
                jp      VdpWriteReg

;; ---------------------------------------------------------------------------
;; WaitVBlank — poll the VDP status flag (bit7).  Corrupts A.
;; ---------------------------------------------------------------------------
WaitVBlank:
                in      a,(VDP_CMD)
                and     $80
                jr      z,WaitVBlank
                ret

;; ---------------------------------------------------------------------------
;; OamFlush — push the shadow OAM (zp $80..$DF, natural order) to VRAM $1C00.
;;   The original ($B4D3) writes it REVERSED: `LDA $80,X` for X=$5F..0, so the
;;   in-memory struct  {attr,pat,X,Y}  lands as hardware order  {Y,X,pat,attr}
;;   and slot 0 becomes the last sprite.  A trailing $D0 caps the sprite list.
;; ---------------------------------------------------------------------------
OamFlush:
                ld      hl,VRAM_SPRATTR
                call    VdpSetWrite
                ld      hl,$C0DF                ; zp+$DF, walk down to zp+$80
                ld      b,$60
OamFlush_l:
                ld      a,(hl)
                out     (VDP_DAT),a
                dec     hl
                djnz    OamFlush_l
                ld      a,$D0                   ; sprite-list terminator
                out     (VDP_DAT),a
                ret

;; ---------------------------------------------------------------------------
;; register file — R0..R7 (docs/reverse-engineering.md §2)
;;   R1 starts $A2 (display off); VdpInit flips it to $E2 at the end.
;; ---------------------------------------------------------------------------
VdpRegs:
                db      $00             ; R0  Mode 1, no EXT
                db      $A2             ; R1  16K, display OFF, IRQ on, 16x16 spr
                db      $01             ; R2  name table   $0400
                db      $50             ; R3  colour table $1400
                db      $07             ; R4  pattern gen  $3800 (shift 0)
                db      $38             ; R5  sprite attr  $1C00
                db      $04             ; R6  sprite gen   $2000
                db      $01             ; R7  fg 0 / backdrop 1 (black)

;; ---------------------------------------------------------------------------
;; embedded assets
;;   preshift_rom.bin / bios_font.bin — raw ROM/BIOS inputs to the boot
;;     pre-shift routines (tools/preshift.py).  Label = the byte the original
;;     addresses as PSROM_ORG / BIOS_ORG respectively.
;;   sprite_patterns.bin / colour_table.bin — carved from ground-truth VRAM
;;     (tools/extract_assets.py); revisited in Phase 4d / 4f.
;; ---------------------------------------------------------------------------
PreShiftRom:    incbin  "assets/preshift_rom.bin"      ; 674  (cart $B000-$B2A1)
BiosFont:       incbin  "assets/bios_font.bin"         ; 496  (BIOS $F7D0-$F9BF)
SprData:        incbin  "assets/sprite_patterns.bin"   ; 2048
ColData:        incbin  "assets/colour_table.bin"      ; 32
TerrainMap:     incbin  "assets/terrain_map.bin"       ; 536  (cart $A000-$A217)
