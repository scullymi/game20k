#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Fails when an instance of a VHDL entity leaves one of its inputs open.

A VHDL entity reaches Yosys through GHDL's Verilog as a plain module, the defaults of its input
ports (WAIT_n : in std_logic := '1') are lost. An instance that leaves such an input open gets
an undriven input, which the synthesis may turn into any constant: a CPU waits for ever or is
optimized away, without an error anywhere else. The instances connect every input themselves.

    vhdl_open_inputs.py <design.json> <entity> [<entity> ...]

It stops as well when an entity has no module or no instance in the design: then the names do
not match and an open input would go unnoticed.
"""
import json
import sys


def main():
    design, entities = sys.argv[1], sys.argv[2:]
    modules = json.load(open(design))["modules"]
    open_inputs = []
    for entity in entities:
        if entity not in modules:
            sys.exit(f"vhdl_open_inputs: no module {entity} in {design}")
        inputs = [p for p, d in modules[entity]["ports"].items() if d["direction"] == "input"]
        instances = [(mod, name, c) for mod, m in modules.items() for name, c in m["cells"].items()
                     if c["type"] == entity]
        if not instances:
            sys.exit(f"vhdl_open_inputs: no instance of {entity} in {design}")
        for mod, name, c in instances:
            open_inputs += [f"{mod}.{name}.{p}" for p in inputs if p not in c["connections"]]
    if open_inputs:
        sys.exit("vhdl_open_inputs: inputs of VHDL entities left open, connect them in the "
                 "instance:\n  " + "\n  ".join(open_inputs))


if __name__ == "__main__":
    main()
