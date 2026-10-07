-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
-- input script for events.lua: fire and steering during the attract demo, first without
-- credit, then with a credit in, then a one player start
local ev = {{26.0,"Coin 1",1},{26.15,"Coin 1",0},{31.0,"1 Player Start",1},{31.15,"1 Player Start",0}}
local t = 15.0
while t < 30.5 do
  ev[#ev+1] = {t, "P1 Button 1", 1}; ev[#ev+1] = {t + 0.2, "P1 Button 1", 0}; t = t + 0.5
end
for k = 0, 7 do
  local s = 15.25 + k * 2.0
  local d = (k % 2 == 0) and "P1 Left" or "P1 Right"
  ev[#ev+1] = {s, d, 1}; ev[#ev+1] = {s + 0.9, d, 0}
end
return ev
