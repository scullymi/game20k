/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 1-1-2020 */
// game20k: changed copy of jotego/jtcores 548b87b32a1b528a16cb41f689accb179e85d1a8
// modules/jtframe/hdl/cpu/jtframe_z80wait.v. Only change: with GAME20K_Z80_GAP defined,
// jtframe_z80wait keeps its clock enables that many clocks apart, see there.

module jtframe_rom_wait(
    input       rst_n,
    input       clk,
    input       cen_in,
    input       rec_en,
    output      cen_out,
    output      gate,
    // manage access to ROM data from SDRAM
    input       rom_cs,
    input       rom_ok
);
    /* verilator coverage_off */
    jtframe_z80wait #(1) u_wait(
        .rst_n      ( rst_n     ),
        .clk        ( clk       ),
        .cen_in     ( cen_in    ),
        .cen_out    ( cen_out   ),
        .gate       ( gate      ),
        .iorq_n     ( rec_en    ),
        .mreq_n     ( 1'b1      ),
        .busak_n    ( 1'b1      ),
        // manage access to shared memory
        .dev_busy   ( 1'b0      ),
        // manage access to ROM data from SDRAM
        .rom_cs     ( rom_cs    ),
        .rom_ok     ( rom_ok    )
    );
endmodule

/////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////

module jtframe_dual_wait #(parameter devcnt=2)(
    input       rst_n,
    input       clk,
    input  [1:0]     cen_in,
    output reg [1:0] cen_out,
    output           gate,
    // manage access to shared memory
    input  [devcnt-1:0] dev_busy,
    // manage access to ROM data from SDRAM
    input       rom_cs,
    input       rom_ok
);

/////////////////////////////////////////////////////////////////
// wait_n generation
reg last_rom_cs;
wire rom_cs_posedge = !last_rom_cs && rom_cs;
wire rom_bad = rom_cs && !rom_ok || rom_cs_posedge;

reg [1:0] mark, gated_at;
reg       locked, latched;
assign gate = !( rom_bad || dev_busy || locked || latched);
wire bus_ok = (rom_ok||!rom_cs) && !dev_busy;

always @(posedge clk) begin
    if( !rst_n ) begin
        gated_at <= 1'b0;
        latched  <= 1'b0;
    end else begin
        if(cen_in[0]) mark <= 2'b01;
        if(cen_in[1]) mark <= 2'b10;
        if(locked) begin
            gated_at <= mark;
            latched  <= 1'b1;
        end
        latched <= locked;
        if(bus_ok && !locked && latched) begin
            if( gated_at[0] & cen_in[1] ) latched <= 1'b0;
            if( gated_at[1] & cen_in[0] ) latched <= 1'b0;
        end
    end
end

always @(posedge clk)
    cen_out <= cen_in & {2{gate}};


always @(posedge clk) begin
    if( !rst_n ) begin
        last_rom_cs <= 1'b1;
        locked      <= 1'b0;
    end else begin
        last_rom_cs <= rom_cs;
        if( rom_bad || dev_busy) begin
            locked  <= 1'b1;
        end
        else begin
            locked <= 1'b0;
        end
    end
end

endmodule

module jtframe_z80wait #(parameter DEVCNT=2, RECOVERY=1)(
    input       rst_n,
    input       clk,
    input       cen_in,
    output reg  cen_out,
    output      gate,
    // Recover cycles
    input       mreq_n,
    input       iorq_n,
    input       busak_n,
    // manage access to shared memory
    input  [DEVCNT-1:0] dev_busy, // Delays here are not recovered
    // manage access to ROM data from SDRAM
    input       rom_cs,
    input       rom_ok // Delays because of rom_ok are recovered
);

`ifdef JTFRAME_CLK24
initial begin
    if(RECOVERY==1) begin
       $display("WARNING: %m");
       $display("         Do not use cycle recovery with a 24MHz clock and 6MHz pixel");
       $display("         that combination fails in jtkiwi.");
       $display("         See issue https://github.com/jotego/jtbubl/issues/27");
       $display("         This could affect 48MHz/8MHz combination too");
    end
end
`endif

/////////////////////////////////////////////////////////////////
// wait_n generation
reg last_rom_cs;
wire rom_cs_posedge = !last_rom_cs && rom_cs;

reg        locked, rec, start, cen_l;
wire       rom_bad, rec_en;
reg  [3:0] miss_cnt;

// wire bus_ok = (rom_ok||!rom_cs) && !dev_busy;

assign gate    = !(rom_bad || dev_busy!=0 || locked );
assign rom_bad = (rom_cs && !rom_ok) || rom_cs_posedge;
assign rec_en  = &{mreq_n, iorq_n, busak_n, RECOVERY[0] };

always @(*) begin
    rec = 0;
    // two cen pulses in a row will break most systems
    // probably because of memory delays. That's why cen_l
    // is used too
    if( miss_cnt!=0 && !cen_in && rec_en && !cen_l )
        rec = 1;
end

always @(posedge clk) cen_l <= cen_out;

`ifndef GAME20K_Z80_GAP
always @(posedge clk) begin
    if( !rst_n ) begin
        miss_cnt <= 4'd0;
    end else begin
        if( !start ) begin
            miss_cnt <= 4'd0;
        end else begin
            if( cen_in && !gate && dev_busy==0 ) begin
                if( ~&miss_cnt ) miss_cnt <= miss_cnt+4'd1;
            end else if( rec ) begin
                if( miss_cnt!=0 ) miss_cnt <= miss_cnt - 4'd1;
            end
        end
    end
end

always @(*)
    cen_out = (cen_in & gate) | rec;
`else
// game20k: with GAME20K_Z80_GAP defined, two enables are at least that many clocks apart.
// The recovery above can put a recovered enable two clocks after the previous one; at
// 37.125 MHz with an 8 MHz CPU (4 or 5 clocks per enable) a RAM byte, one clock in the RAM and
// one in the core's registered data bus, then came too late (Pang read FF from its stack).
// A natural enable that would come too early is held back and owed like a ROM wait, and an
// owed one goes out while the bus is idle, as above, once the gap allows it.
reg  [1:0] gap = 2'd0;          // clocks since the last enable, saturating
wire       gap_ok = gap >= 2'(`GAME20K_Z80_GAP);
always @(posedge clk) gap <= cen_out ? 2'd1 : (gap == 2'd3 ? 2'd3 : gap + 2'd1);

always @(posedge clk) begin
    if( !rst_n ) begin
        miss_cnt <= 4'd0;
    end else begin
        if( !start ) begin
            miss_cnt <= 4'd0;
        end else begin
            if( cen_in && !cen_out && dev_busy==0 ) begin
                if( ~&miss_cnt ) miss_cnt <= miss_cnt+4'd1;
            end else if( !cen_in && cen_out ) begin
                if( miss_cnt!=0 ) miss_cnt <= miss_cnt - 4'd1;
            end
        end
    end
end

always @(*)
    cen_out = gap_ok & ( (cen_in & gate) | (!cen_in & miss_cnt!=0 & rec_en & gate) );
`endif

always @(posedge clk) begin
    if( !rst_n ) begin
        last_rom_cs <= 1'b1;
        locked      <= 1'b0;
        start       <= 0;
    end else begin
        last_rom_cs <= rom_cs;
        if(rom_bad) begin
            locked  <= 1'b1;
        end
        else begin
            locked <= 1'b0;
            start  <= 1;
        end
    end
end

`ifdef SIMULATION
// Count how often there are delays because of ROM waits
integer misses=0;
always @(posedge cen_in) if(!gate) misses<=misses+1;
`endif

endmodule // jtframe_z80wait