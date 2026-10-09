#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Simulation of audio_cdc.sv with Verilator 5: the audio word through the HDMI module into its
# audio sample packets, next to the former path (tb_audio_cdc.sv). The core clocks of the
# games (18.5625, 37.125 and 46.40625 MHz), each at 14 offsets to the pixel clock and once
# detuned by 3 ppm, with routing skew, and once without. The new path must deliver every
# word whole and in order. The former path must tear words in some run with skew, or the
# skew model does not work. Ends with one line PASS or exits nonzero.
#
# Usage: sh fpga/common/sim/run_audio_sim.sh
# The build and the logs go to $WORK (default ${TMPDIR:-/tmp}/verilator_audio), never into
# the tree.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src"
H="$SRC/hdmi"
W="${WORK:-${TMPDIR:-/tmp}/verilator_audio}"
mkdir -p "$W"
verilator --binary --timing -j 8 -O3 --timescale 1ns/1ps --top-module tb_audio_cdc -Mdir "$W/obj" \
  -Wno-fatal -Wno-lint -Wno-style \
  "$H/audio_info_frame.sv" "$H/audio_sample_packet.sv" "$H/auxiliary_video_information_info_frame.sv" \
  "$H/packet_assembler.sv" "$H/packet_picker.sv" "$H/serializer.sv" \
  "$H/source_product_description_info_frame.sv" "$H/tmds_channel.sv" "$H/hdmi.sv" \
  "$SRC/audio_cdc.sv" "$HERE/tb_audio_cdc.sv" > "$W/build.log" 2>&1 \
  || { cat "$W/build.log"; exit 1; }

# one run per line: core clock period (ns), offset (ns), detuning (ppm), skew, samples
for c in 53.872 26.936 21.5488; do
  for p in 0 1 2 3 4 5 6 7 8 9 10 11 12 13; do echo "$c $p 0 1 400"; done
  echo "$c 0 3 1 1000"
  echo "$c 5 0 0 400"
done > "$W/runs.txt"
# eight at a time, each with a log of its own
xargs -P 8 -L 1 sh -c '"$0/obj/Vtb_audio_cdc" +core_ns=$1 +phase_ns=$2 +ppm=$3 +skew=$4 +samples=$5 \
  > "$0/run_$1_$2_$3_$4.log" 2>&1 || echo "FAIL $*" >> "$0/run_$1_$2_$3_$4.log"' "$W" < "$W/runs.txt"
cat "$W"/run_*.log | grep -v '^- ' > "$W/sim.log" || true
cat "$W/sim.log"

if grep -q -e FAIL -e '%Fatal' -e '%Error' "$W/sim.log"; then
  echo "FAIL: the new path lost, repeated or tore a word"
  exit 1
fi
n=$(grep -c '^core' "$W/sim.log" || true)
if [ "$n" -ne "$(wc -l < "$W/runs.txt")" ]; then
  echo "FAIL: $n of $(wc -l < "$W/runs.txt" | tr -d ' ') runs reported"
  exit 1
fi
# the counter-check: with skew the former path must tear words somewhere
torn=$(awk '/skew 1/ { for (i = 1; i <= NF; i++) if ($i == "old") s += $(i + 3) } END { print s + 0 }' "$W/sim.log")
if [ "$torn" -eq 0 ]; then
  echo "FAIL: the former path tore no word, so the skew model does not work"
  exit 1
fi
echo "$n runs, the former path tore $torn words in the runs with skew, the new path none"
echo PASS
