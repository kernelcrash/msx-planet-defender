;; ===========================================================================
;; src/enemies.asm — enemy spawn / drift / weave / project / fire  (Phase 4d)
;;
;; Faithful Z80 port of the enemy-update phase $B730-$B916 of the Funvision
;; FrameUpdate (docs/reverse-engineering.md §7).  One AI, 8 stride-4 slots;
;; the three cosmetic "types" differ only by slot group (X mod 12 -> 0/4/8).
;;
;; Validated byte-exact vs the real ROM over 279 frames of live play by
;; tools/enemy_model.py + tools/enemy_model_check.py (0 mismatches); this file
;; is a direct hand-translation of that model.  1-player hardcoded (CURPLR = 0)
;; like the rest of the port, so $55,X / $54,X collapse to SPAWNTHROTTLE /
;; SCROLLFLOOR.
;;
;; Per-slot pointers rebuilt each iteration by EnPtrs (X = slot*4 = $00..$1C):
;;   ix = zp + $80 + X   ->  (ix+0)col (ix+1)pat (ix+2)screenX (ix+3)screenY
;;                           (ix+$20..$23) enemy-bullet record ($A0..$A3,X)
;;                           (ix+$60)wXlo (ix+$61)wXhi (ix+$62)wYlo (ix+$63)wYhi
;;   iy = zp + $300 + X  ->  (iy+0)speed (iy+$20)state (iy+$40)weaveCtr
;;                           (iy+$41)weavePhase (iy+$42)animTimer
;; ===========================================================================

;; scratch in the free page-3 window $0390-$03BF (BIOS clears $03C0-$03DF for the
;; live hi-score $03C0/$03D0; $0300-$038F is obj state + death debris).
EN_D04          equ $C390       ; drift base = max(0, SCROLLSPD - SCROLLFLOOR)
EN_GATE         equ $C391       ; per-frame enemy-fire gate ($08 in the original)
EN_X            equ $C392       ; current slot X ($00..$1C)

;; weave step tables — the ROM overlaps X and Y (bases 2 bytes apart), and the
;; carved blob keeps that layout (assets/enemy_tables.bin).
WX_LO_T         equ WeaveTab + 0
WY_LO_T         equ WeaveTab + 2
WX_HI_T         equ WeaveTab + 10
WY_HI_T         equ WeaveTab + 12

;; ---------------------------------------------------------------------------
EnemyUpdate:
                call    EnSpawn
                call    EnDriftBase
                call    EnDrift
                call    EnWeave
                call    EnProject
                call    EnTickFire
                ret

;; --- ix/iy := per-slot pointers for slot X in A ; A untouched (callers
;;     decrement it and re-enter).  Clobbers BC, HL.
EnPtrs:
                ld      (EN_X),a
                ld      c,a
                ld      b,0
                ld      hl,zp+$80
                add     hl,bc
                push    hl
                pop     ix
                ld      hl,zp+$300
                add     hl,bc
                push    hl
                pop     iy
                ret

;; ---------------------------------------------------------------------------
;; Spawn ($B730-$B78B) — gated by (SPAWNTHROTTLE & FRAMECTR) and ($1A & RNGhi).
;; ---------------------------------------------------------------------------
EnSpawn:
                ld      a,(SPAWNTHROTTLE)
                ld      hl,FRAMECTR
                and     (hl)
                ret     nz                     ; throttle gate closed this frame
                ld      a,(RNG+1)
                and     $1A
                ret     nz                     ; LFSR gate closed

                ld      a,$1C                  ; find a free slot (state == 0)
ESp_find:
                call    EnPtrs
                ld      a,(iy+$20)
                or      a
                jr      z,ESp_got
                ld      a,(EN_X)
                sub     4
                jr      nc,ESp_find
                ret                            ; no free slot

ESp_got:
                ld      a,(RNG)                ; RNGlo -> c (kept through spawn)
                ld      c,a

                and     $1F                    ; weaveCtr = (RNGlo & $1F) + $20
                add     a,$20
                ld      (iy+$40),a

                ld      a,c                    ; weavePhase = RNGlo & 7
                and     $07
                ld      (iy+$41),a

                ld      a,c                    ; wYhi = (RNGlo>>1) + $40 + (RNGlo&1)
                srl     a                      ;   C = RNGlo bit0
                adc     a,$40                  ;   ... + $40 + C  (never carries: max $C0)
                ld      (ix+$63),a

                and     $07                    ; speed = (wYhi & 7) + $10
                add     a,$10                  ;   (6502 ADC here would leak C from the
                ld      (iy+$00),a             ;    ADC #$40 above; provably always 0)

                ld      (iy+$02),0             ; OBJSPD+2 / +3 pad = 0
                ld      (iy+$03),0

                ld      a,c                    ; wXhi: side chosen by RNGlo bit7
                bit     7,a
                jr      z,ESp_r
                or      $E0                    ; ($C0|RNGlo)|$20  ==  RNGlo|$E0
                jr      ESp_sx
ESp_r:
                and     $1F
                or      $20
ESp_sx:
                ld      (ix+$61),a
                ld      (iy+$20),$FF           ; state = active
                ret

;; ---------------------------------------------------------------------------
;; Drift base ($B78C) — EN_D04 = max(0, SCROLLSPD - SCROLLFLOOR)
;; ---------------------------------------------------------------------------
EnDriftBase:
                ld      a,(SCROLLSPD)
                ld      hl,SCROLLFLOOR
                sub     (hl)
                jr      nc,EDB_st
                xor     a
EDB_st:
                ld      (EN_D04),a
                ret

;; ---------------------------------------------------------------------------
;; Horizontal homing drift ($B79D right / $B7CA left) — all 8 slots.
;;   BB73 delta = EN_D04 + speed  (unsigned 16-bit)
;;   BB82 delta = EN_D04 - speed  (sign-extended: hi = $FF on borrow)
;;   right ($B7B6): worldX += delta      left ($B7E3): worldX -= delta
;; ---------------------------------------------------------------------------
EnDrift:
                ld      a,$1C
ED_loop:
                call    EnPtrs

                ld      a,(FACING)
                bit     7,a
                jr      nz,ED_left

;; facing right: BB73 if bit7(wXhi); BB82 if (wXhi & $E0); else screenX < PLRX
                bit     7,(ix+$61)
                jr      nz,ED_bb73
                ld      a,(ix+$61)
                and     $E0
                jr      nz,ED_bb82
                ld      a,(ix+2)
                ld      hl,PLRX
                cp      (hl)
                jr      c,ED_bb73              ; screenX < PLRX -> BB73
                jr      ED_bb82

;; facing left: BB82 if bit7(wXhi); BB73 if (wXhi & $E0); else screenX >= PLRX
ED_left:
                bit     7,(ix+$61)
                jr      nz,ED_bb82
                ld      a,(ix+$61)
                and     $E0
                jr      nz,ED_bb73
                ld      a,(ix+2)
                ld      hl,PLRX
                cp      (hl)
                jr      nc,ED_bb73             ; screenX >= PLRX -> BB73
                ;; else fall through to BB82

ED_bb82:
                ld      a,(EN_D04)
                sub     (iy+$00)               ; a = D04 - speed, C = borrow
                ld      c,a
                sbc     a,a                     ; a = $FF if borrow else $00
                ld      b,a
                jr      ED_apply
ED_bb73:
                ld      a,(EN_D04)
                add     a,(iy+$00)              ; a = D04 + speed
                ld      c,a
                ld      a,0
                adc     a,0
                ld      b,a

ED_apply:
                ld      l,(ix+$60)             ; hl = worldX
                ld      h,(ix+$61)
                ld      a,(FACING)
                bit     7,a
                jr      nz,ED_neg
                add     hl,bc                  ; right: worldX += delta
                jr      ED_st
ED_neg:
                or      a
                sbc     hl,bc                  ; left:  worldX -= delta
ED_st:
                ld      (ix+$60),l
                ld      (ix+$61),h

                ld      a,(EN_X)
                sub     4
                jr      nc,ED_loop
                ret

;; ---------------------------------------------------------------------------
;; Weave ($B7F5-$B849) — all 8 slots.  weaveCtr--, reload + re-pick phase on 0;
;;   worldX += WXstep[phase] ; worldY += WYstep[phase] ; band-clamp Yhi [$03,$16).
;; ---------------------------------------------------------------------------
EnWeave:
                ld      a,$1C
EW_loop:
                call    EnPtrs

                dec     (iy+$40)
                jr      nz,EW_phase
                ld      a,(RNG+1)              ; reload = (RNGhi & $1F) + $20
                and     $1F
                add     a,$20
                ld      (iy+$40),a
                ld      a,(RNG)                ; phase = RNGlo & 7
                and     $07
                ld      (iy+$41),a
EW_phase:
                ld      a,(iy+$41)             ; de = phase index (0..7), d = 0
                ld      e,a
                ld      d,0

                ld      hl,WX_LO_T             ; worldX += WXstep[phase]
                add     hl,de
                ld      c,(hl)
                ld      hl,WX_HI_T
                add     hl,de
                ld      b,(hl)
                ld      l,(ix+$60)
                ld      h,(ix+$61)
                add     hl,bc
                ld      (ix+$60),l
                ld      (ix+$61),h

                ld      hl,WY_LO_T             ; worldY += WYstep[phase]
                add     hl,de
                ld      c,(hl)                 ; c = WYstep lo  (fetch both table
                ld      hl,WY_HI_T             ;   bytes first: `add hl,de` below
                add     hl,de                  ;   would clobber the carry that must
                ld      b,(hl)                 ;   flow from the lo add into the hi)
                ld      a,c
                add     a,(ix+$62)
                ld      (ix+$62),a
                ld      a,b
                adc     a,(ix+$63)
                and     $1F                    ; band clamp into [$03,$16)
                cp      $03
                jr      nc,EW_hichk
                ld      (ix+$62),0
                ld      a,$03
                jr      EW_sety
EW_hichk:
                cp      $16
                jr      c,EW_sety
                ld      (ix+$62),$FF
                ld      a,$15
EW_sety:
                ld      (ix+$63),a

                ld      a,(EN_X)
                sub     4
                jr      nc,EW_loop
                ret

;; ---------------------------------------------------------------------------
;; Project to sprite ($B84B-$B8B6) — visible active slots only.
;; ---------------------------------------------------------------------------
EnProject:
                ld      a,(PLRY)               ; $6C = PLRY + $0C ; $6D = PLRY - $0C
                add     a,$0C
                ld      (YBANDLO),a
                ld      a,(PLRY)
                sub     $0C
                ld      (YBANDHI),a

                ld      a,$1C
EP_loop:
                call    EnPtrs

                dec     (iy+$42)               ; anim timer
                jr      nz,EP_state
                ld      (iy+$42),$17
EP_state:
                ld      a,(iy+$20)             ; state
                or      a
                jr      nz,EP_notfree
                ld      (ix+3),$E0             ; free -> hide
                jr      EP_next
EP_notfree:
                bit     7,a
                jr      z,EP_next              ; 1-$7F (spawn countdown) -> skip
                ld      a,(ix+$61)             ; off the visible strip?
                and     $E0
                jr      z,EP_vis
                ld      (ix+3),$E0
                jr      EP_next
EP_vis:
                ld      l,(ix+$60)             ; screenX = (worldX << 3) >> 8
                ld      h,(ix+$61)
                add     hl,hl
                add     hl,hl
                add     hl,hl
                ld      (ix+2),h

                ld      a,(EN_X)               ; g = X mod 12  -> {0,4,8}
EP_gmod:
                sub     $0C
                jr      nc,EP_gmod
                add     a,$0C
                ld      e,a                    ; e = g (colour-table index)
                add     a,a                    ; s04 = (g << 2) | $80
                add     a,a
                or      $80
                ld      c,a

                ld      a,(iy+$42)             ; pat = ((animT >> 1) & $0C) | s04
                srl     a
                and     $0C
                or      c
                ld      (ix+1),a

                ld      d,0                    ; col = Be00Tab[g]
                ld      hl,Be00Tab
                add     hl,de
                ld      a,(hl)
                ld      (ix+0),a

                ld      l,(ix+$62)             ; screenY = (worldY << 3) >> 8
                ld      h,(ix+$63)
                add     hl,hl
                add     hl,hl
                add     hl,hl
                ld      a,h
                cp      $C0                    ; hide if >= $C0
                jr      c,EP_sety
                ld      a,$E0
EP_sety:
                ld      (ix+3),a
EP_next:
                ld      a,(EN_X)
                sub     4
                jr      nc,EP_loop
                ret

;; ---------------------------------------------------------------------------
;; Tick + fire ($B8BD-$B916).  FLIP4A toggles $0F<->$F0 ; EN_GATE = FLIP4A ;
;; per active on-screen slot LSR EN_GATE -> C gates the bullet Y (else $E0).
;; Bullet attrs and the off-left-edge despawn run regardless of C.  Enemy
;; bullets are never advanced elsewhere (set-and-forget in the original).
;; ---------------------------------------------------------------------------
EnTickFire:
                ld      a,(FLIP4A)
                cpl
                ld      (FLIP4A),a
                ld      (EN_GATE),a

                ld      a,$1C
ETF_loop:
                call    EnPtrs

                ld      a,(iy+$20)             ; state
                or      a
                jr      nz,ETF_ns
                ld      (ix+$23),$E0           ; free -> bullet hidden
                jr      ETF_next
ETF_ns:
                bit     7,a
                jr      nz,ETF_active
                dec     a                      ; 1-$7F -> countdown
                ld      (iy+$20),a
                jr      ETF_next
ETF_active:
                ld      l,(ix+$62)             ; enemy screenY = (worldY << 3) >> 8
                ld      h,(ix+$63)
                add     hl,hl
                add     hl,hl
                add     hl,hl
                ld      a,h
                cp      $C0
                jr      c,ETF_on
                ld      (ix+$23),$E0           ; below the strip -> free slot
                ld      (iy+$20),0
                jr      ETF_next
ETF_on:
                ld      b,h                    ; b = screenY (kept for >> 4)
                ld      hl,EN_GATE
                srl     (hl)                   ; C = old bit0 ; EN_GATE >>= 1
                jr      c,ETF_show
                ld      (ix+$23),$E0
                jr      ETF_edge
ETF_show:
                ld      a,b                    ; bullet Y = screenY >> 4
                rrca
                rrca
                rrca
                rrca
                and     $0F
                ld      (ix+$23),a
ETF_edge:
                ld      a,(ix+$61)             ; (wXhi + $80) & $E0 == 0 -> despawn
                add     a,$80
                ld      c,a
                and     $E0
                jr      nz,ETF_bul
                ld      (ix+$23),$E0
                ld      (iy+$20),0
                jr      ETF_next
ETF_bul:
                ld      a,c                    ; bullet X = ((wXhi+$80) >> 1) + $38
                srl     a
                add     a,$38
                ld      (ix+$22),a
                ld      (ix+$20),$0F           ; bullet col
                ld      (ix+$21),$DC           ; bullet pat
ETF_next:
                ld      a,(EN_X)
                sub     4
                jr      nc,ETF_loop
                ret

;; ---------------------------------------------------------------------------
;; Data — raw from PlanetDefender.rom $BDE2-$BE08 (assets/enemy_tables.bin, 39 B)
;;   WeaveTab+0  WX lo [8]   +2  WY lo [8]   +10  WX hi [8]   +12  WY hi [8]
;;   Be00Tab = WeaveTab+30 : group colour, indexed by g -> [0]=$02 [4]=$04 [8]=$06
;; ---------------------------------------------------------------------------
WeaveTab:       incbin  "assets/enemy_tables.bin"
Be00Tab         equ     WeaveTab + 30
