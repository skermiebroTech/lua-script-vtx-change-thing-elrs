-- lib/telem.lua: telemetry snapshot S for the dashboard (data only, no drawing).
--
-- Sensor ids come from getFieldInfo(name).id, because getValue(name) returns 0 for an
-- unknown name. Ids are kept per instance in S._ids (false = sensor not in the model) and
-- one field is checked again every RESOLVE_EVERY ticks (round-robin), so sensors that are
-- discovered, deleted or renumbered later are found without a getFieldInfo call per tick.
--
-- Timers: the value comes from getValue(<id of "timerN">) every tick (no table is made);
-- model.getTimer(n).mode is read every 2 s only to find unused timers (mode 0 = OFF).
--
-- TX battery: getValue("tx-voltage"). The state uses the radio's own battery range from
-- getGeneralSettings() (battMin, battMax, battWarn) when it is valid, else 7.1/7.5/7.9 V.
--
-- RX cell count (S.cells). rxCells option 1..14: S.cells = rxCells always. rxCells 0 (auto)
-- follows one principle: when in doubt, no count (the dashboard shows the total voltage),
-- and where a rule must choose, the count is too high (the cell voltage shows too low,
-- never a used pack fuller than it is).
-- * Fresh readings only: the link is up and getSourceValue tells that the value is not
--   old. EdgeTX keeps a value after a link loss and only marks it old (also after 20 s
--   without a new value). The RX voltage V, Curr and Capa are read this way.
-- * New pack: no count (S.cells and S.cellV nil, neutral battery icon) until a rest window
--   latches one. A new pack is (a) the first fresh V after the widget started; (b) a fresh
--   Capa more than 10 mAh (CAPA_DROP) below the last one when fresh V had a gap of more
--   than 1 s since the last Capa reading (the FC sets Capa to about 0 when it starts, and
--   a pack change cuts the power of the RX, so the link is lost); (c) fresh V below
--   PACK_MIN for 1 s (LOW_TIME) with the link up (no pack: the FC runs from USB).
-- * Same pack, the count stays: a Capa drop without that gap (the FC started again from
--   the OSD menu, the configurator or a tool; the RX kept its power); V below PACK_MIN for
--   less than 1 s (the voltage filter of an FC that starts again begins at 0 V); a gap of
--   any length without a Capa drop (link lost, failsafe, a tool script open).
-- * Used pack of unknown history: the first fresh Capa after the widget started is above
--   100 mAh (CAPA_JOIN) and no count is latched (a model change away and back, a radio
--   restart, a USB storage visit): no count until the next new pack.
-- * Rest window: every fresh V stays within 0.15 V (REST_RIPPLE) and every fresh Curr is
--   2.5 A (REST_CURR) or less (an FC with an HD VTX takes about 2 A at idle); without a
--   fresh Curr, V alone decides. A tick without a fresh V, or more than 1 s without a
--   read, ends the window.
-- * Rest voltage (for the keep rule below): the last reading of a rest window of 0.5 s
--   (REST_HOLD) or more, or of any length when a gap ends it (the RX lost its power with
--   the pack). A window that starts more than 0.15 V below the reading before it counts
--   only after 3 s, and with a count n a reading below 3.12 V x n is no rest: when a pack
--   is unplugged from an FC on USB, the FC filter lets the voltage fall for about 1 s, and
--   with one battery frame per second a reading of that fall stays for 1 s.
-- * Latch, only while there is no count: max(1, ceil(V / 4.42)) of a reading after 3 s
--   (REST_TIME) of rest (4.42 V = a full LiHV cell plus the 0.1 V sensor step and about
--   1 % FC error). After (b) or (c) the old count stays instead when it is higher, gives
--   3.20 V per cell or more, and V is within -0.04..+0.08 V per cell of the old pack's rest
--   voltage (for (b): the one from before the gap): the same pack plugged in again. That is
--   never lower than the latch.
-- * Upward: fresh V above count x 4.42 + 0.10 V for 1.5 s (sag only lowers V): the count
--   becomes ceil(V / 4.42).
-- * Nothing else changes a latched count. A count goes down only through (b) or (c) and
--   then a rest latch.
-- * An RX voltage that is old while the link is up shows for 2 s (OLD_SHOW), then S.rxV is
--   nil. A reading below PACK_MIN has no count.
-- Limits (set rxCells for such packs, and always for 7S and more and for Li-ion):
-- * A pack that is not full is counted from V at rest: n cells below (n - k) x 4.42 / n V
--   per cell give k cells less (one: 3S 2.95, 4S 3.32, 5S 3.54, 6S 3.68, 8S 3.87, 12S
--   4.05 V; two: 6S 2.95, 8S 3.32, 12S 3.68 V), and the cell voltage shows about 4.1 to
--   4.4 V. This happens to a used pack plugged in that is not at the old pack's rest
--   voltage (another pack, or one unplugged before it was at rest), to a used pack that
--   the widget finds first without a Capa sensor (model change, radio restart), and to a
--   widget that starts in flight without a Curr sensor.
-- * Without a Capa drop with a gap (no Capa sensor, an FC that always sends Capa 0, a pack
--   changed before it used 10 mAh) the count never goes down: a later pack with fewer
--   cells shows too low (6S, then a full 4S at 16.8 V shows 6S at 2.80 V). After (b) or
--   (c), a pack with fewer cells at about the old pack's rest voltage keeps the old count
--   too (a 6S landed at 21.0 V, then a full 5S shows 6S at 3.50 V).
-- * An RX with its own battery keeps its link: a pack change in less than 20 s is the
--   same pack.

local M = {}

local floor = math.floor
local ceil = math.ceil

local RESOLVE_EVERY = 4     -- ticks between two sensor id checks (one field per check)
local CLOCK_EVERY = 100     -- read the clock once per second
local SLOW_EVERY = 200      -- model name, timer modes, radio battery range: every 2 s
-- RX cell count (see the rules above; times in 10 ms ticks)
local CELL_DETECT = 4.42    -- count = ceil(V / CELL_DETECT)
local GAP_MAX = 100         -- more than 1 s without a fresh V: a gap (the rest window starts again)
local REST_TIME = 300       -- rest: 3 s of fresh readings
local REST_RIPPLE = 0.15    --   all within 0.15 V (one 0.1 V sensor step of noise)
local REST_CURR = 2.5       --   and every fresh current reading 2.5 A or less
local REST_HOLD = 50        -- rest voltage: the last reading of a rest of 0.5 s or more
local UP_MARGIN = 0.10      -- upward: V above count x CELL_DETECT + 0.10 V
local UP_TIME = 150         --   for 1.5 s
local CAPA_DROP = 10        -- Capa more than 10 mAh below the last value: the FC started again
local CAPA_JOIN = 100       -- a first Capa above 100 mAh: a used pack of unknown history
local KEEP_MIN = 3.20       -- after a new pack the old count stays when it gives 3.20 V per cell
local KEEP_LO = 0.04        --   or more and the voltage is within -0.04..+0.08 V per cell of
local KEEP_HI = 0.08        --   the old pack's rest voltage
local REST_LOW = KEEP_MIN - KEEP_HI   -- with a count n, V below 3.12 V x n is no rest voltage
local PACK_MIN = 2.5        -- an RX battery reading below this is not used for the cell count
M.PACK_MIN = PACK_MIN
local LOW_TIME = 100        -- readings below PACK_MIN for 1 s: no pack
local OLD_SHOW = 200        -- an old RX voltage with the link up shows for 2 s
local IMPLAUSIBLE = 0.05    -- S.rxImplausible: a reading from 0.05 V up to PACK_MIN

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local FM_NAMES = { [0] = "FM0", "FM1", "FM2", "FM3", "FM4", "FM5", "FM6", "FM7", "FM8" }

-- Field key and its sensor names. The first name that exists in the model is used.
local FKEY = { "rxV", "lq", "rssi1", "rssi2", "snr", "rfmd", "tpwr", "curr", "capa", "sats", "gps", "fm", "ant" }
local FNAMES = {
  { "VFAS", "RxBt", "Bat", "BATT", "A4" },
  { "RQly", "LQ", "TQly" },
  { "1RSS" },
  { "2RSS" },
  { "RSNR" },
  { "RFMD" },
  { "TPWR", "TxPw" },
  { "Curr", "CUR" },
  { "Capa", "CAP" },
  { "Sats", "SATS", "SAT" },
  { "GPS" },
  { "FM", "FMODE" },
  { "ANT" },
}
local NF = #FKEY

local function fieldId(name)
  if getFieldInfo == nil then return false end
  local fi = getFieldInfo(name)
  if fi ~= nil and fi.id ~= nil then return fi.id end
  return false
end

local function resolve(names)
  for i = 1, #names do
    local id = fieldId(names[i])
    if id then return id end
  end
  return false
end

-- Integer reading (rounded), nil when the sensor is missing or not a number.
local function rint(id)
  if id then
    local v = getValue(id)
    if type(v) == "number" then return floor(v + 0.5) end
  end
  return nil
end

-- Float reading (always a float, so later ~= compares float with float), or nil.
local function rnum(id)
  if id then
    local v = getValue(id)
    if type(v) == "number" then return v + 0.0 end
  end
  return nil
end

-- Value (float) and true when it was received after the last link loss (not old).
-- getSourceValue returns nothing for a sensor without a value.
local function rnumCur(id)
  if not id then return nil, false end
  if getSourceValue ~= nil then
    local v, cur = getSourceValue(id)
    if type(v) == "number" then return v + 0.0, cur == true end
    return nil, false
  end
  local v = getValue(id)
  if type(v) == "number" then return v + 0.0, true end
  return nil, false
end

-- RX cell count: a new pack ((b) or (c) of the rules) has no count until the next rest
-- latch. The old count and rv (the old pack's rest voltage) are kept for that latch; a
-- second new pack before it changes nothing. The open rest window ends without a rest
-- voltage (its readings can be the new pack's).
local function newPack(S, w, rv)
  local n = S._latch
  if n ~= nil then
    S._prevN, S._prevV = n, rv
    S._latch = nil
  end
  S._upAt = nil
  S._join = nil
  w.at = nil
end

-- RX cell count: the rest window ends. Its last reading becomes the rest voltage when the
-- window did not start with a fall (that one counts only after REST_TIME) and lasted
-- hold: REST_HOLD while the link is up, 0 at a gap (the RX lost its power with the pack,
-- so no falling voltage came).
local function restEnd(S, w, hold)
  local t0 = w.at
  if t0 ~= nil then
    w.at = nil
    if not w.fall and w.t - t0 >= hold then S._restV = w.v end
  end
end

-- RX cell count, one tick (rules at the top of this file). Changes only private fields.
-- All values are fresh (link up, not old) or nil: fv is the RX voltage (also a value
-- below PACK_MIN), amps the Curr value, capa the Capa value.
local function cellTick(S, now, fv, amps, capa)
  local w = S._rw
  local at = S._freshAt
  local gap = at == nil or now - at > GAP_MAX
  if fv == nil or fv < PACK_MIN then
    if fv == nil or gap then restEnd(S, w, 0) else restEnd(S, w, REST_HOLD) end
    if fv ~= nil then
      -- (c) no pack when it stays low for 1 s; the first frames of an FC that starts
      -- again are low only for a moment
      local lo = S._lowAt
      if lo == nil then
        S._lowAt = now
      elseif now - lo >= LOW_TIME then
        newPack(S, w, S._restV)
      end
      fv = nil
    end
  else
    S._lowAt = nil
    if gap then
      -- a new run of fresh readings after a gap: keep the rest voltage from before it
      -- (the old pack's, also when Capa comes later than the voltage)
      restEnd(S, w, 0)
      S._runAt = now
      S._runV = S._restV
    end
    S._freshAt = now
  end
  if capa ~= nil then
    local last = S._capa
    if last == nil then
      -- the first fresh Capa after the widget started
      if capa > CAPA_JOIN and S._latch == nil then S._join = true end
    elseif capa < last - CAPA_DROP then
      -- (b) the FC started again: a new pack only when fresh V had a gap since the last
      -- Capa reading (the RX lost its power), else the same pack. The old pack's rest
      -- voltage: the last one when no fresh V came after the gap, else the one from
      -- before the current run.
      at = S._freshAt
      if at == nil or now - at > GAP_MAX then
        newPack(S, w, S._restV)
      elseif S._runAt > S._capaAt then
        newPack(S, w, S._runV)
      end
    end
    S._capa = capa
    S._capaAt = now
  end
  if fv == nil then
    S._upAt = nil
    return
  end
  local n = S._latch
  if n ~= nil then
    -- upward: a voltage that the count cannot give, for 1.5 s. No rule lowers a count.
    if fv > n * CELL_DETECT + UP_MARGIN then
      local up = S._upAt
      if up == nil then
        S._upAt = now
      elseif now - up >= UP_TIME then
        S._upAt = nil
        local c = ceil(fv / CELL_DETECT)
        if c > n then
          n = c
          S._latch = c
        end
      end
    else
      S._upAt = nil
    end
  end
  -- rest window: it latches a count (no count yet) and gives the rest voltage. A load, a
  -- voltage step, or (with a count) a voltage that cannot be the pack at rest ends it.
  local fall = S._lastV ~= nil and fv < S._lastV - REST_RIPPLE
  S._lastV = fv
  if (amps ~= nil and amps > REST_CURR) or (n ~= nil and fv < REST_LOW * n) then
    restEnd(S, w, REST_HOLD)
    return
  end
  local t0 = w.at
  if t0 ~= nil then
    local lo, hi = w.lo, w.hi
    if fv < lo then lo = fv elseif fv > hi then hi = fv end
    if hi - lo > REST_RIPPLE then
      restEnd(S, w, REST_HOLD)
      t0 = nil
    else
      w.lo, w.hi = lo, hi
    end
  end
  if t0 == nil then
    t0 = now
    w.at, w.lo, w.hi, w.fall = now, fv, fv, fall
  end
  w.v, w.t = fv, now
  if now - t0 < REST_TIME then return end
  -- at rest for 3 s: the reading is the rest voltage (also after a fall), and without a
  -- count it gives one, or the old (higher) count at the old pack's rest voltage after a
  -- new pack
  S._restV = fv
  if n ~= nil or S._join then return end
  local c = ceil(fv / CELL_DETECT)
  if c < 1 then c = 1 end
  local pn, rv = S._prevN, S._prevV
  if pn ~= nil then
    S._prevN = nil
    if pn > c and rv ~= nil and fv >= rv - KEEP_LO * pn and fv <= rv + KEEP_HI * pn
        and fv >= KEEP_MIN * pn then
      c = pn
    end
  end
  S._latch = c
end

-- Reads the fresh Curr and Capa values (nil when old, missing or without link) and runs
-- one cell count tick. fv: the fresh RX voltage or nil.
local function cellRead(S, now, ids, conn, fv)
  local amps, capa = nil, nil
  if conn then
    local x, cur = rnumCur(ids.curr)
    if cur then amps = x end
    x, cur = rnumCur(ids.capa)
    if cur then capa = x end
  end
  cellTick(S, now, fv, amps, capa)
end

local function readBattRange(S)
  local lo, hi, warn
  if getGeneralSettings ~= nil then
    local g = getGeneralSettings()
    if type(g) == "table" then
      lo, hi, warn = g.battMin, g.battMax, g.battWarn
    end
  end
  if type(lo) == "number" and type(hi) == "number" and lo > 1.0 and hi - lo >= 0.5 then
    S._bMin = lo
    S._bMax = hi
    if type(warn) == "number" and warn >= lo and warn < hi then S._bWarn = warn else S._bWarn = lo end
  else
    S._bMin = nil
    S._bMax = nil
    S._bWarn = nil
  end
end

-- TX battery state. With the radio range the thresholds are 75/55/35 % of the range
-- (= 7.9/7.5/7.1 V on a 6.4..8.4 V 2S range, the same as the old fixed values).
local function txStateOf(S, v)
  if v == nil then return "low" end
  if v < 0.05 then return "dead" end
  local lo = S._bMin
  if lo ~= nil then
    if v < lo then return "dead" end
    if v <= S._bWarn then return "low" end
    local p = (v - lo) / (S._bMax - lo)
    if p >= 0.75 then return "full" end
    if p >= 0.55 then return "ok" end
    if p >= 0.35 then return "warn" end
    return "low"
  end
  if v >= 7.9 then return "full" end
  if v >= 7.5 then return "ok" end
  if v >= 7.1 then return "warn" end
  return "low"
end

-- Things that change rarely. Returns true when a public field changed.
local function readSlow(S)
  local ch = false
  local name = "MODEL"
  if model ~= nil and model.getInfo ~= nil then
    local info = model.getInfo()
    if info ~= nil and type(info.name) == "string" and info.name ~= "" then name = info.name end
  end
  if name ~= S.modelName then
    S.modelName = name
    ch = true
  end
  if model ~= nil and model.getTimer ~= nil then
    local used = S._tused
    for i = 1, 3 do
      local t = model.getTimer(i - 1)
      used[i] = (t ~= nil) and (t.mode ~= 0)
    end
  end
  local lo, hi, warn = S._bMin, S._bMax, S._bWarn
  readBattRange(S)
  if lo ~= S._bMin or hi ~= S._bMax or warn ~= S._bWarn then
    local st = txStateOf(S, S.txV)
    if st ~= S.txState then
      S.txState = st
      ch = true
    end
  end
  return ch
end

local function readClock(S)
  if getDateTime == nil then return false end
  local dt = getDateTime()
  if dt == nil then return false end
  local ch = false
  local h, mi, d, mo = dt.hour, dt.min, dt.day, dt.mon
  if type(h) == "number" and type(mi) == "number" and (h ~= S._hour or mi ~= S._min) then
    S._hour = h
    S._min = mi
    S.clock = string.format("%02d:%02d", h, mi)
    ch = true
  end
  if type(d) == "number" and (d ~= S._day or mo ~= S._mon) then
    S._day = d
    S._mon = mo
    S.date = string.format("%d %s", d, MONTHS[mo] or "")
    ch = true
  end
  return ch
end

function M.new()
  local S = {
    connected = false,
    gps = false,
    txState = "low",
    modelName = "MODEL",
    timers = { {}, {}, {} },
    clock = "--:--",
    date = "",
    changed = 0,
    rxImplausible = false,
    -- private
    _ids = {},
    _rc = 0,
    _rk = 0,
    _tids = {},
    _tused = { true, true, true },
    _txId = fieldId("tx-voltage"),
    _rw = {},          -- cell count rest window { at, lo, hi }
  }
  for k = 1, NF do
    S._ids[FKEY[k]] = resolve(FNAMES[k])
  end
  for i = 1, 3 do
    S._tids[i] = fieldId("timer" .. i)
  end
  S.gps = S._ids.gps ~= false
  return S
end

-- One sensor id check every RESOLVE_EVERY calls (round-robin over the fields).
local function resolveStep(S, ids)
  local rc = S._rc + 1
  if rc >= RESOLVE_EVERY then
    rc = 0
    local k = S._rk % NF + 1
    S._rk = k
    ids[FKEY[k]] = resolve(FNAMES[k])
  end
  S._rc = rc
end

-- Fills S in place. E and elrs (the elrs module) are optional; elrs.rateHz(E, rfmd)
-- gives the packet rate. light = true reads only the link and the RX battery (used while
-- the full-screen VTX page is open).
function M.read(S, now, options, E, elrs, light)
  local ids = S._ids
  local ch = false

  resolveStep(S, ids)

  -- link: live when RQly > 0, TPWR > 0 or RFMD > 0 (sensors read 0 when the link is down)
  local lq = rint(ids.lq)
  local tp = rint(ids.tpwr)
  local rf = rint(ids.rfmd)
  local conn = (lq ~= nil and lq > 0) or (tp ~= nil and tp > 0) or (rf ~= nil and rf > 0)
  if lq ~= S.lq then S.lq = lq; ch = true end
  if tp ~= S.tpwr then S.tpwr = tp; ch = true end
  if rf ~= S.rfmd then S.rfmd = rf; ch = true end
  if conn ~= S.connected then S.connected = conn; ch = true end

  -- RX battery (nil without link; an old value shows for 2 s) and cells
  local v, cur = rnumCur(ids.rxV)
  local fv = nil
  if conn and cur then fv = v end
  if v ~= nil and (v <= 0.0 or not conn) then v = nil end
  if v ~= nil and not cur then
    local t = S._oldAt
    if t == nil then S._oldAt = now elseif now - t > OLD_SHOW then v = nil end
  else
    S._oldAt = nil
  end
  if v ~= S.rxV then S.rxV = v; ch = true end
  local imp = v ~= nil and v >= IMPLAUSIBLE and v < PACK_MIN
  if imp ~= S.rxImplausible then S.rxImplausible = imp; ch = true end
  cellRead(S, now, ids, conn, fv)
  local cells = S._latch
  local fixed = options and options.rxCells
  if type(fixed) == "number" and fixed >= 1 then
    cells = floor(fixed)
  elseif v ~= nil and v < PACK_MIN then
    cells = nil                        -- not a pack: no count
  end
  if cells ~= S.cells then S.cells = cells; ch = true end
  local cv = nil
  if v ~= nil and cells ~= nil then cv = v / cells end
  if cv ~= S.cellV then S.cellV = cv; ch = true end

  if not light then
    -- slow and clock parts first (timer modes are used below)
    local st = S._slowT
    if st == nil or now - st >= SLOW_EVERY then
      S._slowT = now
      if readSlow(S) then ch = true end
    end
    local ct = S._clkT
    if ct == nil or now - ct >= CLOCK_EVERY then
      S._clkT = now
      if readClock(S) then ch = true end
    end

    -- RSSI: 0 means missing; best = the higher (less negative) of the two antennas
    local r1, r2 = rint(ids.rssi1), rint(ids.rssi2)
    if r1 == 0 then r1 = nil end
    if r2 == 0 then r2 = nil end
    local rb = r1
    if r2 ~= nil and (rb == nil or r2 > rb) then rb = r2 end
    if r1 ~= S.rssi1 then S.rssi1 = r1; ch = true end
    if r2 ~= S.rssi2 then S.rssi2 = r2; ch = true end
    if rb ~= S.rssi then S.rssi = rb; ch = true end

    local x = rint(ids.snr)
    if x ~= S.snr then S.snr = x; ch = true end
    x = rnum(ids.curr)
    if x ~= S.curr then S.curr = x; ch = true end
    x = rint(ids.capa)
    if x ~= S.capa then S.capa = x; ch = true end
    x = rint(ids.sats)
    if x ~= S.sats then S.sats = x; ch = true end
    x = rint(ids.ant)
    if x ~= S.ant then S.ant = x; ch = true end
    local gps = ids.gps ~= false
    if gps ~= S.gps then S.gps = gps; ch = true end

    -- flight mode: FM sensor text, else the name of the active flight mode
    local fm = nil
    local fid = ids.fm
    if fid then
      local t = getValue(fid)
      if type(t) == "string" and t ~= "" then fm = t end
    end
    if fm == nil and getFlightMode ~= nil then
      local n, name = getFlightMode()
      if type(name) == "string" and name ~= "" then
        fm = name
      elseif type(n) == "number" then
        fm = FM_NAMES[n]
      end
    end
    if fm ~= S.fm then S.fm = fm; ch = true end

    -- packet rate (the elrs module knows the RFMD table of the module version)
    local rate = nil
    if conn and rf ~= nil and elrs ~= nil then
      local fn = elrs.rateHz
      if fn ~= nil then
        rate = fn(E, rf)
        if type(rate) == "number" then rate = floor(rate + 0.5) else rate = nil end
      end
    end
    if rate ~= S.rateHz then S.rateHz = rate; ch = true end

    -- TX battery
    x = rnum(S._txId)
    if x ~= S.txV then
      S.txV = x
      S.txState = txStateOf(S, x)
      ch = true
    end

    -- timers: seconds (negative for an expired count-down timer), nil when unused
    local tids, used, T = S._tids, S._tused, S.timers
    for i = 1, 3 do
      local sec = nil
      if used[i] then sec = rint(tids[i]) end
      local t = T[i]
      if sec ~= t.sec then t.sec = sec; ch = true end
    end
  end

  if ch then S.changed = S.changed + 1 end
end

-- Cheap cell count tracking for background(): the same cell count rules run while the
-- dashboard is not on screen (Capa follows the pack, a new pack clears the count, a pack
-- at rest is counted), with the same round-robin id check (sensors found after the
-- widget started). Does not change public fields.
function M.track(S, now)
  local ids = S._ids
  resolveStep(S, ids)
  local lq, tp, rf = rint(ids.lq), rint(ids.tpwr), rint(ids.rfmd)
  local conn = (lq ~= nil and lq > 0) or (tp ~= nil and tp > 0) or (rf ~= nil and rf > 0)
  local fv = nil
  if conn then
    local v, cur = rnumCur(ids.rxV)
    if cur then fv = v end
  end
  cellRead(S, now, ids, conn, fv)
end

return M
