#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Resources per instance: Yosys (hierarchical synthesis) next to Gowin's synthesis report.

Usage: compare_resources.py <yosys stat -json file> <Gowin *_syn_rsc.xml> [depth]

The Yosys side needs a synthesis with --keep-hierarchy in read_slang and synth_gowin -noflatten,
so that modules stay instances. slang names a module after its instance path ("name$top.a.b"),
GHDL modules are matched by their entity name. LUT counts LUT1 to LUT4, the wide-LUT muxes
(MUX2_LUT5..8) are left out, as Gowin's report leaves them out.
"""
import functools
import json
import re
import sys
import xml.etree.ElementTree as ET

stat, rsc = sys.argv[1], sys.argv[2]
depth = int(sys.argv[3]) if len(sys.argv) > 3 else 2
mods = json.load(open(stat))["modules"]


def kind(t):
    if re.match(r"LUT\d$", t):
        return "LUT"
    if t == "ALU":
        return "ALU"
    if t.startswith("DFF"):
        return "REG"
    if t.startswith("RAM16"):
        return "SSRAM"
    if t in ("DPB", "DPX9B", "SDPB", "SDPX9B", "SP", "SPX9", "pROM", "pROMX9"):
        return "BSRAM"
    return None


def key(t):
    return "\\" + t if "\\" + t in mods else (t if t in mods else None)


@functools.lru_cache(None)
def total(m):
    r = dict(LUT=0, ALU=0, REG=0, SSRAM=0, BSRAM=0)
    for t, n in mods[m]["num_cells_by_type"].items():
        k = key(t)
        if k:
            sub = total(k)
            for x in r:
                r[x] += sub[x] * n
        elif kind(t):
            r[kind(t)] += n
    return r


# instance path -> Yosys module: slang appends the path, the rest is found by entity name
by_path = {}
for m in mods:
    name = m.lstrip("\\")
    if "$" in name:
        by_path[name.split("$", 1)[1]] = m


def yosys_for(path, gowin_name):
    p = "game20k_top" + "".join("." + s for s in path)
    if p in by_path:
        return by_path[p]
    for m in mods:   # GHDL entity, lower case, with generics appended
        n = m.lstrip("\\").lower()
        if n == gowin_name.lower() or n.startswith(gowin_name.lower() + "_brtl"):
            return m
    return None


def T(e, k):
    return int(e.get("T_" + k, "0").split("(")[0])


root = ET.parse(rsc).getroot()
top = [m for m in mods if m.lstrip("\\") == "game20k_top"][0]
print(f"{'instance':42s} {'Gowin LUT':>9s} {'ALU':>5s} {'SSRAM':>5s} | {'Yosys LUT':>9s} {'ALU':>5s} {'SSRAM':>5s} | sites ratio")
def line(label, g, y):
    gs = g[0] + g[1] + 6 * g[2]
    if y:
        ys = y["LUT"] + y["ALU"] + 6 * y["SSRAM"]
        print(f"{label:42s} {g[0]:9d} {g[1]:5d} {g[2]:5d} | {y['LUT']:9d} {y['ALU']:5d} {y['SSRAM']:5d} | {ys / max(gs, 1):5.2f}")
    else:
        print(f"{label:42s} {g[0]:9d} {g[1]:5d} {g[2]:5d} | {'-':>9s}")
line("TOTAL", (T(root, "Lut"), T(root, "Alu"), T(root, "Ssram")), total(top))


def walk(e, path, d):
    for s in e.findall("SubModule"):
        g = (T(s, "Lut"), T(s, "Alu"), T(s, "Ssram"))
        if g[0] + g[1] + 6 * g[2] < 60:
            continue
        p = path + [s.get("name")]
        y = yosys_for(p, s.get("name"))
        line("  " * d + "/".join(p)[-(42 - 2 * d):], g, total(y) if y else None)
        if d + 1 < depth:
            walk(s, p, d + 1)


walk(root, [], 0)
