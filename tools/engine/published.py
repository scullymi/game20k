# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The project's releases on GitHub: fetching and checking their files.

[project] releases in project.toml names the repository. GitHub's API lists the files of each
release with their SHA-256 (digest), which every download is checked against. A file goes to
<tools>/downloads/, its zip is unpacked into <tools>/release-<version>/<name of the zip>/."""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any

from tools.engine import config, host, toolchain
from tools.engine.host import StepError


def repository(project: config.Project) -> str:
    """@brief owner/name of the repository [project] releases names, e.g. scullymi/game20k."""
    prefix = "https://github.com/"
    if not project.releases.startswith(prefix) or project.releases.rstrip("/").count("/") != 4:
        raise StepError(f"project.toml: releases is {project.releases!r}, expected {prefix}<owner>/<name>")
    return project.releases.rstrip("/").removeprefix(prefix)


def release(root: Path, project: config.Project, version: str) -> dict[str, Any]:
    """@brief What GitHub's API says about the release of version (with or without the v of its
    tag), or about the latest one for "latest"."""
    which = "latest" if version == "latest" else f"tags/v{version.removeprefix('v')}"
    url = f"https://api.github.com/repos/{repository(project)}/releases/{which}"
    cmd: list[host.Arg] = ["curl", "--fail", "--location", "--silent", "--show-error"]
    try:
        text = host.run([*cmd, "--user-agent", "game20k", url], cwd=root)
    except StepError:
        # curl's message above tells a missing release (404) from a network or rate limit error
        raise StepError(
            f"could not read release {version} of {project.releases}, see curl's message above"
        ) from None
    info: dict[str, Any] = json.loads(text)
    return info


def fetch(root: Path, info: dict[str, Any], name: str) -> Path:
    """@brief The file name of a release, downloaded and checked against the SHA-256 GitHub lists
    for it, and for a zip the folder it is unpacked into."""
    version = str(info["tag_name"]).removeprefix("v")
    assets = {a["name"]: a for a in info.get("assets", [])}
    if name not in assets:
        raise StepError(f"release {version} has no {name}. Its files: {', '.join(sorted(assets))}")
    asset = assets[name]
    digest = str(asset.get("digest") or "")
    if not digest.startswith("sha256:"):
        raise StepError(f"GitHub lists no SHA-256 for {name} of release {version}, it cannot be checked")
    archive = config.Archive(url=asset["browser_download_url"], sha256=digest.removeprefix("sha256:"))
    dest = toolchain.tools_dir(root) / f"release-{version}" / name.removesuffix(".zip")
    # a zip unpacked from this very file needs no download
    if name.endswith(".zip") and toolchain.marker(dest).get("sha256") == archive.sha256:
        return dest
    file = toolchain.fetched(root, archive, f"{name} of release {version}", "GitHub")
    if not name.endswith(".zip"):
        return file
    if dest.exists():
        shutil.rmtree(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    toolchain.unpack(file, dest)
    toolchain.write_marker(
        dest, {"name": name, "version": version, "url": archive.url, "sha256": archive.sha256}
    )
    return dest


def cores_image(root: Path, version: str, board: Path | None = None) -> Path:
    """@brief The flash image of a release for the board of project.toml, or board instead."""
    project = config.load_project(root / "project.toml", board)
    info = release(root, project, version)
    stem = f"{project.name}-{str(info['tag_name']).removeprefix('v')}-cores-{project.board.folder.name}"
    return fetch(root, info, f"{stem}.zip") / f"{stem}.bin"


def pico_firmware(root: Path, version: str) -> Path:
    """@brief The Pico 2 W's firmware (.uf2) of a release."""
    project = config.load_project(root / "project.toml")
    info = release(root, project, version)
    v = str(info["tag_name"]).removeprefix("v")
    stem = f"{project.name}-{v}-firmware-pico2w"
    uf2 = fetch(root, info, f"{stem}.zip") / f"{stem}.uf2"
    if not uf2.is_file():
        raise StepError(f"release {v} has no {uf2.name} in {stem}.zip")
    return uf2


def bl616_firmware(root: Path, version: str, board: str) -> Path:
    """@brief The BL616 image of a release for board, as src/bl616/CMakeLists.txt names it."""
    project = config.load_project(root / "project.toml")
    info = release(root, project, version)
    v = str(info["tag_name"]).removeprefix("v")
    image = fetch(root, info, f"{project.name}-{v}-firmware-bl616.zip") / f"{project.name}-{v}-{board}.bin"
    if not image.is_file():
        raise StepError(f"release {v} has no BL616 image for {board}")
    return image


def show_pico_steps(uf2: Path) -> None:
    """@brief How the firmware goes onto the Pico 2 W: as a file onto the drive it shows in its
    boot mode, which needs no program and no driver on any system."""
    print(f"The Pico's firmware: {uf2}")
    print("To put it onto the Pico 2 W:")
    print("  1. Unplug the Pico. Hold its BOOTSEL button and plug it in, then let go.")
    print("  2. A drive named RP2350 appears.")
    print("  3. Copy the file above onto it. The Pico restarts with the new firmware by itself.")
