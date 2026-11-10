# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief The simulations: python3 g20k.py sim [name [variant]], described by a sim.toml in each
simulation folder.

A sim.toml holds one table per simulation, named as g20k.py sim takes it:

    [rom_sdram]
    about = "rom_sdram.sv with the real sdram_fb.v and an SDRAM model"   one line for --list
    ci = true                     part of g20k.py sim without a name, as the CI runs it
    tool = "verilator"            or "nvc"
    run = "sim.py:audio"          a function of a file next to it, which does the whole run
    core = ".."                   a core folder: its sources as the build reads them (g20k.py
                                  sources), in a bench's files where "{core}" stands
    files = [...]                 nvc: the files every bench is analyzed from
    flags = [...]                 more options for Verilator
    timescale = "1ns/1ps"         Verilator's --timescale
    sets = ["1942", "vulgus"]     ROM sets, the first one by default: <core>/<set>.manifest
    variants = { port = [], path = ["ROM_PATH"] }   defines per variant, the first by default
    fetch = [{ name, url, blob }] files from the net, checked by their git blob hash
    rom = { words = "rom32.hex", bytes = { "proms.hex" = { from, to, define } } }
                                  the ROM image as 32-bit words and byte slices for the
                                  benches, define set when the slice holds data
    frames = { dir = "img", reference = "ref_screen.sha256" }   the folder of the frames in the
                                  work folder, and every frame against its SHA-256
    sheets = [{ png, frames, variant }]   PNG sheets of frames, by sheet_script
    sheet_script = "ppm2png.py"

    [[rom_sdram.bench]]           one testbench: built, run, it must end with a line PASS
    top = "tb_rom_sdram"
    files = ["../src/sdram_fb.v", "../src/rom_sdram.sv", "tb_rom_sdram.sv"]
    args = ["+dir={work}/img"]    plusargs
    generics = { JR = "true" }    nvc: generics

Paths are relative to the folder of sim.toml, "{work}" stands for the work folder,
build/sim/<name>[-<variant>][-<set>]. A run keeps the Verilator builds (obj*) and fetched
files of its work folder and starts everything else afresh. Verilator comes from the suite of
tools.toml, nvc from PATH. The simulations run on Linux and macOS."""

from __future__ import annotations

import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

from tools.engine import config, host, toolchain
from tools.engine.config import ConfigError
from tools.engine.flow import build
from tools.engine.host import StepError

## the folder of the shared simulations, listed first
COMMON = Path("fpga") / "common" / "sim"

## Verilator's options in every build: warnings stay warnings, lint and style stay quiet
VERILATOR_FLAGS = ["-Wno-fatal", "-Wno-lint", "-Wno-style"]

## nvc's options in every call. --ieee-warnings=off must come before -a: after -r it has no
## effect on the metavalue warnings of std_logic_unsigned arithmetic
NVC_FLAGS = ["--std=2008", "--ieee-warnings=off"]


@dataclass
class Bench:
    """@brief One testbench.

    - top: its top module or entity
    - files: its sources, "{core}" for the core's
    - args: plusargs of the run
    - generics: generics of nvc's elaboration"""

    top: str
    files: list[str]
    args: list[str]
    generics: dict[str, str]


@dataclass
class Slice:
    """@brief Bytes of the ROM image for a bench.

    - name: the hex file, one byte per line
    - start, end: the range in the image
    - define: set when the range holds data"""

    name: str
    start: int
    end: int
    define: str


@dataclass
class Fetch:
    """@brief A file from the net, checked by its git blob hash.

    - name: its name in the work folder
    - url: where it comes from
    - blob: git hash-object of the file"""

    name: str
    url: str
    blob: str


@dataclass
class Sheet:
    """@brief A PNG sheet of frames.

    - png: its name, "{variant}" for the variant
    - frames: the frames, relative to the work folder
    - variant: only for this variant, empty for all"""

    png: str
    frames: list[str]
    variant: str


@dataclass
class Sim:
    """@brief One simulation of a sim.toml, the fields as the file describes them (see the top of
    this file).

    - name, folder: its table and the folder of its sim.toml
    - about, ci, tool, run, core, files, flags, timescale, sets, variants, fetch: the keys
    - rom_words, rom_bytes: rom.words and rom.bytes
    - frames_dir, frames_reference: frames.dir and frames.reference
    - sheets, sheet_script, benches: the keys sheets, sheet_script and the [[<name>.bench]]"""

    name: str
    folder: Path
    about: str
    ci: bool = False
    tool: str = "verilator"
    run: str = ""
    core: Path | None = None
    files: list[str] = field(default_factory=list)
    flags: list[str] = field(default_factory=list)
    timescale: str = ""
    sets: list[str] = field(default_factory=list)
    variants: dict[str, list[str]] = field(default_factory=dict)
    fetch: list[Fetch] = field(default_factory=list)
    rom_words: str = ""
    rom_bytes: list[Slice] = field(default_factory=list)
    frames_dir: str = ""
    frames_reference: str = ""
    sheets: list[Sheet] = field(default_factory=list)
    sheet_script: Path | None = None
    benches: list[Bench] = field(default_factory=list)


def _strings(t: config._Table, key: str) -> dict[str, str]:
    """@brief A table of strings."""
    values = t.get(key, dict, {})
    if not all(isinstance(v, str) for v in values.values()):
        raise t.error(f"{t._name(key)} must be a table of strings")
    return values


def _sim(name: str, t: config._Table) -> Sim:
    t.allow(
        "about", "ci", "tool", "run", "core", "files", "flags", "timescale", "sets", "variants",
        "fetch", "rom", "frames", "sheets", "sheet_script", "bench",
    )  # fmt: skip
    folder = t.path.parent
    s = Sim(name, folder, t.get("about", str))
    s.ci = t.get("ci", bool, False)
    s.tool = t.get("tool", str, "verilator")
    if s.tool not in ("verilator", "nvc"):
        raise t.error(f"{name}.tool is verilator or nvc, not {s.tool}")
    s.run = t.get("run", str, "")
    if s.run and ":" not in s.run:
        raise t.error(f"{name}.run must be <file>:<function>, e.g. sim.py:audio")
    core = t.get("core", str, "")
    s.core = (folder / core).resolve() if core else None
    s.files = t.strings("files")
    s.flags = t.strings("flags")
    s.timescale = t.get("timescale", str, "")
    s.sets = t.strings("sets")
    variants = t.table("variants", required=False)
    for v in variants.data:
        s.variants[v] = variants.strings(v, required=True)
    for f in t.tables("fetch"):
        f.allow("name", "url", "blob")
        s.fetch.append(Fetch(f.get("name", str), f.get("url", str), f.get("blob", str)))
    rom = t.table("rom", required=False).allow("words", "bytes")
    s.rom_words = rom.get("words", str, "")
    sliced = rom.table("bytes", required=False)
    for n in sliced.data:
        b = sliced.table(n).allow("from", "to", "define")
        s.rom_bytes.append(Slice(n, b.get("from", int), b.get("to", int), b.get("define", str, "")))
    if (s.rom_words or s.rom_bytes) and not (s.sets and s.core):
        raise t.error(f"{name}.rom needs sets and core: the image is made from <core>/<set>.manifest")
    frames = t.table("frames", required=False).allow("dir", "reference")
    s.frames_dir = frames.get("dir", str, "")
    s.frames_reference = frames.get("reference", str, "")
    for sh in t.tables("sheets"):
        sh.allow("png", "frames", "variant")
        s.sheets.append(Sheet(sh.get("png", str), sh.strings("frames", True), sh.get("variant", str, "")))
    script = t.get("sheet_script", str, "")
    s.sheet_script = folder / script if script else None
    if s.sheets and not s.sheet_script:
        raise t.error(f"{name}.sheets needs sheet_script")
    for b in t.tables("bench"):
        b.allow("top", "files", "args", "generics")
        s.benches.append(
            Bench(b.get("top", str), b.strings("files"), b.strings("args"), _strings(b, "generics"))
        )
    if not s.run and not s.benches:
        raise t.error(f"{name} has neither run nor a [[{name}.bench]]")
    return s


def sim_files(root: Path) -> list[Path]:
    """@brief Every sim.toml: the shared simulations first, then the cores' in folder order."""
    common = root / COMMON / "sim.toml"
    cores = sorted(p for p in (root / "fpga").glob("*/sim/sim.toml") if p != common)
    return ([common] if common.is_file() else []) + cores


def load(root: Path) -> dict[str, Sim]:
    """@brief All simulations by name, in the order of their files and tables."""
    sims: dict[str, Sim] = {}
    for path in sim_files(root):
        top = config._read(path)
        for name in top.data:
            if name in sims:
                raise ConfigError(f"{path}: simulation {name} is in {sims[name].folder / 'sim.toml'} too")
            sims[name] = _sim(name, top.table(name))
    return sims


def git_blob(data: bytes) -> str:
    """@brief The hash git hash-object gives a file."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def frames_report(folder: Path, reference: Path) -> list[str]:
    """@brief The frames (*.ppm) of folder against their SHA-256 in reference ("<sha>  <name>"
    per line): one line per frame that differs, is missing or has no reference, empty when all
    agree."""
    want = {}
    for line in reference.read_text(encoding="utf-8").splitlines():
        if line.strip():
            sha, name = line.split(maxsplit=1)
            want[name.strip()] = sha
    got = {p.name: toolchain.sha256(p) for p in folder.glob("*.ppm")}
    lines = []
    for name in sorted(want.keys() | got.keys()):
        if name not in got:
            lines.append(f"{name}: missing")
        elif name not in want:
            lines.append(f"{name}: no reference")
        elif got[name] != want[name]:
            lines.append(f"{name}: differs")
    return lines


@dataclass
class Context:
    """@brief One run of a simulation, handed to the function of run.

    - root: the game20k tree
    - sim: the simulation
    - work: its work folder
    - variant, rom_set: the chosen ones, empty when it has none
    - defines: Verilator defines of the variant, the ROM slices and the command line"""

    root: Path
    sim: Sim
    work: Path
    variant: str
    rom_set: str
    defines: list[str]

    @property
    def folder(self) -> Path:
        return self.sim.folder

    def verilator(
        self, top: str, files: Sequence[host.Arg], flags: Sequence[str] = (), obj: str = ""
    ) -> Path:
        """@brief Builds a testbench with Verilator into work/obj_<top> (or obj), returns the
        binary. A failed build shows the end of its log."""
        exe = toolchain.find(self.root, "suite") / "bin" / "verilator"
        mdir = self.work / (obj or f"obj_{top}")
        cmd: list[host.Arg] = [exe, "--binary", "--timing", "-j", str(os.cpu_count() or 4), "-O3"]
        if self.sim.timescale:
            cmd += ["--timescale", self.sim.timescale]
        cmd += ["--top-module", top, "-Mdir", mdir, *VERILATOR_FLAGS, *self.sim.flags, *flags]
        cmd += [f"+define+{d}" for d in self.defines]
        log = self.work / f"build_{mdir.name}.log"
        # one file for both streams, in the order Verilator, make and the compiler write them
        with open(log, "w", encoding="utf-8") as f:
            code = subprocess.run(
                [str(c) for c in [*cmd, *files]], cwd=self.work, stdout=f, stderr=subprocess.STDOUT
            ).returncode
        if code != 0:
            tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-60:]
            print("\n".join(tail))
            raise StepError(f"Verilator could not build {top}, see {log}")
        return mdir / f"V{top}"

    def run(self, cmd: Sequence[host.Arg], log: Path, show: bool = True) -> tuple[int, list[str]]:
        """@brief Runs a simulation in the work folder, all its output into log. Returns its exit
        status and its lines without Verilator's report lines ("- "), which it also prints
        unless show is off."""
        lines = []
        with open(log, "w", encoding="utf-8") as f:
            with subprocess.Popen(
                [str(c) for c in cmd],
                cwd=self.work,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="replace",
            ) as p:
                assert p.stdout is not None
                for line in p.stdout:
                    f.write(line)
                    line = line.rstrip("\n")
                    if not line.startswith("- "):
                        lines.append(line)
                        if show:
                            print(line, flush=True)
                code = p.wait()
        return code, lines

    def python(self, script: Path, *args: host.Arg) -> str:
        """@brief Runs one of the project's Python scripts, returns what it printed."""
        return host.run(host.python(script, *args), cwd=self.work)

    def path(self, entry: str) -> Path:
        """@brief A path of sim.toml: relative to its folder, or in the work folder."""
        if entry.startswith("{work}"):
            return self.work / entry.removeprefix("{work}").lstrip("/")
        return self.folder / entry


def prepare_work(work: Path, keep: Sequence[str]) -> None:
    """@brief The work folder afresh, but with the Verilator builds (obj*) and the files of keep."""
    work.mkdir(parents=True, exist_ok=True)
    for p in work.iterdir():
        if p.name.startswith("obj") or p.name in keep:
            continue
        shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else p.unlink()


def fetch(ctx: Context) -> None:
    """@brief The files from the net, once: a file there with the right hash stays."""
    for f in ctx.sim.fetch:
        dest = ctx.work / f.name
        if dest.is_file() and git_blob(dest.read_bytes()) == f.blob:
            continue
        toolchain.download(f.url, dest)
        if git_blob(dest.read_bytes()) != f.blob:
            raise StepError(f"{f.name}: not the file of {f.url}, git hash {git_blob(dest.read_bytes())}")


def rom_image(ctx: Context) -> None:
    """@brief The ROM image of the set, from its manifest as for the SD card but without the
    footer, as 32-bit words and as byte slices."""
    s = ctx.sim
    assert s.core is not None
    image = ctx.work / f"{ctx.rom_set}.rom"
    manifest = s.core / f"{ctx.rom_set}.manifest"
    ctx.python(ctx.root / "scripts" / "make_rom.py", "--no-footer", manifest, image)
    data = image.read_bytes()
    if s.rom_words:
        words = (int.from_bytes(data[i : i + 4], "little") for i in range(0, len(data), 4))
        (ctx.work / s.rom_words).write_text("".join(f"{w:08x}\n" for w in words))
    for sl in s.rom_bytes:
        part = data[sl.start : sl.end]
        (ctx.work / sl.name).write_text("".join(f"{b:02x}\n" for b in part))
        if part and sl.define:
            ctx.defines.append(sl.define)


def bench_files(ctx: Context, bench: Bench, core: Sequence[Path]) -> list[Path]:
    files: list[Path] = []
    for entry in bench.files:
        files += core if entry == "{core}" else [ctx.path(entry)]
    return files


def expand(ctx: Context, arg: str) -> str:
    return arg.replace("{work}", str(ctx.work))


def run_verilator(ctx: Context) -> None:
    core: list[Path] = []
    include: list[str] = []
    if ctx.sim.core:
        sources, folders = build.sources(ctx.root, ctx.sim.core / "core.toml", ctx.work)
        core = list(sources)
        include = [f"+incdir+{p}" for p in folders]
    for bench in ctx.sim.benches:
        exe = ctx.verilator(bench.top, bench_files(ctx, bench, core), include)
        code, lines = ctx.run([exe, *(expand(ctx, a) for a in bench.args)], ctx.work / f"sim_{bench.top}.log")
        if code != 0 or "PASS" not in lines:
            raise StepError(
                f"{bench.top} failed (exit status {code}), see {ctx.work / f'sim_{bench.top}.log'}"
            )


def run_nvc(ctx: Context) -> None:
    nvc = shutil.which("nvc")
    if nvc is None:
        raise StepError(
            "nvc is missing: brew install nvc, or the package of https://github.com/nickg/nvc/releases"
        )
    lib = f"--work=work:{ctx.work / 'work'}"
    host.run(
        [nvc, *NVC_FLAGS, lib, "-a", *(ctx.path(f) for f in ctx.sim.files)], cwd=ctx.folder, capture=False
    )
    for bench in ctx.sim.benches:
        generics = [f"-g{k}={v}" for k, v in bench.generics.items()]
        log = ctx.work / f"sim_{bench.top}{''.join('_' + v for v in bench.generics.values())}.log"
        code, lines = ctx.run([nvc, *NVC_FLAGS, lib, "-e", *generics, bench.top, "-r"], log)
        if code != 0 or not any(line.endswith("PASS") for line in lines):
            raise StepError(f"{bench.top} {' '.join(generics)} failed (exit status {code}), see {log}")


def check_frames(ctx: Context) -> None:
    s = ctx.sim
    reference = s.folder / s.frames_reference
    folder = ctx.work / s.frames_dir
    report = frames_report(folder, reference)
    if report:
        print("\n".join(report))
        raise StepError(f"the frames differ from {reference.name}, see {folder}")
    n = len(list(folder.glob("*.ppm")))
    print(f"{n} of {n} frames agree with {reference.name}")


def make_sheets(ctx: Context) -> None:
    s = ctx.sim
    assert s.sheet_script is not None
    for sheet in s.sheets:
        if sheet.variant and sheet.variant != ctx.variant:
            continue
        png = ctx.work / sheet.png.replace("{variant}", ctx.variant)
        ctx.python(s.sheet_script, png, *sheet.frames)
        print(f"sheet: {png}")


def call(ctx: Context) -> None:
    """@brief The function of run, from its file next to sim.toml."""
    file, _, func = ctx.sim.run.partition(":")
    path = ctx.folder / file
    spec = importlib.util.spec_from_file_location(f"g20k_sim_{ctx.sim.name}", path)
    if spec is None or spec.loader is None:
        raise StepError(f"{path}: cannot load it")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not hasattr(module, func):
        raise StepError(f"{path} has no function {func}")
    getattr(module, func)(ctx)


def work_folder(root: Path, s: Sim, variant: str, rom_set: str) -> Path:
    """@brief build/sim/<name>[-<variant>][-<set>]: runs that are compared never share one."""
    return root / "build" / "sim" / "-".join(p for p in (s.name, variant, rom_set) if p)


def run(root: Path, s: Sim, variant: str = "", rom_set: str = "", defines: Sequence[str] = ()) -> None:
    """@brief Runs one simulation, raises StepError when it fails."""
    if os.name == "nt":
        raise StepError("the simulations run on Linux and macOS")
    if variant and variant not in s.variants:
        raise StepError(f"{s.name} has the variants {', '.join(s.variants) or 'none'}, not {variant}")
    if rom_set and rom_set not in s.sets:
        raise StepError(f"{s.name} has the sets {', '.join(s.sets) or 'none'}, not {rom_set}")
    variant = variant or next(iter(s.variants), "")
    rom_set = rom_set or next(iter(s.sets), "")
    work = work_folder(root, s, variant, rom_set)
    prepare_work(work, [f.name for f in s.fetch])
    ctx = Context(root, s, work, variant, rom_set, [*s.variants.get(variant, []), *defines])
    fetch(ctx)
    if s.run:
        call(ctx)
        return
    if s.sets and s.core and (s.rom_words or s.rom_bytes):
        rom_image(ctx)
    # the folder the benches write their frames into
    if s.frames_dir:
        (work / s.frames_dir).mkdir(parents=True, exist_ok=True)
    try:
        run_nvc(ctx) if s.tool == "nvc" else run_verilator(ctx)
    except StepError:
        # the sheets of the frames there, to look at what failed
        if s.sheets:
            try:
                make_sheets(ctx)
            except StepError:
                pass
        raise
    if s.frames_reference:
        check_frames(ctx)
    if s.sheets:
        make_sheets(ctx)


def show_list(sims: dict[str, Sim], root: Path) -> None:
    """@brief One line per simulation: name, variants, sets, whether the CI runs it, what it does."""
    for s in sims.values():
        extra = "".join(
            [
                f" [{'|'.join(s.variants)}]" if s.variants else "",
                f" --set {'|'.join(s.sets)}" if s.sets else "",
            ]
        )
        print(f"{s.name}{extra}{'  (CI)' if s.ci else ''}")
        print(f"    {s.about}  ({s.folder.relative_to(root).as_posix()})")


def main(root: Path, name: str, variant: str, rom_set: str, defines: Sequence[str], listing: bool) -> None:
    """@brief g20k.py sim: one simulation by name, or every one the CI runs."""
    sims = load(root)
    if listing:
        show_list(sims, root)
        return
    if name:
        if name not in sims:
            raise StepError(f"no simulation {name}, python3 g20k.py sim --list shows them")
        run(root, sims[name], variant, rom_set, defines)
        print(f"sim {name}: PASS")
        return
    if variant or rom_set or defines:
        raise StepError("a variant, --set or -D needs the name of a simulation")
    failed = []
    for s in (s for s in sims.values() if s.ci):
        print(f"== sim {s.name}", flush=True)
        try:
            run(root, s)
            print(f"sim {s.name}: PASS", flush=True)
        except StepError as e:
            print(f"sim {s.name}: FAIL, {e}", file=sys.stderr, flush=True)
            failed.append(s.name)
    if failed:
        raise StepError(f"failed: {', '.join(failed)}")
