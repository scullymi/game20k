// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file galaga_hdmi_top.sv
//! @brief Top level of the Galaga cabinet on the Tang Nano 20K: core, HDMI, SDRAM, Companion.
//!
//! Galaga arcade cabinet on the Tang Nano 20K. Game core in VHDL by Dar, video and audio
//! over HDMI.
//!
//! Clocks: 27 MHz crystal and TWO PLLs. pll_hdmi produces clk_x5 (371.25 MHz) and clk_core
//! (18.5625 MHz), clkdiv5 divides clk_x5 down to clk_pixel (74.25 MHz). pll_sdram provides
//! a separate 64.8 MHz for the frame buffer in SDRAM.
//!
//! Buttons: S1 = reset. S2 = OSD button, reported to the Companion. Coin and start come
//! from the arcade stick via the Companion, not from S2.
//!
//! Video: landscape through galaga_scaler (3x), portrait through the SDRAM frame buffer
//! with fb_read_rotated (2x). Switched at run time from the menu, not at synthesis.
//!
//! Audio: embedded in the HDMI stream and, in addition, as sigma-delta on pwm_audio_l.
//!
//! SD card: attached to the FPGA (sd_card from Nanomig), operated by the Companion over
//! SPI. galaga.rom reaches the core's ROM memories the same way.
//!
//! The build parameters below are DIAGNOSTIC builds only and are all 0 in the normal
//! build. They are set through environment variables, see build.tcl. The production
//! branch is g_fb_live.
module galaga_hdmi_top #(
    parameter bit TESTBAR   = 1,   //!< synthesise the input test bar (1 BSRAM)
    parameter bit ROMVIEW   = 0,   //!< 1: show the character ROM instead of the game (diagnostic)
    parameter bit SDRAMTEST = 0,   //!< 1: SDRAM controller plus phase self test
    parameter bit SDRAMCL3  = 0,   //!< 1: CAS latency 3 instead of 2 (self test comparison run)
    parameter bit FBTEST    = 0,   //!< 1: write path plus cross-check (fb_check)
    parameter bit FBSHOW    = 0,   //!< 1: picture from the SDRAM, not rotated
    parameter bit FBROT     = 0,   //!< 1: picture from the SDRAM, ROTATED 2x
    parameter bit RAMDIAG   = 0    //!< 1: measure writes to the game RAM (ram_diag)
) (
    input  wire        sys_clk,      //!< 27 MHz crystal
    input  wire        s1,           //!< reset (pressed = 1)
    input  wire        s2,           //!< OSD button, reported to the Companion
    output logic [5:0] led,          //!< active low
    output logic       tmds_clk_n,
    output logic       tmds_clk_p,
    output logic [2:0] tmds_d_n,
    output logic [2:0] tmds_d_p,
    output logic       pwm_audio_l,
    //! SDRAM inside the GW2AR package. Gowin binds these port names to the internal
    //! pads, there is no line for them in the .cst.
    output logic        O_sdram_clk,
    output logic        O_sdram_cke,
    output logic        O_sdram_cs_n,
    output logic        O_sdram_ras_n,
    output logic        O_sdram_cas_n,
    output logic        O_sdram_wen_n,
    output logic [10:0] O_sdram_addr,
    output logic [1:0]  O_sdram_ba,
    output logic [3:0]  O_sdram_dqm,
    inout  wire  [31:0] IO_sdram_dq,
    //! microSD, driven by sd_card, operated by the Companion over SPI
    output logic       sd_clk,
    inout  wire        sd_cmd,
    inout  wire  [3:0] sd_dat,
    //! FPGA Companion (Pico) on the 40-pin header
    input  wire        spi_csn,
    input  wire        spi_sck,
    input  wire        spi_mosi,
    output logic       spi_miso,
    output logic       spi_irqn
);
    import ram_mirror_pkg::*;   // block sizes of the RAM mirror, see ram_mirror_pkg.sv
    // ---------------- Clocks ----------------
    logic clk_x5, clk_pixel, clk_core, pll_lock;
    pll_hdmi pll (.clkin(sys_clk), .clkout(clk_x5), .clkoutd(clk_core), .lock(pll_lock));
    clkdiv5  div (.hclkin(clk_x5), .resetn(pll_lock), .clkout(clk_pixel));

    // ---------------- Reset ----------------
    logic [1:0] s1_s = 0;
    logic [7:0] rst_cnt = 0;
    logic       reset = 1;
    always_ff @(posedge clk_core) begin
        s1_s <= {s1_s[0], s1};
        if (!pll_lock || s1_s[1] || system_reset[0] || !rom_loaded) begin
            rst_cnt <= 8'd0;
            reset   <= 1'b1;
        end else if (rst_cnt != 8'hFF)
            rst_cnt <= rst_cnt + 8'd1;
        else
            reset <= 1'b0;
    end

    logic video_reset;
    assign video_reset = reset;

    // ---------------- S2: OSD button, reported to the Companion ----------------
    logic [1:0]  s2_s = 0;
    always_ff @(posedge clk_core) s2_s <= {s2_s[0], s2};

    // ---------------- Galaga core (VHDL, Dar) ----------------
    logic [2:0] video_r, video_g;
    logic [1:0] video_b;
    logic [7:0] dbg_bgdata;
    logic [8:0] dbg_hcnt, dbg_vcnt;
    logic [3:0] dbg_bgbits;
    logic [3:0]  dbg_ram_we;     // taps of the game RAM writes, observation only
    logic [10:0] dbg_ram_addr;
    logic [7:0]  dbg_ram_data;
    // RAM mirror: the snapshot on its way to the Pico
    logic        snap_run, snap_full, snap_push, snap_pop, snap_empty;
    logic        snap_undr;   // underrun flag of the FIFO, formed in the SPI clock
    logic [15:0] ram_rc;      // {loaded conditions, fired ones}
    logic [15:0] ram_us;      // rcheevos compute time per frame
    logic [7:0]  ram_last;    // last fired achievement, 1-based
    logic        ram_txt_we;  // banner: write one character
    logic [4:0]  ram_txt_addr;
    logic [7:0]  ram_txt_data;
    logic        ram_banner;  // show the banner
    logic        ram_bgold, ram_bnew;   // text gold (hardcore), mark green (new)
    logic [7:0]  snap_byte, snap_fifo_q;
    logic [15:0] snap_frame;
    logic [15:0] snap_catchup_peak;   // peak fill level of the catch-up queue
    logic        snap_harv;
    logic       video_blankn, video_hs, video_vs, video_csync, video_clk;
    logic [9:0] audio;

    // Five taps of the core stay open: dbg_tile_num, dbg_tile_color, dbg_bgaddr, dbg_shadow
    // and dbg_score exist for measurement builds (src/rtl_dar/galaga.vhd) and nothing in this
    // file reads them. The empty parentheses say so on purpose.
    galaga core (
        .clock_18     (clk_core),
        .reset        (reset),
        .video_reset  (video_reset),
        .dbg_tile_num  (),
        .dbg_tile_color(),
        .dbg_hcnt      (dbg_hcnt),
        .dbg_vcnt      (dbg_vcnt),
        .dbg_bgaddr    (),
        .dbg_bgdata    (dbg_bgdata),
        .dbg_bgbits    (dbg_bgbits),
        .dbg_ram_we    (dbg_ram_we),
        .dbg_ram_addr  (dbg_ram_addr),
        .dbg_ram_data  (dbg_ram_data),
        .dbg_score     (),
        .dbg_shadow    (),
        .snap_run      (snap_run),      .snap_full (snap_full),
        .snap_byte     (snap_byte),     .snap_push (snap_push),
        .snap_frame    (snap_frame),    .dbg_skip  (),
        .dbg_nzmax     (snap_catchup_peak),
        .dbg_harv      (snap_harv),
        .video_r      (video_r),
        .video_g      (video_g),
        .video_b      (video_b),
        .video_clk    (video_clk),
        .video_csync  (video_csync),
        .video_blankn (video_blankn),
        .video_hs     (video_hs),
        .video_vs     (video_vs),
        .audio        (audio),
        .rom_wr_clk   (clk_core),
        .rom_wr_addr  (rom_wr_addr),
        .rom_wr_data  (rom_wr_data),
        .rom_wr_en    (rom_wr_en),
        .dip_a        ({1'b1, 1'b1, 1'b1, 1'b1, ~system_demosound, 1'b1, system_difficulty}),  // bit 3 = 0: demo sounds on (MAME galaga.cpp)
        .dip_b        ({system_lives, system_bonus, system_coinage}),
        .b_test       (1'b1),
        .b_svce       (1'b1),
        .coin         (joy_coin),
        .start1       (joy_start1),
        .left1        (joy_left),
        .right1       (joy_right),
        .fire1        (joy_fire),
        .start2       (joy_start2),
        .left2        (joy_left),
        .right2       (joy_right),
        .fire2        (joy_fire)
    );

    // ---------------- SDRAM clock ----------------
    // clk_sdram = 64.8 MHz from the second rPLL. clkoutp drives the clock pin of the SDRAM
    // with an adjustable phase; sdram_psda selects it in steps of 22.5 degrees. In normal
    // operation it is fixed at SDRAM_PSDA = 11 (247.5 degrees, middle of the measured
    // window 7..15), in the self test sdram_selftest sweeps 0..15.
    // Controller and self test are further down because the self test needs cx and cy.
    logic clk_sdram, pll_sdram_lock;
    logic [3:0]  sdram_psda;
    pll_sdram pll_sdram_i (
        .clkin(sys_clk), .clkout(clk_sdram), .clkoutp(O_sdram_clk),
        .lock(pll_sdram_lock), .psda(sdram_psda)
    );
    logic        st_on;          // result bar of the self test
    logic [23:0] st_col;
    logic [5:0]  st_led;

    // ---------------- microSD (SPI target 3), controller from Nanomig ----------------
    // The card hangs on the FPGA, not on the Pico: the Companion reads every sector through
    // the FPGA. CLK_DIV 0 gives 189 kHz init and 9.3 MHz transfer at the 18.5625 MHz core
    // clock. Reset hangs on pll_lock, not on the core reset, so that a game reset does not
    // unmount the card.
    logic [63:0] sd_img_size;
    logic [7:0]  sd_img_mounted;
    logic [2:0]  rom_selected;
    logic        rom_selection_strobe, rom_data_available;
    logic [7:0]  rom_data;
    logic        rom_accepted, rom_data_strobe;
    logic        rom_loaded, rom_busy;
    logic [15:0] rom_count;
    logic [13:0] rom_wr_addr;
    logic [7:0]  rom_wr_data;
    logic [10:0] rom_wr_en;

    sd_card #(
        .CLK_DIV(3'd0),
        .IMAGE_FIFO_BITS(9)          // 512 bytes, the Companion must never be told more
    ) sd_card (
        .rstn(pll_lock), .clk(clk_core),
        .sdclk(sd_clk), .sdcmd(sd_cmd), .sddat(sd_dat),
        .data_strobe(mcu_sdc_strobe), .data_start(mcu_start),
        .data_in(mcu_data_out), .data_out(sdc_data_out),
        .image_mounted(sd_img_mounted), .image_size(sd_img_size),
        .rom_image_selected(rom_selected),
        .rom_image_selection_strobe(rom_selection_strobe),
        .rom_image_accepted(rom_accepted),
        .rom_image_data_available(rom_data_available),
        .rom_image_data(rom_data),
        .rom_image_data_strobe(rom_data_strobe),
        .irq(sdc_int), .iack(int_ack[3]),
        // The core requests no sectors itself
        .rstart(8'h00), .wstart(8'h00), .rsector(32'd0),
        .rsrc(), .rbusy(), .rdone(),
        .inbyte(8'h00), .outen(), .outaddr(), .outbyte()
    );

    // Distributes the bytes of galaga.rom to the core's ROM memories. The file arrives
    // from the SD card via the Companion, rom_loaded reports completion to the LEDs.
    rom_loader #(.SLOT(0), .TOTAL(38944)) loader (
        .clk(clk_core), .reset(!pll_lock),
        .sel_strobe(rom_selection_strobe), .sel_index(rom_selected), .image_size(sd_img_size),
        .accepted(rom_accepted),
        .data_available(rom_data_available), .data_in(rom_data), .data_strobe(rom_data_strobe),
        .wr_addr(rom_wr_addr), .wr_data(rom_wr_data), .wr_en(rom_wr_en),
        .loaded(rom_loaded), .busy(rom_busy), .count(rom_count)
    );

    // ---------------- FPGA Companion: SPI, HID, system control ----------------
    logic       mcu_sys_strobe, mcu_hid_strobe, mcu_osd_strobe, mcu_sdc_strobe, mcu_start;
    // SPI target channel 5, the RAM mirror (channel 4 is assigned in the Companion as
    // SPI_TARGET_AUDIO and implemented nowhere)
    logic       mcu_ram_strobe;
    logic [7:0] ram_data_out;
    logic [15:0] ram_last_count, ram_last_us;
    logic [7:0]  ram_verdict;
    logic [7:0] mcu_data_out, sys_data_out, hid_data_out, osd_data_out;
    logic [7:0] int_ack;
    logic       hid_int, sdc_int;
    // Interrupt bit 5: a new RAM mirror snapshot is ready. Set when the harvest ends,
    // cleared by the Pico's acknowledge; setting wins if both come in the same clock.
    logic       harv_d = 1'b0, snap_int = 1'b0;
    always_ff @(posedge clk_core) begin
        harv_d <= snap_harv;
        if (int_ack[5]) snap_int <= 1'b0;
        if (harv_d && !snap_harv) snap_int <= 1'b1;
    end
    logic [7:0] sdc_data_out;
    logic [1:0] mcu_leds;
    logic [23:0] mcu_color;
    logic [1:0] system_reset, system_lives, system_difficulty, system_scanlines;
    logic [2:0] system_bonus, system_coinage;
    logic       system_demosound;
    logic [2:0] system_volume;
    logic       system_inputtest;
    logic [1:0] system_screen;      // screen mode from the menu
    logic [3:0] system_fire_btn, system_coin_btn, system_start_btn, system_start2_btn, system_voldn_btn, system_volup_btn;
    logic [7:0] joystick [4];
    logic [7:0] joystick_extra [4];
    logic [7:0] joystick_ax [4], joystick_ay [4];

    mcu_spi mcu_spi (
        .clk(clk_core), .reset(!pll_lock),
        .spi_io_ss(spi_csn), .spi_io_clk(spi_sck), .spi_io_din(spi_mosi), .spi_io_dout(spi_miso),
        .mcu_sys_strobe(mcu_sys_strobe), .mcu_hid_strobe(mcu_hid_strobe),
        .mcu_osd_strobe(mcu_osd_strobe), .mcu_sdc_strobe(mcu_sdc_strobe),
        .mcu_ram_strobe(mcu_ram_strobe),
        .mcu_start(mcu_start),
        .mcu_sys_din(sys_data_out), .mcu_hid_din(hid_data_out), .mcu_osd_din(osd_data_out), .mcu_sdc_din(sdc_data_out),
        .mcu_ram_din(ram_data_out),
        .mcu_dout(mcu_data_out)
    );

    sysctrl_galaga sysctrl (
        .clk(clk_core), .reset(!pll_lock),
        .data_in_strobe(mcu_sys_strobe), .data_in_start(mcu_start), .data_in(mcu_data_out), .data_out(sys_data_out),
        // interrupt bits: 1 = HID, 3 = SD card, 5 = RAM mirror snapshot ready
        .int_out_n(spi_irqn), .int_in({2'b00, snap_int, 1'b0, sdc_int, 1'b0, hid_int, 1'b0}), .int_ack(int_ack),
        .buttons({s2_s[1], s1_s[1]}),     // [0] = S1 reset, [1] = S2 OSD
        .leds(mcu_leds), .color(mcu_color),
        .system_reset(system_reset), .system_lives(system_lives), .system_bonus(system_bonus),
        .system_coinage(system_coinage), .system_difficulty(system_difficulty),
        .system_demosound(system_demosound), .system_scanlines(system_scanlines),
        .system_volume(system_volume), .system_inputtest(system_inputtest),
        .system_fire_btn(system_fire_btn), .system_coin_btn(system_coin_btn),
        .system_start_btn(system_start_btn), .system_start2_btn(system_start2_btn),
        .system_voldn_btn(system_voldn_btn), .system_volup_btn(system_volup_btn),
        .system_screen(system_screen)
    );

    hid hid (
        .clk(clk_core), .reset(!pll_lock),
        .data_in_strobe(mcu_hid_strobe), .data_in_start(mcu_start), .data_in(mcu_data_out), .data_out(hid_data_out),
        .db9_port(6'b000000), .irq(hid_int), .iack(int_ack[1]),
        .mouse(), .keyboard(), .joystick(joystick), .joystick_extra(joystick_extra),
        .joystick_ax(joystick_ax), .joystick_ay(joystick_ay)
    );

    // Joystick byte (Companion hid.c): bit0 right, bit1 left, bit2 down, bit3 up,
    // bit4..7 = HID buttons 1..4. Extra byte: generic format bit0..7 = HID buttons 5..12
    // (DInput: 9 = Select, 10 = Start); for sticks from the Companion's SDL database bit2 is
    // Select and bit3 Start (= "button 7/8"). The mapping is therefore adjustable in the OSD
    // menu "Controller" (0 = none or all buttons, respectively).
    logic [11:0] btns;
    assign btns = {joystick_extra[0], joystick[0][7:4]};   // btns[n-1] = HID button n
    function automatic logic btn_sel(input logic [3:0] n, input logic [11:0] b);
        btn_sel = (n == 4'd0 || n > 4'd12) ? 1'b0 : b[n - 4'd1];
    endfunction
    logic joy_left, joy_right, joy_fire, joy_coin, joy_start1, joy_start2, joy_voldn, joy_volup;
    assign joy_right  = joystick[0][0];
    assign joy_left   = joystick[0][1];
    assign joy_fire   = (system_fire_btn == 4'd0) ? |btns : btn_sel(system_fire_btn, btns);
    assign joy_coin   = btn_sel(system_coin_btn, btns);
    assign joy_start1 = btn_sel(system_start_btn, btns);
    assign joy_start2 = btn_sel(system_start2_btn, btns);
    assign joy_voldn  = btn_sel(system_voldn_btn, btns);
    assign joy_volup  = btn_sel(system_volup_btn, btns);

    // Volume 0..7: from the menu (V) or via hotkey on the stick; the menu value wins on change
    logic [2:0] volume = 3'd6, sysvol_d = 3'd6;
    logic       voldn_d = 0, volup_d = 0;
    always_ff @(posedge clk_core) begin
        sysvol_d <= system_volume;
        voldn_d  <= joy_voldn;
        volup_d  <= joy_volup;
        if (system_volume != sysvol_d)                 volume <= system_volume;
        else if (joy_volup && !volup_d && volume != 3'd7) volume <= volume + 3'd1;
        else if (joy_voldn && !voldn_d && volume != 3'd0) volume <= volume - 3'd1;
    end
    logic [4:0] gain;
    always_comb case (volume)
        3'd0: gain = 5'd0;  3'd1: gain = 5'd1;  3'd2: gain = 5'd2;  3'd3: gain = 5'd4;
        3'd4: gain = 5'd6;  3'd5: gain = 5'd8;  3'd6: gain = 5'd12; default: gain = 5'd16;
    endcase

    // Diagnostic: has the Companion ever sent a joystick packet?
    logic hid_seen = 0;
    always_ff @(posedge clk_core)
        if (mcu_hid_strobe && mcu_start && mcu_data_out == 8'd3) hid_seen <= 1'b1;

    // ---------------- Scaler + HDMI ----------------
    logic [10:0] cx;
    logic [9:0]  cy;
    logic        sync;
    logic [23:0] rgb;
    logic [23:0] rgb_scaler;             // picture from the line ring buffer (landscape 3x)
    logic [23:0] rgb_fb;                 // picture from the SDRAM frame buffer (portrait 2x)
    // Portrait mode takes the picture from the frame buffer instead of the scaler. The
    // scaler keeps running either way: it generates the sync pulse HDMI is locked to.
    // Screen mode: 0 = landscape 3x via the scaler, 1 = portrait 2x from the SDRAM.
    // It is taken over only at cy 760, i.e. in the blanking interval and at the same moment
    // at which fb_read_rotated takes over its buffer. Switching mid-frame would give a torn
    // picture.
    logic [1:0] scr_s0 = 0, scr_s1 = 0, screen_p = 0;
    always_ff @(posedge clk_pixel) begin
        scr_s0 <= system_screen;
        scr_s1 <= scr_s0;
        if (cx == 11'd0 && cy == 10'd760) screen_p <= scr_s1;
    end
    wire screen_rot = (screen_p != 2'd0);
    assign rgb = (FBSHOW || FBROT || screen_rot) ? rgb_fb : rgb_scaler;

    // ---------------- Diagnostic: show the character ROM directly ----------------
    // Character c at column x/8, row line/8 (36 x 28 places); layout as in MAME galaga:
    // 16 bytes per character, byte = (x%8 < 4 ? 8 : 0) + row,
    // plane0 = bit (x%4), plane1 = bit 4+(x%4)
    logic [1:0]  rv_pix;
    logic [2:0]  rv_r, rv_g;
    logic [1:0]  rv_b;
    // upper half of the raster: ROM data of the core (bggraphx_do) with our own bit selection
    // lower half of the raster: finished palette bits of the core (bgbits), 0/15 = off
    logic [1:0] core_pix;
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

    galaga_scaler #(.X0(208), .Y0(24)) scaler (
        .clk_core (clk_core),
        .r_in     (ROMVIEW ? rv_r : video_r),
        .g_in     (ROMVIEW ? rv_g : video_g),
        .b_in     (ROMVIEW ? rv_b : video_b),
        .blankn   (video_blankn),
        .vs       (video_vs),
        .clk_pixel(clk_pixel),
        .cx       (cx),
        .cy       (cy),
        .sync     (sync),
        .rgb      (rgb_scaler),
        .dbg_we   (),                 // write-side taps of the scaler: nothing reads them,
        .dbg_x    (),                 // ROMVIEW takes the core signals directly (rv_pix)
        .dbg_line (),
        .dbg_data ()
    );

    // 48 kHz audio clock from the pixel clock (74.25e6 / 48000 / 2 = 773.4)
    logic [9:0] aud_div = 0;
    logic       clk_audio = 0;
    always_ff @(posedge clk_pixel) begin
        if (aud_div == 10'd772) begin
            aud_div   <= 10'd0;
            clk_audio <= ~clk_audio;
        end else
            aud_div <= aud_div + 10'd1;
    end
    // 10 bit unsigned -> 16 bit signed, into the pixel clock domain.
    //
    // The core delivers UNIPOLAR: silence = 0, largest possible value 817
    // (galaga.vhd:423 = 16*cs54xx_1 + 16*cs54xx_2 + snd_audio/2 = 240 + 240 + 337).
    // HDMI wants two's complement per IEC 60958 with silence at 0, hence aud_s = 64*audio
    // with clipping at 32767, see WHY 64 below.
    //
    // Not {~audio[9], audio[8:0], 6'b0}: that would be 64*audio - 32768, the conversion from
    // offset binary, and assumes silence at 512. The sound would still come out right because
    // the mapping is affine and the sink is AC-coupled, but the idle value would be 0x8000,
    // the digital negative rail, and not even constant: aud_g = -2048*gain, i.e. 0 at volume
    // 0 and -32768 at volume 7. Every volume step would shift the stream by up to 30720 LSB:
    // a pop, and no headroom left for the sink.
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
    logic [15:0] aud_s, aud_p0, aud_p1;
    wire [16:0] aud_x64 = {1'b0, audio, 6'b0};      // 17 bits, up to 52288, always fits
    assign aud_s = (aud_x64 > 17'd32767) ? 16'd32767 : aud_x64[15:0];
    logic signed [21:0] aud_mul;
    logic [15:0] aud_g;
    always_ff @(posedge clk_core) aud_mul <= $signed(aud_s) * $signed({1'b0, gain});
    assign aud_g = aud_mul[19:4];   // /16, sign-correct
    always_ff @(posedge clk_pixel) begin
        aud_p0 <= aud_g;
        aud_p1 <= aud_p0;
    end
    logic [15:0] audio_sample_word [1:0];
    assign audio_sample_word[0] = aud_p1;
    assign audio_sample_word[1] = aud_p1;

    // Companion OSD in the 720p raster (active-low sync pulses from cx/cy)
    logic hdmi_hs_n, hdmi_vs_n;
    always_ff @(posedge clk_pixel) begin
        hdmi_hs_n <= !(cx >= 11'd1390 && cx < 11'd1430);
        hdmi_vs_n <= !(cy >= 10'd725 && cy < 10'd730);
    end
    // OSD data path from clk_core to clk_pixel: the strobe is a single clk_core pulse,
    // data and start flag stay stable until the next SPI byte.
    logic [2:0] osd_strobe_s = 0;
    logic [1:0] osd_start_s = 0;
    logic [7:0] osd_data_s0, osd_data_s1;
    always_ff @(posedge clk_pixel) begin
        osd_strobe_s <= {osd_strobe_s[1:0], mcu_osd_strobe};
        osd_start_s  <= {osd_start_s[0], mcu_start};
        osd_data_s0  <= mcu_data_out;
        osd_data_s1  <= osd_data_s0;
    end
    logic osd_strobe_p;
    // The OSD and the RA banner turn with the picture: in landscape 3x the monitor is
    // turned, so both are drawn rotated by 90 degrees. In portrait 2x they stay upright.
    // screen_rot changes only in the blanking interval (screen_p above), so no extra
    // register stage is needed.
    wire rot90 = ~screen_rot;
    assign osd_strobe_p = osd_strobe_s[1] & ~osd_strobe_s[2];

    /* ---------------- Scanlines ----------------------------------------
       Imitates the dark gaps between the lines of a CRT. Mixed in here,
       BEFORE the OSD, so that menu, banner and input test bar stay
       untouched. On a flat panel every original line otherwise becomes a
       solid block; the artists, however, worked with the gaps.

       Which line is darkened depends on the magnification:
         portrait  2x from y=72  -> every second line. 72 is even, cy[0] suffices.
         landscape 3x from y=24  -> every third. 24 is divisible by 3, so
                                    cy mod 3 == 2 suffices, the last of the triple.
       At 3x one line in three is dark instead of every second. That looks
       different from a CRT, but it is the best that can be done there.

       The counter stays aligned across frames because FRAME_H 768 is
       divisible by 3 and it is reset at cy == 0.

       Price: at 50 percent about half the brightness. Hence adjustable in
       steps and off by default. */
    logic [1:0] sl_row3;
    logic [9:0] cy_d;
    always_ff @(posedge clk_pixel) begin
        cy_d <= cy;
        if (cy != cy_d) begin
            if      (cy == 10'd0)       sl_row3 <= 2'd0;
            else if (sl_row3 == 2'd2) sl_row3 <= 2'd0;
            else                        sl_row3 <= sl_row3 + 2'd1;
        end
    end

    logic sl_dark;
    assign sl_dark = screen_rot ? cy[0] : (sl_row3 == 2'd2);

    function automatic logic [7:0] sl_dim(input logic [7:0] v, input logic [1:0] level);
        case (level)
            2'd1:    sl_dim = v - (v >> 2);   // a quarter less
            2'd2:    sl_dim = v >> 1;         // half less
            2'd3:    sl_dim = v >> 2;         // three quarters less
            default: sl_dim = v;
        endcase
    endfunction

    logic [23:0] rgb_sl;
    assign rgb_sl = (system_scanlines != 2'd0 && sl_dark)
                  ? { sl_dim(rgb[23:16], system_scanlines),
                      sl_dim(rgb[15:8],  system_scanlines),
                      sl_dim(rgb[7:0],   system_scanlines) }
                  : rgb;

    logic [5:0] osd_r, osd_g, osd_b;
    logic       osd_visible;
    osd_u8g2 osd (
        .clk(clk_pixel), .reset(!pll_lock), .rotate(rot90),
        .data_in_strobe(osd_strobe_p), .data_in_start(osd_start_s[1]), .data_in(osd_data_s1),
        .hs(hdmi_hs_n), .vs(hdmi_vs_n),
        .r_in(rgb_sl[23:18]), .g_in(rgb_sl[15:10]), .b_in(rgb_sl[7:2]),
        .r_out(osd_r), .g_out(osd_g), .b_out(osd_b),
        .visible(osd_visible)
    );
    assign osd_data_out = 8'h00;
    logic [23:0] rgb_osd;
    assign rgb_osd = {osd_r, osd_r[5:4], osd_g, osd_g[5:4], osd_b, osd_b[5:4]};

    // Input test bar (menu Controller -> Input test), raw bits from the Companion plus game signals
    logic [31:0] dbg_bits_p0, dbg_bits_p;
    logic [5:0]  dbg_map_p0, dbg_map_p;
    logic        hid_seen_p0, hid_seen_p, inputtest_p0, inputtest_p;
    always_ff @(posedge clk_pixel) begin
        dbg_bits_p0  <= {joystick[0], joystick_extra[0], joystick_ax[0], joystick_ay[0]};
        dbg_bits_p   <= dbg_bits_p0;
        dbg_map_p0   <= {joy_start2, joy_start1, joy_coin, joy_fire, joy_right, joy_left};
        dbg_map_p    <= dbg_map_p0;
        hid_seen_p0  <= hid_seen;        hid_seen_p  <= hid_seen_p0;
        inputtest_p0 <= system_inputtest; inputtest_p <= inputtest_p0;
    end
    logic        dbg_on;
    logic [23:0] dbg_col;
    generate
        if (TESTBAR) begin : g_testbar
            input_test_bar test_bar (
                .clk(clk_pixel), .enable(inputtest_p), .cx(cx), .cy(cy),
                .hid_seen(hid_seen_p), .bits(dbg_bits_p), .mapped(dbg_map_p),
                .on(dbg_on), .color(dbg_col)
            );
        end else begin : g_no_testbar
            assign dbg_on  = 1'b0;
            assign dbg_col = 24'h000000;
        end
    endgenerate
    // Banner for unlocks. Lies above the game picture but below the diagnostic
    // bars. The text arrives over the back channel of the RAM mirror.
    // The text buffer is written in the core clock and read in the pixel clock.
    // The write pulse therefore has to cross over. It is rare (one per frame) and
    // exactly one core clock wide: an edge detector after two registers
    // suffices, a queue would be effort without benefit here.
    logic [2:0] txt_we_s;
    logic [4:0] txt_addr_p;
    logic [7:0] txt_data_p;
    logic       banner_p0, banner_p;
    logic       gold_p, new_p;
    always_ff @(posedge clk_pixel) begin
        txt_we_s   <= {txt_we_s[1:0], ram_txt_we};
        txt_addr_p <= ram_txt_addr;
        txt_data_p <= ram_txt_data;
        banner_p0  <= ram_banner;
        banner_p   <= banner_p0;
        gold_p     <= ram_bgold;
        new_p      <= ram_bnew;
    end
    logic txt_we_p;
    assign txt_we_p = txt_we_s[1] & ~txt_we_s[2];

    logic        ra_on;
    logic [23:0] ra_col;
    ra_overlay ra_overlay_i (
        .clk(clk_pixel), .cx(cx), .cy(cy), .rotate(rot90),
        .txt_we(txt_we_p), .txt_addr(txt_addr_p), .txt_data(txt_data_p),
        .banner_on(banner_p), .banner_gold(gold_p), .banner_new(new_p),
        .on(ra_on), .color(ra_col)
    );
    logic [23:0] rgb_ra;
    assign rgb_ra = ra_on ? ra_col : rgb_osd;

    logic [23:0] rgb_dbg;
    assign rgb_dbg = dbg_on ? dbg_col : rgb_ra;

    // ---------------- SDRAM frame buffer: controller, write path, read path ----------------
    // Four generate branches, chosen by the diagnostic parameters (all 0 in the normal build):
    //   SDRAMTEST     sdram_fb plus the phase self test
    //   FBTEST        write path, fb_check reads every frame back
    //   FBSHOW/FBROT  picture from SDRAM, flat or rotated, always
    //   none          g_fb_live, the production path: the frame buffer runs alongside
    //                 the scaler and the menu switches between them at run time.
    // Shared by the three frame buffer branches below (FBTEST, FBSHOW/FBROT and the
    // production build): controller and write path are identical there, only the consumer
    // of the finished frames differs. The self test (SDRAMTEST) owns its own controller
    // instance because it has to reset it after every phase step.
    localparam logic [3:0] SDRAM_PSDA    = 4'd11;  // middle of the measured window 7..15
    localparam logic [1:0] SDRAM_CAP_OFS = 2'd1;   // read capture offset, measured by the self test
    logic        sdram_ready;
    logic [21:0] fb_wr_addr, fb_rd_addr;
    logic [31:0] fb_wr_din, fb_rd_dout;
    logic [1:0]  fb_wr_bank, fb_rd_bank;
    logic        fb_wr_req, fb_wr_ack;
    logic        fb_rd_req, fb_rd_ack, fb_rd_valid;
    logic        fb_wbuf, fb_frame_done, fb_ovf, fb_eaddr, fb_late, fb_active;
    logic [1:0]  fb_done_bank;
    logic [15:0] fb_done_words, fb_done_nz;
    logic [31:0] fb_done_sum;
    generate if (!SDRAMTEST) begin : g_fb
        assign sdram_psda = SDRAM_PSDA;
        // Reset comes from pll_sdram_lock alone: a game reset must not
        // restart the 200 us initialisation of the memory.
        sdram_fb #(.FREQ(64_800_000), .CAS(3'd2)) sdram_i (
            .SDRAM_DQ  (IO_sdram_dq),   .SDRAM_A   (O_sdram_addr),
            .SDRAM_DQM (O_sdram_dqm),   .SDRAM_BA  (O_sdram_ba),
            .SDRAM_nCS (O_sdram_cs_n),  .SDRAM_nWE (O_sdram_wen_n),
            .SDRAM_nRAS(O_sdram_ras_n), .SDRAM_nCAS(O_sdram_cas_n),
            .SDRAM_CKE (O_sdram_cke),
            .clk(clk_sdram), .resetn(pll_sdram_lock), .sdram_ready(sdram_ready),
            .cap_ofs(SDRAM_CAP_OFS),
            .wr_addr(fb_wr_addr), .wr_din(fb_wr_din), .wr_bank(fb_wr_bank),
            .wr_req(fb_wr_req), .wr_ack(fb_wr_ack),
            .rd_addr(fb_rd_addr), .rd_bank(fb_rd_bank),
            .rd_req(fb_rd_req), .rd_ack(fb_rd_ack),
            .rd_dout(fb_rd_dout), .rd_valid(fb_rd_valid)
        );
        fb_pack pack_i (
            .clk_core(clk_core), .r_in(video_r), .g_in(video_g), .b_in(video_b),
            .blankn(video_blankn), .vs(video_vs),
            .clk_sdram(clk_sdram), .sdram_ready(sdram_ready), .clear(s1 | system_reset[0]),
            .wr_addr(fb_wr_addr), .wr_din(fb_wr_din), .wr_bank(fb_wr_bank),
            .wr_req(fb_wr_req), .wr_ack(fb_wr_ack),
            .wbuf(fb_wbuf),            // consumed by the read path (fb_read_flat / fb_read_rotated)
            .frame_done(fb_frame_done), .done_bank(fb_done_bank),
            .done_words(fb_done_words), .done_sum(fb_done_sum), .done_nz(fb_done_nz),
            .err_overflow(fb_ovf), .err_addr(fb_eaddr)
        );
    end endgenerate

    generate
    if (SDRAMTEST) begin : g_sdram_test
        logic        sdram_ready, sdram_resetn;
        logic [21:0] sd_wr_addr, sd_rd_addr;
        logic [31:0] sd_wr_din,  sd_rd_dout;
        logic [1:0]  sd_wr_bank, sd_rd_bank;
        logic        sd_wr_req,  sd_wr_ack;
        logic        sd_rd_req,  sd_rd_ack, sd_rd_valid;
        logic [1:0]  sd_cap_ofs;
        // The self test adjusts the phase itself, with 31 ms of rest after every change: 63 us
        // is too short for the PLL to take over the new phase, see SETTLE in sdram_selftest.sv.

        sdram_fb #(.FREQ(64_800_000), .CAS(SDRAMCL3 ? 3'd3 : 3'd2)) sdram_i (
            .SDRAM_DQ  (IO_sdram_dq),   .SDRAM_A   (O_sdram_addr),
            .SDRAM_DQM (O_sdram_dqm),   .SDRAM_BA  (O_sdram_ba),
            .SDRAM_nCS (O_sdram_cs_n),  .SDRAM_nWE (O_sdram_wen_n),
            .SDRAM_nRAS(O_sdram_ras_n), .SDRAM_nCAS(O_sdram_cas_n),
            .SDRAM_CKE (O_sdram_cke),
            .clk(clk_sdram), .resetn(sdram_resetn), .sdram_ready(sdram_ready),
            .cap_ofs(sd_cap_ofs),
            .wr_addr(sd_wr_addr), .wr_din(sd_wr_din), .wr_bank(sd_wr_bank),
            .wr_req(sd_wr_req), .wr_ack(sd_wr_ack),
            .rd_addr(sd_rd_addr), .rd_bank(sd_rd_bank),
            .rd_req(sd_rd_req), .rd_ack(sd_rd_ack),
            .rd_dout(sd_rd_dout), .rd_valid(sd_rd_valid)
        );

        // The self test owns the controller's reset because the SDRAM has to be
        // re-initialised after every phase change. In normal operation (g_fb above)
        // resetn comes from pll_sdram_lock alone.
        // s1 additionally clears the result table so that the cold measurement is
        // repeatable (and, as always, resets the game on the side).
        sdram_selftest #(.WORDS_LOG2(19)) selftest_i (
            .clk(clk_sdram), .pll_lock(pll_sdram_lock), .clear(s1),
            .ctrl_resetn(sdram_resetn), .sdram_ready(sdram_ready),
            .wr_addr(sd_wr_addr), .wr_din(sd_wr_din), .wr_bank(sd_wr_bank),
            .wr_req(sd_wr_req), .wr_ack(sd_wr_ack),
            .rd_addr(sd_rd_addr), .rd_bank(sd_rd_bank),
            .rd_req(sd_rd_req), .rd_ack(sd_rd_ack),
            .rd_dout(sd_rd_dout), .rd_valid(sd_rd_valid),
            .psda(sdram_psda), .cap_ofs(sd_cap_ofs),
            .clk_pixel(clk_pixel), .cx(cx), .cy(cy),
            .bar_on(st_on), .bar_color(st_col), .leds(st_led)
        );
    end else if (FBTEST) begin : g_fb_write
        // ---- FBTEST: the write path ----
        // Every core frame goes into the SDRAM, the picture on the screen still comes from
        // the scaler. fb_check reads every finished frame back immediately and compares the
        // checksum. The phase is fixed at the value measured by the self test.
        fb_check check_i (
            .clk_sdram(clk_sdram), .sdram_ready(sdram_ready),
            .frame_done(fb_frame_done), .done_bank(fb_done_bank),
            .done_words(fb_done_words), .done_sum(fb_done_sum),
            .err_overflow(fb_ovf), .err_addr(fb_eaddr),
            .done_nz(fb_done_nz), .clear(s1),
            .rd_addr(fb_rd_addr), .rd_bank(fb_rd_bank),
            .rd_req(fb_rd_req), .rd_ack(fb_rd_ack),
            .rd_dout(fb_rd_dout), .rd_valid(fb_rd_valid),
            .clk_pixel(clk_pixel), .cx(cx), .cy(cy),
            .bar_on(st_on), .bar_color(st_col), .leds(st_led)
        );
    end else if (FBSHOW || FBROT) begin : g_fb_show
        // ---- measurement builds: FBSHOW (not rotated) and FBROT (rotated) ----
        // FBSHOW shows the picture unrotated (proof of the path), FBROT rotated.
        if (FBROT) begin : g_rot
            fb_read_rotated #(.X0(416), .Y0(72), .ROT_CCW(0)) rot_i (
                .clk_sdram(clk_sdram), .sdram_ready(sdram_ready),
                .wbuf(fb_wbuf), .frame_done(fb_frame_done),
                .rd_addr(fb_rd_addr), .rd_bank(fb_rd_bank),
                .rd_req(fb_rd_req), .rd_ack(fb_rd_ack),
                .rd_dout(fb_rd_dout), .rd_valid(fb_rd_valid),
                .err_late(fb_late),
                .clk_pixel(clk_pixel), .cx(cx), .cy(cy),
                .rgb(rgb_fb), .active(fb_active), .clear(s1 | system_reset[0])
            );
        end else begin : g_flat
            fb_read_flat #(.X0(208), .Y0(24)) flat_i (
                .clk_sdram(clk_sdram), .sdram_ready(sdram_ready),
                .wbuf(fb_wbuf), .frame_done(fb_frame_done),
                .rd_addr(fb_rd_addr), .rd_bank(fb_rd_bank),
                .rd_req(fb_rd_req), .rd_ack(fb_rd_ack),
                .rd_dout(fb_rd_dout), .rd_valid(fb_rd_valid),
                .err_late(fb_late),
                .clk_pixel(clk_pixel), .cx(cx), .cy(cy),
                .rgb(rgb_fb), .active(fb_active), .clear(s1 | system_reset[0])
            );
        end

        // No panel in the picture: the proof IS the picture. The flags go to the LEDs.
        // The order is chosen so that a black screen can be told apart:
        //   LED6 picture content present   LED5 SDRAM ready         LED4 group/line too late
        //   LED3 FIFO overflow             LED2 address error       LED1 output running
        // LED5 off means: the SDRAM PLL or the initialisation hangs.
        // LED5 on and LED1 off means: two complete frames were never counted.
        assign st_on  = 1'b0;
        assign st_col = 24'h000000;
        assign st_led = {|fb_done_nz, sdram_ready, fb_late, fb_ovf, fb_eaddr, fb_active};
    end else begin : g_fb_live
        // ---- g_fb_live, the normal case. Both picture paths are built, the menu
        // chooses. The frame buffer always runs along so that switching takes effect at once.
        fb_read_rotated #(.X0(416), .Y0(72), .ROT_CCW(0)) rot_i (
            .clk_sdram(clk_sdram), .sdram_ready(sdram_ready),
            .wbuf(fb_wbuf), .frame_done(fb_frame_done),
            .rd_addr(fb_rd_addr), .rd_bank(fb_rd_bank),
            .rd_req(fb_rd_req), .rd_ack(fb_rd_ack),
            .rd_dout(fb_rd_dout), .rd_valid(fb_rd_valid),
            .err_late(fb_late),
            .clk_pixel(clk_pixel), .cx(cx), .cy(cy),
            .rgb(rgb_fb), .active(fb_active), .clear(s1 | system_reset[0])
        );

        // In the normal case the usual LED assignment applies; st_led is not used.
        assign st_on  = 1'b0;
        assign st_col = 24'h000000;
        assign st_led = 6'd0;
    end
    endgenerate

    // NETS FIRST, THEN THE INSTANCES. If a net is used in a port connection before it is
    // declared, Verilog silently creates an implicit 1-bit net: an eight-bit data path then
    // quietly becomes one bit wide, and an enable can stand there with no driver at all.
    // That is why counters and source switching sit up here.
    //
    // Measured with GowinSynthesis 1.9.11.03: at MODULE LEVEL Gowin merges the implicit
    // net with the later declaration and gets the width right, it only reports EX3638.
    // INSIDE a generate block it does not: there a separate, one-bit, driverless net
    // remains, and the build goes through. `default_nettype none at the top of this file
    // catches both, the rule "nets first, then the instances" remains the better style
    // nonetheless.

    // When a transfer begins, the write side starts over as well.
    logic [1:0] snap_run_s = 0;
    always_ff @(posedge clk_core) snap_run_s <= {snap_run_s[0], snap_run};
    wire snap_run_rise = snap_run_s[0] & ~snap_run_s[1];

    // The oracle: the write accesses during the harvest. Its 1536 bytes
    // append themselves behind the 5120 payload bytes in the same FIFO, so the checksum
    // covers them as well, and the SPI block sees only a longer body.
    logic [7:0]  log_byte;
    logic [9:0]  log_count;
    logic        log_ovf;

    // Source switching of the FIFO. The core does not count its 5120 bytes itself, so the
    // top counts the pushed bytes: that is at the same time the point at which the oracle
    // log takes over.
    logic [12:0] push_n = 0;
    wire         log_phase = (push_n >= RAM_MIRROR_DATA);
    wire         log_push  = log_phase && !snap_full && (push_n < RAM_MIRROR_BODY);
    wire         fifo_push = log_phase ? log_push : snap_push;
    wire [7:0]   fifo_wdat = log_phase ? log_byte : snap_byte;
    always_ff @(posedge clk_core) begin
        if (snap_run_rise) begin
            push_n   <= 13'd0;
        end else if (fifo_push && !snap_full) push_n <= push_n + 13'd1;
    end

    snap_log #(.DEPTH(512)) snap_log_i (
        .clk(clk_core), .harv_busy(snap_harv),
        .ram_we(dbg_ram_we), .ram_addr(dbg_ram_addr), .ram_data(dbg_ram_data),
        .send_start(snap_run_rise), .send_pop(log_push), .send_byte(log_byte),
        .count(log_count), .overflow(log_ovf)
    );

    // The look-ahead FIFO decouples core clock and SPI clock. The core delivers one byte per
    // round (323 ns), the line fetches one per 1.2 us: eight places go a long way.
    snap_fifo snap_fifo_i (
        .wclk(clk_core), .wreset(snap_run_rise), .wdata(fifo_wdat), .wpush(fifo_push),
        .wfull(snap_full),
        .rclk(spi_sck), .rss(spi_csn), .rpop(snap_pop),
        .rdata(snap_fifo_q), .rempty(snap_empty), .rundr(snap_undr)
    );


    // Checksum over the delivered payload bytes, formed AT THE SOURCE: here stands exactly
    // what the core put into the FIFO. The Pico computes the same over what arrives at its
    // end and compares. Header and footer only bracket the transfer and say nothing about
    // the 6656 bytes in between (5120 payload + 1536 oracle log); this sum checks every
    // single one.
    // It thereby catches a byte delivered twice as well, and more reliably than the
    // underrun bit: it needs no assumption about WHEN something could go wrong.
    // Rotate left before combining, otherwise the order would not matter and a byte
    // swap would go unnoticed.
    logic [15:0] snap_sum = 0;
    always_ff @(posedge clk_core) begin
        if (snap_run_rise)  snap_sum <= 16'd0;
        else if (fifo_push && !snap_full)
            snap_sum <= {snap_sum[14:0], snap_sum[15]} ^ {8'h00, fifo_wdat};
    end

    ram_spi ram_spi_i (
        .clk(clk_core), .reset(!pll_lock),
        .spi_ss(spi_csn), .spi_clk(spi_sck),
        .strobe(mcu_ram_strobe), .start(mcu_start), .data_in(mcu_data_out),
        .data_out(ram_data_out),
        .fifo_data(snap_fifo_q), .fifo_empty(snap_empty), .fifo_pop(snap_pop),
        .fifo_undr(snap_undr),   .body_sum(snap_sum),
        .log_count(log_count),   .log_ovf(log_ovf),
        .pico_rc(ram_rc),        .pico_us(ram_us),   .pico_last(ram_last),
        .txt_we(ram_txt_we), .txt_addr(ram_txt_addr), .txt_data(ram_txt_data),
        .banner_on(ram_banner), .banner_gold(ram_bgold), .banner_new(ram_bnew),
        .undr_pos(),   // not shown: row 2 of ram_diag carries the fill level of the
                       // catch-up queue and the achievement number instead
        .frame_no(snap_frame), .harv_busy(snap_harv), .run(snap_run), .underrun(),
        .last_count(ram_last_count), .last_us(ram_last_us),
        .pico_verdict(ram_verdict), .transfers()
    );

    // RAMDIAG: the measurement block shares the result bar with the SDRAM diagnostic
    // blocks above, only one of them is ever built.
    logic        rd_on;
    logic [23:0] rd_col;
    logic [5:0]  rd_led;
    generate
    if (RAMDIAG) begin : g_ramdiag
        ram_diag diag_i (
            .clk_core(clk_core), .ram_we(dbg_ram_we), .ram_addr(dbg_ram_addr),
            .ram_data(dbg_ram_data), .vcnt(dbg_vcnt),
            .spi_count(ram_last_count), .spi_us(ram_last_us), .spi_verdict(ram_verdict),
            .rc_calc_us(ram_us),
            .catchup_peak_and_ach({snap_catchup_peak[7:0], ram_last}),
            .rc_loaded_and_fired(ram_rc),
            .clk_pixel(clk_pixel), .cx(cx), .cy(cy),
            .bar_on(rd_on), .bar_color(rd_col), .leds(rd_led)
        );
    end else begin : g_no_ramdiag
        assign rd_on = 1'b0; assign rd_col = 24'h000000; assign rd_led = 6'd0;
    end
    endgenerate

    // The result bar lies on top of everything, above OSD and input test bar.
    logic [23:0] rgb_hdmi;
    assign rgb_hdmi = rd_on ? rd_col : (st_on ? st_col : rgb_dbg);

    logic [2:0] tmds;
    logic       tmds_clock;
    hdmi #(
        .VIDEO_ID_CODE(4), .DVI_OUTPUT(0), .VIDEO_REFRESH_RATE(60), .IT_CONTENT(1),
        .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16), .START_X(0), .START_Y(0),
        .FRAME_W(1584), .FRAME_H(768), .SYNC_X(0), .SYNC_Y(20),
        .VENDOR_NAME({"game20k", 8'd0}), .PRODUCT_DESCRIPTION({"Galaga", 80'd0})
    ) hdmi_i (
        .clk_pixel_x5     (clk_x5),
        .clk_pixel        (clk_pixel),
        .clk_audio        (clk_audio),
        .reset            (1'b0),
        .sync             (sync),
        .rgb              (rgb_hdmi),
        .audio_sample_word(audio_sample_word),
        .tmds             (tmds),
        .tmds_clock       (tmds_clock),
        .cx               (cx),
        .cy               (cy),
        .frame_width      (),
        .frame_height     (),
        .screen_width     (),
        .screen_height    ()
    );

    ELVDS_OBUF tmds_bufds [3:0] (
        .I ({clk_pixel, tmds}),
        .O ({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
    );

    // ---------------- Sigma-delta audio on the pins of the original port ----------------
    // Computed unipolar, independent of the HDMI path: silence is duty cycle 0 at EVERY
    // volume. Not aud_g[15:6] ^ 10'h200: that flips the sign bit of the HDMI word back to
    // offset binary and inherits its idle level, which depends on the volume: at silence a
    // duty cycle of up to 50 percent, i.e. up to 1.65 V DC and a 9.28 MHz square wave with
    // full swing on pin 77.
    //
    // Deriving it from aud_s would be possible but would cost half the amplitude (silence
    // sits at the lower edge there, so only half the range is left). Hence the separate
    // computation: 817/1024 = 79.8 percent duty cycle at full scale instead of 49.8.
    // 1023*16 = 16368 < 2^14, no overflow.
    //
    // Touchstone on the device: multimeter on pin 77 against ground, game idle.
    // 0.00 V means correct, 1.65 V means offset binary has crept back in.
    logic [13:0] aud_u_mul;
    always_ff @(posedge clk_core) aud_u_mul <= audio * gain;   // /16 follows below
    logic [10:0] sd_acc = 0;
    always_ff @(posedge clk_core) sd_acc <= {1'b0, sd_acc[9:0]} + {1'b0, aud_u_mul[13:4]};
    assign pwm_audio_l = sd_acc[10];
    
    // ---------------- LEDs (active low) ----------------
    logic [23:0] blink = 0;
    always_ff @(posedge clk_core) blink <= blink + 24'd1;
    logic vs_seen = 0;
    always_ff @(posedge clk_core) if (!video_vs) vs_seen <= 1'b1;
    // LED 1 blinker, 2 HID seen, 3 stick active, 4 vsync, 5 ROM loaded, 6 PLL
    // Repurposed in the self test (that is a diagnostic stage): LED1..LED4 = running stage
    // in binary, LED5 = an error already in this stage, LED6 = heartbeat. If LED6 stands
    // still, the test hangs, whatever the bar in the picture shows.
    assign led = RAMDIAG ? ~rd_led
               : (SDRAMTEST || FBTEST || FBSHOW || FBROT) ? ~st_led
                           : ~{pll_lock, rom_loaded, vs_seen, |{joystick[0], joystick_extra[0]}, hid_seen, rom_busy ? rom_count[9] : blink[23]};
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
