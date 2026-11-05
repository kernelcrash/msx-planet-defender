# Planet Defender — Funvision → MSX port

This is an AI experiment to port the Funvision/Wizzard/Creativision game "Planet Defender" 
to MSX. So these machines share the same video chip, but have different CPUs and sound chips.
I mostly used Claude Sonnet 5 to do this. It was relatively seamless, and Claude automatically
used opemnsx to test progress, take screenshots and compare. I used the funnmyu Funvision
emulator as the reference platform.

## Build & run

```sh
make            # -> build/planetdefender.rom (16 KB MSX cartridge)
make run        # launch in openMSX (C-BIOS MSX1 EU / PAL 50 Hz)
make headless   # boot, screenshot to build/boot.png, exit
make check      # validate the ROM image
```

Requires `pasmo` and `openmsx`. The reverse-engineering tools additionally need
`python3` with `py65` (`pip install py65`) and `pillow`.

## Controls

Keyboard only (this was just a simplification):

| Key | Action |
|---|---|
| **Space** / **Return** | Start game / leave title |
| **←** / **→** | Thrust — change scroll velocity by ±$20; reverses facing when it crosses 0 |
| **↑** / **↓** | Altitude — move the ship up / down 1px |
| **Space** | Fire (single shot per press — no auto-repeat) |

## Layout

| Path | |
|---|---|
| `src/` | Z80 source |
| `assets/` | data blobs carved from the original ROM |
| `tools/` | `dis6502.py` / `trace6502.py` (6502 disasm), `fv_emu.py` (headless Funvision 6502 harness), `fv_probe.py` / `fv_probe2.py` (RAM-state probes), `fv_trace_fa00.py` / `fv_ingame_input.py` (input decode), `fv_kill.py` (collision trace), `fv_dump_vram.py` / `extract_assets.py` / `view_assets.py` / `view_vram.py` (Phase 2 assets), `sn_decode.py` (SN76489 stream decoder), `check_rom.py` |
| `docs/` | `reverse-engineering.md`, `memory-map.md`, `coleco-to-msx-sound.md`, raw + traced disassemblies |
