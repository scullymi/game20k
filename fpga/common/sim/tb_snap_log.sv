// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file tb_snap_log.sv
//! @brief snap_log.sv against a model: what one harvest window logs and how it is delivered.
//!
//! Each instance of snap_log_check runs harvest windows of random length with random writes,
//! some on purpose in the first and last clock of a window and in the clocks just before and
//! after it. Most windows are delivered as game20k_top.sv does (send_start, then pops, sometimes
//! in consecutive clocks), the others are followed by a window one clock later. It checks:
//!   - every write of a clock with harv_busy high is logged, in order, nothing else,
//!   - count and overflow: count is the number of entries up to DEPTH, overflow once more came,
//!   - the delivered bytes: address low, address high, data for each entry.
//! Ends with PASS or $fatal, after a minimum of windows, of overflows and of writes in the
//! first window clock.

module snap_log_check #(
    parameter int DEPTH = 512,
    parameter int WINDOWS = 200,
    parameter int unsigned SEED = 1
)(
    input  logic clk,
    output logic done,
    output int   errors
);
    logic        harv = 0, we = 0, start = 0, pop = 0;
    logic [15:0] addr = 0;
    logic [7:0]  data = 0;
    wire  [7:0]  sbyte;
    wire  [9:0]  count;
    wire         ovf;

    snap_log #(.DEPTH(DEPTH)) dut (
        .clk(clk), .harv_busy(harv), .ram_we(we), .ram_addr(addr), .ram_data(data),
        .send_start(start), .send_pop(pop), .send_byte(sbyte), .count(count), .overflow(ovf)
    );

    // xorshift32, one state per instance
    int unsigned rs = SEED;
    function automatic int unsigned rnd(input int unsigned range);
        rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5;
        return rs % range;
    endfunction

    function automatic void err(input string what);
        errors++;
        if (errors <= 5) $display("FAIL DEPTH=%0d: %s", DEPTH, what);
    endfunction

    // the model: every write of a clock in which harv_busy is high, sampled at the clock edge
    logic [23:0] exp_q [$];
    int          exp_n = 0, first_hits = 0, overflows = 0, back2back = 0;
    bit          gap = 1;
    always @(posedge clk) begin
        if (harv && we) begin
            if (exp_q.size() < DEPTH) exp_q.push_back({data, addr});
            exp_n++;
        end
    end

    // a write in this clock or none
    task automatic put(input bit w);
        we = w;
        if (w) begin addr = 16'(rnd(65536)); data = 8'(rnd(256)); end
    endtask

    // the next clock, a write in it with probability 1/p, always when force_we
    task automatic step(input int p, input bit force_we);
        @(negedge clk);
        put(force_we || rnd(p) == 0);
    endtask

    // one window: with gap a few clocks without the window first, the last one with a write now
    // and then, without gap it opens in the clock after the last window closed
    task automatic window(input bit gap);
        int len = 1 + (rnd(4) == 0 ? rnd(4) : rnd(3 * DEPTH));
        int p = 1 + rnd(4);
        bit first = rnd(2) == 0;
        exp_q.delete();
        exp_n = 0;
        if (gap) begin
            repeat (rnd(3)) step(p, 0);
            step(p, rnd(2) == 0);
        end
        @(negedge clk);
        harv = 1;
        put(first);
        if (first) first_hits++;
        repeat (len - 1) step(p, 0);
        // the clock after the window, with a write now and then
        @(negedge clk);
        harv = 0;
        put(rnd(2) == 0);
    endtask

    task automatic deliver();
        int n;
        // past the clock after the window, so a write logged there shows in count
        @(negedge clk);
        put(0);
        n = exp_q.size();
        if (count != 10'(n))
            err($sformatf("count %0d, the model logged %0d", count, n));
        if (ovf != (exp_n > DEPTH))
            err($sformatf("overflow %0d after %0d writes", ovf, exp_n));
        if (exp_n > DEPTH) overflows++;
        repeat (rnd(3)) @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        for (int i = 0; i < n; i++)
            for (int b = 0; b < 3; b++) begin
                automatic logic [7:0] want = exp_q[i][8 * b +: 8];
                if (rnd(2) == 0) repeat (1 + rnd(3)) @(negedge clk);
                if (sbyte !== want) begin
                    err($sformatf("entry %0d byte %0d is %h, the model has %h", i, b, sbyte, want));
                    i = n;
                    break;
                end
                pop = 1;
                @(negedge clk);
                pop = 0;
            end
    endtask

    initial begin
        done = 0; errors = 0;
        repeat (3) @(negedge clk);
        // a window is delivered before the next, or the next opens in the clock after it
        for (int w = 0; w < WINDOWS; w++) begin
            window(w == 0 || gap);
            gap = rnd(4) != 0;
            if (gap || w == WINDOWS - 1) deliver();
            else back2back++;
        end
        if (first_hits < WINDOWS / 4 || overflows == 0 || back2back == 0)
            err($sformatf("%0d windows with a write in the first clock, %0d overflows, %0d back to back",
                          first_hits, overflows, back2back));
        $display("DEPTH=%0d: %0d windows, %0d with a write in the first clock, %0d overflows, %0d back to back",
                 DEPTH, WINDOWS, first_hits, overflows, back2back);
        done = 1;
    end
endmodule

module tb_snap_log;
    logic clk = 0;
    always #13.468 clk = ~clk;

    // the depth game20k_top.sv uses and a small one that overflows often
    wire done [2];
    int  errors [2];
    snap_log_check #(.DEPTH(512), .WINDOWS(150), .SEED(21)) c512 (clk, done[0], errors[0]);
    snap_log_check #(.DEPTH(16),  .WINDOWS(400), .SEED(22)) c16  (clk, done[1], errors[1]);

    initial begin
        int total;
        foreach (done[i]) wait (done[i]);
        total = 0;
        foreach (errors[i]) total += errors[i];
        if (total != 0) $fatal(1, "FAIL: %0d errors", total);
        $display("PASS");
        $finish;
    end
endmodule
