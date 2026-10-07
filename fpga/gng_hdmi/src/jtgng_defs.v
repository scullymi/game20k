// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// Ghosts'n Goblins (game20k): global macros for the jtcores sources.
//
// JTFRAME passes these as tool-wide defines, read from cores/gng/cfg/macros.def
// (jtcores 548b87b). Gowin has no define option in gw_sh, but it compiles all files
// as one unit, so this file goes FIRST in the file list. GnG is ROT0: no
// JTFRAME_VERTICAL, and without JTFRAME_OSD_FLIP dip_flip is an output of the game.
`define JTFRAME_MEMGEN            // game ports come from mem_ports.inc (src/inc)
`define JTFRAME_COLORW   4
`define JTFRAME_BUTTONS  2
`define JTFRAME_PXLCLK   6        // pxl_cen and pxl2_cen come from outside the game
`define JTFRAME_WIDTH  256
`define JTFRAME_HEIGHT 224
`define JTFRAME_BA1_START 'h14000
`define SND_START         'h18000
`define JTFRAME_BA2_START 'h20000
`define JTFRAME_BA3_START 'h40000
`define JTFRAME_MCLK 37125000     // our core clock, 371.25 MHz / 10
