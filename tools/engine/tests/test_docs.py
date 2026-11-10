# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the Doxygen pages of the fork, with Doxygen replaced."""

import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from tools.engine import docs
from tools.engine.host import StepError


class DocsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.fork = self.root / "external" / "FPGA-Companion"
        (self.fork / docs.MARK).parent.mkdir(parents=True)
        (self.fork / docs.MARK).touch()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_docs(self, warnings: str) -> tuple[list[tuple[list[object], dict[str, str]]], str]:
        """docs() with a Doxygen that writes warnings (none when empty) and the calls it got."""
        calls: list[tuple[list[object], dict[str, str]]] = []

        def doxygen(cmd: list[object], *, cwd: Path, env: dict[str, str], capture: bool) -> str:
            calls.append((cmd, env))
            if warnings:
                Path(env["OUT"], "warnings.txt").write_text(warnings)
            return ""

        out = io.StringIO()
        with (
            mock.patch("shutil.which", return_value="/usr/bin/doxygen"),
            mock.patch("tools.engine.host.run", side_effect=doxygen),
            redirect_stdout(out),
        ):
            try:
                docs.docs(self.root, None)
            finally:
                self.printed = out.getvalue()
        return calls, self.printed

    def test_no_warnings(self) -> None:
        calls, text = self.run_docs("")
        ((cmd, env),) = calls
        self.assertEqual(cmd, ["doxygen", self.root / "scripts" / "Doxyfile"])
        self.assertEqual(env, {"FORK": str(self.fork.resolve()), "OUT": str(self.root / "build" / "doxygen")})
        self.assertIn("No warnings.", text)

    def test_warnings_fail_with_short_paths(self) -> None:
        with self.assertRaises(StepError):
            self.run_docs(f"{self.fork.resolve()}/src/game20k/ra_task.c:12: warning: x is not documented\n")
        self.assertEqual(
            self.printed, "Doxygen warnings:\nsrc/game20k/ra_task.c:12: warning: x is not documented\n"
        )

    def test_old_warnings_do_not_count(self) -> None:
        out = self.root / "build" / "doxygen"
        out.mkdir(parents=True)
        (out / "warnings.txt").write_text("old\n")
        _, text = self.run_docs("")
        self.assertIn("No warnings.", text)

    def test_no_doxygen(self) -> None:
        with mock.patch("shutil.which", return_value=None), self.assertRaises(StepError) as e:
            docs.docs(self.root, None)
        self.assertIn("brew install doxygen", str(e.exception))

    def test_no_fork(self) -> None:
        with mock.patch("shutil.which", return_value="/usr/bin/doxygen"), self.assertRaises(StepError) as e:
            docs.docs(self.root, self.root / "elsewhere")
        self.assertIn("git submodule update --init", str(e.exception))


if __name__ == "__main__":
    unittest.main()
