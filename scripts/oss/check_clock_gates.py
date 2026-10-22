#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Fails when a clock net leaves the global clock network and re-enters it through a gate.

The gates (TRBDCLK0 and family) feed logic signals into the global clock network. A route from a
global clock wire into such a gate is a detour whose delay nextpnr's timing model does not know,
so flip-flops behind it get their clock late and hold fails on the board. nextpnr's
clock_gate_wire_filter() forbids it, but before the scullymi/nextpnr fix e43bf42e not for nets
behind a BUFG, and with the fix it still takes the detour, with a warning, when there is no other
route. This catches both.

    check_clock_gates.py <routed.json>

Run with the oss-cad-suite's Python and Apicula on PYTHONPATH, for its chip database.
"""
import importlib.resources
import json
import re
import sys

from apycula import chipdb


def main():
    with importlib.resources.as_file(importlib.resources.files("apycula") / "GW2A-18C.msgpack.xz") as p:
        db = chipdb.load_chipdb(p)
    # the input wires of the gates, as (row, column, wire) like the routing names them
    gates = {}
    for name, (_, wires) in db.nodes.items():
        if "BDCLK" in name or "MDCLK" in name:
            for r, c, w in wires:
                if w.startswith("CLK"):
                    gates[(r, c, w)] = name
    module = next(iter(json.load(open(sys.argv[1]))["modules"].values()))
    bad = []
    for name, net in module["netnames"].items():
        for pip in net.get("attributes", {}).get("ROUTING", "").split(";")[1::3]:
            m = re.fullmatch(r"X(\d+)Y(\d+)/(\w+)/(\w+)", pip)
            if not m:
                continue
            x, y, dst, src = int(m[1]), int(m[2]), m[3], m[4]
            if (y, x, dst) in gates and src.startswith(("GB", "GT", "SPINE")):
                bad.append(f"net {name} re-enters the clock network through {gates[(y, x, dst)]}: {pip}")
    for line in bad:
        print(line, file=sys.stderr)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
