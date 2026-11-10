# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""@file
@brief The two shared simulations that need more than a testbench, run by g20k.py sim through
sim.toml: audio and mcu. ctx is the run's tools.engine.sim.Context."""

import gzip
from concurrent.futures import ThreadPoolExecutor

from tools.engine import config
from tools.engine.host import StepError

## the HDMI module of hdl-util, which takes the audio word into its sample packets
HDMI = [
    "audio_info_frame.sv",
    "audio_sample_packet.sv",
    "auxiliary_video_information_info_frame.sv",
    "packet_assembler.sv",
    "packet_picker.sv",
    "serializer.sv",
    "source_product_description_info_frame.sv",
    "tmds_channel.sv",
    "hdmi.sv",
]

## the core clock periods of the games in ns: 18.5625, 37.125 and 46.40625 MHz
CORE_NS = ["53.872", "26.936", "21.5488"]


def audio(ctx):
    """audio_cdc.sv against the former path (tb_audio_cdc.sv), at each core clock: 14 offsets to
    the pixel clock with routing skew, once detuned by 3 ppm, once without skew. The new path
    must deliver every word whole and in order. The former path must tear words in some run
    with skew, or the skew model does not work."""
    src = ctx.folder.parent / "src"
    files = [src / "hdmi" / f for f in HDMI] + [src / "audio_cdc.sv", ctx.folder / "tb_audio_cdc.sv"]
    exe = ctx.verilator("tb_audio_cdc", files)
    # core clock period (ns), offset (ns), detuning (ppm), skew, samples
    runs = []
    for c in CORE_NS:
        runs += [(c, str(p), "0", "1", "400") for p in range(14)]
        runs += [(c, "0", "3", "1", "1000"), (c, "5", "0", "0", "400")]

    def one(r):
        c, p, ppm, skew, n = r
        log = ctx.work / f"run_{c}_{p}_{ppm}_{skew}.log"
        args = [f"+core_ns={c}", f"+phase_ns={p}", f"+ppm={ppm}", f"+skew={skew}", f"+samples={n}"]
        code, lines = ctx.run([exe, *args], log, show=False)
        return log.name, lines + ([f"FAIL {' '.join(r)}"] if code else [])

    # eight at a time, each with a log of its own
    with ThreadPoolExecutor(8) as pool:
        results = sorted(pool.map(one, runs))
    lines = [line for _, ls in results for line in ls]
    print("\n".join(lines))
    if any(k in line for line in lines for k in ("FAIL", "%Fatal", "%Error")):
        raise StepError("the new path lost, repeated or tore a word")
    n = sum(1 for line in lines if line.startswith("core"))
    if n != len(runs):
        raise StepError(f"{n} of {len(runs)} runs reported")
    # the counter-check: with skew the former path must tear words somewhere
    torn = 0
    for line in lines:
        if "skew 1" in line:
            w = line.split()
            torn += sum(int(w[i + 3]) for i in range(len(w) - 3) if w[i] == "old")
    if torn == 0:
        raise StepError("the former path tore no word, so the skew model does not work")
    print(f"{n} runs, the former path tore {torn} words in the runs with skew, the new path none")
    print("PASS")


def mcu(ctx):
    """rom_loader.sv takes a ROM file with the footer of make_rom.py (tb_rom_loader.sv). sysctrl.v
    sends each game's menu on READ_CFG (tb_sysctrl_menu.sv): the bytes it clocks out must unpack
    to the game's menu_rom.xml, freshly made for every core of the ring."""
    src = ctx.folder.parent / "src"
    exe = ctx.verilator("tb_rom_loader", [src / "mcu" / "rom_loader.sv", ctx.folder / "tb_rom_loader.sv"])
    code, lines = ctx.run([exe], ctx.work / "sim_tb_rom_loader.log")
    if code or "PASS" not in lines:
        raise StepError("tb_rom_loader failed")
    for core in config.load_project(ctx.root / "project.toml").slots:
        name = core.name
        gen = ctx.work / f"{name}-gen"
        ctx.python(ctx.root / "scripts" / "make_menu.py", "--out", gen, name)
        menu_rom = gen / "menu_rom.v"
        # one line per byte of the gzipped menu
        size = sum(1 for line in menu_rom.read_text().splitlines() if line.startswith("    11'd"))
        files = [menu_rom, src / "misc" / "sysctrl.v", ctx.folder / "tb_sysctrl_menu.sv"]
        exe = ctx.verilator("tb_sysctrl_menu", files, obj=f"obj_{name}")
        out = ctx.work / f"{name}.hex"
        log = ctx.work / f"sim_{name}.log"
        code, lines = ctx.run([exe, f"+bytes={size}", f"+out={out}"], log, show=False)
        if code or "PASS" not in lines:
            raise StepError(f"{name}: READ_CFG failed")
        data = bytes(int(v, 16) for v in out.read_text().split())
        if gzip.decompress(data).decode("utf-8") != (gen / "menu_rom.xml").read_text(encoding="utf-8"):
            raise StepError(f"{name}: READ_CFG unpacks to another menu than gen/menu_rom.xml")
        print(f"{name}: READ_CFG sends {len(data)} bytes, they unpack to gen/menu_rom.xml")
    print("PASS")
