# Planet Defender — Funvision → MSX Port Plan

## Context

Planet Defender is an 8KB Funvision (CreatiVision-family) cartridge: a *Defender*-style
horizontal shooter. The Funvision and MSX1 share the **same video chip** (TMS9918/9929),
which makes the graphics path a near-direct translation. The two hard parts are:

1. **CPU**: 6502A → Z80. No source exists, so this is a *reverse-engineer + reimplement*
   effort — disassemble the ROM, understand the game, and hand-write idiomatic Z80.
2. **Sound**: Funvision uses a **SN76489** (wired through a 6821 PIA at `$1002`); MSX uses
   an **AY-3-8910 PSG**. Different register model — the sound layer is a rewrite, not a port.
3. **Input**: the Funvision's PIA keyboard/joystick matrix is unique; remap to the MSX
   joystick + keyboard.

Decisions locked in with the user:
- **Strategy**: reverse-engineer the ROM, then reimplement in idiomatic Z80. Reuse the
  original graphics/level data blobs verbatim.
- **Target**: MSX1, tested under openMSX with the bundled `C-BIOS_MSX1` machine.
- **Fidelity**: faithful clone — match gameplay, graphics, timing and sound as closely as
  the MSX allows; adapt only what the hardware forces (sound chip, controls).

### What exploration established

- ROM layout (loaded by Funvision as an 8K cart into `$A000-$BFFF`, mirrored at `$8000`):
  - `$A000-$A7FF` mirrored to `$A800-$AFFF` (2KB, unique content).
  - `$B000-$BFFF` unique.
  - `$A000-$A1FF` looks like name-table / layout data (small byte values); `$A200`–`$B3FF`
    is pattern (tile/sprite) bitmap data; **game code clusters in `$B400-$BFFF`** (~3KB).
    Precise boundaries are an RE task.
- BIOS routines the game calls (from a JSR/JMP scan): `$FD30` (×15), `$FE77` (×10),
  `$FE1F` (×8), `$FD82`, `$FD53`, `$FDD3`, `$FEAD`, `$FBD6`, `$FD46` — these must be
  identified by disassembling `FunvisionBIOS.rom` (VDP register write, VRAM fill/copy,
  keyboard scan, RNG, etc.). **The BIOS is not ported** — its services are reimplemented
  natively or via MSX BIOS equivalents.
- Reset path: Funvision boot ROM does `JMP ($BFFC)`; real game entry must be traced.
- Likely VDP mode: Graphics I (Mode 1, 32×24 tiles + sprites) given ~2KB of pattern data —
  to be confirmed during RE by watching VDP register writes in the reference emulator.

### Toolchain present

`pasmo` and `z80asm` installed; `openmsx` 21.0 with `C-BIOS_MSX1`. Reference emulator
sources in `funvision-reference/funnymu-0.44/` (`funny.c` = VDP/PIA/sound model,
`M6502.c` = CPU core, `Debug.c` = a trace/debug monitor). A minimal Python 6502
disassembler was written during planning (`scratchpad/dis6502.py`) — move it into the repo.

## Phases

### Phase 0 — Repo scaffolding & build pipeline
- Create project tree:
  - `src/` — Z80 source (`main.asm`, `header.asm`, `vdp.asm`, `game.asm`, `enemies.asm`,
    `input.asm`, `sound.asm`)
  - `assets/` — extracted binary blobs + `manifest.txt`
  - `tools/` — `dis6502.py`, `extract_assets.py`, `view_assets.py`, reference-trace scripts
  - `docs/` — `reverse-engineering.md`, `memory-map.md`
  - `build/` — output `planetdefender.rom`
  - `Makefile`, `run.sh`
- `src/header.asm`: standard **16KB MSX ROM** cartridge header at `$4000` — `"AB"`,
  INIT word, zero the STATEMENT/DEVICE/TEXT words; code/data span `$4000-$7FFF`.
- `Makefile`: assemble with `pasmo --tap`/plain bin; pad/enforce exactly 16384 bytes.
- `run.sh`: `openmsx -machine C-BIOS_MSX1 -carta build/planetdefender.rom` plus a
  headless variant (`-command` script: boot, run N frames, `screenshot`, `exit`) for
  automated verification.
- Smoke test: INIT sets Mode 1, writes a few tiles / a test sprite, confirm via screenshot.
- Build `funnymu` (or use the shipped binary) so the original ROM can be run and traced
  for reference behaviour and screenshots.

### Phase 1 — Reverse engineer the ROM
Output: `docs/reverse-engineering.md` + `docs/memory-map.md`.
- Disassemble `FunvisionBIOS.rom` (`org $F800`); identify every BIOS entry the game calls
  (`$FD30`, `$FE77`, `$FE1F`, `$FD82`, …) — name and document each (params, effect).
- Trace the reset/entry path (`JMP ($BFFC)` → BIOS → game entry) to find the game's
  real start address.
- Disassemble the game code region (`$B400-$BFFF`, extend as needed), separating code
  from embedded data tables. Annotate:
  - VDP setup (which screen mode, register values, table base addresses).
  - Main game loop structure and frame timing (VBLANK/IRQ usage — `VDP[1]&0x20`).
  - Entity model: player ship, terrain/scanner, enemies (RE'd: one uniform AI, 8
    slots, cosmetic "type" by slot group), bullets — data structures & update code.
    (No humanoids/abduction — `$52-$55` is the difficulty ramp, §7c.)
  - Collision handling (original likely uses VDP sprite-coincidence status bit).
  - Scoring, lives, game-over (no wave progression — see §10), attract mode, high-score.
  - Sound: locate SN76489 write sites (`STA $1002` via PIA) and any sound-sequence tables.
  - Input: locate PIA reads (`$1000-$1003`) and how thrust/reverse/fire/bomb/hyperspace
    are decoded.
- Build a zero-page / `$0000-$03FF` RAM variable map (the game's working state).
- Use `funnymu`'s `Debug.c` monitor (breakpoints, memory dump, step) to confirm the
  static analysis dynamically where ambiguous.

### Phase 2 — Asset extraction ✅ DONE
The cart builds VRAM at run time (tile unpacker + tile-by-tile terrain draw), so
assets are carved from **ground-truth VRAM**, not the ROM image:
- `tools/fv_dump_vram.py` — captures VRAM at title / gamestart / attract.
- `tools/extract_assets.py` — diffs the three (graphics are 100% static; only the
  name table, OAM and 4 flashing colour bytes vary), carves `assets/*.bin` +
  `manifest.txt`.
- `tools/view_assets.py` — renders `assets/preview/*.png` for eyeball verification
  (clean font, cyan terrain, enemy sprites + "20/30/50" score chart, ship — all
  match the reference).
- Output: `patterns.bin` (clean shift-0 bank), `patterns_shift0..7.bin` (the 8
  pre-shifted smooth-scroll banks, §2), `sprite_patterns.bin`, `colour_table.bin`,
  `nametable_chrome.bin`. INCBIN'd unchanged (TMS9918 format identical on MSX1).
- Sound/movement tables live in ROM and are already documented (§8/§9) — carve at
  Phase 6 from the fixed offsets there.

### Phase 3 — Video / VDP layer (`src/vdp.asm`) — ✅ static frame verified

Done:
- `src/vdp.asm` — native VDP via ports `$98`/`$99`, no BIOS. Primitives:
  `VdpWriteReg`, `VdpSetWrite`/`VdpSetRead`, `VdpFill`, `VdpCopy` (LDIRVM-equiv),
  `WaitVBlank` (polls status bit7 — Phase 3 runs with interrupts off), `OamFlush`
  (128-byte `ShadowOAM` → `$1C00`), `SetScrollShift` (A=0..7 → R4 = `7-A`).
- `VdpInit` — writes R0..R7 from `VdpRegs` (`$00 $A2 $01 $50 $07 $38 $04 $01`),
  clears 16 K VRAM, loads `patterns.bin`→`$3800`, `sprite_patterns.bin`→`$2000`,
  `colour_table.bin`→`$1400`, then flips R1 to `$E2` (display on).
- `src/main.asm` — Phase 3 bring-up: `VdpInit`, paint `nametable_title.bin`→`$0400`
  + `oam_title.bin`→`$1C00`, idle. Builds to exactly 16384 B.
- Verified: `make headless` screenshot under `C-BIOS_MSX1_EU` reproduces the
  reference title/game-start frame — HUD bar + score meter, ringed planet + moons +
  starfield, cyan terrain silhouette with gold pods, correct colours.

Deferred to when scrolling is wired (Phase 4b):
- Build the 8 pre-shifted pattern banks. **Decided (user): port the original's
  boot generator, INCBIN raw base data from the ROM** — the banks are not raw in
  the cart (~19/88 terrain tiles verbatim). Two loops, both cracked + reproduced
  byte-exact by `tools/preshift.py` (0 misses vs `vram_attract.bin`):
  - `$B514` — 8 banks × 8 `$B27A` records `{dsthi,dstlo,srchi,srclo,ystart}`,
    copy `256-ystart` bytes; sources cart `$B038/$B078/$B0C8` + BIOS `$F7D0/
    $F850/$F870/$F8A0/$F8B8`. HUD/font/scanner ($59-$7F, $E0-$FF), same in all banks.
  - `$B547` — `slot=$58..0`: E = `$B000 + 8*B1C8[slot]`, F (left neighbour) =
    `$B000 + 8*B1C8[B221[slot]]`; 8 passes write E to bank then `{E:F}<<=1` per
    row, bank += `$0800`; banks `$0000`(7px)…`$3800`(0px). Terrain ($01-$58).
  INCBIN `assets/preshift_rom.bin` (674 B) + `assets/bios_font.bin` (496 B).
  Golden: `build/re/pattern_banks_golden.bin`.  ✅ done in 4b.
- Per-frame R4 write = `7 - (($44>>5)&7)`.  ✅ done in 4b (in `DrawTerrain`).
- VBLANK-synced OAM flush from an actual ISR (Phase 3 polls instead).

### Phase 4 — Core game logic (`src/game.asm`, `src/enemies.asm`)

Broken into sub-phases (each builds + verifies against the reference emulator):

- **4a — frame skeleton + player** ✅ DONE. `src/game.asm`: zp mirrored 1:1 at
  `zp` = `$C000`; `GameInit` / `InitGame` (`$BD23`) / `InitPlayer` (`$BD60`) /
  `ParkSprites` (`$BD83`) / `ClearObjStates` (`$BD8F`); `StepRng` (16-bit LFSR,
  `$FF58`); `WorldScroll` accumulator (`$B400-$B42F`, no R4/terrain yet);
  `PlayerControl` — full port of `$B65B-$B6FE` (altitude clamp `[$1C,$AC]`,
  thrust/reverse `$42` ±$20 with `$4F` latch + `$48` cooldown, facing flip,
  world-X drift `[$30,$C0]`, scanner echo); `RampUpdate` (`$B6FF-$B72F`);
  `PlayerShot` (spawn on fire edge + travel/retire). `OamFlush` does the reversed
  `$80..$DF` copy + `$D0` terminator. `src/input.asm` — BIOS `GTSTCK`/`GTTRIG`
  stub → `$11`/`$12`/`$16` (Phase 5 makes it native). `src/main.asm` forces a
  live session; no interrupts (poll vblank). Verified under `C-BIOS_MSX1_EU`:
  ship spawns, moves in X (drift) and Y (cursor-up), fire path runs.
  Deviations flagged for later: spawn-in FSM skipped (`$68`:=`$FF`), 1-player
  hardcoded, `DrawHUD`/`SoundDispatch` are `ret` stubs.
- **4b — world scroll + terrain** ✅ DONE. `VdpInit` calls `PreShiftHudFont`
  (`$B514`) + `PreShiftTerrain` (`$B547`), then loads `sprite_patterns.bin` over
  bank 4 — MSX VRAM diffs **1272/1272** referenced tile-slots vs
  `build/re/pattern_banks_golden.bin`. `DrawTerrain` (`$B431`) in `src/game.asm`,
  called from the **main loop** right after `WaitVBlank` + `WorldScroll` (mirrors
  the original `$B5B5` order): writes name-table rows 12-23 straight to VRAM from
  `assets/terrain_map.bin` (cart `$A000-$A217`) through the wrapping column window
  (`$40 = $45&$3F`, `$41 = (($45&$40)>>1)|$1F`; main block as two straight
  descending-run `out` loops, ~5 ms for all 384 cells), then
  `R4 = 7-(($44>>5)&7)`. Verified frame-by-frame at a breakpoint under
  `C-BIOS_MSX1_EU` vs a faithful Python re-model of `$B431` — name table + R4
  exact every frame, steady 50 fps.
  **Three fixes that mattered** (all "interrupts must stay off"):
  1. `di`/`ei` inside `VdpWriteReg`/`VdpSetWrite`/`VdpSetRead` re-enabled
     interrupts during `VdpInit`; a C-BIOS VBlank ISR between the two VDP
     control-port writes corrupted one in-progress VRAM write (`$2800`/`$51`).
     Removed the pair. → 1272/1272.
  2. MSX BIOS `GTSTCK`/`GTTRIG` return with interrupts **enabled** — the C-BIOS
     ISR then ate the vblank flag before `WaitVBlank` saw it and the game ran at
     ~16 fps. `ReadInput` now ends with `di`. → 50 fps.
  3. VRAM writes moved to the top of the frame (before `ReadInput`/logic) so the
     name-table write finishes before the raster returns to those rows — no
     tearing.
- **4c — shots** ✅ DONE. `PlayerShot` in `src/game.asm` ports the fire hook
  `$B918-$B94F` (spawn: `$D6 = PLRX +$20` right / `-$10` left, `$D7 = PLRY-$08`,
  `$D5 = $D4` pattern, `$D4` attr = `($80 & $43) ^ $8F`, `$6A = $43`, `$20 = $0E`
  fire SFX id) and the travel/retire preamble `$B9B1-$B9CD` (gate `$D7 < $C0`;
  step `$D6` by `-$10` when `$6A` ≥ 0, `+$10` when `$6A` < 0 — i.e. **opposite**
  the facing bit, faithful to `LDX $6A; BMI`; walk off an edge → `$D7 = $E0`).
  The shot record lives at `zp+$D4` inside the shadow-OAM window, so `OamFlush`
  renders it as sprite slot 21 with no extra code — verified under
  `C-BIOS_MSX1_EU` (spawn X/Y, `-$10`/frame travel, edge-retire all match the
  disasm frame-by-frame). The secondary `$C0-$C7` slots are **vestigial dead
  code** (`$B94F: JMP $B984` + `$B922: BEQ $B984` skip the only spawn at
  `$B952-$B983`; never populate over 600 frames of firing in `fv_emu`) — not
  ported. Shot→enemy / shot→terrain collision is Phase 4e.
  Fire input: `ReadInput` now calls `GTTRIG` with `A=0` (space bar / any
  trigger) — `C-BIOS_MSX1_EU` exposes no joystick ports, so `A=1` never fired.
- **4d — enemies** ✅ DONE. `src/enemies.asm` ports the enemy-update phase
  `$B730-$B916` (§7): `EnSpawn` (gate `(SPAWNTHROTTLE & FRAMECTR)` then
  `($1A & RNGhi)`, LFSR-seeded slot fill), `EnDriftBase`
  (`EN_D04 = max(0, SCROLLSPD-SCROLLFLOOR)`), `EnDrift` (player-homing horizontal
  drift, `$BB73`/`$BB82` ± branch), `EnWeave` (`$BDE2`/`$BDE4` overlapped step
  tables, band-clamp Yhi `[$03,$16)`), `EnProject` (`worldX/Y << 3 >> 8` to
  sprite, `g = X mod 12` group colour `assets/enemy_tables.bin`, hide off-strip),
  `EnTickFire` (`FLIP4A` alternating-half fire gate → enemy bullets `$A0-$A3,X`
  col `$0F`/pat `$DC`, off-left-edge despawn). One AI, 8 stride-4 slots; per-slot
  access via `ix = zp+$80+X` / `iy = zp+$300+X` rebuilt each iteration.
  Hand-translated from `tools/enemy_model.py` (validated byte-exact vs the ROM
  over 279 frames); verified under `C-BIOS_MSX1_EU` — screenX/Y projection,
  group colours ($02/$04/$06), speeds ($10-$17), weave reload, alternating
  bullet gate all match the model. Enemy bullets are set-and-forget (never
  advanced) — faithful to the original. Collisions are 4e.
  - **4d fix (2026-09-01):** `EnWeave` dropped the lo→hi carry in the 16-bit
    `worldY += WYstep` add — a stray `add hl,de` (fetching the WY_HI table byte)
    between the `add a` and the `adc a` clobbered CF, so downward drift (phases
    that carry out of the low byte) was lost while the `$FF` hi-byte phases still
    pulled up. Result: every enemy magneted to the top clamp line `wYhi=$03`.
    Fixed by fetching both step-table bytes into `bc` before the add pair.
- **4e — collisions + death** ✅ DONE. `src/death.asm`: collision loop 1
  (primary shot `$D6/$D7` vs 8 enemy slots — class-banded `dy` via `CollTab`
  `$BDFD`, facing-relative `dx < $10`; on hit set explosion bits, retire shot,
  `AddScore`), loop 3 (enemy box vs ship `dy∈[-6,+5) dx∈[-$0D,+$0C)` → death).
  Loop 2 (vestigial secondary shots) not ported. `AddScore` = 16-bit BCD add +
  live hi-score refresh at `$03C0`/`$03D0`[GAMECFG&$0F]. `PlayerDeath` +
  `DeathRespawnFSM` port the `$68`/`$69` state machine (`$BABC`): spawn-in
  ($68=0, $69 counts $7F→0), explosion ($68=1..3, $69 up to `DeathLim`
  `$BDF5`), debris-cross layout into sprite slots 0-7, `STATE` bit2 → respawn
  (lose a life, `InitPlayer`), lives 0 → game over → `StartSession`. `GameFrame`
  now dispatches on `$68` (spawn-in FSM runs at boot; the 4a `$68:=$FF` hack
  removed). `GameInit` split into `GameInit`/`StartSession`. Verified under
  `C-BIOS_MSX1_EU`: shot kills score + clear enemy, ship contact → explosion →
  respawn → field clears (`ClearObjStates`) → lives decrement → game-over restart.
- **4f — HUD + ramp meter + title/attract** (sliced) — slices 1-4 ✅ DONE;
  attract demo (`$FE83` score cycler + `$BCF2` timeout auto-play) and all
  jingles deferred to Phase 5/6:
  - _slice 1 — score / hi-score / lives_ ✅ DONE. Native `DrawHUD` in
    `src/game.asm` (no BIOS): P1 BCD score → name-table `$0443`, live hi-score
    → `$0458` (5 digit tiles each, `digit + $E0`, trailing literal 0), ship-icon
    tiles `$7E` → `$0423` for lives. Reimplements `$BBBF` (called from the
    OAM-flush tail `$B4E2`) + the lives-icon loop `$BC46`. Wired into `MainLoop`
    right after `OamFlush`. Verified under `C-BIOS_MSX1_EU`: score/hi-score
    digits and lives icons render and track their zp values.
  - _slice 2 — ramp meter + HUD labels_ ✅ DONE. `VdpRunScript` in `src/vdp.asm`
    ports BIOS `$FD53` (VDP script = `{addrHi,addrLo,count,bytes}` blocks,
    0-terminated; addr high byte `EOR $80` like `$FE1F`). `DrawHUD` runs the
    ramp script `RampScrTab[$52]` → `$A440` (state 0/4, restore default colour
    table) / `$BE19` (state 2) / `$BE29` (state 6): each rewrites colour-table
    entries 0-11 at VRAM `$1400`, so the terrain/meter cells shift hue as
    difficulty climbs. Plus the 1-player label scripts `$BFC0` (blank
    `$0403-05`) and `$BFDE` ("HIGH" at `$0418-1B`). Script blobs carved raw to
    `assets/hud_scripts.bin` (`tools/carve_hud_scripts.py`, 67 B). Verified
    under `C-BIOS_MSX1_EU`: colour table tracks `RAMPSTATE` (default / `$77` /
    `$88` bands); terrain visibly reddens at state 6.
  - _slice 3 — title screen_ ✅ DONE. `GameInit` now leaves STATE = 0 (title)
    instead of calling `StartSession`. `GameFrame` gates on STATE bit6
    (`$B5CB`): clear → `GF_title` (runs `InitGame` every frame like `$BD23`,
    forces `SCROLLSPD`/`SCROLLACC` = 0 so the terrain is static — the port's
    main loop always calls `WorldScroll`, unlike the original's title path;
    press start `$12|$14` → `StartSession` sets bit6 + inits the player, spawn-in
    FSM follows). `GF_gameover` now clears STATE bits 6+0 → back to title
    (`$B61E`) instead of the 4e `StartSession` placeholder. Verified under
    `C-BIOS_MSX1_EU`: boot → static title, press start → session begins,
    play → lives out → title → start → new session. Deferred: `$FE83` attract
    score cycler, `$BCF2` attract-timeout auto-demo, title jingle (Phase 5/6).
  - _slice 4 — game-over banner_ ✅ DONE. `$BFB1` (" GAME OVER ", 11 tiles at
    name `$058A` = row 12 col 10) carved into `assets/hud_scripts.bin`
    (`GameOverScr`, +67). `GF_gameover` (lives==0) parks sprites, runs the
    script via `VdpRunScript`, sets STATE bit1 (banner-pending) and clears
    bits 6+0 (`$B61E`). The main loop now skips `WorldScroll`/`DrawTerrain`
    while bit6 is clear (`ML_nofield` — matches `$B5B5`, whose title path never
    calls `$B400`/`$B431`), so the frozen field + banner persist; `GF_title`
    repaints the banner each frame while bit1 is set. Press start →
    `StartSession` (STATE=$40 clears bit1); the next frame's `DrawTerrain`
    wipes the banner (`$B5E6`). Verified under `C-BIOS_MSX1_EU`: die out →
    "GAME OVER" over a frozen field, no stray sprites, HUD intact → start →
    clean new session. Deferred: sound 6 (Phase 6).

Original contract (all sub-phases):
  - Frame loop driven by the VDP VBLANK interrupt (**PAL 50 Hz** — the Funvision
    reference is PAL: 9929 VDP, 2 MHz 6502, funnymu 40000 cyc/frame).
  - Player ship: `$42` = scroll velocity `[0,$A0]` stepped ±$20 by LEFT/RIGHT
    (cooldown `$48`←`$4D`), floored at `$54,X`, facing `$43` flips at 0; ±1px
    altitude (`$DB`); world scrolling (`$44/$45` += `$42`) & the mini-scanner
    (`$D8-$DF`). *Defender* thrust/reverse, not a dash (see §7b note).
  - Enemy AI (§7): **one uniform routine** — LFSR-seeded spawn, player-homing
    horizontal drift, `$BDE2`/`$BDE4` weave. No per-type constants: the 3 "types"
    (score `$02`/`$03`/`$05`, sprite `$02`/`$04`/`$06`) are just `(slot mod 12)`.
  - Difficulty ramp (§7c): timer `$53,X` → raise scroll floor `$54,X` `+$20` (cap
    `$A0`, wrap) and `LSR` spawn throttle `$55,X`; redraw the HUD meter (`$52,X`).
  - Player shots: primary scratch `$D6/$D7` + `$C0-$C3` slot shots. Single fire
    action — no smart bomb / hyperspace (confirmed absent, §7b/§7c).
  - Collision: box checks (§7a) — loop 1 shot→enemy (per-class dy window + BCD score
    `$02/$03/$05`), loop 2 shot→name-table tile in `[$38,$4F)` = +1, loop 3
    enemy→player `dx∈[−$0D,+$0C) dy∈[−6,+5)`.
  - Score, bonus, lives (`$56,X`), game-over at 0 lives (no wave structure — endless
    survival, spawn rate ramps via `$55,X`), attract/demo mode, live high-score
    (`$03C0/$03D0`).
- Keep RAM layout documented in `docs/memory-map.md` (MSX RAM at `$C000-$FFFF`).
- Calibrate speed against `funnymu` running the original side by side.

### Phase 5 — Input (`src/input.asm`) — ✅ DONE

Native PPI keyboard-matrix scan, **no BIOS** (C-BIOS_MSX1_EU exposes no joystick
ports and no `GTSTCK`/`GTTRIG` we want on the hot path). `KbdRow` selects a row in
PPI `$AA` bits 0-3 (bits 4-7 preserved) and reads PPI `$A9`; a matrix bit is 0
while its key is held. `ReadInput` keeps the terminating `di` (poll-vblank loop).

Maps to the original contract (`docs/reverse-engineering.md` §7b):
- cursor keys (row 8: LEFT $10 / RIGHT $80 / UP $20 / DOWN $40) → `$11` direction
  index `$80|idx`, priority LEFT > RIGHT > UP > DOWN. idx: LEFT $8D, RIGHT $85,
  UP $89, DOWN $81 (bit2 = L/R axis, bit3 = UP-or-LEFT — the `$FBB2` bits
  `PlayerControl` tests). UP/DOWN = ±1px `$DB`; LEFT/RIGHT = ±$20 `$42` gated by
  cooldown `$48`←`$4D`, facing flip `$43` at `$42`==0.
- SPACE (row 8 bit0) → `$16` fire new-press edge (`$0C` for one frame; `FIREPREV`
  at `$C3F0` holds the previous level) → spawn shot `$D4-$D7`. Single-fire, no
  auto-repeat.
- SPACE | RETURN (row 7 bit7) → `$12` start byte ($FF held / $00 released);
  `$14` left 0. (Original: "press 6 or B".)
- P2 (`$13`/`$17`), raw columns (`$18-$1B`), fire-status (`$15`) unused by the
  port — left 0. No smart-bomb / hyperspace input exists.

Verified under `C-BIOS_MSX1_EU` (`keymatrixdown`/`up` probes): title held until
SPACE; LEFT/RIGHT drive `$42`/`$43`; UP/DOWN drive `$DB`; SPACE fires exactly one
shot per press once the ship is alive.

### Phase 6 — Sound (`src/sound.asm`) — ✅ DONE

Verified under `C-BIOS_MSX1_EU` (openMSX PSG-register probes): 3-voice jingles
id 0 / 3 / 6, the per-frame SFX mixer (fire descending sweep, death/ground
rumble + noise, spawn-in warp tone, shot-kill noise tail), and the direct
`$E4` noise bursts all produce correct AY register activity with a stable SP.

- `SnWrite` — SN76489 command-byte → PSG-register translator. Tracks 4 shadow
  registers (ch 0/1/2 tone period, ch 0/1/2/noise attenuation) + an R7 mixer
  shadow. `ConvPeriod`: `n_ay = (n_sn·57) >> 5` (= 1.781, SN clock = φ2 2 MHz),
  clamped `[1,4095]`. Attenuation `ay_amp = 15 − sn_att`. SN noise (only ever
  `$E4` white / rate 0) routes to AY channel C (R7 bit5=0, bit2=1; R6=1;
  R10 = 15 − att); noise-off restores tone-C from the ch2 tone volume.
- `SoundTick` — port of `$BC83` (per-frame mixer), called from `GameFrame`
  every live frame before the player/enemy dispatch. 4 sections keyed off
  `$20` / `$23`+`$24` / `$68` / `$25`, tables from `assets/sound_sfx.bin`
  (cart `$BD9C-$BDE1` verbatim).
- `PlaySfx(id)` — port of BIOS `$FBD6`, blocking 3-voice jingle player.
  id 0 game-start (`GF_title` after `StartSession`), id 3 respawn, id 6
  game-over. Sequences read backwards from a start index; per-voice envelope
  steps down every 8 ticks. `JngDelay` busy-waits `J_TEMPO·172` djnz per tempo
  tick (≈ 10 ms for tempo `$10`, matching the 6502 `$0E·256·4` loop). Tables +
  records + sequences from `assets/sound_jingle.bin` (BIOS `$FC79/$FC80/$FCAA/
  $FCD5` + cart `$BF00/$BF20/$BEC0/$BF80`), carved by `tools/carve_sound.py`.
- Direct noise bursts: `$BA1B` (enemy killed by shot) and `$BA9B` (ship death)
  → `SnWrite($E4)` at the collision sites in `src/death.asm`.

**Bug found + fixed during bring-up:** `SnWrite` pushes BC/DE/HL on entry; the
noise-attenuation branch `jp`-ed (not `call`-ed) into a `ret`-terminated helper,
so the `ret` popped a stack word as its return address → SP corruption + wild
jump. Manifested as an apparent "hang" (Z80 crashed into C-BIOS/RAM garbage).

<details><summary>original design notes</summary>

- Write an **SN76489 → AY-3-8910** translation layer:
  - 3 square-wave tone channels: convert SN period → AY 12-bit period. Funvision SN
    clock = φ2 = 2 MHz (circuit diagram), AY clock ≈ 1.7897 MHz → `n_ay ≈ 1.79 · n_sn`
    (≈ 16/9; see `docs/reverse-engineering.md` §8). NB the Coleco reference layer
    assumes SN = 3.579 MHz (`n_ay ≈ n_sn`) — do not reuse that constant here.
  - Noise channel: map SN noise modes to the AY noise generator + mixer.
  - Volume: SN 4-bit attenuation (log) → AY 4-bit amplitude (also log) via a lookup table.
- Drive it from the sound-trigger points / sequence tables found in Phase 1, so the
  effect set (fire, explosion, ground hit, death sweep, start/respawn/game-over jingles)
  matches the original.
- PSG access via BIOS `WRTPSG` or direct ports `$A0/$A1`.
- **Reuse** the ColecoVision→MSX SN76489→AY layer in `coleco-to-msx-reference/`
  (`donkeykong.rom` ≈ `$D600-$DBFF`) — helper routines + conversion constants are
  written up in `docs/coleco-to-msx-sound.md`.

</details>

### Phase 7 — Integration, polish, timing
- Full playthrough parity pass vs `funnymu`: enemy counts, speeds, wave cadence, scoring,
  extra-life thresholds, attract loop.
- Fix timing drift. **Target MSX 50 Hz** (matches the PAL reference 1:1 — no timer
  rescaling). If run on a 60 Hz MSX the game will play ~20 % fast; acceptable, or
  gate the frame step on a 50 Hz software divider.
- Title/attract screen, high-score persistence in RAM for the session.

### Phase 8 — Packaging & verification
- Final `build/planetdefender.rom` — exactly 16384 bytes, valid MSX header.
- `docs/` updated; README with controls and build/run instructions.
- Automated check: `run.sh --headless` boots under `C-BIOS_MSX1`, runs the attract loop,
  captures screenshots, and diffs against reference stills.

## Critical files

| File | Purpose |
|---|---|
| `src/header.asm` | MSX 16KB cartridge header + INIT entry |
| `src/main.asm` | startup, interrupt hook, main loop dispatch |
| `src/vdp.asm` | TMS9918 init + name-table/OAM/VRAM primitives |
| `src/game.asm`, `src/enemies.asm` | reimplemented game logic |
| `src/input.asm` | MSX joystick/keyboard → game controls |
| `src/sound.asm` | SN76489→AY-3-8910 sound layer |
| `assets/*.bin` + `assets/manifest.txt` | verbatim graphics/table data from the ROM |
| `tools/dis6502.py` | 6502 disassembler (from planning) |
| `tools/extract_assets.py`, `tools/view_assets.py` | asset carving + verification |
| `docs/reverse-engineering.md`, `docs/memory-map.md` | RE findings, the contract for Phase 3–6 |
| `Makefile`, `run.sh` | build + openMSX run/headless test |

## Reference material to reuse (do not reinvent)

- `funvision-reference/funnymu-0.44/funny.c` — authoritative model of the Funvision VDP
  address latch, PIA (`$1000-$1003`), sound wiring (`SN76496Write` on write to `$1002`
  unless value `$90`), TMS9918 palette, sprite-collision algorithm. Mirror its semantics.
- `funvision-reference/funnymu-0.44/M6502.c` / `Codes.h` — 6502 opcode semantics for
  translating tricky routines (decimal mode, flag behaviour).
- `funvision-reference/funnymu-0.44/sn76496.c` — SN76489 period/volume math for the
  sound translation table.
- `funvision-reference/funnymu-0.44/Debug.c` — built-in monitor for dynamic tracing.
- `funvision-reference/funnymu-0.44/funvision-tech.txt` — memory map, keyboard matrix.

## Verification

- **Per phase**: build with `make`, run `./run.sh`, screenshot under `C-BIOS_MSX1`,
  compare with `funnymu` running `PlanetDefender.rom`.
- **Graphics**: `tools/view_assets.py` PNGs vs reference screenshots.
- **Logic/timing**: side-by-side play vs `funnymu`; check wave cadence, scoring,
  extra-life points, attract loop length.
- **Final**: `./run.sh --headless` boots the 16KB ROM, runs the attract loop, captures
  and diffs screenshots; assert ROM is exactly 16384 bytes with a valid header.
