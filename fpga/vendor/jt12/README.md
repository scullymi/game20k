# jotego's JT12 (YM2203 as jt03)

The files under `hdl/` are copied from [jotego/jt12](https://github.com/jotego/jt12) at commit
`d495f64f7e7519401692ce3ce990944f2aa31e1f` (9 October 2026), folder `hdl/`, with its
subfolder `adpcm/`. jtcores `548b87b` still pulls in the older `dc9be7c` as its submodule
`modules/jt12`. 1943 and Ghosts'n Goblins each have two YM2203 on their sound board, which
`jtgng_sound.v` instantiates as `jt03`. Only the files `jt03` needs are copied. `LICENSE` is the
licence file of the repository. The SSG part of each YM2203 is jt49, see `../jt49/README.md`.

Author: Jose Tejada Gomez (jotego). Licence: GPL-3.0-or-later, see the file heads.

## What changed, and why

Each change is marked `game20k` in the text.

- **`hdl/jt12_rst.v`:** the reset is registered on the rising instead of the falling clock
  edge, as in `jtgng_sound.v` (see `../jtcores/README.md`). On the falling edge the path has
  only half a clock, which fails timing on the GW2AR-18C.
- **`hdl/jt12_top.v`:** the SSG keeps level table 1 (`COMP`), as in jt12 `dc9be7c`. Upstream
  gives the YM2203 table 5, which comes with jt49 `441eea8`. That commit is not on GitHub, and
  the jt49 copy here has no table 5.

To check the copy:

```sh
git clone https://github.com/jotego/jt12.git /tmp/jt12
git -C /tmp/jt12 checkout d495f64f7e7519401692ce3ce990944f2aa31e1f
cd fpga/vendor/jt12
for f in LICENSE $(find hdl -type f); do cmp -s "$f" "/tmp/jt12/$f" || echo "differs: $f"; done
```

It lists only `hdl/jt12_rst.v` and `hdl/jt12_top.v`.
