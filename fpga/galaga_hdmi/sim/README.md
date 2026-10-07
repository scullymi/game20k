# Galaga: the Namco MCUs against MAME

Checks with [nvc](https://www.nickg.me.uk/nvc/), all against recordings from MAME:

- **trace**: `mb88.vhd` runs the 51XX or 54XX program in lock step with a MAME debugger trace
  of the same program. The bench feeds the inputs MAME saw at the same instruction and
  compares PC, A, X, Y, SI, PIO, TH and TL before every instruction.
- **replay**: `namco_io.vhd` (06XX and 51XX) gets the main CPU's 06XX accesses of a MAME run
  at their time, and every read must return what MAME read.
- `tb_namco54.vhd` replays the same log with the 54XX on chip select 3 and lists every nibble
  it reads, to compare with its MAME trace.

Both replay benches take `SHIFT_US`: the data accesses come that much later than in MAME, as
with a main CPU whose NMI handler is slower. It shows how much room the MCUs have before they
read a byte that is not written yet.

Recordings hold or derive from ROM data: keep them outside the tree.

## Recording

MAME needs `galaga.zip`, `namco51.zip` and `namco54.zip` in `roms/`. The SDL dummy drivers keep
MAME in the background, without a window:

```sh
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
M="mame galaga -rompath roms -video none -sound none -nothrottle -skip_gameinfo \
   -keyboardprovider none -mouseprovider none -joystickprovider none"
S=fpga/galaga_hdmi/sim/mame
OUT=/path/outside/the/tree

# instruction trace of the 51XX (starts at $07E) or the 54XX (at $000)
MCU=51xx START=07E TRACE=$OUT/t51.log EVDRIVER=$S/events.lua EVFILE=$S/attract.lua \
  $M -debug -debugger none -autoboot_script $S/mcu_trace.lua -seconds_to_run 24

# the 06XX accesses of the main CPU
BUSLOG=$OUT/bus.log EVDRIVER=$S/events.lua EVFILE=$S/attract.lua \
  $M -autoboot_script $S/bus_log.lua -seconds_to_run 24
```

`attract.lua` presses fire and steers during the attract mode, inserts two coins and starts a
game. `play.lua` plays until the ship is lost, which is the only time the 54XX gets a command
besides the self test (run 44 seconds).

## Checking

```sh
sh fpga/galaga_hdmi/sim/run_mcu_sim.sh trace  $OUT/t51.log  51xx.bin
sh fpga/galaga_hdmi/sim/run_mcu_sim.sh replay $OUT/bus.log  51xx.bin
```

`trace` ends with `PASS: <n> steps in lock step with MAME` or stops at the first difference.
`replay` ends with the number of reads and of differences.
