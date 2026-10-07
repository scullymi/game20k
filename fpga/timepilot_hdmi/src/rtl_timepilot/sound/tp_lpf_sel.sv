// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file tp_lpf_sel.sv
//! @brief game20k: one switchable low pass per AY channel of Time Pilot.
//!
//! The board switches capacitors onto the same RC node with 74HC4066s (A2, A3, A4), so each
//! channel has one filter whose corner changes. Ace's core runs three filters per channel
//! and picks an output, 18 filters with 54 products, more than the GW2AR-18 has multipliers.
//! This module is one first-order filter per channel with the coefficients of Ace's
//! tp_lpf_light, tp_lpf_medium and tp_lpf_heavy (MIT, same difference equation as his
//! iir_1st_order), chosen by sel. B1 = B2 there, so B * (x0 + x1) saves a product: two per
//! channel. sel 0 is no capacitor: the output is the input, and the filter state follows it
//! so that switching a filter in does not click.
//!
//! The products are registered: x0, x1 and y0 change only at the sample tick, the next
//! tick comes 165 clocks later.
module tp_lpf_sel (
    input  logic               clk,
    input  logic               reset,
    input  logic [1:0]         sel,     //!< 0 none, 1 light, 2 medium, 3 heavy
    input  logic signed [15:0] in,
    output logic signed [15:0] out
);
    // sample rate 37.125 MHz / 166 = 223.6 kHz, Ace's 49.152 MHz / 220 = 223.4 kHz
    localparam int DIV = 166;

    logic signed [17:0] a2, b;
    always_comb
        case (sel)
            2'd1:    begin a2 = -18'sd31642; b = 18'sd563; end   // 3386 Hz
            2'd2:    begin a2 = -18'sd32420; b = 18'sd174; end   // 723 Hz
            default: begin a2 = -18'sd32498; b = 18'sd135; end   // 596 Hz
        endcase

    logic [7:0] count = '0;
    logic signed [15:0] x0 = '0, x1 = '0, y0 = '0;
    logic signed [35:0] pb = '0, pa = '0;
    always_ff @(posedge clk) begin
        pb <= b * (17'(x0) + 17'(x1));
        pa <= a2 * y0;
    end
    wire signed [35:0] acc = pb - pa;

    always_ff @(posedge clk)
        if (reset) begin
            count <= '0;
            x0 <= '0; x1 <= '0; y0 <= '0;
        end else if (count == 8'(DIV - 1)) begin
            count <= '0;
            x1 <= x0;
            x0 <= in;
            // scale 2^15, the sign and the 15 bits below it, as iir_1st_order does
            y0 <= (sel == 2'd0) ? in : {acc[35], acc[29:15]};
        end else
            count <= count + 8'd1;

    assign out = (sel == 2'd0) ? in : y0;
endmodule
