#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Simulation of Pang or Super Pang (game_core with jotego's jtpang) with Verilator 5, the
# frames compared with MAME's. FRAMES frames from the reset (default 600), every 10th
# written out, coin and start at COIN_F and START_F (frames, default none: attract mode).
#
# FIRE_F and FIRE_N press button 1 FIRE_N times, every 30 frames from frame FIRE_F.
# Usage: [SET=pang|spang|bbros|sbbros] [FRAMES=n] [COIN_F=n] [START_F=n] [FIRE_F=n] [FIRE_N=n] [MAME_OFS=n] sh fpga/pang_hdmi/sim/run_sim.sh [port|path]
#   port   the ROM buses read through a model of rom_sdram's read stream
#   path   through the real rom_sdram.sv, sdram_share.sv, sdram_fb.v and an SDRAM model
# EXTRA adds Verilator options.
#
# Needs roms/<SET>.zip (the ROM file is built from it with make_rom.py, as for the SD card).
# With MAME on the path (mame_ref.lua, SDL dummy drivers, no window): MAME's decrypted views of
# the program, against which the testbench checks every ROM byte the CPU takes, and MAME's
# frames of the same run, compared by compare_frames.py. The Z80 in Verilog, jtframe's T80s.v,
# comes from jtcores at the commit our copy is from and is checked by its git blob hash, as
# in fpga/g1942_hdmi/sim/run_sim.sh. Everything generated, the ROM image included, goes to
# $WORK (default ${TMPDIR:-/tmp}/verilator_<SET>), never into the tree.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
G="$HERE/../src"
J="$G/jtcores"
FW="$J/modules/jtframe/hdl"
SET="${SET:-pang}"
FRAMES="${FRAMES:-600}"
COIN_F="${COIN_F:-0}"
START_F="${START_F:-0}"
FIRE_F="${FIRE_F:-0}"
FIRE_N="${FIRE_N:-1}"
W="${WORK:-${TMPDIR:-/tmp}/verilator_$SET}"
mode="${1:-port}"
JTCORES=548b87b32a1b528a16cb41f689accb179e85d1a8
T80S_BLOB=6baa20633ae0d8bf389290b7252b74490bba62bd
case "$SET" in
  pang|bbros)   nbanks=8 ;;
  spang|sbbros) nbanks=16 ;;
  *) echo "SET is pang, spang, bbros or sbbros" >&2; exit 2 ;;
esac
case "$mode" in
  port) define="" ;;
  path) define="+define+ROM_PATH" ;;
  *) echo "usage: $0 [port|path]" >&2; exit 2 ;;
esac
mkdir -p "$W/frames_$mode" "$W/mame"
rm -f "$W/frames_$mode"/*.ppm

# the ROM file, as words for the SDRAM side and as bytes for the two write port sections
python3 "$ROOT/scripts/make_rom.py" --no-footer "$HERE/../$SET.manifest" "$W/$SET.rom"
python3 - "$W" "$SET" <<'EOF'
import sys
w = sys.argv[1]
b = open(w + "/" + sys.argv[2] + ".rom", "rb").read()
with open(w + "/rom32.hex", "w") as f:
    for i in range(0, 0x170000, 4):
        f.write("%08x\n" % int.from_bytes(b[i:i + 4], "little"))
with open(w + "/ee.hex", "w") as f:
    f.writelines("%02x\n" % x for x in b[0x170000:0x170080])
with open(w + "/id.hex", "w") as f:
    f.writelines("%02x\n" % x for x in b[0x170080:0x170084])
EOF
python3 "$ROOT/scripts/make_rom.py" --package "$HERE/../pang.manifest" "$W/rom_map_pkg.sv" "$HERE/../spang.manifest"

# MAME: the decrypted views once, the frames of this run
kab=""
if command -v mame > /dev/null; then
  mrun() {
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy mame "$SET" -rompath "$ROOT/roms" -video none \
      -sound none -keyboardprovider none -mouseprovider none -joystickprovider none -nothrottle \
      -skip_gameinfo -nvram_directory "$W/mame/nvram_$1" -cfg_directory "$W/mame/cfg_$1" \
      -snapshot_directory "$W/mame/snap" -autoboot_script "$HERE/mame_ref.lua"
  }
  rm -rf "$W/mame/nvram_views" "$W/mame/nvram_frames" "$W/mame/snap"
  MODE=views OUT="$W/mame/views" NBANKS=$nbanks mrun views > "$W/mame/views.log" 2>&1
  python3 - "$W" <<'EOF'
import sys
w = sys.argv[1]
for src, dst in (("views", "kab_data.hex"), ("views.op", "kab_op.hex")):
    b = open(w + "/mame/" + src, "rb").read()
    open(w + "/" + dst, "w").writelines("%02x\n" % x for x in b)
print(len(b))
EOF
  kab="+kab_n=$(wc -c < "$W/mame/views" | tr -d ' ')"
  # MAME counts its frames from another moment: MAME_OFS moves coin and start by as many
  # frames as the offset compare_frames.py reports for an attract run of the same set
  mofs="${MAME_OFS:-0}"
  mcoin=$COIN_F; mstart=$START_F; mfire=$FIRE_F
  [ "$COIN_F" -ne 0 ] && mcoin=$((COIN_F + mofs))
  [ "$START_F" -ne 0 ] && mstart=$((START_F + mofs))
  [ "$FIRE_F" -ne 0 ] && mfire=$((FIRE_F + mofs))
  MODE=frames EVERY=1 LAST="$((FRAMES + 30))" COIN_F="$mcoin" START_F="$mstart" FIRE_F="$mfire" FIRE_N="$FIRE_N" mrun frames \
    > "$W/mame/frames.log" 2>&1 &
  mame_pid=$!
fi

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
OPL="$G/jtopl/hdl"
OKI="$G/jt6295/hdl"
P="$J/cores/pang/hdl"
verilator --binary --timing -j 8 -O3 --top-module tb_pang -Mdir "$W/obj_$mode" $define ${EXTRA:-} \
  -GFRAMES="$FRAMES" -GCOIN_F="$COIN_F" -GSTART_F="$START_F" -GFIRE_F="$FIRE_F" -GFIRE_N="$FIRE_N" \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD +define+TV80S \
  "$G/jtpang_defs.v" \
  "$FW/ram/jtframe_dual_ram.v" "$FW/ram/jtframe_dual_nvram.v" "$FW/ram/jtframe_obj_buffer.v" \
  "$W/T80s.v" "$FW/cpu/jtframe_z80wait.v" "$FW/cpu/jtframe_z80.v" \
  "$FW/jtframe_sh.v" "$FW/video/jtframe_vtimer.v" "$FW/video/jtframe_draw.v" \
  "$FW/video/jtframe_objdraw_gate.v" "$FW/video/jtframe_objdraw.v" \
  "$FW/jtframe_bcd_cnt.v" "$FW/clocking/jtframe_freqinfo.v" "$FW/clocking/jtframe_gated_cen.v" \
  "$OPL"/jtopl_*.v "$OPL"/jtopll_*.v "$OPL/jt2413.v" \
  "$OKI"/jt12_*.v "$OKI"/jt6295_*.v "$OKI/jt6295.v" \
  "$G/jteeprom/hdl/jt9346.v" "$G/jteeprom/hdl/jt9346_16b8b.v" \
  "$P/jtpang_main.v" "$P/jtpang_snd.v" "$P/jtpang_char.v" "$P/jtpang_obj.v" "$P/jtpang_colmix.v" \
  "$P/jtpang_video.v" \
  "$ROOT/fpga/common/src/rom_slots.sv" "$ROOT/fpga/common/src/sdram_fb.v" \
  "$ROOT/fpga/common/src/rom_sdram.sv" "$ROOT/fpga/common/src/sdram_share.sv" \
  "$G/gpang_mirror.sv" "$W/rom_map_pkg.sv" "$G/game_pkg.sv" "$G/game_core.sv" "$HERE/tb_pang.sv" \
  > "$W/build_$mode.log" 2>&1 || { cat "$W/build_$mode.log"; exit 1; }

cd "$W"
rm -rf frames && ln -s "frames_$mode" frames
"./obj_$mode/Vtb_pang" $kab
if [ -n "${mame_pid:-}" ]; then
  wait "$mame_pid"
  python3 "$HERE/compare_frames.py" "$W/frames_$mode" "$W/mame/snap" "$W/compare_$mode.png" 24
fi
