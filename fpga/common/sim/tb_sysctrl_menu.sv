// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// Testbench for READ_CFG (command 8) of sysctrl.v with a game's generated menu_rom.v: sends
// the command as mcu_spi.v does, clocks out +bytes=N bytes and writes them, one hex byte per
// line, to +out=FILE. run_mcu_sim.sh unpacks them and compares the result with the game's
// gen/menu_rom.xml. A second read must start at the first byte again. Ends with PASS or $fatal.
`timescale 1ns/1ps
`default_nettype none
module tb_sysctrl_menu;
    logic       clk = 0, reset = 1;
    logic       strobe = 0, start = 0;
    logic [7:0] din = 0, dout;

    sysctrl dut (
        .clk(clk), .reset(reset), .data_in_strobe(strobe), .data_in_start(start),
        .data_in(din), .data_out(dout), .int_out_n(), .int_in(8'h00), .int_ack(),
        .buttons(2'b00), .leds(), .color(), .system_reset(), .system_scanlines(),
        .system_volume(), .system_inputtest(), .system_fire_btn(), .system_coin_btn(),
        .system_start_btn(), .system_start2_btn(), .system_voldn_btn(), .system_volup_btn(),
        .system_screen(), .cfg_we(), .cfg_id(), .cfg_val());

    always #5 clk = ~clk;

    // one SPI byte: a strobe of one clock, then the gap of the slow SPI bus
    task automatic byte_in(logic first, logic [7:0] b);
        @(negedge clk);
        strobe = 1; start = first; din = b;
        @(negedge clk);
        strobe = 0; start = 0;
        repeat (6) @(negedge clk);
    endtask

    initial begin
        int n, fd;
        string out;
        logic [7:0] first [4];
        if (!$value$plusargs("bytes=%d", n)) $fatal(1, "+bytes=N missing");
        if (!$value$plusargs("out=%s", out)) $fatal(1, "+out=FILE missing");
        repeat (3) @(posedge clk);
        reset = 0;

        byte_in(1, 8'd8);
        fd = $fopen(out, "w");
        for (int i = 0; i < n; i++) begin
            byte_in(0, 8'h00);
            $fwrite(fd, "%02x\n", dout);
            if (i < 4) first[i] = dout;
        end
        $fclose(fd);

        // the Companion reads the menu twice, the second read starts over
        byte_in(1, 8'd8);
        for (int i = 0; i < 4; i++) begin
            byte_in(0, 8'h00);
            if (dout !== first[i])
                $fatal(1, "second read: byte %0d is %02x, the first read had %02x", i, dout, first[i]);
        end
        $display("PASS");
        $finish;
    end
endmodule
`default_nettype wire
