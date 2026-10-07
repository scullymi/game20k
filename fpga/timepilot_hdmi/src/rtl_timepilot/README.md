# Ace's Time Pilot core

The files under this folder are copied from
[MiSTer-devel/Arcade-TimePilot_MiSTer](https://github.com/MiSTer-devel/Arcade-TimePilot_MiSTer)
at commit `5a148e2b2a94ddfbcaef4348f4416a4ed15cec7c` (9 December 2025), folder `rtl/`, with the
folder layout kept. `README.upstream.md` is the repository's `README.md`, unchanged: it credits
Ace for the core design and the Konami custom chips, Kitrinx for the ROM loader and jotego for
JT49. The repository has no licence file.

| File | Author | Licence | Changed here |
|---|---|---|---|
| `TimePilot.sv`, `TimePilot_SND.sv`, `custom/k082.sv`, `custom/k501.sv`, `custom/k502.sv`, `custom/k503.sv`, `custom/k526.sv`, `custom/k528.sv` | Ace | MIT, in each head | `TimePilot.sv`, `TimePilot_SND.sv` |
| `TimePilot_CPU.sv` | Ace, Artemio Urbina and RTLEngineering | MIT, in the head | yes |
| `custom/k083.sv` | Ace and ElectronAsh | MIT, in the head | no |
| `ram_rom/rom_loader.sv` | Kitrinx | MIT, in the head | yes |
| `cpu/T80/*.vhd` | Daniel Wallner, later changes by MikeJ, Sorgelig and others | BSD-style, see the file heads | `T80.vhd`, `T80s.vhd` |
| `sound/jt49/hdl/` | Jose Tejada Gomez (jotego), the volume scale changed by Ace according to `README.upstream.md` | GPL-3.0-or-later, in each head | no |
| `jtframe_frac_cen.v` | not stated, the file has no head. An earlier version of a JTFRAME module by jotego, which jtcores carries under GPL-3.0-or-later | none stated | no |
| `ram_rom/spram.vhd` | not stated, the file has no head | none stated | yes |
| `ram_rom/dpram_dc.vhd`, `sound/tp_lpf_sel.sv` | game20k | GPL-3.0-only | ours |

`custom/k526.sv` and `custom/k528.sv` describe the address decoding PLAs of the board (82S153)
as logic, converted from dumps in the PLD Archive, as their heads say. Not copied: `hiscore.v`,
`pause.v`, `pll.v` and `pll/` (Altera), `sound/Filters/` and the `LICENSE` and `README.md` of
`sound/jt49/`.

## What changed, and why

The changes in the Time Pilot files and in `spram.vhd` are marked `game20k` in the text, with
one exception named below. The changes in `T80.vhd`, `T80s.vhd` and `rom_loader.sv` are not
marked, they are listed here.

- **`TimePilot_CPU.sv`, `TimePilot.sv`:** the program ROM (tm1 to tm3) comes from SDRAM over
  the new ports `rom_addr`, `rom_cs`, `rom_din` and `rom_ok`. A read the SDRAM has not answered
  yet holds the Z80 in wait states. The three block RAMs of the program are gone.
- **`TimePilot_CPU.sv`, `TimePilot.sv`:** the Z80 writes into the work RAM go out as `mir_we`,
  `mir_addr` and `mir_data` for the RetroAchievements RAM mirror.
- **`TimePilot_CPU.sv`, `TimePilot_SND.sv`:** the clock dividers count modulo 12 and 384 for
  the platform's 37.125 MHz instead of the original's power-of-two dividers of 49.152 MHz. The
  main CPU then runs 0.7 % fast. The fractional divider for the sound CPU and the two
  AY-3-8910 gets constants for 37.125 MHz, the `underclock` option is not used.
- **`TimePilot_SND.sv`:** one switchable low-pass filter per channel, our `sound/tp_lpf_sel.sv`
  with the coefficients of Ace's three filters, instead of three filters per channel and a
  selection. The board switches capacitors onto one RC node, and three filters per channel
  need more multipliers than the GW2AR-18 has.
- **`TimePilot_CPU.sv`, `TimePilot_SND.sv`:** signals used before their declaration are
  declared at the top (Gowin EX3638), and output ports of instances that upstream ties to a
  constant `Z` go to unused wires. In `TimePilot_SND.sv` `timer_val` is declared as `logic`
  instead of `wire`, without a mark.
- **`ram_rom/spram.vhd`:** the memory is a signal instead of a shared variable, which Gowin
  maps to block RAM.
- **`ram_rom/dpram_dc.vhd`:** our own file with the entity of upstream's Altera `altsyncram`
  wrapper, as an inferred block RAM.
- **`ram_rom/rom_loader.sv`:** in every RAM instance the load side uses port A and the game
  side port B, the other way round from upstream, to fit `dpram_dc.vhd`, whose port B only
  reads.
- **`cpu/T80/T80.vhd`:** in the flag calculation of the block I/O instructions the literal
  `x"7"` is written as `"000000111"`, the width of `ioq`.
- **`cpu/T80/T80s.vhd`:** the T80 is instantiated as `entity work.T80`.

## Checking the copy

```sh
git clone https://github.com/MiSTer-devel/Arcade-TimePilot_MiSTer.git /tmp/Arcade-TimePilot_MiSTer
git -C /tmp/Arcade-TimePilot_MiSTer checkout 5a148e2b2a94ddfbcaef4348f4416a4ed15cec7c
cd fpga/timepilot_hdmi/src/rtl_timepilot
cmp README.upstream.md /tmp/Arcade-TimePilot_MiSTer/README.md
for f in $(find . -type f ! -name 'README*'); do cmp -s "$f" "/tmp/Arcade-TimePilot_MiSTer/rtl/$f" || echo "differs: $f"; done
```

It lists the seven changed files and our two.
