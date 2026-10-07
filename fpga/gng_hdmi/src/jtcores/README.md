# jotego's Ghosts'n Goblins core

The files under this folder are copied from
[jotego/jtcores](https://github.com/jotego/jtcores) at commit
`548b87b32a1b528a16cb41f689accb179e85d1a8` (4 October 2026), with the folder layout of the
repository kept, so `cores/gng/hdl/jtgng_game.v` here is `cores/gng/hdl/jtgng_game.v` there.
Only the files the game needs are copied: the game itself (`cores/gng/hdl`) and the parts of
JTFRAME it instantiates (`modules/jtframe/hdl`), among them the T80 and the 6809 CPU. JTFRAME's
own frame (SDRAM controller, download, OSD, scan doubler) is not used: the platform under
`fpga/common` takes its place, and `../game_core.sv` connects the two.

The sound chips come from [jotego/jt12](https://github.com/jotego/jt12), see `../jt12/README.md`,
and [jotego/jt49](https://github.com/jotego/jt49), see `../jt49/README.md`.

| Folder | Author | Licence | Changed here |
|---|---|---|---|
| `cores/gng/hdl` | Jose Tejada Gomez (jotego) | GPL-3.0-or-later | `jtgng_game.v`, `jtgng_main.v`, `jtgng_sound.v`, see below |
| `modules/jtframe/hdl` (without `cpu/t80` and `cpu/mc6809i.v`) | Jose Tejada Gomez | GPL-3.0-or-later | `ram/jtframe_dual_ram.v`, see below |
| `modules/jtframe/hdl/cpu/t80` | Daniel Wallner, later changes by MikeJ, Sorgelig and others | BSD-style, see the file heads | no |
| `modules/jtframe/hdl/cpu/mc6809i.v` | Greg Miller, changes by Jose Tejada Gomez | BSD-style, see below | no |

The upstream files keep their headers, except the two port lists in `modules/jtframe/hdl/inc`,
which have none upstream. The T80 licence asks for the copyright notice in the documentation of a
synthesized form, which [THIRD-PARTY.md](../../../../THIRD-PARTY.md) gives.

`modules/jtframe/hdl/cpu/mc6809i.v` is jotego's changed copy of `mc6809i.v` from
[cavnex/mc6809](https://github.com/cavnex/mc6809). It carries only the line "Copyright (c)
2016, Greg Miller". `mc6809i_LICENSE.md` beside it is the author's licence file,
`documentation/LICENSE.md` of cavnex/mc6809 at `17e94a6`, not part of jtcores. It offers a
standard BSD licence and a binary-only variant that forbids passing on the source. This copy
uses the standard BSD licence.

For simulation with Verilator, which reads no VHDL, `../../sim/run_sim.sh` fetches JTFRAME's
Verilog T80, `modules/jtframe/hdl/cpu/t80/T80s.v` (no licence header), from the same jtcores
commit and checks its git blob hash, as the 1943 core does.

## What changed, and why

Every change is marked `game20k` in the text.

- **`modules/jtframe/hdl/ram/jtframe_dual_ram.v`:** the same file as in the
  [1943 core](../../../g1943_hdmi/src/jtcores/README.md): both RAM processes read only when they
  do not write, because the place and route for the GW2AR-18C rejects the read-before-write
  mode (PA2122). During a write the output holds its last value.
- **`cores/gng/hdl/jtgng_sound.v`:** the local reset of the sound board is registered on the
  rising instead of the falling clock edge, as in the 1943 core. On the falling edge the reset
  path into the T80 has only half a clock, which fails timing on the GW2AR-18C.
- **`cores/gng/hdl/jtgng_game.v`:** `cen6`, `cen3` and `cen1p5` come in as ports (declared in
  `../inc/mem_ports.inc`) instead of from `jtframe_cen48`, which expects a 48 MHz clock.
  `jtframe_cen48` is left out.
- **`cores/gng/hdl/jtgng_main.v`, `jtgng_game.v`:** taps for the RAM mirror of
  RetroAchievements (`../mirror_n.sv`). jtgng_main brings out the write strobe of its work RAM
  (`mir_we`), jtgng_game passes it out together with the CPU's address and data bus. Outputs
  only, the logic of the game is unchanged.

## Checking the copy

Every other file is byte for byte the upstream file. To check:

```sh
git clone --filter=blob:none --sparse https://github.com/jotego/jtcores.git /tmp/jtcores
git -C /tmp/jtcores checkout 548b87b32a1b528a16cb41f689accb179e85d1a8
git -C /tmp/jtcores sparse-checkout set cores/gng modules/jtframe/hdl
cd fpga/gng_hdmi/src/jtcores
for f in $(find . -type f ! -name README.md ! -name mc6809i_LICENSE.md); do cmp -s "$f" "/tmp/jtcores/$f" || echo "differs: $f"; done
```

It lists exactly the four changed files.
