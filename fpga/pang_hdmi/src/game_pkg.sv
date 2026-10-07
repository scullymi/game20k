// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file game_pkg.sv
//! @brief What the platform top (fpga/common/src/game20k_top.sv) needs to know about Pang.
//!
//! Every game folder has a package of this name with these constants. The ROM layout and
//! the screen (upright, cw, ccw) are not here: they come from the manifests as
//! gen/rom_map_pkg.sv.
package game_pkg;
    //! visible raster of the core, jtpang_video.v: 384 x 240 of 512 x 272, 8 MHz pixel
    localparam int W = 384;
    localparam int H = 240;
    //! core clock: 371.25 MHz / 10. jtframe_gated_cen makes exactly 8, 4 and 1 MHz from it
    //! (64/297), see game_core.sv
    localparam int CORE_HZ = 37_125_000;
    //! HDMI lines per frame: 1 core frame = 512 x 272 pixels at 8 MHz = 646272 core clocks
    //! = 1584 x 816 HDMI clocks, 57.445 Hz. One core line is exactly three HDMI lines.
    localparam int FRAME_H = 816;
    //! the pixel enable comes from the core (8 MHz, 4 or 5 core clocks apart) on video_ce
    localparam int CPP = 0;
    //! colour depth on video_r/g/b: 4/4/4 from the palette RAM, 2048 colours
    localparam bit RGB444 = 1;
    //! no palette stage: the game delivers its colour
    localparam bit PALETTE = 0;
    localparam int PAL_SEC = 0;
    //! the name in the HDMI source product description, 16 bytes
    localparam logic [127:0] PRODUCT_DESCRIPTION = {"Pang", 96'd0};
    //! game signals on the input test bar, two characters each, signal 0 in the lowest 16
    //! bits: what game_core reports on map_bits
    localparam int MAP_N = 9;
    localparam logic [255:0] MAP_LABELS = 256'({"S2", "S1", "C ", "B ", "A ", "U ", "D ", "L ", "R "});
endpackage
