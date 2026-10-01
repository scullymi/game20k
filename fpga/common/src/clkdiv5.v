// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent 1-bit net.
//! -----------------------------------------------------------------------------------------
//! @file clkdiv5.v
//! @brief Clock divider 5:1 for the pixel clock (game20k)
//!
//! 371.25 MHz (HDMI serialiser clock) -> 74.25 MHz pixel clock.
//!
//! Why this file is hand-written
//! -----------------------------
//! This used to be the output of the Gowin IP generator. That output is tiny, but it belongs
//! to Gowin, and its redistribution terms are in no file of the project: for a publication
//! an open question without need. What the generator produces is the instantiation of a
//! hardware primitive with a few parameters, and there is only one way to write that. CLKDIV
//! comes from the toolchain library like OSER10 and ELVDS_OBUF; naming it is not
//! redistributing foreign code.
//! -----------------------------------------------------------------------------------------

module clkdiv5 (
    output wire clkout,      //!< 74.25 MHz
    input  wire hclkin,      //!< 371.25 MHz from the rPLL
    input  wire resetn       //!< active low
);
    CLKDIV clkdiv_inst (
        .CLKOUT (clkout),
        .HCLKIN (hclkin),
        .RESETN (resetn),
        .CALIB  (1'b0)
    );
    defparam clkdiv_inst.DIV_MODE = "5";
    defparam clkdiv_inst.GSREN    = "false";
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
