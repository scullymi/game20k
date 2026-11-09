# Known issues and plans

## Known issues

- **Hardcore approval.** Unlocks count as softcore until RetroAchievements approves this client.
  Rich Presence, the achievement list in the menu, the hardcore setting that only takes effect
  after a reset, and the chain of proof (device key, ROM digest, set tag, DIP switches applied
  only on reset) are all in place. Plan: request approval from RetroAchievements.
- **FTP and telnet without a password.** Anyone on the network can read the SD card, including
  the Wi-Fi key and the RetroAchievements token, see [PRIVACY.md](../PRIVACY.md#local-risks).
  Plan: make FTP and telnet switchable in `config.ini`, and check whether FTP can support an
  optional password.
- **Wi-Fi.** The firmware only connects via WPA2 and gives up after the attempts at power-on.
  Plan: allow WPA3 networks and keep retrying in the background.

## Plans

- **Sound through a speaker, in addition to HDMI.** Two options: an I2S amplifier module such as
  the MAX98357A on three free FPGA pins, which first requires an I2S output in the FPGA, or the
  sigma-delta output on pin 77 with an external filter and amplifier, see
  [hardware.md](hardware.md#analog-sound-optional).
- **More games.** Every arcade board needs its own core, which is shared by all the games that
  ran on that board. The eight flash slots are taken, so a further core needs a smaller
  bitstream or has to load from the SD card. Candidates:
  - Namco: Galaxian, Xevious, Bosconian
  - Capcom, from jotego's jtcores: Commando, Gun.Smoke, Black Tiger
  - games with an existing Tang Nano port: Donkey Kong, Defender, Centipede, Pooyan, Bagman,
    Crazy Climber
- **Hardcore unlocks and leaderboard entries on RetroAchievements,** once RetroAchievements
  approves this client.
