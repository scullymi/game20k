#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Summarises the report of the last Gowin build.
# Usage: scripts/fpga_report.sh [project folder under fpga/]   (default galaga_hdmi)
#
# The tool's reports are HTML with a few thousand lines. This prints only the numbers
# this project uses as acceptance criteria: utilisation, Fmax per clock and the number of
# violated endpoints. The timing part lives in fpga_report.py, which documents the
# tables it expects and gives the verdict: every clock reaches its required frequency, and
# the synthesis log has no EX3638 or EX3988. The exit code is 1 when that fails.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="${1:-galaga_hdmi}"
D="$ROOT/fpga/$P/impl/pnr"
[ -f "$D/$P.rpt.txt" ] || { echo "No report in $D, build first."; exit 1; }
echo "Report from $(date -r "$D/$P.rpt.txt" '+%Y-%m-%d %H:%M:%S')"
# Warn when a source was touched after the report. An aborted build leaves the old
# reports in place, and those get read as if they were current.
NEWER=$(find "$ROOT/fpga/$P" "$ROOT/fpga/common" "$ROOT/fpga/vendor" \( -name '*.v' -o -name '*.sv' -o -name '*.vhd' -o -name '*.sdc' \
        -o -name '*.cst' -o -name '*.tcl' -o -name '*.manifest' -o -name '*.hex' \) -newer "$D/$P.rpt.txt" -not -path '*/impl/*' 2>/dev/null | head -3)
[ -n "$NEWER" ] && { echo "WARNING: the report is OLDER than these files, so it is not from the last build:";
                     echo "$NEWER" | sed "s|$ROOT/||;s|^|  |"; }
echo "--- Utilisation ---"
# grep exits 1 when a line is missing; that is a finding, not a reason to stop.
grep -E "^ +(Logic|Register|CLS|I/O Port|BSRAM|DSP|PLL|rPLL|PRIMARY|LW|GCLK_PIN|CLKDIV) +\|" "$D/$P.rpt.txt" \
  | sed 's/ *| */  /g;s/^ *//' || echo "  (no utilisation table found)"
grep -E "Logic Register as FF|I/O Register as FF" "$D/$P.rpt.txt" | sed 's/ *| */  /g;s/^ *//' || true
echo "--- Timing ---"
[ -f "$D/${P}_tr_content.html" ] || { echo "  (no timing report ${P}_tr_content.html)"; exit 1; }
exec python3 "$ROOT/scripts/fpga_report.py" "$D/${P}_tr_content.html" "$ROOT/fpga/$P/impl/gwsynthesis/$P.log"
