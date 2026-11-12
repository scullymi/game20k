# Building game20k from source

Everything goes through one script, `g20k.py`, with free tools on macOS (Apple silicon), Linux
(x86_64) and Windows (x64). It needs Python 3.11.4 or newer and git, and downloads everything
else itself. On Windows, type `py g20k.py` instead of `python3 g20k.py`. Each command lists its
options with `--help`.

## 1. Sources and tools

```sh
git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/scullymi/game20k.git && cd game20k
python3 g20k.py tools fetch
python3 g20k.py tools
```

The clone takes the current state of the repository and its submodules under `external/`,
without history (`git fetch --unshallow` brings it back). Without history, a build after the
last release tag names its version by the commit alone.

`tools fetch` downloads every program the build needs into `external/tools/`, several GB in
all, and checks each download against its SHA-256 in [tools.toml](../tools.toml), the forks
against the one published beside their archive.
`tools` then lists each program with its version, where it came from and its folder:

| Name | Program | Needed for |
|---|---|---|
| `suite` | YosysHQ's oss-cad-suite: Yosys with its slang frontend, openFPGALoader | cores, flashing them |
| `ghdl` | GHDL, the VHDL frontend | cores |
| `yosys`, `nextpnr`, `apicula` | game20k's forks, built by GitHub Actions, see [OPEN-TOOLCHAIN.md](OPEN-TOOLCHAIN.md) | cores |
| `arm`, `armlibs` | Arm GNU Toolchain and its C libraries | Pico firmware |
| `pioasm`, `picotool` | the host tools of the Pico SDK | Pico firmware |
| `riscv`, `riscvlibs` | Bouffalo's RISC-V toolchain and its C libraries | BL616 firmware |
| `bouffalo_sdk` | Bouffalo SDK with its flash tool | BL616 firmware |
| `cmake`, `ninja` | CMake and Ninja | firmware, building the forks yourself |

The SD card is prepared as in the [README](../README.md#quick-start).

### Only some tools

With names from the table, `tools fetch` fetches only those programs, for example everything
for the cores:

```sh
python3 g20k.py tools fetch suite ghdl yosys nextpnr apicula
```

The three forks come as one archive, so naming one of them fetches all three.

### Building the forks yourself

Instead of the prebuilt forks, `tools build-forks` builds them on this machine. It needs the
suite, CMake and Ninja from `tools fetch` first:

```sh
python3 g20k.py tools build-forks
python3 g20k.py tools
```

The build fetches the sources at the commits in `tools.toml` into `external/tools/src/`: Yosys,
nextpnr and Apicula from game20k's forks, and Eigen, a header library that nextpnr's placer
needs. Eigen is only needed for this build, so the table above does not list it. Each step
names its log file there and says how long it took. git, a C++ compiler, Boost, Flex and Bison
have to be on the path. On Windows, run it in a Visual Studio developer shell, with Boost from
vcpkg and `CMAKE_PREFIX_PATH` set to its `installed\x64-windows-static`, as
`.github/workflows/forks.yml` does:

```powershell
vcpkg install --triplet x64-windows-static boost-program-options "boost-iostreams[core]" boost-thread boost-filesystem
$env:CMAKE_PREFIX_PATH = "$env:VCPKG_ROOT\installed\x64-windows-static"
```

`tools` then shows the forks as "built here from" their repository and commit. A later
`tools fetch` leaves them as they are, and `tools fetch apicula nextpnr yosys` goes back to the
prebuilt ones. [local.toml](#localtoml) keeps the choice.

### local.toml

`local.toml` next to `g20k.py` holds the settings of this machine. git does not track it. All
settings go in its `[tools]` table:

```toml
[tools]
dir = "../game20k-tools"
mode = "source"
nextpnr = "../nextpnr/build/nextpnr-himbaechel"
```

| Setting | Meaning |
|---|---|
| `dir` | where the tools go instead of `external/tools/`, for example so that an editor does not index them. Set it before the first `tools fetch`. |
| `mode` | where the forks came from: `prebuilt` (`tools fetch`) or `source` (`tools build-forks`). Both commands write it, so it does not need to be set by hand. |
| a name from the table above | a folder that replaces the fetched one, or for `nextpnr`, `yosys` and `ninja` also the program itself. The build warns when its version is unknown or differs from `tools.toml`. |

Paths are relative to the folder that holds `local.toml`. When `mode` changes, the commands
write the file anew, which drops its comments.

## 2. Cores

```sh
python3 g20k.py build fpga/pang_hdmi                # into build/pang_hdmi/
python3 g20k.py flash fpga/pang_hdmi --sram         # into the FPGA only, gone at power-off
python3 g20k.py flash fpga/pang_hdmi                # into its slot in the flash
python3 g20k.py release --dev                       # every core as one flash image under dist/
python3 g20k.py flash --image dist/<name>/<name>.bin
```

On Windows, `flash` needs the WinUSB driver on the Nano once, see
[windows-usb.md](windows-usb.md).

[project.toml](../project.toml) lists the cores in the order of their slots in the flash. The
FPGA loads the first one at power-on. To flash fewer cores, remove the others there and build
everything again, firmware included. After writing the flash, power the board off and on. A
build stops when a clock misses its frequency or the cells differ from the core's `cells.toml`
(`--update-cells` after a wanted change). Without `--dev`, `release` only builds a clean tree on
a release tag.

More options:

- `cores` prints the core folders of `project.toml` in slot order.
- `--board boards/tangnano20k-singleboard` on `build`, `flash` and `release` takes another board
  folder than the one `project.toml` names, here the Nano without a Pico, see
  [bl616.md](bl616.md).
- `flash --dry-run` prints the command without running it.
- `sources <core> --out <folder>` writes a core's own source files for a simulation, with
  `--include` it prints the include folders instead.

## 3. Firmware

```sh
python3 g20k.py firmware              # stick on the Pico's own USB port
python3 g20k.py firmware --usb pio    # stick on a USB A socket at GP2/GP3
```

The command prints the path of `fpga_companion.uf2`. Copy it to the Pico in BOOTSEL mode, or
flash it with a debug probe, see [debugging.md](debugging.md#flashing-through-the-probe). For the
BL616 see [bl616.md](bl616.md#from-source).

The firmware is built from the fork in `external/FPGA-Companion`, as checked out. Commit changes
there first, then `git add external/FPGA-Companion` here. The game table and the menus come
from this repository: the ROM manifests and each core's `menu_core.xml` with
`fpga/common/menu/base.xml`. A change to a `menu_core.xml` needs a new build of the core and
the firmware, a change to labels in `base.xml` only the firmware. When the menus of firmware
and core do not match, the firmware shows a basic menu without DIP switches, and hardcore stays
off.

`--without-ra` builds without RetroAchievements, for a trial. `--upstream PICO` builds a board
of FPGA Companion without game20k's code, `--bl616 nano20k` the firmware of the onboard BL616.

`firmware --release` (or `--release bl616`) packs a release under `dist/`. The release files
come from GitHub Actions, and `gh attestation verify <zip> -R scullymi/game20k` confirms that a
zip was built there.

## 4. Checks, tests and simulations

```sh
python3 g20k.py check --staged   # before a commit: secrets, ignored files, line ends, host tests
python3 g20k.py test             # the host tests of the firmware alone, see tests/README.md
python3 g20k.py sim              # the simulations the CI runs
python3 g20k.py sim --list       # every simulation with its variants and ROM sets
python3 g20k.py sim 1942 path    # one of them, 1942 and 1943 need their ROM zips in roms/
python3 g20k.py docs             # the Doxygen pages of game20k's sources in the fork
```

Each simulation folder describes its simulations in a `sim.toml`. They run on Linux and macOS,
with Verilator from the suite. The Pac-Man simulation needs nvc and `docs` needs Doxygen, which
the suite lacks: `brew install nvc doxygen` on macOS, on Ubuntu the release package of
[nvc](https://github.com/nickg/nvc/releases) and `apt install doxygen`.

## Debugging

Serial log, debug probe and diagnostic builds: [debugging.md](debugging.md). How cores and
boards are described: [cores.md](cores.md). Host tests of the
firmware: [tests/README.md](../tests/README.md). Updating dependencies:
[dependencies.md](dependencies.md). Licenses: [THIRD-PARTY.md](../THIRD-PARTY.md).

## Repository layout

```
g20k.py, tools/     the build
project.toml        the cores in the flash and the board
tools.toml          the programs of the build
boards/             pins, flash layout and FLASHING.txt of each board
fpga/common/        the platform: top level, HDMI, scaler, SDRAM, SPI, RAM mirror, menu
fpga/<core>/        one core each, with its menu, ROM manifests and any simulation
external/           the firmware's submodules
scripts/            ROM files, checks, NOTICE files
roms/, sdcard/      your ROMs, the files for the SD card
tests/, docs/       host tests, documentation
```
