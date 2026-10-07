# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Pang and Super Pang with HDMI. Invocation: scripts/build_fpga.sh pang_hdmi
#
# The platform (HDMI, SDRAM, Companion, RAM mirror) comes from ../common, see
# ../common/files.tcl. This folder holds the game: jotego's core, the wrapper game_core, the
# package game_pkg, the menu and the ROM manifests. Third-party HDL, copied into src/ with its
# original headers and the upstream folder layout, each folder with a README.md on where it
# comes from, at which commit, and what game20k changed:
#   src/jtcores/   jtpang and the parts of JTFRAME it uses (jotego, GPL-3.0-or-later; the T80
#                  inside JTFRAME by Daniel Wallner, BSD-style)
#   src/jtopl/     the YM2413 (jotego, GPL-3.0-or-later)
#   src/jt6295/    the OKI M6295 (jotego, GPL-3.0-or-later)
#   src/jteeprom/  the 93C46 EEPROM (jotego, GPL-3.0-or-later)
set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C

# the global macros first: Gowin compiles all files as one unit
add_file src/jtpang_defs.v

set jt src/jtcores
set fw $jt/modules/jtframe/hdl
foreach f {T80_ALU T80_MCode T80_Reg T80 T80s} { add_file $fw/cpu/t80/$f.vhd }
foreach f {ram/jtframe_dual_ram.v ram/jtframe_dual_nvram.v ram/jtframe_obj_buffer.v cpu/jtframe_z80wait.v cpu/jtframe_z80.v} { add_file $fw/$f }
foreach f {jtframe_sh.v jtframe_bcd_cnt.v clocking/jtframe_freqinfo.v clocking/jtframe_gated_cen.v} { add_file $fw/$f }
foreach f {jtframe_vtimer jtframe_draw jtframe_objdraw_gate jtframe_objdraw} { add_file $fw/video/$f.v }
foreach f [lsort [glob src/jtopl/hdl/jtopl_*.v src/jtopl/hdl/jtopll_*.v]] { add_file $f }
add_file src/jtopl/hdl/jt2413.v
foreach f {jt12_comb jt12_interpol jt6295_sh_rst jt6295_timing jt6295_rom jt6295_ctrl jt6295_serial jt6295_adpcm jt6295_acc jt6295} { add_file src/jt6295/hdl/$f.v }
foreach f {jt9346 jt9346_16b8b} { add_file src/jteeprom/hdl/$f.v }
foreach f {jtpang_main jtpang_snd jtpang_char jtpang_obj jtpang_colmix jtpang_video} { add_file $jt/cores/pang/hdl/$f.v }

add_file src/gpang_mirror.sv
add_file src/game_pkg.sv
add_file src/game_core.sv

# The ROM layout for rom_loader and the screen, from the manifests: both games have one layout
# and one size, the header section tells them apart
file mkdir gen
if {[catch {exec python3 ../../scripts/make_rom.py --package pang.manifest gen/rom_map_pkg.sv spang.manifest} msg]} {
    error "rom_map_pkg.sv: $msg"
}
add_file gen/rom_map_pkg.sv

source ../common/files.tcl
add_file $top_src

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name pang_hdmi
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module game20k_top
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -bit_compress 1
set_option -place_option 1

run all
