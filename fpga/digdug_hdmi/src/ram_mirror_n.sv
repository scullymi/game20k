// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file ram_mirror_n.sv
//! @brief RAM mirror of N bytes for RetroAchievements: shadow, harvest, catch-up, delivery.
//!
//! g1942_mirror.sv for any size and one event source. The game reports every write into the
//! RAM that RetroAchievements reads as one event with its flat address (the FBNeo layout of
//! the set) and the module keeps its own copy, the live shadow, so the core's RAM ports stay
//! untouched. Power-on content is zero like the core's RAMs, a core reset keeps both.
//!
//! Both memories are built from banks of 2048 bytes, one block RAM each: N = 5120 takes
//! 3 + 3 blocks. As one array of N bytes Gowin rounds up to a power of two (g1942_mirror.sv,
//! measured: 9344 bytes became 16384).
//!
//! Once per frame, at frame_go, the harvest copies the live shadow into the snapshot, one
//! byte per clock. Every event inside that window is logged (log_we, the platform's oracle,
//! snap_log.sv) and caught up into the snapshot, so the snapshot is the state at the end of
//! the window, which is what the Pico checks against the log:
//!   - no read of the live shadow is issued in the clock an event writes it,
//!   - the catch-up queue writes the snapshot only in clocks without a harvest write and keeps
//!     the order of the events, so for each address the last event wins,
//!   - the window ends only when the queue is empty.
//!
//! Delivery follows the platform contract of game20k_top.sv as g1942_mirror.sv does: the first
//! read in the third snap_run cycle, the first push in the fourth, one byte per clock while
//! the FIFO has room. No harvest starts while snap_run is high, no delivery during a harvest.
module ram_mirror_n #(
    parameter int N = 5120                  //!< bytes of the mirror, MIRROR_DATA, up to 32768
)(
    input  wire         clk,
    input  wire         reset,              //!< blocks harvest starts
    input  wire         frame_go,           //!< one clock per frame
    //! ---- write events, one clock each, at most one per clock ----
    input  wire         ev,
    input  wire  [14:0] ev_flat,
    input  wire  [7:0]  ev_data,
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
    localparam int NB = (N + 2047) / 2048;  // banks of 2048 bytes
    localparam int BW = NB > 1 ? $clog2(NB) : 1;

    assign log_we   = ev;
    assign log_addr = {1'b0, ev_flat};
    assign log_data = ev_data;

    // ---------------- the live shadow ----------------
    logic [14:0] lr_addr;
    logic [7:0]  lr_bank [0:NB-1];
    logic [BW-1:0] lr_sel;
    for (genvar b = 0; b < NB; b++) begin : g_live
        logic [7:0] mem [0:2047];
        always_ff @(posedge clk) begin
            if (ev && ev_flat[14:11] == 4'(b)) mem[ev_flat[10:0]] <= ev_data;
            lr_bank[b] <= mem[lr_addr[10:0]];
        end
    end
    always_ff @(posedge clk) lr_sel <= BW'(lr_addr[14:11]);
    wire [7:0] lr_q = lr_bank[lr_sel];

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

    // ---------------- the snapshot and its delivery ----------------
    logic [1:0]  run_n = 2'd0;              // snap_run cycles so far, saturating at 3
    logic        dl = 1'b0;
    logic [14:0] dl_ptr;
    logic        q_v = 1'b0;
    logic [7:0]  q_bank [0:NB-1];
    logic [BW-1:0] q_sel;
    wire  [7:0]  q    = q_bank[q_sel];
    wire         take = dl && q_v && !snap_full;       // the byte in q is pushed now
    wire         rd   = dl && dl_ptr != 15'(N) && (!q_v || take);
    for (genvar b = 0; b < NB; b++) begin : g_snap
        logic [7:0] mem [0:2047];
        always_ff @(posedge clk) begin
            if (sw_we && sw_addr[14:11] == 4'(b)) mem[sw_addr[10:0]] <= sw_data;
            if (rd) q_bank[b] <= mem[dl_ptr[10:0]];
        end
    end
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
                    q_sel  <= BW'(dl_ptr[14:11]);
                    dl_ptr <= dl_ptr + 15'd1;
                    q_v    <= 1'b1;
                end else if (take)
                    q_v <= 1'b0;
            end
        end
    end
    assign snap_push = dl && q_v;
    assign snap_byte = q;
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
