# Dar's Galaga core

Six files by Dar (darfpga@aol.fr), copied from
[DECAfpga/Arcade_Galaga](https://github.com/DECAfpga/Arcade_Galaga) at commit
`e06ba91d713702f8cde229ace2eacd7ad0f89855`, folder `rtl_dar/`. The core's RAMs and the ROMs it
loads at run time are our own files in `src/` (`g20k_spram.vhd`, `g20k_lutram.vhd`,
`g20k_promram.vhd`, `g20k_promram2.vhd`), and so is the Namco 06XX with the 51XX
(`namco_io.vhd`). The files keep their original headers. `galaga.vhd` and `mb88.vhd` carry
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
| `mb88.vhd` | Dar | yes, timer, interrupts, port O strobe, RAM size, one reset |
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

**Coin and start: the original 51XX**

- Dar's core imitates the Namco 51XX with a few registers: a credit counter, the coin and
  start logic and the joystick bytes. The imitation differs from the chip. In credit mode it
  reports the joystick and the fire button live, so a player could steer the ship during the
  attract demo. It also ignores the coinage the game sends.
- The 51XX is an MB88 that runs the chip's own program, `51xx.bin` from MAME's
  `namco51.zip`, behind a Namco 06XX built after MAME's `namco06.cpp`. Both live in our file
  `src/namco_io.vhd`. In `galaga.vhd` the 06XX and 51XX logic is gone, the core instantiates
  `namco_io` and keeps only the wiring and the command latch of the 54XX.
- The 06XX also drives the 54XX, as on the board: its IRQ is chip select 3, not a pulse on
  each write as in Dar's core.
- Both MCUs run at the board's rate, one instruction cycle every 72 clocks (18.432 MHz / 12 / 6).
  Dar's core ran the 54XX every 48 clocks.
- The chip selects follow the NMI by 192 clocks (10.4 us). In MAME both come at once, and the
  MCUs then read the byte the main CPU's NMI handler writes only 5 to 15 us after it is
  written. A handler a few us slower than MAME's leaves them the old byte, and the 54XX takes
  wrong explosion parameters until the next reset (seen on the board, reproduced with
  `sim/tb_namco54.vhd`).
- The programs of the 51XX and the 54XX share one block RAM (`src/g20k_promram2.vhd`). The ROM
  manifest loads them as one section of 2048 bytes.

**MB88**

- Timer: TL/TH count rising edges of `tc_n` while PIO bit 6 is set. An overflow sets VF and
  requests the timer interrupt. The 51XX counts vertical blanks this way.
- Interrupts as MAME's `mb88xx.cpp` describes them: a request waits until PIO enables its
  source and no interrupt is in service, the entry sets ST and takes three cycles more than a
  jump, `rti` ends the service. The external interrupt goes to $002, the timer to $004.
- `o_we` pulses after `outO`, so that the 06XX latch takes the 51XX's answer.
- `inR` selects R(Y & 3), as MAME does.
- Generic `data_6bit` for the MB8843 and MB8844 with 64 nibbles of RAM (X & 3). The 51XX uses
  it, the 54XX keeps Dar's 128 nibbles, its program does not tell the difference.

**Sound**

- `mb88.vhd`: the DAC nibbles of the Namco 54XX (`ol_port_out`, `oh_port_out`) get a reset.
  Without it they keep their last value across a reset, which freezes as a DC offset in the
  sound output.

## Line endings

Upstream uses CRLF, and so do the six VHDL files here. Keep it that way, otherwise a diff against
upstream shows every line as changed.
