# T80, Z80 compatible core

Six files by Daniel Wallner, versions 0242 to 0247 as their headers state, unchanged, copied from
[DECAfpga/Arcade_Galaga](https://github.com/DECAfpga/Arcade_Galaga) at commit
`e06ba91d713702f8cde229ace2eacd7ad0f89855`, folder `rtl_T80/`. Dar's Galaga core instantiates
`T80se`. The other files of that folder are not needed and were not copied: `T80a`, `T80s`,
`T8080se`, `T80_RegX` as the Xilinx variant of `T80_Reg`, the debug system with its `T16450`
UART, and the RAM models.

The licence is in the header of every file, BSD-style with three conditions. One of them
concerns bitstreams: "Redistributions in synthesized form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the documentation and/or other
materials provided with the distribution." A published bitstream needs this notice next to it.
