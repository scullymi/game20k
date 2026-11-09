#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""@file
@brief The one entry point of game20k's build: python3 g20k.py <command> (Windows: py g20k.py).

    build <core folder> [--out <folder>]   builds one core, e.g. fpga/pang_hdmi
    release [--dev]                        builds every core and packs a release under dist/
    flash <core folder> [--sram]           loads a core's build into its slot or into SRAM
    flash --image <file>                   writes a flash image from 0
    cores                                  prints the core folders in ring order
    sdcard [card]                          makes the ROM files and settings, copies them to the card
    sources <core folder> --out <folder>   prints a core's own sources, for a simulation
    tools [fetch [names] | build-forks | pack --out <folder> | path <name>]
                                           the programs of tools.toml: where, fetch, build"""

import sys

# 3.11 for tomllib, 3.11.4 for the filter of tarfile.extractall, with which g20k.py tools
# fetch unpacks the archives safely: 3.11.0 to 3.11.3 lack it and stop with a TypeError
if sys.version_info < (3, 11, 4):
    sys.exit("game20k needs Python 3.11.4 or newer, this is " + sys.version.split()[0])

from tools.engine.cli import main  # noqa: E402  only after the version check

sys.exit(main(sys.argv[1:]))
