// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// Testbench for osd_u8g2.v: fills the 1024-byte buffer with a fixed pattern over the
// Companion's OSD commands, shows the OSD and draws one whole 1280x720 frame for every
// rotate/flip pair and HDMI frame height (768 Galaga, 786 1942, 816 a 57.44 Hz core), with
// hs and vs formed from cx and cy as game20k_top.sv forms them. The picture behind the OSD
// is a gradient, so the shadow and the darkened background show in the file. Each frame goes
// to $WORK/osd_<frame height>_r<rotate>f<flip>.ppm, run_screen_sim.sh compares the files with
// ref_screen.sha256. Prints where the box lies. Ends with PASS.
`timescale 1ns/1ps
`default_nettype none
module tb_osd_u8g2;
    localparam int FRAME_W = 1584;

    logic clk = 0;
    always #6.734 clk = ~clk;   // 74.25 MHz

    int          frame_h = 768;
    logic [10:0] cx = 0;
    logic [9:0]  cy = 0;
    always_ff @(posedge clk) begin
        cx <= (cx == 11'(FRAME_W - 1)) ? 11'd0 : cx + 11'd1;
        if (cx == 11'(FRAME_W - 1)) cy <= (int'(cy) >= frame_h - 1) ? 10'd0 : cy + 10'd1;
    end
    // active-low sync pulses, as in game20k_top.sv
    logic hs_n = 1, vs_n = 1;
    always_ff @(posedge clk) begin
        hs_n <= !(cx >= 11'd1390 && cx < 11'd1430);
        vs_n <= !(cy >= 10'd725 && cy < 10'd730);
    end

    logic       reset = 1, rotate = 0, flip = 0;
    logic       strobe = 0, start = 0;
    logic [7:0] data = 0;
    logic [5:0] r_in, g_in, b_in, r_out, g_out, b_out;
    assign r_in = cx[7:2];
    assign g_in = cy[7:2];
    assign b_in = 6'h2A;
    osd_u8g2 dut (
        .clk(clk), .reset(reset), .rotate(rotate), .flip(flip),
        .data_in_strobe(strobe), .data_in_start(start), .data_in(data),
        .hs(hs_n), .vs(vs_n), .r_in(r_in), .g_in(g_in), .b_in(b_in),
        .r_out(r_out), .g_out(g_out), .b_out(b_out), .visible());

    task automatic put(input logic s, input logic [7:0] d);
        start <= s; data <= d; strobe <= 1'b1;
        @(posedge clk);
        strobe <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    // one frame, taken while cap is set; box: the area where the output differs from the input
    logic        cap = 0;
    logic [23:0] img [720][1280];
    int          bx0, bx1, by0, by1;
    always_ff @(posedge clk)
        if (cap && cx < 11'd1280 && cy < 10'd720) begin
            img[cy][cx] <= {r_out, r_out[5:4], g_out, g_out[5:4], b_out, b_out[5:4]};
            if ({r_out, g_out, b_out} != {r_in, g_in, b_in}) begin
                if (int'(cx) < bx0) bx0 <= int'(cx);
                if (int'(cx) > bx1) bx1 <= int'(cx);
                if (int'(cy) < by0) by0 <= int'(cy);
                if (int'(cy) > by1) by1 <= int'(cy);
            end
        end

    task automatic frame_start();
        do @(posedge clk); while (!(cx == 11'(FRAME_W - 1) && int'(cy) == frame_h - 1));
    endtask

    task automatic write_ppm(input string name);
        int fd;
        fd = $fopen(name, "wb");
        if (fd == 0) $fatal(1, "cannot write %s", name);
        $fwrite(fd, "P6\n1280 720\n255\n");
        for (int y = 0; y < 720; y++)
            for (int x = 0; x < 1280; x++)
                $fwrite(fd, "%c%c%c", img[y][x][23:16], img[y][x][15:8], img[y][x][7:0]);
        $fclose(fd);
    endtask

    string dir;
    int    heights [3] = '{768, 786, 816};
    initial begin
        if (!$value$plusargs("dir=%s", dir)) dir = ".";
        repeat (4) @(posedge clk);
        reset <= 1'b0;
        repeat (4) @(posedge clk);
        // command 2: tile t (8 bytes), every byte different and no tile symmetric
        for (int t = 0; t < 128; t++) begin
            put(1'b1, 8'd2);
            put(1'b0, 8'(t));
            for (int i = 0; i < 8; i++) put(1'b0, 8'((t * 8 + i) * 37) ^ 8'(t >> 1));
        end
        // command 1: show
        put(1'b1, 8'd1);
        put(1'b0, 8'd1);

        foreach (heights[k])
            for (int m = 0; m < 4; m++) begin
                frame_start();
                @(posedge clk);   // cy is 0 now: a new height cannot meet the wrap
                frame_h = heights[k];
                rotate <= m[0];
                flip   <= m[1];
                // the OSD measures line length and frame height over a whole frame first
                repeat (3) frame_start();
                bx0 = 9999; bx1 = -1; by0 = 9999; by1 = -1;
                cap <= 1'b1;
                frame_start();
                cap <= 1'b0;
                @(posedge clk);
                write_ppm($sformatf("%s/osd_%0d_r%0df%0d.ppm", dir, heights[k], m[0], m[1]));
                $display("osd %0d rotate %0d flip %0d: box x %0d..%0d y %0d..%0d",
                         heights[k], m[0], m[1], bx0, bx1, by0, by1);
            end
        $display("PASS");
        $finish;
    end
endmodule

`default_nettype wire
