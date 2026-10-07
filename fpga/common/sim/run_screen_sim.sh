#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Simulation of the screen layouts with Verilator 5: screen_sel.sv against its table
# (tb_screen_sel.sv), the banner (tb_ra_overlay.sv) and the OSD (tb_osd_u8g2.sv) as whole
# 1280x720 frames, and the frame lock of scaler and HDMI (tb_scaler_sync.sv). The frames
# are compared by SHA-256 with ref_screen.sha256. Ends with one line PASS or exits nonzero.
#
# Usage: sh fpga/common/sim/run_screen_sim.sh
# The build and the frames (.ppm) go to $WORK (default ${TMPDIR:-/tmp}/verilator_screen),
# never into the tree.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src"
W="${WORK:-${TMPDIR:-/tmp}/verilator_screen}"
rm -rf "$W"
mkdir -p "$W/img"

# one testbench: build, run, show its lines without Verilator's report
run() {
  tb=$1; shift
  verilator --binary --timing -j 8 -O3 --top-module "$tb" -Mdir "$W/obj_$tb" \
    -Wno-fatal -Wno-lint -Wno-style "$@" "$HERE/$tb.sv" > "$W/build_$tb.log" 2>&1 \
    || { cat "$W/build_$tb.log"; exit 1; }
  "$W/obj_$tb/V$tb" +dir="$W/img" > "$W/sim_$tb.log" 2>&1 || { grep -v '^- ' "$W/sim_$tb.log"; exit 1; }
  grep -v '^- ' "$W/sim_$tb.log"
}
run tb_screen_sel "$SRC/screen_sel.sv"
run tb_ra_overlay "$SRC/ra_overlay.sv"
run tb_osd_u8g2 "$SRC/misc/osd_u8g2.v"
run tb_scaler_sync "$SRC/arcade_scaler.sv"

# every frame must have its reference, every reference its frame
cd "$W/img"
shasum -a 256 *.ppm | sort -k 2 > "$W/frames.sha256"
sort -k 2 "$HERE/ref_screen.sha256" > "$W/ref.sha256"
if ! diff "$W/ref.sha256" "$W/frames.sha256"; then
  echo "FAIL: frames differ from ref_screen.sha256 (< reference, > this run)"
  exit 1
fi
echo "$(wc -l < "$W/frames.sha256" | tr -d ' ') of $(wc -l < "$W/ref.sha256" | tr -d ' ') frames agree with ref_screen.sha256"
echo PASS
