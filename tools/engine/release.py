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


def git(root: Path, *args: str, check: bool = True) -> str:
    """@brief What git prints. A failing git stops, unless check is off."""
    done = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if check and done.returncode != 0:
        raise StepError(f"git {' '.join(args)} failed: {done.stderr.strip()}")
    return done.stdout.strip()


def check_clock(root: Path) -> None:
    """@brief Stops inside the window of git config game20k.quiethours."""
    quiet = git(root, "config", "--get", "game20k.quiethours", check=False)  # exit 1 when not set
    if not quiet:
        return
    m = re.fullmatch(r"([1-7])-([1-7]) ([0-2][0-9])-([0-2][0-9])", quiet)
    if not m:
        raise StepError(f'git config game20k.quiethours is "{quiet}", expected "D1-D2 H1-H2"')
    d1, d2, h1, h2 = map(int, m.groups())
    now = time.localtime()
    if d1 <= now.tm_wday + 1 <= d2 and h1 <= now.tm_hour <= h2:
        raise StepError(f"the clock is inside game20k.quiethours ({quiet}), the files would carry this time")


def build_all(root: Path, cores: list[Path], logs: Path, board: Path | None = None) -> None:
    """@brief Builds the cores at the same time, each by its own g20k.py, and prints the logs in
    ring order. board is passed on as --board."""
    logs.mkdir(parents=True, exist_ok=True)

    def one(core: Path) -> bool:
        with open(logs / f"{core.name}.log", "w", encoding="utf-8") as log:
            cmd = [sys.executable, str(root / "g20k.py"), "build", str(core)]
            if board is not None:
                cmd += ["--board", str(board)]
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


#: git describe on the tags that name a version, v<version>, not the tools-<key> of tools.yml
DESCRIBE = ("describe", "--tags", "--match", "v[0-9]*")


def on_version_tag(root: Path) -> bool:
    return (
        subprocess.run(
            ["git", "-C", str(root), *DESCRIBE, "--exact-match", "HEAD"], capture_output=True
        ).returncode
        == 0
    )


def tree_version(root: Path) -> str:
    """@brief The version of the tree without the leading v: 0.9.1 on its tag, 0.9.1-5-gabc1234
    five commits later, plus -dirty with uncommitted changes, the commit before any tag."""
    version = git(root, *DESCRIBE, "--always", "--dirty").removeprefix("v")
    if not version:
        raise StepError("git describe gives no version")
    return version


def check_tree(root: Path) -> None:
    """@brief A release names its sources: a tag, a clean tree, outside the quiet hours."""
    if not on_version_tag(root):
        raise StepError(
            "HEAD is not on a version tag v<version>, a release needs one (--dev for a trial run)"
        )
    if git(root, "status", "--porcelain"):
        raise StepError("the tree has uncommitted changes (--dev for a trial run)")
    check_clock(root)


def new_dist(root: Path, name: str) -> tuple[Path, Path]:
    """@brief The folder and the zip of a release under dist/. A release of this name that is
    there already stays: another build of it is a decision of whoever removes the old one."""
    dist = root / "dist" / name
    archive = root / "dist" / f"{name}.zip"
    for old in (dist, archive):
        if old.exists():
            raise StepError(f"{old.relative_to(root)} is there already, remove it for a new build")
    return dist, archive


def pack(root: Path, dist: Path, archive: Path, name: str) -> None:
    """@brief Zips the release folder and prints its files with the SHA-256 of the zip."""
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(dist.iterdir()):
            z.write(f, f"{name}/{f.name}")
    print("release files:")
    for f in sorted(dist.iterdir()) + [archive]:
        print(f"  {f.stat().st_size:9d}  {f.relative_to(root)}")
    print(f"  {hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.relative_to(root)}")


def release(root: Path, dev: bool, board: Path | None = None) -> Path:
    """@brief Builds and packs a release under dist/ and returns the path of its zip. board is a
    board folder in place of the one project.toml names."""
    project = config.load_project(root / "project.toml", board)
    if not dev:
        check_tree(root)
    head = git(root, "rev-parse", "HEAD")
    version = tree_version(root)
    name = f"{project.name}-{version}-{project.board.folder.name}"

    dist, archive = new_dist(root, name)

    start = time.time()
    builds = project.build_folder("")
    build_all(
        root, project.slots, builds / "release-logs", project.board.folder if project.other_board else None
    )
    # the bitstreams come from this run, whose builds met every clock frequency and measure
    for core in project.slots:
        out = project.build_folder(core.name)
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
                builds,
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
        data = (project.build_folder(core.name) / f"{core.name}.bin").read_bytes()
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
    pack(root, dist, archive, name)
    return archive
