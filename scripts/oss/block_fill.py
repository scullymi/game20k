#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Picks memories for the block RAM that are still free after a first synthesis.

Yosys maps a memory to LUT RAM or logic when that looks cheaper than a block RAM, even while
block RAMs stay unused. Gowin fills them first. This script reads the memories (JSON of the
$mem_v2 cells) and the log of the first run and prints the names of memories that a second run
should put into block RAM: named, at least 256 words, every read port on a clock, largest first
while the free block RAMs last. It stops when the log names a memory the JSON does not have:
then the names do not match and every memory would look free.

    block_fill.py <mems.json> <yosys.log> <netlist.json> [total block RAMs]
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


def memories(path):
    """name -> (width, size, all read ports clocked) of the $mem_v2 cells, parameters being bit
    strings in JSON"""
    out = {}
    for m in json.load(open(path))["modules"].values():
        for n, c in m["cells"].items():
            if c["type"] == "$mem_v2":
                p = c["parameters"]
                out[n] = (int(p["WIDTH"], 2), int(p["SIZE"], 2), "0" not in p.get("RD_CLK_ENABLE", "0"))
    return out


def main():
    mems_json, log, netlist = sys.argv[1:4]
    total = int(sys.argv[4]) if len(sys.argv) > 4 else 46
    mems = memories(mems_json)
    # how the first run mapped each memory, from memory_libmap's line per memory
    mapped, in_block = set(), set()
    for line in open(log):
        m = re.search(r"mapping memory \S+?\.(\S+) via \$__GOWIN_(\w+)", line)
        if m:
            mapped.add(m.group(1))
            if m.group(2) in ("SP_", "DP_", "SDP_"):
                in_block.add(m.group(1))
    if not mapped or mapped - set(mems):
        sys.exit("block_fill: the log names %d memories, %d of them not in %s"
                 % (len(mapped), len(mapped - set(mems)), mems_json))
    cells = json.load(open(netlist))["modules"]
    used = sum(1 for mod in cells.values() for c in mod["cells"].values() if c["type"] in BSRAM_TYPES)
    free = total - used
    picks = []
    # JSON writes public names without the backslash, generated ones start with $
    cand = [(n, w, s) for n, (w, s, clocked) in mems.items()
            if not n.startswith("$") and clocked and s >= 256 and n not in in_block]
    # largest first, equal sizes by name, so that the order depends on nothing else
    for n, w, s in sorted(cand, key=lambda x: (-x[1] * x[2], x[0])):
        need = blocks_needed(w, s)
        if need <= free:
            picks.append(re.sub(r"[][]", "?", n))   # [ and ] are pattern characters in select
            free -= need
    print(" ".join(picks))


if __name__ == "__main__":
    main()
