#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Frames of tb_1942.sv (P3 PPM, 4 bits per channel) -> one PNG sheet, for a look at them.

Usage: ppm2png.py <out.png> <frame.ppm> [<frame.ppm> ...]   environment: SCALE=2

A frame wider than high is turned upright: 1942 is a ROT270 game, its raster lies on its
side, and turned 90 degrees clockwise the text reads normally. A frame higher than wide (the
frame buffer's output, already upright) is taken as it is. Six frames per row. Standard library
only, so the script runs wherever Python does.
"""
import os
import struct
import sys
import zlib


def read_ppm(path):
    words = open(path).read().split()
    w, h, mx = int(words[1]), int(words[2]), int(words[3])
    v = list(map(int, words[4:]))
    # channels to 8 bits: 4-bit frames scale by 17 (15 * 17 = 255), 8-bit ones by 1
    k = 255 // mx
    return w, h, [[tuple(v[(y * w + x) * 3 + i] * k for i in range(3)) for x in range(w)]
                  for y in range(h)]


def upright(w, h, px):
    """The raster turned 90 degrees clockwise, unless it already stands."""
    if h > w:
        return w, h, px
    return h, w, [[px[h - 1 - y][x] for y in range(h)] for x in range(w)]


def scaled(w, h, px, s):
    return w * s, h * s, [[px[y // s][x // s] for x in range(w * s)] for y in range(h * s)]


def write_png(path, w, h, rows):
    raw = b"".join(b"\0" + bytes(c for p in r for c in p) for r in rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n"
                 + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                 + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    s = int(os.environ.get("SCALE", "1"))
    frames = [scaled(*upright(*read_ppm(p)), s) for p in argv[2:]]
    fw, fh = frames[0][0], frames[0][1]
    cols = min(len(frames), 6)
    nrows = (len(frames) + cols - 1) // cols
    gap = 4
    width, height = cols * (fw + gap), nrows * (fh + gap)
    sheet = [[(40, 40, 40)] * width for _ in range(height)]
    for k, (w, h, px) in enumerate(frames):
        ox, oy = (k % cols) * (fw + gap), (k // cols) * (fh + gap)
        for y in range(h):
            sheet[oy + y][ox:ox + w] = px[y]
    write_png(argv[1], width, height, sheet)
    print("%s: %d frames, %d x %d" % (argv[1], len(frames), width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
