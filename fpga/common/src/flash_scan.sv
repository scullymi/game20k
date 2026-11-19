// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file flash_scan.sv
//! @brief Reads once after reset which core each slot of the configuration flash holds.
//!
//! Each slot of SLOT_BYTES gets two reads with command 0x03:
//!   - its first HEAD_BYTES: a bitstream has its sync word a5 c3 there,
//!   - its last TAG_BYTES, the tag the build writes there: "G20KCORE", the board id and its
//!     complement. Every bitstream ends long before, the FPGA never reads it.
//! board[n] is then 0 for no bitstream, the tag's board id, or 255 for a bitstream without a
//! valid tag. done rises when all slots are read. The pins are driven only during the scan
//! and released afterwards, so a programmer that writes the flash over JTAG finds them as
//! before. SCK runs at half the clock, within the flash's limit for 0x03 at every core
//! clock. done rises clocks after the last board is final, the RAM mirror's header sends
//! it ahead of the boards for that reason (ram_spi.sv).

module flash_scan #(
    parameter int SLOTS      = 8,
    parameter int SLOT_BYTES = 'h100000,
    parameter int HEAD_BYTES = 32,
    parameter int TAG_BYTES  = 16
)(
    input  wire        clk,
    input  wire        reset,
    output logic       oe,                  //!< drive cs_n, sck and mosi, low after the scan
    output logic       cs_n,
    output logic       sck,
    output logic       mosi,
    input  wire        miso,
    output logic [7:0] board [SLOTS],       //!< per slot: 0 empty, 1..254 the tag's board, 255 no tag
    output logic       done
);
    localparam logic [63:0] MAGIC = "G20KCORE";
    localparam int SW = $clog2(SLOTS + 1);
    localparam int NMAX = HEAD_BYTES > TAG_BYTES ? HEAD_BYTES : TAG_BYTES;
    localparam int BW = $clog2(32 + 8 * NMAX + 1);

    typedef enum logic [2:0] {S_START, S_HIGH, S_LOW, S_END, S_GAP, S_DONE} state_t;
    state_t st = S_START;

    logic [SW-1:0] slot  = '0;
    logic          tag   = 1'b0;    // 0: the head read of the slot, 1: its tag read
    logic [31:0]   out   = '0;      // command and address, sent MSB first
    logic [BW-1:0] bitn  = '0;      // bits done in this read
    logic [7:0]    sh    = '0;      // byte being received
    logic [7:0]    prev  = '0;      // previous byte of the head read
    logic          sync  = 1'b0;    // the head read saw a5 c3
    logic          tagok = 1'b0;    // the tag read matched so far
    logic [7:0]    tagb  = '0;      // the tag's board id
    logic [2:0]    gap   = '0;

    wire [BW-1:0] nbits = BW'(32 + 8 * (tag ? TAG_BYTES : HEAD_BYTES));
    wire [23:0]   addr  = 24'(slot * SLOT_BYTES + (tag ? SLOT_BYTES - TAG_BYTES : 0));
    wire [7:0]    rx    = {sh[6:0], miso};             // the byte complete at this rising edge
    wire [BW-1:0] dbit  = bitn - BW'(32);               // data bit index once past the address
    wire [7:0]    bytei = 8'(dbit >> 3);

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= S_START; slot <= '0; tag <= 1'b0; done <= 1'b0;
            oe <= 1'b0; cs_n <= 1'b1; sck <= 1'b0; mosi <= 1'b0;
        end else case (st)
            // Start a read: command 0x03 and the address, the first bit already on mosi
            S_START: begin
                oe <= 1'b1; cs_n <= 1'b0; sck <= 1'b0;
                out <= {8'h03, addr}; mosi <= 1'b0;   // bit 7 of 0x03
                bitn <= '0; sync <= 1'b0; tagok <= 1'b1; prev <= 8'h00;
                st <= S_HIGH;
            end
            // Rising edge: the flash's bit is sampled
            S_HIGH: begin
                sck <= 1'b1;
                sh  <= rx;
                if (bitn >= BW'(32) && dbit[2:0] == 3'd7) begin
                    // a whole data byte
                    if (!tag) begin
                        if (prev == 8'hA5 && rx == 8'hC3) sync <= 1'b1;
                        prev <= rx;
                    end else if (bytei < 8) begin
                        if (rx != MAGIC[63 - 8 * bytei -: 8]) tagok <= 1'b0;
                    end else if (bytei == 8) tagb <= rx;
                    else if (bytei == 9 && rx != ~tagb) tagok <= 1'b0;
                end
                st <= S_LOW;
            end
            // Falling edge: the next command or address bit goes out
            S_LOW: begin
                sck  <= 1'b0;
                out  <= out << 1;
                mosi <= out[30];
                bitn <= bitn + 1'b1;
                st   <= (bitn + 1'b1 == nbits) ? S_END : S_HIGH;
            end
            // The read is over: deselect, and after the tag read the slot's verdict
            S_END: begin
                cs_n <= 1'b1;
                gap  <= '0;
                if (!tag) board[slot] <= sync ? 8'hFF : 8'h00;
                else if (board[slot] == 8'hFF && tagok && tagb != 8'h00 && tagb != 8'hFF)
                    board[slot] <= tagb;
                st <= S_GAP;
            end
            // CS high for a few clocks between two reads, then the next one or the end
            S_GAP: begin
                gap <= gap + 1'b1;
                if (&gap) begin
                    if (!tag) tag <= 1'b1;
                    else begin
                        tag  <= 1'b0;
                        slot <= slot + 1'b1;
                    end
                    st <= (tag && slot == SW'(SLOTS - 1)) ? S_DONE : S_START;
                end
            end
            S_DONE: begin
                oe   <= 1'b0;
                done <= 1'b1;
            end
            default: st <= S_START;
        endcase
    end
endmodule
