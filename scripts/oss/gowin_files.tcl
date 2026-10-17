# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Runs a game's build.tcl with Gowin's project commands stubbed out and prints what the
# project would contain: one line per file ("hdl|cst|sdc <path>") and the options.
# Usage: cd fpga/<core> && tclsh ../../scripts/oss/gowin_files.tcl
proc set_device {args} { puts "device [lindex $args 0]" }
proc add_file {args} {
    set type hdl
    if {[lindex $args 0] eq "-type"} { set type [lindex $args 1]; set args [lrange $args 2 end] }
    puts "$type [file normalize [lindex $args 0]]"
}
proc set_option {name value} { puts "option $name $value" }
proc run {args} {}
source build.tcl
