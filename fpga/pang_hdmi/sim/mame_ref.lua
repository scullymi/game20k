-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 scullymi
-- game20k: reference data from MAME for tb_pang.sv, run by run_sim.sh with the SDL dummy
-- drivers (no window, no sound). Environment:
--   MODE=views   the main CPU's ROM as its data reads and its opcode fetches see it, the
--                fixed 32 KiB and then NBANKS banks of 16 KiB, to OUT and OUT.op
--   MODE=frames  a snapshot of every EVERY-th frame up to LAST as mNNNN.png in the snapshot
--                directory, frames counted from 0; coin from COIN_F and start 1 from START_F
--                for 6 frames each (0 for none), button 1 FIRE_N times every 30 frames from FIRE_F
local mode = os.getenv("MODE")
local n = 0
local function press(port, field, on)
  manager.machine.ioport.ports[port].fields[field]:set_value(on and 1 or 0)
end
emu.register_frame_done(function()
  if mode == "views" then
    local cpu = manager.machine.devices[":maincpu"]
    local prg, op, iosp = cpu.spaces["program"], cpu.spaces["opcodes"], cpu.spaces["io"]
    local fd, fo = io.open(os.getenv("OUT"), "wb"), io.open(os.getenv("OUT") .. ".op", "wb")
    local function span(lo, hi)
      local d, o = {}, {}
      for a = lo, hi do d[#d + 1] = string.char(prg:read_u8(a)); o[#o + 1] = string.char(op:read_u8(a)) end
      fd:write(table.concat(d)); fo:write(table.concat(o))
    end
    span(0x0000, 0x7FFF)
    for b = 0, tonumber(os.getenv("NBANKS")) - 1 do
      iosp:write_u8(2, b)          -- the bank register, port 02
      span(0x8000, 0xBFFF)
    end
    fd:close(); fo:close()
    manager.machine:exit()
    return
  end
  local every, last = tonumber(os.getenv("EVERY")), tonumber(os.getenv("LAST"))
  local coin_f, start_f = tonumber(os.getenv("COIN_F") or "0"), tonumber(os.getenv("START_F") or "0")
  local fire_f, fire_n = tonumber(os.getenv("FIRE_F") or "0"), tonumber(os.getenv("FIRE_N") or "1")
  if n % every == 0 then manager.machine.screens[":screen"]:snapshot(string.format("m%04d.png", n)) end
  n = n + 1
  if coin_f ~= 0 then press(":IN0", "Coin 1", n >= coin_f and n < coin_f + 6) end
  if start_f ~= 0 then press(":IN0", "1 Player Start", n >= start_f and n < start_f + 6) end
  if fire_f ~= 0 then
    press(":IN1", "P1 Button 1", n >= fire_f and n < fire_f + 30 * fire_n and (n - fire_f) % 30 < 6)
  end
  if n > last then manager.machine:exit() end
end)
