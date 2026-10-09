#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""@file make_menu.py
@brief Puts a core's OSD menu together and packs it into the form the FPGA keeps on hand.

Usage: scripts/make_menu.py <core> [<core> ...]     core folders under fpga/, e.g. galaga_hdmi

The menu is fpga/common/menu/base.xml with its gaps filled from fpga/<core>/menu_core.xml, see
the head of base.xml for the format. The script writes the result to fpga/<core>/gen/menu.xml
and its gzip as one hex byte per line to fpga/<core>/menu_xml.hex, which
fpga/common/src/mcu/menu_rom.v reads with $readmemh (2048 bytes of room). files.tcl runs it at
every Gowin build. The Companion fetches the menu from the FPGA over SPI at startup. The script
stops on an action the menu does not define and on a setting that the core's game_core.sv starts
at another value than the menu's default.

BUT: there is a second menu source, and it wins. If a file /config.xml lies on the SD card,
the Companion reads that one and leaves the menu in the bitstream untouched (FPGA-Companion
src/main.c, f_open on sys_get_config_name() BEFORE the fallback to the core). Then a menu change
has no effect no matter how often you rebuild and flash, and the device shows no sign of it.
The only hint goes to the debug UART: "Loading XML config from file" versus "Loading XML config
from core" (GP0, 921600 baud).
"""
import os
import re
import struct
import sys
import textwrap
import xml.etree.ElementTree as ET
import zlib
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = "fpga/common/menu/base.xml"
ROOM = 2048        # bytes of menu_rom.v
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


def compose(core):
    """The menu of a core as text, from base.xml and the core's part."""
    attrs, blocks = core_part(core)
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


def pack(xml):
    """The gzip of the menu, byte for byte what gzip -9 -n writes on macOS: zlib level 9, no
    name, no time, OS 3."""
    data = xml.encode("utf-8")
    z = zlib.compressobj(9, zlib.DEFLATED, -15)
    return (b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03" + z.compress(data) + z.flush()
            + struct.pack("<II", zlib.crc32(data), len(data)))


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
        gz = pack(xml)
        if len(gz) > ROOM:
            fail("fpga/%s: menu too large, %d bytes packed, %d fit (fpga/common/src/mcu/menu_rom.v)"
                 % (core, len(gz), ROOM))
        write("fpga/%s/menu_xml.hex" % core, "\n".join("%02x" % b for b in gz) + "\n")
        print("make_menu.py: fpga/%s/menu_xml.hex, %d of %d bytes" % (core, len(gz), ROOM))


if __name__ == "__main__":
    main()
