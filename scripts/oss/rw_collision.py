#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Marks read-during-write between different ports of a memory as undefined.

Reads the $memrd_v2 and $memwr_v2 cells as JSON, written after memory_unpack. For each clocked
read port and each clocked write port of the same memory on the same clock, with another address
and without transparency, it sets the collision bit. memory_libmap then needs no logic around a
block RAM for it. The result is a Yosys script of setparam commands, so the design stays in the
running Yosys.

    rw_collision.py <memports.json> <out.ys>
"""
import json
import sys

modules = json.load(open(sys.argv[1]))["modules"]

# The memory port cells with their module. JSON gives parameters as bit strings, MSB first, an
# integer parameter with 32 bits, and connections as lists of bit numbers.
cells = [(mod, name, c) for mod, m in modules.items() for name, c in m["cells"].items()
         if c["type"] in ("$memrd_v2", "$memwr_v2")]
# every design here has memories, none found means the selection or the format changed
if not any(c["type"] == "$memrd_v2" for _, _, c in cells):
    sys.exit("rw_collision: no $memrd_v2 cell in " + sys.argv[1])

writes = {}
for mod, _, c in cells:
    if c["type"] == "$memwr_v2":
        writes.setdefault((mod, c["parameters"]["MEMID"]), []).append(c)

changed = 0
cmds = []
for mod, name, r in cells:
    p = r["parameters"]
    if r["type"] != "$memrd_v2" or int(p["CLK_ENABLE"], 2) != 1:
        continue
    ws = writes.get((mod, p["MEMID"]), [])
    if not ws:
        continue
    trans = list(p["TRANSPARENCY_MASK"])
    coll = list(p["COLLISION_X_MASK"])
    before = list(coll)
    n = len(coll)
    for w in ws:
        wp = w["parameters"]
        pos = n - 1 - int(wp["PORTID"], 2)  # MSB first
        if int(wp["CLK_ENABLE"], 2) != 1:
            continue
        if w["connections"]["CLK"] != r["connections"]["CLK"] or int(wp["CLK_POLARITY"], 2) != int(p["CLK_POLARITY"], 2):
            continue
        if trans[pos] == "1" or coll[pos] == "1":
            continue
        if w["connections"]["ADDR"] == r["connections"]["ADDR"]:
            continue  # same port: read-first or no-change stays as written
        coll[pos] = "1"
        changed += 1
    if coll != before:
        cmds.append(f"setparam -set COLLISION_X_MASK {n}'b{''.join(coll)} {mod}/{name}")

open(sys.argv[2], "w").write("".join(c + "\n" for c in cmds))
print(f"rw_collision: {changed} read/write port pairs marked undefined")
