# game20k: arcade on the Tang Nano 20K

An arcade cabinet built from two boards: a **Sipeed Tang Nano 20K** (Gowin GW2AR-18) running
the game core, the scaler, HDMI and the SD card, and a **Raspberry Pi Pico 2 W** as companion
processor for the USB arcade stick, the menu and **RetroAchievements**. The first game is
Galaga, more are to follow.

Picture and sound go out over HDMI (1280x720), landscape at 3x or portrait at 2x as in the
cabinet, switchable in the menu. The ROMs are loaded from the SD card at run time, and a mirror
of the game RAM goes to the Pico frame by frame, where
[rcheevos](https://github.com/RetroAchievements/rcheevos) evaluates the achievement conditions.

> **ROMs are not included and never will be.** You need your own, legally obtained Galaga ROM
> set. Without it the screen stays dark.

## Status

| | |
|---|---|
| Picture, sound, input, OSD menu | works |
| ROMs from the SD card, no ROM image in the bitstream (one exception, Pac-Man's sound PROM 3M as a table in MikeJ's core, see [THIRD-PARTY.md](THIRD-PARTY.md#bitstreams)) | works |
| Landscape (3x) or portrait (2x) through the SDRAM frame buffer, switchable in the menu, scanlines selectable | works |
| RAM mirror to the Pico, consistent snapshots | works |
| RetroAchievements: conditions evaluated on the Pico | works |
| RetroAchievements: login, unlocks submitted over HTTPS (TLS 1.2), achievement set and account state fetched from the server, unlocks queued on the card while offline | works |
| In game: text banner on an unlock, account state under RetroAchievements, Account in the menu | works |
| RetroAchievements: session with Rich Presence, achievement list with progress in the menu, challenge marker, leaderboards | works |
| WiFi after a cold start, clock from NTP | works |
| Hardcore mode: the default, switched on only with a reset, FTP write protection, device key, known ROM only | works on the device. Until RetroAchievements approves this client, the server keeps its unlocks as softcore and no leaderboard entries, and the banner shows the server's warning |

## Planned

- **Sound through a speaker, in addition to HDMI.** Two ways: an I2S amplifier module such as
  the MAX98357A on three free FPGA pins, which first needs an I2S output in the FPGA, or the
  sigma-delta output on pin 77 with an external filter and amplifier, see
  [docs/hardware.md](docs/hardware.md#analogue-sound-optional).
- **More games.** Every arcade board needs its own core and bitstream, shared by the games that
  ran on it. The ROMs come from the SD card as with Galaga. Candidates:
  - Namco: Galaxian, Pac-Man and Ms. Pac-Man, Dig Dug, Xevious, Bosconian
  - Capcom, from Jotego's jtcores: 1942, Vulgus, Commando, Gun.Smoke, 1943
  - games with an existing Tang Nano port: Donkey Kong, Defender, Time Pilot, Centipede,
    Pooyan, Bagman, Crazy Climber
- **RetroAchievements for every game.** The firmware identifies the game by the name of its ROM
  file, as RetroAchievements does for arcade games, and keeps one achievement set per game on
  the card.
- **Hardcore unlocks and leaderboard entries on RetroAchievements,** once it approves this client.
  The device side is in place.

What this builds on:

- existing FPGA cores with published source that recreate the original hardware instead of
  emulating it: Dar's arcade cores including Galaga, Jotego's jtcores and the MiSTer arcade ports
- Till Harbaum's MiSTeryNano, Nanomig and FPGA-Companion for the SPI link, the OSD, SD card
  access and the companion firmware
- odelot's RetroAchievements fork of the MiSTer main program as the model for achievements on an
  FPGA, and the FBNeo sets on RetroAchievements as the reference for arcade games

## Open points

- **Hardcore approval.** Unlocks count as softcore until RetroAchievements approves this client.
  Rich Presence, the achievement list in the menu, the hardcore setting that takes effect only
  with a reset, and the proof chain (device key, ROM digest, set tag, DIP switches taken over in
  reset only) are in place. Plan: ask RetroAchievements for approval.
- **FTP without a password.** The FTP server accepts any login, so anyone on the network can read
  and change the SD card, including `config.ini` with the WiFi key and the RetroAchievements
  token. Telnet on port 23 shows the debug log to anyone on the network. Plan: make FTP and
  telnet switchable in `config.ini`, and check whether FTP can take an optional password.
- **Secrets in the debug log.** A `config.ini` line over 62 characters is dropped, and so is a
  last line without a line break. The debug log prints its start in plain text, a long WiFi
  password included. Plan: log only the key name and accept longer lines.
- **Heap on the Pico.** The FreeRTOS heap is nearly full. A second FTP connection finds no memory
  for its task, and new firmware features need more heap first. Plan: give FreeRTOS more of the
  RP2350's RAM and turn on the stack overflow check.
- **FPGA timing.** The timing report lists 36 endpoints that fail setup. All 25 it shows are on
  the SDRAM read path, whose clock phase was measured on the board, and the 371 MHz clock of the
  HDMI serializer is not checked at all. The design runs on the tested board. Plan: constrain
  both paths so that the report covers them, then close the violations.
- **WiFi.** The firmware connects with WPA2 only and gives up after the attempts at power-on.
  Plan: allow WPA3 networks and keep retrying in the background.
- **Pico W.** It has not been tested with the RetroAchievements firmware, yet
  `scripts/build_companion.sh` builds for it by default. Plan: make the Pico 2 W the default,
  then test the Pico W or drop it from the docs.
- **Bitstreams in the release.** Up to 0.2.0 everyone builds the bitstream.
  `scripts/make_bitstream_release.sh` builds them with their NOTICE for the next release, see
  [THIRD-PARTY.md](THIRD-PARTY.md#bitstreams). Plan: read Gowin's current licence agreement
  (behind a login on gowinsemi.com) before the first upload.

## Hardware

| Part | Note |
|---|---|
| Sipeed Tang Nano 20K | GW2AR-LV18QN88C8/I7 |
| Raspberry Pi Pico 2 W | stepping **A3 or A4**, see below |
| microSD card | FAT32 tested, exFAT compiled in, contents in [sdcard/README.md](sdcard/README.md) |
| Micro USB to USB A OTG adapter | for the stick on the Pico |
| HDMI monitor | must accept 1280x720 at **61.03 Hz** |
| USB arcade stick (HID) | |
| Perfboard, wire | seven connections |

**Stepping.** The RP2350 stepping A2 is affected by erratum E9: a USB host port built on GP2/GP3
does not work there without external pull-downs. The **native micro USB port with an OTG
adapter**, the recommended way, is not affected. Details in [docs/hardware.md](docs/hardware.md).

**Sound.** The Nano's onboard amplifier is not usable with the Companion attached, its I2S pins
are the SPI pins. Sound comes over HDMI. Analogue sound through an external filter and amplifier
module on pin 77 is planned, see [docs/hardware.md](docs/hardware.md#analogue-sound-optional).

**Wiring:** [docs/wiring.md](docs/wiring.md) and
[docs/wiring_pico.svg](docs/wiring_pico.svg). **5 V goes to pin 40 (VBUS)**, not VSYS,
otherwise the Pico's USB host port has no power.

## Tools

| Tool | Version | Note |
|---|---|---|
| Gowin EDA **Education** | 1.9.11.03 | free download, **no licence file needed**, its programmer flashes the board |
| openFPGALoader | optional | alternative for flashing: `brew install openfpgaloader` or `apt install openfpgaloader`, no winget package |
| Arm GNU Toolchain | 14.2 | search paths below, `PICO_TOOLCHAIN_PATH` overrides them |
| Pico SDK | 2.2.0 | git submodule `external/pico-sdk`, minimum 2.2.0 |
| git, curl, CMake, make, Python 3, gzip, unzip, cc | | |

`scripts/build_fpga.sh` looks for Gowin in the usual places on macOS and Linux. Elsewhere, set
it once:

```sh
export GOWIN_IDE=/opt/gowin/IDE          # the folder that contains bin/gw_sh
export PICO_TOOLCHAIN_PATH=/opt/arm-gnu-toolchain-14.2
```

Windows is untested. The scripts are POSIX sh, under WSL they should run.

## Build

### 1. Sources and third-party repositories

```sh
git clone --recursive https://github.com/scullymi/game20k.git && cd game20k
```

All HDL is in the repository. What the firmware build needs beyond that comes as git
submodules under `external/`, about 2 GB with git's object stores:

- **The Pico firmware**, our fork of FPGA-Companion,
  [scullymi/FPGA-Companion](https://github.com/scullymi/FPGA-Companion), branch `game20k`
  (Till Harbaum's tree plus our commits), as `external/FPGA-Companion`. Its own submodules
  bring FreeRTOS, u8g2, tusb_xinput and rcheevos.
- **The Pico SDK** as `external/pico-sdk`, at a release tag, with its own submodules for WiFi,
  Bluetooth and TLS.
- **TinyUSB**, our fork [scullymi/tinyusb](https://github.com/scullymi/tinyusb), branch
  `game20k`, as `external/tinyusb`. The Companion needs a newer TinyUSB than the SDK pins, plus
  one changed line, and the branch carries Pico-PIO-USB as a submodule, so nothing has to be
  fetched by hand. Details in [THIRD-PARTY.md](THIRD-PARTY.md).

Git records which commits are in use, and `git submodule status --recursive` lists them. A
clone without `--recursive` works too, the build script fetches the submodules itself.

**Third-party HDL** sits under `fpga/` with its original headers: the game cores in the game
folder (`fpga/galaga_hdmi/src/`), the board files in `fpga/common/src/`. `rtl_dar/`, `rtl_T80/`
and `misc/` each have a README that names the upstream commit and our changes, `hdmi/` has its
MIT notice, which names the changed files:

| Folder | From | Our changes |
|---|---|---|
| [`rtl_dar/`](fpga/galaga_hdmi/src/rtl_dar/README.md) | Dar's Galaga core, via DECAfpga/Arcade_Galaga | ROMs from the SD card, DIP switches from the menu, RAM mirror for the achievements, Gowin fixes |
| [`rtl_T80/`](fpga/galaga_hdmi/src/rtl_T80/README.md) | T80 Z80 core by Daniel Wallner | none |
| [`rtl_pacman/`](fpga/pacman_hdmi/src/rtl_pacman/README.md) | MikeJ's Pac-Man core, via MiSTer-devel/Arcade-Pacman_MiSTer | ROMs from the SD card, RAM Gowin can place, taps for the RAM mirror, the second program bank left out |
| [`rtl_T80/`](fpga/pacman_hdmi/src/rtl_T80/README.md) (Pac-Man) | T80 Z80 core Ver 300 with MikeJ's T80sed | none |
| [`misc/`](fpga/common/src/misc/README.md) | MiSTeryNano and Nanomig by Till Harbaum | extra joystick byte, SPI target 5, rotated OSD, `sysctrl.v`, `sd_rw.v` retries `CMD24` |
| [`hdmi/`](fpga/common/src/hdmi/LICENSE) | hdl-util/hdmi by Sameer Puri, at `08936f6` | audio and timing changes marked `game20k:` |

What comes from whom, under which licence, is listed in [THIRD-PARTY.md](THIRD-PARTY.md).

### 2. ROMs

Put into `roms/` (excluded from version control):

- `galaga.zip`, the MAME set **`galaga`** (parent, Namco **Rev B**), as a merged set
- `namco54.zip`, optional, without it the explosion sounds are missing

```sh
scripts/make_sdcard.sh                        # builds and checks, lists what is missing
scripts/make_sdcard.sh /Volumes/YOUR_CARD     # ... and copies to the card
```

The script builds one ROM file per game whose set lies in `roms/`, as the game's manifest
(`fpga/galaga_hdmi/galaga.manifest`) describes it: every chip is checked by size and SHA-1
against MAME, the result is `sdcard/galaga.rom` (exactly 38944 bytes). It then checks
`config.ini` (line length), writes a `galaga.ini` that preselects the ROM, and copies everything
together with `sdcard/README.md` to the card. The loader on the device rejects a ROM of the
wrong size **silently**, so the check happens here.

### 3. RetroAchievements, with or without an account

The firmware needs nothing from RetroAchievements to build. At start it fetches the achievement
set from the server and keeps it as `ra/<id>/patch.json` on the card (the game's id on
RetroAchievements, Galaga: `ra/12138/`), so it is there without a network at the next
power-up. **Without an account:** nothing to do, the device does not log in anywhere and shows
"no set loaded" under RetroAchievements, Account. Continue with step 4.

**With an account:**

```sh
cp sdcard/config.ini.example sdcard/config.ini && chmod 600 sdcard/config.ini
```

`sdcard/config.ini` is the only place for credentials, the same file that goes to the SD card
and that the device reads. Enter your account name and the connect token under `[RA]` and
remove the `;` in front of those two lines.
`.gitignore` excludes the file.

| | what it is | for |
|---|---|---|
| **Password** | your RA password | once, to obtain the token, not kept |
| **Connect token** | 16 characters, replaces the password in `dorequest.php` | the only way to the achievement conditions and to submitting unlocks |
| Web API key | 32 characters, from the account settings | not usable here, `MemAddr` comes as hashes only |

The token, once:

```sh
curl -s -A 'game20k/v0.2.0 (token request with curl)' https://retroachievements.org/dorequest.php \
  --data-urlencode 'r=login2' --data-urlencode 'u=YOURNAME' --data-urlencode 'p=YOURPASSWORD'
```

`-A` names game20k as the client. RetroAchievements refused a request with curl's own
User-Agent (HTTP 403), and a client must never send another emulator's. Put the `Token` field
of the reply into `[RA] TOKEN=`. A normal account with a confirmed e-mail address is enough.
Until RetroAchievements approves this client for hardcore, unlocks count as softcore and
leaderboard entries are not kept.

> The card is FAT32 and has no permissions: token and WiFi key are on it in plain text. The
> Companion's FTP server serves every file on the card, `config.ini` included, to anyone on the
> network. Before lending the cabinet, delete `/config.ini` from the card.

### 4. FPGA: build and flash

```sh
scripts/make_menu_hex.sh              # only after a change to a core's menu.xml
scripts/build_fpga.sh galaga_hdmi
scripts/build_fpga.sh pacman_hdmi
scripts/fpga_report.sh galaga_hdmi    # utilisation, clocks, violated endpoints
scripts/flash_fpga.sh galaga_hdmi flash
scripts/flash_fpga.sh pacman_hdmi flash
```

Without `flash` the bitstream goes to SRAM only and is gone after power off. The flash holds
both cores, each at its address in [fpga/common/slots.txt](fpga/common/slots.txt): Galaga at 0,
the one the FPGA loads at power-on, Pac-Man at 0x100000. The script writes Galaga with Gowin's
`programmer_cli`, with `FLASHER=openfpgaloader` with openFPGALoader. Pac-Man always goes through
openFPGALoader, which has to be installed for it: `programmer_cli` cannot write another
address. After writing the flash, power the board off and on.

Releases after 0.2.0 carry both bitstreams as `game20k-<version>-tangnano20k.zip`, with the
flash commands in its `FLASHING.txt`: take them instead of building, like the firmware.

### 5. Firmware: build and flash

Each release on the GitHub release page carries the image `game20k-<version>-pico2w.uf2` with
its `NOTICE.txt`, for the Pico 2 W only. Take it instead of building, then continue with
BOOTSEL below. To build:

```sh
scripts/build_companion.sh pico2 native
```

Plug in the Pico with BOOTSEL held and copy
`external/FPGA-Companion/src/rp2040/build_pico2_native/fpga_companion.uf2` to the drive. The
drive disappears by itself when the firmware arrived. With a debug probe, OpenOCD flashes
without BOOTSEL, see [docs/wiring.md](docs/wiring.md#flashing-through-the-probe).

`external/FPGA-Companion` is the fork on branch `game20k` as a git submodule. What is checked
out there gets built. Firmware work happens there as in any git repository. After a firmware
commit, `git add external/FPGA-Companion` and commit here: this repository then records which
firmware commit belongs to which game20k commit. The build script prints the commit it builds
and says when the checkout has uncommitted changes. It passes the version of this repository,
`git describe --tags`, to the firmware, so a release built on its tag reports itself as that
version, a build in between as the tag plus the distance to it.

### 6. First start

Card in the Nano, power on.

1. The screen stays **dark until LED 5 is on**. The core is held in reset until the ROM is
   loaded, which takes a moment.
2. The Pico's LED blinks, the firmware's heartbeat.
3. **S2 on the Nano opens the menu.** If it appears, Pico and Nano talk to each other.
4. Test the stick **in the game**, not in the open menu. While the menu is open, the Pico uses
   the stick for navigation.

What to expect and what the LEDs report: [docs/wiring.md](docs/wiring.md#first-start-check).
What goes on the card: [sdcard/README.md](sdcard/README.md).

## Operation

On the Nano: **S1** resets the game, **S2** opens and closes the menu.

On the stick, as shipped:

| | Button |
|---|---|
| Fire | any button |
| Coin | 9 |
| Start player 1 | 10 |
| Start player 2 | off |
| Volume | menu, Settings |

The numbers are the ones the input test shows on the buttons (menu, `Controller`, `Input test:
On`). Everything can be changed under `Controller` and kept with `Save settings` under
`Settings`, otherwise it lasts until power off.

`RetroAchievements` holds the mode, the achievement list with progress and the account. `Mode` switches between hardcore, the
default, and softcore. Softcore applies at once. Switching to hardcore resets a running game
first, as RetroAchievements requires, and the banner names the mode at each game start. In
hardcore the server's warning follows, "Unknown Emulator" until RetroAchievements approves this
client. In hardcore, FTP cannot change the `ra_*` files, the folder `ra` and `config.ini`.
`Account` shows the login, the unlocks and what still waits for the server. Without a
connection the achievements still count, their unlocks wait on the card and go out once the
server is reached.

`Status` shows the network and, under `Version`, the firmware version, the same one the firmware
reports to RetroAchievements.

The game changes under `ROM set` in `Settings`. A ROM of another game on the same board, such as
`puckman.rom` while Pac-Man runs, restarts the Pico into that game with its own achievements. A
ROM of a game on the other core, such as `galaga.rom` while Pac-Man runs, loads that core first.
Either way the menu says so, and after about three seconds the new game starts. The choice lasts
until power off. `Save settings` keeps a ROM of the same core. Power-on always starts Galaga.

A stick button can open the menu as well: `GAMEPAD_TRIGGER` under `[MENU]` in `config.ini`, see
[sdcard/config.ini.example](sdcard/config.ini.example). That setting counts the buttons from 0,
while the input test labels them from 1, so enter the label minus one (B1 is 0, button 5 is 4).

## Debugging: the Pico talks

The firmware prints its whole run as text on **UART0, GP0 (TX), 921600 baud**. A USB TTL
adapter on GP0 and GND is enough, a debug probe brings the UART along. Connection, probe,
flashing over SWD and reading with timestamps: [docs/wiring.md](docs/wiring.md#reading-the-serial-output).

## Debugging: the Nano shows

Six LEDs on the Tang Nano, counted as printed on the board, **LED 1 to 6**, active low. In normal
operation:

| LED | on when | signal |
|---|---|---|
| 1 | blinks once a second, faster while the ROM loads | `blink[23]` or `rom_count[9]` |
| 2 | a packet from the Pico has arrived at least once | `hid_seen` |
| 3 | a direction or button is held | `joystick` |
| 4 | a vsync has been seen at least once | `vs_seen` |
| 5 | the ROM is completely loaded | `rom_loaded` |
| 6 | the HDMI PLL is locked | `pll_lock` |

LED 6 off: the PLL does not run, no picture at all. LED 6 on and LED 5 off: the ROM did not
arrive, the core stays in reset. LED 5 on and LED 4 off: the core runs but produces no video.
LED 2 off: the Pico does not talk to the Nano. The diagnostic builds below reassign the LEDs,
see their source.

## Diagnostic builds

`build.tcl` reads environment variables that build a test picture instead of the game, and one
that saves a block RAM:

| Variable | shows |
|---|---|
| `ROMVIEW=1` | the loaded ROM data |
| `SDRAMTEST=2\|3` | SDRAM phase measurement |
| `FBTEST=1`, `FBSHOW=1`, `FBROT=1` | frame buffer write path, read path, rotation |
| `RAMDIAG=1` | RAM mirror, rcheevos state, queues |
| `NOTESTBAR=1` | the game without the input test bar, saves one BSRAM block |

Example: `RAMDIAG=1 scripts/build_fpga.sh galaga_hdmi`

## Layout

```
fpga/common/             the platform, one for every game: top level, HDMI, scaler, SDRAM frame buffer,
                         SPI, RAM mirror, pins and clocks of the board
fpga/common/src/misc/, hdmi/   third-party HDL, a README in misc/, a LICENSE in hdmi/
fpga/galaga_hdmi/        the game: Dar's core, its wrapper game_core.sv and game_pkg.sv, the menu,
                         the ROM manifest
fpga/galaga_hdmi/src/rtl_dar/, rtl_T80/   third-party HDL, a README in each
fpga/pacman_hdmi/        the second game: MikeJ's core with its RAM mirror, game_core.sv, game_pkg.sv,
                         the menu, the ROM manifest, and sim/ with two nvc testbenches
external/                the submodules FPGA-Companion, pico-sdk and tinyusb
roms/                    your ROM zips, excluded from version control, only its README is tracked
sdcard/                  what goes on the SD card, with the template for config.ini
scripts/                 build, flash, prepare ROMs and the card, firmware release with NOTICE, Doxygen pages of the fork's RA sources
docs/                    hardware and wiring, in docs/licenses/ the licence text the firmware NOTICE
                         needs and no submodule carries (newlib)
```

The two boards are connected by five SPI lines with six target channels: system, input, OSD,
SD card, audio (reserved by the Companion, unused) and **channel 5, the RAM mirror**.

## Privacy

game20k runs no servers and collects nothing. With a RetroAchievements account, the device talks
to retroachievements.org. [PRIVACY.md](PRIVACY.md) lists what it sends and stores, and the local
risks of FTP and telnet.

## Licence

**GPL-3.0-only** ([LICENSE](LICENSE)), Copyright (C) 2026 scullymi. Every own source file
carries `SPDX-License-Identifier: GPL-3.0-only` and this notice in its first lines. Three files
mix our changes with code that is not ours and carry our copyright for those changes but no
SPDX tag: `sysctrl.v` (from Till Harbaum's `sysctrl.v`), `sd_rw.v` (GPL-3.0, WangXuan95's SD
card reader via Nanomig) and `mcu/sector_dpram.v` (output of the Gowin IP generator via
MiSTeryNano, with Gowin's header). The menu `menu.xml`, which goes into the
bitstream byte for byte, carries no header. The wiring drawing `docs/wiring_pico.svg` is a Fritzing
export and CC BY-SA 3.0 like Fritzing's breadboard graphics in it. Not ours: the ten HDMI files (MIT OR
Apache-2.0, the notice in `src/hdmi/LICENSE`), `sdram_fb.v` (GPL-3.0, a derivative of NESTang,
both copyright notices in its header) and, kept with their original headers, the T80 cores
(BSD-style), MikeJ's Pac-Man core (BSD-style), Dar's Galaga core, WangXuan95's SD card reader
(GPL-3.0) and Till Harbaum's MiSTeryNano and Nanomig files.
[THIRD-PARTY.md](THIRD-PARTY.md) explains what that means, on what terms the bitstreams are
published and what the NOTICE files of the firmware image and of the bitstreams cover.
The files we add to the Companion (`src/ra_*.c/.h`, `ra_ca.h`, `game20k_mbedtls_config.h`) live
in the fork under Apache-2.0 like the Companion.

Where one of our own files contains no code from others, it can be made available under another
licence on request, file by file. Ask in an issue.

## Author and contact

scullymi (GitHub). Questions, bugs, build reports and licence requests as issues in this
repository.
