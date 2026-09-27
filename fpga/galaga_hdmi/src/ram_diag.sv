// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent 1-bit net.
//! @file ram_diag.sv
//! @brief Result bar for the RAM mirror and rcheevos (game20k), RAMDIAG=1 only
//!
//! Only in the diagnostic build RAMDIAG=1, see build.tcl. It is the permanent result bar
//! of the RAM mirror: it only measures and builds nothing of the mirror itself.
//!
//! This module changes nothing in the game. It only counts what the three Z80s write into
//! the four working RAMs and thereby answers four questions that cannot be settled at the
//! desk and on which the whole design of the RAM mirror depends:
//!
//!   1. How many write accesses are there per frame at all?
//!      At the desk the rate can only be ESTIMATED, here it is measured.
//!   2. How many of them fall into the harvest window (the first 662 us of the blanking
//!      interval)? That number decides whether the simple copy shadow suffices or whether
//!      logging the writes and freezing becomes necessary.
//!   3. Does Galaga ever write into the mirror windows 0x8C00 / 0x9400 / 0x9C00, i.e. with
//!      address bit 10 set? Our core maps those back, FBNeo does not. If so, our memory
//!      differs at places that achievements read.
//!   4. Does the core run reproducibly frame by frame from reset? Without that, every later
//!      comparison "the core runs unchanged" is a mere claim. For this a checksum runs over
//!      EVERY write access (address, data, target) and is frozen after 600 frames: two
//!      runs from reset must show the same value.
//!
//! No block RAM, only counters. The display is the same construction as in fb_check.sv.
//!
//! Display, four rows of 16 fields, most significant bit on the left:
//!   Row 0  left the conditions loaded by rcheevos (expected 17), right the number of
//!          fired achievements. The Pico reports both over the back channel.
//!   Row 1  highest rcheevos evaluation time per frame in microseconds, sticky.
//!          A frame lasts 16400 us, anything clearly below that is uncritical.
//!   Row 2  left the peak fill level of the catch-up queue (bounded at 6), right the number of the last fired achievement, 1-based. A bare
//!          count only says THAT something fired, which one it is decides whether the
//!          address mapping is right.
//!   Row 3  left the FIRST deviating verdict code of the Pico, right how often it came.
//!   below that six yes/no fields, see the status register further down.
//!
//! -----------------------------------------------------------------------------------------

module ram_diag #(
    parameter int FREEZE_FRAMES = 600,   //!< the checksum is frozen after this many frames
    parameter int HARV_FIRST    = 240,   //!< harvest window: vcnt 240 to 250, that is the
    parameter int HARV_LAST     = 250    //!< first 662 us of the blanking interval
)(
    input  wire         clk_core,
    input  wire  [3:0]  ram_we,          //!< bgram, wram1, wram2, wram3
    input  wire  [10:0] ram_addr,
    input  wire  [7:0]  ram_data,
    input  wire  [8:0]  vcnt,
    //! SPI target 5, the RAM mirror: measured on the FPGA side.
    input  wire  [15:0] spi_count,      //!< bytes of the last transfer, expected RAM_MIRROR_BYTES
    input  wire  [15:0] spi_us,         //!< duration of the transfer in microseconds
    input  wire  [7:0]  spi_verdict,    //!< Pico's verdict, 0xA5 = all good
    //! Reported back by the Pico after each frame.
    input  wire  [15:0] rc_calc_us,           //!< rcheevos evaluation time per frame, microseconds
    input  wire  [15:0] catchup_peak_and_ach, //!< {catch-up queue peak fill, last achievement no}
    input  wire  [15:0] rc_loaded_and_fired,  //!< {loaded conditions, fired achievements}
    input  wire         clk_pixel,
    input  wire  [10:0] cx,
    input  wire  [9:0]  cy,
    output logic        bar_on,
    output logic [23:0] bar_color,
    output logic [5:0]  leds
);
    import ram_mirror_pkg::*;   // block sizes of the RAM mirror, see ram_mirror_pkg.sv
    // ---------------- Counters in the core clock ----------------
    logic [8:0]  vcnt_d = 0;
    wire         frame_edge = (vcnt_d == 9'd239) && (vcnt == 9'd240);
    wire         any_we     = |ram_we;
    wire         in_harv    = (vcnt >= HARV_FIRST[8:0]) && (vcnt <= HARV_LAST[8:0]);

    logic [15:0] cnt_all = 0, cnt_harv = 0;
    logic [15:0] last_all = 0, last_harv = 0;
    logic [15:0] max_all = 0;            // highest count per frame, sticky

    // Replica of the harvest and the queue, without building anything:
    // One round is 6 core clocks. The harvest runs over 2048 rounds from vcnt 239->240.
    // During that time every write into the three wram enters the queue (bgram needs
    // none, it has its own block), and exactly one drains per round.
    logic [2:0]  ring = 0;               // core clock within the round
    wire         round_tick = (ring == 3'd5);
    logic [11:0] harv_round = 0;         // 0..2047 during the harvest
    logic        harv_run = 0;
    logic [7:0]  backlog = 0;
    logic [15:0] max_backlog = 0;        // sticky, this is the number we are after

    // Where within the harvest do the writes land? 16 buckets of 128 rounds each.
    logic [7:0]  hist [0:15];
    logic [7:0]  hist_l [0:15];
    wire  [3:0]  bucket = harv_round[10:7];
    integer i;
    logic [15:0] cnt_mirror = 0;         // cumulative, saturating

    // Sticky values for the long-run measurement. A momentary value is no good for
    // that: a single bad frame in ten minutes slips through between two glances.
    // "armed" is set only with the first valid verdict, otherwise the zero after power-up
    // trips at once.
    logic        armed = 0, verdict_bad = 0;
    logic [15:0] bad_max = 0, logn_max = 0;
    // A flag only says THAT. For the cause we need the code itself and the number of
    // cases: transitions are counted, not clocks, because the verdict stands still between
    // two transfers.
    logic [7:0]  bad_verdict = 0, bad_cnt = 0, verd_d = 8'hA5;
    logic [31:0] sig = 32'h1234_5678;
    logic [15:0] frames = 0;
    logic        frozen = 0;

    always_ff @(posedge clk_core) begin
        vcnt_d <= vcnt;

        if (spi_verdict == 8'hA5)                   armed       <= 1'b1;
        verd_d <= spi_verdict;
        if (armed && spi_verdict != verd_d && spi_verdict != 8'hA5) begin
            // 0xE8 is NOT a failure: it only reports that the look-ahead FIFO signalled
            // underrun while the checksum was right. So the content was correct. It is
            // counted anyway, row 3 shows it, but it does not turn the yes/no field red,
            // otherwise after an hour one could not tell any more whether a snapshot was
            // ever really discarded.
            if (spi_verdict != 8'hE8) verdict_bad <= 1'b1;
            if (bad_verdict == 8'd0)   bad_verdict <= spi_verdict;
            if (bad_cnt     != 8'hFF)  bad_cnt     <= bad_cnt + 8'd1;
        end
        if (rc_calc_us > bad_max)                      bad_max     <= rc_calc_us;
        if (rc_loaded_and_fired > logn_max)            logn_max    <= rc_loaded_and_fired;

        if (any_we) begin
            if (cnt_all  != 16'hFFFF) cnt_all  <= cnt_all + 16'd1;
            if (in_harv && cnt_harv != 16'hFFFF) cnt_harv <= cnt_harv + 16'd1;
            // Address bit 10 set means 0x8C00, 0x9400 or 0x9C00: windows that FBNeo does
            // not map. For bgram (2 kB), by contrast, bit 10 is regular.
            if (ram_addr[10] && |ram_we[2:0] && cnt_mirror != 16'hFFFF)
                cnt_mirror <= cnt_mirror + 16'd1;

            // Checksum over every single access. Rotates before adding so that the order
            // matters: two runs with the same accesses in a different order must
            // differ.
            if (!frozen)
                sig <= {sig[30:0], sig[31]} + {1'b0, ram_we, ram_addr, ram_data};
        end

        // ---- Replica: round, harvest window, queue ----
        ring <= round_tick ? 3'd0 : ring + 3'd1;
        if (frame_edge) begin
            harv_run   <= 1'b1;
            harv_round <= 12'd0;
        end else if (harv_run && round_tick) begin
            if (harv_round == 12'd2047) harv_run <= 1'b0;
            else                        harv_round <= harv_round + 12'd1;
        end

        if (harv_run) begin
            // Arrival: every write into the three wram, unconditionally (no comparator).
            // bgram bypasses the queue.
            // Drain: exactly one per round. Both can coincide in the same clock.
            automatic logic [7:0] nb = backlog;
            if (|ram_we[2:0]) nb = nb + 8'd1;
            if (round_tick && nb != 8'd0) nb = nb - 8'd1;
            backlog <= nb;
            if ({8'd0, nb} > max_backlog) max_backlog <= {8'd0, nb};
            if (any_we && hist[bucket] != 8'hFF) hist[bucket] <= hist[bucket] + 8'd1;
        end

        if (frame_edge) begin
            if (cnt_all > max_all) max_all <= cnt_all;
            backlog <= 8'd0;
            for (i = 0; i < 16; i = i + 1) begin
                hist_l[i] <= hist[i];
                hist[i]   <= 8'd0;
            end
            last_all  <= cnt_all;
            last_harv <= cnt_harv;
            cnt_all   <= 16'd0;
            cnt_harv  <= 16'd0;
            if (frames != 16'hFFFF) frames <= frames + 16'd1;
            if (frames == FREEZE_FRAMES[15:0]) frozen <= 1'b1;
        end
    end

    // ---------------- Display, three stages as in fb_check.sv ----------------
    logic [15:0] v0_a = 0, v0 = 0, v1_a = 0, v1 = 0, v2_a = 0, v2 = 0, v3_a = 0, v3 = 0;
    logic [7:0]  h_a [0:15];
    logic [7:0]  h_p [0:15];
    logic [5:0]  st_a = 0, st_b = 0;
    always_ff @(posedge clk_pixel) begin
        // Rows 0 to 3, what they mean is documented once, in the file header.
        v0_a <= rc_loaded_and_fired;            // row 0
        v1_a <= bad_max;                        // row 1
        v2_a <= catchup_peak_and_ach;           // row 2
        v3_a <= {bad_verdict, bad_cnt};         // row 3
        for (int k = 0; k < 16; k = k + 1) h_a[k] <= hist_l[k];
        // Six yes/no fields instead of reading bits off a photo:
        //  0 frames running   1 byte count right (6672)   2 duration under 15 ms
        //  3 never a bad verdict   4 mirror windows clean   5 all 17 loaded
        st_a <= {|frames,
                 // Measured on the device: exactly 6672. mcu_start marks the first payload
                 // byte after the target id, the counter is zeroed there, and the 6672
                 // bytes of the block count it up. Any deviation is a lost byte.
                 (spi_count == RAM_MIRROR_BYTES),
                 // Measured about 6200 to 7100 us, not the computed 2055: the Pico is
                 // interrupted during the block (USB polling, interrupts), the line then
                 // stands still. Effectively 0.83 MB/s instead of 2.5. On top of that the
                 // snapshot shares the line with the stick data, and under key presses
                 // the transfer grazes 10 ms. So a bound of 10 ms is too tight, the bound
                 // is 15 ms. The hard limit is the frame at 16.4 ms, the bound stays
                 // under that.
                 (spi_us != 16'd0 && spi_us < 16'd15000),
                 // The Pico's verdict alone. The underrun flag of ram_spi does not belong
                 // next to it: redundant (0xA5 already includes the underrun) AND wrong,
                 // the sticky bit is only cleared at the start of the NEXT transfer, and
                 // on an aborted header probe it still twitches up briefly at the byte
                 // end. The field would then blink although nothing is broken.
                 (armed && !verdict_bad),
                 (cnt_mirror == 16'd0),
                 // Has rcheevos loaded all 17 conditions of the Galaga set?
                 // The oracle has no field of its own: it keeps running along but only
                 // reports through verdict 0xE9, and field 4 catches that.
                 (rc_loaded_and_fired[15:8] == 8'd17)};
        if (cy == 10'd0) begin
            v0 <= v0_a; v1 <= v1_a; v2 <= v2_a; v3 <= v3_a; st_b <= st_a;
            for (int k = 0; k < 16; k = k + 1) h_p[k] <= h_a[k];
        end
    end

    logic [10:0] q_xb = 0;
    logic        q_inx = 0, q_bgx = 0, q_rbg = 0, q_rsta = 0;
    logic [2:0]  q_row = 3'd4;
    always_ff @(posedge clk_pixel) begin
        q_xb   <= cx - 11'd128;
        q_inx  <= (cx >= 11'd128) && (cx < 11'd1152);
        q_bgx  <= (cx >= 11'd112) && (cx < 11'd1168);
        q_rbg  <= (cy >= 10'd240) && (cy < 10'd470);
        q_rsta <= (cy >= 10'd430) && (cy < 10'd462);
        q_row  <= (cy >= 10'd250 && cy < 10'd286) ? 3'd0 :
                  (cy >= 10'd294 && cy < 10'd330) ? 3'd1 :
                  (cy >= 10'd338 && cy < 10'd374) ? 3'd2 :
                  (cy >= 10'd382 && cy < 10'd418) ? 3'd3 : 3'd4;
    end

    logic [3:0] fi;
    logic [5:0] xin;
    assign fi  = q_xb[9:6];
    assign xin = q_xb[5:0];

    logic       r_bg = 0, r_fld = 0, r_bit = 0, r_sta = 0, r_stv = 0;
    logic [1:0] r_which = 0;
    logic [7:0] r_hist = 0;
    always_ff @(posedge clk_pixel) begin
        r_bg    <= q_bgx & q_rbg;
        r_fld   <= q_inx & (q_row != 3'd4) & (xin < 6'd56);
        r_which <= q_row[1:0];
        case (q_row[1:0])
            2'd0: r_bit <= v0[4'd15 - fi];
            2'd1: r_bit <= v1[4'd15 - fi];
            2'd2: r_bit <= v2[4'd15 - fi];
            default: r_bit <= v3[4'd15 - fi];
        endcase
        // Bucket i sits at field i, so left to right is vcnt 0 to 263
        r_hist <= h_p[fi];
        r_sta <= q_inx & q_rsta & (xin < 6'd56) & (fi < 4'd6);
        r_stv <= st_b[5 - fi[2:0]];
    end

    logic [23:0] colf;
    always_comb begin
        // Row 2 is the catch-up backlog: a set bit is red so that a value above 7 stands out
        // at once.
        if (r_which == 2'd2 && r_bit) colf = 24'hC00000;
        else if (r_bit)                    colf = 24'hFFFFFF;
        else                               colf = 24'h303030;
    end

    always_ff @(posedge clk_pixel) begin
        bar_on <= r_bg | r_fld | r_sta;
        if      (r_sta) bar_color <= r_stv ? 24'h00B000 : 24'h505050;
        else if (r_fld) bar_color <= colf;
        else            bar_color <= 24'h000000;
    end

    // LED6 heartbeat from the frame counter, LED5 checksum frozen,
    // LED4 mirror windows clean, LED3..LED1 without meaning
    assign leds = {frames[3], frozen, (cnt_mirror == 16'd0), 3'd0};

endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
