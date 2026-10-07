-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
-- a coin, a one player start, then fire every 0.25 s and steer left and right until the
-- ship is lost (the 54XX plays its explosion)
local ev = {{15.0,"Coin 1",1},{15.15,"Coin 1",0},{16.0,"1 Player Start",1},{16.15,"1 Player Start",0}}
local t = 18.0
while t < 42.0 do
  ev[#ev+1] = {t, "P1 Button 1", 1}; ev[#ev+1] = {t + 0.1, "P1 Button 1", 0}; t = t + 0.25
end
for k = 0, 11 do
  local s = 18.0 + k * 2.0
  local d = (k % 2 == 0) and "P1 Left" or "P1 Right"
  ev[#ev+1] = {s, d, 1}; ev[#ev+1] = {s + 0.8, d, 0}
end
return ev
