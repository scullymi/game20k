#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Assembles from roms/galaga.zip (MAME set "galaga", Namco Rev B) the single file that the
# FPGA Companion loads from the SD card into the core: 38944 bytes.
#
# Usage: scripts/make_galaga_rom.sh [output file]     default: sdcard/galaga.rom
# Normally scripts/make_sdcard.sh calls this script, there is no need to run it by hand.
#
# Sources live in roms/ (gitignored), the result in sdcard/ (galaga.rom there is gitignored
# too, via *.rom). Both contain ROM data and never leave this machine, except onto the card.
#
# Layout (all boundaries 256-byte aligned, which is why the 32-byte PROM comes last):
#   0x0000 16384  cpu1        gg1_1b.3p + gg1_2b.3m + gg1_3.2m + gg1_4b.2l
#   0x4000  4096  cpu2        gg1_5b.3f
#   0x5000  4096  cpu3        gg1_7b.2c
#   0x6000  4096  bg_graphx   gg1_9.4l
#   0x7000  8192  sp_graphx   gg1_11.4d + gg1_10.4f
#   0x9000  1024  cs54xx      54xx.bin from roms/namco54.zip, otherwise zeros
#   0x9400   256  bg_palette  prom-4.2n
#   0x9500   256  sp_palette  prom-3.1c
#   0x9600   256  sound_seq   prom-2.5c
#   0x9700   256  sound_samp  prom-1.1d
#   0x9800    32  rgb         prom-5.5n
#
# This table is the ONLY place where the mapping is written down. The core knows just the
# offsets (rom_loader.sv), the firmware knows nothing about the content, it streams the file.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$ROOT/roms/galaga.zip"
N54="$ROOT/roms/namco54.zip"
OUT="${1:-$ROOT/sdcard/galaga.rom}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$ZIP" ] || { echo "missing: $ZIP  (MAME set galaga, Namco Rev B, as a merged set)" >&2; exit 1; }
unzip -q -o -j "$ZIP" 'gg1_*' 'prom-*' -d "$TMP"
if [ -f "$N54" ]; then
  unzip -q -o -j "$N54" '54xx.bin' -d "$TMP" 2>/dev/null || true
fi
[ -f "$TMP/54xx.bin" ] || {
  echo "WARNING: roms/namco54.zip is missing, the 54xx is filled with zeros and the" >&2
  echo "         explosion sounds stay silent. Everything else works." >&2
  dd if=/dev/zero of="$TMP/54xx.bin" bs=1024 count=1 2>/dev/null
}

cd "$TMP"
# Check sizes BEFORE anything is assembled. A wrong set shows up here, on the device it
# would show up nowhere: the loader takes 38944 bytes no matter what is in them.
check() {
  [ -f "$1" ] || { echo "file missing from the set: $1, wrong or incomplete ROM set?" >&2; exit 1; }
  sz=$(wc -c < "$1" | tr -d ' ')
  [ "$sz" = "$2" ] || { echo "$1 has $sz bytes, expected $2. Wrong ROM set?" >&2; exit 1; }
}
for f in gg1_1b.3p gg1_2b.3m gg1_3.2m gg1_4b.2l gg1_5b.3f gg1_7b.2c gg1_9.4l gg1_11.4d gg1_10.4f; do
  check "$f" 4096
done
check 54xx.bin 1024
for f in prom-1.1d prom-2.5c prom-3.1c prom-4.2n; do check "$f" 256; done
check prom-5.5n 32

mkdir -p "$(dirname "$OUT")"
cat gg1_1b.3p gg1_2b.3m gg1_3.2m gg1_4b.2l \
    gg1_5b.3f \
    gg1_7b.2c \
    gg1_9.4l \
    gg1_11.4d gg1_10.4f \
    54xx.bin \
    prom-4.2n \
    prom-3.1c \
    prom-2.5c \
    prom-1.1d \
    prom-5.5n > "$OUT"

SZ=$(wc -c < "$OUT" | tr -d ' ')
[ "$SZ" = "38944" ] || { echo "ERROR: $OUT has $SZ bytes, expected 38944" >&2; rm -f "$OUT"; exit 1; }
echo "written: $OUT ($SZ bytes)"
