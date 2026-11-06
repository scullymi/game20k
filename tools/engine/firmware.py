# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Builds the firmware of the Pico 2 W and packs it for a release.

The sources are the fork in external/FPGA-Companion with the Pico SDK and TinyUSB beside it. The
programs come from tools.toml, so that the build needs no compiler for the machine it runs on.
The firmware's version is the version of this repository, the firmware reports it to
RetroAchievements in its User-Agent and shows it under Status, Version.

The result goes to build/firmware/pico2-<usb>/. The image for a release is the variant with the
Pico's own USB port as host, the one tested with RetroAchievements. cyw43-driver in it may be
used and passed on only with Raspberry Pi devices, its NOTICE says so at the top."""

from __future__ import annotations

import os
import re
import shutil
from pathlib import Path

from tools.engine import config, host, release, toolchain
from tools.engine.host import StepError

#: the checkout of the fork
FORK = Path("external") / "FPGA-Companion"

#: a file of each submodule the build needs, missing after a clone without --recursive
SUBMODULE_FILES = (
    FORK / "src" / "rp2040" / "CMakeLists.txt",
    Path("external") / "pico-sdk" / "pico_sdk_init.cmake",
    Path("external") / "tinyusb" / "src" / "tusb.h",
    Path("external") / "tinyusb" / "hw" / "mcu" / "raspberry_pi" / "Pico-PIO-USB" / "src" / "pio_usb.c",
)

#: the folders of the libraries the Pico 2 W links, in a toolchain
LIBRARIES = (
    Path("arm-none-eabi") / "lib" / "thumb" / "v8-m.main+fp" / "softfp",
    Path("lib") / "gcc" / "arm-none-eabi" / "14.2.1" / "thumb" / "v8-m.main+fp" / "softfp",
)

#: CMake's rules for this build
RULES = Path(__file__).with_name("firmware_rules.cmake")

#: the settings of config.ini that must not end up in an image
SECRETS = ("SSID", "PASS", "TOKEN")


def out_folder(root: Path, usb: str) -> Path:
    return root / "build" / "firmware" / f"pico2-{usb}"


def init_submodules(root: Path) -> None:
    """@brief Fetches the submodules when they are empty, as git clone --recursive would."""
    if not all((root / f).is_file() for f in SUBMODULE_FILES):
        print("initializing the submodules under external/", flush=True)
        host.run(["git", "submodule", "update", "--init", "--recursive"], cwd=root, capture=False)


def make_tables(root: Path) -> tuple[Path, Path]:
    """@brief The game table from the ROM manifests and the menus of the cores, generated
    outside the fork's tree. A build without them would take the fork's example tables."""
    gen = root / "build" / "firmware" / "gen"
    host.run(host.python(root / "scripts" / "make_fw_tables.py", "--out", gen), cwd=root, capture=False)
    return gen / "ra_games_data.c", gen / "menus_data.c"


def use_one_library_set(arm: Path, libraries: Path) -> None:
    """@brief Puts the libraries of [download.armlibs] in the place of the toolchain's own, so
    that every machine links the same bytes in the same order. The folders are replaced as a
    whole: the Windows toolchain has a libc.a in the folder of GCC, which comes first. The
    toolchain's marker says when this is done, it is written last, so a run that stops halfway
    is done again."""
    marks = toolchain.marker(arm)
    done = toolchain.marker(libraries)["sha256"]
    if marks.get("libraries") == done:
        return
    for folder in LIBRARIES:
        shutil.rmtree(arm / folder, ignore_errors=True)
        shutil.copytree(libraries / folder, arm / folder)
    toolchain.write_marker(arm, {**marks, "libraries": done})


def prefix_flags(root: Path, arm: Path, out: Path) -> str:
    """@brief The compiler options that keep the paths of this machine out of the ELF, quoted for
    a path with a space. The most specific path comes last, GCC tries the last one first."""
    pairs = ((root, "."), (arm, "arm"), (out, "build"))
    return " ".join(f'"-ffile-prefix-map={p.as_posix()}={to}"' for p, to in pairs)


def cmake_args(root: Path, out: Path, usb: str, version: str, tables: tuple[Path, Path]) -> list[host.Arg]:
    """@brief The first cmake call. The paths go into the cache, so a later run of ninja that
    configures again finds the same ones."""
    return [
        "cmake",
        "-S",
        root / FORK / "src" / "rp2040",
        "-B",
        out,
        "-G",
        "Ninja",
        f"-DCMAKE_USER_MAKE_RULES_OVERRIDE:FILEPATH={RULES.as_posix()}",
        "-DBOARD=PICO2",
        f"-DNATIVE_USB={'ON' if usb == 'native' else 'OFF'}",
        f"-DGAME20K_VERSION={version}",
        f"-DGAME20K_GAMES_TABLE:FILEPATH={tables[0].as_posix()}",
        f"-DGAME20K_MENU_TABLE:FILEPATH={tables[1].as_posix()}",
        f"-DPICO_TINYUSB_PATH:PATH={(root / 'external' / 'tinyusb').as_posix()}",
        f"-Dpioasm_DIR:PATH={(toolchain.find(root, 'pioasm') / 'pioasm').as_posix()}",
        f"-Dpicotool_DIR:PATH={(toolchain.find(root, 'picotool') / 'picotool').as_posix()}",
    ]


def step(cmd: list[host.Arg], root: Path, log: Path, env: dict[str, str]) -> None:
    """@brief Runs one step into its log, whose end is printed when the step fails."""
    errors = log.with_suffix(".err")
    try:
        host.run(cmd, cwd=root, stdout=log, stderr=errors, env=env)
    except StepError:
        for f in (log, errors):
            print("\n".join(f.read_text(encoding="utf-8", errors="replace").splitlines()[-30:]))
        raise


def build(root: Path, usb: str, version: str | None = None) -> Path:
    """@brief Builds the firmware and returns its folder. Without a version it is the tree's."""
    init_submodules(root)
    # the contract between core and firmware, compared without a board: the RAM mirror layout
    # of the core against ram_mirror.c, or the firmware refuses the core or reads garbage
    host.run(
        host.python(root / "scripts" / "check_contracts.py", "--root", root, "--fork", root / FORK),
        cwd=root,
        capture=False,
    )
    tables = make_tables(root)
    version = version or release.tree_version(root)
    fork = root / FORK
    print(f"building fork commit {release.git(fork, 'log', '-1', '--format=%h %s')} as version {version}")
    if release.git(fork, "status", "--porcelain", "--untracked-files=no"):
        print("note: the checkout of the fork has uncommitted changes, this build contains them")

    out = out_folder(root, usb)
    out.mkdir(parents=True, exist_ok=True)
    toolchain.find(root, "cmake")  # both are found through PATH from here on
    toolchain.find(root, "ninja")
    arm = toolchain.find(root, "arm")
    # a toolchain of local.toml belongs to its owner and stays as it is
    if "arm" in toolchain.load_local(root, config.load_toolset(root / "tools.toml")).paths:
        print("note: the toolchain of local.toml links its own libraries, the image may differ")
    else:
        use_one_library_set(arm, toolchain.find(root, "armlibs"))
    flags = prefix_flags(root, arm, out)
    env = {
        "PICO_SDK_PATH": (root / "external" / "pico-sdk").as_posix(),
        "PICO_TOOLCHAIN_PATH": arm.as_posix(),
        # the build date the SDK puts into the image is the commit's, the same on every day
        "SOURCE_DATE_EPOCH": release.git(root, "log", "-1", "--format=%ct"),
        # read at the first configure and added to the flags of the SDK
        "CFLAGS": flags,
        "CXXFLAGS": flags,
        "ASMFLAGS": flags,
    }
    step(cmake_args(root, out, usb, version, tables), root, out / "cmake.log", env)
    step(["ninja", "-C", out], root, out / "ninja.log", env)
    print((out / "fpga_companion.uf2").as_posix())
    return out


def check_tables(map_text: str) -> None:
    """@brief The linked tables are the generated ones, not the fork's examples."""
    for table in ("ra_games", "menus"):
        if f"/build/firmware/gen/{table}_data.c." not in map_text or f"{table}_example.c." in map_text:
            raise StepError(f"the image does not link the generated table {table}_data.c")


def check_image(image: bytes, version: str, ini: Path) -> None:
    """@brief The image reports its version, has no diagnostic output, and none of the values
    of the builder's own config.ini ended up in it."""
    if f"game20k/v{version} ".encode() not in image:
        raise StepError(f"the image does not report version {version}")
    if re.search(rb"(^|\x00)TEST:", image):
        raise StepError("the image prints TEST: lines, it contains a diagnostic build")
    if ini.is_file():
        text = ini.read_text(encoding="utf-8", errors="replace")
        hits = 0
        for key in SECRETS:
            # as the firmware reads it: KEY=value ; comment
            m = re.search(rf"^\s*{key}\s*=\s*(.+?)\s*(?:;.*)?$", text, re.M | re.I)
            if m and len(m.group(1)) >= 4:
                hits += image.count(m.group(1).encode())
        if hits:
            raise StepError(f"the image contains {hits} value(s) from {ini.name}")


def make_release(root: Path, dev: bool) -> Path:
    """@brief Builds the image from scratch and packs it with its NOTICE under dist/. Returns
    the path of the zip. A build from scratch, because ninja rebuilds only what changed and a
    release must not carry the objects of a diagnostic build."""
    if not dev:
        release.check_tree(root)
        # a line of git submodule status that starts with one of these is not the recorded commit
        if any(line[:1] in "-+U" for line in release.git(root, "submodule", "status").splitlines()):
            raise StepError("a submodule is missing or not at the recorded commit, see git submodule status")
    project = config.load_project(root / "project.toml")
    version = release.tree_version(root)
    name = f"{project.name}-{version}-pico2w"
    dist, archive = release.new_dist(root, name)

    head = release.git(root, "rev-parse", "HEAD")
    out = out_folder(root, "native")
    if out.exists():
        shutil.rmtree(out)
    build(root, "native", version)
    # a parallel session may have committed or edited files during the build
    if not dev and (
        release.git(root, "rev-parse", "HEAD") != head or release.git(root, "status", "--porcelain")
    ):
        raise StepError("HEAD or the tree changed during the build, the image matches no commit")
    map_file = out / "fpga_companion.elf.map"
    check_tables(map_file.read_text(encoding="utf-8", errors="replace").replace(os.sep, "/"))
    check_image((out / "fpga_companion.bin").read_bytes(), version, root / "sdcard" / "config.ini")

    dist.mkdir(parents=True)
    shutil.copyfile(out / "fpga_companion.uf2", dist / f"{name}.uf2")
    notice = host.python(root / "scripts" / "firmware_notice.py", map_file, dist / "NOTICE.txt", version)
    host.run(notice, cwd=root, capture=False)
    release.pack(root, dist, archive, name)
    return archive
