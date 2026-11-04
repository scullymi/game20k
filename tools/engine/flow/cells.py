# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The cells of the synthesized netlist against the measure in the core's cells.toml.

A change of the tools or of a script of the build can change the netlist without any error:
a memory goes from block RAM into LUTs, a CPU loses an input and is optimized away, every clock
still meets its frequency. The cell counts show it. LUTs, flip-flops and ALUs are compared as
sums and may move by TOLERANCE, every other cell type (block RAM, DSP, PLL, I/O) must match.
After a wanted change, g20k.py build <core> --update-cells writes the measure anew."""

from __future__ import annotations

import json
import re
import tomllib
from pathlib import Path

from tools.engine.host import StepError

#: how far the sums of GROUPS may move, as a share of the measure
TOLERANCE = 0.05
#: cell types that are compared as one sum, by the pattern of their names
GROUPS = {"LUT": r"LUT\d+", "DFF": r"DFF\w*", "ALU": r"ALU"}

HEAD = """\
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# The cells of the synthesized netlist per board, written by g20k.py build --update-cells. The
# build compares its netlist with them: {groups} may move by {percent} percent, every other
# cell type must match.
"""


def counts(stat_json: Path) -> dict[str, int]:
    """@brief The cell counts of Yosys' stat -json, the types of GROUPS summed up."""
    by_type: dict[str, int] = json.loads(stat_json.read_text())["design"]["num_cells_by_type"]
    out: dict[str, int] = {}
    for cell, n in by_type.items():
        name = next((g for g, pattern in GROUPS.items() if re.fullmatch(pattern, cell)), cell)
        out[name] = out.get(name, 0) + n
    return out


def differences(measure: dict[str, int], now: dict[str, int]) -> list[str]:
    """@brief One line per cell type that is off its measure, empty when all match."""
    lines = []
    for cell in sorted(set(measure) | set(now)):
        was, got = measure.get(cell, 0), now.get(cell, 0)
        allowed = was * TOLERANCE if cell in GROUPS else 0
        if abs(got - was) > allowed:
            lines.append(f"{cell}: {got} instead of {was}")
    return lines


def check(cells_toml: Path, board: str, now: dict[str, int], shown: str) -> None:
    """@brief Raises StepError when the cells are off the measure of board in cells_toml.

    shown is the path of cells_toml as the messages name it, relative to the project's root."""
    hint = f"g20k.py build {Path(shown).parent.as_posix()} --update-cells after a wanted change"
    try:
        with open(cells_toml, "rb") as f:
            measure = tomllib.load(f).get(board)
    except FileNotFoundError:
        measure = None
    if measure is None:
        raise StepError(f"{shown} has no measure for {board}, write it with {hint}")
    off = differences(measure, now)
    if off:
        raise StepError(f"the netlist is off its measure in {shown}:\n  " + "\n  ".join(off) + f"\n{hint}")


def update(cells_toml: Path, board: str, now: dict[str, int]) -> None:
    """@brief Writes now as the measure of board, the other boards of the file stay."""
    boards: dict[str, dict[str, int]] = {}
    if cells_toml.exists():
        with open(cells_toml, "rb") as f:
            boards = tomllib.load(f)
    boards[board] = now
    text = HEAD.format(groups=", ".join(GROUPS), percent=round(TOLERANCE * 100))
    for name in sorted(boards):
        text += f"\n[{name}]\n" + "".join(f'"{c}" = {n}\n' for c, n in sorted(boards[name].items()))
    cells_toml.write_text(text, encoding="utf-8", newline="\n")
