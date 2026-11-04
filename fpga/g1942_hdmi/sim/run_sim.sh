#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Simulation of 1942 (game_core with jotego's jt1942) with Verilator 5: ten seconds of the
# game, attract mode, a coin and a start, every 30th frame written out, at the end one PNG
# sheet of the frames, turned upright. Takes about six minutes (port), ten (path).
#
# Usage: [SET=1942|vulgus|higemaru] sh fpga/g1942_hdmi/sim/run_sim.sh [port|path|fb]
#   (default: SET=1942, port). EXTRA adds Verilator options, such as +define+HIGEDBG
#   port   the ROM buses read through a model of rom_sdram's read port, latency as measured
#   path   through the real rom_sdram.sv, sdram_fb.v and an SDRAM model (tb define ROM_PATH)
#   fb     path, and the upright picture as on the device: sdram_share.sv puts the frame
#          buffer (fb_pack.sv, fb_read_rotated.sv) next to the ROM on the controller
#
# Needs roms/<SET>.zip (the ROM file is built from it with make_rom.py, as for the SD card)
# and network access once: the Z80 in Verilog, jtframe's T80s.v, comes from jtcores at the
# commit our copy is from and is checked by its git blob hash. It is a machine translation
# of the T80 without its licence header, so it is fetched, not kept in this tree.
# Everything generated, the ROM image included, goes to $WORK (default
# ${TMPDIR:-/tmp}/verilator_<SET>), never into the tree.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SET="${SET:-1942}"
W="${WORK:-${TMPDIR:-/tmp}/verilator_$SET}"
mode="${1:-port}"
JTCORES=548b87b32a1b528a16cb41f689accb179e85d1a8
T80S_BLOB=6baa20633ae0d8bf389290b7252b74490bba62bd

case "$mode" in
  port) define="" ;;
  path) define="+define+ROM_PATH" ;;
  fb)   define="+define+ROM_PATH +define+FB_PATH" ;;
  *) echo "usage: $0 [port|path|fb]" >&2; exit 2 ;;
esac
mkdir -p "$W/frames"
rm -f "$W"/frames/*.ppm

# the ROM image, as words for the SDRAM side and as bytes for the PROMs
python3 "$ROOT/scripts/make_rom.py" --no-footer "$ROOT/fpga/g1942_hdmi/$SET.manifest" "$W/$SET.rom"
python3 - "$W" "$SET" <<'EOF'
import sys
w = sys.argv[1]
b = open(w + "/" + sys.argv[2] + ".rom", "rb").read()
with open(w + "/rom32.hex", "w") as f:
    for i in range(0, len(b), 4):
        f.write("%08x\n" % int.from_bytes(b[i:i + 4], "little"))
with open(w + "/proms.hex", "w") as f:
    f.writelines("%02x\n" % x for x in b[0x3A000:0x3AA00])
# the id section of Vulgus and Higemaru, none for 1942
with open(w + "/id.hex", "w") as f:
    f.writelines("%02x\n" % x for x in b[0x3AA00:0x3AB00])
EOF
id=""
[ -s "$W/id.hex" ] && id="+define+ID_SECTION"

# the Verilog Z80 for simulation, once
if [ ! -f "$W/T80s.v" ] || [ "$(git hash-object "$W/T80s.v")" != "$T80S_BLOB" ]; then
  curl -sfL -o "$W/T80s.v" \
    "https://raw.githubusercontent.com/jotego/jtcores/$JTCORES/modules/jtframe/hdl/cpu/t80/T80s.v"
  if [ "$(git hash-object "$W/T80s.v")" != "$T80S_BLOB" ]; then
    echo "T80s.v: not the file of jtcores $JTCORES" >&2
    exit 1
  fi
fi

# the core's sources as the build reads them (core.toml, its generated files into $W/gen,
# the package with FB_CCW among them), the VHDL T80 replaced by T80s.v
files=$(python3 "$ROOT/g20k.py" sources "$ROOT/fpga/g1942_hdmi" --out "$W")
incdirs=$(python3 "$ROOT/g20k.py" sources "$ROOT/fpga/g1942_hdmi" --out "$W" --include 2>/dev/null | sed 's|^|+incdir+|')
verilator --binary --timing -j 8 -O3 --top-module tb_1942 -Mdir "$W/obj_$mode" $define $id ${EXTRA:-} \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  +define+TV80S $incdirs \
  "$W/T80s.v" "$W/gen/iface_pkg.sv" $files \
  "$ROOT/fpga/common/src/rom_slots.sv" "$ROOT/fpga/common/src/sdram_fb.v" \
  "$ROOT/fpga/common/src/rom_sdram.sv" "$ROOT/fpga/common/src/sdram_share.sv" \
  "$ROOT/fpga/common/src/fb_pack.sv" "$ROOT/fpga/common/src/fb_read_rotated.sv" \
  "$HERE/tb_1942.sv" \
  > "$W/build_$mode.log" 2>&1 || { cat "$W/build_$mode.log"; exit 1; }

cd "$W"
"./obj_$mode/Vtb_1942"
python3 "$HERE/ppm2png.py" "$W/frames_$mode.png" frames/f0060.ppm frames/f0120.ppm \
  frames/f0180.ppm frames/f0300.ppm frames/f0450.ppm frames/f0600.ppm
if [ "$mode" = fb ]; then
  python3 "$HERE/ppm2png.py" "$W/upright_fb.png" frames/u0119.ppm frames/u0179.ppm \
    frames/u0299.ppm frames/u0419.ppm frames/u0539.ppm
fi
