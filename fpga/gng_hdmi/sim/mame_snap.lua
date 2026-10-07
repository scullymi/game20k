-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
-- MAME autoboot script for compare_mame.py: one snapshot per frame (fNNNN.png with
-- -snapname 'f%i'), quit after GNG_LAST frames. GNG_COIN and GNG_START press coin 1 and
-- start 1 for GNG_HOLD frames from that frame on, to follow the inputs of tb_gng.sv.
-- Without a window (the set is gngb in MAME 0.289, gng.zip copied or linked under that name):
--   SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy mame gngb -rompath <dir> -video none
--   -sound none -keyboardprovider none -mouseprovider none -joystickprovider none
--   -nothrottle -skip_gameinfo -snapshot_directory <out> -snapname 'f%i'
--   -autoboot_script mame_snap.lua
local LAST = tonumber(os.getenv("GNG_LAST") or "700")
local COIN = tonumber(os.getenv("GNG_COIN") or "-1")
local START = tonumber(os.getenv("GNG_START") or "-1")
local HOLD = tonumber(os.getenv("GNG_HOLD") or "3")
local n = 0
local function field(port, name)
  local p = manager.machine.ioport.ports[port]
  for k, f in pairs(p.fields) do if k == name then return f end end
end
local coin = field(":SYSTEM", "Coin 1")
local start = field(":SYSTEM", "1 Player Start")
emu.register_frame_done(function()
  if coin then coin:set_value((COIN >= 0 and n >= COIN and n < COIN + HOLD) and 1 or 0) end
  if start then start:set_value((START >= 0 and n >= START and n < START + HOLD) and 1 or 0) end
  manager.machine.video:snapshot()
  n = n + 1
  if n > LAST then manager.machine:exit() end
end)
