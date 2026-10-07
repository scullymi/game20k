# roms

Put your own MAME sets here. Nothing in this folder is committed, `.gitignore` excludes it.

| Game | Zip |
|---|---|
| Galaga | `galaga.zip`, the MAME set `galaga` (parent, Namco Rev B), merged, and `namco51.zip` for the program of the 51XX. Optionally `namco54.zip` for the explosion sounds |
| Pac-Man | `pacman.zip` |
| Puck Man | `puckman.zip` |
| Pac-Man (speedup hack) | `puckman.zip`, merged: the MAME clone `pacmanf` |
| Ms. Pac-Man | `mspacman.zip` |
| Ms. Pac-Man (speedup hack) | `mspacman.zip`, the MAME clone `mspacmnf`, with `pacfast.6f` from the merged `puckman.zip` |
| Jr. Pac-Man | `jrpacman.zip`, the MAME set `jrpacman` (Bally Midway) |
| 1942 | `1942.zip`, the MAME set `1942` (parent, Revision B) |
| Vulgus | `vulgus.zip`, the MAME set `vulgus` (set 1) |
| Pirate Ship Higemaru | `higemaru.zip`, the MAME set `higemaru` |
| 1943: The Battle of Midway | `1943.zip`, the MAME set `1943` (parent, Euro), merged |
| 1943: The Battle of Midway Mark II | `1943mii.zip`, the MAME set `1943mii` (US) |
| Ghosts'n Goblins | `gng.zip`, merged: the chips `gg1.bin` to `gg17.bin`, which current MAME lists as the clone `gngb` |
| Makaimura (Japan) | `gng.zip`, merged: the MAME clone `makaimurg` |
| Dig Dug | `digdug.zip`, the MAME set `digdug` (rev 2), with `namco51.zip` and `namco53.zip` for the programs of the 51XX and 53XX |
| Pang | `pang.zip`, the MAME set `pang` (World) |
| Buster Bros. (US) | `pang.zip`, merged: the MAME clone `bbros` |
| Super Pang | `spang.zip`, the MAME set `spang` (World 900914) |
| Super Buster Bros. (US) | `spang.zip`, merged: the MAME clone `sbbros` |
| Time Pilot | `timeplt.zip`, the MAME set `timeplt` |

`scripts/make_sdcard.sh` builds a ROM file for every game whose set is here and checks the size
and SHA-1 of every chip against MAME, as the game's manifest (`fpga/<core>/<set>.manifest`)
lists them. See [sdcard/README.md](../sdcard/README.md) for what goes onto the card.
