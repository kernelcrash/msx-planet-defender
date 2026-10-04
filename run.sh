#!/usr/bin/env bash
# Build and run the Planet Defender MSX cartridge under openMSX (C-BIOS MSX1).
#   ./run.sh              interactive
#   ./run.sh --headless   boot ~6s, save build/boot.png, exit
set -euo pipefail
cd "$(dirname "$0")"

MACHINE=C-BIOS_MSX1
ROM=build/planetdefender.rom

make --no-print-directory "$ROM"

if [[ "${1:-}" == "--headless" ]]; then
    openmsx -machine "$MACHINE" -carta "$ROM" \
        -command 'after time 6 "screenshot -raw build/boot.png; exit"'
    echo "screenshot -> build/boot.png"
else
    openmsx -machine "$MACHINE" -carta "$ROM"
fi
