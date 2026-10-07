-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
-- MAME autoboot script: the main CPU's accesses to the 06XX (0x7000..0x7100), its writes to
-- the misc latch (0x6820..0x6827) and the input events, for tb_namco_io.vhd.
-- Environment: BUSLOG (output file), EVDRIVER (events.lua), EVFILE (input script).
local m = manager.machine
local out = io.open(os.getenv("BUSLOG"), "w")
local function us() return math.floor(m.time:as_double() * 1e6 + 0.5) end
local function log(kind, off, d) out:write(string.format("%d %s %04X %02X\n", us(), kind, off, d & 0xff)) end
local sp = m.devices[":maincpu"].spaces["program"]
-- the taps stay installed only while referenced
tap_r = sp:install_read_tap(0x7000, 0x7100, "r", function(off, d) log("R", off, d) end)
tap_w = sp:install_write_tap(0x7000, 0x7100, "w", function(off, d) log("W", off, d) end)
tap_l = sp:install_write_tap(0x6820, 0x6827, "l", function(off, d) log("L", off, d) end)
dofile(os.getenv("EVDRIVER"))(function(t, name, v)
  out:write(string.format("%d I %s %d\n", t, (name:gsub(" ", "_")), v))
end)
emu.add_machine_stop_notifier(function() out:close() end)
