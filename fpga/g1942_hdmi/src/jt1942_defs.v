// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k, 1942: global macros for the jtcores sources.
//
// JTFRAME passes these as tool-wide defines. Its Go tool reads them from
// cores/1942/cfg/macros.def plus a few it derives itself. Gowin has no define
// option in gw_sh (SUG100, set_option list), but it compiles all files as one
// unit, so this file goes FIRST in the file list and the defines reach every
// later file.
`define JTFRAME_MEMGEN            // game ports come from mem_ports.inc (src/inc)
`define JTFRAME_COLORW   4
`define JTFRAME_BUTTONS  2
`define JTFRAME_HEADER   4
`define JTFRAME_BA1_START 'h14000
`define JTFRAME_BA2_START 'h18000
`define JTFRAME_BA3_START 'h2a000
`define JTFRAME_PROM_START 'h3a000
`define OBJ_OFFSET 'h1000
`define JTFRAME_WIDTH  256
`define JTFRAME_HEIGHT 224
`define JTFRAME_VERTICAL
`define JTFRAME_MCLK 37125000     // our core clock, 371.25 MHz / 10
