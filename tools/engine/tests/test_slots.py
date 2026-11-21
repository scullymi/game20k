# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the slot data of the configuration flash: the tag that flash_scan.sv reads."""

import tempfile
import unittest
from pathlib import Path

from tools.engine import config, slots
from tools.engine.host import StepError
from tools.engine.tests.test_config import BOARD, PROJECT, write

## the header of a core as gowin_pack writes it, up to its 0xD2 command
HEAD = b"\xff" * 22 + bytes.fromhex("a5c3060000000000081b1000000000d400005100ffffffffffff0b000000")


def bits(address: int = 0, data: bytes = b"") -> bytes:
    """A bitstream with the next address in its 0xD2 command, the rest of the header and data."""
    return (
        HEAD
        + bytes.fromhex("d200ffff")
        + address.to_bytes(4, "big")
        + bytes.fromhex("120000003b80083e")
        + data
    )


def cores(root: Path, *names: tuple[str, int]) -> None:
    """Core folders with a manifest of their board and a build with a bitstream."""
    for name, board in names:
        write(root, f"fpga/{name}/core.toml", "")
        write(root, f"fpga/{name}/{name}.manifest", f"board {board}\n")
        (root / "build" / name).mkdir(parents=True)
        (root / "build" / name / f"{name}.bin").write_bytes(bits(data=name.encode()))


class HeaderTest(unittest.TestCase):
    def test_next_address_offset(self) -> None:
        self.assertEqual(slots.next_offset(bits()), len(HEAD) + 4)

    def test_set_next_leaves_the_data(self) -> None:
        # the frame data may hold the bytes of a 0xD2 command, as in some cores
        data = bytes.fromhex("d200ffff00000000")
        b = slots.set_next(bits(data=data), 0x300000)
        self.assertEqual(b, bits(0x300000, data))

    def test_headers_without_the_command(self) -> None:
        for name, b in (
            ("no sync word", b"\xff" * 22 + b"\x06" + bits()[23:]),
            ("unknown command", HEAD[:-4] + b"\x77\x00\x00\x00" + bits()[len(HEAD) :]),
            ("frames first", HEAD + bytes.fromhex("3b80083e")),
            ("cut short", bits()[: len(HEAD) + 6]),
            ("other 0xD2 command", HEAD + bytes.fromhex("d2010000") + bits()[len(HEAD) + 4 :]),
        ):
            with self.subTest(name), self.assertRaises(StepError):
                slots.next_offset(b)


class SlotsTest(unittest.TestCase):
    def test_tag(self) -> None:
        t = slots.tag(9)
        self.assertEqual(len(t), slots.TAG_BYTES)
        self.assertEqual(t[:10], b"G20KCORE\x09\xf6")
        self.assertEqual(t[10:], b"\xff" * 6)

    def test_no_tag_holds_the_sync_word(self) -> None:
        for board in range(1, 255):
            self.assertNotIn(b"\xa5\xc3", b"\xff" + slots.tag(board) + b"\xff")

    def test_board_ids_only(self) -> None:
        for board in (0, 255, 256):
            with self.assertRaises(StepError):
                slots.tag(board)

    def test_slot_data(self) -> None:
        b = bits(data=b"abc")
        data = slots.slot_data("a", b, 3, 0x1000, 0x2000)
        self.assertEqual(len(data), 0x1000)
        self.assertEqual(data[: len(b)], bits(0x2000, b"abc"))
        self.assertEqual(
            data[len(b) : 0x1000 - slots.TAG_BYTES], b"\xff" * (0x1000 - slots.TAG_BYTES - len(b))
        )
        self.assertEqual(data[-slots.TAG_BYTES :], slots.tag(3))

    def test_bitstream_that_reaches_the_tag(self) -> None:
        room = 0x1000 - slots.TAG_BYTES
        slots.slot_data("a", bits(data=b"\x00" * (room - len(bits()))), 3, 0x1000, 0)
        with self.assertRaisesRegex(StepError, "a.bin"):
            slots.slot_data("a", bits(data=b"\x00" * (room - len(bits()) + 1)), 3, 0x1000, 0)

    def test_core_board(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            core = Path(tmp)
            write(core, "a.manifest", "name a\nboard   9\n")
            write(core, "b.manifest", "board 0x09\n")  # make_rom.py takes it as 9 too
            self.assertEqual(slots.core_board(core), 9)
            write(core, "c.manifest", "board 8\n")
            with self.assertRaises(StepError):
                slots.core_board(core)

    def test_core_without_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(StepError):
                slots.core_board(Path(tmp))

    def test_flash_image(self) -> None:
        # the cores of project.toml in its order: each at its slot with the next slot's address,
        # the last back to 0, the tag at each slot's end
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            write(root, "boards/b/board.toml", BOARD)
            write(root, "project.toml", PROJECT)
            cores(root, ("one", 3), ("two", 9))
            image = slots.flash_image(config.load_project(root / "project.toml"))
        self.assertEqual(len(image), 0x200000)
        self.assertTrue(image.startswith(bits(0x100000, b"one")))
        self.assertEqual(image[0x100000 - slots.TAG_BYTES : 0x100000], slots.tag(3))
        self.assertTrue(image[0x100000:].startswith(bits(0, b"two")))
        self.assertEqual(image[-slots.TAG_BYTES :], slots.tag(9))

    def test_flash_image_of_cores(self) -> None:
        # cores picked in any order make the ring, the slots behind them are erased: no tag of an
        # older core stays for the flash scan
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            write(root, "boards/b/board.toml", BOARD.replace("size = 0x200000", "size = 0x400000"))
            write(root, "project.toml", PROJECT)
            cores(root, ("one", 3), ("two", 9))
            project = config.load_project(root / "project.toml")
            image = slots.flash_image(project, [root / "fpga/two", root / "fpga/one"])
        self.assertEqual(len(image), 0x400000)
        self.assertTrue(image.startswith(bits(0x100000, b"two")))
        self.assertEqual(image[0x100000 - slots.TAG_BYTES : 0x100000], slots.tag(9))
        self.assertTrue(image[0x100000:].startswith(bits(0, b"one")))
        self.assertEqual(image[0x200000 - slots.TAG_BYTES : 0x200000], slots.tag(3))
        self.assertEqual(image[0x200000:], b"\xff" * 0x200000)

    def test_flash_image_from_a_folder(self) -> None:
        # the bitstreams of a release's zip in place of the builds
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            write(root, "boards/b/board.toml", BOARD)
            write(root, "project.toml", PROJECT)
            cores(root, ("one", 3))
            (root / "zip").mkdir()
            (root / "zip" / "one.bin").write_bytes(bits(0x700000, b"zip"))
            project = config.load_project(root / "project.toml")
            image = slots.flash_image(project, [root / "fpga/one"], root / "zip")
        self.assertTrue(image.startswith(bits(0, b"zip")))

    def test_flash_image_takes_what_fits(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            write(root, "boards/b/board.toml", BOARD)
            write(root, "project.toml", PROJECT)
            cores(root, ("one", 3), ("two", 9), ("three", 5))
            project = config.load_project(root / "project.toml")
            one, two, three = (root / "fpga" / n for n in ("one", "two", "three"))
            for picked, error in (([], "no core"), ([one, two, three], "2 slots"), ([one, one], "twice")):
                with self.subTest(error), self.assertRaisesRegex(StepError, error):
                    slots.flash_image(project, picked)


if __name__ == "__main__":
    unittest.main()
