// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file tb_mcu_spi.sv
//! @brief mcu_spi.v as the Companion drives it: SPI mode 1 at 20 MHz, the select raised at any
//!        time after the last SCK edge and held high for less than one core clock.
//!
//! Each round sends four transactions: three bytes to the OSD, two to the HID, the target id
//! of the SD card alone, and twenty bytes to the system target. What comes out in the core
//! clock is checked as one sequence of events: every byte after the target id as one strobe
//! of its target with its data, mcu_start only with the first one, and exactly one mcu_end per
//! transaction, at least two core clocks after its last strobe (one in reserve for a synchronizer
//! that resolves a clock late, which the simulation does not show). Between some transactions the select is high for less
//! than one core clock, where mcu_end may come with the next target id instead. The rounds
//! sweep the time from the last SCK edge to the rising select over three core clocks, at the
//! core clocks of the games and with the core clock's phase shifted each round. Ends with PASS
//! or $fatal.
`timescale 1ns/1ps

module tb_mcu_spi;
    real clk_half = 26.936;
    logic clk = 0;
    always #(clk_half) clk = ~clk;

    logic ss = 1, sck = 0, mosi = 0;
    wire  miso;
    wire  sys_s, hid_s, osd_s, sdc_s, ram_s, start, done;
    wire [7:0] dout;

    mcu_spi dut (
        .clk(clk), .reset(1'b0),
        .spi_io_ss(ss), .spi_io_clk(sck), .spi_io_din(mosi), .spi_io_dout(miso),
        .mcu_sys_strobe(sys_s), .mcu_hid_strobe(hid_s), .mcu_osd_strobe(osd_s),
        .mcu_sdc_strobe(sdc_s), .mcu_ram_strobe(ram_s), .mcu_start(start), .mcu_end(done),
        .mcu_sys_din(8'h00), .mcu_hid_din(8'h00), .mcu_osd_din(8'h00), .mcu_sdc_din(8'h00),
        .mcu_ram_din(8'h00), .mcu_dout(dout)
    );

    // what the core clock side delivered, in order: a strobe with its target, data and start
    // flag, or an end (target E_END)
    localparam int E_END = 99;
    typedef struct { int target; logic [7:0] data; bit start; } ev_t;
    ev_t got[$];
    int cyc = 0, last_strobe = -1000, min_gap = 1000;
    always @(posedge clk) begin
        cyc++;
        if (sys_s + hid_s + osd_s + sdc_s + ram_s > 1) $fatal(1, "FAIL: two strobes in one clock");
        if (sys_s | hid_s | osd_s | sdc_s | ram_s) last_strobe = cyc;
        if (done) begin
            if (cyc - last_strobe < min_gap) min_gap = cyc - last_strobe;
            if (cyc - last_strobe < 2)
                $fatal(1, "FAIL: mcu_end %0d clock(s) after the last strobe", cyc - last_strobe);
        end
        if (sys_s) got.push_back('{0, dout, start});
        if (hid_s) got.push_back('{1, dout, start});
        if (osd_s) got.push_back('{2, dout, start});
        if (sdc_s) got.push_back('{3, dout, start});
        if (ram_s) got.push_back('{5, dout, start});
        if (done)  got.push_back('{E_END, 8'h00, 1'b0});
    end

    // SPI mode 1, 20 MHz: data set up on the rising edge, read on the falling one
    task automatic spi_byte(input logic [7:0] b);
        for (int i = 7; i >= 0; i--) begin
            #25 sck = 1; mosi = b[i];
            #25 sck = 0;
        end
    endtask

    // one transaction: select low, the target id and the payload, select high hold ns after
    // the last SCK edge, high for gap ns
    task automatic transaction(input int target, input logic [7:0] payload[], input real hold,
                               input real gap);
        ss = 0;
        #50;
        spi_byte(8'(target));
        foreach (payload[i]) spi_byte(payload[i]);
        #(hold) ss = 1;
        #(gap);
    endtask

    // the events one transaction must give: its strobes, then its end
    task automatic expect_tr(ref ev_t want[$], input int target, input logic [7:0] payload[]);
        foreach (payload[i]) want.push_back('{target, payload[i], i == 0});
        want.push_back('{E_END, 8'h00, 1'b0});
    endtask

    int rounds = 0, bad = 0;
    real periods[3] = '{26.936, 13.468, 10.7744};   // half periods: 18.5625, 37.125, 46.40625 MHz

    initial begin
        logic [7:0] osd[] = '{8'hA5, 8'h3C, 8'h81};   // to target 2, the OSD
        logic [7:0] hid[] = '{8'h5A, 8'hC3};          // to target 1, the HID
        logic [7:0] none[];                            // the SD card's target id alone
        logic [7:0] sys[];                             // twenty bytes to target 0
        ev_t want[$];
        sys = new[20];
        foreach (sys[i]) sys[i] = 8'(i * 37 + 11);
        #200;
        foreach (periods[p]) begin
            clk_half = periods[p];
            // the select rises 1 ns to three core clocks after the last SCK edge, the phase of
            // the core clock moves with every round as the transactions do not divide its period
            for (real hold = 1.0; hold <= 6.0 * periods[p]; hold += 1.37) begin
                got.delete(); want.delete();
                // high shorter than one core clock after the first and the third transaction
                transaction(2, osd, hold, 0.8 * periods[p]);
                transaction(1, hid, hold, 8.0 * periods[p]);
                transaction(3, none, hold, 0.8 * periods[p]);
                transaction(0, sys, hold, 8.0 * periods[p]);
                #(8.0 * periods[p]);
                expect_tr(want, 2, osd);
                expect_tr(want, 1, hid);
                expect_tr(want, 3, none);
                expect_tr(want, 0, sys);
                if (got != want) begin
                    bad++;
                    if (bad <= 5) begin
                        $display("FAIL: core clock %.4f MHz, select %.2f ns after SCK: %0d events, %0d expected",
                                 500.0 / clk_half, hold, got.size(), want.size());
                        foreach (got[i])
                            if (i >= want.size() || got[i] != want[i]) begin
                                $display("  first difference at event %0d: target %0d data %h start %b",
                                         i, got[i].target, got[i].data, got[i].start);
                                break;
                            end
                    end
                end
                rounds++;
            end
        end
        if (bad != 0) $fatal(1, "FAIL: %0d of %0d rounds out of order", bad, rounds);
        $display("%0d rounds of four transactions, every byte once with its target and start flag, one end each, at least %0d clocks after its last byte",
                 rounds, min_gap);
        $display("PASS");
        $finish;
    end
endmodule
