//--------------------------------------------
// Wave-base Sound Generator (3ch)
//
//					Copyright (c) 2017 MiSTer-X
//--------------------------------------------
// game20k: one clock CLK48M with enables. CPUCLK is the bus enable, WROMCLK the read enable of
// the wave ROM, PCMCLK one clock per new sample. The 96 kHz divider is set for 46.40625 MHz.

`timescale 1 ps / 1 ps

module WSG_3CH
(
   input			 CLK48M,
   input        RESET,

   input        CPUCLK,	// game20k: enable
   input  [4:0] ADRS,
   input  [3:0] DATA,
   input        WR,

	output		 WROMCLK,
   output [7:0] WROMADR,
   input  [3:0] WROMDAT,

	output		 PCMCLK,
   output [7:0] PCMOUT
);

wire WSGCLKx4, WSGCLKx4_FALL;	// game20k: enables of the edges of the old clock
WSGCLKGEN cgen( CLK48M, WSGCLKx4, WSGCLKx4_FALL );

wire  [2:0] W0, W1, W2;
wire  [3:0] V0, V1, V2;
wire [19:0] F0;
wire [15:0]     F1, F2;

WSGREGS regs
(
	RESET,
	CLK48M, CPUCLK, ADRS, WR, DATA,	// game20k: CLK48M

	W0, W1, W2,
	V0, V1, V2,
	F0, F1, F2
);

WSGCORE core
(
	RESET, CLK48M, WSGCLKx4, WSGCLKx4_FALL,	// game20k: CLK48M and the falling edge
	WROMCLK, WROMADR, WROMDAT,

	W0, W1, W2, 
	V0, V1, V2,
	F0, F1, F2,

	PCMCLK, PCMOUT
);

endmodule


module WSGREGS
(
	input			RESET,
	input			CLK,		// game20k
	input			CPUCLK,	// game20k: enable
	input [4:0]	ADRS,
	input			WR,
	input [3:0]	DATA,
	
	output reg  [2:0] W0,
	output reg  [2:0] W1,
	output reg  [2:0] W2,

	output reg  [3:0] V0,
	output reg  [3:0] V1,
	output reg  [3:0] V2,
 
	output reg [19:0] F0,
	output reg [15:0] F1,
	output reg [15:0] F2
);

always @ ( posedge CLK or posedge RESET ) begin	// game20k: CLK, CPUCLK as enable

   if ( RESET ) begin

      W0 <= 0;
      W1 <= 0;
      W2 <= 0;

      F0 <= 0;
      F1 <= 0;
      F2 <= 0;

      V0 <= 0;
      V1 <= 0;
      V2 <= 0;

   end
   else if ( CPUCLK ) begin

      if ( WR ) case ( ADRS )

      5'h05: W0 <= DATA[2:0];
      5'h0A: W1 <= DATA[2:0];
      5'h0F: W2 <= DATA[2:0];

      5'h15: V0 <= DATA;
      5'h1A: V1 <= DATA;
      5'h1F: V2 <= DATA;

      5'h10: F0[3:0]   <= DATA;
      5'h11: F0[7:4]   <= DATA;
      5'h12: F0[11:8]  <= DATA;
      5'h13: F0[15:12] <= DATA;
      5'h14: F0[19:16] <= DATA;

      5'h16: F1[3:0]   <= DATA;
      5'h17: F1[7:4]   <= DATA;
      5'h18: F1[11:8]  <= DATA;
      5'h19: F1[15:12] <= DATA;

      5'h1B: F2[3:0]   <= DATA;
      5'h1C: F2[7:4]   <= DATA;
      5'h1D: F2[11:8]  <= DATA;
      5'h1E: F2[15:12] <= DATA;

      default:;

      endcase

   end

end

endmodule


module WSGCORE
(
	input				RESET,
	input				CLK,				// game20k
	input				WSGCLKx4,		// game20k: enable, the rising edge of the old clock
	input				WSGCLKx4_FALL,	// game20k: its falling edge

	output			WROMCLK,
	output [7:0]	WROMADR,
	input  [3:0]	WROMDAT,

	input  [2:0]	W0,
	input  [2:0]	W1,
	input  [2:0]	W2,

	input  [3:0]	V0,
	input  [3:0]	V1,
	input  [3:0]	V2,

	input [19:0]	F0,
	input [15:0]	F1,
	input [15:0]	F2,

	output				outclk,	// game20k: one clock per sample, where the old outclk rose
	output reg [7:0]	sndout
);

reg   [7:0] waveadr, cc1, cc2;

reg  [19:0] c0;
reg  [15:0] c1, c2;

reg   [3:0] wavevol;
wire  [7:0] waveout = wavevol * WROMDAT;

reg   [9:0] sndmix;
wire [10:0] sndmixdown = { 1'b0, sndmix };

reg   [1:0] phase;
assign outclk = WSGCLKx4 & (phase == 2'h1);	// game20k
always @ ( posedge CLK or posedge RESET ) begin	// game20k: CLK, WSGCLKx4 as enable

   if ( RESET ) begin
      phase  <= 2'h0;
      sndout <= 8'h00;
		cc1    <= 8'h00;
		cc2    <= 8'h00;
   end
   else if ( WSGCLKx4 ) begin

      case ( phase )

      2'h0: begin
            sndout  <= ( sndmixdown[9:2] | {8{sndmixdown[10]}} );

				cc1     <= {W1,c1[15:11]};
				cc2     <= {W2,c2[15:11]};

            sndmix  <= 10'h000;
            waveadr <= {W0,c0[19:15]};
            wavevol <= (F0!=0) ? V0 : 4'h0;
         end

      2'h1: begin
            sndmix  <= sndmix + waveout;

            waveadr <= cc1;
            wavevol <= (F1!=0) ? V1 : 4'h0;
         end

      2'h2: begin
            sndmix  <= sndmix + waveout;

            waveadr <= cc2;
            wavevol <= (F2!=0) ? V2 : 4'h0;
         end

      2'h3: begin
            sndmix  <= sndmix + waveout;
         end

			default:;

      endcase

      phase <= phase+1'b1;

      c0 <= c0 + F0;
      c1 <= c1 + F1;
      c2 <= c2 + F2;

   end

end

assign WROMCLK = WSGCLKx4_FALL;	// game20k: was ~WSGCLKx4
assign WROMADR = waveadr;

endmodule


/*
   Clock Generator
     in: 48000000Hz -> out: 96000Hz
   game20k: in 46406250 Hz, threshold 241 instead of 249: a toggle every 242 clocks gives
   95.88 kHz (MAME 96 kHz). rise and fall are enables of the old out's edges.
*/
module WSGCLKGEN( input in, output rise, output fall );
reg [7:0] count = 8'd0;
reg       out   = 1'b0;
wire      tgl   = (count > 8'd241);
assign rise = tgl & ~out;
assign fall = tgl &  out;
always @( posedge in ) begin
	if (tgl) begin
		count <= count - 8'd241;
      out <= ~out;
	end
   else count <= count + 8'd1;
end
endmodule

