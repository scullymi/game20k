# MikeJ's Pac-Man core

Five files copied from
[MiSTer-devel/Arcade-Pacman_MiSTer](https://github.com/MiSTer-devel/Arcade-Pacman_MiSTer) at
commit `6b5ccb08145eadb31912b43d53a93ed522ab34b2` (20 July 2026), folder `rtl/`, with the
line ends changed from CRLF to LF. Four further files are ours. The Jr. Pac-Man support in
`pacman.vhd`, `pacman_video.vhd` and `pacman_audio.vhd` is Rodimus Prime's, added upstream in
commit `9bcb0b6` (26 June 2026). The other two files are the same at `648172d`, the commit of
the Z80 in `../rtl_T80`.

| File | Author | Changed here |
|---|---|---|
| `pacman.vhd` | MikeJ, later changes by Alexey Melnikov (Sorgelig), Alan Steremberg and Rodimus Prime | yes, see below |
| `pacman_video.vhd` | MikeJ, later changes by the same three | yes, RAM primitives and the sprite x/y shadow |
| `pacman_audio.vhd` | MikeJ, later changes by the same three | yes, RAM primitives only |
| `pacman_rom_descrambler.vhd` | d18c7db, later changes by Sorgelig | yes, RAM primitives and the second bank |
| `pacman_vram_addr.vhd` | MikeJ and CarlW, later changes by Sorgelig | no |
| `g20k_dpram.vhd` | game20k | new: the dual-port RAM the core uses, in a form Gowin places |
| `pacman_mirror.vhd` | game20k | new: the RAM mirror for RetroAchievements |
| `sn76489_top.vhd`, `ym2149.vhd` | game20k | new: stubs for two sound chips the build never uses |

The upstream files keep their headers: a BSD-style licence with three conditions (source and
synthesized form, the notice in the documentation, no endorsement), see
[THIRD-PARTY.md](../../../../THIRD-PARTY.md). Rodimus Prime's additions carry no copyright line
of their own. The upstream repository has no licence file of its own at its root. The files of
ours carry `SPDX-License-Identifier: GPL-3.0-only`.

Every change in the upstream files is marked `game20k` in the text. The complete record is the
diff against the upstream commit:

```sh
git clone https://github.com/MiSTer-devel/Arcade-Pacman_MiSTer.git /tmp/Arcade-Pacman_MiSTer
git -C /tmp/Arcade-Pacman_MiSTer checkout 6b5ccb08145eadb31912b43d53a93ed522ab34b2
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
- A generic `G_HI_BANK`, default `true`: the second 16 KB program bank for Ms. Pac-Man (8
  block RAMs). Only with `MSPACMAN` does the CPU read it, every other game sees 0x8000 to
  0xBFFF mirror bank 0 as on the Pac-Man board. `false` leaves the bank out.

**Jr. Pac-Man**

- Upstream decrypts Jr. Pac-Man's program while it is downloaded and keeps it in a 64 KB block
  RAM. Here `scripts/make_rom.py` decrypts it ahead with the same table as MAME
  (`decrypt=jrpacman` in `jrpacman.manifest`), and the program stays in SDRAM. `pacman.vhd`
  reads it over the ports `jr_rom_addr`, `jr_rom_cs`, `jr_rom_din` and `jr_rom_ok`, and holds the
  CPU in wait states until the byte is there. The decryption table and the block RAM are left
  out. Marked `game20k`, the rest of the Jr. Pac-Man code is upstream's.

**RAM mirror for RetroAchievements**

- The read port of the 4 KB main RAM is the upstream high score port (`hs_address`,
  `hs_data_out`). The wrapper ties `hs_access_read` and `hs_access_write` to 0: a 1 there drops
  every CPU write to the RAM.
- A second copy of the sprite x/y registers (`sprite_xy_shadow`) with the same writes gives the
  mirror a read port, because the CPU can only write these registers.
- Taps for the mirror: the write strobes of the main RAM, the sprite x/y registers and the flip
  latch, the CPU address and data, the flip bit, and `mir_frame_go`, one pixel per frame at
  which a harvest starts so that it ends at the interrupt edge.
- `pacman_mirror.vhd` copies the bytes FBNeo's "All Ram" holds into a shadow once per frame,
  catches up every game write during the copy, and delivers the shadow in FBNeo's order, with
  zeros in the gaps. With `mod_jr` it uses Jr. Pac-Man's layout, and `mir_frame_go` moves so
  that the longer harvest still ends at the interrupt edge. Its head explains the timing. The
  snapshot is the state at the frame boundary before the interrupt handler runs, the instant
  FBNeo shows to RetroAchievements.
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
