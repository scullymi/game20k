// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! @file rom_sdram.sv
//! @brief A game's ROM in SDRAM: fills it from rom_loader, reads it word by word (game20k).
//!
//! For a game whose ROM does not fit into block RAM (1942). The ROM file's sections marked
//! sdram in the manifest lie in SDRAM bank BANK at their file offset, as 32-bit words, byte
//! 0 of a word in bits 7:0. scripts/make_rom.py already lays the file out as the SDRAM
//! image, so filling it is a plain sequence of word writes.
//!
//! Both sides live in clk_core. The controller (sdram_fb.v, through sdram_share.sv) runs in
//! clk_sdram, with a req/ack toggle per channel. The clock groups are asynchronous in
//! board.sdc, so the tools time none of the crossing paths.
//!
//! Write side: rom_loader hands over one byte at a time with its file offset. Four bytes
//! make a word; while the previous word is still on its way, the next one is gathered in a
//! second register. Only when that one is full as well does wr_ready drop and the loader
//! wait. Towards clk_sdram the request toggle passes two flip-flops, address and data are
//! held from before the toggle until its acknowledge returns.
//!
//! Read side: a stream with several reads in flight. rd_push takes rd_addr while rd_ready is
//! high; the words come back in the same order, one clock of rd_valid each, rd_data valid in
//! that clock only. The controller accepts one read per round of six clk_sdram cycles and
//! returns its word a fixed number of cycles later, in order (sdram_fb.v), so reads can follow
//! each other at the ring rate instead of waiting for the previous word:
//!   - clk_core -> clk_sdram: a small FIFO of addresses (cdc_fifo below, Gray pointers).
//!     The clk_sdram side passes the oldest address on as soon as the previous toggle has
//!     been accepted (sd_rd_ack equals sd_rd_req).
//!   - clk_sdram -> clk_core: a FIFO of words, written at every sd_rd_valid. sdram_share keeps
//!     the ROM's word in sd_rd_dout from sd_rd_valid on.
//!   - a credit count in clk_core: at most RD_MAX reads between rd_push and rd_valid, so the
//!     word FIFO, as deep as RD_MAX, can never overflow.
//! Latency is unchanged at about 10 clk_core clocks typically; what changes is that up to
//! RD_MAX of them overlap.
//!
//! Writes and reads never overlap. sdram_fb opens the write channel's bank in ring cycle 0
//! and the read channel's in cycle 1 of the same round, and both are bank BANK here. A write
//! in the same round as a read would open the open bank a second time, and a write in the
//! round after a read would come one cycle before the read's auto precharge has finished
//! (tRP). So a word goes out only while no read is in flight (credit count zero, no push in
//! this clock), and rd_ready is low while a write is gathered or out: the synchronisers then
//! put at least one whole round between them. Writes come only while the game is held in
//! reset after loading, reads only while it runs.
module rom_sdram #(
    parameter int AW = 18,                 //!< width of the file offsets, ROM_AW of the package
    parameter logic [1:0] BANK = 2'd2,     //!< SDRAM bank of the ROM; 0 and 1 hold the frame buffer
    parameter int RD_MAX = 4               //!< reads in flight at most, depth of both FIFOs
)(
    input  wire          clk_core,
    input  wire          reset,            //!< clk_core, drops pending gather state
    //! ---- write side, from rom_loader: the bytes of the sdram sections in file order ----
    input  wire          wr_we,            //!< one clock: wr_data belongs at wr_off
    input  wire [AW-1:0] wr_off,
    input  wire [7:0]    wr_data,
    output logic         wr_ready,         //!< 0: both word registers full, hold the next byte
    output logic         wr_idle,          //!< 1: no word gathered or on its way
    //! ---- read side, a stream of 32-bit word reads ----
    input  wire [AW-1:2] rd_addr,          //!< taken with rd_push
    input  wire          rd_push,          //!< one clock per read, only while rd_ready
    output logic         rd_ready,
    output logic         rd_valid,         //!< one clock per word, in the order of the pushes
    output logic [31:0]  rd_data,          //!< valid with rd_valid
    //! ---- to sdram_share.sv (port A), its write and read channels ----
    input  wire          clk_sdram,
    output logic [21:0]  sd_wr_addr,
    output logic [31:0]  sd_wr_din,
    output logic [1:0]   sd_wr_bank,
    output logic         sd_wr_req,
    input  wire          sd_wr_ack,
    output logic [21:0]  sd_rd_addr,
    output logic [1:0]   sd_rd_bank,
    output logic         sd_rd_req,
    input  wire          sd_rd_ack,        //!< equals sd_rd_req once the read is accepted
    input  wire  [31:0]  sd_rd_dout,
    input  wire          sd_rd_valid,
    output logic         sd_rd_hint        //!< a read is queued or not yet accepted
);
    localparam int CW = $clog2(RD_MAX + 1);

    // ---------------- Write side, clk_core ----------------
    // gather: the word being filled, out: the word on its way to the controller
    logic [31:0]   g_word;
    logic [AW-1:2] g_addr;
    logic          g_full;
    logic [31:0]   o_word;
    logic [AW-1:2] o_addr;
    logic          w_req = 1'b0;               // toggle towards clk_sdram
    logic [1:0]    w_ack_s = 2'b00;            // sd_wr_ack synchronised into clk_core
    wire           o_busy = w_req ^ w_ack_s[1];
    logic [CW-1:0] r_fly = '0;                 // reads pushed and not yet returned
    // a full word goes out when no write is out and no read is in flight or pushed now
    wire           w_go   = g_full && !o_busy && r_fly == '0 && !rd_push;
    always_ff @(posedge clk_core) begin
        w_ack_s <= {w_ack_s[0], sd_wr_ack};
        if (reset) begin
            g_full <= 1'b0;
        end else begin
            // a byte arrives: into its lane; the fourth one completes the word
            if (wr_we) begin
                g_word[8*wr_off[1:0] +: 8] <= wr_data;
                g_addr <= wr_off[AW-1:2];
                if (wr_off[1:0] == 2'd3) g_full <= 1'b1;
            end
            // a full word moves on as soon as the previous one has been taken
            if (w_go) begin
                o_word <= g_word;
                o_addr <= g_addr;
                w_req  <= ~w_req;
                g_full <= 1'b0;
            end
        end
    end
    // The loader takes at most one byte every two clocks and writes it one clock later, so
    // dropping wr_ready in the clock g_full rises is early enough.
    assign wr_ready = !g_full;
    assign wr_idle  = !g_full && !o_busy;

    // ---------------- Read side, clk_core ----------------
    // credits: a read counts from its push to its word; no reads while a write is about
    wire q_full;
    assign rd_ready = r_fly != CW'(RD_MAX) && !q_full && !g_full && !o_busy;
    wire w_empty;
    wire [31:0] w_word;
    assign rd_valid = !w_empty;              // a word is popped in the clock it is shown
    assign rd_data  = w_word;
    always_ff @(posedge clk_core)
        if (reset)                           r_fly <= '0;
        else case ({rd_push && rd_ready, rd_valid})
            2'b10:   r_fly <= r_fly + CW'(1);
            2'b01:   r_fly <= r_fly - CW'(1);
            default: ;
        endcase

    // addresses towards clk_sdram
    wire          q_empty;
    wire [AW-1:2] q_addr;
    logic         q_pop;
    cdc_fifo #(.DW(AW - 2), .DEPTH(RD_MAX)) u_q (
        .wclk(clk_core),  .wr(rd_push && rd_ready), .wdata(rd_addr), .full(q_full),
        .rclk(clk_sdram), .rd(q_pop),               .rdata(q_addr),  .empty(q_empty)
    );
    // words towards clk_core
    cdc_fifo #(.DW(32), .DEPTH(RD_MAX)) u_w (
        .wclk(clk_sdram), .wr(sd_rd_valid), .wdata(sd_rd_dout), .full(),
        .rclk(clk_core),  .rd(!w_empty),    .rdata(w_word),     .empty(w_empty)
    );

    // ---------------- clk_sdram side ----------------
    logic [1:0]  w_req_s = 2'b00;
    logic        r_req = 1'b0;
    logic [21:0] r_addr;
    // the next address goes out once the previous toggle has been accepted
    assign q_pop = !q_empty && (sd_rd_ack == r_req);
    always_ff @(posedge clk_sdram) begin
        w_req_s <= {w_req_s[0], w_req};
        if (q_pop) begin
            r_addr <= 22'({q_addr, 2'b00});
            r_req  <= ~r_req;
        end
    end
    initial r_req = 1'b0;
    assign sd_wr_req  = w_req_s[1];
    assign sd_wr_addr = 22'({o_addr, 2'b00});
    assign sd_wr_din  = o_word;
    assign sd_wr_bank = BANK;
    assign sd_rd_req  = r_req;
    assign sd_rd_hint = !q_empty || sd_rd_ack != r_req;
    assign sd_rd_addr = r_addr;
    assign sd_rd_bank = BANK;
endmodule

//! A small FIFO between two unrelated clocks: Gray-coded pointers, each synchronised by two
//! flip-flops into the other domain, the entries in registers. rdata shows the oldest entry
//! while not empty; rd takes it away. An entry is written at the same write clock edge at
//! which the write pointer announcing it moves, and the reader sees that pointer only two of
//! its own clocks later, so rdata is stable whenever empty is low. DEPTH 4 or more.
module cdc_fifo #(
    parameter int DW    = 32,
    parameter int DEPTH = 4                 //!< a power of two
)(
    input  wire           wclk,
    input  wire           wr,               //!< ignored while full
    input  wire  [DW-1:0] wdata,
    output logic          full,
    input  wire           rclk,
    input  wire           rd,               //!< ignored while empty
    output logic [DW-1:0] rdata,
    output logic          empty
);
    localparam int PW = $clog2(DEPTH);
    logic [DW-1:0] mem [0:DEPTH-1];
    logic [PW:0]   wbin = '0, rbin = '0;     // binary pointers, one bit more than the index
    logic [PW:0]   wgray = '0, rgray = '0;
    logic [PW:0]   wgray_s1 = '0, wgray_s2 = '0;   // write pointer in rclk
    logic [PW:0]   rgray_s1 = '0, rgray_s2 = '0;   // read pointer in wclk
    function automatic logic [PW:0] g(input logic [PW:0] b); return b ^ (b >> 1); endfunction

    // write domain
    assign full = wgray == {~rgray_s2[PW:PW-1], rgray_s2[PW-2:0]};
    always_ff @(posedge wclk) begin
        rgray_s1 <= rgray;
        rgray_s2 <= rgray_s1;
        if (wr && !full) begin
            mem[wbin[PW-1:0]] <= wdata;
            wbin  <= wbin + 1'b1;
            wgray <= g(wbin + 1'b1);
        end
    end
    // read domain
    assign empty = rgray == wgray_s2;
    assign rdata = mem[rbin[PW-1:0]];
    always_ff @(posedge rclk) begin
        wgray_s1 <= wgray;
        wgray_s2 <= wgray_s1;
        if (rd && !empty) begin
            rbin  <= rbin + 1'b1;
            rgray <= g(rbin + 1'b1);
        end
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
