# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the host test runner: Unity's summary line, what counts as passed, the report,
with small Python programs in place of the test binaries."""

import io
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from tools.engine import hosttests

UNITY_OK = (
    "test_a.c:10:test_one:PASS\ntest_a.c:20:test_two:INFO: 40 samples\n\n2 Tests 0 Failures 0 Ignored \nOK\n"
)


class SummaryTest(unittest.TestCase):
    def test_last_summary_counts(self) -> None:
        self.assertEqual(hosttests.summary(UNITY_OK), (2, 0, 0))
        # a binary running two Unity groups prints two summaries, the last one counts
        self.assertEqual(
            hosttests.summary("1 Tests 0 Failures 0 Ignored\n3 Tests 1 Failures 2 Ignored\n"), (3, 1, 2)
        )

    def test_no_summary(self) -> None:
        self.assertIsNone(hosttests.summary("Segmentation fault\n"))


class ResultTest(unittest.TestCase):
    def result(self, out: str, code: int) -> hosttests.Result:
        return hosttests.Result("test_a", code, out)

    def test_passed(self) -> None:
        r = self.result(UNITY_OK, 0)
        self.assertTrue(r.passed)
        self.assertEqual(r.why, "")

    def test_failed_counts(self) -> None:
        r = self.result("3 Tests 1 Failures 0 Ignored\nFAIL\n", 1)
        self.assertFalse(r.passed)
        self.assertEqual(r.why, "1 of 3 tests failed, exit status 1")

    def test_no_test_ran(self) -> None:
        r = self.result("0 Tests 0 Failures 0 Ignored\nOK\n", 0)
        self.assertFalse(r.passed)
        self.assertEqual(r.why, "no test ran")

    def test_died_early(self) -> None:
        r = self.result("test_a.c:10:test_one:PASS\n", -11)
        self.assertFalse(r.passed)
        self.assertEqual(r.why, "no Unity summary, exit status -11")

    def test_nonzero_exit_with_good_counts(self) -> None:
        # a sanitizer finding after Unity's summary
        r = self.result(UNITY_OK + "==1==ERROR: LeakSanitizer\n", 1)
        self.assertFalse(r.passed)
        self.assertEqual(r.why, "0 of 2 tests failed, exit status 1")


class ReportTest(unittest.TestCase):
    def report(self, results: list[hosttests.Result], verbose: bool = False) -> tuple[bool, str]:
        out = io.StringIO()
        with redirect_stdout(out):
            ok = hosttests.report(results, verbose)
        return ok, out.getvalue()

    def test_pass_shows_samples_only(self) -> None:
        ok, text = self.report([hosttests.Result("test_a", 0, UNITY_OK)])
        self.assertTrue(ok)
        self.assertEqual(
            text,
            "PASS test_a: 2 tests, 0 failures, 0 ignored\n"
            "  test_a.c:20:test_two:INFO: 40 samples\n"
            "host tests: 1 of 1 binaries passed, 2 tests, 0 failures, 0 ignored\n",
        )

    def test_verbose_shows_everything(self) -> None:
        _, text = self.report([hosttests.Result("test_a", 0, UNITY_OK)], verbose=True)
        self.assertIn("  test_a.c:10:test_one:PASS\n", text)

    def test_fail_shows_the_output(self) -> None:
        ok, text = self.report(
            [hosttests.Result("test_a", 0, UNITY_OK), hosttests.Result("test_b", 1, "boom\n")]
        )
        self.assertFalse(ok)
        self.assertIn("FAIL test_b: no Unity summary, exit status 1\n  boom\n", text)
        self.assertTrue(text.endswith("host tests: 1 of 2 binaries passed, 2 tests, 0 failures, 0 ignored\n"))

    def test_no_binary_fails(self) -> None:
        ok, text = self.report([])
        self.assertFalse(ok)
        self.assertEqual(text, "host tests: 0 of 0 binaries passed, 0 tests, 0 failures, 0 ignored\n")


@unittest.skipIf(os.name == "nt", "the host tests build with make and run on Linux and macOS")
class RunTest(unittest.TestCase):
    def program(self, folder: Path, name: str, text: str, code: int) -> Path:
        p = folder / name
        p.write_text(f"#!{sys.executable}\nimport sys\nsys.stdout.write({text!r})\nsys.exit({code})\n")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
        return p

    def test_runs_each_binary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            good = self.program(Path(tmp), "test_good", UNITY_OK, 0)
            bad = self.program(Path(tmp), "test_bad", "1 Tests 1 Failures 0 Ignored\n", 1)
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertTrue(hosttests.main([str(good)]) == 0)
                self.assertTrue(hosttests.main(["-v", str(good), str(bad)]) == 1)
        self.assertIn("PASS test_good", out.getvalue())
        self.assertIn("FAIL test_bad: 1 of 1 tests failed, exit status 1", out.getvalue())

    def test_missing_binary_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(hosttests.main([str(Path(tmp) / "test_gone")]), 1)
        self.assertIn("FAIL test_gone: no Unity summary, exit status 127", out.getvalue())


if __name__ == "__main__":
    unittest.main()
