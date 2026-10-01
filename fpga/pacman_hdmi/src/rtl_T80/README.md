# T80, Z80 compatible core, Ver 300 with T80sed

Six files by Daniel Wallner, unchanged, copied from
[MiSTer-devel/Arcade-Pacman_MiSTer](https://github.com/MiSTer-devel/Arcade-Pacman_MiSTer) at
commit `648172dec5f9effbfcdc9f4a7897a78b045ea967`, folder `rtl/cpu/`, with the line ends
changed from CRLF to LF. Their headers name the version: `T80.vhd`, `T80_MCode.vhd` and
`T80_Pack.vhd` "Ver 300 started tidyup, MikeJ March 2005" (fpgaarcade), `T80_ALU.vhd` "Ver 301
parity flag ... by Sean Riddle", `T80_Reg.vhd` Wallner's 0242, and `T80sed.vhd` MikeJ's
synchronous top "CUSTOM 2 CLOCK MEMORY ACCESS FOR PACMAN": one T state per two pixel clocks,
which is what the Pac-Man core's sync bus expects. The core instantiates `T80sed`.

This is not the same T80 as `fpga/galaga_hdmi/src/rtl_T80` (Wallner's 0242 to 0247 with
`T80se`): `T80.vhd`, `T80_ALU`, `T80_MCode` and `T80_Pack` differ, only `T80_Reg` is the same
file. Both sets declare the same entity names, so one build must never add both; each
game's `build.tcl` adds only its own folder, and a shared file list would have to keep it that
way.

The licence is in the header of every file, BSD-style with three conditions. One of them
concerns bitstreams: "Redistributions in synthesized form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the documentation and/or other
materials provided with the distribution." A published bitstream needs this notice next to it.
