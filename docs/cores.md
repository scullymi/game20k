# Cores and boards

How a core, a board and the project are described, and what a new core needs. Paths in each
file are relative to its own folder. The build refuses a key it does not know and names the file
and the key.

## The files

| File | Says |
|---|---|
| [project.toml](../project.toml) | the board and the cores in the configuration flash, in slot order. The FPGA loads the first one at power-on, each core's bitstream names the next one for the core switch. |
| [boards/\<board\>/board.toml](../boards/tangnano20k/board.toml) | the FPGA, its pin files (`.cst`), its block RAMs, the flash size and slot size, and the clock from outside. `FLASHING.txt` in the same folder goes into the release zip. |
| [fpga/common/platform.toml](../fpga/common/platform.toml) | the platform every core shares: the top level `game20k_top` with HDMI, SDRAM, SPI, OSD, SD card and RAM mirror, and its sources. |
| `fpga/<core>/core.toml` ([GnG](../fpga/gng_hdmi/core.toml)) | the core: its name, the platform, the core clock (`hz`), the sources, VHDL entities for GHDL (`[vhdl]`), synthesis options (`[synth]`), and generated files (`[[generate]]`). |
| `fpga/<core>/cells.toml` ([GnG](../fpga/gng_hdmi/cells.toml)) | the cells of the netlist per board. The build compares its netlist with them, see below. |
| `fpga/<core>/<set>.manifest` ([Galaga](../fpga/galaga_hdmi/galaga.manifest)) | one game: which chips of the MAME set go where in the ROM file, the board id, the RAM mirror size, the screen orientation, the files accepted for hardcore, the RetroAchievements id and the DIP switches the set expects. Its head explains the format. |
| `fpga/<core>/menu_core.xml` ([GnG](../fpga/gng_hdmi/menu_core.xml)) | the core's part of the menu: title, files, DIP switches. [fpga/common/menu/base.xml](../fpga/common/menu/base.xml) holds the rest. |
| `fpga/<core>/sim/sim.toml` ([platform](../fpga/common/sim/sim.toml)) | the simulations of a folder, `ci = true` for those the CI runs. [tools/engine/sim.py](../tools/engine/sim.py) describes the keys. |

## What is made from them

- **The bitstream.** `g20k.py build fpga/<core>` reads `core.toml`, the platform and the board,
  runs the `[[generate]]` steps into the build folder, and builds. It stops when a clock misses
  its frequency or the cells differ from `cells.toml`: LUT, DFF and ALU may move by 5 percent,
  every other cell type must match. After a wanted change, `--update-cells` writes the new
  counts.
- **The ROM file and its loader.** `scripts/make_rom.py` builds `sdcard/<set>.rom` from the
  manifest and checks every chip, and writes `rom_map_pkg.sv`, the section table the core's
  ROM loader uses.
- **The firmware's tables.** `scripts/make_fw_tables.py` writes the game table from every
  manifest and the menus from `base.xml` and each `menu_core.xml`. A change to a
  `menu_core.xml` needs a new build of the core and the firmware.

## The core's part

The platform's top level instantiates `game_core` from `fpga/<core>/src/game_core.sv` and imports
`game_pkg` from `fpga/<core>/src/game_pkg.sv`, which holds the raster, the name and the labels of
the input test. The comments at the top of
[game20k_top.sv](../fpga/common/src/game20k_top.sv) describe both. An existing core such as
[pang_hdmi](../fpga/pang_hdmi/) is the best template.

## A new core

1. A folder `fpga/<core>/` with `core.toml`, `src/game_core.sv`, `src/game_pkg.sv`, a manifest
   per set, `menu_core.xml` and a README naming the sources and their licenses. Third-party
   code goes into its own folder with its original headers and an entry in
   [THIRD-PARTY.md](../THIRD-PARTY.md).
2. `python3 g20k.py build fpga/<core>` until it meets its clock, then `--update-cells` once.
3. A slot in `project.toml`. All slots of the board are taken, so the core replaces one or the
   board needs a larger flash.
4. The games on the card: `python3 g20k.py sdcard` builds every set that has a manifest and a
   zip in `roms/`. List the files in [roms/README.md](../roms/README.md) and the game in
   [games.md](games.md).
5. The firmware: build it again, it takes the new game table and menu.
6. The CI builds every core of `project.toml` and runs every simulation with `ci = true`.

## A new board

A folder `boards/<board>/` with `board.toml`, which names its pin files (they may lie in another
board's folder), and `FLASHING.txt`. `--board
boards/<board>` on `build`, `flash` and `release` uses it in place of the one `project.toml`
names. [boards/tangnano20k-singleboard](../boards/tangnano20k-singleboard/) is the Nano without
a Pico, with the Companion on the onboard BL616.
