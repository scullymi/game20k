// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! -----------------------------------------------------------------------------------------
//! @file snap_log.sv
//! @brief The oracle: records the write accesses DURING the harvest (game20k).
//!
//! The snapshot is meant to show the memory state at ONE point in time: the end of the
//! harvest. It can deviate from that only through a write that happens during the harvest -
//! outside of it the shadow is not touched. So the log of this one window is enough:
//! 662 us out of 16.5 ms, around 26 entries on average and about 105 in the peak frame. The
//! complete log, at 7890 bytes per frame, would be larger than the snapshot itself.
//!
//! The check the Pico derives from it reads:
//!   For every address written inside the window, the snapshot must carry the LAST value
//!   written there.
//! Without catch-up this fails for the addresses the harvest had already passed - about
//! half of them. With catch-up it must be exactly zero. Addresses outside the window need
//! no check: nothing can have changed at them between copy and snapshot.
//!
//! The oracle feeds on the write enables of the GAME, brought out by the game wrapper as a
//! flat address in the RAM mirror, and knows nothing of the catch-up FIFO. It does not measure whether the catch-up does what it should, but whether
//! the result is right - no circular reasoning.
//!
//! Writing and reading never collide: no harvest can begin during a transfer, and during a
//! harvest the Pico fetches no snapshot (header check, byte 7).
//! -----------------------------------------------------------------------------------------

module snap_log #(
    parameter int DEPTH = 512             //!< entries; 3 bytes per entry = 1536 bytes in the stream
)(
    input  wire         clk,              //!< clk_core
    input  wire         harv_busy,
    //! Write accesses of the game: one clock of ram_we per byte written, with the address
    //! as the position in the RAM mirror (the game wrapper flattens its RAMs), and the byte
    input  wire         ram_we,
    input  wire  [15:0] ram_addr,
    input  wire  [7:0]  ram_data,
    //! Delivery: one byte per call, into the same look-ahead FIFO as the payload
    input  wire         send_start,
    input  wire         send_pop,
    output logic [7:0]  send_byte,

    output logic [9:0]  count,            //!< entries in the last window
    output logic        overflow          //!< the window held more than DEPTH
);
    localparam int AW = $clog2(DEPTH);

    // Initial value so the overflow bit is not undefined before the first harvest - it goes
    // out as the footer byte and would discard the first snapshot for no reason.
    logic overflow_r = 1'b0;
    assign overflow = overflow_r;

    // One write port, one read port, one clock: synthesis turns this into a BSRAM block.
    // As a register array it would be 12288 flip-flops - the board has them, the CLS
    // utilisation does not. 512 x 24 still fits one block.
    logic [23:0] mem [0:DEPTH-1];

    logic [AW:0] wp = 0;                  // one bit wider so DEPTH itself is representable
    logic        harv_d = 0;

    always_ff @(posedge clk) begin
        harv_d <= harv_busy;
        if (harv_busy && !harv_d) begin   // new harvest: window starts over
            wp       <= '0;
            overflow_r <= 1'b0;
        end else if (harv_busy && ram_we) begin
            if (wp[AW]) overflow_r <= 1'b1;
            else begin
                mem[wp[AW-1:0]] <= {ram_data, ram_addr};
                wp <= wp + 1'b1;
            end
        end
    end
    assign count = wp;

    // ---- Delivery: three bytes per entry: address low, address high, the written byte ----
    // The read uses the NEXT entry number, not the current one. Otherwise the old entry
    // would still be present at the transition from byte 3 to byte 1: the memory outputs
    // only one clock after the address, and three bytes can be fetched in three consecutive
    // clocks when the FIFO is empty.
    logic [AW:0] ep = 0;
    logic [1:0]  bsel = 0;
    logic [23:0] q;

    wire [AW:0] ep_n = send_start                     ? '0
                     : (send_pop && bsel == 2'd2)     ? ep + 1'b1
                     :                                  ep;

    always_ff @(posedge clk) begin
        q <= mem[ep_n[AW-1:0]];
        ep <= ep_n;
        if (send_start)     bsel <= 2'd0;
        else if (send_pop)  bsel <= (bsel == 2'd2) ? 2'd0 : bsel + 2'd1;
    end

    always_comb begin
        case (bsel)
            2'd0:    send_byte = q[7:0];          // flat address, lower eight bits
            2'd1:    send_byte = q[15:8];
            default: send_byte = q[23:16];        // the written byte
        endcase
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
