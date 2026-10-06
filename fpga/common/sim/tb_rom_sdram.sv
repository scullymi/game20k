// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k: rom_sdram.sv with the real sdram_fb.v and a simple SDR SDRAM model. clk_core
// (37.125 MHz) and clk_sdram (64.8 MHz) run unrelated. A byte stream like rom_loader's (one
// byte every two clocks at most, waiting on wr_ready, with gaps) fills 1942's 232 KiB of
// sdram sections into bank 2 while a second process keeps reading words already written.
// Then every word is read back and compared, then random reads one at a time, then random
// reads streamed with as many in flight as rd_ready allows. The data is generated, no
// ROM is needed. The SDRAM model samples on the falling edge of clk_sdram (the board's
// lagging clock phase) and counts every ACTIVATE on a bank that is still open or still
// precharging. Ends with PASS or $fatal. Run by run_sim.sh.
`timescale 1ns/1ps
module tb_rom_sdram;
    localparam int NBYTES = 32'h3A000;    // the sdram sections of 1942.manifest
    logic clk_core = 0, clk_sdram = 0;
    always #13.468 clk_core  = ~clk_core;
    always #7.716  clk_sdram = ~clk_sdram;

    logic reset = 1, sd_resetn = 0;

    // ---------------- DUT ----------------
    logic        wr_we = 0;
    logic [21:0] wr_off = '0;
    logic [7:0]  wr_data = '0;
    logic        wr_ready, wr_idle;
    logic [21:2] rd_addr = '0;
    logic        rd_want = 0, rd_ready, rd_valid;
    wire         rd_push = rd_want && rd_ready;   // as rom_slots: only while rd_ready
    logic [31:0] rd_data;
    logic [21:0] sd_wr_addr, sd_rd_addr;
    logic [31:0] sd_wr_din, sd_rd_dout;
    logic [1:0]  sd_wr_bank, sd_rd_bank;
    logic        sd_wr_req, sd_wr_ack, sd_rd_req, sd_rd_ack, sd_rd_valid, sdram_ready, sd_rd_hint;

    rom_sdram #(.AW(22), .BANK(2'd2)) dut (
        .clk_core(clk_core), .reset(reset),
        .wr_we(wr_we), .wr_off(wr_off), .wr_data(wr_data), .wr_ready(wr_ready), .wr_idle(wr_idle),
        .rd_addr(rd_addr), .rd_push(rd_push), .rd_ready(rd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data),
        .clk_sdram(clk_sdram),
        .sd_wr_addr(sd_wr_addr), .sd_wr_din(sd_wr_din), .sd_wr_bank(sd_wr_bank),
        .sd_wr_req(sd_wr_req), .sd_wr_ack(sd_wr_ack),
        .sd_rd_addr(sd_rd_addr), .sd_rd_bank(sd_rd_bank), .sd_rd_req(sd_rd_req),
        .sd_rd_ack(sd_rd_ack), .sd_rd_dout(sd_rd_dout), .sd_rd_valid(sd_rd_valid),
        .sd_rd_hint(sd_rd_hint)
    );

    wire [31:0] dq;
    wire [10:0] a;
    wire [3:0]  dqm;
    wire [1:0]  ba;
    wire        ncs, nwe, nras, ncas, cke;
    sdram_fb #(.FREQ(64_800_000), .CAS(3'd2)) ctrl (
        .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_DQM(dqm), .SDRAM_BA(ba),
        .SDRAM_nCS(ncs), .SDRAM_nWE(nwe), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas), .SDRAM_CKE(cke),
        .clk(clk_sdram), .resetn(sd_resetn), .sdram_ready(sdram_ready), .cap_ofs(2'd1),
        .wr_addr(sd_wr_addr), .wr_din(sd_wr_din), .wr_bank(sd_wr_bank),
        .wr_req(sd_wr_req), .wr_ack(sd_wr_ack),
        .rd_addr(sd_rd_addr), .rd_bank(sd_rd_bank), .rd_req(sd_rd_req), .rd_ack(sd_rd_ack),
        .rd_dout(sd_rd_dout), .rd_valid(sd_rd_valid), .rd_hint(sd_rd_hint)
    );

    // ---------------- SDRAM model: 4 banks x 2048 rows x 256 columns x 32 bits, CL2, BL1 ----------------
    logic [31:0] mem [0:4*2048*256-1];
    logic [10:0] row [0:3];
    logic [31:0] dq_out = '0;
    logic        dq_drive = 0;
    logic [20:0] rd_pipe [0:2];              // {valid, bank, row, col}: the READ, then CL stages
    logic [2:0]  rd_vld = '0;
    assign dq = dq_drive ? dq_out : 'z;
    int writes = 0;
    // timing check: an ACTIVATE needs its bank closed and precharged (tRP 2 cycles after the
    // auto precharge, which starts CL cycles after a READ and tWR 2 cycles after a WRITE)
    longint cyc = 0, idle_at [0:3] = '{0, 0, 0, 0};
    logic   open_b [0:3] = '{0, 0, 0, 0};
    int     hazards = 0;
    always @(negedge clk_sdram) begin
        cyc <= cyc + 1;
        if (!ncs && {nras, ncas, nwe} == 3'b011) begin
            if (open_b[ba] || cyc < idle_at[ba]) begin
                hazards <= hazards + 1;
                if (hazards < 5) $display("ACT on bank %0d at cycle %0d: open %0d, idle from %0d", ba, cyc, open_b[ba], idle_at[ba]);
            end
            open_b[ba] <= 1'b1;
        end
        if (!ncs && {nras, ncas, nwe} == 3'b101) begin open_b[ba] <= 1'b0; idle_at[ba] <= cyc + 2 + 2; end
        if (!ncs && {nras, ncas, nwe} == 3'b100) begin open_b[ba] <= 1'b0; idle_at[ba] <= cyc + 2 + 2; end
    end
    always @(negedge clk_sdram) begin
        // read data: CL edges after the READ edge, for one cycle
        dq_drive <= rd_vld[1];
        if (rd_vld[1]) dq_out <= mem[rd_pipe[1][20:0]];
        rd_vld  <= {rd_vld[1:0], 1'b0};
        rd_pipe[1] <= rd_pipe[0];
        rd_pipe[2] <= rd_pipe[1];
        if (!ncs) case ({nras, ncas, nwe})
            3'b011: row[ba] <= a;                                      // ACTIVATE
            3'b101: begin rd_pipe[0] <= {ba, row[ba], a[7:0]}; rd_vld[0] <= 1'b1; end   // READ
            3'b100: begin mem[{ba, row[ba], a[7:0]}] <= dq; writes <= writes + 1; end  // WRITE
            default: ;                                                 // refresh, precharge, mode
        endcase
    end

    // ---------------- the data: a fixed scramble of the word address ----------------
    function automatic logic [31:0] word_at(int w); return 32'(w) * 32'h9E3779B1 ^ 32'h5A5A1234; endfunction
    function automatic logic [7:0] byte_at(int o); return word_at(o >> 2)[8*(o & 3) +: 8]; endfunction

    int errors = 0;
    int written_words = 0;                   // words the loader has completed so far
    logic loading = 1;
    // stress: while the image is being written, read words that are already in SDRAM
    initial begin
        int w, n = 0;
        wait (sd_resetn);
        while (loading) begin
            if (written_words > 16) begin
                w = $urandom % (written_words - 8);
                check(w);
                n++;
            end else
                @(posedge clk_core);
        end
        $display("%0d reads during loading", n);
    end
    initial begin
        repeat (10) @(posedge clk_core);
        reset <= 0;
        #1000 sd_resetn <= 1;
        // the loader: a byte, then at least one clock pause, and only while wr_ready
        for (int o = 0; o < NBYTES; o++) begin
            @(posedge clk_core);
            while (!wr_ready) @(posedge clk_core);
            wr_we <= 1; wr_off <= 22'(o); wr_data <= byte_at(o);
            @(posedge clk_core);
            wr_we <= 0;
            if ((o & 3) == 3) written_words = o / 4;   // the word before this one is surely out
            if ($urandom % 4 == 0) repeat ($urandom % 30) @(posedge clk_core);   // SPI gaps
        end
        while (!wr_idle) @(posedge clk_core);
        loading = 0;
        repeat (40) @(posedge clk_core);
        $display("written: %0d bytes, %0d SDRAM writes, sdram_ready %0d at %0t", NBYTES, writes, sdram_ready, $time);
        // read back every word
        for (int w = 0; w < NBYTES / 4; w++) check(w);
        $display("read back all %0d words, %0d errors", NBYTES / 4, errors);
        for (int i = 0; i < 20000; i++) check($urandom % (NBYTES / 4));
        $display("20000 random reads, %0d errors in total", errors);
        stream(20000);
        $display("20000 streamed reads, at most %0d in flight, %0d errors in total", fly_max, errors);
        if (errors != 0 || hazards != 0) $fatal(1, "FAIL: %0d errors, %0d SDRAM timing hazards", errors, hazards);
        $display("PASS");
        $finish;
    end

    int lat_max = 0, lat_sum = 0, nreads = 0;
    // one read: wanted until a clock edge takes it with rd_ready, then wait for the word
    task automatic check(input int w);
        int t;
        @(posedge clk_core);
        rd_addr <= 20'(w);
        rd_want <= 1;
        do @(posedge clk_core); while (!rd_ready);
        rd_want <= 0;
        t = 0;
        while (!rd_valid) begin @(posedge clk_core); t++; end
        nreads++; lat_sum += t; if (t > lat_max) lat_max = t;
        compare(w, rd_data);
    endtask

    task automatic compare(input int w, input logic [31:0] d);
        if (d !== word_at(w)) begin
            errors++;
            if (errors < 10) $display("word %05x: read %08x, expected %08x", w, d, word_at(w));
        end
    endtask

    // n reads, pushed back to back with random gaps. The words must come back in the order of the pushes.
    int fly_max = 0;
    task automatic stream(input int n);
        int sent = 0, got = 0, w;
        int q [$];
        while (got < n) begin
            @(posedge clk_core);
            if (rd_valid) begin
                compare(q.pop_front(), rd_data);
                got++;
            end
            if (rd_push) begin
                q.push_back(int'(rd_addr));
                sent++;
            end
            if (!rd_want || rd_ready) begin           // the last read is taken: offer the next
                if (sent < n && $urandom % 4 != 0) begin
                    w = $urandom % (NBYTES / 4);
                    rd_addr <= 20'(w);
                    rd_want <= 1;
                end else
                    rd_want <= 0;
            end
            if (q.size() > fly_max) fly_max = q.size();
        end
        rd_want <= 0;
    endtask

    final $display("read latency in core clocks: mean %0.1f, max %0d; SDRAM timing hazards %0d", real'(lat_sum) / nreads, lat_max, hazards);
endmodule
