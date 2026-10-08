#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""@file make_rom.py
@brief Builds the ROM file of a game from its MAME set, as a ROM manifest describes it.

Usage:
  scripts/make_rom.py <manifest> [output]        build, default output sdcard/<set>.rom
  scripts/make_rom.py --package <manifest> <out> [<manifest> ...]
                                                 write the section table for rom_loader
                                                 as a SystemVerilog package (build.tcl),
                                                 with the board id (BOARD_ID) and the RAM
                                                 mirror size (MIRROR_DATA) of the game.
                                                 Further manifests are sets of the same
                                                 board whose file is a prefix of the first
                                                 one's layout. The first one's size is the
                                                 largest file the loader takes (ROM_TOTAL).
                                                 The screen lines of all of them give the
                                                 screen values (SCREEN_*, HDR_SEC, FB_*)
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
# gfx_sort values of JTFRAME's mem.yaml that arrange() knows: (lowest sorted address bit, number
# of V bits). The x suffixes are the bits below, which stay. jtframe_dwnld.v: hvvvx is gfx4
# with GFX8B0=1, hvvvvxx is gfx16c with GFX16B0=2.
GFX_SORT = {"hvvvx": (1, 3), "hvvvvxx": (2, 4)}
# derive= of a chip: one 4-bit colour table of 256 entries from a palette PROM with one byte
# in 3/3/2 per colour, repeated to fill the table. The bits are the ones jt1942_colmix.v
# widens Higemaru's palette with: red {b2,b1,b0,b2}, green {b5,b4,b3,b5}, blue {b7,b6,b7,b6}.
# the screen line of a manifest: how the core's raster stands on the monitor. The code is
# byte 2 of a header section and SCREEN_DEFAULT in rom_map_pkg, screen_sel.sv decodes it.
SCREEN = {"upright": 0, "cw": 1, "ccw": 2}
# byte of a header section that make_rom.py writes with the screen code
HDR_SCREEN_BYTE = 2
DERIVE = {"r332": lambda b: ((b & 7) << 1) | ((b >> 2) & 1),
          "g332": lambda b: (((b >> 3) & 7) << 1) | ((b >> 5) & 1),
          "b332": lambda b: (((b >> 6) & 3) << 2) | ((b >> 6) & 3)}
# kabuki= of a section: the program decrypted ahead for a Kabuki Z80 (Capcom's Mitchell
# board), as data reads or as opcode fetches see it. The keys are the manifest's kabuki line.
KABUKI = ("data", "op")


def kabuki_byte(src, swap1, swap2, xor, sel):
    """One byte through Kabuki's decryption, after jotego's jtframe_kabuki.v (MAME kabuki.cpp
    does the same): four bit pair swaps chosen by bits of sel, rotations and an XOR."""
    def swap(d, nibbles, s):
        # pairs 7:6, 5:4, 3:2, 1:0, each swapped when the bit of s its key nibble names is set
        for lo, nib in zip((6, 4, 2, 0), nibbles):
            if (s >> nib) & 1:
                d = (d & ~(3 << lo)) | (((d >> lo) & 1) << (lo + 1)) | (((d >> (lo + 1)) & 1) << lo)
        return d
    def fwd(k):    # bitswap1: key nibbles 3, 2, 1, 0 on the pairs from the top
        return [(k >> 12) & 7, (k >> 8) & 7, (k >> 4) & 7, k & 7]
    def rev(k):    # bitswap2: the same nibbles in the other order
        return fwd(k)[::-1]
    rol = lambda d: ((d << 1) | (d >> 7)) & 0xFF
    d = rol(swap(src, fwd(swap1 & 0xFFFF), sel & 0xFF))
    d = rol(swap(d, rev(swap1 >> 16), sel & 0xFF) ^ xor)
    d = rol(swap(d, rev(swap2 & 0xFFFF), sel >> 8))
    return swap(d, fwd(swap2 >> 16), sel >> 8)


def kabuki(data, keys, mode):
    """The bytes of a kabuki= section, decrypted. Byte o is seen by the Z80 at o below 0x8000
    and in the 16 KiB bank window at 0x8000 + (o & 0x3FFF) above, which is how the Mitchell
    board maps its program ROM. Kabuki keys the decryption to that address: an opcode fetch
    with address + addr_key, a data read with (address ^ 0x1FC0) + addr_key + 1."""
    swap1, swap2, akey, xor = keys
    out = bytearray(len(data))
    for o, b in enumerate(data):
        a = o if o < 0x8000 else 0x8000 | (o & 0x3FFF)
        sel = (a + akey) if mode == "op" else ((a ^ 0x1FC0) + akey + 1)
        out[o] = kabuki_byte(b, swap1, swap2, xor, sel & 0xFFFF)
    return bytes(out)


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
    """Parse a manifest into a dict: set, title, zip, total, board, mirror, screen, sections,
    notes, known, and kabuki (the four keys) when the manifest has a kabuki line.

    screen is the code of SCREEN. sections is a list of dicts {name, offset, size, chips,
    header, ...}, chips a list of dicts
    {name, size, sha1, zip, optional, derive, out} for a chip of the set, {fill, out} for
    filler bytes or {data, out} for literal bytes, out being the bytes it takes in the file.
    known a list of (sha256, label). The layout, the
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
                elif key == "screen" and len(args) == 1:
                    if args[0] not in SCREEN:
                        raise ManifestError("%s: screen %s, it is upright, cw or ccw" % (where, args[0]))
                    m["screen"] = SCREEN[args[0]]
                elif key == "kabuki" and len(args) == 4:
                    # swap key 1, swap key 2, address key, XOR key, in hex as MAME lists them
                    m["kabuki"] = tuple(int(a, 16) for a in args)
                elif key == "section" and len(args) >= 3:
                    sec = {"name": args[0], "offset": int(args[1], 0), "size": int(args[2], 0),
                           "chips": [], "interleave": 8, "swap16": False, "sdram": False,
                           "gfx_sort": None, "header": False, "kabuki": None, "decrypt": None,
                           "zeros": False}
                    for opt in args[3:]:
                        if opt in ("interleave=16", "interleave=32"):
                            sec["interleave"] = int(opt[11:])
                        elif opt == "swap16":
                            sec["swap16"] = True
                        elif opt == "sdram":
                            sec["sdram"] = True
                        elif opt == "header":
                            sec["header"] = True
                        elif opt.startswith("gfx_sort=") and opt[9:] in GFX_SORT:
                            sec["gfx_sort"] = opt[9:]
                        elif opt.startswith("kabuki=") and opt[7:] in KABUKI:
                            sec["kabuki"] = opt[7:]
                        elif opt == "decrypt=jrpacman":
                            sec["decrypt"] = opt[8:]
                        elif opt == "zeros":
                            sec["zeros"] = True
                        else:
                            raise ManifestError("%s: unknown section option %s" % (where, opt))
                    m["sections"].append(sec)
                elif key == "chip" and len(args) >= 3 and m["sections"]:
                    chip = {"name": args[0], "size": int(args[1], 0), "sha1": args[2].lower(),
                            "zip": None, "optional": False, "derive": None}
                    for opt in args[3:]:
                        if opt.startswith("zip="):
                            chip["zip"] = opt[4:]
                        elif opt == "optional":
                            chip["optional"] = True
                        elif opt.startswith("derive=") and opt[7:] in DERIVE:
                            chip["derive"] = opt[7:]
                        else:
                            raise ManifestError("%s: unknown chip option %s" % (where, opt))
                    chip["out"] = 256 if chip["derive"] else chip["size"]
                    m["sections"][-1]["chips"].append(chip)
                elif key == "fill" and 1 <= len(args) <= 2 and m["sections"]:
                    # filler bytes after chips, 0xFF unless given, as MAME erases a region
                    value = int(args[1], 0) if len(args) == 2 else 0xFF
                    if not 0 <= value <= 255:
                        raise ManifestError("%s: fill byte %d is not a byte" % (where, value))
                    m["sections"][-1]["chips"].append({"fill": value, "out": int(args[0], 0)})
                elif key == "data" and args and m["sections"]:
                    # literal bytes in hex, such as jotego's header bytes
                    m["sections"][-1]["chips"].append({"data": bytes(int(a, 16) for a in args),
                                                        "out": len(args)})
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
    for key in ("set", "zip", "total", "board", "mirror", "screen"):
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
        # zeros: a section without chips, its bytes are 0 (a longer set of the board that has
        # no use for a section the shorter ones fill)
        if s["zeros"] and s["chips"]:
            raise ManifestError("%s: section %s is zeros and has chips" % (path, s["name"]))
        if not s["zeros"] and sum(c["out"] for c in s["chips"]) != s["size"]:
            raise ManifestError("%s: the chips of section %s do not add up to %d bytes"
                                % (path, s["name"], s["size"]))
        # interleave=N takes each run of chips between fill and data lines in groups of N/8
        # of equal size
        k = s["interleave"] // 8
        for run in runs(s["chips"]):
            if len(run) % k or any(len({c["out"] for c in run[i:i + k]}) != 1
                                   for i in range(0, len(run), k)):
                raise ManifestError("%s: section %s, interleave=%d needs groups of %d chips of "
                                    "equal size" % (path, s["name"], s["interleave"], k))
        if s["swap16"] and s["size"] % 2:
            raise ManifestError("%s: section %s, swap16 needs an even size" % (path, s["name"]))
        # the sort moves bytes inside blocks of 2^(b0+nv+1) bytes: 32 for hvvvx, 128 for hvvvvxx
        if s["gfx_sort"]:
            b0, nv = GFX_SORT[s["gfx_sort"]]
            block = 2 << (b0 + nv)
            if s["offset"] % block or s["size"] % block:
                raise ManifestError("%s: section %s, gfx_sort=%s works on %d-byte blocks, offset "
                                    "and size must be multiples of %d"
                                    % (path, s["name"], s["gfx_sort"], block, block))
        pos += s["size"]
    if pos != m["total"]:
        raise ManifestError("%s: the sections add up to %d bytes, total says %d"
                            % (path, pos, m["total"]))
    # A header section goes plain to the core's write port, and the top takes byte 2 from
    # it (game20k_top.sv, screen_rt): make_rom.py writes the screen code there, so the
    # manifest leaves it to a fill line rather than stating it twice.
    heads = [s for s in m["sections"] if s["header"]]
    if len(heads) > 1:
        raise ManifestError("%s: %d header sections, at most one" % (path, len(heads)))
    for s in heads:
        if s["interleave"] != 8 or s["swap16"] or s["sdram"] or s["gfx_sort"]:
            raise ManifestError("%s: section %s, a header section takes no other option" % (path, s["name"]))
        pos = 0
        for c in s["chips"]:
            if pos <= HDR_SCREEN_BYTE < pos + c["out"]:
                if "fill" not in c:
                    raise ManifestError("%s: section %s, byte %d of a header section is the screen "
                                        "code, it must come from a fill line"
                                        % (path, s["name"], HDR_SCREEN_BYTE))
                break
            pos += c["out"]
        else:
            raise ManifestError("%s: section %s, a header section has at least %d bytes"
                                % (path, s["name"], HDR_SCREEN_BYTE + 1))
    # A kabuki section is the program as the CPU sees it: its chips one after the other from
    # byte 0, fill only behind them (left as it is), no other arrangement.
    for s in m["sections"]:
        if not s["kabuki"]:
            continue
        if "kabuki" not in m:
            raise ManifestError("%s: section %s is kabuki=%s, but there is no kabuki line"
                                % (path, s["name"], s["kabuki"]))
        if s["interleave"] != 8 or s["swap16"] or s["gfx_sort"] or s["header"]:
            raise ManifestError("%s: section %s, a kabuki section takes no other arrangement"
                                % (path, s["name"]))
        kinds = "".join("c" if "name" in c else "f" if "fill" in c else "d" for c in s["chips"])
        if not re.fullmatch(r"c+f*", kinds):
            raise ManifestError("%s: section %s, a kabuki section has chips first and fill only "
                                "behind them" % (path, s["name"]))
    # rom_sdram.sv gathers whole 32-bit words: an sdram section starts and ends on a word
    for s in m["sections"]:
        if s["sdram"] and (s["offset"] % 4 or s["size"] % 4):
            raise ManifestError("%s: section %s, an sdram section starts and ends on a 32-bit word"
                                % (path, s["name"]))
    return m


def runs(items):
    """The chips of a section as runs of set chips, split at every fill or data entry."""
    out, run = [], []
    for c in items:
        if "name" in c:
            run.append(c)
        else:
            if run:
                out.append(run)
            run = []
    return out + [run] if run else out


def manifests():
    """Every manifest of every core, sorted."""
    return sorted(glob.glob(os.path.join(ROOT, "fpga", "*", "*.manifest")))


def read_chip(zips, chip, default_zip):
    """Content of one chip from its zip in roms/, or None when zip or member is missing.

    The member with the manifest's size and SHA-1 is taken, wherever it lies and however it
    is named, as MAME finds its chips by checksum: a merged set keeps its clones in folders,
    and a set from another MAME release may name a chip differently, so the same name can
    belong to another set's chip. Members of that name are tried first. Without a match the
    first member of that name is returned, so that build() says what is wrong with it.
    """
    zpath = os.path.join(ROOT, "roms", chip["zip"] or default_zip)
    if zpath not in zips:
        zips[zpath] = zipfile.ZipFile(zpath) if os.path.isfile(zpath) else None
    z = zips[zpath]
    if z is None:
        return None
    hits = [i for i in z.infolist() if os.path.basename(i.filename) == chip["name"]]
    for i in hits + [i for i in z.infolist() if i not in hits]:
        if i.file_size == chip["size"]:
            data = z.read(i)
            if hashlib.sha1(data).hexdigest() == chip["sha1"]:
                return data
    return z.read(hits[0]) if hits else None


# Jr. Pac-Man's program ROM is garbled by PALs on the board. MAME (jrpacman.cpp,
# init_jrpacman, table by David Caldwell) undoes it with a run-length XOR table over the
# CPU address space 0x0000-0xFFFF. (count, value) pairs, in address order.
JRPACMAN_XOR = (
    (0x00C1, 0x00), (0x0002, 0x80), (0x0004, 0x00), (0x0006, 0x80), (0x0003, 0x00), (0x0002, 0x80),
    (0x0009, 0x00), (0x0004, 0x80), (0x9968, 0x00), (0x0001, 0x80), (0x0002, 0x00), (0x0001, 0x80),
    (0x0009, 0x00), (0x0002, 0x80), (0x0009, 0x00), (0x0001, 0x80), (0x00AF, 0x00), (0x000E, 0x04),
    (0x0002, 0x00), (0x0004, 0x04), (0x001E, 0x00), (0x0001, 0x80), (0x0002, 0x00), (0x0001, 0x80),
    (0x0002, 0x00), (0x0002, 0x80), (0x0009, 0x00), (0x0002, 0x80), (0x0009, 0x00), (0x0002, 0x80),
    (0x0083, 0x00), (0x0001, 0x04), (0x0001, 0x01), (0x0001, 0x00), (0x0002, 0x05), (0x0001, 0x00),
    (0x0003, 0x04), (0x0003, 0x01), (0x0002, 0x00), (0x0001, 0x04), (0x0003, 0x01), (0x0003, 0x00),
    (0x0003, 0x04), (0x0001, 0x01), (0x002E, 0x00), (0x0078, 0x01), (0x0001, 0x04), (0x0001, 0x05),
    (0x0001, 0x00), (0x0001, 0x01), (0x0001, 0x04), (0x0002, 0x00), (0x0001, 0x01), (0x0001, 0x04),
    (0x0002, 0x00), (0x0001, 0x01), (0x0001, 0x04), (0x0002, 0x00), (0x0001, 0x01), (0x0001, 0x04),
    (0x0001, 0x05), (0x0001, 0x00), (0x0001, 0x01), (0x0001, 0x04), (0x0002, 0x00), (0x0001, 0x01),
    (0x0001, 0x04), (0x0002, 0x00), (0x0001, 0x01), (0x0001, 0x04), (0x0001, 0x05), (0x0001, 0x00),
    (0x01B0, 0x01), (0x0001, 0x00), (0x0002, 0x01), (0x00AD, 0x00), (0x0031, 0x01), (0x005C, 0x00),
    (0x0005, 0x01), (0x604E, 0x00),
)


def jrpacman_decrypt(prog):
    """The 40 KB program section as the CPU sees it: file 0x0000-0x3FFF is CPU 0x0000-0x3FFF,
    file 0x4000-0x9FFF is CPU 0x8000-0xDFFF. The XOR table runs over CPU addresses."""
    xor = bytearray()
    for count, value in JRPACMAN_XOR:
        xor += bytes([value]) * count
    if len(xor) != 0x10000 or len(prog) != 0xA000:
        raise ManifestError("decrypt=jrpacman: table covers %d bytes, section has %d"
                            % (len(xor), len(prog)))
    return bytes(b ^ xor[a if a < 0x4000 else a + 0x4000] for a, b in enumerate(prog))


def arrange(s, datas):
    """The bytes of one section from the contents of its chips, in manifest order. Plain:
    one chip after the other. interleave=16 or 32: the chips in groups of 2 or 4, each group
    byte by byte (byte i of the first chip, byte i of the second, ...), the groups one after
    the other. swap16 then swaps the two bytes of every 16-bit word. This is how jotego's MRA
    files lay out a ROM region (width and sequence, reverse), see fpga/g1942_hdmi. gfx_sort
    finally moves the bytes the way JTFRAME's loader does for a bus with gfx_sort in its
    mem.yaml, so the file is the image of the SDRAM."""
    k = s["interleave"] // 8
    out = bytearray()
    run = []
    # fill and data entries close the run of chips before them
    for c, d in list(zip(s["chips"], datas)) + [(None, None)]:
        if c is not None and "name" in c:
            run.append(d)
            continue
        for g in range(0, len(run), k):
            group = run[g:g + k]
            if k == 1:
                out += group[0]
            else:
                for i in range(len(group[0])):
                    out += bytes(x[i] for x in group)
        run = []
        if c is not None:
            out += d
    if s["swap16"]:
        out[0::2], out[1::2] = out[1::2], out[0::2]
    if s["gfx_sort"]:
        # JTFRAME sorts these address bits while it downloads the ROM into SDRAM
        # (jtframe_dwnld.v): above the b0 bits that stay, the H bit on top of the nv V bits
        # moves down to bit b0 and the V bits move up by one. hvvvvxx: bits 6:2 become
        # a[5:2], a[6] (HVVVV -> VVVVH), hvvvx: bits 4:1 become a[3:1], a[4] (HVVV -> VVVH).
        # The core reads with the plain address.
        b0, nv = GFX_SORT[s["gfx_sort"]]
        vbits, hbit = ((1 << nv) - 1) << b0, 1 << (b0 + nv)
        sorted_out = bytearray(len(out))
        for a, byte in enumerate(out):
            sorted_out[(a & ~(vbits | hbit)) | ((a & vbits) << 1) | ((a & hbit) >> nv)] = byte
        out = sorted_out
    if s["decrypt"] == "jrpacman":
        out = bytearray(jrpacman_decrypt(out))
    return bytes(out)


def build(m, out):
    """Assemble the file, checking every chip. Returns (sha256, known label or None, warnings)."""
    zips, parts, warnings = {}, [], []
    for s in m["sections"]:
        datas = []
        for c in s["chips"]:
            if "fill" in c:
                datas.append(bytes([c["fill"]]) * c["out"])
                continue
            if "data" in c:
                datas.append(c["data"])
                continue
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
            if c["derive"]:
                data = bytes(DERIVE[c["derive"]](data[i % len(data)]) for i in range(256))
            datas.append(data)
        part = bytes(s["size"]) if s["zeros"] else arrange(s, datas)
        if s["kabuki"]:
            n = sum(c["out"] for c in s["chips"] if "name" in c)
            part = kabuki(part[:n], m["kabuki"], s["kabuki"]) + part[n:]
        if s["header"]:
            part = part[:HDR_SCREEN_BYTE] + bytes([m["screen"]]) + part[HDR_SCREEN_BYTE + 1:]
        parts.append(part)
    blob = b"".join(parts)
    if len(blob) != m["total"]:
        raise ManifestError("assembled %d bytes, expected %d" % (len(blob), m["total"]))
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(blob)
    digest = hashlib.sha256(blob).hexdigest()
    label = next((lbl for sha, lbl in m["known"] if sha == digest), None)
    return digest, label, warnings


def check_prefixes(m, prefixes):
    """Every further manifest must describe the same board and mirror, and its sections must
    be the first sections of m with the same offsets and sizes: rom_loader decodes with m's
    table and simply stops early, so anything else would land in the wrong memory. A
    manifest with exactly m's sections is another set of the same size."""
    for p in prefixes:
        if (p["board"], p["mirror"]) != (m["board"], m["mirror"]):
            raise ManifestError("%s: board or mirror differ from %s" % (p["path"], m["path"]))
        n = len(p["sections"])
        mine = [(s["offset"], s["size"]) for s in m["sections"][:n]]
        theirs = [(s["offset"], s["size"]) for s in p["sections"]]
        # a header section is read by the top at its index, in every file of the board alike
        if [s["header"] for s in m["sections"][:n]] != [s["header"] for s in p["sections"]]:
            raise ManifestError("%s: its header sections differ from %s" % (p["path"], m["path"]))
        if n > len(m["sections"]) or mine != theirs:
            raise ManifestError("%s: its sections are not the first sections of %s"
                                % (p["path"], m["path"]))


def screen_values(m, prefixes):
    """The screen values of the board in rom_map_pkg: (SCREEN_DEFAULT, SCREEN_RT, HDR_SEC,
    FB_BUILD, FB_CCW). A file without a header section stands as its screen line says, so
    all of them must agree, and their screen is the default; without any it is m's. A file
    with one sets the screen at run time from header byte 2 (SCREEN_RT), unless every file of
    the board stands the same way: then byte 2 can only repeat the default, and the top keeps
    the constant. The frame buffer turns one way per bitstream (fb_read_rotated.sv), so cw and
    ccw do not mix."""
    allm = [m] + list(prefixes)
    hdr = [i for i, s in enumerate(m["sections"]) if s["header"]]
    plain_m = [p for p in allm if not any(s["header"] for s in p["sections"])]
    plain = {p["screen"] for p in plain_m}
    if len(plain) > 1:
        names = {v: k for k, v in SCREEN.items()}
        raise ManifestError("files without a header section have different screen lines, the "
                            "core cannot tell them apart: %s" % ", ".join(
                                "%s %s" % (os.path.basename(p["path"]), names[p["screen"]]) for p in plain_m))
    turned = {p["screen"] for p in allm} - {SCREEN["upright"]}
    if turned == {SCREEN["cw"], SCREEN["ccw"]}:
        raise ManifestError("cw and ccw on one board: the frame buffer turns one way per bitstream")
    run_time = bool(hdr) and len({p["screen"] for p in allm}) > 1
    return (plain.pop() if plain else m["screen"], 1 if run_time else 0, hdr[0] if hdr else 0,
            1 if turned else 0, 1 if SCREEN["ccw"] in turned else 0)


def write_package(m, out, prefixes=()):
    """gen/rom_map_pkg.sv: the board id and the RAM mirror size the core announces in the
    header (ram_spi.sv), then the size of the whole layout, number of sections and their
    offsets, the parameters of rom_loader.sv. Written only when the content changes, so an
    unchanged manifest does not touch the file's time stamp."""
    check_prefixes(m, prefixes)
    sc_default, sc_rt, hdr_sec, fb_build, fb_ccw = screen_values(m, prefixes)
    offs = [s["offset"] for s in m["sections"]]
    if len(offs) > 16:
        raise ManifestError("%s: %d sections, rom_loader takes at most 16" % (m["path"], len(offs)))
    # address width of the loader's byte counter: 16 bits up to 64 KiB, more for bigger files
    aw = max(16, (m["total"] - 1).bit_length())
    sdram = sum(1 << i for i, s in enumerate(m["sections"]) if s["sdram"])
    lines = ["// Generated by scripts/make_rom.py from %s. Do not edit." % os.path.relpath(m["path"], ROOT),
             "// Board id and RAM mirror size of %s for ram_spi.sv, its ROM layout for" % m["set"],
             "// rom_loader.sv, see the manifest.",
             "package rom_map_pkg;",
             "    // header byte 12 of the RAM mirror: which board this core is to the firmware",
             "    localparam logic [7:0] BOARD_ID = 8'd%d;" % m["board"],
             "    // game RAM bytes in the RAM mirror before the oracle log, header byte 14 x RAM_MIRROR_PAGE",
             "    localparam int MIRROR_DATA = %d;" % m["mirror"],
             "    // end of the layout: rom_loader takes any file of 1 up to this many bytes",
             "    localparam int ROM_TOTAL    = %d;" % m["total"],
             "    localparam int ROM_SECTIONS = %d;" % len(offs),
             "    // width of the loader's byte counter and of every offset below",
             "    localparam int ROM_AW = %d;" % aw,
             "    // bit i: section i goes to the SDRAM (rom_sdram.sv), not to the core's write port",
             "    localparam logic [15:0] ROM_SDRAM = 16'h%04X;" % sdram,
             "    // section 0 in the lowest ROM_AW bits",
             "    localparam logic [16*%d-1:0] ROM_OFFSETS = {" % aw]
    words = ["%d'h%0*X" % (aw, (aw + 3) // 4, o) for o in reversed(offs)]
    lines += ["        " + ", ".join(words[i:i + 6]) + ("," if i + 6 < len(words) else "")
              for i in range(0, len(words), 6)]
    lines += ["    };",
              "    // screen of the game: 0 upright, 1 cw, 2 ccw (screen line of the manifest,",
              "    // decoded by screen_sel.sv). The screen after every accepted file, final for a",
              "    // file without a header section",
              "    localparam logic [1:0] SCREEN_DEFAULT = 2'd%d;" % sc_default,
              "    // 1: a file of this board has a header section, its byte 2 sets the screen, and the",
              "    // files of the board do not all stand the same way",
              "    localparam bit SCREEN_RT = 1'b%d;" % sc_rt,
              "    // the header section, 0 without one",
              "    localparam int HDR_SEC = %d;" % hdr_sec,
              "    // 1: a game of this board is turned (cw or ccw) and needs the frame buffer for",
              "    // portrait. 0: the top builds no frame buffer (game20k_top.sv, g_fb_none)",
              "    localparam bit FB_BUILD = 1'b%d;" % fb_build,
              "    // 1: the turned games are ccw, fb_read_rotated turns the other way",
              "    localparam bit FB_CCW = 1'b%d;" % fb_ccw,
              "endpackage", ""]
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
    if len(argv) >= 4 and argv[1] == "--package":
        try:
            write_package(read_manifest(argv[2]), argv[3], [read_manifest(a) for a in argv[4:]])
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
    elif not m["known"]:
        # a manifest without known lines: RetroAchievements has no set for the game
        print("no achievement set for this game, it plays without RetroAchievements")
    else:
        print("WARNING: unknown ROM file %s, the firmware will stay in softcore" % digest[:16],
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
