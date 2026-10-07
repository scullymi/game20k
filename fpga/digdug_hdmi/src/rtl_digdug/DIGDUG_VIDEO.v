//--------------------------------------------
// FPGA DigDug (Video part)
//
//					Copyright (c) 2017 MiSTer-X
//--------------------------------------------
// game20k: one clock CLK48M. VCLK and VCLKx2 are enables of their edges, PCLK is the pixel
// enable (one clock per pixel where the old PCLK = ~VCLK rose), FGSCCL the read enable of the
// FG VRAM port.

`timescale 1 ps / 1 ps

module DIGDUG_VIDEO
(
	input					CLK48M,
	input	  [8:0]		POSH,
	input	  [8:0]		POSV,

	input	  [1:0]		BG_SELECT,
	input   [1:0]		BG_COLBNK,
	input					BG_CUTOFF,
	input					FG_CLMODE,

	output				FGSCCL,	// game20k: enable
	output  [9:0]		FGSCAD,
	input   [7:0]		FGSCDT,

	output				SPATCL,
	output  [6:0]		SPATAD,
	input	 [23:0]		SPATDT,

	output				VBLK,
	output				PCLK,	// game20k: pixel enable
	output  [7:0]		POUT,

	input 				V_FLIP,

	input					ROMCL,		// Downloaded ROM image
	input  [15:0]		ROMAD,
	input	  [7:0]		ROMDT,
	input					ROMEN
);

//---------------------------------------
//  Clock Generator
//---------------------------------------
reg [2:0] clkdiv = 3'd0;	// game20k: initialised
always @( posedge CLK48M ) clkdiv <= clkdiv+1'b1;
wire VCLKx8 = CLK48M;
// game20k: VCLKx2 = clkdiv[1] and VCLK = clkdiv[2] become enables in the clock of their edges
wire VCLKx2_RISE = (clkdiv[1:0] == 2'd1);
wire VCLKx2_FALL = (clkdiv[1:0] == 2'd3);
wire VCLK_RISE   = (clkdiv == 3'd3);
wire VCLK_FALL   = (clkdiv == 3'd7);


//---------------------------------------
//  Local Offset
//---------------------------------------
reg [8:0] PH, PV;
reg [8:0] SPH, SPV;
always@( posedge CLK48M ) if (VCLK_RISE) begin	// game20k
	PH <= V_FLIP ? (9'd286 - POSH) : POSH + 9'd1;
	PV <= V_FLIP ? (9'd223 - POSV) : POSV+(POSH>=9'd504);
	SPH <= POSH;
	SPV <= POSV+(POSH>=9'd504);
end

//---------------------------------------
//  VRAM Scan Address Generator
//---------------------------------------
wire  [5:0] SCOL = PH[8:3]-2'd2;
wire  [5:0] SROW = PV[8:3]+2'd2;
wire  [9:0] VSAD = SCOL[5] ? {SCOL[4:0],SROW[4:0]} : {SROW[4:0],SCOL[4:0]};


//---------------------------------------
//  Sprite ScanLine Generator
//---------------------------------------
wire  [4:0]	SPCOL;

DIGDUG_SPRITE sprite
(
	.RCLK(VCLKx8),.VCLK_RISE(VCLK_RISE),.VCLK_FALL(VCLK_FALL),.VCLKx2_RISE(VCLKx2_RISE),	// game20k
	.POSH(SPH),.POSV(SPV),
	.SPATCL(SPATCL),.SPATAD(SPATAD),.SPATDT(SPATDT),

	.SPCOL(SPCOL),
	.V_FLIP(V_FLIP),
	.ROMCL(ROMCL),.ROMAD(ROMAD),.ROMDT(ROMDT),.ROMEN(ROMEN)
);


//---------------------------------------
//  FG ScanLine Generator
//---------------------------------------
reg   [4:0] FGCOL;

assign		FGSCCL = VCLKx2_RISE;	// game20k
assign 		FGSCAD = VSAD;

wire [10:0]	FGCHAD = {1'b0,FGSCDT[6:0],PV[2:0]};
wire  [7:0]	FGCHDT;
DLROMe #(11,8) fgchip(VCLKx2_FALL,CLK48M,	// game20k
	FGCHAD,FGCHDT, ROMCL,ROMAD[10:0],ROMDT,ROMEN & (ROMAD[15:11]=={4'hD,1'b0}));
wire  [7:0] FGCHPX = FGCHDT >> (PH[2:0]);

wire  [3:0] FGCLUT = FG_CLMODE ? FGSCDT[3:0] : ({FGSCDT[7:5],1'b0}|{2'b00,FGSCDT[4],1'b0});

always @( posedge CLK48M ) if (VCLKx2_RISE) FGCOL <=	// game20k
	 {FGCHPX[0],FGCLUT};


//---------------------------------------
//  BG ScanLine Generator
//---------------------------------------
wire  [3:0] BGCOL;

wire [11:0] BGSCAD = {BG_SELECT,VSAD};
wire  [7:0] BGSCDT;
DLROMe #(12,8) bgscrn(VCLKx2_RISE,CLK48M,	// game20k
	BGSCAD,BGSCDT, ROMCL,ROMAD[11:0],ROMDT,ROMEN & (ROMAD[15:12]==4'hB));

wire [11:0] BGCHAD = {BGSCDT,~PH[2],PV[2:0]};
wire  [7:0] BGCHDT;
DLROMe #(12,8) bgchip(VCLKx2_FALL,CLK48M,	// game20k
	BGCHAD,BGCHDT, ROMCL,ROMAD[11:0],ROMDT,ROMEN & (ROMAD[15:12]==4'hC));
wire  [7:0] BGCHPI = BGCHDT << (PH[1:0]);
wire  [1:0] BGCHPX = {BGCHPI[7],BGCHPI[3]};

wire  [7:0] BGCLAD = BG_CUTOFF ? {6'h0F,BGCHPX} : {BG_COLBNK,BGSCDT[7:4],BGCHPX};
DLROMe #(8,4) bgclut(VCLKx2_RISE,CLK48M,	// game20k
	BGCLAD,BGCOL, ROMCL,ROMAD[7:0],ROMDT[3:0],ROMEN & (ROMAD[15:8]==8'hDA));


//---------------------------------------
//  Color Mixer & Pixel Output
//---------------------------------------
wire [4:0] CMIX = SPCOL[4] ? {1'b1,SPCOL[3:0]} : FGCOL[4] ? {1'b0,FGCOL[3:0]} : {1'b0,BGCOL};

DLROMe #(5,8) palet( VCLK_RISE,CLK48M,	// game20k
	 CMIX, POUT, ROMCL,ROMAD[4:0],ROMDT,ROMEN & (ROMAD[15:5]=={8'hDB,3'b000}) );
assign PCLK = VCLK_FALL;	// game20k: was ~VCLK
assign VBLK = (PH<9'd64)&(PV==9'd224);

endmodule

