// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! @file sdram_selftest.sv
//! @brief Self-test for sdram_fb (game20k): PSDA and capture-cycle sweep
//!
//! Purpose: the phase of the clock on O_sdram_clk is the
//! only real hardware risk. We are not looking for one good PSDA value but for a window of at
//! least four steps.
//!
//! The self-test sweeps TWO quantities: the phase PSDA 0..15 and the capture cycle of the read
//! data cap_ofs 0..3. For each of the 64 combinations it remembers the worst result it ever
//! had and shows that as four rows of 16 fields each.
//!
//! Why the capture cycle is swept too: measured on the device, a sweep with only the computed
//! capture cycle gives exactly ONE error-free phase step at CL2 (PSDA 15, the step at the
//! cycle boundary) and none at all at CL3. That is exactly what a capture cycle off by one
//! looks like: it always reads the wrong cycle, unless the phase happens to shift the arrival
//! by exactly that one cycle. A marginal phase would look different, namely yellow at the
//! edges.
//!
//! No block RAM, no stored reference pattern.
//!
//! Test pattern
//! ------------
//! Base pattern: an affine map of the word number over GF(2) (an LFSR jump in one go):
//!   h0 = {a[5:0], a[18:0], ~a[6:0]}      address interleaved three times, pure wiring
//!   h1 = h0 ^ (h0 << 12)
//!   h  = h1 ^ (h1 >> 13) ^ 32'h5A5AA5A5
//! Each result bit depends on at most four address bits: one LUT4 per bit.
//! Verified over all 2^19 words: rank 19 over GF(2), hence injective; each bit is set 50.0
//! percent of the time; no bit pair always equal or always inverse; no word is 0 or
//! FFFFFFFF; on average 8.89 of the 32 bits change from word to word, at least 7.
//!
//! These 8.89 are NOT a seal of quality but the reason for the second term: the real picture
//! data switches much harder (black background = 0x00000000, at sprite edges everything flips
//! at once). Therefore a seed is added that does three jobs at once:
//!
//!   seed = {t, ~t, t, ~t} ^ {32{bank}} ^ (odd ? 32'hFFFF0000 : 0),  t = {psda, stage, 2'b10}
//!
//!   {32{bank}} : bank 0 and bank 1 hold mutually INVERSE data at the same location. A
//!                swapped, stuck or ignored bank thus shows up in all 32 bits. Without this
//!                the test cannot see bank errors at all.
//!   t          : one mark per pass. The reader in half s expects the mark {psda, s-1}, i.e.
//!                exactly the one this bank was written with in the previous half. If a write
//!                does not happen, the cell still carries the mark of the pass before that:
//!                4 of 32 bits wrong, reliably detected. Without this a write that never
//!                arrived is invisible, because every cell would hold the same value forever.
//!   odd        : flips the upper 16 bits from word to word. Verified: this raises the number
//!                of edges per word change from 8.89 to 16.79 (min 5, max 28).
//!
//! Read skew
//! ---------
//! The reader works at a DIFFERENT location of the bank than the writer:
//!   ridx = r_cnt ^ RSKEW,  RSKEW = 0x2AAAA (masked to 2^WORDS_LOG2)
//! XOR instead of addition: bijective, costs no gate, shifts row (bits 10:0) and column
//! (bits 18:11) at the same time. Side effect: the two BankActivates of one round carry
//! different row addresses, as in the later video operation.
//!
//! Why all of this together is necessary (the real reason)
//! -------------------------------------------------------
//! The write cycle sits in ring cycle 4, the capture of the read data at the end of ring
//! cycle 5 (CL2). So between the FPGA driver turning off and the capture there is ONE cycle.
//! An undriven CMOS bus holds its charge orders of magnitude longer. If the SDRAM delivers no
//! data at all - wrong phase, failed initialisation, miswired rd_valid -, the test reads back
//! its own write value. With a pattern that depends only on the word number that would be
//! GREEN, and precisely at the broken phase steps. Because pat32 is affine and the read skew
//! constant, the distance between the last driven write value and the read value expected at
//! the same time can be computed in closed form. Exhaustively checked over all 2^19 words,
//! all 16 PSDA steps and all halves:
//!     skew 0 words : at least 20 of 32 bits differ  (this is the real case)
//!     skew 1 word  : at least 12
//!     skew 2 words : at least  9
//! The real case is skew 0: when word k is compared, the last value driven on DQ is exactly
//! the write value of word k. A floating bus thus shows up in EVERY word with at least 20
//! wrong bits.
//!
//! Sequence per PSDA step
//! ----------------------
//!   stage 0: fill bank 0, only the writer runs
//!   stage 1: write bank 1, meanwhile read and compare bank 0
//!   stage 2: write bank 0, meanwhile read and compare bank 1
//!   HOLD   : 2^23 cycles = 129.4 ms doing nothing, only the AutoRefresh of sdram_fb runs.
//!            This is the ONLY place where data retention is checked at all: otherwise the
//!            test keeps the memory awake itself, because the row is the fast dimension and
//!            it activates each of the 2048 rows every 190 us. 129 ms is twice the required
//!            64 ms.
//!   stage 3: write bank 1, meanwhile read bank 0 (contents from stage 2, 129 ms old)
//!
//! Size of the tested area: 2^19 = 524288 words per bank, i.e. 2 MB per bank, 4 MB of 8 MB.
//!   - word number -> address such that the SDRAM row is the fast dimension:
//!     row = cnt[10:0], column = cnt[18:11]. So the row changes on EVERY access, all 2048
//!     rows occur 256 times each and A[10:0] toggles maximally. That is harder than the
//!     later video operation, which uses only 112 rows.
//!   - time: one access per 6 cycles = 92.59 ns. One half takes 524288 x 92.59 ns =
//!     48.5 ms, about 49.7 ms with the refresh pause. Four halves plus 129 ms rest are
//!     about 328 ms per step, one full sweep over 16 steps about 5.3 s. In ten minutes
//!     that is about 113 sweeps per step.
//!   - BA[1] is not tested: the test uses only bank 0 and 1. That is acceptable because the
//!     frame buffer ties BA[1] to 0. Whoever wants it anyway makes stage 3 bits
//!     wide and puts stage 4..7 on bank 2/3 - that doubles the measurement time.
//!
//! CAS: CL2 and CL3 are NOT switchable at run time, that takes two bitstreams. CL sits in
//! the mode register of the SDRAM and in addition determines in which ring cycle sdram_fb
//! captures the data. Both could be muxed, but exactly this path is the one we want to
//! measure; a mux in front of it distorts the measurement. Hence: build and measure once
//! with CAS(3'd2), then build with CAS(3'd3) and repeat the same measurement.
//! -----------------------------------------------------------------------------------------

module sdram_selftest #(
    parameter int          WORDS_LOG2 = 19,       //!< 2^19 words per bank (>= 11, <= 19)
    //! Settling time after a phase change. 2 million cycles are 31 ms - deliberately a lot.
    //! With 4096 cycles (63 us) the sweep measurement on the device is unusable: the PLL does
    //! not take over a changed phase that fast, so every result still belongs to the
    //! previous step. A full sweep thus takes 23 s instead of 21 s.
    parameter logic [21:0] SETTLE     = 22'd2_000_000,
    parameter logic [21:0] WARMUP     = 22'd4096   //!< cycles after sdram_ready: 8 AutoRefresh
) (
    //! ---- SDRAM domain, 64.8 MHz ----
    input  wire         clk,
    input  wire         pll_lock,
    input  wire         clear,           //!< button S1 raw (pressed = 1), clears the table
    output logic        ctrl_resetn,     //!< reset of sdram_fb
    input  wire         sdram_ready,

    output logic [21:0] wr_addr,
    output logic [31:0] wr_din,
    output logic [1:0]  wr_bank,
    output logic        wr_req,
    input  wire         wr_ack,

    output logic [21:0] rd_addr,
    output logic [1:0]  rd_bank,
    output logic        rd_req,
    input  wire         rd_ack,
    input  wire  [31:0] rd_dout,
    input  wire         rd_valid,

    output logic [3:0]  psda,            //!< to pll_sdram
    output logic [1:0]  cap_ofs,         //!< capture cycle of the read data, to sdram_fb

    //! ---- display, pixel domain ----
    input  wire         clk_pixel,
    input  wire  [10:0] cx,
    input  wire  [9:0]  cy,
    output logic        bar_on,
    output logic [23:0] bar_color,

    output logic [5:0]  leds             //!< active high, the top inverts
);

    localparam int          WL     = WORDS_LOG2;
    localparam logic [19:0] NWORDS = 20'd1 << WL;
    // Skew of the reader, clipped to the tested area (otherwise a smaller WORDS_LOG2 would
    // let the reader run outside the written area)
    localparam logic [19:0] WMASK  = NWORDS - 20'd1;
    localparam logic [18:0] RSKEW  = 19'h2AAAA & WMASK[18:0];

    // ---------------- test pattern and address mapping ----------------
    function automatic logic [31:0] pat32(input logic [18:0] a);
        logic [31:0] h0, h1;
        begin
            h0    = {a[5:0], a[18:0], ~a[6:0]};
            h1    = h0 ^ (h0 << 12);
            pat32 = (h1 ^ (h1 >> 13)) ^ 32'h5A5A_A5A5;
        end
    endfunction

    function automatic logic [31:0] seed32(input logic [3:0] ps,
                                           input logic [1:0] sg,
                                           input logic [1:0] cf,
                                           input logic       bnk,
                                           input logic       odd);
        logic [7:0] t;
        begin
            // cf is constant within one sweep, across sweeps it makes the data differ
            // from the data of the sweep before.
            t      = {ps, sg, cf};
            seed32 = ({t, ~t, t, ~t} ^ {32{bnk}})
                     ^ (odd ? 32'hFFFF_0000 : 32'h0000_0000);
        end
    endfunction

    // Word number -> byte address. The row is the fast dimension, see header.
    function automatic logic [21:0] wadr(input logic [18:0] c);
        wadr = {1'b0, c[10:0], c[18:11], 2'b00};
    endfunction

    // ---------------- states ----------------
    localparam logic [2:0] ST_SETTLE = 3'd0,   // phase changed, controller in reset
                           ST_INIT   = 3'd1,   // reset released, wait for sdram_ready, warm up
                           ST_RUN    = 3'd2,   // one of the four halves runs
                           ST_HOLD   = 3'd3,   // 129 ms rest, only AutoRefresh
                           ST_NEXT   = 3'd4;   // record result, advance PSDA

    integer      i;
    logic [2:0]  st;
    logic [1:0]  stage;
    logic [21:0] settle_cnt;
    logic [22:0] hold_cnt;
    logic [19:0] w_cnt;        // writer: next word to write
    logic [19:0] r_cnt;        // reader: next word to request
    logic [19:0] c_cnt;        // checker: next word to compare
    logic        w_busy, r_busy;
    logic [15:0] err_cnt;      // errors of this step, saturating
    logic [1:0]  sev [0:63];   // worst result ever seen, {cap_ofs, psda}
    logic [7:0]  sweeps;       // number of complete phase sweeps, saturating
    logic        cap_rst;      // after clearing, start again at offset 0
    logic [24:0] wd_cnt;       // watchdog, 2^25 cycles = 518 ms
    logic [21:0] hb;           // heartbeat, counts ONLY on progress
    logic        psda_step;    // phase is to be changed as soon as the reset is in place
    logic        psda_rst;     // after clearing, start again at step 0

    // Clear button, debounced enough in the SDRAM domain (bouncing only clears several times)
    logic [1:0] clr_s = 2'd0;
    logic       clr_d = 1'b0;
    always_ff @(posedge clk) begin
        clr_s <= {clr_s[0], clear};
        clr_d <= clr_s[1];
    end
    wire clr_pulse = clr_s[1] & ~clr_d;

    // Flat view of the result table (read in parallel, hence registers)
    logic [127:0] sev_flat;
    genvar gi;
    generate
        for (gi = 0; gi < 64; gi = gi + 1) begin : g_sevflat
            assign sev_flat[2*gi +: 2] = sev[gi];
        end
    endgenerate

    // ---------------- requests and expected values ----------------
    wire [18:0] widx = w_cnt[18:0];
    wire [18:0] ridx = r_cnt[18:0] ^ RSKEW;
    wire [18:0] cidx = c_cnt[18:0] ^ RSKEW;

    assign wr_addr = wadr(widx);
    assign rd_addr = wadr(ridx);
    assign wr_bank = {1'b0,  stage[0]};            // 0,1,0,1
    assign rd_bank = {1'b0, ~stage[0]};            // the other bank in every check half
    assign wr_din  = pat32(widx) ^ seed32(psda, stage,           cap_ofs, wr_bank[0], widx[0]);
    wire [31:0] rd_exp = pat32(cidx)
                       ^ seed32(psda, stage - 2'd1, cap_ofs, rd_bank[0], cidx[0]);

    wire w_done    = (w_cnt == NWORDS);
    wire r_done    = (r_cnt == NWORDS);
    wire c_done    = (c_cnt == NWORDS);
    wire rd_stage  = |stage;                       // stage 0 only fills
    wire half_done = rd_stage ? (w_done && c_done) : w_done;
    wire w_got     = w_busy && (wr_req == wr_ack); // a write acknowledge has arrived
    wire r_got     = r_busy && (rd_req == rd_ack);

    assign ctrl_resetn = pll_lock && (st != ST_SETTLE);

    // ---------------- sequencer ----------------
    always_ff @(posedge clk) begin
        if (!pll_lock) begin
            st         <= ST_SETTLE;
            stage      <= 2'd0;
            settle_cnt <= SETTLE;
            hold_cnt   <= 23'd0;
            psda       <= 4'd0;
            cap_ofs    <= 2'd0;
            psda_step  <= 1'b0;
            psda_rst   <= 1'b0;
            cap_rst    <= 1'b0;
            w_cnt      <= 20'd0;
            r_cnt      <= 20'd0;
            c_cnt      <= 20'd0;
            w_busy     <= 1'b0;
            r_busy     <= 1'b0;
            wr_req     <= 1'b0;
            rd_req     <= 1'b0;
            err_cnt    <= 16'd0;
            wd_cnt     <= 25'd0;
            hb         <= 22'd0;
            sweeps     <= 8'd0;
            for (i = 0; i < 64; i = i + 1) sev[i] <= 2'd0;
        end else begin
            case (st)
            // The controller is in reset: cmd is NOP, CS# high, DQ high-impedance, address
            // and BA fixed. The reset is synchronous, so it takes effect one edge after the
            // change of st. Therefore the clock phase jumps only four cycles later; by then a
            // shortened pulse on O_sdram_clk is certainly a NOP.
            ST_SETTLE: begin
                w_cnt  <= 20'd0; r_cnt <= 20'd0; c_cnt <= 20'd0;
                w_busy <= 1'b0;  r_busy <= 1'b0;
                wr_req <= 1'b0;  rd_req <= 1'b0;
                stage  <= 2'd0;
                wd_cnt <= 25'd0;

                if (psda_step && (settle_cnt == SETTLE - 22'd4)) begin
                    psda      <= psda_rst ? 4'd0 : psda + 4'd1;
                    psda_rst  <= 1'b0;
                    psda_step <= 1'b0;
                    if (cap_rst) begin
                        cap_ofs <= 2'd0;
                        cap_rst <= 1'b0;
                    end else if (psda == 4'd15 && !psda_rst)
                        cap_ofs <= cap_ofs + 2'd1;   // after every full phase sweep
                end

                if (settle_cnt != 22'd0)
                    settle_cnt <= settle_cnt - 22'd1;
                else begin
                    st         <= ST_INIT;
                    settle_cnt <= WARMUP;
                end
            end

            // Reset is released. sdram_fb waits 200 us and then runs the full
            // initialisation: PrechargeAll, two AutoRefresh, mode register.
            // Then 4096 cycles = 63 us warm-up: the forced refresh chain delivers eight
            // AutoRefresh in that time. Devices of the Winbond/ESMT family require eight in
            // the power-up sequence, the template gives only two. Here we re-initialise 16
            // times per sweep; otherwise a weak start lands as an error count on the PSDA
            // step just set and looks like a phase error.
            ST_INIT: begin
                err_cnt <= 16'd0;
                if (sdram_ready) begin
                    wd_cnt <= 25'd0;
                    if (settle_cnt != 22'd0) settle_cnt <= settle_cnt - 22'd1;
                    else                     st         <= ST_RUN;
                end else begin
                    // A watchdog here too: if sdram_ready never comes, the step turns red and
                    // the sweep counter keeps running. Without it the display hangs and
                    // "hung" cannot be told from "not running yet".
                    wd_cnt <= wd_cnt + 25'd1;
                    if (wd_cnt == {25{1'b1}}) begin
                        err_cnt <= 16'hFFFF;
                        st      <= ST_NEXT;
                    end
                end
            end

            ST_RUN: begin
                // --- writer ---
                if (!w_busy && !w_done) begin
                    wr_req <= ~wr_req;            // address and data come from w_cnt
                    w_busy <= 1'b1;
                end else if (w_got) begin
                    w_busy <= 1'b0;
                    w_cnt  <= w_cnt + 20'd1;      // advance only after the acknowledge
                end

                // --- reader and checker, from stage 1 on ---
                if (rd_stage) begin
                    if (!r_busy && !r_done) begin
                        rd_req <= ~rd_req;
                        r_busy <= 1'b1;
                    end else if (r_got) begin
                        r_busy <= 1'b0;
                        r_cnt  <= r_cnt + 20'd1;
                    end
                    // The responses arrive in the order of the requests.
                    if (rd_valid) begin
                        if (rd_dout != rd_exp && err_cnt != 16'hFFFF)
                            err_cnt <= err_cnt + 16'd1;
                        c_cnt <= c_cnt + 20'd1;
                    end
                end

                // --- heartbeat: counts only when something really happens ---
                if (w_got || rd_valid) hb <= hb + 22'd1;

                // --- watchdog: if the controller hangs, the step counts as bad ---
                if (w_got || rd_valid) wd_cnt <= 25'd0;
                else                   wd_cnt <= wd_cnt + 25'd1;

                // --- half done ---
                // Guaranteed no request is still open here (half_done requires w_done and
                // c_done), so the seed cannot jump in the middle of an access.
                if (half_done) begin
                    w_cnt  <= 20'd0; r_cnt <= 20'd0; c_cnt <= 20'd0;
                    w_busy <= 1'b0;  r_busy <= 1'b0;
                    wd_cnt <= 25'd0;
                    if (stage == 2'd3) st <= ST_NEXT;
                    else begin
                        stage <= stage + 2'd1;
                        if (stage == 2'd2) begin  // before the last half: retention test
                            st       <= ST_HOLD;
                            hold_cnt <= {23{1'b1}};
                        end
                    end
                end

                if (wd_cnt == {25{1'b1}}) begin
                    err_cnt <= 16'hFFFF;
                    st      <= ST_NEXT;
                end
                // Should the controller drop out of initialisation, start over.
                if (!sdram_ready) begin
                    st         <= ST_SETTLE;
                    settle_cnt <= SETTLE;
                end
            end

            // 129.4 ms: both channels silent, only the AutoRefresh of sdram_fb runs.
            ST_HOLD: begin
                if (hold_cnt != 23'd0) hold_cnt <= hold_cnt - 23'd1;
                else                   st       <= ST_RUN;
                if (!sdram_ready) begin
                    st         <= ST_SETTLE;
                    settle_cnt <= SETTLE;
                end
            end

            ST_NEXT: begin
                // 1 = never an error, 2 = few, 3 = many. Only ever gets worse.
                if (err_cnt == 16'd0) begin
                    if (sev[{cap_ofs, psda}] < 2'd1) sev[{cap_ofs, psda}] <= 2'd1;
                end else if (err_cnt < 16'd16) begin
                    if (sev[{cap_ofs, psda}] < 2'd2) sev[{cap_ofs, psda}] <= 2'd2;
                end else begin
                    sev[{cap_ofs, psda}] <= 2'd3;
                end

                if (psda == 4'd15 && sweeps != 8'hFF) sweeps <= sweeps + 8'd1;

                psda_step  <= 1'b1;                // advance psda only in ST_SETTLE
                settle_cnt <= SETTLE;
                st         <= ST_SETTLE;
            end

            default: st <= ST_SETTLE;
            endcase

            // Clear on button press: table and counters back, then start again at phase 0
            // and offset 0. Sits after the case so that it wins.
            if (clr_pulse) begin
                for (i = 0; i < 64; i = i + 1) sev[i] <= 2'd0;
                sweeps     <= 8'd0;
                psda_rst   <= 1'b1;
                cap_rst    <= 1'b1;
                psda_step  <= 1'b1;
                settle_cnt <= SETTLE;
                st         <= ST_SETTLE;
            end
        end
    end

    // LEDs as fallback if no picture comes. The heartbeat comes from progress, not from a
    // free-running counter: if the test stalls, the LED stalls too.
    //   LED1..LED4 = running step in binary, LED5 = already an error in this step,
    //   LED6 = heartbeat about 2.5 Hz (stands still during the 129 ms rest)
    assign leds = {hb[21], |err_cnt, psda};

    // -------------------------------------------------------------------------------------
    // Display: FOUR rows of 16 fields each, one per capture cycle.
    // We look for the combination of phase and capture cycle in which a contiguous window
    // of at least four phase steps stands. A sweep with a fixed capture cycle, measured on
    // the device, shows why this is needed: with the wrong capture cycle everything is red
    // except the one phase step at which the data happens to fall into the expected cycle.
    //
    // Layout (720p raster, visible cx 0..1279, cy 0..719):
    //   cy 230..499, cx 112..1167  black backdrop (red-brown if the PLL ever lost lock)
    //   cy 236..243                tick marks above field 0, 4, 8, 12
    //   cy 248..283   row 0        capture cycle CAPT+0, one cycle earlier than computed
    //   cy 294..329   row 1        capture cycle CAPT+1, the computed one
    //   cy 340..375   row 2        capture cycle CAPT+2
    //   cy 386..421   row 3        capture cycle CAPT+3
    //   cy 430..441                white mark under the phase step currently running
    //   cy 450..461                progress: blue = measuring, violet = rest
    //   cy 470..481                sweep counter, 8 fields, bit 7 on the left
    // Raster of all rows: 16 fields, pitch 64, width 56, from cx 128.
    // Colours: dark grey = never tested yet, green = never an error,
    //          yellow = 1..15 errors in one sweep, red = 16 or more.
    //
    // Clock domain crossing clk -> clk_pixel: sev, psda, prog and sweeps are slow quantities.
    // clk_sdram is declared asynchronous to everything else in the SDC, so nothing is
    // checked. Double-synchronised; a torn crossing colours at most one field wrong for one
    // frame, and that goes unnoticed in a table that only ever gets worse.
    // -------------------------------------------------------------------------------------
    logic [9:0] prog;
    always_comb begin
        if (st == ST_HOLD) prog = {2'd3, ~hold_cnt[22:15]};
        else               prog = {stage, w_done ? 8'hFF : w_cnt[WL-1 -: 8]};
    end

    logic [127:0] sevw_s0 = 0, sevw_p = 0;
    logic [3:0]  psda_s0 = 0, psda_p = 0;
    logic [9:0]  prog_s0 = 0, prog_p = 0;
    logic [7:0]  swp_s0  = 0, swp_p  = 0;
    logic        hold_s0 = 0, hold_p = 0;
    logic [1:0]  lk_s = 0;
    logic        lock_seen = 0, lock_lost = 0;
    logic [1:0]  clrp_s = 0;
    logic        clrp_d = 0;

    always_ff @(posedge clk_pixel) begin
        sevw_s0 <= sev_flat;        sevw_p <= sevw_s0;
        psda_s0 <= psda;            psda_p <= psda_s0;
        prog_s0 <= prog;            prog_p <= prog_s0;
        swp_s0  <= sweeps;          swp_p  <= swp_s0;
        hold_s0 <= (st == ST_HOLD); hold_p <= hold_s0;

        // Survives the loss of pll_sdram_lock, which resets everything in the SDRAM domain.
        // Without this flag "the PLL loses lock on switching" cannot be told from "the test
        // does not start at all".
        lk_s   <= {lk_s[0], pll_lock};
        clrp_s <= {clrp_s[0], clear};
        clrp_d <= clrp_s[1];
        if (clrp_s[1] && !clrp_d) begin
            lock_seen <= 1'b0;
            lock_lost <= 1'b0;
        end else begin
            if (lk_s[1])               lock_seen <= 1'b1;   // only after the first lock
            if (lock_seen && !lk_s[1]) lock_lost <= 1'b1;
        end
    end

    // ---- pipeline stage 1: only compares on cx/cy ----
    logic [10:0] q_xb = 0;
    logic        q_inx = 0, q_bgx = 0, q_rbg = 0, q_rtic = 0;
    logic        q_rmrk = 0, q_rprg = 0, q_rswp = 0;
    logic [2:0]  q_row = 3'd4;          // 0..3 = row, 4 = none
    always_ff @(posedge clk_pixel) begin
        q_xb   <= cx - 11'd128;
        q_inx  <= (cx >= 11'd128) && (cx < 11'd1152);
        q_bgx  <= (cx >= 11'd112) && (cx < 11'd1168);
        q_rbg  <= (cy >= 10'd230) && (cy < 10'd500);
        q_rtic <= (cy >= 10'd236) && (cy < 10'd244);
        q_rmrk <= (cy >= 10'd430) && (cy < 10'd442);
        q_rprg <= (cy >= 10'd450) && (cy < 10'd462);
        q_rswp <= (cy >= 10'd470) && (cy < 10'd482);
        q_row  <= (cy >= 10'd248 && cy < 10'd284) ? 3'd0 :
                  (cy >= 10'd294 && cy < 10'd330) ? 3'd1 :
                  (cy >= 10'd340 && cy < 10'd376) ? 3'd2 :
                  (cy >= 10'd386 && cy < 10'd422) ? 3'd3 : 3'd4;
    end

    // ---- pipeline stage 2: field index, table access ----
    logic [3:0] fi;
    logic [5:0] xin;
    assign fi  = q_xb[9:6];
    assign xin = q_xb[5:0];

    logic       r_bg = 0, r_tic = 0, r_fld = 0, r_mrk = 0;
    logic       r_prg = 0, r_swp = 0, r_swpbit = 0, r_hold = 0, r_lock = 0;
    logic [1:0] r_sev = 0;
    always_ff @(posedge clk_pixel) begin
        r_bg     <= q_bgx & q_rbg;
        r_tic    <= q_inx & q_rtic & (xin < 6'd8)  & (fi[1:0] == 2'd0);
        r_fld    <= q_inx & (q_row != 3'd4) & (xin < 6'd56);
        r_mrk    <= q_inx & q_rmrk & (xin < 6'd56) & (fi == psda_p);
        r_prg    <= q_inx & q_rprg & (q_xb[9:0] < prog_p);
        r_swp    <= q_inx & q_rswp & (xin < 6'd24) & (fi < 4'd8);
        r_swpbit <= swp_p[3'd7 - fi[2:0]];
        r_sev    <= sevw_p[2*(16*{4'd0, q_row[1:0]} + {3'd0, fi}) +: 2];
        r_hold   <= hold_p;
        r_lock   <= lock_lost;
    end

    // ---- pipeline stage 3: colour. The output is thus shifted 3 pixels right, irrelevant.
    logic [23:0] colf;
    always_comb begin
        case (r_sev)
            2'd0:    colf = 24'h282828;   // not tested yet
            2'd1:    colf = 24'h00B000;   // never an error
            2'd2:    colf = 24'hC0C000;   // 1 to 15 errors in one sweep
            default: colf = 24'hC00000;   // 16 or more
        endcase
    end

    always_ff @(posedge clk_pixel) begin
        bar_on <= r_bg | r_fld | r_mrk | r_tic | r_prg | r_swp;
        if      (r_fld) bar_color <= colf;
        else if (r_mrk) bar_color <= 24'hFFFFFF;
        else if (r_tic) bar_color <= 24'h909090;
        else if (r_prg) bar_color <= r_hold ? 24'h8040FF : 24'h0060FF;
        else if (r_swp) bar_color <= r_swpbit ? 24'hFFFFFF : 24'h303030;
        else            bar_color <= r_lock ? 24'h400000 : 24'h000000;
    end

endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
