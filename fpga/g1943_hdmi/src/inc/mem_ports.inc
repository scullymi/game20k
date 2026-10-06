// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// 1943 (game20k): the game port list that the jtframe Go tool
// would generate as mem_ports.inc from cores/1943/cfg/mem.yaml (jtcores 548b87b),
// written by hand with the same rules as the 1942 core:
// addr_range [aw-1 : dw>>4], a _cs port only for buses without cs: in mem.yaml.
//
// clocks: clk48 -> 6M with cen6 cen3 cen1p5, clk48 -> 8M with cen8
    input cen1p5, cen3, cen6, // 6000000 Hz
    input cen8,               // 8000000 Hz
    // Audio channels (audio_mod.yaml: jt03_psg 10 bit unsigned, jt03_fm 16 bit signed)
    output        [ 9:0] psg0,
    output        [ 9:0] psg1,
    output signed [15:0] fm0,
    output signed [15:0] fm1,
    // Memory ports
    input   [21:0]  prog_addr,
    input   [ 7:0]  prog_data,
    input           prog_we,
    input   [ 1:0]  prog_ba,
    input   [25:0]  ioctl_addr,
    input           prom_we,
    input           ioctl_ram,
    input           ioctl_cart,
    // snd: a BRAM in jotego's mem.yaml, here a bus to SDRAM with cs and ok (game20k)
    output  [14:0]  snd_addr,
    input   [ 7:0]  snd_data,
    output          snd_cs,
    input           snd_ok,
    // Buses to SDRAM, bank 0
    input   [ 7:0]  main_data,
    output          main_cs,
    output  [17:0]  main_addr,
    input           main_ok,
    input   [15:0]  char_data,
    output  [14:1]  char_addr,
    input           char_ok,
    // bank 1
    input   [15:0]  map1_data,
    output          map1_cs,
    output  [14:1]  map1_addr,
    input           map1_ok,
    input   [15:0]  map2_data,
    output          map2_cs,
    output  [14:1]  map2_addr,
    input           map2_ok,
    // bank 2
    input   [15:0]  scr1_data,
    output  [17:1]  scr1_addr,
    input           scr1_ok,
    input   [15:0]  scr2_data,
    output  [15:1]  scr2_addr,
    input           scr2_ok,
    // bank 3
    input   [15:0]  obj_data,
    output  [17:1]  obj_addr,
    input           obj_ok,
    // game20k: taps for the RetroAchievements mirror and the palette index
    output          mir_ram_we,
    output  [12:0]  mir_ab,
    output  [ 7:0]  mir_dout,
    output  [ 7:0]  pal_idx
