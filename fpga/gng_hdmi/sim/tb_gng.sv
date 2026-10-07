// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k, Ghosts'n Goblins: simulation of game_core (jotego's jtgng behind our wrapper) with
// its ROM, derived from fpga/g1943_hdmi/sim/tb_1943.sv. Two ways to serve the five
// ROM buses, chosen at build time:
//   default   a model of rom_sdram's read stream: up to four reads in flight, latency as
//             measured for 1942, the ring rate as the upper bound
//   ROM_PATH  the real path: rom_sdram.sv, sdram_fb.v at 64.8 MHz unrelated to the core
//             clock, and an SDR SDRAM model. The image is first written through rom_sdram's
//             write side, as rom_loader does on the device (FB_PATH: with the frame buffer)
// A coin and a start follow unless ATTRACT is defined. Counted as late in the picture:
// characters and scroll tiles without data in their window, sprite lines not finished. All
// three layers reach the colour mixer in GnG (jtgng_colmix), so all three counts apply.
// Whether the game is GnG at all is decided outside, by compare_mame.py against MAME.
`timescale 1ns/1ps
module tb_gng;
    parameter int FRAMES      = 1500;
    parameter int FRAME_EVERY = 30;
    localparam int ROM_BYTES  = 360448;
    localparam int MIR_N      = 5760;

    logic clk = 1'b0;
    always #13.468 clk = ~clk;          // 37.125 MHz

    logic        reset = 1'b1;
    logic [21:2] rom_rd_addr;
    logic        rom_rd_push;
`ifdef ROM_PATH
    logic        rom_rd_ready, rom_rd_valid;
    logic [31:0] rom_rd_data;
`else
    logic        rom_rd_ready = 1'b1, rom_rd_valid = 1'b0;
    logic [31:0] rom_rd_data  = '0;
`endif
    logic [3:0]  r, g, b;
    logic        ce, blankn, vs, hs;
    logic signed [15:0] audio;
    logic [15:0] map_bits;
    logic        coin = 1'b0, start1 = 1'b0;

    game_core dut (
        .clk_core(clk), .reset(reset),
        .video_r(r), .video_g(g), .video_b(b), .video_ce(ce),
        .video_blankn(blankn), .video_vs(vs), .video_hs(hs),
        .audio(audio),
        .rom_wr_addr(16'd0), .rom_wr_data(8'd0), .rom_wr_en(16'd0),
        .rom_rd_addr(rom_rd_addr), .rom_rd_push(rom_rd_push), .rom_rd_ready(rom_rd_ready),
        .rom_rd_valid(rom_rd_valid), .rom_rd_data(rom_rd_data),
        .cfg_we(1'b0), .cfg_id(8'd0), .cfg_val(8'd0),
        .p1_dir(4'd0), .p2_dir(4'd0), .p1_fire(1'b0), .p2_fire(1'b0),
        .p1_btns(12'd0), .p2_btns(12'd0),
        .coin(coin), .start1(start1), .start2(1'b0),
        .map_bits(map_bits),
        .snap_run(snap_run), .snap_full(1'b0), .snap_push(snap_push), .snap_byte(snap_byte),
        .snap_frame(snap_frame), .snap_harv(snap_harv),
        .log_we(log_we), .log_addr(log_addr), .log_data(log_data),
        .clk_pixel(clk), .cx(11'd0), .cy(10'd0),
        .diag_spi_count(16'd0), .diag_spi_us(16'd0), .diag_spi_verdict(8'd0),
        .diag_rc_us(16'd0), .diag_rc_lf(16'd0), .diag_last_ach(8'd0),
        .diag_on(), .diag_color(), .diag_leds()
    );

    // ---------------- ROM image ----------------
    logic [31:0] rom [0:ROM_BYTES/4-1];
    initial $readmemh("rom32.hex", rom);

`ifndef ROM_PATH
    // ---------------- read stream model ----------------
    // Up to four reads in flight, words in order. Each read is due 9..12 clocks after its
    // push (one in 40 meets a refresh: 13..19), the latency measured on the single-read port
    // before the stream. A word never comes before the one ahead of it, and the ring takes
    // a read only every 3.4 core clocks at most, so a read is never due earlier than 4
    // clocks after the one before.
    logic [21:2] m_addr [$];
    longint      m_due  [$];
    longint      now = 0, last_due = 0;
    int          reads = 0;
    always @(posedge clk) begin
        now++;
        rom_rd_valid <= 1'b0;
        if (rom_rd_push && rom_rd_ready) begin
            longint d;   // assigned, not initialised: in an always block an initialiser runs once
            d = now + (($urandom % 40 == 0) ? 13 + ($urandom % 7) : 9 + ($urandom % 4));
            if (d < last_due + 4) d = last_due + 4;
            last_due = d;
            m_addr.push_back(rom_rd_addr);
            m_due.push_back(d);
        end
        if (m_due.size() > 0 && m_due[0] <= now) begin
            rom_rd_data  <= rom[m_addr[0][18:2]];
            rom_rd_valid <= 1'b1;
            void'(m_addr.pop_front());
            void'(m_due.pop_front());
            reads <= reads + 1;
        end
        rom_rd_ready <= m_due.size() < 3;      // registered: four in flight at most
    end

`else
    // ---------------- the real ROM path ----------------
    logic clk_sdram = 0;
    always #7.716 clk_sdram = ~clk_sdram;
    logic        sd_resetn = 0;
    logic        wr_we = 0;
    logic [21:0] wr_off = '0;
    logic [7:0]  wr_byte = '0;
    logic        wr_ready, wr_idle;
    logic [21:0] sd_wr_addr, sd_rd_addr;
    logic [31:0] sd_wr_din, sd_rd_dout, rom_rd_dout;   // controller's word, rom_sdram's copy
    logic [1:0]  sd_wr_bank, sd_rd_bank;
    logic        sd_wr_req, sd_wr_ack, sd_rd_req, sd_rd_ack, sd_rd_valid, sdram_ready, sd_rd_hint;
    int          reads = 0;
    always @(posedge clk) if (rom_rd_push && rom_rd_ready) reads <= reads + 1;

    rom_sdram #(.AW(22), .BANK(2'd2)) path (
        .clk_core(clk), .reset(1'b0),
        .wr_we(wr_we), .wr_off(wr_off), .wr_data(wr_byte), .wr_ready(wr_ready), .wr_idle(wr_idle),
        .rd_addr(rom_rd_addr), .rd_push(rom_rd_push), .rd_ready(rom_rd_ready),
        .rd_valid(rom_rd_valid), .rd_data(rom_rd_data),
        .clk_sdram(clk_sdram),
        .sd_wr_addr(sd_wr_addr), .sd_wr_din(sd_wr_din), .sd_wr_bank(sd_wr_bank),
        .sd_wr_req(sd_wr_req), .sd_wr_ack(sd_wr_ack),
        .sd_rd_addr(sd_rd_addr), .sd_rd_bank(sd_rd_bank), .sd_rd_req(sd_rd_req),
        .sd_rd_ack(sd_rd_ack), .sd_rd_dout(rom_rd_dout), .sd_rd_valid(sd_rd_valid),
        .sd_rd_hint(sd_rd_hint)
    );
    wire [31:0] dq;
    wire [10:0] a;
    wire [3:0]  dqm;
    wire [1:0]  ba;
    wire        ncs, nwe, nras, ncas, cke;
    sdram_fb #(.FREQ(64_800_000), .CAS(3'd2)) ctrl (
        .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_DQM(dqm), .SDRAM_BA(ba),
        .SDRAM_nCS(ncs), .SDRAM_nWE(nwe), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas), .SDRAM_CKE(cke),
        .clk(clk_sdram), .resetn(sd_resetn), .sdram_ready(sdram_ready), .cap_ofs(2'd1),
        .wr_addr(c_wr_addr), .wr_din(c_wr_din), .wr_bank(c_wr_bank),
        .wr_req(c_wr_req), .wr_ack(c_wr_ack),
        .rd_addr(c_rd_addr), .rd_bank(c_rd_bank), .rd_req(c_rd_req), .rd_ack(c_rd_ack),
        .rd_dout(sd_rd_dout), .rd_valid(c_rd_valid), .rd_hint(sd_rd_hint)
    );
    // the controller's side: straight to rom_sdram, or with FB_PATH through sdram_share,
    // with the frame buffer of the portrait picture on its port B, as the top builds it
    logic [21:0] c_wr_addr, c_rd_addr;
    logic [31:0] c_wr_din;
    logic [1:0]  c_wr_bank, c_rd_bank;
    logic        c_wr_req, c_wr_ack, c_rd_req, c_rd_ack, c_rd_valid;
`ifndef FB_PATH
    assign {c_wr_addr, c_wr_din, c_wr_bank, c_wr_req} = {sd_wr_addr, sd_wr_din, sd_wr_bank, sd_wr_req};
    assign {c_rd_addr, c_rd_bank, c_rd_req}           = {sd_rd_addr, sd_rd_bank, sd_rd_req};
    assign sd_wr_ack   = c_wr_ack;
    assign sd_rd_ack   = c_rd_ack;
    assign sd_rd_valid = c_rd_valid;
    assign rom_rd_dout = sd_rd_dout;
`else
    // ---- frame buffer: fb_pack writes the core's frames, fb_read_rotated reads them ----
    logic clk_pixel = 0;
    always #6.734 clk_pixel = ~clk_pixel;          // 74.25 MHz
    logic [10:0] cx = '0;
    logic [9:0]  cy = '0;
    always @(posedge clk_pixel) begin             // the raster of 1942 and GnG, 1584 x 786, free running
        cx <= (cx == 11'd1583) ? 11'd0 : cx + 11'd1;
        if (cx == 11'd1583) cy <= (cy == 10'd785) ? 10'd0 : cy + 10'd1;
    end
    logic [21:0] f_wr_addr, f_rd_addr;
    logic [31:0] f_wr_din;
    logic [1:0]  f_wr_bank, f_rd_bank;
    logic        f_wr_req, f_wr_ack, f_rd_req, f_rd_ack, f_rd_valid;
    logic        fb_wbuf, fb_done, fb_ovf, fb_eaddr, fb_late, fb_active, fb_pic;
    logic [23:0] fb_rgb;
    fb_pack #(.W(256), .H(224), .CPP(0)) pack (
        .clk_core(clk), .r_in(r[3:1]), .g_in(g[3:1]), .b_in(b[3:2]), .pix_ce(ce),
        .blankn(blankn), .vs(vs),
        .clk_sdram(clk_sdram), .sdram_ready(sdram_ready), .clear(1'b0),
        .wr_addr(f_wr_addr), .wr_din(f_wr_din), .wr_bank(f_wr_bank), .wr_req(f_wr_req), .wr_ack(f_wr_ack),
        .wbuf(fb_wbuf), .frame_done(fb_done), .done_bank(), .done_words(), .done_sum(), .done_nz(),
        .err_overflow(fb_ovf), .err_addr(fb_eaddr)
    );
    fb_read_rotated #(.W(256), .H(224), .X0(416), .Y0(104), .ROT_CCW(rom_map_pkg::FB_CCW)) rot (
        .clk_sdram(clk_sdram), .sdram_ready(sdram_ready), .wbuf(fb_wbuf), .frame_done(fb_done),
        .rd_addr(f_rd_addr), .rd_bank(f_rd_bank), .rd_req(f_rd_req), .rd_ack(f_rd_ack),
        .rd_dout(sd_rd_dout), .rd_valid(f_rd_valid), .err_late(fb_late),
        .clk_pixel(clk_pixel), .cx(cx), .cy(cy), .rgb(fb_rgb), .pic(fb_pic), .active(fb_active), .clear(1'b0)
    );
    sdram_share share (
        .clk(clk_sdram),
        .c_wr_addr(c_wr_addr), .c_wr_din(c_wr_din), .c_wr_bank(c_wr_bank), .c_wr_req(c_wr_req), .c_wr_ack(c_wr_ack),
        .c_rd_addr(c_rd_addr), .c_rd_bank(c_rd_bank), .c_rd_req(c_rd_req), .c_rd_dout(sd_rd_dout), .c_rd_ack(c_rd_ack), .c_rd_valid(c_rd_valid),
        .a_wr_addr(sd_wr_addr), .a_wr_din(sd_wr_din), .a_wr_bank(sd_wr_bank), .a_wr_req(sd_wr_req), .a_wr_ack(sd_wr_ack),
        .a_rd_addr(sd_rd_addr), .a_rd_bank(sd_rd_bank), .a_rd_req(sd_rd_req), .a_rd_ack(sd_rd_ack), .a_rd_dout(rom_rd_dout), .a_rd_valid(sd_rd_valid),
        .b_wr_addr(f_wr_addr), .b_wr_din(f_wr_din), .b_wr_bank(f_wr_bank), .b_wr_req(f_wr_req), .b_wr_ack(f_wr_ack),
        .b_rd_addr(f_rd_addr), .b_rd_bank(f_rd_bank), .b_rd_req(f_rd_req), .b_rd_ack(f_rd_ack), .b_rd_valid(f_rd_valid)
    );
    // refreshes armed, and those forced by the deferral limit while a read was pending
    int rf_arms = 0, rf_forced = 0;
    always @(posedge clk_sdram)
        if (ctrl.normal && ctrl.cycle[5] && !ctrl.rfsh_arm && !ctrl.rfsh_wait && ctrl.rfsh_go) begin
            rf_arms++;
            if (ctrl.rd_pend || ctrl.rd_hint) rf_forced++;
        end
    final $display("refresh: %0d armed, %0d forced over a pending read", rf_arms, rf_forced);
    final $display("frame buffer: overflow %0d, address error %0d, group late %0d, output running %0d",
                   fb_ovf, fb_eaddr, fb_late, fb_active);
`endif
    logic [31:0] mem [0:4*2048*256-1];
    logic [10:0] row [0:3];
    logic [31:0] dq_out = '0;
    logic        dq_drive = 0;
    logic [20:0] rd_pipe [0:2];
    logic [2:0]  rd_vld = '0;
    assign dq = dq_drive ? dq_out : 'z;
    always @(negedge clk_sdram) begin
        dq_drive <= rd_vld[1];
        if (rd_vld[1]) dq_out <= mem[rd_pipe[1][20:0]];
        rd_vld  <= {rd_vld[1:0], 1'b0};
        rd_pipe[1] <= rd_pipe[0];
        if (!ncs) case ({nras, ncas, nwe})
            3'b011: row[ba] <= a;
            3'b101: begin rd_pipe[0] <= {ba, row[ba], a[7:0]}; rd_vld[0] <= 1'b1; end
            3'b100: mem[{ba, row[ba], a[7:0]}] <= dq;
            default: ;
        endcase
    end

`endif

    // ---------------- loading, then out of reset ----------------
    initial begin
        repeat (20) @(posedge clk);
`ifdef ROM_PATH
        sd_resetn <= 1'b1;
        for (int o = 0; o < ROM_BYTES; o++) begin           // all sections are sdram
            while (!wr_ready) @(posedge clk);
            wr_we <= 1'b1; wr_off <= 22'(o); wr_byte <= rom[o >> 2][8*(o & 3) +: 8];
            @(posedge clk);
            wr_we <= 1'b0;
            @(posedge clk);
        end
        while (!wr_idle) @(posedge clk);
        $display("image written at %0t", $time);
`endif
        repeat (300) @(posedge clk);
        reset <= 1'b0;
        $display("reset released at %0t, frame %0d", $time, nframe);
    end

    // ---------------- RAM mirror: a Pico model and the truth ----------------
    // The model fetches a snapshot about every 50 ms, as the firmware does: only when no
    // harvest runs, then snap_run for the whole delivery. Each snapshot is checked twice:
    //   - oracle, as main.c does: for every address logged during the harvest window, the
    //     snapshot holds the last logged value
    //   - truth: the 6809's work RAM itself (jtframe_sys6809_dma, 8 KiB), copied at the end
    //     of the harvest by ram_probe below: 0x0000-0x167F equals the snapshot
    // Also counted: the most log entries in one window (the platform has 512).
    logic        snap_run = 1'b0, snap_push, snap_harv, log_we;
    logic [7:0]  snap_byte, log_data;
    logic [15:0] snap_frame, log_addr;
    logic [7:0]  ref_ram [0:MIR_N-1];       // truth at the end of the last harvest
    logic [7:0]  got     [0:MIR_N-1];       // the delivered snapshot
    logic [7:0]  lg_val  [0:MIR_N-1];       // last logged value per address in the window
    logic        lg_set  [0:MIR_N-1];
    int          lg_n = 0, lg_max = 0, snaps = 0, mir_bad = 0, ora_bad = 0, got_n = 0;
    int          grabs = 0, ram_nz = 0;
    logic        harv_q = 1'b0;
    always @(posedge clk) begin
        harv_q <= snap_harv;
        if (snap_harv && !harv_q) begin                   // window opens
            lg_n = 0;
            for (int i = 0; i < MIR_N; i++) lg_set[i] = 1'b0;
        end
        if (snap_harv && log_we) begin
            lg_n = lg_n + 1;
            lg_val[log_addr] = log_data;
            lg_set[log_addr] = 1'b1;
        end
        if (!snap_harv && harv_q) begin                   // window closed: the truth now
            if (lg_n > lg_max) lg_max = lg_n;
            // ram_probe copies the truth in this clock
        end
        if (snap_run && snap_push) begin                  // snap_full is 0: every push counts
            if (got_n < MIR_N) got[got_n] = snap_byte;
            got_n = got_n + 1;
        end
    end
    initial begin
        #(64'd300_000_000);                               // the game runs by then
        forever begin
            #(64'd50_000_000);
            @(posedge clk);
            while (snap_harv) @(posedge clk);
            got_n = 0;
            snap_run <= 1'b1;
            repeat (MIR_N + 50) @(posedge clk);
            snap_run <= 1'b0;
            snaps++;
            if (got_n != MIR_N) begin
                mir_bad++;
                $display("mirror: snapshot %0d has %0d bytes, expected %0d", snaps, got_n, MIR_N);
            end
            ram_nz = 0;
            for (int i = 0; i < MIR_N; i++) begin
                if (ref_ram[i] != 8'h00) ram_nz++;
                if (got[i] !== ref_ram[i]) begin
                    if (mir_bad < 8) $display("mirror: snapshot %0d byte %04x is %02x, the core holds %02x", snaps, i, got[i], ref_ram[i]);
                    mir_bad++;
                end
            end
            for (int i = 0; i < MIR_N; i++)
                if (lg_set[i] && got[i] !== lg_val[i]) begin
                    if (ora_bad < 8) $display("oracle: snapshot %0d byte %04x is %02x, last logged %02x", snaps, i, got[i], lg_val[i]);
                    ora_bad++;
                end
        end
    end

    // ---------------- read latency of the ROM port, as the game sees it ----------------
    int lat_n = 0, lat_max = 0, lat_over = 0, fly_max = 0;
    longint lat_sum = 0, lat_clk = 0;
    longint lat_t0 [$];
    always @(posedge clk) begin
        lat_clk++;
        if (rom_rd_push && rom_rd_ready) lat_t0.push_back(lat_clk);
        if (rom_rd_valid && lat_t0.size() > 0) begin
            int t;
            t = int'(lat_clk - lat_t0.pop_front());
            lat_n++; lat_sum += t;
            if (t > lat_max) lat_max = t;
            if (t > 19) lat_over++;
        end
        if (lat_t0.size() > fly_max) fly_max = lat_t0.size();
    end

    // ---------------- late ROM data, counted in the visible picture only ----------------
    // char: jtgng_char takes rom_data only with rom_ok while Hfix[2:0] is 3..7 and uses it at
    // the next Hfix 2. A tile without ok in that window draws the previous pattern.
    // scroll: jtgng_tile3 does the same on its HS[2:0] (jtgng_scroll's HS, the scroll
    // position is part of it). sprites: jtgng_objcnt must reach draw_over by HINIT.
    // Besides, every clock in a window with ok is checked against the ROM image: a slot that
    // calls a wrong word ok would draw garbage without being late.
    int char_late = 0, scr_late = 0, obj_lines = 0, obj_short = 0;
    int char_okbad = 0, scr_okbad = 0, main_okbad = 0, snd_okbad = 0, obj_okbad = 0;
    logic chr_seen = 1'b0, scr_seen = 1'b0;
    // counted only once the core runs: under reset (while the image loads) the video timing
    // runs on, but the slots read nothing on purpose
    wire  visible = dut.u_game.LVBL && dut.u_game.LHBL && !reset;
    wire [2:0] hc = dut.u_game.u_video.u_char.Hfix[2:0];
    wire [2:0] hsc = dut.u_game.u_video.u_scroll.HS[2:0];
    function automatic logic [31:0] romw(input logic [21:0] off);
        return rom[off[18:2]];
    endfunction
    always @(posedge clk) begin
        if (hc > 3'd2 && dut.char_ok) chr_seen <= 1'b1;
        if (dut.cen6 && hc == 3'd2) begin
            chr_seen <= 1'b0;
            if (!chr_seen && visible) char_late <= char_late + 1;
        end
        if (hsc > 3'd2 && dut.scr_ok) scr_seen <= 1'b1;
        if (dut.cen6 && hsc == 3'd2) begin
            scr_seen <= 1'b0;
            if (!scr_seen && visible) begin
                scr_late <= scr_late + 1;
                if (scr_late < 20)
                    $display("late scroll: frame %0d V %0d", nframe, dut.u_game.V);
            end
        end
        if (dut.u_game.u_video.u_obj.u_cnt.HINIT_draw && dut.u_game.u_video.u_obj.draw_cen && dut.u_game.LVBL && !reset) begin
            obj_lines <= obj_lines + 1;
            if (!dut.u_game.u_video.u_obj.u_cnt.draw_over) obj_short <= obj_short + 1;
        end
        if (!reset) begin
            if (dut.char_ok && dut.slot_data[1] != romw(dut.off_char)) char_okbad <= char_okbad + 1;
            if (dut.scr_ok  && dut.slot_data[0] != romw(dut.off_scr))  scr_okbad  <= scr_okbad + 1;
            if (dut.obj_ok  && dut.slot_data[2] != romw(dut.off_obj))  obj_okbad  <= obj_okbad + 1;
            if (dut.main_ok && dut.main_cs && dut.slot_data[3] != romw(dut.off_main)) main_okbad <= main_okbad + 1;
            if (dut.snd_ok  && dut.snd_cs  && dut.slot_data[4] != romw(dut.off_snd))  snd_okbad  <= snd_okbad + 1;
        end
    end

    // ---------------- frames ----------------
    logic [11:0] frame [0:223][0:255];
    int x = 0, y = -1, nframe = 0;
    logic blankn_d = 0, vs_d = 1;
    always @(posedge clk) begin
        blankn_d <= blankn;
        vs_d     <= vs;
        if (blankn && !blankn_d) begin y <= y + 1; x <= 0; end
        if (ce && blankn) begin
            if (x < 256 && y >= 0 && y < 224)
                frame[y][x] <= {r, g, b};
            x <= x + 1;
        end
        if (!vs && vs_d) begin                // start of the vsync pulse: a frame is complete
            if (nframe % FRAME_EVERY == 0) dump(nframe);
            nframe <= nframe + 1;
            y <= -1;
            if (nframe == FRAMES) begin
                $display("done: %0d frames, %0d ROM reads, slot misses %0d", nframe, reads,
                         dut.u_slots.miss);
                $display("late in the picture: char %0d, scroll %0d; sprite lines %0d, unfinished %0d",
                         char_late, scr_late, obj_lines, obj_short);
                $display("board probe (game_core): scroll %0d, char %0d late", dut.d_late_scr, dut.d_late_chr);
                $display("ok with a wrong word: char %0d, scroll %0d, obj %0d, main %0d, sound %0d",
                         char_okbad, scr_okbad, obj_okbad, main_okbad, snd_okbad);
                $display("ROM port: %0d reads, latency mean %0.1f, max %0d clocks, %0d over 19, at most %0d in flight",
                         lat_n, real'(lat_sum) / lat_n, lat_max, lat_over, fly_max);
                $display("mirror: %0d snapshots, %0d bytes differ from the core, %0d against the oracle; most log entries in a window %0d; truth copied %0d times, %0d nonzero bytes in the last",
                         snaps, mir_bad, ora_bad, lg_max, grabs, ram_nz);
                // late data is reported, not fatal: the numbers are the result of this test
                if (snaps == 0 || grabs == 0 || mir_bad != 0 || ora_bad != 0 || lg_max >= 512) $fatal(1, "FAIL: RAM mirror");
                if (char_okbad + scr_okbad + obj_okbad + main_okbad + snd_okbad != 0) $fatal(1, "FAIL: a slot called a wrong word ok");
                if (char_late + scr_late + obj_short != 0)
                    $display("FAIL: ROM data late in the picture");
                else
                    $display("PASS (the picture still has to match MAME, compare_mame.py)");
                $finish;
            end
        end
    end

    task automatic dump(input int n);
        int fd;
        string name;
        name = $sformatf("frames/f%04d.ppm", n);
        fd = $fopen(name, "w");
        $fwrite(fd, "P3\n256 224\n15\n");
        for (int yy = 0; yy < 224; yy++) begin
            for (int xx = 0; xx < 256; xx++)
                $fwrite(fd, "%0d %0d %0d ", frame[yy][xx][11:8], frame[yy][xx][7:4], frame[yy][xx][3:0]);
            $fwrite(fd, "\n");
        end
        $fclose(fd);
        if (n % 60 == 0)
            $display("frame %0d written, %0d ROM reads so far, late char %0d scroll %0d", n, reads, char_late, scr_late);
    endtask

    // a coin and a start later on, to see the game itself. ATTRACT leaves the demo running.
    // The frame numbers are printed for the same inputs in MAME (compare_mame.py).
`ifndef ATTRACT
    initial begin
        #(64'd9_000_000_000);                 // 9 s: after the power-on test, on the title
        @(posedge vs);
        $display("coin at frame %0d", nframe);
        coin <= 1'b1; #(64'd50_000_000); coin <= 1'b0;
        #(64'd1_000_000_000);
        @(posedge vs);
        $display("start at frame %0d", nframe);
        start1 <= 1'b1; #(64'd50_000_000); start1 <= 1'b0;
    end
`endif
endmodule

// The 6809's work RAM sits in jtframe_dual_ram_cen inside an unnamed generate branch of
// jtframe_sys6809_dma, which a dotted path from the testbench does not reach in Verilator.
// The probe is bound into every jtframe_dual_ram_cen and acts only in the one with AW 13 and
// DW 8 (the only such RAM in GnG, the instance path is printed once). It copies in the clock
// after the harvest window closed: the RAM writes with nonblocking assignments, so the copy
// is the state at the end of the window, the state the snapshot holds.
module ram_probe #(parameter int AW = 10, parameter int DW = 8) (
    input wire          clk,
    input wire [DW-1:0] mem [0:(2**AW)-1]
);
    initial if (AW == 13 && DW == 8) $display("ram_probe: 6809 work RAM is %m");
    always @(posedge clk)
        if (AW == 13 && DW == 8 && !tb_gng.snap_harv && tb_gng.harv_q) begin
            for (int i = 0; i < tb_gng.MIR_N; i++) tb_gng.ref_ram[i] = 8'(mem[i]);
            tb_gng.grabs++;
        end
endmodule
bind jtframe_dual_ram_cen ram_probe #(.AW(AW), .DW(DW)) u_rprobe (.clk(clk0), .mem(mem));
