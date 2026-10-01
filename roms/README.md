# roms

Put your own ROM files here. Nothing in this folder is committed, `.gitignore` excludes it.

- `galaga.zip`: the MAME set `galaga` (parent, Namco Rev B), as a merged set. Required.
- `namco54.zip`: optional, without it the explosion sounds are missing.

`scripts/make_sdcard.sh` builds `sdcard/galaga.rom` (38944 bytes) from them, every chip checked
by size and SHA-1 against MAME as the manifest `fpga/galaga_hdmi/galaga.manifest` lists them,
see [sdcard/README.md](../sdcard/README.md). Sets of other games go here the same way, each
game's manifest names its zip.
