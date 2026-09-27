// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // 1-bit net.
//! @file fb_read_flat.sv
//! @brief Frame buffer read path, NOT rotated (game20k).
//!
//! Only built for FBSHOW=1. The production read path is fb_read_rotated.sv.
//!
//! This module builds only the UNROTATED path: the picture comes from the SDRAM instead of
//! galaga_scaler.sv, but looks exactly the same (288 x 224 tripled to 864 x 672, X0 208,
//! Y0 24). It proves the whole path with the simple address pattern independently of the
//! rotation: a fault that fb_read_rotated.sv shows and this path does not is in the rotation.
//!
//! Structure
//! ---------
//! One source row is 72 words = 288 bytes. While one row is output three times
//! (3 x 21.3 us = 64 us), the SDRAM side fetches the next one (72 accesses x 92.6 ns = 6.7 us).
//! Two halves of a line buffer alternate; the half is simply ys[0].
//!
//!   Line buffer: 1024 x 8 in one block RAM, write clock clk_sdram, read clock clk_pixel
//!   Address:     { ys[0], xs[8:0] }   xs = 0..287
//!
//! The row counter does NOT free-run but is tied to the vertical counter of the output.
//! The scaler's sync pulse can make cx and cy jump to (0, 20) at any time;
//! a free-running counter would be permanently off by one row afterwards.
//!
//! Request across the clock domain crossing
//! ----------------------------------------
//! A toggle handshake: the pixel side flips req_tgl and places row number and buffer next
//! to it. Payload and toggle bit change in the SAME clock; the SDRAM side may therefore
//! read them only after the toggle bit has passed three synchronizer stages (req_s) and the
//! edge detector (req_d) fires, which is at least 46 ns. For this reason the chain must not
//! be shortened to two stages.
//!
//! Double buffering
//! ----------------
//! The buffer just FINISHED writing is read, i.e. rbuf = wbuf. This is because wbuf flips
//! at the FIRST word of a frame, not at the end (fb_pack.sv, e_first branch): at cy 760 the
//! frame is complete and wbuf still points to it. The writer starts the next buffer only at
//! cy 20 of the following frame, 28 output rows = 597 us later. Whoever takes ~wbuf here
//! reads the frame before last and gets overwritten while doing so.
//!
//! Black until two complete frames have been written: otherwise the screen shows the
//! SDRAM's power-on garbage at cold start, and that gets mistaken for a memory error.
//! -----------------------------------------------------------------------------------------

module fb_read_flat #(
    parameter int X0 = 208,              //!< as galaga_scaler
    parameter int Y0 = 24
)(
    //! ---- SDRAM side ----
    input  wire         clk_sdram,
    input  wire         sdram_ready,
    input  wire         wbuf,            //!< buffer fb_pack is currently writing to
    input  wire         frame_done,      //!< one frame written completely
    output logic [21:0] rd_addr,
    output logic [1:0]  rd_bank,
    output logic        rd_req,
    input  wire         rd_ack,
    input  wire  [31:0] rd_dout,
    input  wire         rd_valid,
    output logic        err_late,        //!< a row was not there in time (sticky)

    //! ---- Pixel side ----
    input  wire         clk_pixel,
    input  wire  [10:0] cx,
    input  wire  [9:0]  cy,
    output logic [23:0] rgb,
    output logic        active,          //!< held per frame: output running. Only for LED1
    input  wire         clear            //!< button S1 raw, clears err_late
);
    // =========================================================================================
    // Pixel side: raster position, requests, output
    // =========================================================================================
    // ---- Line buffer, 1024 x 8, two clocks ----
    logic [7:0] lbuf [0:1023];
    logic [9:0] lb_waddr;
    logic [7:0] lb_wdata;
    logic       lb_we;
    always_ff @(posedge clk_sdram) if (lb_we) lbuf[lb_waddr] <= lb_wdata;

    // The raster position is a literal copy of the read side of galaga_scaler.sv, so that the
    // picture stands pixel for pixel at the same place and has the same color. Only the
    // memory differs: instead of {rd_line[3:0], rd_x} from the ring buffer, here it is
    // { ys[0], xs } from the line buffer, which is filled from the SDRAM.
    logic [7:0] ys = 0;                  // current source row 0..223
    logic [1:0] row3 = 0;                // 0..2, threefold repetition
    logic [1:0] xph = 0;
    logic [8:0] xs = 0;                  // current source column 0..287
    logic       act_y = 0, act_x = 0, act_x_d1 = 0;
    logic       rbuf_p = 0;              // buffer being read from (pixel side)
    logic [2:0] wbuf_s = 0;
    logic [2:0] rdy_p = 0;
    logic [1:0] nfr_p = 0;               // completed frames, saturating at 2
    logic [2:0] fd_s = 0;
    logic [7:0] q;

    // Request to the SDRAM side
    logic       req_tgl = 0;
    logic [7:0] req_line = 0;
    logic       req_buf = 0;

    always_ff @(posedge clk_pixel) begin
        wbuf_s <= {wbuf_s[1:0], wbuf};
        rdy_p  <= {rdy_p[1:0], sdram_ready};
        fd_s   <= {fd_s[1:0], frame_done};
        if (fd_s[2] == 1'b0 && fd_s[1] == 1'b1 && nfr_p != 2'd2) nfr_p <= nfr_p + 2'd1;
        if (!rdy_p[2]) nfr_p <= 2'd0;   // like armed in fb_pack.sv: start over after a dropout

        if (cx == 11'd0) begin
            if (cy == 10'd760) begin
                // Blanking interval: take over the buffer and request row 0.
                // rbuf = wbuf, NOT ~wbuf. wbuf flips at the FIRST word of a frame, not at
                // the end; at cy 760 the frame is thus complete and wbuf still points to it.
                // The writer starts the next buffer only at cy 20 of the following frame,
                // 28 output rows = 597 us later. With ~wbuf one would read the frame before
                // last and get overwritten while doing so.
                //
                // From here to cy 20 the read and write banks are the SAME. This is allowed
                // because the write channel is demonstrably idle during this time: fb_pack
                // pushes nothing more after source row 223, and the FIFO is empty after at
                // most seven words (0.65 us). Without wr_pend, sdram_fb issues no bank
                // activation at all in cycle[0], so nothing can collide.
                // Whoever additionally switches the geometry at cy 760, as galaga_hdmi_top.sv
                // does with screen_p, must re-check this condition.
                rbuf_p   <= wbuf_s[2];
                active   <= (nfr_p == 2'd2) && rdy_p[2];   // held per frame, for LED1
                req_line <= 8'd0;
                req_buf  <= wbuf_s[2];
                req_tgl  <= ~req_tgl;
            end else if (cy == Y0[9:0]) begin
                ys    <= 8'd0;
                row3  <= 2'd0;
                act_y <= 1'b1;
                req_line <= 8'd1;        // next row into the other half
                req_buf  <= rbuf_p;
                req_tgl  <= ~req_tgl;
            end else if (cy < Y0[9:0]) begin
                // See fb_read_rotated.sv: after a core reset cy jumps to 20 in mid-frame.
                act_y <= 1'b0;
            end else if (act_y) begin
                if (row3 == 2'd2) begin
                    row3 <= 2'd0;
                    ys   <= ys + 8'd1;
                    if (ys == 8'd223) act_y <= 1'b0;
                    // While row ys+1 is shown, ys+2 goes into the half being freed.
                    // (ys+2)[0] is the opposite of (ys+1)[0].
                    else if (ys + 8'd2 <= 8'd223) begin
                        req_line <= ys + 8'd2;
                        req_buf  <= rbuf_p;
                        req_tgl  <= ~req_tgl;
                    end
                end else
                    row3 <= row3 + 2'd1;
            end
        end

        if (cx == X0[10:0] - 11'd2) begin
            xph   <= 2'd0;
            xs    <= 9'd0;
            act_x <= act_y;
        end else if (act_x) begin
            if (xph == 2'd2) begin
                xph <= 2'd0;
                xs  <= xs + 9'd1;
                if (xs == 9'd287) act_x <= 1'b0;
            end else
                xph <= xph + 2'd1;
        end

        q        <= lbuf[{ys[0], xs}];
        act_x_d1 <= act_x;
        // RGB332 -> RGB888, bit for bit as the conversion in galaga_scaler.sv.
        // Black until two complete frames are in memory.
        rgb <= (act_x_d1 && nfr_p == 2'd2 && rdy_p[2])
             ? {q[7:5], q[7:5], q[7:6],
                q[4:2], q[4:2], q[4:3],
                q[1:0], q[1:0], q[1:0], q[1:0]} : 24'h000000;
    end

    // =========================================================================================
    // SDRAM side: fetch one row
    // =========================================================================================
    logic [2:0] req_s = 0;               // req_tgl synchronized in
    logic       req_d = 0;
    logic [7:0] s_line;
    logic       s_buf;
    logic       busy;
    logic       pend;
    logic [6:0] s_xw;                    // requested word 0..71
    logic [6:0] g_xw;                    // arrived word
    logic [1:0] g_b;                     // byte within the word
    logic [31:0] g_word;
    logic [15:0] wdog;    // 1.01 ms; a row is due every 64 us
    logic [1:0] clr_s = 0;
    logic       clr_d = 0;
    wire        clr_pulse = clr_s[1] & ~clr_d;

    assign rd_addr = {5'b0, s_line, s_xw, 2'b00};
    assign rd_bank = {1'b0, s_buf};

    always_ff @(posedge clk_sdram) begin
        req_s <= {req_s[1:0], req_tgl};
        req_d <= req_s[2];
        clr_s <= {clr_s[0], clear};
        clr_d <= clr_s[1];
        lb_we <= 1'b0;

        if (!sdram_ready) begin
            busy <= 1'b0; pend <= 1'b0; rd_req <= 1'b0;
            s_xw <= 7'd0; g_xw <= 7'd0; g_b <= 2'd0; err_late <= 1'b0; wdog <= 16'd0;
            s_line <= 8'd0; s_buf <= 1'b0;
        end else begin
            if (req_s[2] != req_d) begin
                // New row. If the previous one did not get through in time, that is a
                // finding: 6.7 us against 64 us must never get tight.
                if (busy) err_late <= 1'b1;
                s_line <= req_line;
                s_buf  <= req_buf;
                s_xw   <= 7'd0;
                g_xw   <= 7'd0;
                g_b    <= 2'd0;
                busy   <= 1'b1;
                pend   <= 1'b0;
                wdog   <= 16'd0;
            end

            // The restart branch above and the work branch below are in the same block;
            // without this guard the lower one wins and overwrites the reset.
            if (busy && (req_s[2] == req_d)) begin
                if (!pend && s_xw != 7'd72) begin
                    rd_req <= ~rd_req;
                    pend   <= 1'b1;
                end else if (pend && (rd_req == rd_ack)) begin
                    pend <= 1'b0;
                    s_xw <= s_xw + 7'd1;
                end

                if (rd_valid) begin
                    g_word <= rd_dout;
                    g_b    <= 2'd1;                 // byte 0 in this clock, 1..3 in the next
                    lb_we    <= 1'b1;
                    lb_waddr <= {s_line[0], g_xw, 2'd0};
                    lb_wdata <= rd_dout[7:0];
                    wdog   <= 16'd0;
                end else if (g_b != 2'd0) begin
                    lb_we    <= 1'b1;
                    lb_waddr <= {s_line[0], g_xw, g_b};
                    lb_wdata <= (g_b == 2'd1) ? g_word[15:8] :
                                (g_b == 2'd2) ? g_word[23:16] : g_word[31:24];
                    if (g_b == 2'd3) begin
                        g_b  <= 2'd0;
                        g_xw <= g_xw + 7'd1;
                        if (g_xw == 7'd71) busy <= 1'b0;   // row complete
                    end else
                        g_b <= g_b + 2'd1;
                end else begin
                    wdog <= wdog + 16'd1;
                    if (wdog == {16{1'b1}}) begin
                        busy     <= 1'b0;
                        pend     <= 1'b0;
                        err_late <= 1'b1;
                    end
                end
            end

            if (clr_pulse) err_late <= 1'b0;
        end
    end

endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
