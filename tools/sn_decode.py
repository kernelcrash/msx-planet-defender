#!/usr/bin/env python3
"""Decode an SN76489 byte stream (from `fv_emu.py --sound-log`) into per-channel
tone/noise/volume events.

The Funvision feeds the chip one byte at a time through the PIA; every byte in the
log is a real chip write. SN76489 protocol:
  1cc t dddd   latch:  cc=channel 0..3, t=0 tone-freq-low / t=1 attenuation,
                       dddd = 4 data bits (low nibble of freq, or 4-bit atten)
  0 x dddddd   data:   6 more freq bits for the last-latched tone channel
Noise channel (cc=3), t=0: dddd = -pfp  (p=period 0..3, f=0 periodic/1 white)

Funvision SN clock = 6502 phi-2 = 2_000_000 Hz (per the Funvision circuit diagram:
the 76489 clock pin is wired to phi-2, and to the 6821 E input). Tone Hz = clk/(32*n).
(The funnymu emulator uses VDP_CLOCK/15 ~= 3.55 MHz instead - an approximation; its
audio plays ~1.78x too high. Trust the sound-log period values, read at 2 MHz.)

Usage:  sn_decode.py build/re/sound.log [--clock 2000000]
"""
import sys, argparse

CH = ["tone0", "tone1", "tone2", "noise"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--clock", type=float, default=2_000_000.0)
    ap.add_argument("--group-gap", type=int, default=2,
                    help="frames of silence that separate two effects")
    a = ap.parse_args()

    period = [0, 0, 0, 0]
    atten = [15, 15, 15, 15]
    last_ch = 0
    noise_cfg = 0
    prev_frame = None
    events = []  # (frame, text)

    for line in open(a.log):
        line = line.split()
        if len(line) != 3:
            continue
        frame, pc, byte = int(line[0]), line[1], int(line[2], 16)
        if byte & 0x80:
            ch = (byte >> 5) & 3
            typ = (byte >> 4) & 1
            data = byte & 0x0F
            last_ch = ch
            if typ == 1:
                atten[ch] = data
                vol = (15 - data)
                events.append((frame, f"{CH[ch]:6s} vol={vol:2d}/15"
                                      + ("  (off)" if data == 15 else "")))
            else:
                if ch == 3:
                    noise_cfg = data
                    mode = "white" if data & 4 else "periodic"
                    rate = data & 3
                    events.append((frame, f"noise  {mode} rate={rate}"))
                else:
                    period[ch] = (period[ch] & 0x3F0) | data
        else:
            data = byte & 0x3F
            if last_ch < 3:
                period[last_ch] = (period[last_ch] & 0x0F) | (data << 4)
                n = period[last_ch]
                hz = a.clock / (32 * n) if n else 0
                events.append((frame,
                               f"{CH[last_ch]:6s} period={n:4d}  ~{hz:7.1f} Hz"))

    # print grouped by effect (gap in frames)
    for frame, text in events:
        if prev_frame is not None and frame - prev_frame > a.group_gap:
            print("  " + "-" * 40)
        print(f"  f{frame:<6d} {text}")
        prev_frame = frame


if __name__ == "__main__":
    main()
