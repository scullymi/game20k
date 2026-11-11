// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file tb_ram_mirror.sv
//! @brief ram_mirror.sv against a model, at the sizes and event sources of the games and at the
//!        smallest and largest size with both sources and writes beyond N.
//!
//! Each instance of ram_mirror_check drives one mirror with random CPU writes (a few hot
//! addresses, two sources that may come together, each at most once in three clocks as a CPU
//! writes), frame starts, resets over a frame start, snap_full stalls and transfers that start
//! at any time, some on purpose inside a harvest. It checks:
//!   - every delivered snapshot byte against the model's RAM at the end of the last harvest,
//!   - the Pico's oracle: the last logged value per address equals the delivered byte,
//!   - the log of a window against the model's writes in it (the second source may slip one
//!     write into the first clock of the window, so one more is allowed),
//!   - no harvest starts during a transfer or the clock after it, a transfer refuses to
//!     deliver when a harvest runs in its third clock and delivers exactly N bytes otherwise,
//!   - snap_frame counts the harvests, writes at or beyond N leave no trace.
//! Ends with PASS or $fatal, after a minimum of harvests and of both kinds of transfer.

module ram_mirror_check #(
    parameter int N        = 2048,     //!< MIRROR_DATA of the mirror
    parameter bit TWO      = 0,        //!< both event sources in use
    parameter bit OUTSIDE  = 0,        //!< some writes at or beyond N
    parameter int HOLE_LO  = 0,        //!< no writes in [HOLE_LO, HOLE_HI), as 1943's core
    parameter int HOLE_HI  = 0,
    parameter int XFERS    = 32,       //!< transfers to run
    parameter int unsigned SEED = 1
)(
    input  logic clk,
    output logic done,
    output int   errors
);
    logic        reset = 1, frame_go = 0, snap_run = 0, snap_full = 0;
    logic        m_ev = 0, s_ev = 0;
    logic [14:0] m_flat = 0, s_flat = 0;
    logic [7:0]  m_data = 0, s_data = 0;
    wire         snap_push, snap_harv, log_we;
    wire  [7:0]  snap_byte, log_data;
    wire  [15:0] snap_frame, log_addr;

    ram_mirror #(.N(N)) dut (
        .clk(clk), .reset(reset), .frame_go(frame_go),
        .m_ev(m_ev), .m_flat(m_flat), .m_data(m_data),
        .s_ev(s_ev), .s_flat(s_flat), .s_data(s_data),
        .snap_run(snap_run), .snap_full(snap_full), .snap_push(snap_push), .snap_byte(snap_byte),
        .snap_frame(snap_frame), .snap_harv(snap_harv),
        .log_we(log_we), .log_addr(log_addr), .log_data(log_data)
    );

    // xorshift32, one state per instance
    int unsigned rs = SEED;
    function automatic int unsigned rnd(input int unsigned range);
        rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5;
        return rs % range;
    endfunction

    function automatic logic [14:0] pick_addr();
        int unsigned a;
        if (OUTSIDE && rnd(20) == 0) return 15'(N + rnd(32768 - N));
        if (rnd(10) < 3) a = (rnd(4) * 37 + 5) % N;          // four hot addresses
        else             a = rnd(N);
        if (HOLE_HI > HOLE_LO && a >= HOLE_LO && a < HOLE_HI) a = HOLE_LO - 1;
        return 15'(a);
    endfunction

    function automatic void err(input string what);
        errors++;
        if (errors <= 5) $display("FAIL N=%0d: %s", N, what);
    endfunction

    // ---------------- the model, at every clock edge ----------------
    logic [7:0]  live [N], snap [N];
    int          frames_done = 0, refused = 0, delivered = 0, skipped = 0, n_ev = 0, n_log = 0;
    logic        h_prev = 0, run_q = 0, run_qq = 0;
    int          win_ev = 0, win_log = 0;
    logic [15:0] log_a [$];
    logic [7:0]  log_d [$];
    initial begin
        foreach (live[i]) begin live[i] = 0; snap[i] = 0; end
    end
    always @(posedge clk) begin
        // values of the clock that ends here
        automatic logic h = snap_harv;
        // a harvest ended at the edge before: the snapshot is the RAM after its last write
        if (h_prev && !h) begin
            foreach (live[i]) snap[i] = live[i];
            frames_done++;
            if (win_log < win_ev || win_log > win_ev + (TWO ? 1 : 0))
                err($sformatf("window logged %0d writes, the model has %0d", win_log, win_ev));
            if (snap_frame != 16'(frames_done))
                err($sformatf("snap_frame %0d after %0d harvests", snap_frame, frames_done));
        end
        if (!h_prev && h) begin
            if (run_q || run_qq) err("a harvest started during a transfer");
            win_ev = 0; win_log = 0;
            log_a.delete(); log_d.delete();
        end
        if (frame_go && !h && (reset || snap_run || run_q)) skipped++;
        // the writes of this clock, the first source first
        if (m_ev && m_flat < 15'(N)) begin live[m_flat] = m_data; n_ev++; if (h) win_ev++; end
        if (s_ev && s_flat < 15'(N)) begin live[s_flat] = s_data; n_ev++; if (h) win_ev++; end
        if (log_we) begin
            if (log_addr >= 16'(N)) err($sformatf("logged a write at %0d", log_addr));
            if (h) begin win_log++; n_log++; log_a.push_back(log_addr); log_d.push_back(log_data); end
        end
        h_prev = h;
        run_qq = run_q;
        run_q  = snap_run;
    end

    // ---------------- stimulus ----------------
    int unsigned period;
    // one clock per write, then at least two without, as a Z80 writes at most once in a few clocks.
    // About one write in 14 clocks per source, several times what a Z80 at 3 to 8 MHz writes.
    task automatic source(input bit second);
        forever begin
            @(negedge clk);
            if (rnd(12) == 0) begin
                if (second) begin s_ev = 1; s_flat = pick_addr(); s_data = 8'(rnd(256)); end
                else        begin m_ev = 1; m_flat = pick_addr(); m_data = 8'(rnd(256)); end
                @(negedge clk);
                if (second) s_ev = 0; else m_ev = 0;
                repeat (1 + rnd(4)) @(negedge clk);
            end
        end
    endtask

    task automatic frames();
        forever begin
            repeat (period + rnd(N)) @(negedge clk);
            if (rnd(12) == 0) reset = 1;
            frame_go = 1;
            @(negedge clk);
            frame_go = 0;
            repeat (3) @(negedge clk);
            reset = 0;
        end
    endtask

    task automatic fifo();
        forever begin
            @(negedge clk);
            snap_full = rnd(10) < 3;
        end
    endtask

    // one transfer as game20k_top.sv runs it: snap_run high, pushes count from the third clock,
    // only with snap_full low, snap_run falls after N bytes or when nothing comes
    task automatic transfer();
        int got = 0, cyc = 0;
        bit harv3 = 0;
        logic [7:0] bytes [$];
        snap_run = 1;
        forever begin
            @(posedge clk);
            cyc++;
            if (cyc == 3) harv3 = snap_harv;
            if (snap_push && !snap_full) begin
                if (cyc < 4) err($sformatf("a push in clock %0d of the transfer", cyc));
                bytes.push_back(snap_byte);
                got++;
            end
            if (got == N || (harv3 && cyc == 64) || cyc > 4 * N + 200) break;
        end
        @(negedge clk);
        snap_run = 0;
        // now and then a frame start in the clock after the transfer, when no harvest may start
        if (rnd(3) == 0) begin
            frame_go = 1;
            @(negedge clk);
            frame_go = 0;
        end
        if (harv3) begin
            refused++;
            if (got != 0) err($sformatf("%0d bytes delivered while a harvest ran", got));
        end else if (got != N) begin
            err($sformatf("%0d of %0d bytes delivered", got, N));
        end else begin
            delivered++;
            foreach (bytes[i])
                if (bytes[i] !== snap[i]) begin
                    err($sformatf("byte %0d is %h, the model has %h", i, bytes[i], snap[i]));
                    break;
                end
            // the Pico's oracle: the last logged value of an address is in the snapshot
            for (int i = 0; i < log_a.size(); i++) begin
                automatic bit last = 1;
                for (int j = i + 1; j < log_a.size(); j++) if (log_a[j] == log_a[i]) last = 0;
                if (last && bytes[log_a[i]] !== log_d[i])
                    err($sformatf("oracle: address %0d logged %h, delivered %h",
                                  log_a[i], log_d[i], bytes[log_a[i]]));
            end
        end
    endtask

    initial begin
        done = 0; errors = 0;
        // a harvest takes about N clocks, so a frame of 3 N + 500 leaves room for transfers
        period = 3 * N + 500;
        repeat (5) @(negedge clk);
        reset = 0;
        fork
            source(0);
            if (TWO) source(1);
            frames();
            fifo();
        join_none
        for (int x = 0; x < XFERS; x++) begin
            // every fourth transfer starts right after a frame start, inside the harvest
            if (x % 4 == 3) begin
                @(posedge frame_go);
                repeat (2) @(negedge clk);
            end else
                repeat (rnd(period)) @(negedge clk);
            transfer();
        end
        if (frames_done < XFERS / 4) err($sformatf("only %0d harvests", frames_done));
        if (delivered == 0 || refused == 0)
            err($sformatf("%0d transfers delivered, %0d refused", delivered, refused));
        $display("N=%0d%s: %0d harvests, %0d frame starts skipped, %0d transfers delivered, %0d refused, %0d writes, %0d logged",
                 N, TWO ? " two sources" : "", frames_done, skipped, delivered, refused, n_ev, n_log);
        done = 1;
    end
endmodule

module tb_ram_mirror;
    logic clk = 0;
    always #13.468 clk = ~clk;

    // the games: 1942 (two CPUs), 1943 (nothing in 0x1000-0x1FFF), Time Pilot, GnG, Dig Dug
    localparam int K = 8;
    wire        done [K];
    int         errors [K];
    ram_mirror_check #(.N(9344), .TWO(1), .SEED(11))                        c1942 (clk, done[0], errors[0]);
    ram_mirror_check #(.N(8960), .HOLE_LO(4096), .HOLE_HI(8192), .SEED(12)) c1943 (clk, done[1], errors[1]);
    ram_mirror_check #(.N(2048), .SEED(13))                                 ctp   (clk, done[2], errors[2]);
    ram_mirror_check #(.N(5760), .SEED(14))                                 cgng  (clk, done[3], errors[3]);
    ram_mirror_check #(.N(5120), .SEED(15))                                 cdd   (clk, done[4], errors[4]);
    // beyond the games: the smallest and largest size, an odd one, both sources, writes beyond N
    ram_mirror_check #(.N(128),   .TWO(1), .OUTSIDE(1), .SEED(16))          cmin  (clk, done[5], errors[5]);
    ram_mirror_check #(.N(22528), .TWO(1), .OUTSIDE(1), .SEED(17))          cmax  (clk, done[6], errors[6]);
    ram_mirror_check #(.N(4224),  .TWO(1), .OUTSIDE(1), .SEED(18))          codd  (clk, done[7], errors[7]);

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
