#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""@file make_rom.py
@brief Builds the ROM file of a game from its MAME set, as a ROM manifest describes it.

Usage:
  scripts/make_rom.py <manifest> [output]        build, default output sdcard/<set>.rom
  scripts/make_rom.py --package <manifest> <out> write the section table for rom_loader
                                                 as a SystemVerilog package (build.tcl),
                                                 with the board id (BOARD_ID) and the RAM
                                                 mirror size (MIRROR_DATA) of the game
  scripts/make_rom.py --list                     the manifests under fpga/, one per line

The manifest (fpga/<core>/<set>.manifest) names every chip, its size and its SHA-1 as MAME
lists it, the order in the file and the finished size, plus the board id and the RAM mirror
size the core announces to the firmware. The format is described in the head of
fpga/galaga_hdmi/galaga.manifest. Normally scripts/make_sdcard.sh calls this script.

Sources live in roms/ (gitignored), the result in sdcard/ (*.rom is gitignored too). Both
contain ROM data and never leave this machine, except onto the card.

Every chip is checked by size and SHA-1 before anything is written: a set of the right sizes
but another revision, or a patched one, stops here. On the device it would show up nowhere,
the loader takes any file of the right size.

Exit status 0 when the file was written, 1 when the set is missing or wrong, 2 on wrong usage.
"""
import glob
import hashlib
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# the RAM mirror package of the FPGA platform: the unit and the bound of a game's mirror size
PKG = os.path.join(ROOT, "fpga", "common", "src", "mcu", "ram_mirror_pkg.sv")


class ManifestError(Exception):
    """The manifest itself is malformed. The message names file and line."""


def mirror_bounds():
    """RAM_MIRROR_PAGE and RAM_MIRROR_DATA_MAX of ram_mirror_pkg.sv: the unit of header byte
    14 and the most a core may announce. Read from the package, so no copy of either number
    lives here; without them a manifest cannot be judged, which is a ManifestError."""
    try:
        with open(PKG, encoding="utf-8") as fh:
            found = dict(re.findall(r"\blocalparam\s+int\s+RAM_MIRROR_(PAGE|DATA_MAX)\s*=\s*(\d+)\s*;", fh.read()))
    except OSError:
        raise ManifestError("%s: cannot be read, the mirror bounds are unknown" % PKG)
    if "PAGE" not in found or "DATA_MAX" not in found:
        raise ManifestError("%s: no localparam int RAM_MIRROR_PAGE or RAM_MIRROR_DATA_MAX" % PKG)
    return int(found["PAGE"]), int(found["DATA_MAX"])


def read_manifest(path):
    """Parse a manifest into a dict: set, title, zip, total, board, mirror, sections, notes,
    known.

    sections is a list of dicts {name, offset, size, chips}, chips a list of dicts
    {name, size, sha1, zip, optional}, known a list of (sha256, label). The layout, the
    board id and the mirror size are checked here, so every user of the manifest (this
    script, check_contracts.py) sees the same verdict.
    """
    m = {"path": path, "sections": [], "notes": {}, "known": []}
    with open(path, encoding="utf-8") as fh:
        for no, raw in enumerate(fh, 1):
            words = raw.split("#", 1)[0].split()
            if not words:
                continue
            where = "%s:%d" % (path, no)
            key, args = words[0], words[1:]
            try:
                if key in ("set", "zip") and len(args) == 1:
                    m[key] = args[0]
                elif key == "title" and args:
                    m["title"] = " ".join(args)
                elif key in ("total", "board", "mirror") and len(args) == 1:
                    m[key] = int(args[0], 0)
                elif key == "section" and len(args) == 3:
                    m["sections"].append({"name": args[0], "offset": int(args[1], 0),
                                          "size": int(args[2], 0), "chips": []})
                elif key == "chip" and len(args) >= 3 and m["sections"]:
                    chip = {"name": args[0], "size": int(args[1], 0), "sha1": args[2].lower(),
                            "zip": None, "optional": False}
                    for opt in args[3:]:
                        if opt.startswith("zip="):
                            chip["zip"] = opt[4:]
                        elif opt == "optional":
                            chip["optional"] = True
                        else:
                            raise ManifestError("%s: unknown chip option %s" % (where, opt))
                    m["sections"][-1]["chips"].append(chip)
                elif key == "note" and len(args) >= 2:
                    m["notes"][args[0]] = " ".join(args[1:])
                elif key == "known" and len(args) >= 2:
                    # the firmware shows the label next to "board N, " in its version dialog
                    label = " ".join(args[1:])
                    if len(label) > 16:
                        raise ManifestError("%s: known label '%s' has %d characters, at most 16"
                                            % (where, label, len(label)))
                    m["known"].append((args[0].lower(), label))
                else:
                    raise ManifestError("%s: cannot read '%s'" % (where, raw.strip()))
            except ValueError:
                raise ManifestError("%s: not a number in '%s'" % (where, raw.strip()))

    # The layout must be gapless and add up: rom_loader decodes by offset, the ROM file is
    # the chips one after another. A mismatch between the two would load garbage silently.
    for key in ("set", "zip", "total", "board", "mirror"):
        if key not in m:
            raise ManifestError("%s: no '%s' line" % (path, key))
    # The board id goes out in header byte 12 with its complement in 13: 0 tells the firmware
    # "no header read" and 255 would pass a stuck line, so neither names a board.
    if not 1 <= m["board"] <= 254:
        raise ManifestError("%s: board %d, a board id is 1..254" % (path, m["board"]))
    # The mirror size goes out in header byte 14 in pages of RAM_MIRROR_PAGE bytes, at most
    # RAM_MIRROR_DATA_MAX, both read from ram_mirror_pkg.sv (the firmware carries the same
    # values, scripts/check_contracts.py compares them and checks this bound once more). The
    # FPGA build runs this script alone, so the bound holds here. A core with less RAM pads.
    page, data_max = mirror_bounds()
    if m["mirror"] % page or not 0 < m["mirror"] <= data_max:
        raise ManifestError("%s: mirror %d, the mirror size is a multiple of RAM_MIRROR_PAGE %d up to "
                            "RAM_MIRROR_DATA_MAX %d (ram_mirror_pkg.sv)" % (path, m["mirror"], page, data_max))
    pos = 0
    for s in m["sections"]:
        if s["offset"] != pos:
            raise ManifestError("%s: section %s starts at 0x%X, the previous one ends at 0x%X"
                                % (path, s["name"], s["offset"], pos))
        if sum(c["size"] for c in s["chips"]) != s["size"]:
            raise ManifestError("%s: the chips of section %s do not add up to %d bytes"
                                % (path, s["name"], s["size"]))
        pos += s["size"]
    if pos != m["total"]:
        raise ManifestError("%s: the sections add up to %d bytes, total says %d"
                            % (path, pos, m["total"]))
    return m


def manifests():
    """Every manifest of every core, sorted."""
    return sorted(glob.glob(os.path.join(ROOT, "fpga", "*", "*.manifest")))


def read_chip(zips, chip, default_zip):
    """Content of one chip from its zip in roms/, or None when zip or member is missing.

    Members are matched by their base name: a merged set keeps its files at the top level,
    but a repacked zip may have a folder in front.
    """
    zpath = os.path.join(ROOT, "roms", chip["zip"] or default_zip)
    if zpath not in zips:
        zips[zpath] = zipfile.ZipFile(zpath) if os.path.isfile(zpath) else None
    z = zips[zpath]
    if z is None:
        return None
    hits = [i for i in z.infolist() if os.path.basename(i.filename) == chip["name"]]
    if not hits:
        return None
    data = z.read(hits[0])
    # the same name twice with different content: which one is meant cannot be decided
    if any(z.read(h) != data for h in hits[1:]):
        raise ManifestError("%s holds %s more than once, with different content" % (zpath, chip["name"]))
    return data


def build(m, out):
    """Assemble the file, checking every chip. Returns (sha256, known label or None, warnings)."""
    zips, parts, warnings = {}, [], []
    for s in m["sections"]:
        for c in s["chips"]:
            data = read_chip(zips, c, m["zip"])
            # a missing optional chip becomes zeros; the firmware knows that file too
            if data is None and c["optional"]:
                data = bytes(c["size"])
                warnings.append("%s is missing (roms/%s), filled with zeros: %s"
                                % (c["name"], c["zip"] or m["zip"],
                                   m["notes"].get(c["name"], "that part of the game is missing")))
            elif data is None:
                raise ManifestError("%s is missing from roms/%s, wrong or incomplete ROM set?"
                                    % (c["name"], c["zip"] or m["zip"]))
            elif len(data) != c["size"]:
                raise ManifestError("%s has %d bytes, expected %d. Wrong ROM set?"
                                    % (c["name"], len(data), c["size"]))
            elif hashlib.sha1(data).hexdigest() != c["sha1"]:
                raise ManifestError("%s differs from MAME's set %s (SHA-1), wrong revision or modified?"
                                    % (c["name"], m["set"]))
            parts.append(data)
    blob = b"".join(parts)
    if len(blob) != m["total"]:
        raise ManifestError("assembled %d bytes, expected %d" % (len(blob), m["total"]))
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(blob)
    digest = hashlib.sha256(blob).hexdigest()
    label = next((lbl for sha, lbl in m["known"] if sha == digest), None)
    return digest, label, warnings


def write_package(m, out):
    """gen/rom_map_pkg.sv: the board id and the RAM mirror size the core announces in the
    header (ram_spi.sv), then total size, number of sections and their offsets, the
    parameters of rom_loader.sv. Written only when the content changes, so an unchanged
    manifest does not touch the file's time stamp."""
    offs = [s["offset"] for s in m["sections"]]
    if len(offs) > 16:
        raise ManifestError("%s: %d sections, rom_loader takes at most 16" % (m["path"], len(offs)))
    lines = ["// Generated by scripts/make_rom.py from %s. Do not edit." % os.path.relpath(m["path"], ROOT),
             "// Board id and RAM mirror size of %s for ram_spi.sv, its ROM layout for" % m["set"],
             "// rom_loader.sv, see the manifest.",
             "package rom_map_pkg;",
             "    // header byte 12 of the RAM mirror: which board this core is to the firmware",
             "    localparam logic [7:0] BOARD_ID = 8'd%d;" % m["board"],
             "    // game RAM bytes in the RAM mirror before the oracle log, header byte 14 x RAM_MIRROR_PAGE",
             "    localparam int MIRROR_DATA = %d;" % m["mirror"],
             "    localparam int ROM_TOTAL    = %d;" % m["total"],
             "    localparam int ROM_SECTIONS = %d;" % len(offs),
             "    // section 0 in the lowest 16 bits",
             "    localparam logic [16*16-1:0] ROM_OFFSETS = {"]
    words = ["16'h%04X" % o for o in reversed(offs)]
    lines += ["        " + ", ".join(words[i:i + 6]) + ("," if i + 6 < len(words) else "")
              for i in range(0, len(words), 6)]
    lines += ["    };", "endpackage", ""]
    text = "\n".join(lines)
    if os.path.isfile(out) and open(out, encoding="utf-8").read() == text:
        return
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(text)


def main(argv):
    if len(argv) == 2 and argv[1] == "--list":
        print("\n".join(os.path.relpath(p, ROOT) for p in manifests()))
        return 0
    if len(argv) == 4 and argv[1] == "--package":
        try:
            write_package(read_manifest(argv[2]), argv[3])
        except (ManifestError, OSError) as e:
            print("make_rom.py: %s" % e, file=sys.stderr)
            return 1
        return 0
    if len(argv) not in (2, 3) or argv[1].startswith("-"):
        print(__doc__)
        return 2
    try:
        m = read_manifest(argv[1])
        out = argv[2] if len(argv) == 3 else os.path.join(ROOT, "sdcard", m["set"] + ".rom")
        if not os.path.isfile(os.path.join(ROOT, "roms", m["zip"])):
            raise ManifestError("missing: roms/%s (MAME set %s, as a merged set)" % (m["zip"], m["set"]))
        digest, label, warnings = build(m, out)
    except (ManifestError, OSError, zipfile.BadZipFile) as e:
        print("make_rom.py: %s" % e, file=sys.stderr)
        return 1
    for w in warnings:
        print("WARNING: %s" % w, file=sys.stderr)
    print("written: %s (%d bytes)" % (out, m["total"]))
    # The firmware allows hardcore only for a file it knows (ra_patch.c, ROM digests).
    if label:
        print("known ROM file, %s: hardcore possible" % label)
    else:
        print("WARNING: unknown ROM file %s, the firmware will stay in softcore" % digest[:16],
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
