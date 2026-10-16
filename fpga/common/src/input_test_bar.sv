// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent 1-bit net.
//! @file input_test_bar.sv
//! @brief Input test bar: raw FPGA Companion bits and the derived game signals, labelled.
//!
//! Visible when enable = 1 in lines 0..19 of the 720p raster, from x = 32 on.
//!
//! Why at the top and not at the bottom: in portrait mode the bottom edge is taken by the
//! unlock banner (ra_overlay.sv, lines 700..713), so both down there would overlap. The
//! top has room in both orientations: landscape leaves lines 0..23 free, portrait 0..71.
//!
//! The start line is NOT freely selectable: font_addr derives the glyph row from
//! cy[2:0]-4, so the label must start at a cy with (cy mod 8) == 4. With boxes from Y
//! and labels from Y+12 that means Y is a multiple of 8. Y = 0 is the only value where
//! everything fits into the 24 free lines of the landscape orientation.
//!   box 0: "OK" green as soon as at least one joystick packet has been received
//!   1..8  white:   joystick byte bits 7..0 = buttons B4 B3 B2 B1, Up, Down, Left, Right
//!   9..16 yellow:  extra byte bits 7..0 = HID buttons 12..5 (generic format)
//!   17..24 cyan:   axis X bits 7..0, 25..32 magenta: axis Y bits 7..0
//!   from 34 green: the game signals as the game core receives them, MAP_N of them, each
//!                  labelled with two characters from MAP_LABELS (Galaga: L R F C S1 S2)
module input_test_bar #(
    parameter int MAP_N = 6,                  //!< number of game signals, 1..16
    //! two characters per game signal, signal 0 in the lowest 16 bits. The font knows
    //! 0-9, space, B C D F K L O R S U X Y.
    parameter logic [16*16-1:0] MAP_LABELS = 256'({"S2", "S1", "C ", "F ", "R ", "L "})
)(
    input  wire         clk,
    input  wire         enable,
    input  wire  [10:0] cx,
    input  wire  [9:0]  cy,
    input  wire         hid_seen,
    input  wire  [31:0] bits,      //!< {joystick, extra, ax, ay}
    input  wire  [15:0] mapped,    //!< game signals, field 34 + n shows bit n
    output logic        on,
    output logic [23:0] color
);
    logic [10:0] x;
    logic [5:0]  idx;
    logic [3:0]  xi;
    logic [9:0]  label;
    logic [4:0]  glyph;
    logic [2:0]  row, col;
    logic        bit_on, in_box_rows, in_label_rows;

    assign x   = cx - 11'd32;
    assign idx = x[9:4];
    assign xi  = x[3:0];
    assign in_box_rows   = (cy < 10'd12);
    assign in_label_rows = (cy >= 10'd12) && (cy < 10'd20);
    assign row = cy[2:0];             // label from 12 = 8*1+4 -> row 4..7,0..3; corrected below
    assign col = xi[2:0];
    assign glyph = xi[3] ? label[4:0] : label[9:5];

    // Character code of the 8x8 font below for an ASCII character, space for anything
    // the font does not have.
    function automatic logic [4:0] chr(input logic [7:0] c);
        case (c)
            8'h30, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36, 8'h37, 8'h38, 8'h39: chr = 5'(c - 8'h30);
            "B": chr = 5'd11;  "U": chr = 5'd12;  "D": chr = 5'd13;  "L": chr = 5'd14;
            "R": chr = 5'd15;  "X": chr = 5'd16;  "Y": chr = 5'd17;  "O": chr = 5'd18;
            "K": chr = 5'd19;  "F": chr = 5'd20;  "C": chr = 5'd21;  "S": chr = 5'd22;
            default: chr = 5'd10;
        endcase
    endfunction

    always_comb begin
        case (idx)
            6'd0: label = {5'd18, 5'd19};
            6'd1: label = {5'd11, 5'd4};
            6'd2: label = {5'd11, 5'd3};
            6'd3: label = {5'd11, 5'd2};
            6'd4: label = {5'd11, 5'd1};
            6'd5: label = {5'd12, 5'd10};
            6'd6: label = {5'd13, 5'd10};
            6'd7: label = {5'd14, 5'd10};
            6'd8: label = {5'd15, 5'd10};
            6'd9: label = {5'd1, 5'd2};
            6'd10: label = {5'd1, 5'd1};
            6'd11: label = {5'd1, 5'd0};
            6'd12: label = {5'd9, 5'd10};
            6'd13: label = {5'd8, 5'd10};
            6'd14: label = {5'd7, 5'd10};
            6'd15: label = {5'd6, 5'd10};
            6'd16: label = {5'd5, 5'd10};
            6'd17: label = {5'd16, 5'd7};
            6'd18: label = {5'd16, 5'd6};
            6'd19: label = {5'd16, 5'd5};
            6'd20: label = {5'd16, 5'd4};
            6'd21: label = {5'd16, 5'd3};
            6'd22: label = {5'd16, 5'd2};
            6'd23: label = {5'd16, 5'd1};
            6'd24: label = {5'd16, 5'd0};
            6'd25: label = {5'd17, 5'd7};
            6'd26: label = {5'd17, 5'd6};
            6'd27: label = {5'd17, 5'd5};
            6'd28: label = {5'd17, 5'd4};
            6'd29: label = {5'd17, 5'd3};
            6'd30: label = {5'd17, 5'd2};
            6'd31: label = {5'd17, 5'd1};
            6'd32: label = {5'd17, 5'd0};
            6'd33: label = {5'd10, 5'd10};
            // from 34 the game signals, labelled as the game names them
            default: label = (idx >= 6'd34 && idx < 6'(34 + MAP_N))
                           ? {chr(MAP_LABELS[16 * (idx - 6'd34) + 8 +: 8]),
                              chr(MAP_LABELS[16 * (idx - 6'd34) +: 8])}
                           : {5'd10, 5'd10};
        endcase
    end

    // 8x8 character set, 5 pixels wide, bit 7 = left. Address = character*8 + row
    logic [7:0] font_addr;
    assign font_addr = {glyph, cy[2:0] - 3'd4};   // line 12 -> 0
    // Font ROM, address = glyph * 8 + row, read on the clock (stage 1) so that the tools
    // can put it into a block RAM. The bit is picked after the register, in stage 2.
    (* ram_style = "block", syn_romstyle = "block_rom" *)
    logic [7:0] font_rom [0:255] = '{
        8'h70, 8'h88, 8'h98, 8'ha8, 8'hc8, 8'h88, 8'h70, 8'h00,  // 0
        8'h20, 8'h60, 8'h20, 8'h20, 8'h20, 8'h20, 8'h70, 8'h00,  // 1
        8'h70, 8'h88, 8'h08, 8'h10, 8'h20, 8'h40, 8'hf8, 8'h00,  // 2
        8'hf8, 8'h10, 8'h20, 8'h10, 8'h08, 8'h88, 8'h70, 8'h00,  // 3
        8'h10, 8'h30, 8'h50, 8'h90, 8'hf8, 8'h10, 8'h10, 8'h00,  // 4
        8'hf8, 8'h80, 8'hf0, 8'h08, 8'h08, 8'h88, 8'h70, 8'h00,  // 5
        8'h30, 8'h40, 8'h80, 8'hf0, 8'h88, 8'h88, 8'h70, 8'h00,  // 6
        8'hf8, 8'h08, 8'h10, 8'h20, 8'h40, 8'h40, 8'h40, 8'h00,  // 7
        8'h70, 8'h88, 8'h88, 8'h70, 8'h88, 8'h88, 8'h70, 8'h00,  // 8
        8'h70, 8'h88, 8'h88, 8'h78, 8'h08, 8'h10, 8'h60, 8'h00,  // 9
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,  // 10
        8'hf0, 8'h88, 8'h88, 8'hf0, 8'h88, 8'h88, 8'hf0, 8'h00,  // 11
        8'h88, 8'h88, 8'h88, 8'h88, 8'h88, 8'h88, 8'h70, 8'h00,  // 12
        8'hf0, 8'h88, 8'h88, 8'h88, 8'h88, 8'h88, 8'hf0, 8'h00,  // 13
        8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'hf8, 8'h00,  // 14
        8'hf0, 8'h88, 8'h88, 8'hf0, 8'ha0, 8'h90, 8'h88, 8'h00,  // 15
        8'h88, 8'h88, 8'h50, 8'h20, 8'h50, 8'h88, 8'h88, 8'h00,  // 16
        8'h88, 8'h88, 8'h50, 8'h20, 8'h20, 8'h20, 8'h20, 8'h00,  // 17
        8'h70, 8'h88, 8'h88, 8'h88, 8'h88, 8'h88, 8'h70, 8'h00,  // 18
        8'h88, 8'h90, 8'ha0, 8'hc0, 8'ha0, 8'h90, 8'h88, 8'h00,  // 19
        8'hf8, 8'h80, 8'h80, 8'hf0, 8'h80, 8'h80, 8'h80, 8'h00,  // 20
        8'h70, 8'h88, 8'h80, 8'h80, 8'h80, 8'h88, 8'h70, 8'h00,  // 21
        8'h78, 8'h80, 8'h80, 8'h70, 8'h08, 8'h08, 8'hf0, 8'h00,  // 22
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,  // 23
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,  // 24
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,  // 25
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,  // 26
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,  // 27
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,  // 28
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,  // 29
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,  // 30
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00  // 31
    };
    logic [7:0] font_q;
    always_ff @(posedge clk) font_q <= font_rom[font_addr];

    always_comb begin
        if (idx == 6'd0)        bit_on = hid_seen;
        else if (idx <= 6'd32)  bit_on = bits[6'd32 - idx];
        else if (idx >= 6'd34 && idx < 6'(34 + MAP_N)) bit_on = mapped[4'(idx - 6'd34)];
        else                    bit_on = 1'b0;
    end

    // Stage 1 (registered): region, bit, glyph pixel. The bar ends after the last game signal.
    localparam logic [10:0] X_END = 11'(32 + 16 * (34 + MAP_N));
    logic       r_box, r_label, r_bit, r_pix;
    logic [2:0] col_q;
    logic [5:0] r_idx;
    always_ff @(posedge clk) begin
        r_box   <= enable && cx >= 11'd32 && cx < X_END && idx != 6'd33 && in_box_rows && xi < 4'd12;
        r_label <= enable && cx >= 11'd32 && cx < X_END && idx != 6'd33 && in_label_rows;
        r_bit   <= bit_on;
        col_q   <= col;
        r_idx   <= idx;
    end

    assign r_pix = font_q[3'd7 - col_q];

    // Stage 2 (registered): colour. Output is thus shifted 2 pixels to the right, irrelevant.
    always_ff @(posedge clk) begin
        on    <= r_box | r_label;
        color <= 24'h000000;
        if (r_box) begin
            if (r_idx == 6'd0)        color <= r_bit ? 24'h00FF00 : 24'h600000;
            else if (r_idx >= 6'd34)  color <= r_bit ? 24'h00FF00 : 24'h104010;
            else if (!r_bit)          color <= 24'h303030;
            else if (r_idx <= 6'd8)   color <= 24'hFFFFFF;
            else if (r_idx <= 6'd16)  color <= 24'hFFFF00;
            else if (r_idx <= 6'd24)  color <= 24'h00FFFF;
            else                      color <= 24'hFF00FF;
        end else if (r_label)
            color <= r_pix ? 24'hC0C0C0 : 24'h000000;
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the
                        // directive would otherwise leak into the next file.
