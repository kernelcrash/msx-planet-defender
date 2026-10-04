# ColecoVision → MSX reference (`coleco-to-msx-reference/`)

Provided as a reference for **Phase 6 (sound)**. Both ColecoVision and MSX are Z80 +
TMS9918, so the only real porting delta is **SN76489 → AY-3-8910**. This is the same
delta we face for the Funvision.

## Files

| File | What |
|---|---|
| `Donkey Kong (1982).col` | original 16 KB ColecoVision cartridge (header `AA 55` at `$8000`) |
| `donkeykong.rom` | a working MSX conversion — 48 KB of code at `$4000-$FFFF` (file padded to 64 KB; `$0000-$3FFF` = MSX BIOS slot). INIT = `$4010`. |

The MSX build bundles a reimplementation of the ColecoVision BIOS (the Coleco OS the
game calls into), including the sound engine, translated to MSX hardware.

## Sound / PSG layer in `donkeykong.rom` (≈ `$D600-$DBFF`)

Raw disassembly: `coleco-msx-sound-driver.dis.txt` (linear sweep — contains data noise;
a character-map table sits at `$D6DC`, misc lookup tables around `$D700`).

Reusable primitives identified:

| Addr | Routine | Notes |
|---|---|---|
| `$D8CA` | `psg_write` | `out ($A0),A` (reg in A) ; `ld a,e` ; `out ($A1),A` (data in E). The minimal PSG register write. |
| `$D8B2` | `psg_load_table` | walk a table of `[reg,val]` bytes, `$FF` terminates, each pair → `$D8CA`. Used with tables `$D8BE` (beep on: R7=`$BE`,R0/R1 period,R8=`$0F`) and `$D8C7` (R7=`$BF` silence). |
| `$E1F0` | `psg_write_masked` | `out ($A0),C` (reg) ; if `C==7` force mixer bit7=1 / bit6=0 (I/O port A = output) ; `out ($A1),E` (data). Correct MSX mixer handling. |
| `$E1C0` | `psg_write_period` | split a 12-bit period across AY reg `C` (fine) and `C+1` (coarse) via `$E1F0`; channel index from `($DBD8)`, `C = ch*2`. |
| `$D9A6` | `vdp_write_reg` | (VDP, not PSG) `out ($99),C` ; `out ($99),B\|$80`. |
| `$D951` / `$D965` | `vdp_set_addr_write` / `_read` | `out ($99),L` ; `out ($99),H\|$40` (write) or `H` (read). |
| `$D9B1`, `$D9E0`, `$D9ED` | `read_pad_*` | ColecoVision controller emulation: read AY register 14 (`$0E`) / port A after selecting via R15 (`$0F`); bit-shuffle into a Coleco-format pad byte. Relevant model for Phase 5 input if we emulate a 12-key keypad. |
| `$DAAF` | — | packed shadow byte: low nibble / high nibble poked by `$D72A/$D739/$D748/$D758` (Coleco "sound port" volume/mixer shadow). |

### Frequency conversion

The SN76489 tone divider is /32; the AY tone divider is /16. **Careful — the two
machines clock their SN differently.** On the *ColecoVision* the SN runs at
`3.579545 MHz`, so the ÷32-vs-÷16 and the ×2 clock ratio cancel and
`AY_period ≈ SN_period` (copy across). On the *Funvision* the SN clock pin is wired
to the 6502 **φ2 = 2 MHz** (per the circuit diagram; it also feeds the 6821 E input),
so the ratio does **not** cancel:
**`AY_period = SN_period · (2·1_789_772.5 / 2_000_000) ≈ 1.79 · SN_period`** (≈ 16/9;
implement as `(n·229)>>7` or `n·9/5`). Do not reuse the Coleco "copy across"
shortcut here. (`funnymu` models the Funvision SN at `VDP_CLOCK/15 ≈ 3.5467 MHz`, an
emulator approximation — its audio pitch is not a reference.) See
`reverse-engineering.md` §8.

SN attenuation (4-bit, 2 dB/step, `$0F` = silent) maps almost 1:1 to AY amplitude
(4-bit, ~3 dB/step, `$00` = silent) via an inverting LUT: `ay_vol = vol_lut[15 - sn_att]`.

## How this applies to Planet Defender

Planet Defender does **not** call a Coleco-style sound BIOS — it writes **raw SN76489
bytes** through `$FE77`, and the Funvision BIOS `$FA00` runs a frame-ticked sequencer.
So for our port we need:

1. RE the Funvision BIOS `$FA00` sound engine + its data tables (Phase 1 TODO).
2. A `sn76489_write(byte)` shim that keeps the 2-byte latch state (`1 cc t dddd`
   latch byte, `0 -- dddddd` data byte), maintains 4 channel period/volume/noise
   shadows, and pushes the equivalent AY register set — reusing the `psg_write_period`
   / `psg_write_masked` patterns above.
3. Reproduce the effect set (thrust, fire, explosion, abduction, pickup, bonus,
   wave jingle) from the same trigger points.
