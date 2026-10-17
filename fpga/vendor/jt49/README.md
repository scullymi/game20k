# jotego's JT49 (AY-3-8910)

The files under `hdl/` are copied unchanged from [jotego/jt49](https://github.com/jotego/jt49)
at commit `6f1247fe0282a70c86ea2b4d8aa901f5332c94db` (11 October 2026), folder `hdl/`. That is
the commit jt12 `efa4068` pulls in as its submodule `jt49`. 1942 has
two AY-3-8910 on its sound board. Each YM2203 of 1943 and Ghosts'n Goblins contains an
AY-3-8910 compatible SSG, which jt12 builds from jt49. Only 1942 uses `jt49_bus.v`. `LICENSE`
is the licence file of the repository.

Author: Jose Tejada Gomez (jotego). Licence: GPL-3.0-or-later, see the file heads.

To check the copy:

```sh
git clone https://github.com/jotego/jt49.git /tmp/jt49
git -C /tmp/jt49 checkout 6f1247fe0282a70c86ea2b4d8aa901f5332c94db
cd fpga/vendor/jt49
for f in LICENSE hdl/*.v; do cmp -s "$f" "/tmp/jt49/$f" || echo "differs: $f"; done
```
