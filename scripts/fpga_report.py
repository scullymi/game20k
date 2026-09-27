#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Timing summary of a Gowin place-and-route run.

Reads <project>_tr_content.html, the HTML timing report that gw_sh writes next to the
bitstream, and prints only the acceptance criteria of this project:

  * Fmax per clock against the requested frequency. Taken from the clock summary table,
    whose rows look like: index | clock name | required (MHz) | actual Fmax (MHz) | ...
  * setup and hold violations. Taken from the timing summary tables, one row per
    Setup/Hold: clock | Setup or Hold | total negative slack (ns) | violated endpoints
  * as a cross check, the "Numbers of Setup/Hold Violated Endpoints" lines of the report

Usage: fpga_report.py <path to *_tr_content.html>

The report has no ids or classes worth matching, so rows are recognised by their content.
If Gowin changes the layout, the script says so instead of silently printing less.
Exit code 0 when a clock summary was found, 1 when not, 2 on wrong usage.
"""
import html
import re
import sys


def table_rows(text):
    """Every <tr> of the document as a list of cell strings, tags stripped."""
    return [[html.unescape(re.sub(r'<[^>]+>', '', cell)).strip()
             for cell in re.findall(r'<t[dh].*?</t[dh]>', row, re.S)]
            for row in re.findall(r'<tr.*?</tr>', text, re.S)]


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    text = open(argv[1], encoding='utf-8', errors='replace').read()
    clocks = 0
    for r in table_rows(text):
        if len(r) >= 4 and '(MHz)' in r[2] and '(MHz)' in r[3]:
            print(f"  Fmax {r[1]:<10} {r[3]:>12}   required {r[2]}")
            clocks += 1
        if len(r) == 4 and r[1] in ('Setup', 'Hold') and r[3].isdigit() and r[3] != '0':
            print(f"  {r[0]} {r[1]}: {r[3]} violated endpoints (total {r[2]} ns)")
    flat = re.sub(r'<[^>]+>', ' ', text)
    for m in re.finditer(r'Numbers of (Setup|Hold) Violated Endpoints[^0-9]*([0-9]+)', flat):
        print(f"  {m.group(1)} violated endpoints: {m.group(2)}")
    if clocks == 0:
        print("  (no clock summary found: the report layout has changed, open the HTML)")
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
