# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Builds every core of the ring and packs a release: flash image, NOTICE, FLASHING, zip.

A release comes from a clean tree on a tag. dev skips these checks for a trial run, the files
then carry the version git describe gives. Every core of project.toml is built by this run and
has to meet its clock frequencies. The cores build at the same time, at most one per processor
this process may use, each into a log of its own, which is printed in the ring's order
afterwards.

git config game20k.quiethours "D1-D2 H1-H2" names a window of weekdays and hours, as date +%u
and +%H count them, in which no release is made: the files and the zip carry the time they were
written. dev skips this check too."""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from tools.engine import config, host
from tools.engine.host import StepError


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True).stdout.strip()


def check_clock(root: Path) -> None:
    """@brief Stops inside the window of git config game20k.quiethours."""
    quiet = git(root, "config", "--get", "game20k.quiethours")
    if not quiet:
        return
    m = re.fullmatch(r"([1-7])-([1-7]) ([0-2][0-9])-([0-2][0-9])", quiet)
    if not m:
        raise StepError(f'git config game20k.quiethours is "{quiet}", expected "D1-D2 H1-H2"')
    d1, d2, h1, h2 = map(int, m.groups())
    now = time.localtime()
    if d1 <= now.tm_wday + 1 <= d2 and h1 <= now.tm_hour <= h2:
        raise StepError(f"the clock is inside game20k.quiethours ({quiet}), the files would carry this time")


def build_all(root: Path, cores: list[Path], logs: Path) -> None:
    """@brief Builds the cores at the same time, each by its own g20k.py, and prints the logs in
    ring order."""
    logs.mkdir(parents=True, exist_ok=True)

    def one(core: Path) -> bool:
        with open(logs / f"{core.name}.log", "w", encoding="utf-8") as log:
            cmd = [sys.executable, str(root / "g20k.py"), "build", str(core)]
            return subprocess.run(cmd, cwd=root, stdout=log, stderr=subprocess.STDOUT).returncode == 0

    # the processors this process may run on, fewer than the machine's in a container or a CI
    # runner with a CPU set
    cpus = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count() or 1
    jobs = min(len(cores), cpus)
    print(f"building {len(cores)} cores, {jobs} at a time", flush=True)
    with ThreadPoolExecutor(jobs) as pool:
        ok = list(pool.map(one, cores))
    for core, good in zip(cores, ok, strict=True):
        print((logs / f"{core.name}.log").read_text(), end="")
        if not good:
            raise StepError(f"the build of {core.name} failed, its log is above")


def release(root: Path, dev: bool) -> Path:
    """@brief Builds and packs a release under dist/ and returns the path of its zip."""
    project = config.load_project(root / "project.toml")
    if not dev:
        if (
            subprocess.run(
                ["git", "-C", str(root), "describe", "--tags", "--exact-match", "HEAD"], capture_output=True
            ).returncode
            != 0
        ):
            raise StepError("HEAD is not on a tag, a release needs one (--dev for a trial run)")
        if git(root, "status", "--porcelain"):
            raise StepError("the tree has uncommitted changes (--dev for a trial run)")
        check_clock(root)
    head = git(root, "rev-parse", "HEAD")
    version = git(root, "describe", "--tags", "--always", "--dirty").removeprefix("v")
    name = f"{project.name}-{version}-{project.board.folder.name}"

    # a release of this name that is there already stays: another build of it is a decision of
    # whoever removes the old one
    dist = root / "dist" / name
    archive = root / "dist" / f"{name}.zip"
    for old in (dist, archive):
        if old.exists():
            raise StepError(f"{old.relative_to(root)} is there already, remove it for a new build")

    start = time.time()
    build_all(root, project.slots, root / "build" / "release-logs")
    # the bitstreams come from this run, whose builds met every clock frequency and measure
    for core in project.slots:
        out = root / "build" / core.name
        for f in (out / f"{core.name}.fs", out / f"{core.name}.bin"):
            if not f.is_file() or f.stat().st_mtime < start:
                raise StepError(f"{f} is missing or older than this run")
    # a parallel session may have committed or edited files during the build
    if not dev:
        if git(root, "rev-parse", "HEAD") != head or git(root, "status", "--porcelain"):
            raise StepError("HEAD or the tree changed during the build, the bitstreams match no commit")
        check_clock(root)

    dist.mkdir(parents=True)
    env = {"ALLOW_DIRTY": "1"} if dev else None
    print(
        host.run(
            host.python(
                root / "scripts" / "bitstream_notice.py",
                "--build",
                root / "build",
                dist / "NOTICE.txt",
                version,
                *[c.name for c in project.slots],
            ),
            cwd=root,
            env=env,
        ),
        end="",
    )
    # The image is the flash from 0 as project.toml lays it out: every core's .bin at its slot,
    # 0xFF in between as in an erased flash. One write puts every core in place, and the cores
    # of a release always go on together, they must match the firmware of the same version.
    image = bytearray()
    for core in project.slots:
        address = project.address(core)
        data = (root / "build" / core.name / f"{core.name}.bin").read_bytes()
        if len(data) > project.board.flash.slot_size:
            raise StepError(f"{core.name}.bin is larger than its slot")
        image += b"\xff" * (address - len(image)) + data
    (dist / f"{name}.bin").write_bytes(image)
    # how to flash the image on this board, the board's text with the names of this release
    flashing = project.board.folder / "FLASHING.txt"
    (dist / "FLASHING.txt").write_text(
        flashing.read_text().format(
            project=project.name, version=version, board=project.board.name, name=name
        )
    )
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(dist.iterdir()):
            z.write(f, f"{name}/{f.name}")
    print("release files:")
    for f in sorted(dist.iterdir()) + [archive]:
        print(f"  {f.stat().st_size:9d}  {f.relative_to(root)}")
    print(f"  {hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.relative_to(root)}")
    return archive
