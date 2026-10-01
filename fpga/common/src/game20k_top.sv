// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file game20k_top.sv
//! @brief Top level of the arcade platform on the Tang Nano 20K: game, HDMI, SDRAM, Companion.
//!
//! One top for every game. The game sits behind game_core (fpga/<core>/src/game_core.sv),
//! its raster, name and test bar labels come from game_pkg (fpga/<core>/src/game_pkg.sv),
//! its ROM layout from rom_map_pkg, which build.tcl generates from the game's manifest.
//! Video and audio go out over HDMI.
//!
//! Clocks: 27 MHz crystal and TWO PLLs. pll_hdmi produces clk_x5 (371.25 MHz) and clk_core
//! (18.5625 MHz), clkdiv5 divides clk_x5 down to clk_pixel (74.25 MHz). pll_sdram provides
//! a separate 64.8 MHz for the frame buffer in SDRAM.
//!
//! Buttons: S1 = reset. S2 = OSD button, reported to the Companion. Coin and start come
//! from the arcade stick via the Companion, not from S2.
//!
//! Video: landscape through arcade_scaler (3x), portrait through the SDRAM frame buffer
//! with fb_read_rotated (2x). Switched at run time from the menu, not at synthesis.
//!
//! Audio: embedded in the HDMI stream and, in addition, as sigma-delta on pwm_audio_l.
//!
//! SD card: attached to the FPGA (sd_card from Nanomig), operated by the Companion over
//! SPI. The game's ROM file reaches the core's ROM memories the same way.
//!
//! The build parameters below are DIAGNOSTIC builds only and are all 0 in the normal
//! build. They are set through environment variables, see build.tcl. The production
//! branch is g_fb_live.
module game20k_top #(
    parameter bit TESTBAR   = 1,   //!< synthesise the input test bar (1 BSRAM)
    parameter bit ROMVIEW   = 0,   //!< 1: a diagnostic view of the game's own (Galaga: the character ROM)
    parameter bit SDRAMTEST = 0,   //!< 1: SDRAM controller plus phase self test
    parameter bit SDRAMCL3  = 0,   //!< 1: CAS latency 3 instead of 2 (self test comparison run)
    parameter bit FBTEST    = 0,   //!< 1: write path plus cross-check (fb_check)
    parameter bit FBSHOW    = 0,   //!< 1: picture from the SDRAM, not rotated
    parameter bit FBROT     = 0,   //!< 1: picture from the SDRAM, ROTATED 2x
    parameter bit RAMDIAG   = 0    //!< 1: the game's RAM mirror result bar (Galaga: ram_diag)
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
    import game_pkg::*;         // raster, name and test bar labels of the game
    import rom_map_pkg::*;      // ROM layout of the game, generated from its manifest

    // ---------------- Picture geometry in the 720p raster, from the core raster W x H ----------------
    // Landscape 3x through the scaler, the picture centred. Portrait 2x from the frame buffer,
    // the picture turned, so its height is W. The banner (ra_overlay) sits 52 px below the
    // picture: in portrait along the bottom edge, in landscape in the band right of it,
    // rotated like the OSD. Galaga: landscape 208..1072 x 24..696, portrait 416..864 x 72..648.
    localparam int X0_L = (1280 - 3 * W) / 2;
    localparam int Y0_L = (720 - 3 * H) / 2;
    localparam int X0_P = (1280 - 2 * H) / 2;
    localparam int Y0_P = (720 - 2 * W) / 2;
    localparam int BANNER_BX = (1280 - 384) / 2;
    localparam int BANNER_BY = Y0_P + 2 * W + 52;
    localparam int BANNER_RX = X0_L + 3 * W + 52;
    localparam int BANNER_RY = (720 - 384) / 2;
    // ---------------- Clocks ----------------
    logic clk_x5, clk_pixel, clk_core, pll_lock;
    pll_hdmi pll (.clkin(sys_clk), .clkout(clk_x5), .clkoutd(clk_core), .lock(pll_lock));
    clkdiv5  div (.hclkin(clk_x5), .resetn(pll_lock), .clkout(clk_pixel));

    // ---------------- Reset ----------------
    // rst_no counts the ends of core resets, whatever caused them: S1, R from the
    // Companion, a ROM load, a lost PLL lock. The RAM mirror carries it (header byte 8),
    // and the Pico starts the achievements over when it changes: also after S1, which
    // the Pico does not see otherwise.
    logic [1:0] s1_s = 0;
    logic [7:0] rst_cnt = 0;
    logic       reset = 1;
    logic [7:0] rst_no = 0;
    always_ff @(posedge clk_core) begin
        s1_s <= {s1_s[0], s1};
        if (!pll_lock || s1_s[1] || system_reset[0] || !rom_loaded) begin
            rst_cnt <= 8'd0;
            reset   <= 1'b1;
        end else if (rst_cnt != 8'hFF)
            rst_cnt <= rst_cnt + 8'd1;
        else if (reset) begin
            reset  <= 1'b0;
            rst_no <= rst_no + 8'd1;   // the core leaves reset: a new game
        end
    end

    //! Header byte 9 of the RAM mirror: one bit per diagnostic parameter, 0 in a release
    //! build. The Pico allows no hardcore on a core built for measurements. TESTBAR is
    //! left out, it only adds a display aid.
    localparam logic [7:0] BUILD_FLAGS = {1'b0, RAMDIAG, FBROT, FBSHOW, FBTEST, SDRAMCL3, SDRAMTEST, ROMVIEW};

    // ---------------- S2: OSD button, reported to the Companion ----------------
    logic [1:0]  s2_s = 0;
    always_ff @(posedge clk_core) s2_s <= {s2_s[0], s2};

    // ---------------- The game ----------------
    logic [2:0] video_r, video_g;
    logic [1:0] video_b;
    logic        log_we;         // the game's RAM writes, flat mirror address, observation only
    logic [15:0] log_addr;
    logic [7:0]  log_data;
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
    logic [7:0]  ram_flags;   // header byte 5 from the Pico, bit 0: a challenge is on
    logic [7:0]  snap_byte, snap_fifo_q;
    logic [15:0] snap_frame;
    logic        snap_harv;
    logic        video_blankn, video_hs, video_vs;
    logic signed [15:0] audio;   // two's complement, silence = 0
    logic [15:0] map_bits;       // the game signals for the input test bar
    logic        rd_on;          // result bar of the RAMDIAG build, from the game
    logic [23:0] rd_col;
    logic [5:0]  rd_led;

    game_core #(.ROMVIEW(ROMVIEW), .RAMDIAG(RAMDIAG)) game (
        .clk_core(clk_core), .reset(reset),
        .video_r(video_r), .video_g(video_g), .video_b(video_b),
        .video_blankn(video_blankn), .video_vs(video_vs), .video_hs(video_hs),
        .audio(audio),
        .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data), .rom_wr_en(rom_wr_en),
        .cfg_we(cfg_we), .cfg_id(cfg_id), .cfg_val(cfg_val),
        .p1_dir(joystick[0][3:0]), .p2_dir(joystick[1][3:0]),
        .p1_fire(joy_fire), .p2_fire(joy_fire2),
        .p1_btns(btns), .p2_btns(btns2),
        .coin(joy_coin), .start1(joy_start1), .start2(joy_start2),
        .map_bits(map_bits),
        .snap_run(snap_run), .snap_full(snap_full),
        .snap_push(snap_push), .snap_byte(snap_byte), .snap_frame(snap_frame),
        .snap_harv(snap_harv),
        .log_we(log_we), .log_addr(log_addr), .log_data(log_data),
        .clk_pixel(clk_pixel), .cx(cx), .cy(cy),
        .diag_spi_count(ram_last_count), .diag_spi_us(ram_last_us),
        .diag_spi_verdict(ram_verdict), .diag_rc_us(ram_us), .diag_rc_lf(ram_rc),
        .diag_last_ach(ram_last),
        .diag_on(rd_on), .diag_color(rd_col), .diag_leds(rd_led)
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
    logic [15:0] rom_wr_addr;
    logic [7:0]  rom_wr_data;
    logic [15:0] rom_wr_en;

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

    // Distributes the bytes of the game's ROM file to the core's ROM memories, as the
    // manifest lays them out. The file arrives from the SD card via the Companion,
    // rom_loaded reports completion to the LEDs.
    rom_loader #(.SLOT(0), .TOTAL(ROM_TOTAL), .SECTIONS(ROM_SECTIONS), .OFFSETS(ROM_OFFSETS)) loader (
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
    logic [7:0] snap_rst_no = 8'd0;   // reset count as of the last snapshot, header byte 8
    always_ff @(posedge clk_core) begin
        harv_d <= snap_harv;
        if (int_ack[5]) snap_int <= 1'b0;
        if (harv_d && !snap_harv) begin
            snap_int    <= 1'b1;
            // Taken when the harvest ENDS. In reset no harvest starts or ends (vcnt and
            // the slot counter stand still), so a snapshot finished before a reset keeps
            // the old count and one finished after it carries the new one, even if the
            // reset cut into it.
            snap_rst_no <= rst_no;
        end
    end
    logic [7:0] sdc_data_out;
    logic [1:0] mcu_leds;
    logic [23:0] mcu_color;
    logic [1:0] system_reset, system_scanlines;
    logic [2:0] system_volume;
    logic       cfg_we;             // one clock per value the Companion sets, for the game
    logic [7:0] cfg_id, cfg_val;
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

    sysctrl sysctrl (
        .clk(clk_core), .reset(!pll_lock),
        .data_in_strobe(mcu_sys_strobe), .data_in_start(mcu_start), .data_in(mcu_data_out), .data_out(sys_data_out),
        // interrupt bits: 1 = HID, 3 = SD card, 5 = RAM mirror snapshot ready
        .int_out_n(spi_irqn), .int_in({2'b00, snap_int, 1'b0, sdc_int, 1'b0, hid_int, 1'b0}), .int_ack(int_ack),
        .buttons({s2_s[1], s1_s[1]}),     // [0] = S1 reset, [1] = S2 OSD
        .leds(mcu_leds), .color(mcu_color),
        .system_reset(system_reset), .system_scanlines(system_scanlines),
        .system_volume(system_volume), .system_inputtest(system_inputtest),
        .system_fire_btn(system_fire_btn), .system_coin_btn(system_coin_btn),
        .system_start_btn(system_start_btn), .system_start2_btn(system_start2_btn),
        .system_voldn_btn(system_voldn_btn), .system_volup_btn(system_volup_btn),
        .system_screen(system_screen),
        .cfg_we(cfg_we), .cfg_id(cfg_id), .cfg_val(cfg_val)
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
    logic [11:0] btns, btns2;
    assign btns  = {joystick_extra[0], joystick[0][7:4]};   // btns[n-1] = HID button n
    assign btns2 = {joystick_extra[1], joystick[1][7:4]};   // the second controller
    function automatic logic btn_sel(input logic [3:0] n, input logic [11:0] b);
        btn_sel = (n == 4'd0 || n > 4'd12) ? 1'b0 : b[n - 4'd1];
    endfunction
    // Directions go to the game as they are, the buttons through the menu's mapping. The
    // second controller uses the same mapping. Coin, start and volume come from the first.
    logic joy_fire, joy_fire2, joy_coin, joy_start1, joy_start2, joy_voldn, joy_volup;
    assign joy_fire   = (system_fire_btn == 4'd0) ? |btns  : btn_sel(system_fire_btn, btns);
    assign joy_fire2  = (system_fire_btn == 4'd0) ? |btns2 : btn_sel(system_fire_btn, btns2);
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

    arcade_scaler #(.W(W), .H(H), .X0(X0_L), .Y0(Y0_L)) scaler (
        .clk_core (clk_core),
        .r_in     (video_r),
        .g_in     (video_g),
        .b_in     (video_b),
        .blankn   (video_blankn),
        .vs       (video_vs),
        .clk_pixel(clk_pixel),
        .cx       (cx),
        .cy       (cy),
        .sync     (sync),
        .rgb      (rgb_scaler),
        .dbg_we   (),                 // write-side taps of the scaler: nothing reads them
        .dbg_x    (),
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
    // Volume, then into the pixel clock domain. The game delivers two's complement with
    // silence at 0 (HDMI wants that per IEC 60958), the scale is the game's business: a
    // unipolar core such as Galaga delivers 0..32767, see its game_core.
    logic [15:0] aud_p0, aud_p1;
    logic signed [21:0] aud_mul;
    logic [15:0] aud_g;
    always_ff @(posedge clk_core) aud_mul <= audio * $signed({1'b0, gain});
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
    logic [15:0] dbg_map_p0, dbg_map_p;
    logic        hid_seen_p0, hid_seen_p, inputtest_p0, inputtest_p;
    always_ff @(posedge clk_pixel) begin
        dbg_bits_p0  <= {joystick[0], joystick_extra[0], joystick_ax[0], joystick_ay[0]};
        dbg_bits_p   <= dbg_bits_p0;
        dbg_map_p0   <= map_bits;
        dbg_map_p    <= dbg_map_p0;
        hid_seen_p0  <= hid_seen;        hid_seen_p  <= hid_seen_p0;
        inputtest_p0 <= system_inputtest; inputtest_p <= inputtest_p0;
    end
    logic        dbg_on;
    logic [23:0] dbg_col;
    generate
        if (TESTBAR) begin : g_testbar
            input_test_bar #(.MAP_N(MAP_N), .MAP_LABELS(MAP_LABELS)) test_bar (
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
    logic       chal_p0, chal_p;      // a challenge is on, header byte 5 bit 0
    always_ff @(posedge clk_pixel) begin
        txt_we_s   <= {txt_we_s[1:0], ram_txt_we};
        txt_addr_p <= ram_txt_addr;
        txt_data_p <= ram_txt_data;
        banner_p0  <= ram_banner;
        banner_p   <= banner_p0;
        gold_p     <= ram_bgold;
        new_p      <= ram_bnew;
        chal_p0    <= ram_flags[0] & ~reset;   // no challenge in a game that is being reset
        chal_p     <= chal_p0;
    end
    logic txt_we_p;
    assign txt_we_p = txt_we_s[1] & ~txt_we_s[2];

    logic        ra_on;
    logic [23:0] ra_col;
    ra_overlay #(.BX(BANNER_BX), .BY(BANNER_BY), .RX(BANNER_RX), .RY(BANNER_RY)) ra_overlay_i (
        .clk(clk_pixel), .cx(cx), .cy(cy), .rotate(rot90),
        .txt_we(txt_we_p), .txt_addr(txt_addr_p), .txt_data(txt_data_p),
        .banner_on(banner_p), .banner_gold(gold_p), .banner_new(new_p),
        .challenge_on(chal_p),
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
        fb_pack #(.W(W), .H(H)) pack_i (
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
        fb_check #(.W(W), .H(H)) check_i (
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
            fb_read_rotated #(.W(W), .H(H), .X0(X0_P), .Y0(Y0_P), .ROT_CCW(ROT_CCW)) rot_i (
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
            fb_read_flat #(.W(W), .H(H), .X0(X0_L), .Y0(Y0_L)) flat_i (
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
        fb_read_rotated #(.W(W), .H(H), .X0(X0_P), .Y0(Y0_P), .ROT_CCW(ROT_CCW)) rot_i (
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
    // append themselves behind the payload bytes (5120 for Galaga) in the same FIFO, so the
    // checksum covers them as well, and the SPI block sees only a longer body.
    logic [7:0]  log_byte;
    logic [9:0]  log_count;
    logic        log_ovf;

    // Source switching of the FIFO. The core does not count its payload bytes itself, so the
    // top counts the pushed bytes: that is at the same time the point at which the oracle
    // log takes over.
    logic [15:0] push_n = 0;
    wire         log_phase = (push_n >= RAM_MIRROR_DATA);
    wire         log_push  = log_phase && !snap_full && (push_n < RAM_MIRROR_BODY);
    wire         fifo_push = log_phase ? log_push : snap_push;
    wire [7:0]   fifo_wdat = log_phase ? log_byte : snap_byte;
    always_ff @(posedge clk_core) begin
        if (snap_run_rise) begin
            push_n   <= 16'd0;
        end else if (fifo_push && !snap_full) push_n <= push_n + 16'd1;
    end

    snap_log #(.DEPTH(512)) snap_log_i (
        .clk(clk_core), .harv_busy(snap_harv),
        .ram_we(log_we), .ram_addr(log_addr), .ram_data(log_data),
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
    // the bytes in between (for Galaga 6656: 5120 payload + 1536 oracle log); this sum
    // checks every single one.
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
        .ra_flags(ram_flags), .rst_no(snap_rst_no), .build_flags(BUILD_FLAGS),
        .undr_pos(),   // not shown: row 2 of ram_diag carries the fill level of the
                       // catch-up queue and the achievement number instead
        .frame_no(snap_frame), .harv_busy(snap_harv), .run(snap_run), .underrun(),
        .last_count(ram_last_count), .last_us(ram_last_us),
        .pico_verdict(ram_verdict), .transfers()
    );

    // The result bar of the RAMDIAG build (rd_*, from the game) shares the place with the
    // SDRAM diagnostic blocks above, only one of them is ever built. It lies on top of
    // everything, above OSD and input test bar.
    logic [23:0] rgb_hdmi;
    assign rgb_hdmi = rd_on ? rd_col : (st_on ? st_col : rgb_dbg);

    logic [2:0] tmds;
    logic       tmds_clock;
    hdmi #(
        .VIDEO_ID_CODE(4), .DVI_OUTPUT(0), .VIDEO_REFRESH_RATE(60), .IT_CONTENT(1),
        .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16), .START_X(0), .START_Y(0),
        .FRAME_W(1584), .FRAME_H(768), .SYNC_X(0), .SYNC_Y(20),
        .VENDOR_NAME({"game20k", 8'd0}), .PRODUCT_DESCRIPTION(PRODUCT_DESCRIPTION)
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
    // Unipolar from the positive half of the sample: silence is duty cycle 0 at EVERY
    // volume, a negative sample counts as silence. Not aud_g[15:6] ^ 10'h200: that flips
    // the sign bit of the HDMI word back to offset binary and inherits its idle level,
    // which depends on the volume: at silence a duty cycle of up to 50 percent, i.e. up to
    // 1.65 V DC and a 9.28 MHz square wave with full swing on pin 77.
    //
    // For a unipolar core (Galaga: 0..32767 after its scale) this is 49.8 percent duty
    // cycle at full scale, and the loudest peaks, which the game clips at 32767 for HDMI,
    // clip here too. A bipolar core loses its negative half on this pin; the pin is the
    // legacy analogue output, HDMI carries the full signal.
    //
    // Touchstone on the device: multimeter on pin 77 against ground, game idle.
    // 0.00 V means correct, 1.65 V means offset binary has crept back in.
    logic [10:0] sd_acc = 0;
    always_ff @(posedge clk_core) sd_acc <= {1'b0, sd_acc[9:0]} + {1'b0, aud_g[15] ? 10'd0 : aud_g[15:6]};
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
