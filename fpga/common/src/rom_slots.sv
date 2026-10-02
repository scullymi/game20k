// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! @file rom_slots.sv
//! @brief Several ROM buses of a game on one SDRAM read port (game20k).
//!
//! jotego's cores read their SDRAM ROMs through slots: per bus an address, a chip select
//! and an ok that is high while the data belongs to the address (JTFRAME's jtframe_romrq).
//! This module gives a game N such slots on the single word read port of rom_sdram.sv.
//!
//! Every slot keeps the last word it read (tag and data). ok is formed combinationally from
//! that, so it is low in the very clock the address changes, as the cores expect. A slot
//! whose chip select is high and whose word is not held asks for it. One read is out at a
//! time; when the port is free, the lowest numbered slot that asks gets it. Slot 0 thus has
//! priority: the game puts the bus with the tightest deadline there (1942: the sprites,
//! which must be drawn within one line).
//!
//! The port is 32 bits wide, the buses are 8, 16 or 32: slot_data is the whole word, the
//! game picks its byte or half word with the low address bits. A bus that reads its bytes
//! one after the other (a CPU fetching code, the sprite engine reading the two halves of a
//! word) so needs one SDRAM read per word instead of one per access.
//!
//! miss counts the clocks a slot with chip select waited, a measure for the SDRAM latency
//! as the game sees it.
module rom_slots #(
    parameter int N  = 5,                   //!< number of slots, 1..8
    parameter int AW = 18                   //!< byte address width of the ROM image
)(
    input  wire                     clk,
    input  wire                     reset,  //!< forgets every held word

    //! ---- the game's buses, word addresses into the ROM image ----
    input  wire  [N-1:0][AW-1:2]    slot_addr,
    input  wire  [N-1:0]            slot_cs,
    output logic [N-1:0]            slot_ok,
    output logic [N-1:0][31:0]      slot_data,

    //! ---- to rom_sdram.sv, its read side ----
    output logic [AW-1:2]           rd_addr,
    output logic                    rd_req,
    input  wire                     rd_ack,
    input  wire  [31:0]             rd_data,

    //! ---- diagnostics ----
    output logic [31:0]             miss    //!< clocks any slot waited, wraps
);
    logic [N-1:0][AW-1:2] tag;
    logic [N-1:0]         valid;
    logic [N-1:0]         hit, want;

    // what each slot holds, and who asks
    always_comb
        for (int i = 0; i < N; i++) begin
            hit[i]       = valid[i] && tag[i] == slot_addr[i];
            slot_ok[i]   = slot_cs[i] && hit[i];
            want[i]      = slot_cs[i] && !hit[i];
        end

    // the lowest numbered slot that asks
    localparam int PW = $clog2(N > 1 ? N : 2);
    logic [PW-1:0] pick;
    always_comb begin
        pick = '0;
        for (int i = N - 1; i >= 0; i--)
            if (want[i]) pick = PW'(i);
    end

    // one read at a time: issue, then wait for the acknowledge and fill the slot
    logic          busy;
    logic [PW-1:0] sel;
    always_ff @(posedge clk) begin
        if (reset) begin
            valid  <= '0;
            busy   <= 1'b0;
            rd_req <= rd_ack;               // nothing pending after reset
        end else if (busy) begin
            if (rd_ack == rd_req) begin
                // the word belongs to the address that was asked for; if the slot has
                // moved on meanwhile, the tag does not match and it asks again
                tag[sel]       <= rd_addr;
                slot_data[sel] <= rd_data;
                valid[sel]     <= 1'b1;
                busy           <= 1'b0;
            end
        end else if (|want) begin
            rd_addr <= slot_addr[pick];
            rd_req  <= ~rd_req;
            sel     <= pick;
            busy    <= 1'b1;
        end
    end

    always_ff @(posedge clk)
        if (reset)      miss <= 32'd0;
        else if (|want) miss <= miss + 32'd1;
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
