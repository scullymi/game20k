# jotego's JT49 (AY-3-8910)

The files under `hdl/` are copied unchanged from [jotego/jt49](https://github.com/jotego/jt49)
at commit `7f6abfd08a2af9a92dbd5b32c71ea773248a77e2` (1 February 2025), folder `hdl/`. That is
the commit jtcores `0b197caeae15` pulls in through jt12 (`cores/1942/cfg/files.yaml`: jt12,
`jt49.yaml`). 1942 has two AY-3-8910 on its sound board.

Author: Jose Tejada Gomez (jotego). Licence: GPL-3.0-or-later, see the file heads.

To check the copy:

```sh
git clone https://github.com/jotego/jt49.git /tmp/jt49
git -C /tmp/jt49 checkout 7f6abfd08a2af9a92dbd5b32c71ea773248a77e2
for f in fpga/g1942_hdmi/src/jt49/hdl/*.v; do cmp -s "$f" "/tmp/jt49/hdl/$(basename "$f")" || echo "differs: $f"; done
```
