// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! @file arcade_scaler.sv
//! @brief Arcade raster (W x H visible) -> 720p, 3x scaled.
//!
//! Line ring buffer of 16 lines; core frame and HDMI frame are locked exactly through the PLL.
//! For the 384 x 264 raster of Galaga and Pac-Man (288 x 224 visible, 6.1875 MHz pixel):
//! 1 core frame = 304128 core pixel clocks * 4 = 1584 * 768 HDMI clocks.
//! For 1942 (256 x 224 of 384 x 262, 6 MHz pixel at 37.125 MHz): 1 core frame = 1584 * 786.
//!
//! The pixel is taken either every CPP core clocks, counted here (Galaga, Pac-Man: 3), or,
//! with CPP 0, on the core's own pixel enable pix_ce (1942: 6 or 7 clocks, the enable jitters).
//! The picture lies "on its side" like the original raster. Portrait mode uses fb_read_rotated.
//! W up to 512 (one ring buffer line), H up to 256.
module arcade_scaler #(
    parameter int W  = 288,   //!< visible width of the core raster
    parameter int H  = 224,   //!< visible height of the core raster
    parameter int X0 = 208,   //!< left picture edge in the 720p raster, (1280 - 3W) / 2
    parameter int Y0 = 24,    //!< top picture edge, (720 - 3H) / 2
    parameter int CPP = 3,    //!< core clocks per pixel, counted here; 0: take pix_ce
    parameter bit RGB444 = 0  //!< 0: store 3/3/2 (the upper bits of r/g/b_in), 1: 4/4/4
)(
    //! Core side
    input  wire         clk_core,
    input  wire  [3:0]  r_in,
    input  wire  [3:0]  g_in,
    input  wire  [3:0]  b_in,
    input  wire         pix_ce,     //!< pixel enable of the core, only with CPP 0
    input  wire         blankn,     //!< 1 = visible area
    input  wire         vs,         //!< vsync, active low
    //! HDMI side
    input  wire         clk_pixel,
    input  wire  [10:0] cx,
    input  wire  [9:0]  cy,
    output logic        sync,       //!< 1-clock pulse at the start of the first visible core line
    output logic [23:0] rgb,
    //! Debug: write side brought out (clk_core)
    output logic        dbg_we,
    output logic [8:0]  dbg_x,
    output logic [7:0]  dbg_line,
    output logic [7:0]  dbg_data
);

    // A ring line holds 2^XW pixels: 512 for Galaga's 288, 256 for 1942's 256.
    localparam int XW = $clog2(W);
    localparam int CW = RGB444 ? 12 : 8;      // bits per stored pixel
    wire [CW-1:0] pix = RGB444 ? {r_in, g_in, b_in} : {r_in[3:1], g_in[3:1], b_in[3:2]};

    // ---------------- Write side (clk_core) ----------------
    logic       blankn_d = 0, vs_d = 0;
    logic [7:0] wr_line = 8'hFF;
    logic [1:0] ph = 0;
    logic [8:0] wr_x = 0;
    logic       sync_tgl = 0;
    logic       we = 0;
    logic [XW+3:0] waddr;
    logic [CW-1:0] wdata;

    always_ff @(posedge clk_core) begin
        blankn_d <= blankn;
        vs_d     <= vs;
        we       <= 1'b0;
        if (vs && !vs_d)
            wr_line <= 8'hFF;                       // vsync pulse ended: arm the line counter
        if (blankn && !blankn_d) begin              // start of a visible line
            wr_line <= wr_line + 8'd1;
            if (wr_line == 8'hFF) sync_tgl <= ~sync_tgl;
            ph   <= 2'd0;
            wr_x <= 9'd0;
        end else if (blankn) begin
            if (CPP == 0) begin
                // the core's own enable: the pixel is still stable in the clock of the enable
                if (pix_ce) begin
                    wr_x <= wr_x + 9'd1;
                    if (wr_x < 9'(W)) begin
                        we    <= 1'b1;
                        waddr <= {wr_line[3:0], wr_x[XW-1:0]};
                        wdata <= pix;
                    end
                end
            end else begin
                // count the pixels: CPP clocks each, taken in the second clock of the pixel
                if (ph == 2'(CPP - 1)) begin
                    ph   <= 2'd0;
                    wr_x <= wr_x + 9'd1;
                end else
                    ph <= ph + 2'd1;
                if (ph == 2'd1 && wr_x < 9'(W)) begin
                    we    <= 1'b1;
                    waddr <= {wr_line[3:0], wr_x[XW-1:0]};
                    wdata <= pix;
                end
            end
        end
    end

    assign dbg_we   = we;
    assign dbg_x    = 9'(waddr[XW-1:0]);
    assign dbg_line = wr_line;
    assign dbg_data = wdata[CW-1 -: 8];

    // ring buffer 16 lines x 2^XW x CW bit (dual-clock BSRAM)
    logic [CW-1:0] mem [0:(16 << XW) - 1];
    always_ff @(posedge clk_core)
        if (we) mem[waddr] <= wdata;

    // ---------------- Read side (clk_pixel, 74.25 MHz) --------------------------------
    logic [2:0] s_meta = 0;
    always_ff @(posedge clk_pixel) begin
        s_meta <= {s_meta[1:0], sync_tgl};
        sync   <= s_meta[2] ^ s_meta[1];
    end

    logic [7:0] rd_line = 0;
    logic [1:0] row3 = 0;
    logic [1:0] xph = 0;
    logic [8:0] rd_x = 0;
    logic       act_y = 0, act_x = 0, act_x_d1 = 0;
    logic [CW-1:0] q;
    wire  [11:0]   q12 = 12'(q);   // q widened, so the RGB444 branch stays in range at CW 8
    // stored pixel -> RGB888: RGB444 doubles each nibble, RGB332 repeats the bits
    wire  [23:0]   rgb_q = RGB444 ? {q12[11:8], q12[11:8], q12[7:4], q12[7:4],
                                     q12[3:0], q12[3:0]}
                                  : {q12[7:5], q12[7:5], q12[7:6],
                                     q12[4:2], q12[4:2], q12[4:3],
                                     q12[1:0], q12[1:0], q12[1:0], q12[1:0]};

    always_ff @(posedge clk_pixel) begin
        if (cx == 11'd0) begin
            if (cy == Y0) begin
                rd_line <= 8'd0;
                row3    <= 2'd0;
                act_y   <= 1'b1;
            end else if (act_y) begin
                if (row3 == 2'd2) begin
                    row3    <= 2'd0;
                    rd_line <= rd_line + 8'd1;
                    if (rd_line == 8'(H - 1)) act_y <= 1'b0;
                end else
                    row3 <= row3 + 2'd1;
            end
        end

        if (cx == X0 - 2) begin
            xph   <= 2'd0;
            rd_x  <= 9'd0;
            act_x <= act_y;
        end else if (act_x) begin
            if (xph == 2'd2) begin
                xph  <= 2'd0;
                rd_x <= rd_x + 9'd1;
                if (rd_x == 9'(W - 1)) act_x <= 1'b0;
            end else
                xph <= xph + 2'd1;
        end

        q        <= mem[{rd_line[3:0], rd_x[XW-1:0]}];
        act_x_d1 <= act_x;
        rgb <= act_x_d1 ? rgb_q : 24'h000000;
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
