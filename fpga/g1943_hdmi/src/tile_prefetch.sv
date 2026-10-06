// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! @file tile_prefetch.sv
//! @brief Prefetch for one scroll layer of 1943 on two rom_slots slots.
//!
//! jtgng_tile4 (LAYOUT 0) sets a new word address every 8 pixels and samples the data 4
//! pixels later, with no ok: about 25 core clocks, too short now and then for a read that
//! queues behind the other layer's. Its word address, here
//! with the byte address bits [21:2], is {tile, column, row}: bits [6:2] the row in the 32x32
//! tile (SV), [8:7] the 8-pixel column (HS[4:3], counted down for a flipped tile), [21:9] the
//! tile; bit 1 (outside the word) picks the half word. Within a tile and a line the
//! next word is the same address with the column one step on, so it can be read 8 pixels
//! early. At the edge of a tile the next one is not known yet.
//!
//! Two slots take turns: one holds the word the layer reads now (cur), the other reads the
//! predicted next word. When the layer moves to the predicted address, the slots swap roles,
//! so the word is there already. Otherwise the current slot reads the new address at once.
//! The direction is the last one seen inside a tile.
module tile_prefetch (
    input  wire              clk,
    input  wire              cs,        //!< the layer reads (LVBL)
    input  wire  [21:2]      addr,      //!< the layer's word address now
    output logic [1:0][21:2] s_addr,    //!< to the two slots
    output logic [1:0]       s_cs,
    output logic             cur        //!< the slot that holds addr
);
    function automatic logic ok_next(input logic [21:2] a, input logic down);
        return down ? a[8:7] != 2'd0 : a[8:7] != 2'd3;
    endfunction
    function automatic logic [21:2] next(input logic [21:2] a, input logic down);
        return {a[21:9], down ? a[8:7] - 2'd1 : a[8:7] + 2'd1, a[6:2]};
    endfunction

    logic [21:2] addr_q = '0;
    logic        cur_q  = 1'b0;
    logic        down_q = 1'b0;

    // a step inside the same tile and row tells the direction
    wire same  = addr[21:9] == addr_q[21:9] && addr[6:2] == addr_q[6:2];
    wire up1   = same && addr[8:7] == addr_q[8:7] + 2'd1;
    wire dn1   = same && addr[8:7] == addr_q[8:7] - 2'd1;
    wire down  = dn1 ? 1'b1 : up1 ? 1'b0 : down_q;

    // the layer reached the word the other slot was fetching
    wire took  = addr != addr_q && ok_next(addr_q, down_q) && addr == next(addr_q, down_q);
    assign cur = took ? ~cur_q : cur_q;

    wire [21:2] pre    = next(addr, down);
    wire        pre_cs = cs && ok_next(addr, down);
    assign s_addr[0] = cur ? pre    : addr;
    assign s_addr[1] = cur ? addr   : pre;
    assign s_cs[0]   = cur ? pre_cs : cs;
    assign s_cs[1]   = cur ? cs     : pre_cs;

    always_ff @(posedge clk) begin
        addr_q <= addr;
        cur_q  <= cur;
        down_q <= down;
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
