// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// Testbench for rom_loader.sv with a small layout of three sections (TOTAL 40 bytes). Files:
// the whole layout, the layout with a 128-byte footer as the upstream Companion firmware
// sends it, a prefix, and sizes the loader must refuse. Every byte must reach its section
// and address once, nothing past TOTAL may be written, every byte of the file must be
// taken, and loaded must follow the last one. Ends with PASS or $fatal.
`timescale 1ns/1ps
`default_nettype none
module tb_rom_loader;
    localparam int TOTAL = 40, AW = 16, SECTIONS = 3;
    // sections at 0, 16 and 24, the last one up to TOTAL
    localparam logic [17*AW-1:0] OFFSETS = {{14{16'h0000}}, 16'd24, 16'd16, 16'd0};

    logic        clk = 0, reset = 1;
    logic        sel_strobe = 0;
    logic [2:0]  sel_index = 0;
    logic [63:0] image_size = 0;
    logic        accepted, data_available = 0, data_strobe;
    logic [7:0]  data_in = 0, wr_data;
    logic [15:0] wr_addr, wr_en, count;
    logic [AW-1:0] wr_off;
    logic        loaded, busy;

    rom_loader #(.SLOT(0), .TOTAL(TOTAL), .SECTIONS(SECTIONS), .AW(AW), .OFFSETS(OFFSETS)) dut (
        .clk(clk), .reset(reset), .sel_strobe(sel_strobe), .sel_index(sel_index),
        .image_size(image_size), .accepted(accepted), .data_available(data_available),
        .data_in(data_in), .data_strobe(data_strobe), .wr_addr(wr_addr), .wr_off(wr_off),
        .wr_data(wr_data), .wr_en(wr_en), .wr_ready(1'b1), .loaded(loaded), .busy(busy),
        .count(count));

    always #5 clk = ~clk;

    // the memories as the core sees them, and how often each byte was written
    logic [7:0] mem [SECTIONS][TOTAL];
    int         writes [SECTIONS][TOTAL];
    int         past;   // writes that hit no section of the layout
    always @(posedge clk)
        for (int s = 0; s < SECTIONS; s++)
            if (wr_en[s]) begin
                mem[s][wr_addr] <= wr_data;
                writes[s][wr_addr] <= writes[s][wr_addr] + 1;
            end
    always @(posedge clk) if (|wr_en[15:SECTIONS] || $countones(wr_en) > 1) past <= past + 1;

    // the byte of the file at offset i, its own value per offset
    function automatic logic [7:0] pattern(int i);
        return 8'(i * 7 + 3);
    endfunction

    // selects slot 0 with size n, returns whether the loader accepted
    task automatic select(longint n, output logic ok);
        @(negedge clk);
        sel_strobe = 1; image_size = 64'(n);
        #1 ok = accepted;
        @(negedge clk);
        sel_strobe = 0;
    endtask

    // offers n bytes as the SD FIFO would and then more, returns how many the loader took
    task automatic stream(int n, output int taken);
        taken = 0;
        for (int c = 0; c < 2 * n + 16; c++) begin
            @(negedge clk);
            data_in = pattern(taken);
            data_available = 1;
            @(posedge clk); #1;
            if (data_strobe) taken++;
        end
        @(negedge clk);
        data_available = 0;
        repeat (4) @(posedge clk);
    endtask

    task automatic clear();
        for (int s = 0; s < SECTIONS; s++)
            for (int a = 0; a < TOTAL; a++) begin
                mem[s][a] = 8'hxx;
                writes[s][a] = 0;
            end
        past = 0;
    endtask

    // the section and address of file offset i
    function automatic int sec_of(int i);
        return i >= 24 ? 2 : i >= 16 ? 1 : 0;
    endfunction
    function automatic int base_of(int s);
        return s == 2 ? 24 : s == 1 ? 16 : 0;
    endfunction

    // loads a file of n bytes and checks the memories against its first min(n, TOTAL) bytes
    task automatic load(string name, int n);
        logic ok;
        int   taken, bad = 0, missing = 0, filled;
        clear();
        select(n, ok);
        if (!ok) $fatal(1, "%s: a file of %0d bytes was refused", name, n);
        stream(n, taken);
        filled = n < TOTAL ? n : TOTAL;
        for (int i = 0; i < TOTAL; i++) begin
            int s = sec_of(i), a = i - base_of(sec_of(i));
            if (i < filled) begin
                if (writes[s][a] != 1) missing++;
                else if (mem[s][a] != pattern(i)) bad++;
            end else if (writes[s][a] != 0) bad++;
        end
        if (taken != n) $fatal(1, "%s: %0d of %0d bytes taken", name, taken, n);
        if (!loaded) $fatal(1, "%s: loaded not set after the last byte", name);
        if (busy) $fatal(1, "%s: still busy after the last byte", name);
        if (missing || bad || past)
            $fatal(1, "%s: %0d bytes not written once, %0d wrong, %0d writes outside the layout",
                   name, missing, bad, past);
        $display("%s: %0d bytes taken, %0d written, loaded", name, taken, filled);
        // deselect, as the Companion does at the end
        select(0, ok);
    endtask

    initial begin
        logic ok;
        repeat (3) @(posedge clk);
        reset = 0;

        load("whole layout", TOTAL);
        load("with footer", TOTAL + 128);
        load("prefix", 20);
        load("one byte", 1);

        // sizes the counter cannot cover, and size 0, must be refused
        select(longint'(1) << (AW + 1), ok);
        if (ok) $fatal(1, "a file of 2^(AW+1) bytes was accepted");
        select(0, ok);
        if (ok) $fatal(1, "size 0 was accepted");
        select((longint'(1) << (AW + 1)) - 1, ok);
        if (!ok) $fatal(1, "a file of 2^(AW+1)-1 bytes was refused");
        select(0, ok);
        // another slot is not this loader's
        @(negedge clk);
        sel_strobe = 1; sel_index = 1; image_size = TOTAL;
        #1 if (accepted) $fatal(1, "slot 1 was accepted by the loader of slot 0");
        @(negedge clk);
        sel_strobe = 0; sel_index = 0;

        $display("PASS");
        $finish;
    end
endmodule
`default_nettype wire
