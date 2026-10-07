// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none
//! @file tb_mb88_trace.sv
//! @brief Runs mb88_cpu.sv in lock step with a MAME trace of the same program.
//!
//! The step file (mame2steps.py) holds the state MAME had before each instruction and what
//! came from outside: the value an inK or inR read, the level of the interrupt line, timer
//! steps and falling /IRQ edges. The bench feeds exactly these inputs at the matching
//! instruction and compares PC, A, X, Y, SI, PIO, TH and TL before every instruction. When
//! the core starts an interrupt entry, the bench runs its three cycles before the next check.
//! The first difference stops the run with both states. ROM and step file come
//! from the caller, neither is part of the tree.
//!
//! Plusargs: +STEPS=<file> +ROMHEX=<file> (one byte per line), +R=<hex> fixed R3..R0 for the
//! instructions that test or modify R without a recorded value (default 0, as MAME reads an
//! unconnected port), +CORRUPT=<n> changes the expected A at step n (a counter-check).
module tb_mb88_trace;
    logic        clk = 1'b0;
    logic        reset_n = 1'b0;
    logic        ena = 1'b0;
    logic        irq_n = 1'b1;
    logic        tc_n = 1'b0;
    logic [3:0]  k_in = '0;
    logic [15:0] r_in = '0;
    logic [10:0] rom_addr;
    logic [7:0]  rom_data = '0;
    logic [7:0]  rom [0:2047];

    always #5 clk = !clk;

    mb88_cpu #(.RAM_AW(6)) dut (
        .clk(clk), .reset_n(reset_n), .ena(ena), .rom_addr(rom_addr), .rom_data(rom_data),
        .k_in(k_in), .r_in(r_in), .r_out(), .r_we(), .o_out(), .o_we(), .p_out(), .p_we(),
        .irq_n(irq_n), .tc_n(tc_n));

    // the ROM is a block RAM read on the falling edge
    always @(negedge clk) rom_data <= rom[rom_addr];

    // one cycle, then three idle clocks; inputs change between the edges like enables
    task automatic one_ena;
        @(posedge clk) ena <= 1'b1;
        @(posedge clk) ena <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    // a rising /TC edge, seen by the core before the next ena
    task automatic tc_pulse;
        @(posedge clk) tc_n <= 1'b1;
        repeat (2) @(posedge clk);
        tc_n <= 1'b0;
    endtask

    // a falling /IRQ edge, also when the line is low already
    task automatic irq_edge;
        if (!irq_n) begin
            @(posedge clk) irq_n <= 1'b1;
            repeat (2) @(posedge clk);
        end
        @(posedge clk) irq_n <= 1'b0;
        repeat (2) @(posedge clk);
    endtask

    string  steps_f, rom_f;
    int     fd, rc, n, corrupt;
    int     pc, a, x, y, si, pio, th, tl, nb, inkind, inval, irqlev, tick, entry;
    logic [15:0] rfix;

    task automatic check(input string name, input int got, input int want);
        if (got != want) begin
            $display("FAIL: step %0d at $%03X: %s is %X, MAME has %X", n, pc, name, got, want);
            $display("  core: PC=%03X A=%X X=%X Y=%X SI=%X PIO=%02X TH=%X TL=%X",
                     {dut.pa, dut.pc}, dut.a, dut.x, dut.y, dut.si, dut.pio, dut.th, dut.tl);
            $display("  MAME: PC=%03X A=%X X=%X Y=%X SI=%X PIO=%02X TH=%X TL=%X",
                     pc, a, x, y, si, pio, th, tl);
            $finish;
        end
    endtask

    initial begin
        if (!$value$plusargs("STEPS=%s", steps_f)) steps_f = "steps.txt";
        if (!$value$plusargs("ROMHEX=%s", rom_f)) rom_f = "rom.hex";
        if (!$value$plusargs("CORRUPT=%d", corrupt)) corrupt = -1;
        if (!$value$plusargs("R=%h", rfix)) rfix = '0;
        for (int i = 0; i < 2048; i++) rom[i] = '0;
        $readmemh(rom_f, rom);
        r_in = rfix;
        fd = $fopen(steps_f, "r");
        if (fd == 0) begin $display("FAIL: no step file %s", steps_f); $finish; end
        repeat (8) @(posedge clk);
        reset_n <= 1'b1;

        n = 0;
        rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                     pc, a, x, y, si, pio, th, tl, nb, inkind, inval, irqlev, tick, entry);
        // run from reset up to the first traced instruction
        for (int i = 0; i < 100; i++) begin
            if (!dut.ph2 && dut.ent == 0 && {dut.pa, dut.pc} == pc) break;
            one_ena;
        end

        while (rc == 14) begin
            if (n == corrupt) a = a ^ 1;
            check("PC", {dut.pa, dut.pc}, pc);
            check("A", dut.a, a);
            check("X", dut.x, x);
            check("Y", dut.y, y);
            check("SI", dut.si, si);
            check("PIO", dut.pio, pio);
            check("TH", dut.th, th);
            check("TL", dut.tl, tl);

            // inputs this instruction reads
            if (inkind == 1) k_in <= inval[3:0];
            else if (inkind == 2) r_in[4*(y % 4) +: 4] <= inval[3:0];
            if (irqlev == 0) irq_n <= 1'b1;
            else if (irqlev == 1) irq_n <= 1'b0;
            // MAME took the request before this instruction
            if (entry) irq_edge;

            // the instruction; a timer step lands before its last cycle and counts after it,
            // as MAME steps between this instruction and the next
            if (nb == 2) one_ena;
            if (tick) tc_pulse;
            one_ena;
            if (dut.ent != 0) repeat (3) one_ena;
            if (inkind == 2) r_in <= rfix;

            n++;
            if (n % 1000000 == 0) $display("%0d steps", n);
            rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                         pc, a, x, y, si, pio, th, tl, nb, inkind, inval, irqlev, tick, entry);
        end
        $display("PASS: %0d steps in lock step with MAME", n);
        $finish;
    end
endmodule
`default_nettype wire
