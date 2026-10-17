#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Tabulates the memories of a Yosys 'dump t:$mem_v2' (out/<core>/mems_dump.txt), largest first."""
import re
import sys

t = open(sys.argv[1]).read()
rows = []
for c in re.split(r"\n\s*cell \$mem_v2 ", "\n" + t)[1:]:
    name = c.split("\n", 1)[0].strip().lstrip("\\")
    p = dict(re.findall(r"parameter \\(\w+) (\S+)", c))
    def val(k):
        v = p.get(k, "0")
        m = re.match(r"(\d+)'([01x]+)$", v)
        if m:
            return int(m.group(2), 2)
        try:
            return int(v)
        except ValueError:
            return 0
    src = re.search(r'attribute \\src "([^"|]+)', c)
    style = re.search(r'attribute \\(syn_ramstyle|ram_style) "([^"]+)"', c)
    size, width = val("SIZE"), val("WIDTH")
    rows.append((size * width, size, width, val("RD_PORTS"), val("WR_PORTS"),
                 style.group(2) if style else "-", name,
                 src.group(1).split("/fpga/")[-1] if src else "-"))
rows.sort(reverse=True)
for r in rows:
    print("%7d bit  %5dx%-3d rd%s wr%s  %-12s %s  (%s)" % r)
