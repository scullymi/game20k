#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Tabulates the $mem_v2 cells of a Yosys netlist in JSON (out/<core>/mems.json), largest first."""
import json
import sys

rows = []
for m in json.load(open(sys.argv[1]))["modules"].values():
    for name, c in m["cells"].items():
        if c["type"] != "$mem_v2":
            continue
        p, a = c["parameters"], c["attributes"]
        # JSON gives numeric parameters as bit strings, MSB first
        size, width = int(p["SIZE"], 2), int(p["WIDTH"], 2)
        style = a.get("syn_ramstyle", a.get("ram_style", "-"))
        src = a.get("src", "-").split("|")[0]
        rows.append((size * width, size, width, int(p["RD_PORTS"], 2), int(p["WR_PORTS"], 2),
                     style, name, src.split("/fpga/")[-1]))
rows.sort(reverse=True)
for r in rows:
    print("%7d bit  %5dx%-3d rd%s wr%s  %-12s %s  (%s)" % r)
