# Dar's Galaga core

Six files by Dar (darfpga@aol.fr), copied from
[DECAfpga/Arcade_Galaga](https://github.com/DECAfpga/Arcade_Galaga) at commit
`e06ba91d713702f8cde229ace2eacd7ad0f89855`, folder `rtl_dar/`. The core's RAMs and the ROMs it
loads at run time are our own files in `src/` (`g20k_spram.vhd`, `g20k_lutram.vhd`,
`g20k_promram.vhd`). The files keep their original headers. `galaga.vhd` and `mb88.vhd` carry
Dar's condition:

```
-- Educational use only
-- Do not redistribute synthetized file with roms
-- Do not redistribute roms whatever the form
-- Use at your own risk
```

There is no licence beyond that condition, see [THIRD-PARTY.md](../../../../THIRD-PARTY.md).
The bitstream built from these files holds no ROM data, the ROMs come from the SD card at run
time.

| File | Author | Changed here |
|---|---|---|
| `galaga.vhd` | Dar | yes, most of the changes below |
| `mb88.vhd` | Dar | yes, one reset |
| `gen_video.vhd` | Dar | yes, a reset input |
| `sound_machine.vhd` | Dar | yes, the load side of the two sound ROMs |
| `stars.vhd`, `stars_machine.vhd` | Dar | no |

Some changes are marked `game20k` in the text, not all. The complete record is the diff against
the upstream commit:

```sh
git clone https://github.com/DECAfpga/Arcade_Galaga.git /tmp/Arcade_Galaga
git -C /tmp/Arcade_Galaga checkout e06ba91d713702f8cde229ace2eacd7ad0f89855
diff -r /tmp/Arcade_Galaga/rtl_dar fpga/galaga_hdmi/src/rtl_dar
```

## What changed, and why

**Board and toolchain**

- The DIP switches come in as ports `dip_a` and `dip_b`, so that the OSD menu can set them at
  run time. The multiplex index is `mux_addr(2 downto 0)` instead of `(3 downto 0)`.
- The character ROM `bg_graphics` reads on the rising edge of `clock_18` (upstream on
  `clock_18n`), with one register stage, so its byte arrives one clock after the address. The
  bit selection in the tile path therefore uses `hcnt` delayed by one clock (`hcnt_bg_d`).
  **This is Gowin specific and wrong on Altera or Xilinx.**
- The slot counter starts from reset in a defined phase, so the core runs reproducibly.
- `gen_video.vhd` gets a reset input.
- The RAMs are our own `entity work.g20k_spram`: synchronous, read-first, zero at start.

**ROMs from the SD card instead of the bitstream**

- All eleven fixed PROM entities are replaced by `entity work.g20k_promram`, loaded at run
  time: nine in `galaga.vhd`, the two sound ROMs in `sound_machine.vhd`. Our file
  `src/g20k_promram.vhd`.

**RAM mirror for RetroAchievements**

- A shadow copy of the video RAM, an interleaved harvest, an unconditional catch-up, and the
  delivery of a consistent snapshot of 5120 bytes per frame.
- Diagnostic outputs `dbg_*` for the diagnostic build.
- The three work RAMs are widened to 2048 bytes. The upper half is the shadow.
- The background character RAM is `entity work.g20k_lutram`, our file with an asynchronous
  read.

**Coin and start**

- The 51XX leaves credit mode only when a credit is really consumed. Upstream cleared
  `cs51XX_credit_mode` on every one-player start press, before checking whether a credit was
  there. The two-player branch already did it inside the credit check, the one-player branch now
  does the same. In credit mode the chip does not report the start button at all, the game
  learns of a press only through the credit decrement. Leaving credit mode on a press without
  credit disarmed the chip: start stayed dead until the CPU sent command 2 again, so a player
  who pressed start after a game over and inserted the coin afterwards could not start a new
  game. The comment above the check in `galaga.vhd` gives the full reasoning.

**Sound**

- `mb88.vhd`: the DAC nibbles of the Namco 54XX (`ol_port_out`, `oh_port_out`) get a reset.
  Without it they keep their last value across a reset, which freezes as a DC offset in the
  sound output.

## Line endings

Upstream uses CRLF, and so do all nine files here. Keep it that way, otherwise a diff against
upstream shows every line as changed.
