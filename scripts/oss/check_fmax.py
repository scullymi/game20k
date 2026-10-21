#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Prints the clocks of the routed design and fails when one misses its frequency.

The numbers come from nextpnr's --report, which holds the timing after routing. Its log also
has an estimate after placement, which may report FAIL where the routed design passes.

    check_fmax.py <report.json>
"""
import json
import sys


def main():
    fmax = json.load(open(sys.argv[1]))["fmax"]
    width = max(len(name) for name in fmax)
    bad = 0
    for name, clk in sorted(fmax.items()):
        ok = clk["achieved"] >= clk["constraint"]
        bad += not ok
        print(f"{name:>{width}}: {clk['achieved']:7.2f} MHz "
              f"({'PASS' if ok else 'FAIL'} at {clk['constraint']:.2f} MHz)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
