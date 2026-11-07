# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the firmware build: its options and the checks on the image."""

import argparse
import tempfile
import unittest
import unittest.mock
from pathlib import Path

from tools.engine import cli, firmware, toolchain
from tools.engine.host import StepError


class PrefixTest(unittest.TestCase):
    def test_the_most_specific_path_comes_last(self) -> None:
        root = Path("/r")
        flags = firmware.prefix_flags(root, root / "external/tools/arm", root / "build/firmware/x").split()
        self.assertEqual(
            flags,
            [
                '"-ffile-prefix-map=/r=."',
                '"-ffile-prefix-map=/r/external/tools/arm=arm"',
                '"-ffile-prefix-map=/r/build/firmware/x=build"',
            ],
        )


class SwitchTest(unittest.TestCase):
    def test_without_ra_has_a_folder_and_an_option_of_its_own(self) -> None:
        root = Path("/r")
        self.assertEqual(
            firmware.out_folder(root, "native", ra=False), root / "build/firmware/pico2-native-no-ra"
        )
        tables = (root / "g.c", root / "m.c")
        with unittest.mock.patch.object(toolchain, "find", return_value=root / "t"):
            on = firmware.cmake_args(root, root / "o", "native", "1", tables)
            off = firmware.cmake_args(root, root / "o", "native", "1", tables, ra=False)
        self.assertIn("-DGAME20K_RA=ON", on)
        self.assertIn("-DGAME20K_RA=OFF", off)
        self.assertIn("-DGAME20K=ON", off)

    def test_upstream_builds_without_game20k(self) -> None:
        root = Path("/r")
        self.assertEqual(
            firmware.upstream_folder(root, "WS2040ZERO"), root / "build/firmware/upstream-ws2040zero"
        )
        with unittest.mock.patch.object(toolchain, "find", return_value=root / "t"):
            args = firmware.sdk_args(root, root / "o", "PICO")
        self.assertIn("-DBOARD=PICO", args)
        self.assertFalse([a for a in args if "GAME20K" in str(a)])

    def test_a_board_is_a_name_not_a_path(self) -> None:
        self.assertEqual(cli.board_name("msp2_20k"), "MSP2_20K")
        for bad in ("../x", "PICO/2", "", "PÏCO"):
            with self.assertRaises(argparse.ArgumentTypeError):
                cli.board_name(bad)


class LibrariesTest(unittest.TestCase):
    def test_the_libraries_replace_those_of_the_toolchain(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            arm, libraries = Path(tmp) / "arm", Path(tmp) / "armlibs"
            for base, text in ((arm, "machine"), (libraries, "one set")):
                for folder in firmware.LIBRARIES:
                    (base / folder).mkdir(parents=True)
                    (base / folder / "libc.a").write_text(text)
            (arm / "bin").mkdir()
            (arm / firmware.LIBRARIES[1] / "libother.a").write_text("machine")
            toolchain.write_marker(libraries, {"sha256": "abc"})
            toolchain.write_marker(arm, {"version": "1"})
            firmware.use_one_library_set(arm, libraries)
            for folder in firmware.LIBRARIES:
                self.assertEqual((arm / folder / "libc.a").read_text(), "one set")
            self.assertFalse((arm / firmware.LIBRARIES[1] / "libother.a").exists())
            self.assertTrue((arm / "bin").is_dir())
            self.assertEqual(toolchain.marker(arm), {"version": "1", "libraries": "abc"})
            # done once: a second run leaves the folders alone
            (arm / firmware.LIBRARIES[0] / "libc.a").write_text("kept")
            firmware.use_one_library_set(arm, libraries)
            self.assertEqual((arm / firmware.LIBRARIES[0] / "libc.a").read_text(), "kept")

    def test_a_run_that_stopped_halfway_is_done_again(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            arm, libraries = Path(tmp) / "arm", Path(tmp) / "armlibs"
            for folder in firmware.LIBRARIES:
                (libraries / folder).mkdir(parents=True)
                (libraries / folder / "libc.a").write_text("one set")
            arm.mkdir()  # the folders of the toolchain are gone, its marker says nothing
            toolchain.write_marker(libraries, {"sha256": "abc"})
            toolchain.write_marker(arm, {"version": "1"})
            firmware.use_one_library_set(arm, libraries)
            self.assertEqual((arm / firmware.LIBRARIES[0] / "libc.a").read_text(), "one set")


class TablesTest(unittest.TestCase):
    GOOD = "dir/r/build/firmware/gen/ra_games_data.c.o\ndir/r/build/firmware/gen/menus_data.c.obj\n"

    def test_generated_tables_pass(self) -> None:
        firmware.check_tables(self.GOOD)

    def test_an_example_table_stops(self) -> None:
        with self.assertRaises(StepError):
            firmware.check_tables(self.GOOD + "dir/r/src/menus_example.c.o\n")

    def test_a_missing_table_stops(self) -> None:
        with self.assertRaises(StepError):
            firmware.check_tables("dir/r/build/firmware/gen/menus_data.c.o\n")


class ImageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.ini = Path(self.tmp.name) / "config.ini"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_good_image(self) -> None:
        firmware.check_image(b"\0game20k/v1.2.3 (x)\0", "1.2.3", self.ini)

    def test_other_version_stops(self) -> None:
        with self.assertRaises(StepError):
            firmware.check_image(b"game20k/v1.2.4 (x)", "1.2.3", self.ini)

    def test_diagnostic_output_stops(self) -> None:
        with self.assertRaises(StepError):
            firmware.check_image(b"game20k/v1.2.3 \0TEST: x", "1.2.3", self.ini)

    def test_a_value_before_a_comment_stops(self) -> None:
        self.ini.write_text("[WIFI]\nPASS=hunter2 ; my network\n")
        with self.assertRaises(StepError):
            firmware.check_image(b"game20k/v1.2.3 hunter2", "1.2.3", self.ini)

    def test_a_value_of_the_config_stops(self) -> None:
        self.ini.write_text("[WIFI]\nPASS = hunter2\n")
        with self.assertRaises(StepError):
            firmware.check_image(b"game20k/v1.2.3 hunter2", "1.2.3", self.ini)
        firmware.check_image(b"game20k/v1.2.3 ", "1.2.3", self.ini)


if __name__ == "__main__":
    unittest.main()
