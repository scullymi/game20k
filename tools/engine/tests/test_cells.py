# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the comparison of the netlist's cells with the core's measure."""

import json
import tempfile
import unittest
from pathlib import Path

from tools.engine.flow import cells
from tools.engine.host import StepError

MEASURE = {"LUT": 1000, "DFF": 500, "ALU": 100, "DPB": 20, "MULT18X18": 2}


class CellsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_counts_sum_the_groups(self) -> None:
        stat = self.dir / "stat.json"
        by_type = {"LUT1": 1, "LUT4": 2, "DFF": 3, "DFFRE": 4, "ALU": 5, "DPB": 6, "$print": 7}
        stat.write_text(json.dumps({"design": {"num_cells_by_type": by_type}}))
        self.assertEqual(cells.counts(stat), {"LUT": 3, "DFF": 7, "ALU": 5, "DPB": 6, "$print": 7})

    def test_groups_move_within_the_tolerance(self) -> None:
        self.assertEqual(cells.differences(MEASURE, {**MEASURE, "LUT": 1050, "DFF": 475}), [])
        self.assertEqual(cells.differences(MEASURE, {**MEASURE, "LUT": 1051}), ["LUT: 1051 instead of 1000"])

    def test_other_cells_must_match(self) -> None:
        # Time Pilot on 02.11.: every clock passed, block RAM 38 instead of 26
        self.assertEqual(cells.differences(MEASURE, {**MEASURE, "DPB": 21}), ["DPB: 21 instead of 20"])
        now = {k: v for k, v in MEASURE.items() if k != "MULT18X18"} | {"rPLL": 1}
        self.assertEqual(
            cells.differences(MEASURE, now), ["MULT18X18: 0 instead of 2", "rPLL: 1 instead of 0"]
        )

    def test_check_without_measure(self) -> None:
        with self.assertRaises(StepError) as err:
            cells.check(self.dir / "cells.toml", "board", MEASURE, "fpga/c/cells.toml")
        self.assertIn("g20k.py build fpga/c --update-cells", str(err.exception))

    def test_update_then_check(self) -> None:
        path = self.dir / "cells.toml"
        cells.update(path, "other", {"$print": 1, "LUT": 5})
        cells.update(path, "board", MEASURE)
        cells.check(path, "board", MEASURE, "cells.toml")
        cells.check(path, "other", {"$print": 1, "LUT": 5}, "cells.toml")
        with self.assertRaises(StepError):
            cells.check(path, "board", {**MEASURE, "DPB": 19}, "cells.toml")


if __name__ == "__main__":
    unittest.main()
