# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Reads the TOML descriptions of board, platform and core into checked dataclasses.

Every table names the keys it allows: a misspelt key is an error that names the file and the
key, not a setting that is silently left out. Paths in a file are relative to the
folder of that file."""

from __future__ import annotations

import glob
import tomllib
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, TypeVar

T = TypeVar("T")


class ConfigError(Exception):
    """@brief A description file that cannot be read, with file and key in the message."""


class _Table:
    """@brief One TOML table with checked access to its keys."""

    def __init__(self, data: dict[str, Any], path: Path, prefix: str) -> None:
        self.data = data
        self.path = path
        self.prefix = prefix

    def allow(self, *keys: str) -> _Table:
        """@brief Raises for every key of the table that is not one of keys.

        Called before any value is read, so that a misspelt key is reported as unknown and not
        as a missing one."""
        unknown = sorted(set(self.data) - set(keys))
        if unknown:
            raise self.error("unknown " + ", ".join(self._name(k) for k in unknown))
        return self

    def _name(self, key: str) -> str:
        return f"{self.prefix}.{key}" if self.prefix else key

    def error(self, message: str) -> ConfigError:
        return ConfigError(f"{self.path}: {message}")

    def get(self, key: str, kind: type[T], default: T | None = None) -> T:
        """@brief The value of key, checked against kind. Without a default the key is required."""
        if key not in self.data:
            if default is None:
                raise self.error(f"{self._name(key)} is missing")
            return default
        value = self.data[key]
        # bool is an int in Python, a flag must not pass as a number or the other way round
        if not isinstance(value, kind) or (kind is int and isinstance(value, bool)):
            raise self.error(f"{self._name(key)} must be {kind.__name__}, not {type(value).__name__}")
        return value

    def strings(self, key: str, required: bool = False) -> list[str]:
        """@brief A list of strings, empty when the key is left out and not required."""
        values = self.get(key, list, None if required else [])
        if not all(isinstance(v, str) for v in values):
            raise self.error(f"{self._name(key)} must be a list of strings")
        return values

    def table(self, key: str, required: bool = True) -> _Table:
        return _Table(self.get(key, dict, None if required else {}), self.path, self._name(key))

    def tables(self, key: str) -> list[_Table]:
        """@brief An array of tables ([[key]]), empty when left out."""
        values = self.get(key, list, [])
        if not all(isinstance(v, dict) for v in values):
            raise self.error(f"{self._name(key)} must be an array of tables ([[{key}]])")
        return [_Table(v, self.path, f"{self._name(key)}[{i}]") for i, v in enumerate(values)]


def _read(path: Path) -> _Table:
    try:
        with open(path, "rb") as f:
            return _Table(tomllib.load(f), path, "")
    except OSError as e:
        raise ConfigError(f"{path}: {e.strerror}") from None
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"{path}: {e}") from None


@dataclass
class Clock:
    """@brief A clock for the timing analysis, on a top-level port or on a net of the design."""

    name: str
    hz: int | None
    port: str = ""
    net: str = ""


def _clocks(t: _Table, core_clock: str = "") -> list[Clock]:
    """@brief The [[clock]] tables. The clock named core_clock runs at the core's rate and so
    has no hz of its own: the rate is given in one place, the core.toml."""
    clocks = []
    for c in t.tables("clock"):
        c.allow("name", "hz", "port", "net")
        name = c.get("name", str)
        if name == core_clock:
            if "hz" in c.data:
                raise c.error(f"{c.prefix}: {name} runs at the core's rate (core.hz), it takes no hz")
            hz = None
        else:
            hz = c.get("hz", int)
        clock = Clock(name, hz, c.get("port", str, ""), c.get("net", str, ""))
        # the timing tools need to know where the clock is, and it is in one place only
        if bool(clock.port) == bool(clock.net):
            raise c.error(f"{c.prefix} needs either port or net")
        clocks.append(clock)
    return clocks


@dataclass
class Flash:
    """@brief The configuration flash of size bytes: one slot of slot_size bytes per core."""

    size: int
    slot_size: int


@dataclass
class Board:
    """@brief A board: the FPGA, its pins and the clocks that come in from outside."""

    folder: Path
    name: str
    device: str
    family: str
    synth_family: str
    loader: str
    pins: Path
    sspi_as_gpio: bool
    mspi_as_gpio: bool
    block_rams: int
    flash: Flash
    clocks: list[Clock]


def load_board(path: Path) -> Board:
    """@brief Reads a board.toml."""
    root = _read(path).allow("board", "flash", "clock")
    b = root.table("board").allow(
        "name",
        "device",
        "family",
        "synth_family",
        "loader",
        "pins",
        "sspi_as_gpio",
        "mspi_as_gpio",
        "block_rams",
    )
    flash = root.table("flash").allow("size", "slot_size")
    board = Board(
        folder=path.parent,
        name=b.get("name", str),
        device=b.get("device", str),
        family=b.get("family", str),
        synth_family=b.get("synth_family", str),
        loader=b.get("loader", str),
        pins=path.parent / b.get("pins", str),
        sspi_as_gpio=b.get("sspi_as_gpio", bool, False),
        mspi_as_gpio=b.get("mspi_as_gpio", bool, False),
        block_rams=b.get("block_rams", int),
        flash=Flash(flash.get("size", int), flash.get("slot_size", int)),
        clocks=_clocks(root),
    )
    return board


@dataclass
class Generate:
    """@brief A command that writes sources before the build reads them.

    {out} in an argument stands for the folder the outputs go to."""

    run: list[str]
    outputs: list[str]


def _generate(t: _Table) -> list[Generate]:
    generate = []
    for g in t.tables("generate"):
        g.allow("run", "outputs")
        generate.append(Generate(g.strings("run", required=True), g.strings("outputs", required=True)))
    return generate


@dataclass
class Platform:
    """@brief What every core of a project shares: the top level and its sources and clocks.

    core_clock is the clock net that runs at the core's rate, core_hz_parameter the parameter
    of the top that the build sets to it. primitives are the vendor cells the sources
    instantiate, which the elaboration needs as empty modules with their parameters."""

    folder: Path
    top: str
    core_clock: str
    core_hz_parameter: str
    primitives: list[str]
    sources: list[str]
    include: list[str]
    generate: list[Generate]
    clocks: list[Clock]


def load_platform(path: Path) -> Platform:
    """@brief Reads a platform.toml."""
    root = _read(path).allow("platform", "sources", "generate", "clock")
    p = root.table("platform").allow("top", "core_clock", "core_hz_parameter", "primitives")
    s = root.table("sources").allow("files", "include")
    core_clock = p.get("core_clock", str)
    return Platform(
        folder=path.parent,
        top=p.get("top", str),
        core_clock=core_clock,
        core_hz_parameter=p.get("core_hz_parameter", str),
        primitives=p.strings("primitives"),
        sources=s.strings("files", required=True),
        include=s.strings("include"),
        generate=_generate(root),
        clocks=_clocks(root, core_clock),
    )


@dataclass
class Vhdl:
    """@brief The VHDL side of a core: its files and the entities the Verilog side instantiates.

    tops are entity names as their sources declare them. x_ok names outputs of the tops that are
    undefined on purpose, the build stops on any other undefined output."""

    files: list[str] = field(default_factory=list)
    tops: list[str] = field(default_factory=list)
    x_ok: list[str] = field(default_factory=list)


@dataclass
class Synth:
    """@brief Settings of the synthesis that differ between cores.

    ram_block and ram_logic name memories (hierarchical cell names) that go into block RAM or
    into logic whatever Yosys would pick. slang_options are options of slang itself, passed as
    they are to Yosys' read_slang and to slang. read_slang_options are those only Yosys' slang
    frontend knows, they shape the netlist. Comparisons and sums up to alu_lut bits wide go into
    LUTs instead of an ALU chain."""

    ram_block: list[str] = field(default_factory=list)
    ram_logic: list[str] = field(default_factory=list)
    slang_options: list[str] = field(default_factory=list)
    read_slang_options: list[str] = field(default_factory=list)
    alu_lut: int = 8


@dataclass
class Core:
    """@brief A core: its sources, the VHDL it brings and the clock it runs at."""

    folder: Path
    name: str
    platform: Path
    hz: int
    sources: list[str]
    include: list[str]
    vhdl: Vhdl = field(default_factory=Vhdl)
    generate: list[Generate] = field(default_factory=list)
    synth: Synth = field(default_factory=Synth)


def load_core(path: Path) -> Core:
    """@brief Reads a core.toml."""
    root = _read(path).allow("core", "sources", "vhdl", "generate", "synth")
    c = root.table("core").allow("name", "platform", "hz")
    s = root.table("sources").allow("files", "include")
    v = root.table("vhdl", required=False).allow("files", "tops", "x_ok")
    vhdl = Vhdl(v.strings("files"), v.strings("tops"), v.strings("x_ok"))
    if bool(vhdl.files) != bool(vhdl.tops):
        raise v.error("vhdl needs both files and tops")
    y = root.table("synth", required=False).allow(
        "ram_block", "ram_logic", "slang_options", "read_slang_options", "alu_lut"
    )
    synth = Synth(
        y.strings("ram_block"),
        y.strings("ram_logic"),
        y.strings("slang_options"),
        y.strings("read_slang_options"),
        y.get("alu_lut", int, 8),
    )
    # the folder's name: the build writes build/<name>, the release and the CI look for it there
    name = c.get("name", str)
    if name != path.parent.name:
        raise c.error(f'core.name is "{name}", the folder is {path.parent.name}: both must be the same')
    core = Core(
        folder=path.parent,
        name=name,
        platform=(path.parent / c.get("platform", str)).resolve(),
        hz=c.get("hz", int),
        sources=s.strings("files", required=True),
        include=s.strings("include"),
        vhdl=vhdl,
        generate=_generate(root),
        synth=synth,
    )
    return core


def include_dirs(core: Core, platform: Platform) -> list[Path]:
    """@brief The folders an `include searches after the folder of the including file: the
    core's, then the platform's, in the order of their descriptions."""
    return [core.folder / d for d in core.include] + [platform.folder / d for d in platform.include]


def resolve(patterns: list[str], base: Path) -> list[Path]:
    """@brief Expands the patterns relative to base, in the given order, each glob sorted.

    A pattern that matches nothing is an error: a missing source must stop the build, not
    leave a module out."""
    files: list[Path] = []
    for pattern in patterns:
        matches = sorted(glob.glob(pattern, root_dir=base))
        if not matches:
            raise ConfigError(f"{base}: {pattern} matches no file")
        for m in matches:
            p = base / m
            if p not in files:
                files.append(p)
    return files


@dataclass
class Project:
    """@brief A project: its board and the cores in the configuration flash, in ring order.

    Each core has one slot of the board's slot size. The core switch loads the next core of the
    ring, the last one switches back to the first."""

    root: Path
    name: str
    board: Board
    slots: list[Path]

    def _index(self, core: Path) -> int:
        try:
            return self.slots.index(core.resolve())
        except ValueError:
            raise ConfigError(f"{self.root / 'project.toml'}: {core} has no slot") from None

    def address(self, core: Path) -> int:
        """@brief The flash address of the core's slot."""
        return self._index(core) * self.board.flash.slot_size

    def next_address(self, core: Path) -> int:
        """@brief The flash address of the core that the core switch loads."""
        return (self._index(core) + 1) % len(self.slots) * self.board.flash.slot_size


def load_project(path: Path) -> Project:
    """@brief Reads a project.toml and the board.toml it names."""
    root = _read(path).allow("project", "slot")
    p = root.table("project").allow("name", "board")
    board = load_board(path.parent / p.get("board", str) / "board.toml")
    slots = []
    for s in root.tables("slot"):
        s.allow("core")
        core = (path.parent / s.get("core", str)).resolve()
        # a core has one address, a second slot would get that of the first
        if core in slots:
            raise s.error(f"{s.prefix}: {s.get('core', str)} has a slot already")
        slots.append(core)
    if len(slots) * board.flash.slot_size > board.flash.size:
        raise root.error(f"{len(slots)} slots do not fit into the flash of {board.name}")
    return Project(root=path.parent, name=p.get("name", str), board=board, slots=slots)


@dataclass
class Tools:
    """@brief Where the programs of the free toolchain are on this machine.

    suite is YosysHQ's oss-cad-suite (Yosys with its slang plugin, Apicula's Python,
    openFPGALoader, Verilator), python the Python in it, ghdl a GHDL release, the others the
    builds of game20k's forks. yosys is the fork's program, which runs the synthesis, while the
    suite's Yosys reads the sources."""

    suite: Path
    ghdl: Path
    nextpnr: Path
    apicula: Path
    python: Path
    yosys: Path


@dataclass
class Archive:
    """@brief One archive of a download, for one kind of machine.

    python is the Python in it, relative to its folder, path the folders its programs need on
    the search path (on Windows those with their DLLs)."""

    url: str
    sha256: str
    python: str = ""
    path: tuple[str, ...] = ()


@dataclass
class Download:
    """@brief A program that comes as a release archive, one per kind of machine."""

    name: str
    version: str
    release: str
    archives: dict[str, Archive]


@dataclass
class Source:
    """@brief A program built from a commit of its repository."""

    name: str
    repo: str
    commit: str


@dataclass
class Prebuilt:
    """@brief The forks built by tools.yml: one archive per kind of machine, on one release."""

    release: str
    archives: dict[str, Archive]


@dataclass
class Toolset:
    """@brief The programs of tools.toml: downloads and sources by name, and the prebuilt forks
    when there are any."""

    downloads: dict[str, Download]
    sources: dict[str, Source]
    prebuilt: Prebuilt | None = None


def load_toolset(path: Path) -> Toolset:
    """@brief Reads a tools.toml."""
    root = _read(path).allow("download", "source", "prebuilt")
    downloads = {}
    d = root.table("download", required=False)
    for name in d.data:
        t = d.table(name)
        downloads[name] = Download(name, t.get("version", str), t.get("release", str), _archives(t, True))
    sources = {}
    s = root.table("source", required=False)
    for name in s.data:
        t = s.table(name).allow("repo", "commit")
        commit = t.get("commit", str)
        if len(commit) != 40:
            raise t.error(f"{t.prefix}.commit must be a full commit hash")
        sources[name] = Source(name, t.get("repo", str), commit)
    prebuilt = None
    if "prebuilt" in root.data:
        p = root.table("prebuilt")
        prebuilt = Prebuilt(p.get("release", str), _archives(p))
    return Toolset(downloads, sources, prebuilt)


def _archives(t: _Table, programs: bool = False) -> dict[str, Archive]:
    """@brief The archives of a table, one subtable per kind of machine besides version and
    release."""
    archives = {}
    for k in [k for k in t.data if k not in ("version", "release")]:
        # python and path describe the programs of a download, the prebuilt forks have none
        a = t.table(k).allow("url", "sha256", *(("python", "path") if programs else ()))
        sha = a.get("sha256", str)
        if len(sha) != 64 or not all(c in "0123456789abcdef" for c in sha):
            raise a.error(f"{a.prefix}.sha256 is no SHA-256 in lower-case hex")
        archives[k] = Archive(a.get("url", str), sha, a.get("python", str, ""), tuple(a.strings("path")))
    return archives


@dataclass
class Local:
    """@brief This machine's settings from local.toml, which git does not track.

    mode is how the programs of the forks come here, "source" or "prebuilt", empty until it is
    chosen. paths are folders (or for nextpnr the program) that take the place of the fetched
    ones, relative to the folder of local.toml. dir is the folder of the fetched and built
    programs instead of external/tools, e.g. one outside an editor's workspace."""

    mode: str = ""
    paths: dict[str, Path] = field(default_factory=dict)
    dir: Path | None = None


def load_local(path: Path, programs: Sequence[str]) -> Local:
    """@brief Reads local.toml, an empty Local when there is none. programs are the names a
    path may be given for."""
    if not path.exists():
        return Local()
    root = _read(path).allow("tools")
    t = root.table("tools", required=False).allow("mode", "dir", *programs)
    mode = t.get("mode", str, "")
    if mode not in ("", "source", "prebuilt"):
        raise t.error(f'tools.mode is "{mode}", expected "source" or "prebuilt"')
    paths = {k: (path.parent / t.get(k, str)).resolve() for k in programs if k in t.data}
    folder = (path.parent / Path(t.get("dir", str)).expanduser()).resolve() if "dir" in t.data else None
    return Local(mode, paths, folder)
