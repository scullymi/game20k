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
//! Both sides live in clk_core. The controller (sdram_fb.v) runs in clk_sdram, with a
//! req/ack toggle per channel. The crossing:
//!   - towards clk_sdram the request toggle passes two flip-flops, address and data are
//!     held in clk_core from before the toggle until its acknowledge returns, so the
//!     controller samples them stable;
//!   - back the write channel's wr_ack and, for reads, a toggle made from the one-clock
//!     rd_valid pass two flip-flops into clk_core. rd_dout of the controller holds its value
//!     until the next read, which cannot start before this one is acknowledged.
//! The clock groups are asynchronous in board.sdc, so the tools time none of these paths.
//!
//! Write side: rom_loader hands over one byte at a time with its file offset. Four bytes
//! make a word; while the previous word is still on its way, the next one is gathered in a
//! second register. Only when that one is full as well does wr_ready drop and the loader
//! wait. At the SPI rate of the Companion (2.5 MB/s at most, a word per 1.6 us) against
//! about 0.5 us per word write that should not happen.
//!
//! Read side: one word at a time. rd_req toggles with a new rd_addr, rd_ack takes the value
//! of rd_req once rd_data holds the word. Latency, worked out from sdram_fb.v: typically
//! about 270 ns (10 clocks at 37.125 MHz), at most about 510 ns when a refresh is in the way.
module rom_sdram #(
    parameter int AW = 18,                 //!< width of the file offsets, ROM_AW of the package
    parameter logic [1:0] BANK = 2'd2      //!< SDRAM bank of the ROM; 0 and 1 hold the frame buffer
)(
    input  wire          clk_core,
    input  wire          reset,            //!< clk_core, drops pending gather state

    //! ---- write side, from rom_loader: the bytes of the sdram sections in file order ----
    input  wire          wr_we,            //!< one clock: wr_data belongs at wr_off
    input  wire [AW-1:0] wr_off,
    input  wire [7:0]    wr_data,
    output logic         wr_ready,         //!< 0: both word registers full, hold the next byte
    output logic         wr_idle,          //!< 1: no word gathered or on its way

    //! ---- read side, one 32-bit word at a time ----
    input  wire [AW-1:2] rd_addr,          //!< word address, stable from the rd_req toggle to rd_ack
    input  wire          rd_req,           //!< toggle: read rd_addr
    output logic         rd_ack,           //!< equals rd_req once rd_data holds the word
    output logic [31:0]  rd_data,

    //! ---- to sdram_fb.v, its write and read channels ----
    input  wire          clk_sdram,
    output logic [21:0]  sd_wr_addr,
    output logic [31:0]  sd_wr_din,
    output logic [1:0]   sd_wr_bank,
    output logic         sd_wr_req,
    input  wire          sd_wr_ack,
    output logic [21:0]  sd_rd_addr,
    output logic [1:0]   sd_rd_bank,
    output logic         sd_rd_req,
    input  wire          sd_rd_ack,        //!< the controller's own bookkeeping, not used here
    input  wire [31:0]   sd_rd_dout,
    input  wire          sd_rd_valid
);
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
            if (g_full && !o_busy) begin
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
    logic [1:0] r_done_s = 2'b00;              // done toggle from clk_sdram, synchronised
    logic       r_done_q = 1'b0;               // last value seen
    always_ff @(posedge clk_core) begin
        r_done_s <= {r_done_s[0], r_done};
        r_done_q <= r_done_s[1];
        if (r_done_s[1] != r_done_q) begin
            rd_data <= sd_rd_dout;              // stable since the controller wrote it
            rd_ack  <= ~rd_ack;
        end
    end
    initial rd_ack = 1'b0;

    // ---------------- clk_sdram side ----------------
    logic [1:0] w_req_s = 2'b00, r_req_s = 2'b00;
    logic       r_done = 1'b0;
    always_ff @(posedge clk_sdram) begin
        w_req_s <= {w_req_s[0], w_req};
        r_req_s <= {r_req_s[0], rd_req};
        if (sd_rd_valid) r_done <= ~r_done;     // sd_rd_dout holds the word from rd_valid on
    end
    assign sd_wr_req  = w_req_s[1];
    assign sd_wr_addr = 22'({o_addr, 2'b00});
    assign sd_wr_din  = o_word;
    assign sd_wr_bank = BANK;
    assign sd_rd_req  = r_req_s[1];
    assign sd_rd_addr = 22'({rd_addr, 2'b00});
    assign sd_rd_bank = BANK;
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
