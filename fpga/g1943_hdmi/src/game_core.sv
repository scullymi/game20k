// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file game_core.sv
//! @brief 1943 behind the game interface of the platform top (game20k).
//!
//! Wraps jotego's jt1943_game (fpga/vendor/jtcores, jtcores 548b87b) like g1942_hdmi wraps jt1942:
//! clock enables, eight ROM buses through rom_slots, the PROMs over the loader's write port,
//! the palette index for the platform's palette, the audio mix and the RAM mirror. The scroll
//! graphics and the scroll maps are fetched ahead (tile_prefetch.sv, map_prefetch.sv), so
//! their words are there before jotego's renderers take them.
module game_core #(
    parameter bit ROMVIEW = 0,      //!< accepted for the top's sake, no effect here
    parameter bit RAMDIAG = 0       //!< 1: late map words and scroll samples on the LEDs
)(
    input  wire         clk_core,       //!< 37.125 MHz
    input  wire         reset,          //!< core reset, held by the top until the ROM is loaded

    //! ---- video in the core raster, blankn = 1 visible, vs active low ----
    output logic [3:0]  video_r,        //!< palette index in 3/3/2, game_pkg::PALETTE
    output logic [3:0]  video_g,
    output logic [3:0]  video_b,
    output logic        video_ce,       //!< pixel enable, cen6
    output logic        video_blankn,
    output logic        video_vs,
    output logic        video_hs,
    //! ---- audio, two's complement, silence = 0 ----
    output logic signed [15:0] audio,

    //! ---- ROM write port from rom_loader, bit i of rom_wr_en = section i of the manifest ----
    input  wire  [15:0] rom_wr_addr,
    input  wire  [7:0]  rom_wr_data,
    input  wire  [15:0] rom_wr_en,
    //! ---- word reads from the ROM in SDRAM (rom_sdram.sv) ----
    output logic [21:2] rom_rd_addr,    //!< taken with rom_rd_push
    output logic        rom_rd_push,    //!< one clock per read, only while rom_rd_ready
    input  wire         rom_rd_ready,
    input  wire         rom_rd_valid,   //!< one clock per word, in the order of the pushes
    input  wire  [31:0] rom_rd_data,    //!< valid with rom_rd_valid

    //! ---- menu values from the Companion: one clock of cfg_we per value set ----
    input  wire         cfg_we,
    input  wire  [7:0]  cfg_id,
    input  wire  [7:0]  cfg_val,

    //! ---- controls. Directions {up, down, left, right}, buttons as the menu maps them ----
    input  wire  [3:0]  p1_dir,
    input  wire  [3:0]  p2_dir,
    input  wire         p1_fire,
    input  wire         p2_fire,
    input  wire  [11:0] p1_btns,
    input  wire  [11:0] p2_btns,
    input  wire         coin,
    input  wire         start1,
    input  wire         start2,
    output logic [15:0] map_bits,

    //! ---- RAM mirror ----
    input  wire         snap_run,
    input  wire         snap_full,
    output logic        snap_push,
    output logic [7:0]  snap_byte,
    output logic [15:0] snap_frame,
    output logic        snap_harv,
    output logic        log_we,
    output logic [15:0] log_addr,
    output logic [7:0]  log_data,

    //! ---- diagnostic bar of the RAMDIAG build, in the pixel clock; 0 here ----
    input  wire         clk_pixel,
    input  wire  [10:0] cx,
    input  wire  [9:0]  cy,
    input  wire  [15:0] diag_spi_count,
    input  wire  [15:0] diag_spi_us,
    input  wire  [7:0]  diag_spi_verdict,
    input  wire  [15:0] diag_rc_us,
    input  wire  [15:0] diag_rc_lf,
    input  wire  [7:0]  diag_last_ach,
    output logic        diag_on,
    output logic [23:0] diag_color,
    output logic [5:0]  diag_leds
);
    wire clk = clk_core;
    wire rst = reset;

    // ---------------- DIP switches from the menu ----------------
    // Raw bits of MAME 1943.cpp. DSWA: 7 service (1 off), 6 screen stop (1 off), 5 flip
    // (1 off), 4 two-player cost (1: 2 credits), 3:0 difficulty (8 normal). DSWB: 7 demo
    // sounds, 6 continue, 5:3 coin B, 2:0 coin A, both set from the one coinage entry.
    logic [3:0] difficulty = 4'h8;
    logic [2:0] coinage    = 3'd7;
    always_ff @(posedge clk)
        if (cfg_we) case (cfg_id)
            "F": difficulty <= cfg_val[3:0];
            "C": coinage    <= cfg_val[2:0];
            default: ;
        endcase
    logic [7:0] dsw_a = 8'hF8;
    logic [7:0] dsw_b = 8'hFF;
    always_ff @(posedge clk)
        if (reset) begin
            dsw_a <= {4'hF, difficulty};
            dsw_b <= {2'b11, coinage, coinage};
        end

    // ---------------- Controls, JTFRAME convention: active low ----------------
    // joystick {button 3, button 2, button 1, up, down, left, right}. Button 1 shoots (the
    // platform's fire), button 2 is the bomb: the raw HID button the menu names under K.
    // jt1943_main turns button 3 into "both at once", it is not used here.
    logic [3:0] bomb_btn = 4'd2;
    always_ff @(posedge clk)
        if (cfg_we && cfg_id == "K") bomb_btn <= cfg_val[3:0];
    wire p1_bomb = (bomb_btn != 4'd0) && p1_btns[bomb_btn - 4'd1];
    wire p2_bomb = (bomb_btn != 4'd0) && p2_btns[bomb_btn - 4'd1];
    wire [6:0] joystick1 = ~{1'b0, p1_bomb, p1_fire, p1_dir};
    wire [6:0] joystick2 = ~{1'b0, p2_bomb, p2_fire, p2_dir};
    wire [3:0] coin_n    = ~{3'b000, coin};
    wire [3:0] cab_1p    = ~{2'b00, start2, start1};
    assign map_bits = {7'd0, start2, start1, coin, p1_bomb, p1_fire, p1_dir};

    // ---------------- Clock enables ----------------
    // 12, 6, 3, 1.5 MHz from 37.125 MHz * 32/99 as for 1942. cen12 is the pixel double, cen6
    // the pixel (JTFRAME_PXLCLK=6: both come from outside the game). 8 MHz = * 64/297.
    wire cen12, cen6, cen3, cen1p5, cen8;
    jtframe_gated_cen #(.W(4), .NUM(32), .DEN(99), .MFREQ(37125)) u_cen (
        .rst(rst), .clk(clk), .busy(1'b0),
        .cen({cen1p5, cen3, cen6, cen12}), .fave(), .fworst()
    );
    jtframe_gated_cen #(.W(1), .NUM(64), .DEN(297), .MFREQ(37125)) u_cen8 (
        .rst(rst), .clk(clk), .busy(1'b0),
        .cen(cen8), .fave(), .fworst()
    );

    // ---------------- The game ----------------
    wire [ 3:0] red, green, blue;
    wire [ 7:0] pal_idx;
    wire        LHBL, LVBL, HS, VS;
    wire [ 9:0] psg0, psg1;
    wire signed [15:0] fm0, fm1;
    wire [ 7:0] main_data, snd_data;
    wire [15:0] char_data, map1_data, map2_data, scr1_data, scr2_data, obj_data;
    wire [17:0] main_addr;
    wire [14:0] snd_addr;
    wire [14:1] char_addr, map1_addr, map2_addr;
    wire [17:1] scr1_addr, obj_addr;
    wire [15:1] scr2_addr;
    wire        main_cs, snd_cs, map1_cs, map2_cs;
    wire        main_ok, snd_ok, char_ok, map1_ok, map2_ok, scr1_ok, scr2_ok, obj_ok;
    wire        mir_ram_we;
    wire [12:0] mir_ab;
    wire [ 7:0] mir_dout;

    // The PROMs come over the loader's write port: section 8 of 1943.manifest, the address
    // inside it is prog_addr, whose bits 11:8 jt1943_game decodes into the twelve PROMs.
    localparam int SEC_PROMS = 8;
    wire        prom_we   = rom_wr_en[SEC_PROMS];
    wire [21:0] prog_addr = {6'd0, rom_wr_addr};

    jt1943_game u_game (
        .rst        (rst),          .clk        (clk),
        .rst24      (rst),          .clk24      (1'b0),
        .rst96      (rst),          .clk96      (1'b0),
        .pxl2_cen   (cen12),        .pxl_cen    (cen6),
        .red        (red),          .green      (green),       .blue (blue),
        .LHBL       (LHBL),         .LVBL       (LVBL),        .HS   (HS),  .VS (VS),
        .cab_1p     (cab_1p),       .coin       (coin_n),
        .joystick1  (joystick1),    .joystick2  (joystick2),
        .joystick3  (7'h7f),        .joystick4  (7'h7f),
        .dial_x     (2'd0),         .dial_y     (2'd0),
        .joyana_l1  (16'd0), .joyana_l2 (16'd0), .joyana_l3 (16'd0), .joyana_l4 (16'd0),
        .joyana_r1  (16'd0), .joyana_r2 (16'd0), .joyana_r3 (16'd0), .joyana_r4 (16'd0),
        .snd_en     (6'h3f),        .snd_vol    (8'hff),
        .status     (32'd0),        .dipsw      ({16'hFFFF, dsw_b, dsw_a}),
        .dip_pause  (1'b1),         .dip_test   (1'b1),
        .service    (1'b1),         .tilt       (1'b1),
        // dip_flip turns the video by 180 degrees, the game itself does not see it: 1943
        // then lies like 1942 (screen line of the manifest)
        .dip_flip   (1'b1),         .dip_fxlevel(2'd0),
        .gfx_en     (4'hf),         .debug_bus  (8'd0),        .debug_view (),
        .cen1p5     (cen1p5),       .cen3       (cen3),        .cen6 (cen6),  .cen8 (cen8),
        .psg0       (psg0),         .psg1       (psg1),
        .fm0        (fm0),          .fm1        (fm1),
        .prog_addr  (prog_addr),    .prog_data  (rom_wr_data),
        .prog_we    (1'b0),         .prog_ba    (2'd0),
        .ioctl_addr ({10'd0, rom_wr_addr}), .prom_we (prom_we),
        .ioctl_ram  (1'b0),         .ioctl_cart (1'b0),
        .snd_addr   (snd_addr),     .snd_data   (snd_data),
        .snd_cs     (snd_cs),       .snd_ok     (snd_ok),
        .main_data  (main_data),    .main_cs    (main_cs),
        .main_addr  (main_addr),    .main_ok    (main_ok),
        .char_data  (char_data),    .char_addr  (char_addr),   .char_ok (char_ok),
        .map1_data  (map1_data),    .map1_cs    (map1_cs),
        .map1_addr  (map1_addr),    .map1_ok    (map1_ok),
        .map2_data  (map2_data),    .map2_cs    (map2_cs),
        .map2_addr  (map2_addr),    .map2_ok    (map2_ok),
        .scr1_data  (scr1_data),    .scr1_addr  (scr1_addr),   .scr1_ok (scr1_ok),
        .scr2_data  (scr2_data),    .scr2_addr  (scr2_addr),   .scr2_ok (scr2_ok),
        .obj_data   (obj_data),     .obj_addr   (obj_addr),    .obj_ok  (obj_ok),
        .mir_ram_we (mir_ram_we),   .mir_ab     (mir_ab),      .mir_dout (mir_dout),
        .pal_idx    (pal_idx)
    );

    // ---------------- ROM buses: the image in SDRAM ----------------
    // Byte offsets in the file = jotego's bank starts (cfg/macros.def) plus the bus address.
    // Slot order is priority: the layers first (they draw while the beam runs), the chars and
    // sprites, then the maps and the CPUs, which keep at most one read in flight together.
    // Each scroll layer has two slots that take turns, one for the word it reads, one for the
    // next word of its tile (tile_prefetch.sv). Each map has two slots the same way, one for
    // the word at its address, one for the next 64-pixel column (map_prefetch.sv): the word
    // is there a whole column ahead, so the maps do not need the high priority group.
    localparam int NSLOT = 12;
    localparam int S_S1A = 0, S_S1B = 1, S_S2A = 2, S_S2B = 3, S_CHAR = 4, S_OBJ = 5,
                   S_M1A = 6, S_M1B = 7, S_M2A = 8, S_M2B = 9, S_MAIN = 10, S_SND = 11;
    wire [21:0] off_main = 22'(main_addr);
    wire [21:0] off_snd  = 22'h28000 + 22'(snd_addr);
    wire [21:0] off_char = 22'h30000 + 22'({char_addr, 1'b0});
    wire [21:0] off_map1 = 22'h38000 + 22'({map1_addr, 1'b0});
    wire [21:0] off_map2 = 22'h40000 + 22'({map2_addr, 1'b0});
    wire [21:0] off_scr1 = 22'h48000 + 22'({scr1_addr, 1'b0});
    wire [21:0] off_scr2 = 22'h88000 + 22'({scr2_addr, 1'b0});
    wire [21:0] off_obj  = 22'h98000 + 22'({obj_addr, 1'b0});
    wire [NSLOT-1:0][21:2] slot_addr;
    wire [NSLOT-1:0]       slot_cs, slot_ok;
    wire [NSLOT-1:0][31:0] slot_data;

    wire [1:0][21:2] s1_addr, s2_addr, m1_addr, m2_addr;
    wire [1:0]       s1_cs, s2_cs, m1_cs, m2_cs;
    wire             s1_cur, s2_cur, m1_cur, m2_cur;
    tile_prefetch u_pre1 (.clk(clk), .cs(LVBL), .addr(off_scr1[21:2]),
                          .s_addr(s1_addr), .s_cs(s1_cs), .cur(s1_cur));
    tile_prefetch u_pre2 (.clk(clk), .cs(LVBL), .addr(off_scr2[21:2]),
                          .s_addr(s2_addr), .s_cs(s2_cs), .cur(s2_cur));
    map_prefetch  u_mpre1 (.clk(clk), .cs(map1_cs), .addr(off_map1[21:2]),
                           .s_addr(m1_addr), .s_cs(m1_cs), .cur(m1_cur));
    map_prefetch  u_mpre2 (.clk(clk), .cs(map2_cs), .addr(off_map2[21:2]),
                           .s_addr(m2_addr), .s_cs(m2_cs), .cur(m2_cur));
    assign slot_addr[S_S1A]  = s1_addr[0];      assign slot_cs[S_S1A]  = s1_cs[0];
    assign slot_addr[S_S1B]  = s1_addr[1];      assign slot_cs[S_S1B]  = s1_cs[1];
    assign slot_addr[S_S2A]  = s2_addr[0];      assign slot_cs[S_S2A]  = s2_cs[0];
    assign slot_addr[S_S2B]  = s2_addr[1];      assign slot_cs[S_S2B]  = s2_cs[1];
    assign slot_addr[S_CHAR] = off_char[21:2];  assign slot_cs[S_CHAR] = LVBL;
    assign slot_addr[S_OBJ]  = off_obj[21:2];   assign slot_cs[S_OBJ]  = 1'b1;
    assign slot_addr[S_M1A]  = m1_addr[0];      assign slot_cs[S_M1A]  = m1_cs[0];
    assign slot_addr[S_M1B]  = m1_addr[1];      assign slot_cs[S_M1B]  = m1_cs[1];
    assign slot_addr[S_M2A]  = m2_addr[0];      assign slot_cs[S_M2A]  = m2_cs[0];
    assign slot_addr[S_M2B]  = m2_addr[1];      assign slot_cs[S_M2B]  = m2_cs[1];
    assign slot_addr[S_MAIN] = off_main[21:2];  assign slot_cs[S_MAIN] = main_cs;
    assign slot_addr[S_SND]  = off_snd[21:2];   assign slot_cs[S_SND]  = snd_cs;

    // the slot of each layer and map that holds the word it reads now
    wire [3:0] s1_i = s1_cur ? 4'(S_S1B) : 4'(S_S1A);
    wire [3:0] s2_i = s2_cur ? 4'(S_S2B) : 4'(S_S2A);
    wire [3:0] m1_i = m1_cur ? 4'(S_M1B) : 4'(S_M1A);
    wire [3:0] m2_i = m2_cur ? 4'(S_M2B) : 4'(S_M2A);
    // a prefetch waits while a layer waits for the word it reads now
    wire urgent = (LVBL && !slot_ok[s1_i]) || (LVBL && !slot_ok[s2_i]);
    wire [NSLOT-1:0] slot_hold = NSLOT'({s2_cur ? 1'b0 : urgent, s2_cur ? urgent : 1'b0,
                                         s1_cur ? 1'b0 : urgent, s1_cur ? urgent : 1'b0});

    // the maps and the CPUs (slots 6 to 11) keep at most one read in flight together, so a
    // layer read never queues behind more than one of theirs
    rom_slots #(.N(NSLOT), .AW(22), .HI(6), .LO_MAX(1)) u_slots (
        .clk(clk), .reset(rst),
        .slot_addr(slot_addr), .slot_cs(slot_cs), .slot_hold(slot_hold),
        .slot_ok(slot_ok), .slot_data(slot_data),
        .rd_addr(rom_rd_addr), .rd_push(rom_rd_push), .rd_ready(rom_rd_ready),
        .rd_valid(rom_rd_valid), .rd_data(rom_rd_data),
        .miss()
    );
    wire [31:0] scr1_word = slot_data[s1_i];
    wire [31:0] scr2_word = slot_data[s2_i];
    wire [31:0] map1_word = slot_data[m1_i];
    wire [31:0] map2_word = slot_data[m2_i];
`ifndef CPU_IDEAL
    assign main_data = slot_data[S_MAIN][8*off_main[1:0] +: 8];
    assign snd_data  = slot_data[S_SND][8*off_snd[1:0] +: 8];
    assign main_ok   = slot_ok[S_MAIN];
    assign snd_ok    = slot_ok[S_SND];
`else
    // Simulation only: the CPUs take their bytes straight from the testbench's ROM image, ok
    // at once, so the game runs the same whatever the SDRAM traffic (its wait for ROM data
    // shifts when the CPU writes the screen). The slots read as without it.
    wire [31:0] main_ref = tb_1943.rom[off_main[19:2]];
    wire [31:0] snd_ref  = tb_1943.rom[off_snd[19:2]];
    assign main_data = main_ref[8*off_main[1:0] +: 8];
    assign snd_data  = snd_ref[8*off_snd[1:0] +: 8];
    assign main_ok   = main_cs;
    assign snd_ok    = snd_cs;
`endif
    assign char_data = off_char[1] ? slot_data[S_CHAR][31:16] : slot_data[S_CHAR][15:0];
`ifndef GFX_IDEAL
    assign scr1_data = off_scr1[1] ? scr1_word[31:16] : scr1_word[15:0];
    assign scr2_data = off_scr2[1] ? scr2_word[31:16] : scr2_word[15:0];
`else
    // Simulation only: the scroll layers take their graphics words straight from the
    // testbench's ROM image, for a reference without late graphics samples. The slots and
    // scr1_ok/scr2_ok work as without it.
    wire [31:0] scr1_ref = tb_1943.rom[off_scr1[19:2]];
    wire [31:0] scr2_ref = tb_1943.rom[off_scr2[19:2]];
    assign scr1_data = off_scr1[1] ? scr1_ref[31:16] : scr1_ref[15:0];
    assign scr2_data = off_scr2[1] ? scr2_ref[31:16] : scr2_ref[15:0];
`endif
    assign obj_data  = off_obj[1]  ? slot_data[S_OBJ][31:16]  : slot_data[S_OBJ][15:0];
    assign char_ok   = slot_ok[S_CHAR];
    assign scr1_ok   = slot_ok[s1_i];
    assign scr2_ok   = slot_ok[s2_i];
    assign obj_ok    = slot_ok[S_OBJ];
`ifndef MAP_IDEAL
    assign map1_data = off_map1[1] ? map1_word[31:16] : map1_word[15:0];
    assign map2_data = off_map2[1] ? map2_word[31:16] : map2_word[15:0];
    assign map1_ok   = slot_ok[m1_i];
    assign map2_ok   = slot_ok[m2_i];
`else
    // Simulation only, the reference for a perfect map path: the maps take their words
    // straight from the testbench's ROM image, ok at once. The slots read as without it, so
    // the SDRAM traffic stays the same.
    wire [31:0] map1_ref = tb_1943.rom[off_map1[19:2]];
    wire [31:0] map2_ref = tb_1943.rom[off_map2[19:2]];
    assign map1_data = off_map1[1] ? map1_ref[31:16] : map1_ref[15:0];
    assign map2_data = off_map2[1] ? map2_ref[31:16] : map2_ref[15:0];
    assign map1_ok   = map1_cs;
    assign map2_ok   = map2_cs;
`endif

    // ---------------- Video to the platform ----------------
    assign video_r      = game_pkg::PALETTE ? {pal_idx[7:5], 1'b0} : red;
    assign video_g      = game_pkg::PALETTE ? {pal_idx[4:2], 1'b0} : green;
    assign video_b      = game_pkg::PALETTE ? {pal_idx[1:0], 2'b0} : blue;
    assign video_ce     = cen6;
    assign video_blankn = LHBL & LVBL;
    assign video_vs     = ~VS;
    assign video_hs     = ~HS;

    // ---------------- Audio: two YM2203, each FM plus PSG ----------------
    // Levels after jotego (mem.yaml, audio_mod.yaml): the PSG over its full 10-bit range
    // gives 0.72 Vpp, the FM over its full 16-bit range 0.5 Vpp, both into the sum over about
    // equal resistors. So a PSG at full range is about 1.5 times an FM at full range (MAME
    // weights them 0.15 per SSG channel against 0.10 for the FM, the same direction). Here
    // the two PSG sums without DC by a one-pole high pass like 1942's, times 24, and the FM
    // divided by 4: 1023 * 24 = 24552 against 16384, all on cen3.
    wire signed [24:0] ps_x = $signed({2'b00, {1'b0, psg0} + {1'b0, psg1}, 11'd0});
    logic signed [45:0] ps_dc = '0;
    wire  signed [24:0] ps_hp = ps_x - 25'(ps_dc >>> 21);
    always_ff @(posedge clk)
        if (cen3) ps_dc <= ps_dc + 46'(ps_x) - (ps_dc >>> 21);
    wire signed [17:0] mix = 18'(ps_hp >>> 7) + 18'(ps_hp >>> 8) + 18'(fm0 >>> 2) + 18'(fm1 >>> 2);
    always_ff @(posedge clk)
        audio <= (mix >  18'sd32767) ? 16'sd32767 :
                 (mix < -18'sd32768) ? -16'sd32768 : 16'(mix);

    // ---------------- RAM mirror for RetroAchievements ----------------
    // FBNeo "All Ram" of 1943 (d_1943.cpp MemIndex): 0x0000 main RAM E000-EFFF, 0x1000 sound
    // RAM, 0x1800 character video and colour, 0x2000 the "sprite" RAM F000-FFFF. Set 11961
    // reads only E000-EFFF and F000-F23E, so the mirror is 8832 bytes (to 0x227F) and gets only
    // the main RAM's writes: E000-EFFF to 0x0000+, F000-F27F to 0x2000+. Sound and video RAM
    // stay zero.
    logic       mw_q = 1'b0;
    always_ff @(posedge clk) mw_q <= mir_ram_we;
    wire [13:0] m_flat = mir_ab[12] ? 14'h2000 + 14'(mir_ab[11:0]) : 14'(mir_ab[11:0]);
    wire        m_in   = !mir_ab[12] || mir_ab[11:0] < 12'h280;
    logic lvbl_q = 1'b0;
    always_ff @(posedge clk) lvbl_q <= LVBL;

    g1943_mirror #(.N(8832)) u_mirror (
        .clk(clk), .reset(rst), .frame_go(lvbl_q && !LVBL),
        .m_ev(mir_ram_we && !mw_q && m_in), .m_flat(m_flat), .m_data(mir_dout),
        .s_ev(1'b0), .s_flat(14'd0), .s_data(8'd0),
        .snap_run(snap_run), .snap_full(snap_full),
        .snap_push(snap_push), .snap_byte(snap_byte), .snap_frame(snap_frame),
        .snap_harv(snap_harv),
        .log_we(log_we), .log_addr(log_addr), .log_data(log_data)
    );

    // ---------------- Diagnosis: late scroll samples on the board ----------------
    // jtgng_tile4 sets a new word address on a cen6 and takes the data on every fourth cen6
    // after it, without looking at ok. A sample is late when the layer's slot is not ok then.
    // The address change shows here one clock after that cen6, so the phase restarts there.
    // Counted in the visible picture, d_late1/2 for the testbench, d_tot for the LEDs.
    logic [21:2] d_a1 = '0, d_a2 = '0;
    logic [3:0]  d_ph1 = '0, d_ph2 = '0;
    logic [8:0]  d_tot = '0;
    int unsigned d_late1 = 0, d_late2 = 0;
    wire d_vis = LHBL && LVBL && !rst;
    always_ff @(posedge clk) begin
        d_a1 <= off_scr1[21:2];
        d_a2 <= off_scr2[21:2];
        if (off_scr1[21:2] != d_a1) d_ph1 <= 4'd0; else if (cen6) d_ph1 <= d_ph1 + 4'd1;
        if (off_scr2[21:2] != d_a2) d_ph2 <= 4'd0; else if (cen6) d_ph2 <= d_ph2 + 4'd1;
        if (cen6 && d_ph1[1:0] == 2'd3 && d_vis && !scr1_ok) begin
            d_late1 <= d_late1 + 1;
            d_tot   <= d_tot + 9'd1;
        end
        if (cen6 && d_ph2[1:0] == 2'd3 && d_vis && !scr2_ok) begin
            d_late2 <= d_late2 + 1;
            d_tot   <= d_tot + 9'd1;
        end
    end

    // ---------------- Diagnosis: late map words on the board ----------------
    // jt1943_map sets a new map address on a cen6, jtgng_tile4 takes the tile code on the
    // third cen6 after it from the map cache, whose read is registered: the word must have
    // been written (ok) two clocks before. A map word is late when ok was not high since the
    // address changed by then. Only a change of the 32-bit word can be late: within the word
    // ok stays high. The address change shows here one clock after its cen6, the count of
    // cen6 starts there. Armed at the first vertical blank after the reset: the slots start
    // empty, the first words of the first line are always late. d_mlate1/2 count for the
    // testbench.
    logic [21:2] dm_a1 = '0, dm_a2 = '0;
    logic [1:0]  dm_n1 = '0, dm_n2 = '0;        // cen6 since the change, 3 = past the take
    logic        dm_p1 = 1'b0, dm_p2 = 1'b0;    // no ok since the change
    logic        dm_q1 = 1'b0, dm_q2 = 1'b0;    // the same, one clock older
    logic        dm_s1 = 1'b0, dm_s2 = 1'b0, dm_tog = 1'b0;
    logic        dm_on = 1'b0, dm_lvbl_q = 1'b0;
    int unsigned d_mlate1 = 0, d_mlate2 = 0;
    wire dm_l1 = cen6 && dm_n1 == 2'd2 && dm_q1 && d_vis && dm_on;   // a late word taken now
    wire dm_l2 = cen6 && dm_n2 == 2'd2 && dm_q2 && d_vis && dm_on;
    always_ff @(posedge clk) begin
        dm_lvbl_q <= LVBL;
        if (rst) dm_on <= 1'b0; else if (dm_lvbl_q && !LVBL) dm_on <= 1'b1;
        dm_a1 <= off_map1[21:2];
        dm_a2 <= off_map2[21:2];
        if (off_map1[21:2] != dm_a1) dm_n1 <= 2'd0;
        else if (cen6 && dm_n1 != 2'd3) dm_n1 <= dm_n1 + 2'd1;
        if (off_map2[21:2] != dm_a2) dm_n2 <= 2'd0;
        else if (cen6 && dm_n2 != 2'd3) dm_n2 <= dm_n2 + 2'd1;
        if (off_map1[21:2] != dm_a1) dm_p1 <= !map1_ok; else if (map1_ok) dm_p1 <= 1'b0;
        if (off_map2[21:2] != dm_a2) dm_p2 <= !map2_ok; else if (map2_ok) dm_p2 <= 1'b0;
        dm_q1 <= dm_p1;
        dm_q2 <= dm_p2;
        if (dm_l1) d_mlate1 <= d_mlate1 + 1;
        if (dm_l2) d_mlate2 <= d_mlate2 + 1;
        if (rst) begin
            dm_s1 <= 1'b0;
            dm_s2 <= 1'b0;
        end else begin
            if (dm_l1) dm_s1 <= 1'b1;
            if (dm_l2) dm_s2 <= 1'b1;
            if (dm_l1 || dm_l2) dm_tog <= ~dm_tog;
        end
    end

    // With RAMDIAG, diag_leds[0] = LED1, 1 = on:
    //   LED1  a late map word on scroll 1 since the reset
    //   LED2  a late map word on scroll 2 since the reset
    //   LED3  toggles at every late map word (both layers)
    //   LED4..6  bits 4, 6 and 8 of the late scroll samples of both layers, LED4 changes
    //         every 16 of them
    assign diag_on    = 1'b0;
    assign diag_color = 24'd0;
    assign diag_leds  = RAMDIAG ? {d_tot[8], d_tot[6], d_tot[4], dm_tog, dm_s2, dm_s1} : 6'd0;
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
