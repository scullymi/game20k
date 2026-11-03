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
    sources <core folder> --out <folder>   prints a core's own sources, for a simulation
    tools [fetch | build --source]         the programs of tools.toml: where, fetch, build"""

import sys

if sys.version_info < (3, 11):
    sys.exit("game20k needs Python 3.11 or newer, this is " + sys.version.split()[0])

from tools.engine.cli import main  # noqa: E402  only after the version check

sys.exit(main(sys.argv[1:]))
