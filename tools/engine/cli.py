# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The commands of the build."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from tools.engine import config, firmware, flash, forks, release, toolchain
from tools.engine.flow import build
from tools.engine.host import StepError

#: the project's root folder, the one that holds project.toml
ROOT = Path(__file__).resolve().parents[2]


def parameter(text: str) -> tuple[str, int]:
    """@brief NAME=VALUE of -G, the value a whole number."""
    name, sep, value = text.partition("=")
    if not sep or not name.isidentifier():
        raise argparse.ArgumentTypeError(f"{text}: expected NAME=VALUE")
    try:
        return name, int(value, 0)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text}: the value is not a whole number") from None


def board_name(text: str) -> str:
    """@brief A board of --upstream: a name as CMakeLists.txt has it, which also names its folder."""
    if not text.replace("_", "").isalnum() or not text.isascii():
        raise argparse.ArgumentTypeError(f"{text}: expected a board name such as PICO2")
    return text.upper()


def bl616_board(text: str) -> str:
    """@brief A board of --bl616: a name as src/bl616/CMakeLists.txt has it, which also names its
    build folder."""
    if not text.replace("_", "").isalnum() or not text.isascii():
        raise argparse.ArgumentTypeError(f"{text}: expected a board name such as nano20k_v3923")
    return text.lower()


#: --board of build, release and flash
BOARD_HELP = "a board folder in place of the one project.toml names, e.g. boards/tangnano20k-bl616"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="g20k.py")
    sub = ap.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build", help="build one core")
    b.add_argument("core", type=Path, help="core folder, e.g. fpga/pang_hdmi")
    b.add_argument("--out", type=Path, help="output folder, default build/<core>")
    b.add_argument(
        "-G",
        dest="params",
        type=parameter,
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="set a parameter of the top for a diagnostic build, e.g. -G RAMDIAG=1",
    )
    b.add_argument(
        "--update-cells", action="store_true", help="write the netlist's cells as the core's measure"
    )
    b.add_argument("--board", type=Path, help=BOARD_HELP)
    r = sub.add_parser("release", help="build every core of project.toml and pack a release")
    r.add_argument("--dev", action="store_true", help="trial run: no tag, uncommitted changes allowed")
    r.add_argument("--board", type=Path, help=BOARD_HELP)
    w = sub.add_parser("firmware", help="build the Pico firmware")
    w.add_argument(
        "--usb",
        choices=("native", "pio"),
        default="native",
        help="USB host: the Pico's own port (OTG adapter) or a USB A socket on GP2/GP3",
    )
    w.add_argument("--without-ra", action="store_true", help="no RetroAchievements, only for a trial build")
    w.add_argument(
        "--upstream",
        type=board_name,
        metavar="BOARD",
        help="a board of FPGA Companion's src/rp2040/CMakeLists.txt without game20k's code, e.g. PICO",
    )
    w.add_argument(
        "--bl616",
        type=bl616_board,
        metavar="BOARD",
        help="the onboard BL616 instead of the Pico, BOARD as src/bl616/CMakeLists.txt has it, e.g. nano20k",
    )
    w.add_argument("--release", action="store_true", help="build from scratch and pack a release")
    w.add_argument("--dev", action="store_true", help="with --release: no tag, uncommitted changes allowed")
    f = sub.add_parser("flash", help="load a core or a flash image into the board")
    what = f.add_mutually_exclusive_group(required=True)
    what.add_argument(
        "core", type=Path, nargs="?", help="core folder: its build into the slot of project.toml"
    )
    what.add_argument("--image", type=Path, help="a flash image from 0, as a release packs it")
    what.add_argument(
        "--bl616",
        type=bl616_board,
        metavar="BOARD",
        help="the Companion of g20k.py firmware --bl616 BOARD into the onboard BL616, in download mode",
    )
    f.add_argument("--port", help="with --bl616: the BL616's serial port, e.g. /dev/cu.usbmodem1101 or COM3")
    f.add_argument(
        "--sram", action="store_true", help="the core into the FPGA's SRAM, gone at the next power cut"
    )
    f.add_argument("--board", type=Path, help=BOARD_HELP)
    f.add_argument("--dry-run", action="store_true", help="print the command only")
    sub.add_parser("cores", help="print the core folders of project.toml in ring order")
    t = sub.add_parser("tools", help="the programs of tools.toml: without a command where they are")
    tsub = t.add_subparsers(dest="tools_command")
    tf = tsub.add_parser("fetch", help="download and check the programs that come as archives")
    tf.add_argument("names", nargs="*", help="only these programs of tools.toml, e.g. suite ghdl")
    tb = tsub.add_parser("build", help="make the programs of game20k's forks")
    how = tb.add_mutually_exclusive_group()
    how.add_argument("--source", action="store_const", const="source", dest="mode", help="from their sources")
    how.add_argument(
        "--prebuilt", action="store_const", const="prebuilt", dest="mode", help="from the releases"
    )
    tk = tsub.add_parser("pack", help="build the forks with static linking into one archive, for tools.yml")
    tk.add_argument("--out", type=Path, required=True, help="folder for the archive")
    tp = tsub.add_parser("path", help="print the folder a program of tools.toml is taken from")
    tp.add_argument("name", help="a program of tools.toml, e.g. suite")
    s = sub.add_parser("sources", help="print a core's own source files, for a simulation")
    s.add_argument("core", type=Path, help="core folder, e.g. fpga/g1943_hdmi")
    s.add_argument("--out", type=Path, required=True, help="folder for the generated sources (in gen/)")
    s.add_argument("--include", action="store_true", help="print the include folders instead")
    args = ap.parse_args(argv)
    if args.command == "flash" and args.sram and args.image:
        f.error("--sram takes a core, not an image")
    if args.command == "flash" and bool(args.bl616) != bool(args.port):
        f.error("--bl616 and --port go together")
    if args.command == "flash" and args.bl616 and (args.sram or args.board):
        f.error("--bl616 takes no --sram or --board")
    if args.command == "firmware" and args.dev and not args.release:
        w.error("--dev goes with --release")
    if args.command == "firmware" and args.release and (args.usb != "native" or args.without_ra):
        w.error("a release is the native variant with RetroAchievements")
    if (
        args.command == "firmware"
        and args.upstream
        and (args.release or args.without_ra or args.usb != "native")
    ):
        w.error("--upstream takes no other option")
    if (
        args.command == "firmware"
        and args.bl616
        and (args.release or args.upstream or args.without_ra or args.usb != "native")
    ):
        w.error("--bl616 takes no other option")
    try:
        if args.command == "build":
            core_toml = args.core.resolve() / "core.toml"
            print(build.build(ROOT, core_toml, args.out, dict(args.params), args.update_cells, args.board))
        elif args.command == "release":
            release.release(ROOT, args.dev, args.board)
        elif args.command == "firmware":
            if args.release:
                firmware.make_release(ROOT, args.dev)
            elif args.upstream:
                firmware.build_upstream(ROOT, args.upstream)
            elif args.bl616:
                firmware.build_bl616(ROOT, args.bl616)
            else:
                firmware.build(ROOT, args.usb, ra=not args.without_ra)
        elif args.command == "flash" and args.bl616:
            flash.flash_bl616(ROOT, args.bl616, args.port, args.dry_run)
        elif args.command == "flash":
            core = args.core.resolve() if args.core else None
            image = args.image.resolve() if args.image else None
            flash.flash(ROOT, core, args.sram, image, args.dry_run, args.board)
        elif args.command == "tools":
            if args.tools_command == "fetch":
                toolchain.fetch(ROOT, args.names)
            elif args.tools_command == "build":
                forks.build(ROOT, args.mode)
            elif args.tools_command == "pack":
                forks.pack(ROOT, args.out.resolve())
            elif args.tools_command == "path":
                print(toolchain.find(ROOT, args.name).as_posix())
            else:
                toolchain.status(ROOT)
        elif args.command == "sources":
            files, include = build.sources(ROOT, args.core.resolve() / "core.toml", args.out)
            for p in include if args.include else files:
                print(p.as_posix())
        elif args.command == "cores":
            for core in config.load_project(ROOT / "project.toml").slots:
                print(core.relative_to(ROOT).as_posix())
    except (config.ConfigError, StepError) as e:
        print(f"g20k.py: {e}", file=sys.stderr)
        return 1
    return 0
