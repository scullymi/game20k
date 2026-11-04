# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for tools.toml, local.toml and finding, unpacking and checking the programs."""

import io
import tarfile
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tools.engine import config, toolchain
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
        toolchain.write_marker(made, {"name": name, "version": version})


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
        self.assertEqual(config.load_local(self.root / "local.toml"), config.Local())
        path = write(self.root, "local.toml", '[tools]\nmode = "source"\nsuite = "my/suite"\n')
        local = config.load_local(path)
        self.assertEqual((local.mode, local.paths), ("source", {"suite": self.root / "my/suite"}))
        write(self.root, "local.toml", '[tools]\nmode = "fast"\n')
        with self.assertRaises(config.ConfigError):
            config.load_local(path)


class LocateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        fake_tools(self.root)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_fetched_folders(self) -> None:
        tools = toolchain.locate(self.root)
        self.assertEqual(tools.suite, toolchain.folder(self.root, "suite", "20261102"))
        nextpnr = toolchain.folder(self.root, "nextpnr", COMMIT)
        self.assertEqual(tools.nextpnr.parent, nextpnr / "bin")

    def test_missing_folder_says_what_to_run(self) -> None:
        (toolchain.folder(self.root, "ghdl", "6.0.0") / toolchain.MARKER).unlink()
        with self.assertRaises(StepError) as err:
            toolchain.locate(self.root)
        self.assertIn("g20k.py tools fetch", str(err.exception))

    def test_suite_without_the_forks(self) -> None:
        # tools build needs the suite before nextpnr exists
        (toolchain.folder(self.root, "nextpnr", COMMIT) / toolchain.MARKER).unlink()
        self.assertEqual(toolchain.find(self.root, "suite"), toolchain.folder(self.root, "suite", "20261102"))
        with self.assertRaises(StepError) as err:
            toolchain.locate(self.root)
        self.assertIn("g20k.py tools build", str(err.exception))

    def test_build_needs_a_mode(self) -> None:
        with self.assertRaises(StepError) as err:
            toolchain.build(self.root, None)
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

    def test_save_mode_keeps_paths(self) -> None:
        write(self.root, "local.toml", '[tools]\nsuite = "own-suite"\n')
        toolchain.save_mode(self.root / "local.toml", "source")
        local = config.load_local(self.root / "local.toml")
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


if __name__ == "__main__":
    unittest.main()
