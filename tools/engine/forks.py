# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The programs of game20k's forks, Apicula, nextpnr and Yosys: building, packing, unpacking them.

build makes them from the commits of tools.toml, or unpacks them from the archive that pack made
for this kind of machine and the CI (forks.yml) put on a release. Their folders and archives carry the key
of toolchain.forks_key, which the text of this file is part of: a change here can build the forks
differently, so it asks for a build of their own and for new archives."""

from __future__ import annotations

import os
import shutil
import struct
import sys
import tarfile
import time
from pathlib import Path
from typing import NamedTuple

from tools.engine import config, host, toolchain
from tools.engine.host import StepError

## the submodules of Yosys that its build needs, without slang, whose frontend the fork leaves out
YOSYS_SUBMODULES = ("abc", "libs/boost_regex", "libs/cxxopts", "libs/fmt", "libs/symfpu", "libs/tomlplusplus")


class Made(NamedTuple):
    """@brief A fork as build, make_forks and unpack_forks leave it.

    - path: its folder
    - state: what happened to it, "built here", "fetched and checked" or "is there"
    """

    path: Path
    state: str


def took(seconds: float) -> str:
    """@brief A duration as 4 min 12 s, below a minute as 12 s."""
    minutes, rest = divmod(round(seconds), 60)
    return f"{minutes} min {rest} s" if minutes else f"{rest} s"


def step(
    root: Path, what: str, cmd: list[host.Arg], log: Path | None = None, env: dict[str, str] | None = None
) -> None:
    """@brief One step of building a fork: says what it does and where its output goes, runs it
    in the folder of the sources and says how long it took. A failed step names its log, which
    holds what the program printed, its error messages are in the terminal."""
    print(f"  {what}" + (f", log {toolchain.shown(root, log)}" if log else ""), flush=True)
    start = time.monotonic()
    try:
        host.run(cmd, cwd=toolchain.tools_dir(root) / "src", stdout=log, env=env)
    except StepError as e:
        raise StepError(f"{e}, see the messages above and {log}" if log else str(e)) from None
    print(f"    done in {took(time.monotonic() - start)}", flush=True)


def checkout(root: Path, repo: str, commit: str, dest: Path) -> None:
    """@brief A checkout of commit at dest, fetched alone: an empty repository, not a clone,
    which would fetch the whole history first."""
    if not (dest / ".git").is_dir():
        dest.mkdir(parents=True, exist_ok=True)
        host.run(["git", "-C", dest, "init", "-q"], cwd=dest.parent)
        host.run(["git", "-C", dest, "remote", "add", "origin", repo], cwd=dest.parent)
    host.run(["git", "-C", dest, "remote", "set-url", "origin", repo], cwd=dest.parent)
    step(
        root,
        f"fetching {commit[:12]} from {repo}",
        ["git", "-C", dest, "fetch", "-q", "--depth", "1", "origin", commit],
    )
    host.run(["git", "-C", dest, "checkout", "-q", "--detach", commit], cwd=dest.parent)


def need_git() -> None:
    """@brief Stops when git is not on the path."""
    if shutil.which("git") is None:
        raise StepError(
            "building the forks needs git, a C++ compiler, Boost, Flex and Bison. "
            "Or fetch the prebuilt ones: python3 g20k.py tools fetch"
        )


def build_tools(root: Path) -> str:
    """@brief Puts cmake and ninja of tools.toml to the front of PATH, so every machine builds
    with the same ones, and gives the cmake option that names this ninja: a cache from an earlier
    build keeps the ninja it found, also one from elsewhere."""
    need_git()
    toolchain.find(root, "cmake")
    ninja = toolchain.find(root, "ninja")
    # local.toml may name the program itself
    if not ninja.is_file():
        ninja /= "ninja" + host.EXE
    return f"-DCMAKE_MAKE_PROGRAM:FILEPATH={ninja.as_posix()}"


def drop_moved_cache(build_dir: Path) -> None:
    """@brief Removes a cmake build folder whose cache was made in another folder, as after the
    tools folder moved: cmake refuses such a cache and names the folder it was made in."""
    cache = build_dir / "CMakeCache.txt"
    if not cache.is_file():
        return
    for line in cache.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("CMAKE_CACHEFILE_DIR:INTERNAL="):
            made_in = Path(line.partition("=")[2])
            if made_in.resolve() != build_dir.resolve():
                print(f"{build_dir}: cache made in {made_in}, building afresh", flush=True)
                shutil.rmtree(build_dir)
            return


def build(root: Path, mode: str) -> None:
    """@brief Makes the programs of the forks: from their sources ("source"), which needs git, a
    C++ compiler, Boost, Flex and Bison besides cmake and ninja of tools.toml, or from game20k's
    releases ("prebuilt"). local.toml keeps the mode, so that tools fetch leaves forks built here
    as they are."""
    if mode not in config.MODES:
        raise StepError(f"the forks come {' or '.join(config.MODES)}, not {mode}")
    local_toml = root / "local.toml"
    toolset = config.load_toolset(root / "tools.toml")
    local = toolchain.load_local(root, toolset)
    made = unpack_forks(root, toolset) if mode == "prebuilt" else make_forks(root, toolset, static=False)
    # kept only once it worked, so a failed fetch does not become the default
    if mode != local.mode:
        toolchain.save_mode(local_toml, mode)
    toolchain.report_forks(root, toolset, made)


def source(toolset: config.Toolset, name: str) -> config.Source:
    """@brief A source of tools.toml that building the forks needs."""
    if name not in toolset.sources:
        raise StepError(f"tools.toml has no [source.{name}], building the forks needs it")
    return toolset.sources[name]


def make_forks(root: Path, toolset: config.Toolset, static: bool) -> dict[str, Made]:
    """@brief Builds Apicula, nextpnr and Yosys from the commits of tools.toml, where a folder
    does not carry their key already, and gives their folders by name with what happened to
    them. static links Boost into nextpnr (on Linux everything), so the programs run on a
    machine without them, as pack needs."""
    key = toolchain.forks_key(toolset)
    suite = toolchain.find(root, "suite")
    python = toolchain.suite_python(root)
    src = toolchain.tools_dir(root) / "src"
    src.mkdir(parents=True, exist_ok=True)
    states = dict.fromkeys(toolchain.BUILT, "is there")

    # Apicula: the fork, with the chip databases of the suite's Apicula for the devices the fork
    # carries none of
    a = source(toolset, "apicula")
    apicula = toolchain.folder(root, "apicula", a.commit)
    # a folder from an archive is made again, so the mode chosen is the one that is used
    if toolchain.marker(apicula).get("key") != key or "archive" in toolchain.marker(apicula):
        need_git()
        print(f"== apicula {a.commit[:12]}", flush=True)
        checkout(root, a.repo, a.commit, src / "apicula")
        if apicula.exists():
            shutil.rmtree(apicula)
        shutil.copytree(src / "apicula", apicula, ignore=shutil.ignore_patterns(".git"))
        for db in sorted(suite.glob("lib/python3*/site-packages/apycula/*.msgpack.xz")):
            if not (apicula / "apycula" / db.name).exists():
                shutil.copy2(db, apicula / "apycula" / db.name)
        values = {"name": "apicula", "version": a.commit, "repo": a.repo, "commit": a.commit}
        toolchain.write_marker(apicula, values | {"key": key})
        states["apicula"] = "built here"

    n, e = source(toolset, "nextpnr"), source(toolset, "eigen")
    nextpnr = toolchain.folder(root, "nextpnr", n.commit)
    m = toolchain.marker(nextpnr)
    if m.get("key") != key or "archive" in m or (static and m.get("static") != "yes"):
        make_program = build_tools(root)
        print(f"== eigen {e.commit[:12]}", flush=True)
        checkout(root, e.repo, e.commit, src / "eigen")
        # only the headers and Eigen3Config.cmake, which nextpnr's find_package reads
        eigen = src / "eigen-install"
        drop_moved_cache(src / "eigen-build")
        step(
            root, "configuring with cmake",
            [
                "cmake", "-S", src / "eigen", "-B", src / "eigen-build", "-G", "Ninja", make_program,
                "-Wno-author", f"-DCMAKE_INSTALL_PREFIX={eigen}", "-DBUILD_TESTING=OFF",
                "-DEIGEN_BUILD_TESTING=OFF", "-DEIGEN_BUILD_DOC=OFF", "-DEIGEN_BUILD_BLAS=OFF",
                "-DEIGEN_BUILD_LAPACK=OFF",
            ],
            src / "eigen-cmake.log",
        )  # fmt: skip
        step(
            root,
            "installing the headers",
            ["cmake", "--install", src / "eigen-build"],
            src / "eigen-install.log",
        )
        print(f"== nextpnr {n.commit[:12]}", flush=True)
        checkout(root, n.repo, n.commit, src / "nextpnr")
        step(
            root,
            "fetching its submodules",
            ["git", "-C", src / "nextpnr", "submodule", "update", "-q", "--init", "--depth", "1"],
        )
        # a folder of its own per kind of linking, so the cmake caches of both do not mix
        build_dir = src / "nextpnr" / ("build-static" if static else "build")
        drop_moved_cache(build_dir)
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
        # Windows has no Boost of its own: it comes static from vcpkg (x64-windows-static, see
        # forks.yml), so the C++ runtime is static in every build. STATIC_BUILD under MSVC sets
        # the release flags to /MT alone, without /O2 and /DNDEBUG: CMake sets the runtime instead
        if sys.platform == "win32":
            linking = ["-DSTATIC_BUILD=OFF", "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"]
        else:
            linking = [f"-DSTATIC_BUILD={'ON' if static else 'OFF'}"]
        if nextpnr.exists():
            shutil.rmtree(nextpnr)
        step(
            root, "configuring with cmake",
            [
                "cmake", "-S", src / "nextpnr", "-B", build_dir, "-G", "Ninja", make_program, "-Wno-author",
                "-DARCH=himbaechel", "-DHIMBAECHEL_UARCH=gowin", "-DHIMBAECHEL_GOWIN_DEVICES=GW2A-18C",
                "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_PYTHON=OFF", "-DBUILD_GUI=OFF",
                f"-DPython3_EXECUTABLE={python}", f"-DEigen3_DIR={eigen / 'share' / 'eigen3' / 'cmake'}",
                f"-DCMAKE_INSTALL_PREFIX={nextpnr}", *linking,
                *([f"-DCMAKE_EXE_LINKER_FLAGS={link}"] if link else []),
            ],
            src / "nextpnr-cmake.log", env,
        )  # fmt: skip
        step(
            root,
            "building with ninja, the longest step",
            ["ninja", "-C", build_dir],
            src / "nextpnr-build.log",
            env,
        )
        step(root, "installing", ["cmake", "--install", build_dir], src / "nextpnr-install.log")
        values = {"name": "nextpnr", "version": n.commit, "repo": n.repo, "commit": n.commit}
        # the commits of every source, to read off which Eigen a nextpnr has, the key is what is checked
        values |= {s.name: s.commit for s in toolset.sources.values()}
        toolchain.write_marker(nextpnr, values | {"key": key, "static": "yes" if static else "no"})
        states["nextpnr"] = "built here"

    # Yosys: the fork runs the synthesis only, the suite's Yosys with its slang plugin reads the
    # sources. Slang, Tcl, readline, zlib and libffi stay out, the synthesis calls none of them
    y = source(toolset, "yosys")
    yosys = toolchain.folder(root, "yosys", y.commit)
    m = toolchain.marker(yosys)
    if m.get("key") != key or "archive" in m or (static and m.get("static") != "yes"):
        make_program = build_tools(root)
        print(f"== yosys {y.commit[:12]}", flush=True)
        checkout(root, y.repo, y.commit, src / "yosys")
        submodules = ["submodule", "update", "-q", "--init", "--depth", "1", *YOSYS_SUBMODULES]
        step(root, "fetching its submodules", ["git", "-C", src / "yosys", *submodules])
        # a folder of its own per kind of linking, so the cmake caches of both do not mix
        build_dir = src / "yosys" / ("build-static" if static else "build")
        drop_moved_cache(build_dir)
        linking = []
        if sys.platform == "win32":
            linking = ["-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"]
        elif static and sys.platform == "linux":
            linking = ["-DCMAKE_EXE_LINKER_FLAGS=-static"]
        if yosys.exists():
            shutil.rmtree(yosys)
        step(
            root, "configuring with cmake",
            [
                "cmake", "-S", src / "yosys", "-B", build_dir, "-G", "Ninja", make_program, "-Wno-author",
                "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={yosys}", "-DBUILD_SHARED_LIBS=OFF",
                "-DYOSYS_USE_BUNDLED_LIBS=ON",
                f"-DPython3_EXECUTABLE={python}", "-DYOSYS_ENABLE_UNIT_TESTS=OFF", "-DYOSYS_WITHOUT_SLANG=ON",
                "-DYOSYS_WITHOUT_TCL=ON", "-DYOSYS_WITHOUT_READLINE=ON", "-DYOSYS_WITHOUT_EDITLINE=ON",
                "-DYOSYS_WITHOUT_ZLIB=ON", "-DYOSYS_WITHOUT_LIBFFI=ON", *linking,
            ],
            src / "yosys-cmake.log",
        )  # fmt: skip
        step(root, "building with ninja", ["ninja", "-C", build_dir], src / "yosys-build.log")
        step(root, "installing", ["cmake", "--install", build_dir], src / "yosys-install.log")
        values = {"name": "yosys", "version": y.commit, "repo": y.repo, "commit": y.commit}
        toolchain.write_marker(yosys, values | {"key": key, "static": "yes" if static else "no"})
        states["yosys"] = "built here"
    paths = {"apicula": apicula, "nextpnr": nextpnr, "yosys": yosys}
    return {name: Made(path, states[name]) for name, path in paths.items()}


def pack(root: Path, out: Path) -> Path:
    """@brief Builds the forks with static linking and packs their folders into one archive for
    this kind of machine, with its SHA-256 in a file <archive>.sha256 beside it, as tools fetch
    takes them from the release of [prebuilt]."""
    toolset = config.load_toolset(root / "tools.toml")
    made = {name: m.path for name, m in make_forks(root, toolset, static=True).items()}
    programs = [made["nextpnr"] / "bin" / ("nextpnr-himbaechel" + host.EXE)]
    programs += [made["yosys"] / "bin" / (name + host.EXE) for name in ("yosys", "yosys-abc")]
    for program in programs:
        foreign = foreign_libraries(program)
        if foreign:
            raise StepError(f"{program} needs {', '.join(foreign)}, which another machine may not have")
    key = toolchain.forks_key(toolset)
    out.mkdir(parents=True, exist_ok=True)
    archive = out / config.Prebuilt.archive(key, toolchain.machine())

    # the bytecode that building nextpnr's chip database left in Apicula stays out
    def clean(info: tarfile.TarInfo) -> tarfile.TarInfo | None:
        if "__pycache__" in info.name.split("/"):
            return None
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        return info

    with tarfile.open(archive, "w:gz") as t:
        for name, path in made.items():
            t.add(path, arcname=name, filter=clean)
    # in the format of sha256sum, which can check it too
    sums = archive.with_name(archive.name + ".sha256")
    sums.write_text(f"{toolchain.sha256(archive)}  {archive.name}\n", encoding="utf-8", newline="\n")
    print(toolchain.shown(root, archive))
    print(toolchain.shown(root, sums))
    return archive


def foreign_libraries(program: Path) -> list[str]:
    """@brief The shared libraries a program needs beyond the system's: on macOS those
    outside /usr/lib and /System, on Linux any, as a program with an ELF interpreter loads
    them, on Windows the DLLs outside System32 and those of the Visual C++ runtime, which a
    machine without its redistributable lacks. A delay-loaded DLL does not count, Windows loads
    it only on the first call into it."""
    if sys.platform == "darwin":
        lines = host.run(["otool", "-L", program], cwd=program.parent).splitlines()[1:]
        names = [line.split()[0] for line in lines if line.strip()]
        return [n for n in names if not n.startswith(("/usr/lib/", "/System/"))]
    if sys.platform == "linux":
        return ["an ELF interpreter (dynamic linking)"] if elf_interpreter(program) else []
    if sys.platform == "win32":
        # dumpbin of the MSVC the forks were built with lists the DLLs under "dependencies"
        text = host.run(["dumpbin", "/nologo", "/dependents", program], cwd=program.parent)
        lines = text.split("delay load dependencies")[0].splitlines()
        names = [line.strip() for line in lines if line.strip().lower().endswith(".dll")]
        system = Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32"
        runtime = ("msvcp", "vcruntime", "concrt", "vcomp")
        return [n for n in names if not (system / n).exists() or n.lower().startswith(runtime)]
    raise StepError(f"pack checks the linking on macOS, Linux and Windows only, not on {sys.platform}")


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


def published_sha256(root: Path, prebuilt: config.Prebuilt, key: str, url: str) -> str:
    """@brief The SHA-256 of the archive at url, from the file the CI publishes beside it. curl
    says above why it got none: 404 when the CI has not built the forks of key for this machine
    yet, else a network error."""
    sums = toolchain.tools_dir(root) / "downloads" / (url.rsplit("/", 1)[1] + ".sha256")
    sums.parent.mkdir(parents=True, exist_ok=True)
    sums.unlink(missing_ok=True)
    try:
        toolchain.download(url + ".sha256", sums)
    except StepError:
        raise StepError(
            f"no SHA-256 of the prebuilt forks of key {key} for {toolchain.machine()}, see curl's message "
            f"above. On a 404 there are none at {prebuilt.release(key)} yet: the CI builds them on the "
            "next push of these changes, or build them here: python3 g20k.py tools build-forks"
        ) from None
    words = sums.read_text(encoding="utf-8", errors="replace").split()
    if not words or len(words[0]) != 64 or not all(c in "0123456789abcdef" for c in words[0]):
        raise StepError(f"{url}.sha256 holds no SHA-256")
    return words[0]


def unpack_forks(root: Path, toolset: config.Toolset) -> dict[str, Made]:
    """@brief The forks of the key of tools.toml and this file from the release of [prebuilt],
    checked against the SHA-256 beside their archive, and their folders by name with what
    happened to them. Their markers keep the archive's URL and SHA-256."""
    here = toolchain.machine()
    prebuilt = toolset.prebuilt
    if prebuilt is None:
        raise StepError(
            "tools.toml names no repository of prebuilt forks, run python3 g20k.py tools build-forks"
        )
    key = toolchain.forks_key(toolset)
    url = prebuilt.url(key, here)
    dests = {name: toolchain.folder(root, name, source(toolset, name).commit) for name in toolchain.BUILT}
    # the folders of this key's archive need no download
    if all(
        toolchain.marker(d).get("url") == url and toolchain.marker(d).get("key") == key
        for d in dests.values()
    ):
        return {name: Made(d, "is there") for name, d in dests.items()}
    archive = config.Archive(url=url, sha256=published_sha256(root, prebuilt, key, url))
    file = toolchain.fetched(root, archive, f"prebuilt forks {key}", f"{url}.sha256")
    staging = toolchain.tools_dir(root) / f".forks-{archive.sha256[:12]}"
    shutil.rmtree(staging, ignore_errors=True)
    toolchain.unpack(file, staging)
    try:
        # the name carries the key, the folders inside must carry it too
        if any(toolchain.marker(staging / name).get("key") != key for name in toolchain.BUILT):
            raise StepError(f"{archive.url} holds forks of another key than its name, {key}")
        for name, dest in dests.items():
            if dest.exists():
                shutil.rmtree(dest)
            got = {"archive": archive.sha256, "url": archive.url}
            toolchain.write_marker(staging / name, toolchain.marker(staging / name) | got)
            (staging / name).rename(dest)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return {name: Made(d, "fetched and checked") for name, d in dests.items()}
