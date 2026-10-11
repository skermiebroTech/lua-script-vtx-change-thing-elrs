-- lib/thrcap.lua: throttle cap. It sets the weight and the offset of the model's
-- throttle input line: weight = cap, offset = cap - 100. Stick low then always
-- gives -100 and stick high gives the cap (cap 75: weight 75, offset -25).
--
-- The firmware has no Lua function that changes an input line in place, and the
-- mixer task can run between any two Lua instructions (also while insertInput
-- copies the fields of a new line). This file uses the only order in which the
-- mixer never sees a half-written line:
--   1. insertInput(chn, 1, copy)  The copy with the new weight and offset goes
--                                 AFTER the live line 0. Line 0 has no switch, no
--                                 flight mode mask and side "both", so it is active
--                                 in every mixer cycle, and the first active line
--                                 of an input wins: line 1 is never evaluated.
--   2. Read back line 0 and line 1 and compare every field.
--   3. deleteInput(chn, 0)        One memmove while the mixer is stopped. The next
--                                 cycle uses the new line.
-- If a step fails, the extra line 1 is deleted again and line 0 stays as it was.
--
-- When in doubt, the cap is refused and the model is never written. It is allowed
-- only when all of these are true (see scan and mixReason):
--   a. Exactly one input has a line with the Thr stick (also inverted) as its source.
--   b. That input has one line: source Thr (not inverted), no switch, all flight
--      modes, side "both", plain weight above 0 and plain offset (no GVAR), and no
--      curve or an expo curve (an expo keeps the end points).
--   c. A mix line that Lua can read (any channel) takes the input with a plain
--      weight above 0.
--   d. No mix line that Lua can read (any channel) takes the Thr stick itself (also
--      inverted), the input inverted, the input with a negative or GVAR weight, or
--      the input with a function or custom curve (these can invert it).
-- The Lua mix list stops at the first mix line with the source "---" (see mixReason):
-- lines after it are not seen. When that hides the line that takes the input, rule c
-- refuses the cap; a raw Thr line hidden there cannot be seen.
--
-- Writes happen only when tick() is called with allowWrite (from refresh(), never
-- from background(): background also runs while the Inputs editor is open), at
-- most one swap per call, 400 ms after the last request (quick taps make one swap).
-- The model is read again every 2 s and after a model change. A request is
-- dropped when the model changed after it was made, when the line changed after
-- it was made (for example by hand in the Inputs editor while the request waited
-- for the next refresh: a newer manual setting is never overwritten), and when it
-- is more than 5 s old at the time of the swap (the main view was not shown for
-- that time: the cap does not change later without a new tap).
--
-- API:
--   T = thrcap.new()
--   thrcap.tick(T, now, allowWrite)   now = getTime()
--   thrcap.request(T, cap)            records a request (MIN..MAX); no model access
--   thrcap.target(T)                  value to show: pending, else cap, else the
--                                     weight of a custom line, else 0
--   thrcap.step(T, d)                 request(target + d) when the target is known
-- Fields: state ("ok" | "none" | "unsupported" | "busy" | "error"), msg (<= 30
-- chars), cap (0 = unknown), custom, weight, offset, pending (int or nil), pendAt,
-- input (0-based, -1 = none), rev (increments when a field changes).
-- A custom line (weight above 0, but offset not weight - 100 or weight above 100)
-- has custom = true and cap = 0; a request overwrites it with the cap formula.

local M = {}

M.MIN = 20
M.MAX = 100

local DEBOUNCE = 40       -- 400 ms (getTime() counts 10 ms ticks)
local SCAN_TIME = 200     -- read the model again every 2 s
local MODEL_TIME = 50     -- look for a model change every 0.5 s
local RESULT_TIME = 400   -- a result message shows for 4 s
local MAX_AGE = 500       -- a request more than 5 s old is not applied
local MAX_INPUTS = 32
local MAX_CHANNELS = 32   -- output channels of a colour radio

-- Every stored field of an input line (the keys of model.getInput). inputName is
-- one name for the whole input, not a line field: it is not copied.
local KEYS = { "name", "source", "scale", "weight", "offset", "switch",
               "curveType", "curveValue", "trimSource", "side", "flightModes" }
local NKEYS = #KEYS

local floor = math.floor
local fmt = string.format

local function fieldId(name)
  if getFieldInfo == nil then return nil end
  local fi = getFieldInfo(name)
  if fi ~= nil and type(fi.id) == "number" then return fi.id end
  return nil
end

-- A plain number. Lua values >= 1024 or <= -1024 are a GVAR or another source.
local function plain(v)
  return type(v) == "number" and v > -1024 and v < 1024
end

local function same(a, b)
  for i = 1, NKEYS do
    local k = KEYS[i]
    if a[k] ~= b[k] then return false end
  end
  return true
end

local function modelId()
  local m = model
  if m == nil or m.getInfo == nil then return "", "" end
  local info = m.getInfo()
  if type(info) ~= "table" then return "", "" end
  local n, f = info.name, info.filename
  if type(n) ~= "string" then n = "" end
  if type(f) ~= "string" then f = "" end
  return n, f
end

local function apiOk(m)
  return m ~= nil and m.getInputsCount ~= nil and m.getInput ~= nil
    and m.insertInput ~= nil and m.deleteInput ~= nil
end

-- The mix check of the throttle input (rules c and d). src = the mix source number of
-- the input, tid = the Thr stick. getMix (api_model.cpp) gives the raw source number
-- (srcRaw): input chn is getFieldInfo("input1").id + chn, and an inverted source is
-- negative. A weight of 1024 or more, or -1024 or less, is a GVAR or another source
-- (sourceNumValToLuaInt). Every line that Lua can read, on all 32 channels, is
-- checked. Returns nil when the cap can be set, else the first reason (channel order,
-- then line order):
--   "CHn uses raw Thr"            a line takes the Thr stick itself (tid or -tid): that
--                                 part does not follow the cap (also a small
--                                 Thr -> elevator mix of a plane);
--   "CHn inverts the Thr input"   a line takes the input inverted (the source -src,
--                                 with any weight) or with a negative weight: there
--                                 stick high is the idle end, and the cap moves it;
--   "CHn mix weight uses GVAR"    a line takes the input with a GVAR weight (the sign
--                                 is not known);
--   "CHn Thr mix has a curve"     a line takes the input with a function or a custom
--                                 curve (a custom curve can invert, |x| folds). Expo
--                                 and differential keep the direction;
--   "Thr input not in mixes"      no line takes the input with a weight above 0.
-- The Lua mix list stops at the first line with the source "---" (srcRaw 0; 2.12.0
-- api_model.cpp getFirstMix and getMixesCountFromFirst, lines 781-806): Lua sees the
-- lines of that channel before it, and every later channel shows no line. The colour
-- mixer skips that line and uses the lines after it (mixer.cpp evalFlightModeMixes:
-- "continue" with COLORLCD). Lua cannot tell these hidden lines from empty channels. A hidden
-- line that takes the input gives "Thr input not in mixes" (a false refusal, accepted);
-- a hidden raw Thr line cannot be seen.
local function mixReason(m, src, tid)
  local used = false
  for ch = 0, MAX_CHANNELS - 1 do
    for k = 0, m.getMixesCount(ch) - 1 do
      local mx = m.getMix(ch, k)
      if mx == nil then return "Mix read failed" end
      local s = mx.source
      if s == tid or s == -tid then return fmt("CH%d uses raw Thr", ch + 1) end
      if s == -src then return fmt("CH%d inverts the Thr input", ch + 1) end
      if s == src then
        local w = mx.weight
        if not plain(w) then return fmt("CH%d mix weight uses GVAR", ch + 1) end
        if w < 0 then return fmt("CH%d inverts the Thr input", ch + 1) end
        -- curveType: 0 differential, 1 expo, 2 function, 3 custom; value 0 = no curve
        local ct = mx.curveType
        if mx.curveValue ~= 0 and ct ~= 0 and ct ~= 1 then
          return fmt("CH%d Thr mix has a curve", ch + 1)
        end
        if w > 0 then used = true end
      end
    end
  end
  if not used then return "Thr input not in mixes" end
  return nil
end

local function setBase(T, state, msg)
  T._base = state
  T._baseMsg = msg
end

-- Finds the throttle input and checks its line and the mix (rules a to d at the top of
-- this file). Read only.
local function scan(T, now)
  T._scanAt = now
  T._dirty = true
  T._line = nil
  T._chn = -1
  T._cap, T._custom, T._w, T._o = 0, false, 0, 0
  local m = model
  if not apiOk(m) then return setBase(T, "none", "No input API") end
  if m.getMixesCount == nil or m.getMix == nil then return setBase(T, "none", "No mix API") end
  local tid = T._tid                   -- the ids do not change: read them once
  if tid == nil then
    tid = fieldId("thr")
    if tid == nil then return setBase(T, "none", "No thr source") end
    T._tid = tid
  end
  local base = T._ibase
  if base == nil then
    base = fieldId("input1")
    if base == nil then return setBase(T, "none", "No input source id") end
    T._ibase = base
  end

  -- a. every input with a line that uses the Thr stick (also inverted): exactly one
  local found, nThr = -1, 0
  for chn = 0, MAX_INPUTS - 1 do
    for i = 0, m.getInputsCount(chn) - 1 do
      local l = m.getInput(chn, i)
      if l ~= nil and (l.source == tid or l.source == -tid) then
        if found < 0 then found = chn end
        nThr = nThr + 1
        break                          -- one count per input
      end
    end
  end
  if found < 0 then return setBase(T, "none", "No throttle input") end
  if nThr > 1 then return setBase(T, "unsupported", fmt("Thr in %d inputs", nThr)) end
  T._chn = found

  -- b. one line, active in every mixer cycle, plain values
  local n = m.getInputsCount(found)
  if n ~= 1 then return setBase(T, "unsupported", fmt("Thr input has %d lines", n)) end
  local l0 = m.getInput(found, 0)
  if l0 == nil then return setBase(T, "none", "No throttle input") end
  if l0.source == -tid then return setBase(T, "unsupported", "Thr source inverted") end
  if l0.source ~= tid or l0.switch ~= 0 or l0.flightModes ~= 0 or l0.side ~= 3 then
    return setBase(T, "unsupported", "Thr input not simple")
  end
  local w, o = l0.weight, l0.offset
  if not plain(w) then return setBase(T, "unsupported", "Weight uses GVAR") end
  if not plain(o) then return setBase(T, "unsupported", "Offset uses GVAR") end
  -- an expo curve keeps the end points; other curves can move stick low
  if l0.curveValue ~= 0 and l0.curveType ~= 1 then
    return setBase(T, "unsupported", "Thr input has a curve")
  end
  if w <= 0 then return setBase(T, "unsupported", "Thr weight 0 or less") end

  -- c. and d. the mix must take the input, and nothing may bypass or invert it
  local why = mixReason(m, base + found, tid)
  if why ~= nil then return setBase(T, "unsupported", why) end

  T._line = l0
  T._w, T._o = w, o
  if w <= 100 and o == w - 100 then
    T._cap = w
    setBase(T, "ok", "Ready")
  else
    T._custom = true
    setBase(T, "ok", "Custom line: tap to replace")
  end
end

local function result(T, state, msg, now)
  T._resState = state
  T._res = msg
  T._resUntil = now + RESULT_TIME
  T._dirty = true
end

-- Copies the internal values to the public fields; rev counts the changes.
local function compose(T)
  T._dirty = false
  local st, msg = T._base, T._baseMsg
  if T.pending ~= nil and st == "ok" then
    st = "busy"
    msg = fmt("Setting %d%%...", T.pending)
  elseif T._res ~= nil then
    st = T._resState
    msg = T._res
  end
  local ch = false
  if T.state ~= st then T.state = st; ch = true end
  if T.msg ~= msg then T.msg = msg; ch = true end
  if T.cap ~= T._cap then T.cap = T._cap; ch = true end
  if T.custom ~= T._custom then T.custom = T._custom; ch = true end
  if T.weight ~= T._w then T.weight = T._w; ch = true end
  if T.offset ~= T._o then T.offset = T._o; ch = true end
  if T.input ~= T._chn then T.input = T._chn; ch = true end
  if T._pend ~= T.pending then T._pend = T.pending; ch = true end
  if ch then T.rev = T.rev + 1 end
end

---------------------------------------------------------------------------
-- The swap. Every model write is in pcall: a failed step must not stop the
-- script before the clean-up.

local function count(m, chn)
  local ok, n = pcall(m.getInputsCount, chn)
  if ok and type(n) == "number" then return n end
  return -1
end

local function getLine(m, chn, i)
  local ok, l = pcall(m.getInput, chn, i)
  if ok and type(l) == "table" then return l end
  return nil
end

local function isOldOrNew(l, old, new)
  return l ~= nil and (same(l, old) or same(l, new))
end

-- After a failed step: back to one line. Line 0 is the live line; when it is the
-- old or the new line, only the dead line 1 is deleted (no output change).
local function cleanup(m, chn, old, new)
  for _ = 1, 2 do
    if count(m, chn) ~= 2 then return end
    if isOldOrNew(getLine(m, chn, 0), old, new) then
      pcall(m.deleteInput, chn, 1)
    elseif isOldOrNew(getLine(m, chn, 1), old, new) then
      pcall(m.deleteInput, chn, 0)
    else
      return
    end
  end
end

-- old = line 0 (one line in the input, checked by scan). Returns true, or false
-- and a message.
local function swap(m, chn, old, cap)
  local new = {}
  for i = 1, NKEYS do
    local k = KEYS[i]
    new[k] = old[k]
  end
  new.weight = cap
  new.offset = cap - 100

  local ok = pcall(m.insertInput, chn, 1, new)
  local n = count(m, chn)
  if n == 1 then
    -- the firmware refuses an insert only when all 64 input lines are used
    if ok then return false, "No free input line (64 used)" end
    return false, "Insert failed"
  end
  if n ~= 2 or not ok then
    cleanup(m, chn, old, new)
    return false, "Insert failed"
  end
  local l0, l1 = getLine(m, chn, 0), getLine(m, chn, 1)
  if l0 == nil or l1 == nil or not same(l0, old) or not same(l1, new) then
    cleanup(m, chn, old, new)
    return false, "Read-back mismatch"
  end

  pcall(m.deleteInput, chn, 0)
  n = count(m, chn)
  if n == 1 then
    l0 = getLine(m, chn, 0)
    if l0 ~= nil and same(l0, new) then return true end
    if l0 ~= nil and same(l0, old) then return false, "Delete failed" end
    return false, "Check failed"
  end
  cleanup(m, chn, old, new)
  return false, "Delete failed"
end

-- The line is not the one that the request was made for (the user changed it, for
-- example in the Inputs editor while the request waited): another input, or a
-- different value in a field of the line (weight, offset, source, switch, curve and
-- the other stored fields). A request made before the first read of the line has no
-- snapshot. Called only when the scan state is "ok" (T._line is set).
local function lineChanged(T)
  local old = T._reqLine
  if old == nil then return false end
  local l = T._line
  return T._chn ~= T._reqChn or l == nil or not same(l, old)
end

local function applyPending(T, now)
  local cap = T.pending
  T.pending = nil
  T._dirty = true
  local n, f = modelId()
  if n ~= T._reqName or f ~= T._reqFile then
    T._mname, T._mfile, T._modelAt = n, f, now
    scan(T, now)
    return result(T, "error", "Model changed: not set", now)
  end
  if now - T.pendAt > MAX_AGE then
    -- refresh() did not run for a long time (another view or a menu was shown)
    return result(T, "error", "Request expired: not set", now)
  end
  scan(T, now)                         -- fresh read just before the write
  if T._base ~= "ok" then return end   -- the reason is the status text
  if lineChanged(T) then return result(T, "error", "Line changed: not set", now) end
  if not T._custom and T._w == cap then
    return result(T, "ok", fmt("Cap is %d%% already", cap), now)
  end
  local ok, err = swap(model, T._chn, T._line, cap)
  scan(T, now)
  if ok then
    result(T, "ok", fmt("Cap set to %d%%", cap), now)
  else
    result(T, "error", err, now)
  end
end

---------------------------------------------------------------------------

function M.new()
  return {
    state = "none", msg = "Reading model", cap = 0, custom = false,
    weight = 0, offset = 0, pending = nil, pendAt = 0, input = -1, rev = 0,
    -- private
    _base = "none", _baseMsg = "Reading model",
    _cap = 0, _custom = false, _w = 0, _o = 0, _chn = -1, _line = nil,
    _pend = nil, _tid = nil,
    _scanAt = nil, _modelAt = nil, _mname = nil, _mfile = nil,
    _reqName = nil, _reqFile = nil, _reqLine = nil, _reqChn = nil, _ibase = nil,
    _res = nil, _resState = "ok", _resUntil = 0,
    _now = 0, _dirty = true,
  }
end

-- now = getTime(); allowWrite = true only from refresh().
function M.tick(T, now, allowWrite)
  T._now = now
  if T._modelAt == nil or now - T._modelAt >= MODEL_TIME then
    T._modelAt = now
    local n, f = modelId()
    if n ~= T._mname or f ~= T._mfile then
      if T._mname == nil then
        -- first read: a request made before it is for this model
        if T.pending ~= nil and T._reqName == nil then T._reqName, T._reqFile = n, f end
      else
        T._res = nil
        if T.pending ~= nil then
          T.pending = nil
          result(T, "error", "Model changed: not set", now)
        end
      end
      T._mname, T._mfile = n, f
      T._scanAt = nil
    end
  end
  local scanned = false
  if T._scanAt == nil or now - T._scanAt >= SCAN_TIME then
    scan(T, now)
    scanned = true
  end
  if T.pending ~= nil then
    if T._base ~= "ok" then
      T.pending = nil                  -- not possible: the status tells why
      T._dirty = true
    elseif scanned and lineChanged(T) then
      -- the line changed while the request waited (also in background): drop it
      T.pending = nil
      result(T, "error", "Line changed: not set", now)
    elseif allowWrite and now - T.pendAt >= DEBOUNCE then
      applyPending(T, now)             -- at most one swap per call
    end
  end
  if T._res ~= nil and now - T._resUntil >= 0 then
    T._res = nil
    T._dirty = true
  end
  if T._dirty then compose(T) end
end

-- Records a cap request (rounded, MIN..MAX) with its time (pendAt) and the line it is
-- for. Called from a button callback: it does not touch the model; tick() applies it.
function M.request(T, cap)
  if type(cap) ~= "number" or cap ~= cap then return end
  local c = floor(cap + 0.5)
  if c < M.MIN then c = M.MIN elseif c > M.MAX then c = M.MAX end
  T.pending = c
  local t = T._now
  if getTime ~= nil then t = getTime() end
  T.pendAt = t
  T._reqName, T._reqFile = T._mname, T._mfile
  -- the line that the request is for (input index and every field of the line, from
  -- the last read): a later change of the line drops the request. scan() makes a new
  -- table for each read, so this snapshot does not change.
  if T._base == "ok" and T._line ~= nil then
    T._reqLine, T._reqChn = T._line, T._chn
  else
    T._reqLine, T._reqChn = nil, nil
  end
  T._dirty = true
  T.rev = T.rev + 1
end

function M.target(T)
  if T.pending ~= nil then return T.pending end
  if T.cap > 0 then return T.cap end
  if T.custom and T.weight > 0 then return T.weight end
  return 0
end

function M.step(T, d)
  local t = M.target(T)
  if t > 0 and type(d) == "number" then M.request(T, t + d) end
end

return M
