// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file spram.v
//! @brief Verilog twin of src/rtl_timepilot/ram_rom/spram.vhd for the free toolchain build.
//!
//! GHDL elaborates a VHDL entity with its default generics only, the core instantiates it with
//! several widths. Same behaviour as the VHDL: a write shows the new data on q.
module spram #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 10
) (
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] addr,
    input  wire [DATA_WIDTH-1:0] data,
    output reg  [DATA_WIDTH-1:0] q,
    input  wire                  we
);
    reg [DATA_WIDTH-1:0] ram [0:(1 << ADDR_WIDTH) - 1];

    always @(posedge clk) begin
        if (we) begin
            ram[addr] <= data;
            q <= data;
        end else
            q <= ram[addr];
    end
endmodule
