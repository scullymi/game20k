# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief What goes into one slot of the configuration flash: the core's bitstream, 0xFF up to the
tag, and the tag that tells flash_scan.sv which board the slot holds.

The tag is the last TAG_BYTES of the slot: MAGIC, the board id, its complement, 0xFF. Every
bitstream ends long before it, so the FPGA never reads the tag while it loads. It cannot hold
the sync word a5 c3, which keeps an FPGA that searches the flash for a bitstream from starting
there: the board id and its complement are never a5 c3, and the bytes around them are neither."""

from __future__ import annotations

from pathlib import Path

from tools.engine import config, sdcard
from tools.engine.host import StepError

## bytes of the tag at the end of each slot, TAG_BYTES of flash_scan.sv
TAG_BYTES = 16
## the start of the tag, MAGIC of flash_scan.sv
MAGIC = b"G20KCORE"


def tag(board: int) -> bytes:
    """@brief The tag of a slot with a core of this board, 1 to 254."""
    if not 1 <= board <= 254:
        raise StepError(f"board {board} is no board id, 1 to 254")
    return MAGIC + bytes([board, board ^ 0xFF]) + b"\xff" * (TAG_BYTES - len(MAGIC) - 2)


def core_board(core: Path) -> int:
    """@brief The board id of a core folder, the board line its manifests share, read as
    make_rom.py reads it."""
    boards = set()
    for manifest in sorted(core.glob("*.manifest")):
        value = sdcard.manifest_value(manifest, "board")
        try:
            boards.add(int(value, 0))
        except ValueError:
            raise StepError(f"{manifest}: board {value} is no number") from None
    if len(boards) != 1:
        raise StepError(f"{core}: its manifests name {len(boards)} boards, a core has one")
    return boards.pop()


def slot_data(name: str, bitstream: bytes, board: int, slot_size: int) -> bytes:
    """@brief One slot as it goes into the flash: the bitstream of core name, 0xFF, the tag."""
    room = slot_size - TAG_BYTES
    if len(bitstream) > room:
        raise StepError(f"{name}.bin has {len(bitstream)} bytes, its slot room for {room}")
    return bitstream + b"\xff" * (room - len(bitstream)) + tag(board)


def flash_image(project: config.Project) -> bytes:
    """@brief The flash from 0 as project.toml lays it out: each core's built .bin in its slot
    with its tag, 0xFF in between as in an erased flash."""
    image = bytearray()
    for core in project.slots:
        bitstream = (project.build_folder(core.name) / f"{core.name}.bin").read_bytes()
        image += b"\xff" * (project.address(core) - len(image))
        image += slot_data(core.name, bitstream, core_board(core), project.board.flash.slot_size)
    return bytes(image)
