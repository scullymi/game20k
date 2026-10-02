// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file game_core.sv
//! @brief Pac-Man behind the game interface of the platform top (game20k).
//!
//! The platform top (fpga/common/src/game20k_top.sv) knows only this module and game_pkg.
//! Every game folder has a game_core with exactly these ports. Here it wraps MikeJ's Pac-Man
//! core (src/rtl_pacman, MiSTer 648172de with our taps) and holds what is Pac-Man's alone:
//! the pixel enable, the DIP switches, the joystick of an upright cabinet with a 4-way
//! filter, the ROM decode, the video sample phase and the audio scale. The RAM mirror itself
//! is a VHDL entity beside the core (src/rtl_pacman/pacman_mirror.vhd) so that nvc can
//! simulate it; this file only wires it.
//!
//! The parameters ROMVIEW and RAMDIAG are accepted because the top passes them and ignored:
//! there is no character ROM view and no ram_diag instance in this folder, the diag_*
//! outputs are constant 0.
module game_core #(
    parameter bit ROMVIEW = 0,      //!< accepted for the top's sake, no effect here
    parameter bit RAMDIAG = 0       //!< accepted for the top's sake, no effect here
)(
    input  wire         clk_core,       //!< 18.5625 MHz
    input  wire         reset,          //!< core reset, held by the top until the ROM is loaded

    //! ---- video in the core raster, blankn = 1 visible, vs active low ----
    output logic [3:0]  video_r,        //!< 4/4/4, a 3/3/2 core leaves the low bits 0
    output logic [3:0]  video_g,
    output logic [3:0]  video_b,
    output logic        video_ce,       //!< pixel enable, only read when game_pkg::CPP is 0
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

    //! ---- RAM mirror: the harvest delivers the mirror bytes, see rtl_pacman/pacman_mirror.vhd ----
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
    // ---------------- Clock enables ----------------
    // The core steps on ENA_6, one clock in three: 6.1875 MHz pixel, 0.7 percent above the
    // board's 6.144 MHz, 61.04 Hz frames as Galaga on the same clock. Not reset: the core's
    // own counters are not reset either, the scaler locks onto the vsync edge. ENA_4 and
    // ENA_1M79 only clocked the sound chips of other games, which are stubs here.
    logic [1:0] ph = 2'd0;
    always_ff @(posedge clk_core) ph <= (ph == 2'd2) ? 2'd0 : ph + 2'd1;
    wire ena_6 = (ph == 2'd0);

    // ---------------- DIP switches from the menu ----------------
    // The ids are the ones menu.xml uses, the values are the raw DSW1 bits (MAME pacman.cpp):
    // 1:0 coinage, 3:2 lives, 5:4 bonus, 6 difficulty (1 normal), 7 ghost names (1 normal).
    // The defaults are the menu's defaults, they hold until the Companion sends the saved
    // values at start-up: 0xC9, MAME's default, 3 lives and 1 coin per play as the
    // RetroAchievements set expects.
    logic [1:0] lives      = 2'd2;
    logic [1:0] bonus      = 2'd0;
    logic [1:0] coinage    = 2'd1;
    logic       difficulty = 1'b1;
    logic       ghost      = 1'b1;
    always_ff @(posedge clk_core)
        if (cfg_we) case (cfg_id)
            "L": lives      <= cfg_val[1:0];
            "B": bonus      <= cfg_val[1:0];
            "C": coinage    <= cfg_val[1:0];
            "F": difficulty <= cfg_val[0];
            "K": ghost      <= cfg_val[0];
            default: ;
        endcase

    // DIP switches reach the core only while it is in reset: every DIP list in menu.xml
    // carries action="reset", and the top holds reset for at least 255 clocks. DSW2 is
    // unused by Pac-Man, 0xFF is MiSTer's value.
    logic [7:0] dipsw1;
    always_ff @(posedge clk_core)
        if (reset) dipsw1 <= {ghost, difficulty, bonus, lives, coinage};

    // ---------------- Controls ----------------
    // An upright cabinet: both players take turns on one stick, so both controllers feed the
    // same direction bits, as MiSTer does. The stick is 8-way with a square gate and the game
    // reads 4-way. The rule the player wants is "the direction pressed last wins": moving up
    // and pressing into up+left turns left, left alone stays left, left+down turns down. A
    // hat switch pressed into a corner chatters, though: the marginal switch opens and closes
    // while the firm one holds, from 2 ms bounces to on and off for seconds (logs of
    // 01.10.2026: up, up+left, up, ... eleven changes over 3.5 s, half the gaps under 8 ms,
    // two thirds under 50 ms).
    // Taken literally, every gap handed the game back the old direction and every close
    // counted as a new press, so Pac-Man saw a direction that flipped at the junction.
    //
    // So: a press counts as new only after its direction was released for HOLD_MS, else it is
    // the switch chattering and changes nothing. The direction in effect stays while it is
    // pressed, and through a gap of up to HOLD_MS while another direction is still pressed,
    // which is the corner chattering. Releasing everything is neutral at once. Two new
    // directions in one clock take the first in the order up, down, left, right. HOLD_MS is
    // a compromise: longer bridges more of the slow chatter, but a direction released and
    // pressed again within it does not take over while the old one is held, which with
    // 200 ms already felt late in play. Back from a corner to the old direction takes
    // BACK_MS (50 ms) to show, and a gap in the corner longer than that leaks.
    // p1_dir/p2_dir are clk_core registers of the top.
    localparam int HOLD_MS = 100;
    // the gap in the corner bridged before the direction still held takes over again: shorter
    // than HOLD_MS, so leaving a corner for the old direction shows sooner (test 02.10.2026)
    localparam int BACK_MS = 50;
    wire [3:0] raw_dir = p1_dir | p2_dir;      // {up, down, left, right}
    logic [14:0] ms_div = 15'd0;               // 18.5625 MHz / 18563 = 1 kHz
    wire ms_tick = (ms_div == 15'd18562);
    always_ff @(posedge clk_core) ms_div <= ms_tick ? 15'd0 : ms_div + 15'd1;
    logic [3:0]      raw_d = 4'd0;             // raw_dir a clock ago, for the press edges
    logic [3:0][8:0] gap   = {4{9'd511}};      // ms since each direction was released, saturating
    logic [3:0]      dir4  = 4'd0;
    // a press of a direction that was released for HOLD_MS or longer: new, not chatter
    wire [3:0] fresh = raw_dir & ~raw_d & {gap[3] >= HOLD_MS, gap[2] >= HOLD_MS, gap[1] >= HOLD_MS, gap[0] >= HOLD_MS};
    function automatic logic [3:0] first(input logic [3:0] x);
        first = x[3] ? 4'b1000 : x[2] ? 4'b0100 : x[1] ? 4'b0010 : x[0] ? 4'b0001 : 4'b0000;
    endfunction
    // the gap of the direction in effect, 511 when none is
    wire [8:0] gap4 = dir4[3] ? gap[3] : dir4[2] ? gap[2] : dir4[1] ? gap[1] : dir4[0] ? gap[0] : 9'd511;
    always_ff @(posedge clk_core) begin
        raw_d <= raw_dir;
        for (int i = 0; i < 4; i++) begin
            if (raw_dir[i])                           gap[i] <= 9'd0;
            else if (ms_tick && gap[i] != 9'd511)     gap[i] <= gap[i] + 9'd1;
        end
        if (raw_dir == 4'd0)                          dir4 <= 4'd0;             // all released
        else if (fresh != 4'd0)                       dir4 <= first(fresh);     // the newest wins
        else if ((dir4 & raw_dir) != 4'd0)            dir4 <= dir4;             // in effect and pressed
        else if (dir4 != 4'd0 && gap4 < BACK_MS)      dir4 <= dir4;             // a gap in the corner
        else                                          dir4 <= first(raw_dir);  // released for good
    end

    // The core's ports are active low, bit order 0 up, 1 left, 2 right, 3 down. Hardcore
    // needs the rack test (in0 bit 4) and the service mode (in1 bit 4) off, so no fire
    // button is wired; p1_fire, p2_fire, p1_btns and p2_btns stay unused. The P2 bits of
    // in1 are unused with the cabinet bit at upright, fed for a later cocktail option.
    wire [7:0] in0 = {1'b1, 1'b1, ~coin, 1'b1, ~dir4[2], ~dir4[0], ~dir4[1], ~dir4[3]};
    wire [7:0] in1 = {1'b1, ~start2, ~start1, 1'b1, ~dir4[2], ~dir4[0], ~dir4[1], ~dir4[3]};

    // The test bar shows the filtered direction, what the game sees: bit 0 up, 1 down,
    // 2 left, 3 right, 4 coin, 5 start 1, 6 start 2, as MAP_LABELS of game_pkg names them.
    assign map_bits = {9'd0, start2, start1, coin, dir4[0], dir4[1], dir4[2], dir4[3]};

    // ---------------- ROM download ----------------
    // rom_loader gives one clock of rom_wr_en[i] per byte of section i with the offset
    // inside the section. The core's download decoder wants the MiSTer address space:
    // program at 0x0000, graphics at 0x8000, the PROMs at 0xC000 + their MiSTer offset. The
    // palette chip has 32 bytes of which the core decodes 16; bytes 16..31 land at 0xC310
    // where nothing listens, as on MiSTer. The timing PROM (section 5) is in the file for the
    // digest only, the core generates its timing itself. Section 6 is Ms. Pac-Man's second
    // program bank (0x4000..0x7FFF), only mspacman.rom has it, see mspacman.manifest.
    logic [15:0] dn_addr;
    logic        dn_wr;
    always_comb begin
        if      (rom_wr_en[0]) dn_addr = {2'b00, rom_wr_addr[13:0]};              // u_program_rom0
        else if (rom_wr_en[1]) dn_addr = {3'b100, rom_wr_addr[12:0]};             // char_rom_5ef
        else if (rom_wr_en[2]) dn_addr = 16'hC300 | {11'd0, rom_wr_addr[4:0]};    // col_rom_7f
        else if (rom_wr_en[3]) dn_addr = 16'hC100 | {8'd0, rom_wr_addr[7:0]};     // col_rom_4a
        else if (rom_wr_en[4]) dn_addr = 16'hC000 | {8'd0, rom_wr_addr[7:0]};     // audio_rom_1m
        else if (rom_wr_en[6]) dn_addr = {2'b01, rom_wr_addr[13:0]};              // u_program_rom1
        else                   dn_addr = 16'h0000;
        dn_wr = |rom_wr_en[4:0] | rom_wr_en[6];
    end

    // Which game the file is: a file with the second bank is Ms. Pac-Man. The first program
    // byte of every load clears the flag, a byte of the bank sets it. The core stays in
    // reset until the whole file is in (game20k_top), so it never runs with a stale flag.
    logic is_ms = 1'b0;
    always_ff @(posedge clk_core) begin
        if (rom_wr_en[0] && rom_wr_addr == 16'd0) is_ms <= 1'b0;
        else if (rom_wr_en[6])                     is_ms <= 1'b1;
    end

    // ---------------- Core nets ----------------
    logic [2:0]  core_r, core_g;
    logic [1:0]  core_b;
    logic        core_hs, core_vs, core_hb, core_vb;
    logic [9:0]  audio_u10;        // unipolar, silence = 0, at most 900 (225 << 2)
    logic [11:0] hs_address;       // the mirror's read port on the main RAM
    logic [7:0]  hs_data_out;
    logic [3:0]  mir_sxy_addr;
    logic [7:0]  mir_sxy_data;
    logic        mir_flip, mir_we_ram, mir_we_sxy, mir_we_flip, mir_frame_go;
    logic [11:0] mir_wr_addr;
    logic [7:0]  mir_wr_data;
    logic [1:0]  blankn_q = 2'b00;

    // ---------------- The core ----------------
    // Every mod_* input but mod_ms is 0: Pac-Man and Ms. Pac-Man, the other games' decoders
    // and sound chips are swept. hs_access_read and hs_access_write must stay 0: any 1
    // silently drops all CPU RAM writes (pacman.vhd, u_rams). The high score port B is the
    // mirror's read port.
    // Fallback if Gowin does not bind the entity PACMAN from here: lowercase 'pacman core'
    // or a VHDL shell, see src/rtl_pacman/README.md.
    PACMAN core (
        .O_VIDEO_R   (core_r),
        .O_VIDEO_G   (core_g),
        .O_VIDEO_B   (core_b),
        .O_HSYNC     (core_hs),
        .O_VSYNC     (core_vs),
        .O_HBLANK    (core_hb),
        .O_VBLANK    (core_vb),
        .O_AUDIO     (audio_u10),
        .in0         (in0),
        .in1         (in1),
        .dipsw1      (dipsw1),
        .dipsw2      (8'hFF),
        .mod_plus    (1'b0),
        .mod_jmpst   (1'b0),
        .mod_bird    (1'b0),
        .mod_mrtnt   (1'b0),
        .mod_ms      (is_ms),
        .mod_woodp   (1'b0),
        .mod_eeek    (1'b0),
        .mod_glob    (1'b0),
        .mod_alib    (1'b0),
        .mod_ponp    (1'b0),
        .mod_van     (1'b0),
        .mod_dshop   (1'b0),
        .mod_club    (1'b0),
        .flip_screen (1'b0),
        .h_offset    (3'd0),
        .v_offset    (3'd0),
        .dn_addr     (dn_addr),
        .dn_data     (rom_wr_data),
        .dn_wr       (dn_wr),
        .pause       (1'b0),
        .hs_address      (hs_address),
        .hs_data_in      (8'h00),
        .hs_data_out     (hs_data_out),
        .hs_write_enable (1'b0),
        .hs_access_read  (1'b0),
        .hs_access_write (1'b0),
        .mir_sxy_addr (mir_sxy_addr),
        .mir_sxy_data (mir_sxy_data),
        .mir_flip     (mir_flip),
        .mir_we_ram   (mir_we_ram),
        .mir_we_sxy   (mir_we_sxy),
        .mir_we_flip  (mir_we_flip),
        .mir_wr_addr  (mir_wr_addr),
        .mir_wr_data  (mir_wr_data),
        .mir_frame_go (mir_frame_go),
        .RESET       (reset),
        .CLK         (clk_core),
        .ENA_6       (ena_6),
        .ENA_4       (1'b0),
        .ENA_1M79    (1'b0)
    );

    // ---------------- The RAM mirror ----------------
    // Harvest, catch-up, delivery and the oracle addresses all live in the VHDL entity, so
    // that the simulation covers every cycle argument; this file holds no mirror state.
    pacman_mirror mirror (
        .clk        (clk_core),
        .ena_6      (ena_6),
        .reset      (reset),
        .frame_go   (mir_frame_go),
        .ram_addr   (hs_address),
        .ram_q      (hs_data_out),
        .sxy_addr   (mir_sxy_addr),
        .sxy_q      (mir_sxy_data),
        .flip       (mir_flip),
        .we_ram     (mir_we_ram),
        .we_sxy     (mir_we_sxy),
        .we_flip    (mir_we_flip),
        .wr_addr    (mir_wr_addr),
        .wr_data    (mir_wr_data),
        .snap_run   (snap_run),
        .snap_full  (snap_full),
        .snap_push  (snap_push),
        .snap_byte  (snap_byte),
        .snap_frame (snap_frame),
        .snap_harv  (snap_harv),
        .log_we     (log_we),
        .log_addr   (log_addr),
        .log_data   (log_data)
    );

    // ---------------- Video ----------------
    // All four core outputs are active high. blankn is 1 for exactly the 288 x 224 visible
    // pixels and 0 for the whole vertical blank, which the scaler's ring buffer needs.
    // Sample phase: the RGB register of the core (col_rom_7f) takes pixel n at the edge
    // E+1+3n, E being the ENA_6 edge that ends O_HBLANK, and holds it for three clocks
    // (measured in sim/tb_pacman.vhd, T8, sprites included). The scaler samples at the edge
    // ending c0+2, c0 being the first clock in which it sees blankn high: BLANK_DLY = 0
    // takes the middle clock of the three, BLANK_DLY = 1 the last one, which T8 checks on
    // every sample of a frame. RGB is not delayed. The shift register is indexed directly,
    // so no branch carries a negative index.
    localparam int BLANK_DLY = 1;
    wire blankn_live = ~(core_hb | core_vb);
    always_ff @(posedge clk_core) blankn_q <= {blankn_q[0], blankn_live};
    wire [2:0] blankn_sh = {blankn_q, blankn_live};   // [0] live, [1] one clock, [2] two clocks
    assign video_blankn = blankn_sh[BLANK_DLY];
    // 3/3/2 in the upper bits (game_pkg::RGB444 is 0), the scaler counts the pixels itself
    assign video_r  = {core_r, 1'b0};
    assign video_g  = {core_g, 1'b0};
    assign video_b  = {core_b, 2'b00};
    assign video_ce = 1'b0;
    // the ROM lives in block RAM, nothing is read from SDRAM
    assign rom_rd_addr = '0;
    assign rom_rd_req  = 1'b0;
    // O_VSYNC is an active high 8-line pulse 16 lines before the first visible line; the
    // scaler wants it active low. O_HSYNC has no consumer.
    assign video_vs = ~core_vs;
    assign video_hs = ~core_hs;

    // ---------------- Audio: mean of the WSG's time multiplex, then one pole ----------------
    // O_AUDIO is not a sum of the voices. The WSG has one output register (2M in
    // rtl_pacman/pacman_audio.vhd) that holds voice 0 for 20 ena_6 steps, voice 1 for 20 and
    // voice 2 for 24: a frame of 64 steps at 96.68 kHz. On the board the DAC and the analogue
    // stage average it. The 48 kHz sample point of the HDMI path does not: it picked one voice
    // at a time and folded the frame to |96.68 - 2 x 48.03| kHz, a comb of lines 0.63 kHz
    // apart with a third of the power, the buzz next to every tone.
    //
    // Stage 1 sums exactly one frame, 20*v0 + 20*v1 + 24*v2, the board's weights, with nothing
    // of the multiplex left. Any 64 consecutive ena_6 steps hold each slot once, so the frame
    // counter needs no phase from the core. At most 64 * 900 = 57600, 16 bits.
    logic [5:0]  frm     = 6'd0;       // ena_6 step within the frame
    logic [15:0] frm_acc = 16'd0;      // running sum of the current frame
    logic [15:0] frm_sum = 16'd0;      // sum of the last complete frame
    wire  [15:0] frm_nx  = frm_acc + {6'd0, audio_u10};
    always_ff @(posedge clk_core)
        if (ena_6) begin
            frm     <= frm + 6'd1;
            // step 63 closes the frame: hand over the sum, start the next one from 0
            frm_acc <= (frm == 6'd63) ? 16'd0 : frm_nx;
            if (frm == 6'd63) frm_sum <= frm_nx;
        end

    // Stage 2, one pole at the ena_6 rate: lp += (64 * frm_sum - lp) / 64, -3 dB at
    // 6.1875 MHz / (2 pi 64) = 15.5 kHz. It smooths the steps of the held frame value, whose
    // images near 96.7 kHz the sample point would fold to 0.63 kHz above and below every
    // tone. lp settles at 64 * frm_sum, at most 3686400 < 2^22.
    logic [21:0] lp = 22'd0;
    always_ff @(posedge clk_core)
        if (ena_6) lp <= lp - {6'd0, lp[21:6]} + {6'd0, frm_sum};

    // lp / 128 = frm_sum / 2 = 32 * the frame mean, the scale of the earlier 32 * O_AUDIO:
    // at most 28800, no clipping, and silence stays 0 so the top's volume gain does not
    // shift the idle level. If the device says too quiet, Galaga's x64 with clipping is the
    // fallback:
    //   assign audio = (lp[21:6] > 16'd32767) ? 16'd32767 : lp[21:6];
    assign audio = {1'b0, lp[21:7]};

    // ---------------- No diagnostics in this folder ----------------
    assign diag_on    = 1'b0;
    assign diag_color = 24'd0;
    assign diag_leds  = 6'd0;
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
