# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# The platform: every file under fpga/common that a game's build.tcl adds to its project.
# Sourced from fpga/<core>/build.tcl, so the paths are relative to the game folder. Third-party
# HDL is copied in with its original headers, see the README.md in src/misc, the LICENSE in
# src/hdmi, and THIRD-PARTY.md.
#   src/misc/      Till Harbaum's MiSTeryNano and Nanomig files for SPI, HID, OSD and SD card
#   src/hdmi/      hdl-util/hdmi, MIT
set common ../common

foreach f {audio_clock_regeneration_packet audio_info_frame audio_sample_packet auxiliary_video_information_info_frame hdmi packet_assembler packet_picker serializer source_product_description_info_frame tmds_channel} { add_file $common/src/hdmi/$f.sv }
add_file $common/src/pll_hdmi.v
add_file $common/src/pll_sdram.v
add_file $common/src/mcu/ram_mirror_pkg.sv
# The SDRAM frame buffer. The normal build instantiates sdram_fb, fb_pack and
# fb_read_rotated (branch g_fb_live in the top). sdram_selftest, fb_check and fb_read_flat
# are compiled every time but only instantiated by the measurement builds. A module that is
# not instantiated costs nothing and stays syntactically alive this way.
add_file $common/src/sdram_fb.v
add_file $common/src/sdram_selftest.sv
add_file $common/src/fb_pack.sv
add_file $common/src/fb_check.sv
add_file $common/src/fb_read_flat.sv
add_file $common/src/fb_read_rotated.sv
add_file $common/src/clkdiv5.v
add_file $common/src/arcade_scaler.sv
add_file $common/src/misc/mcu_spi.v
add_file $common/src/mcu/ram_spi.sv
add_file $common/src/mcu/snap_fifo.sv
add_file $common/src/mcu/snap_log.sv
add_file $common/src/misc/hid.v
add_file $common/src/misc/osd_u8g2.v
add_file $common/src/misc/sysctrl.v
add_file $common/src/mcu/sector_dpram.v
add_file $common/src/misc/sdcmd_ctrl.v
add_file $common/src/misc/sd_rw.v
add_file $common/src/misc/sd_card.v
add_file $common/src/mcu/rom_loader.sv
add_file $common/src/input_test_bar.sv
add_file $common/src/ra_overlay.sv

# The menu ROM reads the game's menu_xml.hex relative to its own location (see the file
# head), so it is compiled from a copy in the game's gen/ folder.
file mkdir gen
file copy -force $common/src/mcu/menu_rom.v gen/menu_rom.v
add_file gen/menu_rom.v

# The top. The diagnostic parameters are set by rewriting its parameter lines, see the
# game's build.tcl: it decides whether the original or a rewritten copy is added.
set top_src $common/src/game20k_top.sv

# The board: pins and clocks are the same for every game. The description of the SDRAM
# path belongs in EVERY build: the data pin is read in normal operation too
# (fb_read_rotated fetches the picture data back). It is kept in a file of its own because
# set_input_delay on a pad that is never read is a hard error, so a build that never reads
# the pad has to leave it out. A second SDC file does not see the clocks of the first
# (measured: "Cannot get clock with name 'clk_sdram'"), so one single file is assembled.
add_file -type cst $common/board.cst
set fin [open $common/board.sdc r];       set sdc   [read $fin]; close $fin
set fin [open $common/board_sdram.sdc r]; set sdram [read $fin]; close $fin
set anchor {set_clock_groups -asynchronous -group [get_clocks {clk_sdram}]}
if {[string first $anchor $sdc] < 0} {
    error "board.sdc: insertion anchor not found"
}
set fout [open gen/board_gen.sdc w]
puts $fout [string map [list $anchor $sdram] $sdc]; close $fout
add_file -type sdc gen/board_gen.sdc
