# Third-party code

This file lists what in this project is not ours, under which licence it comes, and what comes
in as a git submodule instead of being kept in the repository. The published repository starts
from a fresh initial commit, so its history carries nothing from before publication.

## Why GPL-3.0-only

Two components force the licence of the whole, independently of each other:

1. `fpga/galaga_hdmi/src/sdram_fb.v` is a derivative of `src/sdram_nes.v` from
   [NESTang](https://github.com/nand2mario/nestang), GPL-3.0.
2. `sd_rw.v` and `sdcmd_ctrl.v` in `fpga/galaga_hdmi/src/misc/`, taken from Nanomig and built
   into the bitstream, go back to
   [WangXuan95/FPGA-SDcard-Reader](https://github.com/WangXuan95/FPGA-SDcard-Reader), GPL-3.0.
   Nanomig ships them without the licence text. Under GPL-3.0 section 10 every recipient is
   licensed by the original licensor, so the permission stands. The licence text to consult is
   WangXuan95's.

GPL-3.0 has no "or later" unless the source grants it, hence GPL-3.0-only. Our own source files
carry `SPDX-License-Identifier: GPL-3.0-only` and `Copyright (C) 2026 scullymi`. Where one of
them contains no code from others, it can be made available under another licence on request,
file by file. Three files are the exception: `rtl_dar/gen_ram_dist.vhd`, `rtl_dar/prom_ram.vhd`
and `misc/sysctrl_galaga.v` combine our code with lines from `gen_ram.vhd` and `sysctrl.v` that
carry no licence. They name our copyright for our parts and carry no SPDX tag. The files we add
to the FPGA-Companion fork (`src/ra_*.c`, `src/ra_*.h` and
`src/rp2040/game20k_mbedtls_config.h`) are Apache-2.0 like the Companion, so they can go
upstream.

## In the repository

Third-party HDL is kept as copies with the original headers. `rtl_dar/`, `rtl_T80/` and `misc/`
each have a README that names the upstream commit and lists our changes, `hdmi/` has the MIT
notice in its LICENSE. The repository grants no licence on behalf of
these authors. Where they granted none, none exists, and whoever uses the files is bound by the
authors' terms, as with every other port of these cores.

| Component | Files | Author | Licence | Our changes |
|---|---|---|---|---|
| [DECAfpga/Arcade_Galaga](https://github.com/DECAfpga/Arcade_Galaga), `rtl_dar/` at `e06ba91` | [`fpga/galaga_hdmi/src/rtl_dar/`](fpga/galaga_hdmi/src/rtl_dar/README.md): `galaga.vhd`, `mb88.vhd`, `gen_video.vhd`, `sound_machine.vhd`, `stars.vhd`, `stars_machine.vhd` | Dar (darfpga@aol.fr) | none granted. `galaga.vhd` and `mb88.vhd` say "Educational use only, do not redistribute synthetized file with roms, do not redistribute roms whatever the form". The others carry no licence text | ROMs loaded at run time instead of built in (the two sound ROMs too), RAM mirror for the achievements, DIP switches as ports, resets, a Gowin timing fix, and the 51XX leaves credit mode only when a credit is consumed |
| same repository, `rtl_dar/` | `gen_ram.vhd` in the same folder | Peter Wendrich (pwsoft@syntiac.com), modified by Dar | copyright notice, no licence text | one line. Our `gen_ram_dist.vhd` and `prom_ram.vhd` are derived from it |
| same repository, `rtl_T80/` | [`fpga/galaga_hdmi/src/rtl_T80/`](fpga/galaga_hdmi/src/rtl_T80/README.md): `T80.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`, `T80_Pack.vhd`, `T80_Reg.vhd`, `T80se.vhd` (Z80 core) | Daniel Wallner | BSD-like, three conditions, in every header. Redistribution in synthesized form must reproduce the notice in the accompanying documentation | none |
| [MiSTle-Dev/MiSTeryNano](https://github.com/MiSTle-Dev/MiSTeryNano), `src/misc/` at `c8e4601` | [`fpga/galaga_hdmi/src/misc/`](fpga/galaga_hdmi/src/misc/README.md): `hid.v`, `mcu_spi.v`, `osd_u8g2.v`, and `sysctrl_galaga.v` derived from `sysctrl.v` | Till Harbaum | no licence file, no licence header | extra joystick byte, SPI target 5, OSD rotated by 90 degrees, `sysctrl_galaga.v` reduced to what Galaga needs |
| [MiSTle-Dev/Nanomig](https://github.com/MiSTle-Dev/Nanomig), `src/misc/` at `df97f03` | same folder: `sd_card.v`, `sd_rw.v`, `sdcmd_ctrl.v` | Till Harbaum, the latter two from WangXuan95 | no licence file, `sd_rw.v` and `sdcmd_ctrl.v` GPL-3.0 by origin | `sd_rw.v` retries CMD24 |
| [hdl-util/hdmi](https://github.com/hdl-util/hdmi) at `08936f6` | `fpga/galaga_hdmi/src/hdmi/*.sv` (10) | Sameer Puri | MIT OR Apache-2.0, upstream `LICENSE-MIT` and `LICENSE-APACHE`, used here under MIT, notice in [`src/hdmi/LICENSE`](fpga/galaga_hdmi/src/hdmi/LICENSE) | seven files identical to upstream, `hdmi.sv` and `tmds_channel.sv` with changes marked `game20k:`, `serializer.sv` in NESTang's version, which adds the line `` `define GW_IDE `` that hdl-util prescribes for the Gowin toolchain |
| [NESTang](https://github.com/nand2mario/nestang) | `fpga/galaga_hdmi/src/sdram_fb.v` | nand2mario | GPL-3.0 | derivative, carries both copyright notices |
| [Fritzing](https://fritzing.org) part graphics | [`docs/wiring_pico.svg`](docs/wiring_pico.svg), the breadboard export of the wiring sketch | Fritzing (the two breadboards). The Pico 2 W is Raspberry Pi's Pico W part by Alasdair Allan and Jack Wills, released with the design files "for any purpose, with or without fee", adapted for the Pico 2 W by vanepp on the Fritzing forum in February 2025 without a licence statement | Fritzing's graphics are CC BY-SA 3.0 Unported, and its `LICENSE.txt` asks that diagrams made with them credit Fritzing and carry the same licence, so the drawing is CC BY-SA 3.0 | the Tang Nano 20K part and the wires are ours |

## Submodules for the firmware build

Not in the repository. All are git submodules, pinned by commit. Whoever builds obtains them
under their authors' terms.

| Component | Where | Author | Licence | Our changes |
|---|---|---|---|---|
| [scullymi/FPGA-Companion](https://github.com/scullymi/FPGA-Companion), fork of [MiSTle-Dev/FPGA-Companion](https://github.com/MiSTle-Dev/FPGA-Companion) | submodule `external/FPGA-Companion`, branch `game20k` | Till Harbaum | Apache-2.0, no NOTICE file | our commits on the branch: the RetroAchievements client and the RAM mirror |
| [Pico SDK](https://github.com/raspberrypi/pico-sdk) | submodule `external/pico-sdk`, release 2.2.0 | Raspberry Pi | BSD-3-Clause | none |
| [scullymi/tinyusb](https://github.com/scullymi/tinyusb), fork of [hathach/tinyusb](https://github.com/hathach/tinyusb) | submodule `external/tinyusb`, branch `game20k` | Ha Thach | MIT | one commit on top of upstream: `hid_host.c` hands a failed IN transfer to the callback as `NULL` instead of the stale buffer contents, so the Companion can tell a failure from a report (the change Till Harbaum asks for in TinyUSB issue 3307, his README tells Companion users to make it by hand), and Pico-PIO-USB as a submodule at the commit TinyUSB's `tools/get_deps.py` pins. The SDK pins TinyUSB 0.18.0, with which the Companion does not build |
| [Pico-PIO-USB](https://github.com/sekigon-gonnoc/Pico-PIO-USB) | submodule of that branch, `external/tinyusb/hw/mcu/raspberry_pi/Pico-PIO-USB` | sekigon-gonnoc | MIT | none, the Companion links it in both USB variants |

`git submodule status --recursive` lists the commits in use.

## Firmware dependencies

Pulled in as submodules of the Pico SDK, or as submodules and vendored sources of the Companion
fork. None of them is in the repository.

| Component | Licence | Note |
|---|---|---|
| [rcheevos](https://github.com/RetroAchievements/rcheevos) | MIT | submodule of the fork, used unchanged |
| tusb_xinput | MIT | submodule of the fork, XInput controllers |
| FreeRTOS kernel | MIT | submodule of the fork, Raspberry Pi's port |
| lwIP | BSD-3-Clause | `http_client`, `altcp_tls` |
| mbedTLS | Apache-2.0 OR GPL-2.0-or-later | used under Apache-2.0, which is compatible with GPL-3.0 |
| u8g2 | BSD-2-Clause | submodule of the fork |
| FatFs | BSD-like | vendored in the fork |
| puff | Zlib | vendored in the fork, Mark Adler's inflate routine |
| printf of the Pico SDK | MIT | `pico_printf`, by Marco Paland |
| newlib | several free licences | C library of the Arm GNU Toolchain, text in `licenses/` |
| cyw43-driver | non-commercial, `LICENSE.RP` permits use and redistribution only together with Raspberry Pi silicon | covered for the Pico W |
| BTstack | non-commercial, `pico_btstack/LICENSE.RP` grants Pico W purchasers use and distribution with Pico W products | covered for the Pico W, built in while Bluetooth is enabled |

## Not distributed

- **ROM data**, in no form. `roms/` is excluded, and so are the VHDL tables generated from it
  and everything compiled from those.
- **Achievement conditions.** They belong to RetroAchievements. The firmware fetches the set
  at run time and keeps it only on the user's card. Nothing of it is in the repository.
- **Bitstreams.** They contain the synthesized Galaga core. Dar's condition forbids
  redistributing a synthesized file with ROMs, and this bitstream holds none, which is how
  the MiSTer and MiST ports publish theirs. Until the licence questions below are settled,
  none is published here.

## Firmware image

Each release carries `game20k-<version>-pico2w.uf2` for the Raspberry Pi Pico 2 W, built by
`scripts/make_firmware_release.sh` from the tagged sources, with `NOTICE.txt` next to it.
`scripts/firmware_notice.py` writes that NOTICE from the linker map: every object file in the
image has to belong to a listed component, and the NOTICE carries each component's licence text,
the copyright lines of the linked source files and the commit it was built from. A linked file
that no component claims stops the release, so a new library cannot get in without its notice.

Two components restrict where the image may be used. cyw43-driver, with the firmware of the
radio chip, is licensed under `LICENSE.RP` for use and redistribution only together with
Raspberry Pi semiconductor devices. BTstack is licensed by Raspberry Pi to purchasers of a Pico W
or Pico 2 W for use with those boards and products built on them. The image is published as
part of this project, which is built on the Pico 2 W, and only for it. The NOTICE says so at the
top.

The C library newlib comes with the Arm GNU Toolchain, which does not ship its licence text.
`licenses/newlib-4.4.0-COPYING.NEWLIB` carries it, taken from the newlib 4.4.0 release, and the
script checks that the toolchain in use links that version.

## Notes

- `src/ra_ca.h` in the fork contains the root certificate **GTS Root R4** by Google Trust
  Services, published at [pki.goog](https://pki.goog/repository/) for inclusion in trust
  stores. Its fingerprint is documented in the file. A root certificate is functional data, not
  a work.
- The 5x7 pixel font in `fpga/galaga_hdmi/src/ra_overlay.sv` (41 characters) is our own.
- The ten hdl-util files carry only the author's name. The MIT notice for them is in
  [fpga/galaga_hdmi/src/hdmi/LICENSE](fpga/galaga_hdmi/src/hdmi/LICENSE).
- An explicit licence statement is missing from Dar and from Peter Wendrich. Till Harbaum was
  asked in an issue in MiSTeryNano whether GPL-3.0-or-later is acceptable for his files.
