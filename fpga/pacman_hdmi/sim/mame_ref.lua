-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
-- game20k: MAME's frames for tb_system.vhd, run by run_system_sim.sh with the SDL dummy
-- drivers and -norotate, so the snapshots are in the core's raster (288 x 224). Environment:
--   LAST     the last frame; every frame from FIRST (default 0) to it goes to mNNNN.png,
--            counted from 0
--   PORTS    the two input ports, "IN0 IN1" (Pac-Man) or "P1 P2" (Jr. Pac-Man)
--   INPUTS   optional: the testbench's inputs.txt ("F IN0 IN1" per line, active low hex)
--   OFS      the offset d of the run: the simulation's frame k is MAME's frame k + d
-- After the snapshot of frame m the inputs of the simulation's frame m + 1 - d apply, as
-- tb_system.vhd applies those of frame k + 1 when its frame k ends. Every field of the two
-- ports that is not a DIP switch follows its bit in the byte, 0 = pressed.
local last = tonumber(os.getenv("LAST"))
local first = tonumber(os.getenv("FIRST") or "0")
local ofs = tonumber(os.getenv("OFS") or "0")
local tags = {}
for t in string.gmatch(os.getenv("PORTS") or "IN0 IN1", "%S+") do tags[#tags + 1] = ":" .. t end
local script = {}
local path = os.getenv("INPUTS")
if path and path ~= "" then
  for line in io.lines(path) do
    local f, a, b = string.match(line, "^%s*(%d+)%s+(%x+)%s+(%x+)")
    if f then script[#script + 1] = {tonumber(f), tonumber(a, 16), tonumber(b, 16)} end
  end
end

-- the bytes that hold in the simulation's frame s
local function bytes_at(s)
  local v = {0xFF, 0xFF}
  for _, e in ipairs(script) do
    if e[1] <= s then v = {e[2], e[3]} else break end
  end
  return v
end

local function apply(v)
  for i, tag in ipairs(tags) do
    local port = manager.machine.ioport.ports[tag]
    for _, field in pairs(port.fields) do
      if field.type_class ~= "dipswitch" and field.type_class ~= "config" then
        field:set_value(((v[i] & field.mask) == 0) and 1 or 0)
      end
    end
  end
end

local n = 0
emu.register_frame_done(function()
  if n >= first then manager.machine.screens[":screen"]:snapshot(string.format("m%04d.png", n)) end
  n = n + 1
  if #script > 0 then apply(bytes_at(n - ofs)) end
  if n > last then manager.machine:exit() end
end)
