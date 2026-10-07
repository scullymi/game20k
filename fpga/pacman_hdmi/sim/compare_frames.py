#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Frames of tb_system.vhd against MAME's snapshots of the same set (mame_ref.lua).

Usage: compare_frames.py <sim frames dir> <mame dir> [--offset d | --offsets file | --track 1] [--window n]
                         [--fit-below f] [--fit-span s] [--print-offset] [--sheet out.png]

Both sides are in the core's raster, 288 x 224 (MAME runs with -norotate). The simulated frame
fNNNN.ppm is compared with MAME's mMMMM.png, M = N + d. Colours are compared as the core's
codes, 3 bits red and green and 2 bits blue: each MAME channel is taken to the nearest level of
its resistor network, and the largest distance to a level is reported, so a colour MAME has
and the network has not shows up.

Without --offset, d is the offset in -window..window (default 12) at which most frames below
--fit-below (default: all) are identical, only the last --fit-span of them if given; several
offsets with that count are reported, a still picture decides nothing. --print-offset prints
only that d. --offsets names a file of "F d" lines (align_inputs.py): from the simulation's
frame F on the offset is d, because the testbench's ROM waits slow the CPU down in phases in
which the game is not tied to the frame, and the offset moves there. Every frame is reported:
identical at its offset, or the number of differing pixels and the offsets in the window at
which an identical MAME frame exists, and the residue: the differing pixels that the
simulation's right neighbour does not explain (sim x + 1 = MAME x). --track follows a moving
offset without inputs: each frame takes the offset within the window around the previous one
at which the fewest pixels differ, the steps are reported. The core draws sprites one
pixel later on the line than MAME, so a frame with residue 0 differs by that shift only. --sheet writes sim, MAME and the difference (white) side by side,
turned upright as the cabinet shows them, for differing and identical frames spread over the
run. Standard library only.
"""
import glob
import os
import re
import struct
import sys
import zlib

W, H = 288, 224
RG = (0, 33, 71, 104, 151, 184, 222, 255)
B = (0, 81, 174, 255)


def nearest(levels, shift):
    tab, dist = bytearray(256), [0] * 256
    for v in range(256):
        i = min(range(len(levels)), key=lambda k: abs(levels[k] - v))
        tab[v], dist[v] = i << shift, abs(levels[i] - v)
    return bytes(tab), dist


T_R, D_RG = nearest(RG, 0)
T_G, _ = nearest(RG, 3)
T_B, D_B = nearest(B, 6)


def codes(rgb):
    """RGB bytes to one code byte per pixel, r | g << 3 | b << 6, as a big integer and bytes."""
    n = len(rgb) // 3
    v = (int.from_bytes(rgb[0::3].translate(T_R), "big") | int.from_bytes(rgb[1::3].translate(T_G), "big")
         | int.from_bytes(rgb[2::3].translate(T_B), "big"))
    return v.to_bytes(n, "big")


def level_error(rgb):
    return max(max(D_RG[c] for c in set(rgb[0::3]) | set(rgb[1::3])), max(D_B[c] for c in set(rgb[2::3])))


def read_ppm(path):
    data = open(path, "rb").read()
    parts = data.split(b"\n", 3)
    assert parts[0] == b"P6" and parts[1] == b"%d %d" % (W, H), path
    return parts[3][:W * H * 3]


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat = 8, b""
    while pos < len(data):
        n, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            assert (w, h) == (W, H) and depth == 8 and ctype in (2, 6), "%s: %dx%d type %d" % (path, w, h, ctype)
            bpp = 3 if ctype == 2 else 4
        elif tag == b"IDAT":
            idat += body
        pos += 12 + n
    raw, stride = zlib.decompress(idat), W * bpp
    out, prev = bytearray(), bytearray(stride)
    for y in range(H):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 2:
            line = bytearray((a + b) & 255 for a, b in zip(line, prev))
        elif f != 0:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
                if f == 1: line[i] = (line[i] + a) & 255
                elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
                elif f == 4:
                    p = a + b - c
                    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                    line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line if bpp == 3 else bytes(v for i, v in enumerate(line) if i % 4 != 3)
        prev = line
    return bytes(out)


def write_png(path, w, h, rows):
    raw = b"".join(b"\0" + r for r in rows)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                 + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def ndiff(a, b):
    x = (int.from_bytes(a, "big") ^ int.from_bytes(b, "big")).to_bytes(len(a), "big")
    return len(x) - x.count(0)


def residue(a, b):
    """Differing pixels not explained by the simulation's pixel one to the right."""
    return sum(1 for i in range(len(a)) if a[i] != b[i] and (i % W == W - 1 or a[i + 1] != b[i]))


def upright(rgb):
    """The raster turned 90 degrees clockwise (MAME's ROT90): rows of 224 pixels, 288 of them."""
    rows = []
    for x in range(W):
        rows.append(b"".join(rgb[((H - 1 - y) * W + x) * 3:((H - 1 - y) * W + x) * 3 + 3] for y in range(H)))
    return rows


def main(argv):
    args, opt = [], {}
    i = 1
    while i < len(argv):
        if argv[i] == "--print-offset":
            opt["print"] = True
        elif argv[i].startswith("--"):
            opt[argv[i][2:]] = argv[i + 1]
            i += 1
        else:
            args.append(argv[i])
        i += 1
    if len(args) != 2:
        print(__doc__)
        return 2
    win = int(opt.get("window", 12))
    sims = {int(re.search(r"(\d+)", os.path.basename(p)).group(1)): p for p in glob.glob(os.path.join(args[0], "f*.ppm"))}
    mames = {int(re.search(r"(\d+)", os.path.basename(p)).group(1)): p for p in glob.glob(os.path.join(args[1], "m*.png"))}
    cache, worst = {}, [0]

    def mame(n):
        if n not in mames:
            return None
        if n not in cache:
            rgb = read_png(mames[n])
            worst[0] = max(worst[0], level_error(rgb))
            cache[n] = (rgb, codes(rgb))
        return cache[n]

    sim = {n: (lambda r: (r, codes(r)))(read_ppm(p)) for n, p in sims.items()}
    segs = []
    if "track" in opt:
        d, n0 = 0, min(sim)
        best = None
        for dd in range(-win, win + 1):
            if mame(n0 + dd) is not None:
                k = ndiff(sim[n0][1], mame(n0 + dd)[1])
                if best is None or k < best[0]:
                    best = (k, dd)
        prev = best[1]
        for n in sorted(sim):
            cand = [(ndiff(sim[n][1], mame(n + dd)[1]), abs(dd - prev), dd)
                    for dd in range(prev - win, prev + win + 1) if mame(n + dd) is not None]
            if not cand:
                continue
            dd = min(cand)[2]
            if not segs or dd != segs[-1][1]:
                segs.append((n, dd))
            prev = dd
        d = segs[0][1]
        print("offset track: %s" % " ".join("%d:%+d" % x for x in segs))
    elif "offsets" in opt:
        segs = [tuple(map(int, l.split()[:2])) for l in open(opt["offsets"]) if l.strip()]
        d = segs[0][1]
    elif "offset" in opt:
        d = int(opt["offset"])
    else:
        below = int(opt.get("fit-below", 1 << 30))
        span = int(opt.get("fit-span", 1 << 30))
        fit = [n for n in sim if below - span <= n < below]
        score = {}
        for dd in range(-win, win + 1):
            score[dd] = sum(1 for n in fit if mame(n + dd) is not None and mame(n + dd)[1] == sim[n][1])
        top = max(score.values())
        best = [dd for dd in score if score[dd] == top]
        d = min(best, key=abs)
        print("offset fit over %d frames below %d: %s" % (len(fit), below,
              ", ".join("%+d: %d" % (k, v) for k, v in sorted(score.items()) if v)))
        if len(best) > 1:
            print("offsets with the same count: %s, taking %+d" % (best, d))
        if "print" in opt:
            print(d)
            return 0
    same, total, bad, anywhere, shift_only = 0, 0, [], 0, 0
    base = d
    offs = {}
    for n in sorted(sim):
        d = base
        for f, dd in segs:
            if f <= n:
                d = dd
        offs[n] = d
        m = mame(n + d)
        if m is None:
            continue
        total += 1
        if m[1] == sim[n][1]:
            same += 1
            continue
        k = ndiff(sim[n][1], m[1])
        hits = [dd for dd in range(-win, win + 1) if mame(n + dd) is not None and mame(n + dd)[1] == sim[n][1]]
        bad.append(n)
        anywhere += bool(hits)
        r = residue(sim[n][1], m[1])
        shift_only += (r == 0)
        print("frame %4d: %5d pixels differ from MAME's frame %d, residue %d%s" % (
            n, k, n + d, r, ", identical at offset %s" % hits if hits else ", no identical frame within %d" % win))
    print("largest distance of a MAME colour to a level: %d" % worst[0])
    print("%d of the differing frames differ by the sprite shift only (residue 0)" % shift_only)
    if segs:
        print("%d of %d frames identical to MAME at their offset (%s), %d more at another offset "
              "within %d" % (same, total, " ".join("%d:%+d" % s for s in segs), anywhere, win))
    else:
        print("%d of %d frames identical to MAME at offset %+d, %d more at another offset within %d"
              % (same, total, d, anywhere, win))
    if "sheet" in opt and total:
        ok = [n for n in sorted(sim) if mame(n + offs[n]) is not None and n not in bad]
        # differing frames spread over the run, the rest identical ones
        nb = min(6, len(bad))
        pick = (bad[::max(1, len(bad) // nb)][:nb] if nb else []) + ok[::max(1, len(ok) // max(1, 8 - nb))][:8 - nb]
        pick = sorted(set(pick))[:8]
        gap = 4
        rows = []
        for n in pick:
            a, b = sim[n][0], mame(n + offs[n])[0]
            dif = bytearray(len(a))
            ca, cb = sim[n][1], mame(n + offs[n])[1]
            for j in range(W * H):
                if ca[j] != cb[j]:
                    dif[j * 3:j * 3 + 3] = b"\xff\xff\xff"
            ra, rb, rd = upright(a), upright(b), upright(bytes(dif))
            sep = b"\x28\x28\x28" * gap
            for y in range(W):
                rows.append(ra[y] + sep + rb[y] + sep + rd[y])
            rows += [b"\x28\x28\x28" * (3 * H + 2 * gap)] * gap
        write_png(opt["sheet"], 3 * H + 2 * gap, len(rows), rows)
        print("sheet: frames %s (sim, MAME, difference) in %s" % (pick, opt["sheet"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
