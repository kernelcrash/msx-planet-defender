;; ===========================================================================
;; src/death.asm — collisions + scoring + player death / respawn  (Phase 4e)
;;
;; Faithful Z80 port of the collision phase $B9CF-$BA98, AddScore $BB91/$BB93,
;; PlayerDeath $BA9B and the $68/$69 death-explosion / spawn-in FSM $BABC
;; (docs/reverse-engineering.md §5.2 + §7a).
;;
;; Runs at the tail of GameFrame, after PlayerShot (which already did the
;; $B9B1 shot-step preamble as part of travel/retire).  Loop 2 ($BA2F, the
;; vestigial secondary $C0-$C3 shots vs the tile band) is not ported — those
;; slots are never populated (see the 4c notes).
;; ===========================================================================

SFXGND          equ zp+$22      ; ground-hit SFX id
SFXTICK         equ zp+$23      ; repeating-tick SFX id (set by PlayerDeath)
SFXTICKD        equ zp+$24      ; ...its divider
SFXMISC         equ zp+$25      ; misc SFX id (shot-kill noise)

HISCOREHI       equ $C3C0       ; live hi-score, indexed by GAMECFG nibble
HISCORELO       equ $C3D0
DEBRIS          equ $C380       ; $0380-$0389 death-debris offset scratch

;; shared data blob (assets/enemy_tables.bin via WeaveTab in enemies.asm):
CollTab         equ WeaveTab + 27   ; $BDFD: stride-4 {dy-hi, dy-lo, score-BCD}, Y in {0,4,8}
DeathLim        equ WeaveTab + 19   ; $BDF5: $69 phase limits, X = $68  (00 70 20 10)
DebrisAttr      equ WeaveTab + 23   ; $BDF9: debris OAM colour, X = $68  (0F 02 04 06)

;; ---------------------------------------------------------------------------
;; Collisions — loop 1 (shot vs enemies) then loop 3 (enemies vs ship).
;; ---------------------------------------------------------------------------
Collisions:
                ld      a,(SHOTY)
                cp      $C0
                jr      nc,CL_loop3            ; no live shot -> straight to loop 3

                ld      a,$1C
CL1_loop:
                call    EnPtrs
                ld      a,(iy+$20)
                bit     7,a
                jr      z,CL1_next             ; only fully-active ($FF) enemies

                ld      a,(ix+1)               ; class Y = ($81 & $30) >> 2  -> {0,4,8}
                and     $30
                srl     a
                srl     a
                ld      e,a
                ld      d,0

                ld      a,(ix+3)               ; dy = enemyScreenY - shotY
                ld      hl,SHOTY
                sub     (hl)
                jr      c,CL1_next             ; dy < 0
                ld      hl,CollTab
                add     hl,de
                cp      (hl)                   ; dy >= hi  -> miss
                jr      nc,CL1_next
                inc     hl
                cp      (hl)                   ; dy < lo   -> miss
                jr      c,CL1_next

                ld      a,(FACING)             ; dx: shot ahead of enemy in facing dir
                bit     7,a
                jr      nz,CL1_left
                ld      a,(SHOTX)              ; facing right: dx = shotX - enemyX
                sub     (ix+2)
                jr      CL1_dxchk
CL1_left:
                ld      a,(ix+2)               ; facing left:  dx = enemyX - shotX
                ld      hl,SHOTX
                sub     (hl)
CL1_dxchk:
                jr      c,CL1_next             ; dx < 0
                cp      $10
                jr      nc,CL1_next            ; dx >= $10

;; --- hit ($BA0D) ---
                ld      a,(ix+1)
                or      $0C
                ld      (ix+1),a               ; explosion pattern bits
                xor     a
                ld      (SFXEXPL),a            ; $20 = 0
                ld      a,$1F
                ld      (SFXMISC),a            ; $25 = $1F
                ld      a,$E4
                call    SnWrite               ; $BA1B: ch3 white-noise burst
                ld      (iy+$20),$7F           ; enemy dying
                ld      hl,CollTab+2           ; score = CollTab[Y+2]
                add     hl,de
                ld      a,(hl)
                call    AddScore
                ld      a,$E0
                ld      (SHOTY),a              ; retire the shot
                jr      CL_loop3               ; shot consumed
CL1_next:
                ld      a,(EN_X)
                sub     4
                jr      nc,CL1_loop

;; ---------------------------------------------------------------------------
CL_loop3:
                ld      a,$1C
CL3_loop:
                call    EnPtrs
                ld      a,(iy+$20)
                bit     7,a
                jr      z,CL3_next

                ld      a,(ix+3)               ; enemy screenY
                cp      $C0
                jr      nc,CL3_next            ; hidden
                ld      hl,PLRY                ; dy = enemyY - PLRY - 1  (carry set by cp)
                sbc     a,(hl)
                jr      c,CL3_dyneg
                cp      $05
                jr      nc,CL3_next            ; dy >= +5
                jr      CL3_dxtest
CL3_dyneg:
                cp      $FA
                jr      c,CL3_next             ; dy < -6
CL3_dxtest:
                ld      a,(ix+2)               ; dx = enemyX - PLRX
                ld      hl,PLRX
                sub     (hl)
                jr      c,CL3_dxneg
                cp      $0C
                jr      nc,CL3_next            ; dx >= +$0C
                jr      CL3_hit
CL3_dxneg:
                cp      $F3
                jr      c,CL3_next             ; dx < -$0D
CL3_hit:
                call    PlayerDeath
                ret
CL3_next:
                ld      a,(EN_X)
                sub     4
                jr      nc,CL3_loop
                ret

;; ---------------------------------------------------------------------------
;; AddScore ($BB93) — a = BCD points; 16-bit BCD add into SCORE, then refresh
;; the live hi-score at HISCOREHI/LO[GAMECFG & $0F].
;; ---------------------------------------------------------------------------
AddScore:
                ld      hl,SCORE
                add     a,(hl)
                daa
                ld      (hl),a
                inc     hl
                ld      a,(hl)
                adc     a,0
                daa
                ld      (hl),a

                ld      a,(GAMECFG)
                and     $0F
                ld      e,a
                ld      d,0
                ld      a,(SCORE+1)
                ld      hl,HISCOREHI
                add     hl,de
                cp      (hl)
                jr      c,AS_done              ; scoreHi < hiHi
                jr      nz,AS_update           ; scoreHi > hiHi
                ld      a,(SCORE)
                ld      hl,HISCORELO
                add     hl,de
                cp      (hl)
                jr      c,AS_done
AS_update:
                ld      a,(SCORE+1)
                ld      hl,HISCOREHI
                add     hl,de
                ld      (hl),a
                ld      a,(SCORE)
                ld      hl,HISCORELO
                add     hl,de
                ld      (hl),a
AS_done:
                ret

;; ---------------------------------------------------------------------------
;; PlayerDeath ($BA9B) — arm the death FSM, snapshot ship pos, clear the field.
;; Falls into DeathRespawnFSM.
;; ---------------------------------------------------------------------------
PlayerDeath:
                ld      a,$E4
                call    SnWrite               ; $BA9B: ch3 white-noise burst
                ld      a,$0A
                ld      (SFXTICK),a
                ld      a,$01
                ld      (SFXTICKD),a
                ld      (PHASECT),a            ; $69 = 1
                ld      a,$03
                ld      (PLRPHASE),a           ; $68 = 3
                ld      a,(PLRY)
                ld      (PLRALT),a             ; $47
                ld      a,(PLRX)
                ld      (PLRWORLDX),a          ; $46
                call    ParkSprites            ; $BD83
                call    ClearObjStates         ; $BD8F
                ;; fall through

;; ---------------------------------------------------------------------------
;; DeathRespawnFSM ($BABC) — the $68/$69 state machine.  Called every frame
;; while PLRPHASE != $FF.  Lays out the debris cross into sprite slots 0-7.
;; ---------------------------------------------------------------------------
DeathRespawnFSM:
                ld      a,(PLRPHASE)
                or      a
                jr      nz,DR_explode

;; --- spawn-in ($68 == 0): $69 counts down $7F -> 0, then go alive ---
                ld      hl,PHASECT
                dec     (hl)
                jr      z,DR_goalive
                ld      a,(PHASECT)
                jr      DR_layout
DR_goalive:
                ld      hl,PLRPHASE
                dec     (hl)                   ; $68 -> $FF (alive)
                jp      DR_reinit

;; --- explosion ($68 = 1..3): $69 counts up to DeathLim[$68] ---
DR_explode:
                ld      hl,PHASECT
                inc     (hl)
                ld      a,(PLRPHASE)
                ld      e,a
                ld      d,0
                ld      hl,DeathLim
                add     hl,de
                ld      a,(PHASECT)
                cp      (hl)
                jr      c,DR_layout            ; $69 < limit -> keep exploding (a = $69)

                ld      hl,PLRPHASE
                dec     (hl)                   ; advance phase
                ld      a,(PLRPHASE)
                or      a
                jr      z,DR_phase0
                xor     a                      ; $68 still 1..2 -> restart $69 at 0
                jr      DR_layout
DR_phase0:
                ld      hl,STATE
                set     2,(hl)                 ; death done -> respawn next frame
                ld      a,(PHASECT)
                or      a
                jr      nz,DR_layout
                xor     a

;; --- debris layout ($BAE5-$BB61): p in a ---
DR_layout:
                ld      (PHASECT),a
                ld      (DEBRIS+0),a
                ld      (DEBRIS+3),a
                ld      (DEBRIS+8),a
                add     a,a                    ; 2p
                ld      (DEBRIS+1),a
                ld      (DEBRIS+2),a
                ld      (DEBRIS+9),a
                ld      a,(PHASECT)
                neg                            ; -p
                ld      (DEBRIS+4),a
                ld      (DEBRIS+7),a
                add     a,a                    ; -2p
                ld      (DEBRIS+5),a
                ld      (DEBRIS+6),a

                ld      a,$1C                  ; sprite slot X, with Y index in b
                ld      b,7
DR_row:
                push    bc                     ; EnPtrs clobbers B (the Y index)
                call    EnPtrs                 ; ix = zp+$80+X ; stores EN_X
                pop     bc

                ld      hl,DEBRIS              ; sprite Y = PLRALT + DEBRIS[Y]
                ld      d,0
                ld      e,b
                add     hl,de
                ld      a,(PLRALT)
                add     a,(hl)
                ld      (ix+3),a

                cp      $C0
                jr      nc,DR_hide
                ld      hl,PLRALT
                cp      (hl)
                jr      nc,DR_yge              ; A >= alt
                ld      a,b                    ; A < alt
                cp      $04
                jr      nc,DR_xcoord           ;   Y >= 4 -> compute X
                jr      DR_hide                ;   Y < 4  -> hide
DR_yge:
                ld      a,b
                cp      $04
                jr      nc,DR_hide             ; A >= alt, Y >= 4 -> hide
DR_xcoord:
                ld      hl,DEBRIS+2            ; sprite X = PLRWORLDX + DEBRIS[Y+2]
                ld      d,0
                ld      e,b
                add     hl,de
                ld      a,(PLRWORLDX)
                add     a,(hl)
                ld      (ix+2),a
                jr      c,DR_xcarry
                ld      a,b                    ; no wrap
                cp      $02
                jr      c,DR_keep             ;   Y < 2  -> keep
                cp      $06
                jr      nc,DR_keep            ;   Y >= 6 -> keep
                jr      DR_hide              ;   2 <= Y < 6 -> hide
DR_xcarry:
                ld      a,b                    ; wrapped
                cp      $02
                jr      c,DR_hide            ;   Y < 2  -> hide
                cp      $06
                jr      c,DR_keep            ;   2 <= Y < 6 -> keep
                jr      DR_hide             ;   Y >= 6 -> hide
DR_hide:
                ld      (ix+3),$E0
DR_keep:
                ld      a,(PLRPHASE)           ; colour = DebrisAttr[$68], pattern $BC
                ld      e,a
                ld      d,0
                ld      hl,DebrisAttr
                add     hl,de
                ld      a,(hl)
                ld      (ix+0),a
                ld      (ix+1),$BC

                ld      a,(EN_X)
                sub     4
                dec     b
                jp      p,DR_row
                ret

;; --- ($BB63) spawn-in complete: restore ship + scanner, clear enemies ---
DR_reinit:
                ld      hl,ScannerInit
                ld      de,PLR
                ld      bc,8
                ldir
                call    ClearObjStates
                ret
