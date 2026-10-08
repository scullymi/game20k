#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Simulation of Dig Dug (game_core with MiSTer-X's core on enables) with Verilator 5.
# The core is Verilog throughout (TV80), so Verilator takes it as it is. The TV80 carries
# intra-assignment delays (#1), so the testbench runs without --timing and sim_main.cpp drives
# the clocks.
#
# Usage: sh fpga/digdug_hdmi/sim/run_sim.sh [port|late|path] [plusargs...]   (default: port)
#   port   the program of CPU0 through a model of rom_sdram's read stream
#   late   the same with 40 to 60 clocks latency, so that CPU0 must wait
#   path   through the real rom_sdram.sv, sdram_fb.v and an SDRAM model
#   plusargs: +frames=N (1200) +first=N (0) +coin=N +start=N (frames, -1 = none)
#
# Needs roms/digdug.zip, namco51.zip and namco53.zip (the ROM file is built from them with
# make_rom.py, as for the SD card).
# Everything generated, the ROM image included, goes to $WORK (default
# ${TMPDIR:-/tmp}/verilator_digdug), never into the tree. The picture is compared against
# MAME by compare.py.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
G="$HERE/../src"
D="$G/rtl_digdug"
W="${WORK:-${TMPDIR:-/tmp}/verilator_digdug}"
mode="${1:-port}"
[ $# -gt 0 ] && shift
case "$mode" in
  port) define=""; cdef="" ;;
  late) define="+define+LATE"; cdef="" ;;
  path) define="+define+ROM_PATH"; cdef="-CFLAGS -DROM_PATH" ;;
  *) echo "usage: $0 [port|late|path] [plusargs]" >&2; exit 2 ;;
esac
mkdir -p "$W/$mode"
python3 "$ROOT/scripts/make_rom.py" --no-footer "$ROOT/fpga/digdug_hdmi/digdug.manifest" "$W/digdug.rom"
python3 -c "
import sys
b = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'w').writelines('%02x\n' % x for x in b)
" "$W/digdug.rom" "$W/$mode/rom8.hex"

verilator --cc --exe --build --no-timing -j 8 -O3 --top-module tb_digdug -Mdir "$W/obj_$mode" $define $cdef \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-STMTDLY -Wno-ASSIGNDLY -Wno-TIMESCALEMOD \
  "$D/cpu/tv80_alu.v" "$D/cpu/tv80_reg.v" "$D/cpu/tv80_mcode.v" "$D/cpu/tv80_core.v" "$D/cpu/tv80s.v" \
  "$D/cpucore.v" "$D/dprams.v" "$D/wsg.v" "$D/DIGDUG_IODEV.v" \
  "$D/DIGDUG_SPRITE.v" "$D/DIGDUG_VIDEO.v" "$D/DIGDUG_CORES.v" "$D/FPGA_DIGDUG.v" "$D/HVGEN.v" \
  "$ROOT/fpga/common/src/rom_slots.sv" "$ROOT/fpga/common/src/sdram_fb.v" \
  "$ROOT/fpga/common/src/rom_sdram.sv" "$ROOT/fpga/common/src/namco/mb88_cpu.sv" \
  "$ROOT/fpga/common/src/namco/namco_io.sv" "$ROOT/fpga/common/src/namco/namco_prom2.sv" \
  "$G/ram_mirror_n.sv" "$G/game_pkg.sv" "$G/game_core.sv" "$HERE/tb_digdug.sv" "$HERE/sim_main.cpp" \
  > "$W/build_$mode.log" 2>&1 || { tail -40 "$W/build_$mode.log"; exit 1; }

cd "$W/$mode"
"$W/obj_$mode/Vtb_digdug" "$@"
