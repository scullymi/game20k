#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Simulation of rom_sdram.sv with the real sdram_fb.v and an SDRAM model (tb_rom_sdram.sv),
# with Verilator 5. Ends with one line PASS or exits nonzero.
#
# Usage: sh fpga/common/sim/run_sim.sh
# The build goes to $WORK (default ${TMPDIR:-/tmp}/verilator_rom_sdram), never into the tree.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src"
W="${WORK:-${TMPDIR:-/tmp}/verilator_rom_sdram}"
rm -rf "$W"
mkdir -p "$W"
verilator --binary --timing -j 8 -O3 --top-module tb_rom_sdram -Mdir "$W/obj" \
  -Wno-fatal -Wno-lint -Wno-style \
  "$SRC/sdram_fb.v" "$SRC/rom_sdram.sv" "$HERE/tb_rom_sdram.sv" > "$W/build.log" 2>&1 \
  || { cat "$W/build.log"; exit 1; }
cd "$W"
# the simulation's exit status decides, the filter only hides Verilator's report lines
set +e
./obj/Vtb_rom_sdram > sim.log 2>&1
rc=$?
grep -v '^- ' sim.log
exit $rc
