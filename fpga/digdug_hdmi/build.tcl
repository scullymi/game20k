# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Dig Dug with HDMI. Invocation: scripts/build_fpga.sh digdug_hdmi
#
# The platform (HDMI, SDRAM, Companion, RAM mirror) comes from ../common, see
# ../common/files.tcl. This folder holds the game: MiSTer-X's core in src/rtl_digdug
# (MiSTer-devel/Arcade-DigDug_MiSTer 3022bcc, GPL-3.0, TV80 by Guy Hutchison, MIT-style),
# changed to one clock with enables, the wrapper game_core, the package game_pkg, the RAM
# mirror ram_mirror_n, the menu and the ROM manifest. The custom I/O chips are
# ../common/src/namco (06XX, MB88 with the 51XX and 53XX programs from the ROM file).
set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C

set dd src/rtl_digdug
foreach f {tv80_alu tv80_reg tv80_mcode tv80_core tv80s} { add_file $dd/cpu/$f.v }
foreach f {cpucore dprams wsg DIGDUG_IODEV DIGDUG_SPRITE DIGDUG_VIDEO DIGDUG_CORES FPGA_DIGDUG HVGEN} { add_file $dd/$f.v }
# the 06XX with the real 51XX and 53XX programs on an MB88 of our own
foreach f {mb88_cpu namco_prom2 namco_io} { add_file ../common/src/namco/$f.sv }

add_file src/ram_mirror_n.sv
add_file src/game_pkg.sv
add_file src/game_core.sv

# The ROM layout for rom_loader, from the manifest
file mkdir gen
if {[catch {exec python3 ../../scripts/make_rom.py --package digdug.manifest gen/rom_map_pkg.sv} msg]} {
    error "rom_map_pkg.sv: $msg"
}
add_file gen/rom_map_pkg.sv

source ../common/files.tcl
add_file $top_src

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name digdug_hdmi
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module game20k_top
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -bit_compress 1
set_option -place_option 1

run all
