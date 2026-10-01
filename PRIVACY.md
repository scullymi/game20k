# Privacy policy

This policy covers game20k: the firmware for the Raspberry Pi Pico 2 W, the Galaga core for the
Tang Nano 20K, and this repository.

## In short

- The project operates no servers and collects nothing. The firmware reports nothing to the
  project: no analytics, no telemetry, no crash reports and no update check.
- With a RetroAchievements account, the device sends retroachievements.org your unlocks, your
  scores and, every two minutes, a short description of what happens in the game.
  RetroAchievements' [privacy policy](https://retroachievements.org/terms#privacy-policy)
  applies to that data.

## Who is responsible

game20k is maintained by scullymi. For questions about this policy, open an issue at
https://github.com/scullymi/game20k/issues. Issues are public and show your GitHub account.
Never post your token, password or WiFi key there, and check a debug log for secrets before you
paste it.

## What the device sends, and to whom

Without WiFi settings in `config.ini` and without a USB network adapter, the device has no
network and contacts no server. Bluetooth is always on: devices nearby can see the name "MiSTle
FPGA Companion" and the Pico's Bluetooth address.

### To RetroAchievements

The device contacts RetroAchievements only when `config.ini` holds an account name and token. It
connects to retroachievements.org over HTTPS, checks the server's certificate and sends:

| When | What |
|---|---|
| At start, until the server answers | The game's hash, made from the ROM set name "galaga". No account data. |
| Once per power-on, after the start check | Requests to log in, start the session and load the achievement set and the list of your unlocks, with game ID and hash, hardcore or softcore, and the rcheevos version |
| Every two minutes while the game runs, including attract mode | The rich presence text, a short description of what happens in the game, with game ID, hash and mode |
| For each unlock | Achievement ID, mode, game hash, how many seconds ago it happened if known, and a checksum. The list of your unlocks is then loaded again. |
| For each leaderboard result in hardcore | Leaderboard ID, your score, game hash, how many seconds ago it happened, and a checksum |

Every request except the start check carries your account name and token in its URL. The
User-Agent names the firmware and its version. The connection is encrypted up to Cloudflare,
which runs in front of RetroAchievements. Both see your public IP address and may log request
URLs, token included.

Your RetroAchievements password never reaches the device. You use it once, on your computer, to
get the token.

### To a time server

As soon as it has a network address, the device asks a time server for the time over NTP, and
again about once an hour after that. The certificate check and the file dates need the correct
time. The device asks the first server under `[NTP]` `IP=` in `config.ini`, and the second only
if the first does not answer. Without that line it asks the one your router names. A time
request holds no personal data, but the server sees your IP address.

### To your own network

Your router gives the device its address over DHCP and sees the device's hardware address and,
on WiFi, the name "PicoW". With an account, the device looks up "retroachievements.org" with the
name server your router names. It looks up no other name and contacts no servers other than the
ones named in this policy. On your network it answers ping, FTP and telnet. "Local risks" covers
the last two.

## What the device stores, and for how long

The files on the SD card are plain text.

| Where | Contents | Kept until |
|---|---|---|
| `config.ini` | WiFi name and key, RetroAchievements account name and token, network, time and menu settings | you delete it |
| `galaga.ini` | Menu settings, including hardcore or softcore | you delete it |
| `ra_pending.txt` | Unlocks waiting for the server: achievement ID, time, account name, mode, the game's hash, and a tag made with the device key. Sent lines stay, marked with `#`. | the device deletes it once all are sent or set aside |
| `ra_parked.txt` | Unlocks that will not be sent, in the same format, for example those of another account | you delete it |
| `ra/<id>/unlocked.txt` | Your account name, the game ID and your account's achievements per mode, one folder per game, named by the game's ID on RetroAchievements (Galaga: `ra/12138/`) | you delete it. The device rewrites it when the server's lists change. |
| `ra/<id>/patch.json`, `ra/<id>/patch.mac` | The achievement set with the names of its authors, and a tag over it. Nothing about you. | the device replaces them when the set changes |
| Flash: device key | 32 random bytes made at the first start. With them the device tells its own card files from edited ones. The key never leaves the device and holds nothing about you. | you erase the flash |
| Flash: Bluetooth pairings | Address and link key of each device that pairs, up to 16. The Pico is always discoverable and pairs without confirmation. | a 17th replaces the oldest, or you erase the flash |
| Memory | Up to four hardcore leaderboard results and up to eight unlocks the card could not take | the server or the card has them, or power-off |

The debug log is not stored. It goes to the Pico's serial port and to telnet port 23. It shows
your account name, the WiFi name, network and time settings, your game progress, and the
connected USB devices and nearby Bluetooth devices. The token and the WiFi key appear only as
their length, with one exception under "Local risks".

To remove your data from the SD card, delete `config.ini`, `galaga.ini`, all `ra_*` files and
the folder `ra`.
Deleted files can be recovered until they are overwritten, so wipe the card before you give it
away. To make the token on it useless, use "Sign Out of All Emulators" in your RetroAchievements
settings. A firmware update keeps the device key and the pairings. Erasing the Pico's flash
removes them, and the firmware with them.

## Where the servers are

- The project: none. It operates no servers, so it keeps no data in any country and has no
  retention period.
- RetroAchievements: retroachievements.org, served through Cloudflare. RetroAchievements decides
  where and for how long it keeps your data.
- Time servers: the ones in your `config.ini`, or your router's. The two in the example
  `config.ini` belong to Cloudflare and Google, both US companies.
- DHCP and DNS: your router and the name server it names.

Time servers, your router, your DNS provider and your internet provider keep their logs under
their own rules.

## GDPR

The device sends no data to the project, and the project has no access to the device. The data
on your device is under your control, and you can delete it as described above.

RetroAchievements is responsible for the data your device sends to it. To access, correct or
delete that data, contact RetroAchievements. Issues you open and downloads of game20k go through
GitHub, whose privacy statement applies to them. For questions about this project, open an
issue.

## Local risks

These are known weaknesses of the device. FTP and telnet run whenever the device has a network,
and they cannot be switched off.

- **FTP without a password.** The FTP server on port 21 accepts any login and does not encrypt.
  Anyone on your network can read and change the files on the SD card, including `config.ini`
  with your WiFi key and token. While hardcore is active, `config.ini`, the `ra_*` files and
  the folder `ra` cannot be changed over FTP, but they can still be read.
- **Telnet without a password.** Anyone on your network can connect to port 23 and read the
  debug log from then on.
- **Long lines in `config.ini`.** A line longer than 62 bytes, 61 with Windows line endings, can
  be skipped, and so can a last line without a line break. Up to 63 bytes of it then appear in
  plain text in the debug log on the serial port at start-up. That can be the WiFi key or the
  token.
- **The SD card has no protection.** Whoever holds the card can read `config.ini`, the `ra_*`
  files show your account name and unlock times, and the folder `ra` your account name and
  unlocks. Before you lend the device, remove `config.ini`, and the `ra_*` files and the folder
  `ra` too if the borrower should not see your account name.

Use the device only on a network you trust, and never forward any port from the internet to it.

## Changes

This file is part of the repository, so every change is published here and shows in its git
history.
