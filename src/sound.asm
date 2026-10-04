;; ===========================================================================
;; src/sound.asm — Phase 6 sound: SN76489 -> AY-3-8910 (PSG)
;;
;; The Funvision drives an SN76489 by writing raw command bytes through BIOS
;; $FE77.  Planet Defender uses two drivers on top of that primitive:
;;   * $BC83 SoundDispatch — per-frame in-game SFX mixer (fire / explosion /
;;     death rumble / spawn-in warp / shot-kill noise)          -> SoundTick
;;   * $FBD6 PlaySfx(id)    — blocking 3-voice jingle player
;;     (id 0 game-start, id 3 respawn, id 6 game-over)           -> PlaySfx
;;
;; This file ports both, verbatim data blobs carved from the ROMs
;; (assets/sound_sfx.bin, assets/sound_jingle.bin), plus SnWrite: an
;; SN76489-command -> PSG-register translator.
;;
;; SN clock = 6502 phi-2 = 2 MHz (Funvision circuit diagram).  AY clock =
;; 1.789 MHz.  Tone-period conversion  n_ay = n_sn * (2*F_ay / F_sn) ~= 1.79
;; -> implemented as n_ay = (n_sn * 57) >> 5  (1.781, -0.5 %, < 1/10 semitone).
;; Attenuation: SN 4-bit (0 loud .. 15 off) -> AY amp = 15 - att.
;; Noise (SN ch3, always white / rate 0 in this game) -> AY noise on channel C.
;; ===========================================================================

;; --- PSG ports ----------------------------------------------------------
PSG_ADDR        equ $A0
PSG_DATA        equ $A1

;; --- RAM scratch (page $C3, clear of the zp mirror + input/HUD scratch) --
SND_WS          equ $C3A0
snReg           equ SND_WS+0    ; last-latched SN register 0..7
snPer           equ SND_WS+1    ; ch0/1/2 tone period, 2 bytes LE  (+1 / +3 / +5)
snAtt           equ SND_WS+7    ; ch0/1/2/noise attenuation 0..15  (+7..+10)
snR7            equ SND_WS+11   ; AY mixer (R7) shadow
snLow           equ SND_WS+12   ; scratch: 4-bit field from a latch byte
snCh            equ SND_WS+13   ; scratch: channel 0..3
cpTmp           equ SND_WS+14   ; ConvPeriod scratch (word)
cpAcc           equ SND_WS+16   ; ConvPeriod scratch (word)
J_SEQ           equ SND_WS+18   ; jingle: sequence base ptr (word)
J_ENVP          equ SND_WS+20   ; jingle: envelope-table ptr (word)
J_DUR           equ SND_WS+22   ; jingle: per-voice note-duration countdown (3)
J_ENV           equ SND_WS+25   ; jingle: per-voice envelope index (3)
J_TEMPO         equ SND_WS+28   ; jingle: tempo byte
J_CUR           equ SND_WS+29   ; jingle: sequence cursor (the 6502 Y)
J_VOICE         equ SND_WS+30   ; jingle: current voice 0..2
J_PFX           equ SND_WS+31   ; jingle: SN channel latch prefix

;; Tempo busy-wait inner count — tuned so the id-0 jingle runs ~1 tick / 10 ms
;; (the 2 MHz 6502 loop is ~tempo*256*4 cycles; 1 tick ~= 0.5 PAL frame).
JD_INNER        equ 172

;; ---------------------------------------------------------------------------
;; SoundInit — silence the PSG, set the mixer.  Call once at boot.
;; ---------------------------------------------------------------------------
SoundInit:
                xor     a
                ld      (snReg),a
                ld      hl,snPer
                ld      b,10
SI_z:           ld      (hl),0
                inc     hl
                djnz    SI_z
                ld      a,15
                ld      (snAtt),a
                ld      (snAtt+1),a
                ld      (snAtt+2),a
                ld      (snAtt+3),a
                ld      a,$B8                   ; portB out / portA in,
                ld      (snR7),a                ;   noise off A/B/C, tone on A/B/C
                ld      c,7
                ld      e,a
                call    AyReg
                ld      c,6                     ; noise period = 1
                ld      e,1
                call    AyReg
                ld      c,8                     ; amps A/B/C = 0
                ld      e,0
                call    AyReg
                ld      c,9
                call    AyReg
                ld      c,10
                call    AyReg
                ret

;; ---------------------------------------------------------------------------
;; AyReg — c = register, e = value.  Clobbers A.
;; ---------------------------------------------------------------------------
AyReg:
                ld      a,c
                out     (PSG_ADDR),a
                ld      a,e
                out     (PSG_DATA),a
                ret

;; ---------------------------------------------------------------------------
;; AddAToHL — hl += a (unsigned).  Clobbers A.
;; ---------------------------------------------------------------------------
AddAToHL:
                add     a,l
                ld      l,a
                ld      a,0
                adc     a,h
                ld      h,a
                ret

;; ---------------------------------------------------------------------------
;; ConvPeriod — hl = SN period (0..1023) -> hl = AY period, clamped [1,4095].
;;   n_ay = (n_sn * 57) >> 5      (57 = 32 + 16 + 8 + 1)
;; ---------------------------------------------------------------------------
ConvPeriod:
                ld      a,h
                or      l
                jr      nz,CP_nz
                ld      hl,1
CP_nz:
                ld      (cpTmp),hl              ; n
                add     hl,hl                   ; 2n
                add     hl,hl                   ; 4n
                add     hl,hl                   ; 8n
                ld      (cpAcc),hl              ; acc = 8n
                add     hl,hl                   ; 16n
                ex      de,hl                   ; de = 16n
                ld      hl,(cpAcc)
                add     hl,de                   ; 24n
                ex      de,hl                   ; de = 24n
                ld      hl,(cpTmp)
                add     hl,hl
                add     hl,hl
                add     hl,hl
                add     hl,hl
                add     hl,hl                   ; 32n
                add     hl,de                   ; 56n
                ld      de,(cpTmp)
                add     hl,de                   ; 57n
                ld      b,5
CP_sh:          srl     h
                rr      l
                djnz    CP_sh
                ld      a,h
                and     $F0
                jr      z,CP_ok
                ld      hl,4095
CP_ok:
                ret

;; ---------------------------------------------------------------------------
;; SndSilence — port of BIOS $FE54 ($9F $BF $DF $FF = att 15 on all 4 channels).
;; ---------------------------------------------------------------------------
SndSilence:
                ld      a,$9F
                call    SnWrite
                ld      a,$BF
                call    SnWrite
                ld      a,$DF
                call    SnWrite
                ld      a,$FF
                call    SnWrite
                ret

;; ---------------------------------------------------------------------------
;; SnWrite — A = one SN76489 command/data byte; update shadows + push to PSG.
;;   latch byte  1 rrr dddd   rrr = register 0..7, dddd = 4-bit field
;;   data byte   0 - dddddd   6 more bits for the last-latched tone period
;; Preserves BC / DE / HL.
;; ---------------------------------------------------------------------------
SnWrite:
                push    bc
                push    de
                push    hl
                bit     7,a
                jr      z,SW_data

                ;; --- latch byte ---
                ld      c,a
                and     $70
                rrca
                rrca
                rrca
                rrca
                ld      (snReg),a               ; register 0..7
                ld      a,c
                and     $0F
                ld      (snLow),a               ; 4-bit field
                ld      a,(snReg)
                srl     a                       ; a = channel 0..3, CF = type
                ld      (snCh),a
                jr      c,SW_setAtt

                ;; tone period low nibble (ch 0..2), or noise control (ch 3)
                ld      a,(snCh)
                cp      3
                jr      z,SW_noiseCtl
                add     a,a
                ld      e,a
                ld      d,0
                ld      hl,snPer
                add     hl,de
                ld      a,(hl)
                and     $F0
                ld      b,a
                ld      a,(snLow)
                or      b
                ld      (hl),a
                ld      a,(snCh)
                call    SW_pushTone
                jp      SW_done

SW_setAtt:
                ld      a,(snCh)
                ld      e,a
                ld      d,0
                ld      hl,snAtt
                add     hl,de
                ld      a,(snLow)
                ld      (hl),a
                ld      a,(snCh)
                cp      3
                jr      nz,SW_stv
                call    SW_pushNoiseVol
                jp      SW_done
SW_stv:
                call    SW_pushToneVol
                jp      SW_done

SW_noiseCtl:
                call    SW_pushNoiseCtl
                jp      SW_done

SW_data:
                ld      c,a                     ; c = data byte
                ld      a,(snReg)
                srl     a                       ; a = channel, CF = type
                jr      c,SW_done               ; att/ctl register -> ignore data
                cp      3
                jr      z,SW_done               ; noise -> ignore data
                add     a,a
                ld      e,a
                ld      d,0
                ld      hl,snPer
                add     hl,de                   ; hl -> period lo byte
                ld      a,(hl)
                and     $0F                     ; keep the latched low nibble
                ld      b,a
                ld      a,c
                and     $0F
                add     a,a
                add     a,a
                add     a,a
                add     a,a                     ; (data & $0F) << 4
                or      b
                ld      (hl),a                  ; period lo
                inc     hl
                ld      a,c
                and     $3F
                rrca
                rrca
                rrca
                rrca
                and     $03
                ld      (hl),a                  ; period hi (data >> 4)
                ld      a,(snReg)
                srl     a
                call    SW_pushTone

SW_done:
                pop     hl
                pop     de
                pop     bc
                ret

;; --- SnWrite helpers (channel in A where noted) --------------------------

;; SW_pushTone: a = channel 0..2 — convert snPer[ch] and write AY R(2c)/R(2c+1).
SW_pushTone:
                cp      3
                ret     nc
                push    af
                add     a,a
                ld      e,a
                ld      d,0
                ld      hl,snPer
                add     hl,de
                ld      a,(hl)
                inc     hl
                ld      h,(hl)
                ld      l,a                     ; hl = SN 10-bit period
                call    ConvPeriod              ; hl = AY period
                pop     af
                add     a,a
                ld      c,a
                ld      e,l
                call    AyReg                   ; R(2c)   = fine
                inc     c
                ld      e,h
                call    AyReg                   ; R(2c+1) = coarse
                ret

;; SW_pushToneVol: a = channel 0..2 — AY amp R(8+ch) = 15 - snAtt[ch].
SW_pushToneVol:
                cp      2
                jr      nz,SW_ptv
                ld      a,(snAtt+3)             ; channel C is shared with noise
                cp      15
                ret     nz                      ; noise owns R10 right now
                ld      a,2
SW_ptv:
                push    af
                ld      e,a
                ld      d,0
                ld      hl,snAtt
                add     hl,de
                ld      a,(hl)
                neg
                add     a,15                    ; 15 - att   (att 15 -> 0)
                ld      e,a
                pop     af
                add     a,8
                ld      c,a
                call    AyReg
                ret

;; SW_pushNoiseVol: snAtt[3] -> route noise to channel C (mixer + R10).
SW_pushNoiseVol:
                ld      a,(snAtt+3)
                cp      15
                jr      z,SW_noiseOff
                ld      a,(snR7)
                and     $DF                     ; noise C on  (bit5 = 0)
                or      $04                     ; tone  C off (bit2 = 1)
                ld      (snR7),a
                ld      c,7
                ld      e,a
                call    AyReg
                ld      a,(snAtt+3)
                neg
                add     a,15
                ld      c,10
                ld      e,a
                call    AyReg
                ret
SW_noiseOff:
                ld      a,(snR7)
                or      $20                     ; noise C off
                and     $FB                     ; tone  C on
                ld      (snR7),a
                ld      c,7
                ld      e,a
                call    AyReg
                ld      a,(snAtt+2)             ; restore R10 from the ch2 tone vol
                neg
                add     a,15
                ld      c,10
                ld      e,a
                call    AyReg
                ret

;; SW_pushNoiseCtl: this game only ever selects white noise / rate 0 -> R6 = 1.
SW_pushNoiseCtl:
                ld      c,6
                ld      e,1
                jp      AyReg

;; ===========================================================================
;; SoundTick — port of $BC83 SoundDispatch.  Call once per frame while a
;; session is live (any $68 phase), before the player/enemy dispatch.
;; ===========================================================================
SoundTick:
                ;; --- 1: fire / explosion descending sweep on ch0 ($20) ---
                ld      a,(SFXEXPL)
                bit     7,a
                jp      nz,ST_s2
                or      a
                jr      z,ST_s1q
                ld      a,$80
                call    SnWrite                 ; latch ch0 tone, low nibble 0
                ld      a,(SFXEXPL)
                ld      hl,SfxFireFreq
                call    AddAToHL
                ld      a,(hl)
                call    SnWrite                 ; freq data byte
                ld      a,$0F
                jr      ST_s1w
ST_s1q:
                xor     a                       ; $20 == 0: 0 ^ $9F = $9F (silent)
ST_s1w:
                xor     $9F
                call    SnWrite
                ld      hl,SFXEXPL
                dec     (hl)

ST_s2:
                ;; --- 2: ground-hit / ship-death rumble ($23 ctr, $24 divider) ---
                ld      a,(SFXTICK)
                or      a
                jr      z,ST_s3
                ld      hl,SFXTICKD
                dec     (hl)
                jr      nz,ST_s3
                ld      a,(SFXTICK)
                ld      hl,SfxGndReload
                call    AddAToHL
                ld      a,(hl)
                ld      (SFXTICKD),a
                ld      a,(SFXTICK)
                ld      hl,SfxGndByte
                call    AddAToHL
                ld      a,(hl)
                call    SnWrite
                ld      hl,SFXTICK
                dec     (hl)

ST_s3:
                ;; --- 3: spawn-in warp tone on ch0 ($68 == 0) ---
                ld      a,(PLRPHASE)
                or      a
                jp      nz,ST_s4
                ld      a,(PHASECT)
                xor     $7F
                ld      c,a                     ; c = $69 ^ $7F  (0..$7F)
                and     $0F
                or      $80
                call    SnWrite                 ; latch ch0 tone, low nibble
                ld      a,c
                rrca
                rrca
                rrca
                rrca
                and     $0F
                call    SnWrite                 ; data byte (high freq bits)
                ld      a,(PHASECT)
                dec     a
                jr      z,ST_s3x
                rrca
                rrca
                rrca
                rrca
                and     $0F
                inc     a                       ; (($69 - 1) >> 4) + 1
ST_s3x:
                ld      hl,SfxSpawnAtt
                call    AddAToHL
                ld      a,(hl)
                call    SnWrite

ST_s4:
                ;; --- 4: misc / shot-kill noise tail ($25) ---
                ld      a,(SFXMISC)
                bit     7,a
                ret     nz
                rrca
                and     $0F
                ld      hl,SfxMiscTail
                call    AddAToHL
                ld      a,(hl)
                call    SnWrite
                ld      hl,SFXMISC
                dec     (hl)
                ret

;; ===========================================================================
;; PlaySfx — A = jingle id (0 / 3 / 6).  Port of BIOS $FBD6.  BLOCKS until the
;; jingle finishes (the original does too — the main loop stalls on it).
;; ===========================================================================
PlaySfx:
                cp      3
                jr      c,PS_id0
                cp      6
                jr      c,PS_id3
                ld      hl,JngSeq6
                ld      a,(JngRecs+8)
                jr      PS_setup
PS_id0:
                ld      hl,JngSeq0
                ld      a,(JngRecs+2)
                jr      PS_setup
PS_id3:
                ld      hl,JngSeq3
                ld      a,(JngRecs+5)
PS_setup:
                ld      (J_SEQ),hl
                ld      (J_CUR),a
                ld      hl,JngEnv
                ld      (J_ENVP),hl
                ld      hl,(J_SEQ)              ; tempo = seq[startIdx]
                call    AddAToHL
                ld      a,(hl)
                ld      (J_TEMPO),a
                xor     a
                ld      (J_DUR),a
                ld      (J_DUR+1),a
                ld      (J_DUR+2),a
                call    SndSilence

PS_frame:
                call    JngDelay
                ld      a,2
                ld      (J_VOICE),a
PS_voice:
                ld      a,(J_VOICE)             ; prefix = $80 | voice<<5
                add     a,a
                add     a,a
                add     a,a
                add     a,a
                add     a,a
                or      $80
                ld      (J_PFX),a

                ld      hl,J_DUR
                ld      a,(J_VOICE)
                call    AddAToHL
                dec     (hl)
                jp      p,PS_sustain

                ;; --- fetch next event ---
                ld      hl,J_CUR
                dec     (hl)
                ld      a,(hl)
                cp      $FF
                jp      z,PS_end
                ld      hl,(J_SEQ)
                call    AddAToHL
                ld      a,(hl)
                ld      c,a                     ; c = event byte  (ppppp ddd)
                and     $07
                ld      hl,JngDur
                call    AddAToHL
                ld      b,(hl)                  ; b = duration value
                ld      hl,J_DUR
                ld      a,(J_VOICE)
                call    AddAToHL
                ld      (hl),b                  ; dur[voice] = duration

                ld      a,c
                rrca
                rrca
                rrca
                and     $1F                     ; pitch code 0..31
                jr      z,PS_rest
                cp      1
                jr      nz,PS_pdirect
                ld      hl,J_CUR                ; extended: next byte = table index
                dec     (hl)
                ld      a,(hl)
                ld      hl,(J_SEQ)
                call    AddAToHL
                ld      a,(hl)
PS_pdirect:
                ld      c,a                     ; c = table index 0..41
                ld      hl,JngFlo
                call    AddAToHL
                ld      a,(J_PFX)
                or      (hl)
                call    SnWrite                 ; tone latch
                ld      a,c
                ld      hl,JngDat
                call    AddAToHL
                ld      a,(hl)
                call    SnWrite                 ; tone data
                ld      a,$10
                jr      PS_setenv
PS_rest:
                xor     a
PS_setenv:
                ld      hl,J_ENV
                ld      b,a
                ld      a,(J_VOICE)
                call    AddAToHL
                ld      (hl),b                  ; env[voice] = $10 (note) / 0 (rest)
                jr      PS_envwrite

PS_sustain:
                ld      a,(hl)                  ; hl -> dur[voice]
                and     $07
                cp      $07
                jr      nz,PS_next              ; not a step frame -> hold
                ld      hl,J_ENV
                ld      a,(J_VOICE)
                call    AddAToHL
                dec     (hl)
                jp      p,PS_envwrite
                inc     (hl)                    ; clamp env index at 0

PS_envwrite:
                ld      hl,J_ENV
                ld      a,(J_VOICE)
                call    AddAToHL
                ld      a,(hl)
                ld      hl,(J_ENVP)
                call    AddAToHL
                ld      c,(hl)                  ; envelope value 0..$0F
                ld      a,(J_PFX)
                or      $10                     ; attenuation type
                or      c
                call    SnWrite

PS_next:
                ld      hl,J_VOICE
                dec     (hl)
                jp      p,PS_voice
                jp      PS_frame

PS_end:
                call    SndSilence
                ret

;; JngDelay — one tempo tick: J_TEMPO * JD_INNER djnz iterations.
JngDelay:
                ld      a,(J_TEMPO)
                ld      d,a
JD_outer:
                ld      b,JD_INNER
JD_inner:
                djnz    JD_inner
                dec     d
                jr      nz,JD_outer
                ret

;; ===========================================================================
;; data — carved verbatim from the ROMs (tools/carve_sound.py)
;; ===========================================================================
SfxTables:      incbin  "assets/sound_sfx.bin"          ; cart $BD9C-$BDE1
SfxSpawnAtt     equ     SfxTables + 0                    ; $BD9C  (18)
SfxMiscTail     equ     SfxTables + 18                   ; $BDAE  (16)
SfxFireFreq     equ     SfxTables + 34                   ; $BDBE  (15)
SfxGndReload    equ     SfxTables + 49                   ; $BDCD  (10, overlaps next)
SfxGndByte      equ     SfxTables + 59                   ; $BDD7  (11)

JngTables:      incbin  "assets/sound_jingle.bin"
JngDur          equ     JngTables + 0                    ; BIOS $FC79  (8)
JngFlo          equ     JngTables + 8                    ; BIOS $FC80  (42)
JngDat          equ     JngTables + 50                   ; BIOS $FCAA  (42)
JngEnv          equ     JngTables + 92                   ; BIOS $FCD5  (17)
JngRecs         equ     JngTables + 109                  ; cart $BF00  (9: id0/3/6)
JngSeq0         equ     JngTables + 118                  ; cart $BF20  (53)
JngSeq3         equ     JngTables + 171                  ; cart $BEC0  (16)
JngSeq6         equ     JngTables + 187                  ; cart $BF80  (43)
