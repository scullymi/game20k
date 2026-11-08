# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the command line: the parameters of a diagnostic build, the boards of
--bl616, what tools fetch fetches."""

import argparse
import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from tools.engine import cli, config, forks, toolchain


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


class FetchToolsTest(unittest.TestCase):
    """@brief tools fetch: which names go to the downloads and when the prebuilt forks come."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "tools.toml").write_text("")
        self.calls: list[tuple[str, object]] = []
        for target, name in ((toolchain, "fetch"), (forks, "build")):
            patcher = mock.patch.object(
                target, name, side_effect=lambda root, arg, n=name: self.calls.append((n, arg))
            )
            patcher.start()
            self.addCleanup(patcher.stop)

    def fetch(self, names: list[str], mode: str = "") -> list[tuple[str, object]]:
        self.calls.clear()
        with (
            mock.patch.object(config, "load_toolset"),
            mock.patch.object(toolchain, "load_local", return_value=config.Local(mode=mode)),
            redirect_stdout(io.StringIO()),
        ):
            cli.fetch_tools(self.root, names)
        return self.calls

    def test_all(self) -> None:
        self.assertEqual(self.fetch([]), [("fetch", []), ("build", "prebuilt")])

    def test_all_keeps_forks_built_here(self) -> None:
        self.assertEqual(self.fetch([], mode="source"), [("fetch", [])])

    def test_named(self) -> None:
        self.assertEqual(self.fetch(["suite", "ghdl"]), [("fetch", ["suite", "ghdl"])])
        self.assertEqual(self.fetch(["yosys"]), [("build", "prebuilt")])
        self.assertEqual(
            self.fetch(["suite", "nextpnr"], mode="source"), [("fetch", ["suite"]), ("build", "prebuilt")]
        )


if __name__ == "__main__":
    unittest.main()
