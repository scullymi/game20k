#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Marks read-during-write between different ports of a memory as undefined.

Reads RTLIL written after memory_unpack. For each clocked $memrd_v2 and each clocked $memwr_v2
of the same memory on the same clock, with another address and without transparency, it sets
the collision bit. memory_libmap then needs no logic around a block RAM for it. The result is a
Yosys script of setparam commands, so the design stays in the running Yosys.

    rw_collision.py <in.il> <out.ys>
"""
import re
import sys

src = open(sys.argv[1]).read().split("\n")

# The memory port cells with their parameters and connections
cells = []
module = None
i = 0
while i < len(src):
    line = src[i]
    m = re.match(r"module (\S+)", line)
    if m:
        module = m.group(1)
    m = re.match(r"  cell \$(memrd_v2|memwr_v2) (\S+)", line)
    if m:
        cell = {"module": module, "kind": m.group(1), "name": m.group(2), "params": {}, "conns": {}}
        i += 1
        while src[i] != "  end":
            p = re.match(r"    parameter \\(\S+) (.*)", src[i])
            if p:
                cell["params"][p.group(1)] = (p.group(2), i)
            c = re.match(r"    connect \\(\S+) (.*)", src[i])
            if c:
                cell["conns"][c.group(1)] = c.group(2)
            i += 1
        cells.append(cell)
    i += 1

def bits(value):
    # RTLIL constant <width>'<bits>, MSB first. Small parameters are plain integers.
    if "'" not in value:
        return ["1" if int(value) else "0"]
    width, b = value.split("'")
    return list(b)

writes = {}
for c in cells:
    if c["kind"] == "memwr_v2":
        key = (c["module"], c["params"]["MEMID"][0])
        writes.setdefault(key, []).append(c)

def sel(name):
    return name[1:] if name.startswith("\\") else name

changed = 0
cmds = []
for r in cells:
    if r["kind"] != "memrd_v2" or bits(r["params"]["CLK_ENABLE"][0]) != ["1"]:
        continue
    ws = writes.get((r["module"], r["params"]["MEMID"][0]), [])
    if not ws:
        continue
    trans = bits(r["params"]["TRANSPARENCY_MASK"][0])
    coll = bits(r["params"]["COLLISION_X_MASK"][0])
    before = list(coll)
    n = len(coll)
    for w in ws:
        pid = int(w["params"]["PORTID"][0])
        pos = n - 1 - pid  # MSB first
        if bits(w["params"]["CLK_ENABLE"][0]) != ["1"]:
            continue
        if w["conns"]["CLK"] != r["conns"]["CLK"] or w["params"]["CLK_POLARITY"][0] != r["params"]["CLK_POLARITY"][0]:
            continue
        if trans[pos] == "1" or coll[pos] == "1":
            continue
        if w["conns"]["ADDR"] == r["conns"]["ADDR"]:
            continue  # same port: read-first or no-change stays as written
        coll[pos] = "1"
        changed += 1
    if coll != before:
        cmds.append(f"setparam -set COLLISION_X_MASK {n}'b{''.join(coll)} {sel(r['module'])}/{sel(r['name'])}")

open(sys.argv[2], "w").write("".join(c + "\n" for c in cmds))
print(f"rw_collision: {changed} read/write port pairs marked undefined")
