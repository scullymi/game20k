// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k, 1943: simulation of game_core (jotego's jt1943 behind our wrapper) with its ROM,
// Derived from fpga/g1942_hdmi/sim/tb_1942.sv. Two ways to serve the eight ROM
// buses, chosen at build time:
//   default   a model of rom_sdram's read stream: up to four reads in flight, latency as
//             measured for 1942, the ring rate as the upper bound
//   ROM_PATH  the real path: rom_sdram.sv, sdram_fb.v at 64.8 MHz unrelated to the core
//             clock, and an SDR SDRAM model; the image is first written through rom_sdram's
//             write side, as rom_loader does on the device (FB_PATH: with the frame buffer)
// The PROMs come over the loader's write port while the core is in reset. A coin and a
// start follow. Counted as late in the picture: characters without data in their window,
// scroll tiles sampled before their word arrived (the layers have no ok), map caches not
// filled when the line becomes visible, sprite lines not finished, map words that
// jtgng_tile4 takes while the map cache still holds an older word.
// Defines: ATTRACT leaves the demo running (no coin, no start). RAW_FRAMES writes every frame
// to frames/all.hex, one line of 256 pixels (12 bits each) per row, 224 rows a frame. In
// game_core, straight from rom[] with ok at once: MAP_IDEAL the map words (the reference
// picture for the map path), CPU_IDEAL the CPUs' bytes (the game then runs the same whatever
// the SDRAM traffic), GFX_IDEAL the scroll layers' graphics words. The slots read as without.
`timescale 1ns/1ps
module tb_1943;
    parameter int FRAMES      = 600;
    parameter int FRAME_EVERY = 30;

    logic clk = 1'b0;
    always #13.468 clk = ~clk;          // 37.125 MHz

    logic        reset = 1'b1;
    logic [15:0] rom_wr_addr = '0;
    logic [7:0]  rom_wr_data = '0;
    logic [15:0] rom_wr_en   = '0;
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
        .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data), .rom_wr_en(rom_wr_en),
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

    // ---------------- ROM image and PROMs ----------------
    logic [31:0] rom  [0:223167];
    logic [7:0]  prom [0:3839];      // section proms (3072), then section palette (768)
    initial begin
        $readmemh("rom32.hex", rom);
        $readmemh("proms.hex", prom);
    end
    // the colour of a palette index, as the platform's palette stage makes it
    // (game_pkg::PALETTE): red, green and blue PROM at 0x000, 0x100, 0x200 of the section
    function automatic logic [11:0] pal12(input logic [7:0] i);
        return {prom[3072 + i][3:0], prom[3328 + i][3:0], prom[3584 + i][3:0]};
    endfunction

`ifndef ROM_PATH
    // ---------------- read stream model ----------------
    // Up to four reads in flight, words in order. Each read is due 9..12 clocks after its
    // push (one in 40 meets a refresh: 13..19), the latency measured on the single-read port
    // before the stream; a word never comes before the one ahead of it, and the ring takes
    // a read only every 3.4 core clocks at most (one per round of six SDRAM cycles), so a
    // read is never due earlier than 4 clocks after the one before.
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
            rom_rd_data  <= rom[m_addr[0][19:2]];
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
    // with the frame buffer of the upright picture on its port B
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
    // ---- frame buffer: fb_pack writes the core's frames, fb_read_rotated turns them ----
    logic clk_pixel = 0;
    always #6.734 clk_pixel = ~clk_pixel;          // 74.25 MHz
    logic [10:0] cx = '0;
    logic [9:0]  cy = '0;
    always @(posedge clk_pixel) begin             // the raster of 1942 and 1943, 1584 x 786, free running
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
    // the upright picture, 448 x 512 from (416, 104), every second pixel and line: 224 x 256
    logic [23:0] up [0:255][0:223];
    int upn = 0;
    always @(posedge clk_pixel) begin
        if (cx >= 416 && cx < 864 && cy >= 104 && cy < 616 && !cx[0] && !cy[0])
            up[(cy - 104) >> 1][(cx - 416) >> 1] <= !game_pkg::PALETTE ? fb_rgb : up_col(fb_pic, fb_rgb);
        if (cx == 0 && cy == 700) begin             // below the picture: one upright frame complete
            upn <= upn + 1;
            if (upn % 60 == 59) dump_up(upn);
        end
    end
    function automatic logic [23:0] up_col(input logic pic, input logic [23:0] c);
        logic [11:0] p;
        p = pal12({c[23:21], c[15:13], c[7:6]});
        return pic ? {p[11:8], p[11:8], p[7:4], p[7:4], p[3:0], p[3:0]} : 24'h000000;
    endfunction
    task automatic dump_up(input int n);
        int fd;
        fd = $fopen($sformatf("frames/u%04d.ppm", n), "w");
        $fwrite(fd, "P3\n224 256\n255\n");
        for (int yy = 0; yy < 256; yy++) begin
            for (int xx = 0; xx < 224; xx++)
                $fwrite(fd, "%0d %0d %0d ", up[yy][xx][23:16], up[yy][xx][15:8], up[yy][xx][7:0]);
            $fwrite(fd, "\n");
        end
        $fclose(fd);
    endtask
    // refreshes armed, and those forced by the deferral limit while a read was pending
    int rf_arms = 0, rf_forced = 0;
    always @(posedge clk_sdram)
        if (ctrl.normal && ctrl.cycle[5] && !ctrl.rfsh_arm && !ctrl.rfsh_wait && ctrl.rfsh_go) begin
            rf_arms++;
            if (ctrl.rd_pend || ctrl.rd_hint) rf_forced++;
        end
    final $display("board probe (game_core): scroll1 %0d, scroll2 %0d late", dut.d_late1, dut.d_late2);
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

    // ---------------- loading the PROMs, then out of reset ----------------
    initial begin
        repeat (20) @(posedge clk);
`ifdef ROM_PATH
        sd_resetn <= 1'b1;
        for (int o = 0; o < 32'hD8000; o++) begin           // all sdram sections
            while (!wr_ready) @(posedge clk);
            wr_we <= 1'b1; wr_off <= 22'(o); wr_byte <= rom[o >> 2][8*(o & 3) +: 8];
            @(posedge clk);
            wr_we <= 1'b0;
            @(posedge clk);
        end
        while (!wr_idle) @(posedge clk);
        $display("image written at %0t", $time);
`endif
        for (int i = 0; i < 3072; i++) begin
            rom_wr_addr <= 16'(i);
            rom_wr_data <= prom[i];
            rom_wr_en   <= 16'h0100;          // section 8, the PROMs
            @(posedge clk);
            rom_wr_en   <= '0;
            @(posedge clk);
        end
        repeat (300) @(posedge clk);
        reset <= 1'b0;
    end

    // ---------------- RAM mirror: a Pico model and the truth ----------------
    // The model fetches a snapshot about every 50 ms, as the firmware does: only when no
    // harvest runs, then snap_run for the whole delivery. Each snapshot is checked twice:
    //   - oracle, as main.c does: for every address logged during the harvest window, the
    //     snapshot holds the last logged value
    //   - truth: the main RAM of jt1943 itself (E000-FFFF in one 8 KiB RAM), read
    //     hierarchically at the end of the harvest: E000-EFFF equals 0x0000-0x0FFF of the
    //     snapshot, F000-F27F equals 0x2000-0x227F, and 0x1000-0x1FFF stays zero Also counted: the most log entries in one window (the platform has 512).
    logic        snap_run = 1'b0, snap_push, snap_harv, log_we;
    logic [7:0]  snap_byte, log_data;
    logic [15:0] snap_frame, log_addr;
    logic [7:0]  ref_ram [0:8831];          // truth at the end of the last harvest
    logic [7:0]  got     [0:8831];          // the delivered snapshot
    logic [7:0]  lg_val  [0:8831];          // last logged value per address in the window
    logic        lg_set  [0:8831];
    int          lg_n = 0, lg_max = 0, snaps = 0, mir_bad = 0, ora_bad = 0, got_n = 0;
    logic        harv_q = 1'b0;
    always @(posedge clk) begin
        harv_q <= snap_harv;
        if (snap_harv && !harv_q) begin                   // window opens
            lg_n = 0;
            for (int i = 0; i < 8832; i++) lg_set[i] = 1'b0;
        end
        if (snap_harv && log_we) begin
            lg_n = lg_n + 1;
            lg_val[log_addr] = log_data;
            lg_set[log_addr] = 1'b1;
        end
        if (!snap_harv && harv_q) begin                   // window closed: the truth now
            if (lg_n > lg_max) lg_max = lg_n;
            for (int i = 0; i < 8832; i++) ref_ram[i] = 8'h00;
            for (int i = 0; i < 4096; i++) ref_ram[i]          = dut.u_game.u_main.RAM.mem[i];
            for (int i = 0; i < 640;  i++) ref_ram[8192 + i]   = dut.u_game.u_main.RAM.mem[4096 + i];
        end
        if (snap_run && snap_push) begin                  // snap_full is 0: every push counts
            if (got_n < 8832) got[got_n] = snap_byte;
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
            repeat (8832 + 50) @(posedge clk);
            snap_run <= 1'b0;
            snaps++;
            if (got_n != 8832) begin
                mir_bad++;
                $display("mirror: snapshot %0d has %0d bytes, expected 8832", snaps, got_n);
            end
            for (int i = 0; i < 8832; i++)
                if (got[i] !== ref_ram[i]) begin
                    if (mir_bad < 8) $display("mirror: snapshot %0d byte %04x is %02x, the core holds %02x", snaps, i, got[i], ref_ram[i]);
                    mir_bad++;
                end
            for (int i = 0; i < 8832; i++)
                if (lg_set[i] && got[i] !== lg_val[i]) begin
                    if (ora_bad < 8) $display("oracle: snapshot %0d byte %04x is %02x, last logged %02x", snaps, i, got[i], lg_val[i]);
                    ora_bad++;
                end
        end
    end

    // ---------------- read latency of the ROM port, as the game sees it ----------------
    // clocks from a push to its word, mean and maximum, how many reads took more than 19
    // clocks (the upper end of the model), and the most reads in flight at once
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
    // Hfix 2 of the next tile; a tile without ok in that window draws the previous pattern.
    // scroll: jtgng_tile4 (LAYOUT 0) takes rom_data at cen6 with HS[1:0] == 1 and has no ok;
    // counted when the slot does not hold the word of the current address then.
    // maps: jt1943_map_cache fills its line cache in the blanking, busy at the start of the
    // visible line means wrong tiles. sprites: jtgng_objcnt must reach draw_over by HINIT.
    int char_late = 0, scr1_late = 0, scr2_late = 0, map_late = 0, obj_lines = 0, obj_short = 0;
    // map words (map_chk below), per layer: clocks from a new map word to its ok, samples
    // taken by jtgng_tile4, of them with ok low, and with a word other than the one at the
    // map address (with and without ok)
    int mlat_hist [2][0:63];
    int mp_smp[2] = '{0, 0}, mp_nok[2] = '{0, 0}, mp_bad[2] = '{0, 0};
    int mp_badok[2] = '{0, 0}, mp_badnok[2] = '{0, 0};
    // new map words in the visible picture that are not the next column of the last one: no
    // prefetch can know them
    int mp_jump[2] = '{0, 0};
    // the map cache entry jtgng_tile4 reads was not written since its 8-pixel group began, at
    // least two clocks before the take (a shadow of the cache's writes); of these, those the
    // board probe in game_core missed, and probe events with the entry written in time
    int mp_late[2] = '{0, 0}, mp_late_miss[2] = '{0, 0}, mp_probe_extra[2] = '{0, 0};
    int mp_bad_intime[2] = '{0, 0};
`ifdef ROM_PATH
    // of the late scroll samples, those whose held word differs from the word the address
    // asks for: only these show as a wrong pattern (the ROM image is in rom[] here)
    int scr1_wrong = 0, scr2_wrong = 0;
    // samples the slot calls ok whose word is not the word at the layer's address
    int scr1_okbad = 0, scr2_okbad = 0;
    // pixel in the line, counted from the start of the visible part (LHBL rising)
    int hpix = 0;
    logic hp_lhbl_q = 0;
    always @(posedge clk) if (dut.cen6) begin
        hp_lhbl_q <= dut.LHBL;
        hpix <= (dut.LHBL && !hp_lhbl_q) ? 0 : hpix + 1;
    end
`endif
    // what-if: a small cache of the last 4 and 8 distinct words per scroll slot; counted are
    // the late scroll-2 samples whose word such a cache would still have held
    logic [21:2] c2 [0:7];
    int c2_hit4 = 0, c2_hit8 = 0;
    logic [21:2] c2_q;
    always @(posedge clk) begin
        c2_q <= dut.off_scr2[21:2];
        if (dut.off_scr2[21:2] != c2_q) begin       // a new word: remember the old one
            for (int i = 7; i > 0; i--) c2[i] <= c2[i-1];
            c2[0] <= c2_q;
        end
    end
    logic chr_seen = 1'b0;
    // counted only once the core runs: under reset (while the image loads) the video timing
    // runs on, but the slots read nothing on purpose
    wire  visible = dut.u_game.LVBL && dut.u_game.LHBL && !reset;
    // the map checker counts from the first vertical blank after the reset, as game_core's
    // probe does: the slots start empty, the first line's map words are always late
    wire  mvisible = visible && dut.dm_on;
    always @(posedge clk) begin
        if (dut.u_game.u_video.u_char.Hfix[2:0] > 3'd2 && dut.u_game.u_video.u_char.rom_ok)
            chr_seen <= 1'b1;
        if (dut.cen6 && dut.u_game.u_video.u_char.Hfix[2:0] == 3'd2) begin
            chr_seen <= 1'b0;
            if (!chr_seen && visible) char_late <= char_late + 1;
        end
        // scroll 1 and 2: counted by scr_probe below, each with its own HS (the scroll
        // position is part of it)
        if (dut.u_game.u_video.u_obj.u_cnt.HINIT_draw && dut.u_game.u_video.u_obj.draw_cen && dut.u_game.LVBL && !reset) begin
            obj_lines <= obj_lines + 1;
            if (!dut.u_game.u_video.u_obj.u_cnt.draw_over) obj_short <= obj_short + 1;
        end
    end

`ifdef DIAG
    // ---------------- diagnosis: late scroll-2 samples, in detail ----------------
    // At a late scroll-2 sample (the probe counts up): the column, whether u_pre2 predicted
    // the address, the time since it changed, the reads in flight and the time since the
    // controller last armed a refresh. Stops after 40 events.
    int d_n = 0, d_last = 0;
    realtime d_chg = 0, d_rfsh = -1e9;
    logic d_took = 0;
    logic [21:2] d_addr_q = '0;
    // where the ROM read was when the refresh was armed: still wanted by a slot (not pushed),
    // in rom_sdram's FIFO, at rom_sdram's output waiting for the arbiter, at the controller
    logic d_arm_q = 0;
    logic [3:0] d_where = '0;
    always @(posedge clk_sdram) begin
        d_arm_q <= ctrl.rfsh_arm;
        if (ctrl.rfsh_arm && !d_arm_q) begin
            d_rfsh  = $realtime;
            d_where = {|dut.u_slots.want, !path.q_empty, path.r_req != path.sd_rd_ack, ctrl.rd_pend};
        end
    end
    always @(posedge clk) begin
        d_addr_q <= dut.off_scr2[21:2];
        if (dut.off_scr2[21:2] != d_addr_q) begin
            d_chg  = $realtime;
            d_took = dut.u_pre2.took;
        end
        if (scr2_late != d_last) begin
            d_last = scr2_late;
            if (d_n < 40)
                $display("scr2 late %0d: frame %0d V %0d | column %0d %s, %s, address %0.0f ns ago | fly %b, in flight %0d | refresh %0.0f ns ago, then want/fifo/share/ctrl %b",
                         d_n, nframe, dut.u_game.V, dut.off_scr2[8:7], dut.u_pre2.down_q ? "down" : "up",
                         d_took ? "predicted" : "not predicted", $realtime - d_chg, dut.u_slots.fly,
                         lat_t0.size(), $realtime - d_rfsh, d_where);
            d_n++;
            if (d_n == 40) $finish;
        end
    end
`endif

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
                frame[y][x] <= game_pkg::PALETTE ? pal12({r[3:1], g[3:1], b[3:2]}) : {r, g, b};
            x <= x + 1;
        end
        if (!vs && vs_d) begin                // start of the vsync pulse: a frame is complete
            if (nframe % FRAME_EVERY == 0) dump(nframe);
`ifdef RAW_FRAMES
            dump_raw();
`endif
            nframe <= nframe + 1;
            y <= -1;
            if (nframe == FRAMES) begin
                $display("done: %0d frames, %0d ROM reads, slot misses %0d", nframe, reads,
                         dut.u_slots.miss);
                $display("late in the picture: char %0d, scroll1 %0d, scroll2 %0d, map caches %0d; sprite lines %0d, unfinished %0d",
                         char_late, scr1_late, scr2_late, map_late, obj_lines, obj_short);
                for (int l = 0; l < 2; l++) begin
                    $write("map latency scroll%0d (clocks from a new map word to ok, visible):", l + 1);
                    for (int k = 0; k < 64; k++) if (mlat_hist[l][k] != 0) $write(" %0d:%0d", k, mlat_hist[l][k]);
                    $display("");
                end
                $display("map words taken: %0d / %0d, ok low %0d / %0d, wrong word %0d / %0d (with ok %0d / %0d, without %0d / %0d)",
                         mp_smp[0], mp_smp[1], mp_nok[0], mp_nok[1], mp_bad[0], mp_bad[1],
                         mp_badok[0], mp_badok[1], mp_badnok[0], mp_badnok[1]);
                $display("map words late at the take (shadow of the cache): %0d / %0d, missed by the board probe %0d / %0d, probe events in time %0d / %0d, wrong words written in time %0d / %0d",
                         mp_late[0], mp_late[1], mp_late_miss[0], mp_late_miss[1],
                         mp_probe_extra[0], mp_probe_extra[1], mp_bad_intime[0], mp_bad_intime[1]);
                $display("map words in the picture not the next column: %0d / %0d", mp_jump[0], mp_jump[1]);
                $display("map words late, board probe (game_core): scroll1 %0d, scroll2 %0d",
                         dut.d_mlate1, dut.d_mlate2);
`ifdef ROM_PATH
                $display("late scroll samples with a different word held: scroll1 %0d, scroll2 %0d", scr1_wrong, scr2_wrong);
                $display("scroll samples ok but with a wrong word: scroll1 %0d, scroll2 %0d", scr1_okbad, scr2_okbad);
                $display("late scroll-2 samples a cache of the last 4 / 8 words would hold: %0d / %0d", c2_hit4, c2_hit8);
`endif
                $display("ROM port: %0d reads, latency mean %0.1f, max %0d clocks, %0d over 19, at most %0d in flight",
                         lat_n, real'(lat_sum) / lat_n, lat_max, lat_over, fly_max);
                $display("mirror: %0d snapshots, %0d bytes differ from the core, %0d against the oracle; most log entries in a window %0d",
                         snaps, mir_bad, ora_bad, lg_max);
                // late data is reported, not fatal: the numbers are the result of this test
                if (snaps == 0 || mir_bad != 0 || ora_bad != 0 || lg_max >= 512) $fatal(1, "FAIL: RAM mirror");
                if (char_late + scr1_late + scr2_late + map_late + obj_short + mp_bad[0] + mp_bad[1] != 0)
                    $display("FAIL: ROM data late in the picture");
                else
                    $display("PASS");
                $finish;
            end
        end
    end

`ifdef RAW_FRAMES
    int raw_fd = 0;
    task automatic dump_raw();
        logic [256*12-1:0] line;
        if (raw_fd == 0) raw_fd = $fopen("frames/all.hex", "w");
        for (int yy = 0; yy < 224; yy++) begin
            for (int xx = 0; xx < 256; xx++) line[(255 - xx)*12 +: 12] = frame[yy][xx];
            $fwrite(raw_fd, "%h\n", line);
        end
    endtask
`endif

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
        $display("frame %0d written, %0d ROM reads so far, late scroll1 %0d scroll2 %0d", n, reads, scr1_late, scr2_late);
    endtask

    // a coin and a start later on, to see the game itself; ATTRACT leaves the demo running
`ifndef ATTRACT
    initial begin
        #(64'd420_000_000);                   // 420 ms after time 0, after the loading
        coin <= 1'b1; #(64'd50_000_000); coin <= 1'b0;
        #(64'd500_000_000);
        start1 <= 1'b1; #(64'd50_000_000); start1 <= 1'b0;
    end
`endif
endmodule

// Both map caches (scroll 1 and 2): busy when their own LHBL rises means the line starts
// with tiles not yet in the cache. Bound into every jt1943_map_cache, counted in tb_1943.
module map_probe (input wire clk, input wire LHBL, input wire busy);
    logic q = 1'b0;
    always @(posedge clk) begin
        q <= LHBL;
        if (LHBL && !q && busy && tb_1943.dut.u_game.LVBL && !tb_1943.reset) tb_1943.map_late++;
    end
endmodule
bind jt1943_map_cache map_probe u_probe (.clk(clk), .LHBL(LHBL), .busy(busy));

// Both scroll layers: jtgng_tile4 takes rom_data at cen6 with HS[1:0] == 1; late if the
// layer's slot does not hold the word of the current address then. Bound into every
// jt1943_scroll, scroll 1 has AS8MASK 1, scroll 2 has 0. Verilator does not resolve a dotted
// path into scroll 2's parameter-dependent generate branch, hence the bind.
module scr_probe (input wire clk, input wire cen6, input wire [1:0] hs, input wire as8mask);
    always @(posedge clk)
        if (cen6 && hs == 2'd1 && tb_1943.visible) begin
            if (as8mask  && !tb_1943.dut.scr1_ok) begin
                tb_1943.scr1_late++;
                $display("late scroll1: frame %0d V %0d pixel %0d", tb_1943.nframe, tb_1943.dut.u_game.V, tb_1943.hpix);
`ifdef ROM_PATH
                if (tb_1943.dut.scr1_word != tb_1943.rom[tb_1943.dut.off_scr1[19:2]]) tb_1943.scr1_wrong++;
`endif
            end
            if (!as8mask && !tb_1943.dut.scr2_ok) begin
                tb_1943.scr2_late++;
                $display("late scroll2: frame %0d V %0d pixel %0d", tb_1943.nframe, tb_1943.dut.u_game.V, tb_1943.hpix);
                for (int i = 0; i < 8; i++)
                    if (tb_1943.c2[i] == tb_1943.dut.off_scr2[21:2]) begin
                        if (i < 4) tb_1943.c2_hit4++;
                        tb_1943.c2_hit8++;
                        break;
                    end
`ifdef ROM_PATH
                if (tb_1943.dut.scr2_word != tb_1943.rom[tb_1943.dut.off_scr2[19:2]]) tb_1943.scr2_wrong++;
`endif
            end
`ifdef ROM_PATH
            if (as8mask && tb_1943.dut.scr1_ok && tb_1943.dut.scr1_word != tb_1943.rom[tb_1943.dut.off_scr1[19:2]]) begin
                tb_1943.scr1_okbad++;
                if (tb_1943.scr1_okbad + tb_1943.scr2_okbad <= 30)
                    $display("ok but wrong: scroll1 frame %0d V %0d addr %05x word %08x expected %08x | cur %0d ok %b fly %b",
                             tb_1943.nframe, tb_1943.dut.u_game.V, tb_1943.dut.off_scr1[21:2], tb_1943.dut.scr1_word,
                             tb_1943.rom[tb_1943.dut.off_scr1[19:2]], tb_1943.dut.s1_cur, tb_1943.dut.slot_ok, tb_1943.dut.u_slots.fly);
            end
            if (!as8mask && tb_1943.dut.scr2_ok && tb_1943.dut.scr2_word != tb_1943.rom[tb_1943.dut.off_scr2[19:2]]) begin
                tb_1943.scr2_okbad++;
                if (tb_1943.scr1_okbad + tb_1943.scr2_okbad <= 30)
                    $display("ok but wrong: scroll2 frame %0d V %0d addr %05x word %08x expected %08x | cur %0d ok %b fly %b",
                             tb_1943.nframe, tb_1943.dut.u_game.V, tb_1943.dut.off_scr2[21:2], tb_1943.dut.scr2_word,
                             tb_1943.rom[tb_1943.dut.off_scr2[19:2]], tb_1943.dut.s2_cur, tb_1943.dut.slot_ok, tb_1943.dut.u_slots.fly);
            end
`endif
        end
endmodule
bind jt1943_scroll scr_probe u_sprobe (.clk(clk), .cen6(cen6), .hs(u_tile4.HS[1:0]), .as8mask(AS8MASK));

// Both map paths: at jtgng_tile4's take of the tile code (cen6, HS[2:0] == 1) the map cache
// must give the word at the map address jt1943_map set last. Counted in the visible picture
// outside the cache's refill burst, with the word from rom[]. Also the clocks from a new map
// word (32 bits) to its ok. Bound into every jt1943_scroll.
module map_chk (input wire clk, input wire cen6, input wire [2:0] hs, input wire as8mask,
                input wire busy, input wire ok, input wire cs, input wire [15:0] q,
                input wire [15:0] hpos, input wire [7:0] sh);
    wire [21:0] off = as8mask ? tb_1943.dut.off_map1 : tb_1943.dut.off_map2;
    wire [31:0] w   = tb_1943.rom[off[19:2]];
    wire [15:0] want = off[1] ? w[31:16] : w[15:0];
    wire        li  = !as8mask;
    logic [21:2] w_q = '0;
    int wcnt = 0;
    logic waiting = 1'b0;
    always @(posedge clk) begin
        w_q <= off[21:2];
        if (off[21:2] != w_q && !busy && tb_1943.mvisible) begin
            wcnt <= 0;
            waiting <= 1'b1;
            if (off[21:15] != w_q[21:15] || off[4:2] != w_q[4:2] ||
                (off[14:5] != w_q[14:5] + 10'd1 && off[14:5] != w_q[14:5] - 10'd1)) begin
                tb_1943.mp_jump[li]++;
                if (tb_1943.mp_jump[0] + tb_1943.mp_jump[1] <= 20)
                    $display("map jump: scroll%0d frame %0d V %0d pixel %0d from %05x to %05x, hpos %04x",
                             li + 1, tb_1943.nframe, tb_1943.dut.u_game.V, tb_1943.hpix, {w_q, 2'b00},
                             {off[21:2], 2'b00}, hpos);
            end
        end else if (waiting) begin
            wcnt <= wcnt + 1;
            if (ok) begin
                waiting <= 1'b0;
                tb_1943.mlat_hist[li][wcnt > 63 ? 63 : wcnt]++;
            end
            if (busy) waiting <= 1'b0;
        end
    end
    // shadow of the cache: whether the entry read now (SH[7:3]) was written since its 8-pixel
    // group began. Before the update in a clock, wr0 holds the writes up to the clock before
    // and wr1 up to two clocks before. The take reads the cache's registered output, so its
    // word must be written two clocks before: wr1.
    logic [4:0] e_q = '0;
    logic wr0 = 1'b0, wr1 = 1'b0;
    logic probe;
    always @(posedge clk) begin
        e_q <= sh[7:3];
        if (cen6 && hs == 3'd1 && tb_1943.mvisible && !busy) begin
            probe = as8mask ? tb_1943.dut.dm_l1 : tb_1943.dut.dm_l2;
            if (!wr1) tb_1943.mp_late[li]++;
            if (!wr1 && !probe) tb_1943.mp_late_miss[li]++;
            if (wr1 && probe) tb_1943.mp_probe_extra[li]++;
            if (wr1 && q != want) tb_1943.mp_bad_intime[li]++;
        end
        if (sh[7:3] != e_q) begin
            wr1 = 1'b0;
            wr0 = ok && cs;
        end else begin
            wr1 = wr0;
            wr0 = wr0 || (ok && cs);
        end
    end
    always @(posedge clk)
        if (cen6 && hs == 3'd1 && tb_1943.mvisible && !busy) begin
            tb_1943.mp_smp[li]++;
            if (!ok) tb_1943.mp_nok[li]++;
            if (q != want) begin
                tb_1943.mp_bad[li]++;
                if (ok) tb_1943.mp_badok[li]++; else tb_1943.mp_badnok[li]++;
                if (tb_1943.mp_bad[0] + tb_1943.mp_bad[1] <= 30)
                    $display("map word wrong: scroll%0d frame %0d V %0d pixel %0d addr %05x got %04x want %04x ok %b",
                             li + 1, tb_1943.nframe, tb_1943.dut.u_game.V, tb_1943.hpix, off, q, want, ok);
            end
        end
endmodule
bind jt1943_scroll map_chk u_mchk (.clk(clk), .cen6(cen6), .hs(u_tile4.HS[2:0]), .as8mask(AS8MASK),
    .busy(cache_busy), .ok(map_ok), .cs(map_cs), .q(mapper_data), .hpos(hpos), .sh(SH));
