# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The Doxygen pages of game20k's sources in the FPGA-Companion fork, with what is not
documented as warnings.

scripts/Doxyfile reads the fork's folder and the output folder from the variables FORK and OUT.
The pages go to build/doxygen/html, build/ is not in git."""

from __future__ import annotations

import shutil
from pathlib import Path

from tools.engine import host
from tools.engine.host import StepError

## a file every checkout of the fork with game20k's sources has
MARK = Path("src/game20k/ra_task.c")


def docs(root: Path, fork: Path | None) -> Path:
    """@brief Builds the pages of the fork, by default the submodule external/FPGA-Companion,
    and returns the start page. A warning of Doxygen fails, after all warnings are shown."""
    fork = (fork or root / "external" / "FPGA-Companion").resolve()
    out = root / "build" / "doxygen"
    if shutil.which("doxygen") is None:
        raise StepError(
            "doxygen is missing: brew install doxygen, apt install doxygen, "
            "or a release of https://www.doxygen.nl/download.html"
        )
    if not (fork / MARK).is_file():
        raise StepError(f"no fork sources at {fork}: run git submodule update --init, or give --fork")
    out.mkdir(parents=True, exist_ok=True)
    warnings = out / "warnings.txt"
    # Doxygen writes its log only when it has something to say
    warnings.unlink(missing_ok=True)
    host.run(["doxygen", root / "scripts" / "Doxyfile"], cwd=root, env={"FORK": str(fork), "OUT": str(out)})
    text = warnings.read_text(encoding="utf-8", errors="replace") if warnings.is_file() else ""
    if text.strip():
        print("Doxygen warnings:")
        # paths relative to the fork, after / on Linux and macOS, after \ on Windows
        print(text.replace(f"{fork}/", "").replace(f"{fork}\\", ""), end="")
        raise StepError(f"Doxygen warns, see above or {warnings}")
    page = out / "html" / "index.html"
    print(f"No warnings. Pages: {page}")
    return page
