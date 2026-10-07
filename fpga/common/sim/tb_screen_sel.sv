// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// Testbench for screen_sel.sv: every screen (0..3) x menu screen mode (0..3) x fb_force
// against the table in the head of screen_sel.sv, written out here once more, and for cw
// and ccw against the selection game20k_top.sv made before the screen came from the ROM
// file (use_fb = fb_force || mode != 0, rotate = mode == 0, flip = ROT_CCW where rotate).
// Ends with PASS or $fatal.
`timescale 1ns/1ps
`default_nettype none
module tb_screen_sel;
    logic [1:0] screen, mode;
    logic       fb_force;
    logic       use_fb, portrait, rotate, flip, land;
    screen_sel dut (.screen(screen), .mode(mode), .fb_force(fb_force), .use_fb(use_fb),
                    .portrait(portrait), .rotate(rotate), .flip(flip), .land(land));

    initial begin
        int n = 0, bad = 0;
        logic [4:0] want;   // {use_fb, portrait, rotate, flip, land}
        for (int s = 0; s < 4; s++)
            for (int m = 0; m < 4; m++)
                for (int f = 0; f < 2; f++) begin
                    screen = 2'(s); mode = 2'(m); fb_force = 1'(f);
                    #1;
                    // the table of screen_sel.sv, 3 as cw
                    case (s)
                        0:       want = 5'b00001;
                        2:       want = (m == 0) ? 5'b00110 : 5'b11000;
                        default: want = (m == 0) ? 5'b00100 : 5'b11000;
                    endcase
                    if (f) want[4] = 1'b1;
                    if ({use_fb, portrait, rotate, flip, land} != want) begin
                        $display("screen %0d mode %0d fb_force %0d: got %b, table %b",
                                 s, m, f, {use_fb, portrait, rotate, flip, land}, want);
                        bad++;
                    end
                    // cw and ccw: the selection before the screen came from the file
                    if (s != 0 && (use_fb != (f || m != 0) || portrait != (m != 0) ||
                                   rotate != (m == 0) || (rotate && flip != (s == 2)) || land)) begin
                        $display("screen %0d mode %0d fb_force %0d: differs from the old selection", s, m, f);
                        bad++;
                    end
                    n++;
                end
        $display("screen_sel: %0d combinations, %0d differ", n, bad);
        if (bad != 0) $fatal(1, "screen_sel differs from its table");
        $display("PASS");
        $finish;
    end
endmodule

`default_nettype wire
