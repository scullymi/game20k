// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file dpram_dc.v
//! @brief Dual-port RAM of the Time Pilot core (game20k), in place of the repository's Altera
//!        wrapper dpram_dc.vhd.
//!
//! Verilog, because the core instantiates it with several widths and GHDL elaborates a VHDL
//! entity with one set of generics only. Both ports read on clock_a, a write on port A shows the
//! new data on q_a. Port B and the byte enables are not written.
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
