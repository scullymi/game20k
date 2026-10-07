# jotego's Pang core

The files under this folder are copied from
[jotego/jtcores](https://github.com/jotego/jtcores) at commit
`548b87b32a1b528a16cb41f689accb179e85d1a8` (4 October 2026), with the folder layout of the
repository kept, so `cores/pang/hdl/jtpang_main.v` here is `cores/pang/hdl/jtpang_main.v` there.
Only the files the game needs are copied: the game itself (`cores/pang/hdl`, without
`jtpang_game.v`, whose part `../game_core.sv` takes) and the parts of JTFRAME it instantiates
(`modules/jtframe/hdl`), among them the T80 CPU. JTFRAME's own frame is not used: the platform
under `fpga/common` takes its place.

The sound chips and the EEPROM come from jotego's jtopl, jt6295 and jteeprom, see the
README.md in `../jtopl`, `../jt6295` and `../jteeprom`.

| Folder | Author | Licence | Changed here |
|---|---|---|---|
| `cores/pang/hdl` | Jose Tejada Gomez (jotego) | GPL-3.0-or-later | `jtpang_main.v`, see below |
| `modules/jtframe/hdl` (without `cpu/t80`) | Jose Tejada Gomez | GPL-3.0-or-later | `ram/jtframe_dual_ram.v`, `cpu/jtframe_z80wait.v`, see below |
| `modules/jtframe/hdl/cpu/t80` | Daniel Wallner, later changes by MikeJ, Sorgelig and others | BSD-style, see the file heads | no |

The upstream files keep their headers. For simulation, `../../sim/run_sim.sh` fetches the
Verilog T80 (`T80s.v`, no licence header) from the same commit, as the 1942 core does.

## What changed, and why

Every change is marked `game20k` in the text.

- **`cores/pang/hdl/jtpang_main.v`:** without `jtframe_kabuki`. `scripts/make_rom.py` decrypts
  the program ahead into a data and an opcode image (`kabuki=` sections of `../../pang.manifest`),
  so the ROM byte goes to the CPU as it is and `rom_m1` tells `../game_core.sv` which image to
  read. The VRAM wait block, which sets `cen_haltn` to 1 in every branch and so never stops the
  CPU, is left out. Taps for the RAM mirror: the address and output of the work RAM's second
  port, and its write strobe and address.
- **`modules/jtframe/hdl/ram/jtframe_dual_ram.v`:** Gowin's normal write mode, as in the 1942
  core (the upstream text is the same at both commits): the read-before-write form maps to a
  block RAM mode the GW2AR-18C place and route rejects (PA2122).
- **`modules/jtframe/hdl/cpu/jtframe_z80wait.v`:** with `GAME20K_Z80_GAP` defined
  (`../jtpang_defs.v`), the CPU's clock enables stay at least that many clocks apart. The
  upstream recovery of enables lost to ROM waits can put one 2 clocks after the previous. At
  37.125 MHz with an 8 MHz CPU that is too early for a RAM byte, and Pang read a wrong return
  address from its stack. jotego warns about the recovery at 48 MHz and 8 MHz.

## Checking the copy

```sh
git clone --filter=blob:none --sparse https://github.com/jotego/jtcores.git /tmp/jtcores
git -C /tmp/jtcores checkout 548b87b32a1b528a16cb41f689accb179e85d1a8
git -C /tmp/jtcores sparse-checkout set cores/pang modules/jtframe/hdl
cd fpga/pang_hdmi/src/jtcores
for f in $(find . -type f ! -name README.md); do cmp -s "$f" "/tmp/jtcores/$f" || echo "differs: $f"; done
```

It lists exactly the three changed files.
