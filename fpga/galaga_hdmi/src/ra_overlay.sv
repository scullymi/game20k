// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent 1-bit net.
//! @file ra_overlay.sv
//! @brief RetroAchievements overlays (game20k): unlock banner below the game picture.
//!
//! A banner below the game picture when an achievement unlock has been reached.
//!
//! COLOURS, as on the RetroAchievements site:
//!   gold  = hardcore      white = softcore only
//! To the left of it a small square, whether anything goes to the server:
//!   green = new, is sent      grey = the account had it already, is NOT sent
//! Messages of the firmware (RA: ...) are white, with a green square when all is
//! well and a grey one when not. The distinction is real information, not
//! decoration: the server keeps two separate lists (r=unlocks with h=1 and h=0
//! return different sets).
//! Up to 24 characters, which the Pico pushes in one at a time over the back
//! channel of the RAM mirror (header byte 6 = position and display flag, byte 7 =
//! character). No new transport path was needed for this.
//!
//! There is no permanent "RA" status hint in the picture: the banner reports the
//! login at start-up anyway, and the menu shows the state under Status. An
//! indicator that sits in the picture all the time but says something only once
//! is a distraction.
//!
//! POSITION: the banner follows the screen mode, like the OSD. The game picture
//! sits differently in the two modes, measured in the top level:
//!   portrait 2x  (monitor upright)  x 416..864,  y 72..648
//!   landscape 3x (monitor turned)   x 208..1072, y 24..696
//! In portrait mode the banner lies along the bottom edge of the frame, 52 px
//! below the picture. In landscape mode the monitor is turned clockwise, and
//! what the player sees below the picture is the frame band to its right
//! (x 1072..1280). The banner is drawn there rotated by 90 degrees in the same
//! sense as the OSD (osd_u8g2.v): the glyph tops point to the frame left and the
//! text runs from the frame bottom upwards, so that it reads left to right on the
//! turned monitor. Again 52 px below the picture. 2x magnification (14 px line
//! height) in both modes.
//!
//! The OSD is not suited for this: it draws a 512x256 box into the middle of the
//! picture with a darkened background (osd_u8g2.v, active/sactive/tactive).
//! During play that would be exactly the wrong place.
module ra_overlay (
    input  wire         clk,          //!< clk_pixel
    input  wire  [10:0] cx,
    input  wire  [9:0]  cy,
    input  wire         rotate,       //!< 1 = landscape 3x, banner rotated in the band right of the picture
    input  wire         txt_we,       //!< write one character
    input  wire  [4:0]  txt_addr,     //!< 0..23
    input  wire  [7:0]  txt_data,
    input  wire         banner_on,    //!< show banner
    input  wire         banner_gold,  //!< 1 = hardcore (gold text), 0 = softcore (white)
    input  wire         banner_new,   //!< 1 = new, is sent (green mark), 0 = already had (grey)
    output logic        on,
    output logic [23:0] color
);
    // ---- Text buffer. 24 characters as registers, NOT as BSRAM: the device
    // ---- is at 45 of 46 blocks used, registers are at 31 percent. The attribute
    // ---- keeps the synthesis from turning the registered read below into a block RAM. ----
    logic [7:0] text [0:23] /* synthesis syn_ramstyle = "registers" */;
    always_ff @(posedge clk)
        if (txt_we && txt_addr < 5'd24) text[txt_addr] <= txt_data;

    // ---- Banner: 24 characters, doubled, 16 px cells, 384 px long, 14 px high ----
    // Portrait: the text starts at (BX, BY), its top left corner, and runs along x.
    // Landscape: the text field spans x RX..RX+14 and y RY..RY+384, and the text runs
    // along y from the bottom up.
    localparam int BX = 448,  BY = 700;
    localparam int RX = 1124, RY = 168;

    // ---- Pipeline. Four register stages from the raster position to the output:
    // ---- (1) position inside the banner, (2) character, (3) glyph row, (4) pixel and
    // ---- colour. The chain from the subtraction through the 24:1 character mux and the
    // ---- glyph decoder does not fit into one pixel clock as a whole. cx is taken three
    // ---- pixels ahead so that the output lands where the constants say. ----
    logic [10:0] cxa;
    assign cxa = cx + 11'd3;

    // Stage 1: position. tx runs along the text (0..383), ty across it (0..13),
    // whichever way the text lies. Outside the banner both are meaningless, the
    // output is gated by in_banner.
    logic       in_banner1, in_mark1;
    logic [8:0] tx1;
    logic [3:0] ty1;
    always_ff @(posedge clk) begin
        if (rotate) begin
            in_banner1 <= banner_on && (cxa >= RX) && (cxa < RX + 14)
                                    && (cy >= RY) && (cy < RY + 384);
            /* Small filled square, 10x10, with an 8 pixel gap before the first
               character: below the text field in the frame, left of it for the player. */
            in_mark1   <= banner_on && (cxa >= RX + 2) && (cxa < RX + 12)
                                    && (cy >= RY + 384 + 8) && (cy < RY + 384 + 18);
            tx1 <= RY + 383 - cy;
            ty1 <= cxa - RX;
        end else begin
            in_banner1 <= banner_on && (cxa >= BX) && (cxa < BX + 384)
                                    && (cy >= BY) && (cy < BY + 14);
            /* The same square, here to the left of the text. */
            in_mark1   <= banner_on && (cxa >= BX - 18) && (cxa < BX - 8)
                                    && (cy >= BY + 2)  && (cy < BY + 12);
            tx1 <= cxa - BX;
            ty1 <= cy - BY;
        end
    end

    // Stage 2: character, and the glyph pixel the raster pixel falls into. Each glyph
    // pixel is 2x2 raster pixels, hence the bit slices.
    logic [7:0] char2;
    logic [2:0] col2, row2;
    logic       in_banner2, in_mark2;
    always_ff @(posedge clk) begin
        char2      <= text[tx1[8:4]];
        col2       <= tx1[3:1];
        row2       <= ty1[3:1];
        in_banner2 <= in_banner1;
        in_mark2   <= in_mark1;
    end

    logic [34:0] glyph_bits;
    always_comb begin
        case (char2)
            8'h20: glyph_bits = 35'b00000000000000000000000000000000000;   // space
            8'h21: glyph_bits = 35'b00100001000010000100001000000000100;   // !
            8'h2D: glyph_bits = 35'b00000000000000011111000000000000000;   // -
            8'h2E: glyph_bits = 35'b00000000000000000000000000110001100;   // .
            8'h30: glyph_bits = 35'b01110100011001110101110011000101110;   // 0
            8'h31: glyph_bits = 35'b00100011000010000100001000010001110;   // 1
            8'h32: glyph_bits = 35'b01110100010000100110010001000011111;   // 2
            8'h33: glyph_bits = 35'b11111000100010000010000011000101110;   // 3
            8'h34: glyph_bits = 35'b00010001100101010010111110001000010;   // 4
            8'h35: glyph_bits = 35'b11111100001111000001000011000101110;   // 5
            8'h36: glyph_bits = 35'b00110010001000011110100011000101110;   // 6
            8'h37: glyph_bits = 35'b11111000010001000100010000100001000;   // 7
            8'h38: glyph_bits = 35'b01110100011000101110100011000101110;   // 8
            8'h39: glyph_bits = 35'b01110100011000101111000010001001100;   // 9
            8'h3A: glyph_bits = 35'b00000011000110000000011000110000000;   // :
            8'h41: glyph_bits = 35'b01110100011000111111100011000110001;   // A
            8'h42: glyph_bits = 35'b11110100011000111110100011000111110;   // B
            8'h43: glyph_bits = 35'b01110100011000010000100001000101110;   // C
            8'h44: glyph_bits = 35'b11110100011000110001100011000111110;   // D
            8'h45: glyph_bits = 35'b11111100001000011110100001000011111;   // E
            8'h46: glyph_bits = 35'b11111100001000011110100001000010000;   // F
            8'h47: glyph_bits = 35'b01110100011000010111100011000101111;   // G
            8'h48: glyph_bits = 35'b10001100011000111111100011000110001;   // H
            8'h49: glyph_bits = 35'b01110001000010000100001000010001110;   // I
            8'h4A: glyph_bits = 35'b00111000100001000010000101001001100;   // J
            8'h4B: glyph_bits = 35'b10001100101010011000101001001010001;   // K
            8'h4C: glyph_bits = 35'b10000100001000010000100001000011111;   // L
            8'h4D: glyph_bits = 35'b10001110111010110101100011000110001;   // M
            8'h4E: glyph_bits = 35'b10001110011010110011100011000110001;   // N
            8'h4F: glyph_bits = 35'b01110100011000110001100011000101110;   // O
            8'h50: glyph_bits = 35'b11110100011000111110100001000010000;   // P
            8'h51: glyph_bits = 35'b01110100011000110001101011001001101;   // Q
            8'h52: glyph_bits = 35'b11110100011000111110101001001010001;   // R
            8'h53: glyph_bits = 35'b01111100001000001110000010000111110;   // S
            8'h54: glyph_bits = 35'b11111001000010000100001000010000100;   // T
            8'h55: glyph_bits = 35'b10001100011000110001100011000101110;   // U
            8'h56: glyph_bits = 35'b10001100011000110001100010101000100;   // V
            8'h57: glyph_bits = 35'b10001100011000110101101011101110001;   // W
            8'h58: glyph_bits = 35'b10001100010101000100010101000110001;   // X
            8'h59: glyph_bits = 35'b10001100010101000100001000010000100;   // Y
            8'h5A: glyph_bits = 35'b11111000010001000100010001000011111;   // Z
            default: glyph_bits = 35'd0;
        endcase
    end

    // Stage 3: glyph row. Row r occupies bits [34-5r -: 5], column 0 is the most
    // significant bit.
    logic [4:0] row3;
    logic [2:0] col3;
    logic       in_banner3, in_mark3;
    always_ff @(posedge clk) begin
        row3       <= (row2 > 3'd6) ? 5'd0 : glyph_bits[34 - 5*row2 -: 5];
        col3       <= col2;
        in_banner3 <= in_banner2;
        in_mark3   <= in_mark2;
    end

    // Stage 4: pixel and colour.
    logic pixel;
    assign pixel = (col3 > 3'd4) ? 1'b0 : row3[3'd4 - col3];
    always_ff @(posedge clk) begin
        on <= (pixel && in_banner3) || in_mark3;
        if (in_mark3) color <= banner_new  ? 24'h00C000 : 24'h707070;
        else          color <= banner_gold ? 24'hFFD000 : 24'hFFFFFF;
    end
endmodule

`default_nettype wire
