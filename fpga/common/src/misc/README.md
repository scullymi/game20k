# Till Harbaum's board files

Seven files from two repositories of Till Harbaum (MiSTle-Dev), from the folder `src/misc/` of
each. Till's five files (`hid.v`, `mcu_spi.v`, `osd_u8g2.v`, `sd_card.v`, `sysctrl.v`) are
GPL-3.0-or-later. Upstream they carry no licence header, here they carry the SPDX tag, and the
game20k changes in them are under the same licence, see
[THIRD-PARTY.md](../../../../THIRD-PARTY.md). `sd_rw.v` and `sdcmd_ctrl.v` go back to
[WangXuan95/FPGA-SDcard-Reader](https://github.com/WangXuan95/FPGA-SDcard-Reader), GPL-3.0.

| File | From | Changed here |
|---|---|---|
| `hid.v` | MiSTeryNano `c8e4601fbf7264e13f4b18ac2d452444de6b51c5` | yes: an extra joystick byte for the shoulder, select, start and trigger buttons, the analogue axes for the input test, and the Atari ST `keymap` instance removed with `kbd_row` and `kbd_column` tied to 0, since `atarist_keymap.v` is not copied |
| `mcu_spi.v` | MiSTeryNano, same commit | yes: SPI target 5 passed through, the RAM mirror. `spi_in_cnt` and `spi_target` declared before their first use |
| `osd_u8g2.v` | MiSTeryNano, same commit | yes: input `rotate`, the menu rotated by 90 degrees in landscape mode, `SCALE 4` for 720p, an output `visible` for the top level, the box geometry and the area flags registered and computed one pixel ahead for timing |
| `sysctrl.v` | derived from MiSTeryNano `sysctrl.v`, same commit | our file: the SPI command state machine and its constants are Till's, about 60 lines taken verbatim from the 333-line `sysctrl.v`. Menu ROM, the generic settings and the value strobe for the game are ours |
| `sd_card.v` | Nanomig `df97f033f07b7b4074a2aeb569fe2f6310694e19` | only the licence header. Only Nanomig's version has command 8, the ROM image upload |
| `sd_rw.v` | Nanomig, same commit | yes: `CMD24` gets a retry branch like `CMD17`, seven retries, then back to `READY`. Without it one missing or garbled response leaves the controller in `CMD24` for good, status `0xDC`, and the card is dead until power cycle |
| `sdcmd_ctrl.v` | Nanomig, same commit | no |

Some changes are marked `game20k` in the text, not all. The complete record is the diff against
the upstream commits:

```sh
git clone https://github.com/MiSTle-Dev/MiSTeryNano.git /tmp/MiSTeryNano
git -C /tmp/MiSTeryNano checkout c8e4601fbf7264e13f4b18ac2d452444de6b51c5
git clone https://github.com/MiSTle-Dev/Nanomig.git /tmp/Nanomig
git -C /tmp/Nanomig checkout df97f033f07b7b4074a2aeb569fe2f6310694e19
cd fpga/common/src/misc
for f in hid mcu_spi osd_u8g2; do diff /tmp/MiSTeryNano/src/misc/$f.v $f.v; done
diff /tmp/MiSTeryNano/src/misc/sysctrl.v sysctrl.v
for f in sd_card sd_rw sdcmd_ctrl; do diff /tmp/Nanomig/src/misc/$f.v $f.v; done
```
