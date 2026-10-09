#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""@file make_fw_tables.py
@brief Writes the firmware's game table from the ROM manifests and its menus from the menu parts.

Usage: scripts/make_fw_tables.py --out DIR

Reads every fpga/<core>/*.manifest and writes DIR/ra_games_data.c, the rows that ra_games.c of
the fork looks the games up in, and DIR/menus_data.c, the menu of every core in
fpga/common/slots.txt with its board and IFACE_TAG (make_menu.py), plus the basic menu for a
core without one. scripts/build_companion.sh passes the files to CMake as GAME20K_GAMES_TABLE
and GAME20K_MENU_TABLE, tests/host links the game table into test_games. The files carry the
fork's licence, Apache-2.0, because they link into the fork's firmware.

A set with an ra line gets a row: set, short title, id, the md5 of the set name (how
RetroAchievements knows an arcade game), board, its known lines and its dip lines. Within a
board the set of the menu's ROM default (rom= in menu_core.xml) comes first, because
ra_games_by_board() shows the first row when no ROM has streamed. The others follow by set name.

The script stops with a message on
  - known or dip lines without an ra line, or an ra line without a known line
  - a dip line whose id is no list of the core's menu_core.xml, or whose value that list lacks
  - a set twice, a board in two core folders, a board whose first row is not the ROM default
  - a setting that a core starts at another value than its menu's default (make_menu.py)
  - a core of slots.txt without a menu part or without a manifest, a menu make_menu.py refuses
Exit status 0 when the table is written, 1 otherwise.
"""
import argparse
import glob
import hashlib
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import make_menu  # noqa: E402  the menu part's reader and the check of the cores' start values
import make_rom   # noqa: E402  the manifest reader, one parser for every user of the format

HEAD = """/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright (C) 2026 scullymi */
/** @file ra_games_data.c
 *  @brief The game table of game20k, written by its scripts/make_fw_tables.py from the
 *         ROM manifests fpga/<core>/<set>.manifest. Do not edit: change the manifests. */
#include "ra_games.h"

const char ra_games_origin[] = "generated";
"""

MENU_HEAD = """/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright (C) 2026 scullymi */
/** @file menus_data.c
 *  @brief The menus of game20k's cores, written by its scripts/make_fw_tables.py from
 *         fpga/common/menu/base.xml and fpga/<core>/menu_core.xml. Do not edit: change those. */
#include "menus.h"

const char menus_origin[] = "generated";
"""


def fail(msg):
    sys.exit("make_fw_tables.py: " + msg)


def c_string(text, where):
    """text as a C string literal. Only printable ASCII: the firmware's font has nothing else."""
    if not re.fullmatch(r"[ -~]*", text):
        fail("%s: '%s' is not printable ASCII" % (where, text))
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def menu_part(core):
    """The lists of the core's menu part as {id: set of values}, and the set of its ROM default."""
    rel = "fpga/%s/menu_core.xml" % core
    attrs, _ = make_menu.core_part(core)
    lists = {}
    for lst in ET.parse(os.path.join(ROOT, rel)).getroot().iter("list"):
        lists[lst.get("id")] = {int(e.get("value")) for e in lst.iter("listentry")}
    return lists, os.path.splitext(attrs.get("rom", ""))[0]


def read_games():
    """The rows of the table in their order, each a parsed manifest with core and path."""
    games, boards, cores = [], {}, {}
    for path in sorted(glob.glob(os.path.join(ROOT, "fpga", "*", "*.manifest"))):
        rel = os.path.relpath(path, ROOT)
        try:
            m = make_rom.read_manifest(path)
        except make_rom.ManifestError as e:
            fail(str(e))
        core = os.path.basename(os.path.dirname(path))
        # rom_loader and the firmware tell the cores apart by the board alone
        boards.setdefault(m["board"], set()).add(core)
        if len(boards[m["board"]]) > 1:
            fail("board %d in more than one core folder: %s" % (m["board"], ", ".join(sorted(boards[m["board"]]))))
        if "ra" not in m:
            if m["known"] or m["dips"]:
                fail("%s: known or dip lines but no ra line, the firmware would not know the game" % rel)
            continue
        if not m["known"]:
            fail("%s: an ra line but no known line, hardcore would accept no file" % rel)
        if not re.fullmatch(r"[a-z0-9_]+", m["set"]):
            fail("%s: set %s, a set name is lowercase letters, digits and _" % (rel, m["set"]))
        if core not in cores:
            cores[core] = menu_part(core)
        lists = cores[core][0]
        for key, value in m["dips"]:
            if key not in lists:
                fail("%s: dip %s %d, fpga/%s/menu_core.xml has no list %s" % (rel, key, value, core, key))
            if value not in lists[key]:
                fail("%s: dip %s %d, list %s of fpga/%s/menu_core.xml has the values %s"
                     % (rel, key, value, key, core, sorted(lists[key])))
        games.append(dict(m, rel=rel, default=cores[core][1]))
    if not games:
        fail("no manifest under fpga/ has an ra line, the table would be empty")
    sets = [g["set"] for g in games]
    for s in sorted(set(x for x in sets if sets.count(x) > 1)):
        fail("set %s in more than one manifest" % s)
    games.sort(key=lambda g: (g["board"], g["set"] != g["default"], g["set"]))
    for g in games:
        first = next(x for x in games if x["board"] == g["board"])
        if first["set"] != g["default"]:
            fail("board %d: the ROM default %s.rom of the menu has no ra line, %s would be shown "
                 "without a ROM" % (g["board"], g["default"], first["set"]))
    # the menus are made from the same parts: the cores start where their menus do
    folders = sorted(set().union(*boards.values()))
    started = sum(make_menu.check_core_defaults(c, make_menu.compose(c)) for c in folders)
    return games, boards, started


def read_menus(boards):
    """Per core of slots.txt, in ring order: its board, IFACE_TAG and menu. No core of the ring
    goes without a menu, the firmware would have none for it."""
    board_of = {c: b for b, cs in boards.items() for c in cs}
    menus = []
    with open(os.path.join(ROOT, "fpga/common/slots.txt"), encoding="utf-8") as f:
        ring = [line.split()[0] for line in f if line.strip() and not line.lstrip().startswith("#")]
    for core in ring:
        if not os.path.isfile(os.path.join(ROOT, "fpga", core, "menu_core.xml")):
            fail("%s of fpga/common/slots.txt has no menu part fpga/%s/menu_core.xml" % (core, core))
        if core not in board_of:
            fail("%s of fpga/common/slots.txt has no manifest, so no board" % core)
        xml = make_menu.compose(core)
        make_menu.check(core, xml)
        menus.append((core, board_of[core], make_menu.iface_tag(core), xml))
    if not menus:
        fail("fpga/common/slots.txt names no core")
    return menus


def c_text(text):
    """text as C string literals, one per line, printable ASCII and line ends only."""
    if not re.fullmatch(r"[ -~\n]*", text):
        fail("a menu holds a character other than printable ASCII and line ends")
    return "\n".join('  "%s"' % l.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
                     for l in text.splitlines(True))


def menu_table(menus):
    """The C file: each menu as a string, the rows by board, the basic menu."""
    out = [MENU_HEAD]
    for core, _, _, xml in menus:
        out.append("\n/* fpga/%s/menu_core.xml */\nstatic const char menu_%s[] =\n%s;\n" % (core, core, c_text(xml)))
    out.append("\n/* the board's menu (set NULL), its IFACE_TAG, the menu */\nconst menus_entry_t menus_rows[] = {\n")
    for core, board, tag, _ in menus:
        out.append("  { %d, NULL, 0x%04xu, menu_%s },\n" % (board, tag, core))
    out.append("};\nconst unsigned menus_rows_n = sizeof(menus_rows) / sizeof(menus_rows[0]);\n")
    basic = make_menu.compose("(basic menu)", make_menu.BASIC)
    make_menu.check("(basic menu)", basic)
    out.append("\n/* fpga/common/menu/base.xml without a core's part */\nconst char menus_basic_xml[] =\n%s;\n"
               % c_text(basic))
    return "".join(out)


def table(games):
    """The C file: per game its files and switches, then the rows."""
    out = [HEAD]
    for g in games:
        s = g["set"]
        out.append("\n/* %s */\nstatic const ra_rom_t roms_%s[] = {\n" % (g["rel"], s))
        for digest, label in g["known"]:
            if not re.fullmatch(r"[0-9a-f]{64}", digest):
                fail("%s: known %s is not a SHA-256 in hex" % (g["rel"], digest))
            b = ["0x" + digest[i:i + 2] for i in range(0, 64, 2)]
            out.append("  { { %s,\n      %s }, %s },\n" % (",".join(b[:16]), ",".join(b[16:]), c_string(label, g["rel"])))
        out.append("};\n")
        if g["dips"]:
            out.append("static const ra_dip_t dips_%s[] = { %s };\n"
                       % (s, ", ".join("{ '%s', %d }" % d for d in g["dips"])))
    out.append("\nconst ra_game_t ra_games_rows[] = {\n")
    for g in games:
        s = g["set"]
        out.append('  { "%s", %s, %du, "%s", %d, roms_%s, %d, %s, %d },\n' % (
            s, c_string(g.get("short", g["title"]), g["rel"]), g["ra"], hashlib.md5(s.encode()).hexdigest(),
            g["board"], s, len(g["known"]), "dips_" + s if g["dips"] else "NULL", len(g["dips"])))
    out.append("};\nconst unsigned ra_games_rows_n = sizeof(ra_games_rows) / sizeof(ra_games_rows[0]);\n")
    return "".join(out)


def write(path, text):
    """Writes the file only when it changes, so make and CMake rebuild only then."""
    try:
        with open(path, encoding="utf-8", newline="") as f:
            if f.read() == text:
                return
    except OSError:
        pass
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--out", required=True, help="folder for ra_games_data.c and menus_data.c")
    a = ap.parse_args()
    games, boards, started = read_games()
    menus = read_menus(boards)
    path = os.path.join(a.out, "ra_games_data.c")
    write(path, table(games))
    write(os.path.join(a.out, "menus_data.c"), menu_table(menus))
    print("make_fw_tables.py: %s, %d games on %d boards, %d files, %d DIP switches in the menus, "
          "%d start values of %d cores as in their menus"
          % (path, len(games), len({g["board"] for g in games}), sum(len(g["known"]) for g in games),
             sum(len(g["dips"]) for g in games), started, len(set().union(*boards.values()))))
    print("make_fw_tables.py: %s, %d menus of slots.txt, IFACE_TAG %s"
          % (os.path.join(a.out, "menus_data.c"), len(menus),
             " ".join("%d:%04x" % (b, t) for _, b, t, _ in menus)))


if __name__ == "__main__":
    main()
