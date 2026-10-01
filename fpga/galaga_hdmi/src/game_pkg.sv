// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file game_pkg.sv
//! @brief What the platform top (fpga/common/src/game20k_top.sv) needs to know about Galaga.
//!
//! Every game folder has a package of this name with these constants. The ROM layout is
//! not here: it comes from the manifest as gen/rom_map_pkg.sv.
package game_pkg;
    //! visible raster of the core, MAME galaga.cpp: 288 x 224 of 384 x 264, 6.1875 MHz pixel
    localparam int W = 288;
    localparam int H = 224;
    //! MAME ROT90 (the monitor is turned clockwise for portrait): 0. ROT270: 1.
    localparam bit ROT_CCW = 0;
    //! the name in the HDMI source product description, 16 bytes
    localparam logic [127:0] PRODUCT_DESCRIPTION = {"Galaga", 80'd0};
    //! game signals on the input test bar, two characters each, signal 0 in the lowest 16
    //! bits: what game_core reports on map_bits
    localparam int MAP_N = 6;
    localparam logic [255:0] MAP_LABELS = 256'({"S2", "S1", "C ", "F ", "R ", "L "});
endpackage
