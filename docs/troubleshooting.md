# When something does not work

## First start

1. Does the LED on the Pico blink? On the Pico W and Pico 2 W it is driven through the Wi-Fi
   chip, so a firmware built without Wi-Fi does not blink it.
2. Does button S2 on the Nano open the menu? Then the SPI connection works.
3. Does the stick move something? **Do not test this in the open menu.** While the menu is
   visible, the Pico uses the stick for navigation and does not pass it to the FPGA. Test in
   the game.
4. The Nano's LEDs: LED 2 stays on once a packet from the Pico has arrived. LED 3 is on while a
   direction or button is held.
5. The input test (menu `Controller`, `Input test: On`) shows a bar at the top of the picture with
   the raw data from the Pico, labeled, and next to it the game signals derived from them.

If something hangs: power everything off for ten seconds. A USB pin latched by erratum E9 of
the RP2350 is a hardware state and survives every reset, see
[hardware.md](hardware.md#rp2350-stepping-and-erratum-e9).

## The Nano's LEDs

| LED | Lit when | Off means |
|---|---|---|
| 1 | blinks once a second, faster while the ROM loads | |
| 2 | the Companion has sent a packet | no connection to the Companion |
| 3 | a direction or button is held | |
| 4 | the core has produced a vsync | the core runs but makes no picture |
| 5 | the ROM is loaded | the ROM did not arrive, the core stays in reset |
| 6 | the HDMI PLL is locked | no picture at all |

## Messages about the ROM file

Every file that `python3 g20k.py sdcard` builds carries a footer with the game's name and a
checksum, which the Pico checks while it loads the game.

- `Old ROM file`: the file was built by an older release. Build the card again, see
  [Updating to a new release](#updating-to-a-new-release).
- `ROM file damaged`: the content no longer matches its checksum, and the game does not start.
  Copy the file to the card again.

## Wi-Fi does not connect

- The firmware connects only to WPA2 networks on 2.4 GHz. Open networks, WPA3-only networks and
  5 GHz do not work.
- Check `SSID=` and `PASS=` under `[WIFI]` in `config.ini` on the card. Keep every line within
  125 characters, the firmware skips a longer one.
- The firmware gives up after its attempts at power-on. Power off and on after a change.
- `Status` in the menu shows the network. The serial log names the network and says whether the
  attempt failed, see [debugging.md](debugging.md#reading-the-serial-output).

## Updating to a new release

Cores, firmware and the files on the SD card must come from the same release. In the folder of
the repository:

```sh
git pull
python3 g20k.py tools fetch suite
python3 g20k.py sdcard /Volumes/YOUR_CARD
python3 g20k.py flash --download
python3 g20k.py firmware --download
```

`sdcard` keeps your `config.ini`. Copy the firmware onto the Pico as in
[wiring.md](wiring.md#firmware-onto-the-pico). Without a Pico, see [bl616.md](bl616.md).
