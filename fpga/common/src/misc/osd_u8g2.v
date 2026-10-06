// SPDX-License-Identifier: GPL-3.0-or-later
/*
    osd_u8g2.v
 
    on-screen-display using a memory layout that matches the 
    one of 128x64 OLED displays and is thus supported by u8g2
  */

// game20k: MODIFIED VERSION of MiSTeryNano src/misc/osd_u8g2.v (Till Harbaum).
// Some changes are marked "game20k" in the text, not all: the complete list is the diff
// against the upstream commit named in the README of this folder. Till Harbaum's file is
// GPL-3.0-or-later, the game20k changes are too, Copyright (C) 2026 scullymi.

module osd_u8g2 (
  input        clk,
  input        reset,
  input        rotate,   // game20k: 1 = OSD rotated 90 degrees counter-clockwise (top = left, like the unrotated game picture)
  input        flip,     // game20k: with rotate, 180 degrees more (top = right), for games whose monitor turns the other way (ROT270)

  input        data_in_strobe,
  input        data_in_start,
  input [7:0]  data_in,
	    
  input        hs,
  input        vs, 
  input [5:0]  r_in,
  input [5:0]  g_in,
  input [5:0]  b_in,

  output [5:0] r_out,
  output [5:0] g_out,
  output [5:0] b_out,
  output       visible   // game20k: OSD visible
);

// OSD is enabled and visible
reg enabled;
assign visible = enabled;

// -------------------------- OSD painting -------------------------------

reg vsD, hsD;
reg [11:0] hcnt;    // signal ranges 0..1023
reg [11:0] hcntL;
reg [9:0] vcnt;    // signal ranges 0..626
reg [9:0] vcntL;

// OSD is active on current pixel, the shadow is active or the text area is active
wire active, sactive, tactive;
   
// draw active osd, add some shadow to those parts outside osd
// that are covered by shadow
assign r_out = !enabled?r_in:active?osd_r:sactive?{1'b0, r_in[5:1]}:r_in;
assign g_out = !enabled?g_in:active?osd_g:sactive?{1'b0, g_in[5:1]}:g_in;
assign b_out = !enabled?b_in:active?osd_b:sactive?{1'b0, b_in[5:1]}:b_in;   

wire	   osd_pix;  
wire [5:0] osd_pix_col;

// background is darker where "shadow" is active
wire [5:0] osd_r = (tactive && osd_pix)?osd_pix_col:sactive?{4'b0000, r_in[5:4]}:{3'b000, r_in[5:3]};
wire [5:0] osd_g = (tactive && osd_pix)?osd_pix_col:sactive?{4'b0100, g_in[5:4]}:{3'b010, g_in[5:3]};
wire [5:0] osd_b = (tactive && osd_pix)?osd_pix_col:sactive?{4'b0000, b_in[5:4]}:{3'b000, b_in[5:3]};  
   
`define BORDER 2
`define SHADOW 4
`define SCALE  4   // game20k: 720p
`define WIDTH 16   // OSD width in characters
`define HEIGHT 8   // OSD height in characters

// game20k: box size in picture pixels, swapped when rotated. The geometry is registered (it
// changes once per line or frame at most), the area flags are computed one pixel ahead so that the path to the HDMI input stays short.
reg [11:0] bw = 8*`WIDTH*`SCALE;
reg [9:0]  bh = 8*`HEIGHT*`SCALE;
reg [11:0] hstart = 0;
reg [9:0]  vstart = 0;
always @(posedge clk) begin
   bw     <= rotate ? 8*`HEIGHT*`SCALE : 8*`WIDTH*`SCALE;
   bh     <= rotate ? 8*`WIDTH*`SCALE  : 8*`HEIGHT*`SCALE;
   hstart <= (hcntL/2)-bw/2;
   vstart <= (vcntL/2)-bh/2;
end

wire [11:0] hn = hcnt + 12'd1;   // next pixel
reg hactive, vactive, thactive, tvactive, shactive, svactive;
always @(posedge clk) begin
   // entire OSD area incl border
   hactive  <= hn >= hstart-`SCALE*`BORDER && hn < hstart+`SCALE*`BORDER+bw;
   vactive  <= vcnt >= vstart-`SCALE*`BORDER && vcnt < vstart+`SCALE*`BORDER+bh;
   // text area of OSD
   thactive <= hn >= hstart && hn < hstart+bw;
   tvactive <= vcnt >= vstart && vcnt < vstart+bh;
   // shadow area of OSD
   shactive <= hn >= hstart-`SCALE*`BORDER+`SCALE*`SHADOW && hn < hstart+`SCALE*`BORDER+`SCALE*`SHADOW+bw;
   svactive <= vcnt >= vstart-`SCALE*`BORDER+`SCALE*`SHADOW && vcnt < vstart+`SCALE*`BORDER+`SCALE*`SHADOW+bh;
end
assign active  = hactive && vactive;
assign tactive = thactive && tvactive;
assign sactive = shactive && svactive;

// 1024 bytes = 8192 pixels = 128 x 64 pixels
reg [7:0] buffer [1024];  

// external data interface to write to buffer
reg [9:0] data_cnt;
reg [7:0] command;
reg data_addr_state;
   
always @(posedge clk) begin
    if(reset) begin
        enabled <= 1'b0;

    end else begin

      if(data_in_strobe) begin
        if(data_in_start) begin
            command <= data_in;
            data_addr_state <= 1'b1;
            data_cnt <= 10'd0;
        end else begin
            data_addr_state <= 1'b0;

            // OSD command 1: enabled (show) or disable (hide) OSD
            if((command == 8'd1) && data_addr_state)
                enabled <= data_in[0];   // en/disable

            // OSD command 2: display data for give tile
            if(command == 8'd2) begin
                if(data_addr_state)
                    data_cnt <= { data_in[6:0], 3'b000 };
                else begin	 
                    buffer[data_cnt] <= data_in;
                    data_cnt <= data_cnt + 10'd1;
                end
            end
         end
      end
   end
end
   
// game20k: SCALE 4 -> text area 512 x 256 pixels, 128 x 64 cells
wire [11:0] hpix  = hcnt-hstart;      // horizontal pixel position inside OSD   
wire [11:0] hpixD = hpix+12'd1;       // latch byte one pixel in advance
wire [9:0]  vpix  = vcnt-vstart;      // vertical pixel position inside OSD   

// upright: page = vpix/32, column = hpix/4, bit = (vpix/4)%8
// rotated (counter-clockwise): page = hpix/32, column = 127 - vpix/4, bit = (hpix/4)%8
// rotated and flipped (clockwise): page = 7 - hpix/32, column = vpix/4, bit = 7 - (hpix/4)%8
wire [9:0] buf_addr = !rotate ? { vpix[7:5], hpixD[8:2] } :
                      flip    ? { ~hpixD[7:5], vpix[8:2] } : { hpixD[7:5], ~vpix[8:2] };
reg  [2:0] buf_bit;
always @(posedge clk)
   buf_bit <= !rotate ? vpix[4:2] : flip ? ~hpixD[4:2] : hpixD[4:2];   // one pixel ahead, in step with buffer_byte
assign osd_pix = buffer_byte[buf_bit];

reg [7:0] buffer_byte;
always @(posedge clk)
   buffer_byte <= buffer[buf_addr];
   
assign osd_pix_col = 6'd63;

// -------------------------- video signal analysis -------------------------
   
// analyze video timing to determine center of screen

always @(posedge clk) begin
   // ---- hsync processing -----
   hsD <= hs;

   // end of hsync, rising edge
   if(hs && !hsD) begin
      hcntL <= hcnt;
      hcnt <= 0;
   end else
     hcnt <= hcnt + 12'd1;
   
   if(hs && !hsD) begin
      // ---- vsync processing -----
      vsD <= vs;
      // begin of vsync, falling edge
      if(!vs && vsD) begin
         vcntL <= vcnt;
         vcnt <= 0;
      end else
        vcnt <= vcnt + 10'd1;
   end
end
   
endmodule
