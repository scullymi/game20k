// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// Testbench for ra_overlay.sv: draws one whole 1280x720 frame per banner position, with a
// fixed text, the banner gold and new and a challenge on, and writes each frame as
// $WORK/ra_<game>_<position>.ppm. run_screen_sim.sh compares the files with
// ref_screen.sha256. Two raster geometries, computed as game20k_top.sv computes them:
// Galaga (288 x 224) and 1942 (256 x 224).
//
// The pixel at (x, y) is the output in the clock in which the raster counters stand at x, y,
// as hdmi.sv takes rgb. The landscape upright position is also checked here: its frame must
// be the portrait frame moved by (LX - BX, LY - BY), and every lit pixel must lie in the
// band below the picture. A third geometry, Pang's 384 x 240, fills the height: its banner
// lies over the picture on a dark box (OVL) and the challenge marker in the band right of
// it, written as ra_pang_upright.ppm with the box grey. Ends with PASS or $fatal.
`timescale 1ns/1ps
`default_nettype none
module tb_ra_overlay;
    localparam int FRAME_W = 1584;
    localparam int FRAME_H = 768;

    // the banner positions of game20k_top.sv for a core raster of W x H
    function automatic int bx();             return (1280 - 384) / 2; endfunction
    function automatic int by(input int w);  return (720 - 2 * w) / 2 + 2 * w + 52; endfunction
    function automatic int rx(input int w);  return (1280 - 3 * w) / 2 + 3 * w + 52; endfunction
    function automatic int ry();             return (720 - 384) / 2; endfunction
    function automatic int lx();             return (1280 - 384) / 2; endfunction
    function automatic int ly(input int h);  return (720 - 3 * h) / 2 + 3 * h + 5; endfunction
    localparam int GW = 288, JW = 256, H = 224;
    // Pang: the over-the-picture position of game20k_top.sv (BANNER_OVL)
    localparam int PW = 384, PH = 240;
    localparam int P_LY = (720 - 3 * PH) / 2 + 4;
    localparam int P_X0 = (1280 - 3 * PW) / 2;
    localparam int P_CX = P_X0 + 3 * PW + (P_X0 - 12) / 2, P_CY = P_LY + 1;

    logic clk = 0;
    always #6.734 clk = ~clk;   // 74.25 MHz

    logic [10:0] cx = 0;
    logic [9:0]  cy = 0;
    always_ff @(posedge clk) begin
        cx <= (cx == 11'(FRAME_W - 1)) ? 11'd0 : cx + 11'd1;
        if (cx == 11'(FRAME_W - 1)) cy <= (cy == 10'(FRAME_H - 1)) ? 10'd0 : cy + 10'd1;
    end

    logic       rotate = 0, flip = 0, land = 0;
    logic       txt_we = 0;
    logic [4:0] txt_addr = 0;
    logic [7:0] txt_data = 0;
    logic        g_on, j_on, p_on, p_dim;
    logic [23:0] g_col, j_col, p_col;

    ra_overlay #(.BX(bx()), .BY(by(GW)), .RX(rx(GW)), .RY(ry()), .LX(lx()), .LY(ly(H))) dut_g (
        .clk(clk), .cx(cx), .cy(cy), .rotate(rotate), .flip(flip), .land(land),
        .txt_we(txt_we), .txt_addr(txt_addr), .txt_data(txt_data),
        .banner_on(1'b1), .banner_gold(1'b1), .banner_new(1'b1), .challenge_on(1'b1),
        .on(g_on), .color(g_col));
    ra_overlay #(.BX(bx()), .BY(by(JW)), .RX(rx(JW)), .RY(ry()), .LX(lx()), .LY(ly(H))) dut_j (
        .clk(clk), .cx(cx), .cy(cy), .rotate(rotate), .flip(flip), .land(land),
        .txt_we(txt_we), .txt_addr(txt_addr), .txt_data(txt_data),
        .banner_on(1'b1), .banner_gold(1'b1), .banner_new(1'b1), .challenge_on(1'b1),
        .on(j_on), .color(j_col));
    ra_overlay #(.BX(bx()), .BY(by(PW)), .RX(rx(PW)), .RY(ry()), .LX(lx()), .LY(P_LY),
                 .OVL(1'b1), .CX(P_CX), .CY(P_CY)) dut_p (
        .clk(clk), .cx(cx), .cy(cy), .rotate(rotate), .flip(flip), .land(land),
        .txt_we(txt_we), .txt_addr(txt_addr), .txt_data(txt_data),
        .banner_on(1'b1), .banner_gold(1'b1), .banner_new(1'b1), .challenge_on(1'b1),
        .on(p_on), .color(p_col), .dim(p_dim));

    // one frame of each geometry, taken while cap is set
    logic        cap = 0;
    logic [23:0] img_g [720][1280];
    logic [23:0] img_j [720][1280];
    logic [23:0] img_p [720][1280];
    always_ff @(posedge clk)
        if (cap && cx < 11'd1280 && cy < 10'd720) begin
            img_g[cy][cx] <= g_on ? g_col : 24'h000000;
            img_j[cy][cx] <= j_on ? j_col : 24'h000000;
            img_p[cy][cx] <= p_on ? p_col : p_dim ? 24'h303030 : 24'h000000;
        end

    task automatic frame_start();
        do @(posedge clk); while (!(cx == 11'(FRAME_W - 1) && cy == 10'(FRAME_H - 1)));
    endtask

    // set the position, let one frame pass for the pipeline, take the next one
    task automatic take(input logic r, input logic f, input logic l);
        frame_start();
        rotate <= r; flip <= f; land <= l;
        frame_start();
        cap <= 1'b1;
        frame_start();
        cap <= 1'b0;
        @(posedge clk);
    endtask

    task automatic write_ppm(input string name, input int which);   // 1 Galaga, 0 1942, 2 Pang
        int fd;
        logic [23:0] p;
        fd = $fopen(name, "wb");
        if (fd == 0) $fatal(1, "cannot write %s", name);
        $fwrite(fd, "P6\n1280 720\n255\n");
        for (int y = 0; y < 720; y++)
            for (int x = 0; x < 1280; x++) begin
                p = which == 2 ? img_p[y][x] : which == 1 ? img_g[y][x] : img_j[y][x];
                $fwrite(fd, "%c%c%c", p[23:16], p[15:8], p[7:0]);
            end
        $fclose(fd);
    endtask

    // the portrait frames, kept for the comparison with the upright one
    logic [23:0] por_g [720][1280];
    logic [23:0] por_j [720][1280];

    // Pang over the picture, against 1942's upright frame (the same banner, the same BX):
    // text and mark must be 1942's moved by the difference of the two LY, the challenge
    // marker 1942's moved to (CX, CY), the box exactly 424 x 18 px from (LX - 20, LY - 2), and
    // nothing lit or dark anywhere else. Portrait has no Pang frame to compare: its BY lies
    // below the 720 lines. The positions are taken relative to where 1942's mark lands
    // (nominally LX - 18, the output lands one pixel later in this sampling).
    task automatic check_ovl();
        int dy, bad_move, bad_mark, bad_box, lit, box, mark, o;
        logic [23:0] p, q;
        logic in_box, in_mark, in_jmark;
        dy = P_LY - ly(H);
        bad_move = 0; bad_mark = 0; bad_box = 0; lit = 0; box = 0; mark = 0;
        o = 0;
        while (img_j[ly(H) + 5][lx() - 18 + o] == 24'h000000 && o < 4) o++;
        for (int y = 0; y < 720; y++)
            for (int x = 0; x < 1280; x++) begin
                p = img_p[y][x];
                in_box  = x >= lx() - 20 + o && x < lx() + 404 + o && y >= P_LY - 2 && y < P_LY + 16;
                in_mark = x >= P_CX + o && x < P_CX + 12 + o && y >= P_CY && y < P_CY + 12;
                // where 1942's frame has its marker: 8 px after the text, moved
                in_jmark = x >= lx() + 392 + o && x < lx() + 404 + o && y >= P_LY + 1 && y < P_LY + 13;
                if (in_mark) begin
                    q = img_j[y - P_CY + ly(H) + 1][x - P_CX + lx() + 392];
                    if (p != q) bad_mark++;
                    if (p != 24'h000000) mark++;
                end else if (in_box) begin
                    q = (in_jmark || y - dy >= 720) ? 24'h000000 : img_j[y - dy][x];
                    if ((p == 24'h303030 ? 24'h000000 : p) != q) bad_move++;
                    if (p == 24'h303030) box++; else lit++;
                end else if (p != 24'h000000) bad_box++;
            end
        $display("ra_pang_upright: %0d lit pixels in the box, %0d dark, %0d marker pixels; %0d differ from 1942's moved frame, %0d in the marker, %0d set outside (offset %0d)",
                 lit, box, mark, bad_move, bad_mark, bad_box, o);
        if (bad_move != 0 || bad_mark != 0 || bad_box != 0 || lit == 0 || mark == 0 || lit + box != 424 * 18)
            $fatal(1, "ra_pang_upright: wrong banner over the picture");
    endtask

    // The upright frame against the portrait frame moved by (dx, dy), and every lit pixel
    // inside the band y LY..LY+13 below the picture. Returns the number of lit pixels.
    function automatic int check_land(input string name, input logic is_g, input int dx, input int dy,
                                      input int band_y);
        int bad_move = 0, bad_band = 0, lit = 0;
        logic [23:0] p, q;
        for (int y = 0; y < 720; y++)
            for (int x = 0; x < 1280; x++) begin
                p = is_g ? img_g[y][x] : img_j[y][x];
                q = (y - dy >= 0 && y - dy < 720 && x - dx >= 0 && x - dx < 1280)
                  ? (is_g ? por_g[y - dy][x - dx] : por_j[y - dy][x - dx]) : 24'h000000;
                if (p != q) bad_move++;
                if (p != 24'h000000) begin
                    lit++;
                    if (y < band_y || y >= band_y + 14) bad_band++;
                end
            end
        $display("%s: %0d lit pixels, %0d differ from the moved portrait frame, %0d outside y %0d..%0d",
                 name, lit, bad_move, bad_band, band_y, band_y + 13);
        if (bad_move != 0 || bad_band != 0 || lit == 0) $fatal(1, "%s: wrong upright banner", name);
        return lit;
    endfunction

    string dir;
    initial begin
        if (!$value$plusargs("dir=%s", dir)) dir = ".";
        // the text, 24 characters
        begin
            string t;
            t = "GAME20K TEST: 0123456789";
            repeat (4) @(posedge clk);
            for (int i = 0; i < 24; i++) begin
                txt_addr <= 5'(i);
                txt_data <= t[i];
                txt_we   <= 1'b1;
                @(posedge clk);
                txt_we   <= 1'b0;
                @(posedge clk);
            end
        end

        take(0, 0, 0);
        write_ppm({dir, "/ra_galaga_portrait.ppm"}, 1);
        write_ppm({dir, "/ra_1942_portrait.ppm"}, 0);
        por_g = img_g;
        por_j = img_j;
        take(1, 0, 0);
        write_ppm({dir, "/ra_galaga_cw.ppm"}, 1);
        write_ppm({dir, "/ra_1942_cw.ppm"}, 0);
        take(1, 1, 0);
        write_ppm({dir, "/ra_galaga_ccw.ppm"}, 1);
        write_ppm({dir, "/ra_1942_ccw.ppm"}, 0);
        take(0, 1, 0);
        write_ppm({dir, "/ra_galaga_portrait_flip.ppm"}, 1);
        write_ppm({dir, "/ra_1942_portrait_flip.ppm"}, 0);
        take(0, 0, 1);
        write_ppm({dir, "/ra_galaga_upright.ppm"}, 1);
        write_ppm({dir, "/ra_1942_upright.ppm"}, 0);
        void'(check_land("ra_galaga_upright", 1, lx() - bx(), ly(H) - by(GW), ly(H)));
        void'(check_land("ra_1942_upright", 0, lx() - bx(), ly(H) - by(JW), ly(H)));
        write_ppm({dir, "/ra_pang_upright.ppm"}, 2);
        check_ovl();
        $display("PASS");
        $finish;
    end
endmodule

`default_nettype wire
