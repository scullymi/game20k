# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The programs of the build: fetching and checking them, building the forks, finding them.

tools.toml names every program with its version and, per kind of machine, the archive and its
SHA-256. fetch downloads the archives into external/tools/downloads/, checks them and unpacks
each into a folder of its own, external/tools/<name>-<version>-<machine>/. build makes the
programs of game20k's forks from the commits in tools.toml, or unpacks them from the archive
that pack made for this kind of machine and tools.yml put on a release. Each folder gets a
marker file with what is in it and where it came from, which locate() checks the version
against. A path in local.toml takes the place of a folder, its version is then only checked,
with a warning."""

from __future__ import annotations

import hashlib
import json
import platform
import shutil
import struct
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

#: the programs make_forks builds from the sources of tools.toml
BUILT = ("apicula", "nextpnr")


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


def checkout(repo: str, commit: str, dest: Path) -> None:
    """@brief A checkout of commit at dest, fetched alone: an empty repository, not a clone,
    which would fetch the whole history first."""
    if not (dest / ".git").is_dir():
        dest.mkdir(parents=True, exist_ok=True)
        host.run(["git", "-C", dest, "init", "-q"], cwd=dest.parent)
        host.run(["git", "-C", dest, "remote", "add", "origin", repo], cwd=dest.parent)
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
    toolset = config.load_toolset(root / "tools.toml")
    local = load_local(root, toolset)
    mode = mode or local.mode
    if not mode:
        raise StepError("choose how the forks come here: g20k.py tools build --source or --prebuilt")
    if mode == "prebuilt":
        apicula, nextpnr = unpack_forks(root, toolset)
    else:
        apicula, nextpnr = make_forks(root, toolset, static=False)
    # kept only once it worked, so a failed --prebuilt does not become the default
    if mode != local.mode:
        save_mode(local_toml, mode)
    for name, path in zip(BUILT, (apicula, nextpnr), strict=True):
        print(f"{name} {toolset.sources[name].commit[:12]}: {path.relative_to(root).as_posix()}")


def source(toolset: config.Toolset, name: str) -> config.Source:
    """@brief A source of tools.toml that building the forks needs."""
    if name not in toolset.sources:
        raise StepError(f"tools.toml has no [source.{name}], building the forks needs it")
    return toolset.sources[name]


def holds(values: dict[str, str], toolset: config.Toolset) -> bool:
    """@brief Whether the marker of a nextpnr folder names the commits of every source of
    tools.toml, which a build of nextpnr is made of."""
    return all(values.get(s.name) == s.commit for s in toolset.sources.values())


def make_forks(root: Path, toolset: config.Toolset, static: bool) -> tuple[Path, Path]:
    """@brief Builds Apicula and nextpnr from the commits of tools.toml, where a folder does
    not hold them already. static links Boost into nextpnr (on Linux everything), so the
    program runs on a machine without them, as pack needs."""
    suite = find(root, "suite")
    python = suite / "py3bin" / ("python3" + host.EXE)
    src = tools_dir(root) / "src"
    src.mkdir(parents=True, exist_ok=True)

    # Apicula: the fork, with the chip databases of the suite's Apicula for the devices the fork
    # carries none of
    a = source(toolset, "apicula")
    apicula = folder(root, "apicula", a.commit)
    # a folder from an archive is made again, so the mode chosen is the one that is used
    if marker(apicula).get("commit") != a.commit or "archive" in marker(apicula):
        print(f"== apicula {a.commit[:12]}", flush=True)
        checkout(a.repo, a.commit, src / "apicula")
        if apicula.exists():
            shutil.rmtree(apicula)
        shutil.copytree(src / "apicula", apicula, ignore=shutil.ignore_patterns(".git"))
        for db in sorted(suite.glob("lib/python3*/site-packages/apycula/*.msgpack.xz")):
            if not (apicula / "apycula" / db.name).exists():
                shutil.copy2(db, apicula / "apycula" / db.name)
        write_marker(apicula, {"name": "apicula", "version": a.commit, "repo": a.repo, "commit": a.commit})

    n, e = source(toolset, "nextpnr"), source(toolset, "eigen")
    nextpnr = folder(root, "nextpnr", n.commit)
    m = marker(nextpnr)
    if not holds(m, toolset) or "archive" in m or (static and m.get("static") != "yes"):
        need("git", "cmake", "ninja")
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
        # a folder of its own per kind of linking, so the cmake caches of both do not mix
        build_dir = src / "nextpnr" / ("build-static" if static else "build")
        # The build makes the chip database again only when gowin_arch_gen.py changes, not
        # when Apicula does
        for bba in build_dir.glob("himbaechel/uarch/gowin/chipdb-*.bba"):
            bba.unlink()
        # The chip database depends on Python's hash order: a fixed seed makes every build the
        # same, else it and the bitstreams differ per run
        env = {"PYTHONHASHSEED": "0", "PYTHONPATH": str(apicula)}
        # Static Boost on macOS names the compression libraries of Boost iostreams, which
        # nextpnr does not call: the linker finds them through LIBRARY_PATH and drops them
        link = "-Wl,-dead_strip_dylibs" if static and sys.platform == "darwin" else ""
        if nextpnr.exists():
            shutil.rmtree(nextpnr)
        host.run(
            [
                "cmake", "-S", src / "nextpnr", "-B", build_dir, "-G", "Ninja", "-Wno-dev",
                "-DARCH=himbaechel", "-DHIMBAECHEL_UARCH=gowin", "-DHIMBAECHEL_GOWIN_DEVICES=GW2A-18C",
                "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_PYTHON=OFF", "-DBUILD_GUI=OFF",
                f"-DPython3_EXECUTABLE={python}", f"-DEigen3_DIR={eigen / 'share' / 'eigen3' / 'cmake'}",
                f"-DCMAKE_INSTALL_PREFIX={nextpnr}", f"-DSTATIC_BUILD={'ON' if static else 'OFF'}",
                *([f"-DCMAKE_EXE_LINKER_FLAGS={link}"] if link else []),
            ],
            cwd=src, env=env, stdout=src / "nextpnr-cmake.log",
        )  # fmt: skip
        host.run(["ninja", "-C", build_dir], cwd=src, env=env, stdout=src / "nextpnr-build.log")
        host.run(["cmake", "--install", build_dir], cwd=src, stdout=src / "nextpnr-install.log")
        values = {"name": "nextpnr", "version": n.commit, "repo": n.repo}
        values |= {s.name: s.commit for s in toolset.sources.values()}
        write_marker(nextpnr, values | {"static": "yes" if static else "no"})
    return apicula, nextpnr


def forks_key(toolset: config.Toolset) -> str:
    """@brief A short name for the commits of the sources of tools.toml, in the order of the
    file, which the archives and the release of pack carry."""
    text = "".join(f"{s.name} {s.commit}\n" for s in toolset.sources.values())
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def pack(root: Path, out: Path) -> Path:
    """@brief Builds the forks with static linking and packs both folders into one archive for
    this kind of machine, game20k-forks-<key>-<machine>.tar.gz, then prints what tools.toml
    takes for it."""
    toolset = config.load_toolset(root / "tools.toml")
    apicula, nextpnr = make_forks(root, toolset, static=True)
    program = nextpnr / "bin" / ("nextpnr-himbaechel" + host.EXE)
    foreign = foreign_libraries(program)
    if foreign:
        raise StepError(f"{program} needs {', '.join(foreign)}, which another machine may not have")
    key = forks_key(toolset)
    out.mkdir(parents=True, exist_ok=True)
    archive = out / f"game20k-forks-{key}-{machine()}.tar.gz"

    # the bytecode that building nextpnr's chip database left in Apicula stays out
    def clean(info: tarfile.TarInfo) -> tarfile.TarInfo | None:
        if "__pycache__" in info.name.split("/"):
            return None
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        return info

    with tarfile.open(archive, "w:gz") as t:
        for name, path in zip(BUILT, (apicula, nextpnr), strict=True):
            t.add(path, arcname=name, filter=clean)
    print(f"{archive.relative_to(root).as_posix() if archive.is_relative_to(root) else archive}")
    print(f"[prebuilt.{machine()}]")
    print(f'sha256 = "{sha256(archive)}"')
    return archive


def foreign_libraries(program: Path) -> list[str]:
    """@brief The shared libraries a program needs beyond the system's: on macOS those
    outside /usr/lib and /System, on Linux any, as a program with an ELF interpreter loads
    them."""
    if sys.platform == "darwin":
        lines = host.run(["otool", "-L", program], cwd=program.parent).splitlines()[1:]
        names = [line.split()[0] for line in lines if line.strip()]
        return [n for n in names if not n.startswith(("/usr/lib/", "/System/"))]
    if sys.platform == "linux":
        return ["an ELF interpreter (dynamic linking)"] if elf_interpreter(program) else []
    raise StepError(f"pack checks the linking on macOS and Linux only, not on {sys.platform}")


def elf_interpreter(program: Path) -> bool:
    """@brief Whether a 64-bit ELF program names an interpreter (PT_INTERP), the loader of its
    shared libraries."""
    with open(program, "rb") as f:
        head = f.read(64)
        # program headers at e_phoff, e_phnum entries of e_phentsize bytes
        (phoff,) = struct.unpack_from("<Q", head, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", head, 0x36)
        f.seek(phoff)
        table = f.read(phentsize * phnum)
    return any(struct.unpack_from("<I", table, i * phentsize)[0] == 3 for i in range(phnum))


def unpack_forks(root: Path, toolset: config.Toolset) -> tuple[Path, Path]:
    """@brief Apicula and nextpnr from the archive of [prebuilt] for this machine, which must
    hold the commits of tools.toml."""
    here = machine()
    prebuilt = toolset.prebuilt
    archive = prebuilt.archives.get(here) if prebuilt else None
    if prebuilt is None or archive is None:
        raise StepError(f"tools.toml has no prebuilt forks for {here}, build them with --source")
    a = source(toolset, "apicula")
    dests = {name: folder(root, name, source(toolset, name).commit) for name in BUILT}
    # the folders of this archive, as long as it still holds the commits of tools.toml
    unpacked = all(marker(d).get("archive") == archive.sha256 for d in dests.values())
    if unpacked and holds(marker(dests["nextpnr"]), toolset):
        return dests["apicula"], dests["nextpnr"]
    file = fetched(root, archive, "prebuilt forks")
    staging = tools_dir(root) / f".forks-{archive.sha256[:12]}"
    shutil.rmtree(staging, ignore_errors=True)
    unpack(file, staging)
    try:
        # an archive of other commits means [prebuilt] was not renewed with the forks
        apicula_ok = marker(staging / "apicula").get("commit") == a.commit
        if not apicula_ok or not holds(marker(staging / "nextpnr"), toolset):
            raise StepError(
                f"{archive.url} holds other commits of the forks than tools.toml, "
                "build them with --source or renew [prebuilt] (tools.yml)"
            )
        for name, dest in dests.items():
            if dest.exists():
                shutil.rmtree(dest)
            write_marker(staging / name, marker(staging / name) | {"archive": archive.sha256})
            (staging / name).rename(dest)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    print(f"prebuilt forks ({here}): fetched and checked")
    print(f"  from    {archive.url}")
    print(f"  release {prebuilt.release}")
    print(f"  sha256  {archive.sha256}")
    return dests["apicula"], dests["nextpnr"]


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
    match tools.toml gives a warning."""
    toolset = config.load_toolset(root / "tools.toml")
    local = load_local(root, toolset)
    if name not in programs(toolset):
        raise StepError(f"tools.toml has no program {name}, it has {', '.join(programs(toolset))}")
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
    # nextpnr carries Apicula's chip database and Eigen's placements: another commit of either
    # in tools.toml means a build of its own
    elif name == "nextpnr" and not holds(marker(path), toolset):
        raise StepError(f"nextpnr {want[:12]} is built from other sources, run python3 g20k.py tools build")
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
    local = load_local(root, toolset)
    print(f"machine {machine()}, forks {local.mode or 'not chosen yet'}")
    rows = [(d.name, d.version) for d in toolset.downloads.values()]
    rows += [(s.name, s.commit) for s in toolset.sources.values() if s.name in BUILT]
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
