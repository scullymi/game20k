# MiSTer-X's Dig Dug core

The files under this folder are copied from
[MiSTer-devel/Arcade-DigDug_MiSTer](https://github.com/MiSTer-devel/Arcade-DigDug_MiSTer) at
commit `3022bcc3e18b0284b9473f1e0d45c136e676e5c9` (1 July 2026), folder `rtl/`, with the folder
layout kept. `LICENSE` is the licence file at the root of that repository. The original
author's repository is [MrX-8B/MiSTer-Arcade-DigDug](https://github.com/MrX-8B/MiSTer-Arcade-DigDug).

| File | Author | Licence | Changed here |
|---|---|---|---|
| `FPGA_DIGDUG.v`, `DIGDUG_CORES.v`, `DIGDUG_IODEV.v`, `DIGDUG_VIDEO.v`, `DIGDUG_SPRITE.v`, `HVGEN.v`, `dprams.v`, `wsg.v` | MiSTer-X, "Copyright (c) 2017 MiSTer-X" in the head | GPL-3.0 by the repository's `LICENSE`, the files carry no licence text | yes, see below |
| `cpucore.v` | not stated, the file has no head | GPL-3.0 by the repository's `LICENSE` | yes |
| `cpu/tv80_alu.v`, `cpu/tv80_core.v`, `cpu/tv80_mcode.v`, `cpu/tv80_reg.v` | Guy Hutchison, based on the VHDL T80 by Daniel Wallner | MIT, in each head | no |
| `cpu/tv80s.v` | Guy Hutchison | MIT, in the head | yes, a clock enable |

`LICENSE` is the text of the GPL version 3 and says neither "only" nor "or later". Not copied:
`DIGDUG_CUSIO.v` (replaced by our `fpga/common/src/namco/namco_io.sv`), `hiscore.v`,
`pause.v`, `pll.v` and `pll/` (Altera), `dpram.v` (Jim Gregory, GPL-3.0-or-later, the line
buffer is written in `dprams.v` instead).

## What changed, and why

Every change is marked `game20k` in the text. The heads of the changed files sum up their
changes.

- **One clock.** The derived clocks (`CLK24M`, `CLK12M`, the three CPU clocks, `VCLK`,
  `VCLKx2`, `PCLK`, the WSG clocks) are enables of `MCLK`, high in the clock in which the old
  clock had its edge. The paths on the inverted `MCLK` (sprite RAM ports, sprite ROM, line
  buffer write) stay as they are. This touches every changed file.
- **`tv80s.v`:** input `cen`, also for its bus signals.
- **`cpucore.v`, `DIGDUG_CORES.v`, `FPGA_DIGDUG.v`:** the program of CPU0 comes from outside
  (`CPU0_ROM*`, read from SDRAM by `../game_core.sv`). `ROMWAIT` holds CPU0 in wait states
  until the byte is there. `rom0` is gone.
- **`dprams.v`:** the CPU ports write in Gowin's normal mode, port 1 of `DPR2K` only reads, and
  the line buffer is a simple dual-port memory whose clear goes through the write port. The
  GW2AR-18C place and route rejects a dual-port block in read-before-write mode (PA2122).
- **`DIGDUG_SPRITE.v`:** `radr0` and `radr1` are declared before their first use (Gowin
  EX3638). `PV` is held for the whole sprite pass: with the shorter line of `HVGEN.v`, sprites
  drawn after `POSV` moved on at `POSH` 504 landed one line off.
- **`HVGEN.v`:** raster 360 x 264 instead of 384 x 263, so that a frame fits the HDMI timing of
  the platform.
- **`wsg.v`:** the 96 kHz divider is set for the platform's clock.
- **`DIGDUG_IODEV.v`:** the custom I/O is the Namco 06XX with the 51XX and 53XX running their
  own programs (`namco_io` and `namco_prom2` in `fpga/common/src/namco/`) instead of
  `DIGDUG_CUSIO`. The programs come with the ROM image. The control latch also drives the mode
  inputs of the 53XX and the reset of both MCUs. The sound CPU's NMI comes in raster lines 64
  and 192 as on the board and in MAME, instead of from a 120 Hz oscillator tuned to 48 MHz.
  No hiscore port.
- **`FPGA_DIGDUG.v`:** write taps of the four shared RAMs for the RetroAchievements RAM mirror,
  and one write strobe per CPU write for the 06XX. No hiscore port.

## Checking the copy

```sh
git clone https://github.com/MiSTer-devel/Arcade-DigDug_MiSTer.git /tmp/Arcade-DigDug_MiSTer
git -C /tmp/Arcade-DigDug_MiSTer checkout 3022bcc3e18b0284b9473f1e0d45c136e676e5c9
cd fpga/digdug_hdmi/src/rtl_digdug
cmp LICENSE /tmp/Arcade-DigDug_MiSTer/LICENSE
for f in $(find . -type f ! -name README.md ! -name LICENSE); do cmp -s "$f" "/tmp/Arcade-DigDug_MiSTer/rtl/$f" || echo "differs: $f"; done
```

It lists the ten changed files. The four other TV80 files are byte for byte the upstream ones.
