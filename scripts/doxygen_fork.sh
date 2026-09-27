#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Builds the Doxygen pages of our sources in the FPGA-Companion fork and lists
# what is not documented. Exit code 1 when Doxygen warns.
# Usage: scripts/doxygen_fork.sh   (default: the submodule external/FPGA-Companion, FORK=<checkout> for another one)
#
# Pages: build/doxygen/html/index.html (build/ is not in git).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORK="${FORK:-$ROOT/external/FPGA-Companion}"
OUT="$ROOT/build/doxygen"
command -v doxygen >/dev/null || { echo "doxygen missing: brew install doxygen"; exit 1; }
[ -f "$FORK/src/ra_task.c" ] || { echo "no fork sources at $FORK: run git submodule update --init, or set FORK=<checkout>"; exit 1; }
mkdir -p "$OUT"
export FORK OUT
doxygen "$ROOT/scripts/Doxyfile"
if [ -s "$OUT/warnings.txt" ]; then
  echo "Doxygen warnings:"
  sed "s#$FORK/##" "$OUT/warnings.txt"
  exit 1
fi
echo "No warnings. Pages: $OUT/html/index.html"
