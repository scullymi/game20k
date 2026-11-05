# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The programs of the build: fetching and checking them, finding them.

tools.toml names every program with its version and, per kind of machine, the archive and its
SHA-256. fetch downloads the archives into external/tools/downloads/, checks them and unpacks
each into a folder of its own, external/tools/<name>-<version>-<machine>/. forks.py makes the
programs of game20k's forks. Each folder gets a marker file with what is in it and where it came
from, which locate() checks the version against, for the forks also their key (forks_key). A
path in local.toml takes the place of a folder, its version is then only checked, with a
warning."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import sys
import tarfile
import tempfile
import tomllib
import urllib.request
import zipfile
from pathlib import Path

from tools.engine import config, host
from tools.engine.host import StepError

#: the file in every tool folder that says what it holds
MARKER = ".g20k-tool.toml"

#: the programs forks.py builds from the sources of tools.toml
BUILT = ("apicula", "nextpnr", "yosys")

#: how the forks are built, packed and unpacked, part of their key
RECIPE = Path(__file__).with_name("forks.py")


def machine() -> str:
    """@brief The kind of machine as tools.toml names it, e.g. darwin-arm64."""
    system = {"darwin": "darwin", "linux": "linux", "win32": "windows"}.get(sys.platform, sys.platform)
    arch = platform.machine().lower()
    arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x64", "amd64": "x64"}.get(arch, arch)
    return f"{system}-{arch}"


def programs(toolset: config.Toolset) -> tuple[str, ...]:
    """@brief The programs of tools.toml: its downloads and the ones built from its sources."""
    return (*toolset.downloads, *BUILT)


def load_local(root: Path, toolset: config.Toolset) -> config.Local:
    return config.load_local(root / "local.toml", programs(toolset))


def tools_dir(root: Path) -> Path:
    return root / "external" / "tools"


def folder(root: Path, name: str, version: str) -> Path:
    """@brief The folder of a program, a commit shortened to 12 characters."""
    return tools_dir(root) / f"{name}-{version[:12]}-{machine()}"


def marker(path: Path) -> dict[str, str]:
    """@brief The marker of a tool folder, empty when it has none."""
    try:
        with open(path / MARKER, "rb") as f:
            return {k: str(v) for k, v in tomllib.load(f).items()}
    except FileNotFoundError:
        return {}


def toml_line(key: str, value: str) -> str:
    """@brief key = "value" with the escapes of a TOML basic string, which JSON's string escapes
    are a part of: a Windows path keeps its backslashes."""
    return f"{key} = {json.dumps(value, ensure_ascii=False)}\n"


def write_marker(path: Path, values: dict[str, str]) -> None:
    text = "".join(toml_line(k, v) for k, v in values.items())
    (path / MARKER).write_text(text, encoding="utf-8", newline="\n")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path) -> None:
    """@brief Downloads url to dest, through a .part file, with a line of progress."""
    part = dest.with_name(dest.name + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "game20k"})
    with urllib.request.urlopen(request) as r, open(part, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        done, shown = 0, -1
        for chunk in iter(lambda: r.read(1 << 20), b""):
            f.write(chunk)
            done += len(chunk)
            percent = done * 100 // total if total else 0
            if percent // 10 != shown:
                shown = percent // 10
                print(f"  {done >> 20} of {total >> 20} MB", flush=True)
    part.replace(dest)


def unpack(archive: Path, dest: Path) -> None:
    """@brief Unpacks archive into dest. An archive that holds one folder gives its content."""
    tmp = Path(tempfile.mkdtemp(dir=dest.parent, prefix=".unpack-"))
    try:
        if archive.name.endswith(".zip"):
            with zipfile.ZipFile(archive) as z:
                z.extractall(tmp)
        else:
            with tarfile.open(archive) as t:
                # the data filter refuses absolute paths and links that leave the folder
                t.extractall(tmp, filter="data")
        entries = list(tmp.iterdir())
        top = entries[0] if len(entries) == 1 and entries[0].is_dir() else tmp
        top.rename(dest)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def fetched(root: Path, archive: config.Archive, what: str) -> Path:
    """@brief The archive in external/tools/downloads/, downloaded when it is not there or
    differs, checked against its SHA-256."""
    downloads = tools_dir(root) / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    file = downloads / archive.url.rsplit("/", 1)[1]
    if not file.exists() or sha256(file) != archive.sha256:
        print(f"== {what}: {archive.url}", flush=True)
        download(archive.url, file)
    got = sha256(file)
    if got != archive.sha256:
        raise StepError(f"{file}: SHA-256 {got}, tools.toml expects {archive.sha256}")
    return file


def fetch(root: Path) -> None:
    """@brief Fetches, checks and unpacks every download of tools.toml that is not there yet,
    and prints what came from where."""
    toolset = config.load_toolset(root / "tools.toml")
    here = machine()
    for d in toolset.downloads.values():
        archive = d.archives.get(here)
        if archive is None:
            raise StepError(f"tools.toml has no {d.name} for {here}")
        dest = folder(root, d.name, d.version)
        if marker(dest).get("sha256") == archive.sha256:
            state = "is there"
        else:
            if dest.exists():
                raise StepError(f"{dest} holds something else than {d.name} {d.version}, remove it")
            unpack(fetched(root, archive, f"{d.name} {d.version}"), dest)
            write_marker(
                dest, {"name": d.name, "version": d.version, "url": archive.url, "sha256": archive.sha256}
            )
            state = "fetched and checked"
        print(f"{d.name} {d.version} ({here}): {state}")
        print(f"  from    {archive.url}")
        print(f"  release {d.release}")
        print(f"  sha256  {archive.sha256}")
        print(f"  in      {dest.relative_to(root).as_posix()}")


def forks_key(toolset: config.Toolset) -> str:
    """@brief A short name for all that the programs of the forks are made of, which their
    folders, the archives and the release of pack carry: the commits of the sources of
    tools.toml in the order of the file, the version of the suite, whose Python makes nextpnr's
    chip database and whose Apicula gives the chip databases the fork carries none of, and the
    text of forks.py."""
    if "suite" not in toolset.downloads:
        raise StepError("tools.toml has no [download.suite], building the forks needs it")
    text = "".join(f"{s.name} {s.commit}\n" for s in toolset.sources.values())
    text += f"suite {toolset.downloads['suite'].version}\n"
    # the line ends git keeps, so a checkout on Windows gives the same key
    recipe = RECIPE.read_bytes().replace(b"\r\n", b"\n")
    text += f"recipe {hashlib.sha256(recipe).hexdigest()}\n"
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def save_mode(local_toml: Path, mode: str) -> None:
    """@brief Writes the mode into local.toml. Its other settings stay, its comments do not:
    the file is written anew."""
    data: dict[str, dict[str, str]] = {}
    if local_toml.exists():
        with open(local_toml, "rb") as f:
            data = tomllib.load(f)
    data.setdefault("tools", {})["mode"] = mode
    text = "# Machine-specific settings, not in git. g20k.py tools build writes it anew.\n"
    for table, values in data.items():
        text += f"[{table}]\n" + "".join(toml_line(k, v) for k, v in values.items())
    local_toml.write_text(text, encoding="utf-8", newline="\n")


def find(root: Path, name: str) -> Path:
    """@brief Where one program of tools.toml is: a path of local.toml, else the folder that
    fetch or build made. A missing folder stops, a path of local.toml whose version does not
    match tools.toml gives a warning. The folders of [download.<name>.<machine>] path go to the
    front of PATH, so the programs of a download find what they need."""
    toolset = config.load_toolset(root / "tools.toml")
    local = load_local(root, toolset)
    if name not in programs(toolset):
        raise StepError(f"tools.toml has no program {name}, it has {', '.join(programs(toolset))}")
    if name in toolset.downloads:
        want, how = toolset.downloads[name].version, "fetch"
    else:
        want, how = toolset.sources[name].commit, "build"
    path = local.paths.get(name, folder(root, name, want))
    # nextpnr and yosys may be given as the program itself
    got = marker(path.parent.parent if path.is_file() else path).get("version")
    if name in local.paths:
        if got != want:
            has = got or "of unknown version"
            print(f"warning: {name} in local.toml is {has}, tools.toml has {want}", file=sys.stderr)
    elif got != want:
        raise StepError(f"{name} {want[:12]} is missing, run python3 g20k.py tools {how}")
    # a fork of the same commit, but built with other sources, another suite or another recipe
    elif name in BUILT and marker(path).get("key") != forks_key(toolset):
        raise StepError(
            f"{name} {want[:12]} is built from other sources or by another recipe, "
            "run python3 g20k.py tools build"
        )
    archive = toolset.downloads[name].archives.get(machine()) if name in toolset.downloads else None
    if archive and archive.path:
        front = [str(path / p) for p in archive.path]
        rest = [p for p in os.environ.get("PATH", "").split(os.pathsep) if p not in front]
        os.environ["PATH"] = os.pathsep.join(front + rest)
    return path


def suite_python(root: Path) -> Path:
    """@brief The Python of the suite, which runs Apicula and makes nextpnr's chip database."""
    toolset = config.load_toolset(root / "tools.toml")
    archive = toolset.downloads["suite"].archives.get(machine()) if "suite" in toolset.downloads else None
    if archive is None or not archive.python:
        raise StepError(f"tools.toml names no python for the suite on {machine()}")
    return find(root, "suite") / archive.python


def locate(root: Path) -> config.Tools:
    """@brief Where the programs of the build are on this machine, see find()."""
    nextpnr = find(root, "nextpnr")
    if nextpnr.is_dir():
        nextpnr = nextpnr / "bin" / ("nextpnr-himbaechel" + host.EXE)
    yosys = find(root, "yosys")
    if yosys.is_dir():
        yosys = yosys / "bin" / ("yosys" + host.EXE)
    return config.Tools(
        find(root, "suite"), find(root, "ghdl"), nextpnr, find(root, "apicula"), suite_python(root), yosys
    )


def status(root: Path) -> None:
    """@brief Prints each program of tools.toml with the folder it is taken from."""
    toolset = config.load_toolset(root / "tools.toml")
    local = load_local(root, toolset)
    print(f"machine {machine()}, forks {local.mode or 'not chosen yet'}")
    rows = [(d.name, d.version) for d in toolset.downloads.values()]
    rows += [(s.name, s.commit) for s in toolset.sources.values() if s.name in BUILT]
    # without a suite the forks cannot be checked, the list still shows what is there
    try:
        key: str | None = forks_key(toolset)
    except StepError:
        key = None
    for name, version in rows:
        path = local.paths.get(name, folder(root, name, version))
        base = path.parent.parent if path.is_file() else path
        got = marker(base).get("version")
        if (
            got == version
            and name in BUILT
            and key
            and name not in local.paths
            and marker(base).get("key") != key
        ):
            state = "other key"
        elif got == version:
            state = "ok"
        elif got:
            state = f"has {got[:12]}"
        else:
            state = "unchecked" if path.exists() else "missing"
        where = "local.toml" if name in local.paths else "made here"
        shown = path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path)
        print(f"  {name:8} {version[:12]:12} {state:10} {where:10} {shown}")
