# Building with the free toolchain

The cores build either with the Gowin IDE (`scripts/build_fpga.sh`, see [BUILD.md](BUILD.md))
or with a free toolchain: GHDL and yosys-slang read the sources, Yosys synthesises,
nextpnr-himbaechel places and routes, and Apicula's `gowin_pack` writes the bitstream. Both
builds come from the same sources and run on the same board. Every core builds with the free
toolchain and has been tested on the board.

## Tools

- YosysHQ's [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build/releases), two
  builds of it for now (GHDL comes from an older one). `scripts/oss/fetch_suite.sh` downloads
  both for macOS on Apple silicon or Linux (x86_64, arm64), checks them against their SHA-256
  and unpacks them under `external/`.
- nextpnr and Apicula from game20k's forks, which carry fixes that are not upstream yet
  (timing of LUT1 to LUT3 and of long-wire segments, clock inversion of memories, the
  flip-flop input from SEL, the sign of multipliers). `scripts/oss/build_tools.sh` builds them
  into `external/oss-tools/`, pinned to a commit each. It needs cmake, ninja, a C++ compiler,
  Boost and Eigen. `NEXTPNR` and `APICULA` in the environment point the build at other builds.

```sh
cd game20k && scripts/oss/fetch_suite.sh && scripts/oss/build_tools.sh
```

## Building

```sh
cd game20k && scripts/build_fpga_oss.sh galaga_hdmi
```

The bitstream lands in `fpga/<core>/impl/oss/<core>.fs`. Load it into SRAM with
`openFPGALoader -b tangnano20k <file>.fs`, or write it to its flash slot with
`openFPGALoader -b tangnano20k -f -o <address> --verify <file>.fs` (addresses in
`fpga/common/slots.txt`, then power the board off and on). The cores build independently, so
several can run in parallel.

Settings per core are in `fpga/<core>/oss.conf`, described in the head of the build script.

`OSS=1 scripts/make_bitstream_release.sh` builds every core and packs the flash image with its
NOTICE, as GitHub Actions does for a release (`.github/workflows/bitstreams.yml`). `DEV=1` runs
it without a tag, for a trial.

## What the free build does differently

- VHDL goes through GHDL, one top entity per run. Open VHDL input ports get the default of
  their declaration, as in the Gowin IDE (`scripts/oss/vhdl_port_defaults.py`). Entities that
  a core instantiates with different generics get a Verilog twin (`VHDL_SKIP`, `SV_EXTRA`).
- Synthesis: comparisons go to LUT-sized chunks, no wide-LUT muxes, undriven nets count as
  undefined, and registers without an asynchronous reset start at 0 as in the hardware.
- Memories: a second Yosys run puts the largest memories with clocked reads into the block
  RAMs that are still free, as the Gowin IDE does (`scripts/oss/block_fill.py`). `RAM_BLOCK`
  and `RAM_LOGIC` in `oss.conf` decide single memories.
- `scripts/oss/gowin_pack_g20k.py` wraps `gowin_pack`: bank 4 stays at 3.3 V (the Companion's
  MOSI shares it with HDMI), emulated LVDS on the HDMI pins, and the 25 MHz flash loading rate.
- The build stops when nextpnr reports a hold violation, which nextpnr itself only warns about.
  On the board such a placement fails now and then. Another `SEED` in `oss.conf` places around it.
  It also stops on a net that has users but no route (`scripts/oss/check_unrouted.py`), and on a
  clock that leaves the global clock network and re-enters it through a clock gate, a detour
  whose delay nextpnr does not model (`scripts/oss/check_clock_gates.py`).

## Known issues

- **Larger than the Gowin build.** Most cores need more logic than with the Gowin IDE, though
  all of them fit. Yosys does not pull a register with logic in front of it into a block RAM.
  Plan: extend Yosys, measure each core again.
