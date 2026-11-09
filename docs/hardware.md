# Hardware

The arcade cores run on a Sipeed Tang Nano 20K. A second chip, the Companion, handles the USB
stick, the SD card and the menu. The best Companion is a Raspberry Pi Pico 2 W, the only one
with RetroAchievements.

## Setups

| Setup | RetroAchievements | Besides the Nano | How to set it up |
|---|---|---|---|
| **Nano and Raspberry Pi Pico 2 W** (recommended) | yes | Pico 2 W, micro USB OTG adapter, seven wires | [wiring.md](wiring.md) |
| Nano alone, the Companion on its onboard BL616 | no | a powered USB hub | [bl616.md](bl616.md) |
| Nano and Sipeed M0S Dock | no | M0S Dock, wires | [bl616.md](bl616.md) |

Every setup also needs a microSD card (FAT32), a USB arcade stick (HID, tested with a Mayflash
F500 Elite), and an HDMI cable and monitor (see [Monitor](#monitor)). The menu, the game switch
and the stick work the same in all three. Sound comes over HDMI. An RC low-pass and a small
amplifier on pin 77 add a speaker, see [Analog sound](#analog-sound-optional).

## Parts for the Pico 2 W

| Part | | Note |
|---|---|---|
| Raspberry Pi Pico 2 W, stepping A3 or A4 | required | see [the stepping section](#rp2350-stepping-and-erratum-e9) |
| Micro USB to USB A OTG adapter | required | the stick plugs into it |
| Perfboard, pin headers, sockets, wire | required | seven connections |
| Raspberry Pi Debug Probe | recommended | flashing without BOOTSEL, and the serial log, in one device |
| 2 resistors, 15 kOhm (A3/A4) or 4.7 kOhm (A2) | only with a separate USB A socket | pull-downs on D+ and D- |

## The FPGA board

The Tang Nano 20K carries a Gowin GW2AR-18 with 64 Mbit of SDRAM in the same package, plus HDMI,
a microSD slot, a programmer and 64 Mbit of flash on one small board. Sipeed's
[wiki](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html) has the full
specification.

What makes it fit: HDMI straight from the FPGA pins without extra chips, the SDRAM for the
rotated picture, and a large set of existing cores for this exact board (MiSTeryNano, NanoMig,
NESTang), which the HDMI path, SPI, menu and SD card access come from. The limit is block RAM,
not logic: arcade cores of this generation keep their ROMs in block RAM, and the design uses
almost all 46 blocks.

| Board | Block RAM | For this project |
|---|---|---|
| Tang Nano 9K | 26 blocks | too small |
| **Tang Nano 20K** | 46 blocks | **the platform** |
| Tang Primer 20K | 46 blocks | same FPGA in a different package, portable with some work |
| Tang Primer 25K, Console 60K/138K | 56 blocks and more | different FPGA family, needs a full port |

**Board-specific parts** of the design, for anyone porting it: the board folder
`boards/tangnano20k/` (pins, clock, flash layout), the PLLs (`fpga/common/src/pll_hdmi.v`,
`pll_sdram.v`), the HDMI serializer (Gowin's `OSER10` and `ELVDS_OBUF`) and the SDRAM controller
(`sdram_fb.v`).

### Monitor

The HDMI output is not standard 720p60. It shows 1280x720 at 61.03 Hz (Galaga,
Pac-Man, Dig Dug, Time Pilot), 59.64 Hz (1942, 1943, Ghosts'n Goblins) or 57.44 Hz (Pang), each
locked to the frame of its core, while the AVI infoframe announces CEA mode 4. Every display
tried so far accepts it, but one that insists on exact CEA timing may stay black.

### Shared pins

With a Companion on the header:

| Pin | Onboard use per Sipeed | In game20k |
|---|---|---|
| 56, 54, 51 | I2S BCLK, I2S DIN and enable of the MAX98357A amplifier | SPI CSn, SCK and IRQn |
| 77 | LCD_CLK | sigma-delta audio |
| 85 | SDIO_D1 of the microSD slot | taken by the card |

**The onboard amplifier cannot be used with the Companion attached.** Our SPI pins follow the
FPGA-Companion convention for the Tang Nano 20K, which Till Harbaum's cores and carrier boards
use as well, and that convention puts them on the amplifier's pins. Sound comes over HDMI.

> **Do not solder anything to the SPK pads.** The amplifier's clock input toggles with every SPI
> transfer while its LRCLK input stays idle, and the MAX98357A datasheet warns that this "can
> cause unexpected output behavior including a large DC output voltage". Without a speaker this
> does no harm, with one it can.

With the Companion on the onboard BL616, the SPI uses the FPGA pins that the board wires to the
BL616 (86, 13, 76, 75 and 69), and pin 51 carries the BL616's console.

## The Companion

The FPGA chip itself has no USB host. The Companion acts as SPI master and runs game20k's fork of
the [FPGA-Companion](https://github.com/MiSTle-Dev/FPGA-Companion) firmware by Till Harbaum: USB
input, SD card access and the menu, and on the Pico 2 W the RetroAchievements client.

### Raspberry Pi Pico 2 W

RetroAchievements need the RP2350's 520 kB of RAM, so the Pico W and other RP2040 boards are out,
and Wi-Fi, so the Pico 2 without W is out too.

The stick plugs into the Pico's own micro USB port through an OTG adapter, as the release
firmware expects, or into a soldered USB A socket on GP2/GP3, see [wiring.md](wiring.md). The
stepping section below only concerns that socket.

**A carrier board instead of hand wiring.** The
[MiSTeryShield20k RPiPico](https://github.com/MiSTle-Dev/Boards/tree/main/misteryshield20k_rpipico)
connects the Pico to the same GPIOs as our wiring, with the firmware built by
`python3 g20k.py firmware --usb pio`. It was designed for the Pico W, and with a Pico 2 W fitted
it has not been tested yet. Its USB A sockets run over PIO USB, so check them for the pull-downs
of the next section.

### BL616

The Nano's own BL616 and the M0S Dock run the same firmware without RetroAchievements, see
[bl616.md](bl616.md).

### Upstream firmware

The upstream FPGA-Companion firmware runs too: each core carries a smaller menu of its own for
it, with controller, DIP switches, settings and ROM loading, but no RetroAchievements and no game
switch. It lists every `.rom` file on the card and checks none of them, so pick the game's own
file.

## RP2350 stepping and erratum E9

**In short: with stepping A2, a USB socket on GP2/GP3 detects no device unless you add external
pull-down resistors. The native port with an OTG adapter works on every stepping.**

**Identifying the stepping.** The marking on the chip ends in the stepping: `RP2350A0A2` is A2,
`RP2350A0A3` and `RP2350A0A4` are A3 and A4. With the board in BOOTSEL mode, `picotool info -a`
(version 2.2.0 or newer) shows it as well. Raspberry Pi stopped making A2 in July 2025, so new
boards carry A3 or A4, but old stock can still be A2.

**Why.** Erratum RP2350-E9 makes the GPIO pads leak up to 120 uA, and the chip's internal
pull-downs are too weak to hold D+ and D- low against that. The host then sees both lines high
and never detects a device. The dedicated USB pads of the native port are not affected.

| Setup | Result |
|---|---|
| Pico 2 W (A2), native port, OTG adapter | works |
| Pico 2 W (A2), USB A socket on GP2/GP3, no pull-downs | stick not detected |
| Pico 2 W (A2), the same socket with 4.7 kOhm pull-downs | works |

**What to do.** With the native port, nothing. With a separate socket, add one resistor from D+
to GND and one from D- to GND, right at the socket: 4.7 kOhm on A2 (the erratum allows up to
8.2 kOhm), 15 kOhm on A3 and A4, as the USB specification asks for anyway.

## Analog sound (optional)

Sound comes over HDMI. Pin 77 also carries a **1-bit sigma-delta stream at 18.5625 MHz, LVCMOS
3.3 V**, which needs a low-pass filter and an amplifier. An I2S amplifier module would be
simpler, but the FPGA has no I2S output yet.

**Filter.** 1.0 kOhm from pin 77 to a 10 nF film capacitor to ground, within 10 mm of the pin.
From there, a twisted pair of less than 30 cm to a second 1.0 kOhm and 10 nF at the amplifier
input, with 680 Ohm to ground there. That gives about 235 mVrms, line level. Use film
capacitors, not X7R: the first one sees the full 3.3 V swing.

**Amplifier.** A mono class D module for 5 V with an input trimmer, for example a PAM8302A, with
470 uF and 100 nF right at its supply pins, and 47 uF from its shutdown pin to ground so that it
switches on about 330 ms after power-up, once the FPGA is configured. Power it from a 5 V supply
rated for at least 2 A. Use an 8 Ohm speaker, not 4 Ohm, because the board runs from USB. The
module has its own coupling capacitors, so add no further capacitor, bias divider, choke or
ferrite at its input.

**Check.** A multimeter on pin 77 against ground reads 0.00 V with the volume muted and about
0.07 V while the demo plays at full volume. When a sound starts, the DC step passes through the
module's coupling capacitors as a short thump, as on the original board.

## Sources

- [Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html): Sipeed's
  wiki with the pin diagram and the schematics
- [GW2AR series datasheet](https://www.gowinsemi.com/en/document/main/database/1846/), Gowin DS226
- [RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf) with erratum E9
- [RP2350 A4](https://www.raspberrypi.com/news/rp2350-a4/), Raspberry Pi's announcement of the A4
  stepping (29 July 2025)
- [MAX98357A datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/MAX98357A-MAX98357B.pdf)
- [FPGA-Companion](https://github.com/MiSTle-Dev/FPGA-Companion), and the constraint files of
  [NESTang](https://github.com/nand2mario/nestang) and
  [MiSTeryNano](https://github.com/MiSTle-Dev/MiSTeryNano)
- the measurements of this project
