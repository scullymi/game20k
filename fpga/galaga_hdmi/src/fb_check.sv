// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // 1-bit net.
//! @file fb_check.sv
//! @brief Cross-check of the frame buffer write path by read-back (game20k)
//!
//! -----------------------------------------------------------------------------------------
//! As soon as fb_pack has finished writing a frame, this module reads the same frame back
//! through the controller's read channel and computes the same checksum. If it matches the
//! writer's, the whole path is proven: raster tracking, word packing, FIFO, address
//! calculation, bank selection, and the round trip through the SDRAM.
//!
//! Why read back instead of just counting: a bare word count proves that something was
//! written, not that the right thing sits at the right place. The checksum rotates before
//! adding, so it notices swapped words too.
//!
//! Timing is comfortable: 16128 words at 6 clocks each are 1.49 ms, a frame lasts 16.4 ms.
//! The reader works on the buffer just finished, the writer on the other one, i.e. on
//! different banks, just as in the display path.
//!
//! Display (720p raster), four rows of 16 fields, most significant bit on the left:
//!   row 0  word count of the last frame. Should be 16128 = 0011 1111 0000 0000
//!   row 1  number of frames checked (saturating), must keep running
//!   row 2  frames with wrong word count,  must stay dark
//!   row 3  frames with wrong checksum,    must stay dark
//!   below, five fields: FIFO overflow, address error, frame arrived during a running check,
//!                       overall verdict, frame content
//!
//! What the cross-check does NOT prove: the memory layout. Writer and reader form the address
//! by the same rule. If y and xw were swapped, both would write and read consistently wrong.
//! That only shows when the frame is displayed. The address calculation in
//! fb_read_flat.sv must therefore be derived afresh from the address rule and not copied from
//! fb_pack.sv.
//! -----------------------------------------------------------------------------------------

module fb_check (
    input  wire         clk_sdram,
    input  wire         sdram_ready,

    //! from fb_pack
    input  wire         frame_done,
    input  wire  [1:0]  done_bank,
    input  wire  [15:0] done_words,
    input  wire  [31:0] done_sum,
    input  wire         err_overflow,
    input  wire         err_addr,
    input  wire  [15:0] done_nz,         //!< words with content, see below
    input  wire         clear,           //!< button S1 raw

    //! controller read channel
    output logic [21:0] rd_addr,
    output logic [1:0]  rd_bank,
    output logic        rd_req,
    input  wire         rd_ack,
    input  wire  [31:0] rd_dout,
    input  wire         rd_valid,

    //! display
    input  wire         clk_pixel,
    input  wire  [10:0] cx,
    input  wire  [9:0]  cy,
    output logic        bar_on,
    output logic [23:0] bar_color,
    output logic [5:0]  leds
);
    localparam int WORDS = 16128;

    function automatic logic [31:0] chk(input logic [31:0] s, input logic [31:0] d);
        chk = {s[30:0], s[31]} + d;      // identical to fb_pack
    endfunction

    // ---------------- read-back ----------------
    logic        busy;                   // a frame is being checked
    logic        pend;                   // a read request is in flight
    logic [7:0]  r_y;
    logic [6:0]  r_xw;
    logic [15:0] got;                    // words read back
    logic [31:0] rsum;
    logic [31:0] exp_sum;
    logic [15:0] exp_words;
    logic [1:0]  r_bank;
    logic [24:0] wd;                     // watchdog, 2^25 clocks = 518 ms

    logic [15:0] n_checked, n_badwords, n_badsum, last_words, last_nz;
    logic        missed;                 // a frame arrived while one was still being checked
    logic [21:0] hb;                     // heartbeat, counts only on progress
    logic [1:0]  clr_s = 0;
    logic        clr_d = 0;
    wire         clr_pulse = clr_s[1] & ~clr_d;

    assign rd_addr = {5'b0, r_y, r_xw, 2'b00};
    assign rd_bank = r_bank;

    always_ff @(posedge clk_sdram) begin
        clr_s <= {clr_s[0], clear};
        clr_d <= clr_s[1];

        if (!sdram_ready) begin
            busy <= 1'b0; pend <= 1'b0; rd_req <= 1'b0;
            r_y  <= 8'd0; r_xw <= 7'd0; got <= 16'd0; rsum <= 32'd0;
            n_checked <= 16'd0; n_badwords <= 16'd0; n_badsum <= 16'd0;
            last_words <= 16'd0; last_nz <= 16'd0; missed <= 1'b0; wd <= 25'd0;
            hb <= 22'd0;
        end else begin
            if (frame_done) begin
                last_words <= done_words;
                last_nz    <= done_nz;
                if (done_words != WORDS[15:0] && n_badwords != 16'hFFFF)
                    n_badwords <= n_badwords + 16'd1;
                if (busy)
                    missed <= 1'b1;      // should never happen, 1.49 ms vs 16.4 ms
                else begin
                    busy    <= 1'b1;
                    pend    <= 1'b0;     // otherwise the reader starts at word 1 instead of 0
                    r_bank  <= done_bank;
                    exp_sum <= done_sum;
                    exp_words <= done_words;
                    r_y     <= 8'd0;
                    r_xw    <= 7'd0;
                    got     <= 16'd0;
                    rsum    <= 32'd0;
                    wd      <= 25'd0;
                end
            end

            if (busy) begin
                // issue requests until all of them are out
                if (!pend && ({r_y, r_xw} != {8'd224, 7'd0})) begin
                    rd_req <= ~rd_req;
                    pend   <= 1'b1;
                end else if (pend && (rd_req == rd_ack)) begin
                    pend <= 1'b0;
                    if (r_xw == 7'd71) begin
                        r_xw <= 7'd0;
                        r_y  <= r_y + 8'd1;
                    end else
                        r_xw <= r_xw + 7'd1;
                end

                // collect the replies
                if (rd_valid) begin
                    rsum <= chk(rsum, rd_dout);
                    got  <= got + 16'd1;
                    wd   <= 25'd0;
                    hb   <= hb + 22'd1;  // about 16128 per frame, gives a good 2 Hz on LED6
                    if (got == WORDS[15:0] - 16'd1) begin
                        busy <= 1'b0;
                        if (n_checked != 16'hFFFF) n_checked <= n_checked + 16'd1;
                        // The last value is still pending in rsum, so it is added in here.
                        if ((chk(rsum, rd_dout) != exp_sum || exp_words != WORDS[15:0])
                            && n_badsum != 16'hFFFF)
                            n_badsum <= n_badsum + 16'd1;
                    end
                end else begin
                    wd <= wd + 25'd1;
                    if (wd == {25{1'b1}}) begin      // no more data arriving
                        busy <= 1'b0;
                        pend <= 1'b0;
                        if (n_badsum != 16'hFFFF) n_badsum <= n_badsum + 16'd1;
                    end
                end
            end

            // Clear on S1, sits at the end and thus wins over the rest.
            if (clr_pulse) begin
                n_checked <= 16'd0; n_badwords <= 16'd0; n_badsum <= 16'd0;
                missed    <= 1'b0;  last_words <= 16'd0; last_nz  <= 16'd0;
                busy      <= 1'b0;  pend       <= 1'b0;
            end
        end
    end

    // LED1..4 = low bits of the frames-checked count, LED5 = any error, LED6 = heartbeat
    wire any_err = (n_badwords != 16'd0) || (n_badsum != 16'd0) || err_overflow
                   || err_addr || missed;
    // LED6 from the progress, not from the frame counter: n_checked toggles at 30 Hz and
    // then looks half-bright whether the test is running or stalled.
    assign leds = {hb[21], any_err, n_checked[3:0]};

    // =========================================================================================
    // Display, three stages as in the self-test (the pixel clock is the tightest domain)
    // =========================================================================================
    logic [15:0] v0_a = 0, v0 = 0, v1_a = 0, v1 = 0, v2_a = 0, v2 = 0, v3_a = 0, v3 = 0;
    logic [3:0] st_a = 0, st_b = 0;
    logic [1:0] ct_a = 0, ct_b = 0;      // frame content: 0 empty, 1 little, 2 plenty
    always_ff @(posedge clk_pixel) begin
        v0_a <= last_words;  v1_a <= n_checked;
        v2_a <= n_badwords;  v3_a <= n_badsum;
        st_a <= {err_overflow, err_addr, missed, any_err};
        // Threshold deliberately low: the field is to answer "was there anything in the frame
        // at all", not "was there a lot". In attract mode the frame consists of stars, and
        // depending on the moment a few hundred to over a thousand words have content.
        ct_a <= (last_nz == 16'd0)   ? 2'd0 :
                (last_nz < 16'd100)  ? 2'd1 : 2'd2;
        // The second stage only latches outside the display window. A displayed number then
        // stands for a whole frame and is consistent in itself.
        if (cy == 10'd0) begin
            v0 <= v0_a; v1 <= v1_a; v2 <= v2_a; v3 <= v3_a;
            st_b <= st_a; ct_b <= ct_a;
        end
    end

    logic [10:0] q_xb = 0;
    logic        q_inx = 0, q_bgx = 0, q_rbg = 0, q_rsta = 0;
    logic [2:0]  q_row = 3'd4;
    always_ff @(posedge clk_pixel) begin
        q_xb   <= cx - 11'd128;
        q_inx  <= (cx >= 11'd128) && (cx < 11'd1152);
        q_bgx  <= (cx >= 11'd112) && (cx < 11'd1168);
        q_rbg  <= (cy >= 10'd240) && (cy < 10'd470);
        q_rsta <= (cy >= 10'd430) && (cy < 10'd462);
        q_row  <= (cy >= 10'd250 && cy < 10'd286) ? 3'd0 :
                  (cy >= 10'd294 && cy < 10'd330) ? 3'd1 :
                  (cy >= 10'd338 && cy < 10'd374) ? 3'd2 :
                  (cy >= 10'd382 && cy < 10'd418) ? 3'd3 : 3'd4;
    end

    logic [3:0] fi;
    logic [5:0] xin;
    assign fi  = q_xb[9:6];
    assign xin = q_xb[5:0];

    logic       r_bg = 0, r_fld = 0, r_bit = 0, r_sta = 0;
    logic [1:0] r_which = 0;
    logic [2:0] r_stidx = 0;
    logic [3:0] r_stv = 0;
    logic [1:0] r_ct = 0;
    always_ff @(posedge clk_pixel) begin
        r_bg    <= q_bgx & q_rbg;
        r_fld   <= q_inx & (q_row != 3'd4) & (xin < 6'd56);
        r_which <= q_row[1:0];
        // most significant bit on the left: field 0 shows bit 15
        case (q_row[1:0])
            2'd0: r_bit <= v0[4'd15 - fi];
            2'd1: r_bit <= v1[4'd15 - fi];
            2'd2: r_bit <= v2[4'd15 - fi];
            default: r_bit <= v3[4'd15 - fi];
        endcase
        r_sta   <= q_inx & q_rsta & (xin < 6'd56) & (fi < 4'd5);
        r_stidx <= fi[2:0];
        r_stv   <= st_b;
        r_ct    <= ct_b;
    end

    logic [23:0] colf, cols;
    always_comb begin
        // Rows 0 and 1 are numbers (white/dark), rows 2 and 3 are error counters:
        // there a set digit is red so it cannot be overlooked.
        if (r_which[1] && r_bit) colf = 24'hC00000;
        else if (r_bit)          colf = 24'hFFFFFF;
        else                     colf = 24'h303030;
        // Fields 0..3 are error indicators (green = good), field 4 shows whether the frame had
        // any content at all: grey means "black frame, the verdict next to it says nothing".
        case (r_stidx)
            3'd0:    cols = r_stv[3] ? 24'hC00000 : 24'h00B000;   // FIFO overflow
            3'd1:    cols = r_stv[2] ? 24'hC00000 : 24'h00B000;   // address error
            3'd2:    cols = r_stv[1] ? 24'hC00000 : 24'h00B000;   // frame during check
            3'd3:    cols = r_stv[0] ? 24'hC00000 : 24'h00B000;   // overall verdict
            default: cols = (r_ct == 2'd0) ? 24'h505050 :
                            (r_ct == 2'd1) ? 24'hC0C000 : 24'h00B000;
        endcase
    end

    always_ff @(posedge clk_pixel) begin
        bar_on <= r_bg | r_fld | r_sta;
        if      (r_sta) bar_color <= cols;
        else if (r_fld) bar_color <= colf;
        else            bar_color <= 24'h000000;
    end

endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
