// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file game_pkg.sv
//! @brief What the platform top (fpga/common/src/game20k_top.sv) needs to know about Dig Dug.
//!
//! Every game folder has a package of this name with these constants. The ROM layout and
//! the screen (upright, cw, ccw) are not here: they come from the manifest as
//! gen/rom_map_pkg.sv.
package game_pkg;
    //! visible raster of the core, MAME galaga.cpp (digdug): 288 x 224
    localparam int W = 288;
    localparam int H = 224;
    //! core clock: 371.25 MHz / 8. The core takes 8 clocks per pixel (5.80 MHz pixel, CPUs at
    //! 2.90 MHz), the original 18.432 MHz / 3 and / 6, so everything runs 5.6 % slower
    localparam int CORE_HZ = 46_406_250;
    //! HDMI lines per frame: the raster is cut to 360 x 264 (rtl_digdug/HVGEN.v), 1 core frame
    //! = 360 x 264 x 8 core clocks x 1.6 = 1584 x 768 HDMI clocks, 61.03 Hz as Galaga
    localparam int FRAME_H = 768;
    //! the pixel enable comes from the core (PCLK, every 8th clock) on video_ce
    localparam int CPP = 0;
    //! colour depth on video_r/g/b: 3/3/2 in the upper bits, as the palette PROM has it
    localparam bit RGB444 = 0;
    //! no palette path: the core applies its colour PROMs itself
    localparam bit PALETTE = 0;
    localparam int PAL_SEC = 0;
    //! the name in the HDMI source product description, 16 bytes
    localparam logic [127:0] PRODUCT_DESCRIPTION = {"Dig Dug", 72'd0};
    //! game signals on the input test bar, two characters each, signal 0 in the lowest 16
    //! bits: what game_core reports on map_bits
    localparam int MAP_N = 8;
    localparam logic [255:0] MAP_LABELS = 256'({"S2", "S1", "C ", "F ", "U ", "D ", "L ", "R "});
endpackage
