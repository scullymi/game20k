// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file ram_mirror_pkg.sv
//! @brief Layout of the RAM mirror block on SPI target 5 (game20k)
//!
//! The one place for what is the same for every game: seven constants, identical in the
//! firmware under the same names (RAM_MIRROR_* in src/main.c of the FPGA-Companion fork,
//! branch game20k), scripts/check_contracts.py compares them. ram_spi.sv slices the byte
//! stream with them, the top counts the FIFO with them, ram_diag.sv checks the received
//! length against them.
//!
//! The game's own size is not here: it lives in its manifest (line mirror) and comes out
//! of gen/rom_map_pkg.sv as MIRROR_DATA, a multiple of RAM_MIRROR_PAGE and at most
//! RAM_MIRROR_DATA_MAX. The core announces it in header bytes 14/15 (MIRROR_DATA /
//! RAM_MIRROR_PAGE and the complement) and its board id in bytes 12/13 (BOARD_ID and the
//! complement), so the firmware sizes its read from the header instead of from a constant.
package ram_mirror_pkg;
    //! Header byte 4. Layout 4 has a header of 16 bytes with board id and data size in
    //! bytes 12 to 15. The firmware checks it and refuses a core of another layout with a
    //! message.
    localparam logic [7:0] RAM_MIRROR_LAYOUT = 8'h04;
    //! 'R' 'A' 'C' 'H', layout, frame no (2), harvest flag, reset count, build flags,
    //! their complements, board id and its complement, data size in 128-byte pages and its
    //! complement
    localparam int RAM_MIRROR_HEAD = 16;
    //! The unit of header byte 14: a game's data size goes out in pages of this many bytes.
    //! A multiple of 8, so the footer decode of ram_spi.sv holds for every game.
    localparam int RAM_MIRROR_PAGE = 128;
    //! The largest game RAM a core may announce, 176 pages of RAM_MIRROR_PAGE bytes. The
    //! firmware sizes its buffer with it.
    localparam int RAM_MIRROR_DATA_MAX = 22528;
    //! oracle log, 512 entries of 3 bytes
    localparam int RAM_MIRROR_LOG = 1536;
    //! footer: frame no (2), underrun, log overflow, checksum (2), log count (2)
    localparam int RAM_MIRROR_TAIL = 8;
    //! 24088, the longest block. A game's block is HEAD + MIRROR_DATA + LOG + TAIL.
    localparam int RAM_MIRROR_BYTES_MAX = RAM_MIRROR_HEAD + RAM_MIRROR_DATA_MAX + RAM_MIRROR_LOG + RAM_MIRROR_TAIL;
endpackage
