#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Loads a bitstream into the Tang Nano 20K.
#   scripts/flash_fpga.sh <project folder under fpga/>          into SRAM, volatile
#   scripts/flash_fpga.sh <project folder under fpga/> flash    into the SPI flash, permanent,
#                                                               at the core's address
#
# Uses programmer_cli from the Gowin installation, which is there anyway for the build.
# Alternative: FLASHER=openfpgaloader scripts/flash_fpga.sh ... uses openFPGALoader instead
# (brew install openfpgaloader, apt install openfpgaloader). The board's onboard programmer
# answers to both tools.
#
# programmer_cli wants the ABSOLUTE path of the bitstream. With a relative one it stops with
# "Not found any data File", which reads as if the option were missing.
#
# The flash holds several cores, each at its address in fpga/common/slots.txt, and the core
# switch goes from one to the next. The FPGA loads the core at 0x000000 at power-on.
# programmer_cli writes only that one: given another --spiaddr, it erases there but programs at
# 0, in its .fs mode as in its binary mode (--run 32 with --mcuFile). A core at another address
# is therefore written by openFPGALoader, which needs to be installed for it. Both tools erase
# only the sectors they write, the other cores stay (measured).
#
# Volatile or permanent, the difference matters:
#   without "flash" the design is gone at the next power cut and the FPGA boots the core at
#   0x000000. After writing the flash, power the board off and on: only the fresh start makes
#   sure the FPGA runs the core at 0x000000, and the Pico reads the menu from the FPGA exactly
#   once at power-up. openFPGALoader reloads the FPGA after writing, but that reload is not a
#   power-on: it brought up the core at 0x100000 once (measured).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$1" ] || { echo "Usage: scripts/flash_fpga.sh <project folder under fpga/> [flash]" >&2; exit 2; }
FS="$ROOT/fpga/$1/impl/pnr/$1.fs"
[ -f "$FS" ] || { echo "$FS missing, build it first" >&2; exit 1; }

# the core's flash address, the second column of its line in slots.txt
ADDR=
if [ "$2" = "flash" ]; then
  ADDR=$(awk -v c="$1" '$1 == c { print $2 }' "$ROOT/fpga/common/slots.txt")
  [ -n "$ADDR" ] || { echo "fpga/common/slots.txt has no address for $1" >&2; exit 1; }
  echo "Writing permanently to the SPI flash at $ADDR: $(basename "$FS")"
fi

# openFPGALoader: asked for, or the only tool that writes an address other than 0
if [ "$FLASHER" = "openfpgaloader" ] || { [ -n "$ADDR" ] && [ "$ADDR" != "0x000000" ]; }; then
  command -v openFPGALoader >/dev/null || { echo "openFPGALoader missing: brew install openfpgaloader or apt install openfpgaloader" >&2; exit 1; }
  if [ -n "$ADDR" ]; then exec openFPGALoader -b tangnano20k -f -o "$ADDR" --verify "$FS"; fi
  exec openFPGALoader -b tangnano20k "$FS"
fi

. "$ROOT/scripts/find_gowin.sh"
CLI="$PROGRAMMER/bin/programmer_cli"
[ -x "$CLI" ] || { echo "$CLI missing. It belongs to the Gowin package. Or use FLASHER=openfpgaloader." >&2; exit 1; }
# Operation numbers from "programmer_cli -h": 2 = SRAM Program, 8 = exFlash Erase,Program.
OP=2
[ "$2" = "flash" ] && OP=8
exec "$CLI" --device GW2AR-18C --run $OP --fsFile "$FS"
