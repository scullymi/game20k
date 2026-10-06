// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! @file map_prefetch.sv
//! @brief Prefetch for the map ROM of one 1943 scroll layer on two rom_slots slots.
//!
//! jt1943_map sets a new map address every 8 pixels, jt1943_map_cache writes the word into
//! its line cache whenever ok is high, and jtgng_tile4 takes the tile code about 15 clocks
//! after the address changed, with no ok. A word that comes later leaves the old cache entry
//! in place: an 8-pixel segment of the wrong tile.
//!
//! The map address, here as the byte address bits [21:2] of a 32-bit word, is {bank, column,
//! row}: bits [4:2] the tile row (SV[7:5]), [14:5] the 64-pixel column ({PIC, SH[7:6]}),
//! [21:15] the map's place in the image. Bit 1 (outside the word) picks the tile of the pair
//! (SH[5]). Along a line, in the blanking and in the cache's refill burst alike, the column
//! steps by one, up or down with the screen flip, so the next word is known 64 pixels early.
//!
//! Two slots take turns as in tile_prefetch.sv: one holds the word at the layer's address
//! (cur), the other reads the predicted next word. When the layer moves to the predicted
//! address, the slots swap roles and the word is there already. Any other move (the start of
//! a line, the refill burst, a new scroll position) makes the current slot read the new
//! address at once. ok comes only from the slot whose tag is the layer's address, so a
//! prefetched word is never delivered for another address.
module map_prefetch (
    input  wire              clk,
    input  wire              cs,        //!< map_cs of the layer
    input  wire  [21:2]      addr,      //!< the layer's map word address now
    output logic [1:0][21:2] s_addr,    //!< to the two slots
    output logic [1:0]       s_cs,
    output logic             cur        //!< the slot that holds addr
);
    // the next column, wrapping like {PIC, SH[7:6]} in jt1943_map
    function automatic logic [21:2] next(input logic [21:2] a, input logic down);
        return {a[21:15], down ? a[14:5] - 10'd1 : a[14:5] + 10'd1, a[4:2]};
    endfunction

    logic [21:2] addr_q = '0;
    logic [21:2] pre_q  = '0;       // the predicted next word, one clock old
    logic        cur_q  = 1'b0;
    logic        down_q = 1'b0;

    // a step by one column in the same row tells the direction
    wire same = addr[21:15] == addr_q[21:15] && addr[4:2] == addr_q[4:2];
    wire up1  = same && addr[14:5] == addr_q[14:5] + 10'd1;
    wire dn1  = same && addr[14:5] == addr_q[14:5] - 10'd1;
    wire down = dn1 ? 1'b1 : up1 ? 1'b0 : down_q;

    // the layer reached the word the other slot was fetching
    wire moved = addr != addr_q;
    wire took  = moved && addr == pre_q;
    assign cur = took ? ~cur_q : cur_q;

    // The prefetch reads whatever the layer does: one word per 64 pixels. Its address is
    // registered for timing, so it waits the clock in which the layer moves.
    assign s_addr[0] = cur ? pre_q  : addr;
    assign s_addr[1] = cur ? addr   : pre_q;
    assign s_cs[0]   = cur ? !moved : cs;
    assign s_cs[1]   = cur ? cs     : !moved;

    always_ff @(posedge clk) begin
        addr_q <= addr;
        pre_q  <= next(addr, down);
        cur_q  <= cur;
        down_q <= down;
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
