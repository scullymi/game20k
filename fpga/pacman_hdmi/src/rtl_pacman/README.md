# MikeJ's Pac-Man core

Five files copied from
[MiSTer-devel/Arcade-Pacman_MiSTer](https://github.com/MiSTer-devel/Arcade-Pacman_MiSTer) at
commit `648172dec5f9effbfcdc9f4a7897a78b045ea967` (15 September 2021), folder `rtl/`, with the
line ends changed from CRLF to LF. Four further files are ours.

| File | Author | Changed here |
|---|---|---|
| `pacman.vhd` | MikeJ, later changes by Alexey Melnikov (Sorgelig) and Alan Steremberg | yes, see below |
| `pacman_video.vhd` | MikeJ, later changes by the same two | yes, RAM primitives and the sprite x/y shadow |
| `pacman_audio.vhd` | MikeJ, later changes by the same two | yes, RAM primitives only |
| `pacman_rom_descrambler.vhd` | d18c7db, later changes by Sorgelig | yes, RAM primitives and the second bank |
| `pacman_vram_addr.vhd` | MikeJ and CarlW, later changes by Sorgelig | no |
| `g20k_dpram.vhd` | game20k | new: the dual-port RAM the core uses, in a form Gowin places |
| `pacman_mirror.vhd` | game20k | new: the RAM mirror for RetroAchievements |
| `sn76489_top.vhd`, `ym2149.vhd` | game20k | new: stubs for two sound chips the build never uses |

The upstream files keep their headers: a BSD-style licence with three conditions (source and
synthesized form, the notice in the documentation, no endorsement), see
[THIRD-PARTY.md](../../../../THIRD-PARTY.md). The upstream repository has no licence file of its
own at its root. The files of ours carry `SPDX-License-Identifier: GPL-3.0-only`.

Every change in the upstream files is marked `game20k` in the text. The complete record is the
diff against the upstream commit:

```sh
git clone https://github.com/MiSTer-devel/Arcade-Pacman_MiSTer.git /tmp/Arcade-Pacman_MiSTer
git -C /tmp/Arcade-Pacman_MiSTer checkout 648172dec5f9effbfcdc9f4a7897a78b045ea967
for f in pacman pacman_video pacman_audio pacman_rom_descrambler pacman_vram_addr; do
  diff --strip-trailing-cr /tmp/Arcade-Pacman_MiSTer/rtl/$f.vhd fpga/pacman_hdmi/src/rtl_pacman/$f.vhd
done
```

## What changed, and why

**Board and toolchain**

- Every Altera `dpram` instance is replaced by `g20k_dpram`. Port A reads the new value on a
  write (write-through), as the Altera original does. Gowin's place and route rejects a
  dual-port block in read-before-write mode (PA2122).
- The sprite x/y RAM and its shadow copy are LUT RAM (`RAMSTYLE => "distributed_ram"`): with the
  same writes, Gowin would otherwise merge the two into one block in read-before-write mode.
- `library UNISIM` is removed (unused, unknown to Gowin), and instances of the form
  `label : work.X` read `label : entity work.X`.
- A generic `G_HI_BANK`, default `false`: the second 16 KB program bank stays out (8 block
  RAMs), and 0x8000 to 0xBFFF mirror bank 0 as on the Pac-Man board. Ms. Pac-Man needs `true`.

**RAM mirror for RetroAchievements**

- The read port of the 4 KB main RAM is the upstream high score port (`hs_address`,
  `hs_data_out`). The wrapper ties `hs_access_read` and `hs_access_write` to 0: a 1 there drops
  every CPU write to the RAM.
- A second copy of the sprite x/y registers (`sprite_xy_shadow`) with the same writes gives the
  mirror a read port, because the CPU can only write these registers.
- Taps for the mirror: the write strobes of the main RAM, the sprite x/y registers and the flip
  latch, the CPU address and data, the flip bit, and `mir_frame_go`, one pixel per frame at
  which a harvest starts so that it ends at the interrupt edge.
- `pacman_mirror.vhd` copies the 3089 bytes FBNeo's "All Ram" holds into a shadow once per frame,
  catches up every game write during the copy, and delivers the shadow in FBNeo's order, 6272
  bytes with zeros in the gaps. Its head explains the timing. The snapshot is the state at the
  frame boundary before the interrupt handler runs, the instant FBNeo shows to RetroAchievements.
- The flip latch is cleared by the core's watchdog reset without a CPU write. A harvest that
  runs into a reset may deliver the flip bit from before it, the next harvest is right again.

**Sound chips**

- `pacman.vhd` instantiates two SN76489 and a YM2149 for Van Van Car and Dream Shopper. This
  build fixes `mod_van` and `mod_dshop` to 0, so their outputs never reach the sound. The two
  entities are stubs with the upstream port lists and constant outputs. The upstream sources
  (the SN76489 with a GPL-2 `COPYING`, `ym2149.sv`) are not in this repository. A build that
  enables those games gets silence from them.

## Simulation

`fpga/pacman_hdmi/sim/run_sim.sh` runs two testbenches with nvc (VHDL-2008):

- `tb_mirror_unit.vhd`: the mirror alone, with a model of the core's writes and of the platform.
- `tb_pacman.vhd`: the core with the mirror, a Z80 test program loaded through the download
  port, a monitor of every CPU write, and a model of the platform's FIFO and oracle log. It
  checks the window length, every delivered byte against the monitor and against a literal
  table of FBNeo offsets, the oracle log entry by entry, the catch-up in both orders, a header
  probe, a skipped harvest, the picture phase against the scaler, and a reset during a harvest.

The work library goes to the temporary folder, never into this tree.
