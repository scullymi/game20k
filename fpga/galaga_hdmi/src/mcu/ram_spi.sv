// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent 1-bit net.
//! @file ram_spi.sv
//! @brief SPI target channel 5: the RAM mirror on its way to the Pico (game20k)
//!
//! The Companion fetches one block per frame: header, game RAM, oracle log, footer. The
//! sizes live in ram_mirror_pkg.sv (RAM_MIRROR_*); the firmware carries the same constants.
//!
//! Verdict and measurement
//! -----------------------
//! The Pico checks each block and sends its verdict back as the FIRST byte of the next
//! transfer (0xA5 fine, 0xE1..0xE9 the failed check). The FPGA also counts the fetched
//! bytes and measures the duration itself, for the diagnostic bars (ram_diag.sv).
//!
//! Course of one transfer
//! ----------------------
//! The Companion sends the target id 5, then one byte out for every byte it wants to read
//! (full duplex). The first is its verdict on the previous transfer, from the second on
//! the payload runs.
//!
//! WHY THE BYTE COUNTER RUNS IN THE SPI CLOCK
//! In a block transfer the bytes follow each other WITHOUT a gap. The core clock learns of
//! the finished byte only through two synchroniser stages, that is about 150 ns later, and
//! by then the line is already shifting out the first bits of the next byte, which would
//! come from the old value. Therefore this module counts the bytes itself in the SPI clock,
//! exactly as mcu_spi.v counts its bits. The measurement in the core clock does not depend
//! on it: it only observes.
//!
//! The payload comes out of a look-ahead FIFO (snap_fifo) that the top fills at the core
//! clock and this module drains at the SPI clock.
//! -----------------------------------------------------------------------------------------

module ram_spi (
    input  wire         clk,              //!< clk_core
    input  wire         reset,
    //! SPI side, for the byte counter
    input  wire         spi_ss,           //!< active low
    input  wire         spi_clk,
    //! Interface to mcu_spi.v
    input  wire         strobe,           //!< one byte has gone over the line
    input  wire         start,            //!< first byte after the target id
    input  wire  [7:0]  data_in,          //!< what the Pico sends
    output logic [7:0]  data_out,         //!< what the FPGA returns

    //! Payload from the look-ahead FIFO
    input  wire  [7:0]  fifo_data,
    input  wire         fifo_empty,
    input  wire         fifo_undr,        //!< the FIFO reports it itself, in the SPI clock
    input  wire  [15:0] body_sum,         //!< checksum over the delivered payload bytes
    input  wire  [9:0]  log_count,        //!< entries in the oracle log
    input  wire         log_ovf,          //!< the harvest window had more writes than the log holds
    output logic [15:0] pico_rc,          //!< {loaded conditions, fired}
    output logic [15:0] pico_us,          //!< rcheevos evaluation time per frame
    output logic [7:0]  pico_last,        //!< last fired achievement, 1-based
    //! Banner for unlocks. The Pico pushes ONE character per transfer (header byte 6 =
    //! flag and position, byte 7 = character). At one transfer per frame a text of 24
    //! characters is complete after about 0.4 s, which is why the Pico sets the display
    //! flag only once it has been through once.
    output logic        txt_we,
    output logic [4:0]  txt_addr,
    output logic [7:0]  txt_data,
    output logic        banner_on,
    output logic        banner_gold,      //!< header byte 6 bit 6: hardcore, gold text
    output logic        banner_new,       //!< header byte 6 bit 5: new, green mark
    output logic [15:0] undr_pos,         //!< diagnostic: payload byte number at first underrun
    output logic        fifo_pop,
    input  wire  [15:0] frame_no,        //!< frame number of the snapshot
    input  wire         harv_busy,       //!< a harvest is running right now
    output logic        run,             //!< a transfer is running (to the core)
    output logic        underrun,        //!< the FIFO was empty when a byte was needed

    //! Measurements for the display
    output logic [15:0] last_count,       //!< bytes of the last transfer, expected RAM_MIRROR_BYTES
    output logic [15:0] last_us,          //!< duration of the last transfer in microseconds
    output logic [7:0]  pico_verdict,     //!< 0xA5 = pattern was fine
    output logic [15:0] transfers         //!< number of transfers, saturating
);
    import ram_mirror_pkg::*;   // block sizes of the RAM mirror, see ram_mirror_pkg.sv
    logic [15:0] cnt;                     // byte within the running transfer
    logic [15:0] us_cnt;                  // microseconds of the running transfer
    logic [4:0]  us_div;                  // 18.5625 MHz / 18.5625 = 1 us (approx.: 19 clocks)
    logic        busy;
    // The end of a transfer is told by chip select, not by a guessed idle time.
    // An idle time is no good here: the Pico is interrupted during the block (USB polling,
    // interrupts), and every pause would cut the measurement into pieces. What would be
    // shown is then the last piece, sometimes longer, sometimes shorter.
    logic [2:0]  ss_s;
    logic        harv_at_start;

    // ---- The byte counter runs in the SPI clock ----
    // Counts the bits like mcu_spi.v and increments the byte counter at the byte end. The
    // Pico's verdict is byte 0, the payload starts at 1, which is why the pattern for
    // payload byte k sits at counter value k+1.
    logic [2:0]  bitc;
    logic [15:0] bcnt;
    always_ff @(negedge spi_clk or posedge spi_ss) begin
        if (spi_ss) begin
            bitc <= 3'd0;
            bcnt <= 16'd0;
        end else begin
            bitc <= bitc + 3'd1;
            if (bitc == 3'd7) bcnt <= bcnt + 16'd1;
        end
    end

// Payload byte number: -1 for the target id, -1 for the Pico's verdict byte
    wire [15:0] k = bcnt - 16'd2;

    // Header, then the body (payload plus oracle log), then the footer; sizes in ram_mirror_pkg.
    // Header and footer carry the same frame number: if they do not match, the snapshot
    // changed during the transfer and the Pico discards it.
    logic [7:0] hdr;
    always_comb begin
        case (k[2:0])
            3'd0: hdr = 8'h52;            // 'R'
            3'd1: hdr = 8'h41;            // 'A'
            3'd2: hdr = 8'h43;            // 'C'
            3'd3: hdr = 8'h48;            // 'H'
            // Layout 2: 5120 payload bytes, then 1536 bytes of oracle log
            3'd4: hdr = 8'h02;
            3'd5: hdr = frame_no[7:0];
            3'd6: hdr = frame_no[15:8];
            // Header byte 7 says whether a harvest was running at the START: then an
            // underrun is to be expected, and the Pico can skip checking the snapshot.
            default: hdr = {7'd0, harv_at_start};
        endcase
    end
    logic [7:0] ftr;
    always_comb begin
        case (k[2:0])
            3'd0: ftr = frame_no[7:0];
            3'd1: ftr = frame_no[15:8];
            // The underrun of the look-ahead FIFO belongs in the FOOTER: in the header it
            // could only report what has not happened yet, as the header goes out first.
            // A snapshot with this bit set is unusable, bytes were delivered twice.
            3'd2: ftr = {7'd0, fifo_undr};
            // Overflow of the oracle log: more writes during the harvest than the log holds.
            3'd3: ftr = {7'd0, log_ovf};
            // Core-side checksum over the RAM_MIRROR_BODY bytes (payload plus oracle log).
            // It is final at least seven byte times before the footer, which is how far the
            // line delivery runs ahead before the FIFO throttles it, so it is stable here.
            3'd4: ftr = body_sum[7:0];
            3'd5: ftr = body_sum[15:8];
            // Number of entries in the oracle log; the rest of the 1536 bytes is padding
            3'd6: ftr = log_count[7:0];
            3'd7: ftr = {6'd0, log_count[9:8]};
            default: ftr = 8'h00;
        endcase
    end

    // Body = payload plus oracle log, both out of the same FIFO.
    // DIAGNOSTIC: the underrun only says THAT, not WHERE. Record the position, in the SPI
    // clock at the first occurrence: in the core clock it would be a sample across the clock
    // domain crossing, and a detector sampled that way misses the event (measured on the device).
    logic        undr_d = 0;
    always_ff @(negedge spi_clk) begin
        undr_d <= fifo_undr;
        if (fifo_undr && !undr_d) undr_pos <= k;
    end

    wire in_head = (k < RAM_MIRROR_HEAD);
    wire in_body = (k >= RAM_MIRROR_HEAD) && (k < RAM_MIRROR_FOOT);
    assign data_out = in_head ? hdr : in_body ? fifo_data : ftr;

    // At the byte end of the next payload byte advance one slot
    assign fifo_pop = in_body && (bitc == 3'd7);
    // also in the clock of the verdict byte itself, so no harvest starts in that clock
    assign run      = busy | (strobe & start);

    always_ff @(posedge clk) begin
        if (reset) begin
            cnt <= 16'd0; busy <= 1'b0; us_cnt <= 16'd0; us_div <= 5'd0;
            last_count <= 16'd0; last_us <= 16'd0; transfers <= 16'd0;
            pico_verdict <= 8'd0; ss_s <= 3'b111; underrun <= 1'b0; harv_at_start <= 1'b0;
            pico_rc <= 16'd0; pico_us <= 16'd0; pico_last <= 8'd0;
            txt_we <= 1'b0; txt_addr <= 5'd0; txt_data <= 8'd0;
            banner_on <= 1'b0; banner_gold <= 1'b0; banner_new <= 1'b0;
        end else begin
            // microsecond tick
            if (us_div == 5'd18) begin
                us_div <= 5'd0;
                if (busy && us_cnt != 16'hFFFF) us_cnt <= us_cnt + 16'd1;
            end else
                us_div <= us_div + 5'd1;

            ss_s <= {ss_s[1:0], spi_ss};
            txt_we <= 1'b0;   // the write pulse is exactly one clock wide

            if (strobe) begin
                if (start) begin
                    // First byte: the Pico's verdict on the PREVIOUS transfer. Only what
                    // the Pico CAN send at all is accepted. The back channel is sampled in
                    // the core clock while the line is already shifting the next byte; once
                    // every few minutes a value arrives that does not exist in the code at
                    // all (measured: 0xF0). For the payload this is irrelevant, it runs in
                    // the opposite direction and is covered by checksum and oracle. For a
                    // long-run measurement it is not: a single outlier colours a sticky
                    // field.
                    if (data_in == 8'hA5 || (data_in >= 8'hE1 && data_in <= 8'hE9))
                        pico_verdict <= data_in;
                    underrun      <= 1'b0;
                    harv_at_start <= harv_busy;
                    cnt          <= 16'd0;
                    us_cnt       <= 16'd0;
                    busy         <= 1'b1;
                end else begin
                    // Back channel, Pico to FPGA, sent while the Pico reads the header. It
                    // carries the rcheevos state: fired and loaded achievements, evaluation
                    // time, last achievement number, then the banner text. The oracle count
                    // is not part of it: the oracle keeps running but only speaks up through
                    // verdict 0xE9 when it finds something.
                    if      (cnt == 16'd0) pico_rc[7:0]  <= data_in;  // fired
                    else if (cnt == 16'd1) pico_rc[15:8] <= data_in;  // loaded
                    else if (cnt == 16'd2) pico_us[7:0]  <= data_in;
                    else if (cnt == 16'd3) pico_us[15:8] <= data_in;
                    else if (cnt == 16'd4) pico_last     <= data_in;
                    else if (cnt == 16'd6) begin
                        txt_addr    <= data_in[4:0];
                        banner_new  <= data_in[5];
                        banner_gold <= data_in[6];
                        banner_on   <= data_in[7];
                    end
                    else if (cnt == 16'd7) begin
                        txt_data <= data_in;
                        txt_we   <= 1'b1;   // the address is already set from byte 6
                    end
                    if (cnt != 16'hFFFF) cnt <= cnt + 16'd1;
                end
            end

            // rising edge of chip select: the transfer is over.
            // Only what got past the header is measured. The Pico first reads the eight
            // header bytes alone and aborts if byte 7 reports that a harvest is running
            // right now (the shadow would then be half new, half old). Those probes are
            // intended operation and not measurements: if they were counted, the display
            // would constantly show 8 instead of 6672.
            if (busy && ss_s[2] == 1'b0 && ss_s[1] == 1'b1) begin
                busy     <= 1'b0;
                // The underrun report comes ready-made from the FIFO and is only taken
                // over here: a single sample at the end instead of a hundred thousand
                // during the transfer. It serves the display only; binding is the bit in
                // the footer that the Pico has read.
                underrun <= fifo_undr;
                if (cnt > RAM_MIRROR_HEAD) begin
                    last_count <= cnt;
                    last_us    <= us_cnt;
                    if (transfers != 16'hFFFF) transfers <= transfers + 16'd1;
                end
            end
        end
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
