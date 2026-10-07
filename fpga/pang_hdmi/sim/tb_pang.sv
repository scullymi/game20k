// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k, Pang and Super Pang: simulation of game_core (jotego's jtpang behind our wrapper)
// with the ROM file. Two ways to serve the five ROM buses, chosen at build time:
//   default   a model of rom_sdram's read stream with the latency measured on the device's
//             path: mostly 9 to 12 core clocks, one read in 40 meets a refresh, 13 to 19
//   ROM_PATH  the real path: rom_sdram.sv, sdram_share.sv with its frame buffer port idle (as
//             the top builds it without frame buffer), sdram_fb.v at 64.8 MHz unrelated to
//             the core clock, and an SDR SDRAM model; the image is first written through
//             rom_sdram's write side, as rom_loader does on the device
// The EEPROM and the header section come over the loader's write port while the core is in
// reset, in file order. Frames are counted from the first vertical sync after the reset;
// every FRAME_EVERY-th one is written as frames/fNNNN.ppm (384 x 240, 4 bits per colour).
// COIN_F and START_F (frames, 0 for none) put in a coin and press start 1, each for 6 frames.
// FIRE_F (0 for none) presses button 1 FIRE_N times, every 30 frames from FIRE_F, for 6 frames.
// Run by run_sim.sh, which writes rom32.hex, ee.hex, id.hex and, from MAME, kab_op.hex and
// kab_data.hex into the work folder (with +kab_n=<bytes>).
`timescale 1ns/1ps
module tb_pang;
    parameter int FRAMES      = 600;
    parameter int FRAME_EVERY = 10;
    parameter int COIN_F      = 0;
    parameter int START_F     = 0;
    parameter int FIRE_F      = 0;
    parameter int FIRE_N      = 1;

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
    logic        coin = 1'b0, start1 = 1'b0, fire1 = 1'b0;

    game_core dut (
        .clk_core(clk), .reset(reset),
        .video_r(r), .video_g(g), .video_b(b), .video_ce(ce),
        .video_blankn(blankn), .video_vs(vs), .video_hs(hs),
        .audio(audio),
        .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data), .rom_wr_en(rom_wr_en),
        .rom_rd_addr(rom_rd_addr), .rom_rd_push(rom_rd_push), .rom_rd_ready(rom_rd_ready),
        .rom_rd_valid(rom_rd_valid), .rom_rd_data(rom_rd_data),
        .cfg_we(1'b0), .cfg_id(8'd0), .cfg_val(8'd0),
        .p1_dir(4'd0), .p2_dir(4'd0), .p1_fire(fire1), .p2_fire(1'b0),
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

    // ---------------- ROM image, write port sections, MAME's decrypted views ----------------
    localparam int WORDS = 32'h170000 / 4;     // the SDRAM part of the file
    logic [31:0] rom   [0:WORDS-1];
    logic [7:0]  ee    [0:127];
    logic [7:0]  idsec [0:3];
    logic [7:0]  kab_op   [0:32'h47FFF];
    logic [7:0]  kab_data [0:32'h47FFF];
    int          kab_n = 0;                    // bytes of MAME's views, 0: no check
    initial begin
        $readmemh("rom32.hex", rom);
        $readmemh("ee.hex", ee);
        $readmemh("id.hex", idsec);
        // +kab_n=<bytes of MAME's views>, without it no check
        if ($value$plusargs("kab_n=%d", kab_n)) begin
            $readmemh("kab_op.hex", kab_op);
            $readmemh("kab_data.hex", kab_data);
        end
    end

`ifndef ROM_PATH
    // ---------------- read stream model ----------------
    // Up to four reads in flight, words in order. Each read is due 9..12 clocks after its
    // push (one in 40 meets a refresh: 13..19); a word never comes before the one ahead of it,
    // and the ring takes a read only every 3.4 core clocks at most, so a read is never due
    // earlier than 4 clocks after the one before. As tb_1942.sv.
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
            rom_rd_data  <= rom[m_addr[0][20:2]];
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
    logic [21:0] c_wr_addr, c_rd_addr;
    logic [31:0] c_wr_din;
    logic [1:0]  c_wr_bank, c_rd_bank;
    logic        c_wr_req, c_wr_ack, c_rd_req, c_rd_ack, c_rd_valid;
    sdram_fb #(.FREQ(64_800_000), .CAS(3'd2)) ctrl (
        .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_DQM(dqm), .SDRAM_BA(ba),
        .SDRAM_nCS(ncs), .SDRAM_nWE(nwe), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas), .SDRAM_CKE(cke),
        .clk(clk_sdram), .resetn(sd_resetn), .sdram_ready(sdram_ready), .cap_ofs(2'd1),
        .wr_addr(c_wr_addr), .wr_din(c_wr_din), .wr_bank(c_wr_bank),
        .wr_req(c_wr_req), .wr_ack(c_wr_ack),
        .rd_addr(c_rd_addr), .rd_bank(c_rd_bank), .rd_req(c_rd_req), .rd_ack(c_rd_ack),
        .rd_dout(sd_rd_dout), .rd_valid(c_rd_valid), .rd_hint(sd_rd_hint)
    );
    // sdram_share as the top builds it without frame buffer: port B never asks
    sdram_share share (
        .clk(clk_sdram),
        .c_wr_addr(c_wr_addr), .c_wr_din(c_wr_din), .c_wr_bank(c_wr_bank), .c_wr_req(c_wr_req), .c_wr_ack(c_wr_ack),
        .c_rd_addr(c_rd_addr), .c_rd_bank(c_rd_bank), .c_rd_req(c_rd_req), .c_rd_dout(sd_rd_dout), .c_rd_ack(c_rd_ack), .c_rd_valid(c_rd_valid),
        .a_wr_addr(sd_wr_addr), .a_wr_din(sd_wr_din), .a_wr_bank(sd_wr_bank), .a_wr_req(sd_wr_req), .a_wr_ack(sd_wr_ack),
        .a_rd_addr(sd_rd_addr), .a_rd_bank(sd_rd_bank), .a_rd_req(sd_rd_req), .a_rd_ack(sd_rd_ack), .a_rd_dout(rom_rd_dout), .a_rd_valid(sd_rd_valid),
        .b_wr_addr(22'd0), .b_wr_din(32'd0), .b_wr_bank(2'd0), .b_wr_req(1'b0), .b_wr_ack(),
        .b_rd_addr(22'd0), .b_rd_bank(2'd0), .b_rd_req(1'b0), .b_rd_ack(), .b_rd_valid()
    );
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
        for (int o = 0; o < 32'h170000; o++) begin
            while (!wr_ready) @(posedge clk);
            wr_we <= 1'b1; wr_off <= 22'(o); wr_byte <= rom[o >> 2][8*(o & 3) +: 8];
            @(posedge clk);
            wr_we <= 1'b0;
            @(posedge clk);
        end
        while (!wr_idle) @(posedge clk);
        $display("image written at %0t", $time);
`endif
        // section 5, the EEPROM, then section 6, the header, as in the file
        for (int i = 0; i < 128; i++) begin
            rom_wr_addr <= 16'(i); rom_wr_data <= ee[i]; rom_wr_en <= 16'h0020;
            @(posedge clk);
            rom_wr_en <= '0;
            @(posedge clk);
        end
        for (int i = 0; i < 4; i++) begin
            rom_wr_addr <= 16'(i); rom_wr_data <= idsec[i]; rom_wr_en <= 16'h0040;
            @(posedge clk);
            rom_wr_en <= '0;
            @(posedge clk);
        end
        repeat (300) @(posedge clk);
        reset <= 1'b0;
    end

    // ---------------- RAM mirror: a Pico model and the truth ----------------
    // The model fetches a snapshot about every 50 ms, as the firmware does. Each snapshot is
    // checked twice:
    //   - oracle, as main.c does: for every address logged during the harvest window, the
    //     snapshot holds the last logged value
    //   - truth: the work RAM and the tile map window of jtpang itself, read hierarchically at
    //     the end of the harvest, equal the snapshot byte for byte, and every other byte is 0
    // Also counted: the most log entries in one window (the platform has 512).
    localparam int MN = rom_map_pkg::MIRROR_DATA;
    logic        snap_run = 1'b0, snap_push, snap_harv, log_we;
    logic [7:0]  snap_byte, log_data;
    logic [15:0] snap_frame, log_addr;
    logic [7:0]  ref_ram [0:MN-1];          // truth at the end of the last harvest
    logic [7:0]  got     [0:MN-1];          // the delivered snapshot
    logic [7:0]  lg_val  [0:MN-1];          // last logged value per address in the window
    logic        lg_set  [0:MN-1];
    int          lg_n = 0, lg_max = 0, snaps = 0, mir_bad = 0, ora_bad = 0, got_n = 0, harv_clk = 0, harv_max = 0;
    logic        harv_q = 1'b0;
    always @(posedge clk) begin
        harv_q <= snap_harv;
        if (snap_harv) harv_clk = harv_clk + 1;
        if (snap_harv && !harv_q) begin                   // window opens
            lg_n = 0;
            harv_clk = 1;
            for (int i = 0; i < MN; i++) lg_set[i] = 1'b0;
        end
        if (snap_harv && log_we) begin
            lg_n = lg_n + 1;
            lg_val[log_addr] = log_data;
            lg_set[log_addr] = 1'b1;
        end
        if (!snap_harv && harv_q) begin                   // window closed: the truth now
            if (lg_n > lg_max) lg_max = lg_n;
            if (harv_clk > harv_max) harv_max = harv_clk;
            for (int i = 0; i < MN; i++) ref_ram[i] = 8'd0;
            for (int i = 0; i < 8192; i++)
                ref_ram[i] = dut.u_main.u_cpu.u_ram.u_dual.u_ram.mem[i];
            for (int i = 32'h4600; i < 32'h4700 && i < MN; i++)
                ref_ram[i] = dut.u_video.u_char.u_vram.u_ram.mem[i - 32'h3800];
        end
        if (snap_run && snap_push) begin                  // snap_full is 0: every push counts
            if (got_n < MN) got[got_n] = snap_byte;
            got_n = got_n + 1;
        end
    end
    initial begin
        #(64'd400_000_000);                               // the game runs by then
        forever begin
            #(64'd50_000_000);
            @(posedge clk);
            while (snap_harv) @(posedge clk);
            got_n = 0;
            snap_run <= 1'b1;
            repeat (MN + 50) @(posedge clk);
            snap_run <= 1'b0;
            snaps++;
            if (got_n != MN) begin
                mir_bad++;
                $display("mirror: snapshot %0d has %0d bytes, expected %0d", snaps, got_n, MN);
            end
            for (int i = 0; i < MN; i++)
                if (got[i] !== ref_ram[i]) begin
                    if (mir_bad < 8) $display("mirror: snapshot %0d byte %04x is %02x, the core holds %02x", snaps, i, got[i], ref_ram[i]);
                    mir_bad++;
                end
            for (int i = 0; i < MN; i++)
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

    // ---------------- late ROM data, per path ----------------
    // char: jtpang_char sets its ROM address and takes the word of the previous address in the
    //   same pixel enable, {hf[2:1], h[0]} == 1, every 8 pixels (37 clocks), without ok. Late
    //   means the slot does not hold the word then; "wrong" counts the late ones whose held
    //   word differs from the right one, a wrong pattern on screen. Counted in visible lines.
    // pcm: jt6295_rom takes an ADPCM byte at the end of its two cen32 slots, without ok.
    // obj: the scan and the last drawing must be done when the line buffer swaps (hs rises),
    //   else sprites of that line are missing. Counted in visible lines.
    // cpu: clocks the CPU waited for a ROM byte, and its clock enables against the 8 MHz.
    int chr_n = 0, chr_late = 0, chr_wrong = 0, pcm_n = 0, pcm_late = 0, pcm_wrong = 0;
    int obj_lines = 0, obj_short = 0, obj_most = 0;
    longint cpu_wait = 0, cpu_cen = 0, pxl_cens = 0, cpu_miss = 0, cpu_lost = 0;
    int     miss_max = 0;
    logic   hs_q = 1'b0;
    wire [2:0] chr_ph = {dut.u_video.u_char.hf[2:1], dut.u_video.u_char.h[0]};
    wire [21:0] chr_off = 22'h0B0000 + 22'({dut.char_addr[18:2], 2'b00});
    wire [21:0] pcm_off = 22'h090000 + 22'(dut.pcm_addr[16:0]);
    // for a late one: clocks since the character address changed, until its read went out,
    // and which slots had a read in flight at the change
    // for the rest: the margin, clocks from the word's arrival to the take, its minimum and how
    // many takes had less than 8
    longint chr_clk = 0, chr_t_addr = 0, chr_t_push = 0, chr_t_ok = 0;
    logic [20:2] chr_addr_q = '0;
    logic [7:0]  chr_fly_at = '0;
    logic        chr_ok_q = 1'b0;
    int          chr_slack_min = 1 << 30, chr_slack_low = 0;
    always @(posedge clk) begin
        chr_clk++;
        chr_ok_q <= dut.slot_ok[0];
        if (dut.slot_ok[0] && !chr_ok_q) chr_t_ok = chr_clk;
        chr_addr_q <= dut.char_addr;
        if (dut.char_addr != chr_addr_q) begin
            chr_t_addr = chr_clk;
            chr_fly_at = dut.u_slots.fly;
        end
        if (dut.rom_rd_push && dut.u_slots.pick == 0) chr_t_push = chr_clk;
    end
    always @(posedge clk) begin
        if (!reset && dut.pxl_cen && chr_ph == 3'd1 && dut.char_cs && dut.LVBL) begin
            chr_n++;
            if (!dut.chr_ff && !dut.slot_ok[0]) begin
                chr_late++;
                if (dut.slot_data[0] != rom[chr_off[21:2]]) chr_wrong++;
                if (chr_late <= 16)
                    $display("char late: frame %0d line %0d, %0d clocks after the address, read out after %0d, in flight at the change %b",
                             tb_pang.nframe + 1, tb_pang.y, chr_clk - chr_t_addr, chr_t_push - chr_t_addr, chr_fly_at);
            end else if (!dut.chr_ff) begin
                if (int'(chr_clk - chr_t_ok) < chr_slack_min) chr_slack_min = int'(chr_clk - chr_t_ok);
                if (chr_clk - chr_t_ok < 8) chr_slack_low++;
            end
        end
        if (!reset && dut.u_snd.u_pcm.u_rom.st == 8'b10 && dut.u_snd.u_pcm.u_rom.cen32 && !dut.u_snd.u_pcm.u_rom.cen4
            && !dut.pcm_ff) begin
            pcm_n++;
            if (!dut.slot_ok[1]) begin
                pcm_late++;
                if (dut.pcm_data != rom[pcm_off[21:2]][8*pcm_off[1:0] +: 8]) pcm_wrong++;
            end
        end
        hs_q <= dut.HS;
        if (!reset && dut.HS && !hs_q && dut.LVBL) begin
            obj_lines++;
            if (!dut.u_video.u_obj.scan_done || dut.u_video.u_obj.dr_busy || dut.u_video.u_obj.dr_start)
                obj_short++;
            if (dut.u_video.u_obj.drawn > obj_most) obj_most = dut.u_video.u_obj.drawn;
        end
        // jtframe_z80wait holds a CPU clock enable while the ROM byte is not there (miss) and
        // gives it back later while the bus is idle, up to 15; a miss beyond that is lost
        if (!reset) begin
            pxl_cens += dut.pxl_cen;
            cpu_cen  += dut.u_main.u_cpu.cpu_cen;
            if (dut.main_cs && !dut.main_ok) cpu_wait++;
            if (dut.pxl_cen && !dut.u_main.u_cpu.u_z80wait.u_z80_devwait.u_wait.gate) begin
                cpu_miss++;
                if (dut.u_main.u_cpu.u_z80wait.u_z80_devwait.u_wait.miss_cnt == 4'hF) cpu_lost++;
            end
            if (dut.u_main.u_cpu.u_z80wait.u_z80_devwait.u_wait.miss_cnt > miss_max)
                miss_max = dut.u_main.u_cpu.u_z80wait.u_z80_devwait.u_wait.miss_cnt;
        end
    end

    // ---------------- every ROM byte the CPU takes, against MAME's decrypted views ----------------
    // At the clock a ROM access becomes ok, the byte on main_data must be MAME's opcode view
    // for an M1 fetch and its data view otherwise, at the same ROM offset (fixed 32 KiB, then
    // the 16 KiB banks). Counted once per access: per change of address or M1.
    int   kab_chk = 0, kab_bad = 0, kab_op_n = 0;
    logic ok_q = 1'b0;
    logic [20:0] acc_q = '1;
    always @(posedge clk) begin
        ok_q <= dut.main_cs && dut.main_ok;
        if (dut.main_cs) acc_q <= {dut.main_m1, dut.main_addr};
        if (!reset && kab_n != 0 && dut.main_cs && dut.main_ok &&
            (!ok_q || acc_q != {dut.main_m1, dut.main_addr})) begin
            logic [7:0] want;
            want = dut.main_m1 ? kab_op[dut.main_addr] : kab_data[dut.main_addr];
            kab_chk++;
            if (dut.main_m1) kab_op_n++;
            if (dut.main_addr < kab_n && dut.main_data !== want) begin
                if (kab_bad < 8) $display("kabuki: %s at %05x is %02x, MAME %02x",
                                          dut.main_m1 ? "opcode" : "data", dut.main_addr, dut.main_data, want);
                kab_bad++;
            end
        end
    end

    // ---------------- frames ----------------
    logic [11:0] frame [0:239][0:383];
    int x = 0, y = -1, nframe = -1;
    logic blankn_d = 0, vs_d = 1;
    always @(posedge clk) begin
        blankn_d <= blankn;
        vs_d     <= vs;
        if (blankn && !blankn_d) begin y <= y + 1; x <= 0; end
        if (ce && blankn) begin
            if (x < 384 && y >= 0 && y < 240) frame[y][x] <= {r, g, b};
            x <= x + 1;
        end
        if (!vs && vs_d && !reset) begin       // start of the vsync pulse: a frame is complete
            if (nframe >= 0 && nframe % FRAME_EVERY == 0) dump(nframe);
            nframe <= nframe + 1;
            y <= -1;
            if (COIN_F  != 0) coin   <= (nframe + 1 >= COIN_F  && nframe + 1 < COIN_F  + 6);
            if (START_F != 0) start1 <= (nframe + 1 >= START_F && nframe + 1 < START_F + 6);
            if (FIRE_F  != 0) fire1  <= (nframe + 1 >= FIRE_F && nframe + 1 < FIRE_F + 30 * FIRE_N
                                         && (nframe + 1 - FIRE_F) % 30 < 6);
            if (nframe == FRAMES) finish();
        end
    end

`ifdef PANGDBG
    // diagnosis: the address of the last opcode fetch at every vertical sync, to set beside
    // MAME's PC per frame (manager.machine.devices[":maincpu"].state["PC"])
    logic [15:0] last_m1;
    always @(posedge clk) begin
        if (dut.main_cs && dut.main_m1) last_m1 <= dut.u_main.A;
        if (!vs && vs_d && !reset) $display("PANGPC %0d %04x bank %0d", nframe + 1, last_m1, dut.u_main.bank);
    end
`endif

    task automatic finish();
        $display("done: %0d frames, %0d ROM reads", nframe, reads);
        $display("char: %0d fetches in visible lines, %0d late, %0d of them with another word",
                 chr_n, chr_late, chr_wrong);
        $display("char: margin at least %0d clocks, %0d takes with less than 8", chr_slack_min, chr_slack_low);
        $display("pcm: %0d ADPCM bytes, %0d late, %0d of them with another byte", pcm_n, pcm_late, pcm_wrong);
        $display("sprite lines %0d, unfinished %0d, most sprites in a line %0d", obj_lines, obj_short, obj_most);
        $display("cpu: %0d clocks waiting for ROM, %0d clock enables held, %0d of them lost, most owed at once %0d",
                 cpu_wait, cpu_miss, cpu_lost, miss_max);
        $display("cpu: %0d clock enables against %0d pixel enables (%0.5f)",
                 cpu_cen, pxl_cens, real'(cpu_cen) / real'(pxl_cens));
        $display("kabuki: %0d ROM bytes checked against MAME (%0d opcode fetches), %0d differ",
                 kab_chk, kab_op_n, kab_bad);
        $display("ROM port: %0d reads, latency mean %0.1f, max %0d clocks, %0d over 19, at most %0d in flight",
                 lat_n, real'(lat_sum) / lat_n, lat_max, lat_over, fly_max);
        $display("mirror: %0d snapshots, %0d bytes differ from the core, %0d against the oracle; most log entries in a window %0d, longest window %0d clocks",
                 snaps, mir_bad, ora_bad, lg_max, harv_max);
        $display("game_id %0d, the id section says %0d", dut.game_id, idsec[0]);
        if (dut.game_id != idsec[0][1:0]) $fatal(1, "FAIL: game_id %0d, the id section says %0d", dut.game_id, idsec[0]);
        if (kab_n == 0) $display("kabuki: no MAME views, not checked");
        else if (kab_chk == 0 || kab_bad != 0) $fatal(1, "FAIL: ROM bytes differ from MAME's views");
        if (chr_wrong + pcm_late + obj_short != 0) $fatal(1, "FAIL: ROM data late");
        if (snaps == 0 || mir_bad != 0 || ora_bad != 0 || lg_max >= 512) $fatal(1, "FAIL: RAM mirror");
        $display("PASS");
        $finish;
    endtask

    task automatic dump(input int n);
        int fd;
        fd = $fopen($sformatf("frames/f%04d.ppm", n), "w");
        $fwrite(fd, "P3\n384 240\n15\n");
        for (int yy = 0; yy < 240; yy++) begin
            for (int xx = 0; xx < 384; xx++)
                $fwrite(fd, "%0d %0d %0d ", frame[yy][xx][11:8], frame[yy][xx][7:4], frame[yy][xx][3:0]);
            $fwrite(fd, "\n");
        end
        $fclose(fd);
        $display("frame %0d written, %0d ROM reads so far", n, reads);
    endtask
endmodule
