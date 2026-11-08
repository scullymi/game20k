# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Loads bitstreams into the board with the suite's openFPGALoader, and the Companion into
a BL616 with Bouffalo's flash tool.

Three ways: a core into the FPGA's SRAM (gone at the next power cut, the FPGA then boots the
core at slot 0), a core into the configuration flash at the address of its slot (the other
slots stay, openFPGALoader erases only the sectors it writes), or a whole flash image from 0.

After writing the flash, power the board off and on. openFPGALoader reloads the FPGA after
writing, but that is no power-on: it once brought up the core at 0x100000, and the firmware
reads the menu from the FPGA only at power-up.

The BL616 of the Tang Nano 20K boots Sipeed's encrypted debugger firmware at 0x0. Without a
computer on its USB port it starts a second image at 0x40000, the Companion. Only that address is
written, an image at 0x0 would leave the board in the boot ROM's download mode. The M0S Dock has
nothing else on its BL616, its boot ROM starts the Companion at 0x0, as with the fork's
src/bl616/flash_m0sdock_cfg.ini."""

from __future__ import annotations

import platform
from pathlib import Path

from tools.engine import config, firmware, host, toolchain
from tools.engine.host import StepError

#: Bouffalo's flash tool in the SDK, one program per system
BL616_TOOLS = {
    "Darwin": "BLFlashCommand-macos",
    "Linux": "BLFlashCommand-ubuntu",
    "Windows": "BLFlashCommand.exe",
}


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
        board_folder = project.board.folder
        if board_folder.is_relative_to(root):
            board_folder = board_folder.relative_to(root)
        option = f" --board {board_folder.as_posix()}" if project.other_board else ""
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


def bl616_command(root: Path, board: str, port: str) -> list[host.Arg]:
    """@brief The flash tool's call that writes the Companion of board, built by g20k.py firmware
    --bl616, to its address in firmware.BL616_ADDRESSES. Its configuration file goes next to the
    image."""
    if board not in firmware.BL616_ADDRESSES:
        raise StepError(f"--bl616 {board}: flashing is known only for {', '.join(firmware.BL616_ADDRESSES)}")
    out = firmware.bl616_folder(root, board)
    image = out / "build_out" / "fpga_companion_bl616.bin"
    if not image.is_file():
        raise StepError(
            f"{image.relative_to(root)} is missing, build it first: g20k.py firmware --bl616 {board}"
        )
    try:
        name = BL616_TOOLS[platform.system()]
    except KeyError:
        raise StepError(f"no flash tool of the Bouffalo SDK for {platform.system()}") from None
    tool = toolchain.find(root, "bouffalo_sdk") / "tools" / "bflb_tools" / "bouffalo_flash_cube" / name
    # the image alone: the SDK's own flash_prog_cfg.ini also writes its boot2 to 0x0
    ini = out / "companion.ini"
    ini.write_text(
        "[cfg]\nerase = 1\nskip_mode = 0x0, 0x0\nboot2_isp_mode = 0\n\n"
        f"[FW]\nfiledir = {image.as_posix()}\naddress = 0x{firmware.BL616_ADDRESSES[board]:x}\n",
        encoding="utf-8",
        newline="\n",
    )
    return [
        tool,
        "--interface=uart",
        "--chipname=bl616",
        f"--port={port}",
        "--baudrate=2000000",
        f"--config={ini}",
    ]


def flash_bl616(root: Path, board: str, port: str, dry_run: bool) -> None:
    """@brief Runs the call of bl616_command(), or only prints it with dry_run.

    The BL616 has to be in its download mode: unplug the board, hold UPDATE (Tang Nano 20K) or
    BOOT (M0S Dock), plug it in. The tool reads back the SHA-256 of what it wrote. It leaves its
    loader running, so a second call needs the download mode again."""
    cmd = bl616_command(root, board, port)
    print(" ".join(str(a) for a in cmd), flush=True)
    if dry_run:
        return
    # the tool writes its log to stderr
    log = firmware.bl616_folder(root, board) / "flash.log"
    try:
        host.run(cmd, cwd=log.parent, stdout=log.with_suffix(".out"), stderr=log)
    finally:
        print("\n".join(log.read_text(encoding="utf-8", errors="replace").splitlines()[-6:]))
    # the tool's exit code alone is not known to stop on a failed check, its last lines say it
    if "Verification succeeded" not in log.read_text(encoding="utf-8", errors="replace"):
        raise StepError(f"the flash tool reports no verified write, see {log}")
