# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The SD card: the ROM files from the user's MAME sets, config.ini, a settings file per
core, and copying them onto the card.

Everything is checked here and not on the device: the machine has no error channel, the menu
shows no errors and the UART is not connected, so a bad card fails silently there.

Sources the user provides: roms/<zip> (the MAME sets the manifests fpga/<core>/<set>.manifest
name) and sdcard/config.ini (Wi-Fi and RetroAchievements, made from the template on the first
run). Made per game with a set in roms/: sdcard/<set>.rom, by scripts/make_rom.py, which checks
every chip, and per core sdcard/<ini>, a settings file under the name its menu loads and saves,
with the ROM entry, so the first start needs no trip into the menu. All of it is gitignored."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

from tools.engine.host import StepError

## the longest line of config.ini the firmware reads whole: f_gets into a buffer of 128 bytes
# (inifile.c), less the line end and the terminating zero
LINE_LIMIT = 126

## the credentials in config.ini by section and key
CREDENTIALS = {"WiFi": (("WIFI", "SSID"), ("WIFI", "PASS")), "RA": (("RA", "USER"), ("RA", "TOKEN"))}


@dataclass
class Card:
    """@brief What prepare() made in sdcard/ for the card.

    - sets: the ROM files, by set name, in the order of the manifests
    - inis: the settings files of the cores
    - missing: what stops the copy onto the card
    - notes: what is still open but does not stop it
    """

    sets: list[str] = field(default_factory=list)
    inis: list[str] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


def report(what: str, text: str) -> None:
    print(f"  {what:<14} {text}")


def ini_value(text: str, section: str, key: str) -> str:
    """@brief The value of key in section of an ini text, empty when absent. Reads as the
    firmware does (inifile_config_parse_line): everything after a semicolon is a comment, a
    section is a line [name], names in any case, the first entry of a key counts."""
    current = ""
    for raw in text.splitlines():
        line = raw.split(";", 1)[0].strip()
        if len(line) > 2 and line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            continue
        name, equals, value = line.partition("=")
        if equals and current.upper() == section.upper() and name.strip().upper() == key.upper():
            return value.strip()
    return ""


def credentials(ini: Path) -> dict[str, str]:
    """@brief The credentials of config.ini as SECTION_KEY, e.g. RA_TOKEN. A placeholder of the
    template (YOUR_...) counts as not set."""
    text = ini.read_text(encoding="utf-8", errors="replace") if ini.is_file() else ""
    values = {}
    for pair in CREDENTIALS.values():
        for section, key in pair:
            value = ini_value(text, section, key)
            values[f"{section}_{key}"] = "" if value.startswith("YOUR_") else value
    return values


def long_lines(data: bytes) -> list[tuple[int, bytes]]:
    """@brief The lines of config.ini the firmware drops, with their numbers: longer than
    LINE_LIMIT bytes, with no semicolon in the 127 bytes f_gets keeps of them. A CR of a CRLF
    line counts, as in the firmware."""
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    return [
        (n, line)
        for n, line in enumerate(lines, 1)
        if len(line) > LINE_LIMIT and b";" not in line[: LINE_LIMIT + 1]
    ]


def manifest_value(path: Path, name: str) -> str:
    """@brief The first value of a line "name value" in a manifest."""
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) > 1 and parts[0] == name:
            return parts[1]
    raise StepError(f"{path}: no {name} line")


def manifests(root: Path) -> list[Path]:
    """@brief The ROM manifests under fpga/, in the order make_rom.py --list gives them."""
    out = subprocess.run(
        [sys.executable, root / "scripts" / "make_rom.py", "--list"],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        raise StepError(f"make_rom.py --list failed: {out.stderr.strip()}")
    return [root / line for line in out.stdout.split()]


def build_rom(root: Path, manifest: Path, out: Path) -> tuple[bool, list[str]]:
    """@brief Builds one ROM file with make_rom.py, which exits non-zero for a missing or wrong
    set, a normal outcome here. Gives whether it worked and what it printed, both streams in
    one, as their order belongs together: unbuffered (-u), or the warnings on stderr would come
    first."""
    run = subprocess.run(
        [sys.executable, "-u", root / "scripts" / "make_rom.py", manifest, out],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return run.returncode == 0, run.stdout.splitlines()


def roms(root: Path, card: Card) -> list[tuple[str, str]]:
    """@brief Builds the ROM file of every game whose zip is in roms/ and gives (core folder,
    set) for each file there is. A file in sdcard/ without its zip stays as it is."""
    sd = root / "sdcard"
    pairs = []
    for manifest in manifests(root):
        name, zip_name = manifest_value(manifest, "set"), manifest_value(manifest, "zip")
        rom = sd / f"{name}.rom"
        core = manifest.parent.relative_to(root).as_posix()
        if (root / "roms" / zip_name).is_file():
            # always built anew: it costs little, and sdcard/<set>.rom then matches roms/
            ok, lines = build_rom(root, manifest, rom)
            if ok:
                report(f"{name}.rom", f"built, {rom.stat().st_size} bytes")
                # the verdict on the file (hardcore possible or not) and the warnings: an
                # optional chip that is missing, an unknown file
                for line in lines:
                    if not line.startswith("written"):
                        print(" " * 17 + line.removeprefix("WARNING: "))
                if any(line.startswith("WARNING") for line in lines):
                    card.notes.append(name)
                card.sets.append(name)
                pairs.append((core, name))
            else:
                for line in lines:
                    print(" " * 17 + line, file=sys.stderr)
                card.missing.append(f"{name}.rom(build failed)")
        elif rom.is_file():
            report(
                f"{name}.rom",
                f"present ({rom.stat().st_size} bytes), roms/{zip_name} is missing, not rebuilt",
            )
            card.sets.append(name)
            pairs.append((core, name))
        else:
            report(f"{name}.rom", f"no roms/{zip_name}, this game is left out")
    if not card.sets:
        card.missing.append("every-rom(see roms/README.md)")
    return pairs


def config_ini(root: Path, card: Card) -> None:
    """@brief Makes sdcard/config.ini from the template when there is none, stops on a line the
    firmware would drop and says which credentials are filled in."""
    sd = root / "sdcard"
    ini = sd / "config.ini"
    if not ini.exists():
        shutil.copyfile(sd / "config.ini.example", ini)
        ini.chmod(0o600)
        report("config.ini", "created from the template. Fill it in and run again")
        card.notes.append("config.ini-new")
    data = ini.read_bytes()
    dropped = long_lines(data)
    for n, line in dropped:
        print(
            f"  Line {n} ({len(line)} bytes, no semicolon) would be dropped by the firmware:", file=sys.stderr
        )
        print(f"    {line.decode('utf-8', errors='replace')}", file=sys.stderr)
    if dropped:
        raise StepError("nothing copied. Shorten the line or start its comment earlier")
    values = credentials(ini)
    for name, pair in CREDENTIALS.items():
        if all(values[f"{section}_{key}"] for section, key in pair):
            report(name, "filled in")
        else:
            report(name, f"not filled in, the game runs without {name} anyway")
            card.notes.append(name)
    lines = data.count(b"\n") + (0 if data.endswith(b"\n") or not data else 1)
    report("Lines", f"{lines}, all within the {LINE_LIMIT}-byte limit")


def settings(root: Path, card: Card, pairs: list[tuple[str, str]]) -> None:
    """@brief One settings file per core, under the name its menu loads and saves (the attribute
    ini of fpga/<core>/menu_core.xml): the device reads no other. It preselects the set named
    like the file (pacman.rom for pacman.ini), else the first set of that core."""
    sd = root / "sdcard"
    for core in sorted({c for c, _ in pairs}):
        name = ET.parse(root / core / "menu_core.xml").getroot().get("ini", "")
        if not name:
            raise StepError(f"{core}/menu_core.xml names no settings file")
        sets = [s for c, s in pairs if c == core]
        pick = next((s for s in sets if f"{s}.ini" == name), sets[0])
        card.inis.append(name)
        if (sd / name).is_file():
            report(name, "present, left untouched")
            continue
        # Only the ROM entry. The device fills in everything else from the menu defaults, and
        # "Save settings" rewrites the file anyway. The path must start with /sd:
        # sdc_set_default splits at the last slash into working directory and file name.
        text = (
            "; FPGA Companion settings\n"
            '; Starter file from g20k.py sdcard. "Save settings" rewrites it.\n'
            "\n"
            "; image files\n"
            f"image0=/sd/{pick}.rom\n"
        )
        (sd / name).write_text(text, encoding="utf-8", newline="\n")
        report(name, f"created with image0=/sd/{pick}.rom, no trip into the OSD on first start")


def prepare(root: Path) -> Card:
    """@brief Makes everything for the card in sdcard/ and checks it."""
    card = Card()
    print("== ROMs ==")
    pairs = roms(root, card)
    print("== config.ini ==")
    config_ini(root, card)
    print("== settings ==")
    settings(root, card, pairs)
    return card


def put(source: Path, dest: Path) -> None:
    """@brief Copies a file onto the card. On FAT, macOS keeps the extended attributes of a file
    in ._<name> beside it, and it gives every file a program writes one (com.apple.provenance).
    The device needs none of them, so that file goes."""
    try:
        shutil.copyfile(source, dest)
    except OSError as e:
        # a full or write-protected card, or one pulled during the copy
        raise StepError(f"{dest}: {e.strerror or e}, the card is incomplete") from None
    if sys.platform == "darwin":
        dest.with_name(f"._{dest.name}").unlink(missing_ok=True)


def copy(root: Path, card: Card, target: Path) -> None:
    """@brief Copies the files of sdcard/ onto the card. Settings files the card holds already
    stay, they carry what the device saved."""
    sd = root / "sdcard"
    print(f"== Card: {target} ==")
    if not target.is_dir():
        raise StepError(f"not a folder: {target}")
    if target.resolve() == sd.resolve():
        raise StepError("the target is sdcard/ itself, give the card's folder")
    if card.missing:
        raise StepError(f"not copied, missing: {' '.join(card.missing)}")
    for name in ("config.ini", "README.md", *(f"{s}.rom" for s in card.sets)):
        put(sd / name, target / name)
        report(name, "copied")
    for name in card.inis:
        if (target / name).is_file():
            report(name, "present on the card, stays: it holds your saved settings")
        else:
            put(sd / name, target / name)
            report(name, "copied (starter file)")
    if (target / "config.xml").is_file():
        print()
        print("  WARNING: there is a config.xml on the card. It replaces the menu built into the")
        print("  firmware, permanently and without any notice on the device. If unwanted: delete it.")


def make(root: Path, target: Path | None) -> None:
    """@brief Prepares the card in sdcard/ and, given a target, copies it there. Stops when no
    ROM file can be made or one fails."""
    card = prepare(root)
    if target is None:
        if card.missing:
            raise StepError(f"missing: {' '.join(card.missing)}")
        command = "py g20k.py sdcard E:\\" if os.name == "nt" else "python3 g20k.py sdcard /Volumes/YOUR_CARD"
        print(f"\nEverything ready in sdcard/. To copy: {command}")
        return
    copy(root, card, target)
    print()
    print("Done. Eject the card cleanly, otherwise data will be missing.")
    if card.notes:
        print(f"Still open: {' '.join(card.notes)}")
