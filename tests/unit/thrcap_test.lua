-- thrcap_test.lua: unit tests for lib/thrcap.lua (throttle cap) with the firmware
-- emulation in thrcap_mock.lua (input API + mixer input stage).
-- Run: cd "<root>" && lua tests/unit/thrcap_test.lua
--
-- The main check: for the stick positions -100, -50, 0, +50 and +100 %, the
-- throttle input value of EVERY emulated mixer cycle (after each API call, in the
-- insertInput fill window and after each field store) is the output of the old
-- line or of the new line, never another value; the other inputs never change.

local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
local mock = dofile(here .. "/thrcap_mock.lua")
local ROOT = string.match(here, "^(.*)/tests/unit$") or (here .. "/../..")
local WIDGET = ROOT .. "/radio sd card/WIDGETS/FPVDASH/"

mock.install()
local thrcap = dofile(WIDGET .. "lib/thrcap.lua")

---------------------------------------------------------------- tiny test kit

local pass, fail = 0, 0
local function check(cond, msg)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. msg)
  end
end
local function eq(a, b, msg)
  check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

local KEYS = { "name", "source", "scale", "weight", "offset", "switch",
               "curveType", "curveValue", "trimSource", "side", "flightModes" }

local function sameLine(a, b)
  if a == nil or b == nil then return false end
  for _, k in ipairs(KEYS) do
    if a[k] ~= b[k] then return false end
  end
  return true
end

local function withCap(l, cap)
  local c = {}
  for _, k in ipairs(KEYS) do c[k] = l[k] end
  c.weight, c.offset = cap, cap - 100
  return c
end

local STATES = { ok = true, none = true, unsupported = true, busy = true, error = true }

-- The public fields must always have their documented types.
local function fieldsOk(T, label)
  check(STATES[T.state] == true, label .. ": state " .. tostring(T.state))
  check(type(T.msg) == "string" and #T.msg <= 30, label .. ": msg <= 30 chars: " .. tostring(T.msg))
  check(math.type(T.cap) == "integer" and T.cap >= 0 and T.cap <= 100, label .. ": cap int 0..100")
  check(type(T.custom) == "boolean", label .. ": custom boolean")
  check(math.type(T.weight) == "integer" and math.type(T.offset) == "integer", label .. ": weight/offset int")
  check(T.pending == nil or math.type(T.pending) == "integer", label .. ": pending nil or int")
  check(math.type(T.input) == "integer" and T.input >= -1 and T.input < 32, label .. ": input")
  check(math.type(T.rev) == "integer", label .. ": rev int")
  check(type(T.pendAt) == "number", label .. ": pendAt number")
end

local function countCalls(name, from)
  local n = 0
  for i = from or 1, #mock.calls do
    if mock.calls[i] == name then n = n + 1 end
  end
  return n
end

-- One tick dt (10 ms units) later. At most one insertInput per tick.
local function tick(T, dt, write, label)
  mock.time = mock.time + dt
  local c0 = #mock.calls + 1
  thrcap.tick(T, mock.time, write)
  check(countCalls("insertInput", c0) <= 1, (label or "tick") .. ": at most one insert per tick")
  if not write then
    eq(countCalls("insertInput", c0) + countCalls("deleteInput", c0), 0,
       (label or "tick") .. ": no write without allowWrite")
  end
  fieldsOk(T, label or "tick")
end

-- Starts recording: clears the mixer log and returns the current cycle (the base).
local function startWatch()
  mock.log = {}
  return mock.cycle("start")
end

-- Every recorded cycle: throttle = old or new output, other inputs = base.
-- Returns the number of bad values (printed only when 'quiet' is not set).
local function checkLog(label, base, oldL, newL, quiet)
  local old, new = {}, {}
  for p = 1, #mock.STICK_POS do
    old[p] = mock.lineOut(oldL, p)
    new[p] = mock.lineOut(newL, p)
  end
  local bad, fills = 0, 0
  for _, rec in ipairs(mock.log) do
    if rec.at == "insertInput:fill" then fills = fills + 1 end
    for p = 1, #mock.STICK_POS do
      local v = rec.thr[p]
      if v ~= old[p] and v ~= new[p] then
        bad = bad + 1
        if bad == 1 and not quiet then
          print(string.format("  %s: cycle '%s' stick %d: throttle %s (old %d, new %d)",
            label, rec.at, mock.STICK_POS[p], tostring(v), old[p], new[p]))
        end
      end
      for c = 0, 7 do
        if c ~= mock.watch and rec.all[p][c] ~= base.all[p][c] then
          bad = bad + 1
          if bad == 1 and not quiet then
            print(string.format("  %s: cycle '%s': input %d changed", label, rec.at, c))
          end
        end
      end
    end
  end
  if not quiet then
    check(bad == 0, label .. ": every mixer cycle sees the old or the new throttle ("
      .. #mock.log .. " cycles, " .. fills .. " fill windows)")
  end
  return bad, fills, old, new
end

-- The live line of the throttle input after any result: one line, or two lines
-- where line 0 is the old or new line and always active (line 1 is then dead).
local function safeLayout(label, chn, oldL, newL)
  local ls = mock.lines(chn)
  check(#ls >= 1, label .. ": the throttle input still has a line")
  check(#ls <= 2, label .. ": at most two lines")
  local l0 = ls[1]
  check(sameLine(l0, oldL) or sameLine(l0, newL), label .. ": line 0 is the old or the new line")
  if l0 ~= nil then
    check(l0.switch == 0 and l0.flightModes == 0 and l0.side == 3, label .. ": line 0 is always active")
  end
  return ls
end

-- Compares the whole expo table with a snapshot, except the throttle line slot.
local function othersUnchanged(label, snap, skip)
  local now = mock.snapshot()
  local diff = 0
  for i = 0, mock.MAX_EXPOS - 1 do
    if i ~= skip then
      for k, v in pairs(snap.expo[i]) do
        if now.expo[i][k] ~= v then
          diff = diff + 1
          print(string.format("  %s: line slot %d field %s: %s -> %s", label, i, k,
            tostring(v), tostring(now.expo[i][k])))
        end
      end
    end
  end
  for i = 0, mock.MAX_INPUTS - 1 do
    if now.names[i] ~= snap.names[i] then
      diff = diff + 1
      print(string.format("  %s: input name %d: %s -> %s", label, i, snap.names[i], now.names[i]))
    end
  end
  eq(diff, 0, label .. ": other lines and input names unchanged")
end

-- New thrcap state on the loaded model after the first tick.
local function fresh(label)
  local T = thrcap.new()
  fieldsOk(T, (label or "new") .. " before the first tick")
  tick(T, 1, true, label)
  return T
end

-- Requests cap and runs ticks until the debounce has elapsed (one write tick).
local function requestAndApply(T, cap, label)
  local w0 = mock.writes
  thrcap.request(T, cap)
  tick(T, 20, true, label)
  eq(mock.writes, w0, label .. ": no write before the debounce time")
  tick(T, 25, true, label)
end

---------------------------------------------------------------- mixer emulation sanity

do
  local want = {
    { 75, -25, { -1024, -640, -256, 128, 512 } },
    { 50, -50, { -1024, -768, -512, -256, 0 } },
    { 100, 0, { -1024, -512, 0, 512, 1024 } },
    { 60, -40, { -1024, -717, -410, -103, 204 } },
  }
  for _, w in ipairs(want) do
    for p = 1, 5 do
      eq(mock.lineOut({ weight = w[1], offset = w[2] }, p), w[3][p],
         string.format("mixer %d/%d at stick %d", w[1], w[2], mock.STICK_POS[p]))
    end
  end
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local rec = mock.cycle("sanity")
  eq(rec.thr[5], 512, "mixer: model 75 full stick = 512 (75 % throttle)")
  eq(rec.thr[1], -1024, "mixer: model 75 low stick = -1024")
  eq(rec.all[1][3], 700, "mixer: Ail input = Ail stick")
  eq(mock.SA ~= nil, true, "mock constants")
  -- SourceNumVal round trip
  for _, v in ipairs({ 0, 1, -1, 100, -100, 511, -512, 1024, 1324, -1324 }) do
    eq(mock.fromSNV(mock.toSNV(v)), v, "SourceNumVal round trip " .. v)
  end
end

---------------------------------------------------------------- the user's four models

-- name, file, weight, offset, gyro mix lines (CH15/CH16): the input and mix lines of
-- radio sd card/MODELS/model1..4.yml. All four pass every rule of the cap.
local USER = {
  { "75", "model1.yml", 75, -25, true },
  { "sim", "model2.yml", 50, -50, false },
  { "100% pro", "model3.yml", 100, 0, true },
  { "100% pro gemini", "model4.yml", 100, 0, true },
}

for _, u in ipairs(USER) do
  local label = "model '" .. u[1] .. "'"
  local spec = mock.userSpec(u[1], u[2], u[3], u[4])
  spec.mixes = mock.userMixes(u[5])
  mock.load(spec)
  local T = fresh(label)
  eq(T.state, "ok", label .. ": state")
  eq(T.cap, u[3], label .. ": cap")
  eq(T.custom, false, label .. ": not custom")
  eq(T.weight, u[3], label .. ": weight")
  eq(T.offset, u[4], label .. ": offset")
  eq(T.input, 2, label .. ": input I3 (chn 2)")
  eq(T.msg, "Ready", label .. ": msg")
  eq(mock.writes, 0, label .. ": reading does not write")

  for _, cap in ipairs({ 60, 100, 20, 85, 75 }) do
    local l = label .. " -> " .. cap
    local oldL = mock.lines(2)[1]
    local newL = withCap(oldL, cap)
    local snap = mock.snapshot()
    local base = startWatch()
    mock.writes = 0
    requestAndApply(T, cap, l)
    if oldL.weight == cap then
      eq(mock.writes, 0, l .. ": same cap: no write")
      eq(T.msg, string.format("Cap is %d%% already", cap), l .. ": msg")
    else
      eq(mock.writes, 2, l .. ": one insert and one delete")
      local _, fills = checkLog(l, base, oldL, newL)
      eq(fills, 1, l .. ": the fill window was evaluated")
      eq(T.msg, string.format("Cap set to %d%%", cap), l .. ": msg")
    end
    local ls = mock.lines(2)
    eq(#ls, 1, l .. ": one line")
    check(sameLine(ls[1], newL), l .. ": line = old line with the new weight and offset")
    eq(ls[1].inputName, "Thr", l .. ": input name kept")
    othersUnchanged(l, snap, 2)
    local last = mock.cycle("after")
    eq(last.thr[5], mock.lineOut(newL, 5), l .. ": full stick gives the new cap")
    eq(last.thr[1], -1024, l .. ": low stick gives -100 %")
    eq(T.state, "ok", l .. ": state")
    eq(T.cap, cap, l .. ": cap read back")
    eq(T.weight, cap, l .. ": weight")
    eq(T.offset, cap - 100, l .. ": offset")
    eq(T.pending, nil, l .. ": no pending")
    eq(mock.floatArgs, 0, l .. ": integer arguments only")
    tick(T, 410, true, l)
    eq(T.msg, "Ready", l .. ": status after the result time")
  end
end

---------------------------------------------------------------- field order of the copy loop

-- lua_next order is not specified: try many orders. Method C never shows a new
-- field to the mixer, whatever the order.
for seed = 1, 40 do
  mock.seed = seed
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh("seed")
  local oldL = mock.lines(2)[1]
  local base = startWatch()
  requestAndApply(T, 50 + (seed % 10) * 5, "seed " .. seed)
  local bad = checkLog("seed " .. seed, base, oldL, withCap(oldL, 50 + (seed % 10) * 5), true)
  check(bad == 0, "seed " .. seed .. ": no glitch")
end

---------------------------------------------------------------- negative controls

-- The check above must be able to see a glitch: the unsafe orders do show one.
do
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local oldL = mock.lines(2)[1]
  local newL = withCap(oldL, 60)
  local base = startWatch()
  model.insertInput(2, 0, newL)       -- method B: new line BEFORE the live line
  model.deleteInput(2, 1)
  local bad = checkLog("control B", base, oldL, newL, true)
  check(bad > 0, "control: inserting before the live line shows a glitch (" .. bad .. " bad values)")

  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  base = startWatch()
  model.deleteInput(2, 0)             -- method A: delete, then insert
  model.insertInput(2, 0, newL)
  bad = checkLog("control A", base, oldL, newL, true)
  check(bad > 0, "control: delete then insert shows a glitch (" .. bad .. " bad values)")
end

---------------------------------------------------------------- custom 80 / -10

do
  local label = "custom 80/-10"
  mock.load(mock.userSpec("custom", "model5.yml", 80, -10))
  local T = fresh(label)
  eq(T.state, "ok", label .. ": state ok (simple line)")
  eq(T.custom, true, label .. ": custom")
  eq(T.cap, 0, label .. ": cap unknown")
  eq(T.weight, 80, label .. ": weight")
  eq(T.offset, -10, label .. ": offset")
  eq(thrcap.target(T), 80, label .. ": target = weight")
  eq(T.msg, "Custom line: tap to replace", label .. ": msg")
  -- a request overwrites the custom line with the cap formula, glitch-free
  local oldL = mock.lines(2)[1]
  local base = startWatch()
  requestAndApply(T, 75, label)
  checkLog(label, base, oldL, withCap(oldL, 75))
  eq(T.custom, false, label .. ": formula after the write")
  eq(T.cap, 75, label .. ": cap 75")
  -- weight above 100 is custom too
  mock.load(mock.userSpec("w120", "model6.yml", 120, 20))
  T = fresh("weight 120")
  eq(T.custom, true, "weight 120/20: custom")
  eq(T.cap, 0, "weight 120/20: cap unknown")
  -- formula with a weight below MIN
  mock.load(mock.userSpec("w10", "model7.yml", 10, -90))
  T = fresh("weight 10")
  eq(T.cap, 10, "weight 10/-90: cap 10")
  thrcap.step(T, 5)
  eq(T.pending, 20, "weight 10/-90: +5 clamps to MIN")
end

---------------------------------------------------------------- refused layouts

local function refused(label, spec, state, msg, input)
  mock.load(spec)
  local T = fresh(label)
  eq(T.state, state, label .. ": state")
  eq(T.msg, msg, label .. ": msg")
  eq(T.cap, 0, label .. ": cap unknown")
  eq(T.custom, false, label .. ": not custom")
  eq(T.weight, 0, label .. ": weight 0")
  eq(T.offset, 0, label .. ": offset 0")
  if input ~= nil then eq(T.input, input, label .. ": input") end
  local snap = mock.snapshot()
  thrcap.request(T, 60)
  for _ = 1, 10 do tick(T, 10, true, label) end
  eq(mock.writes, 0, label .. ": a request does not write")
  eq(T.pending, nil, label .. ": request dropped")
  eq(T.state, state, label .. ": state after the request")
  othersUnchanged(label, snap, -1)
  return T
end

local function specWith(fields, extra)
  local s = mock.userSpec("x", "modelx.yml", 75, -25)
  for k, v in pairs(fields) do s.expos[3][k] = v end
  if extra ~= nil then extra(s) end
  return s
end

refused("GVAR weight", specWith({ weight = 1024 + mock.FIRST_GVAR }), "unsupported", "Weight uses GVAR", 2)
refused("GVAR offset", specWith({ offset = 1024 + mock.FIRST_GVAR + 1 }), "unsupported", "Offset uses GVAR", 2)
refused("negative GVAR weight", specWith({ weight = -1024 - mock.FIRST_GVAR }), "unsupported", "Weight uses GVAR", 2)
refused("switch on line", specWith({ switch = 5 }), "unsupported", "Thr input not simple", 2)
refused("flight mode mask", specWith({ flightModes = 2 }), "unsupported", "Thr input not simple", 2)
refused("side positive only", specWith({ side = 2 }), "unsupported", "Thr input not simple", 2)
refused("inverted source", specWith({ source = -mock.THR }), "unsupported", "Thr source inverted", 2)
refused("custom curve", specWith({ curveType = 3, curveValue = 2 }), "unsupported", "Thr input has a curve", 2)
refused("function curve", specWith({ curveType = 2, curveValue = 1 }), "unsupported", "Thr input has a curve", 2)
refused("diff curve", specWith({ curveType = 0, curveValue = 20 }), "unsupported", "Thr input has a curve", 2)
refused("negative weight", specWith({ weight = -75, offset = -25 }), "unsupported", "Thr weight 0 or less", 2)
refused("two lines", specWith({}, function(s)
  table.insert(s.expos, 4, { chn = 2, source = mock.THR, weight = 50, offset = -50, switch = 7 })
end), "unsupported", "Thr input has 2 lines", 2)
refused("thr on line 2", specWith({ source = mock.POT1 }, function(s)
  table.insert(s.expos, 4, { chn = 2, source = mock.THR })
end), "unsupported", "Thr input has 2 lines", 2)
refused("no throttle input", specWith({ source = mock.POT1 }), "none", "No throttle input", -1)
-- Rule a: exactly one input may use the Thr stick (also inverted). A second one is
-- refused, also when the mix shows which one the throttle channel takes.
refused("thr in 2 inputs, CH3 from a switch", specWith({}, function(s)
  s.expos[5] = { chn = 4, source = mock.THR }
  s.mixes[3] = { destCh = 2, source = mock.SA }
end), "unsupported", "Thr in 2 inputs", -1)
refused("thr in 2 inputs, CH3 uses both", specWith({}, function(s)
  s.expos[5] = { chn = 4, source = mock.THR }
  table.insert(s.mixes, 4, { destCh = 2, source = mock.FIRST_INPUT + 4 })
end), "unsupported", "Thr in 2 inputs", -1)
refused("thr in 2 inputs, CH3 = I3, I5 in no mix", specWith({}, function(s)
  s.expos[5] = { chn = 4, source = mock.THR, weight = 80, offset = -20 }
end), "unsupported", "Thr in 2 inputs", -1)
refused("thr in 2 inputs, CH3 = I5", specWith({}, function(s)
  s.expos[5] = { chn = 4, source = mock.THR, weight = 80, offset = -20 }
  s.mixes[3] = { destCh = 2, source = mock.FIRST_INPUT + 4 }
end), "unsupported", "Thr in 2 inputs", -1)
refused("thr in 2 inputs, I5 = inverted Thr", specWith({}, function(s)
  s.expos[5] = { chn = 4, source = -mock.THR }
end), "unsupported", "Thr in 2 inputs", -1)
refused("thr in 2 inputs, Thr on line 2 of I5", specWith({}, function(s)
  s.expos[5] = { chn = 4, source = mock.POT1 }
  s.expos[6] = { chn = 4, source = mock.THR, switch = 5 }
end), "unsupported", "Thr in 2 inputs", -1)
refused("thr in 3 inputs", specWith({}, function(s)
  s.expos[5] = { chn = 4, source = mock.THR }
  s.expos[6] = { chn = 7, source = mock.THR }
end), "unsupported", "Thr in 3 inputs", -1)
refused("thr in 2 inputs, CH3 = I3 + raw Thr, CH9 = I5", specWith({}, function(s)
  s.expos[5] = { chn = 4, source = mock.THR }
  table.insert(s.mixes, 4, { destCh = 2, source = mock.THR })
  s.mixes[#s.mixes + 1] = { destCh = 8, source = mock.FIRST_INPUT + 4 }
end), "unsupported", "Thr in 2 inputs", -1)

---------------------------------------------------------------- mix check of the thr input

-- Rules c and d, on every mix line that Lua can read (all 32 channels): a line must take
-- input 3 with a plain weight above 0, and no line may take the raw Thr stick (also
-- inverted), input 3 inverted (the source -I3, also with a negative weight), input 3
-- with a negative or GVAR weight, or input 3 with a function or custom curve. The
-- refusal names the channel of the first such line. The Lua mix list stops at the
-- first line with the source "---" (api_model.cpp getFirstMix): when that hides the
-- line that takes input 3, the cap is refused ("Thr input not in mixes"); lines hidden
-- after a visible use cannot be seen.

local NONE = 0                                    -- the mix source "---" (srcRaw 0)
local function I(n) return mock.FIRST_INPUT + n - 1 end   -- input n (1-based) as a mix source
local function mx(ch, src, w, extra)
  local t = { destCh = ch - 1, source = src, weight = w }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end
local function mixSpec(name, mixes)
  local s = mock.userSpec(name, name .. ".yml", 75, -25)
  s.mixes = mixes
  return s
end
local AETR = { mx(1, I(4)), mx(2, I(2)), mx(3, I(3)), mx(4, I(1)) }
-- AETR with one more line on channel ch (after the other lines of that channel)
local function aetrWith(ch, line)
  local l = {}
  for _, m in ipairs(AETR) do
    if m.destCh > ch - 1 and line ~= nil then l[#l + 1] = line; line = nil end
    l[#l + 1] = m
  end
  if line ~= nil then l[#l + 1] = line end
  return l
end

-- Every mix slot as a text (the mixes are never written).
local function mixText()
  local t = {}
  for i = 0, mock.MAX_MIXERS - 1 do
    local m = mock.mix[i]
    t[#t + 1] = m.destCh .. ":" .. m.srcRaw .. ":" .. m.weight .. ":" .. m.ctype .. ":" .. m.cvalue
  end
  return table.concat(t, ",")
end

-- The cap is allowed on input 3 (75/-25): a swap to 60 % is glitch-free, only the
-- throttle line changes.
local function allowed(label, spec)
  mock.load(spec)
  local T = fresh(label)
  eq(T.state, "ok", label .. ": state")
  eq(T.msg, "Ready", label .. ": msg")
  eq(T.input, 2, label .. ": input I3")
  eq(T.cap, 75, label .. ": cap")
  local oldL = mock.lines(2)[1]
  local snap = mock.snapshot()
  local mixes = mixText()
  local base = startWatch()
  requestAndApply(T, 60, label)
  eq(mock.writes, 2, label .. ": one swap")
  checkLog(label, base, oldL, withCap(oldL, 60))
  eq(T.state, "ok", label .. ": state after the swap")
  eq(T.cap, 60, label .. ": cap after the swap")
  check(sameLine(mock.lines(2)[1], withCap(oldL, 60)), label .. ": input 3 is 60/-40")
  othersUnchanged(label, snap, 2)
  eq(mixText(), mixes, label .. ": the mix lines are not changed")
  return T
end

-- Allowed: a visible line takes input 3 with a plain weight above 0, nothing bypasses
-- or inverts it.
allowed("AETR, CH3 takes input 3", mixSpec("aetr", AETR))
allowed("the user's whole mix list (gyro lines too)", mixSpec("userfull", mock.userMixes(true)))
allowed("TAER, CH1 takes input 3", mixSpec("taer", { mx(1, I(3)), mx(2, I(4)), mx(3, I(2)), mx(4, I(1)) }))
allowed("input 3 only on CH8", specWith({}, function(s)
  s.mixes[3] = { destCh = 2, source = mock.SA }
  s.mixes[6] = { destCh = 7, source = mock.FIRST_INPUT + 2 }
end))
allowed("CH3 and CH7 take input 3", mixSpec("ch7", aetrWith(7, mx(7, I(3), 50))))
allowed("CH3 takes input 3 twice, one line with weight 0",
  mixSpec("w0", aetrWith(3, mx(3, I(3), 0))))
allowed("CH3 mix with expo 40", mixSpec("mexpo",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3), 100, { curveType = 1, curveValue = 40 }), mx(4, I(1)) }))
allowed("CH3 mix with differential 20", mixSpec("mdiff",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3), 100, { curveType = 0, curveValue = 20 }), mx(4, I(1)) }))
allowed("CH3 mix, custom curve type with value 0 (no curve)", mixSpec("mcnone",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3), 100, { curveType = 3, curveValue = 0 }), mx(4, I(1)) }))

-- Rule d: refused, the message names the channel of the first such line.
refused("CH3 takes the raw Thr stick", specWith({}, function(s)
  s.mixes[3] = { destCh = 2, source = mock.THR }
end), "unsupported", "CH3 uses raw Thr", 2)
refused("CH3 takes the inverted raw Thr stick", specWith({}, function(s)
  s.mixes[3] = { destCh = 2, source = -mock.THR }
end), "unsupported", "CH3 uses raw Thr", 2)
refused("CH3 takes input 3 inverted", specWith({}, function(s)
  s.mixes[3] = { destCh = 2, source = -(mock.FIRST_INPUT + 2) }
end), "unsupported", "CH3 inverts the Thr input", 2)
refused("AETR, CH3 takes input 3 and raw Thr", mixSpec("aetrraw", aetrWith(3, mx(3, mock.THR, 20))),
  "unsupported", "CH3 uses raw Thr", 2)
refused("AETR, CH3 takes input 3 and input 3 inverted", mixSpec("aetrinv", aetrWith(3, mx(3, -I(3), 50))),
  "unsupported", "CH3 inverts the Thr input", 2)
refused("TAER, CH1 takes input 3 and raw Thr", mixSpec("taerraw",
  { mx(1, I(3)), mx(1, mock.THR, 30), mx(2, I(4)), mx(3, I(2)), mx(4, I(1)) }),
  "unsupported", "CH1 uses raw Thr", 2)
-- a small Thr -> elevator mix of a plane is a raw Thr line too (refused when in doubt)
refused("TAER, Thr -> elevator mix on CH3", mixSpec("taercomp",
  { mx(1, I(3)), mx(2, I(4)), mx(3, I(2)), mx(3, mock.THR, 5), mx(4, I(1)) }),
  "unsupported", "CH3 uses raw Thr", 2)
refused("TAER, inverted Thr -> elevator mix on CH3", mixSpec("taercompinv",
  { mx(1, I(3)), mx(2, I(4)), mx(3, I(2)), mx(3, -mock.THR, 5), mx(4, I(1)) }),
  "unsupported", "CH3 uses raw Thr", 2)
refused("AETR, Thr -> elevator mix on CH2", mixSpec("aetrcomp", aetrWith(2, mx(2, mock.THR, 10))),
  "unsupported", "CH2 uses raw Thr", 2)
refused("CH3 takes input 3, CH7 takes input 3 and raw Thr", mixSpec("ch7raw",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3)), mx(4, I(1)), mx(7, I(3)), mx(7, mock.THR) }),
  "unsupported", "CH7 uses raw Thr", 2)
refused("the user's mix list, raw Thr on CH13", specWith({}, function(s)
  s.mixes = mock.userMixes(true)
  table.insert(s.mixes, 13, { destCh = 12, source = mock.THR })
end), "unsupported", "CH13 uses raw Thr", 2)
refused("CH3 takes input 3, raw Thr on CH32", mixSpec("ch32raw", aetrWith(32, mx(32, mock.THR))),
  "unsupported", "CH32 uses raw Thr", 2)
refused("TAER, CH1 takes input 3 inverted, Thr comp on CH3", mixSpec("taerinv",
  { mx(1, -I(3)), mx(2, I(4)), mx(3, I(2)), mx(3, mock.THR, 5), mx(4, I(1)) }),
  "unsupported", "CH1 inverts the Thr input", 2)
refused("TAER, CH1 takes input 3, CH2 takes it inverted", mixSpec("taer2",
  { mx(1, I(3)), mx(2, -I(3), 10), mx(2, mock.THR, 10), mx(3, I(2)), mx(4, I(1)) }),
  "unsupported", "CH2 inverts the Thr input", 2)
refused("input 3 only inverted, on CH6", specWith({}, function(s)
  s.mixes[3] = { destCh = 2, source = mock.SA }
  s.mixes[6] = { destCh = 5, source = -(mock.FIRST_INPUT + 2) }
end), "unsupported", "CH6 inverts the Thr input", 2)
refused("TAER, CH1 takes raw Thr only, no mix takes input 3", mixSpec("taerrawonly",
  { mx(1, mock.THR), mx(2, I(4)), mx(3, I(2)), mx(4, I(1)) }),
  "unsupported", "CH1 uses raw Thr", 2)
refused("CH3 raw Thr, input 3 feeds CH6", specWith({}, function(s)
  s.mixes[3] = { destCh = 2, source = mock.THR }
  s.mixes[5] = { destCh = 4, source = mock.SA, weight = -100 }
  s.mixes[6] = { destCh = 5, source = mock.FIRST_INPUT + 2 }
end), "unsupported", "CH3 uses raw Thr", 2)
refused("CH3 takes only input 3 inverted, CH6 takes input 3", mixSpec("invch6",
  { mx(1, I(4)), mx(2, I(2)), mx(3, -I(3)), mx(4, I(1)), mx(6, I(3)) }),
  "unsupported", "CH3 inverts the Thr input", 2)
-- An input with a negative mix weight gives the same output as the source -I3.
refused("CH3 takes input 3 with weight -100", mixSpec("negw",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3), -100), mx(4, I(1)) }),
  "unsupported", "CH3 inverts the Thr input", 2)
refused("CH3 takes input 3 and input 3 with weight -50", mixSpec("negw50", aetrWith(3, mx(3, I(3), -50))),
  "unsupported", "CH3 inverts the Thr input", 2)
refused("TAER, CH1 takes input 3 with weight -100", mixSpec("taernegw",
  { mx(1, I(3), -100), mx(2, I(4)), mx(3, I(2)), mx(4, I(1)) }),
  "unsupported", "CH1 inverts the Thr input", 2)
refused("CH3 takes input 3, CH6 takes it with weight -1", mixSpec("negw1", aetrWith(6, mx(6, I(3), -1))),
  "unsupported", "CH6 inverts the Thr input", 2)
-- two inversions (source -I3, weight -100) give a plain use, but the rule refuses -I3
refused("CH3 takes -input 3 with weight -100", mixSpec("negneg",
  { mx(1, I(4)), mx(2, I(2)), mx(3, -I(3), -100), mx(4, I(1)) }),
  "unsupported", "CH3 inverts the Thr input", 2)
-- a GVAR weight (Lua value >= 1024 or <= -1024): the sign is not known
refused("CH3 takes input 3 with a GVAR weight", mixSpec("gvw",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3), 1024 + mock.FIRST_GVAR), mx(4, I(1)) }),
  "unsupported", "CH3 mix weight uses GVAR", 2)
refused("CH3 takes input 3 with a negative GVAR weight", mixSpec("gvwn",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3), -1024 - mock.FIRST_GVAR), mx(4, I(1)) }),
  "unsupported", "CH3 mix weight uses GVAR", 2)
-- function and custom curves on the mix line can invert or fold the input
refused("CH3 mix with custom curve 1", mixSpec("mcust",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3), 100, { curveType = 3, curveValue = 1 }), mx(4, I(1)) }),
  "unsupported", "CH3 Thr mix has a curve", 2)
refused("CH3 mix with inverted custom curve 1", mixSpec("mcustinv",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3), 100, { curveType = 3, curveValue = -1 }), mx(4, I(1)) }),
  "unsupported", "CH3 Thr mix has a curve", 2)
refused("CH3 mix with the function |x|", mixSpec("mfunc",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3), 100, { curveType = 2, curveValue = 3 }), mx(4, I(1)) }),
  "unsupported", "CH3 Thr mix has a curve", 2)
-- a "---" line after the raw Thr line of CH3: the lines before it are read, the raw
-- Thr line is still seen
refused("CH3 raw Thr, then a '---' line on CH4", mixSpec("rawnone",
  { mx(1, I(4)), mx(2, I(2)), mx(3, mock.THR), mx(4, NONE), mx(4, I(1)), mx(5, I(3)) }),
  "unsupported", "CH3 uses raw Thr", 2)

-- Rule c: no line that Lua can read takes input 3 with a weight above 0.
refused("input 3 used by no mix", specWith({}, function(s)
  s.mixes[3] = { destCh = 2, source = mock.SA }
end), "unsupported", "Thr input not in mixes", 2)
refused("throttle on a slider (I3 = S1), a leftover I5 = Thr", specWith({ source = mock.POT1 }, function(s)
  s.expos[5] = { chn = 4, source = mock.THR }
end), "unsupported", "Thr input not in mixes", 4)
refused("input 3 used by no mix, no other mix line", specWith({}, function(s)
  s.mixes = { { destCh = 0, source = mock.FIRST_INPUT + 3 } }
end), "unsupported", "Thr input not in mixes", 2)
refused("no mix line at all", specWith({}, function(s) s.mixes = {} end),
  "unsupported", "Thr input not in mixes", 2)
refused("CH3 takes input 3 with weight 0 only", mixSpec("w0only",
  { mx(1, I(4)), mx(2, I(2)), mx(3, I(3), 0), mx(4, I(1)) }),
  "unsupported", "Thr input not in mixes", 2)
do
  -- A mix line with the source "---" (srcRaw 0) on CH1: the colour mixer skips it and
  -- CH3 still uses input 3, but the Lua mix list stops at it (api_model.cpp
  -- getFirstMix): Lua sees no line of CH2..CH32. Refused (a false refusal, accepted).
  local spec = mixSpec("none1", { mx(1, I(4)), mx(1, NONE), mx(2, I(2)), mx(3, I(3)), mx(4, I(1)) })
  mock.load(spec)
  eq(model.getMixesCount(0), 1, "'---' on CH1: Lua sees the CH1 line before it")
  eq(model.getMixesCount(1), 0, "'---' on CH1: Lua sees no line of CH2")
  eq(model.getMixesCount(2), 0, "'---' on CH1: Lua sees no line of CH3")
  eq(model.getMix(2, 0), nil, "'---' on CH1: getMix(CH3, 0) is nil")
  local src = mock.mixerSources(2)
  check(#src == 1 and src[1] == I(3), "'---' on CH1: the mixer uses input 3 on CH3")
  src = mock.mixerSources(0)
  check(#src == 1 and src[1] == I(4), "'---' on CH1: the mixer skips the '---' line")
  refused("'---' line on CH1 hides the CH3 mix", spec, "unsupported", "Thr input not in mixes", 2)
end
refused("'---' line first", mixSpec("none0",
  { mx(1, NONE), mx(1, I(4)), mx(2, I(2)), mx(3, I(3)), mx(4, I(1)) }),
  "unsupported", "Thr input not in mixes", 2)
refused("'---' line on CH3 before input 3", mixSpec("none3",
  { mx(1, I(4)), mx(2, I(2)), mx(3, NONE), mx(3, I(3)), mx(4, I(1)) }),
  "unsupported", "Thr input not in mixes", 2)
refused("'---' line hides CH3 raw Thr", mixSpec("nonehide",
  { mx(1, I(4)), mx(2, NONE), mx(2, I(2)), mx(3, mock.THR), mx(4, I(1)) }),
  "unsupported", "Thr input not in mixes", 2)
refused("AETR, Thr -> elevator mix on CH2, then a '---' line", mixSpec("aetrcompnone",
  { mx(1, I(4)), mx(2, I(2)), mx(2, mock.THR, 10), mx(2, NONE), mx(3, I(3)), mx(4, I(1)) }),
  "unsupported", "CH2 uses raw Thr", 2)
do
  -- The limit: a "---" line AFTER the visible line that takes input 3 hides the lines
  -- after it (here a raw Thr line on CH7). Lua cannot tell them from empty channels,
  -- so the cap is allowed.
  local spec = mixSpec("nonelater",
    { mx(1, I(4)), mx(2, I(2)), mx(3, I(3)), mx(4, NONE), mx(4, I(1)), mx(7, mock.THR) })
  mock.load(spec)
  eq(model.getMixesCount(2), 1, "'---' on CH4: Lua sees the CH3 line")
  eq(model.getMixesCount(6), 0, "'---' on CH4: Lua sees no line of CH7")
  local src = mock.mixerSources(6)
  check(#src == 1 and src[1] == mock.THR, "'---' on CH4: the mixer uses raw Thr on CH7")
  allowed("'---' line on CH4 after the CH3 mix (limit: hidden lines)", spec)
end
do
  -- two thr inputs and a hidden mix: refused by rule a
  local spec = mixSpec("none2", { mx(1, I(4)), mx(1, NONE), mx(2, I(2)), mx(3, I(3)), mx(4, I(1)) })
  spec.expos[5] = { chn = 4, source = mock.THR }
  refused("thr in 2 inputs, '---' line on CH1", spec, "unsupported", "Thr in 2 inputs", -1)
end

do
  -- without the mix API the cap cannot be checked: refused, nothing written
  local gc, gm = model.getMixesCount, model.getMix
  for _, which in ipairs({ "both", "getMix", "getMixesCount" }) do
    local label = "no mix API (" .. which .. " missing)"
    mock.load(specWith({}))
    if which ~= "getMixesCount" then model.getMix = nil end
    if which ~= "getMix" then model.getMixesCount = nil end
    local T = fresh(label)
    eq(T.state, "none", label .. ": state")
    eq(T.msg, "No mix API", label .. ": msg")
    eq(T.input, -1, label .. ": no input")
    eq(T.cap, 0, label .. ": cap unknown")
    thrcap.request(T, 60)
    for _ = 1, 10 do tick(T, 10, true, label) end
    eq(T.pending, nil, label .. ": request dropped")
    eq(mock.writes, 0, label .. ": nothing written")
    model.getMixesCount, model.getMix = gc, gm
  end
  -- no id for the mix source of an input (getFieldInfo("input1") is nil): refused
  local label = "no input1 field"
  mock.load(specWith({}))
  local savedFI = getFieldInfo
  getFieldInfo = function(name)
    if name == "input1" then return nil end
    return savedFI(name)
  end
  local T = fresh(label)
  eq(T.state, "none", label .. ": state")
  eq(T.msg, "No input source id", label .. ": msg")
  thrcap.request(T, 60)
  for _ = 1, 10 do tick(T, 10, true, label) end
  eq(mock.writes, 0, label .. ": nothing written")
  getFieldInfo = savedFI
  -- the source id of a mix line: input chn = getFieldInfo("input1").id + chn
  -- (MIXSRC_FIRST_INPUT + chn in the firmware, the srcRaw value that getMix returns)
  eq(getFieldInfo("input1").id, mock.FIRST_INPUT, "input1 id = MIXSRC_FIRST_INPUT")
  eq(getFieldInfo("input3").id, mock.FIRST_INPUT + 2, "input3 id = MIXSRC_FIRST_INPUT + 2")

  -- the user sets the CH3 mix from raw Thr to I3 by hand: the next read (within 2 s)
  -- accepts the input
  label = "mix of input 3 set later"
  mock.load(specWith({}, function(s) s.mixes[3] = { destCh = 2, source = mock.THR } end))
  T = fresh(label)
  eq(T.state, "unsupported", label .. ": refused first")
  eq(T.msg, "CH3 uses raw Thr", label .. ": msg first")
  thrcap.request(T, 50)
  tick(T, 45, true, label)
  eq(T.pending, nil, label .. ": a request while refused is dropped")
  eq(mock.writes, 0, label .. ": nothing written while refused")
  mock.mix[2].srcRaw = mock.FIRST_INPUT + 2
  tick(T, 200, true, label)
  eq(T.state, "ok", label .. ": state after the edit")
  eq(T.msg, "Ready", label .. ": msg after the edit")
  eq(T.cap, 75, label .. ": cap after the edit")
  local oldL = mock.lines(2)[1]
  local base = startWatch()
  requestAndApply(T, 50, label)
  eq(mock.writes, 2, label .. ": one swap")
  eq(T.cap, 50, label .. ": cap after the swap")
  checkLog(label, base, oldL, withCap(oldL, 50))

  -- the mix gets a raw Thr line while a request waits: the fresh read just before the
  -- write refuses, nothing is written
  label = "raw Thr line added while a request waits"
  mock.load(mixSpec("late", AETR))
  T = fresh(label)
  eq(T.state, "ok", label .. ": ok first")
  thrcap.request(T, 60)
  tick(T, 20, true, label)
  eq(T.pending, 60, label .. ": pending")
  mock.mix[3].srcRaw = mock.THR                   -- CH4 now takes the raw Thr stick
  tick(T, 25, true, label)
  eq(mock.writes, 0, label .. ": nothing written")
  eq(T.pending, nil, label .. ": request dropped")
  eq(T.state, "unsupported", label .. ": state")
  eq(T.msg, "CH4 uses raw Thr", label .. ": msg")
end
do
  -- the mix check runs only in the scan (every 2 s), not on an idle tick; a scan reads
  -- every channel once and every line that Lua sees once
  local spec = mock.userSpec("75", "model1.yml", 75, -25)
  spec.mixes = mock.userMixes(true)
  mock.load(spec)
  local T = fresh("mix check cost")
  local c0 = #mock.calls + 1
  for _ = 1, 30 do tick(T, 5, true, "mix check cost") end
  eq(countCalls("getMixesCount", c0) + countCalls("getMix", c0), 0, "mix check: no mix read between two scans")
  tick(T, 200, true, "mix check cost")
  eq(countCalls("getMixesCount", c0), 32, "mix check: 32 getMixesCount calls in a scan")
  eq(countCalls("getMix", c0), 14, "mix check: one getMix call per line (14 lines)")
  -- a refusal by the input line check reads no mix
  mock.load(specWith({ switch = 5 }))
  T = fresh("input refusal cost")
  c0 = #mock.calls + 1
  tick(T, 200, true, "input refusal cost")
  eq(T.msg, "Thr input not simple", "input refusal cost: msg")
  eq(countCalls("getMixesCount", c0), 0, "input refusal: no mix read")
  -- a hidden mix ("---" line first): every channel is read once in a scan, and getMix
  -- only for the lines that Lua sees (none)
  mock.load(mixSpec("hidden", { mx(1, NONE), mx(1, I(4)), mx(2, I(2)), mx(3, I(3)), mx(4, I(1)) }))
  T = fresh("hidden mix cost")
  c0 = #mock.calls + 1
  for _ = 1, 30 do tick(T, 5, true, "hidden mix cost") end
  eq(countCalls("getMixesCount", c0), 0, "hidden mix: no getMixesCount call between two scans")
  tick(T, 200, true, "hidden mix cost")
  eq(countCalls("getMixesCount", c0), 32, "hidden mix: 32 getMixesCount calls in a scan")
  eq(countCalls("getMix", c0), 0, "hidden mix: no getMix call in a scan")
end

do
  local saved = mock.noThr
  local spec = specWith({})
  local function noThr(s) return s end
  mock.noThr = true
  -- mock.load keeps noThr? it resets it: set it again after the load inside refused()
  mock.load(noThr(spec))
  mock.noThr = true
  local T = fresh("no thr source")
  eq(T.state, "none", "no thr source: state")
  eq(T.msg, "No thr source", "no thr source: msg")
  mock.noThr = saved
end

-- Expo curve and zero DIFF are fine (end points kept / no curve).
do
  for _, c in ipairs({ { 1, 40 }, { 1, -30 }, { 0, 0 }, { 1, 1024 + mock.FIRST_GVAR } }) do
    local label = string.format("curve type %d value %d", c[1], c[2])
    mock.load(specWith({ curveType = c[1], curveValue = c[2] }))
    local T = fresh(label)
    eq(T.state, "ok", label .. ": accepted")
    eq(T.cap, 75, label .. ": cap")
    local oldL = mock.lines(2)[1]
    local base = startWatch()
    requestAndApply(T, 60, label)
    checkLog(label, base, oldL, withCap(oldL, 60))
    check(sameLine(mock.lines(2)[1], withCap(oldL, 60)), label .. ": curve kept")
  end
end

-- Name, trim source and scale are copied.
do
  local label = "line name and trim"
  mock.load(specWith({ name = "ThrCap", trimSource = -1, scale = 3 }))
  local T = fresh(label)
  local oldL = mock.lines(2)[1]
  eq(oldL.name, "ThrCap", label .. ": name stored")
  local base = startWatch()
  requestAndApply(T, 90, label)
  checkLog(label, base, oldL, withCap(oldL, 90))
  local l = mock.lines(2)[1]
  eq(l.name, "ThrCap", label .. ": name kept")
  eq(l.trimSource, -1, label .. ": trim source kept")
  eq(l.scale, 3, label .. ": scale kept")
end

---------------------------------------------------------------- other input positions

-- Throttle on I1 (chn 0): the default line of insertExpo would be the aileron
-- (AETR), and on I6 (chn 5) an analog after the sticks. Both stay dead.
for _, chn in ipairs({ 0, 5 }) do
  local label = "throttle on chn " .. chn
  local spec = { name = "c" .. chn, filename = "c" .. chn .. ".yml", expos = {},
                 mixes = { { destCh = 2, source = mock.FIRST_INPUT + chn } } }
  for c = 0, 6 do
    local src = (c == chn) and mock.THR or mock.AIL
    spec.expos[#spec.expos + 1] = { chn = c, source = src, weight = (c == chn) and 75 or 100,
                                    offset = (c == chn) and -25 or 0 }
  end
  mock.load(spec)
  mock.watch = chn
  local T = fresh(label)
  eq(T.input, chn, label .. ": input")
  eq(T.cap, 75, label .. ": cap")
  local oldL = mock.lines(chn)[1]
  local base = startWatch()
  requestAndApply(T, 55, label)
  checkLog(label, base, oldL, withCap(oldL, 55))
  eq(T.cap, 55, label .. ": cap after")
  mock.watch = 2
end

---------------------------------------------------------------- missing API (older firmware)

do
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local saved = model.getInput
  model.getInput = nil
  local T = fresh("no getInput")
  eq(T.state, "none", "no getInput: state none")
  eq(T.msg, "No input API", "no getInput: msg")
  eq(T.cap, 0, "no getInput: cap unknown")
  eq(T.input, -1, "no getInput: input -1")
  thrcap.request(T, 60)
  tick(T, 50, true, "no getInput")
  eq(T.pending, nil, "no getInput: request dropped")
  eq(mock.writes, 0, "no getInput: no write")
  model.getInput = saved

  local savedModel = model
  model = nil
  T = fresh("no model table")
  eq(T.state, "none", "no model table: state none")
  model = savedModel

  local savedFI = getFieldInfo
  getFieldInfo = nil
  T = fresh("no getFieldInfo")
  eq(T.state, "none", "no getFieldInfo: state none")
  eq(T.msg, "No thr source", "no getFieldInfo: msg")
  getFieldInfo = savedFI

  -- the scan does not need defaultChannel (every channel is checked)
  local savedDC = defaultChannel
  defaultChannel = nil
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  T = fresh("no defaultChannel")
  eq(T.state, "ok", "no defaultChannel: state ok")
  eq(T.input, 2, "no defaultChannel: input 3")
  defaultChannel = savedDC
end

---------------------------------------------------------------- requests: clamp, integers, coalesce

do
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh("clamp")
  thrcap.request(T, 5); eq(T.pending, 20, "request 5 -> MIN 20")
  thrcap.request(T, 150); eq(T.pending, 100, "request 150 -> MAX 100")
  thrcap.request(T, 72.6); eq(T.pending, 73, "request 72.6 -> 73")
  eq(math.type(T.pending), "integer", "pending is an integer")
  thrcap.request(T, 72.4); eq(T.pending, 72, "request 72.4 -> 72")
  local p = T.pending
  thrcap.request(T, nil); eq(T.pending, p, "request nil ignored")
  thrcap.request(T, "80"); eq(T.pending, p, "request string ignored")
  thrcap.request(T, 0 / 0); eq(T.pending, p, "request NaN ignored")
  thrcap.request(T, 1e30); eq(T.pending, 100, "request huge -> MAX")
  eq(math.type(T.pending), "integer", "huge -> integer")
  thrcap.request(T, 72.4)
  local base = startWatch()
  tick(T, 45, true, "clamp")
  eq(T.cap, 72, "72.4 applied as 72")
  eq(mock.floatArgs, 0, "no float argument reached the API")
  checkLog("clamp", base, withCap(mock.lines(2)[1], 75), withCap(mock.lines(2)[1], 72))
end

do
  local label = "rapid requests"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  local rev0 = T.rev
  local oldL = mock.lines(2)[1]
  local base = startWatch()
  mock.writes = 0
  thrcap.request(T, 90)
  check(T.rev > rev0, label .. ": rev changes on a request")
  tick(T, 10, true, label)
  eq(T.state, "busy", label .. ": busy while pending")
  eq(T.msg, "Setting 90%...", label .. ": busy msg")
  thrcap.request(T, 85); tick(T, 10, true, label)
  thrcap.request(T, 80); tick(T, 10, true, label)
  thrcap.step(T, -5); eq(T.pending, 75, label .. ": step from the pending value")
  thrcap.step(T, -5); eq(T.pending, 70, label .. ": second step")
  eq(thrcap.target(T), 70, label .. ": target = pending")
  local tReq = mock.time
  for _ = 1, 3 do tick(T, 10, true, label) end
  eq(mock.writes, 0, label .. ": nothing written 300 ms after the last tap")
  tick(T, 10, true, label)
  check(mock.time - tReq >= 40, label .. ": written 400 ms after the last tap")
  eq(mock.writes, 2, label .. ": one swap for five taps")
  eq(T.cap, 70, label .. ": the last value wins")
  checkLog(label, base, oldL, withCap(oldL, 70))
  for _ = 1, 20 do tick(T, 10, true, label) end
  eq(mock.writes, 2, label .. ": no more writes")
  eq(countCalls("insertInput"), 1, label .. ": one insertInput")
end

---------------------------------------------------------------- request before the first tick

do
  local label = "request before the first tick"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = thrcap.new()
  thrcap.request(T, 60)
  tick(T, 1, true, label)
  eq(T.pending, 60, label .. ": kept for the model that is read first")
  eq(T.state, "busy", label .. ": busy")
  tick(T, 45, true, label)
  eq(T.cap, 60, label .. ": applied")
end

---------------------------------------------------------------- background: never writes

do
  local label = "background"
  mock.load(mock.userSpec("sim", "model2.yml", 50, -50))
  local T = fresh(label)
  thrcap.request(T, 65)
  for _ = 1, 30 do tick(T, 10, false, label) end
  eq(mock.writes, 0, label .. ": no write from background")
  eq(T.pending, 65, label .. ": still pending")
  eq(T.state, "busy", label .. ": busy")
  local oldL = mock.lines(2)[1]
  local base = startWatch()
  tick(T, 5, true, label)
  eq(mock.writes, 2, label .. ": written on the next refresh")
  eq(T.cap, 65, label .. ": cap")
  checkLog(label, base, oldL, withCap(oldL, 65))
end

---------------------------------------------------------------- line changed while a request waits

-- The user taps 50 % on model '75', leaves the main view before the debounce ends (only
-- background() runs), and sets the line to 100/0 by hand in the Inputs editor. The
-- waiting request must not overwrite the newer manual setting.
do
  local label = "line edited, then refresh"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  thrcap.request(T, 50)
  for _ = 1, 10 do tick(T, 10, false, label) end     -- 100 ms in background, no scan due
  eq(T.pending, 50, label .. ": still pending")
  mock.expo[2].weight = mock.toSNV(100)               -- the edit in the Inputs editor
  mock.expo[2].offset = mock.toSNV(0)
  mock.writes = 0
  tick(T, 40, true, label)                            -- first refresh after the debounce
  eq(mock.writes, 0, label .. ": the newer manual line is not overwritten")
  eq(T.pending, nil, label .. ": request dropped")
  eq(T.state, "error", label .. ": state")
  eq(T.msg, "Line changed: not set", label .. ": msg")
  eq(T.cap, 100, label .. ": the edited line was read")
  local ls = mock.lines(2)
  eq(#ls, 1, label .. ": one line")
  eq(ls[1].weight, 100, label .. ": weight kept")
  eq(ls[1].offset, 0, label .. ": offset kept")
  for _ = 1, 20 do tick(T, 10, true, label) end
  eq(mock.writes, 0, label .. ": no write later")
  -- a new request on the edited line works
  local oldL = mock.lines(2)[1]
  local base = startWatch()
  requestAndApply(T, 60, label .. " then 60")
  eq(T.cap, 60, label .. ": a new request is applied")
  checkLog(label .. " then 60", base, oldL, withCap(oldL, 60))
end

do
  local label = "line edited, background scan"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  thrcap.request(T, 50)
  for _ = 1, 5 do tick(T, 10, false, label) end
  mock.expo[2].weight = mock.toSNV(100)
  mock.expo[2].offset = mock.toSNV(0)
  for _ = 1, 25 do tick(T, 10, false, label) end      -- a scan runs in background
  eq(T.pending, nil, label .. ": dropped by the scan in background")
  eq(T.msg, "Line changed: not set", label .. ": msg")
  eq(T.state, "error", label .. ": state")
  mock.writes = 0
  for _ = 1, 10 do tick(T, 10, true, label) end
  eq(mock.writes, 0, label .. ": nothing written on the next refresh")
  eq(T.cap, 100, label .. ": cap of the edited line")
end

do
  -- the throttle line moves to another input while the request waits
  local label = "line moved to input 5"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  thrcap.request(T, 50)
  local spec = mock.userSpec("75", "model1.yml", 75, -25)
  spec.expos[3].source = mock.POT1
  spec.expos[5] = { chn = 4, source = mock.THR, weight = 75, offset = -25 }
  spec.mixes[3] = { destCh = 2, source = mock.FIRST_INPUT + 4 }
  mock.load(spec)
  tick(T, 45, true, label)
  eq(mock.writes, 0, label .. ": nothing written")
  eq(T.msg, "Line changed: not set", label .. ": msg")
  eq(T.input, 4, label .. ": the new input was read")
end

do
  -- an edit to the same values is no change: the request is applied
  local label = "same values written again"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  thrcap.request(T, 50)
  mock.expo[2].weight = mock.toSNV(75)
  mock.expo[2].offset = mock.toSNV(-25)
  tick(T, 45, true, label)
  eq(T.cap, 50, label .. ": applied")
end

do
  -- the user adds an expo by hand (weight and offset stay): the line is not the one
  -- that the request was made for, so the request is dropped too
  local label = "expo edited while pending"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  thrcap.request(T, 50)
  for _ = 1, 10 do tick(T, 10, false, label) end
  mock.expo[2].cvalue = mock.toSNV(30)
  mock.writes = 0
  tick(T, 40, true, label)
  eq(mock.writes, 0, label .. ": nothing written")
  eq(T.pending, nil, label .. ": request dropped")
  eq(T.msg, "Line changed: not set", label .. ": msg")
  local ls = mock.lines(2)
  eq(#ls, 1, label .. ": one line")
  eq(ls[1].curveValue, 30, label .. ": expo kept")
  eq(ls[1].weight, 75, label .. ": weight kept")
end

do
  -- the line name changes in the Inputs editor and a background scan sees it
  local label = "line name edited while pending"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  thrcap.request(T, 50)
  mock.expo[2].name = "Gas"
  for _ = 1, 25 do tick(T, 10, false, label) end
  eq(T.pending, nil, label .. ": dropped by the scan in background")
  eq(T.msg, "Line changed: not set", label .. ": msg")
  for _ = 1, 10 do tick(T, 10, true, label) end
  eq(mock.writes, 0, label .. ": nothing written")
end

---------------------------------------------------------------- request too old

-- The user taps 50 % and the main view is then not shown for more than 5 s (only
-- background() runs); the line does not change. When the view shows again, the old
-- request is not applied: the cap never changes later without a new tap.
do
  local label = "request expired"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  thrcap.request(T, 50)
  local tReq = mock.time
  for _ = 1, 51 do tick(T, 10, false, label) end      -- 5.1 s in background (2 scans)
  eq(T.pending, 50, label .. ": kept in background")
  eq(T.state, "busy", label .. ": busy in background")
  mock.writes = 0
  tick(T, 5, true, label)                             -- the view shows again
  check(mock.time - tReq > 500, label .. ": more than 5 s after the tap")
  eq(mock.writes, 0, label .. ": not written")
  eq(T.pending, nil, label .. ": request dropped")
  eq(T.state, "error", label .. ": state")
  eq(T.msg, "Request expired: not set", label .. ": msg")
  eq(T.cap, 75, label .. ": cap unchanged")
  local ls = mock.lines(2)
  eq(#ls, 1, label .. ": one line")
  eq(ls[1].weight, 75, label .. ": weight unchanged")
  eq(ls[1].offset, -25, label .. ": offset unchanged")
  for _ = 1, 20 do tick(T, 10, true, label) end
  eq(mock.writes, 0, label .. ": no write later")
  tick(T, 400, true, label)
  eq(T.state, "ok", label .. ": ok after the result time")
  eq(T.msg, "Ready", label .. ": msg after the result time")
  -- a new tap is applied as usual
  local oldL = mock.lines(2)[1]
  local base = startWatch()
  requestAndApply(T, 50, label .. " then 50")
  eq(mock.writes, 2, label .. ": a new request writes")
  eq(T.cap, 50, label .. ": a new request is applied")
  checkLog(label .. " then 50", base, oldL, withCap(oldL, 50))
end

do
  -- just inside the limit: 4.85 s in background, then the refresh applies the request
  local label = "request 4.85 s old"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  thrcap.request(T, 50)
  for _ = 1, 48 do tick(T, 10, false, label) end
  mock.writes = 0
  tick(T, 5, true, label)
  eq(mock.writes, 2, label .. ": written")
  eq(T.cap, 50, label .. ": applied")
  eq(T.msg, "Cap set to 50%", label .. ": msg")
end

do
  -- the age counts from the last tap: a new tap after 4 s gives a new 5 s
  local label = "second tap renews the request"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  thrcap.request(T, 50)
  for _ = 1, 40 do tick(T, 10, false, label) end
  thrcap.step(T, 5)
  eq(T.pending, 55, label .. ": step from the pending value")
  for _ = 1, 30 do tick(T, 10, false, label) end      -- 7 s after the first tap
  tick(T, 5, true, label)
  eq(T.cap, 55, label .. ": applied")
end

---------------------------------------------------------------- model change

do
  local label = "model change (background)"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  thrcap.request(T, 60)
  mock.load(mock.userSpec("sim", "model2.yml", 50, -50))
  for _ = 1, 10 do tick(T, 10, false, label) end
  eq(T.pending, nil, label .. ": request dropped")
  eq(T.state, "error", label .. ": state")
  eq(T.msg, "Model changed: not set", label .. ": msg")
  eq(T.cap, 50, label .. ": the new model was read")
  for _ = 1, 10 do tick(T, 10, true, label) end
  eq(mock.writes, 0, label .. ": nothing written to the new model")
  tick(T, 400, true, label)
  eq(T.state, "ok", label .. ": ok after the result time")
  eq(T.msg, "Ready", label .. ": status of the new model")
  eq(T.cap, 50, label .. ": cap of the new model")

  label = "model change (at the write)"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  T = fresh(label)
  tick(T, 50, true, label)              -- model checked now
  thrcap.request(T, 60)
  mock.load(mock.userSpec("75", "model9.yml", 75, -25))   -- same name, other file
  tick(T, 45, true, label)              -- debounce over, model check not due yet
  eq(mock.writes, 0, label .. ": nothing written")
  eq(T.msg, "Model changed: not set", label .. ": msg")
  eq(T.pending, nil, label .. ": request dropped")
end

---------------------------------------------------------------- rediscovery

do
  local label = "rediscovery"
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  local T = fresh(label)
  local rev = T.rev
  for _ = 1, 30 do tick(T, 5, true, label) end
  eq(T.rev, rev, label .. ": idle ticks do not change rev")
  -- the user edits the line in the Inputs menu (the widget runs in background)
  mock.expo[2].weight = mock.toSNV(90)
  mock.expo[2].offset = mock.toSNV(-10)
  local t0 = mock.time
  while T.cap == 75 and mock.time - t0 < 400 do tick(T, 5, false, label) end
  eq(T.cap, 90, label .. ": new value read")
  check(mock.time - t0 <= 205, label .. ": read again within about 2 s")
  check(T.rev > rev, label .. ": rev changed")
  local c0 = #mock.calls + 1
  for _ = 1, 40 do tick(T, 5, false, label) end
  eq(countCalls("getInfo", c0), 4, label .. ": the model is checked every 0.5 s")
  eq(countCalls("getInputsCount", c0), 33, label .. ": one full read in 2 s (32 inputs + the found one)")
end

---------------------------------------------------------------- failure injection

local function failCase(label, inj, wantMsg, extra)
  mock.load(mock.userSpec("75", "model1.yml", 75, -25))
  if extra ~= nil then extra() end
  local T = fresh(label)
  eq(T.state, "ok", label .. ": ok before")
  local oldL = mock.lines(2)[1]
  local newL = withCap(oldL, 60)
  local base = startWatch()
  mock.inj = inj
  requestAndApply(T, 60, label)
  eq(T.state, "error", label .. ": state error")
  eq(T.msg, wantMsg, label .. ": msg")
  checkLog(label, base, oldL, newL)
  local ls = safeLayout(label, 2, oldL, newL)
  local last = mock.cycle("after")
  eq(last.thr[5], mock.lineOut(oldL, 5), label .. ": the old cap is still live")
  mock.inj = {}
  return T, ls, oldL
end

-- 64 lines used: the firmware refuses the insert (nothing changes)
do
  local T = failCase("64 lines", {}, "No free input line (64 used)", function()
    local spec = mock.userSpec("75", "model1.yml", 75, -25)
    for chn = 4, 23 do
      for _ = 1, 3 do spec.expos[#spec.expos + 1] = { chn = chn, source = mock.POT1 } end
    end
    mock.load(spec)
    eq(#spec.expos, 64, "64 lines: model full")
  end)
  eq(#mock.lines(2), 1, "64 lines: one line")
  eq(T.cap, 75, "64 lines: cap unchanged")
end

failCase("insert does nothing", { insertNoop = true }, "No free input line (64 used)")
for k = 0, 12 do
  local T = failCase("insert error after " .. k .. " fields", { insertError = k }, "Insert failed")
  eq(#mock.lines(2), 1, "insert error " .. k .. ": extra line removed")
  eq(T.cap, 75, "insert error " .. k .. ": cap unchanged")
end
for _, f in ipairs({ "weight", "offset", "srcRaw", "ctype", "flightModes", "swtch" }) do
  local T = failCase("read-back mismatch (" .. f .. ")", { insertCorrupt = f }, "Read-back mismatch")
  eq(#mock.lines(2), 1, "read-back " .. f .. ": extra line removed")
  eq(T.cap, 75, "read-back " .. f .. ": cap unchanged")
end
do
  local T = failCase("delete does nothing once", { deleteNoop = 1 }, "Delete failed")
  eq(#mock.lines(2), 1, "delete once: extra line removed")
  eq(T.cap, 75, "delete once: cap unchanged")
  -- a retry works
  local oldL = mock.lines(2)[1]
  local base = startWatch()
  requestAndApply(T, 60, "retry")
  eq(T.cap, 60, "retry after a failure: cap set")
  checkLog("retry", base, oldL, withCap(oldL, 60))
end
do
  local T, ls, oldL = failCase("delete never works", { deleteNoop = 100 }, "Delete failed")
  eq(#ls, 2, "delete never: two lines remain")
  check(sameLine(ls[1], oldL), "delete never: line 0 is the old line (line 1 is dead)")
  tick(T, 410, true, "delete never")
  eq(T.state, "unsupported", "delete never: refused after the result time")
  eq(T.msg, "Thr input has 2 lines", "delete never: msg")
  eq(T.cap, 0, "delete never: cap unknown")
end
do
  local T = failCase("delete error once", { deleteError = 1 }, "Delete failed")
  eq(#mock.lines(2), 1, "delete error once: extra line removed")
  eq(T.cap, 75, "delete error once: cap unchanged")
end
do
  local _, ls = failCase("delete error always", { deleteError = 100 }, "Delete failed")
  eq(#ls, 2, "delete error always: two lines remain, line 0 live")
end
do
  local T = failCase("delete removes line 1", { deleteWrong = true }, "Delete failed")
  eq(#mock.lines(2), 1, "wrong delete: one line")
  eq(T.cap, 75, "wrong delete: cap unchanged")
end

---------------------------------------------------------------- CPU (desktop VM instructions)

do
  local function instr(fn)
    local n = 0
    debug.sethook(function() if not mock.inApi then n = n + 1 end end, "", 1)
    fn()
    debug.sethook()
    return n
  end
  local spec = mock.userSpec("75", "model1.yml", 75, -25)
  spec.mixes = mock.userMixes(true)                -- the whole mix list (14 lines)
  mock.load(spec)
  local T = fresh("cpu")
  tick(T, 1, true, "cpu")
  mock.time = mock.time + 1
  local idle = instr(function() thrcap.tick(T, mock.time, true) end)
  mock.time = mock.time + 200
  local scanN = instr(function() thrcap.tick(T, mock.time, true) end)
  thrcap.request(T, 60)
  mock.time = mock.time + 45
  local write = instr(function() thrcap.tick(T, mock.time, true) end)
  eq(T.cap, 60, "cpu: write done")
  spec = mock.userSpec("big", "big.yml", 75, -25)
  spec.mixes = mock.userMixes(true)
  for chn = 4, 23 do
    for _ = 1, 3 do spec.expos[#spec.expos + 1] = { chn = chn, source = mock.POT1 } end
  end
  mock.load(spec)
  T = fresh("cpu big")
  mock.time = mock.time + 200
  local big = instr(function() thrcap.tick(T, mock.time, true) end)
  print(string.format("instructions: idle %d, scan %d, write %d, scan of 64 lines %d",
    idle, scanN, write, big))
  check(idle < 100, "cpu: idle tick < 100 (" .. idle .. ")")
  check(scanN < 1500, "cpu: scan tick < 1500 (" .. scanN .. ")")
  check(write < 4000, "cpu: write tick < 4000 (" .. write .. ")")
  check(big < 4000, "cpu: scan of 64 lines < 4000 (" .. big .. ")")
end

---------------------------------------------------------------- result

print(string.format("thrcap: %d checks passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
