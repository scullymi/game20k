# Hardware: which boards, and why

game20k uses two boards: an FPGA board that runs the arcade core, and a microcontroller board
for the USB stick, the menu and RetroAchievements. The wiring is in [wiring.md](wiring.md).

## Parts

| Part | | Note |
|---|---|---|
| Sipeed Tang Nano 20K | required | |
| Raspberry Pi Pico 2 W, stepping A3 or A4 | required | see [the stepping section](#rp2350-stepping-and-erratum-e9) |
| Micro USB to USB A OTG adapter | required | the stick plugs into it |
| microSD card | required | FAT32 |
| USB arcade stick (HID) | required | tested with a Mayflash F500 Elite |
| Perfboard, pin headers, sockets, wire | required | seven connections |
| HDMI cable, monitor that accepts 1280x720 at 61.03 Hz and 59.64 Hz | required | |
| Raspberry Pi Debug Probe | recommended | flashing without BOOTSEL, and the serial log, in one device |
| 2 resistors, 15 kOhm (A3/A4) or 4.7 kOhm (A2) | only with a separate USB A socket | pull-downs on D+ and D- |
| RC low-pass and a small amplifier | optional | analogue sound from pin 77, see below |

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

**Board-specific parts** of the design, for anyone porting it: the pins (`fpga/common/board.cst`),
the clocks (`board.sdc`), the PLLs (`pll_hdmi.v`, `pll_sdram.v`), the HDMI serializer (Gowin's
`OSER10` and `ELVDS_OBUF`) and the SDRAM controller (`sdram_fb.v`).

**Monitor.** The HDMI output is not standard 720p60. It shows 1280x720 at 61.03 Hz (Galaga and
Pac-Man) or 59.64 Hz (1942, 1943), each locked to the frame of its core, while the AVI infoframe
announces CEA mode 4. Every display tried so far accepts it, but one that insists
on exact CEA timing may stay black.

### Shared pins

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

## The Companion board

The FPGA has no USB host of its own. A microcontroller on the headers acts as SPI master and runs
the [FPGA-Companion](https://github.com/MiSTle-Dev/FPGA-Companion) firmware by Till Harbaum: USB
input, SD card access and the menu, plus the RetroAchievements client in our fork.

game20k needs a **Raspberry Pi Pico 2 W**. The firmware needs the RP2350's 520 kB of RAM, so the
Pico W and other RP2040 boards are out, and it needs WiFi for RetroAchievements, so the Pico 2
without W is out too. The Companion also runs on other boards (an M0S Dock, the Nano's onboard
BL616, ESP32), but game20k does not support them.

**Two ways to connect the stick.** The recommended way is the Pico's own micro USB port with an
OTG adapter (`scripts/build_companion.sh pico2 native`). It uses the chip's USB controller and
is not affected by erratum E9. The alternative is a soldered USB A socket on GP2/GP3
(`scripts/build_companion.sh pico2 pio`), which needs the pull-downs from the next section. With
the native port, unplug the stick to flash over USB.

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

## Recommendation

1. **Tang Nano 20K plus Pico 2 W, stepping A3 or A4.** All scripts, HDL sources and constraints
   are written for this combination.
2. **Tang Nano 20K plus
   [MiSTeryShield20k RPiPico](https://github.com/MiSTle-Dev/Boards/tree/main/misteryshield20k_rpipico)**,
   if you would rather not solder the SPI wiring by hand. It connects the Pico to the same GPIOs
   as our wiring, so the build would be `scripts/build_companion.sh pico2 pio`. The board was
   designed for the Pico W, so you would fit a Pico 2 W instead, and that combination has not
   been tested yet. Its four USB-A sockets run over PIO USB, so with an RP2350 A2, check that
   the board has the pull-downs described above.

## Analogue sound (optional)

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

Sipeed's pin diagram and schematics of the Tang Nano 20K, the Gowin GW2AR datasheet, the RP2350
datasheet with erratum E9, Raspberry Pi's announcement of the A4 stepping (29 July 2025), the
FPGA-Companion documentation, the constraint files of NESTang and MiSTeryNano, and the
measurements of this project.
