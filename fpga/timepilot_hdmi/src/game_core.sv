// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file game_core.sv
//! @brief Time Pilot behind the game interface of the platform top (game20k).
//!
//! Wraps Ace's TimePilot (src/rtl_timepilot, MiSTer-devel/Arcade-TimePilot_MiSTer 5a148e2,
//! MIT) and holds what the MiSTer top did around it: DIP switches, controls, ROM download.
//! The program ROM (tm1-tm3) is read from SDRAM through one rom_slots slot, everything
//! else comes over the loader's write port into the core's own ROMs. The RAM mirror for
//! RetroAchievements is tp_mirror.sv (1942's, sized for the 2 KB work RAM).
module game_core #(
    parameter bit ROMVIEW = 0,      //!< accepted for the top's sake, no effect here
    parameter bit RAMDIAG = 0       //!< accepted for the top's sake, no effect here
)(
    input  wire         clk_core,       //!< 37.125 MHz
    input  wire         reset,          //!< core reset, held by the top until the ROM is loaded

    //! ---- video in the core raster, blankn = 1 visible, vs active low ----
    output logic [3:0]  video_r,        //!< 4/4/4, game_pkg::RGB444
    output logic [3:0]  video_g,
    output logic [3:0]  video_b,
    output logic        video_ce,       //!< pixel enable, cen_6m
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
    input  wire  [11:0] p1_btns,        //!< raw HID buttons 1..12, for games with more buttons
    input  wire  [11:0] p2_btns,
    input  wire         coin,
    input  wire         start1,
    input  wire         start2,
    output logic [15:0] map_bits,       //!< the game signals, shown on the input test bar

    //! ---- RAM mirror: the harvest delivers the mirror bytes, see tp_mirror.sv ----
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

    // ---------------- DIP switches from the menu ----------------
    // The ids are the ones menu.xml uses, the values are the raw bits of MAME timeplt.cpp.
    // The defaults are MAME's: 1 coin 1 credit, 3 lives, upright, bonus 10000 50000,
    // difficulty 4, demo sounds on.
    // DSW0: 7:4 coin B, 3:0 coin A, both set from the one coinage entry.
    // DSW1: 7 demo sounds (0 on), 6:4 difficulty, 3 bonus, 2 cabinet (0 upright), 1:0 lives.
    logic [1:0] lives      = 2'd3;
    logic       bonus      = 1'b1;
    logic [3:0] coinage    = 4'hF;
    logic [2:0] difficulty = 3'd4;
    always_ff @(posedge clk)
        if (cfg_we) case (cfg_id)
            "L": lives      <= cfg_val[1:0];
            "B": bonus      <= cfg_val[0];
            "C": coinage    <= cfg_val[3:0];
            "F": difficulty <= cfg_val[2:0];
            default: ;
        endcase

    // DIP switches reach the core only while it is in reset, as with 1942
    logic [15:0] dip_sw = 16'h4BFF;
    always_ff @(posedge clk)
        if (reset) dip_sw <= {1'b0, difficulty, bonus, 1'b0, lives, coinage, coinage};

    // ---------------- Controls, active low as in the MiSTer top ----------------
    // Ace's joystick bits are {right, left, down, up}, ours {up, down, left, right}. Only
    // player 1 has a coin.
    wire [3:0] p1_joy_n = ~{p1_dir[0], p1_dir[1], p1_dir[2], p1_dir[3]};
    wire [3:0] p2_joy_n = ~{p2_dir[0], p2_dir[1], p2_dir[2], p2_dir[3]};
    assign map_bits = {8'd0, start2, start1, coin, p1_fire, p1_dir};

    // ---------------- ROM download ----------------
    // Section 1 of timeplt.manifest is the core's download image from 0x6000 on (tm6, tm4,
    // tm5, tm7, the four PROMs). Ace's selector decodes the full download address.
    localparam int SEC_GFX = 1;
    wire [24:0] ioctl_addr = 25'h6000 + 25'(rom_wr_addr);
    wire        ioctl_wr   = rom_wr_en[SEC_GFX];

    // ---------------- Program ROM: SDRAM ----------------
    // Section 0 lies in SDRAM at file offset 0, the Z80 address is the file offset. One slot
    // keeps the last 32-bit word, so straight-line code costs one SDRAM read per four bytes.
    wire [14:0] cpu_rom_addr;
    wire        cpu_rom_cs;
    wire [21:0] rom_off = 22'(cpu_rom_addr);
    wire [0:0][21:2] slot_addr = rom_off[21:2];
    wire [0:0]       slot_cs   = cpu_rom_cs;
    wire [0:0]       slot_ok;
    wire [0:0][31:0] slot_data;
    rom_slots #(.N(1), .AW(22)) u_slots (
        .clk(clk), .reset(reset),
        .slot_addr(slot_addr), .slot_cs(slot_cs), .slot_hold(1'b0),
        .slot_ok(slot_ok), .slot_data(slot_data),
        .rd_addr(rom_rd_addr), .rd_push(rom_rd_push), .rd_ready(rom_rd_ready),
        .rd_valid(rom_rd_valid), .rd_data(rom_rd_data),
        .miss()
    );
    wire [7:0] cpu_rom_din = slot_data[0][8*rom_off[1:0] +: 8];

    // ---------------- The game ----------------
    wire [4:0] red, green, blue;
    wire       hsync_n, vsync_n, hblank, vblank, ce_pix;
    wire signed [15:0] sound;
    wire       mir_we;
    wire [10:0] mir_addr;
    wire [7:0] mir_data;

    TimePilot u_tp (
        .reset(~reset),
        .clk_49m(clk),
        .coin({1'b1, ~coin}),
        .start_buttons({~start2, ~start1}),
        .p1_joystick(p1_joy_n), .p2_joystick(p2_joy_n),
        .p1_fire(~p1_fire), .p2_fire(~p2_fire),
        .btn_service(1'b1),
        .dip_sw(dip_sw),
        .video_hsync(hsync_n), .video_vsync(vsync_n), .video_csync(),
        .video_hblank(hblank), .video_vblank(vblank),
        .ce_pix(ce_pix),
        .video_r(red), .video_g(green), .video_b(blue),
        .sound(sound),
        .h_center(4'd0), .v_center(4'd0),
        .ioctl_addr(ioctl_addr), .ioctl_data(rom_wr_data), .ioctl_wr(ioctl_wr),
        .pause(1'b0),
        .underclock(1'b0),
        .hs_address(16'd0), .hs_data_in(8'd0), .hs_data_out(), .hs_write(1'b0),
        .rom_addr(cpu_rom_addr), .rom_cs(cpu_rom_cs),
        .rom_din(cpu_rom_din), .rom_ok(slot_ok[0]),
        .mir_we(mir_we), .mir_addr(mir_addr), .mir_data(mir_data)
    );

    // ---------------- Video and audio to the platform ----------------
    assign video_r      = red[4:1];
    assign video_g      = green[4:1];
    assign video_b      = blue[4:1];
    assign video_ce     = ce_pix;
    assign video_blankn = ~(hblank | vblank);
    assign video_vs     = vsync_n;
    assign video_hs     = hsync_n;
    always_ff @(posedge clk) audio <= sound;

    // ---------------- RAM mirror for RetroAchievements ----------------
    // RetroAchievements reads FBNeo's "All Ram" of timeplt (d_timeplt.cpp MemIndex), whose
    // first 2 KB are the work RAM at A800-AFFF: RA address n = Z80 A800 + n. Set 11902 reads
    // only there, so the mirror is these 2 KB. Every write becomes one event on the rising
    // edge of the RAM's write enable.
    logic mir_we_q = 1'b0;
    always_ff @(posedge clk) mir_we_q <= mir_we;
    // the snapshot instant: the start of the vertical blank
    logic vblank_q = 1'b0;
    always_ff @(posedge clk) vblank_q <= vblank;

    tp_mirror #(.N(2048)) u_mirror (
        .clk(clk), .reset(reset), .frame_go(vblank && !vblank_q),
        .m_ev(mir_we && !mir_we_q), .m_flat(14'(mir_addr)), .m_data(mir_data),
        .s_ev(1'b0), .s_flat(14'd0), .s_data(8'd0),
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
