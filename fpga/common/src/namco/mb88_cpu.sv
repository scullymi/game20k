// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent one-bit net.
//! @file mb88_cpu.sv
//! @brief Fujitsu MB88xx 4-bit microcontroller as the Namco 51XX, 53XX and 54XX customs use it.
//!
//! Written for game20k after the behaviour of MAME's mb88xx.cpp (0.289, Ernesto Corvi,
//! BSD-3-Clause). No code is taken from other cores.
//!
//! Timing: one machine cycle per ena (1/6 of the MCU clock, 256 kHz on the Namco boards).
//! Instructions take one cycle, the two-byte ones (jpa, en, dis, call, jpl) two. An interrupt
//! entry follows the instruction during which it was accepted and takes three more cycles.
//! The ROM is read one cycle ahead: rom_data must show the byte at rom_addr by the next ena.
//!
//! Interrupts as in MAME: the external request latches on a falling /IRQ edge while PIO bit 2
//! is set, the timer request on a timer overflow. A request waits until PIO enables it and no
//! interrupt is in service, then the entry pushes PC with CF, ZF and ST, sets ST and clears
//! every request. Vectors: external $002, timer $004. RTI ends the service.
//!
//! Timer: TL and TH count rising /TC edges while PIO bit 6 is set. An overflow sets VF and
//! requests the timer interrupt. An edge counts at the next ena, after the instruction of
//! that cycle, and only if bit 6 is set after that instruction: MAME takes the edge between
//! two instructions, so an en or dis in that instruction already applies.
//!
//! Not built: the internal timer clock (PIO bit 7), the serial port (PIO bits 4 and 5, SB is
//! a plain register), standby. The 51XX enables the serial port but never reads SB or the
//! serial flag, the 53XX and 54XX leave it off.
module mb88_cpu #(
    parameter int RAM_AW = 6    //!< data RAM address bits, 6 for the MB8843/MB8844 (64 nibbles)
)(
    input  wire         clk,
    input  wire         reset_n,    //!< synchronous, holds the MCU in reset while low
    input  wire         ena,        //!< one machine cycle
    output logic [10:0] rom_addr,   //!< {PA, PC}
    input  wire  [7:0]  rom_data,   //!< the byte at rom_addr, valid by the next ena
    input  wire  [3:0]  k_in,
    input  wire  [15:0] r_in,       //!< R3..R0 as the program reads them
    output logic [15:0] r_out,      //!< R3..R0 as the program last wrote them
    output logic [3:0]  r_we,       //!< one clock per write to R0..R3
    output logic [7:0]  o_out,      //!< port O, outO writes the half that CF selects
    output logic        o_we,       //!< one clock per outO, o_out holds the new value
    output logic [3:0]  p_out,
    output logic        p_we,       //!< one clock per outP
    input  wire         irq_n,      //!< /IRQ pin
    input  wire         tc_n        //!< /TC pin
);
    // ---- state ----
    logic [5:0]  pc = '0;
    logic [4:0]  pa = '0;
    logic [1:0]  si = '0;
    logic [3:0]  a = '0, x = '0, y = '0;
    logic        st = 1'b1, zf = 1'b0, cf = 1'b0, vf = 1'b0, sf = 1'b0;
    logic [7:0]  pio = '0;
    logic [3:0]  th = '0, tl = '0, sb = '0;
    logic [13:0] stack [4];                 // {CF, ZF, ST, PA, PC}
    logic [3:0]  ram [2**RAM_AW];
    logic        ph2 = 1'b0;                // the second byte of op1 is on rom_data
    logic [7:0]  op1 = '0;
    logic [1:0]  ent = '0;                  // interrupt entry cycles left
    logic [1:0]  vec = '0;                  // entry vector / 2
    logic        in_irq = 1'b0;
    logic [2:0]  pend = '0, pend_s = '0;    // requests: 2 external, 1 timer, 0 serial
    logic        irq_d = 1'b1, tc_d = 1'b0;
    logic        tick = 1'b0;               // a /TC edge waiting for the next ena

    logic [15:0] r_q = '0;                  // port registers behind r_out, o_out, p_out
    logic [7:0]  o_q = '0;
    logic [3:0]  p_q = '0;

    initial begin
        for (int i = 0; i < 4; i++) stack[i] = '0;
        for (int i = 0; i < 2**RAM_AW; i++) ram[i] = '0;
    end

    assign rom_addr = {pa, pc};
    assign r_out    = r_q;
    assign o_out    = o_q;
    assign p_out    = p_q;

    wire [7:0]  ea   = {x, y};
    wire [3:0]  m    = ram[ea[RAM_AW-1:0]];
    wire [7:0]  op   = ph2 ? op1 : rom_data;
    wire [7:0]  arg  = rom_data;
    wire [10:0] pc1  = {pa, pc} + 11'd1;     // PC past the byte on rom_data, carry into PA
    wire [3:0]  bit1 = 4'b0001 << op[1:0];   // bit operand of sbit, rbit, tbit, setD, ...
    wire [3:0]  ybit = 4'b0001 << y[1:0];    // bit operand of setR, rstR, tstr
    wire [3:0]  r_y  = r_in[4*y[3:2] +: 4];  // port R(Y >> 2)

    function automatic logic two_byte(input logic [7:0] o);
        return o == 8'h3D || o == 8'h3E || o == 8'h3F || o[7:4] == 4'h6;
    endfunction

    // ---- one cycle: the next state ----
    logic [5:0]  n_pc;
    logic [4:0]  n_pa;
    logic [1:0]  n_si;
    logic [3:0]  n_a, n_x, n_y, n_th, n_tl, n_sb;
    logic        n_st, n_zf, n_cf, n_vf, n_sf, n_in_irq;
    logic [7:0]  n_pio;
    logic        fin;                       // an instruction ends in this cycle
    logic        push;
    logic        ram_we;
    logic [7:0]  ram_wa;
    logic [3:0]  ram_wd;
    logic        do_o, do_p;
    logic [3:0]  do_r;
    logic [3:0]  r_val [4];
    logic [4:0]  t5;

    always_comb begin
        {n_pa, n_pc} = pc1;
        n_si = si; n_a = a; n_x = x; n_y = y; n_th = th; n_tl = tl; n_sb = sb;
        n_st = st; n_zf = zf; n_cf = cf; n_vf = vf; n_sf = sf; n_in_irq = in_irq; n_pio = pio;
        fin = 1'b0; push = 1'b0;
        ram_we = 1'b0; ram_wa = ea; ram_wd = a;
        do_o = 1'b0; do_p = 1'b0; do_r = '0;
        for (int i = 0; i < 4; i++) r_val[i] = r_q[4*i +: 4];
        t5 = '0;

        if (!ph2 && two_byte(rom_data)) begin
            // first byte of a two-byte instruction: only fetch
        end else begin
            fin = 1'b1;
            n_st = 1'b1;                    // most instructions set ST, the rest below
            case (op) inside
                8'h00: ;                                                    // nop
                8'h01: do_o = 1'b1;                                         // outO
                8'h02: do_p = 1'b1;                                         // outP
                8'h03: begin do_r[y[1:0]] = 1'b1; r_val[y[1:0]] = a; end    // outR
                8'h04: n_y = a;                                             // tay
                8'h05: n_th = a;                                            // tath
                8'h06: n_tl = a;                                            // tatl
                8'h07: n_sb = a;                                            // tas
                8'h08, 8'h0A: begin                                         // icy, stic
                    t5 = {1'b0, y} + 5'd1;
                    n_y = t5[3:0]; n_st = !t5[4]; n_zf = t5[3:0] == 0;
                    if (op[1]) ram_we = 1'b1;
                end
                8'h09: begin                                                // icm
                    t5 = {1'b0, m} + 5'd1;
                    ram_we = 1'b1; ram_wd = t5[3:0]; n_st = !t5[4]; n_zf = t5[3:0] == 0;
                end
                8'h0B: begin ram_we = 1'b1; n_a = m; n_zf = m == 0; end    // x
                8'h0C: begin                                                // rol
                    t5 = {a, cf};
                    n_a = t5[3:0]; n_cf = t5[4]; n_st = !t5[4]; n_zf = t5[3:0] == 0;
                end
                8'h0D: begin n_a = m; n_zf = m == 0; end                    // l
                8'h0E, 8'h1E: begin                                         // adc, sbc
                    t5 = op[4] ? {1'b0, m} - {1'b0, a} - {4'd0, cf} : {1'b0, m} + {1'b0, a} + {4'd0, cf};
                    n_a = t5[3:0]; n_cf = t5[4]; n_st = !t5[4]; n_zf = t5[3:0] == 0;
                end
                8'h0F, 8'h1F: begin                                         // and, or
                    n_a = op[4] ? a | m : a & m;
                    n_zf = n_a == 0; n_st = n_a != 0;
                end
                8'h10, 8'h11: begin                                         // daa, das
                    t5 = {1'b0, a} + ((cf || a > 4'd9) ? (op[0] ? 5'd10 : 5'd6) : 5'd0);
                    n_a = t5[3:0]; n_cf = t5[4]; n_st = !t5[4];
                end
                8'h12: begin n_a = k_in; n_zf = k_in == 0; end              // inK
                8'h13: begin n_a = r_in[4*y[1:0] +: 4]; n_zf = n_a == 0; end // inR
                8'h14: begin n_a = y;  n_zf = y == 0;  end                  // tya
                8'h15: begin n_a = th; n_zf = th == 0; end                  // ttha
                8'h16: begin n_a = tl; n_zf = tl == 0; end                  // ttla
                8'h17: begin n_a = sb; n_zf = sb == 0; end                  // tsa
                8'h18, 8'h1A: begin                                         // dcy, stdc
                    n_y = y - 4'd1; n_st = y != 0;
                    if (op[1]) begin ram_we = 1'b1; n_zf = n_y == 0; end
                end
                8'h19: begin                                                // dcm
                    ram_we = 1'b1; ram_wd = m - 4'd1; n_st = m != 0; n_zf = m == 4'd1;
                end
                8'h1B: begin n_x = a; n_a = x; n_zf = x == 0; end          // xx
                8'h1C: begin                                                // ror
                    n_a = {cf, a[3:1]}; n_cf = a[0]; n_st = !a[0]; n_zf = n_a == 0;
                end
                8'h1D: ram_we = 1'b1;                                       // st
                8'h20, 8'h22: begin                                         // setR, rstR
                    do_r[y[3:2]] = 1'b1;
                    r_val[y[3:2]] = op[1] ? r_y & ~ybit : r_y | ybit;
                end
                8'h21: n_cf = 1'b1;                                         // setc
                8'h23: n_cf = 1'b0;                                         // rstc
                8'h24: n_st = (r_y & ybit) == 0;                            // tstr
                8'h25: n_st = irq_n;                                        // tsti: ST = not IF
                8'h26: begin n_st = !vf; n_vf = 1'b0; end                   // tstv
                8'h27: begin n_st = !sf; n_sf = 1'b0; end                   // tsts
                8'h28: n_st = !cf;                                          // tstc
                8'h29: n_st = !zf;                                          // tstz
                8'h2A: begin ram_we = 1'b1; ram_wd = sb; n_zf = sb == 0; end // sts
                8'h2B: begin n_sb = m; n_zf = m == 0; end                   // ls
                8'h2C: begin                                                // rts
                    n_si = si - 2'd1;
                    {n_pa, n_pc} = stack[si - 2'd1][10:0];
                end
                8'h2D: begin n_a = 4'd0 - a; n_st = a != 0; end             // neg
                8'h2E, [8'hA0:8'hBF]: begin                                 // c, cyi, ci
                    t5 = op == 8'h2E ? {1'b0, m} - {1'b0, a}
                                     : {1'b0, op[3:0]} - {1'b0, op[4] ? a : y};
                    n_cf = t5[4]; n_st = t5[3:0] != 0; n_zf = t5[3:0] == 0;
                end
                8'h2F: begin n_a = a ^ m; n_st = n_a != 0; n_zf = n_a == 0; end // eor
                [8'h30:8'h37]: begin                                        // sbit, rbit
                    ram_we = 1'b1; ram_wd = op[2] ? m & ~bit1 : m | bit1;
                end
                [8'h38:8'h3B]: n_st = (m & bit1) == 0;                      // tbit
                8'h3C: begin                                                // rti
                    n_si = si - 2'd1; n_in_irq = 1'b0;
                    {n_cf, n_zf, n_st, n_pa, n_pc} = stack[si - 2'd1];
                end
                8'h3D: begin n_pa = arg[4:0]; n_pc = {a, 2'b00}; end        // jpa
                8'h3E: n_pio = pio | arg;                                   // en
                8'h3F: n_pio = pio & ~arg;                                  // dis
                [8'h40:8'h47]: begin                                        // setD, rstD
                    do_r[0] = 1'b1;
                    r_val[0] = op[2] ? r_in[3:0] & ~bit1 : r_in[3:0] | bit1;
                end
                [8'h48:8'h4B]: n_st = (r_in[11:8] & bit1) == 0;             // tstD
                [8'h4C:8'h4F]: n_st = (a & bit1) == 0;                      // tba
                [8'h50:8'h53]: begin                                        // xd
                    ram_we = 1'b1; ram_wa = {6'd0, op[1:0]}; n_a = ram[RAM_AW'(op[1:0])];
                    n_zf = n_a == 0;
                end
                [8'h54:8'h57]: begin                                        // xyd
                    ram_we = 1'b1; ram_wa = {6'd1, op[1:0]}; ram_wd = y;
                    n_y = ram[RAM_AW'({1'b1, op[1:0]})]; n_zf = n_y == 0;
                end
                [8'h58:8'h5F]: begin n_x = {1'b0, op[2:0]}; n_zf = op[2:0] == 0; end // lxi
                [8'h60:8'h6F]: if (st) begin                                // call, jpl
                    push = !op[3];
                    n_pc = arg[5:0];
                    n_pa = {op[2:0], arg[7:6]};
                end
                [8'h70:8'h7F]: begin                                        // ai
                    t5 = {1'b0, a} + {1'b0, op[3:0]};
                    n_a = t5[3:0]; n_cf = t5[4]; n_st = !t5[4]; n_zf = t5[3:0] == 0;
                end
                [8'h80:8'h8F]: begin n_y = op[3:0]; n_zf = op[3:0] == 0; end // lyi
                [8'h90:8'h9F]: begin n_a = op[3:0]; n_zf = op[3:0] == 0; end // li
                default: if (st) n_pc = op[5:0];                            // jmp, PA as fetched
            endcase
        end
    end

    // ---- interrupt acceptance at the end of an instruction ----
    // Requests count from the start of the instruction (pend_s for two-byte ones): MAME
    // takes inputs between instructions and enters after the next one.
    wire [2:0] pend_chk = ph2 ? pend_s : pend;
    wire [2:0] take_v   = pend_chk & n_pio[2:0];
    wire       take     = fin && !n_in_irq && take_v != 0;
    wire [1:0] take_vec = take_v[2] ? 2'd1 : take_v[1] ? 2'd2 : 2'd3;

    // ---- timer step of this cycle: a waiting /TC edge, PIO bit 6 as it is after the cycle ----
    wire       t_on     = ent != 0 ? pio[6] : n_pio[6];
    wire       step     = ena && tick && t_on;
    wire [7:0] t_base   = ent != 0 ? {th, tl} : {n_th, n_tl};
    wire       ovf      = step && t_base == 8'hFF;

    wire ext_ev = irq_d && !irq_n && pio[2];
    wire tc_ev  = !tc_d && tc_n;

    // the stack and the data RAM, one write port each. The stack keeps its contents over a
    // reset (MAME clears it), the programs never pop before they push.
    wire        run    = reset_n && ena;
    wire        stk_we = run && (ent == 2'd3 || (ent == 0 && push));
    wire [13:0] stk_wd = ent != 0 ? {cf, zf, st, pa, pc} : {3'b000, pc1};
    always_ff @(posedge clk) begin
        if (stk_we) stack[si] <= stk_wd;
        if (run && ent == 0 && ram_we) ram[ram_wa[RAM_AW-1:0]] <= ram_wd;
    end

    always_ff @(posedge clk) begin
        irq_d <= irq_n;
        tc_d  <= tc_n;
        o_we  <= 1'b0;
        p_we  <= 1'b0;
        r_we  <= '0;
        if (!reset_n) begin
            pc <= '0; pa <= '0; si <= '0; a <= '0; x <= '0; y <= '0;
            st <= 1'b1; zf <= 1'b0; cf <= 1'b0; vf <= 1'b0; sf <= 1'b0;
            pio <= '0; th <= '0; tl <= '0; sb <= '0;
            ph2 <= 1'b0; ent <= '0; in_irq <= 1'b0; pend <= '0; pend_s <= '0; tick <= 1'b0;
        end else begin
            if (ena) begin
                if (ent != 0) begin
                    // interrupt entry, the push in its first cycle
                    if (ent == 2'd3) begin
                        si <= si + 2'd1;
                        pa <= '0;
                        pc <= {3'd0, vec, 1'b0};
                        st <= 1'b1;
                    end
                    ent <= ent - 2'd1;
                end else begin
                    pc <= n_pc; pa <= n_pa; si <= n_si;
                    a <= n_a; x <= n_x; y <= n_y; sb <= n_sb;
                    st <= n_st; zf <= n_zf; cf <= n_cf; vf <= n_vf; sf <= n_sf;
                    pio <= n_pio; in_irq <= n_in_irq;
                    th <= n_th; tl <= n_tl;
                    ph2 <= !fin;
                    if (!fin) begin
                        op1    <= rom_data;
                        pend_s <= pend;
                    end
                    if (push) si <= si + 2'd1;
                    if (do_o) begin
                        if (cf) o_q[7:4] <= a; else o_q[3:0] <= a;
                        o_we <= 1'b1;
                    end
                    if (do_p) begin p_q <= a; p_we <= 1'b1; end
                    for (int i = 0; i < 4; i++)
                        if (do_r[i]) r_q[4*i +: 4] <= r_val[i];
                    r_we <= do_r;
                    if (take) begin
                        ent    <= 2'd3;
                        vec    <= take_vec;
                        in_irq <= 1'b1;
                    end
                end
                // the timer, after the instruction of this cycle
                if (step) begin
                    {th, tl} <= t_base + 8'd1;
                    if (ovf) vf <= 1'b1;
                end
            end
            // requests: an accepted entry clears all, new ones from this clock stay
            if (ena && ent == 0 && take) pend <= {ext_ev, 2'b00};
            else pend <= pend | {ext_ev, ovf, 1'b0};
            if (ena && ent == 0 && take && ovf) pend[1] <= 1'b1;
            if (tc_ev) tick <= 1'b1;
            else if (ena) tick <= 1'b0;
        end
    end
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
