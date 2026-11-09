# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for fetching the files of a published release, on file:// URLs, no network."""

import io
import shutil
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from tools.engine import cli, config, host, published, toolchain
from tools.engine.host import StepError
from tools.engine.tests.test_config import BOARD, PROJECT, write


class RepositoryTest(unittest.TestCase):
    def project(self, releases: str) -> config.Project:
        return config.Project(Path("."), "p", mock.Mock(), [], releases=releases)

    def test_owner_and_name(self) -> None:
        self.assertEqual(published.repository(self.project("https://github.com/o/n")), "o/n")
        self.assertEqual(published.repository(self.project("https://github.com/o/n/")), "o/n")

    def test_others_stop(self) -> None:
        for url in ("", "https://gitlab.com/o/n", "https://github.com/o", "https://github.com/o/n/x"):
            with self.subTest(url=url), self.assertRaises(StepError):
                published.repository(self.project(url))


class FetchTest(unittest.TestCase):
    """@brief A release 1.2.0 of project p with the zip of the cores of board b."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        write(self.root, "boards/b/board.toml", BOARD)
        text = PROJECT.replace(
            'board = "boards/b"', 'board = "boards/b"\n    releases = "https://github.com/o/n"'
        )
        write(self.root, "project.toml", text)
        write(self.root, "tools.toml", "")
        self.zip = self.root / "served" / "p-1.2.0-cores-b.zip"
        self.zip.parent.mkdir()
        with zipfile.ZipFile(self.zip, "w") as z:
            z.writestr("p-1.2.0-cores-b/p-1.2.0-cores-b.bin", b"image")
            z.writestr("p-1.2.0-cores-b/FLASHING.txt", b"text")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def info(self, digest: str | None = None) -> dict[str, object]:
        sha = toolchain.sha256(self.zip)
        asset = {
            "name": self.zip.name,
            "browser_download_url": self.zip.as_uri(),
            "digest": digest or f"sha256:{sha}",
        }
        return {"tag_name": "v1.2.0", "assets": [asset]}

    def test_api_address(self) -> None:
        project = config.load_project(self.root / "project.toml")
        for version, which in (("1.2.0", "tags/v1.2.0"), ("v1.2.0", "tags/v1.2.0"), ("latest", "latest")):
            with (
                self.subTest(version=version),
                mock.patch.object(host, "run", return_value='{"tag_name": "v1"}') as run,
            ):
                self.assertEqual(published.release(self.root, project, version), {"tag_name": "v1"})
            self.assertEqual(run.call_args.args[0][-1], f"https://api.github.com/repos/o/n/releases/{which}")

    def test_cores_image_is_fetched_checked_and_kept(self) -> None:
        info = self.info()
        with mock.patch.object(published, "release", return_value=info), redirect_stdout(io.StringIO()):
            image = published.cores_image(self.root, "1.2.0")
        self.assertEqual(image.read_bytes(), b"image")
        # a second call takes the download and the unpacked folder as they are
        self.zip.unlink()
        with (
            mock.patch.object(published, "release", return_value=info),
            redirect_stdout(io.StringIO()) as out,
        ):
            self.assertEqual(published.cores_image(self.root, "1.2.0"), image)
        self.assertEqual(out.getvalue(), "")
        # the unpacked folder alone is enough, its marker names the zip's SHA-256
        shutil.rmtree(toolchain.tools_dir(self.root) / "downloads")
        with mock.patch.object(published, "release", return_value=info):
            self.assertEqual(published.cores_image(self.root, "1.2.0"), image)

    def test_wrong_digest_stops(self) -> None:
        with mock.patch.object(published, "release", return_value=self.info("sha256:" + "0" * 64)):
            with redirect_stdout(io.StringIO()), self.assertRaises(StepError) as err:
                published.cores_image(self.root, "1.2.0")
        self.assertIn("GitHub expects " + "0" * 64, str(err.exception))

    def test_no_digest_stops(self) -> None:
        info = self.info()
        info["assets"][0]["digest"] = None  # type: ignore[index]
        with mock.patch.object(published, "release", return_value=info), self.assertRaises(StepError) as err:
            published.cores_image(self.root, "1.2.0")
        self.assertIn("no SHA-256", str(err.exception))

    def test_missing_file_names_the_others(self) -> None:
        with (
            mock.patch.object(published, "release", return_value=self.info()),
            self.assertRaises(StepError) as err,
        ):
            published.pico_firmware(self.root, "1.2.0")
        self.assertIn("p-1.2.0-cores-b.zip", str(err.exception))

    def test_zip_without_the_uf2_stops(self) -> None:
        self.zip = self.zip.with_name("p-1.2.0-firmware-pico2w.zip")
        with zipfile.ZipFile(self.zip, "w") as z:
            z.writestr("p-1.2.0-firmware-pico2w/README.txt", b"text")
        with (
            mock.patch.object(published, "release", return_value=self.info()),
            redirect_stdout(io.StringIO()),
            self.assertRaises(StepError) as err,
        ):
            published.pico_firmware(self.root, "1.2.0")
        self.assertIn("no p-1.2.0-firmware-pico2w.uf2", str(err.exception))


class CommandLineTest(unittest.TestCase):
    def test_flash_needs_something(self) -> None:
        with (
            redirect_stdout(io.StringIO()),
            mock.patch("sys.stderr", io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            cli.main(["flash"])

    def test_download_takes_no_core(self) -> None:
        for argv in (
            ["flash", "fpga/x", "--download"],
            ["flash", "--download", "--sram"],
            ["firmware", "--download", "--bl616", "nano20k"],
        ):
            with (
                self.subTest(argv=argv),
                mock.patch("sys.stderr", io.StringIO()),
                self.assertRaises(SystemExit),
            ):
                cli.main(argv)

    def test_firmware_download_shows_the_steps(self) -> None:
        with (
            mock.patch.object(published, "pico_firmware", return_value=Path("/x/f.uf2")) as get,
            redirect_stdout(io.StringIO()) as out,
        ):
            self.assertEqual(cli.main(["firmware", "--download", "1.2.0"]), 0)
        get.assert_called_once_with(cli.ROOT, "1.2.0")
        self.assertIn("BOOTSEL", out.getvalue())
        self.assertIn("f.uf2", out.getvalue())


if __name__ == "__main__":
    unittest.main()
