# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The programs of the build: fetching and checking them, building the forks, finding them.

tools.toml names every program with its version and, per kind of machine, the archive and its
SHA-256. fetch downloads the archives into external/tools/downloads/, checks them and unpacks
each into a folder of its own, external/tools/<name>-<version>-<machine>/. build makes the
programs of game20k's forks from the commits in tools.toml. Each folder gets a marker file
with what is in it and where it came from, which locate() checks the version against. A path in
local.toml takes the place of a folder, its version is then only checked, with a warning."""

from __future__ import annotations

import hashlib
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


def machine() -> str:
    """@brief The kind of machine as tools.toml names it, e.g. darwin-arm64."""
    system = {"darwin": "darwin", "linux": "linux", "win32": "windows"}.get(sys.platform, sys.platform)
    arch = platform.machine().lower()
    arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x64", "amd64": "x64"}.get(arch, arch)
    return f"{system}-{arch}"


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


def write_marker(path: Path, values: dict[str, str]) -> None:
    text = "".join(f'{k} = "{v}"\n' for k, v in values.items())
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


def fetch(root: Path) -> None:
    """@brief Fetches, checks and unpacks every download of tools.toml that is not there yet,
    and prints what came from where."""
    toolset = config.load_toolset(root / "tools.toml")
    here = machine()
    downloads = tools_dir(root) / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
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
            file = downloads / archive.url.rsplit("/", 1)[1]
            if not file.exists() or sha256(file) != archive.sha256:
                print(f"== {d.name} {d.version}: {archive.url}", flush=True)
                download(archive.url, file)
            got = sha256(file)
            if got != archive.sha256:
                raise StepError(f"{file}: SHA-256 {got}, tools.toml expects {archive.sha256}")
            unpack(file, dest)
            write_marker(
                dest, {"name": d.name, "version": d.version, "url": archive.url, "sha256": archive.sha256}
            )
            state = "fetched and checked"
        print(f"{d.name} {d.version} ({here}): {state}")
        print(f"  from    {archive.url}")
        print(f"  release {d.release}")
        print(f"  sha256  {archive.sha256}")
        print(f"  in      {dest.relative_to(root).as_posix()}")


def checkout(repo: str, commit: str, dest: Path) -> None:
    """@brief A checkout of commit at dest, fetched alone."""
    if not (dest / ".git").is_dir():
        host.run(["git", "clone", "-q", "--no-checkout", repo, dest], cwd=dest.parent)
    host.run(["git", "-C", dest, "remote", "set-url", "origin", repo], cwd=dest.parent)
    host.run(["git", "-C", dest, "fetch", "-q", "--depth", "1", "origin", commit], cwd=dest.parent)
    host.run(["git", "-C", dest, "checkout", "-q", "--detach", commit], cwd=dest.parent)


def need(*programs: str) -> None:
    """@brief Stops when a program the build of the forks needs is not on the path."""
    missing = [p for p in programs if shutil.which(p) is None]
    if missing:
        raise StepError(
            f"building the forks needs {', '.join(missing)} (and Boost), see tools.toml; "
            "or take the prebuilt programs"
        )


def build(root: Path, mode: str | None) -> None:
    """@brief Makes the programs of the forks in the mode given or the one chosen before.

    The first build needs the mode, which local.toml then keeps: from the sources, which needs
    cmake, ninja, a C++ compiler and Boost, or prebuilt from game20k's releases."""
    local_toml = root / "local.toml"
    local = config.load_local(local_toml)
    mode = mode or local.mode
    if not mode:
        raise StepError("choose how the forks come here: g20k.py tools build --source or --prebuilt")
    if mode == "prebuilt":
        raise StepError("there are no prebuilt programs of the forks yet, build them with --source")
    if mode != local.mode:
        save_mode(local_toml, mode)
    toolset = config.load_toolset(root / "tools.toml")
    suite = find(root, "suite")
    python = suite / "py3bin" / ("python3" + host.EXE)
    src = tools_dir(root) / "src"
    src.mkdir(parents=True, exist_ok=True)

    # Apicula: the fork, with the chip databases of the suite's Apicula for the devices the fork
    # carries none of
    a = toolset.sources["apicula"]
    apicula = folder(root, "apicula", a.commit)
    if marker(apicula).get("commit") != a.commit:
        print(f"== apicula {a.commit[:12]}", flush=True)
        checkout(a.repo, a.commit, src / "apicula")
        if apicula.exists():
            shutil.rmtree(apicula)
        shutil.copytree(src / "apicula", apicula, ignore=shutil.ignore_patterns(".git"))
        for db in sorted(suite.glob("lib/python3*/site-packages/apycula/*.msgpack.xz")):
            if not (apicula / "apycula" / db.name).exists():
                shutil.copy2(db, apicula / "apycula" / db.name)
        write_marker(apicula, {"name": "apicula", "version": a.commit, "repo": a.repo, "commit": a.commit})
    print(f"apicula {a.commit[:12]}: {apicula.relative_to(root).as_posix()}")

    n = toolset.sources["nextpnr"]
    nextpnr = folder(root, "nextpnr", n.commit)
    if marker(nextpnr).get("commit") != n.commit or marker(nextpnr).get("apicula") != a.commit:
        need("git", "cmake", "ninja")
        e = toolset.sources["eigen"]
        print(f"== eigen {e.commit[:12]}", flush=True)
        checkout(e.repo, e.commit, src / "eigen")
        # only the headers and Eigen3Config.cmake, which nextpnr's find_package reads
        eigen = src / "eigen-install"
        host.run(
            [
                "cmake", "-S", src / "eigen", "-B", src / "eigen-build", "-G", "Ninja", "-Wno-dev",
                f"-DCMAKE_INSTALL_PREFIX={eigen}", "-DBUILD_TESTING=OFF", "-DEIGEN_BUILD_TESTING=OFF",
                "-DEIGEN_BUILD_DOC=OFF", "-DEIGEN_BUILD_BLAS=OFF", "-DEIGEN_BUILD_LAPACK=OFF",
            ],
            cwd=src, stdout=src / "eigen-cmake.log",
        )  # fmt: skip
        host.run(["cmake", "--install", src / "eigen-build"], cwd=src, stdout=src / "eigen-install.log")
        print(f"== nextpnr {n.commit[:12]}", flush=True)
        checkout(n.repo, n.commit, src / "nextpnr")
        host.run(
            ["git", "-C", src / "nextpnr", "submodule", "update", "-q", "--init", "--depth", "1"], cwd=src
        )
        build_dir = src / "nextpnr" / "build"
        # The build makes the chip database again only when gowin_arch_gen.py changes, not
        # when Apicula does
        for bba in build_dir.glob("himbaechel/uarch/gowin/chipdb-*.bba"):
            bba.unlink()
        # The chip database depends on Python's hash order: a fixed seed makes every build the
        # same, else it and the bitstreams differ per run
        env = {"PYTHONHASHSEED": "0", "PYTHONPATH": str(apicula)}
        if nextpnr.exists():
            shutil.rmtree(nextpnr)
        host.run(
            [
                "cmake", "-S", src / "nextpnr", "-B", build_dir, "-G", "Ninja", "-Wno-dev",
                "-DARCH=himbaechel", "-DHIMBAECHEL_UARCH=gowin", "-DHIMBAECHEL_GOWIN_DEVICES=GW2A-18C",
                "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_PYTHON=OFF", "-DBUILD_GUI=OFF",
                f"-DPython3_EXECUTABLE={python}", f"-DEigen3_DIR={eigen / 'share' / 'eigen3' / 'cmake'}",
                f"-DCMAKE_INSTALL_PREFIX={nextpnr}",
            ],
            cwd=src, env=env, stdout=src / "nextpnr-cmake.log",
        )  # fmt: skip
        host.run(["ninja", "-C", build_dir], cwd=src, env=env, stdout=src / "nextpnr-build.log")
        host.run(["cmake", "--install", build_dir], cwd=src, stdout=src / "nextpnr-install.log")
        write_marker(
            nextpnr,
            {"name": "nextpnr", "version": n.commit, "repo": n.repo, "commit": n.commit, "apicula": a.commit},
        )
    print(f"nextpnr {n.commit[:12]}: {nextpnr.relative_to(root).as_posix()}")


def save_mode(local_toml: Path, mode: str) -> None:
    """@brief Writes the mode into local.toml, its other settings stay."""
    data: dict[str, dict[str, str]] = {}
    if local_toml.exists():
        with open(local_toml, "rb") as f:
            data = tomllib.load(f)
    data.setdefault("tools", {})["mode"] = mode
    text = "# Machine-specific settings, not in git\n"
    for table, values in data.items():
        text += f"[{table}]\n" + "".join(f'{k} = "{v}"\n' for k, v in values.items())
    local_toml.write_text(text, encoding="utf-8", newline="\n")


def find(root: Path, name: str) -> Path:
    """@brief Where one program of tools.toml is: a path of local.toml, else the folder that
    fetch or build made. A missing folder stops, a path of local.toml whose version does not
    match tools.toml gives a warning."""
    toolset = config.load_toolset(root / "tools.toml")
    local = config.load_local(root / "local.toml")
    if name in toolset.downloads:
        want, how = toolset.downloads[name].version, "fetch"
    else:
        want, how = toolset.sources[name].commit, "build"
    path = local.paths.get(name, folder(root, name, want))
    # nextpnr may be given as the program itself
    got = marker(path.parent.parent if path.is_file() else path).get("version")
    if name in local.paths:
        if got != want:
            has = got or "of unknown version"
            print(f"warning: {name} in local.toml is {has}, tools.toml has {want}", file=sys.stderr)
    elif got != want:
        raise StepError(f"{name} {want[:12]} is missing, run python3 g20k.py tools {how}")
    return path


def locate(root: Path) -> config.Tools:
    """@brief Where the programs of the build are on this machine, see find()."""
    nextpnr = find(root, "nextpnr")
    if nextpnr.is_dir():
        nextpnr = nextpnr / "bin" / ("nextpnr-himbaechel" + host.EXE)
    return config.Tools(find(root, "suite"), find(root, "ghdl"), nextpnr, find(root, "apicula"))


def status(root: Path) -> None:
    """@brief Prints each program of tools.toml with the folder it is taken from."""
    toolset = config.load_toolset(root / "tools.toml")
    local = config.load_local(root / "local.toml")
    print(f"machine {machine()}, forks {local.mode or 'not chosen yet'}")
    rows = [(d.name, d.version) for d in toolset.downloads.values()]
    rows += [(s.name, s.commit) for s in toolset.sources.values() if s.name in config.TOOL_KEYS]
    for name, version in rows:
        path = local.paths.get(name, folder(root, name, version))
        base = path.parent.parent if path.is_file() else path
        got = marker(base).get("version")
        if got == version:
            state = "ok"
        elif got:
            state = f"has {got[:12]}"
        else:
            state = "unchecked" if path.exists() else "missing"
        where = "local.toml" if name in local.paths else "made here"
        shown = path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path)
        print(f"  {name:8} {version[:12]:12} {state:10} {where:10} {shown}")
