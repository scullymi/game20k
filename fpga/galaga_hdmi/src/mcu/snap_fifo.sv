// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! -----------------------------------------------------------------------------------------
//! @file snap_fifo.sv
//! @brief Look-ahead FIFO between core clock and SPI clock (game20k).
//!
//! The 5120 payload bytes of the snapshot sit in memories that themselves need slots: the
//! bgram shadow in a block of its own, the three wram shadows in the upper half of the same
//! single-port cells the game reads from. One byte per round (323 ns) is possible, one byte
//! per SPI byte (measured 1.2 us) is needed - so the core is three times faster than the
//! line. A buffer in between is still required, because the two clocks know nothing of
//! each other.
//!
//! Eight slots, Gray-code pointers, memory as a register array. Reads happen in the SPI
//! clock on the FALLING edge, i.e. at the very moment mcu_spi.v has a byte complete - so
//! the next byte is ready before its first bit goes out.
//! -----------------------------------------------------------------------------------------

module snap_fifo (
    //! Write side, core clock
    input  wire        wclk,
    input  wire        wreset,
    input  wire  [7:0] wdata,
    input  wire        wpush,
    output logic       wfull,

    //! Read side, SPI clock
    input  wire        rclk,          //!< falling edge of spi_clk
    input  wire        rss,           //!< chip select, active low
    input  wire        rpop,          //!< take one byte
    output logic [7:0] rdata,
    output logic       rempty,
    output logic       rundr          //!< a byte was taken although none was there
);
    logic [7:0] mem [0:7];
    logic       rundr_r = 1'b0;
    assign      rundr = rundr_r;
    logic [3:0] wp = 0, wg = 0, rp = 0, rg = 0;
    logic [3:0] wg_s0 = 0, wg_s1 = 0;   // in the read side
    logic [3:0] rg_s0 = 0, rg_s1 = 0;   // in the write side

    function automatic logic [3:0] b2g(input logic [3:0] b);
        b2g = b ^ (b >> 1);
    endfunction

    wire [3:0] wp_next = wp + 4'd1;
    assign wfull = (b2g(wp_next) == {~rg_s1[3:2], rg_s1[1:0]});

    always_ff @(posedge wclk) begin
        rg_s0 <= rg; rg_s1 <= rg_s0;
        if (wreset) begin
            wp <= 4'd0; wg <= 4'd0;
        end else if (wpush && !wfull) begin
            mem[wp[2:0]] <= wdata;
            wp <= wp_next;
            wg <= b2g(wp_next);
        end
    end

    assign rdata  = mem[rp[2:0]];
    assign rempty = (rg == wg_s1);

    always_ff @(negedge rclk or posedge rss) begin
        if (rss) begin
            // The read side starts over with every transfer. The write pointer stays put -
            // the core keeps filling, and whatever is left over is discarded by the write
            // side resetting on every new request.
            rp <= 4'd0; rg <= 4'd0;
            wg_s0 <= 4'd0; wg_s1 <= 4'd0;
            rundr_r <= 1'b0;
        end else begin
            wg_s0 <= wg; wg_s1 <= wg_s0;
            if (rpop && !rempty) begin
                rp <= rp + 4'd1;
                rg <= b2g(rp + 4'd1);
            end
            // THE UNDERRUN BELONGS HERE, in the read clock and at the exact moment of the
            // pop. The write side cannot detect it by sampling rempty, a signal from this
            // clock here, unsynchronised in the CORE clock: over 6.2 ms that is more than a
            // hundred thousand samples of a foreign clock, and because the flag is sticky,
            // a single slipped one is enough for a false alarm.
            // Here it is not a sample but the condition itself: a byte was needed and none
            // was there. Then the same byte goes out twice.
            else if (rpop) rundr_r <= 1'b1;
        end
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
