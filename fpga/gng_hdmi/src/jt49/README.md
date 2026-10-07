# jotego's JT49 (AY-3-8910)

The files under `hdl/` are copied unchanged from [jotego/jt49](https://github.com/jotego/jt49)
at commit `7f6abfd08a2af9a92dbd5b32c71ea773248a77e2` (1 February 2025), folder `hdl/`. That is
the commit jt12 `dc9be7c` pulls in as its submodule `jt49`, see `../jt12/README.md`, and the
same files as in the 1943 core. Each YM2203 of Ghosts'n Goblins contains an AY-3-8910
compatible SSG, which jt12 builds from jt49. `LICENSE` is the licence file of the repository.

Author: Jose Tejada Gomez (jotego). Licence: GPL-3.0-or-later, see the file heads.

To check the copy:

```sh
git clone https://github.com/jotego/jt49.git /tmp/jt49
git -C /tmp/jt49 checkout 7f6abfd08a2af9a92dbd5b32c71ea773248a77e2
cd fpga/gng_hdmi/src/jt49
for f in LICENSE hdl/*.v; do cmp -s "$f" "/tmp/jt49/$f" || echo "differs: $f"; done
```
