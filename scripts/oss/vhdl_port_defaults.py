#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Ties open inputs of VHDL entities to the default values of their port declarations.

A VHDL entity reaches Yosys through GHDL as a plain module, the defaults of its input ports
(WAIT_n : in std_logic := '1') are lost. An instance in Verilog or SystemVerilog that leaves such
a port open then gets an undriven input, which the synthesis may turn into any constant. Gowin
applies the default. This script reads the instances of the entities and the ports of their
modules as JSON and writes a Yosys script that connects every open input to its default.

    vhdl_port_defaults.py <design.json> <out.ys> <entity> [<entity> ...] -- <vhdl file> [...]

It stops when an entity is not in the VHDL files, its module not in the design, or no instance
of it is found: then the names do not match, and an open input would stay undriven unnoticed.
"""
import json
import re
import sys


def port_defaults(vhdl_files, entity):
    """{port: value as Verilog constant} for the input ports of entity that have a default, None
    if no file declares entity"""
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
                    out[name.strip()] = f"1'b{d.group(3)}"
                continue
            d = re.match(r"\s*([\w\s,]+?)\s*:\s*in\s+std_u?logic_vector\s*\(\s*(\d+)\s+downto\s+(\d+)\s*\)"
                         r"\s*:=\s*\(\s*others\s*=>\s*'([01])'\s*\)", decl, re.I)
            if d:
                width = int(d.group(2)) - int(d.group(3)) + 1
                for name in d.group(1).split(","):
                    out[name.strip()] = f"{width}'b{d.group(4) * width}"
        return out
    return None


def main():
    sep = sys.argv.index("--")
    design, out, entities, vhdl = sys.argv[1], sys.argv[2], sys.argv[3:sep], sys.argv[sep + 1:]
    modules = json.load(open(design))["modules"]
    cmds = []
    for entity in entities:
        defaults = port_defaults(vhdl, entity)
        if defaults is None:
            sys.exit(f"vhdl_port_defaults: no entity {entity} in the VHDL files")
        if entity not in modules:
            sys.exit(f"vhdl_port_defaults: no module {entity} in {design}")
        # GHDL lower-cases the port names, VHDL compares them without case
        inputs = {p.lower(): p for p, d in modules[entity]["ports"].items() if d["direction"] == "input"}
        instances = [(mod, name, c) for mod, m in modules.items() for name, c in m["cells"].items()
                     if c["type"] == entity]
        if not instances:
            sys.exit(f"vhdl_port_defaults: no instance of {entity} in {design}")
        for mod, name, c in instances:
            for port, value in defaults.items():
                if port.lower() not in inputs:
                    sys.exit(f"vhdl_port_defaults: module {entity} has no input {port}")
                if inputs[port.lower()] not in c["connections"]:
                    cmds.append(f"connect -port {name} {inputs[port.lower()]} {value} {mod}")
    open(out, "w").write("".join(c + "\n" for c in cmds))


if __name__ == "__main__":
    main()
