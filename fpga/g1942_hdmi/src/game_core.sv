// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file game_core.sv
//! @brief 1942 behind the game interface of the platform top (game20k).
//!
//! The platform top (fpga/common/src/game20k_top.sv) knows only this module and game_pkg.
//! Here it wraps jotego's jt1942_game (src/jtcores, see its README.md) and stands in for
//! what JTFRAME's generated top would put around it: the clock enables, the tmap block RAM
//! and the five ROM buses. It also holds what is 1942's alone: the DIP switches, the
//! controls and the audio mix.
//!
//! Four ROM buses read the ROM image in SDRAM through rom_slots (fpga/common). The
//! character ROM and the PROMs come over the loader's write port into block RAM.
//!
//! The RAM mirror for RetroAchievements is g1942_mirror.sv, fed from CPU write taps.
module game_core #(
    parameter bit ROMVIEW = 0,      //!< accepted for the top's sake, no effect here
    parameter bit RAMDIAG = 0       //!< accepted for the top's sake, no effect here
)(
    input  wire         clk_core,       //!< 37.125 MHz
    input  wire         reset,          //!< core reset, held by the top until the ROM is loaded

    //! ---- video in the core raster, blankn = 1 visible, vs active low ----
    output logic [3:0]  video_r,        //!< 4/4/4 from the colour PROMs
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
    //! ---- word reads from the ROM in SDRAM (rom_sdram.sv), for a manifest with sdram sections ----
    output logic [21:2] rom_rd_addr,
    output logic        rom_rd_req,     //!< toggle: read rom_rd_addr
    input  wire         rom_rd_ack,     //!< equals rom_rd_req once rom_rd_data holds the word
    input  wire  [31:0] rom_rd_data,

    //! ---- menu values from the Companion: one clock of cfg_we per value set ----
    input  wire         cfg_we,
    input  wire  [7:0]  cfg_id,
    input  wire  [7:0]  cfg_val,

    //! ---- controls. Directions {up, down, left, right}, buttons as the menu maps them ----
    input  wire  [3:0]  p1_dir,
    input  wire  [3:0]  p2_dir,
    input  wire         p1_fire,
    input  wire         p2_fire,
    input  wire  [11:0] p1_btns,        //!< raw HID buttons 1..12, for games with more buttons
    input  wire  [11:0] p2_btns,
    input  wire         coin,
    input  wire         start1,
    input  wire         start2,
    output logic [15:0] map_bits,       //!< the game signals, shown on the input test bar

    //! ---- RAM mirror: the harvest delivers the mirror bytes, see g1942_mirror.sv ----
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
    // The ids are the ones menu.xml uses, the values are the raw bits of MAME 1942.cpp. The
    // defaults are MAME's and the menu's: 1 coin 1 credit, bonus 20K 80K 80K+, 3 lives,
    // normal difficulty. The RetroAchievements set 11960 checks no DIP switch.
    // DSWA: 7:6 lives, 5:4 bonus, 3 cabinet (0 upright), 2:0 coin A.
    // DSWB: 7 screen stop (1 off), 6:5 difficulty, 4 flip (1 off), 3 service (1 off),
    //       2:0 coin B, set like coin A.
    logic [1:0] lives      = 2'd3;
    logic [1:0] bonus      = 2'd3;
    logic [2:0] coinage    = 3'd7;
    logic [1:0] difficulty = 2'd3;
    always_ff @(posedge clk)
        if (cfg_we) case (cfg_id)
            "L": lives      <= cfg_val[1:0];
            "B": bonus      <= cfg_val[1:0];
            "C": coinage    <= cfg_val[2:0];
            "F": difficulty <= cfg_val[1:0];
            default: ;
        endcase

    // DIP switches reach the core only while it is in reset: every DIP list in menu.xml
    // carries action="reset", and the top holds reset for at least 255 clocks.
    logic [7:0] dsw_a = 8'hF7;
    logic [7:0] dsw_b = 8'hFF;
    always_ff @(posedge clk)
        if (reset) begin
            dsw_a <= {lives, bonus, 1'b0, coinage};
            dsw_b <= {1'b1, difficulty, 1'b1, 1'b1, coinage};
        end

    // ---------------- Controls, JTFRAME convention: active low ----------------
    // joystick {button 2, button 1, up, down, left, right}. Button 1 fires (the platform's
    // fire, menu id A), button 2 is the loop: the raw HID button the menu names under K,
    // 1..12, 0 for none. coin and cab_1p carry one bit per player, only player 1 has a coin.
    logic [3:0] loop_btn = 4'd2;
    always_ff @(posedge clk)
        if (cfg_we && cfg_id == "K") loop_btn <= cfg_val[3:0];
    wire p1_loop = (loop_btn != 4'd0) && p1_btns[loop_btn - 4'd1];
    wire p2_loop = (loop_btn != 4'd0) && p2_btns[loop_btn - 4'd1];
    wire [5:0] joystick1 = ~{p1_loop, p1_fire, p1_dir};
    wire [5:0] joystick2 = ~{p2_loop, p2_fire, p2_dir};
    wire [3:0] coin_n    = ~{3'b000, coin};
    wire [3:0] cab_1p    = ~{2'b00, start2, start1};
    assign map_bits = {7'd0, start2, start1, coin, p1_loop, p1_fire, p1_dir};

    // ---------------- Clock enables: 12, 6, 3, 1.5 MHz ----------------
    // 37.125 MHz * 32 / 99 = 12.000 MHz exactly, the slower ones are halvings of it. The
    // same module JTFRAME's generator puts in (template game_sdram.v). The spacing jitters by
    // one clock: cen6 comes every 6 or 7 clocks.
    wire cen12, cen6, cen3, cen1p5;
    jtframe_gated_cen #(.W(4), .NUM(32), .DEN(99), .MFREQ(37125)) u_cen (
        .rst(rst), .clk(clk), .busy(1'b0),
        .cen({cen1p5, cen3, cen6, cen12}), .fave(), .fworst()
    );

    // ---------------- The game ----------------
    wire [ 3:0] red, green, blue;
    wire        LHBL, LVBL, HS, VS, pxl2_cen, pxl_cen;
    wire [ 9:0] psg0, psg1;
    wire [10:1] tmap_addr, chram_addr;
    wire [15:0] tmap_dout, chram_din, chram_o16;
    wire [ 1:0] chram_we;
    wire [ 7:0] main_data, snd_data;
    wire [15:0] char_data, obj_data;
    wire [31:0] scr_data;
    wire [16:0] main_addr;
    wire [14:0] snd_addr;
    wire [12:1] char_addr;
    wire [15:1] obj_addr;
    wire [15:2] scr_addr;
    wire        main_cs, snd_cs, main_ok, snd_ok, char_ok, obj_ok, scr_ok;
    wire        mir_ram_we, mir_char_cs, mir_scr_cs, mir_obj_cs, mir_wr_n, mir_snd_we;
    wire [12:0] mir_ab;
    wire [10:0] mir_snd_addr;
    wire [ 7:0] mir_dout, mir_snd_dout;

    // The colour and timing PROMs come over the loader's write port: section 5 of
    // 1942.manifest, the address inside it is prog_addr, whose bits 11:8 the game decodes
    // into the ten PROMs. Sections 0 to 4 go to SDRAM.
    localparam int SEC_PROMS = 5;
    wire        prom_we   = rom_wr_en[SEC_PROMS];
    wire [21:0] prog_addr = {6'd0, rom_wr_addr};

    jt1942_game u_game (
        .rst        (rst),          .clk        (clk),
        .rst24      (rst),          .clk24      (1'b0),
        .rst96      (rst),          .clk96      (1'b0),
        .pxl2_cen   (pxl2_cen),     .pxl_cen    (pxl_cen),
        .red        (red),          .green      (green),       .blue (blue),
        .LHBL       (LHBL),         .LVBL       (LVBL),        .HS   (HS),  .VS (VS),
        .cab_1p     (cab_1p),       .coin       (coin_n),
        .joystick1  (joystick1),    .joystick2  (joystick2),
        .joystick3  (6'h3f),        .joystick4  (6'h3f),
        .dial_x     (2'd0),         .dial_y     (2'd0),
        .joyana_l1  (16'd0), .joyana_l2 (16'd0), .joyana_l3 (16'd0), .joyana_l4 (16'd0),
        .joyana_r1  (16'd0), .joyana_r2 (16'd0), .joyana_r3 (16'd0), .joyana_r4 (16'd0),
        .snd_en     (6'h3f),        .snd_vol    (8'hff),
        .status     (32'd0),        .dipsw      ({16'hFFFF, dsw_b, dsw_a}),
        // dip_pause, dip_test, service and tilt are active low: 1 = not pressed
        .dip_pause  (1'b1),         .dip_test   (1'b1),
        .service    (1'b1),         .tilt       (1'b1),
        .dip_flip   (),             .dip_fxlevel(2'd0),
        .gfx_en     (4'hf),         .debug_bus  (8'd0),        .debug_view (),
        .cen1p5     (cen1p5),       .cen3       (cen3),
        .cen6       (cen6),         .cen12      (cen12),
        .psg0       (psg0),         .psg1       (psg1),
        .prog_addr  (prog_addr),    .prog_data  (rom_wr_data),
        .prog_we    (1'b0),         .prog_ba    (2'd0),
        .ioctl_addr ({10'd0, rom_wr_addr}), .prom_we (prom_we),
        // no header byte: game_id stays 0, which is 1942 (not Vulgus, not Higemaru)
        .header     (1'b0),
        .ioctl_ram  (1'b0),         .ioctl_cart (1'b0),
        .not_higemaru(),
        .tmap_addr  (tmap_addr),    .tmap_dout  (tmap_dout),
        .chram_addr (chram_addr),   .chram_din  (chram_din),
        .chram_o16  (chram_o16),    .chram_we   (chram_we),
        .main_data  (main_data),    .main_cs    (main_cs),
        .main_addr  (main_addr),    .main_ok    (main_ok),
        .snd_data   (snd_data),     .snd_cs     (snd_cs),
        .snd_addr   (snd_addr),     .snd_ok     (snd_ok),
        .char_data  (char_data),    .char_addr  (char_addr),   .char_ok (char_ok),
        .obj_data   (obj_data),     .obj_addr   (obj_addr),    .obj_ok  (obj_ok),
        .scr_data   (scr_data),     .scr_addr   (scr_addr),    .scr_ok  (scr_ok),
        // game20k taps for the RAM mirror
        .mir_ram_we (mir_ram_we),   .mir_char_cs(mir_char_cs), .mir_scr_cs(mir_scr_cs),
        .mir_obj_cs (mir_obj_cs),   .mir_wr_n   (mir_wr_n),    .mir_ab    (mir_ab),
        .mir_dout   (mir_dout),
        .mir_snd_we (mir_snd_we),   .mir_snd_addr(mir_snd_addr), .mir_snd_dout(mir_snd_dout)
    );

    // The tmap block RAM with the CPU's chram as the second port, as JTFRAME's generator
    // emits it for mem.yaml: 11-bit byte address, 16 bits wide, 2 KiB
    jtframe_dual_ram16 #(.AW(10)) u_bram_tmap (
        .clk0  (clk), .data0 (16'h0),     .addr0 (tmap_addr),  .we0 (2'd0),     .q0 (tmap_dout),
        .clk1  (clk), .data1 (chram_din), .addr1 (chram_addr), .we1 (chram_we), .q1 (chram_o16)
    );

    // ---------------- Character ROM: block RAM ----------------
    // sr-02, 8 KiB, comes over the loader's write port (section 2 of 1942.manifest, already
    // byte-swapped as JTFRAME stores it) into two byte RAMs, even and odd bytes. The layer
    // takes a new address every 8 pixels and its data 8 pixels later; from SDRAM it came too
    // late now and then (simulated: 516 of 1.3 million fetches with the sprites first in the
    // slot order, 121 with them behind), and jt1942 then draws an empty character: parts of
    // the score digits flickered on the device. From block RAM the word is there one clock
    // after the address, ok follows the address one clock later.
    localparam int SEC_CHARS = 2;
    logic [7:0]  chr_lo [0:4095];
    logic [7:0]  chr_hi [0:4095];
    logic [7:0]  chr_lo_q, chr_hi_q;
    logic [12:1] chr_addr_q;
    always_ff @(posedge clk) begin
        if (rom_wr_en[SEC_CHARS] && !rom_wr_addr[0]) chr_lo[rom_wr_addr[12:1]] <= rom_wr_data;
        if (rom_wr_en[SEC_CHARS] &&  rom_wr_addr[0]) chr_hi[rom_wr_addr[12:1]] <= rom_wr_data;
    end
    always_ff @(posedge clk) begin
        chr_lo_q   <= chr_lo[char_addr];
        chr_hi_q   <= chr_hi[char_addr];
        chr_addr_q <= char_addr;
    end
    assign char_data = {chr_hi_q, chr_lo_q};
    assign char_ok   = LVBL && chr_addr_q == char_addr;

    // ---------------- The other ROM buses: the image in SDRAM ----------------
    // The ROM file lies in SDRAM at its file offsets (1942.manifest): main CPU from 0, sound
    // CPU from 0x14000, sprites from 0x1A000, tiles from 0x2A000, jotego's bank starts. Each
    // bus adds its start to its address; the slot returns the whole 32-bit word, a byte of it
    // lies at 8 * address[1:0]. Slot order is priority: the tiles first, the layer draws a
    // new tile every 8 pixels and has no time to wait; the sprites next, they have a whole
    // line; the CPUs last, they stop until the byte is there.
    // cs for scr is LVBL, for obj always (mem.yaml).
    localparam int NSLOT = 4;
    localparam int S_SCR = 0, S_OBJ = 1, S_MAIN = 2, S_SND = 3;
    wire [21:0] off_main = 22'(main_addr);
    wire [21:0] off_snd  = 22'h14000 + 22'(snd_addr);
    wire [21:0] off_obj  = 22'h1A000 + 22'({obj_addr, 1'b0});
    wire [21:0] off_scr  = 22'h2A000 + 22'({scr_addr, 2'b00});
    wire [NSLOT-1:0][21:2] slot_addr;
    wire [NSLOT-1:0]       slot_cs, slot_ok;
    wire [NSLOT-1:0][31:0] slot_data;
    assign slot_addr[S_SCR]  = off_scr[21:2];   assign slot_cs[S_SCR]  = LVBL;
    assign slot_addr[S_OBJ]  = off_obj[21:2];   assign slot_cs[S_OBJ]  = 1'b1;
    assign slot_addr[S_MAIN] = off_main[21:2];  assign slot_cs[S_MAIN] = main_cs;
    assign slot_addr[S_SND]  = off_snd[21:2];   assign slot_cs[S_SND]  = snd_cs;

    // Guard for the tiles: jtgng_tile3 sets a new address every 8 pixels (HS[2:0] == 1) and
    // takes the data within the next 6 pixels, about 37 clocks. A sprite or CPU read already
    // under way when it asks can cost 20 of them. So no slot behind the tiles starts a read
    // in the last 4 pixels (about 25 clocks) before the next change. The phase is counted
    // from the last address change, modulo 8, so a tile repeated with the same address keeps
    // it. Measured with the latency model: without the guard 10 tiles late in 10 s.
    logic [15:2] scr_addr_q;
    logic [2:0]  scr_px = 3'd0;             // pixels since the last tile address change
    always_ff @(posedge clk) begin
        scr_addr_q <= scr_addr;
        if (scr_addr != scr_addr_q) scr_px <= 3'd0;
        else if (pxl_cen)           scr_px <= scr_px + 3'd1;
    end
    wire scr_soon = LVBL && scr_px[2];       // pixels 4 to 7 of the tile period
    wire [NSLOT-1:0] slot_hold = scr_soon ? ~(NSLOT'(1) << S_SCR) : '0;

    rom_slots #(.N(NSLOT), .AW(22)) u_slots (
        .clk(clk), .reset(rst),
        .slot_addr(slot_addr), .slot_cs(slot_cs), .slot_hold(slot_hold),
        .slot_ok(slot_ok), .slot_data(slot_data),
        .rd_addr(rom_rd_addr), .rd_req(rom_rd_req), .rd_ack(rom_rd_ack), .rd_data(rom_rd_data),
        .miss()
    );
    assign main_data = slot_data[S_MAIN][8*off_main[1:0] +: 8];
    assign snd_data  = slot_data[S_SND][8*off_snd[1:0] +: 8];
    assign obj_data  = off_obj[1]  ? slot_data[S_OBJ][31:16]  : slot_data[S_OBJ][15:0];
    assign scr_data  = slot_data[S_SCR];
    assign main_ok   = slot_ok[S_MAIN];
    assign snd_ok    = slot_ok[S_SND];
    assign obj_ok    = slot_ok[S_OBJ];
    assign scr_ok    = slot_ok[S_SCR];

    // ---------------- Video and audio to the platform ----------------
    assign video_r      = red;
    assign video_g      = green;
    assign video_b      = blue;
    assign video_ce     = pxl_cen;
    assign video_blankn = LHBL & LVBL;
    assign video_vs     = ~VS;
    assign video_hs     = ~HS;
    // ---------------- Audio: the sound board's mix, without DC, filtered for 48 kHz ----------------
    // The board (MAME nl_1942.cpp) mixes the six AY channels with equal weight through 10 uF
    // and 220 kOhm: a passive sum, AC coupled. jt49 gives each AY's three channels as one
    // unsigned 10-bit sum, so the mix is psg0 + psg1, 0..2046. Two things are added for HDMI,
    // all steps on cen3 (3 MHz on average):
    //   - DC removal, a one-pole high pass at 3 MHz / (2 pi 2^21) = 0.23 Hz, the coupling
    //     capacitors' part (10 uF into 220 kOhm, 0.07 Hz on the board). Without it the sum sits
    //     on a DC level and only swings upwards. A corner at 7.3 Hz was tried first: after
    //     every loud noise burst the baseline sagged and crept back, the effects sounded like
    //     a broken speaker (measured against MAME's recording of the same sounds).
    //   - three one-pole low passes at 3 MHz / (2 pi 32) = 14.9 kHz each, before the platform
    //     samples at 48 kHz. The AY's square waves have harmonics far above 24 kHz, which a
    //     plain sample folds back as whistles (measured on the device: lines up to 24 kHz at
    //     -50 to -60 dB). Together -9 dB at 15 kHz, -30 dB at 48 kHz, -48 dB at 96 kHz.
    // Fixed point: x = mix << 11 (up to 2^22), the stage states carry extra fraction bits
    // (21 for the high pass, 5 per low pass) so that small signals do not stick.
    wire signed [24:0] au_x = $signed({2'b00, {1'b0, psg0} + {1'b0, psg1}, 11'd0});
    logic signed [45:0] au_dc = '0;                        // DC level << 21
    wire  signed [24:0] au_hp = au_x - 25'(au_dc >>> 21);  // the signal without DC
    logic signed [29:0] au_s1 = '0, au_s2 = '0, au_s3 = '0; // low pass stages << 5
    always_ff @(posedge clk)
        if (cen3) begin
            au_dc <= au_dc + 46'(au_x) - (au_dc >>> 21);
            au_s1 <= au_s1 + 30'(au_hp)          - (au_s1 >>> 5);
            au_s2 <= au_s2 + 30'(au_s1 >>> 5)    - (au_s2 >>> 5);
            au_s3 <= au_s3 + 30'(au_s2 >>> 5)    - (au_s3 >>> 5);
        end
    // Sound setting (menu id W): 0 original, 1 soft. Soft puts two more one-pole low passes
    // behind, at 3 MHz / (2 pi 128) = 3.7 kHz each, like a cabinet speaker. The music has a
    // square wave near 1.9 kHz on the beat whose harmonics (5.6, 9.4, 13 kHz) sit where the
    // ear is most sensitive: soft takes them down by 10 to 17 dB and the tone by 2 dB, and
    // smooths the noise of the effects. Tried on the device: 2.8 and 1.9 kHz were too dull.
    // Original is the default.
    logic au_soft = 1'b0;
    always_ff @(posedge clk)
        if (cfg_we && cfg_id == "W") au_soft <= (cfg_val != 8'd0);
    logic signed [33:0] au_s4 = '0, au_s5 = '0;                  // extra stages << 7
    always_ff @(posedge clk)
        if (cen3) begin
            au_s4 <= au_s4 + 34'(au_s3 >>> 5) - (au_s4 >>> 7);
            au_s5 <= au_s5 + (au_s4 >>> 7)    - (au_s5 >>> 7);
        end
    // in units of x = mix << 11
    wire signed [29:0] au_lp = au_soft ? 30'(au_s5 >>> 7) : 30'(au_s3 >>> 5);
    // >>> 6 more gives mix << 5, twice the former unipolar scale, which the signal centred
    // on 0 has room for. Saturated to 16 bits.
    wire signed [29:0] au_y = au_lp >>> 6;
    always_ff @(posedge clk)
        audio <= (au_y >  30'sd32767) ? 16'sd32767 :
                 (au_y < -30'sd32768) ? -16'sd32768 : 16'(au_y);

    // ---------------- RAM mirror for RetroAchievements ----------------
    // Every CPU write into one of the five mirrored RAMs becomes one event: the rising edge
    // of the RAM's write condition, with the address in FBNeo's "All Ram" order (see
    // g1942_mirror.sv). The main CPU's writes come from its bus: main RAM E000-EFFF through
    // jt1942_main's own strobe, sprite RAM CC00-CC7F, character RAM D000-D7FF and background
    // RAM D800-DBFF through the chip selects and wr_n. A Z80 write holds wr_n low for at
    // least one T state and raises it before the next, so each write gives exactly one edge.
    wire        mw_ram = mir_ram_we;
    wire        mw_obj = mir_obj_cs  && !mir_wr_n;
    wire        mw_chr = mir_char_cs && !mir_wr_n;
    wire        mw_scr = mir_scr_cs  && !mir_wr_n;
    wire        mw_any = mw_ram || mw_obj || mw_chr || mw_scr;
    logic       mw_q = 1'b0, sw_q = 1'b0;
    logic [13:0] m_flat;
    always_comb
        if      (mw_ram) m_flat = 14'h0000 + 14'(mir_ab[11:0]);
        else if (mw_obj) m_flat = 14'h1800 + 14'(mir_ab[6:0]);
        else if (mw_chr) m_flat = 14'h1880 + 14'(mir_ab[10:0]);
        else             m_flat = 14'h2080 + 14'(mir_ab[9:0]);
    always_ff @(posedge clk) begin
        mw_q <= mw_any;
        sw_q <= mir_snd_we;
    end
    // the snapshot instant: the start of the vertical blank
    logic lvbl_q = 1'b0;
    always_ff @(posedge clk) lvbl_q <= LVBL;

    g1942_mirror #(.N(9344)) u_mirror (
        .clk(clk), .reset(rst), .frame_go(lvbl_q && !LVBL),
        .m_ev(mw_any && !mw_q), .m_flat(m_flat), .m_data(mir_dout),
        .s_ev(mir_snd_we && !sw_q), .s_flat(14'h1000 + 14'(mir_snd_addr)), .s_data(mir_snd_dout),
        .snap_run(snap_run), .snap_full(snap_full),
        .snap_push(snap_push), .snap_byte(snap_byte), .snap_frame(snap_frame),
        .snap_harv(snap_harv),
        .log_we(log_we), .log_addr(log_addr), .log_data(log_data)
    );

    // ---------------- No diagnostics in this folder ----------------
    assign diag_on    = 1'b0;
    assign diag_color = 24'd0;
    assign diag_leds  = 6'd0;
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
