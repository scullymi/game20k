# Known issues and plans

## Known issues

- **Hardcore approval.** Unlocks count as softcore until RetroAchievements approves this client.
  Rich Presence, the achievement list in the menu, the hardcore setting that only takes effect
  after a reset, and the chain of proof (device key, ROM digest, set tag, DIP switches applied
  only on reset) are all in place. Plan: request approval from RetroAchievements.
- **FTP without a password.** The FTP server accepts any login, so anyone on the network can read
  and modify the SD card, including `config.ini` with the WiFi key and the RetroAchievements
  token. Telnet on port 23 shows the debug log to anyone on the network. Plan: make FTP and
  telnet switchable in `config.ini`, and check whether FTP can support an optional password.
- **FPGA timing.** The timing report lists 36 endpoints that fail setup. All 25 that it shows are
  on the SDRAM read path, whose clock phase was measured on the board, and the 371 MHz clock of
  the HDMI serializer is not checked at all. The design works on the tested board. Plan: add
  constraints for both paths so that the report covers them, then fix the violations.
- **WiFi.** The firmware only connects via WPA2 and gives up after the attempts at power-on.
  Plan: allow WPA3 networks and keep retrying in the background.

## Plans

- **Sound through a speaker, in addition to HDMI.** Two options: an I2S amplifier module such as
  the MAX98357A on three free FPGA pins, which first requires an I2S output in the FPGA, or the
  sigma-delta output on pin 77 with an external filter and amplifier, see
  [hardware.md](hardware.md#analogue-sound-optional).
- **More games.** Every arcade board needs its own core, which is shared by all the games that
  ran on that board. The eight flash slots are taken, so a further core needs a smaller
  bitstream or has to load from the SD card. Candidates:
  - Namco: Galaxian, Xevious, Bosconian
  - Capcom, from jotego's jtcores: Commando, Gun.Smoke, Black Tiger
  - games with an existing Tang Nano port: Donkey Kong, Defender, Centipede, Pooyan, Bagman,
    Crazy Climber
- **Hardcore unlocks and leaderboard entries on RetroAchievements,** once RetroAchievements
  approves this client.
