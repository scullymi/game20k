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
N54_ZEROS=
[ -f "$TMP/54xx.bin" ] || {
  N54_ZEROS=1
  echo "WARNING: roms/namco54.zip or its 54xx.bin is missing, the 54xx is filled with zeros and the" >&2
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

# The content, chip by chip, against the SHA-1 that MAME lists for the set "galaga"
# (src/mame/namco/galaga.cpp) and for the 54xx (src/mame/namco/namco54.cpp). A set of
# the right sizes but another revision, or a patched one, stops here. The 54xx made of
# zeros above is the one exception, it is known to be missing.
# shasum comes with Perl, sha1sum and sha256sum with coreutils: whichever there is
if command -v shasum >/dev/null 2>&1; then
  sha1()   { shasum -a 1 "$1" | cut -d' ' -f1; }
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
elif command -v sha1sum >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
  sha1()   { sha1sum "$1" | cut -d' ' -f1; }
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
else
  echo "neither shasum nor sha1sum/sha256sum found, cannot check the ROM set" >&2; exit 1
fi
verify() {
  [ "$(sha1 "$1")" = "$2" ] || { echo "$1 differs from MAME's galaga set (SHA-1), wrong revision or modified?" >&2; exit 1; }
}
verify gg1_1b.3p ca7f5da42d4e76fd89bb0b35198a23c01462fbfe
verify gg1_2b.3m ab202aa259c3d332ef13dfb8fc8580ce2a5a253d
verify gg1_3.2m  481f443aea3ed3504ec2f3a6bfcf3cd47e2f8f81
verify gg1_4b.2l ddb8b121903646c320939c7d13f4aa4ebb130378
verify gg1_5b.3f e957a581463caac27bc37ca2e2a90f27e4f62b6f
verify gg1_7b.2c 44c1a04fba3c7c826ff484185cb881b4b22e6657
verify gg1_9.4l  62f1279a784ab2f8218c4137c7accda00e6a3490
verify gg1_11.4d e697c180178cabd1d32483c5d8889a40633f7857
verify gg1_10.4f c340ed8c25e0979629a9a1730edc762bd72d0cff
verify prom-5.5n 1a6dea13b4af155d9cb5b999a75d4f1eb9c71346
verify prom-4.2n 0281de86c236c88739297ff712e0a4f5c8bf8ab9
verify prom-3.1c cdd4bc1013f5c11984fdc4fd10e2d2e27120c1e5
verify prom-1.1d 085ada18c498fdb18ecedef0ea8fe9217edb7b46
verify prom-2.5c 0c4d0bee858b97632411c440bea6948a74759746
[ -n "$N54_ZEROS" ] || verify 54xx.bin 01bdf984a49e8d0cc8761b2cc162fd6434d5afbe

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
# The firmware allows hardcore only with one of these two files (ra_patch.c, ROM
# digests): with the 54xx, or with its 1024 bytes as zeros.
case "$(sha256 "$OUT")" in
  aaf7a7256f8c4e97b31f053e688f24cbb34075a26ac71ff0847651ae93b2af47) echo "known ROM file, with the 54xx: hardcore possible" ;;
  ec21e54daa09f78b2f58ab060f5cdfbd29d50b29816041c6cae3826cb2dabcd5) echo "known ROM file, without the 54xx: hardcore possible" ;;
  *) echo "WARNING: unknown ROM file, the firmware will stay in softcore" >&2 ;;
esac
