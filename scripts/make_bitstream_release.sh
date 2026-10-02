#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Builds the bitstreams of a release and packs them with their NOTICE.
# Usage: scripts/make_bitstream_release.sh
# Result: dist/game20k-<version>-tangnano20k/ with the flash image game20k-<version>-tangnano20k.bin
# (every core at its address), NOTICE.txt and FLASHING.txt, and the same folder as .zip for the
# release page.
#
# The bitstreams are built here and not in GitHub Actions, the Gowin tools are not available
# there. A release comes from a clean tree on a tag, like the firmware (DEV=1 skips these checks
# for a trial run, the files then carry the version git describe gives). Every core of
# fpga/common/slots.txt is built by this run, its timing report has to pass (build_fpga.sh), and
# bitstream_notice.py checks that every source file belongs to a component of the NOTICE.
# Rebuilds of the same sources with the same Gowin version gave the same .bin byte for byte on
# the build machine, also in a fresh clone at another path, the NOTICE records its SHA-256.
#
# The .fs files carry their build time in local time (the image is built from the .bin and has
# none), the zip the time of packing.
# git config game20k.quiethours "D1-D2 H1-H2" names a window of weekdays and hours, as date +%u
# and +%H count them, in which no release is made: the script neither starts nor packs in it and
# refuses a .fs whose "Created Time" falls in it. DEV=1 skips this check too.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- a diagnostic build rewrites the top, a release is the normal build only ---
# build.tcl only asks whether a variable exists, so an empty one counts as set
for v in RAMDIAG ROMVIEW SDRAMTEST FBTEST FBSHOW FBROT NOTESTBAR; do
  eval "isset=\${$v+set}"
  [ -z "$isset" ] || { echo "$v is set, even empty it selects a diagnostic build: unset it"; exit 1; }
done

# --- the time window, see above ---
QUIET=$(git config --get game20k.quiethours || true)
case "$QUIET" in
  "" | [1-7]-[1-7]\ [0-2][0-9]-[0-2][0-9]) ;;
  *) echo "git config game20k.quiethours is \"$QUIET\", expected \"D1-D2 H1-H2\""; exit 1 ;;
esac
# in_quiet <weekday 1-7> <hour 00-23>: true inside the window
in_quiet() {
  [ -n "$QUIET" ] || return 1
  set -- "$1" "$2" $QUIET
  [ "$1" -ge "${3%-*}" ] && [ "$1" -le "${3#*-}" ] && [ "$2" -ge "${4%-*}" ] && [ "$2" -le "${4#*-}" ]
}
# fs_quiet <file.fs>: true when its "//Created Time:" line lies in the window or cannot be read
fs_quiet() {
  [ -n "$QUIET" ] || return 1
  # e.g. "//Created Time: Thu Oct  1 20:18:31 2026": weekday in $1, the time in $4
  set -- $(sed -n 's|^//Created Time: ||p' "$1" | head -n 1)
  case "$1" in
    Mon) d=1 ;; Tue) d=2 ;; Wed) d=3 ;; Thu) d=4 ;; Fri) d=5 ;; Sat) d=6 ;; Sun) d=7 ;;
    *) return 0 ;;
  esac
  in_quiet "$d" "${4%%:*}"
}
check_clock() {
  if [ -z "$DEV" ] && in_quiet "$(date +%u)" "$(date +%H)"; then
    echo "the clock is inside game20k.quiethours ($QUIET), the files would carry this time"
    exit 1
  fi
}

# --- a release names its sources: tag, clean tree ---
if [ -z "$DEV" ]; then
  git describe --tags --exact-match HEAD >/dev/null 2>&1 \
    || { echo "HEAD is not on a tag, a release needs one (DEV=1 for a trial run)"; exit 1; }
  [ -z "$(git status --porcelain)" ] \
    || { echo "the tree has uncommitted changes (DEV=1 for a trial run)"; exit 1; }
  # a release never lets uncommitted sources through, whatever the shell exports
  unset ALLOW_DIRTY
else
  export ALLOW_DIRTY=1
fi
check_clock
HEAD0=$(git rev-parse HEAD)
VERSION=$(git describe --tags --always --dirty | sed 's/^v//')
NAME="game20k-$VERSION-tangnano20k"

# --- build every core of the ring, in its order ---
CORES=$(awk '!/^#/ && NF == 2 { print $1 }' fpga/common/slots.txt)
[ -n "$CORES" ] || { echo "fpga/common/slots.txt names no core"; exit 1; }
STAMP=$(mktemp "${TMPDIR:-/tmp}/bitstream_release.XXXXXX")
trap 'rm -f "$STAMP"' EXIT
for c in $CORES; do
  scripts/build_fpga.sh "$c"
done

# --- the bitstreams come from this run, from the commit it started on, outside the window ---
for c in $CORES; do
  for f in "fpga/$c/impl/pnr/$c.fs" "fpga/$c/impl/pnr/$c.bin"; do
    [ -n "$(find "$f" -newer "$STAMP" 2>/dev/null)" ] \
      || { echo "$f is missing or older than this run"; exit 1; }
  done
  if [ -z "$DEV" ] && fs_quiet "fpga/$c/impl/pnr/$c.fs"; then
    echo "fpga/$c/impl/pnr/$c.fs was built inside game20k.quiethours ($QUIET) or has no readable"
    echo "Created Time, build the release again outside the window"
    exit 1
  fi
done
# a parallel session may have committed or edited files during the build
if [ -z "$DEV" ]; then
  [ "$(git rev-parse HEAD)" = "$HEAD0" ] && [ -z "$(git status --porcelain)" ] \
    || { echo "HEAD or the tree changed during the build, the bitstreams match no commit"; exit 1; }
fi
check_clock

# --- pack: one flash image, the NOTICE, how to flash it, as folder and as zip ---
OUT="$ROOT/dist/$NAME"
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT"
# shellcheck disable=SC2086
python3 scripts/bitstream_notice.py "$OUT/NOTICE.txt" "$VERSION" $CORES
# The image is the SPI flash from 0x000000 as slots.txt lays it out: every core's .bin at its
# address, 0xFF in between as in an erased flash. The .bin is the .fs as bytes, the same data
# programmer_cli and openFPGALoader write from it. One write puts every core in place, and the
# cores of a release always go on together, they must match the firmware of the same version.
# Written with openFPGALoader and read back: equal byte for byte (02.10.2026).
awk '!/^#/ && NF == 2 { print $1, $2 }' fpga/common/slots.txt | python3 -c '
import sys
img = bytearray()
for line in sys.stdin:
    core, addr = line.split()
    addr = int(addr, 16)
    if addr < len(img):
        sys.exit("slots.txt: %s at %#x overlaps the core before it, which ends at %#x" % (core, addr, len(img)))
    img += b"\xff" * (addr - len(img))
    img += open("fpga/%s/impl/pnr/%s.bin" % (core, core), "rb").read()
open(sys.argv[1], "wb").write(img)
' "$OUT/$NAME.bin"
{
  echo "Flashing game20k $VERSION onto the Tang Nano 20K"
  echo
  echo "$NAME.bin holds every game's core at its place in the board's flash. Write it"
  echo "with openFPGALoader (brew install openfpgaloader, apt install openfpgaloader):"
  echo
  echo "  openFPGALoader -b tangnano20k -f --verify $NAME.bin"
  echo
  echo "Power the board off and on afterwards. The firmware of the same version goes onto the"
  echo "Pico 2 W, the ROM files onto the SD card, see the README of the release."
} > "$OUT/FLASHING.txt"
( cd "$ROOT/dist" && zip -q -r "$NAME.zip" "$NAME" )
echo "release files:"
ls -la "$OUT" "$OUT.zip" | sed 's/^/  /'
shasum -a 256 "$OUT.zip" | sed "s|$ROOT/||; s/^/  /"
