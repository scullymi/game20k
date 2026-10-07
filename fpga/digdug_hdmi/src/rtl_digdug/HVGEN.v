//--------------------------------------------
// FPGA DigDug (Video timing part)
//
//					Copyright (c) 2017 MiSTer-X
//--------------------------------------------
// game20k: clocked by CLK with the pixel enable PCLK. The raster is 360 x 264 instead of
// 384 x 263: H runs 0..318, then 471..511 (was 0..342), V 0..233, then 482..511 (was 483). At
// 46.40625 MHz and 8 clocks per pixel one frame is then exactly 1584 x 768 HDMI clocks.

`timescale 1 ps / 1 ps

module HVGEN
(
	output  [8:0]		HPOS,
	output  [8:0]		VPOS,
	input				CLK,		// game20k
	input 				PCLK,		// game20k: pixel enable
	input	 [11:0]		iRGB,

	output reg [11:0]	oRGB,
	output reg			HBLK = 1,
	output reg			VBLK = 1,
	output reg			HSYN = 1,
	output reg			VSYN = 1
);

reg [8:0] hcnt = 0;
reg [8:0] vcnt = 0;

assign HPOS = hcnt;
assign VPOS = vcnt;

always @(posedge CLK) if (PCLK) begin	// game20k
	case (hcnt)
		288: begin HBLK <= 1; hcnt <= hcnt+1'b1; end
		296: begin HSYN <= 0; hcnt <= hcnt+1'b1; end	// game20k: was 311
		318: begin HSYN <= 1; hcnt <= 471;    end	// game20k: was 342
		511: begin HBLK <= 0; hcnt <= 0;
			case (vcnt)
				223: begin VBLK <= 1; vcnt <= vcnt+1'b1; end
				226: begin VSYN <= 0; vcnt <= vcnt+1'b1; end
				233: begin VSYN <= 1; vcnt <= 482;	  end	// game20k: was 483, 264 lines
				511: begin VBLK <= 0; vcnt <= 0;		  end
				default: vcnt <= vcnt+1'b1;
			endcase
		end
		default: hcnt <= hcnt+1'b1;
	endcase
	oRGB <= (HBLK|VBLK) ? 12'h0 : iRGB;
end

endmodule
