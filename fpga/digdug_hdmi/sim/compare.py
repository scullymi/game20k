#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Compare the frames of the Dig Dug simulation with MAME snapshots.

Usage: compare.py <frames.bin> <first> <mame snap dir> [--window N] [--offset D]
                  [--sheet out.png f1,f2,...] [--from F] [--to F]

frames.bin holds the simulated frames from frame <first> on, 288 x 224 palette PROM bytes
each (tb_digdug.sv). The MAME snapshots are NNNN.png, one per frame, 224 x 288 RGB (the
picture turned for the upright monitor, ROT90). Each snapshot is turned back to the raw
raster and its colours mapped to the PROM bytes with MAME's resistor weights
(digdug_palette, compute_resistor_weights in resnet.cpp), so both sides compare as colours.

For every simulated frame the MAME frame within +-window of the expected one (frame + offset,
the offset following the last match) with the fewest differing pixels is taken. Printed:
per frame the MAME frame, the offset and the differing pixels, then a summary. The PNG
decoder reads only what MAME writes: 8-bit RGB, filter 0 on every row.
"""
import os
import struct
import sys
import zlib

W, H = 288, 224


def weights(res):
    """compute_resistor_weights for one net without pull-up or pull-down, unscaled."""
    out = []
    for n in range(len(res)):
        g0 = 1e-12 + sum(1.0 / r for j, r in enumerate(res) if j != n)
        g1 = 1e-12 + 1.0 / res[n]
        r0, r1 = 1.0 / g0, 1.0 / g1
        out.append(255.0 * r0 / (r1 + r0))
    return out


def palette():
    """The colour of every PROM byte: bits 2:0 red, 5:3 green, 7:6 blue (digdug_palette)."""
    rw, gw, bw = weights([1000, 470, 220]), weights([1000, 470, 220]), weights([470, 220])
    scale = 255.0 / max(sum(rw), sum(gw), sum(bw))
    rw, gw, bw = [w * scale for w in rw], [w * scale for w in gw], [w * scale for w in bw]
    pal = []
    for v in range(256):
        r = int(rw[0] * (v & 1) + rw[1] * (v >> 1 & 1) + rw[2] * (v >> 2 & 1) + 0.5)
        g = int(gw[0] * (v >> 3 & 1) + gw[1] * (v >> 4 & 1) + gw[2] * (v >> 5 & 1) + 0.5)
        b = int(bw[0] * (v >> 6 & 1) + bw[1] * (v >> 7 & 1) + 0.5)
        pal.append((r, g, b))
    return pal


PAL = palette()
# one class per colour: a byte and an RGB value compare equal when their class is the same
CLASS = {}
for c in PAL:
    CLASS.setdefault(c, len(CLASS))
BYTE_CLASS = bytes(CLASS[c] for c in PAL)
UNKNOWN = 255


def read_png(path):
    d = open(path, "rb").read()
    p, idat = 8, b""
    while p < len(d):
        n, = struct.unpack(">I", d[p:p + 4])
        t = d[p + 4:p + 8]
        if t == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", d[p + 8:p + 18])
            if (w, h, depth, ctype) != (H, W, 8, 2):
                raise SystemExit("%s: %dx%d depth %d type %d, expected %dx%d RGB" % (path, w, h, depth, ctype, H, W))
        elif t == b"IDAT":
            idat += d[p + 8:p + 8 + n]
        p += 12 + n
    raw = zlib.decompress(idat)
    stride = H * 3 + 1
    if any(raw[i * stride] for i in range(W)):
        raise SystemExit("%s: a row with a PNG filter, not supported" % path)
    return raw, stride


def mame_frame(path):
    """The snapshot as classes in the raw raster: raw (x, y) = shown (223 - y, x)."""
    raw, stride = read_png(path)
    out = bytearray(W * H)
    for x in range(W):            # shown row x
        row = raw[x * stride + 1:(x + 1) * stride]
        for y in range(H):
            sx = H - 1 - y
            out[y * W + x] = CLASS.get((row[3 * sx], row[3 * sx + 1], row[3 * sx + 2]), UNKNOWN)
    return bytes(out)


def diff(a, b):
    x = (int.from_bytes(a, "little") ^ int.from_bytes(b, "little")).to_bytes(len(a), "little")
    return len(a) - x.count(0)


def write_png(path, rgb_rows, w, h):
    raw = b"".join(b"\0" + bytes(r) for r in rgb_rows)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def main(argv):
    args = argv[1:]
    opt = {"--window": "4", "--offset": "0", "--from": "0", "--to": "999999"}
    sheet = None
    pos = []
    i = 0
    while i < len(args):
        if args[i] == "--sheet":
            sheet = (args[i + 1], [int(v) for v in args[i + 2].split(",")])
            i += 3
        elif args[i] in opt:
            opt[args[i]] = args[i + 1]
            i += 2
        else:
            pos.append(args[i])
            i += 1
    if len(pos) != 3:
        print(__doc__)
        return 2
    path, first, snapdir = pos[0], int(pos[1]), pos[2]
    win, off = int(opt["--window"]), int(opt["--offset"])
    data = open(path, "rb").read()
    n = len(data) // (W * H)
    cache = {}

    def mame(m):
        if m not in cache:
            p = os.path.join(snapdir, "%04d.png" % m)
            cache[m] = mame_frame(p) if os.path.isfile(p) else None
        return cache[m]

    sims = {}
    exact = differ = 0
    worst = (0, -1, -1)
    offsets = {}
    for k in range(n):
        f = first + k
        if f < int(opt["--from"]) or f > int(opt["--to"]):
            continue
        s = data[k * W * H:(k + 1) * W * H].translate(BYTE_CLASS)
        sims[f] = s
        best = None
        for m in range(f + off - win, f + off + win + 1):
            mf = mame(m)
            if mf is None:
                continue
            d = diff(s, mf)
            if best is None or d < best[0] or (d == best[0] and abs(m - f - off) < abs(best[1] - f - off)):
                best = (d, m)
        if best is None:
            continue
        d, m = best
        off = m - f
        offsets[off] = offsets.get(off, 0) + 1
        if d == 0:
            exact += 1
        else:
            differ += 1
            if d > worst[0]:
                worst = (d, f, m)
        print("sim %4d  mame %4d  offset %+d  differing pixels %d" % (f, m, off, d))
        for old in [x for x in cache if x < f + off - win - 2]:
            del cache[old]
    print("summary: %d frames, %d identical to a MAME frame, %d with differences, worst %d pixels "
          "(sim %d, mame %d); offsets %s" % (exact + differ, exact, differ, worst[0], worst[1], worst[2],
                                             dict(sorted(offsets.items()))))
    if sheet:
        out, frames = sheet
        rows = []
        for f in frames:
            if f not in sims:
                continue
            best = min((diff(sims[f], mame(m)), m) for m in range(f + off - 3 * win, f + off + 3 * win + 1)
                       if mame(m) is not None)
            mf = mame(best[1])
            inv = {v: k for k, v in CLASS.items()}
            for y in range(H):
                r = []
                for src in (sims[f], mf):
                    for x in range(W):
                        r += inv.get(src[y * W + x], (255, 0, 255))
                    r += (128, 128, 128) * 4
                for x in range(W):
                    r += (255, 0, 0) if sims[f][y * W + x] != mf[y * W + x] else (0, 0, 0)
                rows.append(r)
            rows.append((128, 128, 128) * (3 * W + 8))
        write_png(out, rows, 3 * W + 8, len(rows))
        print("sheet: %s (simulation | MAME | differences in red), rows %s" % (out, frames))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
