// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
create_clock -name sys_clk   -period 37.037 [get_ports {sys_clk}]
create_clock -name clk_x5    -period 2.6936 [get_nets {clk_x5}]
create_clock -name clk_pixel -period 13.468 [get_nets {clk_pixel}]
create_clock -name clk_core  -period 53.872 [get_nets {clk_core}]
// The 48 kHz audio clock is a slow register in clk_pixel. The HDMI module hands its samples
// to clk_pixel with a toggle handshake. The word it takes at the rising edge of clk_audio
// changes only shortly after the falling edge (audio_cdc.sv), half a period away.
create_generated_clock -name clk_audio -source [get_nets {clk_pixel}] -divide_by 1546 [get_nets {clk_audio}]
set_clock_groups -asynchronous -group [get_clocks {clk_audio}] -group [get_clocks {clk_pixel}]

// SPI clock from the Companion (max. 20 MHz), asynchronous to the core.
// clk_core and clk_pixel come from the same VCO, but through two dividers, CLKOUTD of the
// rPLL and CLKDIV, whose phase to each other is not defined. Timed as related, the closest
// edges would be one VCO period (2.69 ns) apart, at 46.4 against 74.25 MHz (8 and 5 VCO
// periods). So they are asynchronous: single bits cross through two registers, words that
// must arrive whole through a handshake (the audio word in audio_cdc.sv, the OSD byte in the
// top). A set_max_delay on those paths would not help: set_clock_groups takes precedence
// (SUG940, 3.8).
create_clock -name spi_sck -period 50.0 [get_ports {spi_sck}]
set_clock_groups -asynchronous -group [get_clocks {spi_sck}] -group [get_clocks {clk_core}] -group [get_clocks {clk_pixel}]

// SDRAM clock, 64.8 MHz from the second rPLL, asynchronous to everything else. The pad
// clock O_sdram_clk comes straight from CLKOUTP and deliberately gets NO create_clock here:
// its waveform and the read path delays on IO_sdram_dq live in galaga_hdmi_sdram.sdc, since
// gowin_sta aborts the run with a hard error on a set_input_delay for a pad that is never
// read. Every build reads the pad, so build.tcl splices that file in here in every build
// and hands gen/galaga_hdmi_gen.sdc to the tools (a second SDC does not see the clocks of
// the first). The set_clock_groups line below is the anchor and must stay exactly as it is.
create_clock -name clk_sdram -period 15.432 [get_nets {clk_sdram}]
set_clock_groups -asynchronous -group [get_clocks {clk_sdram}]
