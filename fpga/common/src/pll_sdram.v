// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent 1-bit net.
//! -----------------------------------------------------------------------------------------
//! @file pll_sdram.v
//! @brief Clock for the SDRAM controller (game20k), with a run-time adjustable phase
//!
//! This file grew out of the output of the Gowin IP generator, but has since been rewritten
//! completely: own phase input, own parameters, own reasoning. What remains of it, the port
//! list and the defparam block, is the instantiation of a hardware primitive for which there
//! is only one way to write it. Details in the header of clkdiv5.v.
//! -----------------------------------------------------------------------------------------

//! The rPLL instantiation is the Gowin IP generator's output as NESTang's gowin_pll_nes.v
//! carries it, here with our own parameters. 64.8 MHz from the 27 MHz crystal: IDIV_SEL 4
//! divides by 5, FBDIV_SEL 11 multiplies by 12, so 27 / 5 * 12 = 64.8 MHz. clkoutp carries
//! the same clock phase-shifted and goes directly to the clock pin of the SDRAM.
//!
//! The phase is set to PSDA 11 (247.5 degrees), the middle of the window measured on the
//! device: PSDA 7 to 15 run error-free, 0 to 6 do not. NESTang runs on the same board with
//! 10, so we are one step off, which supports the measurement.
//!
//! Measured with DYN_DA_EN "true" and the phase from the input, and that is exactly how it
//! runs in operation: the input is tied to 11. The static mode (DYN_DA_EN "false",
//! PSDA_SEL) produces the same rising edge, as the simulation model shows (prim_sim.v line
//! 15278 against line 15289), but a different duty cycle: dynamically DUTYDA is computed
//! relative to PSDA, statically DUTYDA_SEL is absolute. We stay in the mode in which the
//! measurement was made.
//!
//! A slower clock is not needed: the command path has enough time at 64.8 MHz. Errors that
//! suggest a slow command path come from a bus conflict on DQ (see the ring schedule in
//! sdram_fb.v). Should more headroom ever be needed, 54 MHz is 2 x 27, so IDIV_SEL 0 and
//! FBDIV_SEL 1 with ODIV_SEL 16. NOT IDIV_SEL 4 / FBDIV_SEL 9 / ODIV_SEL 16: that chain runs
//! the phase comparator at 5.4 MHz and the PLL reaches LOCK only to lose it for good.
//!
//! The phase is adjustable at run time:
//!   DYN_DA_EN = "true"  -> PSDA_SEL and DUTYDA_SEL are ignored, the inputs PSDA and
//!                          DUTYDA apply (UG286-1.9.9E, table 5-5).
//!   PSDA[3:0]           -> phase in steps of 22.5 degrees, 0 to 337.5 degrees
//!                          (UG286 table 5-7). psda = 10 is 225 degrees, the NESTang value.
//!   DUTYDA[3:0]         -> CAUTION: in dynamic mode DUTYDA is not the duty cycle but the
//!                          position of the falling edge. UG286 table 5-8:
//!                          "when the phase shift setting is 0, the 50% duty cycle setting
//!                          will be 8; if the phase shift setting is 180 degrees, the 50%
//!                          duty cycle setting is 0", and DutyCycle = (DUTYDA - PSDA) mod 16.
//!                          Shown by the simulation model prim_sim.v from line 15277:
//!                            ps_dly      = clkout_period * PSDA / 16
//!                            clkout_duty = clkout_period * ((16 + DUTYDA - PSDA) mod 16)/16
//!                          So 50 percent exists only with DUTYDA = PSDA + 8. Whoever leaves
//!                          DUTYDA fixed at 8 gets a duty cycle of 14/16 at PSDA 10 and thus
//!                          an SDRAM clock that violates the hold time.
//!                          That is why DUTYDA is computed from PSDA here.
//!   PSDA is "rising edge effective" per UG286 table 2-2, DUTYDA "falling edge effective".
//!
//! The same line ps_dly = clkout_period * PSDA / 16 incidentally shows the direction: the
//! pad edge LAGS the fabric edge, by 9.645 ns at PSDA 10. The whole timing arithmetic in
//! sdram_fb.v rests on that.
//!
//! The PLL does not lose lock when switching: PS&DCA sits behind VCODIV and outside the
//! feedback loop (UG286 figure 2-4), CLKFB_SEL is "internal" and hangs on CLKOUT. The fabric
//! clock CLKOUT has no phase adjustment anyway per table 5-2 and keeps running unchanged
//! during the switch. A shortened pulse can occur on CLKOUTP when switching, so the self-test
//! holds the controller in reset during the change (and waits four cycles until the
//! synchronous reset has really taken effect), then CS# is high and every edge is a NOP.
//! Whether the assumption holds is shown by the lock_lost flag in the self-test: a
//! red-brown background means it does not.
//!
//! The self-test (SDRAMTEST=2) keeps sweeping the input, so the window can be re-measured
//! at any time, for instance after larger changes to the design.
module pll_sdram (clkout, clkoutp, lock, clkin, psda);

output wire clkout;
output wire clkoutp;
output wire lock;
input  wire clkin;
input  wire [3:0] psda;

wire clkoutd_o;
wire clkoutd3_o;
wire gw_vcc;
wire gw_gnd;

assign gw_vcc = 1'b1;
assign gw_gnd = 1'b0;

// 50 percent duty cycle, see header: DUTYDA = (PSDA + 8) mod 16. For four bits that is the
// same as PSDA XOR 8, i.e. only the top bit. No adder, no carry propagation delay: DUTYDA
// thus switches exactly together with PSDA and cannot take on intermediate values during
// the change that do not match PSDA.
wire [3:0] dutyda = {~psda[3], psda[2:0]};

rPLL rpll_inst (
    .CLKOUT(clkout),
    .LOCK(lock),
    .CLKOUTP(clkoutp),
    .CLKOUTD(clkoutd_o),
    .CLKOUTD3(clkoutd3_o),
    .RESET(gw_gnd),
    .RESET_P(gw_gnd),
    .CLKIN(clkin),
    .CLKFB(gw_gnd),
    .FBDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .IDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .ODSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .PSDA(psda),
    .DUTYDA(dutyda),
    .FDLY({gw_vcc,gw_vcc,gw_vcc,gw_vcc})
);

defparam rpll_inst.FCLKIN = "27";
defparam rpll_inst.DYN_IDIV_SEL = "false";
defparam rpll_inst.IDIV_SEL = 4;
defparam rpll_inst.DYN_FBDIV_SEL = "false";
defparam rpll_inst.FBDIV_SEL = 11;
defparam rpll_inst.DYN_ODIV_SEL = "false";
// ODIV only determines the VCO frequency (VCO = output clock * ODIV), permitted are 500 to
// 1250 MHz. At 64.8 MHz, 8 is just enough (518 MHz), at 54 MHz it is not (432 MHz).
defparam rpll_inst.ODIV_SEL = 8;           // 64.8 * 8 = 518.4 MHz
defparam rpll_inst.PSDA_SEL = "1011";      // ineffective with DYN_DA_EN "true", stands at
                                           // 11 here only as a reminder
defparam rpll_inst.DYN_DA_EN = "true";     // phase from the input psda, see header
defparam rpll_inst.DUTYDA_SEL = "1000";    // only effective when DYN_DA_EN is "false"
defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL = "internal";
defparam rpll_inst.CLKOUT_BYPASS = "false";
defparam rpll_inst.CLKOUTP_BYPASS = "false";
defparam rpll_inst.CLKOUTD_BYPASS = "false";
defparam rpll_inst.DYN_SDIV_SEL = 2;
defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
defparam rpll_inst.DEVICE = "GW2AR-18C";

endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
