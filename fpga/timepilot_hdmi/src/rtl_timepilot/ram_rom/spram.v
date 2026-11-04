// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file spram.v
//! @brief Single-port RAM of the Time Pilot core (game20k), in place of the repository's spram.vhd.
//!
//! Verilog, because the core instantiates it with several widths and GHDL elaborates a VHDL
//! entity with one set of generics only. A write shows the new data on q, as spram.vhd did.
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
