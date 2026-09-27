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
#   RAMDIAG=1    measure write accesses to the game RAM (ram_diag)
#   NOTESTBAR=1  omit the input test bar (saves 1 BSRAM, only if it does not fit otherwise)
# Third-party HDL, copied into src/ with its original headers. Where it comes from, at which
# commit, and what game20k changed: the README.md in the first three folders, the LICENSE in
# src/hdmi/, and THIRD-PARTY.md.
#   src/rtl_T80/   Z80 core by Daniel Wallner, unchanged
#   src/rtl_dar/   Dar's Galaga core, changed, plus two files of ours derived from gen_ram.vhd
#   src/misc/      Till Harbaum's MiSTeryNano and Nanomig files for SPI, HID, OSD and SD card
#   src/hdmi/      hdl-util/hdmi, MIT
set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C

foreach f {T80 T80_ALU T80_MCode T80_Pack T80_Reg T80se} { add_file src/rtl_T80/$f.vhd }
foreach f {galaga gen_ram gen_ram_dist gen_video mb88 prom_ram sound_machine stars stars_machine} { add_file src/rtl_dar/$f.vhd }
# All eleven ROMs are loaded from SD card at run time (rom_loader), so there are no PROM files
foreach f {audio_clock_regeneration_packet audio_info_frame audio_sample_packet auxiliary_video_information_info_frame hdmi packet_assembler packet_picker serializer source_product_description_info_frame tmds_channel} { add_file src/hdmi/$f.sv }
add_file src/pll_hdmi.v
add_file src/pll_sdram.v
add_file src/mcu/ram_mirror_pkg.sv
# The SDRAM frame buffer. The normal build instantiates sdram_fb, fb_pack and
# fb_read_rotated (branch g_fb_live in the top). sdram_selftest, fb_check, fb_read_flat and
# ram_diag are compiled every time but only instantiated by the measurement builds below.
# A module that is not instantiated costs nothing and stays syntactically alive this way.
add_file src/sdram_fb.v
add_file src/sdram_selftest.sv
add_file src/fb_pack.sv
add_file src/fb_check.sv
add_file src/fb_read_flat.sv
add_file src/fb_read_rotated.sv
add_file src/ram_diag.sv
add_file src/clkdiv5.v
add_file src/galaga_scaler.sv
add_file src/misc/mcu_spi.v
add_file src/mcu/ram_spi.sv
add_file src/mcu/snap_fifo.sv
add_file src/mcu/snap_log.sv
add_file src/misc/hid.v
add_file src/misc/osd_u8g2.v
add_file src/misc/sysctrl_galaga.v
add_file src/mcu/menu_rom.v
add_file src/mcu/sector_dpram.v
add_file src/misc/sdcmd_ctrl.v
add_file src/misc/sd_rw.v
add_file src/misc/sd_card.v
add_file src/mcu/rom_loader.sv
add_file src/input_test_bar.sv
add_file src/ra_overlay.sv

if {[info exists ::env(ROMVIEW)] || [info exists ::env(SDRAMTEST)] || [info exists ::env(FBTEST)] || [info exists ::env(FBSHOW)] || [info exists ::env(FBROT)] || [info exists ::env(RAMDIAG)]} {
    # Generate the top level with the parameters set. The search strings include the
    # alignment of the equals signs. They must match src/galaga_hdmi_top.sv
    # verbatim.
    set fin [open src/galaga_hdmi_top.sv r]; set src [read $fin]; close $fin
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
    # way (BSRAM 42/46, CLS 82 percent). Only if it does not fit: NOTESTBAR=1.
    if {[info exists ::env(NOTESTBAR)]} {
        lappend map "parameter bit TESTBAR   = 1" "parameter bit TESTBAR   = 0"
    }
    file mkdir gen
    set fout [open gen/galaga_hdmi_top_gen.sv w]
    puts $fout [string map $map $src]; close $fout
    add_file gen/galaga_hdmi_top_gen.sv
} else {
    add_file src/galaga_hdmi_top.sv
}
add_file -type cst galaga_hdmi.cst

# The description of the SDRAM path belongs in EVERY build: the data pin is read in normal
# operation too (fb_read_rotated fetches the picture data back). It is kept in a file of its
# own because set_input_delay on a pad that is never read is a hard error, so a build that
# never reads the pad has to leave it out. A second SDC file does not see the clocks of the
# first (measured: "Cannot get clock with name 'clk_sdram'"), so one single file is assembled.
set fin [open galaga_hdmi.sdc r];       set sdc   [read $fin]; close $fin
set fin [open galaga_hdmi_sdram.sdc r]; set sdram [read $fin]; close $fin
set anchor {set_clock_groups -asynchronous -group [get_clocks {clk_sdram}]}
if {[string first $anchor $sdc] < 0} {
    error "galaga_hdmi.sdc: insertion anchor not found"
}
file mkdir gen
set fout [open gen/galaga_hdmi_gen.sdc w]
puts $fout [string map [list $anchor $sdram] $sdc]; close $fout
add_file -type sdc gen/galaga_hdmi_gen.sdc

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name galaga_hdmi
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module galaga_hdmi_top
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -bit_compress 1
# Placement option 1, measured with the CMD24 retry in sd_rw.v: the default placement puts
# the pixel clock at 73.6 MHz (one path 0.12 ns short of the 74.25 MHz), option 1 at 74.4 MHz.
# Same sources, different placement. Check with scripts/fpga_report.sh.
set_option -place_option 1

run all
