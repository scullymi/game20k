#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Ties open inputs of VHDL entities to the default values of their port declarations.

A VHDL entity reaches Yosys through GHDL as a plain module, the defaults of its input ports
(WAIT_n : in std_logic := '1') are lost. An instance in Verilog or SystemVerilog that leaves such
a port open then gets an undriven input, which the synthesis may turn into any constant. Gowin
applies the default. This script adds the default to every instance in the elaborated RTLIL.

    vhdl_port_defaults.py <design.il> <entity> [<entity> ...] -- <vhdl file> [<vhdl file> ...]
"""
import re
import sys


def port_defaults(vhdl_files, entity):
    """{port: value bits as RTLIL constant} for the input ports of entity that have a default"""
    for f in vhdl_files:
        text = re.sub(r"--[^\n]*", "", open(f, errors="replace").read())
        m = re.search(rf"\bentity\s+{entity}\s+is(.*?)\bend\b", text, re.I | re.S)
        if not m:
            continue
        ports = re.search(r"\bport\s*\((.*)\)\s*;", m.group(1), re.I | re.S)
        if not ports:
            return {}
        out = {}
        for decl in ports.group(1).split(";"):
            d = re.match(r"\s*([\w\s,]+?)\s*:\s*in\s+(std_logic|std_ulogic)\s*:=\s*'([01])'", decl, re.I)
            if d:
                for name in d.group(1).split(","):
                    out[name.strip()] = f"1'{d.group(3)}"
                continue
            d = re.match(r"\s*([\w\s,]+?)\s*:\s*in\s+std_u?logic_vector\s*\(\s*(\d+)\s+downto\s+(\d+)\s*\)"
                         r"\s*:=\s*\(\s*others\s*=>\s*'([01])'\s*\)", decl, re.I)
            if d:
                width = int(d.group(2)) - int(d.group(3)) + 1
                for name in d.group(1).split(","):
                    out[name.strip()] = f"{width}'{d.group(4) * width}"
        return out
    return {}


def main():
    sep = sys.argv.index("--")
    il, entities, vhdl = sys.argv[1], sys.argv[2:sep], sys.argv[sep + 1:]
    defaults = {e.lower(): port_defaults(vhdl, e) for e in entities}
    lines = open(il).read().split("\n")
    out, cell, seen, added = [], None, set(), []
    for line in lines:
        m = re.match(r"\s*cell \\(\S+) (\S+)$", line)
        if m:
            cell, seen = (m.group(1).lower(), m.group(2)), set()
        elif cell and re.match(r"\s*connect \\(\S+) ", line):
            seen.add(re.match(r"\s*connect \\(\S+) ", line).group(1))
        elif cell and line.strip() == "end":
            # GHDL lower-cases the module and port names
            for port, val in defaults.get(cell[0], {}).items():
                if port not in seen and port.lower() not in seen:
                    name = port.lower() if any(p.islower() for p in seen) else port
                    out.append(f"    connect \\{name} {val}")
                    added.append(f"{cell[1]}.{name}={val}")
            cell = None
        out.append(line)
    open(il, "w").write("\n".join(out))
    for a in added:
        print(f"vhdl_port_defaults: {a}")


if __name__ == "__main__":
    main()
