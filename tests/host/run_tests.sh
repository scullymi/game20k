#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
#
# Runs the host test binaries the Makefile passes and adds up Unity's counts. Exit status 1
# when a binary fails, crashes, reports a failed test or runs no test at all: a binary with
# 0 tests has checked nothing. V=1 prints each binary's whole output, otherwise failures,
# sample sizes (Unity's INFO lines) and ignored tests.
bins=0; good=0; tests=0; fails=0; ignored=0
for bin in "$@"; do
  bins=$((bins + 1))
  out=$("$bin" 2>&1)
  rc=$?
  # Unity ends with "<n> Tests <f> Failures <i> Ignored", without it the binary died early
  read -r n f i <<EOT
$(printf '%s\n' "$out" | sed -n 's/^\([0-9]*\) Tests \([0-9]*\) Failures \([0-9]*\) Ignored.*$/\1 \2 \3/p' | tail -n 1)
EOT
  tests=$((tests + ${n:-0})); fails=$((fails + ${f:-0})); ignored=$((ignored + ${i:-0}))
  if [ "$rc" -eq 0 ] && [ -n "$n" ] && [ "$f" -eq 0 ] && [ "$n" -gt 0 ]; then
    good=$((good + 1))
    echo "PASS $(basename "$bin"): $n tests, $f failures, $i ignored"
    if [ "${V:-0}" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | grep -e ':INFO:' -e ':IGNORE'; fi | sed 's/^/  /'
  else
    if [ -z "$n" ]; then why="no Unity summary, exit status $rc"
    elif [ "$n" -eq 0 ]; then why="no test ran"
    else why="$f of $n tests failed, exit status $rc"; fi
    echo "FAIL $(basename "$bin"): $why"
    printf '%s\n' "$out" | sed 's/^/  /'
  fi
done
echo "host tests: $good of $bins binaries passed, $tests tests, $fails failures, $ignored ignored"
[ "$bins" -gt 0 ] && [ "$good" -eq "$bins" ]
