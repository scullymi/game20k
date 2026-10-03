// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // 1-bit net.
//! @file fb_pack.sv
//! @brief Frame buffer write path (game20k): core pixels to SDRAM words
//!
//! -----------------------------------------------------------------------------------------
//! Takes the core's pixels, packs four of them into one 32-bit word and pushes the words
//! through an asynchronous FIFO into the SDRAM domain, where the controller writes them out.
//! This module only writes. Reading is done by fb_read_rotated.sv (production, portrait) and
//! fb_read_flat.sv (unrotated, measurement builds only).
//!
//! Raster tracking
//! ---------------
//! Identical to the raster tracking in arcade_scaler.sv so that both paths see the same pixels:
//! CPP core clocks per pixel, sampled in phase 1 (Galaga, Pac-Man: 3), or with CPP 0 on the
//! core's own pixel enable pix_ce (1942). The bounds wr_x < W and wr_line < H are mandatory:
//! a glitch must never write into the neighbouring buffer.
//! The numbers below are for the 288 x 224 raster of Galaga and Pac-Man. W is a multiple
//! of 4 up to 508, H up to 255.
//!
//! Address
//! ----------------------
//!   word number  = { y[7:0], xw[6:0] },  xw = wr_x >> 2, xw 0..71, y 0..223
//!   byte address = { 5'b0, word number, 2'b00 }
//!   bank         = { 1'b0, wbuf }   -- a separate controller input, never taken from the address
//! 72 words per line, 224 lines, i.e. 16128 words per frame.
//!
//! Why the address travels through the FIFO
//! ----------------------------------------
//! The SDRAM side could derive it from a counter of its own. But then every FIFO dropout would
//! be invisible and would merely shift the picture. This way it shows: the SDRAM side counts
//! along anyway and compares. Costs 15 bits of FIFO width.
//!
//! Timing
//! ------
//! One word per 12 core clocks = 646.5 ns. The controller needs 6 clocks of 15.432 ns = 92.6 ns
//! per access. Margin is thus a factor of 7. The 8-entry FIFO is far oversized for that (eight
//! slots, seven usable) and is there for exactly that reason: it makes the path independent
//! of this calculation,
//! and its overflow flag proves it in operation instead of on paper.
//! -----------------------------------------------------------------------------------------

module fb_pack #(
    parameter int W = 288,               //!< visible width of the core raster
    parameter int H = 224,               //!< visible height of the core raster
    parameter int CPP = 3                //!< core clocks per pixel, counted here; 0: take pix_ce
)(
    //! ---- core side ----
    input  wire         clk_core,
    input  wire  [2:0]  r_in,
    input  wire  [2:0]  g_in,
    input  wire  [1:0]  b_in,
    input  wire         pix_ce,          //!< pixel enable of the core, only with CPP 0
    input  wire         blankn,          //!< 1 = visible area
    input  wire         vs,              //!< vsync, active low

    //! ---- SDRAM side ----
    input  wire         clk_sdram,
    input  wire         sdram_ready,
    input  wire         clear,           //!< button S1 raw, clears the sticky flags
    output logic [21:0] wr_addr,
    output logic [31:0] wr_din,
    output logic [1:0]  wr_bank,
    output logic        wr_req,
    input  wire         wr_ack,

    //! ---- status, all in clk_sdram ----
    output logic        wbuf,            //!< buffer currently being written
    output logic        frame_done,      //!< one clock when a frame has been written completely
    output logic [1:0]  done_bank,       //!< bank of the frame just finished
    output logic [15:0] done_words,      //!< word count of that frame, should be H * W / 4
    output logic [31:0] done_sum,        //!< checksum of that frame
    output logic [15:0] done_nz,         //!< words not equal to 0 in that frame
    output logic        err_overflow,    //!< FIFO overflowed (sticky)
    output logic        err_addr         //!< FIFO address did not match the counter (sticky)
);
    localparam int WORDS_PER_FRAME = H * W / 4;   // 16128 for 288 x 224

    // =========================================================================================
    // Core side: raster tracking and word packing
    // =========================================================================================
    logic        blankn_d = 0, vs_d = 0;
    logic [7:0]  wr_line = 8'hFF;
    logic [1:0]  ph = 0;
    logic [8:0]  wr_x = 0;
    logic [23:0] acc = 0;                // the three pixels collected so far

    // FIFO entry
    logic [2:0]  rdy_c = 0;              // sdram_ready in clk_core
    // Start only at a frame boundary. sdram_ready arrives 200 us after power-up and thus
    // somewhere inside a frame; if word packing started there, the first word would carry an
    // address from mid-frame and the cross-check would report an error that does not exist.
    // wr_line is 8'hFF only during vertical blanking, and only then does the next visible
    // line yield wr_line = 0.
    logic        armed = 0;
    logic        f_push;
    logic [31:0] f_data;
    logic [14:0] f_word;                 // { y[7:0], xw[6:0] }
    logic        f_first;                // first word of a frame

    always_ff @(posedge clk_core) begin
        rdy_c    <= {rdy_c[1:0], sdram_ready};
        blankn_d <= blankn;
        vs_d     <= vs;
        f_push   <= 1'b0;

        if (!rdy_c[2]) armed <= 1'b0;               // re-arm after a dropout
        if (vs && !vs_d) begin
            wr_line <= 8'hFF;                       // end of the vsync pulse, as in the scaler
            if (rdy_c[2]) armed <= 1'b1;
        end

        if (blankn && !blankn_d) begin              // start of a visible line
            wr_line <= wr_line + 8'd1;
            ph      <= 2'd0;
            wr_x    <= 9'd0;
        end else if (blankn) begin
            if (CPP == 0) begin
                // the core's own enable: the pixel is still stable in the clock of the enable
                if (pix_ce) begin
                    wr_x <= wr_x + 9'd1;
                    if (wr_x < 9'(W) && wr_line < 8'(H) && armed) begin
                        if (wr_x[1:0] == 2'd3) begin
                            f_data  <= {{r_in, g_in, b_in}, acc};
                            f_word  <= {wr_line, wr_x[8:2]};
                            f_first <= (wr_line == 8'd0) && (wr_x[8:2] == 7'd0);
                            f_push  <= 1'b1;
                        end else
                            acc <= {{r_in, g_in, b_in}, acc[23:8]};
                    end
                end
            end else begin
                if (ph == 2'(CPP - 1)) begin
                    ph   <= 2'd0;
                    wr_x <= wr_x + 9'd1;
                end else
                    ph <= ph + 2'd1;

                // sample the pixel (phase 1, as in the scaler), only inside the frame
                if (ph == 2'd1 && wr_x < 9'(W) && wr_line < 8'(H) && armed) begin
                    if (wr_x[1:0] == 2'd3) begin
                        // Fourth byte: the word is full. Order: the first pixel of the group of
                        // four sits in the lowest 8 bits.
                        f_data  <= {{r_in, g_in, b_in}, acc};
                        f_word  <= {wr_line, wr_x[8:2]};
                        f_first <= (wr_line == 8'd0) && (wr_x[8:2] == 7'd0);
                        f_push  <= 1'b1;
                    end else
                        acc <= {{r_in, g_in, b_in}, acc[23:8]};
                end
            end
        end
    end

    // =========================================================================================
    // Asynchronous FIFO, eight slots, seven usable. The full condition compares the NEXT
    // write pointer, so it blocks already at an occupancy of seven; with a margin of factor 7
    // that does not matter. Gray-code pointers, storage as a register array (48 bits x 8).
    // =========================================================================================
    localparam int AW = 3;               // eight slots
    logic [47:0] fifo_mem [0:7];
    logic [AW:0] wptr_bin = 0, wptr_gray = 0;
    logic [AW:0] rptr_bin = 0, rptr_gray = 0;
    logic [AW:0] wptr_g_s0 = 0, wptr_g_s1 = 0;   // in clk_sdram
    logic [AW:0] rptr_g_s0 = 0, rptr_g_s1 = 0;   // in clk_core

    function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // ---- write side (clk_core) ----
    wire [AW:0] wptr_next = wptr_bin + {{AW{1'b0}}, 1'b1};
    // full when the next write pointer equals the read pointer with its top two bits inverted
    wire        fifo_full = (bin2gray(wptr_next) ==
                             {~rptr_g_s1[AW:AW-1], rptr_g_s1[AW-2:0]});
    logic       ovf_core = 0;

    always_ff @(posedge clk_core) begin
        rptr_g_s0 <= rptr_gray;
        rptr_g_s1 <= rptr_g_s0;
        // The read side resets its pointer on !sdram_ready. Without the same here, the two
        // would disagree after a second start-up (PLL dropout), and the read side would push
        // up to seven stale words into the SDRAM.
        if (!rdy_c[2]) begin
            wptr_bin  <= '0;
            wptr_gray <= '0;
            ovf_core  <= 1'b0;
        end else if (f_push) begin
            if (fifo_full)
                ovf_core <= 1'b1;                   // sticky, never cleared
            else begin
                fifo_mem[wptr_bin[AW-1:0]] <= {f_first, f_word, f_data};
                wptr_bin  <= wptr_next;
                wptr_gray <= bin2gray(wptr_next);
            end
        end
    end

    // ---- read side (clk_sdram) ----
    wire        fifo_empty = (rptr_gray == wptr_g_s1);
    wire [47:0] fifo_out   = fifo_mem[rptr_bin[AW-1:0]];
    wire [31:0] e_data     = fifo_out[31:0];
    wire [14:0] e_word     = fifo_out[46:32];
    wire        e_first    = fifo_out[47];

    // =========================================================================================
    // SDRAM side: one word per request, counter and checksum
    // =========================================================================================
    logic [15:0] cnt;                    // words in the current frame, 0..16127
    logic [31:0] sum;                    // checksum of the current frame
    logic        busy;                   // a request is in flight
    logic [2:0]  ovf_s = 0;              // overflow flag synchronised
    logic [1:0]  clr_s = 0;
    logic        clr_d = 0;
    logic        ovf_clr = 0;           // masks an overflow that was already reported
    wire         clr_pulse = clr_s[1] & ~clr_d;
    logic        started;                // first e_first seen, before that there is no frame
    // Expected word number, tracked like on the core side. NOT to be computed from cnt:
    // the word number is y*128+xw (128 slots are reserved per line, 72 are used), but the
    // counter runs y*72+xw.
    logic [7:0]  exp_y;
    logic [6:0]  exp_xw;
    // A black frame has checksum 0, and a dead read path on an idle bus delivers zeros as
    // well. Both would be indistinguishably green. So the writer counts how many words had
    // any content at all; if that count stays at 0, a green result says nothing.
    logic [15:0] nz;

    // The checksum rotates before adding so that the order matters. Plain summing would
    // not notice swapped words.
    function automatic logic [31:0] chk(input logic [31:0] s, input logic [31:0] d);
        chk = {s[30:0], s[31]} + d;
    endfunction

    always_ff @(posedge clk_sdram) begin
        wptr_g_s0 <= wptr_gray;
        wptr_g_s1 <= wptr_g_s0;
        ovf_s     <= {ovf_s[1:0], ovf_core};
        clr_s     <= {clr_s[0], clear};
        clr_d     <= clr_s[1];

        frame_done <= 1'b0;

        if (!sdram_ready) begin
            rptr_bin  <= '0;
            rptr_gray <= '0;
            cnt       <= 16'd0;
            sum       <= 32'd0;
            busy      <= 1'b0;
            wbuf      <= 1'b0;
            wr_req    <= 1'b0;
            err_addr  <= 1'b0;
            started   <= 1'b0;
            exp_y     <= 8'd0;
            exp_xw    <= 7'd0;
            nz        <= 16'd0;
        end else begin
            if (!busy && !fifo_empty) begin
                // Frame change: the previous frame's counter is latched here, the buffer
                // flips, and the first word already goes into the new buffer.
                if (e_first) begin
                    // The first frame after power-up starts mid-frame (the core is already
                    // running while the SDRAM is still initialising), so it is not
                    // reported.
                    frame_done <= started;
                    done_bank  <= {1'b0, wbuf};
                    done_words <= cnt;
                    done_sum   <= sum;
                    started    <= 1'b1;
                    done_nz    <= nz;
                    nz         <= (e_data != 32'd0) ? 16'd1 : 16'd0;
                    wbuf       <= ~wbuf;
                    cnt        <= 16'd1;
                    sum        <= chk(32'd0, e_data);
                    exp_y      <= 8'd0;
                    exp_xw     <= 7'd1;
                    // Checks the FIFO against itself, NOT the raster position: e_first and
                    // e_word are formed in the same clock from the same registers, so e_first
                    // holds exactly when e_word is 0. Unequal would mean: the 48 bits got
                    // scrambled on the way.
                    if (e_word != 15'd0) err_addr <= 1'b1;
                end else begin
                    cnt <= cnt + 16'd1;
                    sum <= chk(sum, e_data);
                    if (e_data != 32'd0 && nz != 16'hFFFF) nz <= nz + 16'd1;
                    // Cross-check: the word number from the FIFO must match our own tracking.
                    // Without it a lost word would be invisible: the picture would merely be
                    // shifted, exactly what one then hunts for days in the read path.
                    if (started && e_word != {exp_y, exp_xw}) err_addr <= 1'b1;
                    if (exp_xw == 7'(W / 4 - 1)) begin
                        exp_xw <= 7'd0;
                        exp_y  <= exp_y + 8'd1;
                    end else
                        exp_xw <= exp_xw + 7'd1;
                end

                wr_addr <= {5'b0, e_word, 2'b00};
                wr_din  <= e_data;
                wr_bank <= {1'b0, e_first ? ~wbuf : wbuf};
                wr_req  <= ~wr_req;
                busy    <= 1'b1;
            end else if (busy && (wr_req == wr_ack)) begin
                busy      <= 1'b0;
                rptr_bin  <= rptr_bin + 1'b1;
                rptr_gray <= bin2gray(rptr_bin + 1'b1);
            end

            // Clear on S1. After a game reset the core restarts mid-frame, which breaks the
            // word sequence. Without clearing, every measurement series would be worthless
            // after the first button press. started drops too, so the partial frame is
            // discarded. Sits at the end so it wins over the rest.
            if (clr_pulse) begin
                err_addr <= 1'b0;
                started  <= 1'b0;
                ovf_clr  <= ovf_s[2];   // ovf_core lives in clk_core, masking suffices here
            end else if (!ovf_s[2])
                ovf_clr <= 1'b0;        // drops again on the next real overflow
        end
    end

    assign err_overflow = ovf_s[2] & ~ovf_clr;

endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
