// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file tb_sdspi.v
//! @brief Polls the SD card status over SPI as the Companion does at start-up (sdc.c).
//!
//! The Companion sends target 3 (SD card) and command 1 (status), then reads one byte. The card
//! counts as ready when the upper nibble is 0x8. sd_fake (WangXuan95/FPGA-SDcard-Reader) plays
//! the card. The test passes when the status turns ready within the time limit.
`timescale 1ns/1ps
module tb_sdspi;
    reg clk = 0, rstn = 0;
    always #26.936 clk = ~clk;            // 18.5625 MHz, clk_core of Pac-Man and Galaga

    reg  spi_csn = 1, spi_sck = 0, spi_mosi = 0;
    wire spi_miso;
    wire sd_clk, sd_cmd, fpga_cmd;
    wire [3:0] sd_dat, fpga_dat;
    pullup (sd_cmd);                      // the card socket's pull-ups
    pullup (sd_dat[0]); pullup (sd_dat[1]); pullup (sd_dat[2]); pullup (sd_dat[3]);
    // The FPGA side as open drain: its outputs read 1 when it does not drive. Fine for the SD
    // protocol, where only one side drives at a time.
    assign sd_cmd = fpga_cmd ? 1'bz : 1'b0;
    genvar g;
    for (g = 0; g < 4; g = g + 1) begin : g_dat
        assign sd_dat[g] = fpga_dat[g] ? 1'bz : 1'b0;
    end

    sdspi_dut dut (.clk(clk), .rstn(rstn), .spi_csn(spi_csn), .spi_sck(spi_sck),
        .spi_mosi(spi_mosi), .spi_miso(spi_miso), .sd_clk(sd_clk), .sd_cmd(fpga_cmd),
        .sd_cmd_in(sd_cmd), .sd_dat(fpga_dat), .sd_dat_in(sd_dat), .sdc_int(), .sdc_data_out());

    wire        card_cmd_en;
    wire [5:0]  card_cmd;
    wire [31:0] card_arg;
    sd_fake card (.rstn_async(rstn), .sdclk(sd_clk), .sdcmd(sd_cmd), .sddat(sd_dat),
        .rdreq(), .rdaddr(), .rddata(16'h0000), .show_status_bits(), .show_sdcmd_en(card_cmd_en),
        .show_sdcmd_cmd(card_cmd), .show_sdcmd_arg(card_arg));

    // Every command the card receives, seen from outside the design, so the same in all
    // variants. The first ten SD clock edges show whether the controller runs at all.
    always @(posedge card_cmd_en)
        $display("t=%0d us card got CMD%0d arg %08h", $time / 1000, card_cmd, card_arg);
    integer sd_clk_edges = 0;
    always @(posedge sd_clk) begin
        sd_clk_edges = sd_clk_edges + 1;
        if (sd_clk_edges <= 3 || sd_clk_edges % 10000 == 0)
            $display("t=%0d us sd_clk edge %0d", $time / 1000, sd_clk_edges);
    end

    // SPI mode 1 at 5 MHz: the master sets MOSI on the rising edge, both sides sample on the
    // falling edge
    task spi_byte(input [7:0] tx, output [7:0] rx);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                spi_sck = 1; spi_mosi = tx[i];
                #100;
                spi_sck = 0; rx[i] = spi_miso;
                #100;
            end
            // The Pico pauses some microseconds between bytes. The FPGA needs a few core clocks
            // to bring an answer byte across the clock domains, without the pause the first bit
            // of the next byte is read before it is there.
            #2000;
        end
    endtask

`ifndef TB_GATE
    // Every state change of the card's init state machine (sd_rw.v: 0 CMD0 ... 8 READY). The
    // gate netlist is flat and its state register recoded, there is no such name.
    always @(dut.sd_card.sd_rw.sdcmd_stat)
        $display("t=%0d us sd_rw state %0d", $time / 1000, dut.sd_card.sd_rw.sdcmd_stat);
`endif

`ifdef TB_GATE
    // Inside the flat gate netlist: the command the controller latches, and every start bit it
    // drives onto the command line
    always @(dut.\sd_card.sd_rw.u_sdcmd_ctrl.req_cmd )
        $display("t=%0d us req_cmd %0d", $time / 1000, dut.\sd_card.sd_rw.u_sdcmd_ctrl.req_cmd );
    integer cmd_lows = 0;
    always @(negedge fpga_cmd) begin
        cmd_lows = cmd_lows + 1;
        if (cmd_lows <= 5) $display("t=%0d us fpga drives cmd low (%0d)", $time / 1000, cmd_lows);
    end
`endif

    // +maxus=N ends the run after N microseconds of simulated time
    integer maxus;
    initial if ($value$plusargs("maxus=%d", maxus)) begin
        #(maxus * 1000);
        $display("STOP at %0d us", maxus);
        $finish;
    end

`ifdef TB_RTL
    // The sources as written: Icarus starts registers undefined, the FPGA starts them at 0.
    // mcu_spi has no reset on the byte toggle, so it would stay undefined.
    initial begin
        dut.mcu_spi.spi_data_in_ready = 1'b0;
        dut.mcu_spi.spi_target = 8'd0;
    end
`endif

    reg [7:0] st, dummy;
    integer polls = 0;
`ifdef SDSPI_FAST
    // with SIMULATE the init takes a few milliseconds: poll every 20 us, up to 40 ms
    localparam integer POLLS = 2000, PERIOD = 20_000;
`else
    // As sdc.c: up to 200 polls, 10 ms apart on the Pico. Here 1 ms apart, up to 0.8 s: the
    // card's init at about 190 kHz takes some 0.4 s.
    localparam integer POLLS = 800, PERIOD = 1_000_000;
`endif
    initial begin
        #1000 rstn = 1;
        st = 8'h00;
        // the loop ends on ready, Verilator does not stop at once on $finish
        while (polls < POLLS && st[7:4] !== 4'h8) begin
            #PERIOD;
            spi_csn = 0; #200;
            spi_byte(8'd3, dummy);        // target: SD card
            spi_byte(8'd1, dummy);        // command: status
            spi_byte(8'd0, st);
            #200 spi_csn = 1;
            polls = polls + 1;
            if (polls % 50 == 0 || st[7:4] == 4'h8)
                $display("t=%0d us poll %0d status %02h", $time / 1000, polls, st);
        end
        if (st[7:4] === 4'h8) $display("PASS: SD card ready, status %02h", st);
        else                 $display("FAIL: SD card not ready, last status %02h", st);
        $finish;
    end
endmodule
