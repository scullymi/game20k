// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file game_core.sv
//! @brief Dig Dug behind the game interface of the platform top (game20k).
//!
//! Wraps MiSTer-X's Dig Dug (src/rtl_digdug, MiSTer-devel/Arcade-DigDug_MiSTer 3022bcc,
//! GPL-3.0), changed to run on clk_core alone with clock enables, and holds what the MiSTer
//! top did around it: the raster generator, DIP switches, controls, ROM download. The program
//! of the main CPU is read from SDRAM through one rom_slots slot, everything else comes over
//! the loader's write port into the core's own ROMs. The RAM mirror for RetroAchievements is
//! ram_mirror_n.sv, fed from the core's write taps.
module game_core #(
    parameter bit ROMVIEW = 0,      //!< accepted for the top's sake, no effect here
    parameter bit RAMDIAG = 0       //!< accepted for the top's sake, no effect here
)(
    input  wire         clk_core,       //!< 46.40625 MHz
    input  wire         reset,          //!< core reset, held by the top until the ROM is loaded

    //! ---- video in the core raster, blankn = 1 visible, vs active low ----
    output logic [3:0]  video_r,        //!< 3/3/2 in the upper bits
    output logic [3:0]  video_g,
    output logic [3:0]  video_b,
    output logic        video_ce,       //!< pixel enable, one clock in eight
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

    //! ---- RAM mirror: the harvest delivers the mirror bytes, see ram_mirror_n.sv ----
    input  wire         snap_run,
    input  wire         snap_full,
    output logic        snap_push,
    output logic [7:0]  snap_byte,
    output logic [15:0] snap_frame,
    output logic        snap_harv,
    output logic        log_we,
    output logic [15:0] log_addr,
    output logic [7:0]  log_data,

    //! ---- diagnostic bar of the RAMDIAG build, in the pixel clock, 0 here ----
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
    // The ids are the ones menu.xml uses, the values the raw bits of MAME galaga.cpp (digdug).
    // The defaults are MAME's: DSWA 0x99, DSWB 0x24.
    // DSWA: 7:6 lives, 5:3 bonus, 2:0 coin B. DSWB: 7:6 coin A, 5 freeze (1 off), 4 demo
    // sounds (0 on), 3 continue (0 yes), 2 cabinet (1 upright), 1:0 difficulty.
    logic [1:0] lives      = 2'd2;
    logic [2:0] bonus      = 3'd3;
    logic [2:0] coin_b     = 3'd1;
    logic [1:0] coin_a     = 2'd0;
    logic       demo_off   = 1'b0;
    logic       cont_off   = 1'b0;
    logic [1:0] difficulty = 2'd0;
    always_ff @(posedge clk)
        if (cfg_we) case (cfg_id)
            "L": lives      <= cfg_val[1:0];
            "B": bonus      <= cfg_val[2:0];
            "C": coin_a     <= cfg_val[1:0];
            "K": coin_b     <= cfg_val[2:0];
            "F": difficulty <= cfg_val[1:0];
            "M": demo_off   <= cfg_val[0];
            "O": cont_off   <= cfg_val[0];
            default: ;
        endcase

    // DIP switches reach the core only while it is in reset, as with Galaga
    logic [7:0] dsw0 = 8'h99, dsw1 = 8'h24;
    always_ff @(posedge clk)
        if (reset) begin
            dsw0 <= {lives, bonus, coin_b};
            dsw1 <= {coin_a, 1'b1, demo_off, cont_off, 1'b1, difficulty};
        end

    // ---------------- Controls, active high as in the MiSTer top ----------------
    // An upright cabinet: both players play on the one stick and button, the cocktail inputs
    // of the 51XX stay released. The 51XX program makes the 4-way choice.
    wire up    = p1_dir[3] | p2_dir[3];
    wire down  = p1_dir[2] | p2_dir[2];
    wire left  = p1_dir[1] | p2_dir[1];
    wire right = p1_dir[0] | p2_dir[0];
    wire fire  = p1_fire | p2_fire;
    wire [7:0] inp0 = {1'b0, 1'b0, 1'b0, coin, start2, start1, 1'b0, fire};
    wire [7:0] inp1 = {4'd0, left, down, right, up};
    assign map_bits = {8'd0, start2, start1, coin, fire, up, down, left, right};

    // ---------------- ROM download ----------------
    // Section 2 of digdug.manifest is the core's download image from 0x4000 on (sprites, the
    // programs of CPU1 and CPU2, playfield, characters, PROMs), section 1 the programs of the
    // 51XX and 53XX, which the core takes at 0xE000. Section 0, the program of CPU0, goes to
    // SDRAM only.
    localparam int SEC_MCU  = 1;
    localparam int SEC_CORE = 2;
    wire [15:0] romad = (rom_wr_en[SEC_MCU] ? 16'hE000 : 16'h4000) + rom_wr_addr;
    wire        romen = rom_wr_en[SEC_CORE] | rom_wr_en[SEC_MCU];

    // ---------------- Program ROM of CPU0: SDRAM ----------------
    // Section 0 lies in SDRAM at file offset 0, the Z80 address is the file offset. One slot
    // keeps the last 32-bit word, so straight-line code costs one SDRAM read per four bytes.
    // The core holds CPU0 in wait states while the slot has no word for the address.
    wire [13:0] cpu_rom_addr;
    wire        cpu_rom_cs;
    wire [21:0] rom_off = 22'(cpu_rom_addr);
    wire [0:0][21:2] slot_addr = rom_off[21:2];
    wire [0:0]       slot_cs   = cpu_rom_cs;
    wire [0:0]       slot_ok;
    wire [0:0][31:0] slot_data;
    logic [31:0]     rom_miss;
    rom_slots #(.N(1), .AW(22)) u_slots (
        .clk(clk), .reset(reset),
        .slot_addr(slot_addr), .slot_cs(slot_cs), .slot_hold(1'b0),
        .slot_ok(slot_ok), .slot_data(slot_data),
        .rd_addr(rom_rd_addr), .rd_push(rom_rd_push), .rd_ready(rom_rd_ready),
        .rd_valid(rom_rd_valid), .rd_data(rom_rd_data),
        .miss(rom_miss)
    );
    wire [7:0] cpu_rom_din = slot_data[0][8*rom_off[1:0] +: 8];

    // ---------------- The game ----------------
    wire        pclk;                   // pixel enable
    wire [8:0]  hpos, vpos;
    wire [7:0]  pix;
    wire [7:0]  sout;
    wire        mir_we;
    wire [12:0] mir_ad;
    wire [7:0]  mir_dt;

    FPGA_DIGDUG u_dd (
        .RESET(reset), .MCLK(clk),
        .INP0(inp0), .INP1(inp1), .DSW0(dsw0), .DSW1(dsw1),
        .PH(hpos), .PV(vpos), .PCLK(pclk), .POUT(pix),
        .SOUT(sout), .LED(),
        .V_FLIP(1'b0),
        .ROMCL(clk), .ROMAD(romad), .ROMDT(rom_wr_data), .ROMEN(romen),
        .PAUSE(1'b0),
        .CPU0_ROMAD(cpu_rom_addr), .CPU0_ROMCS(cpu_rom_cs),
        .CPU0_ROMDT(cpu_rom_din), .CPU0_ROMOK(slot_ok[0]),
        .MIR_WE(mir_we), .MIR_AD(mir_ad), .MIR_DT(mir_dt)
    );

    // the raster, as the MiSTer top has it (HVGEN, here 360 x 264)
    wire [11:0] rgb12;
    wire        hblank, vblank, hsync, vsync;
    HVGEN u_hv (
        .HPOS(hpos), .VPOS(vpos), .CLK(clk), .PCLK(pclk),
        .iRGB({pix[7:6], 2'b00, pix[5:3], 1'b0, pix[2:0], 1'b0}),
        .oRGB(rgb12), .HBLK(hblank), .VBLK(vblank), .HSYN(hsync), .VSYN(vsync)
    );

    // ---------------- Video and audio to the platform ----------------
    assign video_r      = rgb12[3:0];
    assign video_g      = rgb12[7:4];
    assign video_b      = rgb12[11:8];
    assign video_ce     = pclk;
    // HVGEN registers the colour one pixel after the blank (oRGB takes the old HBLK), so the
    // first pixel after the blank is black and the last picture pixel comes in the blank. The
    // blank one pixel later puts the 288 columns where MAME has them (checked in the simulation).
    logic blank_q = 1'b1;
    always_ff @(posedge clk) if (pclk) blank_q <= hblank | vblank;
    assign video_blankn = ~blank_q;
    assign video_vs     = vsync;
    assign video_hs     = hsync;
    // 8 bit unipolar, silence = 0, scaled to 0..32640
    always_ff @(posedge clk) audio <= {1'b0, sout, 7'd0};

    // ---------------- RAM mirror for RetroAchievements ----------------
    // RetroAchievements reads FBNeo's "All Ram" of digdug (d_galaga.cpp, DrvScan): video RAM
    // 0x800, then the three shared RAMs at 0x400 each, 5120 bytes in the order of the core's
    // write taps (FPGA_DIGDUG.v). The snapshot instant is the start of the vertical blank.
    logic vblank_q = 1'b0;
    always_ff @(posedge clk) vblank_q <= vblank;

    ram_mirror_n #(.N(5120)) u_mirror (
        .clk(clk), .reset(reset), .frame_go(vblank && !vblank_q),
        .ev(mir_we), .ev_flat(15'(mir_ad)), .ev_data(mir_dt),
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
