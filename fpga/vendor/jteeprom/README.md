# jteeprom

The files under `hdl/` are copied from [jotego/jteeprom](https://github.com/jotego/jteeprom) at commit
`9c68ce841f4ec560ca6f228c8af6301129fd95fa`, the submodule commit of jtcores `548b87b`: the 93C46 EEPROM (jt9346), only the files jtpang uses.
Author Jose Tejada Gomez (jotego), GPL version 3 or later, see the file heads and `LICENSE`.

Changed here: `hdl/jt9346.v`, the write mode of `jt9346_dual_ram`: Gowin's normal write mode instead of read-before-write, which the GW2AR-18C place and route rejects (PA2122), as in `jtframe_dual_ram.v`. Marked `game20k`. The other file is byte for byte the upstream one.
