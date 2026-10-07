// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file game_pkg.sv
//! @brief What the platform top (fpga/common/src/game20k_top.sv) needs to know about Time Pilot.
//!
//! Every game folder has a package of this name with these constants. The ROM layout and
//! the screen (upright, cw, ccw) are not here: they come from the manifest as
//! gen/rom_map_pkg.sv.
package game_pkg;
    //! visible raster of the core, MAME timeplt.cpp: 256 x 224 of 384 x 264, 6.144 MHz pixel
    localparam int W = 256;
    localparam int H = 224;
    //! core clock: 371.25 MHz / 10. The core makes 12.375, 6.1875 and 3.09 MHz from it with a
    //! counter modulo 12 (TimePilot_CPU.sv), the original's rates +0.7 % as with Pac-Man
    localparam int CORE_HZ = 37_125_000;
    //! HDMI lines per frame: 1 core frame = 384 x 264 pixels x 6 core clocks = 608256 core
    //! clocks = 1584 x 768 HDMI clocks, the same as Pac-Man
    localparam int FRAME_H = 768;
    //! the pixel enable comes from the core (cen_6m, every 6th clock) on video_ce
    localparam int CPP = 0;
    //! colour depth on video_r/g/b: the core's 5/5/5 cut to 4/4/4
    localparam bit RGB444 = 1;
    //! no palette path: the core applies its colour PROMs itself
    localparam bit PALETTE = 0;
    localparam int PAL_SEC = 0;
    //! the name in the HDMI source product description, 16 bytes
    localparam logic [127:0] PRODUCT_DESCRIPTION = {"Time Pilot", 48'd0};
    //! game signals on the input test bar, two characters each, signal 0 in the lowest 16
    //! bits: what game_core reports on map_bits
    localparam int MAP_N = 8;
    localparam logic [255:0] MAP_LABELS = 256'({"S2", "S1", "C ", "A ", "U ", "D ", "L ", "R "});
endpackage
