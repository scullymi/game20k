// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file mirror_n.sv
//! @brief RAM mirror for RetroAchievements of any size N: g1942_mirror.sv with the
//! memories sized from N instead of a fixed split at 0x2000.
//!
//! The game core decodes its CPU writes into the flat address space of FBNeo's "All Ram"
//! and hands them in as events (one clock each, two sources that may come together). Every
//! event goes into the live shadow, which therefore always equals what the CPUs wrote. Its
//! power-on content is zero like the core's RAMs, a core reset keeps both. Events at or
//! above N are ignored.
//!
//! Each of the two memories (live shadow, snapshot) is split into LO, the largest power of
//! two not above N, and the rest NH = N - LO. Gowin rounds a memory up to a power of two, so
//! one array of N bytes would cost up to twice the blocks (5760 bytes: 4 blocks as one
//! array, 2 + 1 split).
//!
//! Once per frame, at frame_go (the start of the vertical blank), the harvest copies the live
//! shadow into the snapshot, one byte per clock: N clocks. Every event during that window is
//! logged (log_we, the platform's oracle, snap_log.sv) and caught up into the snapshot, so the
//! snapshot is the state at the end of the window, which is what the Pico checks against the
//! log: the last logged value per address.
//!   - A read of the live shadow is never issued in the clock an event writes it, so no
//!     read sees a half-written byte.
//!   - The catch-up queue writes the snapshot only in clocks without a harvest write and
//!     keeps the order of the events, so for each address the last event wins.
//!   - The window ends only when the queue is empty.
//!
//! Delivery, against the platform contract of game20k_top.sv: snap_run rises at the verdict
//! byte, the top resets its FIFO at the end of the second snap_run cycle with priority over
//! a push, a push counts only with snap_full = 0 in the same clock, everything is dropped
//! when snap_run falls. Here the first read comes in the third snap_run cycle, the first push
//! in the fourth, one byte per clock while the FIFO has room. No harvest starts while
//! snap_run is high, and no delivery starts while a harvest runs.
module mirror_n #(
    parameter int N = 5760                  //!< bytes of the mirror, MIRROR_DATA, 2..22528
)(
    input  wire         clk,
    input  wire         reset,              //!< blocks harvest starts
    input  wire         frame_go,           //!< one clock per frame, start of the vertical blank
    //! ---- CPU write events, one clock each, flat address, both sources may come together ----
    input  wire         m_ev,
    input  wire  [14:0] m_flat,
    input  wire  [7:0]  m_data,
    input  wire         s_ev,
    input  wire  [14:0] s_flat,
    input  wire  [7:0]  s_data,
    //! ---- platform ----
    input  wire         snap_run,
    input  wire         snap_full,
    output logic        snap_push,
    output logic [7:0]  snap_byte,
    output logic [15:0] snap_frame,
    output logic        snap_harv,
    output logic        log_we,
    output logic [15:0] log_addr,
    output logic [7:0]  log_data
);
    // LO: the largest power of two not above N, NH the rest (0 when N is a power of two)
    localparam int LW = $clog2(N + 1) - 1;
    localparam int LO = 1 << LW;
    localparam int NH = N - LO;
    localparam int HW = NH > 1 ? $clog2(NH) : 1;
    localparam int NHM = NH > 0 ? NH : 1;   // array size, never 0
    function automatic logic in_lo(input logic [14:0] a);
        return (a >> LW) == 15'd0;
    endfunction

    // ---------------- events: serialised, one per clock ----------------
    // The second source waits one clock when both come together. Each CPU writes at most
    // once in several clocks, so one held slot is enough.
    logic        sh_v = 1'b0;
    logic [14:0] sh_flat;
    logic [7:0]  sh_data;
    logic        ev_any;
    logic [14:0] ev_flat;
    logic [7:0]  ev_data;
    always_comb begin
        ev_any = 1'b0; ev_flat = m_flat; ev_data = m_data;
        if (m_ev)      begin ev_any = 1'b1; ev_flat = m_flat;  ev_data = m_data;  end
        else if (sh_v) begin ev_any = 1'b1; ev_flat = sh_flat; ev_data = sh_data; end
        else if (s_ev) begin ev_any = 1'b1; ev_flat = s_flat;  ev_data = s_data;  end
    end
    always_ff @(posedge clk) begin
        if (s_ev && (m_ev || sh_v)) begin sh_v <= 1'b1; sh_flat <= s_flat; sh_data <= s_data; end
        else if (sh_v && !m_ev)     sh_v <= 1'b0;
    end
    // only addresses inside the mirror count, as an event and for the log
    wire ev = ev_any && ev_flat < 15'(N);
    assign log_we   = ev;
    assign log_addr = {1'b0, ev_flat};
    assign log_data = ev_data;

    // ---------------- the live shadow ----------------
    logic [7:0]  live_lo [0:LO-1];
    logic [7:0]  live_hi [0:NHM-1];
    logic [14:0] lr_addr;
    logic [7:0]  lr_lo, lr_hi = 8'h00;
    logic        lr_sel;
    always_ff @(posedge clk) begin
        if (ev && in_lo(ev_flat)) live_lo[ev_flat[LW-1:0]] <= ev_data;
        lr_lo  <= live_lo[lr_addr[LW-1:0]];
        lr_sel <= !in_lo(lr_addr);
    end
    generate if (NH > 0) begin : g_live_hi
        always_ff @(posedge clk) begin
            if (ev && !in_lo(ev_flat)) live_hi[ev_flat[HW-1:0]] <= ev_data;
            lr_hi <= live_hi[lr_addr[HW-1:0]];
        end
    end endgenerate
    wire [7:0] lr_q = lr_sel ? lr_hi : lr_lo;

    // ---------------- harvest window ----------------
    logic        harv = 1'b0;               // the window
    logic [14:0] h_idx;                     // next byte to read
    logic        rd_v = 1'b0;               // a read was issued last clock
    logic [14:0] rd_idx;
    // catch-up queue, 4 entries: events inside the window, in order
    logic [22:0] cq [0:3];
    logic [2:0]  cq_wp = 3'd0, cq_rp = 3'd0;
    wire         cq_empty = (cq_wp == cq_rp);
    logic        run_d = 1'b0;
    always_ff @(posedge clk) run_d <= snap_run;

    wire issue = harv && h_idx != 15'(N) && cq_empty && !ev;
    assign lr_addr = h_idx;

    // snapshot write port: the harvest write of last clock's read, else one catch-up
    logic [7:0]  snap_lo [0:LO-1];
    logic [7:0]  snap_hi [0:NHM-1];
    logic        sw_we;
    logic [14:0] sw_addr;
    logic [7:0]  sw_data;
    wire         cq_pop = harv && !rd_v && !cq_empty;
    always_comb begin
        sw_we = 1'b0; sw_addr = rd_idx; sw_data = lr_q;
        if (rd_v) begin
            sw_we = 1'b1;
        end else if (cq_pop) begin
            sw_we = 1'b1; sw_addr = cq[cq_rp[1:0]][22:8]; sw_data = cq[cq_rp[1:0]][7:0];
        end
    end

    always_ff @(posedge clk) begin
        if (sw_we && in_lo(sw_addr)) snap_lo[sw_addr[LW-1:0]] <= sw_data;
        rd_v <= issue;
        if (issue) begin
            rd_idx <= h_idx;
            h_idx  <= h_idx + 15'd1;
        end
        // events inside the window go into the catch-up queue
        if (harv && ev) begin
            cq[cq_wp[1:0]] <= {ev_flat, ev_data};
            cq_wp <= cq_wp + 3'd1;
        end
        if (cq_pop) cq_rp <= cq_rp + 3'd1;
        // start: at frame_go, not in reset, not during a delivery, not during a harvest
        if (!harv && frame_go && !reset && !snap_run && !run_d) begin
            harv  <= 1'b1;
            h_idx <= 15'd0;
            cq_wp <= 3'd0;
            cq_rp <= 3'd0;
        end
        // end: everything read and written, the queue empty, no event in this clock
        if (harv && h_idx == 15'(N) && !rd_v && cq_empty && !ev && !issue) begin
            harv       <= 1'b0;
            snap_frame <= snap_frame + 16'd1;
        end
    end
    initial snap_frame = 16'd0;
    assign snap_harv = harv;

    // ---------------- delivery ----------------
    logic [1:0]  run_n = 2'd0;              // snap_run cycles so far, saturating at 3
    logic        dl = 1'b0;
    logic [14:0] dl_ptr;
    logic        q_v = 1'b0;
    logic [7:0]  q_lo, q_hi = 8'h00;
    logic        q_sel;
    wire  [7:0]  q = q_sel ? q_hi : q_lo;
    wire         take = dl && q_v && !snap_full;       // the byte in q is pushed now
    wire         rd   = dl && dl_ptr != 15'(N) && (!q_v || take);
    always_ff @(posedge clk) begin
        if (!snap_run) begin
            run_n <= 2'd0;
            dl    <= 1'b0;
            q_v   <= 1'b0;
        end else begin
            if (run_n != 2'd3) run_n <= run_n + 2'd1;
            // the third snap_run cycle: the FIFO was reset at the end of the second
            if (run_n == 2'd2 && !harv) begin
                dl     <= 1'b1;
                dl_ptr <= 15'd0;
                q_v    <= 1'b0;
            end else if (dl) begin
                if (rd) begin
                    q_lo   <= snap_lo[dl_ptr[LW-1:0]];
                    q_sel  <= !in_lo(dl_ptr);
                    dl_ptr <= dl_ptr + 15'd1;
                    q_v    <= 1'b1;
                end else if (take)
                    q_v <= 1'b0;
            end
        end
    end
    generate if (NH > 0) begin : g_snap_hi
        always_ff @(posedge clk) begin
            if (sw_we && !in_lo(sw_addr)) snap_hi[sw_addr[HW-1:0]] <= sw_data;
            if (snap_run && dl && rd) q_hi <= snap_hi[dl_ptr[HW-1:0]];
        end
    end endgenerate
    assign snap_push = dl && q_v;
    assign snap_byte = q;
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
