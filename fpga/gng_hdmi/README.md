# Ghosts'n Goblins

jotego's jtgng on the game20k platform: `scripts/build_fpga.sh gng_hdmi`, simulation in
[`sim/`](sim/run_sim.sh). Landscape only: the core raster stands upright (`screen upright` in
the manifest) and goes through the scaler as it is, with the menu and the RetroAchievements
banner upright as well.

## Sources and licences

| Folder | Upstream | Author | Licence |
|---|---|---|---|
| `src/jtcores/` | [jotego/jtcores](https://github.com/jotego/jtcores) at `548b87b`, `cores/gng/hdl` and `modules/jtframe/hdl` | Jose Tejada Gomez | GPL-3.0-or-later, in every header |
| `src/jtcores/modules/jtframe/hdl/cpu/mc6809i.v` | the same, jotego's changed copy of [cavnex/mc6809](https://github.com/cavnex/mc6809) (`17e94a6`) | Greg Miller, changes by Jose Tejada Gomez | BSD, three clauses: [`mc6809i_LICENSE.md`](src/jtcores/modules/jtframe/hdl/cpu/mc6809i_LICENSE.md) is the author's licence file. The author offers a standard BSD licence and a binary-only variant, this copy uses the standard BSD licence. jotego's copy carries only the copyright line |
| `src/jtcores/modules/jtframe/hdl/cpu/t80/` | the same, the T80 | Daniel Wallner and others | BSD-like with three conditions, in every header |
| `src/jt12/`, `src/jt49/` | [jotego/jt12](https://github.com/jotego/jt12) at `dc9be7c`, [jotego/jt49](https://github.com/jotego/jt49) at `7f6abfd` | Jose Tejada Gomez | GPL-3.0-or-later, `LICENSE` in each folder |

Changed copies say so in their head and mark each change with `game20k`:
`jtframe_dual_ram.v` (Gowin write mode), `jt12_rst.v` and `jtgng_sound.v` (reset on the rising
edge), `jtgng_game.v` (clock enables from outside, mirror tap) and `jtgng_main.v` (mirror tap).
The files directly in `src/`, `sim/`, the manifest and the menu are GPL-3.0-only.
