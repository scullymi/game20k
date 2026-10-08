#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Simulation of 1943 (game_core with jotego's jt1943) with Verilator 5, after
# fpga/g1942_hdmi/sim/run_sim.sh: ten seconds of the game, a coin and a start, every 30th
# frame written out, late ROM data counted.
#
# Usage: [SET=1943|1943mii] sh fpga/g1943_hdmi/sim/run_sim.sh [port|path|fb]
#   (default: SET=1943, port)
#   port   the ROM buses read through a model of rom_sdram's read stream
#   path   through the real rom_sdram.sv, sdram_fb.v and an SDRAM model (tb define ROM_PATH)
#   fb     path, and the upright picture: sdram_share.sv puts the frame buffer next to the ROM
#
# Needs roms/<SET>.zip and network access once for jtframe's T80s.v (Verilog Z80), checked by
# its git blob hash. Everything generated goes to $WORK (default ${TMPDIR:-/tmp}/verilator_<SET>).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
G="$HERE/.."
SET="${SET:-1943}"
W="${WORK:-${TMPDIR:-/tmp}/verilator_$SET}"
mode="${1:-port}"
JTCORES=548b87b32a1b528a16cb41f689accb179e85d1a8
T80S_BLOB=6baa20633ae0d8bf389290b7252b74490bba62bd
case "$mode" in
  port) define="" ;;
  path) define="+define+ROM_PATH" ;;
  fb)   define="+define+ROM_PATH +define+FB_PATH" ;;
  diag) define="+define+ROM_PATH +define+FB_PATH +define+DIAG" ;;
  *) echo "usage: $0 [port|path|fb|diag]" >&2; exit 2 ;;
esac
case "$SET" in
  1943|1943mii) ;;
  *) echo "SET is 1943 or 1943mii" >&2; exit 2 ;;
esac
mkdir -p "$W/frames"
rm -f "$W"/frames/*.ppm
# the ROM image, as words for the SDRAM side, and the PROM and palette sections as bytes
python3 "$ROOT/scripts/make_rom.py" "$G/$SET.manifest" "$W/$SET.rom"
# FB_CCW for the testbench's fb_read_rotated, as build.tcl makes it
python3 "$ROOT/scripts/make_rom.py" --package "$G/1943.manifest" "$W/rom_map_pkg.sv"
python3 - "$W" "$SET" <<'EOF'
import sys
w = sys.argv[1]
b = open(w + "/" + sys.argv[2] + ".rom", "rb").read()
with open(w + "/rom32.hex", "w") as f:
    for i in range(0, len(b), 4):
        f.write("%08x\n" % int.from_bytes(b[i:i + 4], "little"))
with open(w + "/proms.hex", "w") as f:
    f.writelines("%02x\n" % x for x in b[0xD9000:0xD9F00])
EOF

# the Verilog Z80 for simulation, once
if [ ! -f "$W/T80s.v" ] || [ "$(git hash-object "$W/T80s.v")" != "$T80S_BLOB" ]; then
  curl -sfL -o "$W/T80s.v" \
    "https://raw.githubusercontent.com/jotego/jtcores/$JTCORES/modules/jtframe/hdl/cpu/t80/T80s.v"
  if [ "$(git hash-object "$W/T80s.v")" != "$T80S_BLOB" ]; then
    echo "T80s.v: not the file of jtcores $JTCORES" >&2
    exit 1
  fi
fi

# the game's sources as build.tcl adds them, the VHDL T80 replaced by T80s.v
files=$(sed -n 's|^add_file \(src/.*\.v\)$|\1|p' "$G/build.tcl" | sed "s|^|$G/|")
verilator --binary --timing -j 8 -O3 --top-module tb_1943 -Mdir "$W/obj_$mode" $define $SIM_DEFINES \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  +define+TV80S +incdir+"$G/src/inc" +incdir+"$G/src/jtcores/modules/jtframe/hdl/inc" \
  +incdir+"$G/src/jtcores/cores/1943/hdl" +incdir+"$G/src/jt12/hdl" \
  "$W/T80s.v" $files \
  "$ROOT/fpga/common/src/rom_slots.sv" "$ROOT/fpga/common/src/sdram_fb.v" \
  "$ROOT/fpga/common/src/rom_sdram.sv" "$ROOT/fpga/common/src/sdram_share.sv" \
  "$ROOT/fpga/common/src/fb_pack.sv" "$ROOT/fpga/common/src/fb_read_rotated.sv" \
  "$G/src/g1943_mirror.sv" "$G/src/tile_prefetch.sv" "$G/src/map_prefetch.sv" "$W/rom_map_pkg.sv" "$G/src/game_pkg.sv" "$G/src/game_core.sv" \
  "$HERE/tb_1943.sv" \
  > "$W/build_$mode.log" 2>&1 || { cat "$W/build_$mode.log"; exit 1; }

cd "$W"
"./obj_$mode/Vtb_1943"
python3 "$ROOT/fpga/g1942_hdmi/sim/ppm2png.py" "$W/frames_$mode.png" frames/f0060.ppm \
  frames/f0120.ppm frames/f0180.ppm frames/f0300.ppm frames/f0450.ppm frames/f0600.ppm
if [ "$mode" = fb ]; then
  python3 "$ROOT/fpga/g1942_hdmi/sim/ppm2png.py" "$W/upright_fb.png" frames/u0119.ppm \
    frames/u0179.ppm frames/u0299.ppm frames/u0419.ppm frames/u0539.ppm
fi
