#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Timing summary and verdict of a Gowin place-and-route run.

Reads <project>_tr_content.html, the HTML timing report that gw_sh writes next to the
bitstream, and prints the numbers this project goes by:

  * Fmax per clock against the requested frequency. Taken from the clock summary table,
    whose rows look like: index | clock name | required (MHz) | actual Fmax (MHz) | ...
  * setup and hold violations. Taken from the timing summary tables, one row per
    Setup/Hold: clock | Setup or Hold | total negative slack (ns) | violated endpoints
  * as a cross check, the "Numbers of Setup/Hold Violated Endpoints" lines of the report

Usage: fpga_report.py <path to *_tr_content.html> [<synthesis log>]

The verdict is fixed: every clock reaches the frequency its own summary row requires (the
SDC is the rule), and the synthesis log, when given, has no EX3638 (a net used before its
declaration gets a second, undriven net) and no EX3988 (a $readmemh file was not found, its
memory stays empty). The violation counts are printed without a verdict.

The report has no ids or classes worth matching, so rows are recognised by their content.
If Gowin changes the layout, the script says so instead of silently printing less.
Exit code 0 when every verdict passed, 1 when one failed or no clock summary was found,
2 on wrong usage.
"""
import html
import re
import sys

#: synthesis warnings that must not occur, see above
FORBIDDEN_WARNINGS = ('EX3638', 'EX3988')


def table_rows(text):
    """Every <tr> of the document as a list of cell strings, tags stripped."""
    return [[html.unescape(re.sub(r'<[^>]+>', '', cell)).strip()
             for cell in re.findall(r'<t[dh].*?</t[dh]>', row, re.S)]
            for row in re.findall(r'<tr.*?</tr>', text, re.S)]


def mhz(cell):
    """Leading number of a cell such as '91.509(MHz)', None when it has none."""
    m = re.match(r'\s*([0-9]+(?:\.[0-9]+)?)', cell)
    return float(m.group(1)) if m else None


def main(argv):
    if len(argv) not in (2, 3) or argv[1].startswith('-'):
        print(__doc__)
        return 2
    text = open(argv[1], encoding='utf-8', errors='replace').read()
    clocks = failed = 0
    for r in table_rows(text):
        if len(r) >= 4 and '(MHz)' in r[2] and '(MHz)' in r[3]:
            required, actual = mhz(r[2]), mhz(r[3])
            ok = required is not None and actual is not None and actual >= required
            print(f"  {'PASS' if ok else 'FAIL'}  Fmax {r[1]:<10} {r[3]:>12}   required {r[2]}")
            clocks += 1
            failed += not ok
        if len(r) == 4 and r[1] in ('Setup', 'Hold') and r[3].isdigit() and r[3] != '0':
            print(f"  {r[0]} {r[1]}: {r[3]} violated endpoints (total {r[2]} ns)")
    flat = re.sub(r'<[^>]+>', ' ', text)
    for m in re.finditer(r'Numbers of (Setup|Hold) Violated Endpoints[^0-9]*([0-9]+)', flat):
        print(f"  {m.group(1)} violated endpoints: {m.group(2)}")
    if clocks == 0:
        print("  (no clock summary found: the report layout has changed, open the HTML)")
        return 1
    if len(argv) == 3:
        try:
            log = open(argv[2], encoding='utf-8', errors='replace').read()
        except OSError:
            print(f"  FAIL  no synthesis log {argv[2]}")
            return 1
        # a Gowin synthesis log starts with this line, an empty or foreign file would pass as
        # "0 warnings" without it
        if not log.startswith('GowinSynthesis start'):
            print(f"  FAIL  {argv[2]} is not a Gowin synthesis log ({len(log.splitlines())} lines)")
            return 1
        print(f"  synthesis log: {len(log.splitlines())} lines, {len(re.findall(r'^WARN', log, re.M))} warnings")
        for code in FORBIDDEN_WARNINGS:
            n = len(re.findall(r'^WARN\s*\(' + code + r'\)', log, re.M))
            print(f"  {'PASS' if n == 0 else 'FAIL'}  {code} in the synthesis log: {n}")
            failed += n != 0
    print(f"  verdict: {'FAIL' if failed else 'PASS'}, {clocks} clocks"
          + (f" and {len(FORBIDDEN_WARNINGS)} synthesis warnings" if len(argv) == 3 else "") + " checked")
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
