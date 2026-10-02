# roms

Put your own MAME sets here. Nothing in this folder is committed, `.gitignore` excludes it.

| Game | Zip |
|---|---|
| Galaga | `galaga.zip`, the MAME set `galaga` (parent, Namco Rev B), merged. Optionally `namco54.zip` for the explosion sounds |
| Pac-Man | `pacman.zip` |
| Puck Man | `puckman.zip` |
| Ms. Pac-Man | `mspacman.zip` |

`scripts/make_sdcard.sh` builds a ROM file for every game whose set is here and checks the size
and SHA-1 of every chip against MAME, as the game's manifest (`fpga/<core>/<set>.manifest`)
lists them. See [sdcard/README.md](../sdcard/README.md) for what goes onto the card.
