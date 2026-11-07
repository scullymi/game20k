# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the parts of the build that need no tools: clock lines, placeholders, checks."""

import json
import tempfile
import unittest
from pathlib import Path

from tools.engine import config
from tools.engine.flow import build
from tools.engine.tests.test_config import BOARD, PLATFORM, PROJECT, write


def make_build(root: Path) -> build.Build:
    """@brief A Build with a board clock on a port and platform clocks on nets, one of them the
    core's."""
    board = config.Board(
        root,
        "B",
        "dev",
        "fam",
        "gw2a",
        "ld",
        [root / "b.cst"],
        True,
        False,
        46,
        config.Flash(0x800000, 0x100000),
        [config.Clock("sys_clk", 27_000_000, port="sys_clk")],
        ["BOARD_PORTS"],
    )
    platform = config.Platform(
        root,
        "top",
        "clk_core",
        "CORE_HZ",
        [],
        [],
        [],
        [],
        [
            config.Clock("clk_pixel", 74_250_000, net="clk_pixel"),
            config.Clock("clk_core", None, net="clk_core"),
        ],
    )
    core = config.Core(root / "fpga" / "c", "c", root, 37_125_000, [], [])
    project = config.Project(root, "p", board, [core.folder])
    tools = config.Tools(*(root for _ in range(6)))
    return build.Build(root, project, platform, core, tools, root / "build" / "c")


class ClockTest(unittest.TestCase):
    def test_board_clocks_first_core_clock_from_core(self) -> None:
        lines = build.clock_lines(make_build(Path("/r")))
        self.assertEqual(
            lines,
            [
                "create_clock -name sys_clk -period 37.03703703703704 [get_ports {sys_clk}]",
                "create_clock -name clk_pixel -period 13.468013468013469 [get_nets {clk_pixel}]",
                "create_clock -name clk_core -period 26.936026936026938 [get_nets {clk_core}]",
            ],
        )


class SlangArgsTest(unittest.TestCase):
    def test_board_defines(self) -> None:
        args = build.slang_args(make_build(Path("/r")), [], Path("/r/prims.v"))
        self.assertIn(["-D", "BOARD_PORTS"], [args[i : i + 2] for i in range(len(args))])


class ShellLineTest(unittest.TestCase):
    def test_quotes_for_sh_and_cmd(self) -> None:
        args: list[str | Path] = ["C:\\Program Files\\Python\\python.exe", Path("s.py"), "a b"]
        line = '"C:\\Program Files\\Python\\python.exe" "s.py" "a b"'
        self.assertEqual(build.shell_line(args, windows=False), line)
        # cmd /c drops the outer pair, the quotes of the arguments stay
        self.assertEqual(build.shell_line(args, windows=True), f'"{line}"')


class PlaceholderTest(unittest.TestCase):
    def test_expand(self) -> None:
        b = make_build(Path("/r"))
        self.assertEqual(b.expand("{root}/s.py"), "/r/s.py")
        self.assertEqual(b.expand("{out}/x.sv"), "/r/build/c/gen/x.sv")
        self.assertEqual(b.expand("--core={core}"), "--core=c")

    def test_rel_uses_slashes(self) -> None:
        b = make_build(Path("/r"))
        self.assertEqual(b.rel(Path("/r/fpga/c/src/a.sv")), "fpga/c/src/a.sv")


class UndefinedOutputTest(unittest.TestCase):
    def test_ports_with_an_undefined_bit(self) -> None:
        netlist = {
            "modules": {
                "t": {
                    "ports": {
                        "a": {"direction": "output", "bits": [2, 3]},
                        "b": {"direction": "output", "bits": ["x", 4]},
                        "c": {"direction": "output", "bits": ["x"]},
                        "d": {"direction": "input", "bits": ["x"]},
                    }
                }
            }
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "n.json"
            path.write_text(json.dumps(netlist))
            self.assertEqual(build.undefined_outputs(path, "t"), ["b", "c"])


class SlangIntTest(unittest.TestCase):
    def test_constants(self) -> None:
        self.assertEqual(build.slang_int("5"), 5)
        self.assertEqual(build.slang_int("1'b1"), 1)
        self.assertEqual(build.slang_int("1'b0"), 0)
        self.assertEqual(build.slang_int("8'hff"), 255)
        self.assertEqual(build.slang_int("32'sd18562500"), 18562500)

    def test_unknown_bits(self) -> None:
        self.assertIsNone(build.slang_int("1'bx"))
        self.assertIsNone(build.slang_int(""))


class SourcesTest(unittest.TestCase):
    """@brief The source list a simulation takes: core.toml's files and include folders, with
    the generated files in out/gen."""

    def test_core_files_with_generated_ones(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            write(root, "boards/b/board.toml", BOARD)
            write(root, "project.toml", PROJECT.replace("fpga/one", "fpga/c"))
            # no tools.toml and no tools: a simulation takes the sources without them
            write(root, "fpga/common/platform.toml", PLATFORM.split("[[generate]]")[0])
            write(root, "fpga/c/src/a.v", "")
            write(root, "fpga/c/src/inc/x.vh", "")
            # a generator that also prints, which must not reach the list
            write(root, "gen.py", "import sys\nprint('made')\nopen(sys.argv[1], 'w').close()\n")
            write(
                root,
                "fpga/c/core.toml",
                """
                [core]
                name = "c"
                platform = "../common"
                hz = 1

                [sources]
                files = ["src/a.v", "{out}/g.sv"]
                include = ["src/inc"]

                [[generate]]
                run = ["{root}/gen.py", "{out}/g.sv"]
                outputs = ["g.sv"]
                """,
            )
            out = root / "sim"
            files, include = build.sources(root, root / "fpga/c/core.toml", out)
            self.assertEqual(files, [root / "fpga/c/src/a.v", out / "gen/g.sv"])
            self.assertEqual(include, [root / "fpga/c/src/inc"])


if __name__ == "__main__":
    unittest.main()
