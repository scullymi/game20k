#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Gowin synthesis from the command line. Usage: scripts/build_fpga.sh <project folder under fpga/>
#
# Diagnostic builds via environment variables, see fpga/<project>/build.tcl:
#   RAMDIAG=1  ROMVIEW=1  FBTEST=1  FBSHOW=1  FBROT=1  SDRAMTEST=2|3  NOTESTBAR=1  RATEPROBE=1
#
# The build ends with scripts/fpga_report.sh on the fresh reports and exits 1 when a clock
# misses its constraint or the synthesis log has EX3638 or EX3988.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "$1" ]; then
  echo "Usage: scripts/build_fpga.sh <project folder under fpga/>" >&2
  echo "available:" >&2
  for d in "$ROOT"/fpga/*/build.tcl; do [ -e "$d" ] && echo "  $(basename "$(dirname "$d")")" >&2; done
  exit 2
fi
if [ ! -f "$ROOT/fpga/$1/build.tcl" ]; then
  echo "fpga/$1/build.tcl does not exist." >&2
  exit 2
fi

. "$ROOT/scripts/find_gowin.sh"

# Library paths: macOS resolves them via DYLD_*, Linux via LD_LIBRARY_PATH. Setting both does
# no harm, each system simply ignores the variable meant for the other.
export DYLD_FRAMEWORK_PATH="$IDE/lib" DYLD_LIBRARY_PATH="$IDE/lib"
export LD_LIBRARY_PATH="$IDE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$ROOT/fpga/$1"
# An aborted run leaves the reports of the previous build in place. Only reports newer than
# this stamp are from this build.
STAMP=$(mktemp "${TMPDIR:-/tmp}/build_fpga.XXXXXX")
trap 'rm -f "$STAMP"' EXIT
"$IDE/bin/gw_sh" build.tcl
for f in "impl/pnr/${1}_tr_content.html" "impl/pnr/$1.rpt.txt" "impl/gwsynthesis/$1.log"; do
  # find prints the file only when it exists and is newer than the stamp
  if [ -z "$(find "$f" -newer "$STAMP" 2>/dev/null)" ]; then
    echo "No verdict: fpga/$1/$f is missing or older than this build." >&2
    exit 1
  fi
done
if ! sh "$ROOT/scripts/fpga_report.sh" "$1"; then
  echo "The bitstream is written, but a clock misses its constraint or EX3638/EX3988 appeared." >&2
  exit 1
fi
