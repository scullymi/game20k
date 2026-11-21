// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 scullymi
//! @file stone.v
//! @brief The stepping stone: an empty bitstream the BL616 loads over JTAG to jump to a core.
//!
//! Its header carries the 0xD2 command with the address of a slot of the configuration flash.
//! The BL616 sets that address while it sends the bitstream and starts the jump with a
//! RECONFIG over JTAG, see stone.c in the fork. RECONFIG_N stays high meanwhile.
module stone(output reconfig_n);
    assign reconfig_n = 1'b1;
endmodule
