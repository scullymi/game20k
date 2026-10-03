# Building game20k from source

The [README](../README.md) explains how to play using the release files. This page covers
building the bitstreams and the firmware yourself, and debugging.

## Tools

| Tool | Version | Note |
|---|---|---|
| Gowin EDA **Education** | 1.9.11.03 | free download, **no licence file needed** |
| openFPGALoader | | to flash the Pac-Man core: `brew install openfpgaloader` or `apt install openfpgaloader` |
| Arm GNU Toolchain | 14.2 | |
| git, curl, CMake, make, Python 3, gzip, unzip, a C compiler | | |

The scripts look for Gowin and the Arm toolchain in the usual places on macOS and Linux. If
yours are elsewhere, point the scripts to them:

```sh
export GOWIN_IDE=/opt/gowin/IDE          # the folder that contains bin/gw_sh
export PICO_TOOLCHAIN_PATH=/opt/arm-gnu-toolchain-14.2
```

Windows has not been tested. The scripts are POSIX shell, so they should run under WSL.

## 1. Sources

```sh
git clone --recursive https://github.com/scullymi/game20k.git && cd game20k
```

All the HDL is in this repository. The firmware comes as git submodules under `external/`: our
forks of [FPGA-Companion](https://github.com/scullymi/FPGA-Companion) and
[TinyUSB](https://github.com/scullymi/tinyusb) (both on the branch `game20k`) and the Pico SDK
2.2.0. If you cloned without `--recursive`, the build script fetches them itself.

Third-party HDL keeps its original headers. Each of its folders (`rtl_dar/`, `rtl_pacman/`,
`rtl_T80/`, `misc/`, `hdmi/`) has a README or LICENSE that names the upstream commit and our
changes. [THIRD-PARTY.md](../THIRD-PARTY.md) lists who wrote what and under which licence.

## 2. ROMs and the SD card

Copy your own MAME sets into `roms/`, see [roms/README.md](../roms/README.md) for which ones. Then:

```sh
scripts/make_sdcard.sh                        # builds and checks, lists anything missing
scripts/make_sdcard.sh /Volumes/YOUR_CARD     # also copies everything to the card
```

The script builds a ROM file for every game whose set is in `roms/` and checks the size and
SHA-1 of every chip against MAME. If a set fails the check, it names the chip and copies nothing
to the card. The device silently rejects a ROM file of the wrong size, which is why the check
happens here.
For WiFi and RetroAchievements, fill in `sdcard/config.ini` first, see
[README, RetroAchievements](../README.md#retroachievements).

## 3. FPGA: build and flash

Build each core:

```sh
scripts/build_fpga.sh galaga_hdmi
scripts/build_fpga.sh pacman_hdmi
```

Each build ends with a short report on utilisation and timing, and fails if a clock misses its
target. If you changed a core's `menu.xml`, run `scripts/make_menu_hex.sh <core>` first,
otherwise the bitstream keeps the old menu.

Write both cores into the board's flash, then power the board off and on:

```sh
scripts/flash_fpga.sh galaga_hdmi flash
scripts/flash_fpga.sh pacman_hdmi flash
```

Each core has its own address in the flash, listed in
[fpga/common/slots.txt](../fpga/common/slots.txt). At power-on, the FPGA loads the core at
address 0, which is Galaga. The script writes Galaga with Gowin's `programmer_cli` and Pac-Man
with openFPGALoader, because `programmer_cli` can only write to address 0. Set
`FLASHER=openfpgaloader` to use openFPGALoader for both. Without `flash`, the script loads the
core into the FPGA's SRAM only, which is handy for a quick test and gone at power-off.

`scripts/make_bitstream_release.sh` builds both cores from a release tag and packs them as the
single flash image that the release ships. `DEV=1` runs it without a tag, for a trial.

## 4. Firmware: build and flash

Build the firmware for the Pico 2 W:

```sh
scripts/build_companion.sh            # stick on the Pico's own USB port (the default)
scripts/build_companion.sh pico2 pio  # stick on a soldered USB A socket at GP2/GP3
```

The result is `fpga_companion.uf2` in `external/FPGA-Companion/src/rp2040/build_pico2_native/`
(or `build_pico2_pio/`). To flash it, hold BOOTSEL while plugging in the Pico and copy the file
to the drive that appears. With a debug probe, OpenOCD flashes without BOOTSEL, see
[wiring.md](wiring.md#flashing-through-the-probe).

**Changing the firmware.** `external/FPGA-Companion` is a git submodule, and the script builds
whatever is checked out there. Commit your changes in that repository first, then run
`git add external/FPGA-Companion` and commit here too, so that this repository records which
firmware commit it uses.

**Releases.** GitHub Actions builds the release firmware from the sources at the tag, and
`gh attestation verify game20k-<version>-pico2w.zip -R scullymi/game20k` confirms that a
downloaded zip comes from that build.

## Debugging the Pico

The firmware logs everything it does on **UART0, GP0 (TX), 921600 baud**. A USB serial adapter
on GP0 and GND is enough. The Raspberry Pi Debug Probe has one built in, so with the probe you
need no extra adapter. [wiring.md](wiring.md#reading-the-serial-output) covers the wiring, the
probe and logging with timestamps.

## Debugging the Nano

The Tang Nano has six LEDs, numbered **1 to 6** as printed on the board. In normal operation:

| LED | Lit when |
|---|---|
| 1 | blinks once a second, faster while the ROM loads |
| 2 | the Pico has sent at least one packet |
| 3 | a direction or button is held |
| 4 | the core has produced at least one vsync |
| 5 | the ROM is fully loaded |
| 6 | the HDMI PLL is locked |

If LED 6 is off, the PLL is not running and there is no picture at all. If LED 6 is on but LED 5
is off, the ROM did not arrive and the core stays in reset. If LED 5 is on but LED 4 is off, the
core runs but produces no video. If LED 2 is off, the Pico is not talking to the Nano.

## Diagnostic builds

Environment variables switch `build.tcl` to a test picture instead of the game. The LEDs then
mean something else, see the source.

| Variable | Shows |
|---|---|
| `ROMVIEW=1` | the loaded ROM data |
| `SDRAMTEST=2\|3` | the SDRAM phase measurement |
| `FBTEST=1`, `FBSHOW=1`, `FBROT=1` | the frame buffer's write path, read path and rotation |
| `RAMDIAG=1` | the RAM mirror, the rcheevos state and the queues |
| `NOTESTBAR=1` | the game without the input test bar, which saves one block RAM |

Example: `RAMDIAG=1 scripts/build_fpga.sh galaga_hdmi`

## Repository layout

```
fpga/common/        the platform shared by all games: top level, HDMI, scaler, SDRAM frame
                    buffer, SPI to the Pico, RAM mirror, pins and clocks
fpga/galaga_hdmi/   Galaga: Dar's core, its wrapper, the menu and the ROM manifest
fpga/pacman_hdmi/   Pac-Man, Puck Man and Ms. Pac-Man: MikeJ's core, its wrapper, the menu,
                    the ROM manifests and testbenches for nvc
external/           the submodules FPGA-Companion, pico-sdk and tinyusb
roms/               your ROM zips, not under version control
sdcard/             what goes on the SD card, including the template for config.ini
scripts/            building, flashing, ROMs and the SD card, releases
docs/               hardware, wiring, this page, and licence texts the firmware NOTICE needs
```

## Licences of the files

Each of our own source files carries `SPDX-License-Identifier: GPL-3.0-only` and the copyright
notice at the top. Two files mix our changes with code by others and carry our copyright for
those changes, but no SPDX tag: `sd_rw.v` (GPL-3.0, WangXuan95's SD card reader, via Nanomig)
and `mcu/sector_dpram.v` (output of the Gowin IP generator, via MiSTeryNano, with Gowin's
header). The menus (`menu.xml`) go into the bitstream byte for byte and carry no header. The
wiring drawing `docs/wiring_pico.svg` is a Fritzing export and, like the Fritzing breadboard
graphics in it, CC BY-SA 3.0.

Not ours, and kept with their original headers: the HDMI files (MIT OR Apache-2.0, see
`src/hdmi/LICENSE`), `sdram_fb.v` (GPL-3.0, derived from NESTang, with both copyright notices),
the T80 cores (BSD-style), MikeJ's Pac-Man core (BSD-style), Dar's Galaga core, WangXuan95's SD
card reader (GPL-3.0) and Till Harbaum's MiSTeryNano and Nanomig files (GPL-3.0-or-later, which
also applies to our changes in them).

The files we add to the Companion (`src/ra_*.c/.h`, `ra_ca.h`, `game20k_mbedtls_config.h`) are
Apache-2.0, like the rest of the Companion. [THIRD-PARTY.md](../THIRD-PARTY.md) explains what
all this means, the terms under which the bitstreams are published, and what the NOTICE files
of the firmware image and the bitstreams cover.

If one of our own files contains no code by others, we can make it available under a different
licence on request. Please ask in an issue.
