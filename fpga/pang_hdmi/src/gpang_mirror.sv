// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file gpang_mirror.sv
//! @brief The RAM mirror of Pang and Super Pang for RetroAchievements: harvest, catch-up, delivery.
//!
//! RetroAchievements reads FBNeo's "All Ram" block of the Mitchell board (d_mitchell.cpp,
//! PangMemIndex), 22528 bytes at these flat addresses:
//!   0x0000 work RAM 8 KiB (E000-FFFF)        0x3800 video RAM bank 0, the tile map (D000-DFFF)
//!   0x2000 palette 4 KiB (C000-C7FF, 2 banks) 0x4800 video RAM bank 1, the sprites
//!   0x3000 attributes 2 KiB (C800-CFFF)
//! The mirror delivers the first N of them. Of these it keeps two parts: the work RAM, which
//! both sets read, and a window of the tile map at TM_FLAT, which Pang's set reads (a row near
//! the bottom of the screen). Every other byte goes out as 0.
//!
//! The work RAM is the core's own: jtframe_sysz80_nvram has a second port for an NVRAM dump,
//! which jtpang does not use, and the harvest reads there (wr_addr, wr_q one clock later).
//! The tile map RAM has both ports in use, so the window keeps a live shadow of its own,
//! written by the CPU's writes into it (v_ev). Its power-on content is zero like the core's
//! RAM, a core reset keeps both.
//!
//! Once per frame, at frame_go (the start of the vertical blank), the harvest copies the work
//! RAM and the window into the snapshot, one byte per clock, 8448 clocks, 228 us at
//! 37.125 MHz plus the clocks it waits. Every CPU write into a kept part during that window is
//! logged (log_we, the platform's oracle, snap_log.sv) and caught up into the snapshot, so the
//! snapshot is the state at the end of the window, which the Pico checks against the log:
//!   - The harvest reads neither part in a clock the CPU writes it: not the work RAM while
//!     its write strobe (w_busy) is high, a read beside a write on the other port of a block
//!     RAM is not defined, and not the shadow in the clock of an event.
//!   - The catch-up queue writes the snapshot only in clocks without a harvest write and
//!     keeps the order of the events, so for each address the last event wins.
//!   - The window ends only when the queue is empty.
//! Bound: one Z80 at 8 MHz, PUSH writes two bytes in 11 T states, so at most about 450 writes
//! in 300 us, against the platform's 512; the game's loops write far less.
//!
//! Delivery, against the platform contract of game20k_top.sv, as in g1942_mirror.sv: the first
//! read in the third snap_run cycle, the first push in the fourth, one byte per clock while the
//! FIFO has room. No harvest starts while snap_run is high, no delivery while a harvest runs.
module gpang_mirror #(
    parameter int N       = 18176,          //!< bytes of the mirror, MIRROR_DATA, at most 22528
    parameter int TM_FLAT = 16'h4600,       //!< flat address of the tile map window
    parameter int TM_LEN  = 256             //!< bytes of the window, a power of two
)(
    input  wire         clk,
    input  wire         reset,              //!< blocks harvest starts
    input  wire         frame_go,           //!< one clock per frame, start of the vertical blank
    //! ---- work RAM: its second port, and the CPU's writes into it ----
    output logic [12:0] wr_addr,
    input  wire  [7:0]  wr_q,               //!< one clock after wr_addr
    input  wire         w_busy,             //!< the CPU's write strobe, high for the whole write
    input  wire         w_ev,               //!< one clock at the start of a write
    input  wire  [12:0] w_addr,
    input  wire  [7:0]  w_data,
    //! ---- tile map: the CPU's writes into video RAM bank 0, offset from D000 ----
    input  wire         v_ev,               //!< one clock at the start of a write
    input  wire  [11:0] v_addr,
    input  wire  [7:0]  v_data,
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
    localparam int TW     = $clog2(TM_LEN);
    localparam int TM_OFS = TM_FLAT - 16'h3800;      // offset of the window in bank 0
    localparam int HN     = 8192 + TM_LEN;            // bytes the harvest copies

    // ---------------- events: one CPU, so at most one per clock ----------------
    // A tile map write counts only inside the window, the other parts are not kept.
    wire        v_in   = v_ev && v_addr >= 12'(TM_OFS) && v_addr < 12'(TM_OFS + TM_LEN);
    wire        ev     = w_ev || v_in;
    wire [15:0] ev_flat = w_ev ? {3'd0, w_addr} : 16'(TM_FLAT) + 16'(v_addr - 12'(TM_OFS));
    wire [7:0]  ev_data = w_ev ? w_data : v_data;
    assign log_we   = ev;
    assign log_addr = ev_flat;
    assign log_data = ev_data;

    // ---------------- the live shadow of the tile map window ----------------
    logic [7:0]    live_tm [0:TM_LEN-1];
    logic [TW-1:0] lt_addr;
    logic [7:0]    lt_q;
    always_ff @(posedge clk) begin
        if (v_in) live_tm[TW'(v_addr - 12'(TM_OFS))] <= v_data;
        lt_q <= live_tm[lt_addr];
    end

    // ---------------- harvest window ----------------
    logic        harv = 1'b0;               // the window
    logic [13:0] h_idx;                     // next byte to read: work RAM, then the window
    logic        rd_v = 1'b0;               // a read was issued last clock
    logic [13:0] rd_idx;
    // catch-up queue, 4 entries: events inside the window, in order
    logic [23:0] cq [0:3];
    logic [2:0]  cq_wp = 3'd0, cq_rp = 3'd0;
    wire         cq_empty = (cq_wp == cq_rp);
    logic        run_d = 1'b0;
    always_ff @(posedge clk) run_d <= snap_run;

    wire issue = harv && h_idx != 14'(HN) && cq_empty && !ev && !w_busy;
    assign wr_addr = h_idx[12:0];
    assign lt_addr = TW'(h_idx);
    logic  rd_tm;                           // last clock's read was the window
    wire [7:0] rd_q = rd_tm ? lt_q : wr_q;

    // snapshot: the work RAM and the window, written by the harvest or by one catch-up
    logic [7:0]  snap_wr [0:8191];
    logic [7:0]  snap_tm [0:TM_LEN-1];
    logic        sw_we;
    logic [13:0] sw_idx;                    // harvest index: work RAM below 8192, then the window
    logic [7:0]  sw_data;
    wire         cq_pop = harv && !rd_v && !cq_empty;
    // a flat address of a kept part as harvest index
    function automatic logic [13:0] idx_of(input logic [15:0] flat);
        return flat < 16'd8192 ? 14'(flat) : 14'(8192) + 14'(flat - 16'(TM_FLAT));
    endfunction
    always_comb begin
        sw_we = 1'b0; sw_idx = rd_idx; sw_data = rd_q;
        if (rd_v) begin
            sw_we = 1'b1;
        end else if (cq_pop) begin
            sw_we = 1'b1; sw_idx = idx_of(cq[cq_rp[1:0]][23:8]); sw_data = cq[cq_rp[1:0]][7:0];
        end
    end

    always_ff @(posedge clk) begin
        if (sw_we && !sw_idx[13]) snap_wr[sw_idx[12:0]] <= sw_data;
        if (sw_we &&  sw_idx[13]) snap_tm[TW'(sw_idx)]  <= sw_data;
        rd_v <= issue;
        if (issue) begin
            rd_idx <= h_idx;
            rd_tm  <= h_idx[13];
            h_idx  <= h_idx + 14'd1;
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
            h_idx <= 14'd0;
            cq_wp <= 3'd0;
            cq_rp <= 3'd0;
        end
        // end: everything read and written, the queue empty, no event in this clock
        if (harv && h_idx == 14'(HN) && !rd_v && cq_empty && !ev && !issue) begin
            harv       <= 1'b0;
            snap_frame <= snap_frame + 16'd1;
        end
    end
    initial snap_frame = 16'd0;
    assign snap_harv = harv;

    // ---------------- delivery ----------------
    // flat address dl_ptr: the work RAM, the window, zeros elsewhere
    logic [1:0]  run_n = 2'd0;              // snap_run cycles so far, saturating at 3
    logic        dl = 1'b0;
    logic [14:0] dl_ptr;
    logic        q_v = 1'b0;
    logic [7:0]  q_wr, q_tm;
    logic [1:0]  q_sel;                     // 0 work RAM, 1 window, 2 zero
    wire  [7:0]  q = q_sel == 2'd0 ? q_wr : q_sel == 2'd1 ? q_tm : 8'd0;
    wire         take = dl && q_v && !snap_full;       // the byte in q is pushed now
    wire         rd   = dl && dl_ptr != 15'(N) && (!q_v || take);
    wire         in_tm = dl_ptr >= 15'(TM_FLAT) && dl_ptr < 15'(TM_FLAT + TM_LEN);
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
                    q_wr   <= snap_wr[dl_ptr[12:0]];
                    q_tm   <= snap_tm[TW'(dl_ptr - 15'(TM_FLAT))];
                    q_sel  <= dl_ptr < 15'd8192 ? 2'd0 : in_tm ? 2'd1 : 2'd2;
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
