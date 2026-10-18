#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""@file fs2bin.py
@brief Writes a Gowin .fs bitstream as bytes, the .bin the release image is made of.

Usage: scripts/oss/fs2bin.py <in.fs> <out.bin>

A .fs holds the bitstream as lines of 0 and 1, eight to a byte, most significant bit first,
after a header of // comment lines. Gowin's IDE writes the same bytes as .bin beside it.
"""
import sys

bits = "".join(l.strip() for l in open(sys.argv[1], encoding="ascii") if not l.startswith("//"))
if not bits or len(bits) % 8 or set(bits) - set("01"):
    sys.exit("fs2bin.py: %s is no bitstream of whole bytes" % sys.argv[1])
open(sys.argv[2], "wb").write(int(bits, 2).to_bytes(len(bits) // 8, "big"))
