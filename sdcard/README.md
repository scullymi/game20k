# game20k: the SD card

This file is also copied onto the card, for whoever holds the card later.

The card goes into the slot of the Tang Nano 20K, not the Pico. FAT32, all files in the
root directory, lowercase ASCII file names.

## Files on the card

- galaga.rom: the game data, 38944 bytes. You build it yourself from your own MAME set.
  It is never shipped. Without it the screen stays dark. Every further game brings its own
  <set>.rom and <set>.ini the same way.
- config.ini: WiFi and RetroAchievements account. Optional: without it the machine plays
  without network and without unlocks. Contains secrets, see below.
- galaga.ini: settings and the chosen ROM. The device writes it with "Save settings".
- README.md: this file.
- ra_patch.json, ra_patch.mac, ra_unlocked.txt, ra_pending.txt, ra_parked.txt: created by
  the machine. The achievement set from the server (so it is there without network too)
  with its tag, what the account has unlocked, what still has to be sent, and what was set
  aside. Do not edit.

## Preparing the card

    scripts/make_sdcard.sh                      builds and checks, lists what is missing
    scripts/make_sdcard.sh /Volumes/YOUR_CARD   ... and copies to the card

Sources: roms/galaga.zip (MAME set galaga, Namco Rev B, merged set) and optionally
roms/namco54.zip (explosion sounds). The script builds galaga.rom as the game's manifest
(fpga/galaga_hdmi/galaga.manifest) describes it, every chip checked against MAME, creates config.ini from
config.ini.example on the first run for you to fill in, checks that no line of it is longer
than 62 characters, writes a galaga.ini that preselects the ROM, and warns if a config.xml is
on the card. A galaga.ini already on the card is kept: it holds the settings saved on the
device.

Card types: SD, SDHC, SDXC. FAT32 is tested, exFAT is compiled in but untested. No subfolders
are needed.

## First start

1. Card into the Nano, power on.
2. The screen stays dark until LED 5 comes on, which means the ROM is loaded. That takes a
   moment.
3. S2 on the Nano opens the menu. If galaga.ini is missing: Settings, "ROM set", galaga.rom,
   then "Save settings".

## Traps

- Do not put a config.xml on the card. It replaces the menu from the bitstream, and the
  device then plays softcore only.
- A line in config.ini longer than 62 characters is dropped by the firmware. The machine
  shows nothing. Only the debug log prints the start of the line in plain text.
  make_sdcard.sh checks this.
- WiFi: WPA2-PSK on 2.4 GHz only. The firmware connects with WPA2, so open and WPA3-only
  networks do not work. The Pico's radio has no 5 GHz band.
- FAT32 has no file permissions. The WiFi password and the RA token are in config.ini in
  plain text, and the machine's FTP server serves the card to anyone on the network. Before
  lending the machine, delete config.ini from the card.

Source code, build instructions and licence: https://github.com/scullymi/game20k
