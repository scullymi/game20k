// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k, Dig Dug: simulation of game_core (MiSTer-X's core on enables behind our wrapper)
// with its ROM. The clock comes from sim_main.cpp, everything here counts clocks.
// Two ways to serve the program of CPU0, chosen at build time:
//   default   a model of rom_sdram's read stream, latency as measured for 1942 and scaled to
//             46.4 MHz: mostly 11 to 15 core clocks, one read in 40 meets a refresh, 16 to 24
//   LATE      the model with 40 to 60 clocks, longer than CPU0 waits without wait states, to
//             check that the wait states hold it until the byte is there
//   ROM_PATH  the real path: rom_sdram.sv, sdram_fb.v at 64.8 MHz and an SDR SDRAM model. The
//             image is first written through rom_sdram's write side, as rom_loader does
// Sections 1 (the 51XX and 53XX programs) and 2 of the manifest come over the loader's write
// port while the core is in reset.
// Written to the work folder:
//   frames.bin  every frame from FIRST on, 288 x 224 bytes each: the palette PROM byte of each
//               pixel (bits 2:0 red, 5:3 green, 7:6 blue), the raw raster as the core draws it
//   io.log      every access of CPU0 to the 06XX (7000-7100): frame, R or W, address, data
// Checked, and FAIL if not met: the program bytes CPU0 takes equal the ROM image (no late or
// wrong byte), the RAM mirror equals the core's four RAMs and the oracle.
`timescale 1ns/1ps
module tb_digdug (
    input wire clk
`ifdef ROM_PATH
   ,input wire clk_sdram
`endif
);
    int FRAMES = 1200, FIRST = 0, COIN = -1, START = -1, MOVES = -1;
    initial begin
        void'($value$plusargs("frames=%d", FRAMES));
        void'($value$plusargs("first=%d", FIRST));
        void'($value$plusargs("coin=%d", COIN));
        void'($value$plusargs("start=%d", START));
        void'($value$plusargs("moves=%d", MOVES));
    end

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
    logic        coin = 1'b0, start1 = 1'b0, fire = 1'b0;
    logic [3:0]  dir = 4'd0;   // {up, down, left, right}
    logic        snap_run = 1'b0, snap_push, snap_harv, log_we;
    logic [7:0]  snap_byte, log_data;
    logic [15:0] snap_frame, log_addr;

    game_core dut (
        .clk_core(clk), .reset(reset),
        .video_r(r), .video_g(g), .video_b(b), .video_ce(ce),
        .video_blankn(blankn), .video_vs(vs), .video_hs(hs),
        .audio(audio),
        .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data), .rom_wr_en(rom_wr_en),
        .rom_rd_addr(rom_rd_addr), .rom_rd_push(rom_rd_push), .rom_rd_ready(rom_rd_ready),
        .rom_rd_valid(rom_rd_valid), .rom_rd_data(rom_rd_data),
        .cfg_we(1'b0), .cfg_id(8'd0), .cfg_val(8'd0),
        .p1_dir(dir), .p2_dir(4'd0), .p1_fire(fire), .p2_fire(1'b0),
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
    localparam int ROM_N = 58144;
    logic [7:0] rom [0:ROM_N-1];
    initial $readmemh("rom8.hex", rom);
    function automatic logic [31:0] word(input int a);
        return {rom[4*a + 3], rom[4*a + 2], rom[4*a + 1], rom[4*a]};
    endfunction

    longint now = 0;
    always @(posedge clk) now <= now + 1;

`ifndef ROM_PATH
    // ---------------- read stream model ----------------
    // Up to four reads in flight, words in order. Each read is due 11..15 clocks after its
    // push (one in 40 meets a refresh: 16..24), never earlier than 4 clocks after the one before.
    logic [21:2] m_addr [$];
    longint      m_due  [$];
    longint      last_due = 0;
    always @(posedge clk) begin
        rom_rd_valid <= 1'b0;
        if (rom_rd_push && rom_rd_ready) begin
            longint d;
`ifdef LATE
            d = now + 40 + ($urandom % 21);       // check of the wait states: always too late
`else
            d = now + (($urandom % 40 == 0) ? 16 + ($urandom % 9) : 11 + ($urandom % 5));
`endif
            if (d < last_due + 4) d = last_due + 4;
            last_due = d;
            m_addr.push_back(rom_rd_addr);
            m_due.push_back(d);
        end
        if (m_due.size() > 0 && m_due[0] <= now) begin
            rom_rd_data  <= word(int'(m_addr[0][15:2]));
            rom_rd_valid <= 1'b1;
            void'(m_addr.pop_front());
            void'(m_due.pop_front());
        end
        rom_rd_ready <= m_due.size() < 3;
    end
`else
    // ---------------- the real ROM path ----------------
    logic        sd_resetn = 0;
    logic        wr_we = 0;
    logic [21:0] wr_off = '0;
    logic [7:0]  wr_byte = '0;
    logic        wr_ready, wr_idle;
    logic [21:0] sd_wr_addr, sd_rd_addr;
    logic [31:0] sd_wr_din, sd_rd_dout;
    logic [1:0]  sd_wr_bank, sd_rd_bank;
    logic        sd_wr_req, sd_wr_ack, sd_rd_req, sd_rd_ack, sd_rd_valid, sdram_ready, sd_rd_hint;

    rom_sdram #(.AW(22), .BANK(2'd2)) path (
        .clk_core(clk), .reset(1'b0),
        .wr_we(wr_we), .wr_off(wr_off), .wr_data(wr_byte), .wr_ready(wr_ready), .wr_idle(wr_idle),
        .rd_addr(rom_rd_addr), .rd_push(rom_rd_push), .rd_ready(rom_rd_ready),
        .rd_valid(rom_rd_valid), .rd_data(rom_rd_data),
        .clk_sdram(clk_sdram),
        .sd_wr_addr(sd_wr_addr), .sd_wr_din(sd_wr_din), .sd_wr_bank(sd_wr_bank),
        .sd_wr_req(sd_wr_req), .sd_wr_ack(sd_wr_ack),
        .sd_rd_addr(sd_rd_addr), .sd_rd_bank(sd_rd_bank), .sd_rd_req(sd_rd_req),
        .sd_rd_ack(sd_rd_ack), .sd_rd_dout(sd_rd_dout), .sd_rd_valid(sd_rd_valid),
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
        .wr_addr(sd_wr_addr), .wr_din(sd_wr_din), .wr_bank(sd_wr_bank),
        .wr_req(sd_wr_req), .wr_ack(sd_wr_ack),
        .rd_addr(sd_rd_addr), .rd_bank(sd_rd_bank), .rd_req(sd_rd_req), .rd_ack(sd_rd_ack),
        .rd_dout(sd_rd_dout), .rd_valid(sd_rd_valid), .rd_hint(sd_rd_hint)
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
    // step 0: (ROM_PATH) the program into SDRAM through rom_sdram's write side
    // step 1: sections 1 and 2 over the write port, one byte every second clock
    // step 2: 300 clocks, then the core leaves reset
    int  step = 0, li = 0, wait_n = 0;
    logic ph = 1'b0;
    always @(posedge clk) begin
        case (step)
`ifdef ROM_PATH
        0: begin
            sd_resetn <= 1'b1;
            if (wr_we) wr_we <= 1'b0;
            else if (li == 16384) begin
                if (wr_idle) begin step <= 1; li <= 0; end
            end else if (wr_ready && sdram_ready) begin
                wr_we <= 1'b1; wr_off <= 22'(li); wr_byte <= rom[li];
                li <= li + 1;
            end
        end
`else
        0: step <= 1;
`endif
        1: begin
            ph <= ~ph;
            if (!ph) begin
                rom_wr_addr <= 16'(li < 2048 ? li : li - 2048);
                rom_wr_data <= rom[16384 + li];
                rom_wr_en   <= li < 2048 ? 16'h0002 : 16'h0004;
            end else begin
                rom_wr_en <= '0;
                if (li == ROM_N - 16384 - 1) begin step <= 2; li <= 0; end
                else li <= li + 1;
            end
        end
        2: begin
            wait_n <= wait_n + 1;
            if (wait_n == 300) begin reset <= 1'b0; step <= 3; end
        end
        default: ;
        endcase
    end

    // ---------------- frames ----------------
    logic [7:0] frame [0:223][0:287];
    int x = 0, y = -1, nframe = 0, fd_frames = 0, fd_io = 0;
    logic blankn_d = 0, vs_d = 1;
    initial begin
        fd_frames = $fopen("frames.bin", "wb");
        fd_io     = $fopen("io.log", "w");
    end
    always @(posedge clk) begin
        // a line starts with its first visible pixel, x counts the pixels taken so far
        if (ce) begin
            blankn_d <= blankn;
            if (blankn) begin
                int yy, xx;
                yy = blankn_d ? y : y + 1;
                xx = blankn_d ? x : 0;
                if (yy >= 0 && yy < 224 && xx < 288) frame[yy][xx] <= {b[3:2], g[3:1], r[3:1]};
                y <= yy;
                x <= xx + 1;
            end
        end
        vs_d <= vs;
        if (!vs && vs_d && !reset) begin        // start of the vsync pulse: a frame is complete
            if (nframe >= FIRST) dump();
            nframe <= nframe + 1;
            y <= -1;
            if (nframe % 100 == 0) $display("frame %0d", nframe);
            if (nframe == FRAMES) finish();
        end
    end
    task automatic dump();
        for (int yy = 0; yy < 224; yy++)
            for (int xx = 0; xx < 288; xx += 4)
                $fwrite(fd_frames, "%u", {frame[yy][xx + 3], frame[yy][xx + 2], frame[yy][xx + 1], frame[yy][xx]});
    endtask

    // coin and start, held 6 frames each, at the frames given on the command line. From frame
    // MOVES on the stick and the pump as in mame_ref.lua: right 90 frames, down 60, the pump
    // 8 frames on and 8 off for 120, left 90, up 60
    always @(posedge clk) begin
        int n;
        n = nframe - MOVES;
        coin   <= COIN  >= 0 && nframe >= COIN  && nframe < COIN + 6;
        start1 <= START >= 0 && nframe >= START && nframe < START + 6;
        dir    <= MOVES < 0 || n < 0 ? 4'd0 :
                  n <  90 ? 4'b0001 : n < 150 ? 4'b0100 : n < 270 ? 4'd0 :
                  n < 360 ? 4'b0010 : n < 420 ? 4'b1000 : 4'd0;
        fire   <= MOVES >= 0 && n >= 150 && n < 270 && ((n - 150) / 8) % 2 == 0;
    end

    // ---------------- CPU0: program bytes and the 06XX ----------------
    // At the clock edge that ends T2 with wait_n high the Z80 takes the byte on its data bus
    // (tv80s di_reg, tv80_core IR). For a read below 4000 that byte must be the ROM's.
    wire        c0_ce   = dut.u_dd.cores.CPUCE[0];
    wire [15:0] c0_a    = dut.u_dd.cores.cpu0.m_ad;
    wire        c0_rd   = !dut.u_dd.cores.cpu0.core.rd_n && !dut.u_dd.cores.cpu0.core.mreq_n;
    wire        c0_wr   = !dut.u_dd.cores.cpu0.core.wr_n && !dut.u_dd.cores.cpu0.core.mreq_n;
    wire        c0_t2   = dut.u_dd.cores.cpu0.core.i_tv80_core.tstate[2];
    wire        c0_wait = dut.u_dd.cores.cpu0.ROMWAIT;
    wire [7:0]  c0_di   = dut.u_dd.cores.cpu0.m_di;
    wire [7:0]  c0_do   = dut.u_dd.cores.cpu0.m_do;
    longint rom_reads = 0, rom_bad = 0, rom_waits = 0;
    always @(posedge clk) if (c0_ce && !reset) begin
        if (c0_t2 && c0_rd && c0_a < 16'h4000) begin
            if (c0_wait) rom_waits++;
            else begin
                rom_reads++;
                if (c0_di !== rom[c0_a]) begin
                    if (rom_bad < 8) $display("CPU0 took %02x at %04x, the ROM has %02x (frame %0d)", c0_di, c0_a, rom[c0_a], nframe);
                    rom_bad++;
                end
            end
        end
        if (c0_t2 && c0_rd && !c0_wait && c0_a >= 16'h7000 && c0_a <= 16'h7100)
            $fwrite(fd_io, "%0d R %04x %02x\n", nframe, c0_a, c0_di);
        if (c0_t2 && c0_wr && c0_a >= 16'h7000 && c0_a <= 16'h7100)
            $fwrite(fd_io, "%0d W %04x %02x\n", nframe, c0_a, c0_do);
    end

    // writes into the upper halves of RAM 1..3 (8C00-8FFF, 9400-97FF, 9C00-9FFF): the board
    // mirrors them onto the lower halves, the core keeps them apart, the mirror leaves them out
    longint upper_w = 0;
    always @(posedge clk)
        if (dut.u_dd.DEV_CL && dut.u_dd.DEV_WR && dut.u_dd.DEV_AD[15:13] == 3'b100 &&
            dut.u_dd.DEV_AD[11] && dut.u_dd.DEV_AD[10]) upper_w++;

    // ---------------- RAM mirror: a Pico model and the truth ----------------
    // Every third frame the model fetches a snapshot, only when no harvest runs, then snap_run
    // for the whole delivery. Each snapshot is checked twice: against the oracle (the last
    // logged value per address of the harvest window) and against the truth, the core's four
    // RAMs read hierarchically at the end of the harvest.
    localparam int MN = 5120;
    logic [7:0]  ref_ram [0:MN-1];
    logic [7:0]  got     [0:MN-1];
    logic [7:0]  lg_val  [0:MN-1];
    logic        lg_set  [0:MN-1];
    int          lg_n = 0, lg_max = 0, snaps = 0, mir_bad = 0, ora_bad = 0, got_n = 0;
    longint      ev_total = 0;
    logic        harv_q = 1'b0;
    always @(posedge clk) begin
        harv_q <= snap_harv;
        if (log_we) ev_total++;
        if (snap_harv && !harv_q) begin
            lg_n = 0;
            for (int i = 0; i < MN; i++) lg_set[i] = 1'b0;
        end
        if (snap_harv && log_we) begin
            lg_n = lg_n + 1;
            lg_val[log_addr] = log_data;
            lg_set[log_addr] = 1'b1;
        end
        if (!snap_harv && harv_q) begin
            if (lg_n > lg_max) lg_max = lg_n;
            for (int i = 0; i < 2048; i++) ref_ram[i]        = dut.u_dd.iodev.ram0.ram.core[i];
            for (int i = 0; i < 1024; i++) ref_ram[2048 + i] = dut.u_dd.iodev.ram1.ram.core[i];
            for (int i = 0; i < 1024; i++) ref_ram[3072 + i] = dut.u_dd.iodev.ram2.ram.core[i];
            for (int i = 0; i < 1024; i++) ref_ram[4096 + i] = dut.u_dd.iodev.ram3.ram.core[i];
        end
        if (snap_run && snap_push) begin
            if (got_n < MN) got[got_n] = snap_byte;
            got_n = got_n + 1;
        end
    end
    // the model: wait for frame 30, then every third frame
    int sstate = 0, scount = 0, slast = -1;
    always @(posedge clk) begin
        case (sstate)
        0: if (nframe >= 30 && nframe % 3 == 0 && nframe != slast && !snap_harv) begin
               slast <= nframe; got_n = 0; snap_run <= 1'b1; scount <= 0; sstate <= 1;
           end
        1: begin
               scount <= scount + 1;
               if (scount == MN + 50) begin snap_run <= 1'b0; sstate <= 2; end
           end
        2: begin
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
               sstate <= 0;
           end
        default: ;
        endcase
    end

    // ---------------- ROM read latency, as the game sees it ----------------
    int lat_n = 0, lat_max = 0;
    longint lat_sum = 0;
    longint lat_t0 [$];
    always @(posedge clk) begin
        if (rom_rd_push && rom_rd_ready) lat_t0.push_back(now);
        if (rom_rd_valid && lat_t0.size() > 0) begin
            int t;
            t = int'(now - lat_t0.pop_front());
            lat_n++; lat_sum += t;
            if (t > lat_max) lat_max = t;
        end
    end

    task automatic finish();
        $display("done: %0d frames, CPU0 program bytes %0d, wrong %0d, wait states %0d, slot misses %0d",
                 nframe, rom_reads, rom_bad, rom_waits, dut.rom_miss);
        $display("ROM port: %0d reads, latency mean %0.1f, max %0d clocks",
                 lat_n, lat_n ? real'(lat_sum) / lat_n : 0.0, lat_max);
        $display("mirror: %0d snapshots, %0d bytes differ from the core, %0d against the oracle; %0d events, most log entries in a window %0d; writes to upper RAM halves %0d",
                 snaps, mir_bad, ora_bad, ev_total, lg_max, upper_w);
        $fclose(fd_frames);
        $fclose(fd_io);
        if (rom_bad != 0 || rom_reads == 0) $fatal(1, "FAIL: CPU0 program bytes");
        if (snaps == 0 || mir_bad != 0 || ora_bad != 0 || lg_max >= 512) $fatal(1, "FAIL: RAM mirror");
        $display("PASS (the picture is checked against MAME by compare.py)");
        $finish;
    endtask
endmodule
