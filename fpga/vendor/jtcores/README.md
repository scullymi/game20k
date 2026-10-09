# jotego's jtcores: 1942, 1943, Ghosts'n Goblins and Pang

The files under this folder are copied from
[jotego/jtcores](https://github.com/jotego/jtcores) at commit
`548b87b32a1b528a16cb41f689accb179e85d1a8` (4 October 2026), with the folder layout of the
repository kept, so `cores/1942/hdl/jt1942_game.v` here is `cores/1942/hdl/jt1942_game.v` there.
Only the files the four games need are copied: the games themselves (`cores/1942/hdl`,
`cores/1943/hdl`, `cores/gng/hdl`, `cores/pang/hdl`) and the parts of JTFRAME they instantiate
(`modules/jtframe/hdl`), among them the T80 and the 6809 CPU. 1942 and 1943 share modules with
Ghosts'n Goblins from `cores/gng/hdl`. Each core's `build.tcl` lists the files it uses:
`fpga/g1942_hdmi`, `fpga/g1943_hdmi`, `fpga/gng_hdmi` and `fpga/pang_hdmi`.

Not copied: `cores/pang/hdl/jtpang_game.v`, whose part `fpga/pang_hdmi/src/game_core.sv` takes,
and the protection MCU of 1943 (`cores/trojan/hdl/jttrojan_mcu.v` with JTFRAME's i8751,
`jtframe_8751mcu.v`): with `JT1943_MCU_HLE`, set in `fpga/g1943_hdmi/src/jt1943_defs.v`,
`jt1943_security.v` answers the main CPU from a table instead. JTFRAME's own frame (SDRAM
controller, download, OSD, scan doubler) is not used: the platform under `fpga/common` takes its
place, and each core's `src/game_core.sv` connects the two.

The sound chips and the EEPROM come from jotego's jt12, jt49, jtopl, jt6295 and jteeprom, see
the README.md in `../jt12`, `../jt49`, `../jtopl`, `../jt6295` and `../jteeprom`.

| Folder | Author | Licence | Changed here |
|---|---|---|---|
| `cores/1942/hdl` | Jose Tejada Gomez (jotego) | GPL-3.0-or-later | `jt1942_obj.v`, `jt1942_main.v`, `jt1942_sound.v`, `jt1942_game.v`, `jt1942_colmix.v`, `jt1942_video.v`, see below |
| `cores/1943/hdl` | Jose Tejada Gomez | GPL-3.0-or-later | `jt1943_main.v`, `jt1943_game.v`, `jt1943_colmix.v`, `jt1943_video.v`, see below |
| `cores/gng/hdl` | Jose Tejada Gomez | GPL-3.0-or-later | `jtgng_game.v`, `jtgng_main.v`, `jtgng_sound.v`, see below |
| `cores/pang/hdl` | Jose Tejada Gomez | GPL-3.0-or-later | `jtpang_main.v`, see below |
| `modules/jtframe/hdl` (without `cpu/t80` and `cpu/mc6809i.v`) | Jose Tejada Gomez | GPL-3.0-or-later | `ram/jtframe_dual_ram.v`, `cpu/jtframe_z80wait.v`, see below |
| `modules/jtframe/hdl/cpu/t80` | Daniel Wallner, later changes by MikeJ, Sorgelig and others | BSD-style, see the file heads | no |
| `modules/jtframe/hdl/cpu/mc6809i.v` | Greg Miller, changes by Jose Tejada Gomez | BSD-style, see below | no |

The upstream files keep their headers, except the two port lists in `modules/jtframe/hdl/inc`,
which have none upstream. The T80 licence asks for the copyright notice in the documentation of a
synthesized form, which [THIRD-PARTY.md](../../../THIRD-PARTY.md) gives.

`modules/jtframe/hdl/cpu/mc6809i.v` is jotego's changed copy of `mc6809i.v` from
[cavnex/mc6809](https://github.com/cavnex/mc6809). It carries only the line "Copyright (c)
2016, Greg Miller". `mc6809i_LICENSE.md` beside it is the author's licence file,
`documentation/LICENSE.md` of cavnex/mc6809 at `17e94a6`, not part of jtcores. It offers a
standard BSD licence and a binary-only variant that forbids passing on the source. This copy
uses the standard BSD licence.

For simulation with Verilator, which reads no VHDL, JTFRAME has a Verilog translation of the
T80, `modules/jtframe/hdl/cpu/t80/T80s.v`. It carries no licence header, so it is not copied
here: each core's `sim/run_sim.sh` fetches it from the same jtcores commit and checks its git
blob hash.

## What changed, and why

Every change is marked `game20k` in the text.

- **`modules/jtframe/hdl/ram/jtframe_dual_ram.v`** (all four games): both RAM processes read
  only when they do not write (Gowin's normal write mode). Upstream reads before it writes,
  which Gowin maps to a dual-port block RAM in read-before-write mode, and the place and route
  for the GW2AR-18C rejects that (error PA2122). During a write the output now holds its last
  value instead of the old content of the written address. In 1942 only the CPU side of these
  RAMs writes, and the CPU does not read in the same cycle. In 1943 the CPUs do not read in the
  cycle they write, and the sprite line buffer (`jtgng_objbuf.v`) takes each pixel before it
  clears it.
- **`modules/jtframe/hdl/cpu/jtframe_z80wait.v`** (Pang): with `GAME20K_Z80_GAP` defined
  (`fpga/pang_hdmi/src/jtpang_defs.v`), the CPU's clock enables stay at least that many clocks
  apart. The upstream recovery of enables lost to ROM waits can put one 2 clocks after the
  previous. At 37.125 MHz with an 8 MHz CPU that is too early for a RAM byte, and Pang read a
  wrong return address from its stack. jotego warns about the recovery at 48 MHz and 8 MHz. The
  other games do not define the macro and get the upstream logic.
- **`cores/1942/hdl/jt1942_obj.v`:** `wire LHBL_eff` moved above its first use. Upstream uses
  the net before declaring it, Gowin warns with EX3638, and `scripts/fpga_report.sh` fails a
  build on that warning because it usually means a second, undriven net. Here both are one bit
  wide and the same net, so nothing changes in the logic, but the check stays strict.
- **`cores/1942/hdl/jt1942_main.v`, `jt1942_sound.v`, `jt1942_game.v`:** taps for the RAM
  mirror of RetroAchievements (`fpga/g1942_hdmi/src/g1942_mirror.sv`). jt1942_main brings out
  the write strobe of its main RAM, jt1942_sound the write strobe, address and data of its sound
  RAM, and jt1942_game passes these out together with the main CPU's bus and chip selects, which
  it already has as wires. The extra ports are in `fpga/g1942_hdmi/src/inc/mem_ports.inc`.
  Outputs only, the logic of the game is unchanged.
- **`cores/1942/hdl/jt1942_colmix.v`, `jt1942_video.v`, `jt1942_game.v`:** the palette index
  of each pixel as an extra output, `pal_idx`. jt1942_colmix delays it like the colour (a
  register like the PROM output, then a second `jtframe_blank`), jt1942_video and jt1942_game
  pass it out. `game_core.sv` sends the index instead of the colour, and the platform applies
  the colour PROMs after its frame buffer, which keeps 8 bits a pixel. Outputs only.
- **`cores/gng/hdl/jtgng_sound.v`** (1943, Ghosts'n Goblins): the local reset of the sound board
  (sound CPU and both YM2203) is registered on the rising instead of the falling clock edge. On
  the falling edge the reset path into the T80 has only half a clock, which fails timing on the
  GW2AR-18C. A reset that comes half a clock later changes nothing in the game.
- **`cores/1943/hdl/jt1943_main.v`, `jt1943_game.v`:** taps for the RAM mirror of
  RetroAchievements (`fpga/g1943_hdmi/src/g1943_mirror.sv`). jt1943_main brings out the write
  strobe of its main RAM, jt1943_game passes it out together with the main CPU's address and
  data bus. The extra ports are in `fpga/g1943_hdmi/src/inc/mem_ports.inc`. Outputs only, the
  logic of the game is unchanged.
- **`cores/1943/hdl/jt1943_colmix.v`, `jt1943_video.v`, `jt1943_game.v`:** the palette index
  of each pixel as an extra output, `pal_idx`. jt1943_colmix registers it with the same enable
  and blanking as the colour, jt1943_video and jt1943_game pass it out. `game_core.sv` sends
  the index instead of the colour, and the platform applies the colour PROMs after its frame
  buffer, which keeps 8 bits a pixel. Outputs only.
- **`cores/1943/hdl/jt1943_game.v`:** the sound ROM is read from SDRAM. Upstream it sits in
  block RAM, so `rom_cs` of the sound CPU is left open and `rom_ok` is tied to 1. Here both go
  to the game's ports `snd_cs` and `snd_ok`, and the sound CPU waits for its data like the main
  CPU.
- **`cores/gng/hdl/jtgng_game.v`:** `cen6`, `cen3` and `cen1p5` come in as ports (declared in
  `fpga/gng_hdmi/src/inc/mem_ports.inc`) instead of from `jtframe_cen48`, which expects a
  48 MHz clock. `jtframe_cen48` is left out.
- **`cores/gng/hdl/jtgng_main.v`, `jtgng_game.v`:** taps for the RAM mirror of
  RetroAchievements (`fpga/gng_hdmi/src/mirror_n.sv`). jtgng_main brings out the write strobe
  of its work RAM (`mir_we`), jtgng_game passes it out together with the CPU's address and data
  bus. Outputs only, the logic of the game is unchanged.
- **`cores/pang/hdl/jtpang_main.v`:** without `jtframe_kabuki`. `scripts/make_rom.py` decrypts
  the program ahead into a data and an opcode image (`kabuki=` sections of
  `fpga/pang_hdmi/pang.manifest`), so the ROM byte goes to the CPU as it is and `rom_m1` tells
  `game_core.sv` which image to read. The VRAM wait block, which sets `cen_haltn` to 1 in every
  branch and so never stops the CPU, is left out. Taps for the RAM mirror: the address and
  output of the work RAM's second port, and its write strobe and address.

1943 turns its picture by 180 degrees with jotego's `dip_flip` input, which its `game_core.sv`
sets. That needs no change here.

## Checking the copy

Every file not named above is byte for byte the upstream file. To check:

```sh
git clone --filter=blob:none --sparse https://github.com/jotego/jtcores.git /tmp/jtcores
git -C /tmp/jtcores checkout 548b87b32a1b528a16cb41f689accb179e85d1a8
git -C /tmp/jtcores sparse-checkout set cores/1942 cores/1943 cores/gng cores/pang modules/jtframe/hdl
cd fpga/vendor/jtcores
for f in $(find . -type f ! -name README.md ! -name mc6809i_LICENSE.md); do cmp -s "$f" "/tmp/jtcores/$f" || echo "differs: $f"; done
```

It lists exactly the changed files named above.
