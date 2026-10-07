-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
-- Reference run of Dig Dug in MAME for compare.py: one snapshot per frame up to
-- DD_LAST, a coin at frame DD_COIN and a start at DD_START (held 6 frames each), from DD_MOVES
-- on the stick and the pump (as in tb_digdug.sv), and with DD_LOG every access of the main CPU
-- to the 06XX in the format of the testbench's io.log. Without a window:
--   SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy DD_LAST=2400 DD_LOG=io.log \
--   mame digdug -rompath <roms> -noreadconfig -video none -sound none -keyboardprovider none \
--     -mouseprovider none -joystickprovider none -nothrottle -skip_gameinfo \
--     -snapshot_directory snap -nvram_directory nvram -cfg_directory cfg \
--     -autoboot_script mame_ref.lua
-- An empty nvram directory matters: MAME keeps the EAROM (high scores) there.
local LAST = tonumber(os.getenv("DD_LAST") or "1200")
local COIN = tonumber(os.getenv("DD_COIN") or "-1")
local START = tonumber(os.getenv("DD_START") or "-1")
local MOVES = tonumber(os.getenv("DD_MOVES") or "-1")
local LOG = os.getenv("DD_LOG")
local frame = 0
local logf = LOG and io.open(LOG, "w")
local prog = manager.machine.devices[":maincpu"].spaces["program"]
-- global: a tap whose handle is collected is removed
taps = {}
if logf then
  taps[1] = prog:install_read_tap(0x7000, 0x70ff, "r06", function(offset, data, mask)
    logf:write(string.format("%d R %04x %02x\n", frame, offset, data & 0xff)); return data end)
  taps[2] = prog:install_write_tap(0x7000, 0x7100, "w06", function(offset, data, mask)
    logf:write(string.format("%d W %04x %02x\n", frame, offset, data & 0xff)); return data end)
end
local ports = manager.machine.ioport.ports
local function set(name, v)
  for _, p in pairs(ports) do
    for n, f in pairs(p.fields) do if n == name then f:set_value(v) end end
  end
end
-- right 90 frames, down 60, the pump 8 frames on and 8 off for 120, left 90, up 60
local function moves(n)
  local d = ""
  if n >= 0 then
    if n < 90 then d = "P1 Right" elseif n < 150 then d = "P1 Down"
    elseif n >= 270 and n < 360 then d = "P1 Left" elseif n >= 270 and n < 420 then d = "P1 Up" end
  end
  for _, s in ipairs({"P1 Up", "P1 Down", "P1 Left", "P1 Right"}) do set(s, s == d and 1 or 0) end
  set("P1 Button 1", (n >= 150 and n < 270 and ((n - 150) // 8) % 2 == 0) and 1 or 0)
end
sub = emu.add_machine_frame_notifier(function()
  manager.machine.video:snapshot()
  if frame == COIN then set("Coin 1", 1) end
  if frame == COIN + 6 then set("Coin 1", 0) end
  if frame == START then set("1 Player Start", 1) end
  if frame == START + 6 then set("1 Player Start", 0) end
  if MOVES >= 0 then moves(frame - MOVES) end
  frame = frame + 1
  if frame > LAST then
    if logf then logf:close() end
    manager.machine:exit()
  end
end)
