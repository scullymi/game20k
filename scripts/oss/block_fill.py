#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Picks memories for the block RAM that are still free after a first synthesis.

Yosys maps a memory to LUT RAM or logic when that looks cheaper than a block RAM, even while
block RAMs stay unused. Gowin fills them first. This script reads the memories (JSON of the
$mem_v2 cells) and the netlist of the first run and prints the names of memories that a second
run should put into block RAM: named, at least 256 words, every read port on a clock, largest
first while the free block RAMs last. A memory is in block RAM when the netlist has a block RAM
cell named after it, <memory>.<read port>.<part> as memory_libmap names them. It stops when no
block RAM cell carries the name of a memory: then the names do not match and every memory would
look free.

    block_fill.py <mems.json> <netlist.json> <block RAMs of the device>
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
    mems_json, netlist, total = sys.argv[1], sys.argv[2], int(sys.argv[3])
    mems = memories(mems_json)
    blocks = [n for mod in json.load(open(netlist))["modules"].values()
              for n, c in mod["cells"].items() if c["type"] in BSRAM_TYPES]
    # the memories the first run put into block RAM. Other block RAM cells are primitives the
    # HDL instantiates itself.
    in_block = {m.group(1) for m in (re.fullmatch(r"(.+)\.\d+\.\d+", n) for n in blocks)
                if m and m.group(1) in mems}
    # none of them named after a memory: the netlist names its block RAM cells in another way
    # (the names are Yosys' own, a Yosys version may change them), and every memory would look
    # free to move. A design whose
    # memories all went into LUT RAM stops here too, loudly and never with a wrong result.
    if mems and not in_block:
        sys.exit("block_fill: no block RAM cell of %s is named after a memory of %s"
                 % (netlist, mems_json))
    used = len(blocks)
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
