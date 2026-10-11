-- tests/run.lua : scenario tests for the FPVDASH LVGL widget (desktop Lua 5.5)
--
--   cd "<root>" && lua tests/run.lua                 all FPVDASH scenarios
--   lua tests/run.lua --only a,b-rc1                 some scenarios
--   lua tests/run.lua --selftest                     harness self-test (dummy widget)
--   lua tests/run.lua --list                         list scenario ids
--   options: --mode rc1|v212x (default firmware behaviour), --verbose,
--            --sd <SD card copy> (default "<root>/radio sd card"), --widget /WIDGETS/<DIR>/
--
-- Exit code 0 only when every selected scenario passes.
-- Outputs: tests/out/report.txt, tests/out/<scenario>*.svg|.txt|.json, *_crsf.log
--
-- Harness files must not use string method syntax (the mock traps it).

local function scriptDir()
  local src = string.gsub(debug.getinfo(1, "S").source, "^@", "")
  if string.sub(src, 1, 1) ~= "/" then src = (os.getenv("PWD") or ".") .. "/" .. src end
  return string.match(src, "^(.*)/[^/]*$") or "."
end
local TESTS = scriptDir()
local Mock = dofile(TESTS .. "/edgetx_mock.lua")
local Fake = dofile(TESTS .. "/fake_elrs.lua")
local C = Mock.C
local floor = math.floor
local sformat = string.format

---------------------------------------------------------------------------
-- command line
---------------------------------------------------------------------------

local ARGS = { only = nil, selftest = false, mode = "rc1", verbose = false, list = false }
do
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--selftest" then ARGS.selftest = true
    elseif a == "--verbose" or a == "-v" then ARGS.verbose = true
    elseif a == "--list" then ARGS.list = true
    elseif a == "--only" then
      i = i + 1
      ARGS.only = {}
      for id in string.gmatch(arg[i] or "", "[^,]+") do ARGS.only[id] = true end
    elseif a == "--mode" then
      i = i + 1
      ARGS.mode = arg[i]
    elseif a == "--sd" then
      i = i + 1
      ARGS.sd = arg[i]
    elseif a == "--widget" then
      i = i + 1
      ARGS.widget = arg[i]
    else
      io.stderr:write("unknown argument: " .. tostring(a) .. "\n")
      os.exit(2)
    end
    i = i + 1
  end
end
if ARGS.mode ~= "rc1" and ARGS.mode ~= "v212x" then
  io.stderr:write("unknown --mode: " .. tostring(ARGS.mode) .. " (rc1 or v212x)\n")
  os.exit(2)
end

-- a 2.12.x run writes its dumps to tests/out/v212x so it keeps the rc1 dumps
if ARGS.mode == "v212x" then Mock.OUT_DIR = Mock.OUT_DIR .. "/v212x" end
local OUT = Mock.OUT_DIR
os.execute("mkdir -p '" .. OUT .. "'")

---------------------------------------------------------------------------
-- small test framework
---------------------------------------------------------------------------

local T = {}
T.__index = T

local function newT(id, title)
  return setmetatable({ id = id, title = title, fails = {}, warns = {}, infos = {}, metrics = {}, failSeen = {},
                        dupFails = 0 }, T)
end
-- an identical failure line is listed once (it is counted in dupFails)
function T:fail(msg)
  msg = tostring(msg)
  if self.failSeen[msg] then
    self.dupFails = self.dupFails + 1
    return
  end
  self.failSeen[msg] = true
  self.fails[#self.fails + 1] = msg
end
function T:warn(msg) self.warns[#self.warns + 1] = tostring(msg) end
function T:info(msg) self.infos[#self.infos + 1] = tostring(msg) end
function T:check(cond, msg)
  if not cond then self:fail(msg) end
  return cond and true or false
end
function T:metric(k, v) self.metrics[#self.metrics + 1] = { k, v } end

local SCENARIOS = {}
local function scenario(id, title, fn)
  SCENARIOS[#SCENARIOS + 1] = { id = id, title = title, fn = fn }
end

local function fmtNum(v)
  if type(v) == "number" then
    if v == floor(v) then return sformat("%d", v) end
    return sformat("%.1f", v)
  end
  return tostring(v)
end

---------------------------------------------------------------------------
-- world setup
---------------------------------------------------------------------------

local WIDGET_DIR = ARGS.widget or "/WIDGETS/FPVDASH/"
local SD_ROOT = ARGS.sd or Mock.SD_ROOT

local STD_SENSORS = {
  { name = "1RSS", value = -45 }, { name = "2RSS", value = -48 }, { name = "RQly", value = 100 },
  { name = "RSNR", value = 9 }, { name = "ANT", value = 0 }, { name = "RFMD", value = 7 },
  { name = "TPWR", value = 250 }, { name = "TRSS", value = -50 }, { name = "TQly", value = 100 },
  { name = "TSNR", value = 8 }, { name = "FM", text = "ACRO" }, { name = "RxBt", value = 16.4, prec = 1 },
  { name = "Curr", value = 12.3, prec = 1 }, { name = "Capa", value = 850 }, { name = "Bat%", value = 76 },
  { name = "Ptch", value = 0.12, prec = 2 }, { name = "Roll", value = -0.05, prec = 2 },
  { name = "Yaw", value = 1.5, prec = 2 },
}

local function stdTelemetry(R, streaming)
  R:defineSensors(STD_SENSORS)
  R:setStreaming(streaming ~= false)
  R:setTimer(1, { mode = 1, value = 125, start = 0, name = "" })
  R:setTimer(2, { mode = 1, value = 3725, start = 0, name = "" })
  R:setTimer(3, { mode = 0, value = 0, start = 0, name = "" })
end

local DEFAULT_MODULE = { version = "4.1.0", band = 4, channel = 2, power = 1, pit = 0 }

-- o: mode, module (false = no module object), moduleOpts, crsf (false = no CRSF), stickMode,
--    streaming, sdRoot, widgetDir, lcdW, lcdH (screen size, default 480x320),
--    model (model spec for the input emulation, default the user's model "75"; false = no
--    model input API)
local function world(t, o)
  o = o or {}
  local fake = nil
  if o.module ~= false then fake = Fake.new(o.moduleOpts or DEFAULT_MODULE) end
  local R = Mock.new({ mode = o.mode or ARGS.mode, module = fake, crsf = (o.crsf ~= false),
                       stickMode = o.stickMode, sdRoot = o.sdRoot or SD_ROOT, lcdW = o.lcdW, lcdH = o.lcdH,
                       model = o.model })
  stdTelemetry(R, o.streaming)
  local wt, err = R:loadWidget(o.widgetDir or WIDGET_DIR)
  if not wt then
    t:fail("widget did not load: " .. tostring(err))
    return nil
  end
  return R, fake, wt
end

local function appOf(R, inst) return R:app(inst) end

local function visibleTexts(R, inst, withButtons)
  local list = R:texts(inst, withButtons)
  return table.concat(list, " | ")
end

-- the dashboard cap label "NN%" (TINSIZE, ui/sticks.lua); the LQ text "100%" is not one
local function capLabel(R, inst, n)
  local want = sformat("%d%%", n)
  for _, o in ipairs(R:objects(inst, "label", true)) do
    if o.props.text == want and Mock.fontIndex(o.props.font) == Mock.fontIndex(C.TINSIZE)
       and string.find(o.createdAt or "", "sticks.lua", 1, true) then
      return o
    end
  end
  return nil
end

-- state name of the visible RX battery icon (sticks region, below the top bar), or nil
local function visibleBatteryIcon(R, inst)
  for _, o in ipairs(R:objects(inst, "image", true)) do
    local st = string.match(tostring(o.props.file), "icons/battery/battery%-(%a+)%.png$")
    if st then
      local _, y = R:absRect(o)
      if y >= 46 then return st end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- contract checks (DESIGN.md sections 4 and 5)
---------------------------------------------------------------------------

local V_STATES = { off = true, nocrsf = true, search = true, noelrs = true, novtx = true, load = true,
                   ready = true, busy = true, error = true }
local V_SENDS = { idle = true, writing = true, sending = true, sent = true, queued = true,
                  notenabled = true, failed = true }
local TX_STATES = { full = true, ok = true, warn = true, low = true, dead = true }
local T_STATES = { ok = true, none = true, unsupported = true, busy = true, error = true }

local function isIntN(v) return type(v) == "number" and v == floor(v) end

-- wgt.T, the throttle cap state (DESIGN section 5.5)
local function capProblems(T, bad)
  if type(T) ~= "table" then bad("wgt.T missing (thrcap state)") return end
  if not T_STATES[T.state] then bad("T.state invalid: " .. tostring(T.state)) end
  if type(T.msg) ~= "string" then bad("T.msg must be a string")
  elseif #T.msg > 30 then bad("T.msg longer than 30 chars: " .. T.msg) end
  if not isIntN(T.cap) or T.cap < 0 or T.cap > 100 then bad("T.cap must be an integer 0..100, is " .. tostring(T.cap)) end
  if type(T.custom) ~= "boolean" then bad("T.custom must be boolean") end
  if not isIntN(T.weight) or not isIntN(T.offset) then
    bad(sformat("T.weight/T.offset must be integers, are %s/%s", tostring(T.weight), tostring(T.offset)))
  end
  if T.pending ~= nil and (not isIntN(T.pending) or T.pending < 20 or T.pending > 100) then
    bad("T.pending must be nil or an integer 20..100, is " .. tostring(T.pending))
  end
  if not isIntN(T.input) or T.input < -1 or T.input > 31 then bad("T.input must be an integer -1..31, is " .. tostring(T.input)) end
  if not isIntN(T.rev) then bad("T.rev must be an integer") end
end

local function contractProblems(app)
  local P = {}
  local function bad(m) P[#P + 1] = m end
  if type(app) ~= "table" then
    bad("create() did not return the wgt table with V/E/S fields")
    return P
  end
  local E, V, S, I = app.E, app.V, app.S, app.I
  if type(E) ~= "table" then bad("wgt.E missing") else
    if type(E.found) ~= "boolean" then bad("E.found must be boolean, is " .. type(E.found)) end
    if type(E.label) ~= "string" then bad("E.label must be a string") end
    if E.version ~= nil and type(E.version) ~= "string" then bad("E.version must be string or nil") end
    if type(E.armed) ~= "boolean" then bad("E.armed must be boolean") end
  end
  if type(V) ~= "table" then bad("wgt.V missing") else
    if not V_STATES[V.state] then bad("V.state invalid: " .. tostring(V.state)) end
    if type(V.msg) ~= "string" then bad("V.msg must be a string")
    elseif #V.msg > 30 then bad("V.msg longer than 30 chars: " .. V.msg) end
    if type(V.ready) ~= "boolean" then bad("V.ready must be boolean") end
    for _, k in ipairs({ "bandLabels", "powerLabels", "pitLabels" }) do
      if type(V[k]) ~= "table" then bad("V." .. k .. " must be a table") end
    end
    for _, k in ipairs({ "band", "channel", "power", "pit", "freq", "rev" }) do
      if not isIntN(V[k]) then bad("V." .. k .. " must be an integer, is " .. tostring(V[k])) end
    end
    if isIntN(V.channel) and (V.channel < 0 or V.channel > 8) then bad("V.channel out of 0..8: " .. V.channel) end
    if isIntN(V.band) and (V.band < 0 or V.band > 6) then bad("V.band out of 0..6: " .. V.band) end
    if type(V.bandLetter) ~= "string" then bad("V.bandLetter must be a string") end
    if not V_SENDS[V.send] then bad("V.send invalid: " .. tostring(V.send)) end
    if type(V.sendMsg) ~= "string" then bad("V.sendMsg must be a string") end
  end
  if type(S) ~= "table" then bad("wgt.S missing") else
    if type(S.connected) ~= "boolean" then bad("S.connected must be boolean") end
    if type(S.modelName) ~= "string" then bad("S.modelName must be a string") end
    if not TX_STATES[S.txState] then bad("S.txState invalid: " .. tostring(S.txState)) end
    if type(S.clock) ~= "string" then bad("S.clock must be a string") end
    if type(S.date) ~= "string" then bad("S.date must be a string") end
    if type(S.timers) ~= "table" then bad("S.timers must be a table") else
      for i = 1, 3 do
        if type(S.timers[i]) ~= "table" then bad("S.timers[" .. i .. "] must be a table") end
      end
    end
    for _, k in ipairs({ "rxV", "cells", "cellV", "lq", "rssi1", "rssi2", "rssi", "snr", "rfmd", "rateHz",
                         "tpwr", "curr", "capa", "sats", "ant", "txV" }) do
      if S[k] ~= nil and type(S[k]) ~= "number" then bad("S." .. k .. " must be number or nil") end
    end
    if type(S.gps) ~= "boolean" then bad("S.gps must be boolean") end
    if type(S.rxImplausible) ~= "boolean" then bad("S.rxImplausible must be boolean") end
    if S.fm ~= nil and type(S.fm) ~= "string" then bad("S.fm must be string or nil") end
  end
  if type(I) ~= "table" then bad("wgt.I missing") else
    if not isIntN(I.mode) or I.mode < 1 or I.mode > 4 then bad("I.mode must be 1..4") end
    for _, k in ipairs({ "left", "right" }) do
      if type(I[k]) ~= "table" or type(I[k].x) ~= "number" or type(I[k].y) ~= "number" then
        bad("I." .. k .. " must be { x = number, y = number }")
      end
    end
    if type(I.trim) ~= "table" or type(I.trimTxt) ~= "table" then bad("I.trim / I.trimTxt missing") else
      for _, k in ipairs({ "lh", "lv", "rv", "rh" }) do
        if type(I.trim[k]) ~= "number" then bad("I.trim." .. k .. " must be a number") end
        if type(I.trimTxt[k]) ~= "string" then bad("I.trimTxt." .. k .. " must be a string") end
      end
    end
    if type(I.trimExt) ~= "boolean" then bad("I.trimExt must be boolean") end
  end
  local th = app.theme
  if type(th) ~= "table" then bad("wgt.theme missing") else
    if type(th.dark) ~= "boolean" then bad("theme.dark must be boolean") end
    for _, k in ipairs({ "text", "shadow", "wash", "washOpa", "good", "warn", "bad", "muted", "accent" }) do
      if type(th[k]) ~= "number" then bad("theme." .. k .. " must be a number") end
    end
    if type(th.iconDir) ~= "string" then bad("theme.iconDir must be a string") end
  end
  capProblems(app.T, bad)
  return P
end

-- run n cycles, checking the contract every `every` cycles; returns stop result
local function runChecked(t, R, inst, n, stopFn, every)
  every = every or 20
  local seen = t.contractSeen or {}
  t.contractSeen = seen
  local done = 0
  while done < n do
    local step = math.min(every, n - done)
    local hit, k = R:cycle(step, stopFn)
    done = done + k
    if inst and not inst.dead then
      for _, p in ipairs(contractProblems(appOf(R, inst))) do
        if not seen[p] then
          seen[p] = true
          t:fail("contract: " .. p)
        end
      end
    end
    if hit then return true, done end
  end
  return false, done
end

---------------------------------------------------------------------------
-- common end-of-scenario checks
---------------------------------------------------------------------------

-- o: instrLimits = { max, avg } for refresh cycles; layout = "fail"|"warn"|nil; dumpName
local function finish(t, R, fake, o)
  o = o or {}
  for _, inst in ipairs(R.instances) do
    if inst.dead then
      local e = inst.err
      t:fail(sformat("instance #%d died in %s() at %.2f s: %s%s", inst.id, e.phase, (e.t or 0) / 1000,
        tostring(e.msg), (e.tb and e.tb ~= "") and ("\n" .. Mock.filterTb(e.tb)) or ""))
    end
  end
  for _, g in ipairs(R.globalWrites) do
    t:fail(sformat("global variable written: '%s' at %s (%s)", g.name, g.where, g.phase))
  end
  for _, l in ipairs(R.loads) do
    -- DESIGN section 8: load modules only in create (main.lua itself loads at "load")
    if l.phase ~= "create" and l.phase ~= "load" then
      t:fail("loadScript called during " .. l.phase .. ": " .. l.path .. " (load modules in create only)")
    end
  end
  local nw = 0
  for _, w in ipairs(R.warnings) do
    nw = nw + 1
    if nw <= 12 then t:warn("mock: " .. w.msg) end
  end
  if nw > 12 then t:warn(sformat("mock: ... %d more warnings", nw - 12)) end
  for _, inst in ipairs(R.instances) do
    -- FPVDASH rule: the no-argument lvgl.clear() also deletes the firmware's own children of
    -- the widget (focus border in widget-select mode, freed twice later), so it is never
    -- used after the first build. (The self-test dummy widget uses it on purpose to test
    -- the mock's clear handling, so the rule applies to the widget under test only.)
    if R.widgetPath == WIDGET_DIR then
      t:check(inst.fullClearsAfterBuild == 0, sformat("instance #%d: %d no-argument lvgl.clear() calls after the "
        .. "first build (use root boxes and lvgl.clear(box))", inst.id, inst.fullClearsAfterBuild))
    end
    -- a visible clickable object outside full screen takes the long press (the mock checks it at
    -- the end of every cycle in which the instance is shown and not full screen)
    for _, c in ipairs(inst.clickIssues or {}) do
      t:fail(sformat("instance #%d: %s", inst.id, c.msg))
    end
    if (inst.clickCycles or 0) > 0 then
      t:metric(sformat("inst%d cycles with a visible clickable object outside full screen", inst.id), inst.clickCycles)
    end
    -- a pressed control that a finger cannot reach (an object above it takes the tap: the mock
    -- does an LVGL-order hit test at the centre of every pressed control)
    for _, c in ipairs(inst.touchIssues or {}) do
      t:fail(sformat("instance #%d: %s", inst.id, c.msg))
    end
    t:metric(sformat("inst%d LVGL objects created / wrappers leaked by clears", inst.id),
      sformat("%d / %d", inst.created, inst.leaked))
    local s = R:instrStats(inst, "refresh")
    local u = R:instrStats(inst, "update")
    local b = R:instrStats(inst, "background")
    local cb = R:instrStats(inst, "callback")
    t:metric(sformat("inst%d refresh instr max/avg (n)", inst.id), sformat("%d / %d (%d)", s.max, floor(s.avg + 0.5), s.n))
    if u.n > 0 then t:metric(sformat("inst%d update instr max (n)", inst.id), sformat("%d (%d)", u.max, u.n)) end
    if b.n > 0 then t:metric(sformat("inst%d background instr max/avg (n)", inst.id), sformat("%d / %d (%d)", b.max, floor(b.avg + 0.5), b.n)) end
    if cb.n > 0 then t:metric(sformat("inst%d callback instr max", inst.id), cb.max) end
    if o.instrLimits and s.n > 0 then
      local lim = o.instrLimits
      t:check(s.max < lim[1], sformat("instance #%d: max instructions per refresh cycle %d >= %d", inst.id, s.max, lim[1]))
      t:check(s.avg < lim[2], sformat("instance #%d: average instructions per refresh cycle %d >= %d", inst.id, floor(s.avg), lim[2]))
    end
    if b.n > 0 and b.max >= 14000 then
      t:fail(sformat("instance #%d: background() used %d instructions (>= 14000)", inst.id, b.max))
    end
  end
  if fake then
    for _, v in ipairs(fake.violations) do
      if not (o.allowViolations and o.allowViolations(v.msg)) then
        t:fail(sformat("ELRS protocol: %s (t=%.2f s)", v.msg, v.t / 1000))
      end
    end
    t:metric("module frames received / sent", sformat("%d / %d", fake.stats.rx, fake.stats.tx))
  end
  t:metric("crossfire push calls (ok/busy/nil/probe) / pop calls",
    sformat("%d (%d/%d/%d/%d) / %d", R.crsf.pushCalls, R.crsf.pushOk, R.crsf.pushBusy, R.crsf.pushNil, R.crsf.probes, R.crsf.popCalls))
  -- model input writes (throttle cap): glitch-free, only from refresh(), integers, one swap per call
  local md = R.mdl
  if md then
    for _, g in ipairs(md.glitches) do t:fail(g.msg) end
    if md.nGlitches > #md.glitches then t:fail(sformat("... %d more mixer glitches", md.nGlitches - #md.glitches)) end
    for i, b in ipairs(md.badWrites) do
      if i <= 5 then t:fail(sformat("%s [at %s, %.2f s]", b.msg, b.where, b.t / 1000)) end
    end
    if #md.badWrites > 5 then t:fail(sformat("... %d more model writes outside refresh()", #md.badWrites - 5)) end
    for i, f in ipairs(md.floatArgs) do
      if i <= 5 then
        t:fail(sformat("model.%s got the float %s (integers only; the radio floors it) [at %s]", f.what, tostring(f.v), f.where))
      end
    end
    for i, m in ipairs(md.multi) do
      if i <= 5 then t:fail(sformat("%s [at %s, %.2f s]", m.msg, m.where, m.t / 1000)) end
    end
    if #md.writes > 0 then
      local ins = 0
      for _, w in ipairs(md.writes) do if w.call == "insertInput" then ins = ins + 1 end end
      t:metric("model input writes: calls / swaps (insertInput)", sformat("%d / %d", #md.writes, ins))
    end
  end
  if o.dumpName and R.instances[1] then
    local inst = R.instances[1]
    local p = R:dump(inst, o.dumpName)
    t:info("layout dump: " .. p)
  end
  if fake and o.dumpName then
    Mock.writeFile(OUT .. "/" .. o.dumpName .. "_crsf.log", fake:logText())
  end
end

local function layoutReport(t, R, inst, mode, tag)
  local res = R:layoutCheck(inst)
  local n = 0
  for _, r in ipairs(res) do
    n = n + 1
    local msg = (tag and (tag .. ": ") or "") .. "layout: " .. r.msg
    if r.severe and mode == "fail" then t:fail(msg) elseif n <= 15 then t:warn(msg) end
  end
  if n > 15 then t:warn(sformat("layout: ... %d more", n - 15)) end
  return res
end

---------------------------------------------------------------------------
-- VTX page helpers
---------------------------------------------------------------------------

local BAND_SET = { A = true, B = true, E = true, F = true, R = true, L = true }

local function firstToken(text)
  local s = string.gsub(text or "", "^%s+", "")
  return string.match(s, "^(%S+)") or ""
end

local function pageButtons(R, inst)
  local list = {}
  for _, o in ipairs(R:buttons(inst, true)) do
    local x, y, w, h = R:absRect(o)
    list[#list + 1] = { o = o, text = o.props.text or "", tok = firstToken(o.props.text), x = x, y = y, w = w,
                        h = h, cy = y + h / 2 }
  end
  return list
end

local function describeButtons(list)
  local t = {}
  for _, b in ipairs(list) do
    t[#t + 1] = sformat("%q@(%d,%d %dx%d)", b.text, b.x, b.y, b.w, b.h)
  end
  return table.concat(t, ", ")
end

local function digitOf(tok)
  local d = string.match(tok, "^[Pp]?(%d)$") or string.match(tok, "^[Cc][Hh]?(%d)$")
  return d and tonumber(d) or nil
end

-- classify the buttons of the VTX page into rows
local function classify(R, inst)
  local list = pageButtons(R, inst)
  local rows = {}
  for _, b in ipairs(list) do
    local row = nil
    for _, r in ipairs(rows) do
      if math.abs(r.cy - b.cy) <= 4 then row = r break end
    end
    if not row then
      row = { cy = b.cy, items = {} }
      rows[#rows + 1] = row
    end
    row.items[#row.items + 1] = b
  end
  table.sort(rows, function(a, b) return a.cy < b.cy end)
  local res = { list = list, band = {}, channel = {}, power = {}, all = describeButtons(list) }
  local bandRow, digitRows = nil, {}
  for _, r in ipairs(rows) do
    local letters, digits, keep = 0, 0, false
    for _, b in ipairs(r.items) do
      if BAND_SET[b.tok] then letters = letters + 1 end
      if digitOf(b.tok) then digits = digits + 1 end
      local lt = string.lower(b.tok)
      if b.tok == "-" or lt == "keep" then keep = true end
    end
    r.keep = keep
    if letters >= 3 and not bandRow then bandRow = r end
    if digits >= 4 or (keep and digits >= 1) then digitRows[#digitRows + 1] = r end
  end
  if bandRow then
    for _, b in ipairs(bandRow.items) do
      if BAND_SET[b.tok] then res.band[b.tok] = b end
      if string.lower(b.tok) == "off" or string.lower(b.tok) == "disabled" then res.band.Off = b end
    end
  end
  local chRow, pwRow
  if #digitRows >= 2 then
    for _, r in ipairs(digitRows) do
      if r.keep and not pwRow then pwRow = r end
    end
    for _, r in ipairs(digitRows) do
      if r ~= pwRow and not chRow then chRow = r end
    end
    if not pwRow then pwRow = digitRows[2] end
  elseif #digitRows == 1 then
    if digitRows[1].keep then pwRow = digitRows[1] else chRow = digitRows[1] end
  end
  if chRow then
    for _, b in ipairs(chRow.items) do
      local d = digitOf(b.tok)
      if d then res.channel[d] = b end
    end
  end
  if pwRow then
    for _, b in ipairs(pwRow.items) do
      local d = digitOf(b.tok)
      if d then res.power[tostring(d)] = b end
      if b.tok == "-" or string.lower(b.tok) == "keep" then res.power["-"] = b end
    end
  end
  for _, b in ipairs(list) do
    local lt = string.lower(b.text)
    if string.find(lt, "apply", 1, true) or (string.find(lt, "send", 1, true) and not res.apply) then res.apply = res.apply or b end
    if string.find(lt, "back", 1, true) or b.tok == "<" then res.back = b end
    if string.find(lt, "reload", 1, true) then res.reload = b end
    if string.find(lt, "pit", 1, true) then res.pit = b end
  end
  return res
end

local function press(t, R, inst, b, what)
  if not b then
    t:fail("button not found: " .. what)
    return false
  end
  local ok, why = R:press(inst, b.o or b)
  if not ok then t:fail("cannot press " .. what .. ": " .. tostring(why)) end
  return ok
end

-- enter the page, select band/channel/power, Apply & Send, verify the module
-- want = { band = "R", channel = 4, power = "2" } (any can be nil = keep)
local function pageApply(t, R, fake, inst, want, tag)
  local app = appOf(R, inst)
  R:enterFullScreen(inst)
  R:cycle(4)
  if inst.dead then return false end
  t:check(inst.fullscreen, "instance not in full screen after enterFullScreen")
  local B = classify(R, inst)
  R:dump(inst, tag .. "_page")
  t:info("page buttons: " .. B.all)
  local ok = true
  for _, l in ipairs({ "A", "B", "E", "F", "R", "L" }) do
    if not B.band[l] then ok = false end
  end
  t:check(ok, "page: band buttons A B E F R L not all found; buttons: " .. B.all)
  local nch = 0
  for i = 1, 8 do if B.channel[i] then nch = nch + 1 end end
  t:check(nch == 8, "page: channel buttons 1..8 not all found (" .. nch .. "); buttons: " .. B.all)
  if app and app.V and #app.V.powerLabels > 0 then
    t:check(B.power["2"] ~= nil, "page: power buttons not found; buttons: " .. B.all)
  end
  t:check(B.apply ~= nil, "page: 'Apply & Send' button not found")
  t:check(B.back ~= nil, "page: 'Back' button not found")
  for _, b in ipairs(B.list) do
    t:check(b.text ~= "" and not string.find(b.text, "nil", 1, true), "page: button with bad text " .. sformat("%q", b.text))
    if b.w < 40 or b.h < 30 then t:warn(sformat("page: small button %q %dx%d (DESIGN: >= 40x34)", b.text, b.w, b.h)) end
  end
  if B.apply then
    t:check(string.find(string.lower(B.apply.text), "apply", 1, true) ~= nil,
      "page: apply button text at idle should say 'Apply & Send', is " .. sformat("%q", B.apply.text))
  end
  if not B.apply then return false end
  local writes0 = fake and fake.stats.valueWrites or 0
  if want.band then press(t, R, inst, B.band[want.band], "band " .. want.band); R:cycle(1) end
  if want.channel then press(t, R, inst, B.channel[want.channel], "channel " .. want.channel); R:cycle(1) end
  if want.power then press(t, R, inst, B.power[want.power], "power " .. want.power); R:cycle(1) end
  R:cycle(2)
  if fake then
    t:check(fake.stats.valueWrites == writes0, "page: selecting buttons wrote to the module before Apply")
  end
  local Bn = classify(R, inst)
  press(t, R, inst, Bn.apply or B.apply, "Apply & Send")
  return true
end

-- wait for the send to finish; record apply-button texts on the way
local function waitSend(t, R, fake, inst, maxMs)
  local app = appOf(R, inst)
  local texts, seen = {}, {}
  local function stop()
    local B = classify(R, inst)
    if B.apply and not seen[B.apply.text] then
      seen[B.apply.text] = true
      texts[#texts + 1] = B.apply.text
    end
    return fake.vtx.sends >= 1 and app and app.V and (app.V.send == "sent" or app.V.send == "queued")
  end
  local hit, ms = R:runUntil(maxMs, stop)
  t:info("apply button texts seen: " .. table.concat(texts, " -> "))
  return hit, ms, texts
end

---------------------------------------------------------------------------
-- FPVDASH scenarios
---------------------------------------------------------------------------

local function stdCreate(R, o)
  o = o or {}
  return R:createInstance({ w = o.w or 480, h = o.h or 320, appMode = (o.appMode ~= false), visible = (o.visible ~= false),
                            options = o.options })
end

scenario("static", "widget table, options, files and source lint", function(t)
  local R = Mock.new({ mode = ARGS.mode, sdRoot = SD_ROOT })
  local mainPath = SD_ROOT .. string.sub(WIDGET_DIR, 1) .. "main.lua"
  local src = Mock.readFile(mainPath)
  if not t:check(src ~= nil, "main.lua not found: " .. mainPath) then return end
  t:check(#src < 3072, sformat("main.lua is %d bytes (DESIGN: < 3 KB)", #src))
  local wt, err = R:loadWidget(WIDGET_DIR)
  if not t:check(wt ~= nil, "widget did not load: " .. tostring(err)) then return end
  t:metric("main.lua load instructions", R.loadCount or 0)
  t:check(wt.name == "Telemetry Dashboard", "widget name must stay 'Telemetry Dashboard', is " .. tostring(wt.name))
  t:check(wt.useLvgl == true, "useLvgl must be true (current: " .. tostring(wt.useLvgl) .. ")")
  for _, k in ipairs({ "create", "update", "refresh" }) do
    t:check(type(wt[k]) == "function", k .. " must be a function (rc1 needs update and refresh)")
  end
  if type(wt.background) ~= "function" then t:warn("no background function") end
  local o = wt.options or {}
  local function opt(i, name, typ, def)
    local e = o[i]
    if not t:check(type(e) == "table", sformat("option %d (%s) missing", i, name)) then return end
    t:check(e[1] == name, sformat("option %d name must be %q, is %q", i, name, tostring(e[1])))
    t:check(e[2] == typ, sformat("option %d (%s) type must be %d, is %s", i, name, typ, tostring(e[2])))
    t:check(e[3] == def, sformat("option %d (%s) default must be %s, is %s", i, name, tostring(def), tostring(e[3])))
    return e
  end
  opt(1, "darkTheme", C.BOOL, 1)
  local tl = opt(2, "transpLevel", C.CHOICE, 1)
  if tl then
    local ch = tl[4]
    t:check(type(ch) == "table" and ch[1] == "1" and ch[4] == "4" and #ch == 4,
      "option 2 (transpLevel) choices must be {\"1\",\"2\",\"3\",\"4\"}")
  end
  opt(3, "vtxOff", C.BOOL, 0)
  opt(4, "hideTrims", C.BOOL, 0)
  local rc = opt(5, "rxCells", C.VALUE, 0)
  if rc then t:check(rc[4] == 0 and rc[5] == 14, "option 5 (rxCells) range must be 0..14") end
  local et = opt(6, "extTrims", C.VALUE, 0)
  if et then t:check(et[4] == 0 and et[5] == 2, "option 6 (extTrims) range must be 0..2") end
  opt(7, "trailOff", C.BOOL, 0)
  opt(8, "showFps", C.BOOL, 0)
  t:check(#o == 8, "8 options expected, found " .. #o)
  -- A model saved with an older widget stores only options 0 and 1; EdgeTX loads every
  -- other option as 0 (WidgetFactory::create with init = false does not parse the
  -- defaults). So 0 must be the normal value of every option after index 1.
  for i = 3, #o do
    local e = o[i]
    if type(e) == "table" then
      t:check(e[3] == 0, sformat("option %d (%s): default must be 0 (existing models load it as 0), is %s",
        i, tostring(e[1]), tostring(e[3])))
    end
  end
  for _, l in ipairs(R.loads) do
    if l.phase == "load" and not string.find(l.path, "main.lua$") then
      t:fail("loadScript at radio start (main.lua top level): " .. l.path .. " (load modules in create)")
    end
  end
  for _, g in ipairs(R.globalWrites) do t:fail("global written at load: " .. g.name .. " at " .. g.where) end
  -- files
  local dir = SD_ROOT .. WIDGET_DIR
  local need = { "app.lua", "lib/telem.lua", "lib/inputs.lua", "lib/crsf.lua", "lib/elrs.lua", "lib/vtx.lua",
                 "lib/thrcap.lua", "ui/theme.lua", "ui/layout.lua", "ui/dash.lua", "ui/topbar.lua", "ui/sticks.lua",
                 "ui/grid.lua", "ui/timers.lua", "ui/footer.lua", "ui/vtxpage.lua", "ui/thrpage.lua" }
  local missing = {}
  for _, f in ipairs(need) do
    if not Mock.fileExists(dir .. f) then missing[#missing + 1] = f end
  end
  t:check(#missing == 0, "files missing (DESIGN section 3): " .. table.concat(missing, ", "))
  -- lint
  local p = io.popen("find '" .. dir .. "' -name '*.lua' -type f 2>/dev/null")
  local files = {}
  if p then
    for line in p:lines() do files[#files + 1] = line end
    p:close()
  end
  table.sort(files)
  local luac = io.popen("find '" .. dir .. "' -name '*.luac' -type f 2>/dev/null | wc -l")
  local nluac = luac and tonumber(string.match(luac:read("a") or "", "%d+")) or 0
  if luac then luac:close() end
  if nluac > 0 then t:warn(nluac .. " .luac files in the widget folder (stale .luac can shadow edited .lua; delete them)") end
  for _, old in ipairs({ "layout/layout.lua", "render/topbar.lua", "telemetry/read.lua" }) do
    if Mock.fileExists(dir .. old) then
      t:warn("old file still present: " .. old .. " (removed at integration)")
    end
  end
  local LINT = {
    { ":sub%(", "string method syntax :sub(" }, { ":format%(", "string method syntax :format(" },
    { ":match%(", "string method syntax :match(" }, { ":gsub%(", "string method syntax :gsub(" },
    { ":gmatch%(", "string method syntax :gmatch(" }, { ":find%(", "string method syntax :find(" },
    { ":len%(", "string method syntax :len(" }, { ":upper%(", "string method syntax :upper(" },
    { ":lower%(", "string method syntax :lower(" }, { ":rep%(", "string method syntax :rep(" },
    { ":byte%(", "string method syntax :byte(" },
    { "lvgl%.CHOICE", "lvgl.CHOICE (absent on rc1)" }, { "lvgl%.CHOIDE", "lvgl.CHOIDE (rc1 typo constant)" },
    { "[%s{,]floating%s*=", "property 'floating' (not on rc1)" }, { "[%s{,]borderPad%s*=", "property 'borderPad' (not on rc1)" },
    { "XLSIZE", "XLSIZE (nil on rc1)" }, { "<const>", "Lua 5.4 <const>" }, { "<close>", "Lua 5.4 <close>" },
    { "[^%.%w_]unpack%(", "global unpack (use table.unpack)", "local%s+unpack%s*=" }, { "loadstring", "loadstring (absent)" },
    { "[^%w_]debug%.", "debug library (absent)" }, { "[^%w_]os%.", "os library (absent)" },
    { "[^%w_]require%(", "require (use loadScript)" },
    { "color%s*=%s*0x%x%x%x%x[^%x]", "raw RGB565 color literal" },
    { "[%s{,]edited%s*=", "property 'edited' (not on rc1)" },
  }
  local oldFiles = 0
  for _, f in ipairs(files) do
    local s = Mock.readFile(f) or ""
    local rel = string.match(f, "(WIDGETS/.*)$") or f
    local sub = string.sub(rel, #WIDGET_DIR)
    local own = (sub == "main.lua" or sub == "app.lua" or string.match(sub, "^lib/") ~= nil or string.match(sub, "^ui/") ~= nil)
    if not own then oldFiles = oldFiles + 1 end
    local ln = 0
    for line in string.gmatch(s .. "\n", "([^\n]*)\n") do
      ln = ln + 1
      local code = string.gsub(line, "%-%-.*$", "")
      for _, rule in ipairs(LINT) do
        if string.find(" " .. code, rule[1]) and not (rule[3] and string.find(s, rule[3])) then
          if own then t:fail(sformat("lint %s:%d: %s", rel, ln, rule[2]))
          else t:warn(sformat("lint (file outside DESIGN, not checked strictly) %s:%d: %s", rel, ln, rule[2])) end
        end
      end
    end
    local chunk, cerr = load(s, "@" .. rel, "t", {})
    if not chunk then t:fail("compile error: " .. tostring(cerr)) end
  end
  t:metric("widget .lua files", #files)
  if oldFiles > 0 then t:warn(oldFiles .. " .lua files outside main.lua/app.lua/lib/ui (old implementation?)") end
end)

-- (a) App mode dashboard, ELRS 4.1, connected
scenario("a", "App mode 480x320 dashboard, ELRS 4.1, telemetry connected, 300 cycles", function(t)
  local R, fake = world(t, {})
  if not R then return end
  local inst = stdCreate(R)
  if inst.dead then finish(t, R, fake, {}) return end
  local app = appOf(R, inst)
  if not t:check(app ~= nil, "create() did not return a wgt with V/E/S (visible texts: " .. visibleTexts(R, inst) .. ")") then
    finish(t, R, fake, { dumpName = "a_dashboard" })
    return
  end
  local shownAt = nil
  local function stop()
    if not shownAt and R:findText(inst, "F2", false) then shownAt = R.clock end
    return false
  end
  local ready0 = nil
  local framesAfterReady = 0
  local rxAtReady = nil
  for i = 1, 300 do
    runChecked(t, R, inst, 1, stop, 20)
    if inst.dead then break end
    if not ready0 and app.V and app.V.ready then
      ready0 = R.clock
      rxAtReady = fake.stats.rx
    end
  end
  local startMs = 5000
  if shownAt then
    t:metric("VTX cell shows F2 after", sformat("%.2f s", (shownAt - startMs) / 1000))
    t:check(shownAt - startMs <= 4000, sformat("VTX cell showed 'F2' only after %.2f s (expected <= ~3 s)", (shownAt - startMs) / 1000))
  else
    t:fail("VTX cell never showed the module band/channel 'F2' (visible texts: " .. visibleTexts(R, inst) .. ")")
  end
  if app.V then
    t:check(app.V.ready == true, "V.ready not true after 15 s (state " .. tostring(app.V.state) .. ", msg " .. tostring(app.V.msg) .. ")")
    t:check(app.V.band == 4 and app.V.channel == 2, sformat("V.band/channel = %s/%s, module has 4/2", tostring(app.V.band), tostring(app.V.channel)))
    t:check(app.V.bandLetter == "F", "V.bandLetter should be F, is " .. tostring(app.V.bandLetter))
    t:check(app.V.freq == 5760, "V.freq should be 5760, is " .. tostring(app.V.freq))
    t:check(app.V.power == 1, "V.power should be 1, is " .. tostring(app.V.power))
    t:check(type(app.V.bandLabels) == "table" and app.V.bandLabels[1] == "Disabled" and app.V.bandLabels[6] == "R",
      "V.bandLabels should be the module labels {Disabled,A,B,E,F,R,L}")
  end
  if ready0 then
    t:metric("V.ready after", sformat("%.2f s", (ready0 - startMs) / 1000))
    framesAfterReady = fake.stats.rx - rxAtReady
    local idleSec = (R.clock - ready0) / 1000
    t:metric("frames sent after ready (idle dashboard)", sformat("%d in %.1f s", framesAfterReady, idleSec))
    t:check(framesAfterReady <= math.max(1, math.ceil(idleSec / 15)) + 1,
      sformat("idle dashboard sent %d frames in %.1f s (DESIGN: <= 1 frame per 15 s)", framesAfterReady, idleSec))
  end
  if app.E then
    t:check(app.E.found == true, "E.found should be true")
    t:check(app.E.version == "4.1.0", "E.version should be 4.1.0, is " .. tostring(app.E.version))
    t:check(type(app.E.label) == "string" and string.find(app.E.label, "4.1.0", 1, true) ~= nil,
      "E.label should contain 4.1.0: " .. tostring(app.E.label))
    t:check(R:findText(inst, "4%.1%.0") ~= nil, "footer should show the ELRS version 4.1.0")
  end
  t:check(R:findText(inst, "2%.12") ~= nil, "footer should show the EdgeTX version (2.12...)")
  t:check(R:findText(inst, "^75$") ~= nil, "model name '75' should be visible")
  local S = app.S
  if S then
    t:check(S.connected == true, "S.connected should be true")
    t:check(S.lq == 100, "S.lq should be 100, is " .. tostring(S.lq))
    t:check(S.rssi == -45, "S.rssi should be -45 (best of 1RSS/2RSS), is " .. tostring(S.rssi))
    t:check(S.snr == 9, "S.snr should be 9, is " .. tostring(S.snr))
    t:check(S.tpwr == 250, "S.tpwr should be 250, is " .. tostring(S.tpwr))
    t:check(S.capa == 850, "S.capa should be 850, is " .. tostring(S.capa))
    t:check(type(S.curr) == "number" and math.abs(S.curr - 12.3) < 0.05, "S.curr should be 12.3, is " .. tostring(S.curr))
    t:check(type(S.rxV) == "number" and math.abs(S.rxV - 16.4) < 0.05, "S.rxV should be 16.4, is " .. tostring(S.rxV))
    -- the default world flies at 12.3 A: never at rest, so no cell count (lib/telem.lua)
    t:check(S.cells == nil, "S.cells should be nil under load (12.3 A, no rest), is " .. tostring(S.cells))
    t:check(S.cellV == nil, "S.cellV should be nil without a cell count, is " .. tostring(S.cellV))
    t:check(R:findText(inst, "^16%.40V$") ~= nil, "the dashboard should show the total RX voltage 16.40V")
    t:check(visibleBatteryIcon(R, inst) == "none", "without a cell count the RX battery icon should be the neutral one, is "
      .. tostring(visibleBatteryIcon(R, inst)))
    -- landed (0.3 A): the widget started with this pack in use (Capa 850 mAh), so its
    -- voltage cannot give the count (lib/telem.lua: a used pack of unknown history)
    R:setSensor("Curr", 0.3)
    runChecked(t, R, inst, 80)
    t:check(S.cells == nil, "a pack found in use (Capa 850) should get no count at rest, is " .. tostring(S.cells))
    t:check(R:findText(inst, "^16%.40V$") ~= nil, "a pack found in use: the dashboard should show the total voltage 16.40V")
    -- a pack change (the link is lost for 6 s, the FC starts again: Capa 0): after the 3 s
    -- rest window the count latches 4S for 16.4 V
    R:setStreaming(false)
    R:setSensor("RQly", 0); R:setSensor("TPWR", 0); R:setSensor("RFMD", 0)
    runChecked(t, R, inst, 120)
    R:setStreaming(true)
    R:setSensor("RQly", 100); R:setSensor("TPWR", 250); R:setSensor("RFMD", 7)
    R:setSensor("RxBt", 16.4); R:setSensor("Curr", 0.3); R:setSensor("Capa", 0)
    runChecked(t, R, inst, 80)
    t:check(S.cells == 4, "S.cells should latch to 4 for 16.4 V at rest, is " .. tostring(S.cells))
    t:check(type(S.cellV) == "number" and math.abs(S.cellV - 4.1) < 0.02, "S.cellV should be 4.1, is " .. tostring(S.cellV))
    t:check(R:findText(inst, "^4%.10V ?%(4S%)$") ~= nil, "at rest the dashboard should show 4.10V (4S)")
    t:check(visibleBatteryIcon(R, inst) == "full", "4.10 V per cell should show the full RX battery icon, is "
      .. tostring(visibleBatteryIcon(R, inst)))
    t:check(type(S.curr) == "number" and math.abs(S.curr - 0.3) < 0.05, "S.curr should be 0.3 at rest, is " .. tostring(S.curr))
    t:check(S.fm == "ACRO", "S.fm should be ACRO, is " .. tostring(S.fm))
    t:check(S.gps == false and S.sats == nil, "no GPS sensor: S.gps false, S.sats nil")
    t:check(S.modelName == "75", "S.modelName should be 75, is " .. tostring(S.modelName))
    if type(S.timers) == "table" and type(S.timers[1]) == "table" then
      t:check(S.timers[1].sec == 125, "S.timers[1].sec should be 125, is " .. tostring(S.timers[1].sec))
      t:check(S.timers[2] and S.timers[2].sec == 3725, "S.timers[2].sec should be 3725")
      t:check(S.timers[3] and S.timers[3].sec == nil, "S.timers[3].sec should be nil (timer 3 unused)")
    end
    t:check(type(S.clock) == "string" and string.match(S.clock, "^%d%d:%d%d$") ~= nil, "S.clock should be HH:MM, is " .. tostring(S.clock))
    t:check(S.date == "2 Oct", "S.date should be '2 Oct', is " .. tostring(S.date))
  end
  t:check(R:findText(inst, "02:05") ~= nil, "timer 1 should show 02:05")
  t:check(R:findText(inst, "1:02:05") ~= nil, "timer 2 should show 1:02:05")
  t:check(R:findText(inst, "%-%-:%-%-") ~= nil, "timer 3 (unused) should show --:--")
  for _, s in ipairs(R:texts(inst, true)) do
    if string.find(s, "nil", 1, true) or string.find(s, "nan", 1, true) or string.find(s, "inf", 1, true) then
      t:fail("visible text contains nil/nan/inf: " .. sformat("%q", s))
    end
  end
  -- module table from DESIGN section 4
  local mods = app.mods
  if t:check(type(mods) == "table", "wgt.mods missing (DESIGN section 4)") then
    local need = { telem = { "new", "read" }, inputs = { "new", "read" }, crsf = { "new", "beginTick" },
                   elrs = { "new", "tick" }, vtx = { "new", "tick", "apply", "reload", "freqOf" },
                   thrcap = { "new", "tick", "request" }, theme = { "resolve" }, layout = { "pageHeader" },
                   dash = { "build" }, vtxpage = { "build", "controls" }, thrpage = { "build", "controls", "header" } }
    for m, fns in pairs(need) do
      if t:check(type(mods[m]) == "table", "wgt.mods." .. m .. " missing") then
        for _, f in ipairs(fns) do
          t:check(type(mods[m][f]) == "function", sformat("%s.%s missing", m, f))
        end
      end
    end
    if type(mods.vtx) == "table" and type(mods.vtx.freqOf) == "function" then
      local ok, a, b, c = pcall(function() return mods.vtx.freqOf("R", 4), mods.vtx.freqOf("F", 2), mods.vtx.freqOf("X", 1) end)
      t:check(ok and a == 5769 and b == 5760 and c == 0, sformat("vtx.freqOf R4/F2/X1 = %s/%s/%s (expected 5769/5760/0)",
        tostring(a), tostring(b), tostring(c)))
    end
    if type(mods.thrcap) == "table" then
      t:check(mods.thrcap.MIN == 20 and mods.thrcap.MAX == 100, sformat("thrcap.MIN/MAX should be 20/100, are %s/%s",
        tostring(mods.thrcap.MIN), tostring(mods.thrcap.MAX)))
    end
  end
  -- the user's model "75": throttle input 3 = 75 / -25, cap 75 % read, line on the dashboard
  if app.T then
    t:check(app.T.state == "ok" and app.T.cap == 75 and app.T.input == 2 and app.T.custom == false,
      sformat("wgt.T should read cap 75 from input 3 (state %s, msg %q, cap %s, input %s)", tostring(app.T.state),
        tostring(app.T.msg), tostring(app.T.cap), tostring(app.T.input)))
    t:check(capLabel(R, inst, 75) ~= nil, "the dashboard should show the cap label 75%")
  end
  t:check(R.mdl and #R.mdl.writes == 0, "the dashboard alone must never write the model")
  t:metric("objects", #inst.objects)
  t:metric("max successful pushes in one cycle", inst.maxPushPerCycle)
  layoutReport(t, R, inst, "fail")
  finish(t, R, fake, { instrLimits = { 14000, 8000 }, dumpName = "a_dashboard" })
end)

-- (b) full-screen VTX page
local function scenarioB(mode)
  return function(t)
    local R, fake = world(t, { mode = mode })
    if not R then return end
    local inst = stdCreate(R)
    local app = appOf(R, inst)
    if inst.dead or not app then
      t:fail("no usable instance (dead or no V/E/S)")
      finish(t, R, fake, {})
      return
    end
    runChecked(t, R, inst, 200, function() return app.V and app.V.ready end)
    if not t:check(app.V and app.V.ready, "V.ready not reached before entering the page") then
      finish(t, R, fake, {})
      return
    end
    local tag = "b_" .. mode
    if not pageApply(t, R, fake, inst, { band = "R", channel = 4, power = "2" }, tag) then
      finish(t, R, fake, { dumpName = tag .. "_fail" })
      return
    end
    if R:openPopup(inst) then
      t:fail("a popup opened on Apply although not armed: " .. tostring(R:openPopup(inst).title))
      R:answerPopup(inst, true)
    end
    local hit, ms = waitSend(t, R, fake, inst, 15000)
    t:check(hit, "Apply & Send did not complete within 15 s (V.send=" .. tostring(app.V.send) .. ", sends=" .. fake.vtx.sends .. ")")
    t:metric("apply -> sent", sformat("%.2f s", ms / 1000))
    runChecked(t, R, inst, 100)
    t:check(fake.cfg.band == 5, "module band should be 5 (R), is " .. fake.cfg.band)
    t:check(fake.cfg.channel == 4, "module channel should be 4, is " .. fake.cfg.channel)
    t:check(fake.cfg.power == 2, "module power should be 2, is " .. fake.cfg.power)
    t:check(fake.vtx.sends == 1, "module should have exactly 1 send, has " .. fake.vtx.sends)
    if fake.vtx.sent[1] then
      local s = fake.vtx.sent[1]
      t:check(s.band == 5 and s.channel == 4 and s.power == 2, sformat("the send used band %d ch %d pwr %d", s.band, s.channel, s.power))
    end
    t:check(app.V.band == 5 and app.V.channel == 4 and app.V.power == 2,
      sformat("V after apply: band %s ch %s pwr %s", tostring(app.V.band), tostring(app.V.channel), tostring(app.V.power)))
    t:check(app.V.freq == 5769, "V.freq should be 5769 after R4, is " .. tostring(app.V.freq))
    if not R:findText(inst, app.V.msg ~= "" and app.V.msg or "\1", false) then
      t:warn("V.msg is not shown on the page: " .. tostring(app.V.msg))
    end
    R:dump(inst, tag .. "_page_after")
    layoutReport(t, R, inst, "fail", tag .. " page")
    -- Back button
    local B = classify(R, inst)
    press(t, R, inst, B.back, "Back")
    R:cycle(3)
    t:check(not inst.fullscreen, "Back did not leave full screen")
    t:check(#R:buttons(inst, false) == 0, "buttons still exist after leaving full screen (dashboard not rebuilt): "
      .. describeButtons(pageButtons(R, inst)))
    t:check(R:findText(inst, "R4") ~= nil, "dashboard after exit should show R4 (texts: " .. visibleTexts(R, inst) .. ")")
    t:check(#R:objects(inst, "label", true) >= 8, "dashboard after exit has few visible labels")
    R:dump(inst, tag .. "_dash_after")
    -- RTN key exits too
    R:enterFullScreen(inst)
    R:cycle(3)
    R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
    R:cycle(3)
    t:check(not inst.fullscreen, "RTN (EVT_VIRTUAL_EXIT) did not leave full screen")
    t:check(#R:buttons(inst, false) == 0, "buttons remain after RTN exit")
    -- long RTN (firmware exits at once)
    R:enterFullScreen(inst)
    R:cycle(2)
    R:exitFullScreen(inst)
    R:cycle(3)
    t:check(#R:buttons(inst, false) == 0, "buttons remain after long-RTN exit")
    -- App mode: repeated page visits keep the dashboard (no rebuild) and make only the
    -- page buttons again; the live object count does not grow
    R:cycle(5)
    local dashObjs = R:objects(inst, nil, true)
    local live0, leaked0, created0, clears0 = #R:objects(inst), inst.leaked, inst.created, inst.fullClearsAfterBuild
    local VISITS = 5
    local perVisit = nil
    for v = 1, VISITS do
      local c0 = inst.created
      R:enterFullScreen(inst)
      R:cycle(4)
      local nb = #R:buttons(inst, true)
      if v == 1 then perVisit = inst.created - c0 end
      t:check(nb >= 20, sformat("visit %d: page has %d visible buttons", v, nb))
      if v % 2 == 1 then
        R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
      else
        R:exitFullScreen(inst)
      end
      R:cycle(4)
      t:check(not inst.fullscreen, sformat("visit %d: full screen not left", v))
    end
    local dashKept = true
    for _, o in ipairs(dashObjs) do
      if not o.valid or o.deletedLvgl then dashKept = false end
    end
    t:check(dashKept, "the dashboard was rebuilt by a page visit (its objects should stay)")
    local leaked = inst.leaked - leaked0
    local created = inst.created - created0
    t:metric("App-mode page visit: objects made / wrappers leaked", sformat("%d / %d per visit (page buttons only)",
      perVisit or 0, leaked // VISITS))
    t:check(leaked == created, sformat("%d objects made in %d visits but %d leaked: only the page buttons may be made again",
      created, VISITS, leaked))
    t:check((perVisit or 0) <= 40, sformat("%d objects made per page visit (only the page buttons expected)", perVisit or 0))
    t:check(#R:objects(inst) == live0, sformat("live objects grew from %d to %d over %d visits", live0, #R:objects(inst), VISITS))
    t:check(inst.fullClearsAfterBuild == clears0, "no-argument lvgl.clear() during page visits")
    finish(t, R, fake, { dumpName = tag .. "_final" })
  end
end
scenario("b-rc1", "full-screen VTX page: R4 P2 Apply & Send, Back (rc1: update on exit)", scenarioB("rc1"))
scenario("b-212x", "full-screen VTX page: R4 P2 Apply & Send, Back (2.12.x: no update on exit)", scenarioB("v212x"))

-- (c) ELRS 3.3 layout, shifted ids
scenario("c", "ELRS 3.3 layout (Channel TEXT_SELECTION) with shifted ids", function(t)
  local R, fake = world(t, { moduleOpts = { version = "3.3.2", extraBefore = 2, band = 5, channel = 3, power = 1 } })
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  local hit = runChecked(t, R, inst, 160, function() return app.V and app.V.ready end)
  t:check(hit, "V.ready not reached in 8 s with ELRS 3.3 (state " .. tostring(app.V and app.V.state) .. ")")
  if app.V then
    t:check(app.V.band == 5 and app.V.bandLetter == "R", "V.band should be 5/R, is " .. tostring(app.V.band))
    t:check(app.V.channel == 3, "V.channel should be 3 (TEXT_SELECTION index 2), is " .. tostring(app.V.channel))
    t:check(app.V.bandLabels and app.V.bandLabels[1] == "Off", "V.bandLabels[1] should be 'Off' on 3.3")
    t:check(app.V.freq == 5732, "V.freq should be 5732 (R3), is " .. tostring(app.V.freq))
  end
  runChecked(t, R, inst, 20)
  t:check(R:findText(inst, "R3") ~= nil, "VTX cell should show R3 (texts: " .. visibleTexts(R, inst) .. ")")
  if pageApply(t, R, fake, inst, { channel = 6 }, "c_33") then
    local ok = waitSend(t, R, fake, inst, 15000)
    t:check(ok, "apply did not complete on 3.3")
    runChecked(t, R, inst, 60)
    t:check(fake.cfg.channel == 6, "module channel should be 6, is " .. fake.cfg.channel)
    t:check(fake.cfg.band == 5, "module band should stay 5, is " .. fake.cfg.band)
    t:check(fake.vtx.sends == 1, "module should have 1 send, has " .. fake.vtx.sends)
    t:check(app.V.channel == 6, "V.channel should be 6 after apply, is " .. tostring(app.V.channel))
  end
  finish(t, R, fake, { dumpName = "c_elrs33" })
end)

-- (d) no CRSF module
scenario("d", "no CRSF module (push returns nil)", function(t)
  local R = world(t, { module = false, crsf = false })
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, nil, {}) return end
  runChecked(t, R, inst, 200)
  if app.V then
    t:check(app.V.state == "nocrsf", "V.state should be 'nocrsf', is " .. tostring(app.V.state))
    t:check(app.V.ready == false, "V.ready should be false")
  end
  for _, s in ipairs(R:texts(inst)) do
    if string.match(s, "^[ABEFRL][1-8]") then t:fail("VTX cell shows a band/channel without CRSF: " .. s) end
  end
  local calls = R.crsf.pushCalls
  t:metric("push calls in 10 s", calls)
  t:check(calls <= 20, sformat("%d crossfireTelemetryPush calls in 10 s without CRSF (probe slowly, <= 1 per 2 s)", calls))
  if calls > 10 then t:warn(sformat("%d push calls in 10 s without CRSF (DESIGN: probe every ~2 s)", calls)) end
  -- page without link
  R:enterFullScreen(inst)
  R:cycle(5)
  local B = classify(R, inst)
  t:check(B.back ~= nil, "page without CRSF should still show Back")
  t:check(B.band.R == nil, "page without CRSF should hide the band buttons (V.ready false)")
  R:dump(inst, "d_nocrsf_page")
  if B.back then press(t, R, inst, B.back, "Back") end
  R:cycle(3)
  t:check(not inst.fullscreen, "Back did not leave full screen")
  finish(t, R, nil, { dumpName = "d_nocrsf" })
end)

-- (e) module without VTX folder
scenario("e", "ELRS module without VTX Administrator (airport build)", function(t)
  local R, fake = world(t, { moduleOpts = { version = "4.1.0", airport = true } })
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  local hit = runChecked(t, R, inst, 160, function() return app.V and app.V.state == "novtx" end)
  t:check(hit, "V.state should become 'novtx' within 8 s, is " .. tostring(app.V and app.V.state))
  local rx0 = fake.stats.rx
  runChecked(t, R, inst, 200)
  local n = fake.stats.rx - rx0
  t:metric("frames in 10 s after novtx", n)
  t:check(n <= 6, sformat("%d frames in 10 s after 'novtx' (should be nearly silent)", n))
  if not R:findText(inst, "NO VTX") then t:warn("VTX cell does not show 'NO VTX' (texts: " .. visibleTexts(R, inst) .. ")") end
  t:check(app.E and app.E.found == true, "E.found should be true (ELRS module answered)")
  finish(t, R, fake, { dumpName = "e_novtx" })
end)

-- (f) telemetry disconnected
scenario("f", "telemetry disconnected (sensors exist, no link)", function(t)
  local R, fake = world(t, { streaming = false, moduleOpts = { version = "4.1.0", band = 4, channel = 2, connected = false } })
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  runChecked(t, R, inst, 160)
  if app.S then
    t:check(app.S.connected == false, "S.connected should be false without telemetry")
    t:check(app.S.lq == nil or app.S.lq == 0, "S.lq should be nil/0 without telemetry, is " .. tostring(app.S.lq))
  end
  t:check(app.V and app.V.ready == true, "VTX values come from the TX module and should load without RX link")
  for _, s in ipairs(R:texts(inst, true)) do
    if string.find(s, "nil", 1, true) or string.find(s, "nan", 1, true) then t:fail("bad visible text: " .. s) end
  end
  layoutReport(t, R, inst, "warn")
  finish(t, R, fake, { dumpName = "f_disconnected" })
end)

-- (g) other zone sizes
scenario("g", "zones 480x272, 480x275, 430x225, 240x137", function(t)
  for _, z in ipairs({ { 480, 272 }, { 480, 275 }, { 430, 225 }, { 240, 137 } }) do
    local R, fake = world(t, {})
    if not R then return end
    local inst = R:createInstance({ w = z[1], h = z[2], appMode = false })
    runChecked(t, R, inst, 60)
    local tag = sformat("g_%dx%d", z[1], z[2])
    layoutReport(t, R, inst, "warn", tag)
    if inst.dead then
      t:fail(tag .. ": instance died: " .. tostring(inst.err.msg) .. "\n" .. Mock.filterTb(inst.err.tb))
    else
      local s = R:instrStats(inst, "refresh")
      t:metric(tag .. " refresh instr max/avg", sformat("%d / %d", s.max, floor(s.avg)))
      t:check(s.max < 14000, tag .. ": max instructions " .. s.max .. " >= 14000")
      -- objects outside the zone
      for _, o in ipairs(R:objects(inst, nil, true)) do
        local x, y, w, h = R:absRect(o)
        if (w or 0) > 0 and (x >= z[1] or y >= z[2] or x + w <= 0 or y + h <= 0) then
          t:warn(sformat("%s: %s#%d lies outside the zone (%d,%d %dx%d)", tag, o.kind, o.id, x, y, w, h))
        end
      end
    end
    for _, g in ipairs(R.globalWrites) do t:fail(tag .. ": global written: " .. g.name) end
    R:dump(inst, tag)
  end
end)

-- (h) light theme and transparency levels
scenario("h", "dark/light theme x transpLevel 1..4", function(t)
  local OPA = { 153, 119, 85, 51 }
  for _, dark in ipairs({ 1, 0 }) do
    for lvl = 1, 4 do
      local R, fake = world(t, {})
      if not R then return end
      local inst = stdCreate(R, { options = { darkTheme = dark, transpLevel = lvl } })
      runChecked(t, R, inst, 10)
      local tag = sformat("h_dark%d_t%d", dark, lvl)
      local app = appOf(R, inst)
      if inst.dead then
        t:fail(tag .. ": died: " .. tostring(inst.err.msg))
      elseif app and app.theme then
        local th = app.theme
        t:check(th.dark == (dark == 1), tag .. ": theme.dark wrong")
        t:check(th.washOpa == OPA[lvl], tag .. ": theme.washOpa should be " .. OPA[lvl] .. ", is " .. tostring(th.washOpa))
        t:check(th.text == (dark == 1 and C.WHITE or C.BLACK), tag .. ": theme.text should be " .. (dark == 1 and "WHITE" or "BLACK"))
        t:check(th.wash == (dark == 1 and C.BLACK or C.WHITE), tag .. ": theme.wash should be " .. (dark == 1 and "BLACK" or "WHITE"))
        local n = 0
        for _, o in ipairs(R:objects(inst, "rectangle", true)) do
          if o.props.filled and o.props.opacity == OPA[lvl] and o.props.color == th.wash then n = n + 1 end
        end
        t:check(n >= 4, sformat("%s: expected >= 4 wash rectangles with opacity %d, found %d", tag, OPA[lvl], n))
        if dark == 0 then
          for _, o in ipairs(R:objects(inst, "label", true)) do
            if o.props.color == C.WHITE and (o.props.text or "") ~= "" then
              -- white is allowed only for shadows in the light theme
              local shadowOk = false
              for _, p in ipairs(R:objects(inst, "label", true)) do
                if p ~= o and p.props.text == o.props.text and p.props.color ~= C.WHITE then shadowOk = true break end
              end
              if not shadowOk then t:warn(tag .. ": white text in light theme: " .. o.props.text) end
            end
          end
        end
      else
        t:fail(tag .. ": wgt.theme missing")
      end
      if lvl == 1 or lvl == 4 then R:dump(inst, tag) end
      for _, g in ipairs(R.globalWrites) do t:fail(tag .. ": global written: " .. g.name) end
    end
  end
end)

-- buttons of the Throttle page when VTX control is off (no tabs)
local THR_ONLY_BUTTONS = "Back,100%,90%,80%,75%,70%,60%,50%,-5,+5,Set"

local function buttonList(R, inst)
  local r = {}
  for _, b in ipairs(R:buttons(inst, true)) do r[#r + 1] = b.props.text or "" end
  return table.concat(r, ",")
end

-- (i) vtxOff = 1 (VTX control off)
scenario("i", "vtxOff=1: no CRSF calls at all; full screen shows only the Throttle page", function(t)
  local R, fake = world(t, {})
  if not R then return end
  local inst = stdCreate(R, { options = { vtxOff = 1 } })
  local app = appOf(R, inst)
  runChecked(t, R, inst, 100)
  R:enterFullScreen(inst)
  R:cycle(20)
  t:check(buttonList(R, inst) == THR_ONLY_BUTTONS, "vtxOff=1: full screen should show only the Throttle page ("
    .. THR_ONLY_BUTTONS .. "), buttons: " .. buttonList(R, inst))
  t:check(#R:objects(inst, "numberEdit", true) == 1, "vtxOff=1: the Throttle page should show its number input")
  R:dump(inst, "i_fullscreen")
  R:exitFullScreen(inst)
  R:cycle(20)
  -- the page texts are kept; each later visit makes and leaks only the page controls
  local leaked0, created0, live0 = inst.leaked, inst.created, #R:objects(inst)
  local VISITS = 3
  for v = 1, VISITS do
    R:enterFullScreen(inst)
    R:cycle(4)
    t:check(R:findButton(inst, "^Set$") ~= nil, sformat("vtxOff=1, visit %d: Throttle page shown", v))
    if v % 2 == 1 then R:sendEvent(inst, C.EVT_VIRTUAL_EXIT) else R:exitFullScreen(inst) end
    R:cycle(4)
    t:check(not inst.fullscreen and #R:buttons(inst, false) == 0, sformat("vtxOff=1, visit %d: buttons after the exit", v))
  end
  local made, leaked = inst.created - created0, inst.leaked - leaked0
  t:metric("vtxOff=1 page visit: objects made / leaked", sformat("%d / %d per visit", made // VISITS, leaked // VISITS))
  t:check(made == leaked, sformat("vtxOff=1: %d objects made in %d visits but %d leaked (only the page controls may be made again)",
    made, VISITS, leaked))
  t:check(made // VISITS <= 20, sformat("vtxOff=1: %d objects made per visit (only the page controls expected)", made // VISITS))
  t:check(#R:objects(inst) == live0, sformat("vtxOff=1: live objects grew from %d to %d", live0, #R:objects(inst)))
  t:check(R.crsf.pushCalls == 0, "vtxOff=1: crossfireTelemetryPush called " .. R.crsf.pushCalls .. " times")
  t:check(R.crsf.popCalls == 0, "vtxOff=1: crossfireTelemetryPop called " .. R.crsf.popCalls .. " times")
  if app and app.E then t:check(app.E.label == "ELRS", "vtxOff=1: E.label should be 'ELRS', is " .. tostring(app.E.label)) end
  t:check(R:findText(inst, "^ELRS$") ~= nil, "vtxOff=1: footer should show 'ELRS'")
  t:check(R:findText(inst, "^VTX") == nil, "vtxOff=1: no VTX cell expected")
  t:check(R:findText(inst, "%-%-:%-%-") ~= nil or R:findText(inst, "%d%d:%d%d") ~= nil, "vtxOff=1: timers should be shown")
  finish(t, R, fake, { dumpName = "i_vtxoff", instrLimits = { 14000, 8000 } })
end)

-- (j) trims and sticks
scenario("j", "trims at extremes (normal and extended), stick modes 2 and 1", function(t)
  local function near(a, b) return type(a) == "number" and math.abs(a - b) <= 1.01 end
  -- mode 2
  local R, fake = world(t, { stickMode = 2 })
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  R:setSource("rud", 1024); R:setSource("thr", -1024); R:setSource("ail", -1024); R:setSource("ele", 512)
  R:setSource("trim-rud", 1024); R:setSource("trim-ele", -1024); R:setSource("trim-thr", 0); R:setSource("trim-ail", 512)
  runChecked(t, R, inst, 10)
  if app and app.I then
    local I = app.I
    t:check(I.mode == 2, "I.mode should be 2")
    t:check(near(I.left.x, 100) and near(I.left.y, -100), sformat("mode 2 left stick (rud, thr) should be 100,-100, is %s,%s", tostring(I.left.x), tostring(I.left.y)))
    t:check(near(I.right.x, -100) and near(I.right.y, 50), sformat("mode 2 right stick (ail, ele) should be -100,50, is %s,%s", tostring(I.right.x), tostring(I.right.y)))
    t:check(near(I.trim.lh, 100), "mode 2 trim lh (rud) should be 100, is " .. tostring(I.trim.lh))
    t:check(near(I.trim.lv, 0), "mode 2 trim lv (thr) should be 0, is " .. tostring(I.trim.lv))
    t:check(near(I.trim.rv, -100), "mode 2 trim rv (ele) should be -100, is " .. tostring(I.trim.rv))
    t:check(near(I.trim.rh, 50), "mode 2 trim rh (ail) should be 50, is " .. tostring(I.trim.rh))
    t:check(I.trimTxt.lv == "", "trimTxt.lv should be '' when the trim is 0, is " .. sformat("%q", tostring(I.trimTxt.lv)))
    t:check(type(I.trimTxt.lh) == "string" and string.find(I.trimTxt.lh, "100", 1, true) ~= nil, "trimTxt.lh should show 100")
    t:check(type(I.trimTxt.rv) == "string" and string.find(I.trimTxt.rv, "-", 1, true) == nil, "trimTxt has no sign")
    t:check(I.trimExt == false, "I.trimExt should be false with normal trims")
  else
    t:fail("wgt.I missing")
  end
  layoutReport(t, R, inst, "warn", "j_mode2")
  R:dump(inst, "j_trims_mode2")
  -- extended trims
  R:setSource("trim-rud", 4096); R:setSource("trim-ail", 2048); R:setSource("trim-ele", -4096)
  runChecked(t, R, inst, 10)
  if app and app.I then
    local I = app.I
    t:check(I.trimExt == true, "I.trimExt should be true after |raw| > 1024")
    t:check(near(I.trim.lh, 100) and near(I.trim.rh, 50) and near(I.trim.rv, -100),
      sformat("extended trims: lh/rh/rv should be 100/50/-100, are %s/%s/%s", tostring(I.trim.lh), tostring(I.trim.rh), tostring(I.trim.rv)))
  end
  R:dump(inst, "j_trims_extended")
  -- extTrims option: 2 = extended from the start (a small trim is not 4 times too big),
  -- 1 = normal even after a large value was seen
  R:setSource("trim-rud", 512); R:setSource("trim-ail", 0); R:setSource("trim-ele", 0)
  R:setOptions(inst, { extTrims = 2 })
  runChecked(t, R, inst, 5)
  if app and app.I then
    t:check(app.I.trimExt == true and near(app.I.trim.lh, 12.5) and app.I.trimTxt.lh == "13",
      sformat("extTrims=2: 512 raw should be 12.5 %% / '13', is %s / %q", tostring(app.I.trim.lh), tostring(app.I.trimTxt.lh)))
  end
  R:setOptions(inst, { extTrims = 1 })
  runChecked(t, R, inst, 5)
  if app and app.I then
    t:check(app.I.trimExt == false and near(app.I.trim.lh, 50),
      sformat("extTrims=1: 512 raw should be 50 %%, is %s (trimExt %s)", tostring(app.I.trim.lh), tostring(app.I.trimExt)))
  end
  R:setOptions(inst, { extTrims = 0 })
  runChecked(t, R, inst, 5)
  if app and app.I then
    t:check(app.I.trimExt == false, "extTrims=0 after 1: auto starts again from normal trims")
  end
  finish(t, R, fake, {})
  -- mode 1
  local R1, fake1 = world(t, { stickMode = 1 })
  if not R1 then return end
  local inst1 = stdCreate(R1)
  local app1 = appOf(R1, inst1)
  R1:setSource("rud", -1024); R1:setSource("ele", 1024); R1:setSource("thr", 512); R1:setSource("ail", 1024)
  R1:setSource("trim-rud", 1024); R1:setSource("trim-ele", -512); R1:setSource("trim-thr", 256); R1:setSource("trim-ail", -1024)
  runChecked(t, R1, inst1, 10)
  if app1 and app1.I then
    local I = app1.I
    t:check(I.mode == 1, "I.mode should be 1")
    t:check(near(I.left.x, -100) and near(I.left.y, 100), sformat("mode 1 left stick (rud, ele) should be -100,100, is %s,%s", tostring(I.left.x), tostring(I.left.y)))
    t:check(near(I.right.x, 100) and near(I.right.y, 50), sformat("mode 1 right stick (ail, thr) should be 100,50, is %s,%s", tostring(I.right.x), tostring(I.right.y)))
    t:check(near(I.trim.lh, 100) and near(I.trim.lv, -50) and near(I.trim.rv, 25) and near(I.trim.rh, -100),
      sformat("mode 1 trims lh/lv/rv/rh should be 100/-50/25/-100, are %s/%s/%s/%s", tostring(I.trim.lh), tostring(I.trim.lv),
        tostring(I.trim.rv), tostring(I.trim.rh)))
  end
  layoutReport(t, R1, inst1, "warn", "j_mode1")
  -- hideTrims = 1 must not break anything
  local R2, fake2 = world(t, {})
  if R2 then
    local inst2 = stdCreate(R2, { options = { hideTrims = 1 } })
    runChecked(t, R2, inst2, 10)
    finish(t, R2, fake2, { dumpName = "j_notrims" })
  end
  finish(t, R1, fake1, { dumpName = "j_trims_mode1" })
end)

-- (k) armed: Apply asks for confirmation
scenario("k", "armed flag: Apply shows a confirm popup", function(t)
  local R, fake = world(t, { moduleOpts = { version = "4.1.0", band = 4, channel = 2, power = 1, armed = true } })
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  runChecked(t, R, inst, 200, function() return app.V and app.V.ready end)
  R:enterFullScreen(inst)
  local armedSeen = runChecked(t, R, inst, 100, function() return app.E and app.E.armed end)
  t:check(armedSeen, "E.armed did not become true within 5 s on the page (0x2E status poll)")
  local statusReq = fake.stats.statusReq
  t:metric("ELRS status requests on the page", statusReq)
  R:exitFullScreen(inst)
  R:cycle(5)
  if not pageApply(t, R, fake, inst, { channel = 5 }, "k_armed") then finish(t, R, fake, {}) return end
  R:cycle(2)
  local p = R:openPopup(inst)
  if t:check(p ~= nil and p.kind == "confirm", "no confirm popup after Apply while armed") then
    t:info("popup: " .. tostring(p.title) .. " / " .. tostring(p.message))
    local w0 = fake.stats.valueWrites
    R:answerPopup(inst, false)
    runChecked(t, R, inst, 60)
    t:check(fake.stats.valueWrites == w0 and fake.vtx.sends == 0, "cancel in the confirm popup still wrote/sent")
    local B = classify(R, inst)
    press(t, R, inst, B.apply, "Apply & Send (2nd)")
    R:cycle(2)
    p = R:openPopup(inst)
    if t:check(p ~= nil and p.kind == "confirm", "no confirm popup on the second Apply") then
      R:answerPopup(inst, true)
      local ok = waitSend(t, R, fake, inst, 15000)
      t:check(ok, "confirmed apply did not complete")
      t:check(fake.cfg.channel == 5, "module channel should be 5 after confirm, is " .. fake.cfg.channel)
      t:check(fake.vtx.sends == 1, "module should have 1 send, has " .. fake.vtx.sends)
    end
  end
  t:check(R:openPopup(inst) == nil, "a popup is still open at the end")
  finish(t, R, fake, { dumpName = "k_armed" })
end)

-- (l) two instances
scenario("l", "two widget instances (no shared-state bugs)", function(t)
  local R, fake = world(t, {})
  if not R then return end
  local A = R:createInstance({ w = 480, h = 272, appMode = false, options = { darkTheme = 1 } })
  local B = R:createInstance({ w = 240, h = 137, appMode = false, options = { darkTheme = 0 } })
  local a, b = appOf(R, A), appOf(R, B)
  if not (a and b) then t:fail("instances without V/E/S") finish(t, R, fake, {}) return end
  t:check(a ~= b and a.V ~= b.V and a.S ~= b.S and a.E ~= b.E, "two instances share their state tables")
  local hit = runChecked(t, R, A, 240, function() return a.V.ready and b.V.ready end)
  t:check(hit, sformat("both instances should load VTX values (A %s, B %s)", tostring(a.V.state), tostring(b.V.state)))
  t:check(a.theme and b.theme and a.theme.dark == true and b.theme.dark == false, "theme shared between instances")
  local appLoads = 0
  for _, l in ipairs(R.loads) do
    if string.find(l.path, "app%.lua$") then appLoads = appLoads + 1 end
  end
  t:check(appLoads == 1, sformat("app.lua loaded %d times (DESIGN: cache the chunk in main.lua)", appLoads))
  local bObjs = #B.objects
  local bRefresh0 = B.refreshes
  if pageApply(t, R, fake, A, { band = "B", channel = 7 }, "l_A") then
    local ok = waitSend(t, R, fake, A, 15000)
    t:check(ok, "apply from instance A did not complete")
    t:check(B.refreshes == bRefresh0, sformat("instance B got %d refresh() calls while A was full screen (it is covered)",
      B.refreshes - bRefresh0))
    local Bb = classify(R, A)
    press(t, R, A, Bb.back, "Back")
    R:cycle(5)
  end
  t:metric("instance B cycles covered by A's full screen", B.coveredCycles or 0)
  t:check(fake.cfg.band == 2 and fake.cfg.channel == 7, "module should be B7 after apply from A")
  t:check(not B.dead and #B.objects == bObjs, "instance B objects changed while A used its page")
  runChecked(t, R, B, 400, function() return b.V.band == 2 and b.V.channel == 7 end)
  if b.V.band ~= 2 or b.V.channel ~= 7 then t:warn("instance B did not pick up the new VTX values within 20 s") end
  R:dump(B, "l_instanceB")
  finish(t, R, fake, { dumpName = "l_instanceA" })
end)

-- (m) pause variants
local function scenarioM(variant)
  return function(t)
    local R, fake = world(t, {})
    if not R then return end
    local inst = stdCreate(R)
    local app = appOf(R, inst)
    if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
    runChecked(t, R, inst, 200, function() return app.V and app.V.ready end)
    t:check(app.V.ready, "not ready before the pause")
    local rx0 = fake.stats.rx
    if variant == "bg" then R:setVisible(inst, false) else R:freeze(inst, true) end
    local badSeen = nil
    local function rangeCheck()
      local V = app.V
      if V and (not isIntN(V.band) or V.band < 0 or V.band > 6 or not isIntN(V.channel) or V.channel < 0 or V.channel > 8) then
        badSeen = badSeen or sformat("V.band/channel out of range: %s/%s", tostring(V.band), tostring(V.channel))
      end
      return false
    end
    for i = 1, 200 do
      if i % (variant == "bg" and 20 or 10) == 0 then fake:injectForeign(R.clock, 3) end
      if i == 100 then fake:setConfig({ band = 1, channel = 1 }) end
      R:cycle(1, rangeCheck)
    end
    local during = fake.stats.rx - rx0
    t:metric("frames sent during the pause", during)
    if variant == "bg" then
      t:check(during == 0, sformat("%d frames sent while the widget was not visible (no traffic in background)", during))
      R:setVisible(inst, true)
    else
      R:freeze(inst, false)
    end
    local limitMs = (variant == "bg") and 20000 or 10000
    local hit, ms = R:runUntil(limitMs, function()
      rangeCheck()
      return app.V.band == 1 and app.V.channel == 1 and app.V.ready
    end)
    t:check(hit, sformat("after resume V should show the external change A1 within %d s (V %s/%s)", limitMs / 1000,
      tostring(app.V.band), tostring(app.V.channel)))
    if hit then t:metric("resume -> A1 shown", sformat("%.2f s", ms / 1000)) end
    t:check(badSeen == nil, tostring(badSeen))
    runChecked(t, R, inst, 40)
    finish(t, R, fake, { dumpName = "m_" .. variant })
  end
end
scenario("m-bg", "pause: 200 cycles background only (stale frames), then resume", scenarioM("bg"))
scenario("m-frozen", "pause: 200 cycles without any call (ELRS tool open), then resume", scenarioM("frozen"))

-- (n) lossy, slow link: dropped replies, 2-tick latency, 27-byte chunks, busy output buffer
scenario("n", "lossy link: 20% replies lost, 60 ms latency, 27-byte chunks", function(t)
  local R, fake = world(t, { moduleOpts = { version = "4.1.0", band = 4, channel = 2, power = 1, dropRate = 0.2,
                                            latencyMs = 60, chunk = 27, seed = 99 } })
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  local hit, ms = R:runUntil(15000, function() return app.V and app.V.ready end)
  t:check(hit, "V.ready not reached within 15 s on a lossy link (state " .. tostring(app.V and app.V.state) .. ")")
  if hit then t:metric("ready after", sformat("%.2f s", ms / 1000)) end
  t:check(app.V.band == 4 and app.V.channel == 2, "values read on a lossy link are wrong")
  t:metric("replies dropped", fake.stats.dropped)
  R:holdOutputBuffer(300)
  if hit and pageApply(t, R, fake, inst, { band = "R", channel = 4, power = "2" }, "n_lossy") then
    local ok = waitSend(t, R, fake, inst, 20000)
    t:check(ok, "apply did not complete within 20 s on a lossy link (V.send=" .. tostring(app.V.send) .. ")")
    runChecked(t, R, inst, 60)
    t:check(fake.cfg.band == 5 and fake.cfg.channel == 4 and fake.cfg.power == 2,
      sformat("module config after lossy apply: band %d ch %d pwr %d", fake.cfg.band, fake.cfg.channel, fake.cfg.power))
    t:check(fake.vtx.sends >= 1 and fake.vtx.sends <= 2, "send sequences on a lossy link: " .. fake.vtx.sends)
  end
  finish(t, R, fake, { dumpName = "n_lossy" })
end)

-- trim markers: rectangles with a color function and a pos function (ui/sticks.lua)
local function trimMarkers(R, inst)
  local n = 0
  for _, o in ipairs(R:objects(inst, "rectangle", true)) do
    if o.fns.pos and o.fns.color and string.find(o.createdAt or "", "sticks.lua", 1, true) then n = n + 1 end
  end
  return n
end

-- (o) a model saved with the old widget stores only options 0 and 1
scenario("o", "existing model: options after index 1 load as 0 (VTX cell, page, trims shown)", function(t)
  local R, fake = world(t, {})
  if not R then return end
  local inst = R:createInstance({ w = 480, h = 320, appMode = true, storedOptions = 2,
                                  options = { darkTheme = 1, transpLevel = 4 } })
  local app = appOf(R, inst)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  local list = {}
  for k, v in pairs(inst.options) do list[#list + 1] = k .. "=" .. tostring(v) end
  table.sort(list)
  t:info("options as the firmware loads them: " .. table.concat(list, " "))
  for k, v in pairs(inst.options) do
    if k ~= "darkTheme" and k ~= "transpLevel" then
      t:check(v == 0, "mock: option " .. k .. " not stored by the model should load as 0, is " .. tostring(v))
    end
  end
  local hit = runChecked(t, R, inst, 200, function() return R:findText(inst, "^F2") ~= nil end)
  t:check(R:findText(inst, "^VTX$") ~= nil, "existing model: the VTX cell header should be shown")
  t:check(hit, "existing model: the VTX cell should show F2 (texts: " .. visibleTexts(R, inst) .. ")")
  t:check(R.crsf.pushCalls > 0, "existing model: VTX control should talk to the TX module")
  t:check(app.vtxOn == true, "existing model: VTX control should be on")
  local nt = trimMarkers(R, inst)
  t:check(nt == 4, "existing model: 4 trim markers expected, found " .. nt)
  t:check(R:findText(inst, "4%.1%.0") ~= nil, "existing model: footer should show the ELRS version")
  t:check(R:findText(inst, "^75%%$") ~= nil, "existing model: the dashboard cap label 75% should be shown")
  -- trailOff and showFps are not stored either: trail on, no rate shown
  local nTrail = 0
  for _, o in ipairs(R:objects(inst, "rectangle", true)) do
    if string.find(o.createdAt or "", "sticks.lua", 1, true) and o.props.w == 9 and o.props.h == 9
      and o.fns.pos and type(o.props.opacity) == "number" and o.props.opacity < 255 then
      nTrail = nTrail + 1
    end
  end
  t:check(nTrail == 4, "existing model: 4 trail squares expected (2 per dot), found " .. nTrail)
  t:check(R:findText(inst, " Hz$") == nil, "existing model: no update rate without showFps")
  -- showFps on: refresh every 50 ms gives 20 Hz in the footer
  inst.options.showFps = 1
  local fpsHit = runChecked(t, R, inst, 60, function() return R:findText(inst, "^20 Hz$") ~= nil end)
  t:check(fpsHit, "showFps: footer should show '20 Hz' (texts: " .. visibleTexts(R, inst) .. ")")
  inst.options.showFps = 0
  runChecked(t, R, inst, 2)
  t:check(R:findText(inst, " Hz$") == nil, "showFps off again: rate hidden")
  -- App mode long-press: the VTX page, RTN back
  R:enterFullScreen(inst)
  R:cycle(4)
  local B = classify(R, inst)
  t:check(B.apply ~= nil and B.back ~= nil and B.band.R ~= nil, "existing model: full screen should open the VTX page")
  R:dump(inst, "o_existing_page")
  -- the Throttle tab is there too, and a preset writes the model
  local function button(text)
    for _, b in ipairs(R:buttons(inst, true)) do
      if b.props.text == text then return b end
    end
    return nil
  end
  local tb = button("Throttle")
  t:check(button("VTX") ~= nil and tb ~= nil, "existing model: the VTX and Throttle tabs should be shown")
  if tb then
    R:press(inst, tb)
    R:cycle(2)
    local p80 = button("80%")
    t:check(p80 ~= nil and R:findText(inst, "^Max throttle$") ~= nil, "existing model: the Throttle page should show")
    if p80 then
      R:press(inst, p80)
      runChecked(t, R, inst, 12)
      local l = R:inputLines(2)[1]
      t:check(l ~= nil and l.weight == 80 and l.offset == -20,
        "existing model: preset 80% should give the line 80/-20, is " .. (l and (l.weight .. "/" .. l.offset) or "none"))
    end
  end
  R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
  R:cycle(4)
  t:check(not inst.fullscreen, "existing model: RTN should leave the page")
  layoutReport(t, R, inst, "fail")
  finish(t, R, fake, { dumpName = "o_existing_model", instrLimits = { 14000, 8000 } })
end)

-- (p) 480x272 radio (TX16S class) in App mode: dashboard and VTX page
scenario("p", "480x272 radio: App-mode dashboard and VTX page without overlaps", function(t)
  local R, fake = world(t, { lcdW = 480, lcdH = 272 })
  if not R then return end
  local inst = stdCreate(R, { w = 480, h = 272 })
  local app = appOf(R, inst)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  runChecked(t, R, inst, 200, function() return app.V and app.V.ready end)
  t:check(app.V and app.V.ready, "V.ready not reached")
  layoutReport(t, R, inst, "warn", "p dashboard")
  R:enterFullScreen(inst)
  R:cycle(4)
  t:check(inst.zone.h == 272, "full-screen zone should be 480x272, is " .. inst.zone.w .. "x" .. inst.zone.h)
  -- the Pit button shows the pit label ("Off"): find it by its width (ui/vtxpage.lua PIT_W)
  local function pitButton()
    for _, b in ipairs(pageButtons(R, inst)) do
      if b.w == 170 then return b end
    end
    return nil
  end
  local B = classify(R, inst)
  t:check(B.apply ~= nil and pitButton() ~= nil and B.power["2"] ~= nil and B.channel[8] ~= nil,
    "480x272 page: band, channel, power, pit and Apply buttons expected; buttons: " .. B.all)
  local function noOverlaps(tag)
    local n = 0
    for _, r in ipairs(R:layoutCheck(inst)) do
      if string.find(r.msg, "overlap", 1, true) or string.find(r.msg, "clipped", 1, true) then
        n = n + 1
        t:fail(tag .. ": layout: " .. r.msg)
      end
    end
    for _, b in ipairs(pageButtons(R, inst)) do
      t:check(b.y >= 0 and b.y + b.h <= 272 and b.x >= 0 and b.x + b.w <= 480,
        sformat("%s: button %q outside the 480x272 screen (%d,%d %dx%d)", tag, b.text, b.x, b.y, b.w, b.h))
      if b.h < 34 then t:warn(sformat("%s: button %q is %d px high (DESIGN: >= 34)", tag, b.text, b.h)) end
    end
    return n
  end
  noOverlaps("480x272 page")
  R:dump(inst, "p_272_page")
  -- power Keep: no pit button (ELRS sends no pit mode without a power level)
  press(t, R, inst, B.power["-"], "power Keep")
  R:cycle(2)
  local Bk = classify(R, inst)
  t:check(pitButton() == nil, "power Keep: the Pit button should be hidden")
  t:check(R:findText(inst, "Needs a power level") ~= nil, "power Keep: the pit row should say 'Needs a power level'")
  noOverlaps("480x272 page, power Keep")
  -- stage R4 power 2 and apply
  press(t, R, inst, Bk.band.R, "band R"); R:cycle(1)
  press(t, R, inst, Bk.channel[4], "channel 4"); R:cycle(1)
  press(t, R, inst, Bk.power["2"], "power 2"); R:cycle(2)
  local Bs = classify(R, inst)
  t:check(pitButton() ~= nil, "power 2: the Pit button should be shown again")
  noOverlaps("480x272 page, staged")
  R:dump(inst, "p_272_page_staged")
  press(t, R, inst, Bs.apply, "Apply & Send")
  local hit = waitSend(t, R, fake, inst, 15000)
  t:check(hit, "480x272: Apply & Send did not complete")
  runChecked(t, R, inst, 60)
  t:check(fake.cfg.band == 5 and fake.cfg.channel == 4 and fake.cfg.power == 2,
    sformat("module after apply: band %d ch %d pwr %d", fake.cfg.band, fake.cfg.channel, fake.cfg.power))
  noOverlaps("480x272 page, sent")
  R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
  R:cycle(4)
  t:check(not inst.fullscreen, "RTN should leave the page")
  finish(t, R, fake, { dumpName = "p_272", instrLimits = { 14000, 8000 } })
end)

-- (q) RX cell count with real EdgeTX telemetry behaviour: after a link loss the old
-- values stay and come back with the link (marked old) until the FC sends new ones
scenario("q", "RX cells: stale RxBt and a Capa reset after a pack swap, the count kept through a link loss in flight, LiHV, upward fix", function(t)
  local function lossAndBack(R, inst, ms)
    R:setStreaming(false)
    R:setSensor("RQly", 0); R:setSensor("TPWR", 0); R:setSensor("RFMD", 0)
    runChecked(t, R, inst, floor(ms / 50))
    R:setStreaming(true)
    R:setSensor("RQly", 100); R:setSensor("TPWR", 250); R:setSensor("RFMD", 7)
  end
  local function cellsOf(app) return app.S and app.S.cells end
  -- The count latches only after 3 s at rest (steady voltage, Curr 2.5 A or less): 80
  -- cycles (4 s) are enough. CRSF sends voltage, current and Capa (mAh used) in one battery
  -- frame: every RxBt change below also sets Curr and Capa (landed = no load, in flight =
  -- load). The default world has Curr 12.3 A (in flight), so each case sets a resting
  -- current first. Capa tells the pack: the FC sets it to 0 when it starts (a pack
  -- plugged in); a Capa that continues after a gap is the same pack.
  -- case 1: 6S landed at 21.3 V, pack swapped (link lost 6 s); the link is back before
  -- the FC sends a battery frame, so RxBt and Capa are the old values for 2 s: the old
  -- 21.3 V changes nothing (the latched 6S stays). The first frame of the new pack has
  -- 25.2 V and Capa 0: a new pack, so the dashboard shows the total voltage with the
  -- neutral battery icon until 3 s at rest, then 6S.
  local R, fake = world(t, {})
  if not R then return end
  R:setSensor("RxBt", 25.2); R:setSensor("Curr", 0.4); R:setSensor("Capa", 0)   -- plugged in now
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  runChecked(t, R, inst, 80)
  t:check(cellsOf(app) == 6, "case 1: 25.2 V at rest should latch 6S, is " .. tostring(cellsOf(app)))
  R:setSensor("RxBt", 21.3); R:setSensor("Curr", 0.3); R:setSensor("Capa", 900)
  runChecked(t, R, inst, 10)
  lossAndBack(R, inst, 6000)
  local wrong = false
  for _ = 1, 40 do
    runChecked(t, R, inst, 1)
    if cellsOf(app) ~= 6 then wrong = true end
  end
  t:check(not wrong, "case 1: the old RxBt (21.3 V, marked old) must not change the latched 6S, got " .. tostring(cellsOf(app)))
  t:check(R:findText(inst, "^3%.55V ?%(6S%)$") ~= nil, "case 1: the old RxBt shows with the latched count: 3.55V (6S)")
  R:setSensor("RxBt", 25.2); R:setSensor("Curr", 0.2); R:setSensor("Capa", 0)
  wrong = false
  for _ = 1, 10 do
    runChecked(t, R, inst, 1)
    if cellsOf(app) ~= nil or app.S.cellV ~= nil then wrong = true end
  end
  t:check(not wrong, "case 1: Capa 0 after the swap is a new pack: no count before 3 s at rest, got " .. tostring(cellsOf(app)))
  t:check(R:findText(inst, "^25%.20V$") ~= nil, "case 1: without a cell count the dashboard shows the total voltage 25.20V")
  t:check(visibleBatteryIcon(R, inst) == "none", "case 1: without a cell count the RX battery icon is the neutral one, is "
    .. tostring(visibleBatteryIcon(R, inst)))
  runChecked(t, R, inst, 80)
  t:check(cellsOf(app) == 6, "case 1: fresh 25.2 V at rest after the swap should give 6S, is " .. tostring(cellsOf(app)))
  t:check(app.S.cellV and math.abs(app.S.cellV - 4.2) < 0.01, "case 1: cellV 4.2, is " .. tostring(app.S.cellV))
  -- case 2: the same pack in flight at 3.5 V/cell, link lost for 6 s (failsafe), back with
  -- 21.0 V under load and a Capa that continues: the same pack, so 6S stays all the time
  -- (21.0 V also fits 5S at 4.2 V, but nothing is counted again); landed at 22.8 V
  -- (3.8 V/cell): 6S
  R:setSensor("RxBt", 21.0); R:setSensor("Curr", 18.0); R:setSensor("Capa", 600)
  runChecked(t, R, inst, 10)
  lossAndBack(R, inst, 6000)
  R:setSensor("RxBt", 21.0); R:setSensor("Curr", 16.0); R:setSensor("Capa", 630)
  wrong = false
  for _ = 1, 200 do
    runChecked(t, R, inst, 1)
    if cellsOf(app) ~= 6 then wrong = true end
  end
  t:check(not wrong, "case 2: after a link loss in flight with Capa continuing the 6S stays, got " .. tostring(cellsOf(app)))
  t:check(R:findText(inst, "^3%.50V ?%(6S%)$") ~= nil, "case 2: the dashboard shows 3.50V (6S) in flight after the loss")
  R:setSensor("RxBt", 22.8); R:setSensor("Curr", 0.3); R:setSensor("Capa", 640)
  runChecked(t, R, inst, 80)
  t:check(cellsOf(app) == 6, "case 2: landed at 22.8 V the count should be 6S, is " .. tostring(cellsOf(app)))
  t:check(R:findText(inst, "^3%.80V ?%(6S%)$") ~= nil, "case 2: landed, the dashboard shows 3.80V (6S)")
  finish(t, R, fake, {})
  -- case 3: LiHV full packs (4S 17.5 V, 6S 26.2 V) and a full 2S LiHV at rest
  for _, c in ipairs({ { 17.5, 4 }, { 26.2, 6 }, { 8.7, 2 } }) do
    local R2, fake2 = world(t, {})
    if not R2 then return end
    R2:setSensor("RxBt", c[1]); R2:setSensor("Curr", 0.3); R2:setSensor("Capa", 0)
    local inst2 = stdCreate(R2)
    local app2 = appOf(R2, inst2)
    runChecked(t, R2, inst2, 80)
    t:check(cellsOf(app2) == c[2], sformat("case 3: %.1f V should latch %dS, is %s", c[1], c[2], tostring(cellsOf(app2))))
    finish(t, R2, fake2, {})
  end
  -- case 4: the upward correction
  local R3, fake3 = world(t, {})
  if not R3 then return end
  R3:setSensor("RxBt", 21.0); R3:setSensor("Curr", 0.3); R3:setSensor("Capa", 0)   -- 6S at 3.5 V/cell: looks like 5S
  local inst3 = stdCreate(R3)
  local app3 = appOf(R3, inst3)
  runChecked(t, R3, inst3, 80)
  t:check(cellsOf(app3) == 5, "case 4: 21.0 V at rest latches 5S (expected limit), is " .. tostring(cellsOf(app3)))
  R3:setSensor("RxBt", 25.2)          -- the voltage proves 6 cells
  runChecked(t, R3, inst3, 60)
  t:check(cellsOf(app3) == 6, "case 4: 25.2 V should raise the count to 6S, is " .. tostring(cellsOf(app3)))
  finish(t, R3, fake3, {})
  -- case 6: the FC starts again with the used pack (OSD menu SAVE&REBOOT): the RX keeps
  -- its power and the link, Capa starts again at 0, the voltage is the same: the same
  -- pack, 6S stays (never 5S at 4.32 V)
  local R5, fake5 = world(t, {})
  if not R5 then return end
  R5:setSensor("RxBt", 25.2); R5:setSensor("Curr", 0.4); R5:setSensor("Capa", 0)
  local inst5 = stdCreate(R5)
  local app5 = appOf(R5, inst5)
  runChecked(t, R5, inst5, 80)
  R5:setSensor("RxBt", 21.6); R5:setSensor("Curr", 0.4); R5:setSensor("Capa", 1700)
  runChecked(t, R5, inst5, 40)
  t:check(cellsOf(app5) == 6, "case 6: the landed 6S at 21.6 V is 6S, is " .. tostring(cellsOf(app5)))
  R5:setSensor("RxBt", 21.6); R5:setSensor("Curr", 0.4); R5:setSensor("Capa", 0)
  wrong = false
  for _ = 1, 100 do
    runChecked(t, R5, inst5, 1)
    if cellsOf(app5) ~= 6 then wrong = true end
  end
  t:check(not wrong, "case 6: an FC start without a link loss (Capa 0) keeps 6S, got " .. tostring(cellsOf(app5)))
  t:check(R5:findText(inst5, "^3%.60V ?%(6S%)$") ~= nil, "case 6: the dashboard shows 3.60V (6S) after the FC start")
  finish(t, R5, fake5, {})
  -- case 7: a model without a Capa sensor cannot see a pack change, so the count never
  -- goes down: a 6S, then a full 4S (link lost 6 s) shows 6S at 2.80 V (too low, the safe
  -- side; rxCells gives the right count). A 4S, then a full 6S goes up to 6S (upward rule).
  local noCapa = {}
  for _, d in ipairs(STD_SENSORS) do
    if d.name ~= "Capa" then noCapa[#noCapa + 1] = d end
  end
  for _, c in ipairs({ { 25.2, 16.8, 4, "^2%.80V ?%(6S%)$", "2.80V (6S)" },
                       { 16.8, 25.2, 6, "^4%.20V ?%(6S%)$", "4.20V (6S)" } }) do
    local tag = sformat("case 7: no Capa sensor, %.1f V -> full %dS", c[1], c[3])
    local R6, fake6 = world(t, {})
    if not R6 then return end
    R6:defineSensors(noCapa)
    R6:setSensor("RxBt", c[1]); R6:setSensor("Curr", 0.3)
    local inst6 = stdCreate(R6)
    local app6 = appOf(R6, inst6)
    if inst6.dead or not app6 then t:fail(tag .. ": no usable instance") finish(t, R6, fake6, {}) return end
    runChecked(t, R6, inst6, 80)
    local first = cellsOf(app6)
    t:check(first == (c[1] > 20 and 6 or 4), tag .. ": the first pack latches at rest, is " .. tostring(first))
    lossAndBack(R6, inst6, 6000)
    R6:setSensor("RxBt", c[2]); R6:setSensor("Curr", 0.3)
    local low = false
    for _ = 1, 200 do
      runChecked(t, R6, inst6, 1)
      local n = cellsOf(app6)
      if n == nil or n < first then low = true end
    end
    t:check(not low, tag .. ": the count never goes below the first count")
    t:check(cellsOf(app6) == 6, tag .. ": 6S after 10 s, is " .. tostring(cellsOf(app6)))
    t:check(R6:findText(inst6, c[4]) ~= nil, tag .. ": the dashboard shows " .. c[5])
    finish(t, R6, fake6, {})
  end
  -- case 5: 0.4 V and no cell count: the battery icon shows dead
  local R4, fake4 = world(t, {})
  if not R4 then return end
  R4:setSensor("RxBt", 0.4)
  local inst4 = stdCreate(R4)
  runChecked(t, R4, inst4, 20)
  local dead = false
  for _, o in ipairs(R4:objects(inst4, "image", true)) do
    if string.find(tostring(o.props.file), "battery%-dead%.png$") then dead = true end
  end
  t:check(dead, "case 5: RX battery 0.4 V without a cell count should show the dead icon")
  finish(t, R4, fake4, { dumpName = "q_rx_dead" })
end)

---------------------------------------------------------------------------
-- throttle cap (lib/thrcap.lua, ui/thrpage.lua, the cap line in ui/sticks.lua)
---------------------------------------------------------------------------
-- The mock emulates the model input API and the input stage of the mixer (edgetx_mock.lua,
-- "model inputs"). finish() fails a scenario on a mixer glitch, a model write outside
-- refresh(), a float argument or two swaps in one call, and on a visible clickable object
-- outside full screen.

local THR_CHN = 2          -- Input 3 (chn 2) is the throttle input in the user's models

-- WCAG contrast ratio of two "#rrggbb" colors
local function hexContrast(a, b)
  local function lum(h)
    local function lin(x)
      x = x / 255
      if x <= 0.04045 then return x / 12.92 end
      return ((x + 0.055) / 1.055) ^ 2.4
    end
    local r, g, bl = tonumber(string.sub(h, 2, 3), 16), tonumber(string.sub(h, 4, 5), 16), tonumber(string.sub(h, 6, 7), 16)
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(bl)
  end
  local x, y = lum(a), lum(b)
  if x < y then x, y = y, x end
  return (x + 0.05) / (y + 0.05)
end

local function btnText(R, inst, text)
  for _, b in ipairs(R:buttons(inst, true)) do
    if b.props.text == text then return b end
  end
  return nil
end

local function tap(t, R, inst, text, tag)
  local b = btnText(R, inst, text)
  if not b then
    t:fail(sformat("%s: button %q not visible (buttons: %s)", tag, text, buttonList(R, inst)))
    return false
  end
  local ok, why = R:press(inst, b)
  if not ok then t:fail(sformat("%s: cannot press %q: %s", tag, text, tostring(why))) end
  return ok
end

local function hasText(R, inst, s)
  for _, x in ipairs(R:texts(inst, false)) do
    if string.find(x, s, 1, true) then return true end
  end
  return false
end

-- full screen on the Throttle page (the Throttle tab when VTX control is on)
local function openThrottle(t, R, inst, tag)
  if not inst.fullscreen then
    R:enterFullScreen(inst)
    R:cycle(4)
  end
  local tb = btnText(R, inst, "Throttle")
  if tb then
    R:press(inst, tb)
    R:cycle(2)
  end
  local app = appOf(R, inst)
  return t:check(inst.fullscreen and app ~= nil and app.tabs ~= nil and app.tabs.thr == true,
    tag .. ": full screen with the Throttle page expected (buttons: " .. buttonList(R, inst) .. ")")
end

local function thrLine(R) return R:inputLines(THR_CHN)[1] end

local function lineTxt(l)
  if not l then return "none" end
  return sformat("%s/%s", tostring(l.weight), tostring(l.offset))
end

-- the dashboard cap line: a 2 px hline of ui/sticks.lua
local function capLineObj(R, inst)
  for _, o in ipairs(R:objects(inst, "hline", true)) do
    if o.props.h == 2 and string.find(o.createdAt or "", "sticks.lua", 1, true) then return o end
  end
  return nil
end

-- the two gimbal boxes (2 px outline) sorted from left to right, and the stick dots (9x9, pos
-- function, fixed color)
local function gimbals(R, inst)
  local boxes, dots = {}, {}
  for _, o in ipairs(R:objects(inst, "rectangle", true)) do
    if string.find(o.createdAt or "", "sticks.lua", 1, true) then
      if o.props.filled == false and o.props.thickness == 2 then boxes[#boxes + 1] = o end
      if o.props.filled and o.props.w == 9 and o.props.h == 9 and o.fns.pos and not o.fns.color
        and (o.props.opacity == nil or o.props.opacity >= 255) then dots[#dots + 1] = o end
    end
  end
  table.sort(boxes, function(a, b) return (R:absRect(a)) < (R:absRect(b)) end)
  return boxes, dots
end

-- the dot inside box b
local function dotIn(R, b, dots)
  local bx, by, bw, bh = R:absRect(b)
  for _, d in ipairs(dots) do
    local x, y = R:absRect(d)
    if x >= bx and x < bx + bw and y >= by and y < by + bh then return d end
  end
  return nil
end

-- model writes since index n0: list of { call, t, cycle, phase }
local function writesFrom(R, n0)
  local r = {}
  for i = n0 + 1, #R.mdl.writes do r[#r + 1] = R.mdl.writes[i] end
  return r
end

-- (cap-page) the Throttle page on each of the user's models
scenario("cap-page", "throttle cap page on the 4 user models: presets, -5/+5, number input + Set", function(t)
  for mi, um in ipairs(Mock.USER_MODELS) do
    local tag = sformat("model %q", um.name)
    local R, fake = world(t, { model = Mock.userModel(mi) })
    if not R then return end
    local inst = stdCreate(R)
    local app = appOf(R, inst)
    runChecked(t, R, inst, 60)
    if inst.dead or not app or type(app.T) ~= "table" then
      t:fail(tag .. ": no usable instance or no wgt.T")
      finish(t, R, fake, {})
      return
    end
    local T = app.T
    t:check(R.modelName == um.name, tag .. ": mock model name")
    t:check(T.state == "ok" and T.cap == um.w and T.custom == false and T.input == THR_CHN
      and T.weight == um.w and T.offset == um.o,
      sformat("%s: T should read cap %d from input 3 (state %s, msg %q, cap %s, w/o %s/%s, input %s)", tag, um.w,
        tostring(T.state), tostring(T.msg), tostring(T.cap), tostring(T.weight), tostring(T.offset), tostring(T.input)))
    if um.w < 100 then
      t:check(capLineObj(R, inst) ~= nil and capLabel(R, inst, um.w) ~= nil,
        tag .. ": the dashboard should show the cap line and " .. um.w .. "%")
    else
      t:check(capLineObj(R, inst) == nil and capLabel(R, inst, 100) == nil,
        tag .. ": no cap line and no label at 100 %")
    end
    local snap0 = R:modelSnapshot()
    local base = thrLine(R)
    openThrottle(t, R, inst, tag)
    t:check(R:findText(inst, "^" .. um.w .. "%%$") ~= nil and hasText(R, inst, "Max throttle"),
      tag .. ": the page should show the cap " .. um.w .. "% big")
    t:check(hasText(R, inst, sformat("Input 3: weight %d, offset %d", um.w, um.o)), tag .. ": header shows the input line")
    t:check(hasText(R, inst, "Applies immediately"), tag .. ": note 'Applies immediately'")
    t:check(#R:objects(inst, "numberEdit", true) == 1, tag .. ": number input shown")
    for _, p in ipairs({ 100, 90, 80, 75, 70, 60, 50 }) do
      t:check(btnText(R, inst, p .. "%") ~= nil, sformat("%s: preset %d%% button", tag, p))
    end
    -- the applied preset: its text must be readable on the ACTIVE color of the user's Dark
    -- Theme (PRIMARY1 #909490 text on ACTIVE #F8B038 gave only 1.65:1)
    local ab = btnText(R, inst, um.w .. "%")
    if ab then
      local r = hexContrast(Mock.colorHex(ab.props.color), Mock.colorHex(ab.props.textColor))
      t:check(ab.props.color == C.COLOR_THEME_ACTIVE and r >= 3.0,
        sformat("%s: applied preset %d%%: text %s on %s has contrast %.2f:1 (>= 3:1)", tag, um.w,
          Mock.colorHex(ab.props.textColor), Mock.colorHex(ab.props.color), r))
    end
    layoutReport(t, R, inst, "fail", tag .. " throttle page")
    R:dump(inst, "cap_page_model" .. mi)

    local function expectCap(c, what)
      local lines = R:inputLines(THR_CHN)
      local l = lines[1]
      t:check(#lines == 1 and l ~= nil and l.weight == c and l.offset == c - 100,
        sformat("%s: %s: input 3 should be one line %d/%d, is %s (%d lines)", tag, what, c, c - 100, lineTxt(l), #lines))
      t:check(T.cap == c and (T.state == "ok") and not T.custom,
        sformat("%s: %s: T.cap should be %d, is %s (state %s, msg %q)", tag, what, c, tostring(T.cap), tostring(T.state),
          tostring(T.msg)))
      if l and base then
        for _, k in ipairs(Mock.LINE_KEYS) do
          if k ~= "weight" and k ~= "offset" then
            t:check(l[k] == base[k], sformat("%s: %s: line field %s changed (%s -> %s)", tag, what, k, tostring(base[k]),
              tostring(l[k])))
          end
        end
        t:check(l.inputName == "Thr", sformat("%s: %s: input name should stay 'Thr', is %q", tag, what, tostring(l.inputName)))
      end
      local hi, lo = R:modelOut(THR_CHN, 1024), R:modelOut(THR_CHN, -1024)
      local want = floor(-1024 + 2048 * c / 100 + 0.5)
      t:check(hi ~= nil and math.abs(hi - want) <= 1 and lo == -1024,
        sformat("%s: %s: input 3 output at full stick %s (want %d), at low stick %s (want -1024)", tag, what,
          tostring(hi), want, tostring(lo)))
    end
    -- one swap = insertInput (after the live line) + deleteInput (the old line 0)
    local function oneSwap(n0, what)
      local ws = writesFrom(R, n0)
      t:check(#ws == 2 and ws[1].call == "insertInput" and ws[1].idx == 1 and ws[2].call == "deleteInput" and ws[2].idx == 0,
        sformat("%s: %s: one swap expected (insertInput(2, 1), deleteInput(2, 0)), saw %d write calls", tag, what, #ws))
    end

    local target = 60
    local n0 = #R.mdl.writes
    tap(t, R, inst, target .. "%", tag)
    R:cycle(1)
    t:check(#R.mdl.writes == n0 and T.pending == target, tag .. ": a preset press only records a pending value")
    t:check(hasText(R, inst, "Pending: " .. target .. "%"), tag .. ": 'Pending: 60%' shown")
    R:cycle(12)
    oneSwap(n0, "preset 60%")
    expectCap(target, "preset 60%")
    t:check(hasText(R, inst, "Cap set to 60%"), tag .. ": result message 'Cap set to 60%' shown")
    n0 = #R.mdl.writes
    tap(t, R, inst, "-5", tag)
    R:cycle(12)
    oneSwap(n0, "-5")
    expectCap(target - 5, "-5")
    tap(t, R, inst, "+5", tag)
    R:cycle(12)
    expectCap(target, "+5")
    local ne = R:objects(inst, "numberEdit", true)[1]
    if t:check(ne ~= nil, tag .. ": number input") then
      n0 = #R.mdl.writes
      local ok, why = R:editNumber(inst, ne, 37)
      t:check(ok, tag .. ": edit the number: " .. tostring(why))
      R:cycle(12)
      t:check(#R.mdl.writes == n0 and thrLine(R).weight == target, tag .. ": editing the number must not write (Set applies it)")
      tap(t, R, inst, "Set", tag)
      R:cycle(12)
      oneSwap(n0, "Set 37")
      expectCap(37, "Set 37")
      -- the number input stops at 20 and 100
      R:editNumber(inst, ne, 5)
      tap(t, R, inst, "Set", tag)
      R:cycle(12)
      expectCap(20, "Set below the range")
      n0 = #R.mdl.writes
      tap(t, R, inst, "-5", tag)
      R:cycle(12)
      t:check(#R.mdl.writes == n0, tag .. ": -5 at 20 % must not write")
      expectCap(20, "-5 at the minimum")
      R:editNumber(inst, ne, 150)
      tap(t, R, inst, "Set", tag)
      R:cycle(12)
      expectCap(100, "Set above the range")
      n0 = #R.mdl.writes
      tap(t, R, inst, "+5", tag)
      R:cycle(12)
      t:check(#R.mdl.writes == n0, tag .. ": +5 at 100 % must not write")
    end
    -- back to the model's own cap: the model is exactly as at the start
    tap(t, R, inst, um.w .. "%", tag)
    R:cycle(12)
    expectCap(um.w, "preset back to " .. um.w .. "%")
    t:check(R:modelSnapshot() == snap0, tag .. ": the model should be the same as at the start")
    R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
    R:cycle(4)
    t:check(not inst.fullscreen and #R:buttons(inst, false) == 0, tag .. ": RTN should leave the page")
    finish(t, R, fake, { instrLimits = { 14000, 8000 } })
  end
end)

-- (cap-taps) debounce: quick taps make one swap, slow taps one swap each, never from background()
scenario("cap-taps", "quick taps coalesce to one swap 400 ms after the last tap; nothing from background()", function(t)
  local R, fake = world(t, {})
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  runChecked(t, R, inst, 40)
  if inst.dead or not app or not app.T then t:fail("no usable instance") finish(t, R, fake, {}) return end
  openThrottle(t, R, inst, "taps")
  -- six -5 taps, one per 50 ms cycle
  local n0 = #R.mdl.writes
  local lastTap = R.clock
  for _ = 1, 6 do
    tap(t, R, inst, "-5", "taps")
    lastTap = R.clock
    R:cycle(1)
    t:check(#R.mdl.writes == n0, "taps: no model write while the taps go on")
  end
  t:check(app.T.pending == 45, "taps: six -5 taps from 75 should give a pending 45, is " .. tostring(app.T.pending))
  R:runUntil(1500, function() return #R.mdl.writes > n0 end)
  R:cycle(10)
  local ws = writesFrom(R, n0)
  t:check(#ws == 2 and ws[1].call == "insertInput" and ws[2].call == "deleteInput",
    sformat("taps: six quick taps should give one swap, saw %d write calls", #ws))
  if ws[1] then
    local after = ws[1].t - lastTap
    t:metric("first write after the last tap", sformat("%d ms", after))
    t:check(after >= 400 and after <= 500, sformat("taps: the swap came %d ms after the last tap (debounce 400 ms)", after))
    t:check(ws[1].phase == "refresh", "taps: the swap must run in refresh()")
  end
  t:check(lineTxt(thrLine(R)) == "45/-55", "taps: input 3 should be 45/-55, is " .. lineTxt(thrLine(R)))
  -- a preset storm: the last value wins
  n0 = #R.mdl.writes
  for _, p in ipairs({ "100%", "90%", "80%", "70%" }) do
    tap(t, R, inst, p, "storm")
    R:cycle(2)
  end
  R:cycle(12)
  t:check(#writesFrom(R, n0) == 2 and lineTxt(thrLine(R)) == "70/-30",
    sformat("storm: four presets within 400 ms should give one swap to 70/-30, saw %d calls and %s", #writesFrom(R, n0),
      lineTxt(thrLine(R))))
  -- slow taps (600 ms apart): one swap each
  n0 = #R.mdl.writes
  for _ = 1, 3 do
    tap(t, R, inst, "+5", "slow")
    R:cycle(12)
  end
  t:check(#writesFrom(R, n0) == 6 and lineTxt(thrLine(R)) == "85/-15",
    sformat("slow: three taps 600 ms apart should give three swaps to 85/-15, saw %d calls and %s", #writesFrom(R, n0),
      lineTxt(thrLine(R))))
  -- a pending value waits while only background() runs (the user leaves the main view)
  n0 = #R.mdl.writes
  tap(t, R, inst, "50%", "hidden")
  R:exitFullScreen(inst)
  R:setVisible(inst, false)
  R:cycle(40)
  t:check(#R.mdl.writes == n0, "hidden: no model write while only background() runs")
  t:check(app.T.pending == 50, "hidden: the request should stay pending, T.pending is " .. tostring(app.T.pending))
  R:setVisible(inst, true)
  R:cycle(3)
  t:check(lineTxt(thrLine(R)) == "50/-50", "hidden: the pending cap should be written in the first refresh cycles after "
    .. "the widget shows again, input 3 is " .. lineTxt(thrLine(R)))
  for _, w in ipairs(writesFrom(R, n0)) do
    t:check(w.phase == "refresh", "hidden: write from " .. tostring(w.phase))
  end
  runChecked(t, R, inst, 20)
  finish(t, R, fake, { instrLimits = { 14000, 8000 }, dumpName = "cap_taps" })
end)

-- (cap-armed) the cap applies at any time: armed, during a VTX send, with the stick moving
scenario("cap-armed", "armed: the cap applies at once (no confirm), glitch-free, also during a VTX send", function(t)
  local R, fake = world(t, { moduleOpts = { version = "4.1.0", band = 4, channel = 2, power = 1, armed = true } })
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  runChecked(t, R, inst, 200, function() return app.V and app.V.ready end)
  R:enterFullScreen(inst)
  local armed = runChecked(t, R, inst, 100, function() return app.E and app.E.armed end)
  t:check(armed, "E.armed should become true on the VTX tab (0x2E status poll)")
  -- start a VTX Apply & Send (armed: confirm), then go to the Throttle tab at once
  local B = classify(R, inst)
  press(t, R, inst, B.channel[5], "channel 5")
  R:cycle(1)
  press(t, R, inst, classify(R, inst).apply, "Apply & Send")
  R:cycle(1)
  local p = R:openPopup(inst)
  if t:check(p ~= nil and p.kind == "confirm", "VTX Apply while armed should ask first") then R:answerPopup(inst, true) end
  tap(t, R, inst, "Throttle", "armed")
  R:cycle(1)
  t:check(hasText(R, inst, "Applies immediately, also when armed."), "armed: the page note")
  -- taps while armed, with the throttle stick moving every cycle
  local seq = { { "60%", 60 }, { "-5", 55 }, { "80%", 80 }, { "+5", 85 }, { "50%", 50 } }
  local k = 0
  for _, s in ipairs(seq) do
    tap(t, R, inst, s[1], "armed")
    t:check(R:openPopup(inst) == nil, "armed: the cap must not ask for a confirmation")
    for _ = 1, 12 do
      k = k + 1
      R:setSource("thr", ((k * 397) % 2049) - 1024)
      R:cycle(1)
    end
    t:check(lineTxt(thrLine(R)) == sformat("%d/%d", s[2], s[2] - 100),
      sformat("armed: after %s input 3 should be %d/%d, is %s", s[1], s[2], s[2] - 100, lineTxt(thrLine(R))))
  end
  t:check(app.E.armed == true, "armed: E.armed should still be true")
  local sent = R:runUntil(15000, function() return fake.vtx.sends >= 1 and fake.cfg.channel == 5 end)
  t:check(sent and fake.vtx.sends == 1, sformat("the VTX send should complete next to the cap swaps (sends %d, channel %d)",
    fake.vtx.sends, fake.cfg.channel))
  -- control: the glitch check of the harness finds the unsafe orders
  local function control(name, steps)
    local Rx = world(t, {})
    if not Rx then return end
    local ix = stdCreate(Rx)
    Rx:cycle(5)
    local m = Rx.env.model
    local new = {}
    for _, key in ipairs(Mock.LINE_KEYS) do new[key] = thrLine(Rx)[key] end
    new.weight, new.offset = 60, -40
    Rx.current, Rx.phase = ix, "refresh"
    steps(m, new)
    Rx.current, Rx.phase = nil, "idle"
    Rx:cycle(1)
    t:check(Rx.mdl.nGlitches > 0, "control: the harness should find a glitch with the order " .. name)
  end
  control("delete, then insert", function(m, new) m.deleteInput(2, 0); m.insertInput(2, 0, new) end)
  control("insert before the live line", function(m, new) m.insertInput(2, 0, new); m.deleteInput(2, 1) end)
  finish(t, R, fake, { instrLimits = { 14000, 8000 }, dumpName = "cap_armed" })
end)

-- (cap-refuse) layouts the cap cannot change safely: the reason is shown, the model is never written
local function L(t)
  local l = { source = Mock.SRC.thr, weight = 75, offset = -25 }
  for k, v in pairs(t or {}) do l[k] = v end
  return l
end
local MIX_BOTH = {
  { destCh = 0, source = Mock.SRC.input1 + 3 }, { destCh = 1, source = Mock.SRC.input1 + 1 },
  { destCh = 2, source = Mock.SRC.input1 + 2 }, { destCh = 2, source = Mock.SRC.input1 + 4 },
  { destCh = 3, source = Mock.SRC.input1 + 0 },
}
local MIX_I5 = {
  { destCh = 0, source = Mock.SRC.input1 + 3 }, { destCh = 1, source = Mock.SRC.input1 + 1 },
  { destCh = 2, source = Mock.SRC.input1 + 4 }, { destCh = 3, source = Mock.SRC.input1 + 0 },
}
-- one input uses thr, but the throttle channel takes the raw stick / no mix uses the input
local MIX_RAW = {
  { destCh = 0, source = Mock.SRC.input1 + 3 }, { destCh = 1, source = Mock.SRC.input1 + 1 },
  { destCh = 2, source = Mock.SRC.thr }, { destCh = 3, source = Mock.SRC.input1 + 0 },
}
local MIX_UNUSED = {
  { destCh = 0, source = Mock.SRC.input1 + 3 }, { destCh = 1, source = Mock.SRC.input1 + 1 },
  { destCh = 2, source = Mock.SRC.sa }, { destCh = 3, source = Mock.SRC.input1 + 0 },
}
-- CH3 takes only the raw stick, input 3 feeds CH6; CH3 takes input 3 with weight -100
local MIX_RAW_CH6 = {
  { destCh = 0, source = Mock.SRC.input1 + 3 }, { destCh = 1, source = Mock.SRC.input1 + 1 },
  { destCh = 2, source = Mock.SRC.thr }, { destCh = 3, source = Mock.SRC.input1 + 0 },
  { destCh = 5, source = Mock.SRC.input1 + 2 },
}
local MIX_NEGW = {
  { destCh = 0, source = Mock.SRC.input1 + 3 }, { destCh = 1, source = Mock.SRC.input1 + 1 },
  { destCh = 2, source = Mock.SRC.input1 + 2, weight = -100 }, { destCh = 3, source = Mock.SRC.input1 + 0 },
}
-- TAER channel order on the AETR radio with a small Thr -> elevator mix on CH3
local MIX_TAER_COMP = {
  { destCh = 0, source = Mock.SRC.input1 + 2 }, { destCh = 1, source = Mock.SRC.input1 + 3 },
  { destCh = 2, source = Mock.SRC.input1 + 1 }, { destCh = 2, source = Mock.SRC.thr, weight = 5 },
  { destCh = 3, source = Mock.SRC.input1 + 0 },
}
-- CH3 takes input 3, CH6 takes it with weight -50
local MIX_NEGW_CH6 = {
  { destCh = 0, source = Mock.SRC.input1 + 3 }, { destCh = 1, source = Mock.SRC.input1 + 1 },
  { destCh = 2, source = Mock.SRC.input1 + 2 }, { destCh = 3, source = Mock.SRC.input1 + 0 },
  { destCh = 5, source = Mock.SRC.input1 + 2, weight = -50 },
}
-- a mix line with the source "---" (srcRaw 0) on CH1: the Lua mix list stops there, so the
-- CH3 line that takes input 3 is not seen (the colour mixer still uses it)
local MIX_HIDDEN = {
  { destCh = 0, source = Mock.SRC.input1 + 3 }, { destCh = 0, source = 0 },
  { destCh = 1, source = Mock.SRC.input1 + 1 }, { destCh = 2, source = Mock.SRC.input1 + 2 },
  { destCh = 3, source = Mock.SRC.input1 + 0 },
}
-- thr in inputs 3 and 5: CH3 takes input 3 and the raw stick, CH9 takes input 5
local MIX_TWO_RAW = {
  { destCh = 0, source = Mock.SRC.input1 + 3 }, { destCh = 1, source = Mock.SRC.input1 + 1 },
  { destCh = 2, source = Mock.SRC.input1 + 2 }, { destCh = 2, source = Mock.SRC.thr },
  { destCh = 3, source = Mock.SRC.input1 + 0 }, { destCh = 8, source = Mock.SRC.input1 + 4 },
}
-- TAER channel order on the AETR radio: CH1 = input 3 (throttle), CH3 = input 2
local MIX_TAER = {
  { destCh = 0, source = Mock.SRC.input1 + 2 }, { destCh = 1, source = Mock.SRC.input1 + 3 },
  { destCh = 2, source = Mock.SRC.input1 + 1 }, { destCh = 3, source = Mock.SRC.input1 + 0 },
}
local THR_I5 = { { chn = 4, source = Mock.SRC.thr, weight = 90, offset = -10 } }
local REFUSED = {
  { "CH3 takes the raw Thr stick", { mixes = MIX_RAW }, "unsupported", "CH3 uses raw Thr" },
  { "no mix uses input 3", { mixes = MIX_UNUSED }, "unsupported", "Thr input not in mixes" },
  { "a '---' mix line on CH1 hides the CH3 mix", { mixes = MIX_HIDDEN }, "unsupported", "Thr input not in mixes" },
  { "CH3 takes only the raw stick, input 3 feeds CH6", { mixes = MIX_RAW_CH6 }, "unsupported", "CH3 uses raw Thr" },
  { "TAER, a Thr -> elevator mix on CH3", { mixes = MIX_TAER_COMP }, "unsupported", "CH3 uses raw Thr" },
  { "CH3 takes input 3 with weight -100", { mixes = MIX_NEGW }, "unsupported", "CH3 inverts the Thr input" },
  { "CH6 takes input 3 with weight -50", { mixes = MIX_NEGW_CH6 }, "unsupported", "CH6 inverts the Thr input" },
  { "thr in inputs 3 and 5, CH3 takes input 3 and the raw stick",
    { extra = { { chn = 4, source = Mock.SRC.thr } }, mixes = MIX_TWO_RAW }, "unsupported", "Thr in 2 inputs" },
  { "thr in inputs 3 and 5, CH3 mixes input 3", { extra = THR_I5 }, "unsupported", "Thr in 2 inputs" },
  { "thr in inputs 3 and 5, CH3 mixes input 5", { extra = THR_I5, mixes = MIX_I5 }, "unsupported", "Thr in 2 inputs" },
  { "a switch on the line", { thr = { L({ switch = 5 }) } }, "unsupported", "Thr input not simple" },
  { "a flight mode mask", { thr = { L({ flightModes = 2 }) } }, "unsupported", "Thr input not simple" },
  { "side positive only", { thr = { L({ side = 2 }) } }, "unsupported", "Thr input not simple" },
  { "two lines", { thr = { L(), L({ switch = 5, weight = 50, offset = -50 }) } }, "unsupported", "Thr input has 2 lines" },
  { "line 0 not thr", { thr = { L({ source = Mock.SRC.s1 }), L() } }, "unsupported", "Thr input has 2 lines" },
  { "weight from GVAR1", { thr = { L({ weight = 1024 + Mock.SRC.gvar1 }) } }, "unsupported", "Weight uses GVAR" },
  { "offset from GVAR1", { thr = { L({ offset = 1024 + Mock.SRC.gvar1 }) } }, "unsupported", "Offset uses GVAR" },
  { "inverted source", { thr = { L({ source = -Mock.SRC.thr }) } }, "unsupported", "Thr source inverted" },
  { "function curve", { thr = { L({ curveType = 2, curveValue = 1 }) } }, "unsupported", "Thr input has a curve" },
  { "weight 0", { thr = { L({ weight = 0, offset = -100 }) } }, "unsupported", "Thr weight 0 or less" },
  { "thr in inputs 3 and 5, CH3 mixes both", { extra = { { chn = 4, source = Mock.SRC.thr } }, mixes = MIX_BOTH },
    "unsupported", "Thr in 2 inputs" },
  { "no input uses thr", { thr = { L({ source = Mock.SRC.s1 }) } }, "none", "No throttle input" },
  { "no model input API", false, "none", "No input API" },
}

scenario("cap-refuse", "unsupported throttle inputs and mixes: reason shown, model never written; user models, custom, failures", function(t)
  for _, c in ipairs(REFUSED) do
    local tag = c[1]
    local R, fake = world(t, { model = c[2] and Mock.userModel(1, c[2]) or false })
    if not R then return end
    local inst = stdCreate(R)
    local app = appOf(R, inst)
    runChecked(t, R, inst, 40)
    if inst.dead or not app or not app.T then t:fail(tag .. ": no usable instance") finish(t, R, fake, {}) return end
    local T = app.T
    t:check(T.state == c[3] and T.msg == c[4], sformat("%s: T should be %s %q, is %s %q", tag, c[3], c[4],
      tostring(T.state), tostring(T.msg)))
    t:check(T.cap == 0 and capLineObj(R, inst) == nil, tag .. ": no cap and no cap line on the dashboard")
    local snap = R:modelSnapshot()
    openThrottle(t, R, inst, tag)
    t:check(hasText(R, inst, c[4]), sformat("%s: the page should show %q (texts: %s)", tag, c[4], visibleTexts(R, inst)))
    t:check(btnText(R, inst, "60%") == nil and btnText(R, inst, "Set") == nil and #R:objects(inst, "numberEdit", true) == 0,
      tag .. ": no cap controls on the page")
    if tag == "a switch on the line" then
      R:dump(inst, "cap_refuse_page")
      layoutReport(t, R, inst, "fail", tag)
    end
    -- a request made anyway (as a callback would) is dropped, nothing is written
    R:_callback(inst, "request", function() app.mods.thrcap.request(app.T, 60) end)
    R:cycle(20)
    t:check(T.pending == nil, tag .. ": the request should be dropped")
    if R.mdl then
      t:check(#R.mdl.writes == 0 and R:modelSnapshot() == snap, sformat("%s: the model must not be written (%d write calls)",
        tag, #R.mdl.writes))
    end
    R:exitFullScreen(inst)
    R:cycle(3)
    finish(t, R, fake, {})
  end

  -- supported variants and write failures
  local function variant(tag, over, fn)
    local R, fake = world(t, { model = Mock.userModel(1, over) })
    if not R then return end
    local inst = stdCreate(R)
    local app = appOf(R, inst)
    runChecked(t, R, inst, 40)
    if inst.dead or not app or not app.T then t:fail(tag .. ": no usable instance") finish(t, R, fake, {}) return end
    fn(R, inst, app, app.T)
    finish(t, R, fake, {})
  end
  -- the user's four models pass every rule of the cap
  for mi, um in ipairs(Mock.USER_MODELS) do
    local tag = sformat("user model %q", um.name)
    local R, fake = world(t, { model = Mock.userModel(mi) })
    if not R then return end
    local inst = stdCreate(R)
    local app = appOf(R, inst)
    runChecked(t, R, inst, 40)
    if inst.dead or not app or not app.T then t:fail(tag .. ": no usable instance") finish(t, R, fake, {}) return end
    local T = app.T
    t:check(T.state == "ok" and T.msg == "Ready" and T.input == 2 and T.cap == um.w,
      sformat("%s: T should be ok \"Ready\" on input 3 with cap %d, is %s %q input %s cap %s", tag, um.w,
        tostring(T.state), tostring(T.msg), tostring(T.input), tostring(T.cap)))
    t:check(#R.mdl.writes == 0, tag .. ": reading the model must not write it")
    finish(t, R, fake, {})
  end
  -- a TAER model: the throttle input is on CH1, not on the radio's throttle channel CH3
  variant("TAER model, input 3 on CH1", { mixes = MIX_TAER }, function(R, inst, app, T)
      t:check(T.state == "ok" and T.input == 2 and T.cap == 75, sformat("TAER: T should be ok on input 3 (cap 75), is %s %q",
        tostring(T.state), tostring(T.msg)))
      openThrottle(t, R, inst, "TAER")
      tap(t, R, inst, "60%", "TAER")
      R:cycle(12)
      t:check(lineTxt(thrLine(R)) == "60/-40", "TAER: preset 60% should write 60/-40, input 3 is " .. lineTxt(thrLine(R)))
    end)
  -- an expo curve keeps the end points: allowed and copied
  variant("expo 30", { thr = { L({ curveValue = 30 }) } }, function(R, inst, app, T)
    t:check(T.state == "ok" and T.cap == 75, "expo 30: the cap should be readable")
    openThrottle(t, R, inst, "expo 30")
    tap(t, R, inst, "60%", "expo 30")
    R:cycle(12)
    local l = thrLine(R)
    t:check(lineTxt(l) == "60/-40" and l.curveType == 1 and l.curveValue == 30, "expo 30: the swap should keep the expo, line is "
      .. lineTxt(l) .. " curve " .. tostring(l and l.curveType) .. "/" .. tostring(l and l.curveValue))
  end)
  -- a custom line (weight/offset not W / W-100): shown as custom, a preset replaces it
  variant("custom 80/-10", { thr = { L({ weight = 80, offset = -10 }) } }, function(R, inst, app, T)
    t:check(T.state == "ok" and T.custom == true and T.cap == 0 and T.weight == 80 and T.offset == -10,
      "custom: T.custom with weight 80 offset -10 expected")
    t:check(capLineObj(R, inst) == nil, "custom: no cap line on the dashboard")
    openThrottle(t, R, inst, "custom")
    t:check(hasText(R, inst, "Custom 80/-10"), "custom: the page should show 'Custom 80/-10' (texts: " .. visibleTexts(R, inst) .. ")")
    local minus = btnText(R, inst, "-5")
    t:check(minus ~= nil and not minus.enabled, "custom: -5 should be inactive")
    layoutReport(t, R, inst, "fail", "custom page")
    R:dump(inst, "cap_custom_page")
    tap(t, R, inst, "70%", "custom")
    R:cycle(12)
    t:check(lineTxt(thrLine(R)) == "70/-30" and T.custom == false and T.cap == 70, "custom: a preset should replace the line, is "
      .. lineTxt(thrLine(R)))
  end)
  -- all 64 input lines used: the insert is refused, nothing changes
  local extra = {}
  for c = 4, 23 do
    for _ = 1, 3 do extra[#extra + 1] = { chn = c, source = Mock.SRC.s1 } end
  end
  variant("64 lines used", { extra = extra }, function(R, inst, app, T)
    local snap = R:modelSnapshot()
    openThrottle(t, R, inst, "64 lines")
    tap(t, R, inst, "60%", "64 lines")
    R:cycle(12)
    t:check(T.msg == "No free input line (64 used)" and T.state == "error", "64 lines: T.msg should say so, is " .. tostring(T.msg))
    t:check(hasText(R, inst, "No free input line"), "64 lines: the reason should be shown")
    t:check(R:modelSnapshot() == snap, "64 lines: the model must not change")
  end)
  -- write failures: the extra line goes again, the old line stays live
  for _, f in ipairs({ { "insert error after 3 fields", { insertError = 3 }, "Insert failed" },
                       { "delete does nothing once", { deleteNoop = 1 }, "Delete failed" },
                       { "delete error once", { deleteError = 1 }, "Delete failed" },
                       { "read-back mismatch", { insertCorrupt = "weight" }, "Read-back mismatch" } }) do
    local spec = Mock.userModel(1)
    spec.inj = f[2]
    local R, fake = world(t, { model = spec })
    if not R then return end
    local inst = stdCreate(R)
    local app = appOf(R, inst)
    runChecked(t, R, inst, 40)
    local snap = R:modelSnapshot()
    openThrottle(t, R, inst, f[1])
    tap(t, R, inst, "60%", f[1])
    R:cycle(12)
    t:check(app.T.msg == f[3] and app.T.state == "error", sformat("%s: T.msg should be %q, is %q", f[1], f[3], tostring(app.T.msg)))
    t:check(R:modelSnapshot() == snap and #R:inputLines(THR_CHN) == 1, f[1] .. ": the model should be as before (one line 75/-25), "
      .. "input 3 is " .. lineTxt(thrLine(R)) .. " with " .. #R:inputLines(THR_CHN) .. " lines")
    t:check(not inst.dead, f[1] .. ": the widget must stay alive")
    finish(t, R, fake, {})
  end
  -- a model change before the debounce: the request is dropped, no model is written
  local R, fake = world(t, {})
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  runChecked(t, R, inst, 40)
  openThrottle(t, R, inst, "model change")
  tap(t, R, inst, "60%", "model change")
  R:cycle(1)
  R:loadModel(Mock.userModel(2))
  R:cycle(20)
  t:check(#R.mdl.writes == 0 and lineTxt(thrLine(R)) == "50/-50", "model change: nothing should be written (input 3 of 'sim' is "
    .. lineTxt(thrLine(R)) .. ")")
  t:check(app.T.cap == 50 and app.T.pending == nil, "model change: T should show the new model's cap 50, is " .. tostring(app.T.cap))
  finish(t, R, fake, {})
end)

-- (cap-line) the cap line on the dashboard
scenario("cap-line", "dashboard cap line at 75 % on the throttle box in stick modes 1-4; 50 %; hidden at 100 %", function(t)
  local function lineCheck(tag, R, inst, cap, mode)
    local boxes, dots = gimbals(R, inst)
    local ln = capLineObj(R, inst)
    if not t:check(#boxes == 2 and ln ~= nil, sformat("%s: two gimbal boxes and the cap line expected (boxes %d, line %s)", tag,
      #boxes, tostring(ln ~= nil))) then return end
    local side = (mode == 1 or mode == 3) and 2 or 1
    local bx, by, bw, bh = R:absRect(boxes[side])
    local lx, ly, lw, lh = R:absRect(ln)
    t:check(lx == bx + 2 and lw == bw - 4, sformat("%s: the line should be inside the %s box (line x %d w %d, box x %d w %d)",
      tag, side == 1 and "left" or "right", lx, lw, bx, bw))
    t:check(ly > by and ly + lh < by + bh, sformat("%s: the line should be inside the box height (line y %d, box y %d h %d)", tag,
      ly, by, bh))
    -- the throttle dot shows the throttle output (the cap applied): at full stick it sits
    -- on the line, and no stick position puts it above the line
    local lc = ly + lh / 2
    local worst = nil
    for sv = -1024, 1024, 256 do
      R:setSource("thr", sv)
      R:cycle(3)
      local d = dotIn(R, boxes[side], dots)
      if not t:check(d ~= nil, tag .. ": throttle dot found") then break end
      local _, dy = R:absRect(d)
      local dc = dy + 4.5
      if worst == nil or dc < worst then worst = dc end
      if sv == 1024 then
        t:check(math.abs(dc - lc) <= 1.5, sformat("%s: at full stick the dot centre (%.1f) should be on the line (%.1f)",
          tag, dc, lc))
      end
    end
    if worst ~= nil then
      t:check(worst >= lc - 1.5, sformat("%s: the dot (centre %.1f) must never go above the line (%.1f)", tag, worst, lc))
    end
    local lab = capLabel(R, inst, cap)
    if t:check(lab ~= nil, tag .. ": label " .. cap .. "% expected") then
      local tx, ty, tw, th = R:labelInk(lab)
      t:check(math.abs((ty + th / 2) - (ly + lh / 2)) <= 8, sformat("%s: the label (y %d) should be next to the line (y %d)", tag, ty, ly))
      local b1x, _, b1w = R:absRect(boxes[1])
      local b2x, _, b2w = R:absRect(boxes[2])
      t:check(tx >= b1x and tx + tw <= b2x + b2w, tag .. ": the label should be between the boxes or inside one")
    end
  end
  for mode = 1, 4 do
    local tag = "mode " .. mode
    local R, fake = world(t, { stickMode = mode })
    if not R then return end
    local inst = stdCreate(R)
    runChecked(t, R, inst, 40)
    lineCheck(tag, R, inst, 75, mode)
    layoutReport(t, R, inst, "fail", tag)
    R:dump(inst, "cap_line_mode" .. mode)
    finish(t, R, fake, {})
  end
  -- 50 % (model "sim"): the middle of the travel
  local R, fake = world(t, { model = Mock.userModel(2) })
  if not R then return end
  local inst = stdCreate(R)
  runChecked(t, R, inst, 40)
  lineCheck("sim 50 %", R, inst, 50, 2)
  finish(t, R, fake, {})
  -- 100 % (model "100% pro"): no line, no label
  R, fake = world(t, { model = Mock.userModel(3) })
  if not R then return end
  inst = stdCreate(R)
  local app = appOf(R, inst)
  runChecked(t, R, inst, 40)
  t:check(app.T.cap == 100 and capLineObj(R, inst) == nil and capLabel(R, inst, 100) == nil,
    "100 %: no cap line and no label")
  -- the line follows a change made on the page
  openThrottle(t, R, inst, "100 %")
  tap(t, R, inst, "60%", "100 %")
  R:cycle(12)
  R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
  R:cycle(4)
  lineCheck("100 % -> 60 %", R, inst, 60, 2)
  -- light theme and no trims: still drawn on the throttle box
  R:setOptions(inst, { darkTheme = 0, hideTrims = 1 })
  R:cycle(4)
  t:check(capLineObj(R, inst) ~= nil, "light theme, no trims: the cap line should still be drawn")
  layoutReport(t, R, inst, "fail", "light, no trims")
  finish(t, R, fake, {})
end)

-- (cap-vtxoff) VTX control off: full screen is the Throttle page only
scenario("cap-vtxoff", "VTX control off: full screen shows only the Throttle page; the cap works; no CRSF", function(t)
  local R, fake = world(t, {})
  if not R then return end
  local inst = stdCreate(R, { options = { vtxOff = 1 } })
  local app = appOf(R, inst)
  runChecked(t, R, inst, 60)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  R:enterFullScreen(inst)
  R:cycle(4)
  t:check(buttonList(R, inst) == THR_ONLY_BUTTONS, "vtxOff: buttons should be " .. THR_ONLY_BUTTONS .. ", are " .. buttonList(R, inst))
  t:check(btnText(R, inst, "VTX") == nil and btnText(R, inst, "Throttle") == nil and btnText(R, inst, "Apply & Send") == nil,
    "vtxOff: no tabs and no VTX controls")
  t:check(hasText(R, inst, "Throttle cap"), "vtxOff: page title 'Throttle cap'")
  t:check(R:findText(inst, "^75%%$") ~= nil, "vtxOff: the cap 75% shown")
  layoutReport(t, R, inst, "fail", "vtxOff page")
  R:dump(inst, "cap_vtxoff_page")
  tap(t, R, inst, "60%", "vtxOff")
  R:cycle(12)
  t:check(lineTxt(thrLine(R)) == "60/-40", "vtxOff: preset 60% should write 60/-40, input 3 is " .. lineTxt(thrLine(R)))
  tap(t, R, inst, "Back", "vtxOff")
  R:cycle(4)
  t:check(not inst.fullscreen and #R:buttons(inst, false) == 0, "vtxOff: Back should leave full screen")
  t:check(capLineObj(R, inst) ~= nil and capLabel(R, inst, 60) ~= nil, "vtxOff: the dashboard line should follow (60%)")
  R:enterFullScreen(inst)
  R:cycle(4)
  t:check(buttonList(R, inst) == THR_ONLY_BUTTONS, "vtxOff: second visit shows the Throttle page again")
  R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
  R:cycle(4)
  t:check(R.crsf.pushCalls == 0 and R.crsf.popCalls == 0, sformat("vtxOff: no CRSF calls (push %d, pop %d)", R.crsf.pushCalls,
    R.crsf.popCalls))
  finish(t, R, fake, { instrLimits = { 14000, 8000 } })
end)

-- (fs-loop) App-mode enter/exit loops with option changes: nothing clickable stays visible
scenario("fs-loop", "App-mode full-screen loops with option changes: no visible clickable object outside full screen", function(t)
  local R, fake = world(t, {})
  if not R then return end
  local inst = stdCreate(R)
  local app = appOf(R, inst)
  runChecked(t, R, inst, 60)
  if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
  local OPTS = {
    { vtxOff = 1 }, { darkTheme = 0 }, { vtxOff = 0 }, { hideTrims = 1 }, { transpLevel = 2 },
    { hideTrims = 0, darkTheme = 1 }, { rxCells = 4 }, { vtxOff = 1, transpLevel = 4 }, { vtxOff = 0, rxCells = 0 },
  }
  local oi = 0
  local function nextOpts()
    oi = oi % #OPTS + 1
    return OPTS[oi]
  end
  local maxLive = 0
  for i = 1, 30 do
    R:enterFullScreen(inst)
    R:cycle(3)
    if i % 2 == 0 and btnText(R, inst, "Throttle") then tap(t, R, inst, "Throttle", "loop " .. i); R:cycle(1) end
    if i % 3 == 0 and btnText(R, inst, "VTX") then tap(t, R, inst, "VTX", "loop " .. i); R:cycle(1) end
    if i % 5 == 0 and btnText(R, inst, "90%") then tap(t, R, inst, "90%", "loop " .. i); R:cycle(1) end
    if i % 4 == 0 then
      R:setOptions(inst, nextOpts())     -- settings changed while full screen
      R:cycle(2)
    end
    local how = i % 3
    if how == 0 and btnText(R, inst, "Back") then tap(t, R, inst, "Back", "loop " .. i)
    elseif how == 1 then R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
    else R:exitFullScreen(inst) end
    R:cycle(3)
    t:check(not inst.fullscreen, sformat("loop %d: full screen not left", i))
    t:check(#R:buttons(inst, false) == 0, sformat("loop %d: buttons remain after the exit", i))
    local cl = R:clickables(inst)
    t:check(#cl == 0, sformat("loop %d: %d visible clickable objects on the dashboard (first %s)", i, #cl,
      cl[1] and Mock.objDesc(cl[1]) or "-"))
    t:check(#R:objects(inst, "label", true) >= 8, sformat("loop %d: the dashboard should be shown", i))
    if i % 2 == 1 then
      R:setOptions(inst, nextOpts())     -- settings changed on the dashboard
      R:cycle(2)
    end
    if #R:objects(inst) > maxLive then maxLive = #R:objects(inst) end
  end
  t:metric("live objects max over the loops", maxLive)
  t:check(maxLive < 400, "live objects should stay bounded, max " .. maxLive)
  -- control: the check finds a box made in full screen that stays visible on the dashboard
  local R2 = world(t, {})
  if R2 then
    local i2 = stdCreate(R2)
    R2:cycle(5)
    R2:enterFullScreen(i2)
    R2:cycle(2)
    R2.current = i2
    R2.env.lvgl.box({ x = 0, y = 0, w = 50, h = 50 })
    R2.current = nil
    R2:exitFullScreen(i2)
    R2:cycle(3)
    t:check(#i2.clickIssues > 0, "control: a box made in full screen and left visible should be reported")
  end
  finish(t, R, fake, { instrLimits = { 14000, 8000 }, dumpName = "fs_loop" })
end)

-- (fs-touch) every control of the full-screen pages can be tapped with a finger: an LVGL-order
-- hit test (children searched from the last to the first, a clickable parent takes a point that
-- no child takes) at the centre of each visible control must reach that control. A box made in
-- full screen is clickable, so a box above the header buttons would take their taps.
scenario("fs-touch", "full-screen touch: each visible control gets a tap at its centre (vtxOff 0/1, both tabs)", function(t)
  -- a tap at the centre of the button with this text, through the hit test
  local function touch(R, inst, text, tag)
    local b = btnText(R, inst, text)
    if not b then
      t:fail(sformat("%s: button %q not visible (buttons: %s)", tag, text, buttonList(R, inst)))
      return false
    end
    local cx, cy = R:centre(b)
    local hit = R:hitTest(inst, cx, cy)
    if not t:check(hit == b, sformat("%s: a tap on %q at %d,%d goes to %s", tag, text, cx, cy,
                                     hit and Mock.objDesc(hit) or "the widget")) then
      return false
    end
    local ok, why = R:press(inst, hit)
    return t:check(ok, sformat("%s: cannot press %q: %s", tag, text, tostring(why)))
  end
  local function allReachable(R, inst, tag)
    local n = #R:buttons(inst, true)
    t:check(n > 0, tag .. ": no visible button")
    for _, p in ipairs(R:touchProblems(inst)) do t:fail(tag .. ": " .. p.msg) end
  end
  local cases = {
    { tag = "vtxOff 0", opts = {} },
    { tag = "vtxOff 1", opts = { vtxOff = 1 } },
    { tag = "vtxOff 0, 480x272", opts = {}, w = 480, h = 272 },
    { tag = "vtxOff 0, no throttle input", opts = {},
      model = Mock.userModel(1, { thr = { { source = Mock.SRC.s1 } } }) },
    { tag = "vtxOff 1, no throttle input", opts = { vtxOff = 1 },
      model = Mock.userModel(1, { thr = { { source = Mock.SRC.s1 } } }) },
    { tag = "vtxOff 0, no ELRS module", opts = {}, module = false },
  }
  for _, c in ipairs(cases) do
    local R, fake = world(t, { model = c.model, module = c.module, lcdW = c.w, lcdH = c.h })
    if not R then return end
    local inst = stdCreate(R, { options = c.opts, w = c.w, h = c.h })
    local app = appOf(R, inst)
    runChecked(t, R, inst, 60)
    if inst.dead or not app then t:fail(c.tag .. ": no usable instance") finish(t, R, fake, {}) return end
    for visit = 1, 2 do
      local tag = sformat("%s, visit %d", c.tag, visit)
      R:enterFullScreen(inst)
      R:cycle(4)
      if app.vtxOn then
        t:check(app.tabs.vtx == true, tag .. ": the VTX tab is shown first")
        allReachable(R, inst, tag .. ", VTX tab")
        if touch(R, inst, "Throttle", tag) then
          R:cycle(2)
          t:check(app.tabs.thr == true, tag .. ": a tap on Throttle shows the Throttle tab")
        end
        allReachable(R, inst, tag .. ", Throttle tab")
        if touch(R, inst, "VTX", tag) then
          R:cycle(2)
          t:check(app.tabs.vtx == true, tag .. ": a tap on VTX shows the VTX tab")
        end
        allReachable(R, inst, tag .. ", VTX tab again")
        if visit == 2 and touch(R, inst, "Throttle", tag) then R:cycle(2) end
      else
        t:check(app.tabs.thr == true and btnText(R, inst, "VTX") == nil, tag .. ": only the Throttle page")
        allReachable(R, inst, tag .. ", Throttle page")
      end
      if touch(R, inst, "Back", tag) then
        R:cycle(4)
        t:check(not inst.fullscreen, tag .. ": a tap on Back leaves full screen")
      end
      if inst.fullscreen then
        R:exitFullScreen(inst)
        R:cycle(3)
      end
    end
    finish(t, R, fake, { instrLimits = { 14000, 8000 } })
  end
  -- control: the hit test sees a button that a box made later covers
  local R2 = world(t, {})
  if R2 then
    local i2 = stdCreate(R2)
    R2:cycle(5)
    R2:enterFullScreen(i2)
    R2:cycle(2)
    R2.current = i2
    local L = R2.env.lvgl
    local root = L.box({ x = 0, y = 0, w = 480, h = 320 })
    L.button(root, { x = 10, y = 10, w = 60, h = 30, text = "Under", press = function() end })
    L.box(root, { x = 0, y = 0, w = 480, h = 320 })
    R2.current = nil
    local found = false
    for _, p in ipairs(R2:touchProblems(i2)) do
      if p.obj.props.text == "Under" then found = true end
    end
    t:check(found, "control: a button under a later full-size box should be reported")
  end
end)

-- (cap-cpu) CPU with the Throttle page open, swaps, VTX traffic and telemetry
scenario("cap-cpu", "CPU with the Throttle page open: refresh max < 14000, average < 8000, swap cycles", function(t)
  for _, sz in ipairs({ { 480, 320 }, { 480, 272 } }) do
    local tag = sformat("%dx%d", sz[1], sz[2])
    local R, fake = world(t, { lcdW = sz[1], lcdH = sz[2] })
    if not R then return end
    local inst = stdCreate(R, { w = sz[1], h = sz[2] })
    local app = appOf(R, inst)
    if inst.dead or not app then t:fail("no usable instance") finish(t, R, fake, {}) return end
    runChecked(t, R, inst, 200, function() return app.V and app.V.ready end)
    openThrottle(t, R, inst, tag)
    -- the Throttle page layout at this size: no overlapping or clipped object, every
    -- control on the screen (checked again below with a pending value shown)
    local function noOverlaps(what)
      for _, r in ipairs(R:layoutCheck(inst)) do
        if r.severe or string.find(r.msg, "overlap", 1, true) or string.find(r.msg, "clipped", 1, true) then
          t:fail(sformat("%s %s: layout: %s", tag, what, r.msg))
        end
      end
      local ctl = R:buttons(inst, true)
      for _, e in ipairs(R:objects(inst, "numberEdit", true)) do ctl[#ctl + 1] = e end
      t:check(#ctl >= 11, sformat("%s %s: Throttle page controls expected, saw %d", tag, what, #ctl))
      for _, b in ipairs(ctl) do
        local x, y, w, h = R:absRect(b)
        t:check(x >= 0 and y >= 0 and x + w <= sz[1] and y + h <= sz[2],
          sformat("%s %s: %s %q outside the screen (%d,%d %dx%d)", tag, what, b.kind, tostring(b.props.text),
            x, y, w, h))
      end
    end
    noOverlaps("Throttle page")
    tap(t, R, inst, "60%", tag)
    R:cycle(1)
    t:check(R:findText(inst, "^Pending: 60%%$") ~= nil, tag .. ": pending value shown")
    noOverlaps("Throttle page, pending")
    R:dump(inst, sformat("cap_cpu_%d_page", sz[2]))
    runChecked(t, R, inst, 12)
    t:check(thrLine(R) and thrLine(R).weight == 60, tag .. ": 60 % written, line is " .. lineTxt(thrLine(R)))
    local first = #inst.instr.refresh + 1
    local TAPS = { "60%", "+5", "+5", "80%", "-5", "50%", "100%", "75%", "-5", "90%" }
    local swaps, swapMax = 0, 0
    for i = 1, 400 do
      if i % 15 == 1 then tap(t, R, inst, TAPS[(i // 15) % #TAPS + 1], tag) end
      R:setSource("thr", ((i * 331) % 2049) - 1024)
      R:setSource("ail", ((i * 173) % 2049) - 1024)
      if i % 5 == 0 then
        R:setSensor("RQly", 90 + i % 10)
        R:setSensor("RxBt", 16.0 + (i % 7) / 10)
        R:setSensor("1RSS", -40 - i % 30)
      end
      local w0, r0 = #R.mdl.writes, #inst.instr.refresh
      R:cycle(1)
      if #R.mdl.writes > w0 then
        swaps = swaps + 1
        for k = r0 + 1, #inst.instr.refresh do
          if inst.instr.refresh[k] > swapMax then swapMax = inst.instr.refresh[k] end
        end
      end
    end
    local s = Mock.statsOf(inst.instr.refresh, first)
    t:metric(tag .. " Throttle page refresh max/avg (n)", sformat("%d / %d (%d)", s.max, floor(s.avg + 0.5), s.n))
    t:metric(tag .. " swap cycles / max instructions", sformat("%d / %d", swaps, swapMax))
    t:check(swaps >= 20, sformat("%s: at least 20 swaps expected, saw %d", tag, swaps))
    t:check(s.max < 14000, sformat("%s: refresh max %d on the Throttle page (limit 14000)", tag, s.max))
    t:check(s.avg < 8000, sformat("%s: refresh average %d on the Throttle page (limit 8000)", tag, floor(s.avg)))
    t:check(swapMax < 14000, sformat("%s: a swap cycle used %d instructions (limit 14000)", tag, swapMax))
    local cb = R:instrStats(inst, "callback")
    t:check(cb.max < 2000, sformat("%s: a button callback used %d instructions", tag, cb.max))
    finish(t, R, fake, { instrLimits = { 14000, 8000 } })
  end
end)

---------------------------------------------------------------------------
-- self-test mode
---------------------------------------------------------------------------

if ARGS.selftest then
  SCENARIOS = {}
  local H = { Mock = Mock, Fake = Fake, scenario = scenario, newT = newT, world = world, finish = finish,
              classify = classify, press = press, layoutReport = layoutReport, contractProblems = contractProblems,
              runChecked = runChecked, TESTS = TESTS, ARGS = ARGS }
  dofile(TESTS .. "/unit/harness_selftest.lua")(H)
end

---------------------------------------------------------------------------
-- main
---------------------------------------------------------------------------

if ARGS.list then
  for _, s in ipairs(SCENARIOS) do print(sformat("%-10s %s", s.id, s.title)) end
  os.exit(0)
end

local report = {}
local function out(line)
  print(line)
  report[#report + 1] = line
end

out(sformat("FPVDASH test harness  (%s, mode %s)  %s", ARGS.selftest and "SELF-TEST" or WIDGET_DIR, ARGS.mode,
  os.date("%Y-%m-%d %H:%M:%S")))
out(sformat("meter calibration: api %d, callback %d, top %d", Mock.calibration.apiOverhead, Mock.calibration.cbOverhead,
  Mock.calibration.topOverhead))
local npass, nfail = 0, 0
local t0 = os.clock()
for _, s in ipairs(SCENARIOS) do
  if not ARGS.only or ARGS.only[s.id] then
    local t = newT(s.id, s.title)
    local c0 = os.clock()
    local ok, err = xpcall(s.fn, debug.traceback, t)
    Mock.installStringTrap(false)
    if not ok then t:fail("harness error: " .. tostring(err)) end
    local pass = (#t.fails == 0)
    if pass then npass = npass + 1 else nfail = nfail + 1 end
    out(sformat("%s  %-9s %s  (%.1f s)", pass and "PASS" or "FAIL", s.id, s.title, os.clock() - c0))
    for _, m in ipairs(t.metrics) do out(sformat("      metric  %s: %s", m[1], fmtNum(m[2]))) end
    local maxf = ARGS.verbose and 1000 or 25
    for i, f in ipairs(t.fails) do
      if i <= maxf then out("      FAIL    " .. string.gsub(f, "\n", "\n              ")) end
    end
    if #t.fails > maxf then out(sformat("      FAIL    ... %d more (use --verbose)", #t.fails - maxf)) end
    if t.dupFails > 0 then out(sformat("      FAIL    (%d identical failure lines not repeated)", t.dupFails)) end
    local maxw = ARGS.verbose and 1000 or 8
    for i, w in ipairs(t.warns) do
      if i <= maxw then out("      warn    " .. w) end
    end
    if #t.warns > maxw then out(sformat("      warn    ... %d more (use --verbose)", #t.warns - maxw)) end
    if ARGS.verbose then
      for _, m in ipairs(t.infos) do out("      info    " .. m) end
    end
  end
end
out(sformat("SUMMARY: %d passed, %d failed  (%.1f s)", npass, nfail, os.clock() - t0))
Mock.writeFile(OUT .. "/" .. (ARGS.selftest and "selftest_report.txt" or "report.txt"), table.concat(report, "\n") .. "\n")
os.exit(nfail == 0 and 0 or 1)
