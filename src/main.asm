;; ===========================================================================
;; Planet Defender — MSX port
;; Phase 4a: native VDP init + live game session (RNG, player control, ramp,
;; primary shot).  Terrain is the static reference frame; enemies / collisions /
;; sound / HUD land in 4b-4f.  No MSX BIOS on the frame path (input excepted).
;; ===========================================================================

                include "header.asm"

;; ---------------------------------------------------------------------------
Init:
                di
                ld      sp,$F380

                call    VdpInit                 ; R0-R7 + pattern/sprite/colour

                ld      hl,NameData             ; static terrain / HUD chrome
                ld      de,VRAM_NAME
                ld      bc,768
                call    VdpCopy

                call    GameInit
                call    SoundInit

;; ---------------------------------------------------------------------------
;; main loop — one iteration per 50 Hz frame (interrupts off, poll vblank).
;;   WorldScroll + DrawTerrain + OamFlush run first, right after the vblank
;;   wait, so all VRAM writes land at the top of the frame before the raster
;;   reaches them again (no tearing).  Game logic (input, player, ramp, shot)
;;   then runs through active display.  Mirrors the original's order at $B5B5.
;; ---------------------------------------------------------------------------
MainLoop:
                call    WaitVBlank
                ld      a,(STATE)               ; scroll + terrain redraw only in
                bit     6,a                     ; a live session — the title /
                jr      z,ML_nofield            ; game-over screens hold a static
                call    WorldScroll             ; field (mirrors $B5B5: the title
                call    DrawTerrain             ; path never calls $B400/$B431)
ML_nofield:
                call    OamFlush                ; push last frame's sprites
                call    DrawHUD                 ; score / hi-score / lives / meter
                call    StepRng
                call    ReadInput
                call    GameFrame               ; scanner / player / ramp / shot
                jr      MainLoop

;; ---------------------------------------------------------------------------
                include "vdp.asm"
                include "game.asm"
                include "enemies.asm"
                include "death.asm"
                include "input.asm"
                include "sound.asm"

;; ---------------------------------------------------------------------------
;; embedded assets
;; ---------------------------------------------------------------------------
NameData:       incbin  "assets/nametable_title.bin"   ; 768

;; ---------------------------------------------------------------------------
                ds      ROM_BASE + ROM_SIZE - $, $FF
