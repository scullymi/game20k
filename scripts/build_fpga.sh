#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Gowin synthesis from the command line. Usage: scripts/build_fpga.sh <project folder under fpga/>
#
# Diagnostic builds via environment variables, see fpga/<project>/build.tcl:
#   RAMDIAG=1  ROMVIEW=1  FBTEST=1  FBSHOW=1  FBROT=1  SDRAMTEST=2|3
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
exec "$IDE/bin/gw_sh" build.tcl
