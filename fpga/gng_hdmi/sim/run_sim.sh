#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Simulation of Ghosts'n Goblins (game_core with jotego's jtgng) with Verilator 5,
# after fpga/g1943_hdmi/sim/run_sim.sh: 25 seconds of the game (the power-on test alone takes
# about 8), every 30th frame written out, late ROM data counted. A coin after 9 s and a start
# after 10 s unless SIM_DEFINES has +define+ATTRACT.
#
# Usage: [SET=gng|makaimurg] sh fpga/gng_hdmi/sim/run_sim.sh [port|path|fb]       (default: port)
#   port   the ROM buses read through a model of rom_sdram's read stream
#   path   through the real rom_sdram.sv, sdram_fb.v and an SDRAM model (tb define ROM_PATH)
#   fb     path, and the frame buffer next to the ROM on sdram_share.sv, as the top builds it
# Environment: FRAMES (default 1500), FRAME_EVERY (default 30), SIM_DEFINES, WORK.
# For compare_mame.py: MAME_DIR (snapshots), COMPARE_FROM (default 330).
#
# Needs roms/gng.zip and network access once for jtframe's T80s.v (Verilog Z80), checked by
# its git blob hash. Everything generated goes to $WORK (default ${TMPDIR:-/tmp}/verilator_<SET>):
# it is made from the ROM and stays out of the repository.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
G="$HERE/.."
SET="${SET:-gng}"
W="${WORK:-${TMPDIR:-/tmp}/verilator_$SET}"
mode="${1:-port}"
JTCORES=548b87b32a1b528a16cb41f689accb179e85d1a8
T80S_BLOB=6baa20633ae0d8bf389290b7252b74490bba62bd
case "$SET" in
  gng|makaimurg) ;;
  *) echo "SET is gng or makaimurg" >&2; exit 2 ;;
esac
case "$mode" in
  port) define="" ;;
  path) define="+define+ROM_PATH" ;;
  fb)   define="+define+ROM_PATH +define+FB_PATH" ;;
  *) echo "usage: $0 [port|path|fb]" >&2; exit 2 ;;
esac
mkdir -p "$W/frames"
rm -f "$W"/frames/*.ppm
# the ROM image, as words for the SDRAM side
python3 "$ROOT/scripts/make_rom.py" --no-footer "$G/$SET.manifest" "$W/$SET.rom"
python3 - "$W" "$SET" <<'EOF'
import sys
w = sys.argv[1]
b = open(w + "/" + sys.argv[2] + ".rom", "rb").read()
with open(w + "/rom32.hex", "w") as f:
    for i in range(0, len(b), 4):
        f.write("%08x\n" % int.from_bytes(b[i:i + 4], "little"))
EOF
# the package the build makes from the manifest (build.tcl), for FB_CCW
python3 "$ROOT/scripts/make_rom.py" --package "$G/$SET.manifest" "$W/rom_map_pkg.sv"

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
verilator --binary --timing -j 8 -O3 --top-module tb_gng -Mdir "$W/obj_$mode" $define $SIM_DEFINES \
  -GFRAMES="${FRAMES:-1500}" -GFRAME_EVERY="${FRAME_EVERY:-30}" \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  +define+TV80S +incdir+"$G/src/inc" +incdir+"$G/src/jtcores/modules/jtframe/hdl/inc" \
  +incdir+"$G/src/jtcores/cores/gng/hdl" +incdir+"$G/src/jt12/hdl" \
  "$W/T80s.v" $files \
  "$ROOT/fpga/common/src/rom_slots.sv" "$ROOT/fpga/common/src/sdram_fb.v" \
  "$ROOT/fpga/common/src/rom_sdram.sv" "$ROOT/fpga/common/src/sdram_share.sv" \
  "$ROOT/fpga/common/src/fb_pack.sv" "$ROOT/fpga/common/src/fb_read_rotated.sv" \
  "$G/src/mirror_n.sv" "$W/rom_map_pkg.sv" "$G/src/game_pkg.sv" "$G/src/game_core.sv" \
  "$HERE/tb_gng.sv" \
  > "$W/build_$mode.log" 2>&1 || { cat "$W/build_$mode.log"; exit 1; }

cd "$W"
"./obj_$mode/Vtb_gng"
# with MAME_DIR (snapshots of mame_snap.lua for the same inputs) the frames are checked
# against MAME: only then is it known that the simulation runs GnG, and runs it right
if [ -n "$MAME_DIR" ]; then
  python3 "$HERE/compare_mame.py" "$W/frames" "$MAME_DIR" --from "${COMPARE_FROM:-330}" --sheet "$W/compare.png"
fi
