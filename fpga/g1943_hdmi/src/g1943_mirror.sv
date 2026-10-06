// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file g1943_mirror.sv
//! @brief The RAM mirror of 1943: g1942_mirror.sv with the memories laid out
//! for 1943's flat space of 8832 bytes. Only 0x0000-0x0FFF (main RAM E000-EFFF) and
//! 0x2000-0x227F (F000-F27F) are kept, 4096 + 640 bytes in two memories each for the live
//! shadow and the snapshot; 0x1000-0x1FFF (sound and video RAM in FBNeo's order, read by no
//! condition of set 11961) is delivered as zeros. Three blocks per memory instead of five.
//! Below the description of the original, which holds otherwise.
//!
//! RetroAchievements reads FBNeo's "All Ram" block of 1942 (d_1942.cpp MemIndex), 9344 bytes
//! at these flat addresses:
//!   0x0000 main RAM 4 KiB (E000-EFFF)       0x1880 character RAM 2 KiB (D000-D7FF)
//!   0x1000 sound RAM 2 KiB (sound CPU 4000)  0x2080 background RAM 1 KiB (D800-DBFF)
//!   0x1800 sprite RAM 128 B (CC00-CC7F)
//! jt1942 keeps these in five RAMs whose ports are all in use, the character RAM 16 bits
//! wide. Instead of opening them, this module keeps its own copy: every CPU write into one of
//! them comes in as an event with its flat address (game_core decodes the CPU buses) and
//! goes into the live shadow, which therefore always equals what the two CPUs wrote. Its
//! power-on content is zero like the core's RAMs, a core reset keeps both.
//!
//! One difference to the board, kept on purpose: jt1942 takes a sprite RAM write only in
//! the vertical blank, like the board; FBNeo's map writes it always, and this mirror does as
//! FBNeo does. No condition of set 11960 reads the sprite RAM.
//!
//! Once per frame, at frame_go (the start of the vertical blank), the harvest copies the live
//! shadow into the snapshot, one byte per clock: 9344 clocks, 252 us at 37.125 MHz. Every
//! event during that window is logged (log_we, the platform's oracle, snap_log.sv) and caught
//! up into the snapshot, so the snapshot is the state at the end of the window, which is
//! what the Pico checks against the log: the last logged value per address.
//!   - A read of the live shadow is never issued in the clock an event writes it, so no
//!     read sees a half-written byte.
//!   - The catch-up queue writes the snapshot only in clocks without a harvest write and
//!     keeps the order of the events, so for each address the last event wins. An address
//!     not yet harvested gets the event's value twice, which agrees.
//!   - The window ends only when the queue is empty.
//! Bound: two Z80 at 3 MHz write at most once in 7 T states each (LD (HL),A), about 140
//! writes each in 252 us, so about 280 log entries against the platform's 512.
//!
//! Delivery, against the platform contract of game20k_top.sv: snap_run rises at the verdict
//! byte, the top resets its FIFO at the end of the second snap_run cycle with priority over
//! a push, a push counts only with snap_full = 0 in the same clock, everything is dropped
//! when snap_run falls. Here the first read comes in the third snap_run cycle, the first push
//! in the fourth, one byte per clock while the FIFO has room. No harvest starts while
//! snap_run is high, and no delivery starts while a harvest runs.
module g1943_mirror #(
    parameter int N = 8832                  //!< bytes of the mirror, MIRROR_DATA
)(
    input  wire         clk,
    input  wire         reset,              //!< blocks harvest starts
    input  wire         frame_go,           //!< one clock per frame, start of the vertical blank
    //! ---- CPU write events, one clock each, flat address, both CPUs may come together ----
    input  wire         m_ev,               //!< main CPU
    input  wire  [13:0] m_flat,
    input  wire  [7:0]  m_data,
    input  wire         s_ev,               //!< sound CPU
    input  wire  [13:0] s_flat,
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
    // ---------------- events: serialised, one per clock ----------------
    // The sound event waits one clock when both come together; each CPU writes at most once
    // in several clocks, so one held slot is enough.
    logic        sh_v = 1'b0;               // a sound event held back
    logic [13:0] sh_flat;
    logic [7:0]  sh_data;
    logic        ev;                        // the event of this clock
    logic [13:0] ev_flat;
    logic [7:0]  ev_data;
    always_comb begin
        ev = 1'b0; ev_flat = m_flat; ev_data = m_data;
        if (m_ev)      begin ev = 1'b1; ev_flat = m_flat;  ev_data = m_data;  end
        else if (sh_v) begin ev = 1'b1; ev_flat = sh_flat; ev_data = sh_data; end
        else if (s_ev) begin ev = 1'b1; ev_flat = s_flat;  ev_data = s_data;  end
    end
    always_ff @(posedge clk) begin
        // a sound event that did not get this clock is held for the next
        if (s_ev && (m_ev || sh_v)) begin sh_v <= 1'b1; sh_flat <= s_flat; sh_data <= s_data; end
        else if (sh_v && !m_ev)     sh_v <= 1'b0;
    end
    assign log_we   = ev;
    assign log_addr = {2'b00, ev_flat};
    assign log_data = ev_data;

    // ---------------- the live shadow ----------------
    // Both memories are split at 0x2000 into 8192 + (N - 8192) bytes: as one array of 9344
    // bytes Gowin builds 16384, 8 blocks instead of 5 (measured: BSRAM 46 of 46).
    localparam int NH = N - 8192;
    // 1943: lo holds 0x0000-0x0FFF, hi 0x2000-0x227F; 0x1000-0x1FFF is not kept (zero)
    logic [7:0]  live_lo [0:4095];
    logic [7:0]  live_hi [0:NH-1];
    logic [13:0] lr_addr;
    logic [7:0]  lr_lo, lr_hi;
    logic        lr_sel, lr_zero;
    always_ff @(posedge clk) begin
        if (ev && ev_flat[13:12] == 2'b00) live_lo[ev_flat[11:0]] <= ev_data;
        if (ev && ev_flat[13])             live_hi[ev_flat[9:0]]  <= ev_data;
        lr_lo   <= live_lo[lr_addr[11:0]];
        lr_hi   <= live_hi[lr_addr[9:0]];
        lr_sel  <= lr_addr[13];
        lr_zero <= lr_addr[13:12] == 2'b01;
    end
    wire [7:0] lr_q = lr_zero ? 8'h00 : lr_sel ? lr_hi : lr_lo;

    // ---------------- harvest window ----------------
    logic        harv = 1'b0;               // the window
    logic [13:0] h_idx;                     // next byte to read
    logic        rd_v = 1'b0;               // a read was issued last clock
    logic [13:0] rd_idx;
    // catch-up queue, 4 entries: events inside the window, in order
    logic [21:0] cq [0:3];
    logic [2:0]  cq_wp = 3'd0, cq_rp = 3'd0;
    wire         cq_empty = (cq_wp == cq_rp);
    logic        run_d = 1'b0;
    always_ff @(posedge clk) run_d <= snap_run;

    wire issue = harv && h_idx != 14'(N) && cq_empty && !ev;
    assign lr_addr = h_idx;

    // snapshot write port: the harvest write of last clock's read, else one catch-up
    logic [7:0]  snap_lo [0:4095];
    logic [7:0]  snap_hi [0:NH-1];
    logic        sw_we;
    logic [13:0] sw_addr;
    logic [7:0]  sw_data;
    wire         cq_pop = harv && !rd_v && !cq_empty;
    always_comb begin
        sw_we = 1'b0; sw_addr = rd_idx; sw_data = lr_q;
        if (rd_v) begin
            sw_we = 1'b1;
        end else if (cq_pop) begin
            sw_we = 1'b1; sw_addr = cq[cq_rp[1:0]][21:8]; sw_data = cq[cq_rp[1:0]][7:0];
        end
    end

    always_ff @(posedge clk) begin
        if (sw_we && sw_addr[13:12] == 2'b00) snap_lo[sw_addr[11:0]] <= sw_data;
        if (sw_we && sw_addr[13])             snap_hi[sw_addr[9:0]]  <= sw_data;
        rd_v <= issue;
        if (issue) begin
            rd_idx <= h_idx;
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
        if (harv && h_idx == 14'(N) && !rd_v && cq_empty && !ev && !issue) begin
            harv       <= 1'b0;
            snap_frame <= snap_frame + 16'd1;
        end
    end
    initial snap_frame = 16'd0;
    assign snap_harv = harv;

    // ---------------- delivery ----------------
    logic [1:0]  run_n = 2'd0;              // snap_run cycles so far, saturating at 3
    logic        dl = 1'b0;
    logic [13:0] dl_ptr;
    logic        q_v = 1'b0;
    logic [7:0]  q_lo, q_hi;
    logic        q_sel, q_zero;
    wire  [7:0]  q = q_zero ? 8'h00 : q_sel ? q_hi : q_lo;
    wire         take = dl && q_v && !snap_full;       // the byte in q is pushed now
    wire         rd   = dl && dl_ptr != 14'(N) && (!q_v || take);
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
                dl_ptr <= 14'd0;
                q_v    <= 1'b0;
            end else if (dl) begin
                if (rd) begin
                    q_lo   <= snap_lo[dl_ptr[11:0]];
                    q_hi   <= snap_hi[dl_ptr[9:0]];
                    q_sel  <= dl_ptr[13];
                    q_zero <= dl_ptr[13:12] == 2'b01;
                    dl_ptr <= dl_ptr + 14'd1;
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
