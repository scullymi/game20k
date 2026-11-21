# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the stepping stone of the BL616: the 0xD2 command it needs and the C file that
puts it into the firmware."""

import re
import tempfile
import unittest
from pathlib import Path

from tools.engine import config, stone
from tools.engine.host import StepError

ROOT = Path(__file__).resolve().parents[3]

## the head of a bitstream as gowin_pack writes it, the 0xD2 command at 52 with the address 0
HEAD = b"\xff" * 22 + bytes.fromhex("a5c3060000000000081b1000000000d420005100ffffff090b0d0b000000") + stone.D2


def bits(address: bytes = b"\x00" * 4, tail: bytes = b"\x12\x00\x00\x00") -> bytes:
    return HEAD + address + tail


class StoneTest(unittest.TestCase):
    def test_d2_offset(self) -> None:
        self.assertEqual(stone.d2_offset(bits()), 52)

    def test_no_or_two_d2_commands(self) -> None:
        for b in (HEAD[:52] + b"\x00" * 12, bits() + stone.D2 + b"\x00" * 4):
            with self.assertRaises(StepError):
                stone.d2_offset(b)

    def test_d2_command_cut_short(self) -> None:
        with self.assertRaises(StepError):
            stone.d2_offset(HEAD + b"\x00\x00")

    def test_c_source(self) -> None:
        b = bits(tail=bytes(range(40)))
        text = stone.c_source(b, 0x100000)
        self.assertIn('#include "stone.h"', text)
        self.assertIn(f"const size_t stone_size = {len(b)};", text)
        self.assertIn("const size_t stone_d2 = 52;", text)
        self.assertIn("const uint32_t stone_slot_bytes = 0x100000;", text)
        array = re.search(r"stone_bits\[\] = \{(.*?)\};", text, re.S)
        assert array is not None
        self.assertEqual(bytes(int(x, 16) for x in array.group(1).replace("\n", "").split(",")), b)

    def test_make_source_writes_once(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            path = stone.make_source(ROOT, out)
            path.write_text(path.read_text())  # same text, older file
            before = path.stat().st_mtime_ns
            stone.make_source(ROOT, out)
            self.assertEqual(path.stat().st_mtime_ns, before)
            path.write_text("old")
            stone.make_source(ROOT, out)
            self.assertIn("stone_bits", path.read_text())

    def test_checked_in_stone(self) -> None:
        # the file the firmware takes: one 0xD2 command with the address 0, small enough for a
        # slot of the BL616's board
        b = (ROOT / stone.FOLDER / "stone.bin").read_bytes()
        at = stone.d2_offset(b)
        self.assertEqual(b[at + 4 : at + 8], b"\x00" * 4)
        board = config.load_board(ROOT / stone.BOARD)
        self.assertGreater(board.flash.slot_size, len(b))


if __name__ == "__main__":
    unittest.main()
