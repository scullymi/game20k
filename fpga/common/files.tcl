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
add_file $common/src/rom_sdram.sv
add_file $common/src/rom_slots.sv
add_file $common/src/sdram_share.sv
add_file $common/src/input_test_bar.sv
add_file $common/src/ra_overlay.sv
add_file $common/src/screen_sel.sv
add_file $common/src/audio_cdc.sv

# The interface tag: make_menu.py fills menu/base.xml with the game's menu_core.xml, checks
# the menu and writes gen/iface_pkg.sv with IFACE_TAG, which ram_spi sends in the RAM mirror
# header. The menu itself lives in the Companion's firmware, which takes it only for this tag.
if {[catch {exec python3 ../../scripts/make_menu.py [file tail [pwd]]} msg]} {
    error $msg
}
puts $msg
add_file gen/iface_pkg.sv

# The top. The diagnostic parameters are set by rewriting its parameter lines, see the
# game's build.tcl: it decides whether the original or a rewritten copy is added.
set top_src $common/src/game20k_top.sv

# The core switch: the bitstream header names the next core in slots.txt, the one the
# FPGA loads when the top pulls RECONFIG_N. The project folder is the core's name.
set core [file tail [pwd]]
set ring {}
set fin [open $common/slots.txt r]
foreach line [split [read $fin] "\n"] {
    # comments and empty lines carry no slot
    if {[regexp {^\s*(#|$)} $line]} continue
    if {![regexp {^\s*(\S+)\s+0x([0-9A-Fa-f]{6})\s*$} $line -> name addr]} {
        close $fin
        error "slots.txt: cannot read \"$line\""
    }
    lappend ring $name $addr
}
close $fin
set at [lsearch -exact $ring $core]
if {$at < 0 || $at % 2 != 0} {
    error "slots.txt: $core has no slot"
}
set next [expr {($at + 2) % [llength $ring]}]
set_option -multi_boot 1
set_option -multiboot_spi_flash_address [lindex $ring [expr {$next + 1}]]
puts "files.tcl: $core in the flash at 0x[lindex $ring [expr {$at + 1}]], the core switch loads [lindex $ring $next]"
# 25 MHz from the flash instead of the default 2.5 MHz: a full bitstream loads in 0.3 s
# instead of 2.9 s (UG290 table 3-3). The board's flash delivered 25 MHz in the TP1 test
# of 01.10.2026.
set_option -loading_rate 25.000

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
# The period of clk_core comes from the game's CORE_HZ (src/game_pkg.sv), so the clock is
# named in one place only. board.sdc carries the 18.5625 MHz line as the default.
set fin [open src/game_pkg.sv r]; set pkg [read $fin]; close $fin
if {![regexp {localparam int CORE_HZ = ([0-9_]+);} $pkg -> core_hz]} {
    error "src/game_pkg.sv: CORE_HZ not found"
}
set core_period [format %.3f [expr {1e9 / [string map {_ {}} $core_hz]}]]
# The scanline counter of the top counts HDMI lines modulo 3 from cy 0, the 3x picture keeps
# its pattern only when the frame has a multiple of 3 lines (768, 786, 816).
if {![regexp {localparam int FRAME_H = ([0-9_]+);} $pkg -> frame_h]} {
    error "src/game_pkg.sv: FRAME_H not found"
}
if {[string map {_ {}} $frame_h] % 3 != 0} {
    error "src/game_pkg.sv: FRAME_H $frame_h is not a multiple of 3, the scanlines would drift"
}
set clk_line {create_clock -name clk_core  -period 53.872 [get_nets {clk_core}]}
if {[string first $clk_line $sdc] < 0} {
    error "board.sdc: clk_core line not found"
}
set sdc [string map [list $clk_line "create_clock -name clk_core  -period $core_period \[get_nets {clk_core}\]"] $sdc]
puts "files.tcl: clk_core $core_hz Hz, period $core_period ns"
set fout [open gen/board_gen.sdc w]
puts $fout [string map [list $anchor $sdram] $sdc]; close $fout
add_file -type sdc gen/board_gen.sdc
