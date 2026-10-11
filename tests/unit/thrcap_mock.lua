-- thrcap_mock.lua: emulation of the EdgeTX 2.12 model input API and of the input
-- stage of the mixer, for tests/unit/thrcap_test.lua (desktop Lua 5.5).
--
-- Emulated from the firmware source (v2.12.0-rc1; v2.12.0 has no change in these parts):
--   lua/api_model.cpp      getInputsCount, getInput, insertInput, deleteInput,
--                          getMixesCount, getMix, getInfo (getFirstInput and the
--                          "srcRaw == 0 ends the list" rule included; for the mixes
--                          getFirstMix / getMixesCountFromFirst, 2.12.0 lines 781-806)
--   mixer.cpp evalFlightModeMixes  a mix line with srcRaw 0 (the source "---", which
--                          the colour mix editor offers and the YAML keeps) is skipped
--                          with "continue" on a colour radio (2.12.0 lines 852-857):
--                          the lines after it still work, but Lua does not see them
--                          (M.mixerSources lists what the mixer uses)
--   gui/colorlcd/model/model_inputs.cpp   insertExpo, deleteExpo, getExposCount
--   mixer.cpp              applyExpos (the first active line of an input wins; an
--                          input without an active line keeps its last value),
--                          expo(), applyCurve (DIFF, EXPO), getSourceNumFieldValue
--   datastructs_private.h  ExpoData bit fields, SourceNumVal (Lua value >= 1024 or
--                          <= -1024 = a source such as a GVAR)
--   lua/api_general.cpp    getFieldInfo("thr"), "inputN", "gvarN", defaultChannel
--   input_mapping.cpp      channel order AETR (the user's radio: templateSetup 21)
-- luaL_checkinteger floors a float on the radio (LUA_FLOORN2I); the mock does the
-- same and counts it in M.floatArgs (the widget must pass integers only).
--
-- The mixer task runs at a higher priority than Lua and can run between any two
-- Lua instructions, but not inside insertExpo/deleteExpo (they stop it). The mock
-- runs one "mixer cycle" after EVERY API call, and inside insertInput after
-- insertExpo (the new line still has its default content: the fill window) and
-- after each field store of the copy loop (that loop runs with the mixer on, in
-- lua_next order, which is not specified: the mock shuffles the keys with M.seed).
-- Each cycle evaluates the inputs for five throttle stick positions and appends
-- a record to M.log.

local M = {}

M.MAX_EXPOS = 64
M.MAX_MIXERS = 64
M.MAX_INPUTS = 32
M.LEN_EXPOMIX_NAME = 6
M.LEN_INPUT_NAME = 4

-- MIXSRC numbers of a colour radio with 9 Lua scripts x 6 outputs:
-- inputs 1..32, Lua outputs 33..86, sticks from 87 (Rud, Ele, Thr, Ail).
M.FIRST_INPUT = 1
M.FIRST_STICK = 87
M.RUD, M.ELE, M.THR, M.AIL = 87, 88, 89, 90
M.POT1 = 91
M.SA = 120                 -- a switch source (only for mixes)
M.SB, M.SC, M.SD, M.SE, M.SF = 121, 122, 123, 124, 125   -- more switches (mixes only)
M.TILT_X, M.TILT_Y = 126, 127                             -- gyro sources (mixes only)
M.FIRST_GVAR = 300         -- illustrative: any value that fits the 10-bit field
M.MAX_GVARS = 9

-- channel i -> stick (0 Rud, 1 Ele, 2 Thr, 3 Ail); AETR
M.chOrder = { [0] = 3, [1] = 1, [2] = 2, [3] = 0 }

M.STICK_POS = { -1024, -512, 0, 512, 1024 }   -- throttle -100, -50, 0, +50, +100 %
M.OTHER = { [M.RUD] = 100, [M.ELE] = -300, [M.AIL] = 700, [M.POT1] = 200 }

---------------------------------------------------------------- integer helpers

-- C integer division (truncates toward zero)
local function cdiv(a, b)
  local q = a // b
  if q < 0 and q * b ~= a then q = q + 1 end
  return q
end
M.cdiv = cdiv

local function divRoundClosest(n, d)
  if d == 0 then return 0 end
  if (n < 0) ~= (d < 0) then return cdiv(n - cdiv(d, 2), d) end
  return cdiv(n + cdiv(d, 2), d)
end
M.divRoundClosest = divRoundClosest

local function ubits(v, n) return v & ((1 << n) - 1) end
local function sbits(v, n)
  local m = 1 << n
  v = v & (m - 1)
  if v >= (m >> 1) then v = v - m end
  return v
end
local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- luaIntToSourceNumval / sourceNumValToLuaInt (11-bit raw value)
local function toSNV(val)
  local isSrc, value = 0, val
  if val >= 1024 then isSrc, value = 1, val - 1024
  elseif val <= -1024 then isSrc, value = 1, val + 1024 end
  return ubits(sbits(value, 10), 10) | (isSrc << 10)
end
local function fromSNV(raw)
  local value = sbits(raw & 0x3FF, 10)
  if (raw >> 10) & 1 == 1 then
    if value < 0 then return value - 1024 end
    return value + 1024
  end
  return value
end
M.toSNV, M.fromSNV = toSNV, fromSNV

---------------------------------------------------------------- state

local function emptyExpo()
  return { mode = 0, scale = 0, trimSource = 0, srcRaw = 0, weight = 0, offset = 0,
           swtch = 0, ctype = 0, cvalue = 0, chn = 0, flightModes = 0, name = "" }
end
local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end
local function emptyMix()
  return { destCh = 0, srcRaw = 0, weight = 0, offset = 0, swtch = 0, ctype = 0, cvalue = 0,
           mltpx = 0, flightModes = 0, carryTrim = false, mixWarn = 0, delayPrec = 0,
           delayUp = 0, delayDown = 0, speedPrec = 0, speedUp = 0, speedDown = 0, name = "" }
end

function M.reset()
  M.expo = {}
  for i = 0, M.MAX_EXPOS - 1 do M.expo[i] = emptyExpo() end
  M.mix = {}
  for i = 0, M.MAX_MIXERS - 1 do M.mix[i] = emptyMix() end
  M.inputNames = {}
  for i = 0, M.MAX_INPUTS - 1 do M.inputNames[i] = "" end
  M.info = { name = "", filename = "model1.yml" }
  M.gvars = {}
  for i = 0, M.MAX_GVARS - 1 do M.gvars[i] = 0 end
  M.switchOn = {}
  M.fm = 0
  M.time = 1000
  M.noThr = false
  M.floatArgs = 0
  M.calls = {}          -- names of the API calls, in order
  M.writes = 0          -- insertInput + deleteInput calls
  M.inApi = false
  M.inj = {}            -- failure injection (see insertInput, deleteInput)
  M.seed = 1
  M.watch = 2           -- the throttle input whose value is recorded
  M.anas = {}
  for p = 1, #M.STICK_POS do M.anas[p] = {} end
  M.log = {}
end

---------------------------------------------------------------- mixer (applyExpos)

local function getSwitch(sw)
  if sw == 0 then return true end
  local on = M.switchOn[sw < 0 and -sw or sw] == true
  if sw < 0 then return not on end
  return on
end

local function srcValue(src, p)
  if src < 0 then return -srcValue(-src, p) end
  if src == M.THR then return M.STICK_POS[p] end
  if src >= M.FIRST_GVAR and src < M.FIRST_GVAR + M.MAX_GVARS then
    return M.gvars[src - M.FIRST_GVAR]
  end
  return M.OTHER[src] or 0
end

-- getSourceNumFieldValue(val, min, max): result in 1/10 percent
local function sourceNumField(raw, lo, hi, p)
  local value = sbits(raw & 0x3FF, 10)
  local result
  if (raw >> 10) & 1 == 1 then
    local a = value < 0 and -value or value
    if a >= M.FIRST_GVAR and value < M.FIRST_GVAR + M.MAX_GVARS then
      result = srcValue(value, p) * 10            -- GVAR with precision 0
    else
      result = divRoundClosest(srcValue(value, p) * 1000, 1024)
    end
  else
    result = value * 10
  end
  return clamp(result, lo * 10, hi * 10)
end

local function expou(x, k)
  k = divRoundClosest(k * 256, 100)
  local value = x * x
  value = value * k
  value = value >> 8
  value = value * x
  value = value >> 12
  value = value + (256 - k) * x + 128
  return value >> 8
end

local function expo(x, k)
  if k == 0 then return x end
  local neg = x < 0
  if neg then x = -x end
  if x > 1024 then x = 1024 end
  local y
  if k < 0 then y = 1024 - expou(1024 - x, -k) else y = expou(x, k) end
  if neg then return -y end
  return y
end
M.expoFn = expo

local function applyCurve(x, ctype, craw, p)
  if ctype == 0 then                              -- DIFF
    local cp = sourceNumField(craw, -100, 100, p)
    if cp > 0 and x < 0 then return cdiv(x * (1000 - cp), 1000) end
    if cp < 0 and x > 0 then return cdiv(x * (1000 + cp), 1000) end
    return x
  elseif ctype == 1 then                          -- EXPO
    return expo(x, cdiv(sourceNumField(craw, -100, 100, p), 10))
  end
  return x   -- FUNC and CUSTOM curves are not emulated (layouts with them are refused)
end

-- One line evaluated with the stick position p; nil = the line is not active,
-- false = active line whose side does not match (anas = 0, a later line may win).
local function lineValue(ed, p)
  if (ed.flightModes >> M.fm) & 1 == 1 then return nil end
  if not getSwitch(ed.swtch) then return nil end
  local v = clamp(srcValue(ed.srcRaw, p), -1024, 1024)
  if not ((v < 0 and ed.mode & 1 ~= 0) or (v >= 0 and ed.mode & 2 ~= 0)) then return false end
  if ed.cvalue ~= 0 then v = applyCurve(v, ed.ctype, ed.cvalue, p) end
  local w = sourceNumField(ed.weight, -100, 100, p)
  v = divRoundClosest(v * w, 1000)
  local o = sourceNumField(ed.offset, -100, 100, p)
  if o ~= 0 then v = v + divRoundClosest(divRoundClosest(o * 1024, 100), 10) end
  return v
end

local function applyExpos(anas, p)
  local cur = -1
  for i = 0, M.MAX_EXPOS - 1 do
    local ed = M.expo[i]
    if ed.mode == 0 then break end                -- end of list (EXPO_VALID)
    if ed.chn ~= cur then
      local v = lineValue(ed, p)
      if v == false then
        anas[ed.chn] = 0
      elseif v ~= nil then
        cur = ed.chn
        anas[cur] = v
      end
    end
  end
end

-- One mixer cycle: evaluates all stick positions and records the input values.
function M.cycle(at)
  local rec = { at = at, thr = {}, all = {} }
  for p = 1, #M.STICK_POS do
    local anas = M.anas[p]
    applyExpos(anas, p)
    rec.thr[p] = anas[M.watch]
    local a = {}
    for c = 0, 7 do a[c] = anas[c] end
    rec.all[p] = a
  end
  M.log[#M.log + 1] = rec
  return rec
end

---------------------------------------------------------------- line fields

local function checkint(v)
  local t = math.type(v)
  if t == "integer" then return v end
  if t == "float" then
    M.floatArgs = M.floatArgs + 1
    return math.floor(v)                          -- LUA_FLOORN2I on the radio
  end
  if type(v) == "string" and tonumber(v) ~= nil then return checkint(tonumber(v)) end
  error("bad argument (number expected, got " .. type(v) .. ")", 0)
end
local function checkstring(v)
  if type(v) == "string" then return v end
  if type(v) == "number" then return tostring(v) end
  error("bad argument (string expected, got " .. type(v) .. ")", 0)
end
local function unsigned(v)
  if v < 0 then return v + 4294967296 end        -- C "unsigned int" of a negative value
  return v
end

-- One key of the insertInput loop (api_model.cpp luaModelInsertInput)
local function setField(ed, chn, key, v)
  if key == "name" then ed.name = string.sub(checkstring(v), 1, M.LEN_EXPOMIX_NAME)
  elseif key == "inputName" then M.inputNames[chn] = string.sub(checkstring(v), 1, M.LEN_INPUT_NAME)
  elseif key == "source" then ed.srcRaw = sbits(checkint(v), 10)
  elseif key == "scale" then ed.scale = ubits(checkint(v), 14)
  elseif key == "side" then ed.mode = ubits(checkint(v), 2)
  elseif key == "weight" then ed.weight = toSNV(checkint(v))
  elseif key == "offset" then ed.offset = toSNV(checkint(v))
  elseif key == "switch" then ed.swtch = sbits(checkint(v), 10)
  elseif key == "curveType" then ed.ctype = ubits(checkint(v), 5)
  elseif key == "curveValue" then ed.cvalue = toSNV(checkint(v))
  elseif key == "trimSource" then ed.trimSource = sbits(-checkint(v), 6)
  elseif key == "flightModes" then ed.flightModes = ubits(checkint(v), 9)
  end
end

-- getInput table of one stored line
local function lineTable(ed, chn)
  return {
    name = ed.name, inputName = M.inputNames[chn], source = ed.srcRaw, scale = ed.scale,
    weight = fromSNV(ed.weight), offset = fromSNV(ed.offset), switch = ed.swtch,
    curveType = ed.ctype, curveValue = fromSNV(ed.cvalue), trimSource = -ed.trimSource,
    side = ed.mode, flightModes = ed.flightModes,
  }
end

---------------------------------------------------------------- firmware helpers

local function getFirstInput(chn)
  for i = 0, M.MAX_EXPOS - 1 do
    local e = M.expo[i]
    if e.srcRaw == 0 or e.chn >= chn then return i end
  end
  return 0
end
local function countFrom(chn, first)
  local n = 0
  for i = first, M.MAX_EXPOS - 1 do
    local e = M.expo[i]
    if e.srcRaw == 0 or e.chn ~= chn then break end
    n = n + 1
  end
  return n
end
local function getExposCount()
  local n = 0
  for i = M.MAX_EXPOS - 1, 0, -1 do
    if M.expo[i].mode ~= 0 then n = n + 1 end
  end
  return n
end
local function isInputAvailable(input)
  for i = 0, M.MAX_EXPOS - 1 do
    local e = M.expo[i]
    if e.mode == 0 then break end
    if e.chn == input then return true end
  end
  return false
end

-- model_inputs.cpp insertExpo: under mixerTaskStop (no cycle inside)
local function insertExpo(idx, input)
  for j = M.MAX_EXPOS - 1, idx + 1, -1 do M.expo[j] = M.expo[j - 1] end
  local ed = emptyExpo()
  if input >= 4 then
    ed.srcRaw = sbits(M.FIRST_STICK + input, 10)
  else
    ed.srcRaw = M.FIRST_STICK + M.chOrder[input]
  end
  ed.ctype = 1
  ed.mode = 3
  ed.chn = input
  ed.weight = 100
  M.expo[idx] = ed
end

-- model_inputs.cpp deleteExpo: under mixerTaskStop
local function deleteExpo(idx)
  local input = M.expo[idx].chn
  for j = idx, M.MAX_EXPOS - 2 do M.expo[j] = M.expo[j + 1] end
  M.expo[M.MAX_EXPOS - 1] = emptyExpo()
  if not isInputAvailable(input) then M.inputNames[input] = "" end
end

local function rng()
  M.seed = (M.seed * 1103515245 + 12345) % 2147483648
  return M.seed
end

---------------------------------------------------------------- Lua API

local function api(name, f)
  return function(...)
    local was = M.inApi
    M.inApi = true
    M.calls[#M.calls + 1] = name
    local ok, r = pcall(f, ...)
    M.cycle(name)                                 -- the mixer after every API call
    M.inApi = was
    if not ok then error(r, 0) end
    return r
  end
end

local function getInputsCount(chn)
  chn = unsigned(checkint(chn))
  return countFrom(chn, getFirstInput(chn))
end

local function getInput(chn, idx)
  chn = unsigned(checkint(chn))
  idx = unsigned(checkint(idx))
  local first = getFirstInput(chn)
  if idx < countFrom(chn, first) then return lineTable(M.expo[first + idx], chn) end
  return nil
end

local function insertInput(chn, idx, tbl)
  chn = unsigned(checkint(chn))
  idx = unsigned(checkint(idx))
  M.writes = M.writes + 1
  local first = getFirstInput(chn)
  local count = countFrom(chn, first)
  if M.inj.insertNoop then return end
  if chn < M.MAX_INPUTS and getExposCount() < M.MAX_EXPOS and idx <= count then
    idx = first + idx
    insertExpo(idx, chn)
    M.cycle("insertInput:fill")                   -- the new line has default content
    local ed = M.expo[idx]
    if type(tbl) ~= "table" then error("bad argument #3 (table expected)", 0) end
    local keys = {}
    for k in pairs(tbl) do
      if type(k) ~= "string" then error("bad argument (string key expected)", 0) end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for i = #keys, 2, -1 do                       -- lua_next order is not specified
      local j = rng() % i + 1
      keys[i], keys[j] = keys[j], keys[i]
    end
    for n = 1, #keys do
      if M.inj.insertError ~= nil and n > M.inj.insertError then
        error("injected error in the field loop", 0)
      end
      setField(ed, chn, keys[n], tbl[keys[n]])
      M.cycle("insertInput:" .. keys[n])          -- the mixer runs during the loop
    end
    if M.inj.insertError ~= nil and #keys <= M.inj.insertError then
      error("injected error after the field loop", 0)
    end
    if M.inj.insertCorrupt ~= nil then
      ed[M.inj.insertCorrupt] = ed[M.inj.insertCorrupt] + 1
    end
  end
end

local function deleteInput(chn, idx)
  chn = unsigned(checkint(chn))
  idx = unsigned(checkint(idx))
  M.writes = M.writes + 1
  local inj = M.inj
  if inj.deleteError ~= nil and inj.deleteError > 0 then
    inj.deleteError = inj.deleteError - 1
    error("injected error in deleteInput", 0)
  end
  if inj.deleteNoop ~= nil and inj.deleteNoop > 0 then
    inj.deleteNoop = inj.deleteNoop - 1
    return
  end
  local first = getFirstInput(chn)
  local count = countFrom(chn, first)
  if inj.deleteWrong and idx + 1 < count then idx = idx + 1 end
  if idx < count then deleteExpo(first + idx) end
end

-- getFirstMix and getMixesCountFromFirst stop at the first line with srcRaw 0, also
-- when lines follow it: then no channel at or after that line has a line for Lua.
local function getFirstMix(ch)
  for i = 0, M.MAX_MIXERS - 1 do
    local m = M.mix[i]
    if m.srcRaw == 0 or m.destCh >= ch then return i end
  end
  return 0
end
local function mixCountFrom(ch, first)
  local n = 0
  for i = first, M.MAX_MIXERS - 1 do
    local m = M.mix[i]
    if m.srcRaw == 0 or m.destCh ~= ch then break end
    n = n + 1
  end
  return n
end

local function getMixesCount(ch)
  ch = unsigned(checkint(ch))
  return mixCountFrom(ch, getFirstMix(ch))
end

local function getMix(ch, idx)
  ch = unsigned(checkint(ch))
  idx = unsigned(checkint(idx))
  local first = getFirstMix(ch)
  if idx < mixCountFrom(ch, first) then
    local m = M.mix[first + idx]
    return { name = m.name, source = m.srcRaw, weight = fromSNV(m.weight), offset = fromSNV(m.offset),
             switch = m.swtch, curveType = m.ctype, curveValue = fromSNV(m.cvalue),
             multiplex = m.mltpx, flightModes = m.flightModes, carryTrim = m.carryTrim,
             mixWarn = m.mixWarn, delayPrec = m.delayPrec, delayUp = m.delayUp,
             delayDown = m.delayDown, speedPrec = m.speedPrec, speedUp = m.speedUp,
             speedDown = m.speedDown }
  end
  return nil
end

local function getInfo()
  return { name = M.info.name, extendedLimits = false, jitterFilter = 0, bitmap = "",
           labels = "", filename = M.info.filename }
end

local function getFieldInfo(name)
  if type(name) ~= "string" then return nil end
  local id
  if name == "rud" then id = M.RUD
  elseif name == "ele" then id = M.ELE
  elseif name == "thr" then if not M.noThr then id = M.THR end
  elseif name == "ail" then id = M.AIL
  else
    local n = tonumber(string.match(name, "^input(%d%d?)$"))
    if n ~= nil and n >= 1 and n <= M.MAX_INPUTS then id = M.FIRST_INPUT + n - 1 end
    n = tonumber(string.match(name, "^gvar(%d)$"))
    if n ~= nil and n >= 1 and n <= M.MAX_GVARS then id = M.FIRST_GVAR + n - 1 end
  end
  if id == nil then return nil end
  return { id = id, name = name, desc = "" }
end

local function defaultChannel(stick)
  stick = checkint(stick)
  for i = 0, 3 do
    if M.chOrder[i] == stick then return i end
  end
  return nil
end

-- Installs the globals model, getFieldInfo, getTime, defaultChannel.
function M.install()
  M.model = {
    getInputsCount = api("getInputsCount", getInputsCount),
    getInput = api("getInput", getInput),
    insertInput = api("insertInput", insertInput),
    deleteInput = api("deleteInput", deleteInput),
    getMixesCount = api("getMixesCount", getMixesCount),
    getMix = api("getMix", getMix),
    getInfo = api("getInfo", getInfo),
  }
  _G.model = M.model
  _G.getFieldInfo = api("getFieldInfo", getFieldInfo)
  _G.getTime = function() return M.time end
  _G.defaultChannel = api("defaultChannel", defaultChannel)
end

---------------------------------------------------------------- model building

-- A line with the user's defaults (one plain line: side 3, no switch, expo 0).
function M.line(t)
  local l = { name = "", source = M.THR, scale = 0, weight = 100, offset = 0, switch = 0,
              curveType = 1, curveValue = 0, trimSource = 0, side = 3, flightModes = 0 }
  for k, v in pairs(t or {}) do l[k] = v end
  return l
end

-- spec = { name, filename, expos = { {chn = n, <getInput keys>}, ... } (array order),
--          inputNames = { [chn] = "Thr" },
--          mixes = { {destCh, source, weight, offset, curveType, curveValue}, ... } }
function M.load(spec)
  local keep = { time = M.time, seed = M.seed, watch = M.watch }
  M.reset()
  M.time, M.seed, M.watch = keep.time, keep.seed, keep.watch
  M.info = { name = spec.name or "", filename = spec.filename or "model1.yml" }
  for i, l in ipairs(spec.expos or {}) do
    local ed = emptyExpo()
    ed.chn = l.chn
    for k, v in pairs(M.line(l)) do
      if k ~= "chn" then setField(ed, l.chn, k, v) end
    end
    M.expo[i - 1] = ed
  end
  for chn, n in pairs(spec.inputNames or {}) do M.inputNames[chn] = n end
  for i, m in ipairs(spec.mixes or {}) do
    local x = emptyMix()
    x.destCh, x.srcRaw = m.destCh, m.source
    x.weight, x.offset = toSNV(m.weight or 100), toSNV(m.offset or 0)
    x.ctype, x.cvalue = m.curveType or 0, toSNV(m.curveValue or 0)
    M.mix[i - 1] = x
  end
  for k, v in pairs(spec.gvars or {}) do M.gvars[k] = v end
  M.cycle("load")                                 -- the mixer has run before
  M.log = {}
  M.calls = {}
  M.writes = 0
  M.floatArgs = 0
end

-- The user's models (radio sd card/MODELS/model1..4.yml): inputs Rud, Ele, Thr,
-- Ail on I1..I4 (chn 0..3), mixes CH1 = I4, CH2 = I2, CH3 = I3, CH4 = I1.
function M.userSpec(name, filename, w, o)
  return {
    name = name, filename = filename,
    expos = {
      { chn = 0, source = M.RUD },
      { chn = 1, source = M.ELE },
      { chn = 2, source = M.THR, weight = w, offset = o },
      { chn = 3, source = M.AIL },
    },
    inputNames = { [0] = "Rud", [1] = "Ele", [2] = "Thr", [3] = "Ail" },
    mixes = {
      { destCh = 0, source = M.FIRST_INPUT + 3 },
      { destCh = 1, source = M.FIRST_INPUT + 1 },
      { destCh = 2, source = M.FIRST_INPUT + 2 },
      { destCh = 3, source = M.FIRST_INPUT + 0 },
      { destCh = 4, source = M.SA, weight = -100 },
    },
  }
end

-- The whole mix list of the user's models (mixData of radio sd card/MODELS/model1..4.yml):
-- CH1 = I4, CH2 = I2, CH3 = I3, CH4 = I1, CH5 = SE -100 %, CH6..CH10 = SA SB SC SD SF,
-- CH11 = P1, CH12 = SF; model1, model3 and model4 also have CH15 = TILT_X, CH16 = TILT_Y.
function M.userMixes(tilt)
  local I = M.FIRST_INPUT
  local l = {
    { destCh = 0, source = I + 3 }, { destCh = 1, source = I + 1 },
    { destCh = 2, source = I + 2 }, { destCh = 3, source = I + 0 },
    { destCh = 4, source = M.SE, weight = -100 }, { destCh = 5, source = M.SA },
    { destCh = 6, source = M.SB }, { destCh = 7, source = M.SC }, { destCh = 8, source = M.SD },
    { destCh = 9, source = M.SF }, { destCh = 10, source = M.POT1 }, { destCh = 11, source = M.SF },
  }
  if tilt then
    l[#l + 1] = { destCh = 14, source = M.TILT_X }
    l[#l + 1] = { destCh = 15, source = M.TILT_Y }
  end
  return l
end

---------------------------------------------------------------- inspection

-- Sources of the mix lines of channel ch that the colour mixer uses (evalFlightModeMixes looks
-- at all MAX_MIXERS slots: a line with srcRaw 0 is skipped and the lines after it are
-- used; an empty slot has srcRaw 0 too). No API call, no mixer cycle.
function M.mixerSources(ch)
  local r = {}
  for i = 0, M.MAX_MIXERS - 1 do
    local m = M.mix[i]
    if m.srcRaw ~= 0 and m.destCh == ch then r[#r + 1] = m.srcRaw end
  end
  return r
end

-- Lines of one input as getInput tables (no API call, no mixer cycle).
function M.lines(chn)
  local r = {}
  local first = getFirstInput(chn)
  for i = 0, countFrom(chn, first) - 1 do r[#r + 1] = lineTable(M.expo[first + i], chn) end
  return r
end

-- Value of one line (getInput keys) for the stick position p, with the mixer code.
function M.lineOut(t, p)
  local ed = emptyExpo()
  for k, v in pairs(M.line(t)) do
    if k ~= "inputName" then setField(ed, 0, k, v) end   -- no change of the model
  end
  local v = lineValue(ed, p)
  if v == false then return 0 end
  return v
end

-- Snapshot of the whole expo table (for "nothing else changed" checks).
function M.snapshot()
  local s = {}
  for i = 0, M.MAX_EXPOS - 1 do s[i] = copy(M.expo[i]) end
  local n = {}
  for i = 0, M.MAX_INPUTS - 1 do n[i] = M.inputNames[i] end
  return { expo = s, names = n }
end

M.reset()
return M
