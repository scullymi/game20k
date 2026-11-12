# Ghosts'n Goblins

jotego's jtgng on the game20k platform: `python3 g20k.py build fpga/gng_hdmi`. Landscape only:
the core raster stands upright (`screen upright` in the manifest) and goes through the scaler as
it is, with the menu and the RetroAchievements banner upright as well.

## Sources and licenses

The game comes from [`../vendor/jtcores/`](../vendor/jtcores/README.md) (`cores/gng/hdl` and
JTFRAME with the T80 and the 6809), the sound chips from [`../vendor/jt12/`](../vendor/jt12/README.md)
and [`../vendor/jt49/`](../vendor/jt49/README.md). [THIRD-PARTY.md](../../THIRD-PARTY.md) lists
their authors, commits and licenses.

Changed copies say so in their head and mark each change with `game20k`:
`jtframe_dual_ram.v` (Gowin write mode), `jt12_rst.v` and `jtgng_sound.v` (reset on the rising
edge), `jt12_top.v` (SSG level table), `jtgng_game.v` (clock enables from outside, mirror tap)
and `jtgng_main.v` (mirror tap).
The files directly in `src/`, `sim/`, the manifest and the menu are GPL-3.0-only.
