# roms

Put your own ROM files here. Nothing in this folder is committed, `.gitignore` excludes it.

- `galaga.zip`: the MAME set `galaga` (parent, Namco Rev B), as a merged set. Required.
- `namco54.zip`: optional, without it the explosion sounds are missing.

`scripts/make_sdcard.sh` checks the size of every file inside and builds `sdcard/galaga.rom`
(38944 bytes) from them, see [sdcard/README.md](../sdcard/README.md).
