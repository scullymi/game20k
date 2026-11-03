# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Builds one core into a bitstream with the free toolchain for Gowin FPGAs.

Steps: the generators of core and platform, GHDL for each VHDL top, slang for the Verilog and
SystemVerilog side, Yosys, nextpnr, Apicula's packer. Every step writes into the output folder,
the source tree stays as it is."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import TextIO

from tools.engine import config, host, toolchain
from tools.engine.flow import cells
from tools.engine.host import StepError

# Workaround for a bug in Yosys, not in this project: with more than one thread, opt_clean at times
# crashes (a pointer freed twice) or fails the MEMID assert in kernel/rtlil.cc on the larger cores,
# https://github.com/YosysHQ/yosys/issues/6418. Runs that finish give the same netlist with one
# thread, at a few percent more time.
YOSYS_ENV = {"YOSYS_MAX_THREADS": "1"}


@dataclass
class Build:
    """@brief Everything one build of a core needs to know."""

    root: Path
    project: config.Project
    platform: config.Platform
    core: config.Core
    tools: config.Tools
    out: Path
    #: parameters of the top for a diagnostic build, e.g. {"RAMDIAG": 1}
    params: dict[str, int] = field(default_factory=dict)

    @property
    def gen(self) -> Path:
        """@brief The folder the generators write into, {out} in the descriptions."""
        return self.out / "gen"

    def script(self, name: str) -> Path:
        """@brief A helper script of the project (scripts/oss)."""
        return self.root / "scripts" / "oss" / name

    def suite_bin(self, name: str) -> Path:
        return self.tools.suite / "bin" / (name + host.EXE)

    def expand(self, arg: str) -> str:
        return (
            arg.replace("{root}", str(self.root))
            .replace("{out}", str(self.gen))
            .replace("{core}", self.core.name)
        )

    def sources(self, patterns: list[str], base: Path) -> list[Path]:
        return config.resolve([self.expand(p) for p in patterns], base)

    def rel(self, path: Path) -> str:
        """@brief path relative to the root with / as separator, as the tools that record source
        locations get it: the netlist then holds the same names on every machine and for every
        output folder."""
        return Path(os.path.relpath(path, self.root)).as_posix()


def step(name: str) -> None:
    print(f"== {name}", flush=True)


def generate(b: Build, log: TextIO = sys.stdout) -> None:
    """@brief Runs the generators, the core's first, then the platform's, their output to log."""
    b.gen.mkdir(parents=True, exist_ok=True)
    for folder, gens in ((b.core.folder, b.core.generate), (b.platform.folder, b.platform.generate)):
        for g in gens:
            cmd = [b.expand(a) for a in g.run]
            if cmd[0].endswith(".py"):
                cmd = [sys.executable, *cmd]
            print(host.run(cmd, cwd=folder), end="", file=log)
            for o in g.outputs:
                if not (b.gen / o).is_file():
                    raise StepError(f"{' '.join(g.run)} did not write {o}")


def undefined_outputs(json_path: Path, top: str) -> list[str]:
    """@brief The output ports of top that are undefined in whole or in part."""
    module = json.loads(json_path.read_text())["modules"][top]
    return [
        name
        for name, port in module["ports"].items()
        if port["direction"] == "output" and "x" in port["bits"]
    ]


def vhdl(b: Build) -> None:
    """@brief Each VHDL top through GHDL into Verilog and from there into an RTLIL file of its own.

    GHDL reads all VHDL files of the core for each top. GHDL and Yosys run in the root folder
    with relative paths, see Build.rel().

    One file per top keeps the names inside a top independent of what else the build reads. A
    submodule two tops share has the same name in both (GHDL adds a hash of its generics) and
    is read once (read_rtlil -nooverwrite)."""
    step("ghdl")
    files = b.sources(b.core.vhdl.files, b.core.folder)
    for top in b.core.vhdl.tops:
        verilog = b.out / f"vhdl_{top}.v"
        host.run(
            [
                b.tools.ghdl / "bin" / ("ghdl" + host.EXE),
                "synth",
                "--std=08",
                "-fsynopsys",
                f"--workdir={b.rel(b.out / 'ghdl')}",
                "--out=verilog",
                *map(b.rel, files),
                "-e",
                top,
            ],
            cwd=b.root,
            stdout=verilog,
            stderr=b.out / f"ghdl_{top}.log",
        )
        # hierarchy -top stops when GHDL wrote no module of the entity's name
        il = b.out / f"vhdl_{top}.il"
        host.run(
            [
                b.suite_bin("yosys"),
                "-q",
                "-p",
                f"read_verilog {b.rel(verilog)}; hierarchy -top {top}; write_rtlil {il}",
            ],
            cwd=b.root,
            env=YOSYS_ENV,
        )
        # GHDL can turn a process into constants without a message (a clock edge in both the if
        # and the elsif branch). Yosys then removes everything behind an undefined output, so the
        # build stops here.
        flat = b.out / f"vhdl_only_{top}.json"
        host.run(
            [
                b.suite_bin("yosys"),
                "-q",
                "-p",
                f"read_rtlil {il}; hierarchy -top {top}; proc; flatten; opt -full; "
                f"opt_clean -purge; write_json {flat}",
            ],
            cwd=b.out,
            env=YOSYS_ENV,
        )
        bad = [p for p in undefined_outputs(flat, top) if p not in b.core.vhdl.x_ok]
        if bad:
            raise StepError(f"GHDL leaves outputs of {top} undefined: {', '.join(bad)}")


def elaborate(b: Build, verilog: list[Path]) -> None:
    """@brief slang reads the Verilog and SystemVerilog side over the VHDL tops."""
    prims = b.out / "gowin_prims.v"
    # The Gowin primitives as empty modules with their parameters, so that defparam and #()
    # resolve in slang and the primitives stay cells
    host.run(
        host.python(
            b.script("gowin_prims.py"),
            b.tools.suite / "share" / "yosys" / "gowin",
            prims,
            *b.platform.primitives,
        ),
        cwd=b.out,
    )
    args = slang_args(b, verilog, prims)
    if b.params:
        check_params(b, args)
    lines = [f"read_rtlil -nooverwrite {b.out / f'vhdl_{t}.il'}" for t in b.core.vhdl.tops]
    # --empty-blackboxes is sv-elab's: modules it only knows by name become empty boxes
    own = ["--empty-blackboxes", *b.core.synth.read_slang_options]
    lines.append(" ".join(["read_slang", args[0], *own, *args[1:]]))
    lines += [f"hierarchy -check -top {b.platform.top}", f"write_rtlil {b.out / 'elab.il'}"]
    defaults = b.out / "vhdl_defaults.ys"
    if b.core.vhdl.tops:
        lines += vhdl_default_lines(b, defaults)
    (b.out / "elab.ys").write_text("\n".join(lines) + "\n")
    step("yosys")
    host.run(
        [b.suite_bin("yosys"), "-m", "slang", "-q", "-l", b.out / "elab.log", "-s", b.out / "elab.ys"],
        cwd=b.root,
        env=YOSYS_ENV,
    )
    if b.core.vhdl.tops:
        connects = defaults.read_text()
        print(connects, end="")
        # an open input without its default would leave the CPU or chip behind it waiting or
        # optimized away, with no error anywhere else
        n = len(connects.splitlines())
        if n != b.core.vhdl.open_inputs:
            raise StepError(
                f"{n} open inputs of the VHDL tops take their default, "
                f"vhdl.open_inputs in core.toml says {b.core.vhdl.open_inputs}"
            )


def slang_args(b: Build, verilog: list[Path], prims: Path) -> list[str]:
    """@brief The options and files for slang, the same for the elaboration and its check."""
    include = [a for d in config.include_dirs(b.core, b.platform) for a in ("-I", b.rel(d))]
    # the core's rate, named once in its core.toml, then a diagnostic build's parameters
    params = {b.platform.core_hz_parameter: b.core.hz, **b.params}
    # slang defines SYNTHESIS, Gowin does not: with it serializer.sv picks its Xilinx branch.
    # YOSYS, which Yosys' own reader sets, hides the $error in sd_card.v. Till's files use names
    # before their declaration.
    return [
        "--single-unit",
        "--allow-use-before-declare",
        "-U",
        "SYNTHESIS",
        "-D",
        "YOSYS",
        *b.core.synth.slang_options,
        *(a for name, value in params.items() for a in ("-G", f"{name}={value}")),
        "-v",
        b.rel(prims),
        *include,
        *map(b.rel, verilog),
        "--top",
        b.platform.top,
    ]


def slang_int(value: str) -> int | None:
    """@brief The integer of a constant as slang writes it (5, 1'b1, 8'hff), None for others."""
    base = 10
    if "'" in value:
        value = value.split("'", 1)[1].lstrip("s")
        base = {"b": 2, "o": 8, "d": 10, "h": 16}.get(value[:1].lower(), 0)
        value = value[1:]
    try:
        return int(value.replace("_", ""), base) if base else None
    except ValueError:
        return None


def check_params(b: Build, args: list[str]) -> None:
    """@brief Stops unless every parameter of a diagnostic build reaches the top with its value.

    slang passes over a -G name the top does not have and cuts a value to the parameter's width,
    both without a message. Its JSON of the elaborated top shows what arrived. The VHDL tops are
    not read here, slang alone leaves them as unknown modules. Its analysis after elaboration,
    which Yosys' frontend does not run, stays off."""
    ast = b.out / "top_params.json"
    host.run(
        [
            b.suite_bin("slang"),
            "-q",
            "--ignore-unknown-modules",
            "--disable-analysis",
            "--ast-json",
            ast,
            "--ast-json-scope",
            b.platform.top,
            *args,
        ],
        cwd=b.root,
    )
    members = json.loads(ast.read_text())["body"]["members"]
    got = {m["name"]: m.get("value", "") for m in members if m["kind"] == "Parameter"}
    for name, value in b.params.items():
        if name not in got:
            raise StepError(f"{b.platform.top} has no parameter {name}")
        if slang_int(got[name]) != value:
            raise StepError(f"{name}={value} reaches {b.platform.top} as {got[name]}")


def vhdl_default_lines(b: Build, defaults: Path) -> list[str]:
    """@brief Yosys commands, after elab.il is written, that make the script with the VHDL
    defaults for the open inputs of the VHDL tops.

    GHDL drops the defaults of VHDL input ports, an instance that leaves one open would get an
    undriven input (Time Pilot's sound Z80 waited for ever with WAIT_n open). The instances and
    the ports of the VHDL modules go out as JSON, which needs the processes converted.
    vhdl_port_defaults.py answers with connect commands, which the synthesis runs first. proc
    and the commands would advance Yosys' counter for generated names, which elab.il carries
    into the synthesis, so they come after it."""
    tops = b.core.vhdl.tops
    found = b.out / "vhdl_instances.json"
    vhdl = b.sources(b.core.vhdl.files, b.core.folder)
    script = host.python(b.script("vhdl_port_defaults.py"), found, defaults, *tops, "--", *vhdl)
    return [
        "proc",
        "select " + " ".join([*(f"t:{t}" for t in tops), *(f"{t}/i:*" for t in tops)]),
        f"write_json -selected {found}",
        f"exec -expect-return 0 -- {' '.join(map(str, script))}",
    ]


def synth_script(b: Build, ram_block: list[str]) -> str:
    """@brief The Yosys script from the elaborated design to the netlist for nextpnr."""
    top, fam, out = b.platform.top, b.project.board.synth_family, b.out
    s = [f"read_rtlil {out / 'elab.il'}", f"hierarchy -top {top}"]
    if b.core.vhdl.tops:
        s.append(f"script {out / 'vhdl_defaults.ys'}")
    # synth_gowin's coarse step, with one addition before alumacc: comparisons go to LUT-sized
    # chunks (cmp2lut, cmp2lcu) instead of a carry chain each, as synth_ice40 and synth_ecp5 do.
    # Without it every comparison with a constant costs one ALU per bit of the wider operand.
    s.append(f"synth_gowin -family {fam} -top {top} -run begin:coarse")
    # Undriven nets become undefined, and muxes may treat undefined inputs as don't care: an
    # array of 256 packet types with six of them assigned (hdmi/packet_picker.sv) shrinks to a
    # six-way mux, as Gowin builds it.
    # Registers without an asynchronous reset start at 0, as the FPGA starts them. The cores rely
    # on it (Galaga's star state machine has neither reset nor start value): without a start
    # value Yosys recodes such a state machine with a guessed reset state, and all zeros is no
    # valid state any more.
    s.append(
        r"proc; check; flatten; opt_clean; "
        r"setundef -zero -init t:\$dff t:\$dffe t:\$sdff t:\$sdffe t:\$sdffce"
    )
    s.append("setundef -undriven -undef; tribuf -logic; deminout; opt_expr -mux_undef; check; opt_clean")
    s.append("opt -nodffe -nosdff -mux_undef; fsm; opt -mux_undef; wreduce; peepopt; opt_clean; share")
    for a, bw, amin, bmin, name in (
        (36, 36, 22, 22, "MUL36X36"),
        (18, 18, 10, 4, "MUL18X18"),
        (18, 18, 4, 10, "MUL18X18"),
        (9, 9, 4, 4, "MUL9X9"),
    ):
        s.append(
            f"techmap -map +/mul2dsp.v -D DSP_A_MAXWIDTH={a} -D DSP_B_MAXWIDTH={bw} "
            f"-D DSP_A_MINWIDTH={amin} -D DSP_B_MINWIDTH={bmin} -D DSP_NAME=\\$__{name}"
        )
        s.append("chtype -set $mul t:$__soft_mul")
    s.append("techmap -map +/gowin/dsp_map.v")
    s.append("techmap -map +/cmp2lut.v -map +/cmp2lcu.v -D LUT_WIDTH=4; opt_expr; opt_clean")
    # Arrays of a few registers that slang turns into memories with one write port per element
    # (e.g. one read register per bank in a generate loop) become flip-flops first. Otherwise
    # memory_dff finds no register behind the large memory they read from, and that memory goes
    # into LUT RAM instead of block RAM.
    s.append(r"memory_collect; memory_map t:\$mem_v2 r:SIZE<=8 %i r:WR_PORTS>=2 %i")
    s.append("alumacc; opt; memory -nomap; opt_clean")
    # Read-during-write between different ports is undefined, as with Gowin. Else memory_libmap
    # builds logic around a block RAM to deliver the old data.
    s.append(f"memory_unpack; select t:$memrd_v2 t:$memwr_v2; write_json -selected {out / 'memports.json'}")
    s.append(
        f"select -clear; exec -expect-return 0 -- {sys.executable} {b.script('rw_collision.py')} "
        f"{out / 'memports.json'} {out / 'rw_collision.ys'}"
    )
    s.append(f"script {out / 'rw_collision.ys'}; memory_collect")
    s.append(f"select t:$mem_v2; write_json -selected {out / 'mems.json'}; select -clear")
    # Gowin's syn_ramstyle values in Yosys' words
    s.append('setattr -set syn_ramstyle "distributed" a:syn_ramstyle=distributed_ram')
    s.append('setattr -set syn_ramstyle "block" a:syn_ramstyle=block_ram')
    s += [f'setattr -set ram_style "block" {top}/c:{m}' for m in ram_block]
    s += [f'setattr -set ram_style "logic" {top}/c:{m}' for m in b.core.synth.ram_logic]
    s.append(f"synth_gowin -family {fam} -top {top} -run map_ram:map_gates")
    # A short ALU chain takes more room than the same arithmetic in LUTs
    if b.core.synth.alu_lut > 2:
        s.append(f"techmap -map +/techmap.v t:\\$alu r:Y_WIDTH<={b.core.synth.alu_lut} %i")
    # LUT mapping: ABC9 with the flip-flops in view merges equal ones, fewer LUTs and flip-flops
    s.append(f"synth_gowin -family {fam} -top {top} -run map_gates:map_luts")
    s.append("sort; read_verilog -icells -lib -specify +/abc9_model.v; abc9 -maxlut 4 -dff; clean")
    s.append(f"synth_gowin -family {fam} -top {top} -run map_cells:")
    # Yosys 0.69 leaves $buf cells, which nextpnr cannot place
    s.append("techmap t:$buf")
    s.append("opt_clean")
    s.append(f"write_json {out / (b.core.name + '.json')}")
    s.append(f"tee -q -o {out / 'stat.txt'} stat")
    s.append(f"tee -q -o {out / 'stat.json'} stat -json")
    return "\n".join(s) + "\n"


def synthesize(b: Build) -> None:
    def run_yosys(ram_block: list[str]) -> None:
        (b.out / "synth.ys").write_text(synth_script(b, ram_block))
        # ABC writes files into the working directory, e.g. the miter of an equivalence check
        # that runs out of time, so synthesis runs in the output folder
        host.run(
            [
                b.suite_bin("yosys"),
                "-q",
                "-l",
                b.out / "yosys.log",
                "-s",
                b.out / "synth.ys",
            ],
            cwd=b.out,
            env=YOSYS_ENV,
        )

    ram_block = list(b.core.synth.ram_block)
    run_yosys(ram_block)
    # Yosys leaves block RAMs unused when LUT RAM looks cheaper, Gowin fills them. A second run
    # puts the largest memories with clocked reads into the block RAMs that are still free.
    fill = host.run(
        host.python(
            b.script("block_fill.py"),
            b.out / "mems.json",
            b.out / "yosys.log",
            b.out / f"{b.core.name}.json",
        ),
        cwd=b.out,
    ).split()
    (b.out / "block_fill.txt").write_text("".join(f"{m}\n" for m in fill) or "\n")
    if fill:
        step(f"yosys, again with {len(fill)} more memories in block RAM")
        run_yosys(ram_block + fill)
    host.run(
        host.python(b.script("mems_table.py"), b.out / "mems.json"), cwd=b.out, stdout=b.out / "mems.txt"
    )


def clock_lines(b: Build) -> list[str]:
    """@brief create_clock lines for nextpnr: the board's clocks, then the platform's."""
    lines = []
    for c in b.project.board.clocks + b.platform.clocks:
        hz = b.core.hz if c.hz is None else c.hz
        where = f"get_ports {{{c.port}}}" if c.port else f"get_nets {{{c.net}}}"
        lines.append(f"create_clock -name {c.name} -period {1e9 / hz!r} [{where}]")
    return lines


def place_and_route(b: Build) -> None:
    board, name, out = b.project.board, b.core.name, b.out
    # board.cst is in the Gowin IDE's form. nextpnr needs each pin of a differential pair in its
    # own line.
    host.run(host.python(b.script("cst_pairs.py"), board.pins), cwd=out, stdout=out / "board_oss.cst")
    (out / "clocks.sdc").write_text("\n".join(clock_lines(b)) + "\n")
    step("nextpnr")
    cmd: list[host.Arg] = [
        b.tools.nextpnr,
        "--json",
        out / f"{name}.json",
        "--write",
        out / f"{name}_pnr.json",
        "--device",
        board.device,
        "--vopt",
        f"family={board.family}",
        "--vopt",
        f"cst={out / 'board_oss.cst'}",
    ]
    if board.sspi_as_gpio:
        cmd += ["--vopt", "sspi_as_gpio"]
    cmd += [
        "--sdc",
        out / "clocks.sdc",
        "--timing-allow-fail",
        "--report",
        out / "report.json",
        "-l",
        out / "nextpnr.log",
        "-q",
    ]
    host.run(cmd, cwd=out)
    # the table of the clocks, also when one misses its frequency: a bitstream with a failing
    # clock may run on the board and fail now and then, so it stops the build
    table = out / "fmax.txt"
    try:
        host.run(host.python(b.script("check_fmax.py"), out / "report.json"), cwd=out, stdout=table)
    except StepError:
        print(table.read_text(), end="", flush=True)
        raise StepError(f"a clock misses its frequency, see {table}") from None
    print(table.read_text(), end="")
    # nextpnr only warns about hold violations. On the board such a build fails now and then.
    log = (out / "nextpnr.log").read_text()
    if "Hold/min time violation for" in log:
        raise StepError(f"nextpnr reports hold violations, see {out / 'nextpnr.log'}")
    host.run(host.python(b.script("check_unrouted.py"), out / f"{name}_pnr.json"), cwd=out)
    apicula(b, b.script("check_clock_gates.py"), out / f"{name}_pnr.json")


def apicula(b: Build, script: Path, *args: host.Arg) -> None:
    """@brief Runs script with the suite's Python and the Apicula of the fork.

    Apicula's own Python warnings are left out of the terminal."""
    env = {"PYTHONPATH": str(b.tools.apicula)}
    proc = subprocess.run(
        [str(b.suite_bin("tabbypy3")), str(script), *map(str, args)],
        cwd=b.out,
        env={**os.environ, **env},
        stderr=subprocess.PIPE,
        text=True,
    )
    for line in proc.stderr.splitlines():
        if "UserWarning" not in line and "warnings.warn" not in line:
            print(line, file=sys.stderr)
    if proc.returncode != 0:
        raise StepError(f"{script.name} failed with exit code {proc.returncode}")


def pack(b: Build) -> None:
    board, name, out = b.project.board, b.core.name, b.out
    step("gowin_pack")
    # gowin_pack_g20k.py is Apicula's gowin_pack with bank 4 at 3.3 V and ELVDS on the HDMI
    # pins, see its head. The header names the next core of the ring for the core switch.
    args: list[host.Arg] = ["-d", board.family]
    if board.sspi_as_gpio:
        args.append("--sspi_as_gpio")
    if board.mspi_as_gpio:
        args.append("--mspi_as_gpio")
    args += [
        "--multiboot_address",
        f"0x{b.project.next_address(b.core.folder):06X}",
        "-o",
        out / f"{name}.fs",
        out / f"{name}_pnr.json",
    ]
    apicula(b, b.script("gowin_pack_g20k.py"), *args)
    host.run(host.python(b.script("fs2bin.py"), out / f"{name}.fs", out / f"{name}.bin"), cwd=out)


def version(folder: Path) -> str:
    """@brief The version of a tool folder as its marker gives it (toolchain.MARKER), a commit
    shortened to 12 characters. A folder of local.toml without a marker is of unknown version."""
    return toolchain.marker(folder).get("version", "unknown")[:12]


def tool_line(b: Build) -> str:
    """@brief The tools of this build in one line, for the NOTICE of a release."""
    yosys = " ".join(host.run([b.suite_bin("yosys"), "-V"], cwd=b.out).split()[:2])
    ghdl = host.run([b.tools.ghdl / "bin" / ("ghdl" + host.EXE), "--version"], cwd=b.out).split()[:2]
    # the plugin prints "sv-elab revision <sha>" and "slang revision <sha>"
    revs = host.run([b.suite_bin("yosys"), "-m", "slang", "-p", "slang_version"], cwd=b.out).split()
    slang = revs[revs.index("sv-elab") + 2][:12]
    # nextpnr is the program in bin/ of its folder
    nextpnr = version(b.tools.nextpnr.parent.parent)
    return (
        f"{yosys} and yosys-slang {slang} from YosysHQ's oss-cad-suite {version(b.tools.suite)}, "
        f"{' '.join(ghdl)}, nextpnr-himbaechel {nextpnr} and Apicula {version(b.tools.apicula)}"
    )


def sources(root: Path, core_toml: Path, out: Path) -> tuple[list[Path], list[Path]]:
    """@brief The core's own source files and include folders as its core.toml lists them, for a
    simulation of the core without the platform. The generators write into out/gen first, their
    output goes to stderr."""
    core = config.load_core(core_toml)
    b = Build(
        root,
        config.load_project(root / "project.toml"),
        config.load_platform(core.platform / "platform.toml"),
        core,
        toolchain.locate(root),
        out.resolve(),
    )
    generate(b, sys.stderr)
    return b.sources(core.sources, core.folder), b.sources(core.include, core.folder)


def build(
    root: Path,
    core_toml: Path,
    out: Path | None = None,
    params: dict[str, int] | None = None,
    update_cells: bool = False,
) -> Path:
    """@brief Builds the core described by core_toml and returns the path of its .fs.

    params sets parameters of the top for a diagnostic build. Its default output folder carries
    them in the name, build/<core>-RAMDIAG.1, so that it never replaces the normal build. The name
    holds no = or comma: slang reads both inside a file name of -v as separators. The cells of
    the netlist are compared with the core's cells.toml, update_cells writes them there instead.
    A diagnostic build has other cells and is not compared."""
    project = config.load_project(root / "project.toml")
    core = config.load_core(core_toml)
    platform = config.load_platform(core.platform / "platform.toml")
    tools = toolchain.locate(root)
    params = params or {}
    if update_cells and params:
        raise config.ConfigError("--update-cells takes the normal build, not one with -G")
    if platform.core_hz_parameter in params:
        raise config.ConfigError(f"{platform.core_hz_parameter} comes from {core_toml}, not from -G")
    name = core.name + "".join(f"-{k}.{v}" for k, v in sorted(params.items()))
    b = Build(root, project, platform, core, tools, (out or root / "build" / name).resolve(), params)
    if any(c in b.rel(b.out) for c in "=,"):
        raise config.ConfigError(
            f"{b.rel(b.out)}: no = or comma in the output folder, slang splits file names there"
        )
    b.out.mkdir(parents=True, exist_ok=True)
    project.address(core.folder)  # a core without a slot stops before any work
    generate(b)
    verilog = b.sources(core.sources, core.folder) + b.sources(platform.sources, platform.folder)
    vhdl_sources = b.sources(core.vhdl.files, core.folder)
    (b.out / "sources.txt").write_text("".join(f"{p}\n" for p in vhdl_sources + verilog))
    vhdl(b)
    elaborate(b, verilog)
    synthesize(b)
    now = cells.counts(b.out / "stat.json")
    measure = core.folder / "cells.toml"
    if params:
        print("cells: not compared, a diagnostic build")
    elif update_cells:
        cells.update(measure, project.board.folder.name, now)
        print(f"cells: written to {b.rel(measure)}")
    else:
        cells.check(measure, project.board.folder.name, now, b.rel(measure))
        print(f"cells: as in {b.rel(measure)}")
    place_and_route(b)
    pack(b)
    (b.out / "tools.txt").write_text(tool_line(b) + "\n")
    return b.out / f"{core.name}.fs"
