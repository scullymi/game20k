// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // 1-bit net.
//! @file fb_read_rotated.sv
//! @brief Frame buffer read path, rotated 90 degrees (game20k).
//!
//! This is the production read path (portrait mode). fb_read_flat.sv is the unrotated
//! twin, only built for measurements.
//!
//! Rotates the picture 90 degrees clockwise and outputs it at twice the size:
//! 448 x 576 from X0 416, Y0 72. Structure and handshake are deliberately
//! the same as in the proven unrotated fb_read_flat.sv; the only new part is WHAT is
//! fetched and how it is stored.
//!
//! The mapping
//! -----------
//!   Source:  xc 0..287 (column), yc 0..223 (row)
//!   Clockwise rotation:  xo = 223 - yc,  yo = xc      (MAME ROT90)
//!   Inverse:             xc = yo,        yc = 223 - xo
//! The rotated picture is thus 224 wide and 288 high. Check: source column 0 is "top" in
//! the game and lands at yo = 0, i.e. at the top. If the score shows at the bottom, the
//! rotation direction is wrong, and ROT_CCW reverses it.
//!
//! Why four output rows are fetched at once
//! ----------------------------------------
//! One output row yo needs source column xc = yo, i.e. one byte from each of the 224 source
//! rows; in memory that is 224 different words. But one word holds four adjacent source
//! columns, i.e. four output rows at once. Hence the work is done in groups of four
//! output rows:
//!
//!   Group k covers output rows 4k..4k+3.
//!   Fetch:   for y = 0..223 the word { y[7:0], k[6:0] } from the read bank,
//!            store the four bytes at { fill, (223-y)[7:0], lane[1:0] }
//!   Output:  row yo = 4k+j reads for xo = 0..223 from { show, xo[7:0], j[1:0] }
//!
//! The byte with lane L is source column 4k+L (fb_pack puts the first pixel of a group of
//! four into the lowest 8 bits), i.e. exactly output row 4k+L. The transpose buffer is a
//! plain block RAM 2048 x 8, of which 2 x 896 entries are used.
//!
//! Timing
//! ------
//! One group stays on screen 4 output rows x 2 (vertical doubling) = 8 HDMI lines = 170.7 us.
//! Fetching costs 224 accesses x 92.6 ns = 20.7 us, a factor 8 of margin.
//! Group 0 is requested at cy 760; up to the first visible line at cy 72 that is
//! about 1.7 ms.
//!
//! Double buffering as in fb_read_flat.sv: the buffer just FINISHED writing is read,
//! i.e. rbuf = wbuf, because wbuf flips at the FIRST word of a frame and not at the end.
//! -----------------------------------------------------------------------------------------

module fb_read_rotated #(
    parameter int X0 = 416,              //!< (1280 - 448) / 2
    parameter int Y0 = 72,               //!< (720 - 576) / 2
    parameter bit ROT_CCW = 0            //!< 1: counter-clockwise (if it is the wrong way round)
)(
    //! ---- SDRAM side ----
    input  wire         clk_sdram,
    input  wire         sdram_ready,
    input  wire         wbuf,
    input  wire         frame_done,
    output logic [21:0] rd_addr,
    output logic [1:0]  rd_bank,
    output logic        rd_req,
    input  wire         rd_ack,
    input  wire  [31:0] rd_dout,
    input  wire         rd_valid,
    output logic        err_late,        //!< a group was not ready in time (sticky)

    //! ---- Pixel side ----
    input  wire         clk_pixel,
    input  wire  [10:0] cx,
    input  wire  [9:0]  cy,
    output logic [23:0] rgb,
    output logic        active,          //!< held per frame: output running. Only for LED1
    input  wire         clear
);
    // ---- Transpose buffer, 2048 x 8, two clocks ----
    logic [7:0] tbuf [0:2047];
    logic [10:0] tb_waddr;
    logic [7:0]  tb_wdata;
    logic        tb_we;
    always_ff @(posedge clk_sdram) if (tb_we) tbuf[tb_waddr] <= tb_wdata;

    // =========================================================================================
    // Pixel side
    // =========================================================================================
    logic [8:0] yo = 0;                  // output row 0..287
    logic       vph = 0;                 // vertical doubling
    logic       hph = 0;                 // horizontal doubling
    logic [7:0] xo = 0;                  // 0..223
    logic       act_y = 0, act_x = 0, act_x_d1 = 0;
    logic       rbuf_p = 0;
    logic [2:0] wbuf_s = 0, rdy_p = 0, fd_s = 0;
    logic [1:0] nfr_p = 0;
    logic [7:0] q;

    logic       req_tgl = 0;
    logic [6:0] req_grp = 0;             // group 0..71
    logic       req_buf = 0;

    wire [6:0] grp = yo[8:2];            // tied to the output counter, does not free-run
    wire [1:0] lane_o = yo[1:0];

    always_ff @(posedge clk_pixel) begin
        wbuf_s <= {wbuf_s[1:0], wbuf};
        rdy_p  <= {rdy_p[1:0], sdram_ready};
        fd_s   <= {fd_s[1:0], frame_done};
        if (fd_s[2] == 1'b0 && fd_s[1] == 1'b1 && nfr_p != 2'd2) nfr_p <= nfr_p + 2'd1;
        if (!rdy_p[2]) nfr_p <= 2'd0;

        if (cx == 11'd0) begin
            if (cy == 10'd760) begin
                // Blanking interval: take over the buffer, request group 0. rbuf = wbuf, see
                // header. The writer starts the next buffer only at cy 20 of the following
                // frame; until then the write channel is idle.
                rbuf_p  <= wbuf_s[2];
                active  <= (nfr_p == 2'd2) && rdy_p[2];
                req_grp <= 7'd0;
                req_buf <= wbuf_s[2];
                req_tgl <= ~req_tgl;
            end else if (cy == Y0[9:0]) begin
                yo    <= 9'd0;
                vph   <= 1'b0;
                act_y <= 1'b1;
                req_grp <= 7'd1;                  // group 1 into the other half
                req_buf <= rbuf_p;
                req_tgl <= ~req_tgl;
            end else if (cy < Y0[9:0]) begin
                // After a core reset cy jumps to 20 in mid-frame (sync pulse). Without
                // this line act_y would stay set: a stripe above the picture, prefetches
                // still running, and at cy 72 the restart branch reports a delay that
                // is none. In undisturbed operation act_y is 0 here anyway, so the line
                // changes nothing there.
                act_y <= 1'b0;
            end else if (act_y) begin
                if (vph == 1'b1) begin
                    vph <= 1'b0;
                    if (yo == 9'd287) act_y <= 1'b0;
                    else begin
                        yo <= yo + 9'd1;
                        // On entering a new group, request the one after next.
                        // (grp+2)[0] is the opposite of (grp+1)[0], i.e. the half that
                        // is being freed.
                        if (yo[1:0] == 2'd3 && (grp + 7'd2) <= 7'd71) begin
                            req_grp <= grp + 7'd2;
                            req_buf <= rbuf_p;
                            req_tgl <= ~req_tgl;
                        end
                    end
                end else
                    vph <= 1'b1;
            end
        end

        if (cx == X0[10:0] - 11'd2) begin
            hph   <= 1'b0;
            xo    <= 8'd0;
            act_x <= act_y;
        end else if (act_x) begin
            if (hph == 1'b1) begin
                hph <= 1'b0;
                xo  <= xo + 8'd1;
                if (xo == 8'd223) act_x <= 1'b0;
            end else
                hph <= 1'b1;
        end

        q        <= tbuf[{grp[0], xo, lane_o}];
        act_x_d1 <= act_x;
        rgb <= (act_x_d1 && nfr_p == 2'd2 && rdy_p[2])
             ? {q[7:5], q[7:5], q[7:6],
                q[4:2], q[4:2], q[4:3],
                q[1:0], q[1:0], q[1:0], q[1:0]} : 24'h000000;
    end

    // =========================================================================================
    // SDRAM side: fetch one group, i.e. 224 words
    // =========================================================================================
    logic [2:0]  req_s = 0;
    logic        req_d = 0;
    logic [6:0]  s_grp;
    logic        s_buf;
    logic        busy, pend;
    logic [7:0]  s_y;                    // requested source row 0..224
    logic [7:0]  g_y;                    // arrived source row
    logic [1:0]  g_lane;
    logic [31:0] g_word;
    // 65536 clocks = 1.011 ms. Not a deadline monitor: a group is due every 170.7 us,
    // and the restart branch further down reports that. The watchdog is the emergency
    // exit for a fetch stuck in the long gaps (cy 632..760 and cy 760..72).
    logic [15:0] wdog;
    logic [1:0]  clr_s = 0;
    logic        clr_d = 0;
    wire         clr_pulse = clr_s[1] & ~clr_d;
    wire         restart = (req_s[2] != req_d);

    // Counter-clockwise, xo = yc and yo = 287 - xc hold; output row 4k+j then needs
    // source column 287-4k-j = 4*(71-k) + (3-j), i.e. the mirrored word column.
    // The BUFFER HALF stays s_grp[0], because the reader takes the half of the DISPLAYED
    // group and 71-k would have the opposite parity.
    wire [6:0] s_word = ROT_CCW ? (7'd71 - s_grp) : s_grp;
    assign rd_addr = {5'b0, s_y, s_word, 2'b00};
    assign rd_bank = {1'b0, s_buf};

    // Store location: row y becomes xo = 223 - y, byte lane becomes j = lane.
    wire [7:0] put_xo   = ROT_CCW ? g_y : (8'd223 - g_y);
    wire [1:0] put_lane = ROT_CCW ? (2'd3 - g_lane) : g_lane;

    always_ff @(posedge clk_sdram) begin
        req_s <= {req_s[1:0], req_tgl};
        req_d <= req_s[2];
        clr_s <= {clr_s[0], clear};
        clr_d <= clr_s[1];
        tb_we <= 1'b0;

        if (!sdram_ready) begin
            busy <= 1'b0; pend <= 1'b0; rd_req <= 1'b0;
            s_y <= 8'd0; g_y <= 8'd0; g_lane <= 2'd0; err_late <= 1'b0; wdog <= 16'd0;
            s_grp <= 7'd0; s_buf <= 1'b0;
        end else begin
            if (restart) begin
                // If the previous group did not get through, that is a finding: 20.7 us
                // against 170.7 us must never get tight.
                if (busy) err_late <= 1'b1;
                s_grp  <= req_grp;
                s_buf  <= req_buf;
                s_y    <= 8'd0;
                g_y    <= 8'd0;
                g_lane <= 2'd0;
                busy   <= 1'b1;
                pend   <= 1'b0;
                wdog   <= 16'd0;
            end

            if (busy && !restart) begin
                if (!pend && s_y != 8'd224) begin
                    rd_req <= ~rd_req;
                    pend   <= 1'b1;
                end else if (pend && (rd_req == rd_ack)) begin
                    pend <= 1'b0;
                    s_y  <= s_y + 8'd1;
                end

                // Serializing the four bytes takes 4 clocks. This works out because the
                // free-running 6-clock ring gives the read channel exactly one access per
                // round, so two responses are never closer than 6 clocks apart (sdram_fb.v,
                // BankActivate in cycle[1], Read in cycle[3]). Whoever touches burst length,
                // CAS or clk_sdram must recompute this.
                if (rd_valid) begin
                    g_word   <= rd_dout;
                    g_lane   <= 2'd1;
                    tb_we    <= 1'b1;
                    tb_waddr <= {s_grp[0], put_xo, put_lane};
                    tb_wdata <= rd_dout[7:0];
                    wdog     <= 16'd0;
                end else if (g_lane != 2'd0) begin
                    tb_we    <= 1'b1;
                    tb_waddr <= {s_grp[0], put_xo, put_lane};
                    tb_wdata <= (g_lane == 2'd1) ? g_word[15:8] :
                                (g_lane == 2'd2) ? g_word[23:16] : g_word[31:24];
                    if (g_lane == 2'd3) begin
                        g_lane <= 2'd0;
                        g_y    <= g_y + 8'd1;
                        if (g_y == 8'd223) busy <= 1'b0;      // group complete
                    end else
                        g_lane <= g_lane + 2'd1;
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
