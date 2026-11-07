# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the openFPGALoader calls of g20k.py flash."""

import shutil
import tempfile
import unittest
from pathlib import Path

from tools.engine import config, firmware, flash, host, toolchain
from tools.engine.host import StepError
from tools.engine.tests.test_config import BOARD, CORE, PROJECT, write
from tools.engine.tests.test_toolchain import COMMIT, fake_tools


class FlashTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        write(self.root, "boards/b/board.toml", BOARD)
        write(self.root, "project.toml", PROJECT)
        fake_tools(self.root)
        for name in ("one", "two", "three"):
            write(self.root, f"fpga/{name}/core.toml", CORE.replace('"pang_hdmi"', f'"{name}"'))
        suite = toolchain.folder(self.root, "suite", "20261102")
        self.loader = suite / "bin" / ("openFPGALoader" + host.EXE)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def built(self, name: str) -> Path:
        return write(self.root, f"build/{name}/{name}.fs", "")

    def test_core_into_its_slot(self) -> None:
        fs = self.built("two")
        cmd = flash.command(self.root, self.root / "fpga/two")
        self.assertEqual(cmd, [self.loader, "-b", "tangnano20k", "-f", "-o", "0x100000", "--verify", fs])

    def test_core_into_sram(self) -> None:
        fs = self.built("one")
        cmd = flash.command(self.root, self.root / "fpga/one", sram=True)
        self.assertEqual(cmd, [self.loader, "-b", "tangnano20k", fs])

    def test_suite_is_enough(self) -> None:
        # flashing needs openFPGALoader of the suite, not the forks
        shutil.rmtree(toolchain.folder(self.root, "nextpnr", COMMIT))
        fs = self.built("one")
        self.assertEqual(flash.command(self.root, self.root / "fpga/one", sram=True)[-1], fs)

    def test_core_without_build(self) -> None:
        with self.assertRaises(StepError) as err:
            flash.command(self.root, self.root / "fpga/one")
        self.assertIn("g20k.py build fpga/one", str(err.exception))

    def test_core_outside_the_ring(self) -> None:
        # a core of no slot has no flash address, only SRAM takes it
        self.built("three")
        flash.command(self.root, self.root / "fpga/three", sram=True)
        with self.assertRaises(config.ConfigError) as err:
            flash.command(self.root, self.root / "fpga/three")
        self.assertIn("has no slot", str(err.exception))

    def test_image_from_zero(self) -> None:
        image = self.root / "x.bin"
        image.write_bytes(b"\xff" * 0x200000)
        cmd = flash.command(self.root, image=image)
        self.assertEqual(cmd, [self.loader, "-b", "tangnano20k", "-f", "-o", "0x000000", "--verify", image])

    def test_image_larger_than_the_flash(self) -> None:
        image = self.root / "x.bin"
        image.write_bytes(b"\xff" * (0x200000 + 1))
        with self.assertRaises(StepError):
            flash.command(self.root, image=image)

    def test_core_of_another_board(self) -> None:
        write(self.root, "boards/c/board.toml", BOARD)
        board = self.root / "boards" / "c"
        with self.assertRaises(StepError) as err:
            flash.command(self.root, self.root / "fpga/two", board=board)
        self.assertIn("g20k.py build fpga/two --board boards/c", str(err.exception))
        # the build of the other board, not that of project.toml's
        self.built("two")
        fs = write(self.root, "build/c/two/two.fs", "")
        self.assertEqual(flash.command(self.root, self.root / "fpga/two", board=board)[-2:], ["--verify", fs])


class Bl616Test(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        fake_tools(self.root)
        text = (self.root / "tools.toml").read_text()
        machine = toolchain.machine()
        text += (
            '\n[download.bouffalo_sdk]\nversion = "abc"\nrelease = "r"\n'
            f'\n[download.bouffalo_sdk.{machine}]\nurl = "u"\nsha256 = "{"0" * 64}"\n'
        )
        write(self.root, "tools.toml", text)
        made = toolchain.folder(self.root, "bouffalo_sdk", "abc")
        made.mkdir(parents=True)
        toolchain.write_marker(made, {"name": "bouffalo_sdk", "version": "abc"})

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_only_the_companion_address(self) -> None:
        image = write(firmware.bl616_folder(self.root, "nano20k"), "build_out/fpga_companion_bl616.bin", "")
        cmd = flash.bl616_command(self.root, "nano20k", "COM3")
        self.assertIn("--port=COM3", cmd)
        ini = (firmware.bl616_folder(self.root, "nano20k") / "companion.ini").read_text()
        # one image, at 0x40000: Sipeed's firmware at 0x0 stays
        self.assertEqual(ini.count("filedir"), 1)
        self.assertIn(f"filedir = {image.as_posix()}\naddress = 0x40000\n", ini)

    def test_without_build(self) -> None:
        with self.assertRaises(StepError) as err:
            flash.bl616_command(self.root, "nano20k", "COM3")
        self.assertIn("g20k.py firmware --bl616 nano20k", str(err.exception))


if __name__ == "__main__":
    unittest.main()
