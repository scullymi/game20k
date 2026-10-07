//--------------------------------------------
// Dualport RAM modules for FPGA DigDug
//
//					Copyright (c) 2017 MiSTer-X
//--------------------------------------------
// game20k: every port runs on the master clock (or its inverse) with an enable instead of a
// derived clock. The CPU-side ports write in Gowin's normal mode (output held during a write):
// read-before-write on a dual-port block is refused by the GW2AR-18C place and route (PA2122),
// and no reader uses the output of a write cycle.

`timescale 1 ps / 1 ps

module DPR2KV
(
	input					CL0,
	input					CE0,		// game20k: enable of port 0
	input	[10:0]		AD0,
	input					EN0,
	input					WR0,
	input  [7:0]		DI0,
	output [7:0]		DO0,
	
	input					CL1,
	input					CE1,		// game20k: enable of port 1
	input	[10:0]		AD1,
	output [7:0]		DO1
);

DPR2K ram(
	CL0, AD0, EN0 & CE0, WR0,  DI0, DO0,
	CL1, AD1, CE1, 1'b0, 8'h0, DO1
);

endmodule


module DPR2K
(
	input					CL0,
	input	[10:0]		AD0,
	input					EN0,
	input					WR0,
	input  [7:0]		DI0,
	output reg [7:0]	DO0,
	
	input					CL1,
	input	[10:0]		AD1,
	input					EN1,
	input					WR1,
	input  [7:0]		DI1,
	output reg [7:0]	DO1
);

reg [7:0] core[0:2047] /* synthesis ramstyle = "no_rw_check, M10K" */;

// game20k: normal write mode, see the head of this file
always @( posedge CL0 ) begin
	if (EN0) begin
		if (!WR0) DO0 <= core[AD0];
		if (WR0) core[AD0] <= DI0;
	end
end

// game20k: port 1 only reads, nothing in the core writes through it (WR1 is 0)
always @( posedge CL1 ) begin
	if (EN1) DO1 <= core[AD1];
end

endmodule


// game20k: the line buffer is written here directly instead of through dpram.v (Jim Gregory),
// as a simple dual-port memory: Gowin builds the upstream form, where port 1 reads a pixel and
// clears it later, as a dual-port block in read-before-write mode, which the GW2AR-18C place
// and route refuses (PA2122). Port 1 now only reads, and its clear (WR1, always with DI1) is
// queued and written through port 0 in the next clock of CL0 that the sprite engine does not
// own (OWN0, its pixel phase, every second clock at most). Port 0 is switched on OWN0, not on
// the pixel, which keeps the half-clock path to the address short. The clear goes to the other
// half of the buffer and lands within two clocks, before the address is read again.
module LBUF1K
(
	input				CL0,
	input				OWN0,		// game20k: the sprite engine owns port 0 in this clock
	input	 [9:0]	AD0,
	input				WR0,
	input  [7:0]	DI0,
	
	input				CL1,
	input				CE1,		// game20k: enable of port 1
	input	 [9:0]	AD1,
	input				WR1,
	input  [7:0]	DI1,
	output reg [7:0]	DO1
);

reg [7:0] lbmem[0:1023];

reg       clr_req = 1'b0, clr_ack = 1'b0;
reg [9:0] clr_ad;
reg [7:0] clr_dt;
always @(posedge CL1) begin
	if (CE1) begin
		if (!WR1) DO1 <= lbmem[AD1];
		else if (clr_req == clr_ack) begin
			clr_ad  <= AD1;
			clr_dt  <= DI1;
			clr_req <= ~clr_req;
		end
	end
end

always @(posedge CL0) begin
	if (OWN0) begin
		if (WR0) lbmem[AD0] <= DI0;
	end
	else if (clr_req != clr_ack) begin
		lbmem[clr_ad] <= clr_dt;
		clr_ack <= ~clr_ack;
	end
end

endmodule


module DLROM #(parameter AW,parameter DW)
(
	input							CL0,
	input [(AW-1):0]			AD0,
	output reg [(DW-1):0]	DO0,

	input							CL1,
	input [(AW-1):0]			AD1,
	input	[(DW-1):0]			DI1,
	input							WE1
);

reg [DW-1:0] core[0:((2**AW)-1)] /* synthesis ramstyle = "no_rw_check, M10K" */;

always @(posedge CL0) DO0 <= core[AD0];
always @(posedge CL1) if (WE1) core[AD1] <= DI1;

endmodule


module DLROMe #(parameter AW,parameter DW)
(
	input							RE0,
	input							CL0,
	input [(AW-1):0]			AD0,
	output reg [(DW-1):0]	DO0,

	input							CL1,
	input [(AW-1):0]			AD1,
	input	[(DW-1):0]			DI1,
	input							WE1
);

reg [DW-1:0] core[0:((2**AW)-1)] /* synthesis ramstyle = "no_rw_check, M10K" */;

always @(posedge CL0) if (RE0) DO0 <= core[AD0];
always @(posedge CL1) if (WE1) core[AD1] <= DI1;

endmodule
