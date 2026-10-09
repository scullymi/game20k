# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# 1942, Vulgus and Higemaru with HDMI. Invocation: scripts/build_fpga.sh g1942_hdmi
#
# The platform (HDMI, SDRAM, Companion, RAM mirror) comes from ../common, see
# ../common/files.tcl. This folder holds the game: the wrapper game_core, the package
# game_pkg, the menu and the ROM manifests. Third-party HDL comes from ../vendor, each folder
# with a README.md on where it comes from, at which commit, and what game20k changed:
#   ../vendor/jtcores/  jt1942 and the parts of JTFRAME it uses (jotego, GPL-3.0-or-later; the
#                       T80 inside JTFRAME by Daniel Wallner, BSD-style)
#   ../vendor/jt49/     two AY-3-8910 (jotego, GPL-3.0-or-later), unchanged
# Of the diagnostic variants of the other games (ROMVIEW, RAMDIAG, SDRAMTEST, FB*) only
# RATEPROBE is offered here, see below.
set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C

# jotego's global macros first: Gowin compiles all files as one unit, so the defines of
# this file reach every later one (JTFRAME passes them as tool options instead)
add_file src/jt1942_defs.v

# jotego's sources in dependency order (VHDL: the T80 parts before the T80)
set jt ../vendor/jtcores
set fw $jt/modules/jtframe/hdl
foreach f {ram/jtframe_prom.v ram/jtframe_ram.v} { add_file $fw/$f }
foreach f {T80_ALU T80_MCode T80_Reg T80 T80s} { add_file $fw/cpu/t80/$f.vhd }
foreach f {ram/jtframe_dual_ram.v ram/jtframe_dual_nvram.v cpu/jtframe_z80wait.v cpu/jtframe_z80.v} { add_file $fw/$f }
add_file $jt/cores/1942/hdl/jt1942_main.v
foreach f {jt49_cen jt49_div jt49_eg jt49_exp jt49_noise jt49 jt49_bus} { add_file ../vendor/jt49/hdl/$f.v }
add_file $jt/cores/1942/hdl/jt1942_sound.v
foreach f {jtframe_sh.v video/jtframe_blank.v} { add_file $fw/$f }
foreach f {jt1942_colmix jt1942_objdraw jt1942_objram jt1942_objtiming} { add_file $jt/cores/1942/hdl/$f.v }
add_file $jt/cores/gng/hdl/jtgng_objpxl.v
add_file $jt/cores/1942/hdl/jt1942_obj.v
add_file $fw/video/tilemap/jtframe_tilemap.v
foreach f {jtgng_tile3 jtgng_tile4 jtgng_tilemap jtgng_scroll jtgng_timer} { add_file $jt/cores/gng/hdl/$f.v }
add_file $jt/cores/1942/hdl/jt1942_video.v
add_file $jt/cores/1942/hdl/jt1942_game.v
foreach f {jtframe_bcd_cnt.v clocking/jtframe_freqinfo.v clocking/jtframe_gated_cen.v ram/jtframe_dual_ram16.v} { add_file $fw/$f }

add_file src/g1942_mirror.sv
add_file src/game_pkg.sv
add_file src/game_core.sv

# The ROM layout for rom_loader and the screen, from the manifests: Vulgus and Higemaru have
# 1942's sections plus the header section id, 1942.rom is the shorter file
file mkdir gen
if {[catch {exec python3 ../../scripts/make_rom.py --package vulgus.manifest gen/rom_map_pkg.sv 1942.manifest higemaru.manifest} msg]} {
    error "rom_map_pkg.sv: $msg"
}
add_file gen/rom_map_pkg.sv

source ../common/files.tcl
# RATEPROBE=1: the rate probe of the top (HDMI free running with 816 lines, 57.44 Hz), to check
# whether a monitor or capture card takes Pang's rate. The search string must match
# ../common/src/game20k_top.sv verbatim and occur once.
if {[info exists ::env(RATEPROBE)]} {
    set fin [open $top_src r]; set src [read $fin]; close $fin
    set from "parameter bit RATEPROBE = 0"
    if {[llength [regexp -all -inline -- $from $src]] != 1} {
        error "$top_src: \"$from\" not found exactly once"
    }
    set fout [open gen/game20k_top_gen.sv w]
    puts $fout [string map [list $from "parameter bit RATEPROBE = 1"] $src]; close $fout
    add_file gen/game20k_top_gen.sv
    puts "build.tcl: RATEPROBE build"
} else {
    add_file $top_src
}

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name g1942_hdmi
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module game20k_top
# 1942.vh and jtframe_game_ports.inc live next to the sources that include them,
# mem_ports.inc (the game's port list, ours) in src/inc
set_option -include_path "src/inc;$fw/inc;$jt/cores/1942/hdl"
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -bit_compress 1
set_option -place_option 1

run all
