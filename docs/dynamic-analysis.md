# Dynamic Analysis — running the original ROM

Static disassembly took the RE as far as it usefully goes (see
`reverse-engineering.md`). To confirm the object model, the enemy-AI code path,
sound output and — for Phase 2 — the real VRAM contents, we run the actual game
under a headless 6502 machine harness.

## Tooling

`tools/fv_emu.py` — a **headless Funvision machine** built on `py65` (`pip install
py65`, pure-Python 6502 core). It models only what's needed to boot and run:

- 1 KB RAM mirrored ×4 over `$0000-$0FFF`
- 6821 PIA at `$1000-$1003`: port-A strobe select, port-B = keyboard/joystick in
  (idle returns `$FF` per column → `$18-$1B` decode to `0`), and the SN76489 byte
  strobe on writes to `$1002` (value `≠ $90`) — logged, not synthesised.
- TMS9918 VDP: two-byte control latch, 16 KB VRAM, R0-R7, auto-increment
  read/write pointers, vblank status bit + IRQ once per frame when `R1 bit5` set.
- 8 KB cart mirrored into `$8000-$9FFF` and `$A000-$BFFF`; 2 KB BIOS mirrored ×8.

Bus semantics mirror `funvision-reference/funnymu-0.44/funny.c`
(`Wr6502`/`Rd6502`/`Loop6502`/`VDPOut`). It is **not** a display/audio-accurate
emulator — no rendering, coarse frame pacing (fixed 40000 cyc/frame then IRQ —
PAL 50 Hz, matching `funnymu VPeriod`).
Good enough to read ground-truth RAM/VRAM; not for final timing calibration
(use openMSX + `funnymu` side-by-side for that).

```sh
# boot through BIOS to the game main loop, dump state
python3 tools/fv_emu.py --until 0xB5B5 --frames 400

# run the attract demo, dump VRAM/RAM + which subroutines get called
python3 tools/fv_emu.py --frames 700 \
    --dump-vram build/re/vram_attract.bin --dump-ram build/re/ram_attract.bin \
    --call-summary --watch 0x4C:1 --watch 0x0320:18

# tools/fv_probe.py — snapshots the stride-4 object arrays mid-demo
python3 tools/fv_probe.py

# tools/view_vram.py — render a VRAM dump to PNG (patterns / sprites / name table)
python3 tools/view_vram.py build/re/vram_attract.bin build/re/

# Phase 2: capture VRAM at 3 checkpoints, diff, and carve static assets
python3 tools/fv_dump_vram.py           # -> build/re/vram_{title,gamestart}.bin
python3 tools/extract_assets.py         # -> assets/*.bin + manifest.txt
python3 tools/view_assets.py            # -> assets/preview/*.png
```

`build/re/patterns.png` from the first dump shows a clean font (`0-9 A-Z`),
cyan mountain/terrain tiles, ship and planet-surface graphics — the harness and
the VRAM dump are validated as ground truth.

## Findings

### Boot / frame model — confirmed
- Reset vector `$FF66` → BIOS init → `JMP ($BFFC)`=`$F808` → cart VDP-reg load
  (`$BFF0-$BFF7`) → `JMP ($BFE8)` = **`$B4E6`** game entry. Reaches the main loop
  `$B5B5` after ~40 frames of init.
- VDP registers: R1=`$E2` (display + IRQ on), R2=`$01`, R3=`$50`, R5=`$38`, R6=`$04`.
  **R4 is rewritten every frame** = `7 - (($44>>5)&7)` → the pattern-generator base
  cycles through **8 banks** `$0000`/`$0800`/…/`$3800` (2 KB apart) as the world
  scrolls; each bank = the terrain tiles pre-shifted 0-7 px (reverse-engineering.md
  §2). Other table bases: name `$0400`, colour `$1400`, sprite-attr `$1C00`,
  sprite-pattern `$2000`.
- One IRQ/frame; handler sets `$0C` from VDP status, runs `$FF58` then `$FA00`
  (input), returns. No sound work in the IRQ.

### Attract / demo — confirmed
- `$4B` = attract countdown, decrements each frame from ~`$89`. At `$4B = 0`
  `$BCF2` fires an auto-start trigger; the main loop sets `$4C` bit6 (**game session
  active**) and the demo plays unattended (input `$11` driven by the wave code).
- The demo actually plays: all 8 enemy slots spawn, bullets fire, the score
  increments. `$FE77` and `$BC83 SoundDispatch` run — the effect set is exercised.

### Object model — corrected (was wrong in RE notes §7)
Stride-**4** arrays, **8 enemy slots** at `X ∈ {0,4,8,$0C,$10,$14,$18,$1C}`.
The iterator `LDX #$1C : … : JSR $FD30 : BPL` steps by `-4` — **`$FD30` is `DEX`×4**,
not `×5` (BIOS disasm). The old "stride-5 / 6 slots" reading was doubly wrong.

| Array | Layout per slot |
|---|---|
| `$0320,X` | `[state,-,-,-]` — `$00` free / `$FF` active / `$01-$7F` spawn ctdn / `<0` explode |
| `$80,X`   | `[attr, pattern#, screenX, screenY]` shadow OAM (`Y=$E0` → hidden). 3+ types by pattern (`$BC`/`$90`/`$84`) + colour (`$0F`/`$04`/`$02`) |
| `$E0,X`   | `[Xlo, Xhi, Ylo, Yhi]` 16-bit LE world position |
| `$0300,X` | `[speed,-,-,-]` — base |velocity|, LFSR-seeded to `$10-$17` |
| `$0340,X` | `[ctr, frameIdx 0-7, reload, -]` weave animation (`$BDE2` delta table) |

Enemy bullets `$A0,X` and player bullets `$C0,X`: stride 4, **4 slots** each
(`X ∈ {0,4,8,$0C}`), `[attr, pattern, X, Y]`, `Y=$E0` = inactive.

Full enemy-AI decode (spawn / drift / weave / fire) is in `reverse-engineering.md` §7.

### Enemy-AI dispatch — located
Dynamic instruction coverage over the demo shows the contiguous span
**`$B627-$BB90`** executes every frame while enemies are alive. It is *inline*
main-loop code, not a called subroutine. Sub-regions seen:
`B627-B62F`, `B65B-B673`, `B67F-B6C1`, `B6CB-B6E8`, `B730-B793`, `B7CA-B931`,
`B936-B94F`, `B9AC-B9E9`, `BA2F-BA98`, `BB70-BB90`. This is the block to
reimplement in Phase 4; **fully documented in reverse-engineering.md §7** (spawn,
homing drift, weave tables, sprite projection, enemy fire) and §7c (the `$52-$55`
difficulty ramp).

### Ground-truth assets — captured & extracted (Phase 2 ✅)
Three VRAM captures (`tools/fv_dump_vram.py`):
`build/re/vram_title.bin` (first `$B5B5`), `vram_gamestart.bin` (post-`$BD60`),
`vram_attract.bin` (attract demo). `tools/extract_assets.py` diffs them:

- **Static across all three:** the 8 pattern banks, the sprite generator
  (`$2000-$27FF`), the colour table (bar 4 flashing terrain entries 7-10).
- **Per-frame:** name table (~220/768 cells scroll), OAM (`$1C00`), 4 colour bytes.

So the port needs **no pattern unpacker** — `tools/extract_assets.py` carves the
static data straight into `assets/*.bin` (+ `manifest.txt`), verified by
`tools/view_assets.py` → `assets/preview/*.png` (clean font `0-9 A-Z`, cyan
mountain terrain, enemy sprites with "20/30/50" score chart, player ship).
`assets/patterns.bin` = the clean shift-0 bank (`$3800`, no table overlap);
`patterns_shift1..7.bin` = the pre-shifted terrain copies.

### Sound — byte stream captured
`tools/fv_emu.py --sound-log build/re/sound.log` logs every SN76489 byte (frame, PC,
value). **Every write in the demo comes from BIOS `$FE77`** — no other path. Decode
with `tools/sn_decode.py build/re/sound.log`:

- Startup: `9F BF DF FF` = silence all 4 channels (`$FE54`).
- Wave-start jingle (`$FBD6` id 0, frame ~316+): tones on ch0/ch1/ch2, each with a
  software volume envelope ramped 15→0 one step per frame — done by the `$FBD6`
  interpreter, not the chip. At F_sn = 2 MHz the pitches are ~98 / 124 / 147 / 393 /
  440 Hz.
- The port needs exactly one chip primitive, `sn76489_write(byte)` (2-byte
  latch/data protocol), plus reimplementations of `SoundDispatch` and `$FBD6`.
- **SN clock = φ2 = 2 MHz** (Funvision circuit diagram: SN clock pin ← 6502 φ2, also
  wired to the 6821 E input). SN→AY tone-period conversion `n_ay ≈ 1.79 · n_sn` (§8).
  `funnymu`'s `sn76496.c` runs at `VDP_CLOCK/15 ≈ 3.5467 MHz` (`funnysdl.c:90`) — an
  emulator approximation, so funnymu's audio pitch is *not* a valid ear-check.
  `tools/sn_decode.py` defaults to `--clock 2000000`.

### BIOS input/RNG — corrected
- `$FF58` (called from IRQ) is a **16-bit LFSR advance** on `$02:$03`
  (feedback `bit6($03) ^ bit5($03)`), *not* a keyboard scan.
- `$FA00` (called from IRQ) is the full controller/keyboard decode: raw columns →
  `$18-$1B`, decoded keys → `$11-$14` (bit7 = new press, bit6 = repeat), plus
  `$15` / `$1D` / `$1E`. Key-scancode tables at `$FBB2` (16 B) and `$FBC2` (20 B).
- **Input→action map done** (reverse-engineering.md §7b), via `tools/fv_trace_fa00.py`
  (single-steps one `$FA00` call with a key held — the game clears `$11-$14` before
  end-of-frame so an end-of-frame sample reads 0). `$11`/`$13` = P1/P2 stick (table
  `$FBB2`: UP=9 DOWN=1 LEFT=13 RIGHT=5), `$16`/`$17` = P1/P2 fire edge, `$12`\|`$14` =
  start ("6 or B"). LEFT/RIGHT = ±$20 scroll-velocity (`$42`) w/ cooldown `$4D`;
  UP/DOWN = ±1px alt.

### Player death / spawn-in FSM — confirmed
`tools/fv_probe2.py` watches `$4C/$4D/$56/$5E/$68/$69/$50-$51` across a 6000-frame
demo run. Findings:
- `$56` = **lives**, set to `$03` by `$BD23` at frame 42.
- The demo auto-starts a session at **frame 297** (`$4C` → `$40`, bit6 set) — this is
  `$BCF2` firing the attract-timeout trigger, *not* a scripted keypress.
- The spawn-in animation runs from ~frame 477: `$69` counts **down** cleanly
  `$7F → 0` one per frame (117 frames), `$20` (explosion SFX) clears at the same time.
  This is the `$BABC` FSM with `$68 = 0` — confirms the model in
  `reverse-engineering.md` §5.2 / §7a.
- Over the rest of the 6000 frames nothing else changed (no kills, no death) — the
  idle keytable means the demo ship never fires, so collision/scoring paths are not
  exercised by the default harness. A scripted-input probe is needed for those.

## Open items still needing this harness
- Collision phase **resolved statically and confirmed dynamically** (`tools/fv_kill.py`
  — class `$10`→+3, class `$00`→+2, matching `$BDFF`; running BCD score verified).
- Enemy AI (`$B730-$B931`) **fully decoded** (reverse-engineering.md §7): one uniform
  AI, player-homing drift + `$BDE2`/`$BDE4` weave, slot-group "type" (`X mod 12` →
  score `$02`/`$03`/`$05`). The `$52-$55` state machine is the **difficulty ramp**
  (§7c: `$54` scroll floor, `$55` spawn throttle) — not humanoid abduction.
- Smart-bomb / hyperspace: **resolved — none** (single fire action; §7b/§7c).
- Wave-advance: **resolved — there is no wave structure** (endless survival; see
  reverse-engineering.md §10). Escalation is the `$52-$55` ramp only.
- Timing: this harness is not cycle-accurate — calibrate speed against `funnymu`.
- Phase 2 **done** — assets extracted & verified (see above).
