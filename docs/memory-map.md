# Memory Map

## Funvision (source)

| Range | Use |
|---|---|
| `$0000-$00FF` | zero page — game working variables (see below) |
| `$0100-$01FF` | 6502 stack |
| `$0200-$03FF` | RAM — tables / buffers. 1K total RAM, mirrored ×4 to `$0FFF`. |
| `$1000-$1003` | 6821 PIA (A data/ctrl, B data/ctrl). B = keyboard/joystick + sound. |
| `$2000-$2001` | VDP read (data, status) |
| `$3000-$3001` | VDP write (data, control) |
| `$8000-$BFFF` | cartridge (8K image, mirrored into both halves) |
| `$C000-$FFFF` | 2K boot ROM, mirrored ×8 |

### Zero-page / RAM variables (from static RE — see reverse-engineering.md §5–§9)

| Addr | Name | Meaning |
|---|---|---|
| `$00-$01` | `ptrS` | indirect pointer (BIOS SFX) |
| `$02-$03` | `rng` | **16-bit LFSR** (low:high), advanced one bit per IRQ by `$FF58` (feedback = `bit6($03) ^ bit5($03)`). PRNG for spawn positions / wave params. |
| `$04-$05` | `tmp` / `vramHi` | scratch; `$05` = VRAM-addr-hi accumulator in init |
| `$06-$07` | `ptr0` | 16-bit indirect pointer / 16-bit shift accumulator (`$BC73`) |
| `$08` | `idx` | init loop index; SFX toggle |
| `$09-$0A` | `ptr1` / `cnt` | BIOS script pointer; loop counter |
| `$0B` | scratch | |
| `$0C` | `vblFlag` | VDP status byte, stored every IRQ; bit7 = vblank. Main loop spins on it. |
| `$0D` | `gameCfg` | difficulty/config nibble: bit0 = 1-player, bit1 = scroll-floor init (`$40` vs `$80`), bit2 = difficulty (sets `$4D` fire-cooldown reload 4 vs 2) |
| `$0E` | scratch | Bin2Dec / SFX duration temp |
| `$0F` | `statDelay` | BIOS StatusRefresh sub-counter |
| `$11-$14` | `keyDec[]` | **decoded input**, written every IRQ by BIOS `$FA00`, one byte per matrix column (X=0..3 → col 14,13,11,7). Value = table index with bit7 = pressed-this-frame; `EOR #$C0` (→ bit6) when the key was already held (repeat). `$11`/`$13` use key-table `$FBB2`, `$12`/`$14` use `$FBC2`. **`$11` = P1 direction (left stick)**, **`$13` = P2 direction (right stick)** — read at `$B660` `LDA $11,X` (X=`$4E>>2`). **`$12`\|`$14` non-zero = the start / leave-title trigger** (`$B5D7`,`$B5F7`) — "press 6 or B" (both col 13 → `$12`). The game clears `$11-$14` each frame after consuming them; idle frames also let `$BCF2` reuse `$11` as a behaviour selector. See reverse-engineering.md §7b. |
| `$10` | scratch | zeroed by `$FA00` each frame |
| `$15` | `keyBit7` | assembled by `$FA00` from bit7 of each column: `b3`=col7 `b2`=col11 `b1`=col13 `b0`=col14 (the 4 fire lines) |
| `$16`,`$17` | `fireDec` / `waveParam` | `$FA00` rolls the fire-line bits (via `$FB49`) into `$16` (P1) / `$17` (P2): `b3:b2` = new-press edge, `b1:b0` = raw level. Read at `$B91E` `LDA $16,X; AND #$0C` (X=`$4E>>3`) to spawn a shot. When there is no live input `$BCF2` overwrites `$16` with an RNG-sampled spawn-type. |
| `$18-$1B` | `keyRaw[]` | raw 4 PIA column reads (`$1002 EOR $FF`) for strobes `$FE,$FD,$FB,$F7`, written every IRQ by `$FA00` before decode |
| `$1D` | `keyNcols` | `$FA00`: count of columns with a key pressed this frame |
| `$1E` | `keyLastCol` | `$FA00`: index of the last active column |
| `$20` | `sfxExplode` | explosion SFX countdown (`$BC83`) |
| `$22`,`$23`,`$24`,`$25` | `sfx*` | misc SFX timers/counters |
| `$40-$41` | `colWin` | visible scroll-column window lo/hi |
| `$42` | `scrollSpd` | world scroll velocity, `[0,$A0]` stepped by `$20` (LEFT/RIGHT, cooldown `$48`←`$4D`); floored at `$54,X`; facing `$43` flips when it reaches 0. Added to `$44/$45` each frame by `WorldScroll`. Not a ship-X position. |
| `$43` | `facing` | player facing (bit7) / scroll direction |
| `$44-$45` | `scrollAcc` | scroll position accumulator |
| `$46-$47` | `plrWorldX` / `plrAlt` | player world X, altitude |
| `$48` | `fireCd` | fire cooldown |
| `$49` | `frameCtr` | incremented each `WorldScroll` |
| `$4A` | `flashCol` | terrain colour flash toggle |
| `$4B` | `attractCt` | attract-mode countdown |
| `$4C` | `state` | master flags (see reverse-engineering.md §5.2): **bit7 true attract** (skip input read), **bit6 game session active** (set on start/attract-timeout), **bit2 death sequence finished → lose a life + respawn** (set at `$BAD9`). bit0 is tested (`$B5F1`) but never set in the cart — dead path |
| `$4D` | `fireCdReload` | fire-cooldown reload value: `$04` (easy) / `$02` (hard) per `$0D` bit2; copied to `$48` after each shot (`$B6D9`) |
| `$4E` | `curPlr` | current player select (`$00` / `$08`) |
| `$4F` | scratch | dive-state latch |
| `$50-$51,X` | `score` | 16-bit BCD score, X = `$4E`. Live high score mirrored at `$03C0,Y` (hi) / `$03D0,Y` (lo), Y = `$0D` (`$BB93`) |
| `$52,X` | `rampState` | difficulty-ramp state, cycles `0→2→4→6` (reverse-engineering.md §7c); also selects the HUD-meter VDP script `$BE11[y]`/`$BE12[y]` run by `$BBFA` |
| `$53,X` | `rampTimer` | ramp countdown; state advances at 0 |
| `$54,X` | `scrollFloor` | auto-scroll floor = minimum `$42`. Init `$40`/`$80` (`$0D` bit1); ramp raises it `+$20`/cycle to `$A0` then wraps. Also `$04 = max(0,$42−$54,X)` = the enemy horizontal-drift base. |
| `$55,X` | `spawnThrottle` | enemy-spawn-rate gate, init `%111` (`$BD33`). `$B732: LDA $55,X; AND $49` (frame ctr) `BNE` → skip the spawn in `$B73E`; `LSR $55,X` at `$B72A` each ramp cycle, so spawns **accelerate** over the game (`%111→%011→%001→0` = spawn every eligible frame). Only re-seeded by `InitGame`. Not a smart bomb. |
| `$56,X` | `lives` | lives remaining (init `$03` by `$BD23`; `DEC` on death; game over when `$56 == 0`) |
| `$5E` | `(vestigial)` | 2-player leftover — only ever written `$00` (conditionally, `$BD5D`), read once (`$B60B`) |
| `$60-$62,X` | `pbTimer` | player-bullet timers / phase (stride 4, 4 slots `X ∈ {0,4,8,$0C}`) |
| `$68` | `plrPhase` | player-state FSM (`$BABC`): `$FF` alive · `$00` spawning-in · `$01-$03` death-explosion phase |
| `$69` | `phaseCt` | phase counter: spawn-in counts down `$7F`→0; death-explosion counts up to `$BDF5[$68]` |
| `$6A` | scratch | |
| `$6B` | `waveSeed` | cached wave RNG seed |
| `$6C-$6D` | `plrYband` | player Y collision band (`$DB ± $0C`) |
| `$80-$83,X` | `oam` | shadow OAM per object, **stride 4**: `[attr, pattern#, screenX, screenY]` (screenY `$E0` = hidden). **8 enemy slots** `X ∈ {0,4,8,$0C,$10,$14,$18,$1C}` (iterator step = `$FD30` = `X−=4`) |
| `$A0-$A3,X` | `oamBul` | shadow OAM per enemy bullet, stride 4, 4 slots `X ∈ {0,4,8,$0C}`, pattern `$DC` |
| `$C0-$C3,X` | `pbOam` | player-bullet OAM/state, stride 4, 4 slots `X ∈ {0,4,8,$0C}`; `$C3,X = $E0` = inactive |
| `$D4-$D7` | `shot` | primary player shot scratch: `$D4/$D5` = pattern/attr (`$D4` from `$8F ^ ($43 & $80)`), `$D6` = shot screen-X, `$D7` = shot screen-Y (`$E0` = no shot). Collision loop 1 tests `$D6/$D7` vs enemies. |
| `$D8-$DF` | `scanner` | mini-scanner echo state, reset (8 bytes) from `$BE09` = `02 D0 78 80 06 C0 81 80`. `$DA/$DB` = player world-X / screen-Y (alt); `$DE/$DF` = scanner blip. |
| `$E0-$E3,X` | `posFix` | per-object 16-bit LE position: `$E0/$E1,X` = X, `$E2/$E3,X` = Y (16-bit LE). Stride 4, 8 slots. |
| `$E8-$EF` | `shiftSrc` | paired rotate source in the init pre-shifter |
| `$0300-$0303,X` | `objSpd` | `$0300,X` = base |velocity|, seeded `(($02>>1)&7)+$10` → `$10-$17`; stride 4, 8 slots |
| `$0320,X` | `objState` | object state (`$00` free / `$FF` active / `$01-$7F` spawn countdown / `<0` explode); stride 4, 8 slots |
| `$0340-$0342,X` | `objAnim` | `$0340,X` weave down-counter / `$0341,X` frame index 0-7 (into weave table `$BDE2`) / `$0342,X` 2nd timer (reload `$17`, drives `$81` pattern-anim bits); stride 4 |
| `$0380-$0389` | `debrisTmp` | death-explosion debris sprite offsets, laid out from `±$69` by `$BABC` (grow then shrink) |
| `$03C0-$03DF` | `hiScore` | high-score table (`$03C0,Y` hi / `$03D0,Y` lo) |

### Data tables in ROM

See reverse-engineering.md §9 for the full list. Feeds `tools/extract_assets.py`
(Phase 2). Pattern/name/colour bitmap source is `$A000-$B0FF` (packed).

## MSX (target)

Standard MSX1, 16 KB ROM cartridge in pages 1–2.

| Range | Use |
|---|---|
| `$0000-$3FFF` | MSX BIOS ROM (slot 0) |
| `$4000-$7FFF` | **our cartridge ROM** (16 KB): header + code + INCBIN'd assets |
| `$8000-$BFFF` | (unused by us / BASIC ROM area) |
| `$C000-$FFFF` | RAM — game working variables, stack, buffers |
| ports `$98/$99` | VDP data / control |
| ports `$A0/$A1` | PSG address / data |
| port `$A8` | PPI slot select |
| port `$A9/$AA` | PPI keyboard row / misc |

### VRAM layout (kept identical to the Funvision)

Register values from the dynamic trace. **R4 (pattern-generator base) is
bank-switched at runtime**: `$07` → `$3800` on the title/init screen, `$05` →
`$2800` during the demo/game. The cart's `$BFF4` seed byte alone does not tell you
the running value.

| Base | Table | Reg |
|---|---|---|
| `$0400` | name table | R2 = `$01` |
| `$1400` | colour table | R3 = `$50` |
| `$1C00` | sprite attribute table / OAM | R5 = `$38` |
| `$2000` | sprite pattern generator | R6 = `$04` |
| `$2800` / `$3800` | pattern generator (banked) | R4 = `$05` / `$07` |

### MSX RAM layout (`$C000+`) — as built (Phase 3/4a)

| Range | Use |
|---|---|
| `$C000-$C0FF` | direct 1:1 port of Funvision zero page (`zp` = `$C000`). Shadow OAM is the original's `$80-$DF` = `$C080-$C0DF`. |
| `$C100-$C3EF` | port of Funvision `$0100-$03FF` (`$0300` speeds, `$0320` states, `$0340` anim, `$0380` debris, `$03C0` hi-score) |
| `$C3F0-$C3FF` | port-only scratch (`input.asm` `TRIGPREV`) |
| `$F380` | Z80 stack top (`ld sp,$F380`) — below the MSX BIOS work area, which C-BIOS has already initialised before calling our INIT |

> **Interrupt model (decided Phase 3):** fully polled — `DI` for the whole run,
> the main loop spins on the VDP status flag (port `$99` bit7) for vblank. No IM 1
> handler, no H.TIMI hook. `StepRng` + input refresh + `OamFlush` run at the top of
> each frame instead of in an ISR (the original did them in the BIOS IRQ). R1 keeps
> its `$E2` IRQ-enable bit (matches the original register value) but the CPU ignores
> the line under `DI`. Revisit only if a mid-frame raster effect is ever needed.
>
> Input (Phase 4a) still calls MSX BIOS `GTSTCK`/`GTTRIG` — safe under `DI` (no
> interrupt dependency). Phase 5 replaces it with a native PPI/PSG scan.
