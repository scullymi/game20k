# Hardware: which boards, and why

Two boards: an FPGA board that runs the arcade core, and a microcontroller board that handles
the USB input device and the network connection for RetroAchievements. Each can be swapped
independently, but not for just any board. Wiring is in [wiring.md](wiring.md).

## Parts

| Part | | Note |
|---|---|---|
| Sipeed Tang Nano 20K | required | GW2AR-LV18QN88C8/I7 |
| Raspberry Pi Pico 2 W, stepping A3 or A4 | required | see the erratum section below |
| Micro USB to USB A OTG adapter | required | the stick plugs in there |
| microSD card | required | FAT32 tested, exFAT compiled in but untested. Contents in [sdcard/README.md](../sdcard/README.md) |
| USB arcade stick (HID) | required | tested: Mayflash F500 Elite |
| Perfboard, pin headers, sockets, wire | required | seven connections |
| HDMI cable, monitor accepting 1280x720 at 61.03 Hz | required | |
| Raspberry Pi Debug Probe | recommended | flashing without BOOTSEL and the serial output in one device |
| 2 resistors 15 kOhm (A3/A4, RP2040) or 4.7 kOhm (A2) | only with a separate USB A socket | pull-downs on D+ and D- |
| 2 resistors 22 Ohm, 10 uF and 100 nF | optional, separate USB A socket | series resistors and VBUS decoupling |
| RC low-pass and a small amplifier | optional | analogue sound from pin 77, see below |

## The FPGA board

The Sipeed Tang Nano 20K carries a Gowin GW2AR-LV18QN88C8/I7 with the SDRAM in the package, so
HDMI, SDRAM, microSD and a programmer sit on one small board.

| Property | Value |
|---|---|
| FPGA | Gowin GW2AR-LV18QN88C8/I7 (Arora, GW2A family) |
| Logic | 20736 LUT4, 15552 flip-flops |
| Block RAM | 828 kbit in 46 blocks, plus 41472 bit shadow SRAM |
| DSP | 48 multipliers 18x18 |
| PLL | 2 |
| SDRAM | 64 Mbit SDR, 32 bit wide, in the FPGA package |
| Flash | 64 Mbit SPI, the bitstream survives power off |
| Video | HDMI socket directly on the FPGA, plus a 40-pin RGB LCD connector |
| Storage | microSD slot |
| Audio | PCM amplifier MAX98357A on the board, not usable here, see shared pins |
| Onboard MCU | BL616 as USB JTAG programmer and USB serial bridge |
| Clocks | 27 MHz crystal, plus an MS5351 clock generator |
| Controls | 6 LEDs, 1 WS2812, 2 buttons |
| Size | 22.55 x 54.04 mm, two header rows of 20 pins |

What matters for this project: HDMI without extra hardware (the TMDS pairs are on FPGA pins
33/34, 35/36, 37/38, 39/40, driven with the Gowin primitives `OSER10` and `ELVDS_OBUF`), enough
block RAM for the core plus scaler, HDMI path, OSD, RAM mirror and SPI (the design uses 45 of
the 46 blocks), and a large base of cores for exactly this board (MiSTeryNano, NanoMig, C64Nano,
NESTang), from which HDMI path, SPI, OSD and SD access are taken.

Two caveats. TangCore (nand2mario) lists the Tang Nano 20K as unsupported, so this project
follows the MiSTeryNano path with the FPGA Companion. And the board exists in two assembly
variants (3921 and 3923) that differ in the wiring between the onboard BL616 and the FPGA,
which does not matter with an external Companion.

### Alternatives in the Tang range

| Board | FPGA | LUT4 | Block RAM | Memory | HDMI | For this project |
|---|---|---|---|---|---|---|
| Tang Nano 1K / 4K | GW1NZ-1 / GW1NSR-4C | 1152 / 4608 | small | small | partly | no, far too small |
| Tang Nano 9K | GW1NR-LV9QN88 | 8640 | 468 kbit, 26 blocks | 64 Mbit PSRAM | yes | no, neither logic nor block RAM suffices |
| **Tang Nano 20K** | GW2AR-LV18QN88 | 20736 | 828 kbit, 46 blocks | 64 Mbit SDRAM in package | yes | **reference platform** |
| Tang Primer 20K | GW2A-LV18PG256 | 20736 | 828 kbit | 128 MB DDR3 | on the base board only | same device, different package and pins, portable with effort |
| Tang Primer 25K | GW5A-LV25MG121 | 23040 | 1008 kbit | SDRAM as a plug-in module | PMOD only | different FPGA family, needs a port |
| Tang Console 60K | GW5AT-LV60P484A | 59904 | 2124 kbit | 512 MB DDR3 | yes | oversized, needs a complete port |
| Tang Console 138K | GW5AST-LV138 | 138240 | 6120 kbit | 1 GB DDR3 | yes | the only Tang option for CPS1/CPS2, overkill for Galaga |

Block RAM is the bottleneck, not logic: arcade cores of this generation keep program, character,
sprite and colour ROMs in block RAM. Gowin EDA Education covers the GW2AR-18C free of charge.
The open-source toolchain (yosys, nextpnr, apicula) is untested here: the core is VHDL, and the
primitives `rPLL`, `OSER10` and `ELVDS_OBUF` would need checking.

### What is board specific

| Area | File | Board specific part |
|---|---|---|
| Pin assignment | `fpga/galaga_hdmi/galaga_hdmi.cst` | all pin numbers are for the QN88 package |
| Clocks | `fpga/galaga_hdmi/galaga_hdmi.sdc` | 27 MHz input, from it 371.25 / 74.25 / 18.5625 MHz and 64.8 MHz for the SDRAM |
| PLL | `fpga/galaga_hdmi/src/pll_hdmi.v`, `pll_sdram.v` | primitive `rPLL`, family dependent |
| HDMI serializer | `fpga/galaga_hdmi/src/hdmi/serializer.sv`, `galaga_hdmi_top.sv` | primitives `OSER10` (serializer) and `ELVDS_OBUF` (top level) |
| SDRAM | `fpga/galaga_hdmi/src/sdram_fb.v` | the in-package SDRAM of the GW2AR |
| SPI to the Companion | `fpga/galaga_hdmi/src/misc/mcu_spi.v` and the `.cst` | pins per the M0S Dock assignment |
| Clock edge fix | `fpga/galaga_hdmi/src/rtl_dar/galaga.vhd` | Gowin specific, wrong on Altera or Xilinx |

**Monitor.** The HDMI output is not standard 720p60. The top level sets FRAME_W to 1584 and
FRAME_H to 768. At a 74.25 MHz pixel clock that is 1280x720 visible at 61.03 Hz, while the AVI
infoframe announces CEA mode 4. Every display tried so far accepts it, but a monitor that
insists on exact CEA timing may stay black.

### Shared pins on the Nano 20K

| Pin | Onboard function per Sipeed | In this project |
|---|---|---|
| 56 | I2S_BCLK of the MAX98357A | SPI CSn to the Companion |
| 54 | I2S_DIN of the MAX98357A | SPI SCK to the Companion |
| 51 | PA_EN of the MAX98357A | SPI IRQn from the FPGA |
| 77 | LCD_CLK, left header | sigma-delta audio |
| 85 | SDIO_D1 of the microSD, left header | taken by the card |
| 69 | UART to the onboard BL616 | not used |

**The onboard amplifier MAX98357A is not usable with the Companion attached.** Its I2S lines
and its enable pin are CSn, SCK and IRQn. Sound comes over HDMI.

> **Solder nothing to the SPK pads while SPI is on 51/54/56.** The MAX98357A datasheet: "Do not
> remove LRCLK while BCLK is present. Removing LRCLK while BCLK is present can cause unexpected
> output behavior including a large DC output voltage." Exactly that situation exists here:
> BCLK (pin 56) toggles with every SPI transfer and LRCLK (pin 55) is dead. SD_MODE has no
> external pull (R45 is 0 Ohm, C14 unpopulated), only the internal 100 kOhm pull-down, so the
> enable follows IRQn one to one. Without a speaker attached this has no effect. With one it
> does.

Moving CSn, SCK and IRQn to pins 71, 72 and 73 would free the amplifier. Those three go nowhere
but the headers, unlike pins 75 and 76, which go to the BL616. Not done.

## The Companion MCU

The Tang Nano 20K has no USB host on the FPGA. USB devices go through a microcontroller on the
headers that acts as SPI master and runs the **FPGA Companion** firmware (MiSTle-Dev, Till
Harbaum): USB HID host with SDL gamepad mapping, SD card access, the OSD menu and, in our fork,
the RetroAchievements client.

| Board | Build | USB host | WiFi | RAM | Assessment |
|---|---|---|---|---|---|
| Raspberry Pi Pico | `-DBOARD=PICO` | native or PIO | no | 264 kB | no RetroAchievements without WiFi |
| Raspberry Pi Pico W | `-DBOARD=PICO` | native or PIO | yes | 264 kB | works, RetroAchievements untested, RAM tight for TLS |
| Raspberry Pi Pico 2 | `-DBOARD=PICO2` | native or PIO | no | 520 kB | no RetroAchievements without WiFi |
| **Raspberry Pi Pico 2 W** | `-DBOARD=PICO2` | native or PIO | yes | 520 kB | **recommended**, stepping A3 or A4 |
| Waveshare RP2040-Zero | `-DBOARD=WS2040ZERO` | native only | no | 264 kB | USB-C, other SPI pins, PIO USB blocked by the WS2812 LED |
| MiSTeryShield20k Lite | `-DBOARD=SH20KLITE` | native or PIO | no | 264 kB | carrier board without WiFi |
| MiSTeryShieldPicoTN20k | `-DBOARD=MSP20K` | PIO only | with a Pico W | 264 kB | carrier board, the native port is the JTAG bridge |
| M0S Dock (BL616) | own build | USB 2.0 high speed | yes, WiFi 6 | | strongest USB host, limited SDK support |
| Onboard BL616 of the Nano 20K | own build | yes | with extra work | | overwrites the board's programmer and UART chip, other FPGA pins (CSn 86, SCK 13, MOSI 76, MISO 75, IRQn 69), pins depend on the assembly variant |
| ESP32-S2 / ESP32-S3 | own build | one device, no hubs | yes | 320 / 512 kB | as a network coprocessor at most |

All four Pico variants are pin compatible, so a change costs only a firmware build.

**Two ways for the USB device.** A separate USB A socket is not needed. The Pico's micro USB
port works as host with an OTG adapter. That path uses the chip's USB controller with its
specification-grade pull-downs and is not affected by erratum E9. The build option `NATIVE_USB`
selects it (`scripts/build_companion.sh pico2 native`). The PIO USB port on GP2/GP3 is built
with `scripts/build_companion.sh pico2 pio` and needs the pull-downs from the next section. To
flash over USB with the native port, the stick must be unplugged.

**Build notes.** Pico SDK 2.2.0 or newer. TinyUSB comes from the submodule `external/tinyusb`,
our fork on the branch `game20k`, not from the SDK: it carries one changed line in `hid_host.c`,
which hands a failed transfer to the Companion as `NULL` instead of stale data, and Pico-PIO-USB
as a submodule, which the Companion links in both variants. A build
without radio would make things worse, not better: without the cyw43 init the 3.3 V regulator
stays in its power-save mode with more ripple, and the LED timer toggles GP25, which on the
Pico 2 W is the WL_CS pin. The firmware therefore always builds with radio.

## RP2350 stepping and erratum E9

**Short version: a Pico 2 or Pico 2 W with stepping A2 detects no USB device on a hand-soldered
socket at GP2/GP3 without external pull-down resistors. The native port with an OTG adapter is
not affected.**

Erratum RP2350-E9 concerns the pads of bank 0, GPIO 0 to 47. A pad configured as input with its
input buffer enabled leaks up to 120 uA at a pad voltage between low and high and latches at
about 2.2 V. Pico-PIO-USB relies on the chip's internal pull-downs for USB, 36 to 113 kOhm per
datasheet, which cannot hold the pad down against 120 uA. The host then sees D+ and D-
permanently high and detects neither plugging nor unplugging. The library's partial workaround,
disabling the input buffer briefly and enabling it right before a read, protects the CPU's
reads only, not the PIO state machines that sample continuously.

The native USB port uses the dedicated USB pads, whose pull-downs are 14.25 to 15.75 kOhm, and
the datasheet excludes those pads from E9.

| Setup | Result |
|---|---|
| Pico W (RP2040), native port, OTG adapter | runs |
| Pico 2 W (RP2350 A2), native port, OTG adapter | runs |
| Pico 2 W (A2), USB A socket on GP2/GP3, no pull-downs | stick not detected |
| Pico 2 W (A2), the same socket with 4.7 kOhm pull-downs | runs |

**Identifying the stepping:** the chip marking ends in the revision: `RP2350A0A2` is A2,
`RP2350A0A3` and `RP2350A0A4` are fine. `picotool info -a` from release 2.2.0 on shows the
revision of A3 and A4 chips correctly (board in BOOTSEL mode). Older versions print "Unknown".
In firmware, `rp2350_chip_version()` returns 2 for A2 and 3 for A3 and A4 (A4 differs from A3
only in the boot ROM).

**What to do:** with the native port and an OTG adapter, nothing. With a separate socket, one
pull-down from D+ to GND and one from D- to GND directly at the socket: 4.7 kOhm on A2 (the
erratum allows up to 8.2 kOhm), 15 kOhm on A3, A4 and the RP2040, which the USB specification
asks for anyway. The RP2040 is not affected by E9 and runs PIO USB even without external
pull-downs, 15 kOhm is still the better practice there.

Not the cause, though it looks like one: the system clock. 192 MHz in `mcu_hw.c` is the only
value that gives all four PIO state machines integer dividers (48, 6, 96 and 12 MHz). Leave it.

Raspberry Pi announced on 29 July 2025 that A2 production had ceased and all production had
moved to A4, with the remaining A2 inventory withdrawn from the channel. Boards bought new carry
A4 or A3 (about 30000 A3 chips went into Pico 2 and Pico 2 W). Old stock and marketplace offers
can still be A2, and a board bought before autumn 2025 most likely is.

## Recommendation

1. **Tang Nano 20K plus Pico 2 W, stepping A3 or A4.** This is the combination all scripts,
   HDL sources and constraints are written for. With 520 kB RAM and WiFi, rcheevos plus TLS fit
   comfortably.
2. **Tang Nano 20K plus Pico W.** Pin compatible, no E9, PIO USB works without tinkering. With
   264 kB a TLS handshake can fail. Then change to the Pico 2 W.
3. **Tang Nano 20K plus MiSTeryShieldPicoTN20k**, if you would rather not solder the SPI wiring
   by hand. The USB host must run over PIO USB (the native port serves the JTAG bridge), so plan
   for the pull-downs, and the JTAG core loader needs a modification on the shield.

Not recommended to start with: the onboard BL616 (overwrites programmer and UART chip, other
pins, no debug output), an ESP32 as main controller (one device, no hubs), a Pico or Pico 2
without W (no WiFi, no RetroAchievements), and the Tang Console 60K/138K (a complete port to the
GW5A family).

## Analogue sound (optional)

Sound comes over HDMI. Pin 77 additionally carries a **1-bit sigma-delta stream at 18.5625 MHz,
LVCMOS 3.3 V**, which needs a low-pass filter and an amplifier. An amplifier alone is not
enough. An I2S amplifier module on three free pins would be simpler, but the FPGA has no I2S
output.

Filter: 1.0 kOhm from pin 77 to a 10 nF film capacitor to ground within 10 mm of the pin. From
there a twisted pair of less than 30 cm to a second 1.0 kOhm and 10 nF at the amplifier input,
and 680 Ohm to ground there, which gives about 235 mVrms, line level. Film capacitors, not X7R:
the first one sees the full 3.3 V swing. Amplifier: a mono class D module for 5 V with an input
trimmer (for example PAM8302A), 470 uF and 100 nF directly at its supply pins, 47 uF from its
shutdown pin to ground so that it switches on about 330 ms after power-up, when the FPGA is
configured. Power the module from a 5 V supply rated for at least 2 A, not from any phone
charger. Speaker 8 Ohm, not 4: the board runs from USB. No extra coupling capacitor or bias
divider at the module input, the module has its own coupling capacitors, and no choke or
ferrite.

Check at the device with a multimeter on pin 77 against ground: 0.00 V with the game idle and
the volume muted, about 0.07 V with the demo running at full volume, which is the mean of the
audio signal. A sound that starts brings a DC step, which passes through the module's coupling
capacitors as a short thump, as on the original board.

## Sources

Sipeed's pin diagram and KiCad schematics of the Tang Nano 20K (revisions 3850, 3920, 3921,
3923), the Gowin GW2AR datasheet, the RP2350 datasheet including erratum E9, Raspberry Pi's
post "RP2350 A4, RP2354, and a new Hacking Challenge" of 29 July 2025 and PCN 32, FPGA-Companion
(README, SPI.md, `src/rp2040`), Pico-PIO-USB, the constraint files of NESTang and MiSTeryNano
for the same board, and the measurements of this project.
