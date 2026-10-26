#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Builds one core with the free toolchain: GHDL (VHDL), yosys-slang (Verilog, SystemVerilog),
# Yosys, nextpnr-himbaechel and Apicula's gowin_pack.
#   scripts/build_fpga_oss.sh <project folder under fpga/>
# Output in fpga/<core>/impl/oss/, the bitstream is <core>.fs there.
#
# The file list comes from the core's build.tcl, run with stubbed Gowin commands
# (scripts/oss/gowin_files.tcl). Settings per core in fpga/<core>/oss.conf:
#   VHDL_TOPS   the VHDL entities the SystemVerilog side instantiates
#   VHDL_X_OK   VHDL outputs that are undefined on purpose (regex, word match)
#   RAM_BLOCK   memories that go into block RAM although Yosys would pick LUT RAM
#   RAM_LOGIC   memories that go into flip-flops although Yosys would pick LUT RAM
#   VHDL_SKIP   VHDL files (names) of build.tcl that the free build leaves out
#   SV_EXTRA    Verilog files (relative to the core folder) read in their place, e.g. for a VHDL
#               entity instantiated with different generics, which GHDL cannot hand over
#   BLOCK_FILL  0 turns off the second Yosys run that puts more memories into free block RAM
#   SLANG_OPTS  extra options for read_slang, e.g. to accept code that slang rejects and Gowin
#               does not (out-of-range selects in dead branches, delays in assignments)
#   ALU_LUT     adders, subtractors and comparisons up to this width go to LUTs, wider ones to
#               the ALU chain (default 8; synth_gowin alone keeps 2)
#   SEED        placement seed for nextpnr, empty for nextpnr's default
# OSS_DEFINES in the environment passes extra macros to slang, e.g. "-D NAME" for a diagnostic build.
# SYNTH_ONLY=1 stops after Yosys, for looking at the netlist and its statistics.
#
# nextpnr, Apicula and sv-elab (the slang frontend): scripts/oss/build_tools.sh builds them into
# external/oss-tools/, nextpnr and Apicula from game20k's forks, which carry fixes not yet upstream. NEXTPNR, APICULA
# and SLANG (the path of a slang.so) override them. It also builds a Yosys plugin with fixes for
# the suite's Yosys (scripts/oss/yosys/), YOSYS_FIXES overrides its path.
# Toolchain: YosysHQ's oss-cad-suite under external/ (ignored by git), two builds for now, both
# downloaded and checked by scripts/oss/fetch_suite.sh:
#   OSS_CAD_SUITE  2026-10-03 or later. Its Apicula fixes a crash on PLLs left of column 27.
#   GHDL_SUITE     2026-09-10. GHDL 7.0.0-dev of 2026-10-03 aborts in synthesis
#                  (netlists.adb:978), even on small designs. The macOS suite of 2026-10-18 has
#                  a GHDL plugin that does not load into its Yosys.
set -euo pipefail
[ -n "${1:-}" ] || { echo "Usage: scripts/build_fpga_oss.sh <project folder under fpga/>" >&2; exit 2; }
core=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
suite=${OSS_CAD_SUITE:-$ROOT/external/oss-cad-suite}
# nextpnr and Apicula from game20k's forks, built by scripts/oss/build_tools.sh, unless NEXTPNR or
# APICULA name others
tools=$ROOT/external/oss-tools
[ -z "${NEXTPNR:-}" ] && [ -x "$tools/nextpnr/build/nextpnr-himbaechel" ] && NEXTPNR=$tools/nextpnr/build/nextpnr-himbaechel
[ -z "${APICULA:-}" ] && [ -d "$tools/apicula/apycula" ] && APICULA=$tools/apicula
[ -z "${SLANG:-}" ] && [ -f "$tools/sv-elab/build/slang.so" ] && SLANG=$tools/sv-elab/build/slang.so
[ -z "${YOSYS_FIXES:-}" ] && [ -f "$tools/yosys/fixes.so" ] && YOSYS_FIXES=$tools/yosys/fixes.so
ghdl_suite=${GHDL_SUITE:-$ROOT/external/oss-cad-suite-20260910}
for s in "$suite" "$ghdl_suite"; do
    [ -f "$s/environment" ] || { echo "$s/environment missing, see the head of this script" >&2; exit 1; }
done
# slang.so and fixes.so from external/oss-tools are built against the headers of one Yosys.
# Loaded into another one they crash or run with the wrong layout, so a new suite needs
# scripts/oss/build_tools.sh again.
case "${SLANG:-}${YOSYS_FIXES:-}" in
    *"$tools/"*)
        if [ "$("$suite/bin/yosys" -V)" != "$(cat "$tools/yosys-version.txt" 2>/dev/null)" ]; then
            echo "external/oss-tools is not built for the suite's Yosys, run scripts/oss/build_tools.sh" >&2
            exit 1
        fi ;;
esac
out=$ROOT/fpga/$core/impl/oss
mkdir -p "$out/ghdl"
VHDL_TOPS= VHDL_X_OK= RAM_BLOCK= RAM_LOGIC= VHDL_SKIP= SV_EXTRA= BLOCK_FILL=1 SLANG_OPTS= ALU_LUT=8 SEED=
[ -f "$ROOT/fpga/$core/oss.conf" ] && . "$ROOT/fpga/$core/oss.conf"
source "$suite/environment" >/dev/null

cd "$ROOT/fpga/$core"
tclsh "$ROOT/scripts/oss/gowin_files.tcl" > "$out/files.txt"
vhdl=$(awk '$1=="hdl" && $2 ~ /\.vhdl?$/ {print $2}' "$out/files.txt" | tr '\n' ' ')
sv=$(awk '$1=="hdl" && $2 !~ /\.vhdl?$/ {print $2}' "$out/files.txt" | tr '\n' ' ')
for f in $VHDL_SKIP; do vhdl=$(echo " $vhdl " | sed "s| [^ ]*/$f | |"); done
for f in $SV_EXTRA; do sv="$sv $ROOT/fpga/$core/$f"; done
# the sources this build reads, for the NOTICE (scripts/bitstream_notice.py). Written first, so
# that a bitstream older than it is one of an earlier or a broken build.
printf '%s\n' $vhdl $sv > "$out/sources.txt"
cst=$(awk '$1=="cst" {print $2}' "$out/files.txt")
# board.cst is in the Gowin IDE's form. nextpnr needs each pin of a differential pair in its own line.
python3 "$ROOT/scripts/oss/cst_pairs.py" "$cst" > "$out/board_oss.cst"
cst=$out/board_oss.cst
sdc=$(awk '$1=="sdc" {print $2}' "$out/files.txt")
top=$(awk '$1=="option" && $2=="-top_module" {print $3}' "$out/files.txt")
inc=$(awk '$1=="option" && $2=="-include_path" {print $3}' "$out/files.txt" | tr ';' '\n' | sed 's/^/-I /' | tr '\n' ' ')
mb=$(awk '$1=="option" && $2=="-multiboot_spi_flash_address" {print $3}' "$out/files.txt")

# VHDL: each top entity in a Yosys run of its own, written as RTLIL. Two tops that share a
# submodule with the same generics would define it twice in one run (Pac-Man: g20k_dpram).
echo "== ghdl"
for t in $VHDL_TOPS; do
    (source "$ghdl_suite/environment" >/dev/null && yosys -m ghdl -q -l "$out/ghdl_$t.log" -p \
        "ghdl --std=08 -fsynopsys --workdir=$out/ghdl $vhdl -e $t; write_rtlil $out/vhdl_$t.il")
    # GHDL can turn a process into constants without a message (a clock edge in both the if and
    # the elsif branch). Yosys then removes everything behind an undefined output, so stop here.
    vtop=$(grep -m1 '^module ' "$out/vhdl_$t.il" | awk '{print $2}')   # GHDL lowercases, top first
    yosys -q -p "read_rtlil $out/vhdl_$t.il; hierarchy -top $vtop; proc; flatten; opt -full; opt_clean -purge; write_verilog -noattr $out/vhdl_only_$t.v"
    ports=$(grep -E '^\s*output' "$out/vhdl_only_$t.v" | sed -E 's/.*output (\[[^]]+\] )?//;s/;//' | paste -sd'|' -)
    if grep -E "assign ($ports)(\s*\[[^]]+\])? = [0-9]+'h[x]+;" "$out/vhdl_only_$t.v" \
        | grep -vwE "${VHDL_X_OK:-^$}"; then
        echo "GHDL leaves outputs of $t undefined" >&2; exit 1
    fi
done

# The Gowin primitives as empty modules with their parameters, so that defparam and #() resolve
# in slang and the primitives stay cells
python3 "$ROOT/scripts/oss/gowin_prims.py" "$suite/share/yosys/gowin" "$out/gowin_prims.v" \
    rPLL OSER10 ELVDS_OBUF CLKDIV DPB BUFG
write_synth() {
{
    for t in $VHDL_TOPS; do
        echo "read_rtlil -nooverwrite $out/vhdl_$t.il"
    done
    # slang defines SYNTHESIS, Gowin does not: with it serializer.sv picks its Xilinx branch.
    # YOSYS, which Yosys' own reader sets, hides the $error in sd_card.v. Till's files use names
    # before their declaration.
    echo "read_slang --single-unit --empty-blackboxes --allow-use-before-declare -U SYNTHESIS -D YOSYS ${SLANG_OPTS} ${OSS_DEFINES:-} -v $out/gowin_prims.v $inc $sv --top $top"
    echo "hierarchy -check -top $top"
    echo "write_rtlil $out/elab.il"
} > "$out/elab.ys"
{
    echo "read_rtlil $out/elab.il"
    echo "hierarchy -top $top"
    # synth_gowin's coarse step, with one addition before alumacc: comparisons go to LUT-sized
    # chunks (cmp2lut, cmp2lcu) instead of a carry chain each, as synth_ice40 and synth_ecp5 do.
    # Without it every comparison with a constant costs one ALU per bit of the wider operand.
    echo "synth_gowin -family gw2a -top $top -run begin:coarse"
    # Undriven nets become undefined, and muxes may treat undefined inputs as don't care: an
    # array of 256 packet types with six of them assigned (hdmi/packet_picker.sv) shrinks to
    # a six-way mux, as Gowin builds it
    # Registers without an asynchronous reset start at 0, as the FPGA starts them. The cores rely
    # on it (Galaga's star state machine has neither reset nor start value): without a start
    # value Yosys recodes such a state machine with a guessed reset state, and all zeros is no
    # valid state any more.
    echo "proc; check; flatten; opt_clean; setundef -zero -init t:\\\$dff t:\\\$dffe t:\\\$sdff t:\\\$sdffe t:\\\$sdffce"
    echo "setundef -undriven -undef; tribuf -logic; deminout; opt_expr -mux_undef; check; opt_clean"
    echo "opt -nodffe -nosdff -mux_undef; fsm; opt -mux_undef; wreduce; peepopt; opt_clean; share"
    for r in "36 36 22 22 \\\$__MUL36X36" "18 18 10 4 \\\$__MUL18X18" "18 18 4 10 \\\$__MUL18X18" "9 9 4 4 \\\$__MUL9X9"; do
        set -- $r
        echo "techmap -map +/mul2dsp.v -D DSP_A_MAXWIDTH=$1 -D DSP_B_MAXWIDTH=$2 -D DSP_A_MINWIDTH=$3 -D DSP_B_MINWIDTH=$4 -D DSP_NAME=$5"
        echo "chtype -set \$mul t:\$__soft_mul"
    done
    echo "techmap -map +/gowin/dsp_map.v"
    echo "techmap -map +/cmp2lut.v -map +/cmp2lcu.v -D LUT_WIDTH=4; opt_expr; opt_clean"
    # Arrays of a few registers that slang turns into memories with one write port per element
    # (e.g. one read register per bank in a generate loop) become flip-flops first. Otherwise
    # memory_dff finds no register behind the large memory they read from, and that memory goes
    # into LUT RAM instead of block RAM.
    echo "memory_collect; memory_map t:\\\$mem_v2 r:SIZE<=8 %i r:WR_PORTS>=2 %i"
    echo "alumacc; opt; memory -nomap; opt_clean"
    # Read-during-write between different ports is undefined, as with Gowin. Else memory_libmap
    # builds logic around a block RAM to deliver the old data.
    echo "memory_unpack; write_rtlil $out/unpacked.il"
    echo "exec -- python3 $ROOT/scripts/oss/rw_collision.py $out/unpacked.il $out/rw_collision.ys"
    echo "script $out/rw_collision.ys; memory_collect"
    echo "tee -q -o $out/mems_dump.txt dump t:\$mem_v2"
    # Gowin's syn_ramstyle values in Yosys' words
    echo "setattr -set syn_ramstyle \"distributed\" a:syn_ramstyle=distributed_ram"
    echo "setattr -set syn_ramstyle \"block\" a:syn_ramstyle=block_ram"
    for m in $RAM_BLOCK; do
        echo "setattr -set ram_style \"block\" $top/c:$m"
    done
    for m in $RAM_LOGIC; do
        echo "setattr -set ram_style \"logic\" $top/c:$m"
    done
    # -nowidelut: with the wide-LUT muxes ABC9 builds more LUT4 and the muxes on top
    echo "synth_gowin -family gw2a -top $top -run map_ram:map_gates"
    # A short ALU chain takes more room than the same arithmetic in LUTs
    if [ "$ALU_LUT" -gt 2 ]; then
        echo "techmap -map +/techmap.v t:\\\$alu r:Y_WIDTH<=$ALU_LUT %i"
    fi
    # LUT mapping: ABC9 with the flip-flops in view merges equal ones, fewer LUTs and flip-flops.
    # LUTMAP replaces it for experiments, e.g. LUTMAP="abc9 -maxlut 5 -W 500"; LUTMAP= (empty)
    # takes synth_gowin's own.
    lutmap=${LUTMAP-abc9 -maxlut 4 -dff}
    if [ -n "$lutmap" ]; then
        echo "synth_gowin -family gw2a -top $top -run map_gates:map_luts"
        echo "sort; read_verilog -icells -lib -specify +/abc9_model.v; $lutmap; clean"
        echo "synth_gowin -family gw2a -top $top -run map_cells:"
    else
        echo "synth_gowin -family gw2a -top $top -run map_gates: -nowidelut"
    fi
    # Yosys 0.69 leaves \$buf cells, which nextpnr cannot place
    echo "techmap t:\$buf"
    echo "opt_clean"
    echo "write_json $out/$core.json"
    echo "tee -q -o $out/stat.txt stat"
} > "$out/synth.ys"
}
write_synth
echo "== yosys"
yosys -m "${SLANG:-slang}" -q -l "$out/elab.log" -s "$out/elab.ys"
# GHDL drops the defaults of VHDL input ports, an instance that leaves one open would get an
# undriven input (Time Pilot's sound Z80 waited for ever with WAIT_n open). Apply them.
[ -n "$VHDL_TOPS" ] && python3 "$ROOT/scripts/oss/vhdl_port_defaults.py" "$out/elab.il" $VHDL_TOPS -- $vhdl
# ABC writes files into the working directory, e.g. the miter of an equivalence check that runs
# out of time, so synthesis runs in the output folder (synth.ys has absolute paths only)
(cd "$out" && yosys ${YOSYS_FIXES:+-m "$YOSYS_FIXES"} -q -l "$out/yosys.log" -s "$out/synth.ys")
# Yosys leaves block RAMs unused when LUT RAM looks cheaper, Gowin fills them. A second run puts
# the largest memories with clocked reads into the block RAMs that are still free.
if [ "$BLOCK_FILL" = 1 ]; then
    fill=$(python3 "$ROOT/scripts/oss/block_fill.py" "$out/mems_dump.txt" "$out/yosys.log" "$out/$core.json")
    echo "$fill" | tr ' ' '\n' > "$out/block_fill.txt"
    if [ -n "$fill" ]; then
        echo "== yosys, again with $(echo $fill | wc -w | tr -d ' ') more memories in block RAM"
        RAM_BLOCK="$RAM_BLOCK $fill"
        write_synth
        (cd "$out" && yosys ${YOSYS_FIXES:+-m "$YOSYS_FIXES"} -q -l "$out/yosys.log" -s "$out/synth.ys")
    fi
fi
python3 "$ROOT/scripts/oss/mems_table.py" "$out/mems_dump.txt" > "$out/mems.txt"
[ -n "${SYNTH_ONLY:-}" ] && { echo "$out/stat.txt"; exit 0; }

# nextpnr reads only the clock definitions of the Gowin SDC, not the pad clock with its waveform,
# the I/O delays or the clock groups
grep '^create_clock' "$sdc" | grep -v clk_sdram_pad > "$out/clocks.sdc"
echo "== nextpnr"
${NEXTPNR:-nextpnr-himbaechel} --json "$out/$core.json" --write "$out/${core}_pnr.json" \
    --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C --vopt cst="$cst" --vopt sspi_as_gpio \
    --sdc "$out/clocks.sdc" --timing-allow-fail ${SEED:+--seed $SEED} --report "$out/report.json" -l "$out/nextpnr.log" -q
python3 "$ROOT/scripts/oss/check_fmax.py" "$out/report.json" || true
# nextpnr only warns about hold violations. On the board such a build fails now and then, so
# it stops here. Another SEED in the core's oss.conf usually places around them.
if grep -q "Hold/min time violation for" "$out/nextpnr.log"; then
    grep -A4 "Hold/min time violation for" "$out/nextpnr.log" | grep -E "violation for|Sink" >&2
    echo "nextpnr reports hold violations, see $out/nextpnr.log" >&2
    exit 1
fi
python3 "$ROOT/scripts/oss/check_unrouted.py" "$out/${core}_pnr.json" || exit 1
PYTHONPATH=${APICULA:-} "$suite/bin/tabbypy3" "$ROOT/scripts/oss/check_clock_gates.py" "$out/${core}_pnr.json" 2> >(grep -vE "UserWarning|warnings.warn" >&2) || exit 1

# The Companion's SPI pins share configuration pins: Gowin's -use_sspi_as_gpio and
# -use_mspi_as_gpio. The core switch target comes from build.tcl. gowin_pack_g20k.py is Apicula's
# gowin_pack with bank 4 at 3.3 V and ELVDS on the HDMI pins, see its head.
echo "== gowin_pack"
PYTHONPATH=${APICULA:-} "$suite/bin/tabbypy3" "$ROOT/scripts/oss/gowin_pack_g20k.py" -d GW2A-18C --sspi_as_gpio --mspi_as_gpio ${mb:+--multiboot_address 0x$mb} \
    -o "$out/$core.fs" "$out/${core}_pnr.json" 2> >(grep -vE "UserWarning|warnings.warn" >&2)
# the .fs as bytes for the release image
python3 "$ROOT/scripts/oss/fs2bin.py" "$out/$core.fs" "$out/$core.bin"
# the tools of this build in one line, for the NOTICE: the suite's dates (scripts/oss/fetch_suite.sh)
# and the commits of the forks, or the suite's own tool where none is set
rev() { [ -n "$1" ] && git -C "$1" rev-parse --short=12 HEAD 2>/dev/null || echo "of the suite"; }
date_of() { cut -d- -f1 "$1/.suite-date" 2>/dev/null || echo "unknown"; }
echo "$(yosys -V | cut -d' ' -f1-2)${YOSYS_FIXES:+ with the game20k fixes of write_xaiger and submod}" \
    "and GHDL from YosysHQ's oss-cad-suite $(date_of "$suite")" \
    "(GHDL $(date_of "$ghdl_suite")), yosys-slang $(rev "${SLANG:+$(dirname "$(dirname "$SLANG")")}")," \
    "nextpnr-himbaechel $(rev "${NEXTPNR:+$(dirname "$(dirname "$NEXTPNR")")}")" \
    "and Apicula $(rev "${APICULA:-}")" > "$out/tools.txt"
echo "$out/$core.fs"
