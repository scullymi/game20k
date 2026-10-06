# Third-party code

This file lists what in this project is not ours, under which licence it comes, and what is
pulled in as a git submodule instead of being kept in the repository. The published repository
starts from a fresh initial commit, so its history carries nothing from before publication.

## Why GPL-3.0-only

Two components require the whole to be GPL-3.0, independently of each other:

1. `fpga/common/src/sdram_fb.v` is derived from `src/sdram_nes.v` of
   [NESTang](https://github.com/nand2mario/nestang), which is GPL-3.0.
2. `sd_rw.v` and `sdcmd_ctrl.v` in `fpga/common/src/misc/`, taken from Nanomig and built into
   the bitstream, come from
   [WangXuan95/FPGA-SDcard-Reader](https://github.com/WangXuan95/FPGA-SDcard-Reader), which is
   GPL-3.0. Nanomig ships them without the licence text, but under GPL-3.0 section 10 every
   recipient is licensed by the original licensor, so WangXuan95's licence applies.

Neither grants "or later", hence GPL-3.0-only. Our own source files carry
`SPDX-License-Identifier: GPL-3.0-only` and `Copyright (C) 2026 scullymi`. Where one of them
contains no code by others, it can be made available under another licence on request, file by
file. Our changes to Till Harbaum's files in `misc/` are GPL-3.0-or-later, like his files, which
carry that SPDX tag. The files we add to the FPGA-Companion fork (`src/ra_*.c`, `src/ra_*.h` and
`src/rp2040/game20k_mbedtls_config.h`) are Apache-2.0, like the Companion, so they can go
upstream.

## In the repository

Third-party HDL is kept as copies with the original headers. The README in each folder, or the
LICENSE in `hdmi/`, names the upstream commit and lists our changes. This repository grants no
licence on behalf of these authors. Where they granted none, none exists, and anyone using the
files is bound by the authors' terms, as with every other port of these cores.

| Component | Files | Author | Licence |
|---|---|---|---|
| [DECAfpga/Arcade_Galaga](https://github.com/DECAfpga/Arcade_Galaga), `rtl_dar/` at `e06ba91` | [`fpga/galaga_hdmi/src/rtl_dar/`](fpga/galaga_hdmi/src/rtl_dar/README.md) | Dar (darfpga@aol.fr) | none granted. `galaga.vhd` and `mb88.vhd` say "Educational use only, do not redistribute synthetized file with roms, do not redistribute roms whatever the form". The other files carry no licence text |
| same repository, `rtl_T80/` | [`fpga/galaga_hdmi/src/rtl_T80/`](fpga/galaga_hdmi/src/rtl_T80/README.md) (Z80 core) | Daniel Wallner | BSD-like with three conditions, in every header. Redistribution in synthesized form must reproduce the notice in the accompanying documentation |
| [MiSTer-devel/Arcade-Pacman_MiSTer](https://github.com/MiSTer-devel/Arcade-Pacman_MiSTer), `rtl/` at `648172d` | [`fpga/pacman_hdmi/src/rtl_pacman/`](fpga/pacman_hdmi/src/rtl_pacman/README.md) | MikeJ (the descrambler by d18c7db, `pacman_vram_addr.vhd` with CarlW), later changes by Alexey Melnikov and Alan Steremberg | BSD-like with three conditions, as for the T80. The upstream repository has no licence file at its root. Our own files in the folder (`g20k_dpram.vhd`, `pacman_mirror.vhd`, `sn76489_top.vhd`, `ym2149.vhd`) are GPL-3.0-only |
| same repository, `rtl/cpu/` | [`fpga/pacman_hdmi/src/rtl_T80/`](fpga/pacman_hdmi/src/rtl_T80/README.md) (Z80 core, Ver 300, with MikeJ's `T80sed`) | Daniel Wallner, MikeJ | BSD-like with three conditions, as above |
| [jotego/jtcores](https://github.com/jotego/jtcores) at `0b197ca` | [`fpga/g1942_hdmi/src/jtcores/`](fpga/g1942_hdmi/src/jtcores/README.md) (the 1942 game, six modules of Ghosts'n Goblins and the parts of JTFRAME it uses) | Jose Tejada Gomez (jotego) | GPL-3.0-or-later, in every header |
| same repository, `modules/jtframe/hdl/cpu/t80/` | same folder (Z80 core, Ver 350) | Daniel Wallner, later changes by MikeJ, Sorgelig and others | BSD-like with three conditions, as above |
| [jotego/jt49](https://github.com/jotego/jt49) at `7f6abfd` | [`fpga/g1942_hdmi/src/jt49/`](fpga/g1942_hdmi/src/jt49/README.md) (AY-3-8910) | Jose Tejada Gomez | GPL-3.0-or-later, in every header |
| [jotego/jtcores](https://github.com/jotego/jtcores) at `548b87b` | [`fpga/g1943_hdmi/src/jtcores/`](fpga/g1943_hdmi/src/jtcores/README.md) (the 1943 game, twelve modules of Ghosts'n Goblins and the parts of JTFRAME it uses) | Jose Tejada Gomez | GPL-3.0-or-later, in every header |
| same repository, `modules/jtframe/hdl/cpu/t80/` | same folder (Z80 core, Ver 350, the same files as in the 1942 core) | Daniel Wallner, later changes by MikeJ, Sorgelig and others | BSD-like with three conditions, as above |
| [jotego/jt12](https://github.com/jotego/jt12) at `dc9be7c` | [`fpga/g1943_hdmi/src/jt12/`](fpga/g1943_hdmi/src/jt12/README.md) (YM2203) | Jose Tejada Gomez | GPL-3.0-or-later, in every header |
| [jotego/jt49](https://github.com/jotego/jt49) at `7f6abfd` | [`fpga/g1943_hdmi/src/jt49/`](fpga/g1943_hdmi/src/jt49/README.md) (the SSG of the YM2203) | Jose Tejada Gomez | GPL-3.0-or-later, in every header |
| [MiSTle-Dev/MiSTeryNano](https://github.com/MiSTle-Dev/MiSTeryNano), `src/misc/` at `c8e4601` | [`fpga/common/src/misc/`](fpga/common/src/misc/README.md): `hid.v`, `mcu_spi.v`, `osd_u8g2.v`, `sysctrl.v` | Till Harbaum | GPL-3.0-or-later. Upstream the files carry no licence header, our copies carry the SPDX tag |
| [MiSTle-Dev/Nanomig](https://github.com/MiSTle-Dev/Nanomig), `src/misc/` at `df97f03` | same folder: `sd_card.v`, `sd_rw.v`, `sdcmd_ctrl.v` | Till Harbaum, the last two by WangXuan95 | `sd_card.v` GPL-3.0-or-later, `sd_rw.v` and `sdcmd_ctrl.v` GPL-3.0 by origin |
| [MiSTle-Dev/MiSTeryNano](https://github.com/MiSTle-Dev/MiSTeryNano), `src/tang/nano20k/gowin_dpb/` at `c8e4601` | `fpga/common/src/mcu/sector_dpram.v` | output of the Gowin IP generator, an instance of the DPB primitive | no licence text, Gowin's copyright header ("All rights reserved"). Gowin's licence agreement lets users keep and use the output of its tools |
| [hdl-util/hdmi](https://github.com/hdl-util/hdmi) at `08936f6` | `fpga/common/src/hdmi/*.sv` | Sameer Puri | MIT OR Apache-2.0, used here under MIT. The notice is in [`src/hdmi/LICENSE`](fpga/common/src/hdmi/LICENSE), since the files themselves carry only the author's name. `serializer.sv` is NESTang's version |
| [NESTang](https://github.com/nand2mario/nestang), `src/sdram_nes.v` at `1c00dc5` | `fpga/common/src/sdram_fb.v` | nand2mario | GPL-3.0. Our file is a derivative and carries both copyright notices |
| [Fritzing](https://fritzing.org) part graphics | [`docs/wiring_pico.svg`](docs/wiring_pico.svg), the breadboard export of the wiring sketch | Fritzing (the two breadboards). The Pico 2 W is Raspberry Pi's Pico W part by Alasdair Allan and Jack Wills, released with the design files "for any purpose, with or without fee", adapted for the Pico 2 W by vanepp on the Fritzing forum in February 2025 without a licence statement. The Tang Nano 20K part and the wires are ours | Fritzing's graphics are CC BY-SA 3.0 Unported, and its `LICENSE.txt` asks that diagrams made with them credit Fritzing and carry the same licence, so the drawing is CC BY-SA 3.0 |

## Submodules

Not in the repository. All of them are git submodules, pinned by commit, and whoever builds
obtains them under their authors' terms. `git submodule status --recursive` lists the commits.

| Component | Where | Author | Licence | Our changes |
|---|---|---|---|---|
| [scullymi/FPGA-Companion](https://github.com/scullymi/FPGA-Companion), fork of [MiSTle-Dev/FPGA-Companion](https://github.com/MiSTle-Dev/FPGA-Companion) | `external/FPGA-Companion`, branch `game20k` | Till Harbaum | Apache-2.0, no NOTICE file | the RetroAchievements client and the RAM mirror |
| [Pico SDK](https://github.com/raspberrypi/pico-sdk) | `external/pico-sdk`, release 2.2.0 | Raspberry Pi | BSD-3-Clause | none |
| [scullymi/tinyusb](https://github.com/scullymi/tinyusb), fork of [hathach/tinyusb](https://github.com/hathach/tinyusb) | `external/tinyusb`, branch `game20k` | Ha Thach | MIT | one fix in `hid_host.c` that the Companion needs (TinyUSB issue 3307), and Pico-PIO-USB as a submodule |
| [Pico-PIO-USB](https://github.com/sekigon-gonnoc/Pico-PIO-USB) | submodule of the TinyUSB fork | sekigon-gonnoc | MIT | none |
| [Unity](https://github.com/ThrowTheSwitch/Unity) | `external/unity`, tag v2.7.0 | Mike Karlesky, Mark VanderVoord, Greg Williams | MIT | none. Only the host tests in `tests/host` use it, it is not part of any release |

## Firmware dependencies

Pulled in through the Pico SDK or the Companion fork, as submodules or as vendored sources. None
of them is in this repository.

| Component | Licence | Note |
|---|---|---|
| [rcheevos](https://github.com/RetroAchievements/rcheevos) | MIT | used unchanged |
| tusb_xinput | MIT | XInput controllers |
| FreeRTOS kernel | MIT | Raspberry Pi's port |
| lwIP | BSD-3-Clause | `http_client`, `altcp_tls` |
| mbedTLS | Apache-2.0 OR GPL-2.0-or-later | used under Apache-2.0, which is compatible with GPL-3.0 |
| u8g2 | BSD-2-Clause | |
| FatFs | BSD-like | vendored in the fork |
| puff | Zlib | vendored in the fork, Mark Adler's inflate routine |
| printf of the Pico SDK | MIT | `pico_printf`, by Marco Paland |
| newlib | several free licences | C library of the Arm GNU Toolchain, text in `docs/licenses/` |
| cyw43-driver | non-commercial, `LICENSE.RP` permits use and redistribution only together with Raspberry Pi silicon | covered, as the image only runs on the Pico 2 W |
| BTstack | non-commercial, `pico_btstack/LICENSE.RP` grants Pico W purchasers use and distribution with Pico W products | not in the game20k image, which has Bluetooth turned off |

## Not distributed

- **ROM data, with one exception.** `roms/` is excluded, and so is everything built from it. The
  exception is in third-party code: MikeJ's `pacman_audio.vhd` reproduces the whole content of
  the sound timing PROM 3M (82s126, 256x4, its upper half empty) as a 16-case logic table,
  inverted, as MiSTer's port does.
- **Achievement conditions.** They belong to RetroAchievements. The firmware fetches each set at
  run time and keeps it only on the user's card. Nothing of it is in the repository.

## Firmware image

Each release carries `game20k-<version>-pico2w.uf2` for the Raspberry Pi Pico 2 W with its
`NOTICE.txt`. `scripts/firmware_notice.py` writes the NOTICE from the linker map: every object
file in the image has to belong to a listed component, and the NOTICE carries each component's
licence text, the copyright lines of the linked source files and the commit the image was built
from. A linked file that no component claims stops the release.

Two components restrict where the image may be used. cyw43-driver, with the firmware of the
radio chip, is licensed under `LICENSE.RP` for use and redistribution only together with
Raspberry Pi semiconductor devices. BTstack is licensed by Raspberry Pi to purchasers of a Pico W
or Pico 2 W for use with those boards and products built on them. The image is published as
part of this project, which is built on the Pico 2 W, and only for it. The NOTICE says so at the
top.

The Arm GNU Toolchain does not ship the licence text of its C library, newlib.
`docs/licenses/newlib-4.4.0-COPYING.NEWLIB` carries it, taken from the newlib 4.4.0 release, and
the release script checks that the toolchain in use links that version.

## Bitstreams

Each release carries `game20k-<version>-tangnano20k.zip` with one flash image that holds every
core, `FLASHING.txt` with the command to write it, and `NOTICE.txt`.
`scripts/make_bitstream_release.sh` builds them from the tagged sources with Gowin EDA Education
on a local machine, since GitHub Actions has no Gowin tools. `scripts/bitstream_notice.py`
writes the NOTICE from the file lists of the synthesis: every source file of each bitstream has
to belong to a listed component, and a file that none claims stops the release. The NOTICE
names the commit and the SHA-256 of each core. Rebuilding the same sources with the same Gowin
version gave identical files on the build machine, also from a fresh clone at another path.
Builds on other machines have not been compared yet.

- **No ROM image, with one exception.** The cores load their game's ROMs from the SD card at run
  time, PROMs included. The exception is Pac-Man's sound timing PROM 3M in MikeJ's core, see
  above. The star table in Dar's `stars.vhd` comes from MAME's recording of the 05xx starfield
  chip (MAME 0.190, `src/mame/video/galaga.cpp`, BSD-3-Clause, Nicola Salmoria), not from a ROM.
- **Dar's condition** forbids redistributing a synthesized file with ROMs. We read it strictly: a
  bitstream without ROM images may be passed on, ROMs never. MiSTer and MiST publish bitstreams
  of Dar's cores, and their Galaga bitstreams still contain the five colour and sound PROMs,
  ours contain none. MiSTer's port of Dar's Popeye, whose source carries Dar's note "release rev
  04 : MiSTer configuration", loads all its ROMs at run time, as ours do.
- **An open point with Galaga.** Its bitstream combines GPL-3.0 code by nand2mario
  (`sdram_fb.v`) and WangXuan95 (`sd_rw.v`, `sdcmd_ctrl.v`) with Dar's code, which grants no
  licence and asks for educational use only. GPL-3.0 requires the whole to be under its terms
  and allows no further restrictions. MiSTer and MiST combine Dar's core only with GPL code of
  their own projects. We publish the Galaga bitstream all the same and name the point here. The
  source repository is in the same position. The Pac-Man core itself (MikeJ, T80) is BSD-style,
  so the question does not arise there.
- **Gowin EDA Education** may only be used for education, research and other non-commercial
  purposes (release note RN100 in the installation). The bitstreams are built for this
  non-commercial project and published free of charge. This describes how they were made and
  adds no condition to the GPL-3.0. The design uses device primitives only, no Gowin IP core.
  `sector_dpram.v` and the rPLL instance in `pll_sdram.v` are output of the Gowin IP generator.

## Notes

- `src/ra_ca.h` in the fork contains the root certificate **GTS Root R4** by Google Trust
  Services, published at [pki.goog](https://pki.goog/repository/) for inclusion in trust
  stores. Its fingerprint is documented in the file. A root certificate is functional data, not
  a work.
- The 5x7 pixel font in `fpga/common/src/ra_overlay.sv` is our own.
  `fpga/common/src/input_test_bar.sv` has a second, 8x8 font for the labels of the input test,
  whose origin is not recorded.
