// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! @file rom_slots.sv
//! @brief Several ROM buses of a game on one SDRAM read stream (game20k).
//!
//! jotego's cores read their SDRAM ROMs through slots: per bus an address, a chip select
//! and an ok that is high while the data belongs to the address (JTFRAME's jtframe_romrq).
//! This module gives a game N such slots on the read stream of rom_sdram.sv.
//!
//! Every slot keeps the last word it read (tag and data). ok is formed combinationally from
//! that, so it is low in the very clock the address changes, as the cores expect. A slot
//! whose chip select is high, whose word is not held and which has no read in flight asks
//! for it. Several slots can have a read in flight at the same time, one each: whenever the
//! stream takes a read, the lowest numbered slot that asks gets it. Slot 0 thus has
//! priority: the game puts the bus with the tightest deadline there. The words come back in
//! the order of the reads; a small queue of slot numbers tells whose each one is. If a slot
//! has moved on while its read was out, the word lands under the old address, does not match
//! and the slot asks again.
//!
//! The port is 32 bits wide, the buses are 8, 16 or 32: slot_data is the whole word, the
//! game picks its byte or half word with the low address bits. A bus that reads its bytes
//! one after the other (a CPU fetching code, the sprite engine reading the two halves of a
//! word) so needs one SDRAM read per word instead of one per access.
//!
//! Words come back in order, so a read with a short deadline waits for every read issued
//! before it. Slots from HI on (the CPUs, words fetched ahead: buses that wait or have time) may
//! therefore have at most LO_MAX reads in flight together; the rest of the QD places stays
//! free for the slots below HI. With HI = N (default) there is no such limit.
//!
//! slot_hold keeps a slot from starting a new read for as long as it is set, its held word
//! stays valid. A game uses it to keep the stream free just before a bus with a short, known
//! deadline asks (1942: the tile layer, every 8 pixels).
//!
//! reset forgets every held word, in every clock it is high. Reads already in flight still
//! come back and are counted off the queue, their words are dropped while reset is high: a
//! new ROM is loaded only under reset, and a word from before must not survive it.
//!
//! miss counts the clocks a slot with chip select waited, a measure for the SDRAM latency
//! as the game sees it.
module rom_slots #(
    parameter int N  = 5,                   //!< number of slots, 1..16
    parameter int AW = 18,                  //!< byte address width of the ROM image
    parameter int QD = 4,                   //!< reads in flight at most, rom_sdram's RD_MAX
    parameter int HI = N,                   //!< slots 0..HI-1 have priority over the others
    parameter int LO_MAX = QD               //!< reads in flight at most of slots HI..N-1
)(
    input  wire                     clk,
    input  wire                     reset,  //!< forgets every held word

    //! ---- the game's buses, word addresses into the ROM image ----
    input  wire  [N-1:0][AW-1:2]    slot_addr,
    input  wire  [N-1:0]            slot_cs,
    input  wire  [N-1:0]            slot_hold,  //!< 1: this slot starts no read now
    output logic [N-1:0]            slot_ok,
    output logic [N-1:0][31:0]      slot_data,

    //! ---- to rom_sdram.sv, its read stream ----
    output logic [AW-1:2]           rd_addr,
    output logic                    rd_push,
    input  wire                     rd_ready,
    input  wire                     rd_valid,
    input  wire  [31:0]             rd_data,

    //! ---- diagnostics ----
    output logic [31:0]             miss    //!< clocks any slot waited, wraps
);
    localparam int PW = $clog2(N > 1 ? N : 2);
    localparam int QW = $clog2(QD);

    logic [N-1:0][AW-1:2] tag;
    logic [N-1:0]         valid = '0;
    logic [N-1:0]         fly = '0;          // a read of this slot is in flight
    logic [N-1:0]         hit, want;

    // what each slot holds, and who asks
    always_comb
        for (int i = 0; i < N; i++) begin
            hit[i]       = valid[i] && tag[i] == slot_addr[i];
            slot_ok[i]   = slot_cs[i] && hit[i];
            want[i]      = slot_cs[i] && !hit[i] && !fly[i];
        end

    // the slots from HI on that have a read in flight, and whether one more may go
    logic [$clog2(N + 1)-1:0] lo_fly;
    always_comb begin
        lo_fly = '0;
        for (int i = HI; i < N; i++) lo_fly = lo_fly + fly[i];
    end
    wire lo_ok = lo_fly < LO_MAX;
    logic [N-1:0] lo_mask;
    always_comb
        for (int i = 0; i < N; i++) lo_mask[i] = (i >= HI) && !lo_ok;

    // the lowest numbered slot that asks and is not held
    wire  [N-1:0]  go = want & ~slot_hold & ~lo_mask;
    logic [PW-1:0] pick;
    always_comb begin
        pick = '0;
        for (int i = N - 1; i >= 0; i--)
            if (go[i]) pick = PW'(i);
    end
    assign rd_push = |go && rd_ready && !reset;
    always_comb rd_addr = slot_addr[pick];

    // the slot numbers of the reads in flight, oldest first; rom_sdram never has more than QD
    logic [PW-1:0] q [0:QD-1];
    logic [QW-1:0] q_wp = '0, q_rp = '0;
    wire  [PW-1:0] head = q[q_rp];
    always_ff @(posedge clk) begin
        if (rd_push) begin
            q[q_wp]      <= pick;
            q_wp         <= q_wp + 1'b1;
            tag[pick]    <= slot_addr[pick];   // the word will belong to this address
        end
        if (rd_valid) q_rp <= q_rp + 1'b1;
        // in flight: set at the push, cleared when the word is in
        for (int i = 0; i < N; i++)
            if (rd_push && pick == PW'(i))       fly[i] <= 1'b1;
            else if (rd_valid && head == PW'(i)) fly[i] <= 1'b0;
        // held words
        for (int i = 0; i < N; i++)
            if (reset)                                valid[i] <= 1'b0;
            else if (rd_push && pick == PW'(i))       valid[i] <= 1'b0;
            else if (rd_valid && head == PW'(i))      valid[i] <= 1'b1;
        if (rd_valid) slot_data[head] <= rd_data;
    end

    always_ff @(posedge clk)
        if (reset)      miss <= 32'd0;
        else if (|(slot_cs & ~hit)) miss <= miss + 32'd1;
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
