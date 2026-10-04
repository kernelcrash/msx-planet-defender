#!/usr/bin/env python3
"""Validate the built MSX cartridge image."""
import sys

def main(path):
    d = open(path, "rb").read()
    ok = True
    if len(d) != 16384:
        print(f"FAIL size: {len(d)} (expected 16384)"); ok = False
    else:
        print("OK   size 16384")
    if d[:2] != b"AB":
        print(f"FAIL signature: {d[:2]!r} (expected b'AB')"); ok = False
    else:
        print("OK   signature 'AB'")
    init = d[2] | (d[3] << 8)
    if 0x4000 <= init < 0x8000:
        print(f"OK   INIT ${init:04X}")
    else:
        print(f"FAIL INIT ${init:04X} (outside $4000-$7FFF)"); ok = False
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/planetdefender.rom")
