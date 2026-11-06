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
    r = sub.add_parser("release", help="build every core of project.toml and pack a release")
    r.add_argument("--dev", action="store_true", help="trial run: no tag, uncommitted changes allowed")
    w = sub.add_parser("firmware", help="build the Pico firmware")
    w.add_argument(
        "--usb",
        choices=("native", "pio"),
        default="native",
        help="USB host: the Pico's own port (OTG adapter) or a USB A socket on GP2/GP3",
    )
    w.add_argument("--release", action="store_true", help="build from scratch and pack a release")
    w.add_argument("--dev", action="store_true", help="with --release: no tag, uncommitted changes allowed")
    f = sub.add_parser("flash", help="load a core or a flash image into the board")
    what = f.add_mutually_exclusive_group(required=True)
    what.add_argument(
        "core", type=Path, nargs="?", help="core folder: its build into the slot of project.toml"
    )
    what.add_argument("--image", type=Path, help="a flash image from 0, as a release packs it")
    f.add_argument(
        "--sram", action="store_true", help="the core into the FPGA's SRAM, gone at the next power cut"
    )
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
    if args.command == "firmware" and args.dev and not args.release:
        w.error("--dev goes with --release")
    if args.command == "firmware" and args.release and args.usb != "native":
        w.error("a release is the native variant")
    try:
        if args.command == "build":
            core_toml = args.core.resolve() / "core.toml"
            print(build.build(ROOT, core_toml, args.out, dict(args.params), args.update_cells))
        elif args.command == "release":
            release.release(ROOT, args.dev)
        elif args.command == "firmware":
            if args.release:
                firmware.make_release(ROOT, args.dev)
            else:
                firmware.build(ROOT, args.usb)
        elif args.command == "flash":
            core = args.core.resolve() if args.core else None
            image = args.image.resolve() if args.image else None
            flash.flash(ROOT, core, args.sram, image, args.dry_run)
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
