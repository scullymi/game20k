#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Simulation of what the upstream Companion firmware needs from a core, with Verilator 5:
#   - rom_loader.sv takes a ROM file with the footer of make_rom.py (tb_rom_loader.sv)
#   - sysctrl.v sends each game's menu on READ_CFG (tb_sysctrl_menu.sv): the bytes it clocks
#     out must unpack to the game's gen/menu_rom.xml
# Ends with one line PASS or exits nonzero.
#
# Usage: sh fpga/common/sim/run_mcu_sim.sh
# The builds go to $WORK (default ${TMPDIR:-/tmp}/verilator_mcu), never into the tree.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="$HERE/../src"
W="${WORK:-${TMPDIR:-/tmp}/verilator_mcu}"
rm -rf "$W"
mkdir -p "$W"
VL="verilator --binary --timing -j 8 -O3 -Wno-fatal -Wno-lint -Wno-style"

$VL --top-module tb_rom_loader -Mdir "$W/loader" "$SRC/mcu/rom_loader.sv" "$HERE/tb_rom_loader.sv" \
  > "$W/loader.log" 2>&1 || { cat "$W/loader.log"; exit 1; }
"$W/loader/Vtb_rom_loader" | grep -v '^- '
"$W/loader/Vtb_rom_loader" | grep -q '^PASS$'

# every game of slots.txt, its menu ROM freshly generated
cores=$(awk '!/^#/ && NF { print $1 }' "$ROOT/fpga/common/slots.txt")
python3 "$ROOT/scripts/make_menu.py" $cores > /dev/null
for core in $cores; do
  gz=$(grep -c "^    11'd" "$ROOT/fpga/$core/gen/menu_rom.v")
  $VL --top-module tb_sysctrl_menu -Mdir "$W/$core" "$ROOT/fpga/$core/gen/menu_rom.v" \
    "$SRC/misc/sysctrl.v" "$HERE/tb_sysctrl_menu.sv" > "$W/$core.log" 2>&1 \
    || { cat "$W/$core.log"; exit 1; }
  "$W/$core/Vtb_sysctrl_menu" +bytes="$gz" +out="$W/$core.hex" | grep -q '^PASS$' \
    || { echo "FAIL $core: READ_CFG"; exit 1; }
  python3 -I -c '
import gzip, sys
data = bytes(int(l, 16) for l in open(sys.argv[1]))
xml = gzip.decompress(data).decode("utf-8")
if xml != open(sys.argv[2], encoding="utf-8").read():
    sys.exit("FAIL %s: READ_CFG unpacks to another menu than gen/menu_rom.xml" % sys.argv[3])
print("%s: READ_CFG sends %d bytes, they unpack to gen/menu_rom.xml" % (sys.argv[3], len(data)))
' "$W/$core.hex" "$ROOT/fpga/$core/gen/menu_rom.xml" "$core"
done
echo PASS
