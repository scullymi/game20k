//--------------------------------------------
// FPGA DigDug (Top module)
//
//					Copyright (c) 2017 MiSTer-X
//--------------------------------------------
// game20k: everything runs on MCLK (46.40625 MHz), the derived clocks of the core are enables.
// PCLK is the pixel enable, ROMCL must be MCLK. The program of CPU0 is read outside (CPU0_ROM*),
// the hiscore port is gone, and MIR_* report every CPU write into the four shared RAMs for the
// RetroAchievements RAM mirror. The 06XX sees one write strobe per CPU write (DEV_WR1).

`timescale 1 ps / 1 ps

module FPGA_DIGDUG
(
	input          RESET,      // RESET
	input          MCLK,       // Master Clock (48.0MHz) = VCLKx8   game20k: 46.40625 MHz

	input   [7:0]	INP0,			// Control Panel
	input   [7:0]	INP1,
	input   [7:0]	DSW0,
	input   [7:0]	DSW1,

	input   [8:0]  PH,         // PIXEL H
	input   [8:0]  PV,         // PIXEL V
	output         PCLK,       // PIXEL CLOCK   game20k: pixel enable
	output  [7:0]  POUT,       // PIXEL OUT

	output reg [7:0] SOUT,		// SOUND OUT

	output  [7:0]	LED,		// LEDs (for Debug)

	input 			V_FLIP,		// Vertical flip video

	input				ROMCL,	// Downloaded ROM image
	input  [15:0]	ROMAD,
	input	  [7:0]	ROMDT,
	input				ROMEN,

	input 			PAUSE,

	// game20k: program ROM of CPU0 (16 KB), read outside the core. OK is high when DT belongs to AD
	output [13:0]	CPU0_ROMAD,
	output			CPU0_ROMCS,
	input   [7:0]	CPU0_ROMDT,
	input				CPU0_ROMOK,

	// game20k: one clock per CPU write into the shared RAMs, AD in the FBNeo/RA layout:
	// 0x0000 RAM 0 (8000-87FF), 0x0800 RAM 1 (8800-8BFF), 0x0C00 RAM 2 (9000-93FF), 0x1000 RAM 3
	// (9800-9BFF). Writes to the unused upper halves of RAM 1..3 are not reported.
	output reg		MIR_WE,
	output reg [12:0] MIR_AD,
	output reg  [7:0] MIR_DT
);

// Common I/O Device Bus
wire			DEV_CL;		// game20k: the bus enable (DEV_CE of DIGDUG_CORES)
wire  [3:0]	DEV_OWN;	// game20k
wire [15:0]	DEV_AD;
wire			DEV_RD;
wire			DEV_DV;
wire  [7:0]	DEV_DO;
wire			DEV_WR;
wire			DEV_WR1;	// game20k: the first bus enable of a write cycle
wire  [7:0]	DEV_DI;


//-----------------------------------------------
//  CPUs
//-----------------------------------------------
wire	[2:0]	RSTS,IRQS,NMIS;

DIGDUG_CORES cores
(
	.MCLK(MCLK),
	.RSTS(RSTS),.IRQS(IRQS),.NMIS(NMIS),

	.DEV_CE(DEV_CL),.DEV_OWN(DEV_OWN),.DEV_AD(DEV_AD),	// game20k
	.DEV_RD(DEV_RD),.DEV_DV(DEV_DV),.DEV_DO(DEV_DO),
	.DEV_WR(DEV_WR),.DEV_DI(DEV_DI),

	.ROMCL(ROMCL),.ROMAD(ROMAD),.ROMDT(ROMDT),.ROMEN(ROMEN),

	.PAUSE(PAUSE),

	.CPU0_ROMAD(CPU0_ROMAD),.CPU0_ROMCS(CPU0_ROMCS),.CPU0_ROMDT(CPU0_ROMDT),.CPU0_ROMOK(CPU0_ROMOK)	// game20k
);

assign LED = { RSTS, IRQS[1:0], 1'b0, NMIS[2],NMIS[0] };


//-----------------------------------------------
//  Sound wave ROM
//-----------------------------------------------
wire 			WAVECL;
wire [7:0]	WAVEAD;
wire [3:0]	WAVEDT;

DLROMe #(8,4) wave(WAVECL,MCLK,	// game20k: WAVECL is a read enable
	WAVEAD,WAVEDT, ROMCL,ROMAD[7:0],ROMDT[3:0],ROMEN & (ROMAD[15:8]==8'hD8));


//-----------------------------------------------
//  Common I/O Device Module
//-----------------------------------------------
wire			PCMCLK;
wire [7:0]	PCMOUT;
always @(posedge MCLK) if (PCMCLK) SOUT <= PCMOUT;	// game20k: PCMCLK is an enable

wire			FGSCCL;
wire [9:0]	FGSCAD;
wire [7:0]	FGSCDT;

wire			SPATCL;
wire [6:0]	SPATAD;
wire [23:0]	SPATDT;

wire [1:0]	BG_SELECT;
wire [1:0]	BG_COLBNK;
wire			BG_CUTOFF;
wire			FG_CLMODE;

wire			VBLK;

DIGDUG_IODEV iodev
(
	.RESET(RESET),
	.VBLK(VBLK),
	.SNDNMI((PV==9'd64)|(PV==9'd192)),	// game20k: sound CPU NMI in lines 64 and 192

	.INP0(INP0),
	.INP1(INP1),
	.DSW0(DSW0),
	.DSW1(DSW1),
	
	.CL(DEV_CL), // Access Clock: 24.0MHz
	.AD(DEV_AD),.WR(DEV_WR),.WR1(DEV_WR1),.DI(DEV_DI),	// game20k: WR1
	.RD(DEV_RD),.DV(DEV_DV),.DO(DEV_DO),
	
	.RSTS(RSTS),.IRQS(IRQS),.NMIS(NMIS),

	.CLK48M(MCLK),.PCMCLK(PCMCLK),.PCMOUT(PCMOUT),

	.WAVECL(WAVECL),.WAVEAD(WAVEAD),.WAVEDT(WAVEDT),

	.FGSCCL(FGSCCL),.FGSCAD(FGSCAD),.FGSCDT(FGSCDT),
	.SPATCL(SPATCL),.SPATAD(SPATAD),.SPATDT(SPATDT),

	.BG_SELECT(BG_SELECT),.BG_COLBNK(BG_COLBNK),.BG_CUTOFF(BG_CUTOFF),
	.FG_CLMODE(FG_CLMODE),	// game20k: no hiscore port

	.ROMAD(ROMAD),.ROMDT(ROMDT),.ROMEN(ROMEN)	// game20k: the 51XX and 53XX programs
);


//-----------------------------------------------
//  Video Module
//-----------------------------------------------
DIGDUG_VIDEO video
(
	.CLK48M(MCLK),
	.POSH(PH),.POSV(PV),

	.BG_SELECT(BG_SELECT),.BG_COLBNK(BG_COLBNK),.BG_CUTOFF(BG_CUTOFF),
	.FG_CLMODE(FG_CLMODE),

	.FGSCCL(FGSCCL),.FGSCAD(FGSCAD),.FGSCDT(FGSCDT),
	.SPATCL(SPATCL),.SPATAD(SPATAD),.SPATDT(SPATDT),

	.VBLK(VBLK),.PCLK(PCLK),.POUT(POUT),
	
	.V_FLIP(V_FLIP),

	.ROMCL(ROMCL),.ROMAD(ROMAD),.ROMDT(ROMDT),.ROMEN(ROMEN)
);



//-----------------------------------------------
//  game20k: RAM write taps for the RA mirror
//-----------------------------------------------
// A CPU's bus state is seen at two bus enables in a row, so the first enable of a write cycle
// reports it and the next one of the same CPU without a write re-arms. WRSEEN is per CPU. The
// report comes in the clock the RAM is written. DEV_WR1 is that first enable for every
// address, the 06XX takes it as its write strobe.
reg  [2:0] WRSEEN = 3'd0;
wire       MIRCS0 = (DEV_AD[15:11] == 5'b1000_0);					// 8000-87FF
wire       MIRCS1 = (DEV_AD[15:10] == 6'b1000_10);					// 8800-8BFF
wire       MIRCS2 = (DEV_AD[15:10] == 6'b1001_00);					// 9000-93FF
wire       MIRCS3 = (DEV_AD[15:10] == 6'b1001_10);					// 9800-9BFF
wire [1:0] OWN    = DEV_OWN[0] ? 2'd0 : DEV_OWN[1] ? 2'd1 : 2'd2;
always @(posedge MCLK)
	if (DEV_CL & ~DEV_OWN[3]) WRSEEN[OWN] <= DEV_WR;
assign DEV_WR1 = DEV_CL & ~DEV_OWN[3] & DEV_WR & ~WRSEEN[OWN];
always @(*) begin
	MIR_WE = DEV_WR1 & (MIRCS0|MIRCS1|MIRCS2|MIRCS3);
	MIR_DT = DEV_DI;
	MIR_AD = MIRCS0 ? {2'b00, DEV_AD[10:0]} :
	         MIRCS1 ? {3'b010, DEV_AD[9:0]} :
	         MIRCS2 ? {3'b011, DEV_AD[9:0]} :
	                  {3'b100, DEV_AD[9:0]};
end

endmodule
