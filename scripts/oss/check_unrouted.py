#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Fails when the routed design has a net with users but no route.

nextpnr's router skips a net without a driver and reports nothing, so its users stay
unconnected. This happened to the users of a net in front of a BUFG besides the BUFG itself.
Inputs that need no route are left out: a BUFG input (the global router starts at its source)
and the I/O buffers on top-level pins.

    check_unrouted.py <routed.json>
"""
import json
import sys


def main():
    module = next(iter(json.load(open(sys.argv[1]))["modules"].values()))
    users = {}
    for name, cell in module["cells"].items():
        typ = cell["type"]
        if typ == "BUFG" or typ.endswith(("IBUF", "IOBUF", "OBUF")) or typ.startswith(("TLVDS", "ELVDS")):
            continue
        for port, bits in cell["connections"].items():
            if cell["port_directions"].get(port) == "input":
                for bit in bits:
                    if isinstance(bit, int):
                        users.setdefault(bit, []).append(f"{name}.{port}")
    bad = [(name, users[net["bits"][0]]) for name, net in module["netnames"].items()
           if len(net["bits"]) == 1 and net["bits"][0] in users
           and not net.get("attributes", {}).get("ROUTING", "").strip()]
    for name, ports in bad:
        print(f"unrouted net {name}, used by {', '.join(ports[:3])}", file=sys.stderr)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
