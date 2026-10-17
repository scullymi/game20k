// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file sdspi_dut.v
//! @brief The Companion's SPI interface and the SD card controller, wired as in game20k_top.sv.
//!
//! The test compares this subsystem as written with what the free toolchain's front end makes
//! of it (run_sim.sh). Only the SD card target is connected, the other targets answer 0.
`default_nettype none
module sdspi_dut (
    input  wire       clk,
    input  wire       rstn,
    input  wire       spi_csn, spi_sck, spi_mosi,
    output wire       spi_miso,
    output wire       sd_clk,
    // Till's simulator ports (VERILATOR in sd_card.v): outputs read 1 when not driving, the
    // inputs come separately. The test bench builds the bus, Icarus aborts on the gate-level
    // tri-state buffers.
    output wire       sd_cmd,
    input  wire       sd_cmd_in,
    output wire [3:0] sd_dat,
    input  wire [3:0] sd_dat_in,
    output wire       sdc_int,
    output wire [7:0] sdc_data_out
);
    wire       mcu_sdc_strobe, mcu_start;
    wire [7:0] mcu_data_out;

    mcu_spi mcu_spi (
        .clk(clk), .reset(!rstn),
        .spi_io_ss(spi_csn), .spi_io_clk(spi_sck), .spi_io_din(spi_mosi), .spi_io_dout(spi_miso),
        .mcu_sys_strobe(), .mcu_hid_strobe(), .mcu_osd_strobe(), .mcu_sdc_strobe(mcu_sdc_strobe),
        .mcu_ram_strobe(), .mcu_start(mcu_start),
        .mcu_sys_din(8'h00), .mcu_hid_din(8'h00), .mcu_osd_din(8'h00), .mcu_sdc_din(sdc_data_out),
        .mcu_ram_din(8'h00), .mcu_dout(mcu_data_out)
    );

`ifndef SDSPI_FAST
`define SDSPI_FAST 0
`endif
    // SDSPI_FAST=1 sets Till's SIMULATE: shorter waits and a faster init clock, same logic. It
    // also shrinks the ROM image FIFO, which the status poll does not use, for the gate run.
    sd_card #(.CLK_DIV(3'd0), .SIMULATE(`SDSPI_FAST), .IMAGE_FIFO_BITS(`SDSPI_FAST ? 1 : 9)) sd_card (
        .rstn(rstn), .clk(clk),
        .sdclk(sd_clk), .sdcmd(sd_cmd), .sdcmd_in(sd_cmd_in), .sddat(sd_dat), .sddat_in(sd_dat_in),
        .data_strobe(mcu_sdc_strobe), .data_start(mcu_start),
        .data_in(mcu_data_out), .data_out(sdc_data_out),
        .image_mounted(), .image_size(),
        .rom_image_selected(), .rom_image_selection_strobe(), .rom_image_accepted(1'b0),
        .rom_image_data_available(), .rom_image_data(), .rom_image_data_strobe(1'b0),
        .irq(sdc_int), .iack(1'b0),
        .rstart(8'h00), .wstart(8'h00), .rsector(32'd0),
        .rsrc(), .rbusy(), .rdone(),
        .inbyte(8'h00), .outen(), .outaddr(), .outbyte()
    );
endmodule
`default_nettype wire
