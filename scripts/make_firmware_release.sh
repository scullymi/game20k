#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Builds the firmware image for a release and packs it with its NOTICE.
# Usage: scripts/make_firmware_release.sh
# Result: dist/game20k-<version>-pico2w/ with game20k-<version>-pico2w.uf2 and NOTICE.txt, and
# the same folder as .zip for the release page.
#
# A release comes from a clean tree on a tag, so that the version the firmware reports names
# exactly the sources. DEV=1 skips these checks for a trial run, the files then carry the
# version git describe gives, with -dirty or a commit.
# The image is for the Pico 2 W with its own USB port as host (pico2 native), the variant that
# has been tested with RetroAchievements. cyw43-driver in it may be used and passed on only with
# Raspberry Pi devices, the NOTICE says so at the top. The build has no Bluetooth, so no BTstack.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- a release names its sources: tag, clean tree, submodules at the recorded commits ---
if [ -z "$DEV" ]; then
  git describe --tags --exact-match HEAD >/dev/null 2>&1 \
    || { echo "HEAD is not on a tag, a release needs one (DEV=1 for a trial run)"; exit 1; }
  [ -z "$(git status --porcelain)" ] \
    || { echo "the tree has uncommitted changes (DEV=1 for a trial run)"; exit 1; }
  ! git submodule status | grep -q '^[-+U]' \
    || { echo "a submodule is missing or not at the recorded commit, see git submodule status"; exit 1; }
fi
VERSION=$(git describe --tags --always --dirty | sed 's/^v//')
NAME="game20k-$VERSION-pico2w"

# --- build from scratch: make rebuilds only what changed, and a release must not carry
#     objects of an earlier build, a diagnostic one for example ---
B="$ROOT/external/FPGA-Companion/src/rp2040/build_pico2_native"
rm -rf "$B"
scripts/build_companion.sh pico2 native

# --- the linked game table is the one generated from the manifests, not the fork's example ---
grep -q '/build/firmware/gen/ra_games_data\.c\.o' "$B/fpga_companion.elf.map" \
  && ! grep -q 'ra_games_example\.c\.o' "$B/fpga_companion.elf.map" \
  || { echo "the image does not link the generated game table, see $B/cmake.log"; exit 1; }

# --- checks on the image: the version it reports, no diagnostic output, no credentials ---
python3 - "$B/fpga_companion.bin" "$VERSION" "$ROOT/sdcard/config.ini" <<'PY'
import os, re, sys
img = open(sys.argv[1], "rb").read()
if ("game20k/v%s " % sys.argv[2]).encode() not in img:
    sys.exit("the image does not report version %s" % sys.argv[2])
if re.search(rb"(^|\x00)TEST:", img):
    sys.exit("the image prints TEST: lines, it contains a diagnostic build")
# the values in the builder's own config.ini must not have ended up in the image
if os.path.isfile(sys.argv[3]):
    ini = open(sys.argv[3], encoding="utf-8", errors="replace").read()
    hits = 0
    for key in ("SSID", "PASS", "TOKEN"):
        m = re.search(r"^\s*%s\s*=\s*(.+?)\s*$" % key, ini, re.M)
        if m and len(m.group(1)) >= 4:
            hits += img.count(m.group(1).encode())
    if hits:
        sys.exit("the image contains %d value(s) from sdcard/config.ini" % hits)
PY

# --- pack: the image and its NOTICE, as folder and as zip ---
OUT="$ROOT/dist/$NAME"
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT"
cp "$B/fpga_companion.uf2" "$OUT/$NAME.uf2"
python3 scripts/firmware_notice.py "$B/fpga_companion.elf.map" "$OUT/NOTICE.txt" "$VERSION"
( cd "$ROOT/dist" && zip -q -r "$NAME.zip" "$NAME" )
echo "release files:"
ls -la "$OUT" "$OUT.zip" | sed 's/^/  /'
shasum -a 256 "$OUT/$NAME.uf2" "$OUT.zip" | sed "s|$ROOT/||; s/^/  /"
