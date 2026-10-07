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
G="$HERE/../src"
J="$G/jtcores"
FW="$J/modules/jtframe/hdl"
SET="${SET:-1942}"
W="${WORK:-${TMPDIR:-/tmp}/verilator_$SET}"
mode="${1:-port}"
JTCORES=0b197caeae1596380863b8388552b125e7e1b208
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
python3 "$ROOT/scripts/make_rom.py" "$ROOT/fpga/g1942_hdmi/$SET.manifest" "$W/$SET.rom"
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
# the package the build makes from the manifests (build.tcl), for FB_CCW
python3 "$ROOT/scripts/make_rom.py" --package "$HERE/../vulgus.manifest" "$W/rom_map_pkg.sv" \
  "$HERE/../1942.manifest" "$HERE/../higemaru.manifest"

# the Verilog Z80 for simulation, once
if [ ! -f "$W/T80s.v" ] || [ "$(git hash-object "$W/T80s.v")" != "$T80S_BLOB" ]; then
  curl -sfL -o "$W/T80s.v" \
    "https://raw.githubusercontent.com/jotego/jtcores/$JTCORES/modules/jtframe/hdl/cpu/t80/T80s.v"
  if [ "$(git hash-object "$W/T80s.v")" != "$T80S_BLOB" ]; then
    echo "T80s.v: not the file of jtcores $JTCORES" >&2
    exit 1
  fi
fi

# the sources in the order of build.tcl, the VHDL T80 replaced by T80s.v
verilator --binary --timing -j 8 -O3 --top-module tb_1942 -Mdir "$W/obj_$mode" $define $id ${EXTRA:-} \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  +define+TV80S +incdir+"$G/inc" +incdir+"$FW/inc" +incdir+"$J/cores/1942/hdl" \
  "$G/jt1942_defs.v" \
  "$FW/ram/jtframe_prom.v" "$FW/ram/jtframe_ram.v" "$W/T80s.v" \
  "$FW/ram/jtframe_dual_ram.v" "$FW/ram/jtframe_dual_nvram.v" "$FW/cpu/jtframe_z80wait.v" \
  "$FW/cpu/jtframe_z80.v" "$J/cores/1942/hdl/jt1942_main.v" \
  "$G/jt49/hdl/jt49_cen.v" "$G/jt49/hdl/jt49_div.v" "$G/jt49/hdl/jt49_eg.v" \
  "$G/jt49/hdl/jt49_exp.v" "$G/jt49/hdl/jt49_noise.v" "$G/jt49/hdl/jt49.v" "$G/jt49/hdl/jt49_bus.v" \
  "$J/cores/1942/hdl/jt1942_sound.v" "$FW/jtframe_sh.v" "$FW/video/jtframe_blank.v" \
  "$J/cores/1942/hdl/jt1942_colmix.v" "$J/cores/1942/hdl/jt1942_objdraw.v" \
  "$J/cores/1942/hdl/jt1942_objram.v" "$J/cores/1942/hdl/jt1942_objtiming.v" \
  "$J/cores/gng/hdl/jtgng_objpxl.v" "$J/cores/1942/hdl/jt1942_obj.v" \
  "$FW/video/tilemap/jtframe_tilemap.v" \
  "$J/cores/gng/hdl/jtgng_tile3.v" "$J/cores/gng/hdl/jtgng_tile4.v" "$J/cores/gng/hdl/jtgng_tilemap.v" \
  "$J/cores/gng/hdl/jtgng_scroll.v" "$J/cores/gng/hdl/jtgng_timer.v" \
  "$J/cores/1942/hdl/jt1942_video.v" "$J/cores/1942/hdl/jt1942_game.v" \
  "$FW/jtframe_bcd_cnt.v" "$FW/clocking/jtframe_freqinfo.v" "$FW/clocking/jtframe_gated_cen.v" \
  "$FW/ram/jtframe_dual_ram16.v" \
  "$ROOT/fpga/common/src/rom_slots.sv" "$ROOT/fpga/common/src/sdram_fb.v" \
  "$ROOT/fpga/common/src/rom_sdram.sv" "$ROOT/fpga/common/src/sdram_share.sv" \
  "$ROOT/fpga/common/src/fb_pack.sv" "$ROOT/fpga/common/src/fb_read_rotated.sv" \
  "$G/g1942_mirror.sv" "$W/rom_map_pkg.sv" "$G/game_pkg.sv" "$G/game_core.sv" "$HERE/tb_1942.sv" \
  > "$W/build_$mode.log" 2>&1 || { cat "$W/build_$mode.log"; exit 1; }

cd "$W"
"./obj_$mode/Vtb_1942"
python3 "$HERE/ppm2png.py" "$W/frames_$mode.png" frames/f0060.ppm frames/f0120.ppm \
  frames/f0180.ppm frames/f0300.ppm frames/f0450.ppm frames/f0600.ppm
if [ "$mode" = fb ]; then
  python3 "$HERE/ppm2png.py" "$W/upright_fb.png" frames/u0119.ppm frames/u0179.ppm \
    frames/u0299.ppm frames/u0419.ppm frames/u0539.ppm
fi
