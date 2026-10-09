// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file game_core.sv
//! @brief Ghosts'n Goblins behind the game interface of the platform top (game20k).
//!
//! Wraps jotego's jtgng_game (fpga/vendor/jtcores, jtcores 548b87b) like g1943_hdmi wraps jt1943:
//! clock enables, five ROM buses through rom_slots, the audio mix and the RAM mirror. The
//! palette is a RAM inside the game, so the core delivers 4/4/4 colour (game_pkg::RGB444)
//! and nothing goes over the loader's write port.
module game_core #(
    parameter bit ROMVIEW = 0,      //!< accepted for the top's sake, no effect here
    parameter bit RAMDIAG = 0       //!< 1: late ROM samples on the LEDs, see the end
)(
    input  wire         clk_core,       //!< 37.125 MHz
    input  wire         reset,          //!< core reset, held by the top until the ROM is loaded

    //! ---- video in the core raster, blankn = 1 visible, vs active low ----
    output logic [3:0]  video_r,        //!< 4/4/4 from the palette RAM, game_pkg::RGB444
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

    // ---------------- DIP switches and core options from the menu ----------------
    // Raw bits of MAME gng.cpp. DSW1: 7 flip (1 off), 6 service (1 off), 5 demo sounds
    // (0 on), 4 coinage affects (1 coin A), 3:0 coinage (F 1C/1C). DSW2: 6:5 difficulty
    // (3 normal), 4:3 bonus (3: 20K 70K every 70K), 2 cabinet (0 upright), 1:0 lives (3: 3).
    // The defaults are jotego's MRA (DF, FB). The switches reach the game only in reset,
    // every DIP list in menu_core.xml resets.
    logic [1:0] difficulty = 2'd3, bonus = 2'd3, lives = 2'd3;
    logic [3:0] coinage    = 4'hF;
    logic       demo_snd   = 1'b0;
    logic       no_flash   = 1'b0;          // jotego's OSD entry "Block yellow flashes"
    always_ff @(posedge clk)
        if (cfg_we) case (cfg_id)
            "F": difficulty <= cfg_val[1:0];
            "B": bonus      <= cfg_val[1:0];
            "L": lives      <= cfg_val[1:0];
            "C": coinage    <= cfg_val[3:0];
            "E": demo_snd   <= cfg_val[0];
            "Y": no_flash   <= cfg_val[0];
            default: ;
        endcase
    logic [7:0] dsw_a = 8'hDF;
    logic [7:0] dsw_b = 8'hFB;
    always_ff @(posedge clk)
        if (reset) begin
            dsw_a <= {2'b11, demo_snd, 1'b1, coinage};
            dsw_b <= {1'b1, difficulty, bonus, 1'b0, lives};
        end

    // ---------------- Controls, JTFRAME convention: active low ----------------
    // joystick {button 2, button 1, up, down, left, right}. Button 1 fires (the platform's
    // fire), button 2 jumps: the raw HID button the menu names under K. Player 2 takes
    // turns on the same cabinet (cocktail ports), MAME and jotego read it from joystick2.
    logic [3:0] jump_btn = 4'd2;
    always_ff @(posedge clk)
        if (cfg_we && cfg_id == "K") jump_btn <= cfg_val[3:0];
    wire p1_jump = (jump_btn != 4'd0) && p1_btns[jump_btn - 4'd1];
    wire p2_jump = (jump_btn != 4'd0) && p2_btns[jump_btn - 4'd1];
    wire [5:0] joystick1 = ~{p1_jump, p1_fire, p1_dir};
    wire [5:0] joystick2 = ~{p2_jump, p2_fire, p2_dir};
    wire [3:0] coin_n    = ~{3'b000, coin};
    wire [3:0] cab_1p    = ~{2'b00, start2, start1};
    assign map_bits = {7'd0, start2, start1, coin, p1_jump, p1_fire, p1_dir};

    // ---------------- Clock enables ----------------
    // 12, 6, 3, 1.5 MHz from 37.125 MHz * 32/99 as for 1942 and 1943. cen12 is the pixel
    // double (sprite drawing), cen6 the pixel and the 6809's input clock (JTFRAME_PXLCLK=6:
    // both pixel enables come from outside the game).
    wire cen12, cen6, cen3, cen1p5;
    jtframe_gated_cen #(.W(4), .NUM(32), .DEN(99), .MFREQ(37125)) u_cen (
        .rst(rst), .clk(clk), .busy(1'b0),
        .cen({cen1p5, cen3, cen6, cen12}), .fave(), .fworst()
    );

    // ---------------- The game ----------------
    wire [ 3:0] red, green, blue;
    wire        LHBL, LVBL, HS, VS;
    wire [ 9:0] psg0, psg1;
    wire signed [15:0] fm0, fm1;
    wire [ 7:0] main_data, snd_data;
    wire [15:0] char_data, obj_data;
    wire [31:0] scr_data;
    wire [16:0] main_addr;
    wire [14:0] snd_addr;
    wire [13:1] char_addr;
    wire [16:2] scr_addr;
    wire [16:1] obj_addr;
    wire        main_cs, snd_cs;
    wire        main_ok, snd_ok, char_ok, scr_ok, obj_ok;
    wire        mir_ram_we;
    wire [12:0] mir_ab;
    wire [ 7:0] mir_dout;

    // The palette RAM gets a start value while the core is in reset, as under JTFRAME,
    // where the SDRAM download drives prog_we: entry i becomes grey level i[3:0]
    // (jtgng_colmix, "fills in a non blank palette"). Without it the power-on test, which
    // runs before the game writes its palette, stays black. The top holds reset for at
    // least 256 clocks, enough for all 256 entries.
    logic [7:0] pal_init = 8'd0;
    always_ff @(posedge clk) pal_init <= rst ? pal_init + 8'd1 : 8'd0;

    jtgng_game u_game (
        .rst        (rst),          .clk        (clk),
        .rst24      (rst),          .clk24      (1'b0),
        .rst96      (rst),          .clk96      (1'b0),
        .pxl2_cen   (cen12),        .pxl_cen    (cen6),
        .red        (red),          .green      (green),       .blue (blue),
        .LHBL       (LHBL),         .LVBL       (LVBL),        .HS   (HS),  .VS (VS),
        .cab_1p     (cab_1p),       .coin       (coin_n),
        .joystick1  (joystick1),    .joystick2  (joystick2),
        .joystick3  (6'h3f),        .joystick4  (6'h3f),
        .dial_x     (2'd0),         .dial_y     (2'd0),
        .joyana_l1  (16'd0), .joyana_l2 (16'd0), .joyana_l3 (16'd0), .joyana_l4 (16'd0),
        .joyana_r1  (16'd0), .joyana_r2 (16'd0), .joyana_r3 (16'd0), .joyana_r4 (16'd0),
        .snd_en     (6'h3f),        .snd_vol    (8'hff),
        .status     ({18'd0, no_flash, 13'd0}),
        .dipsw      ({16'hFFFF, dsw_b, dsw_a}),
        .dip_pause  (1'b1),         .dip_test   (1'b1),
        .service    (1'b1),         .tilt       (1'b1),
        .dip_flip   (),             .dip_fxlevel(2'd0),
        .gfx_en     (4'hf),         .debug_bus  (8'd0),        .debug_view (),
        .cen6       (cen6),         .cen3       (cen3),        .cen1p5 (cen1p5),
        .psg0       (psg0),         .psg1       (psg1),
        .fm0        (fm0),          .fm1        (fm1),
        .prog_addr  ({14'd0, pal_init}), .prog_data (8'd0),
        .prog_we    (rst),          .prog_ba    (2'd0),
        .ioctl_addr (26'd0),        .prom_we    (1'b0),
        .ioctl_ram  (1'b0),         .ioctl_cart (1'b0),
        .main_data  (main_data),    .main_cs    (main_cs),
        .main_addr  (main_addr),    .main_ok    (main_ok),
        .char_data  (char_data),    .char_addr  (char_addr),   .char_ok (char_ok),
        .snd_data   (snd_data),     .snd_cs     (snd_cs),
        .snd_addr   (snd_addr),     .snd_ok     (snd_ok),
        .scr_data   (scr_data),     .scr_addr   (scr_addr),    .scr_ok  (scr_ok),
        .obj_data   (obj_data),     .obj_addr   (obj_addr),    .obj_ok  (obj_ok),
        .mir_ram_we (mir_ram_we),   .mir_ab     (mir_ab),      .mir_dout (mir_dout)
    );

    // ---------------- ROM buses: the image in SDRAM ----------------
    // Byte offsets in the file = jotego's bank starts (cfg/macros.def) plus the bus address.
    // Slot order is priority: the layers first (they draw while the beam runs), then the
    // sprites, the CPUs last (they wait). The chip selects are mem.yaml's: char and scr read
    // in the visible lines only, obj always.
    localparam int NSLOT = 5;
    localparam int S_SCR = 0, S_CHAR = 1, S_OBJ = 2, S_MAIN = 3, S_SND = 4;
    wire [21:0] off_main = 22'(main_addr);
    wire [21:0] off_char = 22'h14000 + 22'({char_addr, 1'b0});
    wire [21:0] off_snd  = 22'h18000 + 22'(snd_addr);
    wire [21:0] off_scr  = 22'h20000 + 22'({scr_addr, 2'b00});
    wire [21:0] off_obj  = 22'h40000 + 22'({obj_addr, 1'b0});
    wire [NSLOT-1:0][21:2] slot_addr;
    wire [NSLOT-1:0]       slot_cs, slot_ok;
    wire [NSLOT-1:0][31:0] slot_data;
    assign slot_addr[S_SCR]  = off_scr[21:2];   assign slot_cs[S_SCR]  = LVBL;
    assign slot_addr[S_CHAR] = off_char[21:2];  assign slot_cs[S_CHAR] = LVBL;
    assign slot_addr[S_OBJ]  = off_obj[21:2];   assign slot_cs[S_OBJ]  = 1'b1;
    assign slot_addr[S_MAIN] = off_main[21:2];  assign slot_cs[S_MAIN] = main_cs;
    assign slot_addr[S_SND]  = off_snd[21:2];   assign slot_cs[S_SND]  = snd_cs;

    rom_slots #(.N(NSLOT), .AW(22)) u_slots (
        .clk(clk), .reset(rst),
        .slot_addr(slot_addr), .slot_cs(slot_cs), .slot_hold('0),
        .slot_ok(slot_ok), .slot_data(slot_data),
        .rd_addr(rom_rd_addr), .rd_push(rom_rd_push), .rd_ready(rom_rd_ready),
        .rd_valid(rom_rd_valid), .rd_data(rom_rd_data),
        .miss()
    );
    assign main_data = slot_data[S_MAIN][8*off_main[1:0] +: 8];
    assign snd_data  = slot_data[S_SND][8*off_snd[1:0] +: 8];
    assign char_data = off_char[1] ? slot_data[S_CHAR][31:16] : slot_data[S_CHAR][15:0];
    assign scr_data  = slot_data[S_SCR];
    assign obj_data  = off_obj[1]  ? slot_data[S_OBJ][31:16]  : slot_data[S_OBJ][15:0];
    assign main_ok   = slot_ok[S_MAIN];
    assign snd_ok    = slot_ok[S_SND];
    assign char_ok   = slot_ok[S_CHAR];
    assign scr_ok    = slot_ok[S_SCR];
    assign obj_ok    = slot_ok[S_OBJ];

    // ---------------- Video to the platform ----------------
    assign video_r      = red;
    assign video_g      = green;
    assign video_b      = blue;
    assign video_ce     = cen6;
    assign video_blankn = LHBL & LVBL;
    assign video_vs     = ~VS;
    assign video_hs     = ~HS;

    // ---------------- Audio: two YM2203, each FM plus PSG ----------------
    // As 1943 (game_core.sv there): the two PSG sums without DC by a one-pole high pass,
    // times 24. jotego's resistors weigh the PSG against the FM about twice as heavily in
    // GnG as in 1943 (audio.yaml: PSG 4.9k, FM 10k, against 56k and 50k), so the FM is
    // divided by 8 instead of 4.
    wire signed [24:0] ps_x = $signed({2'b00, {1'b0, psg0} + {1'b0, psg1}, 11'd0});
    logic signed [45:0] ps_dc = '0;
    wire  signed [24:0] ps_hp = ps_x - 25'(ps_dc >>> 21);
    always_ff @(posedge clk)
        if (cen3) ps_dc <= ps_dc + 46'(ps_x) - (ps_dc >>> 21);
    wire signed [17:0] mix = 18'(ps_hp >>> 7) + 18'(ps_hp >>> 8) + 18'(fm0 >>> 3) + 18'(fm1 >>> 3);
    always_ff @(posedge clk)
        audio <= (mix >  18'sd32767) ? 16'sd32767 :
                 (mix < -18'sd32768) ? -16'sd32768 : 16'(mix);

    // ---------------- RAM mirror for RetroAchievements ----------------
    // FBNeo "All Ram" of GnG (d_gng.cpp MemIndex) starts with the 6809's work RAM at
    // 0x0000-0x1DFF, flat address = CPU address. Set 12149 reads only inside it, up to
    // 0x1605, so the mirror is 5760 bytes (0x1680, 45 pages of 128) and gets only the 6809's
    // RAM writes. The sound, video and palette RAMs behind it are not part of it. The strobe
    // is one clock per write.
    localparam int MIRROR_N = 5760;
    logic lvbl_q = 1'b0;
    always_ff @(posedge clk) lvbl_q <= LVBL;

    mirror_n #(.N(MIRROR_N)) u_mirror (
        .clk(clk), .reset(rst), .frame_go(lvbl_q && !LVBL),
        .m_ev(mir_ram_we), .m_flat({2'b00, mir_ab}), .m_data(mir_dout),
        .s_ev(1'b0), .s_flat(15'd0), .s_data(8'd0),
        .snap_run(snap_run), .snap_full(snap_full),
        .snap_push(snap_push), .snap_byte(snap_byte), .snap_frame(snap_frame),
        .snap_harv(snap_harv),
        .log_we(log_we), .log_addr(log_addr), .log_data(log_data)
    );

    // ---------------- Diagnosis: late ROM data on the board ----------------
    // jtgng_tile3 sets a new word address at the cen6 with HS[2:0] == 1, takes the data in
    // any clock with ok while HS[2:0] is 3..7 and uses it at the next HS[2:0] == 2. A tile is
    // late when no clock of that window had ok. jtgng_char works the same way on Hfix[2:0].
    // The address change shows here one clock after its cen6 (HS is 2 then), so a phase
    // counter restarts there: phase 1..5 is HS 3..7, and the window closes with the cen6 at
    // phase 5. An address that does not change keeps its word, nothing to count then.
    // Counted in the visible picture. With RAMDIAG LED1..3 show the scroll count of the last
    // frame (0..7), LED4..6 bits 4, 6 and 8 of the running total of scroll and characters.
    // d_late_scr and d_late_chr count for the testbench.
    logic [21:2] d_as = '0, d_ac = '0;
    logic [3:0]  d_ps = '1, d_pc = '1;
    logic        d_sseen = 1'b0, d_cseen = 1'b0;
    logic [2:0]  d_n = '0, d_f = '0;
    logic        d_lvbl_q = 1'b0;
    logic [8:0]  d_tot = '0;
    int unsigned d_late_scr = 0, d_late_chr = 0;
    wire d_vis = LHBL && LVBL && !rst;
    wire d_swin = d_ps >= 4'd1 && d_ps <= 4'd5;
    wire d_cwin = d_pc >= 4'd1 && d_pc <= 4'd5;
    always_ff @(posedge clk) begin
        d_as <= off_scr[21:2];
        d_ac <= off_char[21:2];
        if (off_scr[21:2] != d_as)       d_ps <= 4'd0;
        else if (cen6 && d_ps != 4'd15)  d_ps <= d_ps + 4'd1;
        if (off_char[21:2] != d_ac)      d_pc <= 4'd0;
        else if (cen6 && d_pc != 4'd15)  d_pc <= d_pc + 4'd1;
        if (off_scr[21:2] != d_as)       d_sseen <= 1'b0;
        else if (d_swin && scr_ok)       d_sseen <= 1'b1;
        if (off_char[21:2] != d_ac)      d_cseen <= 1'b0;
        else if (d_cwin && char_ok)      d_cseen <= 1'b1;
        if (cen6 && d_ps == 4'd5 && !d_sseen && !scr_ok && d_vis) begin
            if (d_n != 3'd7) d_n <= d_n + 3'd1;
            d_late_scr <= d_late_scr + 1;
            d_tot      <= d_tot + 9'd1;
        end
        if (cen6 && d_pc == 4'd5 && !d_cseen && !char_ok && d_vis) begin
            d_late_chr <= d_late_chr + 1;
            d_tot      <= d_tot + 9'd1;
        end
        // a frame ends where the vertical blank starts
        d_lvbl_q <= LVBL;
        if (d_lvbl_q && !LVBL) begin
            d_f <= d_n;
            d_n <= 3'd0;
        end
    end

    assign diag_on    = 1'b0;
    assign diag_color = 24'd0;
    assign diag_leds  = RAMDIAG ? {d_tot[8], d_tot[6], d_tot[4], d_f} : 6'd0;
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
