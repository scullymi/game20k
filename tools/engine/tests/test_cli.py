# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the command line: the parameters of a diagnostic build."""

import argparse
import unittest

from tools.engine import cli


class ParameterTest(unittest.TestCase):
    def test_name_and_value(self) -> None:
        self.assertEqual(cli.parameter("RAMDIAG=1"), ("RAMDIAG", 1))
        self.assertEqual(cli.parameter("N=0x10"), ("N", 16))

    def test_rejects(self) -> None:
        for text in ("RAMDIAG", "RAMDIAG=", "RAMDIAG=yes", "1X=1", "=1"):
            with self.subTest(text=text), self.assertRaises(argparse.ArgumentTypeError):
                cli.parameter(text)


if __name__ == "__main__":
    unittest.main()
