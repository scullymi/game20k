#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Writes the NOTICE file that accompanies a firmware image.

Usage: scripts/firmware_notice.py <fpga_companion.elf.map> <output file> <version>
       scripts/firmware_notice.py <map> <output file> <version> --bl616 BOARD --sdk DIR --toolchain DIR

The linker map says which object files ended up in the image. Every one of them has to belong
to a component below, each component names the licence texts it needs. An object file that no
component claims ends the script with exit code 1, so a new library cannot slip into a release
without its notice. Components that the build did not link stay out of the NOTICE.

Besides the licence texts, the NOTICE lists the copyright lines from the headers of the linked
source files, because the BSD-style licences ask for "the above copyright notice", and the
upstream licence files name only one of the holders.

The BL616 firmware is linked with link-time optimisation, which merges the code of many object
files, so there the NOTICE follows the linker's input instead: every archive member and object
file the linker took in. An archive member of the build is traced to its source file through the
object file in the build folder, the Bouffalo SDK and the toolchain come as folders of their own
(--sdk, --toolchain). Many files of the SDK carry their own licence in their header: a component
marked "headers" adds each distinct licence header of its linked files.
"""

import argparse
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
# the folders of the Bouffalo SDK and of the RISC-V toolchain, set by --sdk and --toolchain
BFLB = None
RISCV = None

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
        "match": r"/external/FPGA-Companion/src/puff\.c(\.o)?$",
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
        "match": r"/external/FPGA-Companion/src/rcheevos/src/util/md5\.c(\.o)?$",
        "licence": "zlib-style licence of Aladdin Enterprises",
        "texts": [("header", "external/FPGA-Companion/src/rcheevos/src/util/md5.c")],
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
        # the Companion's own files, the files of src/rp2040 that CMake names relative to its
        # source folder (bluetooth.c, mcu_hw.c, freertos_callbacks.c), and the tables that
        # g20k.py firmware generates for it under build/firmware/gen
        "match": r"/external/FPGA-Companion/src/|^CMakeFiles/fpga_companion\.dir/[^/]+\.o$"
                 r"|/build/firmware/gen/[^/]+\.c(\.o)?$",
        "licence": "Apache-2.0",
        "texts": ["external/FPGA-Companion/LICENSE"],
        "note": "Written by Till Harbaum, Stefan Voss and further contributors, {client}"
                "the game switch, the menus of the cores (src/game20k) and "
                "the tables of the games and the menus, generated from the ROM manifests and menu sources of "
                "game20k, Copyright (C) 2026 scullymi. "
                "{bluetooth}{certificate}",
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
        "checkout": "external/Pico-PIO-USB",
        "match": r"/external/Pico-PIO-USB/",
        "licence": "MIT",
        "texts": ["external/Pico-PIO-USB/LICENSE"],
    },
    {
        "name": "TinyUSB",
        "order": 16,
        "short": "MIT",
        "url": "https://github.com/hathach/tinyusb",
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
    # The Bouffalo SDK of the BL616 firmware: "sdk:<path in the SDK>" for a source file,
    # "sdk:<archive>(<member>)" for a member of a library that comes built with the SDK
    {
        "name": "wpa_supplicant, in the Wi-Fi stack of the Bouffalo SDK",
        "order": 24,
        "short": "BSD-3-Clause",
        "url": "https://w1.fi/wpa_supplicant/",
        "sdk": True,
        "match": r"^sdk:components/wireless/wifi6/wpa_supplicant/",
        "licence": "BSD-3-Clause",
        "texts": ["sdk:components/wireless/wifi6/wpa_supplicant/COPYING"],
    },
    {
        "name": "Mbed TLS, in the Bouffalo SDK",
        "order": 23,
        "short": "Apache-2.0",
        "url": "https://github.com/Mbed-TLS/mbedtls",
        "sdk": True,
        "match": r"^sdk:components/crypto/mbedtls/",
        "licence": "Apache-2.0 OR GPL-2.0-or-later, used here under Apache-2.0",
        "texts": ["sdk:components/crypto/mbedtls/mbedtls_v3/LICENSE"],
        "headers": True,
    },
    {
        "name": "lwIP, in the Bouffalo SDK",
        "order": 22,
        "short": "BSD-3-Clause",
        "url": "https://savannah.nongnu.org/projects/lwip/",
        "sdk": True,
        "match": r"^sdk:components/net/lwip/",
        "licence": "BSD-3-Clause",
        "texts": ["sdk:components/net/lwip/lwip/COPYING"],
    },
    {
        "name": "FreeRTOS kernel, in the Bouffalo SDK",
        "order": 21,
        "short": "MIT",
        "url": "https://github.com/FreeRTOS/FreeRTOS-Kernel",
        "sdk": True,
        "match": r"^sdk:components/os/freertos/",
        "licence": "MIT",
        "texts": [("header", "sdk:components/os/freertos/tasks.c")],
    },
    {
        "name": "CherryUSB, in the Bouffalo SDK",
        "order": 25,
        "short": "Apache-2.0",
        "url": "https://github.com/cherry-embedded/CherryUSB",
        "sdk": True,
        "match": r"^sdk:components/usb/cherryusb/",
        "licence": "Apache-2.0, the text is in the section of the Bouffalo SDK",
        "texts": [],
    },
    {
        "name": "FatFs, in the Bouffalo SDK",
        "order": 26,
        "short": "FatFs licence",
        "url": "http://elm-chan.org/fsw/ff/",
        "sdk": True,
        "match": r"^sdk:components/fs/fatfs/",
        "licence": "FatFs licence (BSD-style, one clause), the port files under the SDK's licences",
        "texts": [],
        "headers": True,
    },
    {
        "name": "TLSF memory allocator by Matthew Conte, in the Bouffalo SDK",
        "order": 27,
        "short": "BSD-3-Clause",
        "url": "https://github.com/mattconte/tlsf",
        "sdk": True,
        "match": r"^sdk:components/mm/tlsf/tlsf\.c$",
        "licence": "BSD-3-Clause",
        "texts": [("header", "sdk:components/mm/tlsf/tlsf.h")],
    },
    {
        "name": "T-Head CSI DSP library, in the Bouffalo SDK (built, no source)",
        "order": 28,
        "short": "Apache-2.0",
        "url": "https://github.com/scullymi/bouffalo_sdk (drivers/lhal/include/arch/risc-v/t-head/csi_dsp)",
        "sdk": True,
        "match": r"^sdk:drivers/lhal/include/arch/risc-v/t-head/csi_dsp/",
        "licence": "Apache-2.0, the text is in the section of the Bouffalo SDK",
        "texts": [],
        "note": "Copyright (C) 2016-2020 T-head Limited, as its headers in the SDK say.",
    },
    {
        "name": "Bouffalo SDK",
        "order": 20,
        "short": "Apache-2.0, files with their own licence notices below",
        "url": "https://github.com/scullymi/bouffalo_sdk (branch game20k), fork of "
               "https://github.com/bouffalolab/bouffalo_sdk",
        "sdk": True,
        "match": r"^sdk:",
        "licence": "Apache-2.0 (the SDK's LICENSE), unless a file's header names another licence",
        "texts": ["sdk:LICENSE"],
        "headers": True,
        "note": "The Wi-Fi and radio libraries (libmacsw, libfhost, libbl616_phyrf, libpka) come "
                "built with the SDK, without source, under the SDK's licence. The image links "
                "them because the Companion's configuration of the SDK enables Wi-Fi.",
    },
    {
        "name": "picolibc, the C library of the RISC-V toolchain",
        "order": 30,
        "short": "BSD and similar licences",
        "url": "https://github.com/picolibc/picolibc",
        "toolchain": True,
        "match": r"/riscv64-unknown-elf/lib/[^(]*/lib(c|m)\.a\(",
        "licence": "several free licences, one per source file, collected in COPYING.picolibc",
        "texts": ["toolchain:share/licenses/picolibc/COPYING.picolibc"],
        "note": "COPYING.picolibc also lists a build script and test files under the GPL, "
                "none of them is part of the library.",
    },
    {
        "name": "GCC runtime (libgcc and the crt files)",
        "order": 31,
        "short": "GPL-3.0 with GCC Runtime Library Exception",
        "url": "https://gcc.gnu.org/",
        "checkout": None,
        "match": r"/lib/gcc/(arm-none-eabi|riscv64-unknown-elf)/[^/]+/.*(libgcc\.a\(|/crt\w*\.o$)",
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


def resolve(rel):
    """A path of COMPONENTS: in the repository, "sdk:" in the Bouffalo SDK, "toolchain:" in the
    RISC-V toolchain."""
    for prefix, base in (("sdk:", BFLB), ("toolchain:", RISCV)):
        if rel.startswith(prefix):
            if base is None:
                die("%s needs %s" % (rel, "--sdk" if prefix == "sdk:" else "--toolchain"))
            return os.path.join(base, rel[len(prefix):])
    return os.path.join(ROOT, rel)


def shown(rel):
    """How a path of COMPONENTS is named in the NOTICE."""
    if rel.startswith("sdk:"):
        return "the Bouffalo SDK's " + rel[4:]
    if rel.startswith("toolchain:"):
        return "the toolchain's " + rel[10:]
    return rel.split("/", 1)[1] if rel.startswith("external/") else rel


def read(rel):
    path = resolve(rel)
    if not os.path.isfile(path):
        die("licence text missing: %s (submodules initialised?)" % rel)
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def header_comment(rel):
    """The first comment block of a source file, without the comment markers."""
    text = read(rel)
    # the first C comment, after an include guard (TLSF), its lines may start with "**" or "/"
    m = re.match(r"\s*(?:#[^\n]*\n\s*)*/\*(.*?)\*/", text, re.DOTALL)
    if not m:
        die("no licence comment at the top of %s" % rel)
    lines = [re.sub(r"^\s?[*/]{0,2} ?", "", l) for l in m.group(1).splitlines()]
    return "\n".join(lines).strip("\n") + "\n"


# the words of a licence text in a file's header
LICENCE_TEXT = re.compile(r"Redistribution and use|Permission is hereby granted|Permission to use, copy|"
                          r"Licensed under the Apache License|SPDX-License-Identifier")


def licence_headers(sources):
    """The distinct licence comments at the top of the given source files, each with the files
    that carry it: a file's own name, date and copyright lines do not make it another one."""
    found = {}
    for src in sorted(sources):
        try:
            with open(src, encoding="utf-8", errors="replace") as f:
                text = f.read(20000)
        except OSError:
            continue
        m = re.match(r"\s*(/\*.*?\*/)", text, re.DOTALL)
        if not m or not LICENCE_TEXT.search(m.group(1)):
            continue
        lines = [re.sub(r"^\s?[*/]{0,2} ?", "", l).rstrip() for l in m.group(1)[2:-2].splitlines()]
        # an SPDX line alone names the licence, its text is elsewhere in the NOTICE
        if not re.search(LICENCE_TEXT.pattern.replace("|SPDX-License-Identifier", ""), m.group(1)):
            continue
        # compared from the licence text on, a file's description above it does not count
        first = next(i for i, l in enumerate(lines) if LICENCE_TEXT.search(l) or COPYRIGHT_LINE.search(l))
        key = "\n".join(l for l in lines[first:] if l.strip() and not COPYRIGHT_LINE.search(l)
                        and not re.search(r"@(file|date|version|brief|author)|\.[ch]\b|^[-=*]+$", l))
        found.setdefault(key, (lines, []))[1].append(src)
    return [(("\n".join(lines)).strip("\n"), files) for lines, files in found.values()]


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
            # the linker of the Windows toolchain writes some paths with backslashes
            objs.add(m.group(3).replace("\\", "/"))
    if not objs:
        die("no linked object files found in %s" % map_path)
    return objs


def source_of(obj):
    """The source file an object came from, where it can be found, else None."""
    # the keys of bl616_inputs(): a source in the SDK, or a source file itself
    if obj.startswith("sdk:") and "(" not in obj:
        return os.path.join(BFLB, obj[4:])
    if re.search(r"\.(c|cpp|S)$", obj) and os.path.isfile(obj):
        return obj
    m = re.match(r"(?:.*/)?libu8g2\.a\((.+)\.o\)$", obj)
    if m:
        return os.path.join(COMPANION, "src", "u8g2", "csrc", m.group(1))
    m = re.match(r"CMakeFiles/fpga_companion\.dir/(.+)\.o$", obj)
    if not m:
        return None
    rel = m.group(1)
    # CMake names an object by the source's absolute path, a drive as C_ on Windows, or relative
    # to the source folder
    drive = re.sub(r"^([A-Za-z])_/", r"\1:/", rel)
    candidates = [drive, "/" + rel, os.path.join(COMPANION, "src", "rp2040", rel)]
    for c in candidates:
        if os.path.isfile(c):
            return os.path.normpath(c)
    return None


def bl616_inputs(map_path):
    """Every archive member and object file the linker took in, as keys for COMPONENTS: a member
    of an archive of the build becomes its source file (in the SDK "sdk:<path>"), a member of an
    archive of the SDK "sdk:<archive>(<member>)", one of the toolchain keeps the map's path."""
    with open(map_path, encoding="utf-8", errors="replace") as f:
        text = f.read().replace("\\", "/")
    end = text.find("Discarded input sections")
    if end < 0:
        die("%s has no list of archive members" % map_path)
    build = os.path.dirname(os.path.dirname(os.path.abspath(map_path)))
    sdk = os.path.realpath(BFLB).replace("\\", "/") + "/"

    def in_sdk(path):
        """A path as a key: "sdk:<path in the SDK>", or the path itself. Windows may spell the
        drive in another case, so the comparison ignores it there."""
        path = os.path.realpath(path).replace("\\", "/")
        if os.path.normcase(path).startswith(os.path.normcase(sdk)):
            return "sdk:" + path[len(sdk):]
        return path
    # the object files of the build by the folder of their library and their name
    objects = {}
    for top, _, files in os.walk(build):
        lib = next((d[:-4] for d in reversed(top.replace("\\", "/").split("/")) if d.endswith(".dir")), None)
        for name in files:
            if lib and name.endswith(".obj"):
                objects.setdefault((lib, name), []).append(os.path.join(top, name))
    keys = set()

    def source_key(obj):
        rel = os.path.relpath(obj, build).replace("\\", "/")
        m = re.match(r"(?:build_out/(.+?)/)?CMakeFiles/[^/]+\.dir/(.+)\.obj$", rel)
        if not m:
            die("object file outside a CMake target folder: %s" % rel)
        base, rest = m.groups()
        if base is not None:  # a library of the SDK, its folder mirrors the SDK's
            return "sdk:%s/%s" % (base, rest)
        # the application: the source's absolute path, a drive as C_ on Windows, or a file of
        # the Companion's src/bl616 that CMake names relative to it
        for c in (re.sub(r"^([A-Za-z])_/", r"\1:/", rest), "/" + rest, os.path.join(COMPANION, "src", "bl616", rest)):
            if os.path.isfile(c):
                return in_sdk(c)
        die("no source found for the linked file %s" % rel)

    for archive, member in re.findall(r"^(\S+\.a)\(([^)]+)\)", text[:end], re.M):
        if archive.startswith("build_out/lib/"):
            lib = os.path.basename(archive)[:-2]
            found = objects.get((lib, member)) or objects.get((lib[3:], member))
            if not found:
                die("no object file in the build for %s(%s)" % (archive, member))
            keys.update(source_key(o) for o in found)
        else:
            key = in_sdk(archive)
            keys.add((key if key.startswith("sdk:") else archive) + "(%s)" % member)
    for obj in re.findall(r"^LOAD (\S+\.obj)$", text, re.M):
        keys.add(source_key(os.path.join(build, obj)))
    if not keys:
        die("no linked object files found in %s" % map_path)
    return keys


def tool_version(folder):
    """The version in the marker of a tool folder of g20k.py, else None."""
    try:
        with open(os.path.join(folder, ".g20k-tool.toml"), encoding="utf-8") as f:
            m = re.search(r'^version = "([^"]+)"', f.read(), re.M)
        return m.group(1) if m else None
    except OSError:
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
    global BFLB, RISCV
    ap = argparse.ArgumentParser(prog="firmware_notice.py")
    ap.add_argument("map")
    ap.add_argument("out")
    ap.add_argument("version")
    ap.add_argument("--bl616", metavar="BOARD", help="the BL616 firmware of this board")
    ap.add_argument("--sdk", help="the Bouffalo SDK the BL616 firmware was built with")
    ap.add_argument("--toolchain", help="the RISC-V toolchain whose libraries it links")
    args = ap.parse_args()
    if args.bl616 and not (args.sdk and args.toolchain):
        die("--bl616 needs --sdk and --toolchain")
    map_path, out_path, version = args.map, args.out, args.version
    if args.bl616:
        BFLB, RISCV = args.sdk, args.toolchain
        objs = bl616_inputs(map_path)
    else:
        objs = linked_objects(map_path)
    # an object without its source would lose its copyright lines without a word
    lost = sorted(o for o in objs if o.startswith("CMakeFiles/") and not source_of(o))
    if lost:
        die("no source found for these linked files:\n  " + "\n  ".join(lost))

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

    # The catch-all of the Bouffalo SDK takes every file of it without an entry of its own. A file
    # under the GPL must not go through it: one would change what the image may be given under
    if args.bl616:
        gpl = []
        for obj in objs:
            src = source_of(obj)
            try:
                with open(src, encoding="utf-8", errors="replace") as f:
                    head = f.read(6000)
            except (OSError, TypeError):
                continue
            if re.search(r"GNU (Lesser |Library )?General Public|SPDX-License-Identifier:[^\n]*GPL", head) \
                    and not re.search(r"SPDX-License-Identifier:\s*Apache-2\.0 OR GPL", head):
                gpl.append(obj)
        if gpl:
            die("these linked files name the GPL, check them:\n  " + "\n  ".join(sorted(gpl)))

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
    if args.bl616:
        board = {"m0sdock": "the Sipeed M0S Dock"}.get(args.bl616, "the Tang Nano 20K's onboard BL616")
        title = "game20k firmware %s for %s" % (version, board)
    else:
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
            # the BL616 firmware has no RetroAchievements and no TLS client of its own
            comp["note"] = comp["note"].replace("{client}", "" if args.bl616 else "the RetroAchievements client, ")
            if args.bl616:
                comp["name"] = "FPGA-Companion, game20k's fork"
            comp["note"] = comp["note"].replace("{certificate}", "" if args.bl616 else
                "The image also holds the root certificate GTS Root R4 of Google Trust Services "
                "as data (https://pki.goog/repository/).")
    if args.bl616:
        image = "game20k-%s-%s.bin" % (version, args.bl616)
        for para in (
            "This file accompanies the firmware image %s. The image is FPGA-Companion from "
            "https://github.com/scullymi/FPGA-Companion (branch game20k), built with the Bouffalo "
            "SDK by https://github.com/scullymi/game20k at version %s, without "
            "RetroAchievements. It contains the software listed below, each part under its own "
            "licence. The source of every part is available from the repository named with it, "
            "at the commit given, except for the libraries the Bouffalo SDK carries built." % (image, version),
            "The image is linked with link-time optimisation. The lists below name every file the "
            "linker took in, some of them may contribute no code to the image.",
        ):
            out += [textwrap.fill(para, 78, break_long_words=False, break_on_hyphens=False), ""]
        out += [
            "Contents",
            "",
        ]
    else:
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
        commit = git_commit(comp.get("checkout"))
        if comp.get("sdk"):
            commit = tool_version(BFLB)
        if commit:
            out.append(field("Commit:  ", commit))
        if comp.get("toolchain") and tool_version(RISCV):
            out.append(field("Version: ", "Bouffalo Lab's GCC %s" % tool_version(RISCV)))
        out.append(field("Licence: ", comp["licence"]))
        k = len(claimed[i])
        out.append("%s  %d object file%s" % ("Input: " if args.bl616 else "Linked:", k, "" if k == 1 else "s"))
        if comp.get("note"):
            out += ["", textwrap.fill(comp["note"], 78, break_long_words=False, break_on_hyphens=False)]
        sources = [s for s in (source_of(o) for o in claimed[i]) if s]
        lines = copyright_lines(sources)
        if lines:
            out += ["", "Copyright lines in the linked source files:"]
            out += ["  " + l for l in lines]
        for t in comp["texts"]:
            if isinstance(t, tuple):
                name = shown(t[1]) if t[1].startswith(("sdk:", "toolchain:")) else t[1].split("/", 1)[1]
                out += ["", "Licence notice from %s:" % name, ""]
                out.append(header_comment(t[1]).rstrip("\n"))
            else:
                out += ["", "Text of %s:" % shown(t), ""]
                out.append(read(t).rstrip("\n"))
        if comp.get("headers"):
            for text, files in licence_headers(sources):
                rels = sorted(os.path.relpath(f, BFLB).replace("\\", "/") if BFLB else f for f in files)
                where = rels[0] if len(rels) == 1 else "%s and %d more file%s" % (
                    rels[0], len(rels) - 1, "" if len(rels) == 2 else "s")
                out += ["", "Licence notice in the header of %s:" % where, "", text]
        out.append("")

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out).rstrip("\n") + "\n")
    print("%s: %d components, %d linked object files, all claimed"
          % (out_path, len(present), len(objs)))


if __name__ == "__main__":
    main()
