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
        data = slots.slot_data(b"\xa5\xc3abc", 3, 0x1000)
        self.assertEqual(len(data), 0x1000)
        self.assertEqual(data[:5], b"\xa5\xc3abc")
        self.assertEqual(data[5 : 0x1000 - slots.TAG_BYTES], b"\xff" * (0x1000 - slots.TAG_BYTES - 5))
        self.assertEqual(data[-slots.TAG_BYTES :], slots.tag(3))

    def test_bitstream_that_reaches_the_tag(self) -> None:
        slots.slot_data(b"\x00" * (0x1000 - slots.TAG_BYTES), 3, 0x1000)
        with self.assertRaises(StepError):
            slots.slot_data(b"\x00" * (0x1000 - slots.TAG_BYTES + 1), 3, 0x1000)

    def test_core_board(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            core = Path(tmp)
            write(core, "a.manifest", "name a\nboard   9\n")
            write(core, "b.manifest", "board 9\n")
            self.assertEqual(slots.core_board(core), 9)
            write(core, "c.manifest", "board 8\n")
            with self.assertRaises(StepError):
                slots.core_board(core)

    def test_core_without_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(StepError):
                slots.core_board(Path(tmp))

    def test_flash_image(self) -> None:
        # two slots of 0x100000: each bitstream at its slot, the tag at each slot's end
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            write(root, "boards/b/board.toml", BOARD)
            write(root, "project.toml", PROJECT)
            for name, board in (("one", 3), ("two", 9)):
                write(root, f"fpga/{name}/core.toml", "")
                write(root, f"fpga/{name}/{name}.manifest", f"board {board}\n")
                (root / "build" / name).mkdir(parents=True)
                (root / "build" / name / f"{name}.bin").write_bytes(b"\xa5\xc3" + name.encode())
            image = slots.flash_image(config.load_project(root / "project.toml"))
        self.assertEqual(len(image), 0x200000)
        self.assertEqual(image[:5], b"\xa5\xc3one")
        self.assertEqual(image[0x100000 - slots.TAG_BYTES : 0x100000], slots.tag(3))
        self.assertEqual(image[0x100000 : 0x100005], b"\xa5\xc3two")
        self.assertEqual(image[-slots.TAG_BYTES :], slots.tag(9))


if __name__ == "__main__":
    unittest.main()
