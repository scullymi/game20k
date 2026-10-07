// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file namco_prom2.sv
//! @brief Two 1 KB MCU programs in one block RAM, loaded through a write port.
//!
//! Written for game20k. Program A sits in the lower half, B in the upper. One read port
//! serves both halves in turn, one clock each, every result goes through its own output
//! register: data_a and data_b follow their address within three clocks. That suits the
//! Namco MCUs, which fetch one byte per machine cycle of many clocks.
module namco_prom2 (
    input  wire         clk,
    input  wire  [9:0]  addr_a,
    output logic [7:0]  data_a,
    input  wire  [9:0]  addr_b,
    output logic [7:0]  data_b,
    input  wire         wr_en,      //!< load side: program A at 0x000, B at 0x400
    input  wire  [10:0] wr_addr,
    input  wire  [7:0]  wr_data
);
    logic [7:0] mcu_prog [0:2047];
    logic       sel = 1'b0;         // half the read port serves in this clock
    logic       q_sel = 1'b0;
    logic [7:0] q = '0;

    always_ff @(posedge clk) if (wr_en) mcu_prog[wr_addr] <= wr_data;

    always_ff @(posedge clk) begin
        sel   <= !sel;
        q     <= mcu_prog[{sel, sel ? addr_b : addr_a}];
        q_sel <= sel;
        if (q_sel) data_b <= q;
        else       data_a <= q;
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
