# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the command line: the parameters of a diagnostic build."""

import argparse
import io
import unittest
from contextlib import redirect_stderr

from tools.engine import cli


class ParameterTest(unittest.TestCase):
    def test_name_and_value(self) -> None:
        self.assertEqual(cli.parameter("RAMDIAG=1"), ("RAMDIAG", 1))
        self.assertEqual(cli.parameter("N=0x10"), ("N", 16))

    def test_rejects(self) -> None:
        for text in ("RAMDIAG", "RAMDIAG=", "RAMDIAG=yes", "1X=1", "=1"):
            with self.subTest(text=text), self.assertRaises(argparse.ArgumentTypeError):
                cli.parameter(text)


class Bl616BoardTest(unittest.TestCase):
    def test_board_names(self) -> None:
        self.assertEqual(cli.bl616_board("Nano20K_V3923"), "nano20k_v3923")
        for bad in ("", "../x", "nano/20k", "nanö"):
            with self.subTest(text=bad), self.assertRaises(argparse.ArgumentTypeError):
                cli.bl616_board(bad)

    def test_bl616_alone(self) -> None:
        for extra in (["--release"], ["--upstream", "PICO"], ["--without-ra"], ["--usb", "pio"]):
            with self.subTest(extra=extra), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                cli.main(["firmware", "--bl616", "nano20k", *extra])


if __name__ == "__main__":
    unittest.main()
