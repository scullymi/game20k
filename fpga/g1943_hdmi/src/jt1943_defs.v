// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// 1943 (game20k): global macros for the jtcores sources.
//
// JTFRAME passes these as tool-wide defines, read from cores/1943/cfg/macros.def
// (jtcores 548b87b), the [sidi|mist] section included: JT1943_MCU_HLE replaces the
// i8751 by a table. Gowin has no define option in gw_sh, but it compiles all files
// as one unit, so this file goes FIRST in the file list.
`define JTFRAME_MEMGEN            // game ports come from mem_ports.inc (hdl/inc)
`define JTFRAME_COLORW   4
`define JTFRAME_BUTTONS  3
`define JTFRAME_PXLCLK   6        // pxl_cen and pxl2_cen come from outside the game
`define JTFRAME_OSD_FLIP          // dip_flip is an input
`define JTFRAME_VERTICAL
`define JTFRAME_WIDTH  256
`define JTFRAME_HEIGHT 224
`define SND_START  'h28000
`define CHAR_START 'h30000
`define MAP1_START 'h38000
`define MAP2_START 'h40000
`define SCR1_START 'h48000
`define SCR2_START 'h88000
`define OBJ_START  'h98000
`define JTFRAME_BA1_START  'h38000
`define JTFRAME_BA2_START  'h48000
`define JTFRAME_BA3_START  'h98000
`define JTFRAME_PROM_START 'hD8000
`define JT1943_MCU_HLE
`define JTFRAME_MCLK 37125000     // our core clock, 371.25 MHz / 10
