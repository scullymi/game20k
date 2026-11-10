# The free toolchain

The cores build with free tools only: GHDL and yosys-slang read the sources, Yosys synthesizes,
nextpnr-himbaechel places and routes, and Apicula's `gowin_pack` writes the bitstream.
[BUILD.md](BUILD.md) shows how to fetch the tools and build. This page covers what the tools
are and what the build does differently from Gowin's own tools.

## Tools

[tools.toml](../tools.toml) pins every program to one version for every machine:

- YosysHQ's [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) with Yosys,
  its slang frontend and openFPGALoader, and GHDL from its own release.
- nextpnr and Apicula from game20k's forks, which carry fixes that are not upstream yet
  (timing of LUT1 to LUT3 and of long-wire segments, clock inversion of memories, the
  flip-flop input from SEL, the sign of multipliers, a plan of BUFGs and clock spines before
  the clocks are routed, so that no clock detours through another BUFG's gate, and PLL input
  routes that no clock reaches). The Apicula fork carries its own chip databases for that last
  fix.
- Yosys for the synthesis from game20k's fork: the suite's commit plus fixes that are not
  upstream yet (generated names without the directory of the source file, and a build with
  MSVC). The suite's Yosys still reads the sources.
- Eigen, which nextpnr's placer uses, pinned to one commit as well.

The same sources and tools give the same bitstream on macOS, Linux and Windows.
`g20k.py tools fetch` fetches the forks as GitHub Actions built them
(`.github/workflows/forks.yml`), from
[game20k-tools](https://github.com/scullymi/game20k-tools/releases). `g20k.py tools build-forks`
builds them from the commits in `tools.toml` instead, see
[BUILD.md](BUILD.md#building-the-forks-yourself).

## What the free build does differently

- VHDL goes through GHDL, one top entity per run. The build stops when an instance leaves a VHDL
  input open (`scripts/oss/vhdl_open_inputs.py`).
- Synthesis: comparisons go to LUT-sized chunks, undriven nets count as undefined, and
  registers without an asynchronous reset start at 0 as in the hardware.
- Memories: a second Yosys run puts the largest memories with clocked reads into the block
  RAMs that are still free, as Gowin's tools do (`scripts/oss/block_fill.py`). `ram_block` and
  `ram_logic` in the `[synth]` table of a core's `core.toml` decide single memories.
- `scripts/oss/gowin_pack_g20k.py` wraps `gowin_pack`: bank 4 stays at 3.3 V (the Companion's
  MOSI shares it with HDMI), emulated LVDS on the HDMI pins, and the 25 MHz flash loading rate.
- The build stops when nextpnr reports a hold violation, because such a placement fails on the
  board now and then. It also stops on a net that has users but no route
  (`scripts/oss/check_unrouted.py`), and on a clock that leaves the global clock network and
  re-enters it through a clock gate, a detour whose delay nextpnr does not model
  (`scripts/oss/check_clock_gates.py`).

## Known issues

- **Larger than with Gowin's tools.** Most cores need more logic than with the Gowin IDE,
  though all of them fit. Yosys does not pull a register with logic in front of it into a
  block RAM.
  Plan: extend Yosys, measure each core again.
