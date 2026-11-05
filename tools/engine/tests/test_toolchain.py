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
        # tools build needs the suite before nextpnr exists
        (toolchain.folder(self.root, "nextpnr", COMMIT) / toolchain.MARKER).unlink()
        self.assertEqual(toolchain.find(self.root, "suite"), toolchain.folder(self.root, "suite", "20261102"))
        with self.assertRaises(StepError) as err:
            toolchain.locate(self.root)
        self.assertIn("g20k.py tools build", str(err.exception))

    def test_programs_from_tools_toml(self) -> None:
        toolset = config.load_toolset(self.root / "tools.toml")
        self.assertEqual(toolchain.programs(toolset), ("suite", "ghdl", "apicula", "nextpnr", "yosys"))
        # Eigen is a source of nextpnr, not a program of the build
        with self.assertRaises(StepError) as err:
            toolchain.find(self.root, "eigen")
        self.assertIn("no program eigen", str(err.exception))

    def test_build_needs_a_mode(self) -> None:
        with self.assertRaises(StepError) as err:
            forks.build(self.root, None)
        self.assertIn("--source or --prebuilt", str(err.exception))
        self.assertFalse((self.root / "local.toml").exists())

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

    def test_zip_with_several_entries(self) -> None:
        archive = self.dir / "a.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("bin/tool.exe", "x")
            z.writestr("lib/x", "y")
        toolchain.unpack(archive, self.dir / "out")
        self.assertTrue((self.dir / "out/bin/tool.exe").is_file())

    def test_path_outside_the_folder_is_refused(self) -> None:
        archive = self.dir / "a.tgz"
        with tarfile.open(archive, "w:gz") as t:
            info = tarfile.TarInfo("../evil")
            t.addfile(info, io.BytesIO(b""))
        with self.assertRaises(tarfile.TarError):
            toolchain.unpack(archive, self.dir / "out")
        self.assertFalse((self.dir / "evil").exists())


class PrebuiltTest(unittest.TestCase):
    """@brief tools build --prebuilt on an archive given as a file:// URL, no network."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        fake_tools(self.root)
        for name in toolchain.BUILT:
            shutil.rmtree(toolchain.folder(self.root, name, COMMIT))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def archive(self, key: str | None = None) -> Path:
        """@brief An archive as pack makes it, its forks of the key given, else of tools.toml."""
        key = key or toolchain.forks_key(config.load_toolset(self.root / "tools.toml"))
        archive = self.root / "forks.tar.gz"
        made = self.root / "made"
        for name in toolchain.BUILT:
            (made / name / "bin").mkdir(parents=True)
            (made / name / "bin" / "tool").write_text("x")
            values = {"name": name, "version": COMMIT, "commit": COMMIT, "key": key}
            toolchain.write_marker(made / name, values)
        with tarfile.open(archive, "w:gz") as t:
            for name in toolchain.BUILT:
                t.add(made / name, arcname=name)
        shutil.rmtree(made)
        return archive

    def prebuilt(self, archive: Path, machine: str = toolchain.machine()) -> None:
        sha = toolchain.sha256(archive)
        text = (self.root / "tools.toml").read_text()
        text += f'[prebuilt]\nrelease = "https://example.org/forks"\n[prebuilt.{machine}]\n'
        write(self.root, "tools.toml", text + f'url = "{archive.as_uri()}"\nsha256 = "{sha}"\n')

    def test_reads_prebuilt(self) -> None:
        self.prebuilt(self.archive())
        prebuilt = config.load_toolset(self.root / "tools.toml").prebuilt
        assert prebuilt is not None
        self.assertEqual(prebuilt.release, "https://example.org/forks")
        self.assertIn(toolchain.machine(), prebuilt.archives)

    def test_prebuilt_has_no_programs_of_its_own(self) -> None:
        self.prebuilt(self.archive())
        write(self.root, "tools.toml", (self.root / "tools.toml").read_text() + 'path = ["bin"]\n')
        with self.assertRaises(config.ConfigError) as err:
            config.load_toolset(self.root / "tools.toml")
        self.assertIn("path", str(err.exception))

    def test_unpacks_checks_and_keeps(self) -> None:
        archive = self.archive()
        self.prebuilt(archive)
        with redirect_stdout(io.StringIO()):
            forks.build(self.root, "prebuilt")
        nextpnr = toolchain.folder(self.root, "nextpnr", COMMIT)
        self.assertTrue((nextpnr / "bin/tool").is_file())
        self.assertEqual(toolchain.marker(nextpnr)["archive"], toolchain.sha256(archive))
        self.assertEqual(config.load_local(self.root / "local.toml", ("suite",)).mode, "prebuilt")
        # a second build takes the folders as they are, without the archive
        archive.unlink()
        shutil.rmtree(self.root / "external/tools/downloads")
        with redirect_stdout(io.StringIO()):
            forks.build(self.root, None)
        self.assertEqual(toolchain.locate(self.root).nextpnr.parent, nextpnr / "bin")

    def test_new_suite_needs_a_new_archive(self) -> None:
        self.prebuilt(self.archive())
        with redirect_stdout(io.StringIO()):
            forks.build(self.root, "prebuilt")
        # the suite moves on, [prebuilt] does not: the folders of the old archive must not stay
        renew(self.root, "download.suite", "20261102", "20261201")
        with redirect_stdout(io.StringIO()), self.assertRaises(StepError) as err:
            forks.build(self.root, "prebuilt")
        self.assertIn("other forks", str(err.exception))

    def test_archive_of_another_key_stops(self) -> None:
        self.prebuilt(self.archive("2" * 12))
        with redirect_stdout(io.StringIO()), self.assertRaises(StepError) as err:
            forks.build(self.root, "prebuilt")
        self.assertIn("other forks", str(err.exception))
        self.assertFalse(toolchain.folder(self.root, "nextpnr", COMMIT).exists())

    def test_no_archive_for_this_machine(self) -> None:
        self.prebuilt(self.archive(), "plan9-mips")
        with self.assertRaises(StepError) as err:
            forks.build(self.root, "prebuilt")
        self.assertIn("--source", str(err.exception))
        # a mode that failed is not kept
        self.assertFalse((self.root / "local.toml").exists())


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


if __name__ == "__main__":
    unittest.main()
