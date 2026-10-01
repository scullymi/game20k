// Implementation of HDMI Spec v1.4a Section 5.4: Encoding, Section 5.2.2.1: Video Guard Band, Section 5.2.3.3: Data Island Guard Bands.
// By Sameer Puri https://github.com/sameer

module tmds_channel
#(
    // TMDS Channel number.
    // There are only 3 possible channel numbers in HDMI 1.4a: 0, 1, 2.
    parameter int CN = 0
)
(
    input logic clk_pixel,
    input logic [7:0] video_data,
    input logic [3:0] data_island_data,
    input logic [1:0] control_data,
    input logic [2:0] mode,  // Mode select (0 = control, 1 = video, 2 = video guard, 3 = island, 4 = island guard)
    output logic [9:0] tmds = 10'b1101010100
);

// See Section 5.4.4.1
// game20k: split into three pipeline stages so that the path holds 74.25 MHz on the GW2AR-18
// with margin. Stage 1: q_m (prefix XOR instead of a serial chain), stage 2: count the ones,
// stage 3: the disparity decision with acc. mode/control/data are delayed by 2 clocks alongside.

logic signed [4:0] acc = 5'sd0;

// ---- stage 1: q_m from video_data ----
logic [3:0] N1D;
logic [7:0] pfx;          // pfx[i] = ^video_data[i:0]
logic       use_xnor;
logic [8:0] q_m_c;
integer i;
always_comb
begin
    N1D = video_data[0] + video_data[1] + video_data[2] + video_data[3] + video_data[4] + video_data[5] + video_data[6] + video_data[7];
    use_xnor = (N1D > 4'd4) || (N1D == 4'd4 && video_data[0] == 1'b0);
    pfx[0] = video_data[0];
    for (i = 1; i < 8; i++)
        pfx[i] = pfx[i-1] ^ video_data[i];
    // XNOR chain = XOR chain with an inversion at the odd positions
    q_m_c[0] = video_data[0];
    for (i = 1; i < 8; i++)
        q_m_c[i] = pfx[i] ^ (use_xnor & i[0]);
    q_m_c[8] = ~use_xnor;
end

logic [8:0] q_m_s1 = 9'd0;
logic [2:0] mode_s1 = 3'd0;
logic [1:0] control_s1 = 2'd0;
logic [3:0] island_s1 = 4'd0;
always_ff @(posedge clk_pixel)
begin
    q_m_s1     <= q_m_c;
    mode_s1    <= mode;
    control_s1 <= control_data;
    island_s1  <= data_island_data;
end

// ---- stage 2: count the ones in q_m[7:0] ----
logic [8:0] q_m = 9'd0;
logic [3:0] n1_s2 = 4'd0;
logic [2:0] mode_d = 3'd0;
logic [1:0] control_d = 2'd0;
logic [3:0] island_d = 4'd0;
always_ff @(posedge clk_pixel)
begin
    q_m       <= q_m_s1;
    n1_s2     <= q_m_s1[0] + q_m_s1[1] + q_m_s1[2] + q_m_s1[3] + q_m_s1[4] + q_m_s1[5] + q_m_s1[6] + q_m_s1[7];
    mode_d    <= mode_s1;
    control_d <= control_s1;
    island_d  <= island_s1;
end

// ---- stage 3: disparity (Figure 5-7) ----
logic signed [4:0] N1q_m07;
logic signed [4:0] N0q_m07;
logic [9:0] q_out;
logic [9:0] video_coding;
assign video_coding = q_out;
logic signed [4:0] acc_add;

always_comb
begin
    N1q_m07 = {1'b0, n1_s2};
    N0q_m07 = 5'sd8 - N1q_m07;
    if (acc == 5'sd0 || (N1q_m07 == N0q_m07))
    begin
        if (q_m[8])
        begin
            acc_add = N1q_m07 - N0q_m07;
            q_out = {~q_m[8], q_m[8], q_m[7:0]};
        end
        else
        begin
            acc_add = N0q_m07 - N1q_m07;
            q_out = {~q_m[8], q_m[8], ~q_m[7:0]};
        end
    end
    else
    begin
        if ((acc > 5'sd0 && N1q_m07 > N0q_m07) || (acc < 5'sd0 && N1q_m07 < N0q_m07))
        begin
            q_out = {1'b1, q_m[8], ~q_m[7:0]};
            acc_add = (N0q_m07 - N1q_m07) + (q_m[8] ? 5'sd2 : 5'sd0);
        end
        else
        begin
            q_out = {1'b0, q_m[8], q_m[7:0]};
            acc_add = (N1q_m07 - N0q_m07) - (~q_m[8] ? 5'sd2 : 5'sd0);
        end
    end
end

always_ff @(posedge clk_pixel) acc <= mode_d != 3'd1 ? 5'sd0 : acc + acc_add;

// See Section 5.4.2
logic [9:0] control_coding;
always_comb
begin
    unique case(control_d)
        2'b00: control_coding = 10'b1101010100;
        2'b01: control_coding = 10'b0010101011;
        2'b10: control_coding = 10'b0101010100;
        2'b11: control_coding = 10'b1010101011;
    endcase
end

// See Section 5.4.3
logic [9:0] terc4_coding;
always_comb
begin
    unique case(island_d)
        4'b0000 : terc4_coding = 10'b1010011100;
        4'b0001 : terc4_coding = 10'b1001100011;
        4'b0010 : terc4_coding = 10'b1011100100;
        4'b0011 : terc4_coding = 10'b1011100010;
        4'b0100 : terc4_coding = 10'b0101110001;
        4'b0101 : terc4_coding = 10'b0100011110;
        4'b0110 : terc4_coding = 10'b0110001110;
        4'b0111 : terc4_coding = 10'b0100111100;
        4'b1000 : terc4_coding = 10'b1011001100;
        4'b1001 : terc4_coding = 10'b0100111001;
        4'b1010 : terc4_coding = 10'b0110011100;
        4'b1011 : terc4_coding = 10'b1011000110;
        4'b1100 : terc4_coding = 10'b1010001110;
        4'b1101 : terc4_coding = 10'b1001110001;
        4'b1110 : terc4_coding = 10'b0101100011;
        4'b1111 : terc4_coding = 10'b1011000011;
    endcase
end

// See Section 5.2.2.1
logic [9:0] video_guard_band;
generate
    if (CN == 0 || CN == 2)
        assign video_guard_band = 10'b1011001100;
    else
        assign video_guard_band = 10'b0100110011;
endgenerate

// See Section 5.2.3.3
logic [9:0] data_guard_band;
generate
    if (CN == 1 || CN == 2)
        assign data_guard_band = 10'b0100110011;
    else
        assign data_guard_band = control_d == 2'b00 ? 10'b1010001110
            : control_d == 2'b01 ? 10'b1001110001
            : control_d == 2'b10 ? 10'b0101100011
            : 10'b1011000011;
endgenerate

// Apply selected mode.
always @(posedge clk_pixel)
begin
    case (mode_d)
        3'd0: tmds <= control_coding;
        3'd1: tmds <= video_coding;
        3'd2: tmds <= video_guard_band;
        3'd3: tmds <= terc4_coding;
        3'd4: tmds <= data_guard_band;
    endcase
end

endmodule
