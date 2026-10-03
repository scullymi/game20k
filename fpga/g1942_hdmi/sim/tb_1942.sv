// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k, 1942: simulation of game_core (jotego's jt1942 behind our wrapper) with its ROM.
// Two ways to serve the five ROM buses, chosen at build time:
//   default   a model of rom_sdram's read port with the latency measured in path mode:
//             mostly 10 to 13 core clocks, one read in 40 meets a refresh and takes 14 to 20
//   ROM_PATH  the real path: rom_sdram.sv, sdram_fb.v at 64.8 MHz unrelated to the core
//             clock, and an SDR SDRAM model; the image is first written through rom_sdram's
//             write side, as rom_loader does on the device
// The character ROM and the PROMs come over the loader's write port while the core is in
// reset. A coin and a start follow, so the frames show the game itself. Every FRAME_EVERY-th frame is written as
// frames/fNNNN.ppm, the raw raster (256 x 224, the game turned on its side). Run by
// run_sim.sh, which reads the ROM image from rom32.hex and proms.hex in its work folder.
`timescale 1ns/1ps
module tb_1942;
    parameter int FRAMES      = 600;
    parameter int FRAME_EVERY = 30;

    logic clk = 1'b0;
    always #13.468 clk = ~clk;          // 37.125 MHz

    logic        reset = 1'b1;
    logic [15:0] rom_wr_addr = '0;
    logic [7:0]  rom_wr_data = '0;
    logic [15:0] rom_wr_en   = '0;
    logic [21:2] rom_rd_addr;
    logic        rom_rd_req;
`ifdef ROM_PATH
    logic        rom_rd_ack;
    logic [31:0] rom_rd_data;
`else
    logic        rom_rd_ack  = 1'b0;
    logic [31:0] rom_rd_data = '0;
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
        .rom_rd_addr(rom_rd_addr), .rom_rd_req(rom_rd_req), .rom_rd_ack(rom_rd_ack),
        .rom_rd_data(rom_rd_data),
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
    logic [31:0] rom  [0:60031];
    logic [7:0]  prom [0:2559];
    initial begin
        $readmemh("rom32.hex", rom);
        $readmemh("proms.hex", prom);
    end

`ifndef ROM_PATH
    // ---------------- read port model ----------------
    int          wait_cnt = 0;
    logic        pending  = 1'b0;
    int          reads = 0;
    always @(posedge clk) begin
        if (!pending && rom_rd_req != rom_rd_ack) begin
            pending  <= 1'b1;
            // measured in path mode: mean 11.7, at most 20 clocks, 0.25 % above 19: mostly
            // 10..13, one read in 40 meets a refresh and takes 14..20. This model adds two
            // clocks of its own (request seen, acknowledge registered), hence 8..11 and 12..18.
            wait_cnt <= ($urandom % 40 == 0) ? 12 + ($urandom % 7) : 8 + ($urandom % 4);
        end else if (pending) begin
            if (wait_cnt <= 1) begin
                rom_rd_data <= rom[rom_rd_addr[17:2]];
                rom_rd_ack  <= rom_rd_req;
                pending     <= 1'b0;
                reads       <= reads + 1;
            end else
                wait_cnt <= wait_cnt - 1;
        end
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
    logic [31:0] sd_wr_din, sd_rd_dout;
    logic [1:0]  sd_wr_bank, sd_rd_bank;
    logic        sd_wr_req, sd_wr_ack, sd_rd_req, sd_rd_ack, sd_rd_valid, sdram_ready;
    int          reads = 0;
    logic        rom_rd_req_q = 0;
    always @(posedge clk) begin
        rom_rd_req_q <= rom_rd_req;
        if (rom_rd_req != rom_rd_req_q) reads <= reads + 1;
    end

    rom_sdram #(.AW(22), .BANK(2'd2)) path (
        .clk_core(clk), .reset(1'b0),
        .wr_we(wr_we), .wr_off(wr_off), .wr_data(wr_byte), .wr_ready(wr_ready), .wr_idle(wr_idle),
        .rd_addr(rom_rd_addr), .rd_req(rom_rd_req), .rd_ack(rom_rd_ack), .rd_data(rom_rd_data),
        .clk_sdram(clk_sdram),
        .sd_wr_addr(sd_wr_addr), .sd_wr_din(sd_wr_din), .sd_wr_bank(sd_wr_bank),
        .sd_wr_req(sd_wr_req), .sd_wr_ack(sd_wr_ack),
        .sd_rd_addr(sd_rd_addr), .sd_rd_bank(sd_rd_bank), .sd_rd_req(sd_rd_req),
        .sd_rd_ack(sd_rd_ack), .sd_rd_dout(sd_rd_dout), .sd_rd_valid(sd_rd_valid)
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
        .rd_dout(sd_rd_dout), .rd_valid(sd_rd_valid)
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

    // ---------------- loading the PROMs, then out of reset ----------------
    initial begin
        repeat (20) @(posedge clk);
`ifdef ROM_PATH
        sd_resetn <= 1'b1;
        for (int o = 0; o < 32'h3A000; o++) begin
            if (o >= 32'h18000 && o < 32'h1A000) continue;   // the characters go to block RAM
            while (!wr_ready) @(posedge clk);
            wr_we <= 1'b1; wr_off <= 22'(o); wr_byte <= rom[o >> 2][8*(o & 3) +: 8];
            @(posedge clk);
            wr_we <= 1'b0;
            @(posedge clk);
        end
        while (!wr_idle) @(posedge clk);
        $display("image written at %0t", $time);
`endif
        // the characters, section 2, over the write port into game_core's block RAM
        for (int i = 0; i < 8192; i++) begin
            rom_wr_addr <= 16'(i);
            rom_wr_data <= rom[(32'h18000 + i) >> 2][8*(i & 3) +: 8];
            rom_wr_en   <= 16'h0004;
            @(posedge clk);
            rom_wr_en   <= '0;
            @(posedge clk);
        end
        for (int i = 0; i < 2560; i++) begin
            rom_wr_addr <= 16'(i);
            rom_wr_data <= prom[i];
            rom_wr_en   <= 16'h0020;          // section 5, the PROMs
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
    //   - truth: the main and the sound RAM of jt1942 itself, read hierarchically at the end
    //     of the harvest, equal the snapshot's first 6 KiB byte for byte
    // The other three RAMs are organised differently inside the core and are covered by the
    // oracle only. Also counted: the most log entries in one window (the platform has 512).
    logic        snap_run = 1'b0, snap_push, snap_harv, log_we;
    logic [7:0]  snap_byte, log_data;
    logic [15:0] snap_frame, log_addr;
    logic [7:0]  ref_ram [0:6143];          // truth at the end of the last harvest
    logic [7:0]  got     [0:9343];          // the delivered snapshot
    logic [7:0]  lg_val  [0:9343];          // last logged value per address in the window
    logic        lg_set  [0:9343];
    int          lg_n = 0, lg_max = 0, snaps = 0, mir_bad = 0, ora_bad = 0, got_n = 0;
    logic        harv_q = 1'b0;
    always @(posedge clk) begin
        harv_q <= snap_harv;
        if (snap_harv && !harv_q) begin                   // window opens
            lg_n = 0;
            for (int i = 0; i < 9344; i++) lg_set[i] = 1'b0;
        end
        if (snap_harv && log_we) begin
            lg_n = lg_n + 1;
            lg_val[log_addr] = log_data;
            lg_set[log_addr] = 1'b1;
        end
        if (!snap_harv && harv_q) begin                   // window closed: the truth now
            if (lg_n > lg_max) lg_max = lg_n;
            for (int i = 0; i < 4096; i++) ref_ram[i]        = dut.u_game.u_main.RAM.mem[i];
            for (int i = 0; i < 2048; i++) ref_ram[4096 + i] = dut.u_game.u_sound.u_cpu.u_sysz80_nvram.u_ram.u_dual.u_ram.mem[i];
        end
        if (snap_run && snap_push) begin                  // snap_full is 0: every push counts
            if (got_n < 9344) got[got_n] = snap_byte;
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
            repeat (9344 + 50) @(posedge clk);
            snap_run <= 1'b0;
            snaps++;
            if (got_n != 9344) begin
                mir_bad++;
                $display("mirror: snapshot %0d has %0d bytes, expected 9344", snaps, got_n);
            end
            for (int i = 0; i < 6144; i++)
                if (got[i] !== ref_ram[i]) begin
                    if (mir_bad < 8) $display("mirror: snapshot %0d byte %04x is %02x, the core holds %02x", snaps, i, got[i], ref_ram[i]);
                    mir_bad++;
                end
            for (int i = 0; i < 9344; i++)
                if (lg_set[i] && got[i] !== lg_val[i]) begin
                    if (ora_bad < 8) $display("oracle: snapshot %0d byte %04x is %02x, last logged %02x", snaps, i, got[i], lg_val[i]);
                    ora_bad++;
                end
        end
    end

    // ---------------- read latency of the ROM port, as the game sees it ----------------
    // clocks from a new rom_rd_req toggle to its rom_rd_ack, mean and maximum, and how many
    // reads took more than 19 clocks (the upper end of the port model)
    int lat_t = 0, lat_n = 0, lat_max = 0, lat_over = 0;
    longint lat_sum = 0;
    logic lat_on = 1'b0;
    always @(posedge clk) begin
        if (lat_on) lat_t++;
        if (!lat_on && rom_rd_req != rom_rd_ack) begin lat_on = 1'b1; lat_t = 1; end
        else if (lat_on && rom_rd_req == rom_rd_ack) begin
            lat_on = 1'b0; lat_n++; lat_sum += lat_t;
            if (lat_t > lat_max) lat_max = lat_t;
            if (lat_t > 19) lat_over++;
        end
    end

    // ---------------- late ROM data, counted in the visible picture only ----------------
    // char: jtframe_tilemap takes rom_data at pxl_cen && zero and draws zeros if rom_ok is
    // low then. scroll: jtgng_tile3 takes the data only while HS[2:0] > 2 and rom_ok and draws
    // it at HS[2:0] == 2, a window without ok draws the previous tile's pattern. sprites: the
    // object engine must reach 'over' within the line, else the last objects are missing.
    // Fetches in the blanking are not counted, nothing of them is shown.
    int char_late = 0, scr_late = 0, obj_lines = 0, obj_short = 0;
    logic scr_seen = 1'b0, lhbl_q = 1'b0;
    wire  visible = dut.u_game.LVBL && dut.u_game.LHBL;
    always @(posedge clk) begin
        if (dut.u_game.u_video.u_char.pxl_cen && dut.u_game.u_video.u_char.zero &&
            dut.u_game.u_video.u_char.rom_cs && !dut.u_game.u_video.char_ok && visible)
            char_late <= char_late + 1;
        if (dut.u_game.u_video.u_scroll.genblk1.u_tile3.HS[2:0] > 3'd2 && dut.u_game.u_video.scr_ok)
            scr_seen <= 1'b1;
        if (dut.u_game.u_video.u_scroll.genblk1.u_tile3.pxl_cen &&
            dut.u_game.u_video.u_scroll.genblk1.u_tile3.HS[2:0] == 3'd2) begin
            scr_seen <= 1'b0;
            if (!scr_seen && visible) scr_late <= scr_late + 1;
        end
        lhbl_q <= dut.u_game.u_video.u_obj.u_timing.LHBL;
        if (dut.u_game.u_video.u_obj.u_timing.LHBL && !lhbl_q && dut.u_game.LVBL) begin
            obj_lines <= obj_lines + 1;
            if (!dut.u_game.u_video.u_obj.u_timing.over) obj_short <= obj_short + 1;
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
            if (x < 256 && y >= 0 && y < 224) frame[y][x] <= {r, g, b};
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
                $display("ROM port: %0d reads, latency mean %0.1f, max %0d clocks, %0d over 19",
                         lat_n, real'(lat_sum) / lat_n, lat_max, lat_over);
                $display("mirror: %0d snapshots, %0d bytes differ from the core, %0d against the oracle; most log entries in a window %0d",
                         snaps, mir_bad, ora_bad, lg_max);
                if (char_late + scr_late + obj_short != 0) $fatal(1, "FAIL: ROM data late in the picture");
                if (snaps == 0 || mir_bad != 0 || ora_bad != 0 || lg_max >= 512) $fatal(1, "FAIL: RAM mirror");
                $display("PASS");
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
        $display("frame %0d written, %0d ROM reads so far", n, reads);
    endtask

    // a coin and a start later on, to see the game itself
    initial begin
        #(64'd420_000_000);                   // 420 ms after time 0, after the loading
        coin <= 1'b1; #(64'd50_000_000); coin <= 1'b0;
        #(64'd500_000_000);
        start1 <= 1'b1; #(64'd50_000_000); start1 <= 1'b0;
    end
endmodule
