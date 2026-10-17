#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Apicula's gowin_pack with two changes for the Tang Nano 20K's HDMI pins.

Usage: as gowin_pack, run with the oss-cad-suite's Python.

1. A bank with LVDS outputs gets BANK_VCCIO 3.3 instead of Apicula's 1.2 for the GW2A. The
   board supplies bank 4 with 3.3 V, and the Companion's MOSI (pin 41) shares that bank with
   the HDMI pins: with 1.2 the FPGA reads MOSI as 0. Gowin builds the bank with 3.3 as well.
2. ELVDS_OBUF is allowed on pins that can do true LVDS. Apicula refuses it there, Gowin places
   the emulated buffer on exactly these pins (33 to 40) and the picture comes.
3. The header's configuration register (command 0x10) gets the loading rate that Gowin writes
   for "-loading_rate 25.000". With Apicula's template value the FPGA reads the flash so slowly
   at power-on that the board takes many seconds to start.
"""
import re
import sys

import apycula.gowin_pack as gp

gp.Device.get_lvds_bank_vccio = lambda self: "3.3"

_check_elvds = gp.Device.check_elvds_placement


def check_elvds_placement(self, bel):
    """Apicula's check without the refusal of true LVDS pins."""
    cfg = self.chipdb.get_io_diff_cfg(bel.x, bel.y, bel.idx_str)
    if cfg and cfg.true_lvds:
        if cfg.positive != (bel.cell.parms.get('DIFF') == 'P'):
            raise Exception(f"X{bel.x}Y{bel.y}/IOB{bel.idx_str} ({bel.cell.name}) cannot be placed"
                            " - pin P must be IOBA, pin N must be IOBB")
        return
    _check_elvds(self, bel)


gp.Device.check_elvds_placement = check_elvds_placement

_get_hdr = gp.Device.get_hdr


def get_hdr(self):
    """Apicula's header with byte 2 of the 0x10 command set as in Gowin's 25 MHz bitstream."""
    hdr = [bytearray(line) for line in _get_hdr(self)]
    for line in hdr:
        if len(line) == 8 and line[0] == 0x10:
            line[5] = 0xd4
    return hdr


gp.Device.get_hdr = get_hdr

if __name__ == '__main__':
    sys.argv[0] = re.sub(r'(-script\.pyw|\.exe)?$', '', sys.argv[0])
    sys.exit(gp.main())
