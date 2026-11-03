# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for reading and checking the TOML descriptions of board, platform and core."""

import tempfile
import textwrap
import unittest
from pathlib import Path

from tools.engine import config


def write(folder: Path, name: str, text: str) -> Path:
    """@brief Writes a dedented file into folder and returns its path."""
    path = folder / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(text), encoding="utf-8")
    return path


BOARD = """
    [board]
    name = "Tang Nano 20K"
    device = "GW2AR-LV18QN88C8/I7"
    family = "GW2A-18C"
    synth_family = "gw2a"
    loader = "tangnano20k"
    pins = "board.cst"
    block_rams = 46
    sspi_as_gpio = true
    mspi_as_gpio = true

    [flash]
    size = 0x200000
    slot_size = 0x100000

    [[clock]]
    name = "sys_clk"
    port = "sys_clk"
    hz = 27_000_000
"""


class BoardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_reads_board(self) -> None:
        board = config.load_board(write(self.dir, "board.toml", BOARD))
        self.assertEqual(board.device, "GW2AR-LV18QN88C8/I7")
        self.assertEqual(board.pins, self.dir / "board.cst")
        self.assertEqual(board.flash.slot_size, 0x100000)
        self.assertEqual(board.clocks[0].port, "sys_clk")
        self.assertEqual(board.clocks[0].hz, 27_000_000)

    def test_unknown_key_names_file_and_key(self) -> None:
        path = write(self.dir, "board.toml", BOARD.replace("loader =", "loadr ="))
        with self.assertRaises(config.ConfigError) as err:
            config.load_board(path)
        self.assertIn("board.toml", str(err.exception))
        self.assertIn("loadr", str(err.exception))

    def test_missing_key(self) -> None:
        path = write(self.dir, "board.toml", BOARD.replace('device = "GW2AR-LV18QN88C8/I7"\n', ""))
        with self.assertRaises(config.ConfigError) as err:
            config.load_board(path)
        self.assertIn("board.device", str(err.exception))

    def test_wrong_type(self) -> None:
        path = write(self.dir, "board.toml", BOARD.replace("0x100000", '"1M"'))
        with self.assertRaises(config.ConfigError) as err:
            config.load_board(path)
        self.assertIn("flash.slot_size", str(err.exception))

    def test_clock_needs_port_or_net(self) -> None:
        path = write(self.dir, "board.toml", BOARD.replace('port = "sys_clk"', ""))
        with self.assertRaises(config.ConfigError) as err:
            config.load_board(path)
        self.assertIn("clock", str(err.exception))


CORE = """
    [core]
    name = "pang_hdmi"
    platform = "../common"
    hz = 37_125_000

    [sources]
    files = ["src/a.v", "src/b_*.v"]
    include = ["src/inc"]

    [vhdl]
    files = ["vhdl/T80*.vhd"]
    tops = ["T80s"]
    open_inputs = 2

    [[generate]]
    run = ["scripts/make_rom.py", "--package", "pang.manifest", "{out}/rom_map_pkg.sv"]
    outputs = ["rom_map_pkg.sv"]
"""


class CoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_reads_core(self) -> None:
        core = config.load_core(write(self.dir, "core/core.toml", CORE))
        self.assertEqual(core.name, "pang_hdmi")
        self.assertEqual(core.hz, 37_125_000)
        self.assertEqual(core.platform, (self.dir / "common").resolve())
        self.assertEqual(core.vhdl.tops, ["T80s"])
        self.assertEqual(core.vhdl.x_ok, [])
        self.assertEqual(core.vhdl.open_inputs, 2)
        self.assertEqual(core.generate[0].outputs, ["rom_map_pkg.sv"])

    def test_sources_keep_order_and_sort_globs(self) -> None:
        for name in ["src/b_2.v", "src/b_1.v", "src/a.v"]:
            write(self.dir, "core/" + name, "")
        core = config.load_core(write(self.dir, "core/core.toml", CORE))
        names = [p.name for p in config.resolve(core.sources, core.folder)]
        self.assertEqual(names, ["a.v", "b_1.v", "b_2.v"])

    def test_glob_without_match_is_an_error(self) -> None:
        core = config.load_core(write(self.dir, "core/core.toml", CORE))
        with self.assertRaises(config.ConfigError) as err:
            config.resolve(core.sources, core.folder)
        self.assertIn("src/a.v", str(err.exception))

    def test_vhdl_tops_need_open_inputs(self) -> None:
        # a forgotten number must not pass as 0
        path = write(self.dir, "core/core.toml", CORE.replace("open_inputs = 2\n", ""))
        with self.assertRaises(config.ConfigError) as err:
            config.load_core(path)
        self.assertIn("vhdl.open_inputs is missing", str(err.exception))

    def test_unknown_table(self) -> None:
        path = write(self.dir, "core/core.toml", CORE + "\n[sourcess]\nfiles = []\n")
        with self.assertRaises(config.ConfigError) as err:
            config.load_core(path)
        self.assertIn("sourcess", str(err.exception))


PLATFORM = """
    [platform]
    top = "game20k_top"
    core_clock = "clk_core"
    core_hz_parameter = "CORE_HZ"

    [sources]
    files = ["src/top.sv"]

    [[generate]]
    run = ["{root}/scripts/make_menu.py", "--out", "{out}", "{core}"]
    outputs = ["iface_pkg.sv"]

    [[clock]]
    name = "clk_pixel"
    net = "clk_pixel"
    hz = 74_250_000

    [[clock]]
    name = "clk_core"
    net = "clk_core"
"""


class PlatformTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_core_clock_has_no_rate_of_its_own(self) -> None:
        platform = config.load_platform(write(self.dir, "platform.toml", PLATFORM))
        self.assertEqual(platform.top, "game20k_top")
        self.assertEqual([c.hz for c in platform.clocks], [74_250_000, None])

    def test_include_dirs_core_first(self) -> None:
        core = config.load_core(write(self.dir, "core/core.toml", CORE))
        text = PLATFORM.replace('files = ["src/top.sv"]', 'files = ["src/top.sv"]\n    include = ["inc"]')
        platform = config.load_platform(write(self.dir, "common/platform.toml", text))
        dirs = config.include_dirs(core, platform)
        self.assertEqual(dirs, [self.dir / "core/src/inc", self.dir / "common/inc"])

    def test_core_clock_with_rate_is_an_error(self) -> None:
        text = PLATFORM.replace('net = "clk_core"', 'net = "clk_core"\nhz = 1')
        with self.assertRaises(config.ConfigError) as err:
            config.load_platform(write(self.dir, "platform.toml", text))
        self.assertIn("clk_core", str(err.exception))

    def test_other_clock_needs_rate(self) -> None:
        text = PLATFORM.replace("hz = 74_250_000", "")
        with self.assertRaises(config.ConfigError) as err:
            config.load_platform(write(self.dir, "platform.toml", text))
        self.assertIn("hz", str(err.exception))


PROJECT = """
    [project]
    name = "p"
    board = "boards/b"

    [[slot]]
    core = "fpga/one"

    [[slot]]
    core = "fpga/two"
"""


class ProjectTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        write(self.dir, "boards/b/board.toml", BOARD)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_slots_follow_ring_order(self) -> None:
        project = config.load_project(write(self.dir, "project.toml", PROJECT))
        self.assertEqual(project.board.name, "Tang Nano 20K")
        self.assertEqual(project.address(self.dir / "fpga/two"), 0x100000)
        # the last core of the ring switches back to the first
        self.assertEqual(project.next_address(self.dir / "fpga/two"), 0)

    def test_core_outside_the_ring(self) -> None:
        project = config.load_project(write(self.dir, "project.toml", PROJECT))
        with self.assertRaises(config.ConfigError):
            project.address(self.dir / "fpga/three")

    def test_core_twice(self) -> None:
        path = write(self.dir, "project.toml", PROJECT + '\n[[slot]]\ncore = "fpga/one"\n')
        with self.assertRaises(config.ConfigError) as err:
            config.load_project(path)
        self.assertIn("slot[2]", str(err.exception))

    def test_more_slots_than_flash(self) -> None:
        path = write(self.dir, "project.toml", PROJECT + '\n[[slot]]\ncore = "fpga/three"\n')
        with self.assertRaises(config.ConfigError) as err:
            config.load_project(path)
        self.assertIn("3 slots", str(err.exception))


if __name__ == "__main__":
    unittest.main()
