;; ===========================================================================
;; src/game.asm — core game logic (Phase 4a)
;;
;; Faithful Z80 re-implementation of the Planet Defender frame update
;; (docs/reverse-engineering.md §5.2 / §7 / §7b / §7c).  The Funvision zero page
;; is mirrored 1:1 at `zp` ($C000) so the RE addresses map straight across.
;;
;; Phase 4a scope: RAM model, RNG, InitGame/InitPlayer, the player-control
;; handler ($B65B-$B6FE), the difficulty-ramp state machine ($B6FF-$B72F),
;; primary-shot spawn+travel, and the reversed shadow-OAM flush.  A game session
;; is forced active at boot; the ship is immediately alive and controllable.
;;
;; Deferred: world-scroll terrain redraw + shifted banks (4b), enemies (4d),
;; the 3 collision loops + death/respawn FSM (4e), HUD meter + sound (4f).
;; ===========================================================================

;; --- zero-page mirror -----------------------------------------------------
zp              equ $C000

RNG             equ zp+$02      ; 16-bit LFSR (lo:hi)
GAMECFG         equ zp+$0D      ; difficulty nibble (bit1 floor init, bit2 cooldown)
KEYDEC          equ zp+$11      ; decoded P1 direction ($FBB2 index | $80)
STARTK          equ zp+$12      ; start / leave-title trigger (nonzero = pressed)
STARTK2         equ zp+$14
FIREDEC         equ zp+$16      ; fire: bits 2-3 = new-press edge
SFXEXPL         equ zp+$20      ; explosion / fire SFX id
SCROLLSPD       equ zp+$42      ; world scroll velocity [0,$A0]
FACING          equ zp+$43      ; $01 = right, $FF = left
SCROLLACC       equ zp+$44      ; 16-bit scroll accumulator (lo:hi $44/$45)
PLRWORLDX       equ zp+$46
PLRALT          equ zp+$47
FIRECD          equ zp+$48
FRAMECTR        equ zp+$49
FLIP4A          equ zp+$4A
ATTRACTCT       equ zp+$4B
STATE           equ zp+$4C      ; bit6 session active, bit2 death done, bit7 attract,
                                ; bit1 = game-over banner pending (port-only)
FIRECDRELOAD    equ zp+$4D
CURPLR          equ zp+$4E
LRLATCH         equ zp+$4F      ; bit7 = thrust-reverse latch
SCORE           equ zp+$50      ; 16-bit BCD (lo:hi)
RAMPSTATE       equ zp+$52
RAMPTIMER       equ zp+$53
SCROLLFLOOR     equ zp+$54
SPAWNTHROTTLE   equ zp+$55
LIVES           equ zp+$56
PLRPHASE        equ zp+$68      ; $FF alive, $00 spawning, $01-$03 death
PHASECT         equ zp+$69
SHOTFACING      equ zp+$6A
YBANDLO         equ zp+$6C
YBANDHI         equ zp+$6D

OAM             equ zp+$80      ; shadow OAM, natural order, $80..$DF (24 sprites)
SHOT            equ zp+$D4      ; primary shot: attr,pattern,screenX,screenY
SHOTX           equ zp+$D6
SHOTY           equ zp+$D7
PLR             equ zp+$D8      ; player+scanner sprites: $D8..$DF
PLRCOL          equ zp+$D8
PLRPAT          equ zp+$D9
PLRX            equ zp+$DA
PLRY            equ zp+$DB
SCANCOL         equ zp+$DC
SCANPAT         equ zp+$DD
SCANX           equ zp+$DE
SCANY           equ zp+$DF

OBJSPD          equ zp+$300
OBJSTATE        equ zp+$320
OBJANIM         equ zp+$340

DT_COL40        equ $C3E8       ; DrawTerrain: visible-column window start ($40)
DT_COL41        equ $C3E9       ;              wrap column ($41) — MUST follow COL40
DT_OUTER        equ $C3EA       ;              outer row counter
DT_COUNTA       equ $C3EB       ;              main-block run-A length (before wrap)
DT_COUNTB       equ $C3EC       ;              main-block run-B length (after wrap)

;; ---------------------------------------------------------------------------
;; GameInit — one-time setup.  Leaves the machine on the title screen
;; (STATE bit6 clear); StartSession runs when the player presses start.
;; ---------------------------------------------------------------------------
GameInit:
                ld      hl,$C000                ; wipe the whole zp / page-0-3 mirror
                ld      de,$C001
                ld      bc,$03FF
                ld      (hl),0
                ldir

                ld      hl,$A55A                ; seed the LFSR (must be nonzero)
                ld      (RNG),hl
                xor     a
                ld      (GAMECFG),a             ; easy / 1-player

                call    InitGame                ; $BD23 — score/lives/ramp reset
                call    ParkSprites
                call    ClearObjStates
                ret                             ; STATE = 0 (wiped) -> title

;; ---------------------------------------------------------------------------
;; StartSession — begin a game session: per-session + per-life reset, set
;; STATE bit6.  Called from the title screen when start ($12|$14) is pressed
;; ($B5DD: sets bit6, ParkSprites, DrawTerrain, PlaySfx(0) — note it does NOT
;; un-park the ship).  The $68/$69 FSM then runs the spawn-in with every sprite
;; still parked; DeathRespawnFSM/DR_reinit ($BB63) un-parks the ship + scanner
;; only when the converging debris reaches the centre ($69 -> 0).
;; ---------------------------------------------------------------------------
StartSession:
                call    InitGame
                call    InitPlayer
                call    ParkSprites
                call    ClearObjStates

                ld      a,$40                   ; STATE bit6 = session active
                ld      (STATE),a
                ret

;; $BE09 scanner/player reinit block (see §7a): reversed = 2 sprites
;;   $DF..$DC = {Y $80, X $81, pat $C0, col $06}   scanner blip
;;   $DB..$D8 = {Y $80, X $78, pat $D0, col $02}   player ship
ScannerInit:    db      $02,$D0,$78,$80, $06,$C0,$81,$80

;; ---------------------------------------------------------------------------
;; InitGame ($BD23) — per-session reset (player 0 only; P2 slot is vestigial)
;; ---------------------------------------------------------------------------
InitGame:
                xor     a
                ld      (SCORE),a
                ld      (SCORE+1),a
                ld      (RAMPSTATE),a
                ld      (RAMPTIMER),a
                ld      (CURPLR),a
                ld      a,$07
                ld      (SPAWNTHROTTLE),a       ; %111
                ld      a,(GAMECFG)
                bit     1,a
                ld      a,$40
                jr      z,IG_floor
                ld      a,$80
IG_floor:
                ld      (SCROLLFLOOR),a
                ld      a,$03
                ld      (LIVES),a
                ld      a,(GAMECFG)
                bit     2,a
                ld      a,$04
                jr      z,IG_cd
                ld      a,$02
IG_cd:
                ld      (FIRECDRELOAD),a
                ret

;; ---------------------------------------------------------------------------
;; InitPlayer ($BD60) — per-life reset
;; ---------------------------------------------------------------------------
InitPlayer:
                ld      a,$01
                ld      (FACING),a
                xor     a
                ld      (FRAMECTR),a
                ld      (SCROLLACC),a
                ld      (PLRPHASE),a            ; $00 spawn-in (overridden in 4a)
                ld      a,$20
                ld      (SCROLLSPD),a
                ld      a,$5F
                ld      (SCROLLACC+1),a
                ld      a,$80
                ld      (PLRWORLDX),a
                ld      (PLRALT),a
                ld      a,$0F
                ld      (FLIP4A),a
                ld      a,$7F
                ld      (PHASECT),a
                ret

;; ---------------------------------------------------------------------------
;; ParkSprites ($BD83) — Y byte of all 24 shadow sprites = $E0 (off-screen)
;; ---------------------------------------------------------------------------
ParkSprites:
                ld      hl,OAM+3
                ld      b,24
                ld      a,$E0
PSp_l:
                ld      (hl),a
                inc     hl
                inc     hl
                inc     hl
                inc     hl
                djnz    PSp_l
                ret

;; ---------------------------------------------------------------------------
;; ClearObjStates ($BD8F) — free all 8 enemy slots
;; ---------------------------------------------------------------------------
ClearObjStates:
                ld      hl,OBJSTATE
                ld      b,8
                xor     a
COS_l:
                ld      (hl),a
                inc     hl
                inc     hl
                inc     hl
                inc     hl
                djnz    COS_l
                ret

;; ---------------------------------------------------------------------------
;; StepRng ($FF58) — 16-bit LFSR, one bit per frame
;;   feedback = bit6(hi) XOR bit5(hi);  {ROL lo, ROL hi} with C = feedback
;; ---------------------------------------------------------------------------
StepRng:
                ld      a,(RNG+1)
                and     $60                     ; isolate bits 6,5
                jp      pe,SR_fb0               ; even parity (0 or 2 bits) -> fb 0
                scf                             ; odd parity (exactly 1) -> fb 1
                jr      SR_roll
SR_fb0:
                or      a                       ; clear carry
SR_roll:
                ld      a,(RNG)
                rla
                ld      (RNG),a
                ld      a,(RNG+1)
                rla
                ld      (RNG+1),a
                ret

;; ---------------------------------------------------------------------------
;; GameFrame — one frame of game logic (Phase 4a subset of §5.2 FrameUpdate)
;; ---------------------------------------------------------------------------
GameFrame:
                ;; WorldScroll now runs at the top of the main loop (before
                ;; DrawTerrain), matching the original's $B5B5 frame order.

                ;; STATE bit6 clear -> title screen ($B5CB dispatch)
                ld      a,(STATE)
                bit     6,a
                jp      z,GF_title

                call    SoundTick               ; $B62A: per-frame SFX mixer

                ;; scanner sprite pattern ($B4BC): (($43&8)^$C8) | ($49&4)
                ld      a,(FACING)
                and     $08
                xor     $C8
                ld      b,a
                ld      a,(FRAMECTR)
                and     $04
                or      b
                ld      (SCANPAT),a

                ;; player-state dispatch on $68 (§5.2 $B62D)
                ld      a,(PLRPHASE)
                bit     7,a
                jr      nz,GF_alive             ; $FF -> normal player control
                or      a
                jr      nz,GF_fsm               ; 1..3 -> death-explosion FSM
                ld      a,(STATE)
                bit     2,a
                jr      z,GF_fsm                ; $68=0, no bit2 -> spawn-in FSM
                ;; $68=0 + bit2 -> respawn ($B639): lose a life, keep playing
                ld      a,3
                call    PlaySfx                 ; $B63B: respawn jingle (id 3)
                call    InitPlayer
                ld      hl,STATE
                res     2,(hl)
                ld      hl,LIVES
                dec     (hl)
                jr      z,GF_gameover
                jr      GF_ramp
GF_fsm:
                call    DeathRespawnFSM
                ret
GF_alive:
                call    PlayerControl
GF_ramp:
                call    RampUpdate
                call    EnemyUpdate
                call    PlayerShot
                call    Collisions
                ret
;; GF_gameover ($B60F-$B624) — lives exhausted.  DrawHUD already ran this frame
;; (main loop).  Draw the "GAME OVER" banner, then clear STATE bits 6+0 so the
;; next frame is the title screen.  STATE bit1 = "banner pending" so GF_title
;; keeps redrawing it (unlike the original, whose title path never touches the
;; name table; the port still redraws rows 0-2 in DrawHUD but no longer rows
;; 12-23 — see ML_nofield — so only the banked row-12 banner needs refresh).
GF_gameover:
                call    ParkSprites             ; clear the last debris / ship
                call    DrawGameOver
                ld      a,6
                call    PlaySfx                 ; $B61B: game-over jingle (id 6)
                ld      hl,STATE
                set     1,(hl)                  ; banner pending
                res     6,(hl)                  ; $B61E: leave the session
                res     0,(hl)
                ret

;; " GAME OVER " (11 tiles) at name $058A — script $BFB1.
DrawGameOver:
                ld      hl,GameOverScr
                jp      VdpRunScript

;; ---------------------------------------------------------------------------
;; GF_title — title-screen frame ($B5CB-$B5EE, 1-player, no attract).
;;   $BD23 (InitGame) runs every frame, as in the original.  The world is held
;;   static by ML_nofield (main loop skips WorldScroll/DrawTerrain while bit6 is
;;   clear, matching $B5B5 — the title path never calls $B400/$B431).  If a
;;   game just ended (STATE bit1) the banner is repainted over the frozen
;;   field.  Press start ($12|$14) -> StartSession sets bit6 (clearing bit1) +
;;   inits the player; the next frame's DrawTerrain wipes the banner ($B5E6).
;;   Deferred: the $FE83 attract score cycler and the $BCF2 attract-timeout
;;   demo (need Phase 5 input + Phase 6 sound).
;; ---------------------------------------------------------------------------
GF_title:
                call    InitGame

                ld      a,(STATE)
                bit     1,a
                call    nz,DrawGameOver         ; keep the banner up

                ld      a,(STARTK)              ; $12 | $14 — start / leave title
                ld      hl,STARTK2
                or      (hl)
                ret     z                       ; not pressed -> stay on title
                call    StartSession            ; $B5DD: bit6 set, session begins
                ld      a,0
                call    PlaySfx                 ; $B5EB: game-start jingle (id 0)
                ret

;; ---------------------------------------------------------------------------
;; WorldScroll ($B400-$B42F) — advance the 16-bit scroll accumulator.
;;   In the original this falls straight into DrawTerrain ($B431); here the two
;;   are split and GameFrame calls DrawTerrain right after.
;; ---------------------------------------------------------------------------
WorldScroll:
                ld      hl,FRAMECTR
                inc     (hl)
                ld      a,(FACING)
                bit     7,a
                jr      nz,WS_neg
                ld      a,(SCROLLACC)           ; positive: acc += spd
                ld      hl,SCROLLSPD
                add     a,(hl)
                ld      (SCROLLACC),a
                ld      a,(SCROLLACC+1)
                adc     a,0
                jr      WS_store
WS_neg:
                ld      a,(SCROLLACC)           ; negative: acc -= spd
                ld      hl,SCROLLSPD
                sub     (hl)
                ld      (SCROLLACC),a
                ld      a,(SCROLLACC+1)
                sbc     a,0
WS_store:
                ld      (SCROLLACC+1),a
                and     $60
                xor     $60
                ret     nz                      ; not at a wrap boundary
                ld      a,(FACING)
                bit     7,a
                ld      a,$1F
                jr      z,WS_mask
                ld      a,$5F
WS_mask:
                ld      hl,SCROLLACC+1
                and     (hl)
                ld      (SCROLLACC+1),a
                ret

;; ---------------------------------------------------------------------------
;; DrawTerrain ($B431-$B4BB), split for a clean double-buffer:
;;
;;   Called from the main loop right after WaitVBlank (with WorldScroll), so every
;;   VRAM write lands at the top of the frame — the raster does not reach terrain
;;   row 12 (scanline 96) again until ~14 ms later, long after this returns, so
;;   there is no tearing even though the writes are not gated to vblank proper.
;;
;;   Name-table content is a pure function of $45:
;;     $40 = $45 & $3F                   visible-column window start
;;     $41 = (($45 & $40) >> 1) | $1F    column-wrap point
;;   Each of the 12 rows emits 32 cells, the column index counting down from $40
;;   and wrapping to $41 once it passes 0.  The main block splits that into two
;;   straight descending runs (lengths COUNTA / COUNTB); the strip keeps a
;;   per-cell test because its non-zero span is only cols $24-$29.  Sources in
;;   assets/terrain_map.bin:
;;     rows 12-15  top strip   src +$200, stride 6, only cols $24-$29 non-zero
;;     rows 16-23  main ground src +$000, stride $40
;;   R4 = 7 - (($44 >> 5) & 7)   (the 0-7px sub-tile shift; changes every frame).
;; ---------------------------------------------------------------------------
DrawTerrain:
                ld      a,(SCROLLACC+1)         ; $45
                and     $3F
                ld      (DT_COL40),a
                inc     a                       ; COUNTA = min($40 + 1, 32)
                cp      33
                jr      c,DT_ca
                ld      a,32
DT_ca:
                ld      (DT_COUNTA),a
                ld      b,a
                ld      a,32
                sub     b
                ld      (DT_COUNTB),a           ; COUNTB = 32 - COUNTA

                ld      a,(SCROLLACC+1)
                and     $40
                rrca                            ; >>1  (bit6 -> bit5)
                or      $1F
                ld      (DT_COL41),a

                ld      hl,VRAM_NAME + $180     ; rows 12-23  ($0580)
                call    VdpSetWrite

                ;; --- top strip: 4 rows x 32, src +$200 stride 6 -------------
                ld      de,TerrainMap + $200
                ld      a,4
                ld      (DT_OUTER),a
DT_strip_row:
                ld      a,(DT_COL40)
                ld      c,a                     ; c = column index
                ld      b,32
DT_strip_col:
                ld      a,c
                sub     $24
                cp      6
                jr      nc,DT_strip_zero        ; col outside [$24,$29] -> tile 0
                ld      l,a
                ld      h,0
                add     hl,de
                ld      a,(hl)
                out     (VDP_DAT),a
                jr      DT_strip_adv
DT_strip_zero:
                xor     a
                out     (VDP_DAT),a
DT_strip_adv:
                dec     c
                jp      p,DT_strip_next         ; c hit $FF -> wrap to $41
                ld      a,(DT_COL41)
                ld      c,a
DT_strip_next:
                djnz    DT_strip_col
                ld      hl,6
                add     hl,de
                ex      de,hl
                ld      a,(DT_OUTER)
                dec     a
                ld      (DT_OUTER),a
                jr      nz,DT_strip_row

                ;; --- main terrain: 8 rows x 32, src +$000 stride $40 -------
                ld      de,TerrainMap
                ld      a,8
                ld      (DT_OUTER),a
DT_main_row:
                ld      a,(DT_COL40)            ; run A: COUNTA cells from +COL40 down
                ld      l,a
                ld      h,0
                add     hl,de
                ld      a,(DT_COUNTA)
                ld      b,a
DT_main_rA:
                ld      a,(hl)
                out     (VDP_DAT),a
                dec     hl
                djnz    DT_main_rA
                ld      a,(DT_COUNTB)           ; run B: COUNTB cells from +COL41 down
                or      a
                jr      z,DT_main_re
                ld      b,a
                ld      a,(DT_COL41)
                ld      l,a
                ld      h,0
                add     hl,de
DT_main_rB:
                ld      a,(hl)
                out     (VDP_DAT),a
                dec     hl
                djnz    DT_main_rB
DT_main_re:
                ld      hl,$40
                add     hl,de
                ex      de,hl
                ld      a,(DT_OUTER)
                dec     a
                ld      (DT_OUTER),a
                jr      nz,DT_main_row

                ;; --- R4 = 7 - (($44 >> 5) & 7) : sub-tile pixel shift ------
                ld      a,(SCROLLACC)
                rrca
                rrca
                rrca
                rrca
                rrca
                and     $07
                xor     $07
                ld      c,4
                jp      VdpWriteReg

;; ---------------------------------------------------------------------------
;; PlayerControl ($B65B-$B6FE) — read KEYDEC, update altitude / scroll velocity
;;   / facing / world-X / scanner echo.  Player 0 only.
;; ---------------------------------------------------------------------------
PlayerControl:
                ld      a,(KEYDEC)
                or      a
                jp      z,PC_coast
                ld      c,a                     ; c = direction index
                and     $03
                xor     $03
                jp      z,PC_coast              ; diagonal / idx&3==3 -> coast
                bit     2,c
                jp      nz,PC_lr
                bit     3,c
                jr      nz,PC_up
;; --- DOWN ($B675): increase screen-Y, clamp $AC ---
                ld      a,(PLRY)
                cp      $AC
                jr      nc,PC_worldx
                inc     a
                jr      PC_setalt
;; --- UP ($B67F): decrease screen-Y, clamp $1C ---
PC_up:
                ld      a,(PLRY)
                cp      $1C
                jr      c,PC_worldx
                dec     a
PC_setalt:
                ld      (PLRY),a
                ld      (SCANY),a
                jr      PC_worldx

;; --- LEFT / RIGHT ($B68E): thrust / reverse on the scroll velocity ---
PC_lr:
                ld      a,(LRLATCH)
                bit     7,a
                jp      nz,PC_coast
                ld      hl,FIRECD
                dec     (hl)
                jp      p,PC_worldx             ; cooldown still running
                bit     3,c                     ; LEFT (idx $0D) vs RIGHT (idx $05)
                jr      nz,PC_left
;; RIGHT ($B69B)
                ld      a,(SCROLLSPD)
                ld      hl,FACING
                bit     7,(hl)
                jr      z,PC_dec42              ; facing right -> decelerate/reverse
                jr      PC_inc42
;; LEFT ($B6A3)
PC_left:
                ld      a,(SCROLLSPD)
                ld      hl,FACING
                bit     7,(hl)
                jr      z,PC_inc42             ; facing right -> accelerate
;; --- decrease $42 by $20, flip facing at 0 ($B6BC) ---
PC_dec42:
                sub     $20
                jr      nz,PC_store42
                ld      a,(FACING)
                xor     $FE
                ld      (FACING),a
                ld      a,$FF
                ld      (LRLATCH),a
                jr      PC_reload48
;; --- increase $42 by $20, cap $A0 ($B6D0) ---
PC_inc42:
                add     a,$20
                cp      $A0
                jr      z,PC_reload48          ; would hit cap -> don't store
PC_store42:
                ld      (SCROLLSPD),a
PC_reload48:
                ld      a,(FIRECDRELOAD)
                ld      (FIRECD),a
                jr      PC_worldx

;; --- coast ($B6AB): tick cooldown, settle $42 toward the scroll floor ---
PC_coast:
                ld      hl,FIRECD
                dec     (hl)
                jp      p,PC_worldx
                ld      a,(SCROLLSPD)
                ld      hl,SCROLLFLOOR
                cp      (hl)
                jr      c,PC_inc42             ; below floor -> raise
                jr      z,PC_clrlatch          ; at floor -> release latch
                jp      PC_dec42               ; above floor -> lower
PC_clrlatch:
                xor     a
                ld      (LRLATCH),a
                jr      PC_reload48

;; --- world-X drift ($B6DD): ship eases toward the facing edge, scanner echo ---
PC_worldx:
                ld      a,(PLRX)
                ld      hl,FACING
                bit     7,(hl)
                jr      z,PC_wx_right
                dec     a                       ; facing left
                cp      $30
                jr      c,PC_wx_done
                ld      (PLRX),a
                sub     $0B
                ld      (SCANX),a
                jr      PC_wx_done
PC_wx_right:
                inc     a
                cp      $C0
                jr      nc,PC_wx_done
                ld      (PLRX),a
                add     a,$0B
                ld      (SCANX),a
PC_wx_done:
                ret

;; ---------------------------------------------------------------------------
;; RampUpdate ($B6FF-$B72F) — difficulty-ramp state machine (§7c).  Player 0.
;; ---------------------------------------------------------------------------
RampUpdate:
                ld      a,(RAMPSTATE)
                ld      b,a
                or      a
                jr      nz,RU_nz
                ld      hl,RAMPTIMER            ; state 0: count the timer down
                dec     (hl)
                jr      z,RU_advance
                ret
RU_nz:
                ld      a,(SCORE)
                and     $F0
                jr      nz,RU_clrtimer         ; score tens nonzero: stall (faithful)
                ld      a,(RAMPTIMER)
                or      a
                ret     z
                ld      a,b
                cp      $06
                jr      nz,RU_advance
                ld      a,(SCROLLFLOOR)         ; state 6: raise the auto-scroll floor
                add     a,$20
                cp      $A0
                jr      nc,RU_zeroS
                ld      (SCROLLFLOOR),a
RU_zeroS:
                ld      b,0
RU_advance:
                ld      a,b
                add     a,2
                ld      (RAMPSTATE),a
                ld      hl,SPAWNTHROTTLE
                srl     (hl)
                xor     a
RU_clrtimer:
                ld      (RAMPTIMER),a
                ret

;; ---------------------------------------------------------------------------
;; PlayerShot — spawn on the fire edge ($B918-$B94F) + travel/retire ($B9B1+)
;; ---------------------------------------------------------------------------
PlayerShot:
                ld      a,(FIREDEC)
                and     $0C
                jr      z,PS_travel
                ld      a,$0E
                ld      (SFXEXPL),a
                ld      a,(FACING)
                bit     7,a
                ld      a,(PLRX)
                jr      z,PS_right
                sub     $10                     ; left: PLRX - $10 ...
                jr      nz,PS_setx              ; ... unless that hits 0 ($B931)
PS_right:
                add     a,$20                   ; right (or the =0 edge): PLRX + $20
PS_setx:
                ld      (SHOTX),a
                ld      a,(FACING)
                ld      (SHOTFACING),a
                ld      a,(PLRY)
                sub     $08
                ld      (SHOTY),a
                ld      a,$D4
                ld      (SHOT+1),a              ; pattern
                ld      a,(FACING)
                and     $80
                xor     $8F
                ld      (SHOT),a                ; attr / colour
PS_travel:
                ld      a,(SHOTY)
                cp      $C0
                ret     nc                      ; no live shot
                ld      a,(SHOTX)
                ld      hl,SHOTFACING
                bit     7,(hl)
                jr      nz,PS_left_mv
                sub     $10                     ; $6A positive -> step -$10 (faithful)
                jr      c,PS_offscreen
                jr      PS_ok
PS_left_mv:
                add     a,$10                   ; $6A negative -> step +$10
                jr      c,PS_offscreen
PS_ok:
                ld      (SHOTX),a
                ret
PS_offscreen:
                ld      a,$E0
                ld      (SHOTY),a
                ret

;; ---------------------------------------------------------------------------
;; DrawHUD — ramp meter / labels / score / hi-score / lives, native (no BIOS).
;; Phase 4f slices 1-2.
;;
;;   Reimplements the per-frame HUD paint the original splits across $BBFA
;;   (DrawHUD) and $BBBF (DrawScore, called from the OAM-flush tail $B4E2):
;;     - ramp meter ($BBFA head): run the VDP script ($BE11[y],$BE12[y]),
;;       y = RAMPSTATE ($52) = 0/2/4/6.  y=0/4 -> $A440 (restore the default
;;       colour table), y=2 -> $BE19, y=6 -> $BE29 — each rewrites colour-table
;;       entries 0-11 so pattern groups 7-10 (the meter cells) change hue as
;;       difficulty climbs.  Blocks carved to assets/hud_scripts.bin.
;;     - labels (1-player branch of $BBFA): $BFC0 blanks name $0403-$0405,
;;       $BFDE redraws the "HIGH" label at $0418-$041B.  (The 2-player 1UP/2UP
;;       blink paths are not reachable — GAMECFG bit0 is 0.)
;;     - P1 BCD score -> name $0443, live hi-score -> $0458.  Five digit tiles
;;       each: the two BCD bytes split hi-then-lo nibble + a trailing literal 0
;;       (score is always x10).
;;     - lives icons ($BC46): four tiles at $0423 — ship glyph $7E per life,
;;       $00 padding after.
;;
;;   Digit tile = digit + $E0 (glyphs $E0-$E9 loaded by PreShiftHudFont in
;;   Phase 4b); ship-icon tile = $7E.  Name/colour-table bases are identical to
;;   the Funvision, so the RE VRAM offsets map straight across.  Called from the
;;   main loop right after OamFlush.
;; ---------------------------------------------------------------------------
DrawHUD:
                ld      a,(RAMPSTATE)          ; ramp meter: y = $52 (0/2/4/6)
                ld      l,a
                ld      h,0
                ld      de,RampScrTab
                add     hl,de
                ld      a,(hl)
                inc     hl
                ld      h,(hl)
                ld      l,a                    ; hl = script pointer
                call    VdpRunScript

                ld      hl,HudLblClr           ; $BFC0 — blank $0403-$0405
                call    VdpRunScript
                ld      hl,HudLblHigh          ; $BFDE — "HIGH" at $0418-$041B
                call    VdpRunScript

                ld      hl,VRAM_NAME + $43      ; P1 score -> row 2, col 3
                call    VdpSetWrite
                ld      a,(SCORE+1)             ; BCD high byte
                call    DH_pair
                ld      a,(SCORE)               ; BCD low byte
                call    DH_pair
                ld      a,$E0                   ; trailing 0
                out     (VDP_DAT),a

                ld      hl,VRAM_NAME + $58      ; hi-score -> row 2, col $18
                call    VdpSetWrite
                ld      a,(HISCOREHI)           ; index 0 (GAMECFG & $0F = 0)
                call    DH_pair
                ld      a,(HISCORELO)
                call    DH_pair
                ld      a,$E0
                out     (VDP_DAT),a

                ;; lives icons ($BC46) -> row 1, col 3
                ld      hl,VRAM_NAME + $23
                call    VdpSetWrite
                ld      a,(LIVES)
                ld      b,4
DH_lloop:
                dec     a
                ld      c,$7E                  ; life remaining -> ship glyph
                jp      p,DH_lwr
                ld      c,$00                  ; exhausted -> blank
DH_lwr:
                push    af
                ld      a,c
                out     (VDP_DAT),a
                pop     af
                djnz    DH_lloop
                ret

;; A = BCD byte -> emit hi-nibble digit tile then lo-nibble digit tile.
DH_pair:
                push    af
                rrca
                rrca
                rrca
                rrca
                and     $0F
                add     a,$E0
                out     (VDP_DAT),a
                pop     af
                and     $0F
                add     a,$E0
                out     (VDP_DAT),a
                ret

;; ---------------------------------------------------------------------------
;; HUD VDP-script blobs — raw from PlanetDefender.rom (tools/carve_hud_scripts.py,
;; assets/hud_scripts.bin, 82 B).  Layout: $A440 ramp-default (20) | $BE19
;; ramp-2 (16) | $BE29 ramp-6 (16) | $BFC0 label-clear (7) | $BFDE "HIGH" (8) |
;; $BFB1 "GAME OVER" (15).
;; ---------------------------------------------------------------------------
HudScripts:     incbin  "assets/hud_scripts.bin"
RampScrDflt     equ     HudScripts + 0         ; $A440  (RAMPSTATE 0 and 4)
RampScrLo       equ     HudScripts + 20        ; $BE19  (RAMPSTATE 2)
RampScrHi       equ     HudScripts + 36        ; $BE29  (RAMPSTATE 6)
HudLblClr       equ     HudScripts + 52        ; $BFC0
HudLblHigh      equ     HudScripts + 59        ; $BFDE
GameOverScr     equ     HudScripts + 67        ; $BFB1  (name $058A, row 12 col 10)

RampScrTab:     dw      RampScrDflt, RampScrLo, RampScrDflt, RampScrHi
