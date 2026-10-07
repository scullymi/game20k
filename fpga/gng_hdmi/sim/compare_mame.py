#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Frames of tb_gng.sv against MAME snapshots of the same set: is it really GnG, and right?

Usage: compare_mame.py <sim frames dir> <MAME snapshot dir> [--from N] [--window W]
                       [--max-diff P] [--shift dx,dy] [--sheet out.png]

The simulation writes frames/fNNNN.ppm (P3, 4 bits per channel, 256 x 224). MAME writes one
PNG per frame (fNNNN.png, mame_snap.lua). The two runs start at different times (loading,
reset), so one frame offset holds for the whole run: it is the offset within +-W (default 40)
under which the fewest rows differ, summed over all compared frames. A single frame cannot
decide it, a title screen stands still for many frames. MAME's picture may be shifted by
--shift (default 0,0, both rasters show the same 256 x 224, measured). Then every simulated
frame from --from on is compared pixel by pixel with MAME's frame at that offset.

The power-on test runs before the game writes its palette, on the start values of the
palette RAM: jtgng_colmix's grey ramp under JTFRAME (and game_core), a four-step grey in
MAME. Those frames differ in their grey levels by design, --from skips them.

Verdict PASS when no compared frame differs in more than --max-diff percent of its pixels
(default 0.5). A black frame proves nothing and is not compared. MAME's palette has 4 bits a
channel, written out as n * 17, so the comparison is exact, not by colour distance.

Standard library only. The frames are made from the ROM and stay out of the repository.
"""
import os
import struct
import sys
import zlib

W, H = 256, 224


def read_ppm(path):
    words = open(path).read().split()
    w, h, mx = int(words[1]), int(words[2]), int(words[3])
    assert (w, h, mx) == (W, H, 15), path
    v = list(map(int, words[4:]))
    return [bytes(v[(y * w) * 3:(y * w + w) * 3]) for y in range(h)]


def read_png(path):
    """8-bit RGB or RGBA, not interlaced: what MAME's snapshot writes. Rows as bytes of
    4-bit values r, g, b per pixel."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and ctype in (2, 6) and not inter, path
            bpp = 3 if ctype == 2 else 4
        elif typ == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        rows.append(bytes(line[x * bpp + k] // 17 for x in range(w) for k in range(3)))
    assert (w, h) == (W, H), path
    return rows


def diff(a, b, dx=0, dy=0):
    """pixels of a that differ from b shifted by (dx, dy), over the part both cover"""
    n = 0
    for y in range(max(0, -dy), min(H, H - dy)):
        ra, rb = a[y], b[y + dy]
        if dx == 0 and ra == rb:
            continue
        for x in range(max(0, -dx), min(W, W - dx)):
            if ra[3 * x:3 * x + 3] != rb[3 * (x + dx):3 * (x + dx) + 3]:
                n += 1
    return n


def blank(rows):
    return all(not any(r) for r in rows)


def rows_differ(a, b, dx, dy):
    """rows of a that differ from b shifted by (dx, dy): fast, for the search of the offset"""
    if dx == 0:
        return sum(a[y] != b[y + dy] for y in range(max(0, -dy), min(H, H - dy)))
    x0, x1 = max(0, -dx), min(W, W - dx)
    return sum(a[y][3 * x0:3 * x1] != b[y + dy][3 * (x0 + dx):3 * (x1 + dx)]
               for y in range(max(0, -dy), min(H, H - dy)))


def main(argv):
    args = argv[1:]
    opt = {"--from": "0", "--window": "40", "--max-diff": "0.5", "--sheet": "", "--shift": "0,0"}
    pos = []
    while args:
        a = args.pop(0)
        if a in opt:
            opt[a] = args.pop(0)
        else:
            pos.append(a)
    if len(pos) != 2:
        print(__doc__)
        return 2
    sdir, mdir = pos
    first, win, maxd = int(opt["--from"]), int(opt["--window"]), float(opt["--max-diff"])
    dx, dy = (int(v) for v in opt["--shift"].split(","))
    sims = sorted(int(f[1:5]) for f in os.listdir(sdir) if f.startswith("f") and f.endswith(".ppm"))
    mames = set(int(f[1:5]) for f in os.listdir(mdir) if f.startswith("f") and f.endswith(".png"))
    mcache = {}

    def mame(m):
        if m not in mcache:
            mcache[m] = read_png(os.path.join(mdir, "f%04d.png" % m))
        return mcache[m]

    frames = []
    for n in sims:
        if n < first:
            continue
        s = read_ppm(os.path.join(sdir, "f%04d.ppm" % n))
        if blank(s):
            print("frame %4d: black, not compared" % n)
        else:
            frames.append((n, s))
    if not frames:
        print("FAIL: no frame with content")
        return 1
    # the offset of the run: fewest differing rows over all frames, ties to the smaller |offset|
    score = []
    for off in range(-win, win + 1):
        if all(n + off in mames for n, _ in frames):
            score.append((sum(rows_differ(s, mame(n + off), dx, dy) for n, s in frames), abs(off), off))
    if not score:
        print("FAIL: MAME has too few frames for the window")
        return 1
    rows, _, off = min(score)
    worst = 0.0
    for n, s in frames:
        d = diff(s, mame(n + off), dx, dy)
        pct = 100.0 * d / (W * H)
        worst = max(worst, pct)
        print("frame %4d: MAME frame %4d, %5d pixels differ (%.2f %%)" % (n, n + off, d, pct))
    print("offset %+d frames (MAME = simulation %+d), shift %s, %d frames compared, worst %.2f %% of the pixels"
          % (off, off, (dx, dy), len(frames), worst))
    if opt["--sheet"]:
        step = max(1, len(frames) // 6)
        write_sheet(opt["--sheet"], [(s, mame(n + off)) for n, s in frames[::step][:6]])
    if worst <= maxd:
        print("PASS: %d frames match MAME" % len(frames))
        return 0
    print("FAIL: worst %.2f %% (limit %.2f)" % (worst, maxd))
    return 1


def write_sheet(path, pairs):
    """simulation above MAME, one column per pair, 8 bits a channel"""
    cols = len(pairs)
    rows = []
    for half in (0, 1):
        for y in range(H):
            line = bytearray()
            for p in pairs:
                line += bytes(v * 17 for v in p[half][y]) + b"\x00\x00\x00" * 4
            rows.append(bytes(line))
    w = cols * (W + 4)
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, 2 * H, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
