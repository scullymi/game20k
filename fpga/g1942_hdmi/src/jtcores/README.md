# jotego's 1942 core

The files under this folder are copied from
[jotego/jtcores](https://github.com/jotego/jtcores) at commit
`0b197caeae1596380863b8388552b125e7e1b208` (28 September 2026), with the folder layout of the
repository kept, so `cores/1942/hdl/jt1942_game.v` here is `cores/1942/hdl/jt1942_game.v` there.
Only the files the 1942 game needs are copied: the game itself (`cores/1942/hdl`), six modules
it shares with Ghosts'n Goblins (`cores/gng/hdl`) and the parts of JTFRAME it instantiates
(`modules/jtframe/hdl`), among them the T80 CPU. JTFRAME's own frame (SDRAM controller,
download, OSD, scan doubler) is not used: the platform under `fpga/common` takes its place, and
`../game_core.sv` connects the two.

The sound chips come from [jotego/jt49](https://github.com/jotego/jt49), see `../jt49/README.md`.

| Folder | Author | Licence | Changed here |
|---|---|---|---|
| `cores/1942/hdl` | Jose Tejada Gomez (jotego) | GPL-3.0-or-later | `jt1942_obj.v`, `jt1942_main.v`, `jt1942_sound.v`, `jt1942_game.v`, `jt1942_colmix.v`, `jt1942_video.v`, see below |
| `cores/gng/hdl` | Jose Tejada Gomez | GPL-3.0-or-later | no |
| `modules/jtframe/hdl` (without `cpu/t80`) | Jose Tejada Gomez | GPL-3.0-or-later | `ram/jtframe_dual_ram.v`, see below |
| `modules/jtframe/hdl/cpu/t80` | Daniel Wallner, later changes by MikeJ, Sorgelig and others | BSD-style, see the file heads | no |

The upstream files keep their headers. The T80 licence asks for the copyright notice in the
documentation of a synthesized form, which [THIRD-PARTY.md](../../../../THIRD-PARTY.md) gives.

For simulation with Verilator, which reads no VHDL, JTFRAME has a Verilog translation of the
T80, `modules/jtframe/hdl/cpu/t80/T80s.v`. It carries no licence header, so it is not copied
here: `../../sim/run_sim.sh` fetches it from the same jtcores commit and checks its git blob
hash.

## What changed, and why

Every change is marked `game20k` in the text.

- **`modules/jtframe/hdl/ram/jtframe_dual_ram.v`:** both RAM processes read only when they do
  not write (Gowin's normal write mode). Upstream reads before it writes, which Gowin maps to a
  dual-port block RAM in read-before-write mode, and the place and route for the GW2AR-18C
  rejects that (error PA2122). During a write the output now holds its last value instead of
  the old content of the written address. In 1942 only the CPU side of these RAMs writes, and
  the CPU does not read in the same cycle.
- **`cores/1942/hdl/jt1942_obj.v`:** `wire LHBL_eff` moved above its first use. Upstream uses
  the net before declaring it, Gowin warns with EX3638, and `scripts/fpga_report.sh` fails a
  build on that warning because it usually means a second, undriven net. Here both are one bit
  wide and the same net, so nothing changes in the logic, but the check stays strict.
- **`cores/1942/hdl/jt1942_main.v`, `jt1942_sound.v`, `jt1942_game.v`:** taps for the RAM
  mirror of RetroAchievements (`../g1942_mirror.sv`). jt1942_main brings out the write strobe
  of its main RAM, jt1942_sound the write strobe, address and data of its sound RAM, and
  jt1942_game passes these out together with the main CPU's bus and chip selects, which it
  already has as wires. The extra ports are in our `../inc/mem_ports.inc`. Outputs only, the
  logic of the game is unchanged.
- **`cores/1942/hdl/jt1942_colmix.v`, `jt1942_video.v`, `jt1942_game.v`:** the palette index
  of each pixel as an extra output, `pal_idx`. jt1942_colmix delays it like the colour (a
  register like the PROM output, then a second `jtframe_blank`), jt1942_video and jt1942_game
  pass it out. `../game_core.sv` sends the index instead of the colour, and the platform
  applies the colour PROMs after its frame buffer, which keeps 8 bits a pixel. Outputs only.

## Checking the copy

Every file not named above is byte for byte the upstream file. To check:

```sh
git clone --filter=blob:none --sparse https://github.com/jotego/jtcores.git /tmp/jtcores
git -C /tmp/jtcores checkout 0b197caeae1596380863b8388552b125e7e1b208
git -C /tmp/jtcores sparse-checkout set cores/1942 cores/gng modules/jtframe/hdl
cd fpga/g1942_hdmi/src/jtcores
for f in $(find . -type f ! -name README.md); do cmp -s "$f" "/tmp/jtcores/$f" || echo "differs: $f"; done
```

It lists exactly the seven changed files.
