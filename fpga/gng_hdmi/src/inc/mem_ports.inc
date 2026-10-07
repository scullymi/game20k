// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// Ghosts'n Goblins (game20k): the game port list that the jtframe Go tool would
// generate as mem_ports.inc from cores/gng/cfg/mem.yaml (jtcores 548b87b), written by hand
// with the rules of the 1942 and 1943 ports: addr_range [aw-1 : dw>>4], a _cs port only for
// buses without cs: in mem.yaml.
//
// GnG's mem.yaml has no clocks: section, the game makes its enables with jtframe_cen48 from
// a 48 MHz clk. The copy of jtgng_game.v here takes them from these ports instead.
    input cen6, cen3, cen1p5,
    // Audio channels (audio.yaml: jt03_psg 10 bit unsigned, jt03_fm 16 bit signed)
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
    // Buses to SDRAM, bank 0
    input   [ 7:0]  main_data,
    output          main_cs,
    output  [16:0]  main_addr,
    input           main_ok,
    // bank 1
    input   [15:0]  char_data,
    output  [13:1]  char_addr,
    input           char_ok,
    input   [ 7:0]  snd_data,
    output          snd_cs,
    output  [14:0]  snd_addr,
    input           snd_ok,
    // bank 2
    input   [31:0]  scr_data,
    output  [16:2]  scr_addr,
    input           scr_ok,
    // bank 3
    input   [15:0]  obj_data,
    output  [16:1]  obj_addr,
    input           obj_ok,
    // game20k: tap for the RetroAchievements mirror, the writes into the 6809's work RAM
    output          mir_ram_we,
    output  [12:0]  mir_ab,
    output  [ 7:0]  mir_dout
