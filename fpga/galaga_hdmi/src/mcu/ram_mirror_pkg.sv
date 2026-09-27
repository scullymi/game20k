// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file ram_mirror_pkg.sv
//! @brief Layout of the RAM mirror block on SPI target 5 (game20k)
//!
//! The one place for the block sizes. ram_spi.sv slices the byte stream with them, the
//! top counts the FIFO with them, ram_diag.sv checks the received length against them.
//! The firmware has the same six constants under the same names (RAM_MIRROR_* in
//! src/main.c of the FPGA-Companion fork, branch game20k). Both sides must agree byte
//! for byte.
package ram_mirror_pkg;
    //! 'R' 'A' 'C' 'H', layout, frame no (2), harvest flag
    localparam int RAM_MIRROR_HEAD  = 8;
    //! bgram + wram1..3, the game RAM
    localparam int RAM_MIRROR_DATA  = 5120;
    //! oracle log, 512 entries of 3 bytes
    localparam int RAM_MIRROR_LOG   = 1536;
    //! 6656, both from one FIFO
    localparam int RAM_MIRROR_BODY  = RAM_MIRROR_DATA + RAM_MIRROR_LOG;
    //! 6664, offset of the footer
    localparam int RAM_MIRROR_FOOT  = RAM_MIRROR_HEAD + RAM_MIRROR_BODY;
    //! 6672, footer: frame no (2), underrun, log overflow, checksum (2), log count (2)
    localparam int RAM_MIRROR_BYTES = RAM_MIRROR_FOOT + 8;
endpackage
