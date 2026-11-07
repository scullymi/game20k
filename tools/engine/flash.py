# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Loads bitstreams into the board with the suite's openFPGALoader.

Three ways: a core into the FPGA's SRAM (gone at the next power cut, the FPGA then boots the
core at slot 0), a core into the configuration flash at the address of its slot (the other
slots stay, openFPGALoader erases only the sectors it writes), or a whole flash image from 0.

After writing the flash, power the board off and on. openFPGALoader reloads the FPGA after
writing, but that is no power-on: it once brought up the core at 0x100000, and the firmware
reads the menu from the FPGA only at power-up."""

from __future__ import annotations

from pathlib import Path

from tools.engine import config, host, toolchain
from tools.engine.host import StepError


def command(
    root: Path,
    core: Path | None = None,
    sram: bool = False,
    image: Path | None = None,
    board: Path | None = None,
) -> list[host.Arg]:
    """@brief The openFPGALoader call for a core (into SRAM or its slot) or for an image. board is
    a board folder in place of the one project.toml names, whose build of the core it loads."""
    project = config.load_project(root / "project.toml", board)
    loader = toolchain.find(root, "suite") / "bin" / ("openFPGALoader" + host.EXE)
    loader_board = ["-b", project.board.loader]
    if image is not None:
        if not image.is_file():
            raise StepError(f"{image}: no such file")
        if image.stat().st_size > project.board.flash.size:
            raise StepError(f"{image} is larger than the flash of {project.board.name}")
        return [loader, *loader_board, "-f", "-o", "0x000000", "--verify", image]
    assert core is not None
    name = config.load_core(core / "core.toml").name
    fs = project.build_folder(name) / f"{name}.fs"
    if not fs.is_file():
        folder = core.relative_to(root).as_posix()
        option = (
            f" --board {project.board.folder.relative_to(root).as_posix()}" if project.other_board else ""
        )
        raise StepError(f"{fs.relative_to(root)} is missing, build it first: g20k.py build {folder}{option}")
    if sram:
        return [loader, *loader_board, fs]
    return [loader, *loader_board, "-f", "-o", f"0x{project.address(core):06x}", "--verify", fs]


def flash(
    root: Path,
    core: Path | None,
    sram: bool,
    image: Path | None,
    dry_run: bool,
    board: Path | None = None,
) -> None:
    """@brief Runs the call of command(), or only prints it with dry_run."""
    cmd = command(root, core, sram, image, board)
    print(" ".join(str(a) for a in cmd), flush=True)
    if not dry_run:
        host.run(cmd, cwd=root, capture=False)
