-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
-- MAME autoboot script: instruction trace of a Namco MB88 custom for tb_mb88_trace.vhd.
-- Environment: MCU (51xx or 54xx), START (hex address where the trace begins, the first
-- instruction after reset), TRACE (output file), EVDRIVER (events.lua), EVFILE (input script).
-- Needs -debug -debugger none. The breakpoint at START makes the MCU the debugger's current
-- CPU, without that tracelog writes nothing.
local m = manager.machine
local dbg = m.debugger
local tag = ":" .. os.getenv("MCU") .. ":mcu"
m.devices[tag].debug:bpset(tonumber(os.getenv("START"), 16), "",
  'trace ' .. os.getenv("TRACE") .. ',' .. tag ..
  ',noloop,{tracelog "A=%X X=%X Y=%X PA=%X SI=%X PIO=%02X TH=%X TL=%X ",a,x,y,pa,si,pio,th,tl}; bpclear; g')
dofile(os.getenv("EVDRIVER"))()
emu.add_machine_stop_notifier(function() dbg:command('trace off,' .. tag) end)
