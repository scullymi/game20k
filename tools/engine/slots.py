# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief What goes into one slot of the configuration flash: the core's bitstream, 0xFF up to the
tag, and the tag that tells flash_scan.sv which board the slot holds.

The tag is the last TAG_BYTES of the slot: MAGIC, the board id, its complement, 0xFF. Every
bitstream ends long before it, so the FPGA never reads the tag while it loads. It cannot hold
the sync word a5 c3, which keeps an FPGA that searches the flash for a bitstream from starting
there: the board id and its complement are never a5 c3, and the bytes around them are neither.

The bitstream's header names the slot the FPGA loads at the next RECONFIG_N, the core switch of
the ring: the address in its 0xD2 command. The build leaves it at 0, set_next() writes the next
slot's address when the slots are laid out, so a core fits into any slot. The FPGA leaves the
0xD2 command out of the bitstream's CRC (see Apicula's bslib.py)."""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

from tools.engine import config, sdcard
from tools.engine.host import StepError

## bytes of the tag at the end of each slot, TAG_BYTES of flash_scan.sv
TAG_BYTES = 16
## the start of the tag, MAGIC of flash_scan.sv
MAGIC = b"G20KCORE"
## the word after the 0xFF bytes ahead of a bitstream's header
SYNC = b"\xa5\xc3"
## the commands of the header that gowin_pack writes ahead of the 0xD2 command, by their first
## byte, with their length in bytes
HEADER_COMMANDS = {0x06: 8, 0x10: 8, 0x51: 8, 0x0B: 4, 0x12: 4}
## the 0xD2 command up to its address, which takes the four bytes after it, most significant first
NEXT_COMMAND = bytes([0xD2, 0x00, 0xFF, 0xFF])


def next_offset(bitstream: bytes) -> int:
    """@brief Where the address of the 0xD2 command is in a bitstream. Walks the header command by
    command: the frame data may hold the same bytes, as in some cores."""
    at = len(bitstream) - len(bitstream.lstrip(b"\xff"))
    if bitstream[at : at + len(SYNC)] != SYNC:
        raise StepError("the bitstream has no sync word after its 0xFF bytes")
    at += len(SYNC)
    while at < len(bitstream) and bitstream[at] != NEXT_COMMAND[0]:
        size = HEADER_COMMANDS.get(bitstream[at])
        # the frame count (0x3b) ends the header, any other command is not of gowin_pack
        if size is None:
            raise StepError(f"the bitstream's header has command 0x{bitstream[at]:02x} at {at} before 0xD2")
        at += size
    if bitstream[at : at + len(NEXT_COMMAND)] != NEXT_COMMAND or at + len(NEXT_COMMAND) + 4 > len(bitstream):
        raise StepError("the bitstream's header has no 0xD2 command")
    return at + len(NEXT_COMMAND)


def set_next(bitstream: bytes, address: int) -> bytes:
    """@brief The bitstream with address in its 0xD2 command, the slot the FPGA loads next."""
    at = next_offset(bitstream)
    return bitstream[:at] + address.to_bytes(4, "big") + bitstream[at + 4 :]


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


def slot_data(name: str, bitstream: bytes, board: int, slot_size: int, next_address: int) -> bytes:
    """@brief One slot as it goes into the flash: the bitstream of core name with the address of
    the next slot of the ring, 0xFF, the tag."""
    room = slot_size - TAG_BYTES
    if len(bitstream) > room:
        raise StepError(f"{name}.bin has {len(bitstream)} bytes, its slot room for {room}")
    return set_next(bitstream, next_address) + b"\xff" * (room - len(bitstream)) + tag(board)


def flash_image(
    project: config.Project, cores: Sequence[Path] | None = None, source: Path | None = None
) -> bytes:
    """@brief The whole flash from 0: the cores in ring order (those of project.toml without
    cores), each in its slot with its tag, the last one's next address back to 0. The rest is 0xFF
    as in an erased flash, so no tag of an older core stays. The bitstreams are the builds, or the
    <core>.bin files in source, e.g. a release's zip."""
    cores = project.slots if cores is None else [c.resolve() for c in cores]
    flash = project.board.flash
    if not cores:
        raise StepError("no core for the flash")
    if len(cores) * flash.slot_size > flash.size:
        raise StepError(
            f"{len(cores)} cores, the flash of {project.board.name} has {flash.size // flash.slot_size} slots"
        )
    # one slot per core: the flash scan finds a board in its first slot only
    if len(set(cores)) < len(cores):
        raise StepError("a core picked twice")
    image = bytearray()
    for i, core in enumerate(cores):
        folder = source or project.build_folder(core.name)
        bitstream = (folder / f"{core.name}.bin").read_bytes()
        next_address = (i + 1) % len(cores) * flash.slot_size
        image += slot_data(core.name, bitstream, core_board(core), flash.slot_size, next_address)
    return bytes(image + b"\xff" * (flash.size - len(image)))
