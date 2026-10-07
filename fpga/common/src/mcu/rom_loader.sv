// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a silent
                       // one-bit net.
//! @file rom_loader.sv
//! @brief Takes the game's ROM file from the FPGA Companion and fills the ROM memories of the core.
//!
//! File layout: the game's ROM manifest (fpga/<core>/<set>.manifest). scripts/make_rom.py
//! builds the file from it and writes the section table of this module as gen/rom_map_pkg.sv,
//! from which the top takes the parameters below. Both sides therefore read one source.
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
//!
//! Sections the manifest marks sdram (1942) are not for the core's write port but for the
//! SDRAM: their bytes go out with the file offset on wr_off, and rom_sdram.sv takes them.
//! While it cannot take a byte, wr_ready is low and the loader waits.

module rom_loader #(
    parameter int SLOT = 0,            //!< image slot this loader accepts
    parameter int TOTAL = 38944,       //!< expected file size in bytes
    //! two more accepted sizes, 0 for none: a file that is a prefix of the layout, so the
    //! sections from its end on stay unwritten (Pac-Man and Ms. Pac-Man next to Jr. Pac-Man)
    parameter int TOTAL_SHORT = 0,
    parameter int TOTAL_SHORT2 = 0,
    parameter int SECTIONS = 11,       //!< ROM memories of the core, 1..16, one wr_en bit each
    parameter int AW = 16,             //!< width of the byte counter and the offsets, 16..24
    //! start of every section in the file, section 0 in the lowest AW bits, in file order:
    //! section i runs from OFFSETS[i] up to OFFSETS[i+1], the last one up to TOTAL. One slot
    //! more than sections, so that the decoder's look at i+1 is never out of range.
    parameter logic [17*AW-1:0] OFFSETS = {16'h9800, 16'h9700, 16'h9600, 16'h9500, 16'h9400,
                                           16'h9000, 16'h7000, 16'h6000, 16'h5000, 16'h4000,
                                           16'h0000}
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
    output logic [15:0] wr_addr,      //!< offset inside the section
    output logic [AW-1:0] wr_off,     //!< offset in the file, with wr_data
    output logic [7:0]  wr_data,
    output logic [15:0] wr_en,        //!< bit i: section i takes this byte, bits above SECTIONS stay 0
    input  wire         wr_ready,     //!< 0: the taker of the bytes is busy, wait
    output logic        loaded,       //!< file transferred completely
    output logic        busy,
    output logic [15:0] count         //!< bytes taken so far, for the display
);
    // Only slot SLOT and only the exact file sizes are accepted. A wrong size is reported by
    // the Companion as "Core has rejected image".
    wire size_ok = (image_size == TOTAL) || (TOTAL_SHORT != 0 && image_size == TOTAL_SHORT)
                   || (TOTAL_SHORT2 != 0 && image_size == TOTAL_SHORT2);
    assign accepted = sel_strobe && (sel_index == SLOT[2:0]) && size_ok;

    logic [AW-1:0] cnt;
    logic [AW-1:0] last;      // offset of the file's last byte, set when it is accepted
    logic          active;
    assign busy  = active;
    assign count = cnt[15:0];

    // Target decoder: memory and address are derived from the running byte counter, the
    // section is the last one whose start the counter has reached. The address is ALWAYS
    // formed as the difference to the section start. Merely masking off the lower bits only
    // works when the offset is a multiple of the section size, and for Galaga's sp_graphx
    // (0x7000, 8192 bytes) it is not: the two halves ended up swapped in memory.
    logic [15:0]   en_c;
    logic [AW-1:0] addr_c;
    always_comb begin
        en_c   = 16'd0;
        addr_c = '0;
        for (int i = 0; i < SECTIONS; i++)
            if (cnt >= OFFSETS[AW*i +: AW] && (i == SECTIONS - 1 || cnt < OFFSETS[AW*(i+1) +: AW])) begin
                en_c[i] = 1'b1;
                addr_c  = cnt - OFFSETS[AW*i +: AW];
            end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            cnt         <= '0;
            active      <= 1'b0;
            loaded      <= 1'b0;
            wr_en       <= 16'd0;
            data_strobe <= 1'b0;
        end else begin
            wr_en       <= 16'd0;
            data_strobe <= 1'b0;

            // selection: accepting starts the transfer, size 0 is the deselect at the end
            if (sel_strobe && (sel_index == SLOT[2:0])) begin
                if (size_ok) begin
                    cnt    <= '0;
                    last   <= image_size[AW-1:0] - 1'b1;
                    active <= 1'b1;
                    loaded <= 1'b0;
                end else if (image_size == 64'd0)
                    active <= 1'b0;
            end

            // One byte per two clocks: first take and write, in the clock after that
            // data_strobe acknowledges and the FIFO advances.
            if (active && data_available && !data_strobe && wr_ready) begin
                wr_data     <= data_in;
                wr_addr     <= addr_c[15:0];
                wr_off      <= cnt;
                wr_en       <= en_c;
                data_strobe <= 1'b1;
                cnt <= cnt + 1'b1;
                if (cnt == last) begin
                    active <= 1'b0;
                    loaded <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
