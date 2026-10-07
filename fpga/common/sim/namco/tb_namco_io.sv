// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none
//! @file tb_namco_io.sv
//! @brief Replays the main CPU's 06XX accesses from a MAME run against namco_io.sv.
//!
//! The bus log (MAME tap script) has one event per line, times in microseconds since power on:
//!   <t> W <addr> <data>   main CPU writes 0x7000 (data) or 0x7100 (control)
//!   <t> R <addr> <data>   main CPU reads, data is what MAME returned
//!   <t> L <addr> <data>   write to the misc latch: bit 0 at 0x6823 releases the customs from
//!                         reset, 0x6825..0x6827 are the 53XX mode (K1..K3)
//!   <t> F 0000 00         a frame ends, the vertical blank begins (2.5 ms, 40 of 264 lines)
//!   <t> I <name> <0|1>    an input changes
//! The bench applies writes, resets and inputs at their time, makes every read at its time
//! and compares the result with MAME's. Ends with the number of reads and of differences, the
//! first differences are listed. Both MCUs run their programs from namco_prom2.sv.
//!
//! Plusargs: +BUSLOG=<file> +ROM51=<hex> +ROM53=<hex> (one byte per line), +SHIFT_US=<n> the
//! data accesses (0x7000) come that much later than in MAME, as with a slower NMI handler,
//! +SHOW=<n> differences to list (20), +DSW=<hex> R3..R0 of the 53XX (MAME's 2499).
module tb_namco_io #(
    parameter int CLK_FS   = 54253472,  //!< clock period in fs, 18.432 MHz
    parameter int TICK_NUM = 1,
    parameter int TICK_DEN = 192,
    parameter int MCU_NUM  = 1,
    parameter int MCU_DEN  = 72,
    parameter int CS_DELAY = 192,
    parameter bit HAS_53XX = 1'b0
);
    timeunit 1ns;
    timeprecision 1fs;

    logic        clk = 1'b0;
    logic        mcu_rst = 1'b0;
    logic        cpu_we = 1'b0, cpu_sel = 1'b0;
    logic [7:0]  cpu_di = '0;
    wire  [7:0]  cpu_do;
    logic [15:0] in51 = 16'hFFFF;
    logic [3:0]  k53 = '0;
    logic [15:0] in53 = 16'h2499;
    logic        vblank = 1'b0;
    wire  [9:0]  a51, a53;
    wire  [7:0]  d51, d53;
    logic        wr_en = 1'b0;
    logic [10:0] wr_addr = '0;
    logic [7:0]  wr_data = '0;
    logic [7:0]  prog [0:2047];

    always #(real'(CLK_FS) / 2.0e6) clk = !clk;

    namco_io #(.TICK_NUM(TICK_NUM), .TICK_DEN(TICK_DEN), .MCU_NUM(MCU_NUM), .MCU_DEN(MCU_DEN),
               .CS_DELAY(CS_DELAY), .HAS_53XX(HAS_53XX)) dut (
        .clk(clk), .reset(1'b0), .mcu_reset_n(mcu_rst), .mcu_ena(),
        .cpu_we(cpu_we), .cpu_sel(cpu_sel), .cpu_di(cpu_di), .cpu_do(cpu_do), .nmi(),
        .cs(), .dev_we(), .dev_data(), .dev_do(8'hFF),
        .in51(in51), .vblank(vblank), .p51(), .rom51_addr(a51), .rom51_data(d51),
        .k53(k53), .in53(in53), .rom53_addr(a53), .rom53_data(d53));

    namco_prom2 u_prom (
        .clk(clk), .addr_a(a51), .data_a(d51), .addr_b(a53), .data_b(d53),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data));

    string  buslog, rom51, rom53, line, word;
    int     fd, shift_us, show, reads, diffs, v, n;
    longint t_us;
    byte    kind;
    logic [15:0] a16;
    logic [7:0]  d8;

    // the vertical blank of a frame
    task automatic blank;
        vblank = 1'b1;
        #2.5ms;
        vblank = 1'b0;
    endtask

    function automatic int input_bit(input string name);
        case (name)
            "P1_Up":           return 0;
            "P1_Right":        return 1;
            "P1_Down":         return 2;
            "P1_Left":         return 3;
            "P1_Button_1":     return 8;
            "1_Player_Start":  return 10;
            "2_Players_Start": return 11;
            "Coin_1":          return 12;
            "Coin_2":          return 13;
            default:           return -1;
        endcase
    endfunction

    initial begin
        if (!$value$plusargs("BUSLOG=%s", buslog)) buslog = "bus.log";
        if (!$value$plusargs("ROM51=%s", rom51)) rom51 = "rom51.hex";
        if (!$value$plusargs("ROM53=%s", rom53)) rom53 = "";
        if (!$value$plusargs("SHIFT_US=%d", shift_us)) shift_us = 0;
        if (!$value$plusargs("SHOW=%d", show)) show = 20;
        if (!$value$plusargs("DSW=%h", in53)) in53 = 16'h2499;
        for (int i = 0; i < 2048; i++) prog[i] = '0;
        $readmemh(rom51, prog, 0, 1023);
        if (rom53 != "") $readmemh(rom53, prog, 1024, 2047);

        // load both programs through the write port while the MCUs are in reset
        for (int i = 0; i < 2048; i++) begin
            @(posedge clk);
            wr_en   <= 1'b1;
            wr_addr <= 11'(i);
            wr_data <= prog[i];
        end
        @(posedge clk) wr_en <= 1'b0;

        fd = $fopen(buslog, "r");
        if (fd == 0) begin $display("FAIL: no bus log %s", buslog); $finish; end
        reads = 0;
        diffs = 0;
        while ($fgets(line, fd)) begin
            n = $sscanf(line, "%d %c %s %h", t_us, kind, word, d8);
            if (n < 4) continue;
            // only the data accesses move against the chip selects: the NMI handler moves
            // the data, the control register starts the 06XX clock
            if ((kind == "W" || kind == "R") && word.substr(0, 1) == "70") t_us += shift_us;
            if (t_us * 1us > $realtime) #(t_us * 1us - $realtime);
            case (kind)
                "W": begin
                    a16 = 16'(word.atohex());
                    @(posedge clk);
                    cpu_sel <= a16[8];
                    cpu_di  <= d8;
                    cpu_we  <= 1'b1;
                    @(posedge clk) cpu_we <= 1'b0;
                end
                "R": begin
                    a16 = 16'(word.atohex());
                    @(posedge clk) cpu_sel <= a16[8];
                    @(posedge clk);
                    reads++;
                    if (cpu_do !== d8) begin
                        diffs++;
                        if (diffs <= show)
                            $display("%0d us: read %04X gives %02X, MAME %02X", t_us, a16, cpu_do, d8);
                    end
                end
                "L": begin
                    a16 = 16'(word.atohex());
                    case (a16)
                        16'h6823: mcu_rst = d8[0];
                        16'h6825: k53[1] = d8[0];
                        16'h6826: k53[2] = d8[0];
                        16'h6827: k53[3] = d8[0];
                        default: ;
                    endcase
                end
                "F": fork blank; join_none
                "I": begin
                    v = int'(d8);           // "1" or "0", read as hex
                    if (input_bit(word) < 0) begin
                        $display("FAIL: unknown input %s", word);
                        $finish;
                    end
                    // blocking: two inputs may change in the same microsecond
                    in51[input_bit(word)] = (v == 0);
                end
                default: begin
                    $display("FAIL: unknown event %c", kind);
                    $finish;
                end
            endcase
        end
        $display("reads %0d, differences %0d", reads, diffs);
        $finish;
    end
endmodule
`default_nettype wire
