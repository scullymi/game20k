// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! @file sdram_share.sv
//! @brief Two users on the two channels of sdram_fb.v (game20k).
//!
//! For a game whose ROM lives in SDRAM and that still has the frame buffer (1942 upright):
//! port A is the ROM (rom_sdram.sv), port B the frame buffer (fb_pack.sv writes,
//! fb_read_rotated.sv reads). Each channel of the controller, write and read, gets its own
//! arbiter (sdram_share_ch below). Everything runs in clk_sdram.
//!
//! Port A has priority on both channels. On the read channel that matters: the ROM's tile
//! bus has to be served within about a microsecond, while the frame buffer fetches a group of
//! 224 words in one go and then has 170 us until it is shown. With B first, a group would
//! hold the ROM off for 20 us. With A first, B takes every ring slot A leaves free: the ROM
//! reads at most about 4 million words a second of the 10.5 million, the frame buffer needs
//! 1.3 million. On the write channel the two hardly meet: the ROM writes only while the core
//! is held in reset after loading.
//!
//! The banks keep the two apart in the SDRAM: the frame buffer in banks 0 and 1, the ROM in
//! bank 2. sdram_fb runs one write and one read per round on different banks, which holds
//! here as it did for the frame buffer alone. The ROM's own write and read never overlap,
//! rom_sdram.sv makes sure of that.
module sdram_share (
    input  wire         clk,                //!< clk_sdram

    //! ---- to the controller ----
    output logic [21:0] c_wr_addr,
    output logic [31:0] c_wr_din,
    output logic [1:0]  c_wr_bank,
    output logic        c_wr_req,
    input  wire         c_wr_ack,
    output logic [21:0] c_rd_addr,
    output logic [1:0]  c_rd_bank,
    output logic        c_rd_req,
    input  wire         c_rd_ack,
    input  wire  [31:0] c_rd_dout,
    input  wire         c_rd_valid,

    //! ---- port A, first ----
    input  wire  [21:0] a_wr_addr,
    input  wire  [31:0] a_wr_din,
    input  wire  [1:0]  a_wr_bank,
    input  wire         a_wr_req,
    output logic        a_wr_ack,
    input  wire  [21:0] a_rd_addr,
    input  wire  [1:0]  a_rd_bank,
    input  wire         a_rd_req,
    output logic        a_rd_ack,
    output logic [31:0] a_rd_dout,          //!< held until A's next word
    output logic        a_rd_valid,         //!< one clock after the controller's rd_valid

    //! ---- port B ----
    input  wire  [21:0] b_wr_addr,
    input  wire  [31:0] b_wr_din,
    input  wire  [1:0]  b_wr_bank,
    input  wire         b_wr_req,
    output logic        b_wr_ack,
    input  wire  [21:0] b_rd_addr,
    input  wire  [1:0]  b_rd_bank,
    input  wire         b_rd_req,
    output logic        b_rd_ack,
    output logic        b_rd_valid          //!< B takes c_rd_dout itself, in this clock
);
    logic wr_own_unused, rd_own;            // owner of the accepted request, valid with acc
    logic wr_acc_unused, rd_acc;

    sdram_share_ch #(.DW(32 + 22 + 2)) u_wr (
        .clk(clk),
        .a_req(a_wr_req), .a_ack(a_wr_ack), .a_pay({a_wr_din, a_wr_addr, a_wr_bank}),
        .b_req(b_wr_req), .b_ack(b_wr_ack), .b_pay({b_wr_din, b_wr_addr, b_wr_bank}),
        .c_req(c_wr_req), .c_ack(c_wr_ack), .c_pay({c_wr_din, c_wr_addr, c_wr_bank}),
        .acc(wr_acc_unused), .acc_b(wr_own_unused)
    );

    sdram_share_ch #(.DW(22 + 2)) u_rd (
        .clk(clk),
        .a_req(a_rd_req), .a_ack(a_rd_ack), .a_pay({a_rd_addr, a_rd_bank}),
        .b_req(b_rd_req), .b_ack(b_rd_ack), .b_pay({b_rd_addr, b_rd_bank}),
        .c_req(c_rd_req), .c_ack(c_rd_ack), .c_pay({c_rd_addr, c_rd_bank}),
        .acc(rd_acc), .acc_b(rd_own)
    );

    // Read data comes back in the order the reads were accepted, CAPT cycles after each, at
    // most two in flight (one activation per round of six cycles). A queue of owners, pushed
    // at acceptance, popped at rd_valid, tells whose data it is.
    logic [3:0] own_q = 4'd0;               // bit i: owner of the i-th read in flight (1 = B)
    logic [2:0] own_n = 3'd0;               // reads in flight
    wire        head_b = own_q[0];
    always_ff @(posedge clk) begin
        case ({rd_acc, c_rd_valid})
            2'b10: begin own_q[own_n[1:0]] <= rd_own; own_n <= own_n + 3'd1; end
            2'b01: begin own_q <= {1'b0, own_q[3:1]}; own_n <= own_n - 3'd1; end
            2'b11: begin                     // pop and push in the same clock
                own_q <= {1'b0, own_q[3:1]};
                own_q[own_n[1:0] - 2'd1] <= rd_own;
            end
            default: ;
        endcase
    end
    // rom_sdram takes the word several clocks after rd_valid, in its own clock domain, and
    // relies on rd_dout holding it until then. The controller's rd_dout changes with B's
    // next read, so A gets its own copy, valid together with a_rd_valid one clock later.
    // B (fb_read_rotated) takes the word in the clock of rd_valid.
    initial a_rd_valid = 1'b0;
    always_ff @(posedge clk) begin
        a_rd_valid <= c_rd_valid && !head_b;
        if (c_rd_valid && !head_b) a_rd_dout <= c_rd_dout;
    end
    assign b_rd_valid = c_rd_valid && head_b;
endmodule

//! One channel: two users with req/ack toggles in front of the controller's req/ack toggle.
//! The arbiter owns the controller's toggle and keeps one acknowledge per user, so a switch
//! of users never shows the controller an old toggle level as a new request.
//!   - A user asks while its req differs from its ack.
//!   - With nothing in flight, the arbiter takes A if it asks, else B: it latches the
//!     payload and flips c_req.
//!   - The controller accepts when c_ack becomes equal to c_req. In that clock the user's
//!     ack takes the level its req had when the request was latched, and acc pulses with the
//!     owner on acc_b. A new request is latched one clock later at the earliest.
module sdram_share_ch #(
    parameter int DW = 24
)(
    input  wire          clk,
    input  wire          a_req,
    output logic         a_ack,
    input  wire [DW-1:0] a_pay,
    input  wire          b_req,
    output logic         b_ack,
    input  wire [DW-1:0] b_pay,
    output logic         c_req,
    input  wire          c_ack,
    output logic [DW-1:0] c_pay,
    output logic         acc,               //!< one clock: the controller accepted a request
    output logic         acc_b              //!< with acc: it was B's
);
    logic fly = 1'b0;                       // a request is latched and not accepted yet
    logic own_b;                            // whose
    logic lvl;                              // the req level of the user when it was latched
    initial begin a_ack = 1'b0; b_ack = 1'b0; c_req = 1'b0; end
    wire  pa = a_req ^ a_ack;
    wire  pb = b_req ^ b_ack;
    assign acc   = fly && (c_ack == c_req);
    assign acc_b = own_b;
    always_ff @(posedge clk) begin
        if (acc) begin
            fly <= 1'b0;
            if (own_b) b_ack <= lvl; else a_ack <= lvl;
        end else if (!fly && (pa || pb)) begin
            fly   <= 1'b1;
            own_b <= !pa;
            lvl   <= pa ? a_req : b_req;
            c_pay <= pa ? a_pay : b_pay;
            c_req <= ~c_req;
        end
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
