# Planet Defender — Reverse Engineering Notes

Status: **in progress (Phase 1)**. This file is the contract that Phases 3–6 build
against. Raw disassemblies live beside it:

- `bios.dis.txt` — full linear disassembly of `FunvisionBIOS.rom` (`org $F800`)
- `planetdefender.full.dis.txt` — full linear disassembly of the cart (`org $A000`)
- `planetdefender.code.dis.txt` — cart, restricted to `$B4E6`–`$BFE8`

Linear sweeps mis-decode data as code; treat regions flagged below as data.

## 1. Cartridge / boot model

The Funvision maps an 8K cart into `$A000-$BFFF` (also mirrored at `$8000-$9FFF`).
Planet Defender's image:

| Range | Contents |
|---|---|
| `$A000-$A7FF` | data — **mirrored** verbatim at `$A800-$AFFF` |
| `$A000-$A1FF` | small byte values — name-table / screen-layout data |
| `$A200-$B3FF` | pattern (tile + sprite) bitmap data, some small tables interleaved |
| `$B400-$BFDF` | **6502 game code** (+ embedded data tables, e.g. `$B221`, `$B27A`) |
| `$BFE0-$BFFF` | cart vector / parameter block (see §4) |

### Boot sequence
1. Funvision reset → boot ROM copies `$BFFC..$BFFF`→`$0200..$0203`, `JMP ($BFFC)`.
2. `$BFFC = $F808`. BIOS `$F808` runs: clears `$03C0-$03DF`, sets `$4C`, loads the
   8 VDP registers from `$BFF0-$BFF7` (`JSR $F84B` → `LDA $BFF0,X : JSR $FE1F`),
   runs a table loader (`$FD53` with ptr `$F861`), then `JMP ($BFE8)`.
3. `$BFE8 = $B4E6` → **game entry point**.

### Interrupt model
- IRQ vector `$BFFE = $FF3F` (BIOS handler).
- `$FF3F`: push regs; `LDA $2001` (read VDP status, clears IRQ); `STA $0C`;
  `JSR $FF58` (**16-bit LFSR advance** → `$02:$03`); `JSR $FA00` (**controller/keyboard
  decode** → raw `$18-$1B`, decoded `$11-$14`); `JMP ($BFEA)`. `$BFEA = $FF52` =
  pop regs + `RTI` (game adds no IRQ work).
- Net effect the port must reproduce, **once per 50 Hz frame** (PAL — see §8/§10):
  set `$0C` = VDP status byte
  (bit7 set during vblank); step the PRNG (`$02:$03`); refresh decoded input
  (`$11-$14`, plus `$15/$1D/$1E`). There is *no* BIOS sound tick — the game drives
  all sound itself from `$BC83` (`SoundDispatch`), called from its own frame code.
- Main loop (`$B5B5`): `CLI` / `LDA $0C : BPL *` (wait bit7) / `SEI` / clear `$0C`
  bit7 (`ASL $0C : LSR $0C`) / run one frame of game logic.

## 2. VDP configuration (Graphics I / "Mode 1")

Init values from `$BFF0-$BFF7` = R0..R7:

| Reg | Value | Meaning |
|---|---|---|
| R0 | `$00` | Mode 1, no EXT video |
| R1 | `$A2` | 16K, **display off** initially, IRQ enable, 16×16 sprites, MAG 0 |
| R2 | `$01` | Name table base = `$0400` |
| R3 | `$50` | Color table base = `$1400` |
| R4 | *(dynamic)* | Pattern generator base — **rewritten every frame** (see below) |
| R5 | `$38` | Sprite attribute (OAM) base = `$1C00` |
| R6 | `$04` | Sprite pattern generator base = `$2000` |
| R7 | `$01` | Text fg colour 0 / backdrop colour 1 (black) |

Later (`$B5A7`): `LDA #$E2 : LDX #$01 : JSR $FE1F` → **R1 = `$E2`** (turn display on,
keep IRQ + 16×16 sprites).

### Horizontal smooth scroll = 8 pre-shifted pattern banks

TMS9918 has no hardware horizontal scroll, so `WorldScroll` (`$B4AE-$B4BB`) sets
**R4 every frame** from the scroll accumulator:

```
LDA $44 ; scroll accumulator lo
JSR $FD46 ; = LSR A ×5  → A = ($44 >> 5) & 7   (0..7)
AND #$07
EOR #$07 ; A = 7 - ($44>>5)
LDX #$04 : JSR $FE1F ; R4 = A  → pattern base = A << 11
```

So the pattern generator base cycles through **8 banks 2 KB apart** as the world
scrolls; each bank holds the terrain tiles pre-shifted by its index in pixels:

| `$44>>5` | R4 | base | sub-tile shift |
|---|---|---|---|
| 0 | `$07` | `$3800` | 0 px |
| 1 | `$06` | `$3000` | 1 px |
| 2 | `$05` | `$2800` | 2 px |
| 3 | `$04` | `$2000` | 3 px |
| 4 | `$03` | `$1800` | 4 px |
| 5 | `$02` | `$1000` | 5 px |
| 6 | `$01` | `$0800` | 6 px |
| 7 | `$00` | `$0000` | 7 px |

The whole-tile (8 px) part of the scroll is the name-table column window
(`$40/$41`, redrawn by `DrawTerrain $B431`). 169 of the 256 tile slots differ
between banks (the terrain/mountain tiles); the other 87 (font, digits, ship, HUD)
are byte-identical in every bank. Banks `$3800` and `$3000` and `$2800` and `$0800`
are the only ones that don't overlap another VRAM table — the tiles that would sit
under the name table / colour table / OAM / sprite generator in the other four
banks are simply not used while that bank is selected.

**MSX port (Phase 3):** same trick, same VRAM layout. But 8 × 2 KB = 16 KB of raw
banks won't fit a 16 KB cart alongside code, so **generate shifts 1-7 at init**
from the shift-0 bank (`assets/patterns.bin`) straight into VRAM. The shift is
multi-tile-aware (pixels scroll in from the neighbouring tile), so the generator
needs the terrain tile-adjacency order — extract that from the name table / the
`DrawTerrain $B431` stripe data during Phase 3. The 87 non-terrain tiles are
copied unshifted into every bank.

MSX1 has the identical VDP; the register values and table layout port unchanged.

## 3. BIOS routines used (must be reimplemented natively on MSX)

| Addr | Name (ours) | Behaviour | MSX equivalent |
|---|---|---|---|
| `$FE1F` | `VdpCtrlPair` | write A to ctrl port, then write `X XOR $80` to ctrl port. Used as `WriteVdpReg(val=A, reg=X)` and as a raw 2-byte control write. | `OUT ($99),A` / `OUT ($99),reg\|$80` |
| `$FDD3` | `VdpCtrlByte` | write A to `$3001` (VDP control port) | `OUT ($99),A` |
| `$FD82` | `VdpDataByte` | write A to `$3000` (VDP data port) | `OUT ($98),A` |
| `$FD9E` | `VdpRunScript` | interpret a VDP command table @ (A:X): `[reg][val]` pairs via `$FE1F`, then `[cnt][?][byte]` VRAM fills via `$FD82` | port the interpreter |
| `$FD53` | `VdpRunScript2` | table loader, ptr passed in A/X | port |
| `$FD4D` | `VdpRunScript2` w/ ptr from `$BFF8/$BFF9` | as above | port |
| `$FE77` | `SndWrite` | `STA $1002` (byte→SN76489 via PIA), wait `$1003` bit7, read `$1002` | SN76489→AY-3-8910 shim |
| `$FA00` | `ScanInput` | **controller/keyboard scan** (from IRQ, *not* sound). Setup PIA (port A = out low nibble, port B = in). Read 4 columns: strobe `$1000` = `$F7,$FB,$FD,$FE` (via `SEC:ROR`), `$1002 EOR $FF` → `$18,X` (X=3..0). `JSR $FE67` (delay). Decode X=3..0: table ptr = `$FBB2` (X even) or `$FBC2` (X odd), length `$FBAE,X` (`$0F`/`$13`); scan table for a byte == `($18,X)<<1`; on match Y→`$11,X` with bit7 = new-press, `EOR #$C0` if previously held (repeat). Also builds `$15` (bit7-of-each-column mask), `$1D` (# active columns), `$1E` (active column idx), zeroes `$10`. | reimplement: read MSX joystick + keyboard → 4 decoded bytes `$11-$14` |
| `$FF58` | `RngStep` | **16-bit LFSR advance** (from IRQ, *not* input): feedback = `bit6($03) XOR bit5($03)` → `ROL $02 : ROL $03`. `$02:$03` = 16-bit PRNG state, clocked once per frame. | port the LFSR (or use any PRNG seeded per frame) |
| `$FE83` | `StatusRefresh` | per-frame score / status-row refresh into name table `$0400+`; uses `$0D/$0F/$15`, params `$BFE7,$BFED,$BFEE,$BFEF` | reimplement |
| `$FEC5` | `Bin2Dec` | Y = value → BCD/ASCII digit conversion (score display) | small routine |
| `$FEAD` | digit-output helper (continues `$FE83`) | | with above |
| `$FD2C/$FD2F/$FD30/$FD33` | `SubX` | fall-through `DEX` chain + `RTS` = **`X -= 8 / 5 / 4 / 1`** (not a delay). `$FD30` (`X -= 4`) is the object-array iterator step. `$FD35-$FD3D` = same for `Y`. | `sub`/`dec` inline |
| `$FD3E..$FD44` | `ShlA` | `ASL A` chain = `A <<= 6/5/4/3/2/1` by entry | inline |
| `$FD45..$FD4B` | `ShrA` | `LSR A` chain = `A >>= 6/5/4/3/2/1` by entry (`$FD46` = `>>5`, `$FD47` = `>>4`) | inline |

`$FE1F` detail: for `reg` 0–7, `reg XOR $80` = `$80\|reg` → TMS9918 register write.
Callers passing `X ≥ $40` are doing a raw VRAM-address setup instead.

## 4. Cart vector / parameter block `$BFE0-$BFFF`

Bytes (cart offset `$1FE0`): `04 F8 F9 F7 F8 00 BF 20 E6 B4 52 FF E0 08 0F C4`
then `00 A2 01 50 00 38 04 01`  (`$BFF0-$BFF7`)
then `?? ?? .. .. 08 F8 3F FF`  (`$BFF8-$BFFF`)

| Addr | Value | Use |
|---|---|---|
| `$BFE5:E6` | `$BF00` | table pointer (BIOS `$FD53` from `$F861` path / charset) |
| `$BFE7` | `$20` | reload value for `$0F` in `StatusRefresh` |
| `$BFE8:E9` | `$B4E6` | **game entry** (`JMP ($BFE8)`) |
| `$BFEA:EB` | `$FF52` | IRQ continuation (regs pop + RTI) |
| `$BFEC` | `$E0` | ? |
| `$BFED` | `$08` | modulus/wrap for `$0D` counter in `StatusRefresh` |
| `$BFEE` | `$0F` | value written by `StatusRefresh` VDP write |
| `$BFEF` | `$C4` | paired ctrl byte (`XOR $80`→`$44` = VRAM addr hi `$04`, write mode) → target `$040F` in name table |
| `$BFF0-$BFF7` | see §2 | VDP R0–R7 init |
| `$BFF8:F9` | ptr | VRAM-init script for `$FD4D` |
| `$BFFC:FD` | `$F808` | boot entry |
| `$BFFE:FF` | `$FF3F` | IRQ vector |

## 5. Code map

Recursive-descent trace: `tools/trace6502.py` from entry `$B4E6` reaches **2410 bytes
of code, 39 subroutines, 0 bad decodes**. Annotated listing: `planetdefender.trace.txt`.

| Range | Contents |
|---|---|
| `$B400-$BC5C` | game code (init, main loop, world scroll, enemy/ramp/bullet update) |
| `$BC5D-$BCF1` | small helpers (pattern copy, sound-fx emitters) |
| `$BCF2-$BD9B` | input scratch / spawn-param generation, per-life & per-game setup |
| `$BD9C-$BFDF` | **data tables** (see §9) |
| `$B1C0-$B2A1` | data tables referenced by init (`$B1C8`, `$B221`, `$B27A`) |
| `$A000-$B0FF` | pattern / name / colour source data for the VRAM-upload packer |
| `$B300-$B3FF`, `$B2A2-$B2FF` | padding (`$FF`) |

### 5.1 Game entry `$B4E6` (init)

1. `$B4E6-$B4FB`: A-on-entry = warm/cold flag. Cold: clears `$03C0-$03DF` (high-score
   table). Sets `$4C` = `$80` (warm) or `$00` (cold) — bit7 = **attract mode**.
2. `$B4FD-$B509`: fill `$0342-$035E` (per-slot anim timers) with `$17`.
3. `$B50D`: `LDA #$F4 : LDX #$FF : JSR $FD9E` — run VDP script at `$FFF4` (BIOS: base
   screen clear / table addresses).
4. `$B514-$B545`: **VRAM image upload.** Outer loop 8× (`$05` = VRAM-addr hi accumulator
   `$40,$48…$78`), inner 8× over 5-byte records at `$B27A` (`X` steps −5 via `JSR $FD2F`):
   each record = `{hi-bits, lo, srcptr-hi, srcptr-lo, start-Y}`; sets VRAM write address
   (`$FDD3` ×2) and copies `256 − Y` bytes from `(src)` to the data port. Populates the
   whole pattern/name/colour region of VRAM from packed ROM data in `$A000-$B0FF`.
5. `$B547-$B59F`: **sprite pre-shifter.** For `$08` = `$58…0`: `JSR $BC5D` loads an
   8-byte base pattern from `$B000 + $B1C8[type]*8` into `$E0-$E7`; then 8 sub-passes
   write those 8 bytes to sprite-pattern VRAM and `ASL $E8,X / ROL $E0,X` rotate — i.e.
   generates 8 horizontally-shifted copies of each sprite for sub-char-cell movement.
   `$B221[type]` selects the base tile per slot.
6. `$B5A1` `JSR $BD60` (init player/world vars) ; `$B5A4` `JSR $BD83` (park all sprites
   off-screen, `$83,X = $E0`).
7. `$B5A7`: **R1 = `$E2`** — display ON.
8. `$B5AE`: `$4D = $04` (fire-cooldown reload default — overwritten by `$BD23`).
9. `$B5B2` `JSR $B431` (draw terrain / scanner strip) → main loop.

### 5.2 Main loop `$B5B5` (one frame) — dispatch structure (from trace)

```
B5B5  CLI ; LDA $0C : BPL -    ; wait vblank ($0C bit7, set by BIOS IRQ)
      SEI ; ASL $0C : LSR $0C  ; clear bit7
      if NOT $4C.bit7:  JSR $BCF2   ; ReadInputOrWave  (skipped only in true attract)
      JSR $BBFA                     ; DrawHUD
      if $4C.bit6:  goto B5F1       ; a game session is active -> B5F1
  ;--- title (no session active; there are no "waves" — see §10) ---
      JSR $BD23 (InitGame) ; JSR $FE83 (status row)
      if ($12|$14)==0:  goto B5B5   ; spin until start/timeout trigger
      $4C |= $40 ; JSR $BD83 (ParkSprites) ; JSR $B431 (DrawTerrain) ; JSR $FBD6(0)
      goto B5B5
      ;; NB: the start path sets bit6, PARKS every sprite, and does NOT call
      ;; InitPlayer or un-park the ship.  $68 is still 0 / $69 still $7F from the
      ;; one-shot boot InitPlayer at $B5A1 (the title FSM never ticks them), so
      ;; B5F1 immediately enters the spawn-in animation with all sprites parked.
      ;; The ship + scanner ($D8-$DF) are un-parked only at $BB63 (death-FSM exit)
      ;; when $69 reaches 0 — i.e. the ship becomes visible exactly when the
      ;; converging debris "starburst" reaches the centre, never before.

B5F1:  ; $4C.bit6 set — session active
      if $4C.bit0:                  ; DEAD PATH — nothing in the cart ever sets bit0
         if ($12|$14):  $4C &= ~$01 ; JSR $BD60 (InitPlayer)
         goto B5B5
B609:  if ($56 | $5E) == 0:         ; $56 = lives; 0 -> game over
         JSR $BBFA ; JSR $FD53(ptr $BFB1) ; JSR $FBD6(6) ; $4C &= ~$41 ; goto B5B5
      ; else fall through:

B627:  FrameUpdate  — the entire per-frame game logic, run as a linear sequence
       of phases (NOT a table dispatch). Executes every frame while a wave is live.
       B627  JSR $B400   WorldScroll (+ DrawTerrain)
       B62A  JSR $BC83   SoundDispatch
       B62D  ...         player-state dispatch on $68 (see "$68/$69 FSM" below):
                           $68 <0 ($FF) -> B65B  player alive, normal control
                           $68 >0 (1..3) -> B658 -> $BABC  death-explosion running
                           $68 =0:
                             if $4C.bit2 (death anim just finished):
                               JSR $FBD6(3); JSR $BD60 (InitPlayer);
                               $4C &= ~$04; DEC $56,X (lose a life);
                               (2P) switch $4E to other player if this one still has lives;
                               goto B6FF
                             else -> B658 -> $BABC  (spawn-in animation, $69: $7F -> 0)
       B65B  ...         PLAYER CONTROL — reads $11,X (X = $4E>>2 = decoded stick of
                         active player): dir bits `$11 & $03` (^$03), bit2 = axis,
                         bit3 = sign; updates $DB altitude (clamp $1C..$AC), $48
                         cooldown, $42 scroll speed (±$20, clamp $20..$A0), $43 facing
                         (`EOR #$FE`), $DA world-X (clamp $30..$C0), $DE/$DF scanner
       B6FF  ...         difficulty-ramp state machine (§7c): $52,X state 0→2→4→6,
                         $53,X timer, $54,X auto-scroll floor (+$20/cycle, cap $A0);
                          `LSR $55,X` each cycle → spawn-rate ramp, see B730
       B730-B931 ...     enemy spawn + uniform update (8 stride-4 slots, §7);
                         spawn gated by `LDA $55,X; AND $49` — accelerates as $55→0.
                         `$0320,X` state; `$BB73/$BB82` apply signed speed to `$E0,X`
       B933-B983 ...     spawn a new player shot from $C0-$C3 slots + set up $D4-$D7
                         (the single "primary shot" scratch: $D6 shotX, $D7 shotY)
       B984-B9AC ...     advance the 4 $C0-$C3 shots (timer $61,X, travel via
                         `$FD0A`+`$BC6A`; retire at Y>=$C0)
       B9B1-BA0B ...     COLLISION: primary shot ($D6/$D7) vs each enemy — see §7a
       BA2F-BA65 ...     COLLISION: $C0-$C3 shots vs the fixed screen band [$38,$4F)
                         (meaning unconfirmed — hit -> AddScore(1), retire shot)
       BA67-BA98 ...     COLLISION: each enemy vs player ship ($DA/$DB) box
                         (±13 X, −6..+5 Y) — on hit fall into $BA9B (player death)
       BA9B-BB90 ...     $BA9B PlayerDeath (noise burst, save $46/$47, set $68=3)
                         then $BABC the $68/$69 explosion/spawn FSM + debris layout
```

**`$68`/`$69` player-state FSM** (`$BABC`, confirmed live by `tools/fv_probe2.py`):
`$68` = `$FF` alive · `$00` spawning-in · `$01..$03` death-explosion phase.
`$69` = phase counter. Spawn-in (`$68`=0): `$69` counts **down** `$7F`→0, then
`DEC $68` → `$FF` (alive) and `JMP $BB63`. Death (`$68`=1..3): `$69` counts **up**;
when it reaches `$BDF5[$68]` (`$BDF5` = `00 70 20 10`), `DEX $68`; when `$68`
underflows to 0, set `$4C` bit2 (→ main loop does the life-decrement + respawn).
Debris sprites `$0380-$0389` are laid out from `±$69` (grow then shrink).

`$4C` flags (revised): **bit7 = true attract** (skip `$BCF2` input read — the demo
after this still runs as a full session with `$11` fed by the wave code),
**bit6 = game session active**, **bit2 = death sequence finished → lose a life and
respawn** (the only two `ORA $4C` sites in the cart are `$B5DF` bit6 and `$BADB`
bit2). **bit0** is tested at `$B5F1` but never set anywhere in the cart — dead path;
likewise `$5E`. Respawn is driven entirely by the `$68`/`$69` FSM + bit2, not bit0.
`$12`/`$14` = start / attract-timeout trigger (`$BCF2` sets one when `$4B` hits 0).

## 6. Subroutine catalog (game)

| Addr | Name | Summary |
|---|---|---|
| `$B400` | `WorldScroll` | advance scroll pos `$44/$45` by `$42` in `$43` direction; wrap; recompute `$40/$41` (visible column window) → falls into `DrawTerrain` |
| `$B431` | `DrawTerrain` | redraw the scrolling ground/mountain row + mini-scanner strip into name table using `$B2A0`-ish stripe data and `$40/$41`; also writes R4 (`$FE1F` X=4) for coarse scroll, and `$80-$DF` sprite shadow → VRAM (`$B4D3` loop) |
| `$BB73` / `$BB82` | `AddPos` / `SubPos` | `$06:$07 = $04 + $0300,X` (`AddPos`) or `$04 − $0300,X` (`SubPos`), 16-bit — the per-object world-X step for this frame (`$04` = scroll base, `$0300,X` = enemy speed) |
| `$BB91` / `$BB93` | `AddScore1` / `AddScore` | `$BB91`: `A=1` then fall through. `$BB93`: 16-bit BCD add of `A` into score `$50/$51,X` (X=`$4E`); then live hi-score update — if `$51:$50 > $03C0,Y:$03D0,Y` (Y=`$0D`) copy it there |
| `$BBBF` | `DrawScorePanel` | build the two score displays via `$FEAD` digit output |
| `$BBFA` | `DrawHUD` | run the VDP script `($BE11[y],$BE12[y])`, y=`$52,X` = difficulty-ramp state (§7c: y=0/4→`$A440`, 2→`$BE19`, 6→`$BE29` — a changing HUD meter), plus `$BFxx` scripts; draw the lives icon row (`$BC46`) |
| `$BC46` | `DrawIconRow` | write `$56,Y` count of tile `$7E` (else `$00`) to a name-table run |
| `$BC5D`+`$BC78` | `LoadPattern8` | copy 8 bytes from `$B000+$B1C8[X]*8` to `$E0,X…` |
| `$BC6A/$BC6D/$BC73` | `Shl8/Shl16/Shl1` | `$06:$07` <<= 8 / <<= 16-in-3 / <<= 1 |
| `$BC83` | `SoundDispatch` | per-frame SFX mixer: reads `$20` (explosion), `$23/$24` (repeating tick), `$68/$69` (player death/spawn FSM → explosion pitch sweep), `$25` (misc) and emits SN76489 bytes via `$FE77` using tables `$BDBE`,`$BDCD`,`$BDD7`,`$BD9C`,`$BDAE` |
| `$BCF2` | `ReadInputOrWave` | fills wave scratch `$16/$17`; if playing & no player input, samples RNG `$02` into wave params (`$16` spawn-type, `$6B` seed) and drives `$11` (demo/behaviour); `DEC $4B`; when `$4B` hits 0 → set a `$11/$12` trigger (`#$D3`) to auto-start |
| `$B627` | `FrameUpdate` | (fallen into from main loop, not a `JSR` target) the whole per-frame update, phases listed in §5.2 |
| `$BD23` | `InitGame` | for both player slots (X=8,0 via `$FD2C`): `$50-$53,X = 0` (score + ramp state/timer), `$4E=0`, `$55,X = $07` (spawn throttle `%111`, §7c), `$54,X` = `$40`/`$80` (auto-scroll floor, `$0D` bit1 = difficulty), `$56,X = $03` (**lives**). Then `$4D` = `$04`/`$02` (fire-cooldown reload, `$0D` bit2 = difficulty); `$0D` bit0 clears vestigial `$5E` |
| `$BD60` | `InitPlayer` | `$43=1` (dir), `$49=0`, `$44=0`, **`$68=0`** (→ triggers the spawn-in FSM), `$42=$20` (speed), `$45=$5F`, `$46=$47=$80` (player world X/alt), `$4A=$0F`, **`$69=$7F`** (spawn-in countdown) |
| `$BABC` | `DeathRespawnFSM` | the `$68`/`$69` state machine — death explosion (grow/shrink debris `$0380-$0389`, phase limits `$BDF5`, debris colour `$BDF9`) and the spawn-in animation; see §5.2 |
| `$BD83` | `ParkSprites` | `$83,X = $E0` for X=`$5C…0` (Y=$E0 → off screen) |
| `$BD8F` | `ClearObjStates` | `$0320,X = 0` for X=`$1C…0` (free all enemy slots) |
| `$FBD6` | `PlaySfx` (BIOS) | X = jingle id; `$BF00,X` = `{seq_lo,seq_hi,start_idx}`; plays a 3-voice note sequence (format in §8). Call sites: id 0 = **game start** (`$B5EB`, once when you press start from the title — *not* per-wave), id 3 = respawn after death (`$B639`), id 6 = game over (`$B61B`). |

## 7. Object / entity model  *(confirmed by dynamic trace — see `dynamic-analysis.md`)*

Per-object fields are **stride-4 arrays with 8 enemy slots** at
`X ∈ {0,4,8,$0C,$10,$14,$18,$1C}`. The iterator is `LDX #$1C : … : JSR $FD30 : BPL`
where **`$FD30` = `DEX`×4** (the old notes had it as ×5 → 6 slots; wrong). All 8
slots seen live. Enemy "type" is not a stored field — it is `(X mod 12)` ∈ {0,4,8},
recomputed each frame (§7 step 4).

| Base | Bytes (per slot, stride 4) | Meaning (from live capture) |
|---|---|---|
| `$0320,X` | `state, -, -, -` | `$00` free, `$FF` active, `$01-$7F` spawn countdown (`DEC` each frame), `<0`… exploding |
| `$80,X` | `colour, pattern, screenX, screenY` | shadow OAM. `$80` = `$BE00[g]` colour (`$02`/`$04`/`$06` by slot-group `g`), `$81` = pattern/attr `$80 \| (g<<2) \| anim($0342,X>>1 & $0C)` — `$81 & $30` = the collision class (§7a), `$82` X px, `$83` Y px (`$E0` = hidden) |
| `$E0,X` | `Xlo, Xhi, Ylo, Yhi` | 16-bit LE world X (`$E0/$E1`) and Y (`$E2/$E3`) |
| `$0300,X` | `speed, -, -, -` | `$0300+X` = base |velocity|, seeded `(($02>>1)&7)+$10` → range `$10-$17` |
| `$0340,X` | `ctr, frameIdx, reload, -` | weave animation: `$0340` down-counter, `$0341` frame index 0-7 (into `$BDE2`), `$0342` a second timer (reload `$17`) driving the `$81` pattern-anim bits |
| `$A0,X` | `attr, pattern, X, Y` | enemy-bullet shadow OAM, parallel slot; pattern `$DC`, `$A3=$E0` inactive |

Player-bullet / bomb slots: **4 slots**, `X ∈ {0,4,8,$0C}`, `$C0,X` = `attr,pattern,X,Y`;
`$C3,X` (Y) = `$E0` when inactive. Also `$60,X`/`$61,X`/`$62,X` timers.

### Enemy AI (the `$B730-$B931` phase of `FrameUpdate`) — Phase 4 contract

1. **Spawn** `$B730`: gated by `($55,X & $49_frameCtr)` and `($03 & $1A)` (LFSR). Find a
   free slot; seed from LFSR `$02`: `$0340 = ($02&$1F)+$20`, `$0341 = $02&7`,
   `$E3 = ($02>>1)+$40`, `$0300 = (($02>>1)&7)+$10`, `$E1` = left- or right-edge X-hi
   (`$02` bit7 picks side) + jitter, `$0320 = $FF`.
2. **Horizontal drift** `$B79D` (facing right) / `$B7CA` (facing left, by `$43` sign):
   first `$04 = max(0, $42 − $54,X)` (`$B78C`) — the player's scroll velocity `$42`
   above the auto-scroll floor `$54,X` (see §7c). Per slot `JSR $BB73`/`$BB82` →
   `$06:$07 = ±($04 + $0300,X)` (16-bit), added to `$E0/$E1,X`. The sign is chosen by
   comparing the enemy's screen-Y `$82,X` to the player altitude `$DA` — enemies
   **home horizontally toward the player** (off-screen slots also take the homing sign).
3. **Weave** `$B7F5-$B849`: `DEC $0340,X`; on 0 reload the counter (`($03&$1F)+$20`)
   and re-pick phase `$0341 = $02&7`. Then, indexed by `$0341` (0-7), add
   `$BDE2[i]:$BDEC[i]` as a signed 16-bit X step and `$BDE4[i]:$BDEE[i]` as a signed
   16-bit **altitude** step to `$E0:$E1` / `$E2:$E3`. `$E3` (altitude hi) is masked
   `AND #$1F` and reflected to stay in the band `[$03,$16)` (`$E2` flipped on bounce).
4. **Project to sprite** `$B84B-$B8B6`: player altitude window `$6C/$6D = $DB ± $0C`.
   Per slot `$82,X = $E1>>5` (`JSR $BC6D` = `ASL:ROL ×3`), `$83,X = $E3>>5` (or `$E0`
   = hidden if the enemy altitude is `≥ $C0` or the X-hi top bits are set = off-strip).
   **The enemy "type" is assigned here, purely from the slot number** (`$B885`):
   `g = (X mod 12)` ∈ {0,4,8} — so slots {0,`$0C`,`$18`} → g0, {4,`$10`,`$1C`} → g1,
   {8,`$14`} → g2. `$80,X` (colour/pattern lo) = `$BE00[g]` = `$02`/`$04`/`$06`;
   `$81,X` = `$80 | (g<<2) | (($0342,X>>1) & $0C)` — so `$81,X & $30` (the collision
   class, §7a) **= `g<<2`**, i.e. score `$02`/`$03`/`$05` is a function of slot group,
   *not* of any spawn parameter. There is **one enemy AI**; the three "types" differ
   only in sprite pattern and score.
5. **Tick + fire** `$B8C5-$B916`: `$4A` toggles `$FF↔$00` each frame (→ `$08` gate);
   spawn-countdown slots `DEC $0320,X`. Active slots on-screen (`$E3>>5 < $C0`) that
   pass the `$08` gate + `JSR $FD47` (LFSR) emit an enemy bullet into `$A0-$A3,X`
   (8 slots): `$A2,X = (($E1+$80)>>1)+$38`, `$A0,X=$0F` (colour), `$A1,X=$DC` (pattern),
   `$A3,X = $E0` when free. Off top/bottom → free the slot.
6. **Player-fire hook** `$B918-$B94F`: `$16,X & $0C` (fire new-press, §7b) → spawn the
   player shot (`$D4-$D7`) and set `$20 = $0E` (fire SFX id for `SoundDispatch`).

Weave step tables (indexed by `$0341,X`, 0-7; overlapping so 2 pairs share a base):

| i | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| `$BDE2` X-lo | 00 | 10 | 10 | 10 | 00 | F0 | F0 | F0 |
| `$BDEC` X-hi | 00 | 00 | 00 | 00 | 00 | FF | FF | FF |
| `$BDE4` Y-lo | 10 | 10 | 10 | 00 | F0 | F0 | F0 | 00 |
| `$BDEE` Y-hi | 00 | 00 | 00 | FF | FF | FF | 00 | 00 |

i.e. X step `0,+16,+16,+16,0,−16,−16,−16` and altitude step
`+16,+16,+16,−256*,−16,−16,−16,0` (the `−256` phases are absorbed by the `AND #$1F`
band clamp) — a slow side-to-side + up-down wander.

### 7a. Collision phase — fully resolved (static, `$B984-$BA98`)

Runs each frame at the tail of `FrameUpdate` (see §5.2 phase list). Three loops.

**Loop 1 — primary player shot (`$D6`/`$D7`) vs enemies** (`$B9CF-$BA2D`), 8 slots,
X = `$1C`→0 step `−4` (`$FD30`):
- gate (`$B9B1`): only if `$D7 < $C0` (shot Y live). First adjust `$D6` by ±$10 for
  facing (`$6A` sign), retire shot if it walks off (`$D7=$E0`).
- per slot: skip unless `$0320,X` bit7 (active/exploding).
- **class** `Y = ($81,X & $30) >> 2` — only `$00/$10/$20` occur → `Y ∈ {0,4,8}`
  (a `Y=$C` entry exists in the table but is garbage / never hit).
- **vertical**: `dy = $83,X − $D7` (must be ≥ 0); hit needs `$BDFD[Y+1] ≤ dy < $BDFD[Y]`.
- **horizontal**: `dx` = shot-ahead-of-enemy distance in the `$43` facing direction
  (`$B9F1`); hit needs `0 ≤ dx < $10`.

  | `$81,X & $30` | Y | dy window | points (`$BDFD[Y+2]`, BCD) |
  |---|---|---|---|
  | `$00` (biggest) | 0 | `$01 ≤ dy < $0E` | **`$02`** |
  | `$10` | 4 | `$02 ≤ dy < $0D` | **`$03`** |
  | `$20` | 8 | `$03 ≤ dy < $0B` | **`$05`** |

  `$BDFD` bytes = `0E 01 02 | 02 0D 02 03 | 04 0B 03 05 | 06 …` — `$BDFD[Y]`=hi,
  `$BDFE[Y]`=`$BDFD[Y+1]`=lo, `$BDFF[Y]`=`$BDFD[Y+2]`=score (overlapping reads).
- **on hit** (`$BA0D`): `$81,X |= $0C` (explosion pattern bits), `$20 = 0`, `$25 = $1F`
  (SFX), `$FE77($E4)` noise burst, `$0320,X = $7F` (dying — later frames skip it),
  `AddScore($BDFF[Y])` via `$BB93`, retire the shot (`$D7 = $E0`).

**Loop 2 — secondary shots (`$C2`/`$C3` slots, 5) vs the map tiles** (`$BA2F-$BA65`):
for each active `$C3,X < $C0`: `$04 = $C2,X`, `$05 = $C3,X`; `JSR $FDEC` then
`JSR $FE0C` **reads the name-table tile** under the shot (`$45` bit0 picks the
scroll-parity half via `$05 |= $04`/`$0C`). If the tile code is in **`[$38,$4F)`**
(destructible terrain / ground target) → `$22 = $1F` (SFX), retire shot (`$C3,X=$E0`),
`AddScore(1)` via `$BB91`. So loop 2 = *shooting scenery/ground installations for 1 pt*.

**Loop 3 — enemies vs player ship** (`$BA67-$BA98`): for each active enemy, box-test
`$82/$83,X` vs player `$DA/$DB`: **`dx ∈ [−$0D, +$0C)` and `dy ∈ [−6, +5)`** → `$BA9B`
`PlayerDeath`.

**Death FSM `$BABC`** (called from `$B658` when `$68 ≠ 0`): phase `$68` counts **down**
3→0; `$69` counts up each frame until `$69 ≥ $BDF5[$68]` (`$BDF5` = `00 70 20 10`), then
`DEC $68`. Reaching phase 0 → `$4C |= $04` (death done → lose a life + respawn, §5.2).
Each frame it rewrites debris scratch `$0380-$0389` from `$47`/`$69` and the debris OAM
(`$80,X` attr = `$BDF9[$68]` = `0F 02 04 06`, `$81,X` pattern = **`$BC`**), and on exit
reinits the scanner `$D8-$DF` from `$BE09` (`02 D0 78 80 06 C0 81 80`).

Player & world: `$DA` world-X, `$DB` screen-Y (alt), `$DE/$DF` scanner echo,
`$42` scroll speed, `$43` facing (`bit7`), `$44/$45` scroll accumulator,
`$46/$47` = player world X / altitude, `$48` fire cooldown, `$4E` current player (`0`/`8`).

Difficulty ramp (§7c): `$52,X` ramp state (`0→2→4→6`, HUD script index into
`$BE11`/`$BE12` run by `$BBFA`), `$53,X` timer, `$54,X` **auto-scroll floor**
(min `$42`; raised `+$20` per cycle to `$A0`; also `$04 = $42 − $54` enemy-drift base),
`$55,X` **enemy-spawn throttle** (`%111`; `AND $49` frame-gates the spawn in `$B73E`,
`LSR $55,X` at `$B72A` each cycle → spawns accelerate `%111→0` over the game — *not* a
smart bomb). `$56,X` = **lives** (init 3, `DEC` on death, game over at 0).

Per-player: `$50/$51,X` = 16-bit BCD score (X=`$4E` ∈ `{0,8}`); live high score
mirrored at `$03C0,Y` (hi) / `$03D0,Y` (lo), Y = `$0D`. `$4D` = fire-cooldown reload
(4 easy / 2 hard). `$5E` appears vestigial (2-player leftover, only ever set to 0).

Enemy wave control: `$16`/`$17` hold the per-frame fire-button decode from `$FA00`
(see §7b); `$BCF2` overwrites `$16` with a spawn-type when there is no live input.
`$6B` cached wave seed, `$4B` attract countdown.

> **Resolved by dynamic trace.** `$4B` counts down each frame; when it hits 0 the game
> starts a game session (`$4C` bit6 set — see §5.2) and briefly writes `$11 = $D3`
> (the attract-timeout / auto-start trigger). During the demo `$11` is reused by
> `$BCF2`/wave code as a behaviour selector. `$18-$1B` hold the raw column reads.
> `$FA00`'s `STA $11,X` only lands a value with bit7 set (`ORA #$80`) on an actual
> keypress; the game consumes and clears `$11-$14` every frame, so a probe must
> sample right after the IRQ's `JSR $FA00` returns (`tools/fv_trace_fa00.py`).

### 7b. Input model — Phase 5 contract  *(from `$FA00` decode + cart read-trace)*

**Physical start sequence (user):** reset → pick a mode with the controller side
(fire) buttons → press **6** or **B** to start. `6` and `B` are both left-controller
matrix column 13.

**BIOS `$FA00`** (called from the BIOS IRQ at `$FF4C`, once per frame) produces:

| var | source column | contents |
|---|---|---|
| `$11` | col 14 (left joystick) | decoded **P1 direction** = `$80\|idx` new / `$40\|idx` held; `idx` into the 16-byte table `$FBB2` |
| `$13` | col 11 (right joystick) | decoded **P2 direction** (same encoding) |
| `$12` | col 13 (left-hand keys) | decoded key — used only for the start check; nonzero for `1-6 Q-T A-G Z-B` |
| `$14` | col 7 (right-hand keys) | decoded key — start check; nonzero for `7-0 : - Y-Enter H-→ N-space` |
| `$15` | bit7 of each column | 4 raw fire-line bits: `b3`=col7(LCTRL) `b2`=col11(TAB) `b1`=col13(LSHIFT) `b0`=col14(RSHIFT) |
| `$16`/`$17` | via `$FB49` from `$15` | **fire** state, P1=`$16` P2=`$17`; `b3:b2` = new-press edge, `b1:b0` = raw level of that player's two fire lines |
| `$18-$1B` | raw | `EOR $FF` of each column read (X=0..3 → col 14,13,11,7) |

Direction table `$FBB2` (`ASL(rawcol)` → index): left-stick **UP**=idx 9 (`$89`),
**DOWN**=idx 1 (`$81`), **LEFT**=idx 13 (`$8D`), **RIGHT**=idx 5 (`$85`). Diagonals
(idx 3/7/11/15, `idx&3==3`) are treated as no-op by the player handler.

**In-game consumption:**
- **Start / leave title** (`$B5D7`, `$B5F7`): `LDA $12 / ORA $14` — any left- or
  right-hand keyboard key (this is the "press 6 or B").
- **P1/P2 move** (`$B65B`+, `X = $4E>>2` ∈ {0,2}, `LDA $11,X`):
  - `idx & $04` set (**LEFT/RIGHT**) → `$B68E`: gated by latch `$4F` (bit7) and
    cooldown `$48`; change the **scroll velocity** `$42` by **±$20** (range `[0,$A0]`,
    floored at `$54,X`), flip facing `$43 ^= $FE` when `$42` reaches 0, reload `$48`
    from `$4D` (4 easy / 2 hard). See the `$42` note below — this is thrust, not a dash.
  - `idx & $08` distinguishes **UP** (`$B67F`) vs **DOWN** (`$B675`) → step altitude
    `$DB`/`$DF` by **±1 px/frame**, clamped `[$1C,$AC]`.
  - zero / `idx&3==3` → `$B6AB` coast (still ticks `$48`).
- **P1/P2 fire** (`$B91E`, `X = $4E>>3` ∈ {0,1}, `LDA $16,X; AND #$0C`): tests the
  **new-press** bits → spawn shot record `$D4-$D7` (`$D6` = `$DA` ± $10/$20 by facing,
  `$D7` = `$DB` − 8, `$D4` = `$8F`/`$0F` by `$43` sign), set SFX id `$20 = $0E`.

**MSX mapping (Phase 5):** joystick 8-way → synthesise the `$11` direction index
(only the 4 cardinals matter); trigger A → the `$16` fire edge; **space/return** →
the `$12` start byte. No smart-bomb / hyperspace trigger exists (§7c).

> **Note on `$42`.** LEFT/RIGHT do *not* teleport the ship — `$42` is the **world
> scroll velocity** (range `[0,$A0]`, stepped by `$20`, cooldown `$48`←`$4D`). Facing
> `$43` flips when `$42` decrements to `0`; `$42` cannot fall below the floor `$54,X`
> (`$B6B1`). `$B400` adds `$42` to the scroll accumulator `$44/$45` each frame. So the
> control model is *Defender* thrust-and-reverse, not a dash. Altitude (UP/DOWN, `$DB`)
> is the ±1 px/frame part. §7b's earlier "±$20 dash" wording is imprecise — it is a
> ±$20 **velocity** change.

### 7c. Difficulty-ramp state machine (`$52-$55,X`, `$B6FF-$B730`)

Per player (`X = $4E` ∈ {0,8}). Not a humanoid/abduction system — it is the game's
only escalation mechanism (there are no waves, §10).

| var | role |
|---|---|
| `$52,X` | ramp state, cycles `0 → 2 → 4 → 6 → (0)` (`INY INY`) |
| `$53,X` | countdown timer; at `0` the state advances |
| `$54,X` | **auto-scroll floor** = minimum value of `$42`. Init `$40` (or `$80` if `$0D` bit1), raised `+$20` per full cycle up to `$A0`, then wraps. Also the subtrahend in the enemy-drift base `$04 = $42 − $54` (§7 step 2). |
| `$55,X` | **enemy-spawn throttle**, init `%111` (`$BD33`); `LSR $55,X` once per cycle (`$B72A`) → `$B732: LDA $55,X; AND $49` gates the spawn in `$B73E`, so spawns accelerate `%111→%011→%001→0` over the game |

Flow (`$B701-$B730`):
- **state 0:** `DEC $53,X` every frame; on wrap to `0` → advance. `$53,X` inits `0`
  (`$BD23`), so the first `DEC` underflows to `$FF` → a one-shot **255-frame**
  (~5.1 s @ 50 Hz) delay, then 0→2. (RampUpdate only runs while the ship is alive
  — `$B62D` routes spawn-in / death frames elsewhere — so the count starts *after*
  the ~2 s spawn-in, ≈7 s into the session.)
- **states 2/4/6:** advance only when `$53,X != 0` **and** `$50,X & $F0 == 0`.
  But `$53,X` is reloaded to non-zero **only** on frames where `$50,X & $F0 != 0`
  (`B70F: BNE $B72E` → `B72E: STA $53,X`, and `A` there still holds the `AND #$F0`
  result). Each advance sets `$53,X = 0` again. Net: the state steps once per
  **"century rollover"** of the score low byte `$50` (its tens nibble goes
  non-zero, arming `$53`, then back to zero on the BCD wrap → advance). State 6
  also walks `$54,X += $20` (wrap at `$A0`). Every advance does `LSR $55,X`.
- **Consequence (this is the "bug" — confirmed on hardware timing + in openMSX):**
  if the player is *not* clearing ~100 internal points (≈1000 displayed — kills
  are only 2/3/5 pts each, `CollTab $BDFF`), `$53,X` never gets re-armed and the
  ramp **sticks in state 2 indefinitely**. So a typical run shows ~5 s of the
  default (decorated) terrain palette, then the state-2 palette (flat cyan hills)
  for the rest of the game. funnymu reproduces this identically. §7c cadence
  `0→2→4→6→0` is the *design intent*; only the 0→2 step is reliable in practice.

`$BBFA DrawHUD` runs the VDP script `($BE11[$52,X], $BE12[$52,X])` — pointers
`$A440` (states 0/4), `$BE19` (state 2), `$BE29` (state 6).  Each script writes
**colour-table** entries at VRAM `$1400` (block header `D4 00 0C/10` →
`$D4^$80 = $54` = write, addr hi `$14`) — these colour the terrain **pattern
groups** (Graphics-I: entry _n_ = the fg/bg of char codes `8n..8n+7`):
- `$A440` (16 entries) restores the default table
  `70 70 70 70 70 70 70 | 7B 7F 7F 76 | 70 | A0 A0 A6 60`. Entries 7-10 carry
  **light-yellow / white / white / dark-red backgrounds** (`xB/xF/xF/x6`), so the
  hill tiles whose char codes land in groups 7-10 show yellow/white/red speckle
  where their pattern has `0` bits.
- `$BE19` (12 entries) sets entries 7-10 → `$77` (cyan-on-cyan) → those same hill
  tiles read as **flat cyan** (the "solid blue hills").
- `$BE29` (12 entries) sets 0-6 → `$80` and 7-10 → `$88` → the hills go
  **medium-red**.

So the terrain palette is the difficulty/progress indicator — a recolour, not a
filling bar. (Entries 12-15 `A0 A0 A6 60` are only ever rewritten by `$A440`, so
`$BE19`/`$BE29` leave those groups yellow/red regardless of state.)
Ported in Phase 4f slice 2 (`VdpRunScript` = `$FD53`; blobs in
`assets/hud_scripts.bin`).

**MSX (Phase 4):** reimplement as: a timer that every N frames raises `scrollFloor`
by `$20` (cap `$A0`, wrap) and shifts `spawnThrottle` right by 1; redraw the HUD
meter from the state. Re-seed both from `InitGame` only.

## 8. Sound

Funvision: **SN76489** fed one byte at a time through the 6821 PIA port B (`$1002`),
with a PIA-generated strobe; `$1003` bit7 = ready. **There is no BIOS sound tick**
(the earlier guess that `$FA00` was a sound sequencer is wrong — `$FA00` is the
input-decode routine, §3). The game runs its own sound engine: `$BC83 SoundDispatch`
per frame plus 10 direct `$FE77` writes.

**Every** sound write goes through BIOS `$FE77` (raw SN76489 byte). The port needs
the one primitive `sn76489_write(byte)` plus reimplementations of two drivers:

**`$BC83 SoundDispatch`** — per-frame in-game SFX mixer (fire / explosion / ground
hit / scanner blips). Reads `$20` (fire/explosion countdown), `$22-$25`, `$68/$69`
(player death/spawn FSM), emits SN bytes via `$FE77` using tables
`$BDBE/$BDCD/$BDD7/$BD9C/$BDAE`. Software volume envelopes (one atten step/frame,
seen ramping 15→0 over ~48 frames).

**`$FBD6 PlaySfx(id)`** — 3-voice note-sequence player for jingles. Called with
id 0 = game start (`$B5EB`, once from the title), id 3 = respawn after death
(`$B639`), id 6 = game-over (`$B61B`).
- `$BF00,X` = 3-byte record `{seq_lo, seq_hi, start_idx}` per id. Sequences (read
  **backwards** from `start_idx` via `DEY`): id 0 → `$BF20` idx `$34`; id 3 → `$BEC0`
  idx `$0F`; id 6 → `$BF80` idx `$2A`.
- Each event byte = `ppppp ddd`: `ddd` (0-7) → note duration from `$FC79`
  `{07 0F 17 1F 2F 3F 5F 7F}`; `ppppp` (0 = rest) → pitch index into freq tables
  `$FC80` (low nibble, 42 B) + `$FCAA` (data byte, 42 B). Big pitch codes read an
  extra byte for the freq-low.
- Amplitude envelope: per-voice counter `$18,X` starts `$10`, indexes
  `$FCD5` = `0F 0F 0E 0D 0C 0B 0A 09 08 07 06 05 04 03 02 01 00` → atten fades
  loud→silent over 16 ticks. Latch prefix `$80|($BF00-derived ch)<<5` (ch 0/1/2).
- Port = ~40-line interpreter + the 4 BIOS tables + the 3 cart sequence blobs
  (carve into `assets/` in Phase 2).

`$FE54` = silence all 4 (`FF DF BF 9F`).

Captured byte stream: `tools/fv_emu.py --sound-log build/re/sound.log`, decoded by
`tools/sn_decode.py` (see `dynamic-analysis.md` §Sound). SN76489 protocol:
`1cc t dddd` latch (cc=chan, t=0 freq-low / t=1 atten), `0 - dddddd` = 6 more freq
bits.

**Chip clock (from the Funvision circuit diagram).** The SN76489 clock pin is wired
to the 6502 **φ2 (2 MHz)** — the same signal that drives the 6821 PIA's E (Enable)
input. So **F_sn = 2 000 000 Hz** and `f_tone = F_sn / (32 · n_sn)` ⇒
`f ≈ 62 500 / n_sn`. Decoding `sound.log` at 2 MHz the game-start jingle comes out
as a clean G-major arpeggio — 98.0 (G2) / 123.5 (B2) / 146.7 (D3) / 393.1 (G4) /
440.1 (A4) Hz — which corroborates the diagram value well. NB: `funnymu` runs its MAME-derived `sn76496.c` at
`SN76496Init(0, VDP_CLOCK/15, …)` = `53 200 000 / 15 ≈ 3.546 7 MHz`, an emulator
approximation ~1.77× high — its **audio pitch is not a reference**; trust the
`sound.log` period values, interpreted at 2 MHz.

The machine is **PAL / 50 Hz** (9929 VDP, 2 MHz 6502; `funnymu VPeriod = 40000`
cycles/frame = 2 MHz ÷ 50). The MSX port targets 50 Hz as well (§10) so no
frame-rate rescaling of game or sound timers is needed.

MSX: **AY-3-8910 PSG** (ports `$A0` address / `$A1` data, or BIOS `WRTPSG`),
clock `F_ay = 1_789_772.5 Hz`, `f = F_ay / (16 · n_ay)`. Phase-6 translation:
- Equate frequencies: `n_ay = n_sn · (2 · F_ay / F_sn) = n_sn · 3 579 545 / F_sn`.
  With `F_sn = 2 000 000`: **`n_ay ≈ 1.79 · n_sn`** (clean fraction ≈ 16/9 = 1.778,
  or 9/5 = 1.8 which is +0.6 %). Implement as `n_ay = (n_sn · 229) >> 7` (1.789)
  or `n_sn · 9 / 5`.
- Clamp `n_ay` to the AY 12-bit range; SN `n_sn = 0` means "1" (already handled by
  `sn76496.c`).
- SN noise: 3 shift rates + periodic/white → AY noise period + mixer.
- SN attenuation (4-bit, 2 dB/step, `$0F` = off) → AY amplitude (4-bit, also log) via LUT.

Decision (faithful clone): reproduce the **effect set** — fire, enemy/player
explosion, ground-target hit, the `$BC83` death pitch-sweep, game-start / respawn /
game-over jingles — by porting `SoundDispatch` and feeding it the same triggers,
rather than emulating the SN cycle-exactly. (The trigger sites are all now RE'd:
`$20` fire/explosion, `$22` ground hit, `$25` misc, `$68/$69` death FSM.)

**Reference:** `coleco-to-msx-reference/` holds a working ColecoVision→MSX conversion
(Donkey Kong) whose bundled Coleco-BIOS reimplementation contains a full SN76489→AY
PSG layer. Reusable helper routines and the frequency/volume conversion are documented
in `docs/coleco-to-msx-sound.md`.

Direct SFX sites (`JSR $FE77`, raw SN76489 bytes) at `$BA1B`, `$BA9B` (`#$E4` =
channel-3 noise attenuation update — explosion), plus the whole `$BC83 SoundDispatch`
mixer. BIOS `$FBD6 PlaySfx` at `$B5EB` (id 0), `$B61B` (id 6), `$B63B` (id 3).
`$FE54` = silence all 4 channels (`$FF $DF $BF $9F`). `$FE67` = PIA sound-port setup.

## 9. Data tables

| Addr | Size | Use (confidence) |
|---|---|---|
| `$B1C0` | 8 | small sprite/tile header (`00 00 60 7E 7E 00 00 00`) |
| `$B1C8` | ~20 | ascending index `00 01 02 … 13` — pattern-base LUT for `$BC5D` |
| `$B1DC` | ~24 | `0B 0A 0C 07 08 0A 05 01 …` — per-type pattern counts / sizes (?) |
| `$B221` | ~88 | per sprite-preshift-slot base tile index (init step 5) |
| `$B27A` | 40 | 8 × 5-byte VRAM-upload records `{hi,lo,srchi,srclo,startY}` |
| `$BD9C` | 18 | `SoundDispatch` ch0/ch1 attenuation-latch envelopes: `9F 90 90 90 90 94 98 9C 9E` (ch0) `BF BD BB B9 B7 B5 B3 B1 B0` (ch1) |
| `$BDAE` | 16 | `SoundDispatch` table: `FF FD FB F9 F7 F4 F2 F0 F0×8` (freq-data bytes, descending) |
| `$BDBE` | 15 | `SoundDispatch` table: `20 1C 18 14 10 0E 0C 0A 08 07 06 05 04 03 02` (period / decay) |
| `$BDCD` | 10 | `SoundDispatch` table: `01 01 04 08 10 10 30 10 10 08` |
| `$BDD7` | 11 | `SoundDispatch` table: `08 FF FC F8 F6 F4 F0 FF F2 FF F2` |
| `$BDE2` | 19 | object per-frame delta table: `$BDE2/$BDEC` = X step lo/hi, `$BDE4/$BDEE` = Y step, indexed by `$0341,X`. Bytes `$BDE2`: `00 10 10 10 00 F0 F0 F0 00 10 00 00 00 00 00 FF FF FF 00` |
| `$BDF5` | 4 | `00 70 20 10` — `$68`/`$69` death-explosion phase limits, `X = $68` (`$BABC`) |
| `$BDF9` | 4 | `0F 02 04 06` — death-explosion debris OAM attr (`$80,X`), `X = $68`; debris pattern is always `$BC` |
| `$BDFD` | 12 | collision loop-1 table, stride 4, class `Y = ($81,X & $30)>>2` ∈ {0,4,8}. Bytes `0E 01 02 02 · 0D 02 03 04 · 0B 03 05 06`. Per class: `[Y]`=dy-hi (excl), `[Y+1]`=dy-lo (incl), `[Y+2]`=kill score BCD. → class0 `dy∈[$01,$0E) → $02`; class1 `[$02,$0D) → $03`; class2 `[$03,$0B) → $05` |
| `$BE00` | 9 | enemy entry-Y / attr per spawn (`LDA $BE00,Y` at `$B89E`): `02 0D 02 03 04 0B 03 05 06` |
| `$BE09` | 8 | `$D8-$DF` scanner-state reinit block (`LDA $BE09,X` X=7..0 at `$BB65`): `02 D0 78 80 06 C0 81 80` |
| `$BE11` | var | `DrawHUD` VDP-script pointer pairs (`$BE11[y]`,`$BE12[y]`) then inline scripts |
| `$BEC0` | 16 | `PlaySfx` id-3 sequence (post-death respawn): `AD 8D 65 AB 8B 73 AB 8D 73 AB 8B 73 AB 8B 73 0C`, read backwards from idx `$0F` |
| `$BF00` | 9 (+`$FF` pad) | `PlaySfx` id→`{seq_lo, seq_hi, start_idx}`: id0 `{20 BF 34}` id3 `{C0 BE 0F}` id6 `{80 BF 2A}` |
| `$BF20` | ~40 | `PlaySfx` id-0 sequence (game-start), read backwards from idx `$34` |
| `$BF80` | ~45 | `PlaySfx` id-6 sequence (game-over), read backwards from idx `$2A` |
| `$BFB0` | ~30 | VDP scripts: `C5 8A 0B 00 …`, `C4 03 03 …`, `C4 18 04 …` (`$C4^$80=$44` = VRAM-addr) |
| `$BFE0` | 32 | cart vector/param block (§4) |

## 10. Open questions / TODO

- [x] **Dynamic harness built** — `tools/fv_emu.py` (py65 + Funvision bus). Boots the
  real ROM headless, runs the attract demo, dumps RAM/VRAM. See `dynamic-analysis.md`.
- [x] **Phase 2 done** — VRAM captured at title / gamestart / attract
  (`tools/fv_dump_vram.py`), diffed (`tools/extract_assets.py`): graphics fully
  static, only name table + OAM + 4 colour bytes vary. Assets carved into
  `assets/*.bin` (+ `manifest.txt`), rendered & eyeballed via `tools/view_assets.py`.
  No pattern unpacker needed. The 8-bank smooth-scroll trick is documented in §2.
- [x] `$B627 FrameUpdate` — **structure mapped** (§5.2) and the enemy phase
  (`$B730-$B931`) **fully decoded** (§7): 8 stride-4 slots, LFSR-seeded spawn,
  player-homing horizontal drift, `$BDE2`/`$BDE4` weave tables (exact bytes in §7),
  per-slot bullet fire. **There are no per-enemy-type AI constants** — the AI is
  uniform; the 3 "types" (score `$02`/`$03`/`$05`, sprite `$02`/`$04`/`$06`) are
  assigned every frame from the slot number `(X mod 12)` at `$B885`.
- [x] **Difficulty-ramp state machine `$52-$55,X` decoded** (§7c): not humanoid
  abduction — `$54,X` = auto-scroll floor (raised `+$20`/cycle to `$A0`), `$55,X` =
  spawn throttle (`LSR`/cycle), `$53,X` timer, `$52,X` = HUD-meter state. This is the
  only escalation in the (waveless) game.
- [x] **Collision phase fully resolved statically** (§7a): loop 1 shot→enemy
  (class `Y=($81&$30)>>2`, dy windows + BCD scores `$02/$03/$05` from `$BDFD`,
  dx `< $10` facing-relative); **loop 2** = secondary `$C2/$C3` shots vs the
  **name-table tiles** — hit if the tile under the shot is in `[$38,$4F)` → +1 pt
  (shooting ground scenery), *not* a "band"; loop 3 enemy→player box
  `dx∈[−$0D,+$0C) dy∈[−6,+5)` → `PlayerDeath`. Death FSM `$BABC` decoded.
- [x] **Scoring routine RE'd** (`$BB91/$BB93` = BCD `AddScore` + live hi-score
  update `$03C0/$03D0,Y`). **Death/respawn model RE'd**: `$56,X` = lives (game over
  at 0), `$68/$69` = death-explosion / spawn-in FSM (`$BABC`), `$4C` bit2 =
  "death done → lose life + respawn". Corrected `$4D` = fire-cooldown reload (not
  lives) and `$55,X` = **enemy-spawn-rate throttle** (`AND $49` gates the `$B73E`
  spawn; `LSR` at `$B72A` accelerates spawns through the wave — *not* a smart bomb).
  `tools/fv_probe2.py` confirms the spawn-in countdown live (demo auto-starts
  ~frame 297, spawn-in `$69` `$7F→0` from ~frame 477).
- [x] **Wave progression: there is none.** The full main-loop dispatch (`$B5B5`,
  §5.2) has only title → session → game-over (`$56` lives == 0). The world is an
  endlessly-scrolling *Defender* strip (`$40`/`$41` wrap), enemies spawn at an
  ever-increasing rate (`$55,X` throttle `LSR`s toward 0 and is only re-seeded by
  `$BD23 InitGame`, once per game). `$FBD6(0)` = **game-start** jingle (not per-wave),
  `$FBD6(6)` = game-over, `$FBD6(3)` = post-death respawn.
- [x] `$FBD6 PlaySfx` / `$BF00` **decoded** — 3-voice note-sequence player; format,
  tables and the 3 cart jingle blobs documented in §8/§9.
- [x] RE Funvision BIOS `$FA00` — **it is the controller/keyboard decode routine**, not
  sound. Called from the IRQ handler after `$FF58`. Strobes 4 PIA columns (`$1000`,
  strobe value `$F7` rotated right each of 4 passes), reads `$1002 EOR $FF` into
  `$18-$1B`, then `JSR $FE67` and decodes each column vs key tables (ptr `$FBAA/$FBAB`
  selected by `TXA:ASL:AND #2`, length `$FBAE,X`), result `ORA #$80` merged with the
  previous `$11,X` for key-repeat, stored to `$11-$14`. **Must be reproduced for MSX
  input (Phase 5): produce 4 decoded bytes from MSX joystick+keyboard.**
- [x] Resolve the `$11-$14` input-vs-wave-param question — done via live trace (§7).
- [x] RE `$FF58` — it's a **16-bit LFSR advance** (`$02:$03`), not a keyboard scan.
- [x] Input key-scancode tables located: `$FBB2` (16 B, cols 0/2) `$FBC2` (20 B, cols
  1/3). **Index→action map done (§7b)**: `$11`/`$13` = P1/P2 stick, `$16`/`$17` = fire,
  `$12`\|`$14` = start; LEFT/RIGHT = ±$20 scroll-velocity (`$42`, cooldown `$4D`),
  UP/DOWN = ±1px alt.
- [x] Is there a **smart-bomb / hyperspace** feature? **No.** `$55,X` is the spawn
  throttle (§7c), no zero-page var is written from a second fire button, and the
  input decode (§7b) produces only stick + one fire edge + start. The game has a
  single fire action.
- [x] SFX byte stream captured + decoded (`tools/sn_decode.py`); all writes via `$FE77`.
- [x] Confirm the object-model field table (§7) against live memory — **corrected to
  stride-4 / 8 slots** (`$FD30` = `DEX`×4) (`dynamic-analysis.md`).
- [x] **Timing decided: PAL / 50 Hz.** The Funvision uses a 9929 (PAL) VDP + 2 MHz
  6502; `funnymu` models 40000 cycles/frame = 50 Hz. The CreatiVision/Funvision
  shipped in both 50 Hz and 60 Hz regions, but the reference is PAL, so the port
  targets **MSX 50 Hz** — game timers, scroll speeds and sound envelopes carry over
  1:1 with no frame-rate rescale. (`tools/fv_emu.py CYCLES_PER_FRAME = 40000`.)
- [x] **SN76489 clock = φ2 = 2 MHz** (Funvision circuit diagram: SN clock pin ← 6502
  φ2, also feeding the 6821 E input). SN→AY period conversion `n_ay ≈ 1.79 · n_sn`
  (§8). `funnymu`'s `sn76496.c` uses `VDP_CLOCK/15 ≈ 3.5467 MHz` — an emulator
  approximation; its audio pitch is not a reference.
