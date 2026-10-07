-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
-- Plays the input script EVFILE: a Lua file that returns a list of {seconds, field, value},
-- field as MAME names it ("Coin 1", "1 Player Start", "P1 Button 1", "P1 Left", "P1 Right").
-- Values change at the end of the first frame at or after their time. Returns a function
-- that starts the script; its optional argument on_input(t_us, name, value) is called for
-- every change.
return function(on_input)
  local m = manager.machine
  local fields = {}
  for _, p in pairs({":IN0", ":IN1"}) do
    for name, f in pairs(m.ioport.ports[p].fields) do fields[name] = f end
  end
  local ev = dofile(os.getenv("EVFILE"))
  table.sort(ev, function(a, b) return a[1] < b[1] end)
  local i = 1
  emu.register_frame_done(function()
    local t = m.time:as_double()
    while ev[i] and t >= ev[i][1] do
      fields[ev[i][2]]:set_value(ev[i][3])
      if on_input then on_input(math.floor(t * 1e6 + 0.5), ev[i][2], ev[i][3]) end
      i = i + 1
    end
  end)
end
