// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file dpram_dc.v
//! @brief Verilog twin of src/rtl_timepilot/ram_rom/dpram_dc.vhd for the free toolchain build.
//!
//! GHDL elaborates a VHDL entity with its default generics only, the core instantiates it with
//! several widths. Same behaviour as the VHDL: both ports read on clock_a, a write on port A
//! shows the new data on q_a. Port B and the byte enables are not written (as in the VHDL).
module dpram_dc #(
    parameter init_file     = " ",
    parameter widthad_a     = 8,
    parameter width_a       = 8,
    parameter outdata_reg_a = "UNREGISTERED",
    parameter outdata_reg_b = "UNREGISTERED"
) (
    input  wire [widthad_a-1:0] address_a,
    input  wire [widthad_a-1:0] address_b,
    input  wire                 clock_a,
    input  wire                 clock_b,
    input  wire [width_a-1:0]   data_a,
    input  wire [width_a-1:0]   data_b,
    input  wire                 wren_a,
    input  wire                 wren_b,
    input  wire [width_a/8-1:0] byteena_a,
    input  wire [width_a/8-1:0] byteena_b,
    output reg  [width_a-1:0]   q_a,
    output reg  [width_a-1:0]   q_b
);
    reg [width_a-1:0] mem [0:(1 << widthad_a) - 1];

    always @(posedge clock_a) begin
        if (wren_a) begin
            mem[address_a] <= data_a;
            q_a <= data_a;
        end else
            q_a <= mem[address_a];
        q_b <= mem[address_b];
    end
endmodule
