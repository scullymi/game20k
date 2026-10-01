#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Simulation of the Pac-Man RAM mirror with nvc (VHDL-2008): the mirror alone against a core
# emulator and a platform model (tb_mirror_unit), then the whole core with the mirror and a
# hand-assembled Z80 program (tb_pacman). Both end with one line PASS or a severity failure;
# this script exits nonzero on failure. game_core.sv is not covered: nvc cannot elaborate a
# SystemVerilog parent over a VHDL entity, the wrapper is checked by the Gowin build only.
#
# Usage: sh fpga/pacman_hdmi/sim/run_sim.sh [unit|core]     (default: both)
# The work library goes to $WORK (default ${TMPDIR:-/tmp}/nvc_pacman), never into the tree.
# --ieee-warnings=off must come BEFORE -a: after -r it has no effect on the metavalue
# warnings of the core's std_logic_unsigned arithmetic.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HERE/.."
W="${WORK:-${TMPDIR:-/tmp}/nvc_pacman}"
NVC="${NVC:-nvc}"
what="${1:-all}"
rm -rf "$W"
mkdir -p "$W"
cd "$D"
"$NVC" --std=2008 --ieee-warnings=off --work=work:"$W" -a \
  src/rtl_T80/T80_Pack.vhd src/rtl_T80/T80_ALU.vhd src/rtl_T80/T80_MCode.vhd \
  src/rtl_T80/T80_Reg.vhd src/rtl_T80/T80.vhd src/rtl_T80/T80sed.vhd \
  src/rtl_pacman/g20k_dpram.vhd src/rtl_pacman/sn76489_top.vhd src/rtl_pacman/ym2149.vhd \
  src/rtl_pacman/pacman_vram_addr.vhd src/rtl_pacman/pacman_video.vhd \
  src/rtl_pacman/pacman_audio.vhd src/rtl_pacman/pacman_rom_descrambler.vhd \
  src/rtl_pacman/pacman.vhd src/rtl_pacman/pacman_mirror.vhd \
  sim/tb_mirror_unit.vhd sim/tb_pacman.vhd
if [ "$what" = all ] || [ "$what" = unit ]; then
  "$NVC" --std=2008 --ieee-warnings=off --work=work:"$W" -e tb_mirror_unit -r
fi
if [ "$what" = all ] || [ "$what" = core ]; then
  "$NVC" --std=2008 --ieee-warnings=off --work=work:"$W" -e tb_pacman -r
fi
