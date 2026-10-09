// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
// Testbench for audio_cdc.sv: the audio word from clk_core through the HDMI module into its
// audio sample packets, wired as in game20k_top.sv, next to the former path (two registers
// per bit into clk_pixel, taken as it is at the rising edge of clk_audio). The core side
// sends n * 0x9E37 (mod 2^16) in core clock n, a new word every clock, so every word in a
// packet names the core clock it came from, and a torn word names a wrong one. Between two
// packet samples n must advance by the core clocks of one audio period, give or take 3,
// and after a bad sample by as many periods as samples went by.
// RTL simulation shows no metastability, but it shows routing skew: with +skew=1 every bit
// that crosses gets a delay of its own (0.4 to 3 ns) and clk_audio reaches its registers
// 1.6 ns after its pixel clock edge. Further it measures how long each word stands still
// before and after the edge that takes it.
// Plusargs: +core_ns= core clock period, +phase_ns= offset of the first core edge, +ppm=
// detuning of the core clock (sweeps the phase), +skew=0|1, +samples= packet samples.
// Prints one line per run. Ends with $fatal when the new path loses, repeats or tears a word.
`timescale 1ns/1ps
`default_nettype none

// Stands in for hdmi/audio_clock_regeneration_packet.sv: its real-valued localparams are
// beyond Verilator 5.052. It carries no audio words, it only claims a packet slot now and
// then: once per 48 audio clocks, as the real one does (N / 128 at 48 kHz).
module audio_clock_regeneration_packet #(parameter real VIDEO_RATE = 0, parameter int AUDIO_RATE = 0) (
    input  wire         clk_pixel,
    input  wire         clk_audio,
    output logic        clk_audio_counter_wrap = 0,
    output logic [23:0] header,
    output logic [55:0] sub [3:0]
);
    logic [6:0] cnt = 0;
    logic       wrap = 0;
    logic [1:0] wrap_s = 0;
    always @(posedge clk_audio) begin
        cnt <= cnt + 7'd1;
        if (cnt == 7'd47) begin cnt <= 7'd0; wrap <= ~wrap; end
    end
    always @(posedge clk_pixel) begin
        wrap_s <= {wrap_s[0], wrap};
        if (wrap_s[1] ^ wrap_s[0]) clk_audio_counter_wrap <= ~clk_audio_counter_wrap;
    end
    assign header = 24'h000001;
    assign sub[0] = 56'd0; assign sub[1] = 56'd0; assign sub[2] = 56'd0; assign sub[3] = 56'd0;
endmodule

module tb_audio_cdc;
    real core_ns = 53.872, phase_ns = 0.0, ppm = 0.0;
    real step;   // core clocks per audio period
    real t_next;
    int  skew = 1, samples = 1000;
    logic clk_pixel = 0, clk_core = 0;
    always #6.734 clk_pixel = ~clk_pixel;
    initial begin
        void'($value$plusargs("core_ns=%f", core_ns));
        void'($value$plusargs("phase_ns=%f", phase_ns));
        void'($value$plusargs("ppm=%f", ppm));
        void'($value$plusargs("skew=%d", skew));
        void'($value$plusargs("samples=%d", samples));
        step = 1546.0 * 13.468 / (core_ns * (1.0 + ppm * 1e-6));
        // edges from the ideal time, so the 1 ps rounding of each delay does not swallow ppm
        t_next = phase_ns;
        #(phase_ns);
        forever begin
            clk_core = ~clk_core;
            t_next   = t_next + core_ns * (1.0 + ppm * 1e-6) / 2.0;
            #(t_next - $realtime);
        end
    end

    // ---- the core side: word n * 0x9E37 in core clock n ----
    logic [15:0] n = 0, aud_g;
    always @(posedge clk_core) n <= n + 16'd1;
    assign aud_g = 16'(n * 16'h9E37);

    // ---- clk_audio as in the top ----
    logic [9:0] aud_div = 0;
    logic       clk_audio = 0;
    always @(posedge clk_pixel) begin
        if (aud_div == 10'd772) begin
            aud_div   <= 10'd0;
            clk_audio <= ~clk_audio;
        end else
            aud_div <= aud_div + 10'd1;
    end

    // ---- routing skew: a delay per crossing bit, clk_audio late at its registers ----
    function automatic real dly(input int i, input int k);
        return skew != 0 ? 0.4 + real'((i * k) % 16) * 0.17 : 0.0;
    endfunction
    logic [15:0] aud_g_d, p1_d, w_d;
    logic        clk_audio_d = 0;
    always @(clk_audio) clk_audio_d <= #(skew != 0 ? 1.6 : 0.0) clk_audio;

    // ---- the former path ----
    logic [15:0] aud_p0 = 0, aud_p1 = 0;
    always @(posedge clk_pixel) begin
        aud_p0 <= aud_g_d;
        aud_p1 <= aud_p0;
    end

    // ---- the new path ----
    logic        aud_req;
    logic [15:0] aud_w;
    assign aud_req = (aud_div == 10'd772) && clk_audio;
    audio_cdc dut (.clk_core(clk_core), .din(aud_g), .clk_pixel(clk_pixel), .req(aud_req),
                   .dout(aud_w));

    for (genvar i = 0; i < 16; i++) begin : g_skew
        always @(aud_g[i])  aud_g_d[i] <= #(dly(i, 7)) aud_g[i];
        always @(aud_p1[i]) p1_d[i]    <= #(dly(i, 5)) aud_p1[i];
        always @(aud_w[i])  w_d[i]     <= #(dly(i, 5)) aud_w[i];
    end

    // ---- two HDMI modules as in the top, the old and the new word ----
    logic [15:0] word_old [1:0], word_new [1:0];
    assign word_old[0] = p1_d; assign word_old[1] = p1_d;
    assign word_new[0] = w_d;  assign word_new[1] = w_d;
    hdmi #(.VIDEO_ID_CODE(4), .DVI_OUTPUT(0), .VIDEO_REFRESH_RATE(60), .IT_CONTENT(1),
           .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16), .FRAME_W(1584), .FRAME_H(786)) hdmi_old (
        .clk_pixel_x5(1'b0), .clk_pixel(clk_pixel), .clk_audio(clk_audio_d), .reset(1'b0),
        .sync(1'b0), .rgb(24'h000000), .audio_sample_word(word_old), .tmds(), .tmds_clock(),
        .cx(), .cy(), .frame_width(), .frame_height(), .screen_width(), .screen_height());
    hdmi #(.VIDEO_ID_CODE(4), .DVI_OUTPUT(0), .VIDEO_REFRESH_RATE(60), .IT_CONTENT(1),
           .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16), .FRAME_W(1584), .FRAME_H(786)) hdmi_new (
        .clk_pixel_x5(1'b0), .clk_pixel(clk_pixel), .clk_audio(clk_audio_d), .reset(1'b0),
        .sync(1'b0), .rgb(24'h000000), .audio_sample_word(word_new), .tmds(), .tmds_clock(),
        .cx(), .cy(), .frame_width(), .frame_height(), .screen_width(), .screen_height());

    // ---- checks: the samples of every audio sample packet, in order ----
    int  edges = 0;
    always @(posedge clk_audio_d) edges <= edges + 1;

    // Per path (0 old, 1 new): samples, bad ones, n of the last good one and the samples
    // since. A sample is good when n advanced by as many audio periods as samples went by.
    int          got [2] = '{0, 0}, bad [2] = '{0, 0}, gap [2] = '{0, 0};
    logic [15:0] good_n [2];
    task automatic take(input int p, input logic [15:0] v);
        logic [15:0] k, d;
        k = 16'(v * 16'h7787);   // 0x7787 * 0x9E37 = 1 (mod 2^16)
        d = k - good_n[p];
        gap[p]++;
        // the first 8 samples include the zeros of the start
        if (got[p] < 8 || (real'(d) >= gap[p] * step - 3.0 * gap[p] && real'(d) <= gap[p] * step + 3.0 * gap[p])) begin
            good_n[p] = k;
            gap[p]    = 0;
        end else begin
            if (p == 1 && bad[p] == 0)
                $display("new: sample %0d is %04h, n advanced by %0d in %0d periods of %.1f", got[p], v, d, gap[p], step);
            bad[p]++;
        end
        got[p]++;
    endtask

    always @(posedge clk_pixel) begin
        if (hdmi_old.true_hdmi_output.packet_picker.sample_buffer_used)
            for (int s = 0; s < 4; s++)
                take(0, hdmi_old.true_hdmi_output.packet_picker.audio_sample_word_packet[s][0][23:8]);
        if (hdmi_new.true_hdmi_output.packet_picker.sample_buffer_used)
            for (int s = 0; s < 4; s++)
                take(1, hdmi_new.true_hdmi_output.packet_picker.audio_sample_word_packet[s][0][23:8]);
    end

    // ---- margins: how long a word stands still around the edge that takes it ----
    real t_hold = -1e9, t_w = -1e9, t_p1 = -1e9, t_rise = -1e9;
    real m_hold = 1e9;              // new: hold unchanged before dout takes it
    real m_w = 1e9, m_p1 = 1e9;     // word unchanged around a rising edge of clk_audio
    int  n_hold = 0;                // changes of hold, a check that the event fires
    always @(dut.hold) begin t_hold = $realtime; n_hold++; end
    always @(w_d)      begin t_w  = $realtime; if ($realtime - t_rise < m_w)  m_w  = $realtime - t_rise; end
    always @(p1_d)     begin t_p1 = $realtime; if ($realtime - t_rise < m_p1) m_p1 = $realtime - t_rise; end
    always @(posedge clk_audio_d) begin
        t_rise = $realtime;
        if ($realtime - t_w  < m_w)  m_w  = $realtime - t_w;
        if ($realtime - t_p1 < m_p1) m_p1 = $realtime - t_p1;
    end
    always @(posedge clk_pixel)
        if ((dut.ack_s[1] ^ dut.ack_s[2]) && $realtime - t_hold < m_hold) m_hold = $realtime - t_hold;

    initial begin
        wait (got[1] >= samples && got[0] >= samples);
        $display("core %.4f ns phase %5.2f ns %3.0f ppm skew %0d | old %0d samples %0d bad, still %.2f ns | new %0d samples %0d bad, still %.0f ns, hold %.1f ns (%0d changes), %0d edges",
                 core_ns, phase_ns, ppm, skew, got[0], bad[0], m_p1, got[1], bad[1], m_w, m_hold, n_hold, edges);
        if (bad[1] != 0) $fatal(1, "new path: a word arrived torn or out of order");
        // packets carry 4 samples, at most one packet lags behind the edges
        if (edges - got[1] > 8 || edges < got[1]) $fatal(1, "new path: %0d samples for %0d edges", got[1], edges);
        $finish;
    end
endmodule

`default_nettype wire
