# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Galaga with HDMI. Invocation: scripts/build_fpga.sh galaga_hdmi
#
# Diagnostic variants via environment variables:
#   ROMVIEW=1    character ROM instead of the game picture
#   SDRAMTEST=2  SDRAM self-test with CAS latency 2   (sdram_selftest)
#   SDRAMTEST=3  SDRAM self-test with CAS latency 3   (sdram_selftest, sets SDRAMCL3 too)
#   FBTEST=1     write path plus cross-check          (fb_check reads every frame back)
#   FBSHOW=1     picture from the SDRAM, not rotated  (fb_read_flat, always shown)
#   FBROT=1      picture from the SDRAM, ROTATED 2x   (fb_read_rotated, always shown)
#   RAMDIAG=1    measure write accesses to the game RAM (src/ram_diag.sv)
#   NOTESTBAR=1  omit the input test bar (saves 1 BSRAM, only if it does not fit otherwise)
# The platform (HDMI, SDRAM, Companion, RAM mirror) comes from ../common, see
# ../common/files.tcl. This folder holds the game: Dar's core, the wrapper game_core, the
# package game_pkg, the menu and the ROM manifest. Third-party HDL, copied into src/ with
# its original headers, with a README.md on where it comes from, at which commit, and what
# game20k changed:
#   src/rtl_T80/   Z80 core by Daniel Wallner, unchanged
#   src/rtl_dar/   Dar's Galaga core, changed, plus two files of ours derived from gen_ram.vhd
set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C

foreach f {T80 T80_ALU T80_MCode T80_Pack T80_Reg T80se} { add_file src/rtl_T80/$f.vhd }
foreach f {galaga gen_ram gen_ram_dist gen_video mb88 prom_ram sound_machine stars stars_machine} { add_file src/rtl_dar/$f.vhd }
# All eleven ROMs are loaded from SD card at run time (rom_loader), so there are no PROM files
add_file src/game_pkg.sv
add_file src/game_core.sv
add_file src/ram_diag.sv

# The ROM layout for rom_loader, from the manifest. python3 is needed for the report anyway.
file mkdir gen
if {[catch {exec python3 ../../scripts/make_rom.py --package galaga.manifest gen/rom_map_pkg.sv} msg]} {
    error "rom_map_pkg.sv: $msg"
}
add_file gen/rom_map_pkg.sv

source ../common/files.tcl

if {[info exists ::env(ROMVIEW)] || [info exists ::env(SDRAMTEST)] || [info exists ::env(FBTEST)] || [info exists ::env(FBSHOW)] || [info exists ::env(FBROT)] || [info exists ::env(RAMDIAG)] || [info exists ::env(NOTESTBAR)]} {
    # Generate the top level with the parameters set. The search strings include the
    # alignment of the equals signs. They must match ../common/src/game20k_top.sv
    # verbatim.
    set fin [open $top_src r]; set src [read $fin]; close $fin
    set map {}
    if {[info exists ::env(ROMVIEW)]} {
        lappend map "parameter bit ROMVIEW   = 0" "parameter bit ROMVIEW   = 1"
    }
    if {[info exists ::env(SDRAMTEST)]} {
        lappend map "parameter bit SDRAMTEST = 0" "parameter bit SDRAMTEST = 1"
        if {$::env(SDRAMTEST) == 3} {
            lappend map "parameter bit SDRAMCL3  = 0" "parameter bit SDRAMCL3  = 1"
        }
    }
    if {[info exists ::env(FBTEST)]} {
        lappend map "parameter bit FBTEST    = 0" "parameter bit FBTEST    = 1"
    }
    if {[info exists ::env(FBSHOW)]} {
        lappend map "parameter bit FBSHOW    = 0" "parameter bit FBSHOW    = 1"
    }
    if {[info exists ::env(FBROT)]} {
        lappend map "parameter bit FBROT     = 0" "parameter bit FBROT     = 1"
    }
    if {[info exists ::env(RAMDIAG)]} {
        lappend map "parameter bit RAMDIAG   = 0" "parameter bit RAMDIAG   = 1"
    }
    # The input test bar deliberately STAYS IN the measurement build: what gets measured
    # should be a netlist as close as possible to the normal build. Measured, it fits this
    # way (BSRAM 42/46, CLS 82 percent). Only if it does not fit: NOTESTBAR=1. It also works
    # on its own, for the game without the test bar.
    if {[info exists ::env(NOTESTBAR)]} {
        lappend map "parameter bit TESTBAR   = 1" "parameter bit TESTBAR   = 0"
    }
    # string map skips a search string that is not there without a word, and the build
    # would then carry the default. Each one must occur exactly once.
    foreach {from to} $map {
        set n 0
        for {set i [string first $from $src]} {$i >= 0} {set i [string first $from $src [expr {$i + 1}]]} {
            incr n
        }
        if {$n != 1} {
            error "$top_src: \"$from\" found $n times, expected once"
        }
    }
    puts "build.tcl: [expr {[llength $map] / 2}] of [expr {[llength $map] / 2}] parameter substitutions matched"
    set fout [open gen/game20k_top_gen.sv w]
    puts $fout [string map $map $src]; close $fout
    add_file gen/game20k_top_gen.sv
} else {
    add_file $top_src
}

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name galaga_hdmi
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module game20k_top
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -bit_compress 1
# Placement option 1, measured with the CMD24 retry in sd_rw.v: the default placement puts
# the pixel clock at 73.6 MHz (one path 0.12 ns short of the 74.25 MHz), option 1 at 74.4 MHz.
# Same sources, different placement. Check with scripts/fpga_report.sh.
set_option -place_option 1

run all
