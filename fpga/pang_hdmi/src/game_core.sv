// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file game_core.sv
//! @brief Pang and Super Pang behind the game interface of the platform top (game20k).
//!
//! The platform top (fpga/common/src/game20k_top.sv) knows only this module and game_pkg.
//! Here it wraps jotego's jtpang (src/jtcores, see its README.md) and stands in for
//! jtpang_game.v and the JTFRAME top around it: the clock enables, the five ROM buses, the
//! EEPROM load and the audio mix. One bitstream runs both games, from the same core.
//!
//! The ROM image lies in SDRAM (pang.manifest): the program twice, decrypted ahead for data
//! reads and for opcode fetches, then the ADPCM samples, the characters and the sprites. Five
//! slots of rom_slots (fpga/common) read it. The EEPROM section and the header come over the
//! loader's write port.
//!
//! The RAM mirror for RetroAchievements is gpang_mirror.sv.
module game_core #(
    parameter bit ROMVIEW = 0,      //!< accepted for the top's sake, no effect here
    parameter bit RAMDIAG = 0       //!< accepted for the top's sake, no effect here
)(
    input  wire         clk_core,       //!< 37.125 MHz
    input  wire         reset,          //!< core reset, held by the top until the ROM is loaded

    //! ---- video in the core raster, blankn = 1 visible, vs active low ----
    output logic [3:0]  video_r,        //!< 4/4/4 from the palette RAM, game_pkg::RGB444
    output logic [3:0]  video_g,
    output logic [3:0]  video_b,
    output logic        video_ce,       //!< pixel enable, 8 MHz
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
    input  wire  [11:0] p1_btns,        //!< raw HID buttons 1..12, for games with more buttons
    input  wire  [11:0] p2_btns,
    input  wire         coin,
    input  wire         start1,
    input  wire         start2,
    output logic [15:0] map_bits,       //!< the game signals, shown on the input test bar

    //! ---- RAM mirror: the harvest delivers the mirror bytes, see gpang_mirror.sv ----
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

    // sections of the manifests that reach this module over the write port
    localparam int SEC_EE = 5;
    localparam int SEC_ID = 6;

    // ---------------- Which game: header byte 0 ----------------
    // 0 Pang, 1 Super Pang. Both files carry the header, every load sets it. The core itself
    // runs both alike, the program images differ; game_id only sets the volume.
    logic [1:0] game_id = 2'd0;
    always_ff @(posedge clk)
        if (rom_wr_en[SEC_ID] && rom_wr_addr == 16'd0) game_id <= rom_wr_data[1:0];

    // ---------------- Controls, JTFRAME convention: active low ----------------
    // joystick {button 2, button 1, up, down, left, right}. Button 1 fires (the platform's
    // fire, menu id A). Button 2 serves only the test menu: the raw HID button the menu names
    // under K, 1..12, 0 for none. The test switch (menu id X) is read at power-on, its list
    // resets. Two coin slots on the board, the platform has one coin.
    logic [3:0] b2_btn = 4'd2;
    logic       test_on = 1'b0;
    always_ff @(posedge clk)
        if (cfg_we) case (cfg_id)
            "K": b2_btn  <= cfg_val[3:0];
            "X": test_on <= (cfg_val != 8'd0);
            default: ;
        endcase
    wire p1_b2 = (b2_btn != 4'd0) && p1_btns[b2_btn - 4'd1];
    wire p2_b2 = (b2_btn != 4'd0) && p2_btns[b2_btn - 4'd1];
    wire [7:0] joystick1 = ~{2'b00, p1_b2, p1_fire, p1_dir};
    wire [7:0] joystick2 = ~{2'b00, p2_b2, p2_fire, p2_dir};
    assign map_bits = {7'd0, start2, start1, coin, p1_b2, p1_fire, p1_dir};

    // ---------------- Clock enables: 8, 4 and 1 MHz ----------------
    // 37.125 MHz * 64 / 297 = 8.000 MHz exactly, the others are halvings of it: the pixel and
    // the CPU on 8 MHz, the YM2413 on 4, the M6295 on 1 (MAME mitchell.cpp, 16 MHz crystal).
    // The spacing jitters by one clock: the pixel enable comes every 4 or 5 clocks. jotego
    // runs the sound in a 24 MHz domain of its own, here it shares clk_core.
    wire pxl_cen, fm_cen, pcm_cen;
    wire [3:0] cen;
    jtframe_gated_cen #(.W(4), .NUM(64), .DEN(297), .MFREQ(37125)) u_cen (
        .rst(rst), .clk(clk), .busy(1'b0), .cen(cen), .fave(), .fworst()
    );
    assign pxl_cen = cen[0];
    assign fm_cen  = cen[1];
    assign pcm_cen = cen[3];

    // ---------------- The game: jtpang_game.v's connections ----------------
    wire [ 7:0] cpu_dout, pcm_dout, vram_dout, attr_dout, pal_dout;
    wire        fm_cs, oki_cs, cpu_rnw, busrq, int_n, pal_cs, vram_msb, vram_cs, attr_cs;
    wire [11:0] cpu_addr;
    wire        char_en, obj_en, video_en, pal_bank, flip;
    wire        dma_go, busak_n;
    wire [ 8:0] h;
    wire        LHBL, LVBL, HS, VS;
    wire [ 3:0] red, green, blue;
    wire signed [15:0] fm;
    wire signed [13:0] pcm;
    wire [19:0] main_addr;
    wire [ 7:0] main_data, pcm_data, ee_dout;
    wire        main_cs, main_m1, main_ok, pcm_ok, obj_ok, obj_cs, char_cs;
    wire [17:0] pcm_addr;
    wire [20:2] char_addr;
    wire [17:2] obj_addr;
    wire [31:0] char_data, obj_data;
    wire [12:0] mir_addr, mir_ram_addr;
    wire [ 7:0] mir_dout;
    wire        mir_ram_we, pcm_bank;

    jtpang_main u_main (
        .rst        (rst),          .clk        (clk),
        .cpu_cen    (pxl_cen),      .int_n      (int_n),
        .ctrl_type  (2'd0),         // Pang and Super Pang: the plain joystick
        .cpu_addr   (cpu_addr),     .cpu_rnw    (cpu_rnw),      .cpu_dout   (cpu_dout),
        .flip       (flip),         .LVBL       (LVBL),         .LHBL       (LHBL),
        .hcnt       (h[2:0]),       .dip_pause  (1'b1),
        // jotego holds start 1 for 511 frames when no NVRAM was loaded, so that Super Pang
        // sets its EEPROM up. Here the EEPROM section of the file is loaded every time.
        .init_n     (1'b1),
        .char_en    (char_en),      .obj_en     (obj_en),       .video_enq  (video_en),
        .attr_cs    (attr_cs),      .vram_cs    (vram_cs),      .vram_msb   (vram_msb),
        .pal_cs     (pal_cs),       .pal_bank   (pal_bank),
        .attr_dout  (attr_dout),    .pal_dout   (pal_dout),     .vram_dout  (vram_dout),
        .fm_cs      (fm_cs),        .pcm_cs     (oki_cs),       .pcm_bank   (pcm_bank),
        .pcm_dout   (pcm_dout),
        .dma_go     (dma_go),       .busrq_n    (~busrq),       .busak_n    (busak_n),
        .joystick1  (joystick1),    .joystick2  (joystick2),
        .cab_1p     (~{start2, start1}), .coin  (~coin),
        .service    (1'b1),         .test       (~test_on),
        .mouse_1p   (8'd0),         .mouse_2p   (8'd0),
        // the EEPROM section goes to the 93C46's dump port, 16-bit words low byte first
        .prog_addr  (rom_wr_addr[12:0]), .prog_data (rom_wr_data), .prog_din (ee_dout),
        .prog_we    (rom_wr_en[SEC_EE]), .prog_ram  (1'b1),
        .mir_addr   (mir_addr),     .mir_dout   (mir_dout),
        .mir_ram_we (mir_ram_we),   .mir_ram_addr(mir_ram_addr),
        .rom_addr   (main_addr),    .rom_cs     (main_cs),      .rom_m1     (main_m1),
        .rom_data   (main_data),    .rom_ok     (main_ok)
    );

    jtpang_snd u_snd (
        .rst        (rst),          .clk        (clk),
        .fm_cen     (fm_cen),       .pcm_cen    (pcm_cen),
        .cpu_dout   (cpu_dout),     .wr_n       (cpu_rnw),
        .a0         (cpu_addr[0]),  .fm_cs      (fm_cs),
        .pcm_dout   (pcm_dout),     .pcm_cs     (oki_cs),
        .rom_addr   (pcm_addr),     .rom_data   (pcm_data),     .rom_ok     (pcm_ok),
        .fm         (fm),           .pcm        (pcm)
    );

    jtpang_video u_video (
        .rst        (rst),          .clk        (clk),
        .pxl2_cen   (1'b0),         .pxl_cen    (pxl_cen),      // pxl2_cen is not used inside
        .int_n      (int_n),
        .LHBL       (LHBL),         .LVBL       (LVBL),         .HS (HS),   .VS (VS),
        .h          (h),            .flip       (flip),
        // jtpang_main takes the character enable from bit 6 of port 00, which, as its own
        // comment says, goes through a jumper Pang's board does not connect. Pang writes the
        // bit as 0 while its text shows (MAME ignores bits 6 and 7), so it is left out here.
        .video_en   (video_en),     .char_en    (1'b1),
        .pal_bank   (pal_bank),     .pal_cs     (pal_cs),
        .vram_msb   (vram_msb),     .vram_cs    (vram_cs),      .attr_cs    (attr_cs),
        .wr_n       (cpu_rnw),      .cpu_addr   (cpu_addr),     .cpu_dout   (cpu_dout),
        .vram_dout  (vram_dout),    .attr_dout  (attr_dout),    .pal_dout   (pal_dout),
        .dma_go     (dma_go),       .busak_n    (busak_n),      .busrq      (busrq),
        .char_addr  (char_addr),    .char_data  (char_data),    .char_cs    (char_cs),
        .obj_addr   (obj_addr),     .obj_data   (obj_data),     .obj_cs     (obj_cs),
        .obj_ok     (obj_ok),
        .red        (red),          .green      (green),        .blue       (blue),
        .gfx_en     (4'hf)
    );

    // ---------------- The ROM buses: the image in SDRAM ----------------
    // pang.manifest: data image from 0, opcode image from 0x48000, ADPCM from 0x90000,
    // characters from 0xB0000, sprites from 0x130000. Each bus adds its start to its address;
    // a slot returns the whole 32-bit word, a byte of it lies at 8 * address[1:0]. Slot order
    // is priority: the characters first, they take their word 8 pixels after the address and
    // have no ok (about 37 clocks); the ADPCM data next, the M6295 takes it at a fixed time
    // about 150 clocks after its address; the sprites, which have the rest of the line; the
    // CPU last, it stops until the byte is there.
    // jotego's image fills the space above the ROMs with FF, the dense image here has other
    // data there: a character code from 0x4000 and an ADPCM address from 0x20000 read FF.
    //
    // The CPU: a ROM word takes about 12 clocks, a CPU clock is 4 or 5, so every new word
    // stops the CPU. Its program runs mostly straight on, so the slots read ahead: cw is the
    // word of the last opcode fetch, and two slots per image hold cw and cw + 1, one for the
    // even and one for the odd word addresses, so that the one cw moves to is already there
    // while the other reads the next. Opcode fetches read the opcode image there; data reads
    // take the data image there when their word is cw or cw + 1 (the operands), else a slot
    // of their own.
    localparam int NSLOT = 8;
    localparam int S_CHR = 0, S_PCM = 1, S_OBJ = 2, S_OPE = 3, S_OPO = 4, S_DAT = 5, S_DTE = 6, S_DTO = 7;
    wire        chr_ff   = char_addr[20:19] != 2'd0;
    wire        pcm_ff   = pcm_addr[17];
    wire [21:0] off_chr  = 22'h0B0000 + 22'({char_addr[18:2], 2'b00});
    wire [21:0] off_pcm  = 22'h090000 + 22'(pcm_addr[16:0]);
    wire [21:0] off_obj  = 22'h130000 + 22'({obj_addr, 2'b00});
    // the program images: word addresses inside an image, 288 KiB = 0x12000 words
    wire [16:0] mw = main_addr[18:2];               // the word the CPU reads now
    logic [16:0] cw_q = '0;
    logic        cw_on = 1'b0;                      // read ahead only once the CPU runs
    always_ff @(posedge clk)
        if (rst) cw_on <= 1'b0;
        else if (main_cs && main_m1) begin
            cw_q  <= mw;
            cw_on <= 1'b1;
        end
    wire [16:0] cw   = (main_cs && main_m1) ? mw : cw_q;
    wire [16:0] cw_e = cw[0] ? cw + 17'd1 : cw;     // the even word of cw, cw + 1
    wire [16:0] cw_o = cw[0] ? cw : cw + 17'd1;     // the odd one
    localparam logic [21:2] OP = 20'(22'h048000 >> 2);
    wire [NSLOT-1:0][21:2] slot_addr;
    wire [NSLOT-1:0]       slot_cs, slot_ok;
    wire [NSLOT-1:0][31:0] slot_data;
    // a data read served by the read-ahead slots: its word is cw_e or cw_o and held there
    wire dt_e = mw == cw_e && slot_ok[S_DTE];
    wire dt_o = mw == cw_o && slot_ok[S_DTO];
    assign slot_addr[S_CHR] = off_chr[21:2];        assign slot_cs[S_CHR] = !chr_ff;
    assign slot_addr[S_PCM] = off_pcm[21:2];        assign slot_cs[S_PCM] = !pcm_ff;
    assign slot_addr[S_OBJ] = off_obj[21:2];        assign slot_cs[S_OBJ] = obj_cs;
    assign slot_addr[S_OPE] = OP + 20'(cw_e);       assign slot_cs[S_OPE] = cw_on || (main_cs && main_m1);
    assign slot_addr[S_OPO] = OP + 20'(cw_o);       assign slot_cs[S_OPO] = cw_on || (main_cs && main_m1);
    assign slot_addr[S_DAT] = 20'(mw);              assign slot_cs[S_DAT] = main_cs && !main_m1 && !dt_e && !dt_o;
    assign slot_addr[S_DTE] = 20'(cw_e);            assign slot_cs[S_DTE] = cw_on;
    assign slot_addr[S_DTO] = 20'(cw_o);            assign slot_cs[S_DTO] = cw_on;

    // The characters: jtpang_char sets a new address every 8 pixels and takes the word of
    // the previous one in the same pixel enable, about 37 clocks later, without ok. Its own
    // chip select is low during HS, but the address also changes there, and the first word
    // after HS would then have only the clocks from the end of HS. So the slot reads whenever
    // the address changes (char_cs is left out). Guard: the CPU's slots start no read in the
    // last 2 pixels (about 9 clocks) before the next change, so that the characters do not
    // queue behind three CPU reads. The sprites and the ADPCM data are not held, a busy line
    // needs their bandwidth, and a longer guard costs the CPU clock enables. The phase is
    // counted from the last address change, modulo 8, so a repeated address keeps it.
    localparam int CHR_GUARD = 2;           // pixels
    logic [20:2] chr_addr_q = '0;
    logic [2:0]  chr_px = 3'd0;             // pixels since the last character address change
    always_ff @(posedge clk) begin
        chr_addr_q <= char_addr;
        if (char_addr != chr_addr_q) chr_px <= 3'd0;
        else if (pxl_cen)            chr_px <= chr_px + 3'd1;
    end
    wire chr_soon = LVBL && chr_px >= 3'(8 - CHR_GUARD);
    wire [NSLOT-1:0] slot_hold = chr_soon ? NSLOT'(8'b1111_1000) : '0;     // S_OPE and up

    rom_slots #(.N(NSLOT), .AW(22)) u_slots (
        .clk(clk), .reset(rst),
        .slot_addr(slot_addr), .slot_cs(slot_cs), .slot_hold(slot_hold),
        .slot_ok(slot_ok), .slot_data(slot_data),
        .rd_addr(rom_rd_addr), .rd_push(rom_rd_push), .rd_ready(rom_rd_ready),
        .rd_valid(rom_rd_valid), .rd_data(rom_rd_data),
        .miss()
    );
    assign char_data = chr_ff ? 32'hFFFF_FFFF : slot_data[S_CHR];
    assign pcm_data  = pcm_ff ? 8'hFF : slot_data[S_PCM][8*off_pcm[1:0] +: 8];
    assign pcm_ok    = pcm_ff || slot_ok[S_PCM];
    assign obj_data  = slot_data[S_OBJ];
    assign obj_ok    = slot_ok[S_OBJ];
    // the slot of this CPU read
    wire [2:0] s_main = main_m1 ? (mw[0] ? 3'(S_OPO) : 3'(S_OPE))
                                : dt_e ? 3'(S_DTE) : dt_o ? 3'(S_DTO) : 3'(S_DAT);
    assign main_data = slot_data[s_main][8*main_addr[1:0] +: 8];
    assign main_ok   = slot_ok[s_main];

    // ---------------- Video and audio to the platform ----------------
    assign video_r      = red;
    assign video_g      = green;
    assign video_b      = blue;
    assign video_ce     = pxl_cen;
    assign video_blankn = LHBL & LVBL;
    assign video_vs     = ~VS;
    assign video_hs     = ~HS;
    // jotego's mix (cfg/mem.yaml): the M6295 through 32k with a gain of 0.05, the YM2413
    // through 22k with 0.1, so the FM weighs 2.9 times the PCM, both at 16 bits. The PCM's
    // 14 bits are 4 times smaller: fm + pcm * 4 / 2.9, about fm + 1.375 pcm. Halved for room,
    // saturated. The board's RC filters are left out. jotego sets Super Pang's volume to 0x65
    // against Pang's 0x9A: about 0.66, here 1 - 1/4 - 1/16 - 1/32 = 0.66.
    wire signed [17:0] au_pcm = 18'(pcm) + 18'(pcm >>> 2) + 18'(pcm >>> 3);
    wire signed [17:0] au_sum = (18'(fm) + au_pcm) >>> 1;
    wire signed [17:0] au_vol = game_id == 2'd1 ? au_sum - (au_sum >>> 2) - (au_sum >>> 4) - (au_sum >>> 5)
                                                : au_sum;
    always_ff @(posedge clk)
        audio <= (au_vol >  18'sd32767) ? 16'sd32767 :
                 (au_vol < -18'sd32768) ? -16'sd32768 : 16'(au_vol);

    // ---------------- RAM mirror for RetroAchievements ----------------
    // Work RAM writes come from jtpang_main's strobe, tile map writes from the video RAM's
    // chip select with bank 0 (vram_msb low). A Z80 write holds wr_n low for at least one
    // T state and raises it before the next, so each write gives exactly one edge.
    wire  vw = vram_cs && !cpu_rnw && !vram_msb;
    logic mw_q = 1'b0, vw_q = 1'b0, lvbl_q = 1'b0;
    always_ff @(posedge clk) begin
        mw_q   <= mir_ram_we;
        vw_q   <= vw;
        lvbl_q <= LVBL;
    end

    gpang_mirror #(.N(rom_map_pkg::MIRROR_DATA)) u_mirror (
        .clk(clk), .reset(rst), .frame_go(lvbl_q && !LVBL),
        .wr_addr(mir_addr), .wr_q(mir_dout),
        .w_busy(mir_ram_we), .w_ev(mir_ram_we && !mw_q), .w_addr(mir_ram_addr), .w_data(cpu_dout),
        .v_ev(vw && !vw_q), .v_addr(cpu_addr), .v_data(cpu_dout),
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
