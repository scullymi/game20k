//--------------------------------------------
// FPGA DigDug (Sprite part)
//
//					Copyright (c) 2017 MiSTer-X
//--------------------------------------------
// game20k: VCLK and VCLKx2 are enables of RCLK in the clock of their edges.

`timescale 1 ps / 1 ps

module DIGDUG_SPRITE
(
	input				RCLK,			// Rendering Clock
	input				VCLK_RISE,	// game20k: enables of the Video Dot Clock edges
	input				VCLK_FALL,
	input				VCLKx2_RISE,	// game20k: enable of the Dot Clockx2 rising edge
	
	input  [8:0] 	POSH, 
	input  [8:0] 	POSV,

	output			SPATCL,
	output [6:0]	SPATAD,
	input [23:0]	SPATDT,

	output reg [4:0] SPCOL,
	
	input 			V_FLIP,

	input				ROMCL,		// Downloaded ROM image
	input  [15:0]	ROMAD,
	input	  [7:0]	ROMDT,
	input				ROMEN
);

wire [8:0] PH = POSH+9'd1;
// game20k: PV is held for the whole pass, from its start at PH 289. POSV moves on at POSH 504
// (DIGDUG_VIDEO.v), and a sprite drawn after that landed one line off. With the 384-pixel line
// this needs more than 696 clocks of sprites in one line, with the 360-pixel line of game20k
// more than 504, which the title screen has (simulation against MAME).
wire [8:0] PVIN = V_FLIP ? (9'd221 - POSV) : POSV + 9'd2;
reg  [8:0] PV;
wire [8:0] TY;


reg  [3:0] PHASE;
reg		  SIDE;

reg  [7:0] ADR;
reg [23:0] ATR0, ATR1;

reg  [8:0] WXP;
reg  [8:0] WCN;


wire 		  SZ = ATR0[7];													// Size
wire [8:0] SS = SZ ? 9'd32 : 9'd16;										// Size (Pixels)
wire [5:0] SC = ATR1[5:0];													// Color
wire [8:0] SX = {1'b0,ATR1[15:8]}-9'd39;								// Position X
wire [8:0] SY = (9'd256-TY);												// Position Y
wire [8:0] SU = (SS-WCN)^{9{ATR0[16]}};								// Position U
wire [8:0] SV = (PV-SY )^{9{ATR0[17]}};								// Position V
wire [7:0] SM = ATR0[7:0];													// Code (for Normal)
wire [7:0] SL = {SM[7]|SM[5],SM[6]|SM[4],SM[3:0],SV[4],SU[4]};	// Code (for Size)
wire [7:0] SN = SZ ? SL : SM;												// Code
wire		  SD = ATR1[17]|((PV<SY)&(SY<496))|(PV>=(SY+SS));		// Visiblity (False:Visible)

assign TY = ((({1'b0,ATR0[15:8]}+1'b1)+(SZ ? 9'd16 : 9'd0)) & 9'd255) + 9'd30;

wire	ABORT	  = (PH==288);
wire 	STANDBY = (PH!=289);
wire	ATRTAIL = (ADR[7]);
wire	DRAWING = (WCN!=1);


assign SPATCL = ~RCLK;
assign SPATAD = ADR[6:0];

wire [8:0] WSX = {1'b0,SX[7:0]} + ((SX[7:0]<8'd16) ? 9'd256 : 9'd0);

always @( posedge RCLK ) begin
	if (ABORT) begin PHASE <= 4'd0; WCN <= 9'd0; end
	else case (PHASE)
	`define LOOP	(PHASE)
	`define NEXT	(PHASE+1'b1)
	`define NXTA	(4'd1)
		0: begin SIDE <= PVIN[0]; PV <= PVIN; ADR <= 8'd0; WCN <= 9'd0; 	PHASE <= STANDBY ? `LOOP :	`NEXT; end	// game20k: PV held
		1: begin 												PHASE <= ATRTAIL ? `NXTA : `NEXT; end
		2: begin ATR0 <= SPATDT; ADR <= ADR+1'b1;		PHASE <= 						`NEXT; end
		3: begin ATR1 <= SPATDT; ADR <= ADR+1'b1;		PHASE <= 			         `NEXT; end
		4: begin WXP  <= WSX;	 WCN <= SS;				PHASE <=      SD ? `NXTA :	`NEXT; end
					// CHIP Read 
		5: begin /* CLUT Read */ 							PHASE <= 						`NEXT; end
					// LBUF Write
		6: begin WXP <= WXP+1'b1; WCN <= WCN-1'b1;	PHASE <= DRAWING ?  4'd5 :	`NXTA; end
		default:;
	endcase
end

wire [7:0] CHRD;
DLROMe #(14,8) spchip((PHASE==4'd5),~RCLK,{SN,SV[3],SU[3:2],SV[2:0]},CHRD, ROMCL,ROMAD[13:0],ROMDT,ROMEN & (ROMAD[15:14]==2'b01));
wire [7:0] PIX = CHRD << (SU[1:0]);

wire [7:0] WDT;
DLROMe #(8,8)  spclut((PHASE==4'd5), RCLK,{SC,PIX[7],PIX[3]},WDT, ROMCL,ROMAD[7:0],ROMDT,ROMEN & (ROMAD[15:8]==8'hD9));

reg [9:0] radr0=0,radr1=1;	// game20k: declared before its first use (Gowin EX3638)
wire [4:0] LBOUT;
wire [2:0] unused;
wire [8:0] POSH_READ = V_FLIP ? 9'd287-PH : PH;
LBUF1K lbuf (
	  ~RCLK, (PHASE==4'd6), {SIDE,WXP}, (PHASE==4'd6) & (PIX[7]|PIX[3]), {4'h1,WDT[3:0]},	// game20k: OWN0
	 RCLK, VCLKx2_RISE, {~SIDE,POSH_READ}, (radr0==radr1), 8'h0, {unused, LBOUT}	// game20k: RCLK with enable
);

always @(posedge RCLK) if (VCLK_RISE) radr0 <= {~SIDE,PH};	// game20k: was posedge VCLK
always @(posedge RCLK) if (VCLK_FALL) begin	// game20k: was negedge VCLK
	if (radr0!=radr1) SPCOL <= LBOUT;
	radr1 <= radr0;
end

endmodule

