# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The machine the build runs on: program names, starting programs, writing logs.

Programs start without a shell and with their arguments as a list, so that the same call works
on Linux, macOS and Windows and no argument needs quoting."""

from __future__ import annotations

import os
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path

#: suffix of executables on this machine
EXE = ".exe" if os.name == "nt" else ""

Arg = str | Path


class StepError(Exception):
    """@brief A program of the build that failed, with the command and where its output went."""


def python(script: Path, *args: Arg) -> list[Arg]:
    """@brief A call of one of the project's Python scripts with the interpreter of this build."""
    return [sys.executable, script, *args]


def run(
    cmd: Sequence[Arg],
    *,
    cwd: Path,
    stdout: Path | None = None,
    stderr: Path | None = None,
    env: dict[str, str] | None = None,
    capture: bool = True,
) -> str:
    """@brief Runs cmd and returns what it printed, unless stdout goes to a file.

    stdout and stderr name files that take the output. Without them the output is returned
    and stderr goes to the terminal, without capture both go to the terminal as they come. A
    non-zero exit raises StepError."""
    args = [str(a) for a in cmd]
    full_env = {**os.environ, **env} if env else None
    out = open(stdout, "w", encoding="utf-8") if stdout else subprocess.PIPE if capture else None
    err = open(stderr, "w", encoding="utf-8") if stderr else None
    try:
        result = subprocess.run(args, cwd=cwd, stdout=out, stderr=err, env=full_env, text=True)
    except FileNotFoundError:
        raise StepError(f"{args[0]}: no such program") from None
    finally:
        for f in (out, err):
            if f not in (None, subprocess.PIPE):
                f.close()  # type: ignore[union-attr]
    if result.returncode != 0:
        where = f", see {stderr}" if stderr else ""
        raise StepError(f"{Path(args[0]).name} failed with exit code {result.returncode}{where}")
    return result.stdout or ""
