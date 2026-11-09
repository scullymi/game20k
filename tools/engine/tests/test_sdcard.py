# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the SD card: reading config.ini, its line limit, the settings files and the
copy onto the card, with make_rom.py replaced."""

import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from tools.engine import sdcard
from tools.engine.host import StepError

TEMPLATE = (
    "[WIFI]\nSSID=YOUR_WIFI_NAME\nPASS=YOUR_WIFI_PASSWORD\n\n[RA]\nUSER=YOUR_RA_USER\nTOKEN=YOUR_RA_TOKEN\n"
)


class IniTest(unittest.TestCase):
    def test_value_as_the_firmware_reads_it(self) -> None:
        text = "[wifi]\n ssid = home ; comment\n;PASS=x\n[RA]\nUSER=me\r\n"
        self.assertEqual(sdcard.ini_value(text, "WIFI", "SSID"), "home")
        self.assertEqual(sdcard.ini_value(text, "WIFI", "PASS"), "")
        self.assertEqual(sdcard.ini_value(text, "RA", "user"), "me")
        self.assertEqual(sdcard.ini_value(text, "RA", "SSID"), "")
        # a comment after the section name, the first of two entries
        text = "[WIFI] ; home\nSSID=a\nSSID=b\n[ RA ]\nUSER=me\n"
        self.assertEqual(sdcard.ini_value(text, "WIFI", "SSID"), "a")
        # the firmware keeps the blanks inside the brackets, [ RA ] is no section RA
        self.assertEqual(sdcard.ini_value(text, "RA", "USER"), "")

    def test_placeholders_are_not_set(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ini = Path(tmp) / "config.ini"
            ini.write_text(TEMPLATE.replace("YOUR_RA_USER", "me"))
            values = sdcard.credentials(ini)
        self.assertEqual(values["RA_USER"], "me")
        self.assertEqual(values["RA_TOKEN"], "")
        self.assertEqual(values["WIFI_SSID"], "")

    def test_long_lines(self) -> None:
        ok = b"x" * 126
        cut = b"x" * 127
        kept = b"KEY=v ;" + b"x" * 200
        crlf = b"x" * 126 + b"\r"
        # the semicolon as the last of the 127 bytes f_gets keeps, and one byte later
        last = b"x" * 126 + b";" + b"x" * 10
        late = b"x" * 127 + b";"
        data = b"\n".join([ok, cut, kept, crlf, last, late]) + b"\n"
        self.assertEqual(sdcard.long_lines(data), [(2, cut), (4, crlf), (6, late)])


class CardTest(unittest.TestCase):
    """@brief A project with two cores, one of two sets, make_rom.py replaced."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        (self.root / "sdcard").mkdir()
        (self.root / "sdcard" / "config.ini.example").write_text(TEMPLATE)
        (self.root / "sdcard" / "README.md").write_text("card\n")
        (self.root / "roms").mkdir()
        self.manifests = []
        for core, name, ini in (
            ("fpga/pac", "pacman", "pacman.ini"),
            ("fpga/pac", "puckman", ""),
            ("fpga/gal", "galaga", "galaga.ini"),
        ):
            folder = self.root / core
            folder.mkdir(parents=True, exist_ok=True)
            (folder / f"{name}.manifest").write_text(f"# {name}\nset {name}\nzip {name}.zip\n")
            if ini:
                (folder / "menu_core.xml").write_text(f'<core ini="{ini}"/>\n')
            self.manifests.append(folder / f"{name}.manifest")
        self.card = self.root / "card"
        self.card.mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def make(self, target: Path | None) -> str:
        def build(root: Path, manifest: Path, out: Path) -> tuple[bool, list[str]]:
            out.write_bytes(b"rom")
            return True, [f"written: {out}", "WARNING: unknown ROM file"] if "galaga" in out.name else [
                f"written: {out}"
            ]

        with (
            mock.patch.object(sdcard, "manifests", return_value=self.manifests),
            mock.patch.object(sdcard, "build_rom", side_effect=build),
            redirect_stdout(io.StringIO()) as out,
            redirect_stderr(io.StringIO()),
        ):
            sdcard.make(self.root, target)
        return out.getvalue()

    def test_no_rom_stops(self) -> None:
        with self.assertRaises(StepError) as err:
            self.make(self.card)
        self.assertIn("every-rom", str(err.exception))
        self.assertEqual(list(self.card.iterdir()), [])

    def test_first_run_makes_config_and_copies(self) -> None:
        for name in ("puckman", "galaga"):
            (self.root / "roms" / f"{name}.zip").write_bytes(b"")
        out = self.make(self.card)
        self.assertIn("config.ini     created from the template", out)
        self.assertIn("Still open: galaga config.ini-new WiFi RA", out)
        # pacman.ini preselects puckman, the only set of its core that was built
        self.assertIn("image0=/sd/puckman.rom", (self.root / "sdcard" / "pacman.ini").read_text())
        self.assertEqual(
            sorted(p.name for p in self.card.iterdir()),
            ["README.md", "config.ini", "galaga.ini", "galaga.rom", "pacman.ini", "puckman.rom"],
        )

    def test_settings_named_like_the_file_win(self) -> None:
        for name in ("pacman", "puckman"):
            (self.root / "roms" / f"{name}.zip").write_bytes(b"")
        self.make(None)
        self.assertIn("image0=/sd/pacman.rom", (self.root / "sdcard" / "pacman.ini").read_text())

    def test_saved_settings_on_the_card_stay(self) -> None:
        (self.root / "roms" / "galaga.zip").write_bytes(b"")
        (self.card / "galaga.ini").write_text("saved\n")
        out = self.make(self.card)
        self.assertEqual((self.card / "galaga.ini").read_text(), "saved\n")
        self.assertIn("present on the card, stays", out)

    def test_long_line_stops_before_the_copy(self) -> None:
        (self.root / "roms" / "galaga.zip").write_bytes(b"")
        (self.root / "sdcard" / "config.ini").write_text(TEMPLATE + "X=" + "y" * 200 + "\n")
        with self.assertRaises(StepError):
            self.make(self.card)
        self.assertEqual(list(self.card.iterdir()), [])

    def test_config_xml_warns(self) -> None:
        (self.root / "roms" / "galaga.zip").write_bytes(b"")
        (self.card / "config.xml").write_text("<menu/>\n")
        self.assertIn("WARNING: there is a config.xml", self.make(self.card))


if __name__ == "__main__":
    unittest.main()
