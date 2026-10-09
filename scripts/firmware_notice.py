#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Writes the NOTICE file that accompanies a firmware image.

Usage: scripts/firmware_notice.py <fpga_companion.elf.map> <output file> <version>

The linker map says which object files ended up in the image. Every one of them has to belong
to a component below, each component names the licence texts it needs. An object file that no
component claims ends the script with exit code 1, so a new library cannot slip into a release
without its notice. Components that the build did not link stay out of the NOTICE.

Besides the licence texts, the NOTICE lists the copyright lines from the headers of the linked
source files, because the BSD-style licences ask for "the above copyright notice", and the
upstream licence files name only one of the holders.
"""

import os
import re
import subprocess
import sys
import textwrap

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT = os.path.join(ROOT, "external")
COMPANION = os.path.join(EXT, "FPGA-Companion")
SDK = os.path.join(EXT, "pico-sdk")
NEWLIB_VERSION = "4.4.0"  # the version of docs/licenses/newlib-<version>-COPYING.NEWLIB

# Each component: the name in the NOTICE, its place there ("order") and a short licence label
# for the contents, where its source lives (repository, and the submodule checkout whose commit
# is reported), a pattern for the object paths in the map, the licence texts, and a note.
# The list order matters: the first matching component claims a file, so the specific ones
# (a single file, a sub-library) come before the general ones.
# A text is a path relative to the repository root, or ("header", path) for the licence
# comment at the top of a source file, up to the end of that comment.
COMPONENTS = [
    {
        "name": "puff, the inflate routine in FPGA-Companion",
        "order": 2,
        "short": "Zlib",
        "url": "https://github.com/madler/zlib/tree/develop/contrib/puff",
        "checkout": None,
        "match": r"/external/FPGA-Companion/src/puff\.c\.o$",
        "licence": "zlib-style licence of Mark Adler",
        "texts": [("header", "external/FPGA-Companion/src/puff.h")],
    },
    {
        "name": "FatFs",
        "order": 3,
        "short": "FatFs licence",
        "url": "http://elm-chan.org/fsw/ff/",
        "checkout": None,
        "match": r"/external/FPGA-Companion/src/fatfs/",
        "licence": "FatFs licence (BSD-style, one clause)",
        "texts": ["external/FPGA-Companion/src/fatfs/LICENSE.txt"],
    },
    {
        "name": "MD5 by L. Peter Deutsch, part of rcheevos",
        "order": 5,
        "short": "Zlib",
        "url": "https://github.com/RetroAchievements/rcheevos",
        "checkout": "external/FPGA-Companion/src/rcheevos",
        "match": r"/external/FPGA-Companion/src/rcheevos/src/rhash/md5\.c\.o$",
        "licence": "zlib-style licence of Aladdin Enterprises",
        "texts": [("header", "external/FPGA-Companion/src/rcheevos/src/rhash/md5.c")],
    },
    {
        "name": "rcheevos",
        "order": 4,
        "short": "MIT",
        "url": "https://github.com/RetroAchievements/rcheevos",
        "checkout": "external/FPGA-Companion/src/rcheevos",
        "match": r"/external/FPGA-Companion/src/rcheevos/",
        "licence": "MIT",
        "texts": ["external/FPGA-Companion/src/rcheevos/LICENSE"],
    },
    {
        "name": "u8g2, with the font helvB08 (Adobe Helvetica Bold 8 from X11)",
        "order": 6,
        "short": "BSD-2-Clause, font under the X11 Adobe/DEC notice",
        "url": "https://github.com/olikraus/u8g2",
        "checkout": "external/FPGA-Companion/src/u8g2",
        "match": r"(^|/)libu8g2\.a\(|/external/FPGA-Companion/src/u8g2/",
        "licence": "BSD-2-Clause, the X11 fonts under the Adobe and DEC notice",
        "texts": ["external/FPGA-Companion/src/u8g2/LICENSE"],
    },
    {
        "name": "tusb_xinput",
        "order": 7,
        "short": "MIT",
        "url": "https://github.com/Ryzee119/tusb_xinput",
        "checkout": "external/FPGA-Companion/src/tusb_xinput",
        "match": r"/external/FPGA-Companion/src/tusb_xinput/",
        "licence": "MIT",
        "texts": ["external/FPGA-Companion/src/tusb_xinput/LICENSE"],
    },
    {
        "name": "FPGA-Companion, fork with the RetroAchievements client",
        "order": 1,
        "short": "Apache-2.0",
        "url": "https://github.com/scullymi/FPGA-Companion (branch game20k), "
               "fork of https://github.com/MiSTle-Dev/FPGA-Companion",
        "checkout": "external/FPGA-Companion",
        # the Companion's own files, the files of src/rp2040 that CMake names relative to the
        # build directory (bluetooth.c, mcu_hw.c, freertos_callbacks.c), and the tables that
        # scripts/build_companion.sh generates for it under build/firmware/gen
        "match": r"/external/FPGA-Companion/src/|^CMakeFiles/fpga_companion\.dir/[^/]+\.o$"
                 r"|/build/firmware/gen/[^/]+\.c\.o$",
        "licence": "Apache-2.0",
        "texts": ["external/FPGA-Companion/LICENSE"],
        "note": "Written by Till Harbaum, Stefan Voss and further contributors, the "
                "RetroAchievements client (src/ra_*), the menus of the cores (src/menus*) and "
                "the tables of both, generated from the ROM manifests and menu sources of "
                "game20k, Copyright (C) 2026 scullymi. "
                "{bluetooth}"
                "The image also holds the root certificate GTS Root R4 of Google Trust Services "
                "as data (https://pki.goog/repository/).",
    },
    {
        "name": "FreeRTOS kernel, port for the RP2350",
        "order": 9,
        "short": "BSD-3-Clause",
        "url": "https://github.com/raspberrypi/FreeRTOS-Kernel",
        "checkout": "external/FPGA-Companion/src/rp2040/FreeRTOS-Kernel",
        "match": r"^CMakeFiles/fpga_companion\.dir/FreeRTOS-Kernel/portable/ThirdParty/GCC/RP2350_ARM_NTZ/",
        "licence": "BSD-3-Clause",
        "texts": ["external/FPGA-Companion/src/rp2040/FreeRTOS-Kernel/portable/ThirdParty/GCC/RP2350_ARM_NTZ/LICENSE.md"],
    },
    {
        "name": "FreeRTOS kernel",
        "order": 8,
        "short": "MIT",
        "url": "https://github.com/raspberrypi/FreeRTOS-Kernel, Raspberry Pi's fork of "
               "https://github.com/FreeRTOS/FreeRTOS-Kernel",
        "checkout": "external/FPGA-Companion/src/rp2040/FreeRTOS-Kernel",
        "match": r"^CMakeFiles/fpga_companion\.dir/FreeRTOS-Kernel/",
        "licence": "MIT",
        "texts": ["external/FPGA-Companion/src/rp2040/FreeRTOS-Kernel/LICENSE.md"],
    },
    {
        "name": "cyw43-driver, with the firmware of the CYW43439 WiFi and Bluetooth chip",
        "order": 12,
        "short": "LICENSE.RP, Raspberry Pi devices only",
        "url": "https://github.com/georgerobotics/cyw43-driver",
        "checkout": "external/pico-sdk/lib/cyw43-driver",
        "match": r"/external/pico-sdk/lib/cyw43-driver/",
        "licence": "Raspberry Pi's licence for cyw43-driver (LICENSE.RP): use and redistribution "
                   "only together with Raspberry Pi semiconductor devices",
        "texts": ["external/pico-sdk/lib/cyw43-driver/LICENSE.RP"],
        "note": "The firmware blobs for the radio chip come from the driver's firmware directory "
                "and are distributed under the same licence.",
    },
    {
        "name": "BTstack",
        "order": 13,
        "short": "LICENSE.RP, Pico W and Pico 2 W only",
        "url": "https://github.com/bluekitchen/btstack",
        "checkout": "external/pico-sdk/lib/btstack",
        "match": r"/external/pico-sdk/lib/btstack/",
        "licence": "Raspberry Pi's licence for BTstack (LICENSE.RP) for use with Pico W, "
                   "Pico 2 W and products built on them, BlueKitchen's own licence below",
        "texts": ["external/pico-sdk/src/rp2_common/pico_btstack/LICENSE.RP",
                  "external/pico-sdk/lib/btstack/LICENSE"],
        "note": "This image is distributed under Raspberry Pi's licence, as part of a product "
                "built on the Raspberry Pi Pico 2 W and for use with it.",
    },
    {
        "name": "lwIP",
        "order": 14,
        "short": "BSD-3-Clause",
        "url": "https://savannah.nongnu.org/projects/lwip/",
        "checkout": "external/pico-sdk/lib/lwip",
        "match": r"/external/pico-sdk/lib/lwip/",
        "licence": "BSD-3-Clause",
        "texts": ["external/pico-sdk/lib/lwip/COPYING"],
    },
    {
        "name": "Mbed TLS",
        "order": 15,
        "short": "Apache-2.0",
        "url": "https://github.com/Mbed-TLS/mbedtls",
        "checkout": "external/pico-sdk/lib/mbedtls",
        "match": r"/external/pico-sdk/lib/mbedtls/",
        "licence": "Apache-2.0 OR GPL-2.0-or-later, used here under Apache-2.0",
        "texts": ["external/pico-sdk/lib/mbedtls/LICENSE"],
    },
    {
        "name": "printf of the Pico SDK (pico_printf) by Marco Paland",
        "order": 11,
        "short": "MIT",
        "url": "https://github.com/raspberrypi/pico-sdk",
        "checkout": "external/pico-sdk",
        "match": r"/external/pico-sdk/src/rp2_common/pico_printf/",
        "licence": "MIT",
        "texts": ["external/pico-sdk/src/rp2_common/pico_printf/LICENSE"],
    },
    {
        "name": "Raspberry Pi Pico SDK",
        "order": 10,
        "short": "BSD-3-Clause",
        "url": "https://github.com/raspberrypi/pico-sdk",
        "checkout": "external/pico-sdk",
        "match": r"/external/pico-sdk/src/",
        "licence": "BSD-3-Clause",
        "texts": ["external/pico-sdk/LICENSE.TXT"],
    },
    {
        "name": "Pico-PIO-USB",
        "order": 17,
        "short": "MIT",
        "url": "https://github.com/sekigon-gonnoc/Pico-PIO-USB",
        "checkout": "external/tinyusb/hw/mcu/raspberry_pi/Pico-PIO-USB",
        "match": r"/external/tinyusb/hw/mcu/raspberry_pi/Pico-PIO-USB/",
        "licence": "MIT",
        "texts": ["external/tinyusb/hw/mcu/raspberry_pi/Pico-PIO-USB/LICENSE"],
    },
    {
        "name": "TinyUSB",
        "order": 16,
        "short": "MIT",
        "url": "https://github.com/scullymi/tinyusb (branch game20k), fork of "
               "https://github.com/hathach/tinyusb",
        "checkout": "external/tinyusb",
        "match": r"/external/tinyusb/",
        "licence": "MIT",
        "texts": ["external/tinyusb/LICENSE"],
    },
    {
        "name": "newlib, the C library of the Arm GNU Toolchain",
        "order": 18,
        "short": "newlib licences",
        "url": "https://sourceware.org/newlib/",
        "checkout": None,
        "match": r"/arm-none-eabi/lib/.*/lib(g|c|c_nano|m|nosys)\.a\(",
        "licence": "several free licences, one per source file, collected in COPYING.NEWLIB",
        "texts": ["docs/licenses/newlib-%s-COPYING.NEWLIB" % NEWLIB_VERSION],
        "note": "The image contains memory allocation, string, conversion and time functions "
                "of newlib %s." % NEWLIB_VERSION,
    },
    {
        "name": "GCC runtime (libgcc and the crt files)",
        "order": 19,
        "short": "GPL-3.0 with GCC Runtime Library Exception",
        "url": "https://gcc.gnu.org/",
        "checkout": None,
        "match": r"/lib/gcc/arm-none-eabi/[^/]+/.*(libgcc\.a\(|/crt\w*\.o$)",
        "licence": "GPL-3.0 with the GCC Runtime Library Exception",
        "texts": [],
        "note": "The exception places no conditions on the firmware, which is the result of an "
                "eligible compilation process, so no licence text needs to accompany it.",
    },
]

# "Copyright (c) 2020 ...", "Copyright 2020 (c) ...", and without a year "Copyright The Mbed TLS
# Contributors", but not "the above copyright notice"
COPYRIGHT_LINE = re.compile(r"copyright\s*(\(c\)|©)?\s*(\(c\)\s*)?(\d{4}|the\s+\w)", re.IGNORECASE)


def field(label, value):
    """A "Label:  value" line, wrapped at 78 columns with the value column kept."""
    return textwrap.fill(label + value, 78, subsequent_indent=" " * len(label),
                         break_long_words=False, break_on_hyphens=False)


def die(msg):
    print("firmware_notice.py: " + msg, file=sys.stderr)
    sys.exit(1)


def read(rel):
    path = os.path.join(ROOT, rel)
    if not os.path.isfile(path):
        die("licence text missing: %s (submodules initialised?)" % rel)
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def header_comment(rel):
    """The first comment block of a source file, without the comment markers."""
    text = read(rel)
    m = re.match(r"\s*/\*(.*?)\*/", text, re.DOTALL)
    if not m:
        die("no licence comment at the top of %s" % rel)
    lines = [re.sub(r"^\s?\*? ?", "", l) for l in m.group(1).splitlines()]
    return "\n".join(lines).strip("\n") + "\n"


def linked_objects(map_path):
    """Input files that contribute at least one byte to the image, from the memory map part."""
    with open(map_path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    start = text.find("Linker script and memory map")
    if start < 0:
        die("%s has no memory map section" % map_path)
    objs = set()
    for line in text[start:].splitlines():
        # "<section> 0x<addr> 0x<size> <file>" or, after a long section name, the same without
        # the section on the next line
        m = re.match(r"\s+(?:\S+\s+)?0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S+)\s*$", line)
        if m and int(m.group(2), 16) > 0 and not m.group(3).startswith("0x"):
            objs.add(m.group(3))
    if not objs:
        die("no linked object files found in %s" % map_path)
    return objs


def source_of(obj, build_dir):
    """The source file an object came from, where it can be found, else None."""
    m = re.match(r"(?:.*/)?libu8g2\.a\((.+)\.o\)$", obj)
    if m:
        return os.path.join(COMPANION, "src", "u8g2", "csrc", m.group(1))
    m = re.match(r"CMakeFiles/fpga_companion\.dir/(.+)\.o$", obj)
    if not m:
        return None
    rel = m.group(1)
    candidates = ["/" + rel, os.path.join(build_dir, "..", rel)]
    for c in candidates:
        if os.path.isfile(c):
            return os.path.normpath(c)
    return None


def copyright_lines(sources):
    """Distinct copyright lines from the first 60 lines of the given source files."""
    found = []
    for src in sorted(sources):
        try:
            with open(src, encoding="utf-8", errors="replace") as f:
                head = [next(f) for _ in range(60)]
        except (OSError, StopIteration):
            try:
                with open(src, encoding="utf-8", errors="replace") as f:
                    head = f.readlines()[:60]
            except OSError:
                continue
        for line in head:
            if COPYRIGHT_LINE.search(line):
                clean = re.sub(r"^[\s/*#;!-]*", "", line).strip().rstrip("*/").strip()
                clean = re.sub(r"^SPDX-FileCopyrightText:\s*", "", clean)
                clean = re.sub(r"\s+", " ", clean)
                if clean and clean not in found:
                    found.append(clean)
    return found


def git_commit(rel):
    if rel is None:
        return None
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    try:
        out = subprocess.run(["git", "-C", os.path.join(ROOT, rel), "rev-parse", "HEAD"],
                             capture_output=True, text=True, env=env, check=True)
        return out.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def newlib_version_of(objs):
    """The newlib version of the toolchain that produced the image, from its _newlib_version.h."""
    for obj in objs:
        m = re.match(r"(.*)/arm-none-eabi/lib/.*/lib(g|c|c_nano)\.a\(", obj)
        if m:
            header = os.path.normpath(m.group(1) + "/arm-none-eabi/include/_newlib_version.h")
            try:
                with open(header) as f:
                    v = re.search(r'_NEWLIB_VERSION\s+"([^"]+)"', f.read())
                return v.group(1) if v else None
            except OSError:
                return None
    return None


def main():
    if len(sys.argv) != 4:
        die("usage: firmware_notice.py <fpga_companion.elf.map> <output file> <version>")
    map_path, out_path, version = sys.argv[1:]
    build_dir = os.path.dirname(os.path.abspath(map_path))
    objs = linked_objects(map_path)

    # assign every linked object to the first component that matches it
    claimed = {i: set() for i in range(len(COMPONENTS))}
    unclaimed = []
    for obj in sorted(objs):
        for i, comp in enumerate(COMPONENTS):
            if re.search(comp["match"], obj):
                claimed[i].add(obj)
                break
        else:
            unclaimed.append(obj)
    if unclaimed:
        die("no component claims these linked files, add them to COMPONENTS:\n  "
            + "\n  ".join(unclaimed))

    # the bundled newlib text must be the one of the toolchain in use
    if any(claimed[i] for i, c in enumerate(COMPONENTS) if c["name"].startswith("newlib")):
        tc = newlib_version_of(objs)
        if tc != NEWLIB_VERSION:
            die("the toolchain links newlib %s, docs/licenses/ holds the text of %s"
                % (tc, NEWLIB_VERSION))

    present = sorted((i for i in range(len(COMPONENTS)) if claimed[i]),
                     key=lambda i: COMPONENTS[i]["order"])
    rule = "=" * 78
    out = []
    title = "game20k firmware %s for the Raspberry Pi Pico 2 W" % version
    out += [title, "=" * len(title), ""]
    # BTstack is in the image only in a build with Bluetooth, the Pico 2 W build of game20k has
    # none: the header and the Companion's note name it only when the map has it
    btstack = any(COMPONENTS[i]["name"] == "BTstack" for i in present)
    rp_parts = "cyw43-driver and BTstack are" if btstack else "cyw43-driver is"
    for comp in COMPONENTS:
        if "{bluetooth}" in comp.get("note", ""):
            comp["note"] = comp["note"].replace("{bluetooth}",
                "src/rp2040/bluetooth.c is based on BTstack's examples spp_streamer_client.c and "
                "hid_host_demo.c, see BTstack below. " if btstack else "")
    out += [
        "This file accompanies the firmware image game20k-%s-pico2w.uf2. The image is" % version,
        "FPGA-Companion from https://github.com/scullymi/FPGA-Companion (branch game20k), built by",
        "https://github.com/scullymi/game20k at version %s. It contains the software listed" % version,
        "below, each part under its own licence. The source of every part is available from the",
        "repository named with it, at the commit given.",
        "",
        "USE ONLY ON A RASPBERRY PI PICO 2 W. %s licensed for use and" % rp_parts,
        "redistribution only together with Raspberry Pi semiconductor devices and products, see",
        "their sections." if btstack else "its section.",
        "",
        "Contents",
        "",
    ]
    for n, i in enumerate(present, 1):
        out.append("%3d. %s" % (n, COMPONENTS[i]["name"]))
        out.append("     " + COMPONENTS[i]["short"])
    out.append("")

    for n, i in enumerate(present, 1):
        comp = COMPONENTS[i]
        out += [rule, "%d. %s" % (n, comp["name"]), rule, ""]
        out.append(field("Source:  ", comp["url"]))
        commit = git_commit(comp["checkout"])
        if commit:
            out.append(field("Commit:  ", commit))
        out.append(field("Licence: ", comp["licence"]))
        k = len(claimed[i])
        out.append("Linked:  %d object file%s" % (k, "" if k == 1 else "s"))
        if comp.get("note"):
            out += ["", textwrap.fill(comp["note"], 78, break_long_words=False, break_on_hyphens=False)]
        sources = [s for s in (source_of(o, build_dir) for o in claimed[i]) if s]
        lines = copyright_lines(sources)
        if lines:
            out += ["", "Copyright lines in the linked source files:"]
            out += ["  " + l for l in lines]
        for t in comp["texts"]:
            if isinstance(t, tuple):
                out += ["", "Licence notice from %s:" % t[1].split("/", 1)[1], ""]
                out.append(header_comment(t[1]).rstrip("\n"))
            else:
                shown = t.split("/", 1)[1] if t.startswith("external/") else t
                out += ["", "Text of %s:" % shown, ""]
                out.append(read(t).rstrip("\n"))
        out.append("")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(out).rstrip("\n") + "\n")
    print("%s: %d components, %d linked object files, all claimed"
          % (out_path, len(present), len(objs)))


if __name__ == "__main__":
    main()
