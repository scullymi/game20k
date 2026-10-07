#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Turn a MAME debugger trace of a Namco MB88 custom into the step file of tb_mb88_trace.vhd.

The trace comes from MAME's "trace" command with a tracelog prefix that prints the state
before each instruction:
    A=%X X=%X Y=%X PA=%X SI=%X PIO=%02X TH=%X TL=%X <addr>: <disassembly>
The step file has one line per instruction, all fields hexadecimal:
    pc a x y si pio th tl nbytes inkind inval irqlev tick entry
inkind: 0 none, 1 the instruction reads K, 2 it reads R(Y & 3). inval is the value MAME read,
taken from A of the next line. irqlev: level of the interrupt line (1 = asserted) the
instruction must see, 2 for "leave as it is". It is known only for tsti, from whether the
conditional jump after it was taken. tick: the timer stepped during this instruction.
entry: an external interrupt entry follows this instruction.

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
    """Where a conditional jump at pc goes when taken, or None if it is not one."""
    op = rom[pc]
    if op >= 0xC0:                       # jmp: PC within the page, PA unchanged
        nxt = (pc + 1) & 0x3FF           # PA is already incremented if pc was the last byte
        return (nxt & 0x3C0) | (op & 0x3F)
    if 0x68 <= op <= 0x6F:               # jpl
        arg = rom[(pc + 1) & 0x3FF]
        return (((op & 7) << 2 | arg >> 6) << 6) | (arg & 0x3F)
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
    with open(out, "w") as o:
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
                if tgt is None or tgt == fall:
                    unknown_tsti += 1
                else:
                    irqlev = 0 if st[k + 2][8] == tgt else 1
            # an entry: the next line starts at $002 and this instruction does not jump
            # there. SI is no help, after rts or rti it drops and rises in the same step.
            if nxt[8] == 0x002 and jump_target(rom, pc) != 0x002 and not 0x60 <= op <= 0x67:
                entry = 1
            if nxt[7] != tl and op != 0x06:
                tick = 1
            o.write("%03X %X %X %X %X %02X %X %X %X %X %X %X %X %X\n" % (
                pc, a, x, y, si, pio, th, tl, nbytes(op), inkind, inval, irqlev, tick, entry))
    print("%d steps, %d tsti without a decidable jump" % (n - 1, unknown_tsti), file=sys.stderr)


if __name__ == "__main__":
    main()
