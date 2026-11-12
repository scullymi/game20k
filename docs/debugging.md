# Debugging

Tools for finding faults on the board: the Pico's serial log, a debug probe for flashing and
stepping through the firmware, and diagnostic builds of the cores. What the Nano's LEDs show is
in [troubleshooting.md](troubleshooting.md#the-nanos-leds).

## Debug probe (SWD)

On the Pico W and Pico 2 W three vias sit in the middle of the board, below the radio module:
**SWCLK, GND, SWDIO**. Solder a three-pin header there. With a debug probe (the Raspberry Pi
Debug Probe, or a second Pico with the `debugprobe` firmware) this gives flashing without
BOOTSEL, real debugging (breakpoints, single step, memory inspection), and the serial output of
the firmware, since the probe is also a UART adapter.

Connect only SWCLK, SWDIO and GND. The Pico is powered from the Nano's 5 V, so the probe's own
supply line stays unconnected.

### Which probe

The **Raspberry Pi Debug Probe** comes with three cables, among them the one needed here,
JST-SH to a 0.1 inch female header, so a plain pin header on the three pads is enough.

| Probe socket | Purpose | On our Pico |
|---|---|---|
| **D** | SWD | the three pads: SWCLK, GND, SWDIO |
| **U** | UART | GP0 (pin 1), GP1 (pin 2), GND |

**Alternative: a second Pico.** The `debugprobe` firmware from Raspberry Pi runs on an ordinary
Pico or Pico 2. Pinout per its `include/board_pico_config.h`:

| Probe Pico | Signal | To the target |
|---|---|---|
| GP2 | SWCLK | SWCLK pad |
| GP3 | SWDIO | SWDIO pad |
| GP4 | UART TX | GP1 of the target |
| GP5 | UART RX | GP0 of the target |
| GP1 | RESET (optional) | RUN, pin 30 |
| GND | | GND |

Build with `cmake -DDEBUG_ON_PICO=1 -DPICO_BOARD=pico2 ../` (Pico SDK 2.0.0 or newer). The
result is `debugprobe_on_pico2.uf2`.

### Flashing through the probe

OpenOCD must know `target/rp2350.cfg`, which release 0.12.0 predates. A current development
build has it (`brew install --HEAD open-ocd`), and so does the OpenOCD of the VS Code extension
"Raspberry Pi Pico". Then, without BOOTSEL and without replugging:

```sh
openocd -f interface/cmsis-dap.cfg -c "adapter speed 5000" -f target/rp2350.cfg \
        -c "program build/firmware/pico2-native/fpga_companion.elf verify reset; shutdown"
```

If OpenOCD reports `unable to find a matching CMSIS-DAP device` after `could not read product
string ... Pipe error`, the probe is wedged on the USB bus. Unplug it and plug it in again.

### Reading the serial output

The firmware logs its entire run on **UART0, TX on GP0 (pin 1), 921600 baud, 8N1**. `debugf()`
is an unconditional `printf`. There is no switch to turn it off. Over GP1 (pin 2) the Pico also
accepts input. Both pins are free in game20k's [wiring](wiring.md). Without a probe, a USB TTL adapter on GP0 and
GND is enough. With the probe, its socket U appears as a serial port (`/dev/cu.usbmodem*`) next
to the CMSIS-DAP part for OpenOCD.

Use `tio` (`brew install tio`) rather than `screen`, because it adds timestamps:

```sh
tio -b 921600 -t --timestamp-format 24hour-start \
    -L --log-file boot.log --log-strip \
    /dev/cu.usbmodem<id>
```

`<id>` is the number `ls /dev/cu.usbmodem*` shows for the probe.

`24hour-start` counts from the start of the capture, `--log-strip` removes the ANSI color codes
around `ini_debugf` lines, and `tio` reconnects by itself when the device disappears briefly on
a cold start. Quit with Ctrl-T Q.

The Nano's own UART (pin 69 to the onboard BL616) is a different port and not usable for this.

## Diagnostic builds

`-G` builds a diagnostic picture instead of the game, into a folder of its own, for example
`python3 g20k.py build fpga/galaga_hdmi -G RAMDIAG=1`. The parameters are those of
`fpga/common/src/game20k_top.sv`, where the LEDs' meaning in these builds is described too.
