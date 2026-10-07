#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""MAME's inputs at the simulation's game moments, one offset per input change.

Usage: align_inputs.py <sim frames dir> <inputs.txt> <attract dir> <out dir> <last>
       (environment: SET, PORTS, ROMS, LUA; optional SPAN, WINDOW)

The testbench's ROM waits slow Jr.'s CPU down. Where the game waits for the frame this costs
nothing, but where it is not tied to the frame (RAM test, drawing a screen) the simulation falls
behind MAME and the offset d (the simulation's frame k is MAME's frame k + d) moves. One offset
for the whole run would hand MAME a later input a few frames off, and the game would go
elsewhere. So every input change at the simulation's frame F gets its own d: the offset at
which most of the simulated frames in [F - SPAN, F) (default 40) equal MAME's, MAME having had
all earlier changes at their offsets (the first change is fitted on the run without inputs in
<attract dir>). "Equal" is the smallest sum of differing pixels, not identity, so that a small
difference of the core (a sprite one pixel off) does not stop the fit. Searched in WINDOW
(default 16) around the previous d; on a tie the previous d is kept. One MAME run per change, then the final one with
every change to <out dir>/play.
Written: <out dir>/mame_inputs.txt (MAME's frames, for mame_ref.lua with OFS=0) and
<out dir>/offsets.txt ("F d", for compare_frames.py --offsets).
"""
import glob
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare_frames as cf  # noqa: E402


def mame_run(out, inputs, first, last):
    """MAME with the given (frame, in0, in1) lines in MAME's frames, snapshots first..last."""
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    path = os.path.join(out, "inputs.txt")
    with open(path, "w") as f:
        f.writelines("%d %02X %02X\n" % l for l in inputs)
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy", LAST=str(last),
               FIRST=str(max(0, first)), INPUTS=path, OFS="0")
    with open(out + ".log", "w") as log:
        subprocess.run(["timeout", "600", "mame", os.environ["SET"], "-rompath", os.environ["ROMS"],
                        "-video", "none", "-sound", "none", "-norotate", "-keyboardprovider", "none",
                        "-mouseprovider", "none", "-joystickprovider", "none", "-nothrottle",
                        "-skip_gameinfo", "-nvram_directory", out + "/nvram", "-cfg_directory", out + "/cfg",
                        "-snapshot_directory", out, "-autoboot_script", os.environ["LUA"]],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True)


def main(argv):
    if len(argv) != 6:
        print(__doc__)
        return 2
    simdir, inputs, attract, out, last = argv[1], argv[2], argv[3], argv[4], int(argv[5])
    span, win = int(os.environ.get("SPAN", "40")), int(os.environ.get("WINDOW", "16"))
    sims = {int(re.search(r"(\d+)", os.path.basename(p)).group(1)): p for p in glob.glob(os.path.join(simdir, "f*.ppm"))}
    sim = {}

    def simc(n):
        if n not in sim:
            sim[n] = cf.codes(cf.read_ppm(sims[n]))
        return sim[n]

    lines = []
    for l in open(inputs):
        w = l.split()
        if len(w) >= 3:
            lines.append((int(w[0]), int(w[1], 16), int(w[2], 16)))
    os.makedirs(out, exist_ok=True)
    done, offsets, prev = [], [], 0
    for i, (f, a, b) in enumerate(lines):
        frames = [n for n in sims if f - span <= n < f]
        cands = range(prev - win, prev + win + 1) if i else range(-win, win + 1)
        if i == 0:
            ref = attract
        else:
            ref = os.path.join(out, "step")
            mame_run(ref, done, f - span + min(cands), f + max(cands))
        cache = {}

        def mame(m):
            if m not in cache:
                p = os.path.join(ref, "m%04d.png" % m)
                cache[m] = cf.codes(cf.read_png(p)) if os.path.exists(p) else None
            return cache[m]
        score, same = {}, {}
        for d in cands:
            k = [cf.ndiff(simc(n), mame(n + d)) if mame(n + d) is not None else cf.W * cf.H for n in frames]
            score[d], same[d] = sum(k), k.count(0)
        low = min(score.values())
        best = [d for d in score if score[d] == low]
        d = prev if prev in best else min(best, key=lambda x: abs(x - prev))
        nxt = min((v for x, v in score.items() if x != d), default=0)
        note = "%d of %d frames identical, %d pixels differ in all, next best offset %d" % (
            same[d], len(frames), low, nxt) + (", ties %s" % best if len(best) > 1 else "")
        print("input %2d at frame %4d (%02X %02X): offset %+d, %s" % (i, f, a, b, d, note))
        done.append((f + d, a, b))
        offsets.append((f, d))
        prev = d
    shutil.rmtree(os.path.join(out, "step"), ignore_errors=True)
    with open(os.path.join(out, "mame_inputs.txt"), "w") as fh:
        fh.writelines("%d %02X %02X\n" % l for l in done)
    # before the first change the run without inputs is the reference, its offset is the first one
    with open(os.path.join(out, "offsets.txt"), "w") as fh:
        fh.writelines("%d %d\n" % o for o in offsets)
    mame_run(os.path.join(out, "play"), done, 0, last)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
