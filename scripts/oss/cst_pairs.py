#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Writes a Gowin constraint file in the form nextpnr reads for differential pairs.

The Gowin IDE takes a pair in one line, IO_LOC "tmds_d_p[0]" 35,36, and finds the negative pin
itself. nextpnr pairs "x_p" with "x_n" from such a line only for names ending in _p, not for
bus bits, and Apicula needs the IO type of both pins. Each pair becomes one line per pin, the
negative one named with _n, both with IO_TYPE=LVCMOS33D unless the file names a type.

    cst_pairs.py <board.cst>  (writes to stdout)
"""
import re
import sys

pairs = {}      # positive name -> negative name
out = []
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    m = re.match(r'(\s*IO_LOC\s+")([^"]+)("\s+)(\w+)\s*,\s*(\w+)\s*;(.*)', line)
    if m and "_p" in m.group(2):
        pos = m.group(2)
        neg = re.sub(r"_p(\[|$)", r"_n\1", pos, count=1)
        pairs[pos] = neg
        out.append(f'{m.group(1)}{pos}{m.group(3)}{m.group(4)};{m.group(6)}')
        out.append(f'{m.group(1)}{neg}{m.group(3)}{m.group(5)};')
        continue
    m = re.match(r'(\s*IO_PORT\s+")([^"]+)("\s+)(.*?);(.*)', line)
    if m and m.group(2) in pairs:
        attrs = m.group(4) if "IO_TYPE" in m.group(4) else "IO_TYPE=LVCMOS33D " + m.group(4)
        for name in (m.group(2), pairs[m.group(2)]):
            out.append(f'{m.group(1)}{name}{m.group(3)}{attrs};{m.group(5)}')
        continue
    out.append(line)
print("\n".join(out))
