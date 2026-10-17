#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Picks memories for the block RAM that are still free after a first synthesis.

Yosys maps a memory to LUT RAM or logic when that looks cheaper than a block RAM, even while
block RAMs stay unused. Gowin fills them first. This script reads the memory dump and the log of
the first run and prints the names of memories that a second run should put into block RAM:
named, at least 256 words, every read port on a clock, largest first while the free block RAMs
last.

    block_fill.py <mems_dump.txt> <yosys.log> <netlist.json> [total block RAMs]
"""
import json
import math
import re
import sys

# Gowin BSRAM configurations: data width -> depth (18 Kbit with parity)
CONFIGS = ((1, 16384), (2, 8192), (4, 4096), (9, 2048), (18, 1024), (36, 512))
BSRAM_TYPES = ("DPB", "DPX9B", "SP", "SPX9", "SDPB", "SDPX9B", "pROM", "pROMX9")


def blocks_needed(width, size):
    """Fewest block RAMs for a memory of size words of width bits."""
    return min(math.ceil(width / w) * math.ceil(size / d) for w, d in CONFIGS)


def memories(dump):
    """name -> (width, size, all read ports clocked) from the dump of the $mem_v2 cells"""
    mems, name = {}, None
    for line in open(dump):
        m = re.match(r"\s*cell \$mem_v2 (\S+)", line)
        if m:
            name = m.group(1)
            mems[name] = {}
            continue
        m = re.match(r"\s*parameter \\(WIDTH|SIZE|RD_CLK_ENABLE) (\S+)", line)
        if m and name:
            mems[name][m.group(1)] = m.group(2)
    out = {}
    for n, p in mems.items():
        clocked = "0" not in p.get("RD_CLK_ENABLE", "0").split("'")[-1]
        out[n] = (int(p["WIDTH"]), int(p["SIZE"]), clocked)
    return out


def main():
    dump, log, netlist = sys.argv[1:4]
    total = int(sys.argv[4]) if len(sys.argv) > 4 else 46
    # how the first run mapped each memory
    in_block = set()
    for line in open(log):
        m = re.search(r"mapping memory \S+?\.(\S+) via \$__GOWIN_(SP|DP|SDP)", line)
        if m:
            in_block.add(m.group(1))
    cells = json.load(open(netlist))["modules"]
    used = sum(1 for mod in cells.values() for c in mod["cells"].values() if c["type"] in BSRAM_TYPES)
    free = total - used
    picks = []
    cand = [(n[1:], w, s) for n, (w, s, clocked) in memories(dump).items()
            if n.startswith("\\") and clocked and s >= 256 and n[1:] not in in_block]
    for n, w, s in sorted(cand, key=lambda x: -x[1] * x[2]):
        need = blocks_needed(w, s)
        if need <= free:
            picks.append(re.sub(r"[][]", "?", n))   # [ and ] are pattern characters in select
            free -= need
    print(" ".join(picks))


if __name__ == "__main__":
    main()
