// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file game_core.sv
//! @brief Galaga behind the game interface of the platform top (game20k).
//!
//! The platform top (fpga/common/src/game20k_top.sv) knows only this module and game_pkg.
//! Every game folder has a game_core with exactly these ports. Here it wraps Dar's Galaga
//! core (src/rtl_dar) and holds what is Galaga's alone: the DIP switches, the joystick
//! wiring of an upright cabinet, the audio scale, the flat address of its RAMs in the RAM
//! mirror, and the two diagnostic builds ROMVIEW and RAMDIAG.
module game_core #(
    parameter bit ROMVIEW = 0,      //!< diagnostic: show the character ROM instead of the game
    parameter bit RAMDIAG = 0       //!< diagnostic: RAM mirror result bar (src/ram_diag.sv)
)(
    input  wire         clk_core,       //!< 18.5625 MHz
    input  wire         reset,          //!< core reset, held by the top until the ROM is loaded

    //! ---- video in the core raster, blankn = 1 visible, vs active low ----
    output logic [2:0]  video_r,
    output logic [2:0]  video_g,
    output logic [1:0]  video_b,
    output logic        video_blankn,
    output logic        video_vs,
    output logic        video_hs,
    //! ---- audio, two's complement, silence = 0 ----
    output logic signed [15:0] audio,

    //! ---- ROM write port from rom_loader, bit i of rom_wr_en = section i of the manifest ----
    input  wire  [15:0] rom_wr_addr,
    input  wire  [7:0]  rom_wr_data,
    input  wire  [15:0] rom_wr_en,

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

    //! ---- RAM mirror: the harvest delivers the mirror bytes, see rtl_dar/galaga.vhd ----
    input  wire         snap_run,
    input  wire         snap_full,
    output logic        snap_push,
    output logic [7:0]  snap_byte,
    output logic [15:0] snap_frame,
    output logic        snap_harv,
    //! ---- oracle: every write of the game into the mirrored RAM, flat mirror address ----
    output logic        log_we,
    output logic [15:0] log_addr,
    output logic [7:0]  log_data,

    //! ---- diagnostic bar of the RAMDIAG build, in the pixel clock; 0 otherwise ----
    input  wire         clk_pixel,
    input  wire  [10:0] cx,
    input  wire  [9:0]  cy,
    input  wire  [15:0] diag_spi_count,   //!< bytes of the last mirror transfer
    input  wire  [15:0] diag_spi_us,      //!< its duration in microseconds
    input  wire  [7:0]  diag_spi_verdict, //!< the Pico's verdict, 0xA5 = all good
    input  wire  [15:0] diag_rc_us,       //!< rcheevos evaluation time per frame
    input  wire  [15:0] diag_rc_lf,       //!< {loaded conditions, fired achievements}
    input  wire  [7:0]  diag_last_ach,    //!< last fired achievement, 1-based
    output logic        diag_on,
    output logic [23:0] diag_color,
    output logic [5:0]  diag_leds
);
    // ---------------- DIP switches from the menu ----------------
    // The ids are the ones menu.xml uses. The defaults are the menu's defaults, they hold
    // until the Companion sends the saved values at start-up.
    logic [1:0] lives      = 2'd2;    // 3 lives (MAME: 0x80 -> bits 7:6 = 10)
    logic [2:0] bonus      = 3'd2;
    logic [2:0] coinage    = 3'd7;    // 1 coin / 1 play
    logic [1:0] difficulty = 2'd0;    // medium
    logic       demosound  = 1'b1;    // 1 = on, inverted below onto DSW A bit 3
    always_ff @(posedge clk_core)
        if (cfg_we) case (cfg_id)
            "L": lives      <= cfg_val[1:0];
            "B": bonus      <= cfg_val[2:0];
            "C": coinage    <= cfg_val[2:0];
            "F": difficulty <= cfg_val[1:0];
            "M": demosound  <= cfg_val[0];
            default: ;
        endcase

    // DIP switches reach the core only while it is in reset. The menu resets right after
    // a DIP change, so the value goes in during that reset. A menu of one's own (a
    // config.xml on the card) without that reset cannot change lives, bonus, coinage or
    // difficulty in a running game: the change waits for the next reset, which the Pico
    // sees in the reset count. Bit 3 of dip_a = 0: demo sounds on (MAME galaga.cpp).
    logic [7:0] dip_a, dip_b;
    always_ff @(posedge clk_core)
        if (reset) begin
            dip_a <= {1'b1, 1'b1, 1'b1, 1'b1, ~demosound, 1'b1, difficulty};
            dip_b <= {lives, bonus, coinage};
        end

    // ---------------- Controls ----------------
    // An upright cabinet: both players use the one stick, so player 2 in the core gets
    // player 1's controller as well. A second controller adds to it.
    wire left  = p1_dir[1] | p2_dir[1];
    wire right = p1_dir[0] | p2_dir[0];
    wire fire  = p1_fire | p2_fire;
    assign map_bits = {10'd0, start2, start1, coin, fire, right, left};

    // ---------------- The core ----------------
    logic [7:0]  dbg_bgdata;
    logic [8:0]  dbg_hcnt, dbg_vcnt;
    logic [3:0]  dbg_bgbits;
    logic [3:0]  ram_we;          // taps of the game RAM writes: bgram, wram1, wram2, wram3
    logic [10:0] ram_addr;
    logic [7:0]  ram_data;
    logic [15:0] catchup_peak;    // peak fill level of the catch-up queue
    logic [2:0]  core_r, core_g;
    logic [1:0]  core_b;
    logic [9:0]  audio_u10;       // unipolar, silence = 0, at most 817

    // Five taps of the core stay open: dbg_tile_num, dbg_tile_color, dbg_bgaddr, dbg_shadow
    // and dbg_score exist for measurement builds (src/rtl_dar/galaga.vhd) and nothing in this
    // file reads them. The empty parentheses say so on purpose.
    galaga core (
        .clock_18     (clk_core),
        .reset        (reset),
        .video_reset  (reset),
        .dbg_tile_num  (),
        .dbg_tile_color(),
        .dbg_hcnt      (dbg_hcnt),
        .dbg_vcnt      (dbg_vcnt),
        .dbg_bgaddr    (),
        .dbg_bgdata    (dbg_bgdata),
        .dbg_bgbits    (dbg_bgbits),
        .dbg_ram_we    (ram_we),
        .dbg_ram_addr  (ram_addr),
        .dbg_ram_data  (ram_data),
        .dbg_score     (),
        .dbg_shadow    (),
        .snap_run      (snap_run),      .snap_full (snap_full),
        .snap_byte     (snap_byte),     .snap_push (snap_push),
        .snap_frame    (snap_frame),    .dbg_skip  (),
        .dbg_nzmax     (catchup_peak),
        .dbg_harv      (snap_harv),
        .video_r      (core_r),
        .video_g      (core_g),
        .video_b      (core_b),
        .video_clk    (),
        .video_csync  (),
        .video_blankn (video_blankn),
        .video_hs     (video_hs),
        .video_vs     (video_vs),
        .audio        (audio_u10),
        .rom_wr_clk   (clk_core),
        .rom_wr_addr  (rom_wr_addr[13:0]),
        .rom_wr_data  (rom_wr_data),
        .rom_wr_en    (rom_wr_en[10:0]),
        .dip_a        (dip_a),
        .dip_b        (dip_b),
        .b_test       (1'b1),
        .b_svce       (1'b1),
        .coin         (coin),
        .start1       (start1),
        .left1        (left),
        .right1       (right),
        .fire1        (fire),
        .start2       (start2),
        .left2        (left),
        .right2       (right),
        .fire2        (fire)
    );

    // ---------------- Audio: 10 bit unipolar to 16 bit two's complement ----------------
    // The core delivers UNIPOLAR: silence = 0, largest possible value 817
    // (galaga.vhd:423 = 16*cs54xx_1 + 16*cs54xx_2 + snd_audio/2 = 240 + 240 + 337).
    // HDMI wants two's complement per IEC 60958 with silence at 0, hence audio = 64*audio_u10
    // with clipping at 32767, see WHY 64 below.
    //
    // Not {~audio_u10[9], audio_u10[8:0], 6'b0}: that would be 64*audio - 32768, the
    // conversion from offset binary, and assumes silence at 512. The sound would still come
    // out right because the mapping is affine and the sink is AC-coupled, but the idle value
    // would be 0x8000, the digital negative rail, and after the volume gain not even
    // constant: 0 at volume 0 and -32768 at volume 7. Every volume step would shift the
    // stream by up to 30720 LSB: a pop, and no headroom left for the sink.
    //
    // WHY 64 AND NOT 32: learned on the device.
    //
    // 32*audio is arithmetically neat (32*1023 < 32768 holds for EVERY 10-bit value, so no
    // overflow whatever the core may sum up one day), but it costs 6 dB against 64*audio: the
    // AC component is halved. On the device NOTHING is audible over HDMI then: the monitor
    // has a squelch and the quieter signal falls below it. The sigma-delta output on pin 77
    // shows clean sound at the same time (0.07 V mean, fluctuating with explosions), so the
    // core is not the problem.
    //
    // The root problem: with "silence = 0" only half of the number axis is available. The
    // offset binary variant has all of it because it runs from -32768 to +19520, at the price
    // that silence sits on the negative rail and the idle level jumps with the volume.
    //
    // So 64*audio WITH CLIPPING: the full level, silence at 0, and an overflow cannot happen.
    // Clipping starts at audio > 511, which is twenty times the mean of about 25 measured on
    // the device, so it hits only the loudest peaks. And it clips instead of wrapping: too
    // loud becomes loud, not noise. The overflow the 32 is meant to prevent is dealt with.
    wire [16:0] aud_x64 = {1'b0, audio_u10, 6'b0};      // 17 bits, up to 52288, always fits
    assign audio = (aud_x64 > 17'd32767) ? 16'd32767 : aud_x64[15:0];

    // ---------------- Oracle: the flat address of a write in the RAM mirror ----------------
    // The mirror holds bgram 0..2047, then wram1, wram2, wram3 at 1024 each. This is exactly
    // how the snapshot lies on the Pico and exactly how rcheevos computes.
    assign log_we   = |ram_we;
    assign log_data = ram_data;
    assign log_addr = ram_we[3] ? {5'b0, ram_addr[10:0]}
                    : ram_we[2] ? (16'd2048 + {6'd0, ram_addr[9:0]})
                    : ram_we[1] ? (16'd3072 + {6'd0, ram_addr[9:0]})
                    :             (16'd4096 + {6'd0, ram_addr[9:0]});

    // ---------------- Diagnostic: show the character ROM directly (ROMVIEW) ----------------
    // Character c at column x/8, row line/8 (36 x 28 places); layout as in MAME galaga:
    // 16 bytes per character, byte = (x%8 < 4 ? 8 : 0) + row,
    // plane0 = bit (x%4), plane1 = bit 4+(x%4)
    // upper half of the raster: ROM data of the core (bggraphx_do) with our own bit selection
    // lower half of the raster: finished palette bits of the core (bgbits), 0/15 = off
    logic [1:0]  rv_pix, core_pix;
    logic [2:0]  rv_r, rv_g;
    logic [1:0]  rv_b;
    assign core_pix = {dbg_bgdata[4 + dbg_hcnt[1:0]], dbg_bgdata[dbg_hcnt[1:0]]};
    assign rv_pix = (dbg_vcnt[7] == 1'b0) ? core_pix :
                    (dbg_bgbits == 4'd0 || dbg_bgbits == 4'hF) ? 2'd0 : {dbg_bgbits[1] | dbg_bgbits[3], dbg_bgbits[0] | dbg_bgbits[2]};
    always_comb begin
        case (rv_pix)
            2'd0: begin rv_r = 3'd0; rv_g = 3'd0; rv_b = 2'd0; end
            2'd1: begin rv_r = 3'd7; rv_g = 3'd7; rv_b = 2'd3; end
            2'd2: begin rv_r = 3'd7; rv_g = 3'd0; rv_b = 2'd0; end
            default: begin rv_r = 3'd0; rv_g = 3'd7; rv_b = 2'd0; end
        endcase
    end
    assign video_r = ROMVIEW ? rv_r : core_r;
    assign video_g = ROMVIEW ? rv_g : core_g;
    assign video_b = ROMVIEW ? rv_b : core_b;

    // ---------------- Diagnostic: the RAM mirror result bar (RAMDIAG) ----------------
    generate
    if (RAMDIAG) begin : g_ramdiag
        ram_diag diag_i (
            .clk_core(clk_core), .ram_we(ram_we), .ram_addr(ram_addr),
            .ram_data(ram_data), .vcnt(dbg_vcnt),
            .spi_count(diag_spi_count), .spi_us(diag_spi_us), .spi_verdict(diag_spi_verdict),
            .rc_calc_us(diag_rc_us),
            .catchup_peak_and_ach({catchup_peak[7:0], diag_last_ach}),
            .rc_loaded_and_fired(diag_rc_lf),
            .clk_pixel(clk_pixel), .cx(cx), .cy(cy),
            .bar_on(diag_on), .bar_color(diag_color), .leds(diag_leds)
        );
    end else begin : g_no_ramdiag
        assign diag_on = 1'b0; assign diag_color = 24'h000000; assign diag_leds = 6'd0;
    end
    endgenerate
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
