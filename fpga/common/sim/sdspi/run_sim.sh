#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# SD card status over SPI, as the Companion polls it at start-up (tb_sdspi.v).
#   run_sim.sh rtl     the sources as written, Icarus Verilog: the reference
#   run_sim.sh slang   read by yosys-slang (proc only): the free toolchain's front end
#   run_sim.sh gate    after synth_gowin, with Yosys' models of the Gowin cells, in Verilator.
#                      No block RAM (DPB has no model), the sector buffer becomes registers.
#                      Use FAST=1. Icarus is no option here: it took 16 minutes for this
#                      netlist and, unlike the device, never sent CMD0.
# slang and gate are written back as Verilog for Icarus, with Yosys' simlib.v for its internal
# cells. In slang, registers without a start value get 0, as the FPGA starts them (setundef
# -zero -init): Till's mcu_spi has no reset on the byte toggle, Icarus would keep it undefined.
# FAST=1 sets Till's SIMULATE parameter: short waits and a fast init clock, same logic.
# All use Till's simulator ports (VERILATOR: separate SD inputs and outputs, Icarus aborts on
# gate-level tri-state buffers) and the inferred sector buffer (INFER_DPRAM).
# sd_fake.v comes from WangXuan95/FPGA-SDcard-Reader (GPL-3.0), fetched into gen/ once.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$here/../../../.." && pwd)
suite=${OSS_CAD_SUITE:-$ROOT/external/oss-cad-suite}
source "$suite/environment" >/dev/null
gen=$here/gen
mkdir -p "$gen"
fake_commit=71d6b36f4df548b71dba1aa32a7ea14846fb5175
[ -f "$gen/sd_fake.v" ] || curl -sSfL -o "$gen/sd_fake.v" \
    "https://raw.githubusercontent.com/WangXuan95/FPGA-SDcard-Reader/$fake_commit/SIM/sd_fake.v"

misc=$ROOT/fpga/common/src/misc
fast=${FAST:-0}
src="$here/sdspi_dut.v $misc/mcu_spi.v $misc/sd_card.v $misc/sd_rw.v $misc/sdcmd_ctrl.v"
defs="-U SYNTHESIS -D YOSYS -D VERILATOR -D INFER_DPRAM -D SDSPI_FAST=$fast"
d=$(yosys-config --datdir)
case "${1:-}" in
rtl)
    iverilog -g2012 -DINFER_DPRAM -DVERILATOR -DTB_RTL -DSDSPI_FAST=$fast -o "$gen/tb_rtl.vvp" \
        -s tb_sdspi "$here/tb_sdspi.v" "$gen/sd_fake.v" $src ;;
slang)
    # keep the hierarchy, so that the test bench finds sd_rw's state register
    yosys -m slang -q -p "read_slang --single-unit --keep-hierarchy $defs $src --top sdspi_dut; proc; setundef -zero -init; write_verilog -noattr $gen/sdspi_slang.v"
    iverilog -g2012 -DSDSPI_FAST=$fast -o "$gen/tb_slang.vvp" -s tb_sdspi "$here/tb_sdspi.v" \
        "$gen/sd_fake.v" "$gen/sdspi_slang.v" "$d/simlib.v" ;;
gate)
    yosys -m slang -q -p "read_slang --single-unit $defs $src --top sdspi_dut; synth_gowin -family gw2a -top sdspi_dut -nobram -noiopads; techmap t:\$buf; opt_clean; write_verilog -noattr $gen/sdspi_gate.v"
    verilator --binary --timing -j 8 -Wno-fatal -Wno-lint -Wno-style --top-module tb_sdspi \
        -DTB_GATE -DSDSPI_FAST=$fast --Mdir "$gen/obj_gate" -o tb_gate "$here/tb_sdspi.v" \
        "$gen/sd_fake.v" "$gen/sdspi_gate.v" "$d/gowin/cells_sim.v" > "$gen/verilator_gate.log"
    exec "$gen/obj_gate/tb_gate" ;;
*)
    echo "Usage: run_sim.sh rtl|slang|gate" >&2; exit 2 ;;
esac
vvp -n "$gen/tb_$1.vvp"
