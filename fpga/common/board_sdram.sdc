// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// Timing constraints of the SDRAM path. This file is an insert piece: build.tcl splices
// it into galaga_hdmi.sdc in every build in place of the line
//   set_clock_groups -asynchronous -group [get_clocks {clk_sdram}]
// and writes the result to gen/galaga_hdmi_gen.sdc.
// Why not simply add a second SDC: measured, the second file does not see the clocks of
// the first ("Cannot get clock with name 'clk_sdram'").
// Why every build: the set_input_delay lines below require a design that reads IO_sdram_dq.
// On a pad that is only driven and never read, gowin_sta rejects every set_input_delay
// with a hard error and aborts the run. Here the pad is bidirectional in every build: the
// frame buffer readers (fb_read_flat, fb_read_rotated) fetch the picture back from the
// SDRAM, and the self test (SDRAMTEST) reads it as well.

// Pad clock: O_sdram_clk sits directly on CLKOUTP of the second rPLL, 247.5 degrees = 10.609 ns.
// The generated clock the toolchain derives by itself does NOT help here: as soon as
// DYN_DA_EN is "true", it reports Rise 0.000 instead of 9.645 in the Clock Summary (verified).
// The phase therefore has to be stated as a waveform.
create_clock -name clk_sdram_pad -period 15.432 -waveform {10.609 18.325} [get_ports {O_sdram_clk}]

// tAC 6.0 ns (CL2) and tOH 2.5 ns of a -6 device, without trace length: the SDRAM sits in
// the same package. tIS 2.0 ns and tIH 1.0 ns on the command side.
set_input_delay  -clock [get_clocks {clk_sdram_pad}] -max  6.0 [get_ports {IO_sdram_dq[*]}]
set_input_delay  -clock [get_clocks {clk_sdram_pad}] -min  2.5 [get_ports {IO_sdram_dq[*]}]
set_output_delay -clock [get_clocks {clk_sdram_pad}] -max  2.0 [get_ports {O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n IO_sdram_dq[*]}]
set_output_delay -clock [get_clocks {clk_sdram_pad}] -min -1.0 [get_ports {O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n IO_sdram_dq[*]}]

// BOTH SDRAM clocks in ONE group. Within a group they stay synchronous to each other.
// If the pad clock were in a group of its own, or clk_sdram alone as in the line this
// file replaces, the read path would be defined away.
set_clock_groups -asynchronous -group [get_clocks {clk_sdram clk_sdram_pad}]
