# jotego's 1943 core

The files under this folder are copied from
[jotego/jtcores](https://github.com/jotego/jtcores) at commit
`548b87b32a1b528a16cb41f689accb179e85d1a8` (4 October 2026), with the folder layout of the
repository kept, so `cores/1943/hdl/jt1943_game.v` here is `cores/1943/hdl/jt1943_game.v` there.
Only the files the 1943 game needs are copied: the game itself (`cores/1943/hdl`), twelve modules
it shares with Ghosts'n Goblins (`cores/gng/hdl`) and the parts of JTFRAME it instantiates
(`modules/jtframe/hdl`), among them the T80 CPU. The protection MCU
(`cores/trojan/hdl/jttrojan_mcu.v` with JTFRAME's i8751, `jtframe_8751mcu.v`) is not copied:
with `JT1943_MCU_HLE`, set in `../jt1943_defs.v`, `jt1943_security.v` answers the main CPU from
a table instead. JTFRAME's own frame (SDRAM controller, download, OSD, scan doubler) is not
used: the platform under `fpga/common` takes its place, and `../game_core.sv` connects the two.

The sound chips come from [jotego/jt12](https://github.com/jotego/jt12), see `../jt12/README.md`,
and [jotego/jt49](https://github.com/jotego/jt49), see `../jt49/README.md`.

| Folder | Author | Licence | Changed here |
|---|---|---|---|
| `cores/1943/hdl` | Jose Tejada Gomez (jotego) | GPL-3.0-or-later | `jt1943_main.v`, `jt1943_game.v`, `jt1943_colmix.v`, `jt1943_video.v`, see below |
| `cores/gng/hdl` | Jose Tejada Gomez | GPL-3.0-or-later | `jtgng_sound.v`, see below |
| `modules/jtframe/hdl` (without `cpu/t80`) | Jose Tejada Gomez | GPL-3.0-or-later | `ram/jtframe_dual_ram.v`, see below |
| `modules/jtframe/hdl/cpu/t80` | Daniel Wallner, later changes by MikeJ, Sorgelig and others | BSD-style, see the file heads | no |

The upstream files keep their headers, except the two port lists in `modules/jtframe/hdl/inc`,
which have none upstream. The T80 licence asks for the copyright notice in the documentation of a
synthesized form, which [THIRD-PARTY.md](../../../../THIRD-PARTY.md) gives.

For simulation with Verilator, which reads no VHDL, JTFRAME has a Verilog translation of the
T80, `modules/jtframe/hdl/cpu/t80/T80s.v`. It carries no licence header, so it is not copied
here: `../../sim/run_sim.sh` fetches it from the same jtcores commit and checks its git blob
hash.

## What changed, and why

Every change is marked `game20k` in the text.

- **`modules/jtframe/hdl/ram/jtframe_dual_ram.v`:** the same file as in the
  [1942 core](../../../g1942_hdmi/src/jtcores/README.md): both RAM processes read only when
  they do not write, because the place and route for the GW2AR-18C rejects the
  read-before-write mode (PA2122). During a write the output holds its last value. In 1943 the
  CPUs do not read in the cycle they write, and the sprite line buffer (`jtgng_objbuf.v`) takes
  each pixel before it clears it.
- **`cores/gng/hdl/jtgng_sound.v`:** the local reset of the sound board (sound CPU and both
  YM2203) is registered on the rising instead of the falling clock edge. On the falling edge
  the reset path into the T80 has only half a clock, which fails timing on the GW2AR-18C. A
  reset that comes half a clock later changes nothing in the game.
- **`cores/1943/hdl/jt1943_main.v`, `jt1943_game.v`:** taps for the RAM mirror of
  RetroAchievements (`../g1943_mirror.sv`). jt1943_main brings out the write strobe of its main
  RAM, jt1943_game passes it out together with the main CPU's address and data bus. The extra
  ports are in our `../inc/mem_ports.inc`. Outputs only, the logic of the game is unchanged.
- **`cores/1943/hdl/jt1943_colmix.v`, `jt1943_video.v`, `jt1943_game.v`:** the palette index
  of each pixel as an extra output, `pal_idx`. jt1943_colmix registers it with the same enable
  and blanking as the colour, jt1943_video and jt1943_game pass it out. `../game_core.sv` sends
  the index instead of the colour, and the platform applies the colour PROMs after its frame
  buffer, which keeps 8 bits a pixel. Outputs only.
- **`cores/1943/hdl/jt1943_game.v`:** the sound ROM is read from SDRAM. Upstream it sits in
  block RAM, so `rom_cs` of the sound CPU is left open and `rom_ok` is tied to 1. Here both go
  to the game's ports `snd_cs` and `snd_ok`, and the sound CPU waits for its data like the main
  CPU.

The picture is turned by 180 degrees with jotego's `dip_flip` input, which `../game_core.sv`
sets. That needs no change here.

## Checking the copy

Every file not named above is byte for byte the upstream file. To check:

```sh
git clone --filter=blob:none --sparse https://github.com/jotego/jtcores.git /tmp/jtcores
git -C /tmp/jtcores checkout 548b87b32a1b528a16cb41f689accb179e85d1a8
git -C /tmp/jtcores sparse-checkout set cores/1943 cores/gng modules/jtframe/hdl
cd fpga/g1943_hdmi/src/jtcores
for f in $(find . -type f ! -name README.md); do cmp -s "$f" "/tmp/jtcores/$f" || echo "differs: $f"; done
```

It lists exactly the six changed files.
