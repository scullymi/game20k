# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for g20k.py sim: reading sim.toml, the frames against their reference, the work
folder, the ROM image and when a bench passes, with Verilator and make_rom.py replaced."""

import io
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from tools.engine import sim, toolchain
from tools.engine.config import ConfigError
from tools.engine.host import StepError

## the game20k tree, for its sim.toml files
ROOT = Path(__file__).resolve().parents[3]

BENCH = '[[x.bench]]\ntop = "tb_x"\nfiles = ["tb_x.sv"]\n'


class LoadTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, rel: str, text: str) -> None:
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def test_the_simulations_of_this_tree(self) -> None:
        sims = sim.load(ROOT)
        self.assertEqual(
            [n for n, s in sims.items() if s.ci], ["rom_sdram", "screen", "audio", "mcu", "mirror"]
        )
        self.assertEqual(sims["1942"].sets, ["1942", "vulgus", "higemaru"])
        self.assertEqual(sims["1942"].variants["fb"], ["ROM_PATH", "FB_PATH"])
        self.assertEqual(sims["1942"].rom_bytes[1], sim.Slice("id.hex", 0x3AA00, 0x3AB00, "ID_SECTION"))
        self.assertEqual(sims["mirror"].benches[1].generics, {"JR": "true"})
        # every file a bench names is there, but those of the work folder and the core's
        for s in sims.values():
            for b in s.benches:
                for f in b.files:
                    if not f.startswith("{"):
                        self.assertTrue((s.folder / f).is_file(), f"{s.name}: {f}")
            for f in s.files:
                self.assertTrue((s.folder / f).is_file(), f"{s.name}: {f}")

    def test_common_first(self) -> None:
        self.write("fpga/a_hdmi/sim/sim.toml", '[x]\nabout = "a"\n' + BENCH)
        self.write("fpga/common/sim/sim.toml", '[y]\nabout = "c"\n' + BENCH.replace("x.", "y."))
        self.assertEqual(list(sim.load(self.root)), ["y", "x"])

    def test_errors(self) -> None:
        cases = {
            '[x]\nabout = "a"\nmisspelt = 1\n' + BENCH: "unknown x.misspelt",
            '[x]\nabout = "a"\n': "neither run nor",
            '[x]\nabout = "a"\nrun = "sim.py"\n': "<file>:<function>",
            '[x]\nabout = "a"\ntool = "iverilog"\n' + BENCH: "verilator or nvc",
            '[x]\nabout = "a"\nrom = { words = "r.hex" }\n' + BENCH: "needs sets and core",
            '[x]\nabout = "a"\nsheets = [{ png = "a.png", frames = ["f"] }]\n' + BENCH: "needs sheet_script",
            '[x]\nabout = "a"\nvariants = { port = "x" }\n' + BENCH: "x.variants.port must be list",
        }
        for text, message in cases.items():
            self.write("fpga/common/sim/sim.toml", text)
            with self.assertRaises(ConfigError, msg=text) as e:
                sim.load(self.root)
            self.assertIn(message, str(e.exception))

    def test_name_twice(self) -> None:
        self.write("fpga/common/sim/sim.toml", '[x]\nabout = "a"\n' + BENCH)
        self.write("fpga/a_hdmi/sim/sim.toml", '[x]\nabout = "b"\n' + BENCH)
        with self.assertRaises(ConfigError) as e:
            sim.load(self.root)
        self.assertIn("simulation x is in", str(e.exception))


class FramesTest(unittest.TestCase):
    def test_report(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            for name, data in (("a.ppm", b"a"), ("b.ppm", b"b"), ("new.ppm", b"n")):
                (d / name).write_bytes(data)
            ref = d / "ref.sha256"
            sha_a = toolchain.sha256(d / "a.ppm")
            ref.write_text(f"{sha_a}  a.ppm\n{'0' * 64}  b.ppm\n{'1' * 64}  gone.ppm\n")
            self.assertEqual(
                sim.frames_report(d, ref), ["b.ppm: differs", "gone.ppm: missing", "new.ppm: no reference"]
            )
            ref.write_text(f"{sha_a}  a.ppm\n")
            (d / "b.ppm").unlink()
            (d / "new.ppm").unlink()
            self.assertEqual(sim.frames_report(d, ref), [])


class HelpersTest(unittest.TestCase):
    def test_git_blob(self) -> None:
        # git hash-object of a file holding "hello\n"
        self.assertEqual(sim.git_blob(b"hello\n"), "ce013625030ba8dba906f756967f9e9ca394464a")

    def test_work_folder(self) -> None:
        s = sim.Sim("1942", ROOT, "x")
        self.assertEqual(
            sim.work_folder(ROOT, s, "path", "vulgus"), ROOT / "build" / "sim" / "1942-path-vulgus"
        )
        self.assertEqual(sim.work_folder(ROOT, s, "", ""), ROOT / "build" / "sim" / "1942")

    def test_prepare_work_keeps_builds_and_fetched_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            w = Path(tmp) / "w"
            for p in ("obj_tb/Vtb", "frames/f1.ppm", "T80s.v", "sim.log"):
                (w / p).parent.mkdir(parents=True, exist_ok=True)
                (w / p).write_text("x")
            sim.prepare_work(w, ["T80s.v"])
            self.assertEqual(sorted(p.name for p in w.iterdir()), ["T80s.v", "obj_tb"])

    def test_choices_are_checked(self) -> None:
        s = sim.Sim("x", ROOT, "x", variants={"port": []}, sets=["a"])
        with self.assertRaises(StepError) as e:
            sim.run(ROOT, s, variant="fast")
        self.assertIn("variants port, not fast", str(e.exception))
        with self.assertRaises(StepError) as e:
            sim.run(ROOT, s, rom_set="b")
        self.assertIn("sets a, not b", str(e.exception))

    def test_not_on_windows(self) -> None:
        with mock.patch("tools.engine.sim.os.name", "nt"), self.assertRaises(StepError):
            sim.run(ROOT, sim.Sim("x", ROOT, "x"))


class RomTest(unittest.TestCase):
    def test_words_and_slices(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            s = sim.Sim("x", work, "x", core=work, sets=["a"], rom_words="rom32.hex")
            s.rom_bytes = [sim.Slice("p.hex", 4, 6, ""), sim.Slice("id.hex", 8, 12, "ID_SECTION")]
            ctx = sim.Context(work, s, work, "", "a", [])

            def make_rom(script: Path, *args: object) -> str:
                Path(str(args[-1])).write_bytes(bytes(range(1, 9)))
                return ""

            with mock.patch.object(sim.Context, "python", side_effect=make_rom):
                sim.rom_image(ctx)
            self.assertEqual((work / "rom32.hex").read_text(), "04030201\n08070605\n")
            self.assertEqual((work / "p.hex").read_text(), "05\n06\n")
            # the id range lies past the end of this image: empty, so no define
            self.assertEqual((work / "id.hex").read_text(), "")
            self.assertEqual(ctx.defines, [])


@unittest.skipIf(os.name == "nt", "the simulations run on Linux and macOS")
class PassTest(unittest.TestCase):
    """A bench passes on exit status 0 with a line PASS, Verilator's report lines left out."""

    def bench(self, output: str, code: int) -> tuple[bool, str]:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            exe = work / "Vtb_x"
            exe.write_text(
                f"#!{sys.executable}\nimport sys\nsys.stdout.write({output!r})\nsys.exit({code})\n"
            )
            exe.chmod(exe.stat().st_mode | stat.S_IXUSR)
            s = sim.Sim("x", work, "x", benches=[sim.Bench("tb_x", ["tb_x.sv"], ["+dir={work}/img"], {})])
            ctx = sim.Context(work, s, work, "", "", [])
            out = io.StringIO()
            with mock.patch.object(sim.Context, "verilator", return_value=exe), redirect_stdout(out):
                try:
                    sim.run_verilator(ctx)
                    return True, out.getvalue()
                except StepError:
                    return False, out.getvalue()

    def test_pass(self) -> None:
        ok, text = self.bench("checking\nPASS\n- S i m u l a t i o n   R e p o r t\n", 0)
        self.assertTrue(ok)
        self.assertEqual(text, "checking\nPASS\n")

    def test_fail_line_with_exit_status_0(self) -> None:
        self.assertFalse(self.bench("FAIL: ROM data late in the picture\n", 0)[0])

    def test_pass_with_exit_status_1(self) -> None:
        self.assertFalse(self.bench("PASS\n", 1)[0])

    def test_pass_inside_a_line(self) -> None:
        self.assertFalse(self.bench("no PASS here\n", 0)[0])


if __name__ == "__main__":
    unittest.main()
