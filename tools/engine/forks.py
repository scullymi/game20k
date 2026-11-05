# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The programs of game20k's forks, Apicula, nextpnr and Yosys: building, packing, unpacking them.

build makes them from the commits of tools.toml, or unpacks them from the archive that pack made
for this kind of machine and tools.yml put on a release. Their folders and archives carry the key
of toolchain.forks_key, which the text of this file is part of: a change here can build the forks
differently, so it asks for a build of their own and for new archives."""

from __future__ import annotations

import os
import shutil
import struct
import sys
import tarfile
from pathlib import Path

from tools.engine import config, host, toolchain
from tools.engine.host import StepError

#: the submodules of Yosys that its build needs, without slang, whose frontend the fork leaves out
YOSYS_SUBMODULES = ("abc", "libs/boost_regex", "libs/cxxopts", "libs/fmt", "libs/symfpu", "libs/tomlplusplus")


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
            f"building the forks needs {', '.join(missing)} (and Boost), see tools.toml, "
            "or take the prebuilt programs (--prebuilt)"
        )


def build(root: Path, mode: str | None) -> None:
    """@brief Makes the programs of the forks in the mode given or the one chosen before.

    The first build needs the mode, which local.toml then keeps: from the sources, which needs
    cmake, ninja, a C++ compiler, Boost, Flex and Bison, or prebuilt from game20k's releases."""
    local_toml = root / "local.toml"
    toolset = config.load_toolset(root / "tools.toml")
    local = toolchain.load_local(root, toolset)
    mode = mode or local.mode
    if not mode:
        raise StepError("choose how the forks come here: g20k.py tools build --source or --prebuilt")
    made = unpack_forks(root, toolset) if mode == "prebuilt" else make_forks(root, toolset, static=False)
    # kept only once it worked, so a failed --prebuilt does not become the default
    if mode != local.mode:
        toolchain.save_mode(local_toml, mode)
    for name, path in made.items():
        print(f"{name} {toolset.sources[name].commit[:12]}: {path.relative_to(root).as_posix()}")


def source(toolset: config.Toolset, name: str) -> config.Source:
    """@brief A source of tools.toml that building the forks needs."""
    if name not in toolset.sources:
        raise StepError(f"tools.toml has no [source.{name}], building the forks needs it")
    return toolset.sources[name]


def make_forks(root: Path, toolset: config.Toolset, static: bool) -> dict[str, Path]:
    """@brief Builds Apicula, nextpnr and Yosys from the commits of tools.toml, where a folder
    does not carry their key already, and gives their folders by name. static links Boost into
    nextpnr (on Linux everything), so the programs run on a machine without them, as pack needs."""
    key = toolchain.forks_key(toolset)
    suite = toolchain.find(root, "suite")
    python = toolchain.suite_python(root)
    src = toolchain.tools_dir(root) / "src"
    src.mkdir(parents=True, exist_ok=True)

    # Apicula: the fork, with the chip databases of the suite's Apicula for the devices the fork
    # carries none of
    a = source(toolset, "apicula")
    apicula = toolchain.folder(root, "apicula", a.commit)
    # a folder from an archive is made again, so the mode chosen is the one that is used
    if toolchain.marker(apicula).get("key") != key or "archive" in toolchain.marker(apicula):
        need("git")
        print(f"== apicula {a.commit[:12]}", flush=True)
        checkout(a.repo, a.commit, src / "apicula")
        if apicula.exists():
            shutil.rmtree(apicula)
        shutil.copytree(src / "apicula", apicula, ignore=shutil.ignore_patterns(".git"))
        for db in sorted(suite.glob("lib/python3*/site-packages/apycula/*.msgpack.xz")):
            if not (apicula / "apycula" / db.name).exists():
                shutil.copy2(db, apicula / "apycula" / db.name)
        values = {"name": "apicula", "version": a.commit, "repo": a.repo, "commit": a.commit}
        toolchain.write_marker(apicula, values | {"key": key})

    n, e = source(toolset, "nextpnr"), source(toolset, "eigen")
    nextpnr = toolchain.folder(root, "nextpnr", n.commit)
    m = toolchain.marker(nextpnr)
    if m.get("key") != key or "archive" in m or (static and m.get("static") != "yes"):
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
        # Windows has no Boost of its own: it comes static from vcpkg (x64-windows-static, see
        # tools.yml), so the C++ runtime is static in every build. STATIC_BUILD under MSVC sets
        # the release flags to /MT alone, without /O2 and /DNDEBUG: CMake sets the runtime instead
        if sys.platform == "win32":
            linking = ["-DSTATIC_BUILD=OFF", "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"]
        else:
            linking = [f"-DSTATIC_BUILD={'ON' if static else 'OFF'}"]
        if nextpnr.exists():
            shutil.rmtree(nextpnr)
        host.run(
            [
                "cmake", "-S", src / "nextpnr", "-B", build_dir, "-G", "Ninja", "-Wno-dev",
                "-DARCH=himbaechel", "-DHIMBAECHEL_UARCH=gowin", "-DHIMBAECHEL_GOWIN_DEVICES=GW2A-18C",
                "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_PYTHON=OFF", "-DBUILD_GUI=OFF",
                f"-DPython3_EXECUTABLE={python}", f"-DEigen3_DIR={eigen / 'share' / 'eigen3' / 'cmake'}",
                f"-DCMAKE_INSTALL_PREFIX={nextpnr}", *linking,
                *([f"-DCMAKE_EXE_LINKER_FLAGS={link}"] if link else []),
            ],
            cwd=src, env=env, stdout=src / "nextpnr-cmake.log",
        )  # fmt: skip
        host.run(["ninja", "-C", build_dir], cwd=src, env=env, stdout=src / "nextpnr-build.log")
        host.run(["cmake", "--install", build_dir], cwd=src, stdout=src / "nextpnr-install.log")
        values = {"name": "nextpnr", "version": n.commit, "repo": n.repo, "commit": n.commit}
        # the commits of every source, to read off which Eigen a nextpnr has, the key is what is checked
        values |= {s.name: s.commit for s in toolset.sources.values()}
        toolchain.write_marker(nextpnr, values | {"key": key, "static": "yes" if static else "no"})

    # Yosys: the fork runs the synthesis only, the suite's Yosys with its slang plugin reads the
    # sources. Slang, Tcl, readline, zlib and libffi stay out, the synthesis calls none of them
    y = source(toolset, "yosys")
    yosys = toolchain.folder(root, "yosys", y.commit)
    m = toolchain.marker(yosys)
    if m.get("key") != key or "archive" in m or (static and m.get("static") != "yes"):
        need("git", "cmake", "ninja")
        print(f"== yosys {y.commit[:12]}", flush=True)
        checkout(y.repo, y.commit, src / "yosys")
        host.run(
            ["git", "-C", src / "yosys", "submodule", "update", "-q", "--init", "--depth", "1", *YOSYS_SUBMODULES],
            cwd=src,
        )
        # a folder of its own per kind of linking, so the cmake caches of both do not mix
        build_dir = src / "yosys" / ("build-static" if static else "build")
        linking = []
        if sys.platform == "win32":
            linking = ["-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"]
        elif static and sys.platform == "linux":
            linking = ["-DCMAKE_EXE_LINKER_FLAGS=-static"]
        if yosys.exists():
            shutil.rmtree(yosys)
        host.run(
            [
                "cmake", "-S", src / "yosys", "-B", build_dir, "-G", "Ninja", "-Wno-dev",
                "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={yosys}", "-DBUILD_SHARED_LIBS=OFF",
                "-DYOSYS_USE_BUNDLED_LIBS=ON",
                f"-DPython3_EXECUTABLE={python}", "-DYOSYS_ENABLE_UNIT_TESTS=OFF", "-DYOSYS_WITHOUT_SLANG=ON",
                "-DYOSYS_WITHOUT_TCL=ON", "-DYOSYS_WITHOUT_READLINE=ON", "-DYOSYS_WITHOUT_EDITLINE=ON",
                "-DYOSYS_WITHOUT_ZLIB=ON", "-DYOSYS_WITHOUT_LIBFFI=ON", *linking,
            ],
            cwd=src, stdout=src / "yosys-cmake.log",
        )  # fmt: skip
        host.run(["ninja", "-C", build_dir], cwd=src, stdout=src / "yosys-build.log")
        host.run(["cmake", "--install", build_dir], cwd=src, stdout=src / "yosys-install.log")
        values = {"name": "yosys", "version": y.commit, "repo": y.repo, "commit": y.commit}
        toolchain.write_marker(yosys, values | {"key": key, "static": "yes" if static else "no"})
    return {"apicula": apicula, "nextpnr": nextpnr, "yosys": yosys}


def pack(root: Path, out: Path) -> Path:
    """@brief Builds the forks with static linking and packs their folders into one archive for
    this kind of machine, game20k-forks-<key>-<machine>.tar.gz, then prints what tools.toml
    takes for it."""
    toolset = config.load_toolset(root / "tools.toml")
    made = make_forks(root, toolset, static=True)
    programs = [made["nextpnr"] / "bin" / ("nextpnr-himbaechel" + host.EXE)]
    programs += [made["yosys"] / "bin" / (name + host.EXE) for name in ("yosys", "yosys-abc")]
    for program in programs:
        foreign = foreign_libraries(program)
        if foreign:
            raise StepError(f"{program} needs {', '.join(foreign)}, which another machine may not have")
    key = toolchain.forks_key(toolset)
    out.mkdir(parents=True, exist_ok=True)
    archive = out / f"game20k-forks-{key}-{toolchain.machine()}.tar.gz"

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
    print(f"{archive.relative_to(root).as_posix() if archive.is_relative_to(root) else archive}")
    print(f"[prebuilt.{toolchain.machine()}]")
    print(f'sha256 = "{toolchain.sha256(archive)}"')
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


def unpack_forks(root: Path, toolset: config.Toolset) -> dict[str, Path]:
    """@brief The forks from the archive of [prebuilt] for this machine, which must carry the key
    of tools.toml and this file, and their folders by name."""
    here = toolchain.machine()
    prebuilt = toolset.prebuilt
    archive = prebuilt.archives.get(here) if prebuilt else None
    if prebuilt is None or archive is None:
        raise StepError(f"tools.toml has no prebuilt forks for {here}, build them with --source")
    key = toolchain.forks_key(toolset)
    dests = {name: toolchain.folder(root, name, source(toolset, name).commit) for name in toolchain.BUILT}
    # the folders of this archive, as long as it still carries the key
    if all(
        toolchain.marker(d).get("archive") == archive.sha256 and toolchain.marker(d).get("key") == key
        for d in dests.values()
    ):
        return dests
    file = toolchain.fetched(root, archive, "prebuilt forks")
    staging = toolchain.tools_dir(root) / f".forks-{archive.sha256[:12]}"
    shutil.rmtree(staging, ignore_errors=True)
    toolchain.unpack(file, staging)
    try:
        # another key means [prebuilt] was not renewed with the commits, the suite or this file
        if any(toolchain.marker(staging / name).get("key") != key for name in toolchain.BUILT):
            raise StepError(
                f"{archive.url} holds other forks than tools.toml and forks.py make (key {key}), "
                "renew [prebuilt] with tools.yml or build them with --source"
            )
        for name, dest in dests.items():
            if dest.exists():
                shutil.rmtree(dest)
            toolchain.write_marker(
                staging / name, toolchain.marker(staging / name) | {"archive": archive.sha256}
            )
            (staging / name).rename(dest)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    print(f"prebuilt forks ({here}): fetched and checked")
    print(f"  from    {archive.url}")
    print(f"  release {prebuilt.release}")
    print(f"  sha256  {archive.sha256}")
    return dests
