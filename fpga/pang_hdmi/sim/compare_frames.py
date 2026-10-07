#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Frames of tb_pang.sv against MAME's snapshots of the same set (mame_ref.lua).

Usage: compare_frames.py <sim frames dir> <mame dir> <out.png> [max offset]

Every simulated frame fNNNN.ppm (P3, 4 bits per colour) is compared with MAME's mMMMM.png for
M = N + d, d from -max to +max (default 12), the colours at 4 bits: the two count their frames
from different moments, and the offset changes where the game's pace differs (MAME places its
interrupts and its vertical blank by guess, jtpang by the board's line counter). Reported per
frame: the MAME frame it is identical to, column 0 left out (jtpang blanks its first column),
and how many pixels of column 0 differ there; or, without such a frame, the closest one. A
sheet of sim, MAME and the difference (white) goes to out.png. Standard library only.
"""
import glob
import os
import re
import struct
import sys
import zlib


def read_ppm(path):
    words = open(path).read().split()
    w, h, mx = int(words[1]), int(words[2]), int(words[3])
    v = list(map(int, words[4:]))
    k = 255 // mx
    return w, h, [tuple(v[i * 3 + c] * k for c in range(3)) for i in range(w * h)]


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and ctype in (2, 6), "%s: only 8-bit RGB(A)" % path
            bpp = 3 if ctype == 2 else 4
        elif tag == b"IDAT":
            idat += body
        pos += 12 + n
    raw, out, prev = zlib.decompress(idat), [], bytearray(w * bpp)
    stride = w * bpp
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += [tuple(line[x * bpp:x * bpp + 3]) for x in range(w)]
        prev = line
    return w, h, out


def write_png(path, w, h, px):
    raw = b"".join(b"\0" + bytes(c for p in px[y * w:(y + 1) * w] for c in p) for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                 + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def diff(a, b, skip0=False):
    # 4-bit colours: MAME widens with x * 17 as the simulation does. skip0 leaves column 0 out
    return sum(1 for i, (p, q) in enumerate(zip(a, b))
               if not (skip0 and i % 384 == 0) and tuple(c >> 4 for c in p) != tuple(c >> 4 for c in q))


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    dmax = int(argv[4]) if len(argv) > 4 else 12
    sims = {int(re.search(r"(\d+)", os.path.basename(p)).group(1)): p
            for p in glob.glob(os.path.join(argv[1], "f*.ppm"))}
    mames = {int(re.search(r"(\d+)", os.path.basename(p)).group(1)): p
             for p in glob.glob(os.path.join(argv[2], "m*.png"))}
    cache = {}
    def mame(n):
        if n not in cache:
            cache[n] = read_png(mames[n])[2] if n in mames else None
        return cache[n]
    rows, total, same, near, col0 = [], 0, 0, 0, 0
    prev = None
    for n in sorted(sims):
        a = read_ppm(sims[n])[2]
        # the offsets at which MAME shows the same frame, column 0 left out
        hits = [d for d in range(-dmax, dmax + 1) if mame(n + d) is not None and diff(a, mame(n + d), True) == 0]
        best = min((d for d in range(-dmax, dmax + 1) if mame(n + d) is not None),
                   key=lambda d: (diff(a, mame(n + d), True), abs(d - (prev or 0))), default=None)
        if best is None:
            continue
        total += 1
        if hits:
            near += 1
            d = prev if prev in hits else hits[0]
            k0 = diff(a, mame(n + d)) - diff(a, mame(n + d), True)
            col0 += (k0 != 0)
            print("frame %4d: identical to MAME's frame %d (offset %+d), column 0 differs in %d pixels"
                  % (n, n + d, d, k0))
            prev = d
        else:
            print("frame %4d: no identical MAME frame, the closest %+d differs in %d pixels"
                  % (n, best, diff(a, mame(n + best), True)))
        rows.append((a, mame(n + (prev if hits else best))))
    print("%d of %d frames have an identical MAME frame within %d frames (column 0 left out), "
          "%d of them differ in column 0" % (near, total, dmax, col0))
    W, H, gap = 384, 240, 4
    pick = rows[::max(1, len(rows) // 12)][:12]
    sw, sh = 3 * W + 2 * gap, len(pick) * (H + gap)
    sheet = [(40, 40, 40)] * (sw * sh)
    for r, (a, b) in enumerate(pick):
        dd = [(255, 255, 255) if tuple(c >> 4 for c in p) != tuple(c >> 4 for c in q) else (0, 0, 0)
              for p, q in zip(a, b)]
        for col, img in enumerate((a, b, dd)):
            for y in range(H):
                o = (r * (H + gap) + y) * sw + col * (W + gap)
                sheet[o:o + W] = img[y * W:(y + 1) * W]
    write_png(argv[3], sw, sh, sheet)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
