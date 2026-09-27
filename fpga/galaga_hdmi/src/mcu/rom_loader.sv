// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! @file rom_loader.sv
//! @brief Takes galaga.rom from the FPGA Companion and fills the eleven ROM memories of the core.
//!
//! File layout: see scripts/make_galaga_rom.sh.
//!
//! Flow on the SD side (sd_card.v, SPI command 8):
//!   - The Companion selects an image: rom_image_selection_strobe goes high for one clock,
//!     rom_image_selected carries the slot, image_size the file size. accepted must be valid
//!     in exactly this clock, which is why it is combinational.
//!   - The Companion then pushes the bytes block by block into the FIFO of the sd_card
//!     module. data_available flags that a byte is ready; one clock of data_strobe takes it.
//!
//! One byte per two clocks at 18.5625 MHz is plenty by orders of magnitude, the SPI bus is
//! the brake. The core stays in reset as long as loaded is not set.

module rom_loader #(
    parameter int SLOT = 0,            //!< image slot this loader accepts
    parameter int TOTAL = 38944        //!< expected file size in bytes
)(
    input  wire         clk,
    input  wire         reset,

    //! Interface to sd_card.v
    input  wire         sel_strobe,
    input  wire  [2:0]  sel_index,
    input  wire  [63:0] image_size,
    output logic        accepted,
    input  wire         data_available,
    input  wire  [7:0]  data_in,
    output logic        data_strobe,

    //! Write side to the ROM memories of the core
    output logic [13:0] wr_addr,
    output logic [7:0]  wr_data,
    output logic [10:0] wr_en,        //!< 0 cpu1, 1 cpu2, 2 cpu3, 3 bg_graphx, 4 sp_graphx,
                                      //!< 5 cs54xx, 6 bg_pal, 7 sp_pal, 8 snd_seq,
                                      //!< 9 snd_samples, 10 rgb
    output logic        loaded,       //!< file transferred completely
    output logic        busy,
    output logic [15:0] count         //!< bytes taken so far, for the display
);
    // section offsets, identical to scripts/make_galaga_rom.sh
    localparam int O_CPU1 = 16'h0000;
    localparam int O_CPU2 = 16'h4000;
    localparam int O_CPU3 = 16'h5000;
    localparam int O_BGGR = 16'h6000;
    localparam int O_SPGR = 16'h7000;
    localparam int O_54XX = 16'h9000;
    localparam int O_BGPA = 16'h9400;
    localparam int O_SPPA = 16'h9500;
    localparam int O_SSEQ = 16'h9600;
    localparam int O_SSAM = 16'h9700;
    localparam int O_RGB  = 16'h9800;

    // Only slot SLOT and only the exact file size are accepted. A wrong size is reported by
    // the Companion as "Core has rejected image".
    assign accepted = sel_strobe && (sel_index == SLOT[2:0]) && (image_size == TOTAL);

    logic [15:0] cnt;
    logic        active;
    assign busy  = active;
    assign count = cnt;

    // Target decoder: memory and address are derived from the running byte counter.
    // The address is ALWAYS formed as the difference to the section start. Merely masking
    // off the lower bits only works when the offset is a multiple of the section size -
    // for sp_graphx (0x7000, 8192 bytes) it is not, and the two halves ended up swapped
    // in memory.
    logic [10:0] en_c;
    logic [13:0] addr_c;
    always_comb begin
        en_c   = 11'd0;
        addr_c = 14'd0;
        if      (cnt < O_CPU2) begin en_c[0]  = 1'b1; addr_c = 14'(cnt - O_CPU1); end
        else if (cnt < O_CPU3) begin en_c[1]  = 1'b1; addr_c = 14'(cnt - O_CPU2); end
        else if (cnt < O_BGGR) begin en_c[2]  = 1'b1; addr_c = 14'(cnt - O_CPU3); end
        else if (cnt < O_SPGR) begin en_c[3]  = 1'b1; addr_c = 14'(cnt - O_BGGR); end
        else if (cnt < O_54XX) begin en_c[4]  = 1'b1; addr_c = 14'(cnt - O_SPGR); end
        else if (cnt < O_BGPA) begin en_c[5]  = 1'b1; addr_c = 14'(cnt - O_54XX); end
        else if (cnt < O_SPPA) begin en_c[6]  = 1'b1; addr_c = 14'(cnt - O_BGPA); end
        else if (cnt < O_SSEQ) begin en_c[7]  = 1'b1; addr_c = 14'(cnt - O_SPPA); end
        else if (cnt < O_SSAM) begin en_c[8]  = 1'b1; addr_c = 14'(cnt - O_SSEQ); end
        else if (cnt < O_RGB)  begin en_c[9]  = 1'b1; addr_c = 14'(cnt - O_SSAM); end
        else                   begin en_c[10] = 1'b1; addr_c = 14'(cnt - O_RGB);  end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            cnt         <= 16'd0;
            active      <= 1'b0;
            loaded      <= 1'b0;
            wr_en       <= 11'd0;
            data_strobe <= 1'b0;
        end else begin
            wr_en       <= 11'd0;
            data_strobe <= 1'b0;

            // selection: accepting starts the transfer, size 0 is the deselect at the end
            if (sel_strobe && (sel_index == SLOT[2:0])) begin
                if (image_size == TOTAL) begin
                    cnt    <= 16'd0;
                    active <= 1'b1;
                    loaded <= 1'b0;
                end else if (image_size == 64'd0)
                    active <= 1'b0;
            end

            // One byte per two clocks: first take and write, in the clock after that
            // data_strobe acknowledges and the FIFO advances.
            if (active && data_available && !data_strobe) begin
                wr_data     <= data_in;
                wr_addr     <= addr_c;
                wr_en       <= en_c;
                data_strobe <= 1'b1;
                cnt <= cnt + 16'd1;
                if (cnt == TOTAL[15:0] - 16'd1) begin
                    active <= 1'b0;
                    loaded <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
