// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// Testbench for the frame lock of arcade_scaler.sv and hdmi.sv: a synthetic core raster writes
// its line number into every pixel (red the high, green the low nibble), the scaler takes it
// as game20k_top.sv sets it up, and the HDMI counters run as in hdmi.sv: free, except that
// the scaler's sync pulse sets cx to 0 and cy to SYNC_Y. Over four frames every lit pixel of
// an HDMI line of the picture must show the core line it belongs to, at least 3W - 3 of them
// (the model changes blankn in the same pixel enable as the first pixel, which the scaler
// takes as the start of the line and does not store), and no line outside the picture
// anything. Core clock and pixel enable as on the device (37.125 MHz, the pixel a
// fraction of it), the pixel clock exactly twice the core clock.
// Three cases: 1942's raster with SYNC_Y 20, Pang's with SYNC_Y = Y0_L - 4 + FRAME_H (812, as
// the top derives it), and, as a counter-check, Pang's with the former fixed 20, which must
// fail. Ends with PASS or $fatal.
`timescale 1ns/1ps
`default_nettype none

module sync_case #(
    parameter string NAME = "",
    parameter int W = 256, H = 224,        //!< visible raster
    parameter int HT = 384, VT = 262,      //!< total pixels per line, lines per frame
    parameter int NUM = 16, DEN = 99,      //!< pixel enable: NUM / DEN of the core clock
    parameter int FRAME_H = 786,
    parameter int SYNC_Y = 20
)(
    output logic done,
    output int   bad_rows,                 //!< picture lines with a wrong or missing pixel
    output int   stray                     //!< lit pixels outside the picture lines
);
    localparam int X0 = (1280 - 3 * W) / 2;
    localparam int Y0 = (720 - 3 * H) / 2;

    logic clk_pixel = 0, clk_core = 0;
    always #6.734 clk_pixel = ~clk_pixel;
    always @(posedge clk_pixel) clk_core <= ~clk_core;

    // ---- the core raster ----
    int   acc = 0, hc = 0, vc = 0;
    logic ce = 0;
    always @(posedge clk_core) begin
        ce <= 1'b0;
        if (acc + NUM >= DEN) begin
            acc <= acc + NUM - DEN;
            ce  <= 1'b1;
            if (hc == HT - 1) begin
                hc <= 0;
                vc <= (vc == VT - 1) ? 0 : vc + 1;
            end else
                hc <= hc + 1;
        end else
            acc <= acc + NUM;
    end
    wire       blankn = hc < W && vc < H;
    wire       vs     = !(vc >= H + 4 && vc < H + 7);
    wire [7:0] line   = 8'(vc);

    logic [10:0] cx = 0;
    logic [9:0]  cy = 0;
    logic        sync, pic;
    logic [23:0] rgb;
    arcade_scaler #(.W(W), .H(H), .X0(X0), .Y0(Y0), .CPP(0), .RGB444(1)) scaler (
        .clk_core(clk_core), .r_in(line[7:4]), .g_in(line[3:0]), .b_in(4'hF),
        .pix_ce(ce), .blankn(blankn), .vs(vs),
        .clk_pixel(clk_pixel), .cx(cx), .cy(cy), .sync(sync), .rgb(rgb), .pic(pic),
        .dbg_we(), .dbg_x(), .dbg_line(), .dbg_data()
    );
    // hdmi.sv's counters, locked by sync
    always @(posedge clk_pixel)
        if (sync) begin
            cx <= 11'd0;
            cy <= 10'(SYNC_Y);
        end else begin
            cx <= (cx == 11'd1583) ? 11'd0 : cx + 11'd1;
            if (cx == 11'd1583) cy <= (cy == 10'(FRAME_H - 1)) ? 10'd0 : cy + 10'd1;
        end

    // ---- the check, from the first frame start after the first sync, for four frames ----
    logic locked = 0;
    int   frames = 0, lit = 0, good = 0;
    initial begin done = 0; bad_rows = 0; stray = 0; end
    always @(posedge clk_pixel) begin
        if (sync) locked <= 1'b1;
        if (locked && !done) begin
            if (cx == 11'd0 && cy == 10'd0) frames <= frames + 1;
            if (frames >= 1 && frames <= 4) begin
                if (cx == 11'd0) begin lit = 0; good = 0; end
                if (rgb != 24'h000000) begin
                    lit++;
                    if (cy >= Y0 && cy < Y0 + 3 * H && {rgb[23:20], rgb[15:12]} == 8'((cy - Y0) / 3)) good++;
                end
                if (cx == 11'd1583) begin
                    if (cy >= Y0 && cy < Y0 + 3 * H) begin
                        if (lit < 3 * W - 3 || good != lit) begin
                            if (bad_rows < 3) $display("%s: line %0d shows %0d pixels, %0d of core line %0d",
                                                       NAME, cy, lit, good, (cy - Y0) / 3);
                            bad_rows++;
                        end
                    end else
                        stray += lit;
                end
            end
            if (frames == 5) begin
                done <= 1'b1;
                $display("%s: SYNC_Y %0d, FRAME_H %0d, 4 frames: %0d of %0d picture lines wrong, %0d pixels outside",
                         NAME, SYNC_Y, FRAME_H, bad_rows, 4 * 3 * H, stray);
            end
        end
    end
endmodule

module tb_scaler_sync;
    logic d1, d2, d3;
    int   b1, b2, b3, s1, s2, s3;
    sync_case #(.NAME("1942"), .W(256), .H(224), .HT(384), .VT(262), .NUM(16), .DEN(99),
                .FRAME_H(786), .SYNC_Y(20)) c1942 (.done(d1), .bad_rows(b1), .stray(s1));
    sync_case #(.NAME("pang"), .W(384), .H(240), .HT(512), .VT(272), .NUM(64), .DEN(297),
                .FRAME_H(816), .SYNC_Y((0 - 4 + 816) % 816)) cpang (.done(d2), .bad_rows(b2), .stray(s2));
    sync_case #(.NAME("pang_sync20"), .W(384), .H(240), .HT(512), .VT(272), .NUM(64), .DEN(297),
                .FRAME_H(816), .SYNC_Y(20)) cold (.done(d3), .bad_rows(b3), .stray(s3));
    initial begin
        wait (d1 && d2 && d3);
        if (b1 != 0 || s1 != 0) $fatal(1, "1942 raster: frame lock wrong");
        if (b2 != 0 || s2 != 0) $fatal(1, "Pang raster: frame lock wrong");
        if (b3 == 0) $fatal(1, "counter-check: Pang with SYNC_Y 20 should show wrong lines");
        $display("PASS");
        $finish;
    end
endmodule

`default_nettype wire
