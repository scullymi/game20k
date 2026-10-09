#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Builds the Pico firmware from external/FPGA-Companion, our fork of FPGA-Companion on the
# branch game20k, a git submodule.
# The firmware version is the version of this repository: git describe on its tags without the
# leading v, so 0.1.0 on the tag v0.1.0, 0.1.0-5-gabc1234 five commits later, plus -dirty with
# uncommitted changes. The firmware reports it to RetroAchievements in its User-Agent and
# shows it under Status, Version. Without any tag (before the first release) it is the commit.
# Usage: scripts/build_companion.sh [pico2] [native|pio]
#   pico2  = Pico 2 W (RP2350), the only supported board. The firmware needs more RAM than the
#            Pico W (RP2040) has
#   native = the Pico's own micro USB port as USB host (OTG adapter), pio = USB A socket on GP2/GP3
# Result: external/FPGA-Companion/src/rp2040/build_<board>_<usb>/fpga_companion.uf2. The build
# dir has to sit under src/rp2040: the Companion's CMakeLists names ../freertos_callbacks.c,
# which CMake resolves against the build dir. .gitmodules hides these dirs from git status.
# Requires: the submodules external/FPGA-Companion, external/pico-sdk and external/tinyusb.
# A clone made with --recursive has them, otherwise this script initialises them.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -le 2 ] || { echo "usage: $0 [pico2] [native|pio]"; exit 1; }
BOARD_ARG="${1:-pico2}"
USB_ARG="${2:-native}"
case "$BOARD_ARG" in
  pico2) CM_BOARD=PICO2 ;;
  pico)  echo "the Pico W is not supported: the firmware needs more RAM than it has. Use a Pico 2 W"; exit 1 ;;
  *) echo "board must be pico2"; exit 1 ;;
esac
case "$USB_ARG" in
  native) CM_USB="-DNATIVE_USB=ON" ;;
  pio)    CM_USB="-DNATIVE_USB=OFF" ;;
  *) echo "usb must be native or pio"; exit 1 ;;
esac
. "$ROOT/scripts/env_pico.sh"
REPO="$ROOT/external/FPGA-Companion"
# Empty submodule folders mean a clone without --recursive: fetch them now, it is what
# "git clone --recursive" would have done.
if [ ! -f "$REPO/src/rp2040/CMakeLists.txt" ] || [ ! -f "$ROOT/external/pico-sdk/pico_sdk_init.cmake" ] \
   || [ ! -f "$ROOT/external/tinyusb/src/tusb.h" ]; then
  echo "initialising the submodules under external/ (git submodule update --init --recursive)"
  git -C "$ROOT" submodule update --init --recursive
fi

# The checkout must be the fork, on its branch. Local commits on top of the branch are fine,
# that is how one works on the firmware. The superproject records the commit that gets built.
case "$(git -C "$REPO" remote get-url origin 2>/dev/null)" in
  *scullymi/FPGA-Companion*) ;;
  *) echo "external/FPGA-Companion is missing or not the fork, check .gitmodules and git submodule status"; exit 1 ;;
esac
if ! git -C "$REPO" rev-parse -q --verify origin/game20k >/dev/null \
   || ! { git -C "$REPO" merge-base --is-ancestor HEAD origin/game20k \
          || git -C "$REPO" merge-base --is-ancestor origin/game20k HEAD; }; then
  echo "external/FPGA-Companion is not on the fork's branch game20k, see .gitmodules"; exit 1
fi
# TinyUSB must be our fork's branch: the changed line in hid_host.c and the Pico-PIO-USB
# submodule, which the Companion links in both USB variants.
grep -q 'XFER_RESULT_SUCCESS == result' "$ROOT/external/tinyusb/src/class/hid/hid_host.c" 2>/dev/null \
  || { echo "external/tinyusb is not the fork's branch game20k (hid_host.c lacks the changed line), see .gitmodules"; exit 1; }
[ -f "$ROOT/external/tinyusb/hw/mcu/raspberry_pi/Pico-PIO-USB/src/pio_usb.c" ] \
  || { echo "external/tinyusb/hw/mcu/raspberry_pi/Pico-PIO-USB is empty, run: git submodule update --init --recursive"; exit 1; }
# The contract between this repository and the firmware, compared without boards by the same
# script the CI runs: the RAM mirror layout of the core against main.c (otherwise the firmware
# refuses the core with "core too old" or reads garbage).
python3 "$ROOT/scripts/check_contracts.py" --root "$ROOT" --fork "$REPO" \
  || { echo "a contract between core, firmware and scripts is broken, see above"; exit 1; }
# The firmware's tables come from this tree: the game table from the ROM manifests. They go to
# build/firmware/gen, outside the fork's tree, and CMake gets each one as a parameter. A build
# without the parameter takes the fork's example table, which holds no game.
GEN="$ROOT/build/firmware/gen"
python3 "$ROOT/scripts/make_fw_tables.py" --out "$GEN" \
  || { echo "the firmware tables cannot be made from the manifests, see above"; exit 1; }
VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null | sed 's/^v//')
echo "building fork commit $(git -C "$REPO" log -1 --format='%h %s') as game20k version ${VERSION:-unknown}"
# local edits in the checkout go into the build, say so
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] \
  || echo "note: the checkout has uncommitted changes, this build contains them"

B="$REPO/src/rp2040/build_${BOARD_ARG}_${USB_ARG}"
mkdir -p "$B"
# The TinyUSB path goes into the cache: the SDK reads it from the environment only at the first
# configure, and a later cmake re-run from another shell would fall back to the SDK's TinyUSB.
( cd "$B" && cmake -DBOARD=$CM_BOARD $CM_USB \
      ${VERSION:+-DGAME20K_VERSION="$VERSION"} \
      -DGAME20K_GAMES_TABLE:FILEPATH="$GEN/ra_games_data.c" \
      -DPICO_TINYUSB_PATH:PATH="$PICO_TINYUSB_PATH" \
      -DPICOTOOL_FETCH_FROM_GIT_PATH:PATH="$PICOTOOL_FETCH_FROM_GIT_PATH" \
      -DPICOTOOL_FORCE_FETCH_FROM_GIT=1 \
      .. > cmake.log 2>&1 ) || { tail -30 "$B/cmake.log"; exit 1; }
make -C "$B" -j8 > "$B/make.log" 2>&1 || { tail -30 "$B/make.log"; exit 1; }
ls -la "$B/fpga_companion.uf2"
echo "built against:"
git -C "$ROOT" submodule status external/FPGA-Companion external/pico-sdk external/tinyusb | sed 's/^/  /'
exit 0
