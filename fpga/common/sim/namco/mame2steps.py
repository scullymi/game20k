#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Turn a MAME debugger trace of a Namco MB88 custom into the step file of tb_mb88_trace.sv.

The trace comes from MAME's "trace" command with a tracelog prefix that prints the state
before each instruction:
    A=%X X=%X Y=%X PA=%X SI=%X PIO=%02X TH=%X TL=%X <addr>: <disassembly>
The step file has one line per instruction, all fields hexadecimal:
    pc a x y si pio th tl nbytes inkind inval irqlev tick entry
inkind: 0 none, 1 the instruction reads K, 2 it reads R(Y & 3). inval is the value MAME read,
taken from A of the next line. irqlev: level of the interrupt line (1 = asserted) the
instruction must see, 2 for "leave as it is". It is known only for tsti, from whether the
conditional jump after it was taken. When an interrupt entry follows that jump, the return
address of the handler's rti decides. If a tsti finds the line asserted without an entry
before it, MAME saw the edge while PIO bit 2 was clear: the level is then set at the last
instruction before the tsti that starts with bit 2 clear, so that no edge reaches the core
while the bit is set.
tick: the timer stepped after this instruction (TL changed, or after tatl differs from the A
it wrote).
entry: a falling /IRQ edge comes before this instruction. Normally that is the instruction an
external interrupt entry follows. When the entry follows an en that sets PIO bit 2 again, the
request was latched earlier and kept: MAME latches an edge only while bit 2 is set, so the edge
goes before the last instruction that cleared the bit.

Usage: mame2steps.py <trace> <rom.bin> <steps.txt>
The ROM is only read to decode instruction lengths and jump targets. Nothing of it is
written to the step file beyond what the trace already holds (addresses and register values).
"""
import re
import sys

LINE = re.compile(r"A=(\w) X=(\w) Y=(\w) PA=(\w+) SI=(\w) PIO=(\w+) TH=(\w) TL=(\w) +([0-9A-F]{3}):")


def nbytes(op):
    return 2 if op in (0x3D, 0x3E, 0x3F) or 0x60 <= op <= 0x6F else 1


def jump_target(rom, pc):
    """Where a conditional jump or call at pc goes when taken, or None if it is not one."""
    op = rom[pc]
    if op >= 0xC0:                       # jmp: PC within the page, PA unchanged
        nxt = (pc + 1) & 0x3FF           # PA is already incremented if pc was the last byte
        return (nxt & 0x3C0) | (op & 0x3F)
    if 0x60 <= op <= 0x6F:               # call, jpl
        arg = rom[(pc + 1) & 0x3FF]
        return (((op & 7) << 2 | arg >> 6) << 6) | (arg & 0x3F)
    return None


def after_jump(st, k):
    """PC after the instruction in line k: the next line, or the return address of the
    interrupt entry that follows it (the line after the first rti at the same SI)."""
    nxt = st[k + 1]
    if nxt[8] != 0x002 or nxt[4] == st[k][4]:
        return nxt[8]
    for j in range(k + 2, min(k + 100000, len(st) - 1)):
        if st[j + 1][4] == st[k][4] and st[j][4] == nxt[4]:
            return st[j + 1][8]
    return None


def main():
    trace, romfile, out = sys.argv[1:4]
    rom = open(romfile, "rb").read()
    st = []
    with open(trace, "rb") as f:
        for raw in f:
            m = LINE.search(raw.decode("latin-1"))
            if m:
                st.append([int(g, 16) for g in m.groups()])
    # fields: a x y pa si pio th tl pc
    n = len(st)
    unknown_tsti = 0
    moved = 0
    rows = []
    for k in range(n - 1):
        a, x, y, pa, si, pio, th, tl, pc = st[k]
        nxt = st[k + 1]
        op = rom[pc]
        inkind, inval, irqlev, tick, entry = 0, 0, 2, 0, 0
        if op == 0x12:
            inkind, inval = 1, nxt[0]
        elif op == 0x13:
            inkind, inval = 2, nxt[0]
        elif op == 0x25 and k + 2 < n:
            # tsti sets ST = not IF, the next instruction is the conditional jump
            tgt = jump_target(rom, nxt[8])
            fall = (nxt[8] + nbytes(rom[nxt[8]])) & 0x3FF
            went = after_jump(st, k + 1)
            if tgt is None or tgt == fall or went is None:
                unknown_tsti += 1
            else:
                irqlev = 0 if went == tgt else 1
        # an entry: the next line starts at $002 and this instruction does not jump
        # there. SI is no help, after rts or rti it drops and rises in the same step.
        if nxt[8] == 0x002 and jump_target(rom, pc) != 0x002:
            entry = 1
            if not pio & 0x04:
                # the request is older than this instruction, see the header
                j = k - 1
                while j >= 0 and not st[j][5] & 0x04:
                    j -= 1
                if j >= 0:
                    rows[j][13] = 1
                    entry = 0
                    moved += 1
        if (nxt[7] != a) if op == 0x06 else (nxt[7] != tl):
            tick = 1
        rows.append([pc, a, x, y, si, pio, th, tl, nbytes(op), inkind, inval, irqlev, tick, entry])
    # the line level as the bench drives it: an edge leaves the line asserted
    level, last, unplaced = 0, -1, 0
    for k, r in enumerate(rows):
        if r[11] == 1 and level == 0 and not r[13] and r[5] & 0x04:
            j = k - 1
            while j > last and (rows[j][5] & 0x04 or rows[j][11] != 2 or rows[j][13]):
                j -= 1
            if j > last:
                rows[j][11] = 1
            else:
                unplaced += 1
        if r[13]:
            level, last = 1, k
        elif r[11] != 2:
            level, last = r[11], k
    with open(out, "w") as o:
        for r in rows:
            o.write("%03X %X %X %X %X %02X %X %X %X %X %X %X %X %X\n" % tuple(r))
    print("%d steps, %d tsti without a decidable jump, %d edges moved before a dis, "
          "%d asserted levels without a place" % (n - 1, unknown_tsti, moved, unplaced),
          file=sys.stderr)


if __name__ == "__main__":
    main()
