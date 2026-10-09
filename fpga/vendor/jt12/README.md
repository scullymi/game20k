# jotego's JT12 (YM2203 as jt03)

The files under `hdl/` are copied from [jotego/jt12](https://github.com/jotego/jt12) at commit
`dc9be7c1ff75d5b9a7f9d89da1b7fba212af1257` (1 September 2026), folder `hdl/`, with its
subfolder `adpcm/`. That is the commit jtcores `548b87b` pulls in as its submodule
`modules/jt12`. 1943 and Ghosts'n Goblins each have two YM2203 on their sound board, which
`jtgng_sound.v` instantiates as `jt03`. Only the files `jt03` needs are copied. `LICENSE` is the
licence file of the repository. The SSG part of each YM2203 is jt49, see `../jt49/README.md`.

Author: Jose Tejada Gomez (jotego). Licence: GPL-3.0-or-later, see the file heads.

## What changed, and why

The change is marked `game20k` in the text.

- **`hdl/jt12_rst.v`:** the reset is registered on the rising instead of the falling clock
  edge, as in `jtgng_sound.v` (see `../jtcores/README.md`). On the falling edge the path has
  only half a clock, which fails timing on the GW2AR-18C.

To check the copy:

```sh
git clone https://github.com/jotego/jt12.git /tmp/jt12
git -C /tmp/jt12 checkout dc9be7c1ff75d5b9a7f9d89da1b7fba212af1257
cd fpga/vendor/jt12
for f in LICENSE $(find hdl -type f); do cmp -s "$f" "/tmp/jt12/$f" || echo "differs: $f"; done
```

It lists only `hdl/jt12_rst.v`.
