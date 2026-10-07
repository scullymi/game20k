//--------------------------------------------
// FPGA DigDug (CPU part)
//
//					Copyright (c) 2017 MiSTer-X
//--------------------------------------------
// game20k: one clock. The bus and CPU clocks of the arbiter are enables of MCLK, each high in
// the MCLK clock in which the old derived clock had its edge. The program of CPU0 comes from
// outside (game_core reads it from SDRAM) and holds CPU0 in wait states until it is there.

`timescale 1 ps / 1 ps

module DIGDUG_CORES
(
	input				MCLK,			// Clock (48.0MHz)   game20k: 46.40625 MHz

	input  [2:0]	RSTS,			// RESET [2:0]
	input  [2:0]	IRQS,			//   IRQ [2:0]
	input  [2:0]	NMIS,			//   NMI [2:0]

	output			DEV_CE,		// I/O device Interface   game20k: bus enable, was DEV_CL
	output [3:0]	DEV_OWN,		// game20k: which CPU has the bus (one-hot, bit 3 = none)
	output [15:0]	DEV_AD,
	output 			DEV_RD,
	input				DEV_DV,
	input  [7:0]	DEV_DO,
	output			DEV_WR,
	output [7:0]	DEV_DI,


	input				ROMCL,		// Downloaded ROM image
	input  [15:0]	ROMAD,
	input	  [7:0]	ROMDT,
	input				ROMEN,

	input				PAUSE,

	// game20k: program ROM of CPU0, read outside the core
	output [13:0]	CPU0_ROMAD,
	output			CPU0_ROMCS,
	input   [7:0]	CPU0_ROMDT,
	input				CPU0_ROMOK
);

wire [2:0] CPUCE, CPUCF;	// game20k: rising and falling edges of the CPU clocks

//-----------------------------------------------
//  CPU0
//-----------------------------------------------
wire [15:0] CPU0AD;
wire			CPU0RD;
wire			CPU0DV;
wire  [7:0]	CPU0DI;
wire			CPU0WR;
wire	[7:0]	CPU0DO;

// game20k: the program comes from outside instead of rom0
wire  [7:0] CPU0IR = CPU0_ROMDT;
assign CPU0_ROMAD = CPU0AD[13:0];
assign CPU0_ROMCS = (CPU0AD[15:14]==2'b00);

wire NMI0;
CPUNMIACK n0( RSTS[0], MCLK, CPUCF[0], CPU0AD, NMIS[0], NMI0 );

CPUCORE cpu0 (
	.RESET(RSTS[0]),.CLK(MCLK),.CEN(CPUCE[0]),
	.IRQ(IRQS[0]),.NMI(NMI0),
	.AD(CPU0AD),.IR(CPU0IR),
	.RD(CPU0RD),.DV(CPU0DV),.DI(CPU0DI),
	.WR(CPU0WR),.DO(CPU0DO),
	.PAUSE(PAUSE),
	.ROMWAIT(CPU0_ROMCS & ~CPU0_ROMOK)
);


//-----------------------------------------------
//  CPU1
//-----------------------------------------------
wire [15:0] CPU1AD;
wire			CPU1RD;
wire			CPU1DV;
wire  [7:0]	CPU1DI;
wire			CPU1WR;
wire	[7:0]	CPU1DO;

wire  [7:0] CPU1IR;
DLROMe #(13,8) rom1( DEV_CE, MCLK, CPU1AD[12:0], CPU1IR, ROMCL,ROMAD[12:0],ROMDT,ROMEN & (ROMAD[15:13]==3'b100) );

CPUCORE cpu1 (
	.RESET(RSTS[1]),.CLK(MCLK),.CEN(CPUCE[1]),
	.IRQ(IRQS[1]),.NMI(NMIS[1]),
	.AD(CPU1AD),.IR(CPU1IR),
	.RD(CPU1RD),.DV(CPU1DV),.DI(CPU1DI),
	.WR(CPU1WR),.DO(CPU1DO),
	.PAUSE(PAUSE),
	.ROMWAIT(1'b0)
);


//-----------------------------------------------
//  CPU2
//-----------------------------------------------
wire [15:0] CPU2AD;
wire			CPU2RD;
wire			CPU2DV;
wire  [7:0]	CPU2DI;
wire			CPU2WR;
wire	[7:0]	CPU2DO;

wire  [7:0] CPU2IR;
DLROMe #(12,8) rom2( DEV_CE, MCLK, CPU2AD[11:0], CPU2IR, ROMCL,ROMAD[11:0],ROMDT,ROMEN & (ROMAD[15:12]==4'hA) ); 

wire NMI2;
CPUNMIACK n2( RSTS[2], MCLK, CPUCF[2], CPU2AD, NMIS[2], NMI2 );

CPUCORE cpu2 (
	.RESET(RSTS[2]),.CLK(MCLK),.CEN(CPUCE[2]),
	.IRQ(IRQS[2]),.NMI(NMI2),
	.AD(CPU2AD),.IR(CPU2IR),
	.RD(CPU2RD),.DV(CPU2DV),.DI(CPU2DI),
	.WR(CPU2WR),.DO(CPU2DO),
	.PAUSE(1'b0),
	.ROMWAIT(1'b0)
);


//-----------------------------------------------
//  CPU Access Arbiter
//-----------------------------------------------
CPUARB arb
(
	MCLK,
	DEV_CE, DEV_OWN, DEV_AD, DEV_RD, DEV_DV, DEV_DO, DEV_WR, DEV_DI,
	CPUCE, CPUCF,
	CPU0AD, CPU0RD, CPU0DV, CPU0DI, CPU0WR, CPU0DO,
	CPU1AD, CPU1RD, CPU1DV, CPU1DI, CPU1WR, CPU1DO,
	CPU2AD, CPU2RD, CPU2DV, CPU2DI, CPU2WR, CPU2DO
);

endmodule


module CPUARB
(
	input					CLK48M,

	output				DEV_CE,
	output  [3:0]		DEV_OWN,
	output [15:0]		DEV_AD,
	output				DEV_RD,
	input					DEV_DV,
	input	  [7:0]		DEV_DO,
	output				DEV_WR,
	output  [7:0]		DEV_DI,

	output  [2:0]		CPUCE,	// game20k: CPUnCL rises in this clock
	output  [2:0]		CPUCF,	// game20k: CPUnCL falls in this clock

	input  [15:0]		CPU0AD,
	input					CPU0RD,
	output				CPU0DV,
	output  [7:0]		CPU0DI,
	input					CPU0WR,
	input	  [7:0]		CPU0DO,
	
	input  [15:0]		CPU1AD,
	input					CPU1RD,
	output				CPU1DV,
	output  [7:0]		CPU1DI,
	input					CPU1WR,
	input	  [7:0]		CPU1DO,

	input  [15:0]		CPU2AD,
	input					CPU2RD,
	output				CPU2DV,
	output  [7:0]		CPU2DI,
	input					CPU2WR,
	input	  [7:0]		CPU2DO
);

// game20k: CLK24M = clkdiv[0] and CLK12M = clkdiv[1] become enables in the clock of their edges
reg [1:0] clkdiv = 2'd0;
always @( posedge CLK48M ) clkdiv <= clkdiv+1'b1;
wire CLK24M_RISE = ~clkdiv[0];
wire CLK12M_RISE = (clkdiv == 2'd1);
wire CLK12M_FALL = (clkdiv == 2'd3);

reg [3:0] BUSS = 4'b0001;
always @( posedge CLK48M ) if (CLK12M_FALL) BUSS <= {BUSS[2:0],BUSS[3]};

reg [2:0] CPUCL = 3'd0;	// game20k: the old CPU0CL..CPU2CL
always @( posedge CLK48M ) if (CLK12M_RISE) CPUCL <= BUSS[2:0];
assign CPUCE = {3{CLK12M_RISE}} &  BUSS[2:0] & ~CPUCL;
assign CPUCF = {3{CLK12M_RISE}} & ~BUSS[2:0] &  CPUCL;

assign DEV_CE  = CLK24M_RISE;
assign DEV_OWN = BUSS;

assign DEV_AD = BUSS[0] ? CPU0AD :
					 BUSS[1] ? CPU1AD :
					 BUSS[2] ? CPU2AD : 16'd0000;

assign DEV_RD = BUSS[0] ? CPU0RD :
					 BUSS[1] ? CPU1RD :
					 BUSS[2] ? CPU2RD : 1'b0;

assign CPU0DV = BUSS[0] ? DEV_DV : 1'b0;
assign CPU1DV = BUSS[1] ? DEV_DV : 1'b0;
assign CPU2DV = BUSS[2] ? DEV_DV : 1'b0;

assign CPU0DI = BUSS[0] ? DEV_DO : 8'h00;
assign CPU1DI = BUSS[1] ? DEV_DO : 8'h00;
assign CPU2DI = BUSS[2] ? DEV_DO : 8'h00;

assign DEV_WR = BUSS[0] ? CPU0WR :
					 BUSS[1] ? CPU1WR :
					 BUSS[2] ? CPU2WR : 1'b0;

assign DEV_DI = BUSS[0] ? CPU0DO :
					 BUSS[1] ? CPU1DO :
					 BUSS[2] ? CPU2DO : 8'h00;

endmodule
