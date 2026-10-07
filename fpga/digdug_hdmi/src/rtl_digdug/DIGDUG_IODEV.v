//--------------------------------------------
// FPGA DigDug (I/O device part)
//
//					Copyright (c) 2017 MiSTer-X
//--------------------------------------------
// game20k: one clock CLK48M with enables (CL, FGSCCL, the WSG's own), no hiscore port, the
// sound CPU's NMI from the raster (SNDNMI) instead of a free-running 120 Hz oscillator. The
// custom I/O is the 06XX with the real 51XX and 53XX programs (namco_io.sv) instead of
// DIGDUG_CUSIO. The programs come with the ROM image (ROMAD E000-E7FF).

`timescale 1 ps / 1 ps

module DIGDUG_IODEV
(
	input				RESET,

	input  [7:0]	INP0,
	input  [7:0]	INP1,
	input  [7:0]	DSW0,
	input  [7:0]	DSW1,

	input	  			VBLK,			// V-BLANK
	input				SNDNMI,		// game20k: high in raster lines 64 and 192

	input				CL,			// CPU Interface   game20k: an enable of CLK48M now
	input  [15:0]	AD,
	input				WR,
	input				WR1,			// game20k: the first enable of a write cycle
	input   [7:0]	DI,
	input				RD,
	output			DV,
	output  [7:0]	DO,
	
	output  [2:0]	RSTS,			// CPU Reset Ctrl & Interrupt
	output  [2:0]	IRQS,
	output  [2:0]	NMIS,

	input				CLK48M,
	output			PCMCLK,
	output  [7:0]	PCMOUT,

	output			WAVECL,		// Wave ROM   game20k: read enable
	output  [7:0]	WAVEAD,
	input   [3:0]	WAVEDT,

	input				FGSCCL,		// FG VRAM   game20k: read enable
	input   [9:0]	FGSCAD,
	output  [7:0]	FGSCDT,

	input				SPATCL,		// SP ARAM
	input	  [6:0]	SPATAD,
	output [23:0]	SPATDT,

	output  [1:0]	BG_SELECT,	// Video Ctrl.
	output  [1:0]	BG_COLBNK,
	output 			BG_CUTOFF,
	output 			FG_CLMODE,

	input  [15:0]	ROMAD,		// game20k: the MCU programs of the ROM image, on CLK48M
	input	  [7:0]	ROMDT,
	input				ROMEN
);

// Work & Video Memory
wire CSM0 = (AD[15:11] == 5'b1000_0);	// $8000-$87FF
wire CSM1 = (AD[15:11] == 5'b1000_1);	// $8800-$8FFF
wire CSM2 = (AD[15:11] == 5'b1001_0);	// $9000-$97FF
wire CSM3 = (AD[15:11] == 5'b1001_1);	// $9800-$9FFF

wire [10:0]	MAD = AD[10:0];
wire	[7:0]	DOM0, DOM1, DOM2, DOM3;

// game20k: port 0 on CLK48M with the bus enable, the FG port with its enable, the sprite ports
// on SPATCL (the inverted master clock) as before; the hiscore mux into ram1 is gone
DPR2KV ram0( CLK48M, CL, MAD, CSM0, WR, DI, DOM0, CLK48M, FGSCCL, {1'b0,FGSCAD}, FGSCDT );				// (FGTX) $8000-$8300
DPR2KV ram1( CLK48M, CL, MAD, CSM1, WR, DI, DOM1, SPATCL, 1'b1, {4'h7,SPATAD}, SPATDT[ 7: 0] );	// (SPA0) $8B80-$8BFF
DPR2KV ram2( CLK48M, CL, MAD, CSM2, WR, DI, DOM2, SPATCL, 1'b1, {4'h7,SPATAD}, SPATDT[15: 8] );	// (SPA1) $9380-$93FF
DPR2KV ram3( CLK48M, CL, MAD, CSM3, WR, DI, DOM3, SPATCL, 1'b1, {4'h7,SPATAD}, SPATDT[23:16] );	// (SPA2) $9B80-$9BFF


// NAMCO WSG
wire WSGWR =( AD[15:5] == 11'b0110_1000_000 ) & WR;	// $6800-$681F
WSG_3CH wsg( CLK48M, RESET, CL, AD[4:0], DI[3:0], WSGWR, WAVECL, WAVEAD, WAVEDT, PCMCLK, PCMOUT );


// NAMCO Custom I/O Chip
// game20k: 06XX, 51XX and 53XX as on the board (namco_io.sv). 06XX clock 48 kHz and MCU
// machine cycles 256 kHz from 46.40625 MHz by fractional dividers, chip selects 483 clocks
// (10.4 us) after the NMI. 51XX: R0 stick, R1 cocktail stick, R2 buttons and starts, R3
// coins, service and test off; INP0/INP1 are active high. 53XX: mode K3..K1 from latch bits
// Q7..Q5, R0..R3 the DIP switches.
wire CSCUSIO = (AD[15:9] == 7'b0111_000);					// $70xx-$71xx
wire [7:0] DOCUSIO;
wire NMI0;
wire       MCURUN;
wire [2:0] MOD53;
wire [9:0] A51, A53;
wire [7:0] D51, D53;
namco_io #(.TICK_NUM(128), .TICK_DEN(61875), .MCU_NUM(1024), .MCU_DEN(185625),
           .CS_DELAY(483), .HAS_53XX(1'b1)) cusio (
	.clk(CLK48M), .reset(RESET), .mcu_reset_n(MCURUN), .mcu_ena(),
	.cpu_we(WR1 & CSCUSIO), .cpu_sel(AD[8]), .cpu_di(DI), .cpu_do(DOCUSIO), .nmi(NMI0),
	.cs(), .dev_we(), .dev_data(), .dev_do(8'hFF),
	.in51({2'b11, ~INP0[5:4], ~INP0[3:0], ~INP1[7:4], ~INP1[3:0]}), .vblank(VBLK), .p51(),
	.rom51_addr(A51), .rom51_data(D51),
	.k53({MOD53, 1'b0}), .in53({DSW1, DSW0}), .rom53_addr(A53), .rom53_data(D53)
);
namco_prom2 mcuprog(
	.clk(CLK48M), .addr_a(A51), .data_a(D51), .addr_b(A53), .data_b(D53),
	.wr_en(ROMEN & (ROMAD[15:11] == 5'b1110_0)), .wr_addr(ROMAD[10:0]), .wr_data(ROMDT)
);


// Video Ctrl Latches
wire VLWR = (AD[15:3] == 13'b1010_0000_0000_0) & WR;	// $A000-$A007
DIGDUG_VLATCH vlats( RESET, CLK48M, CL, AD[2:0], VLWR, DI[0], BG_SELECT, BG_COLBNK, BG_CUTOFF, FG_CLMODE );


// CPU Ctrl Latches
wire CLWR = (AD[15:3] == 13'b0110_1000_0010_0) & WR;	// $6820-$6827
wire NMI2;
DIGDUG_CLATCH clats( RESET, CLK48M, CL, AD[2:0], CLWR, DI[0], VBLK, SNDNMI, RSTS, IRQS, NMI2, MCURUN, MOD53 );


// To CPU
assign DV = CSM0|CSM1|CSM2|CSM3|CSCUSIO;
assign DO = CSM0 ? DOM0 : CSM1 ? DOM1 : CSM2 ? DOM2 : CSM3 ? DOM3 : CSCUSIO ? DOCUSIO : 8'hFF;
assign NMIS = {NMI2,1'b0,NMI0};

endmodule


module DIGDUG_VLATCH
(
	input					RESET,
	input					CLK,		// game20k
	input					CL,		// game20k: enable
	input	[2:0]			AD,
	input					WR,
	input					DI,
	
	output reg [1:0]	BG_SELECT,
	output reg [1:0]	BG_COLBNK,
	output reg			BG_CUTOFF,
	output reg			FG_CLMODE
);

always @( posedge CLK or posedge RESET ) begin
	if (RESET) begin
		BG_SELECT <= 2'b00;
		BG_COLBNK <= 2'b00;
		BG_CUTOFF <= 1'b0;
		FG_CLMODE <= 1'b0;
	end
	else if (CL) begin
		if (WR) case(AD)
			3'h0: BG_SELECT[0] <= DI;
			3'h1: BG_SELECT[1] <= DI;
			3'h2: FG_CLMODE    <= DI;
			3'h3: BG_CUTOFF    <= DI;
			3'h4: BG_COLBNK[0] <= DI;
			3'h5: BG_COLBNK[1] <= DI;
			default:;
		endcase
	end
end

endmodule


module DIGDUG_CLATCH
(
	input					RESET,
	input					CLK,		// game20k
	input					CL,		// 24MHz   game20k: enable
	input	 [2:0]		AD,
	input					WR,
	input					DI,
	
	input	 				VBLK,
	input					SNDNMI,	// game20k
	output [2:0]		RSTS,
	output [2:0]		IRQS,
	output 				NMI2,
	output 				MCURUN,	// game20k: Q3, the 51XX and 53XX run while high
	output reg [2:0]	MOD		// game20k: Q7..Q5, the input mode of the 53XX
);

// game20k: the 120 Hz oscillator was tuned to 48 MHz. The board (and MAME galaga.cpp,
// cpu3_interrupt_callback) fires the sound CPU's NMI in raster lines 64 and 192, twice a frame
// at any master clock, so H120 comes from the raster now.
wire H120 = SNDNMI;


reg IRQ0EN, IRQ0LC;
reg IRQ1EN, IRQ1LC;
reg NMI2EN, NMI2LC;
//reg			NMI0LC;

reg C12RST = 1'b1;
reg pH120;

always @( posedge CLK or posedge RESET ) begin
	if (RESET) begin
		IRQ0EN <= 1'b0; IRQ0LC <= 1'b0;
		IRQ1EN <= 1'b0; IRQ1LC <= 1'b0;
		NMI2EN <= 1'b0; NMI2LC <= 1'b0;
		C12RST <= 1'b1; //NMI0LC <= 1'b0;
		pH120  <= 1'b0;
		MOD    <= 3'd0;
	end
	else if (CL) begin
		if (WR) begin
			case(AD)
				3'h0: begin IRQ0EN <= DI; if (~DI) IRQ0LC <= 1'b0; end
				3'h1: begin IRQ1EN <= DI; if (~DI) IRQ1LC <= 1'b0; end
				3'h2: begin NMI2EN <=~DI; if ( DI) NMI2LC <= 1'b0; end
				3'h3: C12RST <= ~DI;
				3'h5: MOD[0] <= DI;	// game20k
				3'h6: MOD[1] <= DI;
				3'h7: MOD[2] <= DI;
				default:;
			endcase
		end
		if (VBLK) begin IRQ0LC <= 1'b1; IRQ1LC <= 1'b1; end
		if ((pH120^H120)&H120) NMI2LC <= 1'b1;
		pH120 <= H120;
	end
end

assign RSTS = {{2{C12RST}},RESET};
assign IRQS = {1'b0,(IRQ1EN & IRQ1LC),(IRQ0EN & IRQ0LC)};
assign NMI2 = (NMI2EN & NMI2LC);
assign MCURUN = ~C12RST;

endmodule

