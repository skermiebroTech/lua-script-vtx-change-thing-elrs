-- lib/inputs.lua: sticks and trims I, by physical position (stick-mode aware).
--
-- The sources "rud", "ele", "thr", "ail" and "trim-rud" .. "trim-ail" are named by
-- function. The stick mode tells which physical gimbal or trim has each function
-- (EdgeTX input_mapping.cpp), with the physical order LH, LV, RV, RH:
--   mode 1: Rud Ele Thr Ail   mode 2: Rud Thr Ele Ail
--   mode 3: Ail Ele Thr Rud   mode 4: Ail Thr Ele Rud
-- Ids come from getFieldInfo (getValue of an unknown name returns 0).
--
-- Trims: getValue gives 8 * trim, so +/-1024 for normal trims and +/-4096 for extended
-- trims. Lua cannot read the "extended trims" setting of the model, so the extTrims
-- widget option tells it: 1 = normal, 2 = extended, 0 = auto (a value beyond +/-1024
-- turns I.trimExt on, and it stays on). The text is the EdgeTX one: percent of the
-- range, no sign.
--
-- Throttle output (I.thrOut): the value of the throttle INPUT line in percent, read with
-- getValue(id of "input1" + index). It includes the weight and offset of the throttle cap
-- (and a curve or trim of that line), so the dashboard can show the throttle that the
-- model really uses: it never goes above the cap line. nil when no input index is given.

local M = {}

local floor = math.floor

-- function index (1 = Rud, 2 = Ele, 3 = Thr, 4 = Ail) for physical LH, LV, RV, RH
local MODE_LUT = {
  { 1, 2, 3, 4 },
  { 1, 3, 2, 4 },
  { 4, 2, 3, 1 },
  { 4, 3, 2, 1 },
}
local STICKS = { "rud", "ele", "thr", "ail" }
local TRIMS = { "trim-rud", "trim-ele", "trim-thr", "trim-ail" }

local function fieldId(name)
  if getFieldInfo == nil then return false end
  local fi = getFieldInfo(name)
  if fi ~= nil and fi.id ~= nil then return fi.id end
  return false
end

-- Raw stick (+/-1024) to an integer percent with a small deadband against ADC noise.
local function stick(id)
  if not id then return 0 end
  local v = getValue(id)
  if type(v) ~= "number" then return 0 end
  local n = v * 100 / 1024
  if n > -0.8 and n < 0.8 then return 0 end
  n = floor(n + 0.5)
  if n > 100 then return 100 end
  if n < -100 then return -100 end
  return n
end

local function rawTrim(id)
  if not id then return 0 end
  local v = getValue(id)
  if type(v) ~= "number" then return 0 end
  return floor(v + 0.5)
end

-- Sets one trim slot when its raw value (or the range) changed. Returns true on change.
local function setTrim(I, slot, raw, full, force)
  local last = I._traw
  if raw == last[slot] and not force then return false end
  last[slot] = raw
  local p = raw * 100 / full
  if p > 100 then p = 100.0 elseif p < -100 then p = -100.0 end
  I.trim[slot] = p
  if raw == 0 then
    I.trimTxt[slot] = ""
  else
    local a = raw
    if a < 0 then a = -a end
    -- EdgeTX: divRoundClosest(abs(trim) * 100, trimMax)
    I.trimTxt[slot] = string.format("%d", floor((a * 100 + floor(full / 2)) / full))
  end
  return true
end

function M.new()
  local I = {
    mode = 2,
    left = { x = 0, y = 0 },
    right = { x = 0, y = 0 },
    trim = { lh = 0.0, lv = 0.0, rv = 0.0, rh = 0.0 },
    trimTxt = { lh = "", lv = "", rv = "", rh = "" },
    trimExt = false,
    changed = 0,
    -- private
    _sid = {},
    _tid = {},
    _traw = { lh = 0, lv = 0, rv = 0, rh = 0 },
    _ext = 0,                 -- extTrims option value of the last read
    _inBase = fieldId("input1"),   -- source id of input 1 (false when unknown)
  }
  for f = 1, 4 do
    I._sid[f] = fieldId(STICKS[f])
    I._tid[f] = fieldId(TRIMS[f])
  end
  return I
end

-- ext: the extTrims option (0 = auto, 1 = normal, 2 = extended); nil = auto.
-- thrIn: 0-based index of the throttle input line (lib/thrcap T.input), or nil.
function M.read(I, ext, thrIn)
  local ch = false
  local mode = 2
  if getStickMode ~= nil then
    local m = getStickMode()
    if type(m) == "number" and m >= 1 and m <= 4 then mode = floor(m) end
  end
  if mode ~= I.mode then I.mode = mode; ch = true end
  local lut = MODE_LUT[mode]
  local f1, f2, f3, f4 = lut[1], lut[2], lut[3], lut[4]

  -- gimbals: x = horizontal (+ right), y = vertical (+ up)
  local sid = I._sid
  local L, R = I.left, I.right
  local n = stick(sid[f1])
  if n ~= L.x then L.x = n; ch = true end
  n = stick(sid[f2])
  if n ~= L.y then L.y = n; ch = true end
  n = stick(sid[f3])
  if n ~= R.y then R.y = n; ch = true end
  n = stick(sid[f4])
  if n ~= R.x then R.x = n; ch = true end

  -- throttle output of the throttle input line (nil = show the raw stick)
  local out = nil
  local base = I._inBase
  if base and type(thrIn) == "number" and thrIn >= 0 then
    out = stick(base + floor(thrIn))
  end
  if out ~= I.thrOut then I.thrOut = out; ch = true end

  -- trims by physical slot
  local tid = I._tid
  local lh, lv, rv, rh = rawTrim(tid[f1]), rawTrim(tid[f2]), rawTrim(tid[f3]), rawTrim(tid[f4])
  local mode = 0
  if type(ext) == "number" then
    if ext >= 1.5 then mode = 2 elseif ext >= 0.5 then mode = 1 end
  end
  local want
  if mode == 2 then
    want = true
  elseif mode == 1 then
    want = false
  else
    -- auto: detect again after a fixed setting was used
    want = I.trimExt and I._ext == 0
    if not want and (lh > 1024 or lh < -1024 or lv > 1024 or lv < -1024
        or rv > 1024 or rv < -1024 or rh > 1024 or rh < -1024) then
      want = true
    end
  end
  I._ext = mode
  local force = false
  if want ~= I.trimExt then
    I.trimExt = want
    force = true              -- all slots again with the new range
    ch = true
  end
  local full = want and 4096 or 1024
  if setTrim(I, "lh", lh, full, force) then ch = true end
  if setTrim(I, "lv", lv, full, force) then ch = true end
  if setTrim(I, "rv", rv, full, force) then ch = true end
  if setTrim(I, "rh", rh, full, force) then ch = true end

  if ch then I.changed = I.changed + 1 end
end

return M
