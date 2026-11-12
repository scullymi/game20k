# game20k: the SD card

This file is also copied onto the card.

The card goes into the slot of the Tang Nano 20K, not the Pico. Use SD, SDHC or SDXC with FAT32
and lowercase ASCII file names, and put everything in the root directory.
In the repository, `python3 g20k.py sdcard` prepares the card, see the repository's README.

## Files on the card

- <set>.rom, one per game, named after its MAME set (galaga.rom, pacman.rom, 1942.rom and so
  on): the games. g20k.py sdcard builds them from your own MAME sets in a layout of its own,
  with a footer that names the game and holds a checksum, so ROM files from anywhere else do
  not work. They are never shipped. Without them, no game starts.
- config.ini: Wi-Fi and RetroAchievements account. Optional: without it, the machine plays
  offline and without achievements.
- galaga.ini, pacman.ini, 1942.ini, 1943.ini, timeplt.ini, gng.ini, digdug.ini, pang.ini: one
  settings file per core, not per game, each with the chosen ROM. pacman.ini, for example, also
  covers Puck Man and Ms. Pac-Man. g20k.py sdcard creates them, and "Save settings" saves your
  current settings into them.
- games.ini: the game that starts at power-on, written by "Save settings". Optional: without
  it, Galaga starts.
- ra_pending.txt, ra_parked.txt and the folder ra: written by the machine. Unlocks waiting to
  be sent, and the achievement set and unlocks of each game. Do not edit.
- README.md: this file.

## First start

Power on. The screen stays dark until LED 5 lights up, which means the ROM has loaded. Press S2
on the Nano to open the menu.

## Things to avoid

- Do not put a config.xml on the card. It replaces the menu built into the firmware, and the
  machine then only plays in softcore.
- Keep every line of config.ini within 125 characters. The firmware drops a longer line, and only
  its debug log says so.
- Wi-Fi works with WPA2 on 2.4 GHz only. Open networks, WPA3-only networks and 5 GHz do not work.
- The Wi-Fi password and the RetroAchievements token are stored in config.ini in plain text, and
  the machine's FTP server lets anyone on the network read the card. Delete config.ini before
  lending the machine to someone.

Source code, build instructions and license: https://github.com/scullymi/game20k
