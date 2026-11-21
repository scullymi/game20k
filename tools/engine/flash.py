# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Loads bitstreams into the board with the suite's openFPGALoader, and the Companion into
a BL616 with Bouffalo's flash tool.

Four ways: a core into the FPGA's SRAM (gone at the next power cut, the FPGA then boots the
core at slot 0, and its core switch goes to slot 0 too), a core into the configuration flash at
the address of its slot with the tag at the slot's end (slots.py, the other slots stay,
openFPGALoader erases only the sectors it writes), cores picked in any order as a whole flash
image, or a flash image from 0 as it is.

After writing the flash, power the board off and on. openFPGALoader reloads the FPGA after
writing, but that is no power-on: it once brought up the core at 0x100000, and the firmware
reads the menu from the FPGA only at power-up.

The BL616 of the Tang Nano 20K boots Sipeed's encrypted debugger firmware at 0x0. Without a
computer on its USB port it starts a second image at 0x40000, the Companion. Only that address is
written, an image at 0x0 would leave the board in the boot ROM's download mode. The M0S Dock has
nothing else on its BL616, its boot ROM starts the Companion at 0x0, as with the fork's
src/bl616/flash_m0sdock_cfg.ini."""

from __future__ import annotations

import os
import platform
from pathlib import Path

from tools.engine import config, firmware, host, slots, toolchain
from tools.engine.host import StepError

## the page on the WinUSB driver the Nano needs on Windows
WINDOWS_USB = "https://github.com/scullymi/game20k/blob/main/docs/windows-usb.md"

## printed when one core goes into its slot: that slot and its next address fit project.toml's order only
SLOT_NOTE = (
    "Only this core's slot of project.toml is written, pointing to the next core there. "
    "After flash --cores this can break the ring, see docs/BUILD.md, section 2."
)

## Bouffalo's flash tool in the SDK, one program per system
BL616_TOOLS = {
    "Darwin": "BLFlashCommand-macos",
    "Linux": "BLFlashCommand-ubuntu",
    "Windows": "BLFlashCommand.exe",
}


def missing_build(root: Path, project: config.Project, core: Path, needed: Path) -> StepError:
    """@brief The error for a core whose build lacks needed, with the command that builds it."""
    folder = core.relative_to(root).as_posix()
    board_folder = project.board.folder
    if board_folder.is_relative_to(root):
        board_folder = board_folder.relative_to(root)
    option = f" --board {board_folder.as_posix()}" if project.other_board else ""
    return StepError(f"{needed.relative_to(root)} is missing, build it first: g20k.py build {folder}{option}")


def command(
    root: Path,
    core: Path | None = None,
    sram: bool = False,
    image: Path | None = None,
    board: Path | None = None,
    cores: list[Path] | None = None,
    source: Path | None = None,
) -> list[host.Arg]:
    """@brief The openFPGALoader call for a core (into SRAM or its slot), for cores in ring order
    (an image of their builds, or of the <core>.bin files in source) or for an image. board is a
    board folder in place of the one project.toml names, whose builds it loads."""
    project = config.load_project(root / "project.toml", board)
    loader = toolchain.find(root, "suite") / "bin" / ("openFPGALoader" + host.EXE)
    loader_board = ["-b", project.board.loader]
    if cores is not None:
        for c in cores:
            # the firmware has the menus of project.toml's cores only
            if c.resolve() not in project.slots:
                raise StepError(f"{c} is not in project.toml, the firmware has no menu for it")
            name = config.load_core(c / "core.toml").name
            bitstream = (source or project.build_folder(name)) / f"{name}.bin"
            if not bitstream.is_file():
                if source:
                    raise StepError(f"{bitstream} is missing, the release has no core {name}")
                raise missing_build(root, project, c, bitstream)
        image = project.build_folder("") / "flash-image.bin"
        image.parent.mkdir(parents=True, exist_ok=True)
        image.write_bytes(slots.flash_image(project, cores, source))
    if image is not None:
        if not image.is_file():
            raise StepError(f"{image}: no such file")
        if image.stat().st_size > project.board.flash.size:
            raise StepError(f"{image} is larger than the flash of {project.board.name}")
        return [loader, *loader_board, "-f", "-o", "0x000000", "--verify", image]
    assert core is not None
    name = config.load_core(core / "core.toml").name
    # the SRAM takes the .fs, a slot the .bin with the tag
    fs = project.build_folder(name) / f"{name}.fs"
    bitstream = project.build_folder(name) / f"{name}.bin"
    needed = fs if sram else bitstream
    if not needed.is_file():
        raise missing_build(root, project, core, needed)
    if sram:
        return [loader, *loader_board, fs]
    # the whole slot, so its tag is written anew with the core, and the next slot of
    # project.toml's ring in its header
    slot = project.build_folder(name) / f"{name}-slot.bin"
    board_id = slots.core_board(core)
    data = slots.slot_data(
        name, bitstream.read_bytes(), board_id, project.board.flash.slot_size, project.next_address(core)
    )
    slot.write_bytes(data)
    return [loader, *loader_board, "-f", "-o", f"0x{project.address(core):06x}", "--verify", slot]


def flash(
    root: Path,
    core: Path | None,
    sram: bool,
    image: Path | None,
    dry_run: bool,
    board: Path | None = None,
    cores: list[Path] | None = None,
    source: Path | None = None,
) -> None:
    """@brief Runs the call of command(), or only prints it with dry_run."""
    cmd = command(root, core, sram, image, board, cores, source)
    print(" ".join(str(a) for a in cmd), flush=True)
    if core is not None and not sram:
        print(SLOT_NOTE, flush=True)
    if dry_run:
        return
    try:
        host.run(cmd, cwd=root, capture=False)
    except StepError as e:
        # Windows binds the Nano's JTAG interface to FTDI's driver, which openFPGALoader cannot open
        if os.name == "nt":
            raise StepError(
                f"{e}. On Windows, the board needs the WinUSB driver once: {WINDOWS_USB}"
            ) from None
        raise


def bl616_command(root: Path, board: str, port: str, image: Path | None = None) -> list[host.Arg]:
    """@brief The flash tool's call that writes the Companion of board, built by g20k.py firmware
    --bl616 or the image given, e.g. one of a release, to its address in
    firmware.BL616_ADDRESSES. Its configuration file goes into the build folder of board."""
    if board not in firmware.BL616_ADDRESSES:
        raise StepError(f"--bl616 {board}: flashing is known only for {', '.join(firmware.BL616_ADDRESSES)}")
    out = firmware.bl616_folder(root, board)
    out.mkdir(parents=True, exist_ok=True)
    image = image or out / "build_out" / "fpga_companion_bl616.bin"
    if not image.is_file():
        raise StepError(
            f"{image.relative_to(root)} is missing, build it first: g20k.py firmware --bl616 {board}"
        )
    try:
        name = BL616_TOOLS[platform.system()]
    except KeyError:
        raise StepError(f"no flash tool of the Bouffalo SDK for {platform.system()}") from None
    tool = toolchain.find(root, "bouffalo_sdk") / "tools" / "bflb_tools" / "bouffalo_flash_cube" / name
    ini = out / "companion.ini"
    ini.write_text(
        firmware.bl616_ini(image.as_posix(), firmware.BL616_ADDRESSES[board]), encoding="utf-8", newline="\n"
    )
    return [
        tool,
        "--interface=uart",
        "--chipname=bl616",
        f"--port={port}",
        "--baudrate=2000000",
        f"--config={ini}",
    ]


def flash_bl616(root: Path, board: str, port: str, dry_run: bool, image: Path | None = None) -> None:
    """@brief Runs the call of bl616_command(), or only prints it with dry_run.

    The BL616 has to be in its download mode: unplug the board, hold UPDATE (Tang Nano 20K) or
    BOOT (M0S Dock), plug it in. The tool reads back the SHA-256 of what it wrote. It leaves its
    loader running, so a second call needs the download mode again."""
    cmd = bl616_command(root, board, port, image)
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
