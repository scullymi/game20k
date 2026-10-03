// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k, 1942: the game port list that the jtframe Go tool
// would generate as mem_ports.inc from cores/1942/cfg/mem.yaml, written by hand
// from the template modules/jtframe/hdl/inc/ports.v and the port rules in
// modules/jtframe/src/jtframe/mem/mem.go (fill_implicit_ports, addr_range,
// data_range). jtcores commit 0b197caeae1596380863b8388552b125e7e1b208.
//
// clocks: clk48 -> 12M with outputs cen12 cen6 cen3 cen1p5 (OutStr is reversed)
    input cen1p5, cen3, cen6, cen12, // 12000000 Hz
    // Audio channels (module jt49: data_width 10, unsigned, audio_mod.yaml)
    output [ 9:0] psg0,
    output [ 9:0] psg1,
    // Memory ports (neither JTFRAME_SDRAM_LARGE nor _XL)
    input   [21:0]  prog_addr,
    input   [ 7:0]  prog_data,
    input           prog_we,
    input   [ 1:0]  prog_ba,
    input   [25:0]  ioctl_addr,
    input           prom_we,
`ifdef JTFRAME_HEADER
    input           header,
`endif
    input           ioctl_ram,
    input           ioctl_cart,
    // Explicit ports: mem.yaml ports: plus the BRAM tmap and its dual port chram
    output          not_higemaru,
    output  [10:1]  tmap_addr,
    input   [15:0]  tmap_dout,
    output  [10:1]  chram_addr,
    output  [15:0]  chram_din,
    input   [15:0]  chram_o16,
    // Buses to BRAM
    output  [ 1:0]  chram_we, // Dual port for chram
    // Buses to SDRAM. char and scr use cs: LVBL, obj uses cs: 1'b1, so they
    // have no _cs port. addr_range is [aw-1 : dw>>4].
    input   [ 7:0]  main_data,
    output          main_cs,
    output  [16:0]  main_addr,
    input           main_ok,
    input   [ 7:0]  snd_data,
    output          snd_cs,
    output  [14:0]  snd_addr,
    input           snd_ok,
    input   [15:0]  char_data,
    output  [12:1]  char_addr,
    input           char_ok,
    input   [15:0]  obj_data,
    output  [15:1]  obj_addr,
    input           obj_ok,
    input   [31:0]  scr_data,
    output  [15:2]  scr_addr,
    input           scr_ok,
    // game20k: the CPU writes for the RetroAchievements mirror (g1942_mirror.sv), not
    // part of JTFRAME's port list. Main CPU: bus and the chip selects of its four RAMs.
    output          mir_ram_we,
    output          mir_char_cs,
    output          mir_scr_cs,
    output          mir_obj_cs,
    output          mir_wr_n,
    output  [12:0]  mir_ab,
    output  [ 7:0]  mir_dout,
    // sound CPU: its RAM's write
    output          mir_snd_we,
    output  [10:0]  mir_snd_addr,
    output  [ 7:0]  mir_snd_dout,
    // the palette index of each pixel, timed like red/green/blue (jt1942_colmix)
    output  [ 7:0]  pal_idx
