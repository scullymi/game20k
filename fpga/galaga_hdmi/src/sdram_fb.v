// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2024 nand2mario (sdram_nes.v, NESTang), changes Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent 1-bit net.
//! -----------------------------------------------------------------------------------------
//! @file sdram_fb.v
//! @brief Frame buffer SDRAM controller for the Tang Nano 20K (game20k)
//!
//! Derived from src/sdram_nes.v of NESTang (github.com/nand2mario/nestang)
//!   "Double-channel CL2 SDRAM controller for NES -- nand2mario 2024.3"
//! LICENSE: NESTang is GPL-3.0 (its COPYING). This file is a declared
//! derivative and therefore GPL-3.0 as well. Why the whole project is GPL-3.0-only as a
//! consequence is explained in THIRD-PARTY.md, section "Why GPL-3.0-only".
//! THIRD-PARTY.md is authoritative, this header only names origin and licence.
//!
//! Timing model (recalculated, not copied)
//! ---------------------------------------
//! A command assigned in ring cycle k reaches the bus only in FPGA cycle k+1 because of the
//! output register. The SDRAM edge LAGS the FPGA edge: per the simulation model PSDA is a
//! delay (prim_sim.v line 15278: ps_dly = clkout_period*PSDA/16), at PSDA 10 phi = 9.645 ns.
//! It therefore still lies within the same FPGA cycle. The command is thus taken over in
//! bus cycle k+1, with 9.645 ns setup and T-phi = 5.787 ns hold.
//! Read data appears CL SDRAM edges later: the SDRAM drives it at edge S(read bus cycle + CL),
//! and the FPGA edge at the END of that very bus cycle captures it into the capture stage
//! dq_r. From there it moves to rd_dout one cycle later, in the source rd_track[CAPT+1] with
//! CAPT 4 (CL2) or 5 (CL3); the +1 is dq_r, see change 12.
//! Exactly this path is the one measured on the device: the data is valid only phi + tAC
//! after the start of the bus cycle and is captured after T. At PSDA 10 and tAC 6.0 ns that
//! is 15.645 against 15.432 ns: the measurement decides, not the arithmetic.
//!
//! Ring schedule (6 cycles at 64.8 MHz, one cycle T = 15.432 ns)
//! -------------------------------------------------------------
//! Ring cycle (assignment)   Bus cycle       Command
//!   0                         6m+1          BankActivate write channel (bank = wr_bank)
//!   1                         6m+2          BankActivate read channel  (bank = rd_bank)
//!   2                         6m+3          Write + AutoPrecharge, the FPGA drives DQ
//!                                           exactly in this bus cycle
//!   3                         6m+4          Read  + AutoPrecharge
//!   4                         6m+5          free
//!   5                         6m+6          AutoRefresh, only in a round cleared
//!                                           for that purpose
//!
//! The WRITE CHANNEL comes first, as in the original. The reverse order, read channel first,
//! does not work and makes any phase measurement worthless: with the read channel first, the
//! FPGA drives its write data in bus cycle 6m+4 and the SDRAM its read data in bus cycle
//! 6m+5, i.e. in directly consecutive cycles on the same 32 lines. What separates the two is
//! then the clock phase alone, and that is why, measured on the device with that order,
//! exactly ONE phase value (the largest, PSDA 15) works and no other. With the write channel
//! first there are three or four bus cycles between the FPGA driver (6m+3) and the SDRAM
//! driver (6m+6 at CL2, 6m+7 at CL3).
//!
//! Checked against a typical -6 SDR SDRAM (tRP/tRCD 18 ns, tRC 60 ns, tRAS 42 ns,
//! tRRD 12..14 ns, tRFC 60..66 ns, tAC 6.0 (CL2) / 5.4 (CL3) ns, 2048 rows in 64 ms):
//!   tRCD write channel  S(6m+1) -> S(6m+3) : 2 cycles = 30.9 ns   >= 18 ns
//!   tRCD read channel   S(6m+2) -> S(6m+4) : 2 cycles = 30.9 ns   >= 18 ns
//!   tRRD                S(6m+1) -> S(6m+2) : 1 cycle  = 15.4 ns   >= 12..14 ns
//!        Tightest item of the schedule and not improvable in a 6-cycle ring.
//!   tRC  same bank, same slot of the next round: 6 cycles = 92.6 ns >= 60 ns
//!   tWR  Write S(6m+3), tWR 2 cycles -> internal precharge from S(6m+5), tRP until S(6m+7),
//!        next ACT of the same channel S(6m+7): fits exactly
//!   tRAS read channel ACT S(6m+2), internal precharge from S(6m+4+CL): 4 or 5 cycles >= 42 ns
//!   tRFC AutoRefresh S(6m+6), the following round is blocked, next ACT S(6m+13):
//!        7 cycles = 108 ns >= 66 ns
//!   Refresh every 501 cycles = 7.73 us; required 2048 rows / 64 ms = 31.25 us, 4x margin
//!   DQ bus: the FPGA alone drives bus cycle 6m+3. The SDRAM drives from S(6m+6)+tAC at CL2,
//!           from S(6m+7)+tAC at CL3, and at least two bus cycles remain until the next
//!           write cycle 6m+9. No point of the round depends on the clock phase.
//!   Throughput per channel: 64.8 MHz / 6 = 10.8 million accesses per second, minus the
//!           2.4 percent refresh pause. Needed are 1.55 (write) and 1.31 (read).
//!
//! What differs from the original
//! ------------------------------
//!  1. "import configPackage::*" is gone. The four sizes are fixed for the Nano 20K
//!     (from NESTang's src/boards/nano20k.v:12-15): 32 data bits, 11 row bits,
//!     8 column bits, 2 bank bits. The `ifdef NANO branches are resolved, the others removed.
//!  2. The two clkref-bound byte ports A and B are replaced by a single 32-bit write port
//!     with req/ack toggle (modelled on the RV port of the original). This removes the ring
//!     reset (original lines 238-239), the 6-cycle ring runs free.
//!  3. The RV port is a pure 32-bit read port: rv_din, rv_ds and rv_we are gone,
//!     line 355 becomes rd_dout <= dq_r (all 32 bits).
//!  4. Both channels take the bank as a separate input, never from a computed
//!     address. The four places of the original (lines 258, 271, 286, 309) are marked
//!     "bank site" below.
//!  5. Ring schedule as in the original (write channel first), but both channels with tRCD
//!     2 cycles instead of 1. See above for why the reverse order does not work.
//!  6. Forced refresh. The original inserts the AutoRefresh only when both channels happen
//!     to be idle (line 276). The self-test loads both channels to 100 percent, so a refresh
//!     would never come and the contents would decay. Here a whole round is cleared instead
//!     (rfsh_arm) and the following round is blocked as tRFC pause (rfsh_wait, the blocking
//!     flip-flop).
//!  7. SDRAM_DQM is driven: 1111 in reset and during the whole initialisation sequence (as
//!     the data sheets require), then permanently 0000. Access is word-wise only, there are
//!     no byte masks anywhere. Because DQM stays constant from "normal" on,
//!     there is no CL-dependent DQM read latency.
//!  8. Output sdram_ready (1 only after complete initialisation) instead of busy.
//!  9. In reset, cmd is explicitly set to NOP and the address is cleared. The original
//!     leaves cmd as it is; that goes unnoticed there because resetn acts only once at
//!     power-up. Here the self-test pulls resetn after every phase change, and while the
//!     clock phase jumps, CS# must be safely high. The self-test additionally waits four
//!     cycles for that, because the reset acts synchronously.
//! 10. CAS is a parameter (2 or 3). With CL exactly one thing changes in operation: the cycle
//!     in which the read data is captured (CAPT). tRP, tRCD, tRC, tWR and the refresh
//!     interval do not depend on CL, the mode register does.
//! 11. need_refresh is cleared when arming, not at the counter overflow. Otherwise the start
//!     of the refresh chain silently depends on RFRSH_CYCLES lying at least one ring length
//!     below the counter end.
//! 12. An ungated, unconditional capture stage dq_r before rd_dout. A register without reset
//!     and without enable can be packed by the placer into the IOLOGIC of the 32 DQ pads;
//!     that takes the fabric route between pad and capture register out of the measurement
//!     budget. Costs one cycle of latency on rd_dout/rd_valid, nothing else. Measured in
//!     the measurement build: with this stage "I/O Register as FF" is 77 instead of 10, and
//!     the path pad -> dq_r is at 2.314 ns.
//! -----------------------------------------------------------------------------------------

module sdram_fb #(
    //! Controller clock. Max. 66.7 MHz with these T_xx (note from the original).
    parameter         FREQ  = 64_800_000,

    parameter [2:0]   CAS   = 3'd2,    //!< 2 or 3, goes into the mode register
    parameter [4:0]   T_WR  = 5'd2,    //!< 2 cycles write recovery (>= 12 ns), documentation only
    parameter [4:0]   T_MRD = 5'd2,    //!< 2 cycles after Mode Register Set
    parameter [4:0]   T_RP  = 5'd2,    //!< 2 cycles = 30.9 ns (>= 18 ns)
    parameter [4:0]   T_RCD = 5'd2,    //!< 2 cycles = 30.9 ns (>= 18 ns), documentation only
    parameter [4:0]   T_RC  = 5'd6     //!< 6 cycles = 92.6 ns (>= 60 ns, and >= tRFC 66 ns)
) (
    //! ---- Connections to the SDRAM in the GW2AR package ----
    inout  wire [31:0] SDRAM_DQ,
    output      wire [10:0] SDRAM_A,
    output      wire [3:0]  SDRAM_DQM,
    output reg  [1:0]  SDRAM_BA,
    output             wire SDRAM_nCS,
    output             wire SDRAM_nWE,
    output             wire SDRAM_nRAS,
    output             wire SDRAM_nCAS,
    output             wire SDRAM_CKE,

    //! ---- Control ----
    input              wire clk,          //!< clk_sdram, 64.8 MHz
    input              wire resetn,       //!< in production only pll_sdram_lock
    output             wire sdram_ready,  //!< 1 only after complete initialisation
    input      wire [1:0]   cap_ofs,      //!< capture cycle of the read data, see CAPT above

    //! ---- Write port, 32 bits, req/ack toggle ----
    input      wire [21:0]  wr_addr,      //!< byte address, [20:10] row, [9:2] col, [1:0] unused
    input      wire [31:0]  wr_din,
    input      wire [1:0]   wr_bank,      //!< explicit input, not from the address
    input              wire wr_req,       //!< toggle = new request
    output reg         wr_ack,       //!< becomes equal to wr_req once the request is accepted

    //! ---- Read port, 32 bits, req/ack toggle ----
    input      wire [21:0]  rd_addr,
    input      wire [1:0]   rd_bank,      //!< explicit input
    input              wire rd_req,
    output reg         rd_ack,
    output reg [31:0]  rd_dout,
    output reg         rd_valid      //!< one cycle, rd_dout is then stable
);

// ---- Data bus ----
reg         dq_oen;                  // 0 = the FPGA drives
reg  [31:0] dq_out;
assign SDRAM_DQ = dq_oen ? 32'bz : dq_out;
wire [31:0] dq_in = SDRAM_DQ;

// Change 12: unconditional capture stage so that it fits into the IOLOGIC.
reg  [31:0] dq_r;
always @(posedge clk) dq_r <= dq_in;

reg  [3:0]  cmd;
reg  [10:0] a;
reg  [3:0]  dqm;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
assign SDRAM_A   = a;
assign SDRAM_CKE = 1'b1;
assign SDRAM_DQM = dqm;

// CS# RAS# CAS# WE#
localparam CMD_NOP          = 4'b1111;
localparam CMD_SetModeReg   = 4'b0000;
localparam CMD_BankActivate = 4'b0011;
localparam CMD_Write        = 4'b0100;
localparam CMD_Read         = 4'b0101;
localparam CMD_AutoRefresh  = 4'b0001;
localparam CMD_PreCharge    = 4'b0010;

localparam [2:0]  BURST_LEN  = 3'b000;   // burst length 1
localparam        BURST_MODE = 1'b0;     // sequential
localparam [10:0] MODE_REG   = {4'b0000, CAS[2:0], BURST_MODE, BURST_LEN};

// 2048 rows / 64 ms = 31.25 us required; 501 cycles = 7.73 us is 4x as often.
localparam [8:0] RFRSH_CYCLES = 9'd501;

// Cycle in which the read data is valid at the DQ pad, counted in rd_track stages.
// rd_start is set in ring cycle 0, rd_track[k] is valid in ring cycle 1+k.
// The read CAS lies in bus cycle 6m+3, the data is valid from S(6m+3+CL) on and is captured
// into dq_r by the FPGA edge at the END of bus cycle 6m+3+CL: that is ring cycle 5 at CL2
// and ring cycle 6 at CL3, so rd_track index CAPT = 2+CL. From dq_r it moves to rd_dout one
// cycle later, arithmetically rd_track[CAPT+1].
//
// "Arithmetically" is the problem here. Measured on the device (the series with the read
// channel first, see the header), this arithmetic is wrong: at CL2 exactly ONE phase step
// runs error-free (PSDA 15, the step right at the clock period boundary) and all others are
// fully red, at CL3 the whole band is red. A capture cycle that is off by one cycle looks
// exactly like this: it always reads the wrong cycle, not just barely off. Why that is
// cannot be decided without measurement: the propagation time of the clock out of the pad
// enters the arithmetic, but is in no data sheet.
//
// That is why the capture cycle is adjustable at run time. cap_ofs selects
// rd_track[CAPT + cap_ofs], i.e. one cycle earlier than computed (cap_ofs 0) up to two
// cycles later (cap_ofs 3). The multiplexer is NOT on the measured path: dq_r hangs
// unchanged directly on the pad, only the moment when dq_r is passed on to rd_dout is
// adjusted, and there is a whole cycle of time for that.
localparam integer CAPT = (CAS == 3'd3) ? 5 : 4;

// ---- State ----
reg [16:0] cycle;        // one-hot; 0..16 during initialisation, afterwards only 5..0
reg        normal, setup;
reg        cfg_now;

reg [21:0] addr_w_l, addr_r_l;
reg [31:0] din_l;
reg [1:0]  bank_w_l, bank_r_l;
reg        we_latch, oe_latch;
reg [9:0]  rd_track;      // wide enough for CAPT + cap_ofs, at most 5+3 = 8

reg [8:0]  refresh_cnt;
reg        need_refresh;
reg        rfsh_arm;      // clear this round, AutoRefresh at its end
reg        rfsh_wait;     // recovery round after the AutoRefresh (tRFC)

wire block_act = rfsh_arm | rfsh_wait;
wire wr_pend   = wr_req ^ wr_ack;
wire rd_pend   = rd_req ^ rd_ack;
wire rd_start  = normal & cycle[1] & rd_pend & ~block_act;

assign sdram_ready = normal;

// -----------------------------------------------------------------------------------------
// Refresh counter. Change 11: need_refresh is cleared when arming, with exactly the same
// condition under which the main block sets rfsh_arm.
// -----------------------------------------------------------------------------------------
always @(posedge clk) begin
    if (~resetn) begin
        need_refresh <= 1'b0;
        refresh_cnt  <= 9'd0;
    end else begin
        if (normal) refresh_cnt <= refresh_cnt + 9'd1;
        if (refresh_cnt == RFRSH_CYCLES) need_refresh <= 1'b1;
        if (normal && cycle[5] && !rfsh_arm && !rfsh_wait && need_refresh) begin
            need_refresh <= 1'b0;
            refresh_cnt  <= 9'd0;
        end
    end
end

// ---- Capture of the read data ----
// The capture cycle is adjustable via cap_ofs; a 4:1 multiplexer on a path that has a
// whole cycle of time.
wire [3:0] cap_sel = CAPT[3:0] + {2'b00, cap_ofs};

always @(posedge clk) begin
    if (~resetn) begin
        rd_track <= 10'd0;
        rd_valid <= 1'b0;
        rd_dout  <= 32'd0;
    end else begin
        rd_track <= {rd_track[8:0], rd_start};
        rd_valid <= 1'b0;
        if (rd_track[cap_sel]) begin
            rd_dout  <= dq_r;        // changes 3 and 12: all 32 bits, from the capture stage
            rd_valid <= 1'b1;        // rd_dout is stable in the next cycle
        end
    end
end

// -----------------------------------------------------------------------------------------
// State machine
// -----------------------------------------------------------------------------------------
always @(posedge clk) begin
    if (~resetn) begin
        dq_oen    <= 1'b1;
        cmd       <= CMD_NOP;        // change 9
        a         <= 11'd0;
        dqm       <= 4'b1111;        // change 7
        SDRAM_BA  <= 2'd0;
        normal    <= 1'b0;
        setup     <= 1'b0;
        cycle     <= 17'd0;
        we_latch  <= 1'b0;
        oe_latch  <= 1'b0;
        wr_ack    <= 1'b0;
        rd_ack    <= 1'b0;
        rfsh_arm  <= 1'b0;
        rfsh_wait <= 1'b0;
    end else begin
        // Defaults for this cycle
        dq_oen <= 1'b1;
        cmd    <= CMD_NOP;
        if (normal) dqm <= 4'b0000;  // DQM stays high during initialisation

        // 200 us after power-up
        if (~normal && ~setup && cfg_now) begin
            setup <= 1'b1;
            cycle <= 17'd1;
        end

        // ---- Initialisation, unchanged from the original ----
        if (setup) begin
            cycle <= {cycle[15:0], 1'b0};
            if (cycle[0]) begin                      // PrechargeAll
                cmd      <= CMD_PreCharge;
                a[10]    <= 1'b1;
                SDRAM_BA <= 2'd0;
            end
            if (cycle[T_RP]) begin                   // 2: first AutoRefresh
                cmd <= CMD_AutoRefresh;
            end
            if (cycle[T_RP+T_RC]) begin              // 8: second AutoRefresh
                cmd <= CMD_AutoRefresh;
            end
            if (cycle[T_RP+T_RC+T_RC]) begin         // 14: mode register
                cmd      <= CMD_SetModeReg;
                a[10:0]  <= MODE_REG;
                SDRAM_BA <= 2'd0;
            end
            if (cycle[T_RP+T_RC+T_RC+T_MRD]) begin   // 16: done
                setup  <= 1'b0;
                normal <= 1'b1;
                cycle  <= 17'd1;
            end
        end

        // ---- Operation ----
        if (normal) begin
            cycle[5:0] <= {cycle[4:0], cycle[5]};    // free-running 6-cycle ring

            // Cycle 1: BankActivate read channel
            if (cycle[1]) begin
                oe_latch <= 1'b0;
                if (rd_pend && !block_act) begin
                    oe_latch <= 1'b1;
                    addr_r_l <= rd_addr;
                    bank_r_l <= rd_bank;
                    SDRAM_BA <= rd_bank;             // bank site 3 (original line 271)
                    a        <= rd_addr[20:10];
                    cmd      <= CMD_BankActivate;
                    rd_ack   <= rd_req;              // acknowledged already at activation
                end
            end

            // Cycle 0: BankActivate write channel
            if (cycle[0]) begin
                we_latch <= 1'b0;
                if (wr_pend && !block_act) begin
                    we_latch <= 1'b1;
                    addr_w_l <= wr_addr;
                    din_l    <= wr_din;
                    bank_w_l <= wr_bank;
                    SDRAM_BA <= wr_bank;             // bank site 1 (original line 258)
                    a        <= wr_addr[20:10];
                    cmd      <= CMD_BankActivate;
                    wr_ack   <= wr_req;
                end
            end

            // Cycle 3: Read with AutoPrecharge
            if (cycle[3] && oe_latch) begin
                cmd      <= CMD_Read;
                SDRAM_BA <= bank_r_l;                // bank site 4 (original line 309)
                a        <= {3'b000, addr_r_l[9:2]};
                a[10]    <= 1'b1;                    // AutoPrecharge
            end

            // Cycle 2: Write with AutoPrecharge
            if (cycle[2] && we_latch) begin
                cmd      <= CMD_Write;
                SDRAM_BA <= bank_w_l;                // bank site 2 (original line 286)
                a        <= {3'b000, addr_w_l[9:2]};
                a[10]    <= 1'b1;                    // AutoPrecharge
                dq_oen   <= 1'b0;
                dq_out   <= din_l;
            end

            // Cycle 5: refresh sequence (change 6)
            if (cycle[5]) begin
                if (rfsh_arm) begin
                    // The round was cleared, all banks have long been precharged.
                    cmd       <= CMD_AutoRefresh;
                    rfsh_arm  <= 1'b0;
                    rfsh_wait <= 1'b1;               // one round of pause for tRFC
                end else if (rfsh_wait) begin
                    rfsh_wait <= 1'b0;
                end else if (need_refresh) begin
                    rfsh_arm  <= 1'b1;               // clear the next round
                end
            end
        end
    end
end

// -----------------------------------------------------------------------------------------
// cfg_now: one pulse after 200 us, unchanged from the original
// -----------------------------------------------------------------------------------------
reg [14:0] rst_cnt;
reg        rst_done, rst_done_p1;

always @(posedge clk) begin
    if (~resetn) begin
        rst_cnt     <= 15'd0;
        rst_done    <= 1'b0;
        rst_done_p1 <= 1'b0;
        cfg_now     <= 1'b0;
    end else begin
        rst_done_p1 <= rst_done;
        cfg_now     <= rst_done & ~rst_done_p1;

        if (rst_cnt != FREQ / 1000 * 200 / 1000) begin   // 200 us = 12960 cycles
            rst_cnt  <= rst_cnt + 15'd1;
            rst_done <= 1'b0;
        end else begin
            rst_done <= 1'b1;
        end
    end
end

endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
