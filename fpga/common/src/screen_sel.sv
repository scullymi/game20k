// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
`default_nettype none   // game20k: a typo in a signal name must be an error, not a
                       // silent 1-bit net.
//! @file screen_sel.sv
//! @brief Picture path, OSD and banner position from the game's screen and the menu's screen mode.
//!
//! The screen says how the core's raster stands (screen line of the manifest, at run time
//! from header byte 2, see game20k_top.sv): 0 upright, 1 cw, 2 ccw, 3 is treated as cw.
//! The screen mode comes from the menu (G): 0 landscape, anything else portrait.
//!
//!   screen   mode       use_fb  portrait  rotate  flip  land
//!   upright  any        0       0         0       0     1
//!   cw       landscape  0       0         1       0     0
//!   cw       portrait   1       1         0       0     0
//!   ccw      landscape  0       0         1       1     0
//!   ccw      portrait   1       1         0       0     0
//!
//! An upright game always comes 3x through the scaler on the landscape monitor, the menu's
//! mode has no effect. A turned game in landscape also comes through the scaler, the monitor
//! is turned, so OSD and banner are drawn turned. In portrait it comes 2x from the frame
//! buffer, already turned, with OSD and banner upright. The measurement builds FBSHOW and
//! FBROT always take the frame buffer (fb_force). Combinational: both inputs change only in
//! the blanking interval.
module screen_sel (
    input  wire  [1:0] screen,    //!< 0 upright, 1 cw, 2 ccw, 3 as cw
    input  wire  [1:0] mode,      //!< screen mode from the menu: 0 landscape, else portrait
    input  wire        fb_force,  //!< measurement build: the picture always from the frame buffer
    output logic       use_fb,    //!< picture from the frame buffer instead of the scaler
    output logic       portrait,  //!< portrait 2x: scanlines on every second line
    output logic       rotate,    //!< OSD and banner turned by 90 degrees (osd_u8g2, ra_overlay)
    output logic       flip,      //!< with rotate: turned the other way, for ccw
    output logic       land       //!< banner upright in the band below the landscape picture
);
    wire upright = (screen == 2'd0);
    assign portrait = !upright && (mode != 2'd0);
    assign use_fb   = fb_force || portrait;
    assign rotate   = !upright && !portrait;
    assign flip     = rotate && (screen == 2'd2);
    assign land     = upright;
endmodule

`default_nettype wire   // required: Gowin compiles ALL files as one unit, the directive
                        // would otherwise leak into the next file.
