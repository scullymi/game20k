#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Loads a bitstream into the Tang Nano 20K.
#   scripts/flash_fpga.sh <project folder under fpga/>          into SRAM, volatile
#   scripts/flash_fpga.sh <project folder under fpga/> flash    into the SPI flash, permanent
#
# Uses programmer_cli from the Gowin installation, which is there anyway for the build.
# Alternative: FLASHER=openfpgaloader scripts/flash_fpga.sh ... uses openFPGALoader instead
# (brew install openfpgaloader, apt install openfpgaloader). The board's onboard programmer
# answers to both tools.
#
# programmer_cli wants the ABSOLUTE path of the bitstream. With a relative one it stops with
# "Not found any data File", which reads as if the option were missing.
#
# Volatile or permanent, the difference matters:
#   without "flash" the design is gone at the next power cut and the FPGA boots the last
#   bitstream written to the SPI flash. After writing the flash, power the board off and on:
#   only the fresh start makes sure the FPGA runs the new bitstream, and the Pico reads the
#   menu from the FPGA exactly once at power-up.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$1" ] || { echo "Usage: scripts/flash_fpga.sh <project folder under fpga/> [flash]" >&2; exit 2; }
FS="$ROOT/fpga/$1/impl/pnr/$1.fs"
[ -f "$FS" ] || { echo "$FS missing, build it first" >&2; exit 1; }
[ "$2" = "flash" ] && echo "Writing permanently to the SPI flash: $(basename "$FS")"

if [ "$FLASHER" = "openfpgaloader" ]; then
  command -v openFPGALoader >/dev/null || { echo "openFPGALoader missing: brew install openfpgaloader or apt install openfpgaloader" >&2; exit 1; }
  if [ "$2" = "flash" ]; then exec openFPGALoader -b tangnano20k -f "$FS"; fi
  exec openFPGALoader -b tangnano20k "$FS"
fi

. "$ROOT/scripts/find_gowin.sh"
CLI="$PROGRAMMER/bin/programmer_cli"
[ -x "$CLI" ] || { echo "$CLI missing. It belongs to the Gowin package. Or use FLASHER=openfpgaloader." >&2; exit 1; }
# Operation numbers from "programmer_cli -h": 2 = SRAM Program, 8 = exFlash Erase,Program.
OP=2
[ "$2" = "flash" ] && OP=8
exec "$CLI" --device GW2AR-18C --run $OP --fsFile "$FS"
