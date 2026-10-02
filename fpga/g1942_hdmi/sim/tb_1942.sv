// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// game20k, 1942: simulation of game_core (jotego's jt1942 behind our wrapper) with its ROM.
// Two ways to serve the five ROM buses, chosen at build time:
//   default   a model of rom_sdram's read port that answers after LAT_MIN..LAT_MAX core
//             clocks, the range worked out for the SDRAM path (about 270 ns typical, 510 ns
//             with a refresh in the way)
//   ROM_PATH  the real path: rom_sdram.sv, sdram_fb.v at 64.8 MHz unrelated to the core
//             clock, and an SDR SDRAM model; the image is first written through rom_sdram's
//             write side, as rom_loader does on the device
// The PROMs come over the loader's write port while the core is in reset. A coin and a start
// follow, so the frames show the game itself. Every FRAME_EVERY-th frame is written as
// frames/fNNNN.ppm, the raw raster (256 x 224, the game turned on its side). Run by
// run_sim.sh, which reads the ROM image from rom32.hex and proms.hex in its work folder.
`timescale 1ns/1ps
module tb_1942;
    parameter int LAT_MIN     = 9;
    parameter int LAT_MAX     = 19;
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
        .snap_run(1'b0), .snap_full(1'b0), .snap_push(), .snap_byte(), .snap_frame(), .snap_harv(),
        .log_we(), .log_addr(), .log_data(),
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
            wait_cnt <= LAT_MIN + ($urandom % (LAT_MAX - LAT_MIN + 1));
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
            while (!wr_ready) @(posedge clk);
            wr_we <= 1'b1; wr_off <= 22'(o); wr_byte <= rom[o >> 2][8*(o & 3) +: 8];
            @(posedge clk);
            wr_we <= 1'b0;
            @(posedge clk);
        end
        while (!wr_idle) @(posedge clk);
        $display("image written at %0t", $time);
`endif
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
