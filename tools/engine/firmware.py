# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Builds the firmware of the Pico 2 W and packs it for a release, and the firmware of the
Tang Nano 20K's onboard BL616.

The sources are the fork in external/FPGA-Companion with the Pico SDK and TinyUSB beside it. The
programs come from tools.toml, so that the build needs no compiler for the machine it runs on.
The firmware's version is the version of this repository, the firmware reports it to
RetroAchievements in its User-Agent and shows it under Status, Version.

The result goes to build/firmware/pico2-<usb>/, a build without RetroAchievements (--without-ra)
to pico2-<usb>-no-ra/. --upstream builds a board of FPGA Companion without game20k's code into
upstream-<board>/, a check that those boards still build. Such an image belongs to no release, its
libraries are the toolchain's own. --bl616 builds the firmware of the onboard BL616 with the
Bouffalo SDK and the RISC-V toolchain of tools.toml into bl616-<board>/, without RetroAchievements.

The image for a release is the variant with the Pico's own USB port as host, the one tested with
RetroAchievements. cyw43-driver in it may be used and passed on only with Raspberry Pi devices,
its NOTICE says so at the top."""

from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path

from tools.engine import config, host, release, toolchain
from tools.engine.host import StepError

## the checkout of the fork
FORK = Path("external") / "FPGA-Companion"

## a file of each submodule the build needs, missing after a clone without --recursive
SUBMODULE_FILES = (
    FORK / "src" / "rp2040" / "CMakeLists.txt",
    Path("external") / "pico-sdk" / "pico_sdk_init.cmake",
    Path("external") / "tinyusb" / "src" / "tusb.h",
    Path("external") / "Pico-PIO-USB" / "src" / "pio_usb.c",
)

## the folders of the libraries the Pico 2 W links, in a toolchain
LIBRARIES = (
    Path("arm-none-eabi") / "lib" / "thumb" / "v8-m.main+fp" / "softfp",
    Path("lib") / "gcc" / "arm-none-eabi" / "14.2.1" / "thumb" / "v8-m.main+fp" / "softfp",
)

## the folders of the libraries the BL616 links, in a toolchain
RISCV_LIBRARIES = (
    Path("riscv64-unknown-elf") / "lib" / "rv32imafc_zicsr_zifencei" / "ilp32f",
    Path("lib") / "gcc" / "riscv64-unknown-elf" / "14.3.0" / "rv32imafc_zicsr_zifencei" / "ilp32f",
)

## CMake's rules for this build
RULES = Path(__file__).with_name("firmware_rules.cmake")

## the flash address of the BL616 firmware per board of --bl616: behind Sipeed's firmware on the
# Tang Nano 20K, alone on the M0S Dock. The other boards of the Companion are not tested here.
BL616_ADDRESSES = {"nano20k": 0x40000, "nano20k_v3923": 0x40000, "m0sdock": 0x0}

## the text of FLASHING.txt in the release of the BL616 firmware
BL616_FLASHING = Path(__file__).with_name("flashing_bl616.txt")


def bl616_ini(image: str, address: int) -> str:
    """@brief A configuration of Bouffalo's flash tool that writes the image alone at address. The
    SDK's own flash_prog_cfg.ini also writes its boot2 to 0x0, which a Tang Nano 20K must keep."""
    return (
        "[cfg]\nerase = 1\nskip_mode = 0x0, 0x0\nboot2_isp_mode = 0\n\n"
        f"[FW]\nfiledir = {image}\naddress = 0x{address:x}\n"
    )


def bl616_libraries(root: Path) -> Path:
    """@brief The toolchain folder whose libraries the BL616 firmware links: that of
    [download.riscvlibs], or the toolchain of local.toml with its own."""
    local = toolchain.load_local(root, config.load_toolset(root / "tools.toml"))
    return toolchain.find(root, "riscv" if "riscv" in local.paths else "riscvlibs")


## the settings of config.ini that must not end up in an image
SECRETS = ("SSID", "PASS", "TOKEN")

## the BL616 build: the chip and the board of the Bouffalo SDK, which the Companion's own
# Makefile names, and the toolchain's prefix
BL616_CHIP = "bl616"
BL616_SDK_BOARD = "bl616dk"
BL616_PREFIX = "riscv64-unknown-elf-"


def out_folder(root: Path, usb: str, ra: bool = True) -> Path:
    return root / "build" / "firmware" / (f"pico2-{usb}" if ra else f"pico2-{usb}-no-ra")


def upstream_folder(root: Path, board: str) -> Path:
    return root / "build" / "firmware" / f"upstream-{board.lower()}"


def bl616_folder(root: Path, board: str) -> Path:
    return root / "build" / "firmware" / f"bl616-{board}"


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


def use_one_library_set(compiler: Path, libraries: Path, folders: tuple[Path, ...] = LIBRARIES) -> None:
    """@brief Puts the libraries of [download.armlibs] or [download.riscvlibs] in the place of the
    toolchain's own, so that every machine links the same bytes in the same order. The folders
    are replaced as a whole: the Windows toolchain of Arm has a libc.a in the folder of GCC,
    which comes first. The toolchain's marker says when this is done, it is written last, so a
    run that stops halfway is done again."""
    marks = toolchain.marker(compiler)
    done = toolchain.marker(libraries)["sha256"]
    if marks.get("libraries") == done:
        return
    for folder in folders:
        shutil.rmtree(compiler / folder, ignore_errors=True)
        shutil.copytree(libraries / folder, compiler / folder)
    toolchain.write_marker(compiler, {**marks, "libraries": done})


def prefix_flags(root: Path, arm: Path, out: Path) -> str:
    """@brief The compiler options that keep the paths of this machine out of the ELF, quoted for
    a path with a space. The most specific path comes last, GCC tries the last one first."""
    pairs = ((root, "."), (arm, "arm"), (out, "build"))
    return " ".join(f'"-ffile-prefix-map={p.as_posix()}={to}"' for p, to in pairs)


def sdk_args(root: Path, out: Path, board: str) -> list[host.Arg]:
    """@brief What every cmake call of the fork takes: the board and the programs of tools.toml.
    The paths go into the cache, so a later run of ninja that configures again finds the same
    ones."""
    return [
        "cmake",
        "-S",
        root / FORK / "src" / "rp2040",
        "-B",
        out,
        "-G",
        "Ninja",
        f"-DCMAKE_USER_MAKE_RULES_OVERRIDE:FILEPATH={RULES.as_posix()}",
        f"-DBOARD={board}",
        f"-DPICO_TINYUSB_PATH:PATH={(root / 'external' / 'tinyusb').as_posix()}",
        f"-DPICO_PIO_USB_PATH:PATH={(root / 'external' / 'Pico-PIO-USB').as_posix()}",
        f"-Dpioasm_DIR:PATH={(toolchain.find(root, 'pioasm') / 'pioasm').as_posix()}",
        f"-Dpicotool_DIR:PATH={(toolchain.find(root, 'picotool') / 'picotool').as_posix()}",
    ]


def cmake_args(
    root: Path, out: Path, usb: str, version: str, tables: tuple[Path, Path], ra: bool = True
) -> list[host.Arg]:
    """@brief The first cmake call of game20k's firmware."""
    return [
        *sdk_args(root, out, "PICO2"),
        f"-DNATIVE_USB={'ON' if usb == 'native' else 'OFF'}",
        *game20k_args(version, tables, ra),
    ]


def game20k_args(version: str, tables: tuple[Path, Path], ra: bool) -> list[host.Arg]:
    """@brief The options of game20k's code in the fork, on the Pico and on the BL616."""
    return [
        "-DGAME20K=ON",
        f"-DGAME20K_RA={'ON' if ra else 'OFF'}",
        f"-DGAME20K_VERSION={version}",
        f"-DGAME20K_GAMES_TABLE:FILEPATH={tables[0].as_posix()}",
        f"-DGAME20K_MENU_TABLE:FILEPATH={tables[1].as_posix()}",
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


def build_bl616(root: Path, board: str, version: str | None = None) -> Path:
    """@brief Builds the firmware of the onboard BL616, board as the Companion's
    src/bl616/CMakeLists.txt names it (TANG_BOARD), and returns its folder. The SDK's Makefile
    is left out, it needs GNU make 4: its configuration step and cmake are called as it calls
    them."""
    init_submodules(root)
    tables = make_tables(root)
    version = version or release.tree_version(root)
    out = bl616_folder(root, board)
    gen = out / "generated"
    gen.mkdir(parents=True, exist_ok=True)
    toolchain.find(root, "cmake")  # both are found through PATH from here on
    toolchain.find(root, "ninja")
    sdk = toolchain.find(root, "bouffalo_sdk")
    riscv = toolchain.find(root, "riscv")
    libraries = bl616_libraries(root)
    if libraries == riscv:
        print("note: the toolchain of local.toml links its own libraries, the image may differ")
    else:
        use_one_library_set(riscv, libraries, RISCV_LIBRARIES)
    src = root / FORK / "src" / "bl616"
    env = {
        "BL_SDK_BASE": sdk.as_posix(),
        "SOURCE_DATE_EPOCH": release.git(root, "log", "-1", "--format=%ct"),
        # The SDK puts the git version of its folder into the image. Git stops at the SDK's own
        # folder, not at a repository around it, as external/tools inside a clone of game20k
        "GIT_CEILING_DIRECTORIES": str(sdk.parent),
    }
    # the SDK's configuration from the Companion's defconfig and the SDK's Kconfig
    seed = host.python(
        sdk / "tools" / "kconfig" / "config_seed.py",
        "--defconfig", src / "defconfig",
        "--kconfig", src / "Kconfig",
        "--def-out", gen / "autoconfig.def",
        "--cmake-out", gen / "autoconfig.cmake",
        "--header-out", gen / "autoconfig.h",
        "--make-out", gen / "autoconfig.mk",
        f"CHIP={BL616_CHIP}",
        f"BOARD={BL616_SDK_BOARD}",
    )  # fmt: skip
    step(seed, root, out / "config.log", env)
    cmake: list[host.Arg] = [
        "cmake",
        "-S",
        src,
        "-B",
        out,
        "-G",
        "Ninja",
        f"-DBUILD_DIR={out.as_posix()}",
        f"-DSDK_DEMO_PATH={src.as_posix()}",
        f"-DCROSS_COMPILE={(riscv / 'bin').as_posix()}/{BL616_PREFIX}",
        # the SDK's tools run with the Python of this build
        f"-DPython3_EXECUTABLE={Path(sys.executable).as_posix()}",
        # no ccache, which the SDK takes when one is on the path: the build would depend on it
        "-DCCACHE_PROGRAM=OFF",
        f"-DTANG_BOARD={board}",
        *game20k_args(version, tables, ra=False),
    ]
    step(cmake, root, out / "cmake.log", env)
    step(["ninja", "-C", out], root, out / "ninja.log", env)
    # the SDK's post processing of the image for the BL616's boot ROM
    step(["ninja", "-C", out, "combine"], root, out / "combine.log", env)
    print(out.as_posix())
    return out


def environment(root: Path, out: Path) -> dict[str, str]:
    """@brief The programs of tools.toml and the variables cmake reads at the first configure of
    the build folder out."""
    toolchain.find(root, "cmake")  # both are found through PATH from here on
    toolchain.find(root, "ninja")
    arm = toolchain.find(root, "arm")
    # a toolchain of local.toml belongs to its owner and stays as it is
    if "arm" in toolchain.load_local(root, config.load_toolset(root / "tools.toml")).paths:
        print("note: the toolchain of local.toml links its own libraries, the image may differ")
    else:
        use_one_library_set(arm, toolchain.find(root, "armlibs"))
    flags = prefix_flags(root, arm, out)
    return {
        "PICO_SDK_PATH": (root / "external" / "pico-sdk").as_posix(),
        "PICO_TOOLCHAIN_PATH": arm.as_posix(),
        # the build date the SDK puts into the image is the commit's, the same on every day
        "SOURCE_DATE_EPOCH": release.git(root, "log", "-1", "--format=%ct"),
        # read at the first configure and added to the flags of the SDK
        "CFLAGS": flags,
        "CXXFLAGS": flags,
        "ASMFLAGS": flags,
    }


def build(root: Path, usb: str, version: str | None = None, ra: bool = True) -> Path:
    """@brief Builds the firmware and returns its folder. Without a version it is the tree's. With
    ra off it builds without RetroAchievements."""
    init_submodules(root)
    # the contract between core and firmware, compared without a board: the RAM mirror layout
    # of the core against ram_mirror.c. Otherwise the firmware refuses the core or reads garbage
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

    out = out_folder(root, usb, ra)
    out.mkdir(parents=True, exist_ok=True)
    env = environment(root, out)
    step(cmake_args(root, out, usb, version, tables, ra), root, out / "cmake.log", env)
    step(["ninja", "-C", out], root, out / "ninja.log", env)
    print((out / "fpga_companion.uf2").as_posix())
    return out


def build_upstream(root: Path, board: str) -> Path:
    """@brief Builds the fork for a board of FPGA Companion without GAME20K and returns its
    folder. Nothing of game20k is in such a build, the files of FPGA Companion take their own
    settings. The boards are those of src/rp2040/CMakeLists.txt, which stops at any other."""
    init_submodules(root)
    out = upstream_folder(root, board)
    out.mkdir(parents=True, exist_ok=True)
    env = environment(root, out)
    step(sdk_args(root, out, board), root, out / "cmake.log", env)
    step(["ninja", "-C", out], root, out / "ninja.log", env)
    print((out / "fpga_companion.uf2").as_posix())
    return out


def check_tables(map_text: str) -> None:
    """@brief The linked tables are the generated ones, not the fork's examples. The map of the
    Pico names their objects by path, that of the BL616 as members of the application's library."""
    for table in ("ra_games", "menus"):
        linked = f"/build/firmware/gen/{table}_data.c." in map_text or f"({table}_data.c.obj)" in map_text
        if not linked or f"{table}_example.c." in map_text:
            raise StepError(f"the image does not link the generated table {table}_data.c")


def check_image(image: bytes, version: str, ini: Path, marker: bytes | None = None) -> None:
    """@brief The image reports its version, has no diagnostic output, and none of the values
    of the builder's own config.ini ended up in it. marker holds the version, by default the
    User-Agent of RetroAchievements."""
    if (marker or f"game20k/v{version} ".encode()) not in image:
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


def check_sources(root: Path, dev: bool) -> None:
    """@brief A release is built from a clean tree with every submodule at its recorded commit,
    a trial run (dev) from anything."""
    if dev:
        return
    release.check_tree(root)
    # a line of git submodule status that starts with one of these is not the recorded commit
    if any(line[:1] in "-+U" for line in release.git(root, "submodule", "status").splitlines()):
        raise StepError("a submodule is missing or not at the recorded commit, see git submodule status")


def check_unchanged(root: Path, dev: bool, head: str) -> None:
    """@brief Stops when HEAD or the tree changed during the build: a parallel session may have
    committed or edited files, and the image would match no commit."""
    if not dev and (
        release.git(root, "rev-parse", "HEAD") != head or release.git(root, "status", "--porcelain")
    ):
        raise StepError("HEAD or the tree changed during the build, the image matches no commit")


def make_release(root: Path, dev: bool) -> Path:
    """@brief Builds the image from scratch and packs it with its NOTICE under dist/. Returns
    the path of the zip. A build from scratch, because ninja rebuilds only what changed and a
    release must not carry the objects of a diagnostic build."""
    check_sources(root, dev)
    project = config.load_project(root / "project.toml")
    version = release.tree_version(root)
    name = f"{project.name}-{version}-firmware-pico2w"
    dist, archive = release.new_dist(root, name)

    head = release.git(root, "rev-parse", "HEAD")
    out = out_folder(root, "native")
    if out.exists():
        shutil.rmtree(out)
    build(root, "native", version)
    check_unchanged(root, dev, head)
    map_file = out / "fpga_companion.elf.map"
    check_tables(map_file.read_text(encoding="utf-8", errors="replace").replace(os.sep, "/"))
    check_image((out / "fpga_companion.bin").read_bytes(), version, root / "sdcard" / "config.ini")

    dist.mkdir(parents=True)
    shutil.copyfile(out / "fpga_companion.uf2", dist / f"{name}.uf2")
    notice = host.python(root / "scripts" / "firmware_notice.py", map_file, dist / "NOTICE.txt", version)
    host.run(notice, cwd=root, capture=False)
    release.pack(root, dist, archive, name)
    return archive


def make_release_bl616(root: Path, dev: bool) -> Path:
    """@brief Builds the BL616 firmware of every board of BL616_ADDRESSES from scratch and packs
    the images under dist/, each with its NOTICE and a configuration of Bouffalo's flash tool that
    writes only its address. Returns the path of the zip."""
    check_sources(root, dev)
    project = config.load_project(root / "project.toml")
    version = release.tree_version(root)
    name = f"{project.name}-{version}-firmware-bl616"
    dist, archive = release.new_dist(root, name)

    head = release.git(root, "rev-parse", "HEAD")
    for board in BL616_ADDRESSES:
        out = bl616_folder(root, board)
        if out.exists():
            shutil.rmtree(out)
        build_bl616(root, board, version)
    check_unchanged(root, dev, head)

    dist.mkdir(parents=True)
    sdk = toolchain.find(root, "bouffalo_sdk")
    for board, address in BL616_ADDRESSES.items():
        out = bl616_folder(root, board) / "build_out"
        image = f"{project.name}-{version}-{board}.bin"
        map_file = out / "fpga_companion_bl616.map"
        check_tables(map_file.read_text(encoding="utf-8", errors="replace").replace(os.sep, "/"))
        # the version as a string of its own, without RetroAchievements there is no User-Agent
        marker = b"\0" + version.encode() + b"\0"
        check_image(
            (out / "fpga_companion_bl616.bin").read_bytes(), version, root / "sdcard" / "config.ini", marker
        )
        shutil.copyfile(out / "fpga_companion_bl616.bin", dist / image)
        notice = host.python(
            root / "scripts" / "firmware_notice.py",
            map_file,
            dist / f"NOTICE-{board}.txt",
            version,
            "--bl616",
            board,
            "--sdk",
            sdk,
            "--toolchain",
            bl616_libraries(root),
        )
        host.run(notice, cwd=root, capture=False)
        # the image alone at its address, as g20k.py flash --bl616 writes it
        (dist / f"flash-{board}.ini").write_text(
            bl616_ini(f"./{image}", address), encoding="utf-8", newline="\n"
        )
    # the release's text files have the same bytes on every machine, LF on Windows too
    (dist / "FLASHING.txt").write_text(
        BL616_FLASHING.read_text(encoding="utf-8").format(project=project.name, version=version),
        encoding="utf-8",
        newline="\n",
    )
    release.pack(root, dist, archive, name)
    return archive
