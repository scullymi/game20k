#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""@file make_menu.py
@brief Puts a core's OSD menu together and derives the core's interface tag from it.

Usage: scripts/make_menu.py <core> [<core> ...]     core folders under fpga/, e.g. galaga_hdmi

The menu is fpga/common/menu/base.xml with its gaps filled from fpga/<core>/menu_core.xml, see
the head of base.xml for the format. The Companion's firmware holds the menus of all cores,
scripts/make_fw_tables.py writes them with compose() and iface_tag() of this script. Here, at
every Gowin build (files.tcl), the script writes the menu to fpga/<core>/gen/menu.xml for a look
and the core's IFACE_TAG to fpga/<core>/gen/iface_pkg.sv, which ram_spi sends in the RAM mirror
header. The firmware takes its menu for the core only when the tags agree. The script stops on
an action the menu does not define and on a setting that the core's game_core.sv starts at
another value than the menu's default.

BUT: there is a second menu source, and it wins. If a file /config.xml lies on the SD card,
the Companion reads that one and leaves its built-in menu aside (FPGA-Companion src/main.c,
f_open on sys_get_config_name() first). Then a menu change has no effect no matter how often
you rebuild and flash, and only the debug UART tells: "Loading XML config from file" versus
"Loading the built-in XML config" (GP0, 921600 baud).
"""
import os
import re
import sys
import textwrap
import xml.etree.ElementTree as ET
import zlib
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = "fpga/common/menu/base.xml"
# the menu for a core the firmware has no menu for: base.xml without a core's part
BASIC = ({"title": "Unknown core", "name": "game20k", "ini": "unknown.ini", "rom": "", "fire": "0",
          "header": "game20k basic menu, for a core without a menu of its own in the firmware"},
         {"screen": ""})
# a whole line "<!--@...-->": a directive (slot, if, end) or, with a blank after the @, a note
DIRECTIVE = re.compile(r"^([ \t]*)<!--@((?:(?!-->).)*)-->\n", re.M | re.S)
# a block of the core's part: the tags on lines of their own, or one empty element
BLOCK = re.compile(r"^([ \t]*)<(\w+)>\n(.*?)^\1</\2>\n|^[ \t]*<(\w+)/>\n", re.M | re.S)


def fail(msg):
    sys.exit("make_menu.py: " + msg)


def read(rel):
    try:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        fail("%s: %s" % (rel, e.strerror))


def core_part(core):
    """The attributes of <core> in fpga/<core>/menu_core.xml and the text of its elements."""
    rel = "fpga/%s/menu_core.xml" % core
    text = read(rel)
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        fail("%s: %s" % (rel, e))
    if root.tag != "core":
        fail("%s: the root element is <%s>, not <core>" % (rel, root.tag))
    blocks = {}
    for m in BLOCK.finditer(text):
        blocks[m.group(2) or m.group(4)] = m.group(3) or ""
    tags = [e.tag for e in root]
    if sorted(tags) != sorted(blocks) or len(set(tags)) != len(tags):
        fail("%s: each element of <core> once, its tags on lines of their own or as <name/>" % rel)
    return dict(root.attrib), blocks


def compose(core, part=None):
    """The menu of a core as text, from base.xml and the core's part, or part (attributes and
    blocks as core_part() returns them) for a menu without a core folder."""
    attrs, blocks = part or core_part(core)
    text = read(BASE)
    used = set()

    def fill(s):
        # {key} from the attributes, escaped as an attribute value
        def one(m):
            if m.group(1) not in attrs:
                fail("%s needs the attribute %s in fpga/%s/menu_core.xml"
                     % (BASE, m.group(1), core))
            used.add(m.group(1))
            return escape(attrs[m.group(1)], {'"': "&quot;"})
        return re.sub(r"\{(\w+)\}", one, s)

    out, pos, block = [], 0, None
    for m in DIRECTIVE.finditer(text):
        lead, words = m.group(1), m.group(2).split()
        part, pos = text[pos:m.start()], m.end()
        if m.group(2)[:1].isspace():
            # a note of the template: the text before it counts, the note does not
            if block:
                block[3].append(part)
            else:
                out.append(fill(part))
        elif len(words) == 2 and words[0] in ("slot", "if") and not block:
            out.append(fill(part))
            block = (words[0], words[1], lead, [])
        elif words == ["end"] and block:
            kind, name, lead, body = block
            body = "".join(body) + part
            if kind == "slot" and name in blocks:
                # the core's lines, indented like the slot
                used.add(name)
                out.append(textwrap.indent(textwrap.dedent(blocks[name]), lead))
            elif kind == "slot":
                out.append(fill(body))
            elif name in attrs:
                used.add(name)
                out.append(fill(body))
            block = None
        else:
            line = text.count("\n", 0, m.start()) + 1
            inside = " inside <!--@%s %s-->" % block[:2] if block else ""
            fail("%s:%d: unexpected <!--@%s-->%s" % (BASE, line, m.group(2), inside))
    if block:
        fail("%s: <!--@%s %s--> has no <!--@end-->" % (BASE, block[0], block[1]))
    out.append(fill(text[pos:]))
    if "<!--@" in "".join(out):
        fail("%s: a <!--@...--> that is not a line of its own" % BASE)
    unknown = (set(attrs) | set(blocks)) - used
    if unknown:
        fail("fpga/%s/menu_core.xml: %s fills no gap of %s" % (core, ", ".join(sorted(unknown)), BASE))
    return "".join(out)


def check(core, xml):
    """Stops on a menu the Companion cannot read or would show with buttons that do nothing."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as e:
        fail("fpga/%s/gen/menu.xml: %s" % (core, e))
    # Every action a button, list or link names must be defined under <actions>, with or
    # without commands. config_get_action() in the Companion resolves an unknown name to NULL,
    # and the element then does nothing, without any message on the device.
    defined = {a.get("name") for a in root.iter("action")}
    missing = sorted({'%s action="%s"' % (e.tag, e.get("action")) for e in root.iter()
                      if e.get("action") is not None and e.get("action") not in defined})
    if missing:
        fail("fpga/%s/gen/menu.xml names actions that <actions> does not define: %s"
             % (core, ", ".join(missing)))


def check_core_defaults(core, xml):
    """Stops when the core starts a menu setting at another value than the menu's default.
    The core holds its start values until the Companion sends the saved ones, a difference
    would show a setting in the menu that the game does not run with. Returns the number of
    settings compared."""
    rel = "fpga/%s/src/game_core.sv" % core
    sv = re.sub(r"//[^\n]*", "", read(rel))
    defaults = {e.get("id"): e.get("default") for e in ET.fromstring(xml).iter("list")}
    # the settings the core takes: '"L": lives <= cfg_val...' in a case on cfg_id, or
    # 'cfg_id == "K") loop_btn <= ...'
    taken = (re.findall(r'"(\w)"\s*:\s*(\w+)\s*<=', sv)
             + re.findall(r'cfg_id\s*==\s*"(\w)"\s*\)\s*(\w+)\s*<=', sv))
    if not taken:
        fail("%s: no menu setting found (cfg_id)" % rel)
    for key, var in taken:
        # its declaration with the start value, "logic [1:0] lives = 2'd2;"
        m = re.search(r"^\s*logic\b[^;]*?\b%s\s*=\s*\d*'([bdh])([0-9a-fA-F_]+)" % var, sv, re.M)
        if not m:
            fail("%s: no start value for %s, the setting %s" % (rel, var, key))
        start = int(m.group(2).replace("_", ""), {"b": 2, "d": 10, "h": 16}[m.group(1)])
        if key not in defaults:
            fail("%s: the setting %s (%s) is not in the menu" % (rel, key, var))
        if defaults[key] is None or int(defaults[key]) != start:
            fail("%s: %s starts at %d, the menu's default of %s is %s"
                 % (rel, var, start, key, defaults[key]))
    return len(taken)


def iface_tag(core):
    """IFACE_TAG of a core: what core and firmware must agree on, as 16 bits. Today that is the
    menu, the id and the values of every setting it sends (base.xml and the core's part), and
    the labels of the core's part, which say what a value means to the core (Lives: value 2 is
    "3"). Defaults, order, comments and titles change nothing the core decodes and stay out. A
    further contract between core and firmware adds its lines to the same text. The sum is
    zlib.crc32 as for the ROM footer of make_rom.py, cut to 16 bits."""
    def lines(root, labels):
        # a line per id and value, with labels also one per label. Sorted: the order is no part
        out = set()
        for e in root.iter():
            i = e.get("id")
            if i is None:
                continue
            if e.get("value") is not None:
                out.add("%s=%s" % (i, e.get("value")))
            if labels and e.get("label") is not None:
                out.add("%s:%s" % (i, e.get("label")))
            for x in e.iter("listentry"):
                out.add("%s=%s" % (i, x.get("value")))
                if labels:
                    out.add("%s=%s:%s" % (i, x.get("value"), x.get("label")))
        return sorted(out)
    attrs, _ = core_part(core)
    part = ET.fromstring(read("fpga/%s/menu_core.xml" % core))
    text = ["menu"] + lines(ET.fromstring(compose(core)), False) + ["core"] + lines(part, True)
    # the label of the second button's list K in base.xml comes from the core
    if "button2" in attrs:
        text.append("K:" + attrs["button2"])
    return zlib.crc32("\n".join(text).encode("utf-8")) & 0xFFFF


def iface_pkg(core, tag):
    """gen/iface_pkg.sv of a core: its IFACE_TAG as a package for the top level."""
    return ("// Generated by scripts/make_menu.py from %s and fpga/%s/menu_core.xml. Do not edit.\n"
            "// The interface tag of %s, RAM mirror header bytes 16 and 17, see make_menu.py.\n"
            "package iface_pkg;\n"
            "    localparam logic [15:0] IFACE_TAG = 16'h%04x;\n"
            "endpackage\n" % (BASE, core, core, tag))


def write(rel, text):
    """Writes the file unless it holds this text already, so its date tells when it changed."""
    path = os.path.join(ROOT, rel)
    if os.path.isfile(path):
        with open(path, encoding="utf-8", newline="") as f:
            if f.read() == text:
                return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def main():
    if len(sys.argv) < 2:
        fail("usage: make_menu.py <core> [<core> ...]")
    for core in sys.argv[1:]:
        xml = compose(core)
        write("fpga/%s/gen/menu.xml" % core, xml)
        check(core, xml)
        check_core_defaults(core, xml)
        tag = iface_tag(core)
        write("fpga/%s/gen/iface_pkg.sv" % core, iface_pkg(core, tag))
        print("make_menu.py: fpga/%s/gen/iface_pkg.sv, IFACE_TAG 0x%04x" % (core, tag))


if __name__ == "__main__":
    main()
