#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""@file check_contracts.py
@brief Values that live in two places of game20k and must agree, compared without boards.

  mirror   the RAM mirror layout constants: ram_mirror_pkg.sv (core) against main.c (firmware)
The firmware's game table and menus need none: scripts/make_fw_tables.py generates them from the
ROM manifests and menu parts at every firmware build and host test run, and checks them as it
goes. The interface tag of a core comes from the same parts through make_menu.py.

Each contract prints how many values it compared ("N of N agree") and fails when it matched
nothing: a check that found nothing to compare is blind, not green.

Usage: scripts/check_contracts.py [--root DIR] [--fork DIR]
Exit status 0 when all hold, 1 otherwise.
"""
import argparse
import os
import re
import sys

DEFAULT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# the files the contracts read, relative to the game20k root ("root") or the fork ("fork")
F_PKG = ("root", "fpga/common/src/mcu/ram_mirror_pkg.sv")
F_MAIN = ("fork", "src/main.c")
# one localparam per line in the package, "localparam <type> RAM_MIRROR_X = <expr>;"
RE_PKG = r"\blocalparam\b[^;=]*?\b(RAM_MIRROR_\w+)\s*=\s*([^;]+);"


class Violation(Exception):
    """A contract does not hold. The message says which values differ and where."""


class Tree:
    """The two roots the contracts read from: the game20k tree and the fork checkout."""

    def __init__(self, root, fork):
        self.base = {"root": root, "fork": fork}

    def path(self, f):
        return os.path.join(self.base[f[0]], f[1])

    def read(self, f, code=True):
        """Content of a file, for code without // and /* */ comments. A missing file is a
        violation: the contract cannot compare."""
        try:
            with open(self.path(f), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            hint = " (git submodule update --init?)" if f[0] == "fork" else ""
            raise Violation("cannot read %s%s" % (self.path(f), hint))
        return re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", " ", text, flags=re.S)) if code else text


def need(cond, msg):
    """Raise a violation with msg unless cond holds."""
    if not cond:
        raise Violation(msg)


def value(defs, name, depth=0):
    """Value of the constant name in defs, with SV (8'h03, 16'd5) and C (0x03, 5u) literals and
    references to other RAM_MIRROR_* constants of the same side resolved."""
    need(depth < 10, "%s: references nest too deep" % name)
    expr = re.sub(r"\d*'[hH]([0-9a-fA-F_]+)", lambda m: str(int(m.group(1).replace("_", ""), 16)), defs[name])
    expr = re.sub(r"\d*'[dD]([0-9_]+)", lambda m: m.group(1).replace("_", ""), expr)
    expr = re.sub(r"\b0[xX]([0-9a-fA-F]+)[uUlL]*\b", lambda m: str(int(m.group(1), 16)), expr)
    expr = re.sub(r"\b(\d+)[uUlL]+\b", r"\1", expr)
    for ref in set(re.findall(r"\bRAM_MIRROR_\w+\b", expr)):
        need(ref in defs, "%s refers to %s, which is not defined on the same side" % (name, ref))
        expr = re.sub(r"\b%s\b" % ref, "(%d)" % value(defs, ref, depth + 1), expr)
    # only digits, + - * / and parentheses are left, so eval() sees nothing but arithmetic
    need(re.fullmatch(r"[0-9+\-*/() \t]+", expr) and "**" not in expr,
         "%s = %s cannot be evaluated" % (name, defs[name].strip()))
    try:
        return eval(expr.replace("/", "//"), {"__builtins__": {}})
    except (SyntaxError, ZeroDivisionError):
        raise Violation("%s = %s cannot be evaluated" % (name, defs[name].strip()))


def contract_mirror(t):
    """RAM_MIRROR_* in the core package and in the firmware: same names, same values."""
    core = dict(re.findall(RE_PKG, t.read(F_PKG)))
    fw = dict(re.findall(r"^[ \t]*#[ \t]*define[ \t]+(RAM_MIRROR_\w+)[ \t]+(.+?)[ \t]*$",
                         t.read(F_MAIN), re.M))
    need(core, "no RAM_MIRROR_* localparam in %s" % t.path(F_PKG))
    need(fw, "no #define RAM_MIRROR_* in %s" % t.path(F_MAIN))
    need(set(core) == set(fw), "names differ: only in the core %s, only in the firmware %s"
         % (sorted(set(core) - set(fw)), sorted(set(fw) - set(core))))
    diffs = ["%s: core %d, firmware %d" % (n, value(core, n), value(fw, n))
             for n in sorted(core) if value(core, n) != value(fw, n)]
    need(not diffs, "; ".join(diffs))
    return "%d of %d constants agree (ram_mirror_pkg.sv, main.c)" % (len(core), len(core))


CONTRACTS = [("mirror", contract_mirror)]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--root", default=DEFAULT_ROOT, help="game20k tree (default: this script's)")
    ap.add_argument("--fork", help="fork checkout (default: ROOT/external/FPGA-Companion)")
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    tree = Tree(root, os.path.abspath(a.fork or os.path.join(root, "external/FPGA-Companion")))
    failed = 0
    for name, fn in CONTRACTS:
        try:
            print("contract %s: ok, %s" % (name, fn(tree)))
        except (Violation, ValueError) as e:
            print("contract %s: FAIL, %s" % (name, e))
            failed += 1
    print("contracts: %d of %d hold" % (len(CONTRACTS) - failed, len(CONTRACTS)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
