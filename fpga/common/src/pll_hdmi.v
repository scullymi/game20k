// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent 1-bit net.
//! -----------------------------------------------------------------------------------------
//! @file pll_hdmi.v
//! @brief Clock generation for HDMI and core (game20k)
//!
//! 27 MHz crystal -> CLKOUT 371.25 MHz (serialiser clock), CLKOUTD the core clock.
//!   371.25 = 27 * 55 / 4      (IDIV_SEL 3 divides by 4, FBDIV_SEL 54 multiplies by 55)
//!   pixel clock 74.25 = 371.25 / 5, generated in clkdiv5.v
//!   core clock  371.25 / SDIV (DYN_SDIV_SEL): 20 gives 18.5625 (Galaga, Pac-Man), 10 gives
//!               37.125 (1942). Both come from the same VCO, so the frame lock to HDMI holds.
//!
//! Why this file is hand-written: see the header of clkdiv5.v. In short: what stands here is
//! the instantiation of a hardware primitive with chosen parameters, and there is only one
//! way to write that.
//!
//! DYN_DA_EN is "true", but the phase inputs are tied to zero: the HDMI chain needs no phase
//! shift. The mode comes from the original and stays so that both PLLs of the design are
//! treated alike; PSDA_SEL would be ineffective in dynamic mode anyway.
//! -----------------------------------------------------------------------------------------

module pll_hdmi #(
    parameter SDIV = 20      //!< CLKOUTD = CLKOUT / SDIV, even, 2..128 (UG286)
) (
    output wire clkout,      //!< 371.25 MHz
    output wire clkoutd,     //!<  371.25 MHz / SDIV
    output wire lock,
    input  wire clkin        //!<  27 MHz
);
    wire gnd = 1'b0;

    rPLL rpll_inst (
        .CLKOUT   (clkout),
        .LOCK     (lock),
        .CLKOUTP  (),
        .CLKOUTD  (clkoutd),
        .CLKOUTD3 (),
        .RESET    (gnd),
        .RESET_P  (gnd),
        .CLKIN    (clkin),
        .CLKFB    (gnd),
        .FBDSEL   ({6{gnd}}),
        .IDSEL    ({6{gnd}}),
        .ODSEL    ({6{gnd}}),
        .PSDA     ({4{gnd}}),
        .DUTYDA   ({4{gnd}}),
        .FDLY     ({4{gnd}})
    );

    defparam rpll_inst.FCLKIN           = "27";
    defparam rpll_inst.IDIV_SEL         = 3;      // /4
    defparam rpll_inst.FBDIV_SEL        = 54;     // *55
    defparam rpll_inst.ODIV_SEL         = 2;
    defparam rpll_inst.DYN_SDIV_SEL     = SDIV;   // CLKOUTD = CLKOUT / SDIV
    defparam rpll_inst.DYN_IDIV_SEL     = "false";
    defparam rpll_inst.DYN_FBDIV_SEL    = "false";
    defparam rpll_inst.DYN_ODIV_SEL     = "false";
    defparam rpll_inst.PSDA_SEL         = "0000";
    defparam rpll_inst.DYN_DA_EN        = "true";
    defparam rpll_inst.DUTYDA_SEL       = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR    = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR   = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP  = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
    defparam rpll_inst.CLKFB_SEL        = "internal";
    defparam rpll_inst.CLKOUT_BYPASS    = "false";
    defparam rpll_inst.CLKOUTP_BYPASS   = "false";
    defparam rpll_inst.CLKOUTD_BYPASS   = "false";
    defparam rpll_inst.CLKOUTD_SRC      = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC     = "CLKOUT";
    defparam rpll_inst.DEVICE           = "GW2AR-18";
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
