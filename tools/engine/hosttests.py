# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The host tests of the firmware in tests/host: its Makefile builds them, this runs each
binary and adds up Unity's counts.

A binary counts as passed when it exits with 0, ends with Unity's summary line and reports at
least one test and no failure: a binary with 0 tests has checked nothing. The Makefile calls
main() with its binaries (python3 -m tools.engine.hosttests), so it keeps the only list of them."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from tools.engine import host

## Unity's last line, "<n> Tests <f> Failures <i> Ignored"
SUMMARY = re.compile(r"^(\d+) Tests (\d+) Failures (\d+) Ignored", re.MULTILINE)


def summary(out: str) -> tuple[int, int, int] | None:
    """@brief Tests, failures and ignored of the last summary line, None without one: then the
    binary died early."""
    found = SUMMARY.findall(out)
    if not found:
        return None
    n, f, i = found[-1]
    return int(n), int(f), int(i)


@dataclass
class Result:
    """@brief One test binary's run.

    - name: the binary's file name
    - code: its exit status, negative for a signal
    - output: what it printed, stdout and stderr together"""

    name: str
    code: int
    output: str

    @property
    def counts(self) -> tuple[int, int, int]:
        return summary(self.output) or (0, 0, 0)

    @property
    def passed(self) -> bool:
        s = summary(self.output)
        return self.code == 0 and s is not None and s[0] > 0 and s[1] == 0

    @property
    def why(self) -> str:
        """@brief Why it failed, empty when it passed."""
        if self.passed:
            return ""
        s = summary(self.output)
        if s is None:
            return f"no Unity summary, exit status {self.code}"
        if s[0] == 0:
            return "no test ran"
        return f"{s[1]} of {s[0]} tests failed, exit status {self.code}"


def run_binary(path: Path) -> Result:
    """@brief Runs one test binary and keeps all it prints. One that cannot start fails with the
    shell's status for a missing program."""
    try:
        p = subprocess.run([str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError as e:
        return Result(path.name, 127, f"{path}: {e.strerror}\n")
    return Result(path.name, p.returncode, p.stdout.decode("utf-8", errors="replace"))


def indent(lines: list[str]) -> None:
    for line in lines:
        print(f"  {line}")


def report(results: list[Result], verbose: bool) -> bool:
    """@brief One line per binary and the sums. A passed binary shows its sample sizes (Unity's
    INFO lines) and ignored tests, all its lines with verbose, a failed one all its lines.
    True when every binary passed, False also for none at all."""
    tests = fails = ignored = good = 0
    for r in results:
        n, f, i = r.counts
        tests, fails, ignored = tests + n, fails + f, ignored + i
        lines = r.output.splitlines()
        if r.passed:
            good += 1
            print(f"PASS {r.name}: {n} tests, {f} failures, {i} ignored")
            indent(lines if verbose else [s for s in lines if ":INFO:" in s or ":IGNORE" in s])
        else:
            print(f"FAIL {r.name}: {r.why}")
            indent(lines)
    passed = f"{good} of {len(results)} binaries passed"
    print(f"host tests: {passed}, {tests} tests, {fails} failures, {ignored} ignored")
    return bool(results) and good == len(results)


def test(root: Path, sanitize: bool, verbose: bool) -> None:
    """@brief Builds and runs the host tests with their Makefile, with AddressSanitizer and
    UndefinedBehaviorSanitizer unless sanitize is off."""
    cmd: list[host.Arg] = [
        "make",
        "-C",
        root / "tests" / "host",
        "check",
        f"SAN={int(sanitize)}",
        f"V={int(verbose)}",
    ]
    try:
        host.run(cmd, cwd=root, capture=False)
    except host.StepError:
        raise host.StepError("the host tests failed, see above") from None


def main(argv: list[str]) -> int:
    """@brief For the Makefile: runs the binaries given, exit status 1 unless all passed."""
    ap = argparse.ArgumentParser(prog="python3 -m tools.engine.hosttests")
    ap.add_argument("-v", "--verbose", action="store_true", help="print every line of each binary")
    ap.add_argument("binaries", nargs="*", type=Path)
    args = ap.parse_args(argv)
    return 0 if report([run_binary(b) for b in args.binaries], args.verbose) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
