-- glue_telem_test.lua: unit tests for lib/telem.lua.
-- Run: cd "<root>" && lua tests/unit/glue_telem_test.lua

local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
local mock = dofile(here .. "/glue_mock.lua")
mock.install()

local telem = dofile(mock.WIDGET .. "lib/telem.lua")
local opts = { darkTheme = 1, transpLevel = 1, vtxOff = 0, hideTrims = 0, rxCells = 0, extTrims = 0 }

local function sensorsOfModel1()
  mock.add("1RSS", -60); mock.add("2RSS", -70); mock.add("RQly", 100); mock.add("RSNR", 0)
  mock.add("ANT", 1); mock.add("RFMD", 7); mock.add("TPWR", 25); mock.add("TRSS", -55)
  mock.add("TQly", 100); mock.add("TSNR", 9); mock.add("FM", "ACRO"); mock.add("RxBt", 16.4)
  mock.add("Curr", 1.2); mock.add("Capa", 120); mock.add("Bat%", 90)
end

-- run n ticks of 50 ms (5 x 10 ms)
local function run(S, n, o, E, elrs)
  for _ = 1, n do
    mock.advance(5)
    telem.read(S, mock.time, o or opts, E, elrs, false)
  end
end

---------------------------------------------------------------- sensors absent
do
  mock.install()
  local S = telem.new()
  run(S, 3)
  mock.eq(S.connected, false, "absent: not connected")
  mock.eq(S.lq, nil, "absent: lq nil")
  mock.eq(S.rssi, nil, "absent: rssi nil")
  mock.eq(S.rxV, nil, "absent: rxV nil")
  mock.eq(S.cells, nil, "absent: cells nil")
  mock.eq(S.snr, nil, "absent: snr nil")
  mock.eq(S.curr, nil, "absent: curr nil")
  mock.eq(S.gps, false, "absent: gps false")
  mock.eq(S.sats, nil, "absent: sats nil")
  mock.eq(S.rateHz, nil, "absent: rateHz nil")
  mock.eq(S.fm, "FM0", "absent: fm falls back to FM0 (unnamed flight mode)")
  mock.eq(mock.getValueByName, 0, "absent: getValue never called with a name")
  mock.eq(S.modelName, "75", "model name")
  mock.eq(S.clock, "09:05", "clock")
  mock.eq(S.date, "2 Oct", "date")
  mock.eq(S.txV, 7.8 + 0.0, "tx voltage")
end

---------------------------------------------------------------- sensors present
do
  mock.install()
  sensorsOfModel1()
  local S = telem.new()
  run(S, 2)
  mock.eq(S.connected, true, "present: connected")
  mock.eq(S.lq, 100, "present: lq")
  mock.eq(math.type(S.lq), "integer", "present: lq is an integer")
  mock.eq(S.rssi1, -60, "present: rssi1")
  mock.eq(S.rssi2, -70, "present: rssi2")
  mock.eq(S.rssi, -60, "present: best rssi")
  mock.eq(S.snr, 0, "present: SNR 0 is valid")
  mock.eq(S.rfmd, 7, "present: rfmd")
  mock.eq(S.tpwr, 25, "present: tpwr")
  mock.near(S.curr, 1.2, 1e-6, "present: curr")
  mock.eq(math.type(S.curr), "float", "present: curr is a float")
  mock.eq(S.capa, 120, "present: capa")
  mock.eq(S.ant, 1, "present: ant")
  mock.eq(S.fm, "ACRO", "present: fm text")
  mock.eq(S.gps, false, "present: no GPS sensor")
  mock.near(S.rxV, 16.4, 1e-6, "present: rxV")
  mock.eq(mock.getValueByName, 0, "present: getValue never called with a name")

  -- 1RSS reads 0 (antenna not reporting): best is 2RSS
  mock.set("1RSS", 0)
  run(S, 1)
  mock.eq(S.rssi1, nil, "rssi 0 -> nil")
  mock.eq(S.rssi, -70, "best rssi uses the other antenna")

  -- link lost: telemetry reads 0
  for _, n in ipairs({ "1RSS", "2RSS", "RQly", "RSNR", "ANT", "RFMD", "TPWR", "RxBt", "Curr", "Capa" }) do mock.set(n, 0) end
  mock.set("FM", 0)
  mock.fmName = "Normal"
  run(S, 1)
  mock.eq(S.connected, false, "lost: not connected")
  mock.eq(S.rxV, nil, "lost: rxV 0 -> nil")
  mock.eq(S.fm, "Normal", "lost: fm falls back to flight mode name")

  -- GPS sensor appears later (found by the round-robin check)
  mock.add("GPS", { lat = 1, lon = 2 })
  mock.add("Sats", 9)
  run(S, 13 * 4 + 1)
  mock.eq(S.gps, true, "rescan: GPS found")
  mock.eq(S.sats, 9, "rescan: Sats found")
end

---------------------------------------------------------------- sensor renumbered / first name wins
do
  mock.install()
  mock.add("RQly", 100)
  mock.add("RxBt", 12.0)
  local S = telem.new()
  run(S, 1)
  mock.near(S.rxV, 12.0, 1e-6, "rxV from RxBt")
  mock.add("VFAS", 16.0)                -- VFAS is first in the list
  mock.renumber("RQly")                 -- RQly moves to a new id
  mock.set("RQly", 77)
  run(S, 13 * 4 + 1)
  mock.eq(S.lq, 77, "renumbered sensor found again")
  mock.near(S.rxV, 16.0, 1e-6, "VFAS wins when it appears")
end

---------------------------------------------------------------- cell count: the simulated quad
-- One tick is 50 ms. A rest window lasts 3 s from its first reading, so the count latches
-- at the 61st fresh reading at rest (REST ticks). The quad sends one CRSF battery frame per
-- tick with the link up: RxBt, Curr and Capa together. Capa counts the mAh used from the
-- current. A link loss marks the three values old (EdgeTX keeps them, getSourceValue tells
-- it). A pack change starts the FC again, so Capa starts again at 0.
local REST = 61
local floor = math.floor
local Q = {}   -- the quad: v, amps, mah, curr (Curr sensor exists), capa (Capa sensor exists)

-- a quad with a pack plugged in and the link up; amps nil = no Curr sensor, mah nil = no
-- Capa sensor. Returns a new telem state (the widget starts).
local function quad(v, amps, mah)
  mock.install()
  Q.v, Q.amps, Q.mah = v, amps or 0.0, mah or 0
  Q.curr, Q.capa = amps ~= nil, mah ~= nil
  mock.add("RQly", 100); mock.add("TPWR", 25); mock.add("RxBt", v)
  if Q.curr then mock.add("Curr", Q.amps) end
  if Q.capa then mock.add("Capa", floor(Q.mah)) end
  return telem.new()
end
-- n ticks of time: the quad uses mAh at its current
local function use(n) Q.mah = Q.mah + Q.amps * 0.05 * n / 3.6 end
-- the FC sends a battery frame: fresh RxBt, Curr and Capa
local function frame()
  mock.set("RxBt", Q.v)
  if Q.curr then mock.set("Curr", Q.amps) end
  if Q.capa then mock.set("Capa", floor(Q.mah)) end
end
-- n ticks with the link up and one battery frame per tick (v, amps: set first)
local function fly(S, n, v, amps, o)
  if v ~= nil then Q.v = v end
  if amps ~= nil then Q.amps = amps end
  for _ = 1, n do
    mock.advance(5); use(1); frame()
    telem.read(S, mock.time, o or opts, nil, nil, false)
  end
end
-- the same in background (the dashboard not on screen): telem.track only
local function bg(S, n, v, amps)
  if v ~= nil then Q.v = v end
  if amps ~= nil then Q.amps = amps end
  for _ = 1, n do
    mock.advance(5); use(1); frame()
    telem.track(S, mock.time)
  end
end
-- fly n ticks; true when S.cells and S.cellV stayed nil (the dashboard shows the total voltage)
local function flyTotal(S, n, v, amps, o)
  local ok = true
  for _ = 1, n do
    fly(S, 1, v, amps, o)
    if S.cells ~= nil or S.cellV ~= nil then ok = false end
  end
  return ok
end
-- fly n ticks; true when S.cells was c in every tick
local function flyKeep(S, n, c, v, amps)
  local ok = true
  for _ = 1, n do
    fly(S, 1, v, amps)
    if S.cells ~= c then ok = false end
  end
  return ok
end
local function linkDown()
  mock.set("RQly", 0); mock.set("TPWR", 0)
  mock.setOld("RxBt")
  if Q.curr then mock.setOld("Curr") end
  if Q.capa then mock.setOld("Capa") end
end
local function linkUp() mock.set("RQly", 100); mock.set("TPWR", 25) end
-- the link is down for n ticks (the widget runs, the quad uses mAh), then up again with
-- the old values until the next frame. True when S.cells did not change.
local function lost(S, n, bgr, o)
  local c0, same = S.cells, true
  linkDown()
  for _ = 1, n do
    mock.advance(5); use(1)
    if bgr then telem.track(S, mock.time) else telem.read(S, mock.time, o or opts, nil, nil, false) end
    if S.cells ~= c0 then same = false end
  end
  linkUp()
  return same
end
-- the widget does not run for n ticks (a tool script is open); the link stays up
local function pause(n)
  mock.advance(5 * n); use(n)
end
-- a pack change: the link is down for n ticks, then the new pack (the FC starts again:
-- Capa 0). True when S.cells did not change while the link was down.
local function swap(S, n, v, amps)
  local same = lost(S, n)
  Q.v, Q.mah = v, 0
  if amps ~= nil then Q.amps = amps end
  return same
end

---------------------------------------------------------------- plug-in at rest
do
  -- full LiPo and LiHV packs (4.35 V per cell plus the sensor step and FC error is not
  -- one cell more), with Curr 0.3 A and Capa, without Capa, and without both
  local list = { { 4.35, 1 }, { 4.4, 1 }, { 4.2, 1 }, { 3.3, 1 }, { 8.7, 2 }, { 8.4, 2 }, { 6.8, 2 },
                 { 12.6, 3 }, { 13.1, 3 }, { 16.8, 4 }, { 17.4, 4 }, { 17.5, 4 }, { 17.6, 4 },
                 { 21.0, 5 }, { 21.8, 5 }, { 25.2, 6 }, { 26.1, 6 }, { 26.2, 6 } }
  for _, k in ipairs({ { 0.3, 0, "" }, { 0.3, nil, " (no Capa)" }, { nil, nil, " (no Curr, no Capa)" } }) do
    for _, c in ipairs(list) do
      local S = quad(c[1], k[1], k[2])
      local tag = string.format("plug-in %.2f V%s", c[1], k[3])
      mock.check(flyTotal(S, REST - 1), tag .. ": no count before 3 s at rest")
      mock.near(S.rxV, c[1], 1e-6, tag .. ": the total voltage is shown")
      fly(S, 1)
      mock.eq(S.cells, c[2], tag .. ": count after 3 s at rest")
      mock.near(S.cellV, c[1] / c[2], 1e-6, tag .. ": cellV")
    end
  end
  mock.eq(telem.PACK_MIN, 2.5, "PACK_MIN exported for the battery icon")
end

---------------------------------------------------------------- rest window
do
  -- no link, then link up: the FC voltage filter ramps up from 5 V (would be 2S)
  local S = quad(0.0, 0.2, 0)
  mock.set("RQly", 0); mock.set("TPWR", 0)
  run(S, 2)
  mock.eq(S.cells, nil, "ramp: no cells before link")
  mock.eq(S.rxV, nil, "ramp: no RX voltage before link")
  linkUp()
  local ok = true
  for _, v in ipairs({ 5.0, 8.0, 11.0, 14.0, 16.0, 16.6 }) do
    fly(S, 1, v)
    if S.cells ~= nil then ok = false end
  end
  mock.check(ok and flyTotal(S, REST - 1, 16.8), "ramp: no count from the ramp, none before 3 s at 16.8 V")
  fly(S, 1)
  mock.eq(S.cells, 4, "ramp: 4S from the last reading of the rest window")

  -- one 0.1 V sensor step of noise is rest; 0.2 V is not
  S = quad(16.4, 0.4, 0)
  for i = 1, REST do fly(S, 1, 16.4 + (i % 2) * 0.1) end
  mock.eq(S.cells, 4, "ripple: 0.1 V of noise is rest")
  S = quad(16.4, 0.4, 0)
  ok = true
  for i = 1, 400 do
    fly(S, 1, 16.4 + (i % 2) * 0.2)
    if S.cells ~= nil then ok = false end
  end
  mock.check(ok, "ripple: a voltage that moves by 0.2 V is not rest")

  -- one high sample starts the window again and does not decide the count
  S = quad(16.0, 0.3, 0)
  fly(S, 40)
  fly(S, 1, 17.9)
  ok = true
  for _ = 1, REST - 1 do
    fly(S, 1, 16.0)
    if S.cells ~= nil then ok = false end
  end
  mock.check(ok, "spike: the window starts again after the spike")
  fly(S, 1)
  mock.eq(S.cells, 4, "spike: 4S (never 5S) after 3 s at 16.0 V")

  -- current: 2.5 A is rest, 2.6 A is not; an FC with an HD VTX at 2.0 A on the bench
  S = quad(16.8, 2.5, 0)
  fly(S, REST)
  mock.eq(S.cells, 4, "current 2.5 A: rest")
  S = quad(25.2, 2.0, 0)
  fly(S, REST)
  mock.eq(S.cells, 6, "idle 2.0 A (HD VTX): rest, 6S")
  S = quad(16.8, 2.6, 0)
  mock.check(flyTotal(S, 400), "current 2.6 A: not rest, no count")
  mock.check(flyTotal(S, REST - 1, nil, 0.8), "current back to 0.8 A: the window starts then")
  fly(S, 1)
  mock.eq(S.cells, 4, "current 0.8 A: 4S after 3 s")

  -- an old Curr value is not a reading: the fresh voltage alone decides
  S = quad(16.8, 12.0, 0)
  Q.curr = false                            -- the frames do not refresh Curr any more
  mock.setOld("Curr")
  fly(S, REST)
  mock.eq(S.cells, 4, "old Curr 12 A: not used, 4S from the steady fresh voltage")

  -- a tick without link (a flicker) starts the window again
  S = quad(16.8, 0.3, 0)
  fly(S, 50)
  lost(S, 1)
  mock.check(flyTotal(S, REST - 1), "flicker: the rest window starts again after a tick without link")
  fly(S, 1)
  mock.eq(S.cells, 4, "flicker: 4S 3 s after the link came back")

  -- more than 1 s without a read (the widget did not run) starts the window again
  S = quad(16.8, 0.3, 0)
  fly(S, 50)
  pause(40)
  mock.check(flyTotal(S, REST - 1), "gap 2 s: the rest window starts again")
  fly(S, 1)
  mock.eq(S.cells, 4, "gap 2 s: 4S 3 s after it")
end

---------------------------------------------------------------- pack changes
do
  -- old pack at rest, flown for 60 s at 20 A, landed; the link is down while the pack is
  -- changed; the new full pack at rest. kind: "capa" = Curr and Capa (the FC starts again:
  -- Capa 0), "nocapa" = Curr without a Capa sensor, "none" = no Curr and no Capa sensor,
  -- "zero" = an FC without a current meter (Curr and Capa read 0, so Capa never drops).
  -- { old full V, old landed V, new full V, old count, new count }
  local swaps = { { 25.2, 22.2, 21.0, 6, 5 }, { 16.8, 14.8, 12.6, 4, 3 }, { 21.0, 18.5, 16.8, 5, 4 },
                  { 25.2, 22.2, 16.8, 6, 4 }, { 25.2, 22.2, 25.2, 6, 6 }, { 12.6, 11.2, 16.8, 3, 4 },
                  { 4.2, 4.0, 8.4, 1, 2 }, { 8.4, 7.6, 4.2, 2, 1 } }
  local function setupKind(kind, v)
    if kind == "capa" then return quad(v, 0.4, 0) end
    if kind == "nocapa" then return quad(v, 0.4) end
    if kind == "zero" then return quad(v, 0.0, 0) end
    return quad(v)
  end
  for _, kind in ipairs({ "capa", "nocapa", "none", "zero" }) do
    for _, gap in ipairs({ 120, 60 }) do
      for _, c in ipairs(swaps) do
        local tag = string.format("swap %dS -> full %dS, link lost %.1f s (%s)", c[4], c[5], gap / 20, kind)
        local S = setupKind(kind, c[1])
        local load = (kind == "capa" or kind == "nocapa") and 20.0 or 0.0
        local idle = (kind == "capa" or kind == "nocapa") and 0.4 or 0.0
        fly(S, REST)
        mock.eq(S.cells, c[4], tag .. ": old pack latched")
        fly(S, 1200, c[2] - 0.8, load)
        fly(S, 40, c[2], idle)
        mock.check(swap(S, gap, c[3]), tag .. ": the count stays while the link is down")
        if kind == "capa" then
          -- Capa started again: a new pack, counted at rest
          mock.check(flyTotal(S, REST - 1), tag .. ": the total voltage shows before 3 s at rest")
          mock.near(S.rxV, c[3], 1e-6, tag .. ": the total voltage of the new pack")
          fly(S, 1)
          mock.eq(S.cells, c[5], tag .. ": the new count after 3 s at rest")
          mock.near(S.cellV, c[3] / c[5], 1e-6, tag .. ": cellV")
        elseif c[5] <= c[4] then
          -- no Capa drop: the count never goes down, a smaller pack shows too low (the
          -- safe side, documented)
          mock.check(flyKeep(S, REST + 400, c[4]), tag .. ": without a Capa drop the old count stays")
          mock.near(S.cellV, c[3] / c[4], 1e-6, tag .. ": cellV from the old count (too low)")
        else
          -- more cells: the upward rule
          fly(S, REST + 40)
          mock.eq(S.cells, c[5], tag .. ": without a Capa drop more cells are found (upward rule)")
        end
      end
    end
  end

  -- without a Capa sensor a latched count never goes down: 4S -> full 3S stays 4S (3.15 V
  -- per cell, too low: the safe side; set rxCells)
  local S = quad(16.8, 0.4)
  fly(S, REST)
  fly(S, 1200, 14.4, 15.0)
  swap(S, 120, 12.6, 0.4)
  mock.check(flyKeep(S, 1200, 4), "no Capa: 4S -> full 3S stays 4S, also long at rest")
  mock.near(S.cellV, 3.15, 1e-6, "no Capa: 4S -> full 3S shows 3.15 V per cell")

  -- the same used pack plugged in again (Capa starts again at 0) at the last rest voltage
  -- of the old pack: the old 6S stays (3.6 V per cell is plausible for 6S)
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 20.8, 20.0)
  fly(S, 40, 21.6, 0.4)
  swap(S, 120, 21.6)
  mock.check(flyTotal(S, REST - 1), "same used 6S plugged in again: the total voltage before rest")
  fly(S, 1)
  mock.eq(S.cells, 6, "same used 6S plugged in again: 6S (the rest voltage of the old pack)")
  fly(S, 600, 20.0, 15.0)
  mock.eq(S.cells, 6, "same used 6S plugged in again: stays 6S in flight")
  -- the recovered voltage of the same pack 0.1 V per cell higher is still the old pack
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 20.8, 20.0)
  fly(S, 40, 21.6, 0.4)
  swap(S, 120, 22.0)
  fly(S, REST)
  mock.eq(S.cells, 6, "same used 6S, rest voltage 0.4 V higher: 6S")
  -- another used 6S (a rest voltage 0.6 V below the old pack's): counted from its voltage
  -- at rest, so a 6S at 21.6 V (3.6 V per cell) is counted 5S at 4.32 V. The voltage cannot
  -- solve this case; set rxCells for it. Without Capa the count stays 6S (no Capa drop).
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 20.8, 20.0)
  fly(S, 40, 22.2, 0.4)
  swap(S, 120, 21.6)
  mock.check(flyTotal(S, REST - 1), "another used 6S plugged in: the total voltage before rest")
  fly(S, 1)
  mock.eq(S.cells, 5, "another used 6S plugged in: 5S (documented limit)")
  fly(S, 600, 20.0, 15.0)
  mock.eq(S.cells, 5, "another used 6S plugged in: stays 5S in flight (the voltage only goes down)")
  -- a 6S landed at 3.5 V per cell, then a full 5S at 21.0 V: the voltage is the rest
  -- voltage of the old pack, so 6S stays (3.50 V per cell, too low: documented)
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 20.2, 20.0)
  fly(S, 40, 21.0, 0.4)
  swap(S, 120, 21.0)
  fly(S, REST)
  mock.eq(S.cells, 6, "6S landed at 21.0 V -> full 5S at 21.0 V: 6S stays (documented, too low)")
  -- a voltage 0.6 V above the last rest voltage of the old 6S (20.4 V) is not the old
  -- pack: a full 5S at 21.0 V is counted 5S
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 19.6, 20.0)
  fly(S, 40, 20.4, 0.4)
  swap(S, 120, 21.0)
  fly(S, REST)
  mock.eq(S.cells, 5, "6S landed at 20.4 V -> full 5S at 21.0 V: 5S")
  -- Capa reaches the radio 1 s after the voltage (a non-CRSF order): the old 6S landed at
  -- 22.2 V, the full 5S at 21.0 V is compared with the rest voltage from before the gap
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 21.4, 20.0)
  fly(S, 40, 22.2, 0.4)
  lost(S, 120)
  Q.v, Q.mah, Q.amps = 21.0, 0, 0.4
  for _ = 1, 20 do
    mock.advance(5); mock.set("RxBt", Q.v); mock.set("Curr", Q.amps)
    telem.read(S, mock.time, opts, nil, nil, false)
  end
  fly(S, REST + 1)
  mock.eq(S.cells, 5, "6S -> full 5S, Capa 1 s after the voltage: 5S")
  -- the larger counts lose more cells (documented): a used 8S at 3.30 V per cell is
  -- counted 6S, a used 12S at 3.65 V per cell 10S
  S = quad(26.4, 0.4, 0)
  fly(S, REST)
  mock.eq(S.cells, 6, "used 8S plugged in at 26.4 V: 6S (documented: two cells less)")
  S = quad(43.8, 0.4, 0)
  fly(S, REST)
  mock.eq(S.cells, 10, "used 12S plugged in at 43.8 V: 10S (documented: two cells less)")
  S = quad(25.2, 0.4, 0)
  local o6 = { rxCells = 6 }
  fly(S, REST, nil, nil, o6)
  fly(S, 1200, 20.8, 20.0, o6)
  swap(S, 120, 21.6)
  fly(S, 1, nil, nil, o6)
  mock.eq(S.cells, 6, "used 6S plugged in again, rxCells 6: 6S at once")
  S = quad(25.2, 0.4)
  fly(S, REST)
  fly(S, 1200, 20.8, 20.0)
  fly(S, 40, 21.6, 0.4)
  swap(S, 120, 21.6)
  mock.check(flyKeep(S, REST + 40, 6), "used 6S plugged in again (no Capa): stays 6S")

  -- a quick swap (link lost 3 s) 6S -> full 4S: Capa started again, 4S after rest
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 21.0, 20.0)
  fly(S, 40, 22.0, 0.4)
  swap(S, 60, 16.8, 0.3)
  mock.check(flyTotal(S, REST - 1), "quick swap 6S -> 4S: the total voltage before rest")
  fly(S, 1)
  mock.eq(S.cells, 4, "quick swap 6S -> 4S: 4S after 3 s at rest")

  -- Capa that goes down by 10 mAh or less is not a new pack (sensor noise). 11 mAh lower
  -- is an FC that started again: with a gap of the RX voltage (the RX lost its power) a
  -- new pack, without a gap (the RX kept its power) the same pack.
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 21.0, 20.0)
  Q.mah = 500.0
  fly(S, 1, 22.0, 0.4)
  Q.mah = 490.0
  mock.check(flyKeep(S, 100, 6), "Capa 10 mAh lower: the same pack")
  Q.mah = 478.9
  mock.check(flyKeep(S, 100, 6), "Capa 11 mAh lower without a gap: the FC started again, the same pack")
  Q.mah = 500.0
  fly(S, 1)
  lost(S, 40)                               -- 2 s without link
  Q.mah = 488.9
  fly(S, 1, 25.2)
  mock.eq(S.cells, nil, "Capa 11 mAh lower after a 2 s link loss: a new pack")

  -- a fresh pack (Capa below 10 mAh) changed after 10 s: Capa does not drop by more than
  -- 10 mAh, so it is the same pack: the old 6S stays (2.57 V per cell, the safe side)
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  swap(S, 200, 16.8, 0.4)
  mock.check(flyKeep(S, 5, 6), "fresh pack changed: the old 6S shows")
  mock.check(flyKeep(S, 1200, 6, 15.0, 20.0), "fresh pack changed: 6S under load")
  mock.check(flyKeep(S, REST + 200, 6, 15.4, 0.4), "fresh pack changed: 6S at rest (no Capa drop)")

  -- the FC on USB with the pack unplugged: the link stays, the RX voltage reads 0.4 V:
  -- no pack (a new pack at once), also when Capa continues (the FC does not start again)
  S = quad(16.8, 0.3, 0)
  fly(S, REST)
  fly(S, 1200, 15.0, 20.0)
  fly(S, 1, 0.4, 0.0)
  mock.eq(S.rxImplausible, true, "USB: 0.4 V is not a pack")
  mock.eq(S.cells, nil, "USB: no pack, no count")
  fly(S, 200)
  mock.check(flyTotal(S, REST - 1, 12.6, 0.3), "USB: a 3S plugged in shows the total voltage first")
  fly(S, 1)
  mock.eq(S.cells, 3, "USB: a 3S plugged in is counted at rest")
  mock.eq(S.rxImplausible, false, "USB: 12.6 V is a pack")
  lost(S, 1)
  mock.eq(S.rxImplausible, false, "no link: no RX voltage, not implausible")
  S = quad(0.0)
  run(S, 1)
  mock.eq(S.rxV, nil, "0.0 V: no RX voltage")
  mock.eq(S.rxImplausible, false, "0.0 V: not implausible (no value)")
end

---------------------------------------------------------------- the same pack through gaps
do
  for _, withCapa in ipairs({ true, false }) do
    local cp = withCapa and 0 or nil
    local sfx = withCapa and "" or " (no Capa)"
    -- a used 6S in flight at 20 A, link lost for 20 s, back under load, landed at 3.6 V
    -- per cell: 6S all the time (never 5S, never the total voltage)
    local S = quad(25.2, 0.4, cp)
    fly(S, REST)
    fly(S, 1200, 21.5, 20.0)
    mock.check(lost(S, 400), "loss 20 s" .. sfx .. ": 6S while the link is down")
    mock.check(flyKeep(S, 600, 6, 20.6, 20.0), "loss 20 s" .. sfx .. ": 6S back under load")
    mock.check(flyKeep(S, 200, 6, 21.6, 0.5), "loss 20 s" .. sfx .. ": 6S landed at 21.6 V")
    mock.near(S.cellV, 3.6, 1e-6, "loss 20 s" .. sfx .. ": cellV 3.6")

    -- landed at 3.6 V per cell, the ELRS tool open for 6 s (the widget not run)
    S = quad(25.2, 0.4, cp)
    fly(S, REST)
    fly(S, 1200, 21.0, 20.0)
    fly(S, 100, 21.6, 0.5)
    pause(120)
    mock.check(flyKeep(S, 200, 6), "tool 6 s" .. sfx .. ": stays 6S")
    -- the same in flight
    fly(S, 200, 20.6, 20.0)
    pause(120)
    mock.check(flyKeep(S, 200, 6, 20.4, 20.0), "tool 6 s in flight" .. sfx .. ": stays 6S")

    -- failsafe with GPS rescue: link lost 30 s, the quad flies home and lands
    S = quad(25.2, 0.4, cp)
    fly(S, REST)
    fly(S, 1200, 21.0, 20.0)
    Q.amps = 12.0
    mock.check(lost(S, 600), "failsafe 30 s" .. sfx .. ": 6S while the link is down")
    mock.check(flyKeep(S, 200, 6, 21.6, 0.3), "failsafe 30 s" .. sfx .. ": 6S back at rest at 21.6 V")

    -- a short loss (4 s) in flight and back at 17.9 V and 4 A (also fits 5S): 6S
    S = quad(25.2, 0.5, cp)
    fly(S, REST)
    fly(S, 100, 20.0, 4.0)
    mock.check(lost(S, 80), "short loss" .. sfx .. ": 6S kept for 4 s")
    mock.check(flyKeep(S, 800, 6, 17.9, 4.0), "short loss" .. sfx .. ": back at 17.9 V and 4 A, never 5S")
    mock.near(S.cellV, 17.9 / 6, 1e-6, "short loss" .. sfx .. ": cellV 2.98")

    -- a deep sag and a Li-ion cruise never lower the count
    S = quad(8.4, 0.3, cp)
    fly(S, REST)
    fly(S, 200, 6.6, 4.0)
    mock.eq(S.cells, 2, "sag" .. sfx .. ": 2S at 6.6 V under load stays 2S")
    S = quad(25.2, 0.5, cp)
    fly(S, REST)
    fly(S, 600, 17.4, 8.0)
    mock.eq(S.cells, 6, "Li-ion" .. sfx .. ": cruise at 2.9 V per cell stays 6S")
    fly(S, 800, 19.2, 0.3)
    mock.eq(S.cells, 6, "Li-ion" .. sfx .. ": landed at 3.2 V per cell stays 6S")
    -- a Li-ion 6S lands at 3.15 V per cell after a 10 s loss: no Capa drop, so it is the
    -- same pack and 6S stays
    S = quad(25.2, 0.5, cp)
    fly(S, REST)
    fly(S, 1200, 17.4, 8.0)
    lost(S, 200)
    fly(S, REST + 40, 18.9, 0.3)
    mock.eq(S.cells, 6, "Li-ion" .. sfx .. ": landed at 3.15 V per cell after a 10 s loss")

    -- background: 20 min with the dashboard not on screen and a 6 s loss in it
    S = quad(25.2, 0.4, cp)
    fly(S, REST)
    bg(S, 12000, 21.0, 20.0)
    mock.check(lost(S, 120, true), "background" .. sfx .. ": 6S during a 6 s loss")
    bg(S, 12000, 20.6, 15.0)
    mock.check(flyKeep(S, 200, 6, 21.6, 0.4), "background" .. sfx .. ": 6S after 20 min")
  end

  -- a steady cruise without a current sensor after a 10 s loss (no Capa) looks like rest,
  -- but without a Capa drop nothing lowers the count: 6S stays
  local S = quad(25.2)
  fly(S, REST)
  fly(S, 600, 21.5)
  lost(S, 200)
  mock.check(flyKeep(S, 400, 6, 20.5), "cruise (no Curr, no Capa): a steady 20.5 V keeps 6S")
  S = quad(25.2)
  fly(S, REST)
  fly(S, 600, 19.5)
  lost(S, 200)
  mock.check(flyKeep(S, REST + 40, 6, 19.0), "cruise (no Curr, no Capa): a steady 19.0 V (3.17 V per cell) keeps 6S")
  -- the same with a Curr sensor (no Capa): 6S under load and landed
  S = quad(25.2, 0.4)
  fly(S, REST)
  fly(S, 600, 19.5, 15.0)
  lost(S, 200)
  mock.check(flyKeep(S, 400, 6, 19.0, 15.0), "cruise at 15 A (no Capa): 6S under load")
  mock.check(flyKeep(S, 200, 6, 21.0, 0.4), "cruise at 15 A (no Capa): 6S landed at 3.5 V per cell")
end

---------------------------------------------------------------- stale values
do
  -- a new widget while the link is up with old values (kept from before a link loss):
  -- no count from them
  local S = quad(25.2, 0.4, 900)
  linkDown(); linkUp()
  local ok = true
  for _ = 1, 400 do
    run(S, 1)
    if S.cells ~= nil then ok = false end
  end
  mock.check(ok, "stale: old values never set a count (20 s)")
  mock.eq(S.rxV, nil, "stale: an old value is not shown after 2 s")

  -- a pack change, and the link is back before the FC sends a frame: the old 21.3 V and
  -- the old Capa change nothing; the fresh frame (Capa 0) is a new pack
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 21.0, 20.0)
  fly(S, 40, 21.3, 0.3)
  swap(S, 120, 25.2, 0.2)
  ok = true
  for _ = 1, 400 do
    run(S, 1)
    if S.cells ~= 6 then ok = false end
  end
  mock.check(ok, "stale: the old 21.3 V never changes the count (20 s)")
  mock.eq(S.rxV, nil, "stale: the old 21.3 V is not shown after 2 s")
  mock.eq(S.cellV, nil, "stale: no cell voltage from the old 21.3 V after 2 s")
  mock.check(flyTotal(S, REST - 1), "stale: the fresh frame is a new pack, the total voltage before rest")
  fly(S, 1)
  mock.eq(S.cells, 6, "stale: 6S from the fresh readings")
  mock.near(S.cellV, 4.2, 1e-6, "stale: cellV 4.2")
end

---------------------------------------------------------------- the FC starts again, the same pack
do
  -- The FC starts again with a used pack (OSD menu SAVE&REBOOT, a setting that needs a
  -- restart, the configurator): the RX keeps its power and the link, so the RX voltage
  -- stays fresh (EdgeTX marks a value old only after 20 s without a new one). No battery
  -- frame for 1.5 s, then Capa 0 and a voltage from the FC filter that starts at 0 V (or
  -- at 3 V) and moves 9.8 % of the way per 50 ms (PT1, tau 0.48 s).
  local function noFrames(S, n)
    for _ = 1, n do
      mock.advance(5); use(1)
      telem.read(S, mock.time, opts, nil, nil, false)
    end
  end
  -- true when S.cells was c in every tick, or nil only while the RX voltage was below
  -- PACK_MIN (not a pack)
  local function ramp(S, target, ticks, startV, c)
    local x, ok = startV, true
    for _ = 1, ticks do
      fly(S, 1, floor(x * 10 + 0.5) / 10)
      if S.cells ~= c and not (S.cells == nil and (S.rxV == nil or S.rxV < telem.PACK_MIN)) then ok = false end
      x = x + (target - x) * 0.098
    end
    Q.v = target
    return ok
  end
  for _, c in ipairs({ { 25.2, 21.6, 6 }, { 25.2, 22.0, 6 }, { 16.8, 13.2, 4 }, { 21.0, 17.6, 5 } }) do
    for _, kind in ipairs({ "capa", "nocapa", "zero" }) do
      for _, startV in ipairs({ 0.0, 3.0 }) do
        local tag = string.format("FC start, %dS at %.1f V (%s, filter from %.0f V)", c[3], c[2], kind, startV)
        local S
        if kind == "capa" then S = quad(c[1], 0.4, 0)
        elseif kind == "zero" then S = quad(c[1], 0.0, 0)
        else S = quad(c[1], 0.4) end
        local load = (kind == "zero") and 0.0 or 20.0
        local idle = (kind == "zero") and 0.0 or 0.4
        fly(S, REST)
        fly(S, 1200, c[2] - 1.2, load)
        fly(S, 200, c[2], idle)
        mock.eq(S.cells, c[3], tag .. ": latched before")
        noFrames(S, 30)
        if Q.capa then Q.mah = 0 end
        mock.check(ramp(S, c[2], 60, startV, c[3]), tag .. ": the count stays during the filter ramp")
        mock.check(flyKeep(S, 200, c[3]), tag .. ": the count stays at rest")
        mock.check(flyKeep(S, 600, c[3], c[2] - 1.6, load), tag .. ": the count stays in flight")
      end
    end
  end

  -- a reading below PACK_MIN for less than 1 s keeps the count; for 1 s it is no pack
  local S = quad(16.8, 0.3, 0)
  fly(S, REST)
  fly(S, 10, 0.4, 0.0)
  mock.eq(S.cells, nil, "below PACK_MIN for 0.5 s: no count shown")
  mock.check(flyKeep(S, 100, 4, 16.8, 0.3), "below PACK_MIN for 0.5 s: 4S again at 16.8 V")
  fly(S, 21, 0.4, 0.0)
  mock.check(flyTotal(S, REST - 1, 12.6, 0.3), "below PACK_MIN for 1 s: no pack, a 3S shows the total voltage")
  fly(S, 1)
  mock.eq(S.cells, 3, "below PACK_MIN for 1 s: a 3S counted at rest")

  -- the BF Lua tool open for 15 s (the widget does not run) and the FC starts again in it
  -- (a save with reboot): Capa 0 after the gap, the voltage is the old rest voltage: 6S
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 20.4, 20.0)
  fly(S, 200, 21.6, 0.4)
  pause(60)
  Q.mah = 0
  pause(240)
  mock.check(flyTotal(S, REST - 1), "tool + FC start: the total voltage before rest")
  fly(S, 1)
  mock.eq(S.cells, 6, "tool + FC start: 6S at the old rest voltage (21.6 V)")
  mock.check(flyKeep(S, 600, 6, 20.0, 15.0), "tool + FC start: 6S in flight")
  -- a power cut in a crash (loose XT60): the FC and the RX start again, the link is lost
  -- for 3 s, the same pack at its rest voltage: 6S
  S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 20.4, 20.0)
  fly(S, 20, 21.6, 0.4)
  lost(S, 60)
  Q.mah = 0
  fly(S, REST + 40, 21.6, 0.4)
  mock.eq(S.cells, 6, "power cut: 6S at the old rest voltage")
  mock.check(flyKeep(S, 600, 6, 20.0, 15.0), "power cut: 6S in flight")
end

---------------------------------------------------------------- a used pack of unknown history
do
  -- the widget starts with a used pack (model change away and back, radio restart, USB
  -- storage): the first Capa 1300 mAh tells that the pack was used, so its voltage gives
  -- no count; the total voltage shows with the neutral icon
  local S = quad(21.6, 0.4, 1300)
  mock.check(flyTotal(S, 400), "used pack, widget new (Capa 1300): no count at rest")
  mock.check(flyTotal(S, 600, 20.0, 15.0), "used pack, widget new: no count in flight")
  mock.check(flyTotal(S, 400, 21.8, 0.3), "used pack, widget new: no count after landing")
  -- the FC starts again (no gap): the same pack, still no count
  Q.mah = 0
  mock.check(flyTotal(S, 200), "used pack, widget new, FC start: the same pack, no count")
  -- the next pack (Capa 0 after a gap) is counted at rest
  Q.mah = 400
  fly(S, 1)
  swap(S, 120, 25.2, 0.3)
  mock.check(flyTotal(S, REST - 1), "used pack, widget new: the next pack shows the total voltage first")
  fly(S, 1)
  mock.eq(S.cells, 6, "used pack, widget new: the next pack is counted at rest")
  -- Capa 100 mAh or less: a pack plugged in a short time before, counted from its voltage
  S = quad(25.2, 2.0, 100)
  fly(S, REST)
  mock.eq(S.cells, 6, "widget new, Capa 100 mAh: 6S at rest")
  -- rxCells gives the count also for such a pack
  S = quad(21.6, 0.4, 1300)
  fly(S, 1, nil, nil, { rxCells = 6 })
  mock.eq(S.cells, 6, "used pack, widget new, rxCells 6: 6S")
end

---------------------------------------------------------------- background: sensors found later
do
  -- a new model: RxBt, Curr and Capa appear after the widget started, and the dashboard
  -- is not on screen; telem.track finds them and counts the full pack
  mock.install()
  mock.add("RQly", 100); mock.add("TPWR", 25)
  local S = telem.new()
  mock.add("RxBt", 25.2); mock.add("Curr", 0.4); mock.add("Capa", 0)
  Q.v, Q.amps, Q.mah, Q.curr, Q.capa = 25.2, 0.4, 0, true, true
  bg(S, 200)
  bg(S, 6000, 20.4, 20.0)
  bg(S, 100, 21.6, 0.4)
  fly(S, 1)
  mock.eq(S.cells, 6, "track: sensors found later, the full 6S counted in background")
  mock.near(S.cellV, 3.6, 1e-6, "track: sensors found later, 3.6 V per cell after the flight")
end

---------------------------------------------------------------- an old RX voltage with the link up
do
  -- quad X: a full 6S; the link is lost; quad Y on the same model links, but its FC sends
  -- no battery frame: the old 25.2 V shows for 2 s, then no RX voltage
  local S = quad(25.2, 0.4, 0)
  fly(S, REST)
  lost(S, 100)
  run(S, 41)
  mock.near(S.rxV, 25.2, 1e-6, "old value: shown for 2 s after the link came back")
  run(S, 1)
  mock.eq(S.rxV, nil, "old value: not shown after 2 s")
  mock.eq(S.cellV, nil, "old value: no cell voltage after 2 s")
  run(S, 6000)
  mock.eq(S.rxV, nil, "old value: not shown after 5 min without a battery frame")
  mock.eq(S.connected, true, "old value: the link is up")
  fly(S, 1, 16.8, 0.3)
  mock.near(S.rxV, 16.8, 1e-6, "old value: the first battery frame shows at once")
end

---------------------------------------------------------------- a gap without a working current meter
-- (no Curr and no Capa sensor, or an FC without a current meter that sends Curr 0 and
-- Capa 0): a steady voltage looks like rest, but without a Capa drop nothing lowers the
-- count, also not a real change to a pack with fewer cells (the safe side)
do
  for _, kind in ipairs({ "none", "zero" }) do
    local function q(v)
      if kind == "zero" then return quad(v, 0.0, 0) end
      return quad(v)
    end
    local sfx = " (" .. kind .. ")"
    -- a 4S wing cruises at 3.17 V per cell, the link is lost for 7 s, it comes back at
    -- 3.15 to 3.18 V per cell: 4S stays (not 3S at 4.20 V)
    local S = q(16.8)
    fly(S, REST)
    for i = 1, 600 do fly(S, 1, 12.7 + (i % 2) * 0.1) end
    lost(S, 140)
    local ok = true
    for i = 1, 400 do
      fly(S, 1, 12.6 + (i % 2) * 0.1)
      if S.cells ~= 4 then ok = false end
    end
    mock.check(ok, "4S wing cruise after a 7 s loss" .. sfx .. ": 4S stays")
    -- the pilot climbs at full throttle after the loss: 1.2 V lower and steady: 4S stays
    S = q(16.8)
    fly(S, REST)
    fly(S, 600, 12.8)
    lost(S, 140)
    mock.check(flyKeep(S, 400, 4, 11.6), "4S wing climb after a 7 s loss" .. sfx .. ": 4S stays")
    -- a 6S Li-ion cruises at 2.9 V per cell after an 8 s loss: 6S stays (not 4S)
    S = q(25.2)
    fly(S, REST)
    fly(S, 600, 17.6)
    lost(S, 160)
    mock.check(flyKeep(S, 400, 6, 17.4), "6S Li-ion cruise at 2.9 V per cell after a loss" .. sfx .. ": 6S stays")
    -- an 8S at 3.15 V per cell after an 8 s loss: 8S stays (not 6S)
    S = q(33.6)
    fly(S, REST)
    mock.eq(S.cells, 8, "8S full" .. sfx .. ": 8S")
    fly(S, 600, 25.4)
    lost(S, 160)
    mock.check(flyKeep(S, 400, 8, 25.2), "8S cruise at 3.15 V per cell after a loss" .. sfx .. ": 8S stays")
    -- a 6S Li-ion landed at rest at 3.10 V per cell, a tool open for 6 s: 6S stays (not 5S)
    S = q(25.2)
    fly(S, REST)
    fly(S, 600, 18.6)
    pause(120)
    mock.check(flyKeep(S, 400, 6), "6S Li-ion at rest at 3.10 V per cell, tool 6 s" .. sfx .. ": 6S stays")
    -- a quad with a current meter, then (Capa 0: a new pack) a quad without one on the
    -- same model: 4S at rest, and a steady climb after a loss keeps it
    S = quad(16.8, 0.4, 0)
    fly(S, REST)
    fly(S, 1200, 14.8, 15.0)
    fly(S, 40, 15.6, 0.4)
    swap(S, 120, 16.8, 0.0)
    fly(S, REST)
    mock.eq(S.cells, 4, "meter, then a quad without one" .. sfx .. ": 4S at rest")
    fly(S, 600, 12.8)
    lost(S, 140)
    mock.check(flyKeep(S, 400, 4, 11.6), "meter, then a quad without one" .. sfx .. ": 4S in a climb after a loss")
    -- a real change 6S -> full 4S on the ground: the old 6S stays (too low, the safe
    -- side; documented)
    S = q(25.2)
    fly(S, REST)
    fly(S, 600, 22.2)
    swap(S, 120, 16.8)
    mock.check(flyKeep(S, REST + 400, 6), "6S -> full 4S at rest" .. sfx .. ": 6S stays (documented)")
    mock.near(S.cellV, 2.8, 1e-6, "6S -> full 4S at rest" .. sfx .. ": 2.80 V per cell (too low)")
  end
end

---------------------------------------------------------------- a count goes down only after a new pack
do
  -- without a Capa drop (no Capa sensor, or an FC that sends Capa 0) a latched count never
  -- goes down: 6S -> full 4S stays 6S (the cell voltage shows too low, the safe side; set
  -- rxCells), through a flight, a landing, a 30 s loss, a tool pause and background.
  -- More cells are found by the upward rule: 4S -> full 6S gives 6S after 1.5 s.
  for _, kind in ipairs({ "nocapa", "none", "zero" }) do
    local function q(v)
      if kind == "nocapa" then return quad(v, 0.4) end
      if kind == "zero" then return quad(v, 0.0, 0) end
      return quad(v)
    end
    local load = kind == "nocapa" and 20.0 or 0.0
    local idle = kind == "nocapa" and 0.4 or 0.0
    local sfx = " (" .. kind .. ")"
    local S = q(25.2)
    fly(S, REST)
    fly(S, 1200, 21.6, load)
    fly(S, 40, 22.2, idle)
    swap(S, 200, 16.8, idle)
    mock.check(flyKeep(S, REST + 400, 6), "6S -> full 4S" .. sfx .. ": 6S stays at rest")
    mock.near(S.cellV, 2.8, 1e-6, "6S -> full 4S" .. sfx .. ": 2.80 V per cell (too low, the safe side)")
    mock.check(flyKeep(S, 1200, 6, 14.4, load), "6S -> full 4S" .. sfx .. ": 6S in flight")
    mock.check(lost(S, 600), "6S -> full 4S" .. sfx .. ": 6S during a 30 s loss")
    mock.check(flyKeep(S, 400, 6, 15.2, idle), "6S -> full 4S" .. sfx .. ": 6S landed after the loss")
    pause(200)
    mock.check(flyKeep(S, 400, 6), "6S -> full 4S" .. sfx .. ": 6S after a 10 s tool pause")
    bg(S, 2000)
    mock.check(flyKeep(S, 200, 6), "6S -> full 4S" .. sfx .. ": 6S after background")
    S = q(16.8)
    fly(S, REST)
    fly(S, 1200, 14.4, load)
    fly(S, 40, 15.2, idle)
    swap(S, 200, 25.2, idle)
    fly(S, 30)
    mock.eq(S.cells, 4, "4S -> full 6S" .. sfx .. ": 4S before 1.5 s")
    fly(S, 1)
    mock.eq(S.cells, 6, "4S -> full 6S" .. sfx .. ": 6S after 1.5 s (upward rule)")
    mock.near(S.cellV, 4.2, 1e-6, "4S -> full 6S" .. sfx .. ": 4.20 V per cell")
  end

  -- with Capa the same changes are new packs (Capa 0 after the gap): the total voltage,
  -- then the new count at rest
  for _, c in ipairs({ { 25.2, 16.8, 4 }, { 16.8, 25.2, 6 } }) do
    local tag = string.format("%.1f V -> full %dS (Capa)", c[1], c[3])
    local S = quad(c[1], 0.4, 0)
    fly(S, REST)
    fly(S, 1200, c[1] * 0.85, 20.0)
    fly(S, 40, c[1] * 0.88, 0.4)
    swap(S, 200, c[2], 0.4)
    mock.check(flyTotal(S, REST - 1), tag .. ": the total voltage before rest")
    fly(S, 1)
    mock.eq(S.cells, c[3], tag .. ": the new count at rest")
  end

  -- the FC on USB: the same used 6S unplugged for 2 s and plugged in again is a new pack
  -- (no pack for 1 s), and at its old rest voltage the old 6S stays (not 5S at 4.32 V).
  -- Capa continues, or Betaflight sets it to 0 while there is no pack.
  for _, reset in ipairs({ false, true }) do
    local sfx = reset and " (Capa 0 without a pack)" or ""
    local S = quad(25.2, 0.4, 0)
    fly(S, REST)
    fly(S, 1200, 20.6, 20.0)
    fly(S, 100, 21.6, 0.4)
    fly(S, 30, 0.4, 0.0)
    if reset then Q.mah = 0 end
    fly(S, 10)
    mock.check(flyTotal(S, REST - 1, 21.6, 0.4), "USB, the same used 6S again" .. sfx .. ": the total voltage before rest")
    fly(S, 1)
    mock.eq(S.cells, 6, "USB, the same used 6S again" .. sfx .. ": 6S at its old rest voltage")
  end

  -- n ticks; the FC sends a battery frame with V = f(time since the start) only every
  -- `every` ticks (at the given phase); between frames the values stay fresh
  local exp = math.exp
  local function quiet(S, n)
    for _ = 1, n do
      mock.advance(5); use(1)
      telem.read(S, mock.time, opts, nil, nil, false)
    end
  end
  local function frames(S, n, every, phase, f)
    for i = 1, n do
      mock.advance(5); use(1)
      if (i + phase) % every == 0 then
        Q.v = floor(f(i * 0.05) * 10 + 0.5) / 10
        frame()
      end
      telem.read(S, mock.time, opts, nil, nil, false)
    end
  end
  -- the FC on USB, the pack unplugged: the FC filter (PT1, tau 0.48 s) lets the voltage
  -- fall to 0.4 V in about 1 s, and the RX sends a battery frame every 1, 2, 10, 20 or 40
  -- ticks (20 Hz .. 0.5 Hz), at every phase. A reading of that fall is not the rest
  -- voltage: the same used pack plugged in again (the voltage rises through the filter)
  -- keeps its count (6S at 21.6 V, not 5S at 4.32 V; 4S at 13.0 V, not 3S at 4.33 V).
  -- Capa continues, or Betaflight sets it to 0 while there is no pack. The count is never
  -- lower than the real one.
  for _, c in ipairs({ { 25.2, 21.6, 6 }, { 16.8, 13.0, 4 } }) do
    local full, rv, n = c[1], c[2], c[3]
    local okNever, okEnd, runs = true, true, 0
    for _, every in ipairs({ 1, 2, 10, 20, 40 }) do
      for phase = 0, every - 1 do
        for _, reset in ipairs({ false, true }) do
          local S = quad(full, 0.4, 0)
          fly(S, REST)
          fly(S, 1200, rv - 1.0, 20.0)
          fly(S, 100, rv, 0.4)
          Q.amps = 0.0
          frames(S, 100, every, phase, function(t) return 0.4 + (rv - 0.4) * exp(-t / 0.48) end)
          if reset then Q.mah = 0 end
          frames(S, 100, every, phase, function() return 0.4 end)
          Q.amps = 0.4
          for _ = 1, 160 do
            frames(S, 1, every, phase, function() return rv end)
            if S.cells ~= nil and S.cells < n then okNever = false end
          end
          frames(S, 200, every, phase, function() return rv end)
          if S.cells ~= n then okEnd = false end
          runs = runs + 1
        end
      end
    end
    local tag = string.format("USB, %dS at %.1f V unplugged (filtered fall, %d runs)", n, rv, runs)
    mock.check(okNever, tag .. ": never fewer cells")
    mock.check(okEnd, tag .. ": the same pack again keeps " .. n .. "S")
  end
  -- a slow tail after the filter: the voltage stays at 6.0 V for 5 s before it goes below
  -- PACK_MIN. With 6S latched a reading below 3.12 V per cell is no rest voltage: 6S again.
  do
    local S = quad(25.2, 0.4, 0)
    fly(S, REST)
    fly(S, 1200, 20.6, 20.0)
    fly(S, 100, 21.6, 0.4)
    Q.amps = 0.0
    frames(S, 100, 20, 0, function() return 6.0 end)
    frames(S, 60, 20, 0, function() return 0.4 end)
    mock.check(flyTotal(S, REST - 1, 21.6, 0.4), "USB, a tail at 6.0 V for 5 s: the total voltage before rest")
    fly(S, 1)
    mock.eq(S.cells, 6, "USB, a tail at 6.0 V for 5 s: the same 6S again is 6S")
    -- a slow fall (0.1 V every 0.2 s): every short rest window of it ends in less than
    -- 0.5 s with the link up, so none is a rest voltage: 6S again
    S = quad(25.2, 0.4, 0)
    fly(S, REST)
    fly(S, 1200, 20.6, 20.0)
    fly(S, 100, 21.6, 0.4)
    Q.amps = 0.0
    frames(S, 400, 1, 0, function(t) return 21.6 - floor(t * 5) * 0.1 end)
    frames(S, 60, 1, 0, function() return 0.4 end)
    mock.check(flyTotal(S, REST - 1, 21.6, 0.4), "USB, a slow fall: the total voltage before rest")
    fly(S, 1)
    mock.eq(S.cells, 6, "USB, a slow fall of 0.5 V/s: the same 6S again is 6S")
  end

  -- the pack unplugged after landing (the link is lost), then the quad on USB on the bench:
  -- the FC and the RX start, and the first fresh frame is 0.1 V with Capa 0 (a new pack,
  -- (b), with no fresh pack voltage after the gap). The old pack's rest voltage is the
  -- last one before the gap, also when the widget saw no gap before (no run start) or a
  -- failsafe in flight (an older run start). The same used 6S plugged in later is 6S.
  for _, failsafe in ipairs({ false, true }) do
    for _, usb in ipairs({ 40, 400 }) do
      local tag = string.format("USB after landing (%s, %d s on USB)",
        failsafe and "a failsafe before" or "no gap before", usb // 20)
      local S = quad(25.2, 0.4, 0)
      fly(S, REST)
      if failsafe then
        fly(S, 600, 22.8, 20.0)
        fly(S, 10, 23.4, 1.0)
        lost(S, 40)
      end
      fly(S, 2400, 20.4, 20.0)
      fly(S, 400, 21.6, 0.5)
      lost(S, 600)
      Q.mah = 0
      mock.check(flyTotal(S, usb, 0.1, 0.0), tag .. ": no count without a pack")
      mock.check(flyTotal(S, REST - 1, 21.6, 0.5), tag .. ": the same 6S, the total voltage before rest")
      fly(S, 1)
      mock.eq(S.cells, 6, tag .. ": the same 6S again is 6S")
      mock.near(S.cellV, 3.6, 1e-6, tag .. ": cellV 3.6")
    end
  end
  -- the same start, then another pack: a full 5S at 21.0 V is 5S (not at the old rest
  -- voltage), a full 6S is 6S
  for _, c in ipairs({ { 21.0, 5 }, { 25.2, 6 } }) do
    local S = quad(25.2, 0.4, 0)
    fly(S, REST)
    fly(S, 2400, 20.4, 20.0)
    fly(S, 400, 21.6, 0.5)
    lost(S, 600)
    Q.mah = 0
    fly(S, 40, 0.1, 0.0)
    fly(S, REST, c[1], 0.5)
    mock.eq(S.cells, c[2], string.format("USB after landing, then a full %dS: %dS", c[2], c[2]))
  end
  -- a power cut (a loose XT60): the first frame after the gap is 0.3 V (the FC filter
  -- starts at 0 V), then the same pack at its rest voltage: 6S
  do
    local S = quad(25.2, 0.4, 0)
    fly(S, REST)
    fly(S, 600, 22.8, 20.0)
    fly(S, 20, 23.6, 1.0)
    lost(S, 60)
    fly(S, 1200, 20.4, 20.0)
    fly(S, 100, 21.6, 0.5)
    lost(S, 60)
    Q.mah = 0
    fly(S, 1, 0.3, 0.5)
    fly(S, REST + 40, 21.6, 0.5)
    mock.eq(S.cells, 6, "power cut, the first frame 0.3 V: 6S at the old rest voltage")
    -- a power cut 0.3 s after landing: a rest window that ends with the link needs no
    -- minimum time (the RX lost its power with the pack, so no falling voltage came)
    S = quad(25.2, 0.4, 0)
    fly(S, REST)
    fly(S, 1200, 20.4, 20.0)
    fly(S, 6, 21.6, 0.5)
    lost(S, 60)
    Q.mah = 0
    fly(S, REST + 40, 21.6, 0.5)
    mock.eq(S.cells, 6, "power cut 0.3 s after landing: 6S at the old rest voltage")
    -- ESC passthrough: no battery frames for 80 s (the values old after 20 s), then the FC
    -- starts again and the first frame is 0.4 V: the same pack, 6S
    S = quad(25.2, 0.4, 0)
    fly(S, REST)
    fly(S, 2400, 20.4, 20.0)
    fly(S, 400, 21.6, 0.5)
    quiet(S, 400)
    mock.setOld("RxBt"); mock.setOld("Curr"); mock.setOld("Capa")
    quiet(S, 1200)
    Q.mah = 0
    fly(S, 1, 0.4, 0.5)
    fly(S, REST + 40, 21.6, 0.5)
    mock.eq(S.cells, 6, "ESC passthrough, then an FC start (the first frame 0.4 V): 6S")
  end

  -- two new packs before a latch: the old count and its rest voltage stay for the latch
  -- (a 6S landed at 21.6 V; another pack at idle for 1 s, flown at once and swapped
  -- without rest; then the first 6S again at 21.6 V: 6S)
  local S = quad(25.2, 0.4, 0)
  fly(S, REST)
  fly(S, 1200, 20.6, 20.0)
  fly(S, 100, 21.6, 0.4)
  swap(S, 120, 25.2, 0.4)
  fly(S, 20)
  mock.check(flyTotal(S, 1200, 23.0, 20.0), "two new packs: the second pack, flown at once, has no count")
  swap(S, 120, 21.6, 0.4)
  mock.check(flyTotal(S, REST - 1), "two new packs: the total voltage before rest")
  fly(S, 1)
  mock.eq(S.cells, 6, "two new packs: the first 6S again at its rest voltage is 6S")

  -- no new pack, no lower count: random loads, voltage steps and spikes (2.6..26.5 V, so
  -- 6S never goes up), link losses, tool pauses, background, FC starts without a link
  -- loss (Capa 0, the voltage filter below PACK_MIN for less than 1 s) and Capa that
  -- continues. The count stays 6S, and it is nil only while the RX voltage is below
  -- PACK_MIN.
  math.randomseed(20261003)
  local rnd = math.random
  for _, kind in ipairs({ "capa", "nocapa", "none", "zero" }) do
    local hasCurr = kind == "capa" or kind == "nocapa"
    if kind == "capa" then S = quad(25.2, 0.4, 0)
    elseif kind == "nocapa" then S = quad(25.2, 0.4)
    elseif kind == "zero" then S = quad(25.2, 0.0, 0)
    else S = quad(25.2) end
    fly(S, REST)
    local okCount, okNil, okLost = true, true, true
    local function watch()
      if S.cells == nil then
        if not (S.rxV ~= nil and S.rxV < telem.PACK_MIN) then okNil = false end
      elseif S.cells ~= 6 then
        okCount = false
      end
    end
    local function amps()
      if not hasCurr then return 0.0 end
      if rnd(1, 3) == 1 then return rnd(0, 25) / 10 end
      return rnd(0, 400) / 10
    end
    for _ = 1, 250 do
      local r = rnd(1, 10)
      if r == 1 then
        if not lost(S, rnd(1, 800)) then okLost = false end
      elseif r == 2 then
        pause(rnd(1, 800))
      elseif r == 3 then
        bg(S, rnd(1, 400), rnd(150, 252) / 10, amps())
      elseif r == 4 then
        -- an FC start without a link loss: fresh frames, then Capa 0 with a low voltage
        -- for less than 1 s, then the same pack
        fly(S, 2); watch()
        if Q.capa then Q.mah = 0 end
        for _ = 1, rnd(1, 18) do fly(S, 1, rnd(0, 24) / 10, 0.0); watch() end
        fly(S, 1, rnd(180, 252) / 10, 0.4); watch()
      elseif r == 5 then
        -- a short spike or a dip
        for _ = 1, rnd(1, 20) do fly(S, 1, rnd(26, 265) / 10, amps()); watch() end
      else
        local v, a = rnd(150, 265) / 10, amps()
        for _ = 1, rnd(1, 400) do
          local x = v
          if rnd(1, 4) == 1 then x = v + rnd(-1, 1) / 10 end
          fly(S, 1, x, a); watch()
        end
      end
    end
    local sfx = " (" .. kind .. ")"
    mock.check(okCount, "random flight without a new pack" .. sfx .. ": the count stays 6S")
    mock.check(okNil, "random flight without a new pack" .. sfx .. ": no count only below PACK_MIN")
    mock.check(okLost, "random flight without a new pack" .. sfx .. ": the count stays while the link is down")
  end
end

---------------------------------------------------------------- upward correction
do
  -- a used 6S plugged in at 21.0 V (3.5 V per cell) is counted 5S (documented limit);
  -- a voltage that 5S cannot give for 1.5 s gives 6S
  local S = quad(21.0, 0.3, 0)
  fly(S, REST)
  mock.eq(S.cells, 5, "upward: a used 6S at 21.0 V at rest is counted 5S (limit)")
  fly(S, 30, 25.2)
  mock.eq(S.cells, 5, "upward: not before 1.5 s")
  fly(S, 1)
  mock.eq(S.cells, 6, "upward: 25.2 V for 1.5 s raises the count to 6S")
  fly(S, 400, 19.0, 20.0)
  mock.eq(S.cells, 6, "upward: sag does not lower the count")
  fly(S, 400, 19.0, 0.3)
  mock.eq(S.cells, 6, "upward: a low voltage at rest does not lower the count")
  fly(S, 5, 27.0)
  fly(S, 40, 24.0)
  mock.eq(S.cells, 6, "upward: a 0.25 s spike does not raise the count")
  -- a tick without link starts the 1.5 s again
  S = quad(21.0, 0.3, 0)
  fly(S, REST)
  fly(S, 20, 25.2)
  lost(S, 1)
  fly(S, 30)
  mock.eq(S.cells, 5, "upward: the 1.5 s start again after a tick without link")
  fly(S, 1)
  mock.eq(S.cells, 6, "upward: 6S 1.5 s after the link came back")
  -- the margin: 4S latched, 17.7 V (below 4 x 4.42 + 0.10) stays 4S, 17.9 V gives 5S
  S = quad(16.8, 0.3, 0)
  fly(S, REST)
  fly(S, 200, 17.7)
  mock.eq(S.cells, 4, "upward: 17.7 V is within the margin of 4S")
  fly(S, 31, 17.9)
  mock.eq(S.cells, 5, "upward: 17.9 V for 1.5 s gives 5S")
  -- a quick swap 3S -> 4S without Capa (link lost 3 s): the upward rule finds 4S
  S = quad(12.6, 0.4)
  fly(S, REST)
  swap(S, 60, 16.8, 0.3)
  fly(S, 30)
  mock.eq(S.cells, 3, "quick swap 3S -> 4S (no Capa): not before 1.5 s")
  fly(S, 1)
  mock.eq(S.cells, 4, "quick swap 3S -> 4S (no Capa): 4S after 1.5 s (upward rule)")
end

---------------------------------------------------------------- rxCells option
do
  local S = quad(12.8, 0.3, 0)
  local o = { rxCells = 4 }
  fly(S, 1, nil, nil, o)
  mock.eq(S.cells, 4, "rxCells: fixed 4 at once, even when 12.8 V looks like 3S")
  mock.near(S.cellV, 3.2, 1e-6, "rxCells: cellV")
  -- link lost in flight for 8 s and back under load: the fixed count stays
  fly(S, 20, 14.0, 20.0, o)
  lost(S, 160, false, o)
  run(S, 1, o)
  mock.eq(S.cells, 4, "rxCells: the fixed count also without a fresh value")
  fly(S, 1, 13.2, 18.0, o)
  mock.eq(S.cells, 4, "rxCells: the fixed count under load after the loss")
  mock.near(S.cellV, 3.3, 1e-6, "rxCells: cellV 3.3")
  linkDown()
  run(S, 1, o)
  mock.eq(S.cells, 4, "rxCells: the fixed count without link")
  mock.eq(S.cellV, nil, "rxCells: no cellV without link")
  linkUp()
  -- back to automatic: the first reading never made a rest window under load, no count
  -- yet; then the count at rest
  o.rxCells = 0
  fly(S, 1, 13.2, 18.0, o)
  mock.eq(S.cells, nil, "rxCells 0: automatic, no count under load")
  mock.check(flyTotal(S, REST - 1, 12.8, 0.3, o), "rxCells 0: no count before 3 s at rest")
  fly(S, 1, nil, nil, o)
  mock.eq(S.cells, 3, "rxCells 0: 3S after 3 s at rest")
  -- a fixed 6 overrides a latched automatic count at once
  o.rxCells = 6
  fly(S, 1, nil, nil, o)
  mock.eq(S.cells, 6, "rxCells 6: overrides the automatic 3S")
end

---------------------------------------------------------------- background tracking
do
  -- a pack change while the dashboard is not on screen (Capa starts again): the new pack
  -- is counted in background
  local S = quad(16.4, 0.3, 0)
  fly(S, REST)
  mock.eq(S.cells, 4, "track: latched 4S")
  bg(S, 1200, 14.8, 15.0)
  lost(S, 120, true)
  Q.v, Q.mah, Q.amps = 8.4, 0, 0.3
  bg(S, REST)
  run(S, 1)
  mock.eq(S.cells, 2, "track: a 2S at rest is counted in background")
  -- a battery thrown out in a crash; another quad on the same model 20 min later: the
  -- new FC starts Capa at 0, so the new pack is counted at rest
  for _, c in ipairs({ { 16.8, 4 }, { 21.0, 5 } }) do
    S = quad(25.2, 0.5, 0)
    fly(S, REST)
    fly(S, 1200, 21.0, 20.0)
    lost(S, 24000, true)                    -- 20 min, the dashboard not on screen
    Q.v, Q.mah, Q.amps = c[1], 0, 0.3
    local six = false
    for _ = 1, REST - 1 do
      fly(S, 1)
      if S.cells == 6 then six = true end
    end
    mock.check(not six and S.cells == nil, string.format("crash: the full %dS is never shown as 6S", c[2]))
    fly(S, 1)
    mock.eq(S.cells, c[2], string.format("crash: the full %dS is counted after 3 s at rest", c[2]))
  end
end

---------------------------------------------------------------- timers
do
  mock.install()
  mock.timers = { { mode = 1, value = 65 }, { mode = 0, value = 0 }, { mode = 3, value = 3725 } }
  mock.set("timer1", 65); mock.set("timer2", 0); mock.set("timer3", 3725)
  local S = telem.new()
  run(S, 1)
  mock.eq(S.timers[1].sec, 65, "timer1 used")
  mock.eq(S.timers[2].sec, nil, "timer2 unused (mode OFF) -> nil")
  mock.eq(S.timers[3].sec, 3725, "timer3 over one hour")
  mock.set("timer1", -5)
  run(S, 1)
  mock.eq(S.timers[1].sec, -5, "expired count-down timer keeps its sign")
  mock.timers[2].mode = 2
  mock.set("timer2", 10)
  run(S, 41)                      -- modes are read every 2 s
  mock.eq(S.timers[2].sec, 10, "timer2 used after its mode changed")
  local gt = model.getTimer
  model.getTimer = nil
  mock.timers[3].mode = 0
  run(S, 41)
  mock.eq(S.timers[3].sec, 3725, "no model.getTimer: timer counts as used")
  model.getTimer = gt
end

---------------------------------------------------------------- TX battery
do
  mock.install()
  local S = telem.new()
  local function st(v)
    mock.set("tx-voltage", v)
    run(S, 1)
    return S.txState
  end
  mock.eq(st(8.2), "full", "tx range: 8.2 full")
  mock.eq(st(7.6), "ok", "tx range: 7.6 ok")
  mock.eq(st(7.2), "warn", "tx range: 7.2 warn")
  mock.eq(st(6.9), "low", "tx range: 6.9 low")
  mock.eq(st(6.45), "low", "tx range: at warn level low")
  mock.eq(st(6.3), "dead", "tx range: below min dead")
  mock.eq(st(0), "dead", "tx range: 0 dead")
  -- radio range not readable: fixed thresholds
  mock.install()
  mock.gs = nil
  S = telem.new()
  mock.eq(st(7.9), "full", "tx fixed: 7.9 full")
  mock.eq(st(7.5), "ok", "tx fixed: 7.5 ok")
  mock.eq(st(7.1), "warn", "tx fixed: 7.1 warn")
  mock.eq(st(7.0), "low", "tx fixed: 7.0 low")
  mock.eq(st(0), "dead", "tx fixed: 0 dead")
  -- a 1S radio (3.3..4.2 V) with its own range
  mock.gs = { battMin = 3.3, battMax = 4.2, battWarn = 3.4 }
  run(S, 41)
  mock.eq(st(4.1), "full", "tx 1S range: 4.1 full")
  mock.eq(st(3.35), "low", "tx 1S range: 3.35 low")
end

---------------------------------------------------------------- packet rate through the elrs module
do
  mock.install()
  sensorsOfModel1()
  local calls = 0
  local elrs = { rateHz = function(E, rfmd) calls = calls + 1; if rfmd == 7 then return 250 end return nil end }
  local E = { version = "4.1.0" }
  local S = telem.new()
  run(S, 1, opts, E, elrs)
  mock.eq(S.rateHz, 250, "rate: from elrs.rateHz")
  mock.set("RFMD", 99)
  run(S, 1, opts, E, elrs)
  mock.eq(S.rateHz, nil, "rate: unknown RFMD -> nil")
  mock.eq(S.rfmd, 99, "rate: raw rfmd kept")
  run(S, 1, opts, E, nil)
  mock.eq(S.rateHz, nil, "rate: no elrs module -> nil")
  mock.set("RFMD", 7)
  mock.set("RQly", 0); mock.set("TPWR", 0)
  run(S, 1, opts, E, elrs)
  mock.eq(S.connected, true, "rate: RFMD > 0 alone counts as link")
  mock.set("RFMD", 0)
  run(S, 1, opts, E, elrs)
  mock.eq(S.rateHz, nil, "rate: nil when not connected")
end

---------------------------------------------------------------- changed counter and light mode
do
  mock.install()
  sensorsOfModel1()
  local S = telem.new()
  run(S, 3)
  local c = S.changed
  run(S, 3)
  mock.eq(S.changed, c, "changed: no change -> same counter")
  mock.set("1RSS", -61)
  run(S, 1)
  mock.eq(S.changed, c + 1, "changed: one change -> +1")
  -- light mode: only link and battery
  mock.set("1RSS", -80)
  mock.set("RQly", 90)
  mock.advance(5)
  telem.read(S, mock.time, opts, nil, nil, true)
  mock.eq(S.lq, 90, "light: lq read")
  mock.eq(S.rssi1, -61, "light: rssi not read")
end

---------------------------------------------------------------- clock
do
  mock.install()
  local S = telem.new()
  run(S, 1)
  mock.dt.hour, mock.dt.min, mock.dt.day, mock.dt.mon = 23, 59, 31, 12
  run(S, 21)
  mock.eq(S.clock, "23:59", "clock after 1 s")
  mock.eq(S.date, "31 Dec", "date after 1 s")
end

---------------------------------------------------------------- CPU cost (desktop VM instructions)
do
  -- the 200 measured ticks cover the rest window, the latch (Curr 1.2 A, 16.4 V) and the
  -- latched count; a moving voltage then restarts nothing (the count is latched)
  mock.install()
  sensorsOfModel1()
  mock.set("Capa", 0)                       -- a pack plugged in now
  local elrs = { rateHz = function(E, rfmd) return 250 end }
  local E = { version = "4.1.0" }
  local S = telem.new()
  run(S, 10, opts, E, elrs)
  local worst, total = 0, 0
  for i = 1, 200 do
    mock.advance(5)
    if i % 7 == 0 then mock.set("1RSS", -60 - (i % 5)) end
    if i > 120 then mock.set("RxBt", 16.0 + (i % 3) * 0.2) end
    local n = mock.count(telem.read, S, mock.time, opts, E, elrs, false)
    total = total + n
    if n > worst then worst = n end
  end
  mock.eq(S.cells, 4, "CPU: the count latched during the measured ticks")
  mock.advance(5)
  local light = mock.count(telem.read, S, mock.time, opts, E, elrs, true)
  mock.advance(5)
  local tr = mock.count(telem.track, S, mock.time)
  print(string.format("telem.read: typical %d, worst %d instructions; light %d; track %d",
    total // 200, worst, light, tr))
  mock.check(worst < 1500, "telem.read worst case below 1500 instructions")
  mock.check(total // 200 < 800, "telem.read typical below 800 instructions")
  mock.check(light < 400, "telem.read light below 400 instructions")
  mock.check(tr < 300, "telem.track below 300 instructions")
end

mock.finish("glue_telem_test")
