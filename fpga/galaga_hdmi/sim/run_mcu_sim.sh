#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Checks the Namco MCUs of the Galaga core against MAME, with nvc.
#
#   trace  <mame trace> <program.bin>  mb88.vhd in lock step with a MAME debugger trace of the
#                                      same program (tb_mb88_trace.vhd, step file from
#                                      mame2steps.py)
#   replay <bus log> <51xx.bin>        namco_io.vhd against the main CPU's 06XX accesses of a
#                                      MAME run (tb_namco_io.vhd)
#
# Traces, logs and programs come from the caller: they hold or derive from ROM data and stay
# out of the tree. How to record them with MAME: README.md in this folder.
# Work files go to $WORK (default ${TMPDIR:-/tmp}/nvc_galaga_mcu).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src"
W="${WORK:-${TMPDIR:-/tmp}/nvc_galaga_mcu}"
NVC="${NVC:-nvc}"
mkdir -p "$W"

hexdump_rom() {  # program.bin -> one byte per line in hex
  python3 -c "import sys; d=open(sys.argv[1],'rb').read(); sys.stdout.write(''.join('%02X\n' % b for b in d))" "$1" > "$2"
}

case "$1" in
  trace)
    python3 "$HERE/mame2steps.py" "$2" "$3" "$W/steps.txt"
    hexdump_rom "$3" "$W/rom.hex"
    rm -rf "$W/work"
    "$NVC" --std=2008 --ieee-warnings=off --work=work:"$W/work" -a \
      "$SRC/rtl_dar/mb88.vhd" "$HERE/tb_mb88_trace.vhd" \
      -e tb_mb88_trace -gSTEPS="$W/steps.txt" -gROMHEX="$W/rom.hex" -r
    ;;
  replay)
    hexdump_rom "$3" "$W/rom.hex"
    rm -rf "$W/work"
    "$NVC" --std=2008 --ieee-warnings=off --work=work:"$W/work" -a \
      "$SRC/rtl_dar/mb88.vhd" "$SRC/namco_io.vhd" "$HERE/tb_namco_io.vhd" \
      -e tb_namco_io -gBUSLOG="$2" -gROMHEX="$W/rom.hex" -r
    ;;
  *)
    echo "Usage: sh $0 trace <mame trace> <program.bin> | replay <bus log> <51xx.bin>" >&2
    exit 2
    ;;
esac
