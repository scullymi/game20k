// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k, Pang: global macros for the jtcores sources.
//
// JTFRAME passes these as tool-wide defines. Gowin has no define option in gw_sh, but it
// compiles all files as one unit, so this file goes FIRST in the file list and the defines
// reach every later file. Of jtpang's macros (cores/pang/cfg/macros.def) the sources used
// here test none; jtframe_freqinfo.v, inside jtframe_gated_cen.v, needs the clock.
`define JTFRAME_MCLK 37125000     // our core clock, 371.25 MHz / 10
// game20k: the Z80's clock enables at least 3 clocks apart (jtframe_z80wait.v): its
// 8 MHz are 4 or 5 clocks of 37.125 MHz, and a recovered enable closer than 3 clocks reads
// RAM too early
`define GAME20K_Z80_GAP 3
