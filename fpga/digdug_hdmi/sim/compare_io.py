#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Compare the 06XX traffic of the main CPU in the simulation with MAME's.

Usage: compare_io.py <sim io.log> <mame io.log> [--offset D]

Both logs have lines "frame R|W address data" (tb_digdug.sv, mame_ref.lua). MAME runs the
real 51XX and 53XX programs on its MB88 model, the core on its own MB88 (fpga/common/src/namco).
Reads of the control register 7100 are dropped (MAME's tap does not log them). The rest is
cut into transactions: a write of a command to 7100 and the data accesses up to the next
command. Per command only the changes are kept: a transaction counts when it differs from the
last one with the same command. The two sequences of changes are compared,
each shown with the frame of its first transaction (simulation frame minus D, the offset
compare.py found) and how often it repeated.
"""
import sys


def runs(path, off):
    tx, cur = [], None
    for line in open(path):
        if len(line.split()) != 4:      # a log cut short in its last line
            continue
        f, rw, a, d = line.split()
        f, a, d = int(f), int(a, 16), int(d, 16)
        if a == 0x7100 and rw == "R":
            continue
        if a == 0x7100:
            if cur:
                tx.append(cur)
            cur = (f - off, d, [])
        elif cur:
            cur[2].append("%s%X=%02X" % (rw, a & 0xFF, d))
    if cur:
        tx.append(cur)
    # per command only its changes: a transaction counts when it differs from the last one
    # with the same command. Stop commands (10) without data accesses carry nothing
    out, last = [], {}
    for f, cmd, acc in tx:
        if cmd == 0x10 and not acc:
            continue
        key = "%02X %s" % (cmd, " ".join(acc))
        if last.get(cmd) != key:
            out.append([f, key, 1])
            last[cmd] = key
        else:
            for o in reversed(out):
                if o[1] == key:
                    o[2] += 1
                    break
    return out


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    off = int(argv[argv.index("--offset") + 1]) if "--offset" in argv else 0
    s, m = runs(argv[1], off), runs(argv[2], 0)
    print("transactions: simulation %d runs, MAME %d runs" % (len(s), len(m)))
    # walk both sequences of distinct transactions. Frames and run lengths are shown, not compared
    i = j = bad = 0
    while i < len(s) and j < len(m):
        if s[i][1] == m[j][1]:
            print("  same  sim f%-5d x%-5d mame f%-5d x%-5d  %s" % (s[i][0], s[i][2], m[j][0], m[j][2], s[i][1]))
            i += 1
            j += 1
        else:
            bad += 1
            print("  DIFF  sim f%-5d x%-5d %s\n        mame f%-5d x%-5d %s" % (s[i][0], s[i][2], s[i][1], m[j][0], m[j][2], m[j][1]))
            # resynchronise on the next transaction the other side has as well
            nxt = [(a + b, a, b) for a in range(0, 6) for b in range(0, 6)
                   if i + a < len(s) and j + b < len(m) and s[i + a][1] == m[j + b][1]]
            if not nxt:
                break
            _, a, b = min(nxt)
            i, j = i + max(a, 1) if a == 0 and b == 0 else i + a, j + b
    print("summary: %d differing runs, %d runs left in the simulation, %d in MAME" % (bad, len(s) - i, len(m) - j))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
