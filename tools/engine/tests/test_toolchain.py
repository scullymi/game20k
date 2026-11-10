# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for tools.toml, local.toml and fetching, finding, unpacking and checking the programs."""

import io
import os
import shutil
import struct
import sys
import tarfile
import tempfile
import tomllib
import unittest
import unittest.mock
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tools.engine import config, forks, host, toolchain
from tools.engine.host import StepError
from tools.engine.tests.test_config import write

SHA = "0" * 64
COMMIT = "1" * 40

TOOLS = f"""
    [download.suite]
    version = "20261102"
    release = "https://example.org/suite"

    [download.suite.{toolchain.machine()}]
    url = "https://example.org/suite.tgz"
    sha256 = "{SHA}"
    python = "bin/tabbypy3"
    path = ["lib"]

    [download.ghdl]
    version = "6.0.0"
    release = "https://example.org/ghdl"

    [download.ghdl.{toolchain.machine()}]
    url = "https://example.org/ghdl.tar.gz"
    sha256 = "{SHA}"

    [source.apicula]
    repo = "https://example.org/apicula.git"
    commit = "{COMMIT}"

    [source.nextpnr]
    repo = "https://example.org/nextpnr.git"
    commit = "{COMMIT}"

    [source.eigen]
    repo = "https://example.org/eigen.git"
    commit = "{COMMIT}"

    [source.yosys]
    repo = "https://example.org/yosys.git"
    commit = "{COMMIT}"
"""


def fake_tools(root: Path) -> None:
    """@brief A tools.toml and, for each of its programs, the folder fetch or build would make."""
    write(root, "tools.toml", TOOLS)
    toolset = config.load_toolset(root / "tools.toml")
    versions = {d.name: d.version for d in toolset.downloads.values()}
    versions |= {s.name: s.commit for s in toolset.sources.values()}
    for name, version in versions.items():
        made = toolchain.folder(root, name, version)
        made.mkdir(parents=True)
        values = {"name": name, "version": version}
        # the forks carry the key of what they are made of
        if name in toolchain.BUILT:
            values["key"] = toolchain.forks_key(toolset)
        toolchain.write_marker(made, values)


def renew(root: Path, table: str, old: str, new: str) -> None:
    """@brief tools.toml with the first old after [table] replaced by new."""
    text = (root / "tools.toml").read_text()
    at = text.index(f"[{table}]")
    write(root, "tools.toml", text[:at] + text[at:].replace(old, new, 1))


class ToolsetTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_reads_toolset(self) -> None:
        toolset = config.load_toolset(write(self.root, "tools.toml", TOOLS))
        self.assertEqual(toolset.downloads["suite"].archives[toolchain.machine()].sha256, SHA)
        self.assertEqual(toolset.sources["nextpnr"].commit, COMMIT)

    def test_sha256_must_be_hex(self) -> None:
        path = write(self.root, "tools.toml", TOOLS.replace(SHA, "X" * 64, 1))
        with self.assertRaises(config.ConfigError) as err:
            config.load_toolset(path)
        self.assertIn("sha256", str(err.exception))

    def test_local_mode_and_paths(self) -> None:
        self.assertEqual(config.load_local(self.root / "local.toml", ("suite",)), config.Local())
        path = write(self.root, "local.toml", '[tools]\nmode = "source"\nsuite = "my/suite"\n')
        local = config.load_local(path, ("suite",))
        self.assertEqual((local.mode, local.paths), ("source", {"suite": self.root / "my/suite"}))
        write(self.root, "local.toml", '[tools]\nmode = "fast"\n')
        with self.assertRaises(config.ConfigError):
            config.load_local(path, ("suite",))

    def test_local_dir_of_the_programs(self) -> None:
        # relative to local.toml, ~ for the home folder
        path = write(self.root, "local.toml", '[tools]\ndir = "../outside"\n')
        self.assertEqual(config.load_local(path, ()).dir, (self.root / "../outside").resolve())
        write(self.root, "local.toml", '[tools]\ndir = "~/t"\n')
        self.assertEqual(config.load_local(path, ()).dir, Path.home() / "t")


class LocateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        fake_tools(self.root)
        # locate() puts the suite in front of PATH, the tests keep the PATH of the process
        path = unittest.mock.patch.dict(os.environ, {"PATH": os.environ.get("PATH", "")})
        path.start()
        self.addCleanup(path.stop)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_status_names_origin_and_folder(self) -> None:
        suite = toolchain.folder(self.root, "suite", "20261102")
        toolchain.write_marker(suite, toolchain.marker(suite) | {"url": "https://x/suite.tgz"})
        shutil.rmtree(toolchain.folder(self.root, "nextpnr", COMMIT))
        write(self.root, "local.toml", '[tools]\nghdl = "own-ghdl"\n')
        out = io.StringIO()
        with redirect_stdout(out):
            toolchain.status(self.root)
        lines = out.getvalue().splitlines()
        at = lines.index("suite 20261102: ok")
        self.assertEqual(lines[at + 1], "  from  https://x/suite.tgz")
        self.assertEqual(lines[lines.index(f"nextpnr {COMMIT[:12]}: missing") + 1], "  from  not there yet")
        ghdl = next(n for n, line in enumerate(lines) if line.startswith("ghdl "))
        self.assertEqual(lines[ghdl + 1], "  from  a path in local.toml")

    def test_fetched_folders(self) -> None:
        tools = toolchain.locate(self.root)
        self.assertEqual(tools.suite, toolchain.folder(self.root, "suite", "20261102"))
        nextpnr = toolchain.folder(self.root, "nextpnr", COMMIT)
        self.assertEqual(tools.nextpnr.parent, nextpnr / "bin")
        self.assertEqual(tools.yosys.parent, toolchain.folder(self.root, "yosys", COMMIT) / "bin")

    def test_python_and_path_of_the_suite(self) -> None:
        suite = toolchain.folder(self.root, "suite", "20261102")
        os.environ["PATH"] = os.pathsep.join(["/usr/bin", str(suite / "lib")])
        tools = toolchain.locate(self.root)
        toolchain.locate(self.root)
        # in front, and once
        self.assertEqual(os.environ["PATH"], os.pathsep.join([str(suite / "lib"), "/usr/bin"]))
        self.assertEqual(tools.python, suite / "bin/tabbypy3")

    def test_python_of_a_local_suite_on_a_machine_without_a_download(self) -> None:
        suite = toolchain.folder(self.root, "suite", "20261102")
        (self.root / "local.toml").write_text(f'[tools]\nsuite = "{suite.as_posix()}"\n')
        with unittest.mock.patch.object(toolchain, "machine", return_value="linux-riscv64"):
            self.assertEqual(toolchain.suite_python(self.root), suite / "bin/tabbypy3")

    def test_missing_folder_says_what_to_run(self) -> None:
        (toolchain.folder(self.root, "ghdl", "6.0.0") / toolchain.MARKER).unlink()
        with self.assertRaises(StepError) as err:
            toolchain.locate(self.root)
        self.assertIn("g20k.py tools fetch", str(err.exception))

    def test_forks_of_another_key(self) -> None:
        # another Eigen gives other placements, another suite another chip database: nextpnr
        # of the same commit is not the one tools.toml asks for
        for table, old, new in (
            ("source.eigen", COMMIT, "2" * 40),
            ("download.suite", "20261102", "20261201"),
        ):
            shutil.rmtree(self.root / "external")
            fake_tools(self.root)
            renew(self.root, table, old, new)
            for name in toolchain.BUILT:
                with self.subTest(table=table, name=name), self.assertRaises(StepError) as err:
                    toolchain.find(self.root, name)
                self.assertIn("built from other sources", str(err.exception))

    def test_key_covers_the_recipe(self) -> None:
        toolset = config.load_toolset(self.root / "tools.toml")
        key = toolchain.forks_key(toolset)
        recipe = self.root / "forks.py"
        # LF, as on macOS and Linux, from a checkout of either kind
        text = toolchain.RECIPE.read_bytes().replace(b"\r\n", b"\n")
        for changed, same in ((text + b"# another recipe\n", False), (text.replace(b"\n", b"\r\n"), True)):
            recipe.write_bytes(changed)
            with self.subTest(same=same), unittest.mock.patch.object(toolchain, "RECIPE", recipe):
                self.assertEqual(toolchain.forks_key(toolset) == key, same)

    def test_suite_without_the_forks(self) -> None:
        # building the forks needs the suite before nextpnr exists
        (toolchain.folder(self.root, "nextpnr", COMMIT) / toolchain.MARKER).unlink()
        self.assertEqual(toolchain.find(self.root, "suite"), toolchain.folder(self.root, "suite", "20261102"))
        with self.assertRaises(StepError) as err:
            toolchain.locate(self.root)
        self.assertIn("g20k.py tools fetch", str(err.exception))
        # a machine that builds the forks itself is told to build them
        write(self.root, "local.toml", '[tools]\nmode = "source"\n')
        with self.assertRaises(StepError) as err:
            toolchain.locate(self.root)
        self.assertIn("g20k.py tools build-forks", str(err.exception))

    def test_programs_from_tools_toml(self) -> None:
        toolset = config.load_toolset(self.root / "tools.toml")
        self.assertEqual(toolchain.programs(toolset), ("suite", "ghdl", "apicula", "nextpnr", "yosys"))
        # Eigen is a source of nextpnr, not a program of the build
        with self.assertRaises(StepError) as err:
            toolchain.find(self.root, "eigen")
        self.assertIn("no program eigen", str(err.exception))

    def test_local_path_of_other_version_warns(self) -> None:
        own = self.root / "own-suite"
        own.mkdir()
        toolchain.write_marker(own, {"name": "suite", "version": "20250101"})
        write(self.root, "local.toml", '[tools]\nsuite = "own-suite"\n')
        warnings = io.StringIO()
        with redirect_stderr(warnings):
            self.assertEqual(toolchain.locate(self.root).suite, own)
        self.assertIn("20250101", warnings.getvalue())

    def test_save_mode_keeps_a_windows_path(self) -> None:
        write(self.root, "local.toml", "[tools]\nsuite = 'C:\\tools\\suite'\n")
        toolchain.save_mode(self.root / "local.toml", "prebuilt")
        with open(self.root / "local.toml", "rb") as f:
            self.assertEqual(tomllib.load(f)["tools"], {"suite": "C:\\tools\\suite", "mode": "prebuilt"})

    def test_save_mode_keeps_paths(self) -> None:
        write(self.root, "local.toml", '[tools]\nsuite = "own-suite"\n')
        toolchain.save_mode(self.root / "local.toml", "source")
        local = config.load_local(self.root / "local.toml", ("suite",))
        self.assertEqual((local.mode, local.paths), ("source", {"suite": self.root / "own-suite"}))


class UnpackTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_one_folder_gives_its_content(self) -> None:
        archive = self.dir / "a.tgz"
        with tarfile.open(archive, "w:gz") as t:
            data = b"x"
            info = tarfile.TarInfo("top/bin/tool")
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
        toolchain.unpack(archive, self.dir / "out")
        self.assertTrue((self.dir / "out/bin/tool").is_file())

    def test_the_resource_forks_of_a_mac_are_left_out(self) -> None:
        # as Bouffalo's toolchain comes: ._top beside top, ._name beside each file
        archive = self.dir / "a.tar.xz"
        with tarfile.open(archive, "w:xz") as t:
            for name in ("._top", "top/bin/tool", "top/bin/._tool"):
                info = tarfile.TarInfo(name)
                info.size = 1
                t.addfile(info, io.BytesIO(b"x"))
        toolchain.unpack(archive, self.dir / "out")
        self.assertTrue((self.dir / "out/bin/tool").is_file())
        self.assertFalse((self.dir / "out/bin/._tool").exists())

    def test_zip_with_several_entries(self) -> None:
        archive = self.dir / "a.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("bin/tool.exe", "x")
            z.writestr("lib/x", "y")
        toolchain.unpack(archive, self.dir / "out")
        self.assertTrue((self.dir / "out/bin/tool.exe").is_file())

    @unittest.skipIf(os.name == "nt", "Windows has no mode bits")
    def test_zip_keeps_the_mode_of_a_program(self) -> None:
        archive = self.dir / "a.zip"
        with zipfile.ZipFile(archive, "w") as z:
            info = zipfile.ZipInfo("bin/tool")
            info.external_attr = 0o755 << 16
            z.writestr(info, "x")
            z.writestr("lib/x", "y")
        toolchain.unpack(archive, self.dir / "out")
        self.assertTrue(os.access(self.dir / "out/bin/tool", os.X_OK))

    def test_path_outside_the_folder_is_refused(self) -> None:
        archive = self.dir / "a.tgz"
        with tarfile.open(archive, "w:gz") as t:
            info = tarfile.TarInfo("../evil")
            t.addfile(info, io.BytesIO(b""))
        with self.assertRaises(tarfile.TarError):
            toolchain.unpack(archive, self.dir / "out")
        self.assertFalse((self.dir / "evil").exists())


class PrebuiltTest(unittest.TestCase):
    """@brief The prebuilt forks of tools fetch from releases in a folder given as a file://
    URL, no network."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        fake_tools(self.root)
        for name in toolchain.BUILT:
            shutil.rmtree(toolchain.folder(self.root, name, COMMIT))
        self.served = self.root / "served"
        text = (self.root / "tools.toml").read_text()
        write(self.root, "tools.toml", text + f'[prebuilt]\nrepository = "{self.served.as_uri()}"\n')
        self.key = toolchain.forks_key(config.load_toolset(self.root / "tools.toml"))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def publish(self, inside: str | None = None, machine: str = toolchain.machine()) -> Path:
        """@brief Publishes an archive as the CI does, named with the key of tools.toml, its
        forks of the key inside, by default the same, and its SHA-256 beside it."""
        prebuilt = config.Prebuilt(self.served.as_uri())
        archive = self.root / prebuilt.url(self.key, machine).removeprefix(self.root.as_uri() + "/")
        archive.parent.mkdir(parents=True, exist_ok=True)
        made = self.root / "made"
        for name in toolchain.BUILT:
            (made / name / "bin").mkdir(parents=True)
            (made / name / "bin" / "tool").write_text("x")
            values = {"name": name, "version": COMMIT, "commit": COMMIT, "key": inside or self.key}
            toolchain.write_marker(made / name, values)
        with tarfile.open(archive, "w:gz") as t:
            for name in toolchain.BUILT:
                t.add(made / name, arcname=name)
        shutil.rmtree(made)
        archive.with_name(archive.name + ".sha256").write_text(
            f"{toolchain.sha256(archive)}  {archive.name}\n"
        )
        return archive

    def test_reads_prebuilt(self) -> None:
        prebuilt = config.Prebuilt("https://github.com/o/tools")
        self.assertEqual(prebuilt.release("abc"), "https://github.com/o/tools/releases/tag/forks-abc")
        self.assertEqual(
            prebuilt.url("abc", "linux-x64"),
            "https://github.com/o/tools/releases/download/forks-abc/game20k-forks-abc-linux-x64.tar.gz",
        )
        loaded = config.load_toolset(self.root / "tools.toml").prebuilt
        assert loaded is not None
        self.assertEqual(loaded.repository, self.served.as_uri())

    def test_prebuilt_takes_only_the_repository(self) -> None:
        write(self.root, "tools.toml", (self.root / "tools.toml").read_text() + 'release = "x"\n')
        with self.assertRaises(config.ConfigError) as err:
            config.load_toolset(self.root / "tools.toml")
        self.assertIn("release", str(err.exception))

    def test_unpacks_checks_and_keeps(self) -> None:
        archive = self.publish()
        with redirect_stdout(io.StringIO()) as out:
            forks.build(self.root, "prebuilt")
        nextpnr = toolchain.folder(self.root, "nextpnr", COMMIT)
        self.assertTrue((nextpnr / "bin/tool").is_file())
        self.assertEqual(toolchain.marker(nextpnr)["archive"], toolchain.sha256(archive))
        self.assertEqual(toolchain.marker(nextpnr)["url"], archive.as_uri())
        self.assertEqual(config.load_local(self.root / "local.toml", ("suite",)).mode, "prebuilt")
        self.assertIn(f"nextpnr {COMMIT[:12]} ({toolchain.machine()}): fetched and checked", out.getvalue())
        self.assertIn(f"  from    {archive.as_uri()}", out.getvalue())
        self.assertIn(f"  release {self.served.as_uri()}/releases/tag/forks-{self.key}", out.getvalue())
        # a second build takes the folders as they are, without the archive
        shutil.rmtree(self.served)
        shutil.rmtree(self.root / "external/tools/downloads")
        with redirect_stdout(io.StringIO()) as out:
            forks.build(self.root, "prebuilt")
        self.assertEqual(toolchain.locate(self.root).nextpnr.parent, nextpnr / "bin")
        self.assertIn(f"nextpnr {COMMIT[:12]} ({toolchain.machine()}): is there", out.getvalue())

    def test_unknown_mode_stops(self) -> None:
        with self.assertRaises(StepError) as err:
            forks.build(self.root, "sources")
        self.assertIn("source or prebuilt", str(err.exception))
        self.assertFalse((self.root / "local.toml").exists())

    def test_new_key_has_no_archive_yet(self) -> None:
        self.publish()
        with redirect_stdout(io.StringIO()):
            forks.build(self.root, "prebuilt")
        # the suite moves on: the folders of the old key must not stay, the new one has no release
        renew(self.root, "download.suite", "20261102", "20261201")
        key = toolchain.forks_key(config.load_toolset(self.root / "tools.toml"))
        with redirect_stdout(io.StringIO()), self.assertRaises(StepError) as err:
            forks.build(self.root, "prebuilt")
        self.assertIn(f"prebuilt forks of key {key}", str(err.exception))
        self.assertIn("tools build-forks", str(err.exception))

    def test_archive_of_another_key_stops(self) -> None:
        self.publish(inside="2" * 12)
        with redirect_stdout(io.StringIO()), self.assertRaises(StepError) as err:
            forks.build(self.root, "prebuilt")
        self.assertIn("forks of another key", str(err.exception))
        self.assertFalse(toolchain.folder(self.root, "nextpnr", COMMIT).exists())

    def test_wrong_sha256_stops(self) -> None:
        archive = self.publish()
        archive.with_name(archive.name + ".sha256").write_text("0" * 64 + "\n")
        with redirect_stdout(io.StringIO()), self.assertRaises(StepError) as err:
            forks.build(self.root, "prebuilt")
        self.assertIn(".sha256 expects " + "0" * 64, str(err.exception))

    def test_pack_writes_the_sha256_beside_the_archive(self) -> None:
        made = {}
        for name in toolchain.BUILT:
            folder = self.root / "made" / name
            (folder / "bin").mkdir(parents=True)
            made[name] = forks.Made(folder, "built here")
        with (
            unittest.mock.patch.object(forks, "make_forks", return_value=made),
            unittest.mock.patch.object(forks, "foreign_libraries", return_value=[]),
            redirect_stdout(io.StringIO()),
        ):
            archive = forks.pack(self.root, self.root / "dist")
        self.assertEqual(archive.name, config.Prebuilt.archive(self.key, toolchain.machine()))
        sums = archive.with_name(archive.name + ".sha256").read_text()
        self.assertEqual(sums, f"{toolchain.sha256(archive)}  {archive.name}\n")

    def test_no_archive_for_this_machine(self) -> None:
        self.publish(machine="plan9-mips")
        with redirect_stdout(io.StringIO()), self.assertRaises(StepError) as err:
            forks.build(self.root, "prebuilt")
        self.assertIn("no SHA-256 of the prebuilt forks", str(err.exception))
        # a mode that failed is not kept
        self.assertFalse((self.root / "local.toml").exists())


class BuildStepsTest(unittest.TestCase):
    """@brief What building the forks prints and checks, without building them."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        fake_tools(self.root)
        (self.root / "external/tools/src").mkdir(parents=True)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_took(self) -> None:
        self.assertEqual(forks.took(12.4), "12 s")
        self.assertEqual(forks.took(252), "4 min 12 s")

    def test_step_says_what_and_how_long(self) -> None:
        log = self.root / "external/tools/src/x.log"
        with redirect_stdout(io.StringIO()) as out:
            forks.step(self.root, "doing x", [sys.executable, "-c", "print('hi')"], log)
        self.assertEqual(log.read_text().strip(), "hi")
        self.assertIn("  doing x, log external/tools/src/x.log", out.getvalue())
        self.assertRegex(out.getvalue(), r"\n    done in \d+ s\n")

    def test_failed_step_names_its_log(self) -> None:
        log = self.root / "external/tools/src/x.log"
        with redirect_stdout(io.StringIO()), self.assertRaises(StepError) as err:
            forks.step(self.root, "doing x", [sys.executable, "-c", "raise SystemExit(3)"], log)
        self.assertIn("exit code 3", str(err.exception))
        self.assertIn(str(log), str(err.exception))

    def test_cmake_and_ninja_come_from_tools_toml(self) -> None:
        with self.assertRaises(StepError) as err:
            forks.build_tools(self.root)
        self.assertIn("no program cmake", str(err.exception))
        # with both in tools.toml, cmake is told the ninja of tools.toml
        text = (self.root / "tools.toml").read_text()
        for name in ("cmake", "ninja"):
            text += f'[download.{name}]\nversion = "1"\nrelease = "https://example.org/{name}"\n'
            text += f'[download.{name}.{toolchain.machine()}]\nurl = "https://example.org/{name}.zip"\n'
            text += f'sha256 = "{SHA}"\npath = ["."]\n'
            folder = toolchain.folder(self.root, name, "1")
            folder.mkdir(parents=True)
            toolchain.write_marker(folder, {"name": name, "version": "1"})
        write(self.root, "tools.toml", text)
        ninja = toolchain.folder(self.root, "ninja", "1") / ("ninja" + host.EXE)
        with unittest.mock.patch.dict(os.environ, {"PATH": os.environ.get("PATH", "")}):
            self.assertEqual(
                forks.build_tools(self.root), f"-DCMAKE_MAKE_PROGRAM:FILEPATH={ninja.as_posix()}"
            )
            front = os.environ["PATH"].split(os.pathsep)[:2]
            self.assertEqual(
                set(front), {str(toolchain.folder(self.root, n, "1")) for n in ("cmake", "ninja")}
            )
        # local.toml may name the ninja program itself
        program = self.root / "bin" / "ninja"
        program.parent.mkdir()
        program.write_text("")
        write(self.root, "local.toml", f'[tools]\nninja = "{program.as_posix()}"\n')
        with (
            unittest.mock.patch.dict(os.environ, {"PATH": os.environ.get("PATH", "")}),
            redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(
                forks.build_tools(self.root), f"-DCMAKE_MAKE_PROGRAM:FILEPATH={program.as_posix()}"
            )

    def test_report_of_a_fork_built_here(self) -> None:
        toolset = config.load_toolset(self.root / "tools.toml")
        nextpnr = toolchain.folder(self.root, "nextpnr", COMMIT)
        values = {"name": "nextpnr", "version": COMMIT, "repo": "https://example.org/nextpnr.git"}
        toolchain.write_marker(nextpnr, values | {"commit": COMMIT, "eigen": "2" * 40})
        with redirect_stdout(io.StringIO()) as out:
            toolchain.report_forks(self.root, toolset, {"nextpnr": forks.Made(nextpnr, "built here")})
        self.assertEqual(
            out.getvalue().splitlines(),
            [
                f"nextpnr {COMMIT[:12]} ({toolchain.machine()}): built here",
                "  from    https://example.org/nextpnr.git",
                f"  commit  {COMMIT}",
                f"  eigen   {'2' * 40} from https://example.org/eigen.git",
                f"  in      external/tools/nextpnr-{COMMIT[:12]}-{toolchain.machine()}",
            ],
        )


class ElfTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def elf(self, types: list[int]) -> Path:
        """@brief An ELF64 head with program headers of the types given, at offset 64."""
        head = bytearray(64)
        head[:4] = b"\x7fELF"
        struct.pack_into("<Q", head, 0x20, 64)
        struct.pack_into("<HH", head, 0x36, 56, len(types))
        table = b"".join(struct.pack("<I", t) + bytes(52) for t in types)
        path = self.dir / "program"
        path.write_bytes(bytes(head) + table)
        return path

    def test_static_and_dynamic(self) -> None:
        self.assertFalse(forks.elf_interpreter(self.elf([1, 1, 4])))
        self.assertTrue(forks.elf_interpreter(self.elf([6, 3, 1])))


class MovedCacheTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def cache(self, made_in: Path) -> Path:
        """@brief A build folder with a cmake cache made in made_in."""
        build_dir = self.dir / "build"
        build_dir.mkdir()
        (build_dir / "CMakeCache.txt").write_text(f"CMAKE_CACHEFILE_DIR:INTERNAL={made_in.as_posix()}\n")
        return build_dir

    def test_cache_of_another_folder_goes(self) -> None:
        build_dir = self.cache(self.dir / "old" / "build")
        with redirect_stdout(io.StringIO()) as out:
            forks.drop_moved_cache(build_dir)
        self.assertFalse(build_dir.exists())
        self.assertIn("building afresh", out.getvalue())

    def test_own_cache_and_no_cache_stay(self) -> None:
        build_dir = self.cache(self.dir / "build")
        forks.drop_moved_cache(build_dir)
        self.assertTrue((build_dir / "CMakeCache.txt").is_file())
        forks.drop_moved_cache(self.dir / "none")


class FetchTest(unittest.TestCase):
    """@brief fetch on archives given as file:// URLs, no network."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        archive = self.root / "a.tgz"
        with tarfile.open(archive, "w:gz") as t:
            info = tarfile.TarInfo("top/bin/tool")
            t.addfile(info, io.BytesIO(b""))
        self.sha = toolchain.sha256(archive)
        self.url = archive.as_uri()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def tools(self, sha: str) -> None:
        text = TOOLS.replace("https://example.org/suite.tgz", self.url).replace(SHA, sha, 1)
        # one download is enough
        write(self.root, "tools.toml", text.split("[download.ghdl]")[0])

    def test_fetches_checks_and_marks(self) -> None:
        self.tools(self.sha)
        with redirect_stdout(io.StringIO()) as out:
            toolchain.fetch(self.root)
            toolchain.fetch(self.root)
        dest = toolchain.folder(self.root, "suite", "20261102")
        self.assertTrue((dest / "bin/tool").is_file())
        self.assertEqual(toolchain.marker(dest)["sha256"], self.sha)
        self.assertIn("is there", out.getvalue())

    def test_fetches_only_the_named(self) -> None:
        self.tools(self.sha)
        with redirect_stdout(io.StringIO()):
            toolchain.fetch(self.root, ["suite"])
        self.assertTrue(toolchain.folder(self.root, "suite", "20261102").exists())
        with self.assertRaises(StepError) as err:
            toolchain.fetch(self.root, ["nosuch"])
        self.assertIn("nosuch", str(err.exception))

    def test_wrong_sha256_stops(self) -> None:
        self.tools("f" * 64)
        with redirect_stdout(io.StringIO()), self.assertRaises(StepError) as err:
            toolchain.fetch(self.root)
        self.assertIn("SHA-256", str(err.exception))
        self.assertFalse(toolchain.folder(self.root, "suite", "20261102").exists())


class ForeignLibrariesTest(unittest.TestCase):
    """@brief The check of pack on the output of dumpbin, on any machine."""

    DUMPBIN = """Dump of file yosys-abc.exe

File Type: EXECUTABLE IMAGE

  Image has the following dependencies:

    KERNEL32.dll
    VCRUNTIME140.dll
    other.dll

  Image has the following delay load dependencies:

    pthreadVC2.dll
"""

    def test_delay_loaded_dll_does_not_count(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            system = Path(tmp) / "System32"
            system.mkdir()
            (system / "KERNEL32.dll").touch()
            with (
                unittest.mock.patch.object(sys, "platform", "win32"),
                unittest.mock.patch.dict(os.environ, {"SystemRoot": tmp}),
                unittest.mock.patch.object(host, "run", return_value=self.DUMPBIN),
            ):
                found = forks.foreign_libraries(Path(tmp) / "yosys-abc.exe")
        self.assertEqual(found, ["VCRUNTIME140.dll", "other.dll"])


class OriginTest(unittest.TestCase):
    """@brief Where tools status says a folder came from, by its marker."""

    def test_origins(self) -> None:
        self.assertEqual(toolchain.origin({"url": "https://x/suite.tgz"}), "https://x/suite.tgz")
        # a marker of the prebuilt forks from before their URL was kept
        self.assertIn("sha256 bbbbbbbbbbbb", toolchain.origin({"archive": "b" * 64}))
        built = toolchain.origin({"repo": "https://x/yosys.git", "commit": "1" * 40})
        self.assertEqual(built, "built here from https://x/yosys.git at 111111111111")
        self.assertEqual(toolchain.origin({}), "unknown")


if __name__ == "__main__":
    unittest.main()
