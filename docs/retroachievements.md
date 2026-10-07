# RetroAchievements

The FPGA core runs the game's original program on the rebuilt arcade board. Every frame it
mirrors the game's RAM to the Pico 2 W, where
[rcheevos](https://github.com/RetroAchievements/rcheevos) checks the conditions of the
achievement set. Unlocks go to retroachievements.org over HTTPS, wait on the SD card while
offline, and appear as a banner in the game.

![Unlock banner, achievement list, account and version](images/retroachievements.png)

## Account

You do not need RetroAchievements to play. **With an account**, the firmware downloads the
game's achievement set at startup and keeps it on the card as `ra/<id>/patch.json`, where
`<id>` is the game's RetroAchievements ID (Galaga: `ra/12138/`). This way the set is available
at the next power-up, even without a network. **Without an account**, the device does not
contact the server and downloads nothing. A set that is already on the card still runs, but
its unlocks are neither sent nor kept.

**With an account:**

```sh
cp sdcard/config.ini.example sdcard/config.ini && chmod 600 sdcard/config.ini
```

`sdcard/config.ini` is the only place for credentials. It is the same file that goes onto the SD
card and that the device reads, and `.gitignore` keeps it out of the repository. Enter your WiFi
details under `[WIFI]`. Under `[RA]`, enter your account name and your connect token, and remove
the `;` in front of those two lines.

The connect token is a 16-character key that RetroAchievements issues to clients. The device
logs in with it, so your password is never stored. You only need to get it once:

```sh
curl -s -A 'game20k (token request with curl)' https://retroachievements.org/dorequest.php \
  --data-urlencode 'r=login2' --data-urlencode 'u=YOURNAME' --data-urlencode 'p=YOURPASSWORD'
```

Copy the `Token` field from the reply into `[RA] TOKEN=`. The `-A` option is needed because
RetroAchievements rejects requests with curl's default User-Agent. The web API key in your
account settings is something different and does not work here. A regular account with a
confirmed email address is all you need.

> The token and the WiFi key are stored on the card in plain text, and anyone on your network can
> read them over FTP. Read [PRIVACY.md](../PRIVACY.md#local-risks) before lending the cabinet to
> someone.

## The menu

The `RetroAchievements` menu holds the mode, the achievement list with progress, and the account.
`Mode` switches between hardcore (the default) and softcore. Softcore takes effect immediately.
Switching to hardcore first resets the running game, as RetroAchievements requires, and the
banner shows the mode each time a game starts. In hardcore mode, the server's warning follows,
which reads "Unknown Emulator" until RetroAchievements approves this client. Also in hardcore,
FTP cannot modify the `ra_*` files, the `ra` folder or `config.ini`. `Account` shows the login,
the unlocks and anything still waiting to be sent to the server. Without a connection,
achievements still count: their unlocks are queued on the card and sent once the server can be
reached.

## Hardcore

RetroAchievements approves each new client manually. Everything on the device side is ready.
Until then, the server records unlocks as softcore and stores no leaderboard entries, see
[status.md](status.md).
