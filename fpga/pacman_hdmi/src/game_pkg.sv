// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file game_pkg.sv
//! @brief What the platform top (fpga/common/src/game20k_top.sv) needs to know about Pac-Man.
//!
//! Every game folder has a package of this name with these constants. The ROM layout is
//! not here: it comes from the manifest as gen/rom_map_pkg.sv.
package game_pkg;
    //! visible raster of the core, MAME pacman.cpp: 288 x 224 of 384 x 264, 6.1875 MHz pixel
    localparam int W = 288;
    localparam int H = 224;
    //! core clock: 371.25 MHz / 20, the platform derives its timers and the PLL divider from it
    localparam int CORE_HZ = 18_562_500;
    //! HDMI lines per frame: 1 core frame = 384 x 264 pixels x 3 clocks x 4 = 1584 x 768
    localparam int FRAME_H = 768;
    //! core clocks per pixel. The scaler counts them itself, video_ce is not used (0 would
    //! mean: the pixel enable comes from game_core on video_ce)
    localparam int CPP = 3;
    //! colour depth on video_r/g/b: 0 = 3/3/2 in the upper bits, 1 = 4/4/4
    localparam bit RGB444 = 0;
    //! MAME ROT90 (the monitor is turned clockwise for portrait): 0. ROT270: 1.
    localparam bit ROT_CCW = 0;
    //! the name in the HDMI source product description, 16 bytes
    localparam logic [127:0] PRODUCT_DESCRIPTION = {"Pac-Man", 72'd0};
    //! game signals on the input test bar, two characters each, signal 0 in the lowest 16
    //! bits: what game_core reports on map_bits (the filtered 4-way direction, coin, starts)
    localparam int MAP_N = 7;
    localparam logic [255:0] MAP_LABELS = 256'({"S2", "S1", "C ", "R ", "L ", "D ", "U "});
endpackage
