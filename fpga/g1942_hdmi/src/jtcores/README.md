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
| `cores/1942/hdl` | Jose Tejada Gomez (jotego) | GPL-3.0-or-later | `jt1942_obj.v`, see below |
| `cores/gng/hdl` | Jose Tejada Gomez | GPL-3.0-or-later | no |
| `modules/jtframe/hdl` (without `cpu/t80`) | Jose Tejada Gomez | GPL-3.0-or-later | `ram/jtframe_dual_ram.v`, see below |
| `modules/jtframe/hdl/cpu/t80` | Daniel Wallner, later changes by MikeJ, Sorgelig and others | BSD-style, see the file heads | no |

The upstream files keep their headers. The T80 licence asks for the copyright notice in the
documentation of a synthesized form, which [THIRD-PARTY.md](../../../../THIRD-PARTY.md) gives.

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

## Checking the copy

Every file not named above is byte for byte the upstream file. To check:

```sh
git clone --filter=blob:none --sparse https://github.com/jotego/jtcores.git /tmp/jtcores
git -C /tmp/jtcores checkout 0b197caeae1596380863b8388552b125e7e1b208
git -C /tmp/jtcores sparse-checkout set cores/1942 cores/gng modules/jtframe/hdl
cd fpga/g1942_hdmi/src/jtcores
for f in $(find . -type f ! -name README.md); do cmp -s "$f" "/tmp/jtcores/$f" || echo "differs: $f"; done
```

It lists exactly the two changed files.
