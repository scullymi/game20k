// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! -----------------------------------------------------------------------------------------
//! @file audio_cdc.sv
//! @brief The audio word from the core clock to the pixel clock, one word per request (game20k).
//!
//! Core and pixel clock are asynchronous (board.sdc). A 16-bit word taken bit by bit through
//! two registers each can arrive torn, some bits from the old and some from the new sample.
//! Here the pixel side asks with a toggle, the core side takes the word into a register of
//! its own on the synchronised toggle and answers with a second toggle one clock later, and
//! the pixel side takes the held word on the synchronised answer. The held word changes
//! only on a request, so it stands still from well before the pixel side takes it until the
//! next request.
//!
//! Request to dout takes up to 5 core and 4 pixel clocks, under 0.4 us at 18.5625 MHz.
//! The top requests at the falling edge of the 48 kHz clk_audio, so dout settles more than
//! 10 us before the rising edge at which the HDMI module takes it, and holds for 10 us after.
//! -----------------------------------------------------------------------------------------

module audio_cdc (
    input  wire         clk_core,
    input  wire  [15:0] din,         //!< the word in the core clock, may change every clock
    input  wire         clk_pixel,
    input  wire         req,         //!< one pixel clock: take a new word
    output logic [15:0] dout         //!< the word in the pixel clock, changes only on req
);
    // pixel side: request toggle, synchronised answer, the word
    logic        req_t = 1'b0;
    logic [2:0]  ack_s = 3'b000;
    logic [15:0] word  = '0;
    assign dout = word;
    // core side: synchronised request, held word, answer toggle
    logic [2:0]  req_s = 3'b000;
    logic [15:0] hold  = '0;
    logic        ack_t = 1'b0;

    always_ff @(posedge clk_pixel) begin
        if (req) req_t <= ~req_t;
        ack_s <= {ack_s[1:0], ack_t};
        if (ack_s[1] ^ ack_s[2]) word <= hold;
    end

    always_ff @(posedge clk_core) begin
        req_s <= {req_s[1:0], req_t};
        if (req_s[1] ^ req_s[2]) hold <= din;
        // req_s[2] one clock later: the answer toggles a clock after hold has been written
        ack_t <= req_s[2];
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
