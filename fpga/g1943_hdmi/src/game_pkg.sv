// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file game_pkg.sv
//! @brief What the platform top (fpga/common/src/game20k_top.sv) needs to know about 1943.
//!
//! Every game folder has a package of this name with these constants. The ROM layout is
//! not here: it comes from the manifest as gen/rom_map_pkg.sv.
package game_pkg;
    //! visible raster of the core, jtgng_timer.v: 256 x 224 of 384 x 262, 6 MHz pixel
    localparam int W = 256;
    localparam int H = 224;
    //! core clock: 371.25 MHz / 10. jotego's clock enables make exactly 12, 6, 3 and 1.5 MHz
    //! from it (jtframe_gated_cen, 32/99), see game_core.sv
    localparam int CORE_HZ = 37_125_000;
    //! HDMI lines per frame: 1 core frame = 384 x 262 pixels at 6 MHz = 622512 core clocks
    //! = 1584 x 786 HDMI clocks, 59.637 Hz. One core line is exactly three HDMI lines.
    localparam int FRAME_H = 786;
    //! the pixel enable comes from the core (cen6, 6 or 7 core clocks apart) on video_ce
    localparam int CPP = 0;
    //! colour depth on video_r/g/b: with PALETTE the index in 3/3/2, so 0
    localparam bit RGB444 = 0;
    //! the game delivers its palette index, the platform applies the colour PROMs after the
    //! scaler and the frame buffer: the frame buffer keeps 8 bits a pixel, the picture keeps
    //! all 4/4/4 colours. The PROMs are section PAL_SEC of the manifest, red at 0x000, green
    //! at 0x100, blue at 0x200 (bm1.12a, bm2.13a, bm3.14a, section palette).
    localparam bit PALETTE = 1;
    localparam int PAL_SEC = 9;
    //! MAME lists 1943 as ROT270 (monitor turned anticlockwise). game_core turns the picture
    //! by 180 degrees with jotego's dip_flip, so it lies like 1942 (ROT90) and takes the
    //! same rotation, menu and banner.
    localparam bit ROT_CCW = 0;
    //! the name in the HDMI source product description, 16 bytes
    localparam logic [127:0] PRODUCT_DESCRIPTION = {"1943", 96'd0};
    //! game signals on the input test bar, two characters each, signal 0 in the lowest 16
    //! bits: what game_core reports on map_bits
    localparam int MAP_N = 9;
    localparam logic [255:0] MAP_LABELS = 256'({"S2", "S1", "C ", "B ", "A ", "U ", "D ", "L ", "R "});
endpackage
