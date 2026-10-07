// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file namco_io.sv
//! @brief Namco 06XX interface with a 51XX and optionally a 53XX that run their original programs.
//!
//! Written for game20k after the behaviour MAME describes in namco06.cpp, namco51.cpp,
//! namco53.cpp and mb88xx.cpp (0.289, BSD-3-Clause). No code is taken from other cores.
//!
//! 06XX: its clock is 48 kHz (clk x TICK_NUM / TICK_DEN gives twice that), divided by
//! 2^(control bits 7..5). Each half period toggles an internal state. Going high it sets R/W
//! from control bit 4, raises the chip selects named in control bits 3..0 (the IRQs of the
//! customs) and the NMI of the main CPU, going low it drops selects and NMI. A read
//! suppresses the first NMI, so the chips have one period to answer. A control write
//! restarts the clock at the next 48 kHz edge, a zero divider stops it.
//!
//! Unlike MAME, the chip selects follow NMI by CS_DELAY clocks (about 10 us). With both at
//! once, the MCUs read a byte about 5 to 15 us after the main CPU's NMI handler writes it,
//! and a handler a few us slower than MAME's leaves them the old byte.
//!
//! 51XX (MB8843 on chip select 0): K is R/W and the low three bits of the latch between 06XX
//! and 51XX, the MCU answers through the same latch with outO. R0..R3 are the inputs as the
//! board wires them, active low. /TC is the vertical blank.
//!
//! 53XX (MB8843 on chip select 1, HAS_53XX): K is the mode from the misc latch, R0..R3 the
//! DIP switches. The main CPU reads its port O, it takes no writes.
//!
//! Chip selects 1..3 go out for customs outside (Galaga: the 54XX on 3), with a write strobe
//! per chip and the written byte. The MCU programs sit outside, read one cycle ahead.
module namco_io #(
    parameter int TICK_NUM = 1,     //!< clk x TICK_NUM / TICK_DEN = 96 kHz, twice the 06XX clock
    parameter int TICK_DEN = 192,
    parameter int MCU_NUM  = 1,     //!< clk x MCU_NUM / MCU_DEN = 256 kHz, the MCU machine cycle
    parameter int MCU_DEN  = 72,
    parameter int CS_DELAY = 192,   //!< clocks from NMI to the chip selects, below one 48 kHz period
    parameter bit HAS_53XX = 1'b0   //!< a 53XX on chip select 1 (Dig Dug)
)(
    input  wire         clk,
    input  wire         reset,          //!< the 06XX, active high
    input  wire         mcu_reset_n,    //!< the MCUs, active low
    output logic        mcu_ena,        //!< one MCU machine cycle, also for customs outside
    //! ---- main CPU: data at address bit 8 = 0, control at 1 ----
    input  wire         cpu_we,         //!< one clock per write
    input  wire         cpu_sel,
    input  wire  [7:0]  cpu_di,
    output logic [7:0]  cpu_do,         //!< read data, combinational
    output logic        nmi,            //!< to the main CPU, active high
    //! ---- customs outside on chip selects 1..3 ----
    output logic [3:1]  cs,             //!< chip selects, active high
    output logic [3:1]  dev_we,         //!< one clock per write to the chip
    output logic [7:0]  dev_data,       //!< the byte written
    input  wire  [7:0]  dev_do,         //!< AND of what the selected chips give, FF if none
    //! ---- 51XX ----
    input  wire  [15:0] in51,           //!< R3..R0, active low as on the board
    input  wire         vblank,         //!< the timer steps on its rising edge
    output logic [3:0]  p51,            //!< port P: coin counters and lockout
    output logic [9:0]  rom51_addr,
    input  wire  [7:0]  rom51_data,
    //! ---- 53XX ----
    input  wire  [3:0]  k53,            //!< K3..K0: the input mode
    input  wire  [15:0] in53,           //!< R3..R0: the DIP switches
    output logic [9:0]  rom53_addr,
    input  wire  [7:0]  rom53_data
);
    // ---- clock enables: fractional dividers, exact on average ----
    localparam int TW = $clog2(TICK_DEN + 1);
    localparam int MW = $clog2(MCU_DEN + 1);
    logic [TW-1:0] acc_t = '0;
    logic [MW-1:0] acc_m = '0;
    logic tick = 1'b0;                  // 96 kHz
    logic ena_q = 1'b0;
    assign mcu_ena = ena_q;
    always_ff @(posedge clk) begin
        if (acc_t >= TW'(TICK_DEN - TICK_NUM)) begin
            acc_t <= acc_t + TW'(TICK_NUM) - TW'(TICK_DEN);
            tick  <= 1'b1;
        end else begin
            acc_t <= acc_t + TW'(TICK_NUM);
            tick  <= 1'b0;
        end
        if (acc_m >= MW'(MCU_DEN - MCU_NUM)) begin
            acc_m   <= acc_m + MW'(MCU_NUM) - MW'(MCU_DEN);
            ena_q <= 1'b1;
        end else begin
            acc_m   <= acc_m + MW'(MCU_NUM);
            ena_q <= 1'b0;
        end
    end

    // ---- 06XX ----
    logic [7:0] control = '0;
    logic       ph48 = 1'b0;            // phase of the 48 kHz clock: an edge every second tick
    logic       run = 1'b0;
    logic [7:0] left = '0;              // ticks to the next toggle, 1..128
    logic       state = 1'b0;
    logic       stretch = 1'b0;
    logic       rw = 1'b0;              // 1 = read
    logic [3:0] sel = '0;               // chip selects as MAME has them
    logic [3:0] sel_out = '0;           // the same, CS_DELAY clocks later
    logic [7:0] latch = '0;             // between 06XX and 51XX
    wire  [7:0] o51;
    wire        o51_we;
    wire  [7:0] o53;

    always_ff @(posedge clk) begin
        dev_we <= '0;
        if (tick) ph48 <= !ph48;

        // the clock: every half period toggles the state, going high it latches R/W and
        // raises chip selects and NMI (unless a read suppresses this first NMI)
        if (run && tick) begin
            if (left == 8'd1) begin
                left  <= 8'd1 << control[7:5];
                state <= !state;
                if (!state) begin
                    rw  <= control[4];
                    nmi <= !stretch;
                    sel <= control[3:0];
                end else begin
                    nmi <= 1'b0;
                    sel <= '0;
                end
                stretch <= 1'b0;
            end else
                left <= left - 8'd1;
        end

        // the 51XX answers through the latch the main CPU writes to
        if (o51_we) latch <= o51;

        if (cpu_we) begin
            if (!cpu_sel) begin
                // data: taken only in write mode, by every selected chip
                if (!control[4]) begin
                    if (control[0]) latch <= cpu_di;
                    dev_we   <= control[3:1];
                    dev_data <= cpu_di;
                end
            end else begin
                // control: a zero divider stops the clock, otherwise it restarts at the next
                // 48 kHz edge, and a read clears the NMI at once
                control <= cpu_di;
                if (cpu_di[7:5] == 3'd0) begin
                    run   <= 1'b0;
                    state <= 1'b0;
                    nmi   <= 1'b0;
                    sel   <= '0;
                end else begin
                    run     <= 1'b1;
                    left    <= (tick ? !ph48 : ph48) ? 8'd1 : 8'd2;
                    stretch <= cpu_di[4];
                    if (cpu_di[4]) nmi <= 1'b0;
                end
            end
        end

        if (reset) begin
            control <= '0;
            run     <= 1'b0;
            state   <= 1'b0;
            stretch <= 1'b0;
            nmi     <= 1'b0;
            rw      <= 1'b0;
            sel     <= '0;
            latch   <= '0;
            dev_we  <= '0;
        end
    end

    // the chip selects: every change of sel, CS_DELAY clocks later, short pulses included. MAME
    // has a select rise 3 us before the main CPU stops the clock, and the 51XX counts that
    // pulse. Changes come a half period apart, plus a stop at any time, so at most two wait.
    localparam int CW = $clog2(CS_DELAY + 1);
    logic [3:0]    last = '0, v0 = '0, v1 = '0, nv0, nv1;
    logic [CW-1:0] c0 = '0, c1 = '0, nc0, nc1;      // clocks left, 0 = slot empty
    always_comb begin
        nv0 = v0;
        nv1 = v1;
        nc0 = c0 != 0 ? c0 - 1'b1 : c0;
        nc1 = c1 != 0 ? c1 - 1'b1 : c1;
        if (c0 == 1) begin                          // slot 0 fires, slot 1 moves up
            nv0 = v1;
            nc0 = nc1;
            nc1 = '0;
        end
        if (sel != last) begin
            if (nc0 == 0) begin nv0 = sel; nc0 = CW'(CS_DELAY); end
            else begin nv1 = sel; nc1 = CW'(CS_DELAY); end
        end
    end
    always_ff @(posedge clk) begin
        if (c0 == 1) sel_out <= v0;
        last <= sel;
        v0 <= nv0; v1 <= nv1; c0 <= nc0; c1 <= nc1;
        if (reset) begin
            last    <= '0;
            c0      <= '0;
            c1      <= '0;
            sel_out <= '0;
        end
    end

    assign cs = sel_out[3:1];

    // read: 0 in write mode, else the AND of the selected chips
    localparam logic [3:1] OUTSIDE = HAS_53XX ? 3'b110 : 3'b111;
    always_comb begin
        cpu_do = 8'hFF;
        if (control[0]) cpu_do &= latch;
        if (HAS_53XX && control[1]) cpu_do &= o53;
        if ((control[3:1] & OUTSIDE) != 0) cpu_do &= dev_do;
        if (!control[4]) cpu_do = 8'h00;
        if (cpu_sel) cpu_do = control;
    end

    // ---- the MCUs ----
    wire [10:0] a51;
    mb88_cpu #(.RAM_AW(6)) u_51xx (
        .clk(clk), .reset_n(mcu_reset_n), .ena(mcu_ena),
        .rom_addr(a51), .rom_data(rom51_data),
        .k_in({rw, latch[2:0]}), .r_in(in51), .r_out(), .r_we(),
        .o_out(o51), .o_we(o51_we), .p_out(p51), .p_we(),
        .irq_n(!sel_out[0]), .tc_n(vblank));
    assign rom51_addr = a51[9:0];

    generate if (HAS_53XX) begin : g53
        wire [10:0] a53;
        mb88_cpu #(.RAM_AW(6)) u_53xx (
            .clk(clk), .reset_n(mcu_reset_n), .ena(mcu_ena),
            .rom_addr(a53), .rom_data(rom53_data),
            .k_in(k53), .r_in(in53), .r_out(), .r_we(),
            .o_out(o53), .o_we(), .p_out(), .p_we(),
            .irq_n(!sel_out[1]), .tc_n(1'b0));
        assign rom53_addr = a53[9:0];
    end else begin : g_no53
        assign o53 = 8'hFF;
        assign rom53_addr = '0;
    end endgenerate
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
