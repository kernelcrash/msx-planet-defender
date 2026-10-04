;; ===========================================================================
;; src/input.asm — MSX keyboard -> Funvision decoded-input vars (Phase 5)
;;
;; Native PPI keyboard-matrix scan, no MSX BIOS.  Reproduces the part of the
;; Funvision BIOS $FA00 decode (docs/reverse-engineering.md §7b) that this game
;; actually consumes: the P1 direction index $11, the start byte $12/$14, and
;; the fire new-press edge $16.  P2 ($13/$17), the raw columns ($18-$1B) and the
;; fire-line status byte ($15) are not consumed by the port and are left 0.
;;
;;   C-BIOS_MSX1_EU has no joystick ports (PSG R14 reads nothing), so the port
;;   is keyboard-only:
;;
;;     cursor keys   -> KEYDEC  ($11) = $80 | idx
;;                        UP $89   DOWN $81   LEFT $8D   RIGHT $85
;;                        (idx bit2 = LEFT/RIGHT, bit3 = UP-or-LEFT; matches the
;;                         $FBB2 table entries the player handler tests)
;;     SPACE         -> FIREDEC ($16) = $0C on the press edge, else $00
;;     SPACE / RETURN-> STARTK  ($12) = $FF while held   (STARTK2 $14 = 0)
;;
;;   MSX keyboard matrix (select row in PPI port $AA bits 0-3, read port $A9;
;;   a matrix bit reads 0 while its key is down):
;;     row 7 : bit7 RETURN
;;     row 8 : bit7 RIGHT  bit6 DOWN  bit5 UP  bit4 LEFT   bit0 SPACE
;; ===========================================================================

FIREPREV        equ $C3F0      ; previous SPACE level (RAM scratch, for the edge)

ReadInput:
                ;; --- row 8: cursor keys + SPACE ------------------------------
                ld      c,8
                call    KbdRow
                cpl                             ; a: 1 = key down
                ld      e,a

                xor     a                       ; KEYDEC default = no direction
                bit     4,e
                jr      nz,RI_left
                bit     7,e
                jr      nz,RI_right
                bit     5,e
                jr      nz,RI_up
                bit     6,e
                jr      z,RI_dirset
                ld      a,$81                   ; DOWN
                jr      RI_dirset
RI_left:
                ld      a,$8D
                jr      RI_dirset
RI_right:
                ld      a,$85
                jr      RI_dirset
RI_up:
                ld      a,$89
RI_dirset:
                ld      (KEYDEC),a

                ;; --- fire level = SPACE (row 8 bit0) -----------------------
                ld      a,e
                and     $01
                ld      d,a                     ; d = fire level (0 / 1)

                ;; --- start level = SPACE | RETURN -------------------------
                ld      c,7
                call    KbdRow
                cpl
                and     $80                     ; RETURN
                or      d                       ; | SPACE
                neg                             ; 0 -> 0 / NC ; nonzero -> C
                sbc     a,a                     ; -> $00 released / $FF held
                ld      (STARTK),a
                xor     a
                ld      (STARTK2),a

                ;; --- fire new-press edge -> FIREDEC ($16) -----------------
                ld      hl,FIREPREV
                ld      a,(hl)
                cpl
                and     d                       ; a = fire & ~prev  (0 / 1)
                ld      (hl),d                  ; prev = current level
                or      a
                jr      z,RI_f0
                ld      a,$0C                   ; new-press edge (b3:b2 per §7b)
RI_f0:
                ld      (FIREDEC),a

                di                              ; keep interrupts off — the port
                ret                             ; polls vblank (see port-status)

;; ---------------------------------------------------------------------------
;; KbdRow — C = matrix row 0-10; returns A = raw PPI $A9 read for that row
;;   (a bit is 0 while its key is held).  Preserves PPI port-C bits 4-7
;;   (CAPS lamp / cassette / keyclick).
;; ---------------------------------------------------------------------------
KbdRow:
                in      a,($AA)
                and     $F0
                or      c
                out     ($AA),a
                in      a,($A9)
                ret
