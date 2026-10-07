# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Time Pilot with HDMI. Invocation: scripts/build_fpga.sh timepilot_hdmi
#
# The platform (HDMI, SDRAM, Companion, RAM mirror) comes from ../common, see
# ../common/files.tcl. This folder holds the game: Ace's core in src/rtl_timepilot
# (MiSTer-devel/Arcade-TimePilot_MiSTer 5a148e2, MIT; T80 by Daniel Wallner, BSD-style;
# jt49 by jotego, GPL-3.0-or-later), the wrapper game_core, the package game_pkg, the menu
# and the ROM manifest. The RAM mirror tp_mirror.sv is 1942's, sized for 2 KB.
set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C

add_file src/timepilot_defs.v

set tp src/rtl_timepilot
foreach f {T80_Pack T80_ALU T80_MCode T80_Reg T80 T80s} { add_file $tp/cpu/T80/$f.vhd }
add_file $tp/ram_rom/dpram_dc.vhd
add_file $tp/ram_rom/spram.vhd
add_file $tp/ram_rom/rom_loader.sv
add_file $tp/jtframe_frac_cen.v
foreach f {k082 k083 k501 k502 k503 k526 k528} { add_file $tp/custom/$f.sv }
foreach f {jt49_cen jt49_div jt49_eg jt49_exp jt49_noise jt49 jt49_bus} { add_file $tp/sound/jt49/hdl/$f.v }
add_file $tp/sound/jt49/hdl/filter/jt49_dcrm2.v
add_file $tp/sound/tp_lpf_sel.sv
add_file $tp/TimePilot_CPU.sv
add_file $tp/TimePilot_SND.sv
add_file $tp/TimePilot.sv

add_file src/tp_mirror.sv
add_file src/game_pkg.sv
add_file src/game_core.sv

# The ROM layout for rom_loader, from the manifest
file mkdir gen
if {[catch {exec python3 ../../scripts/make_rom.py --package timeplt.manifest gen/rom_map_pkg.sv} msg]} {
    error "rom_map_pkg.sv: $msg"
}
add_file gen/rom_map_pkg.sv

source ../common/files.tcl
add_file $top_src

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name timepilot_hdmi
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module game20k_top
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -bit_compress 1
set_option -place_option 1

run all
