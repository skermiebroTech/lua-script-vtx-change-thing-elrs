-- tests/unit/integ_soak_test.lua : long random soak of the real FPVDASH widget.
--
--   cd "<root>" && lua tests/unit/integ_soak_test.lua [cycles]
--
-- Runs the widget from the SD card copy in the strict mock (tests/edgetx_mock.lua)
-- with the fake ELRS module (tests/fake_elrs.lua), in rc1 and in 2.12.x mode, with
-- several random seeds. Every cycle can bring a random event: link loss, new sensor
-- values, stick and trim moves, full screen enter/exit, page button presses, popup
-- answers, armed flag, RX link flag, external VTX changes, module reboot (silent),
-- CRSF off/on, a paused widget (tool open), option changes and zone changes.
--
-- The 3.4.2 runs also have a second instance on a hidden screen (background calls,
-- shown now and then).
--
-- Checks: the instance never dies, the DESIGN field contract holds, no global
-- writes, loadScript only in create, CPU limits (refresh max < 14000,
-- average < 8000, background < 14000), no ELRS protocol violations, the widget
-- tables do not grow, and after the chaos a normal Apply & Send still works.
-- Throttle cap: the random presses also hit the Throttle page (presets, -5/+5, Set,
-- number edits), so the model input line is swapped many times. The mixer emulation
-- of the mock must never see a glitch, every model write must come from refresh()
-- with integer arguments and one swap per call, wgt.T keeps its contract, and no
-- visible clickable object may stay on the dashboard outside full screen.
--
-- Harness rule: no string method syntax in this file (the mock traps it).
-- Exit code 0 when every check passes.

local function scriptDir()
  local src = string.gsub(debug.getinfo(1, "S").source, "^@", "")
  if string.sub(src, 1, 1) ~= "/" then src = (os.getenv("PWD") or ".") .. "/" .. src end
  return string.match(src, "^(.*)/[^/]*$") or "."
end
local UNIT = scriptDir()
local TESTS = string.match(UNIT, "^(.*)/[^/]*$")
local Mock = dofile(TESTS .. "/edgetx_mock.lua")
local Fake = dofile(TESTS .. "/fake_elrs.lua")
local C = Mock.C
local sformat = string.format
local floor = math.floor

local CYCLES = tonumber(arg and arg[1]) or 6000
local SEEDS = { 11, 23, 37 }
local WIDGET = "/WIDGETS/FPVDASH/"

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else
    failed = failed + 1
    print("FAIL: " .. msg)
  end
  return cond
end

---------------------------------------------------------------------------
-- small deterministic random generator (independent of math.random)
local function rng(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    s = (s * 16807) % 2147483647
    local r = (s - 1) / 2147483646
    if n then return floor(r * n) + 1 end
    return r
  end
end

---------------------------------------------------------------------------
-- contract (subset of tests/run.lua contractProblems)
local V_STATES = { off = true, nocrsf = true, search = true, noelrs = true, novtx = true, load = true,
                   ready = true, busy = true, error = true }
local V_SENDS = { idle = true, writing = true, sending = true, sent = true, queued = true,
                  notenabled = true, failed = true }
local function isInt(v) return type(v) == "number" and v == floor(v) end

local function contract(app)
  local P = {}
  local E, V, S = app.E, app.V, app.S
  if type(E.found) ~= "boolean" or type(E.label) ~= "string" or type(E.armed) ~= "boolean" then
    P[#P + 1] = "E fields"
  end
  if not V_STATES[V.state] then P[#P + 1] = "V.state " .. tostring(V.state) end
  if type(V.msg) ~= "string" or #V.msg > 30 then P[#P + 1] = "V.msg " .. tostring(V.msg) end
  if type(V.ready) ~= "boolean" then P[#P + 1] = "V.ready" end
  for _, k in ipairs({ "band", "channel", "power", "pit", "freq", "rev" }) do
    if not isInt(V[k]) then P[#P + 1] = "V." .. k .. " " .. tostring(V[k]) end
  end
  if isInt(V.channel) and (V.channel < 0 or V.channel > 8) then P[#P + 1] = "V.channel range" end
  if not V_SENDS[V.send] or type(V.sendMsg) ~= "string" then P[#P + 1] = "V.send " .. tostring(V.send) end
  for _, k in ipairs({ "bandLabels", "powerLabels", "pitLabels" }) do
    if type(V[k]) ~= "table" then P[#P + 1] = "V." .. k end
  end
  if type(S.connected) ~= "boolean" or type(S.modelName) ~= "string" then P[#P + 1] = "S fields" end
  local T = app.T
  if type(T) ~= "table" then
    P[#P + 1] = "wgt.T missing"
  else
    if T.state ~= "ok" and T.state ~= "none" and T.state ~= "unsupported" and T.state ~= "busy" and T.state ~= "error" then
      P[#P + 1] = "T.state " .. tostring(T.state)
    end
    if type(T.msg) ~= "string" or #T.msg > 30 then P[#P + 1] = "T.msg " .. tostring(T.msg) end
    if not isInt(T.cap) or T.cap < 0 or T.cap > 100 then P[#P + 1] = "T.cap " .. tostring(T.cap) end
    if type(T.custom) ~= "boolean" or not isInt(T.weight) or not isInt(T.offset) or not isInt(T.input)
       or not isInt(T.rev) then
      P[#P + 1] = "T fields"
    end
    if T.pending ~= nil and (not isInt(T.pending) or T.pending < 20 or T.pending > 100) then
      P[#P + 1] = "T.pending " .. tostring(T.pending)
    end
  end
  return P
end

-- number of table entries reachable from t (code modules and LVGL handles skipped)
local function entries(t, seen)
  seen = seen or {}
  if seen[t] then return 0 end
  seen[t] = true
  local n = 0
  for k, v in pairs(t) do
    n = n + 1
    if type(v) == "table" and k ~= "mods" and k ~= "_app" and k ~= "view" and k ~= "reg" then
      n = n + entries(v, seen)
    end
  end
  return n
end

---------------------------------------------------------------------------
local SENSORS = {
  { name = "1RSS", value = -45 }, { name = "2RSS", value = -48 }, { name = "RQly", value = 100 },
  { name = "RSNR", value = 9 }, { name = "ANT", value = 0 }, { name = "RFMD", value = 7 },
  { name = "TPWR", value = 250 }, { name = "TRSS", value = -50 }, { name = "TQly", value = 100 },
  { name = "TSNR", value = 8 }, { name = "FM", text = "ACRO" }, { name = "RxBt", value = 16.4, prec = 1 },
  { name = "Curr", value = 12.3, prec = 1 }, { name = "Capa", value = 850 }, { name = "Bat%", value = 76 },
}
local FMS = { "ACRO", "ANGLE", "HOR", "!FS!", "AIR", "MANUAL*", "" }
local ZONES = { { 480, 320 }, { 480, 272 }, { 430, 225 }, { 240, 137 }, { 480, 320 } }
local STICKS = { "rud", "ele", "thr", "ail" }
local TRIMS = { "trim-rud", "trim-ele", "trim-thr", "trim-ail" }

local function soak(mode, seed, version, two)
  local tag = sformat("[%s seed %d %s%s]", mode, seed, version, two and " 2 inst" or "")
  local rnd = rng(seed)
  local fake = Fake.new({ version = version, band = 4, channel = 2, power = 1, pit = 0, seed = seed,
                          chunk = (seed % 2 == 0) and 27 or 56, dropRate = 0.05 })
  local R = Mock.new({ mode = mode, module = fake, crsf = true })
  R:defineSensors(SENSORS)
  R:setStreaming(true)
  R:setTimer(1, { mode = 1, value = 125, start = 0, name = "" })
  R:setTimer(2, { mode = 1, value = 3725, start = 0, name = "" })
  R:setTimer(3, { mode = 0, value = 0, start = 0, name = "" })
  local wt, err = R:loadWidget(WIDGET)
  if not check(wt ~= nil, tag .. " widget loads: " .. tostring(err)) then return end
  local inst = R:createInstance({ w = 480, h = 320, appMode = true, visible = true })
  local app = R:app(inst)
  if not check(app ~= nil and not inst.dead, tag .. " instance created") then return end
  -- one seed also has a second instance on another (hidden) screen: background() only,
  -- shown now and then
  local inst2, app2 = nil, nil
  if two then
    inst2 = R:createInstance({ w = 480, h = 272, appMode = false, visible = false })
    app2 = R:app(inst2)
    check(app2 ~= nil and not inst2.dead, tag .. " second instance created")
  end

  local frozenUntil = nil
  local seenProblems = {}
  local sizeAt = {}
  local events = { fs = 0, press = 0, popup = 0, opts = 0, zone = 0, freeze = 0, silent = 0, crsf = 0, edit = 0 }

  for cyc = 1, CYCLES do
    local r = rnd()
    -- telemetry
    if r < 0.01 then
      R:setStreaming(not R.streaming)
    elseif r < 0.04 then
      R:setSensor("RQly", rnd(101) - 1)
      R:setSensor("TPWR", ({ 0, 10, 25, 100, 250, 500, 1000 })[rnd(7)])
      R:setSensor("RFMD", rnd(40) - 2)
      R:setSensor("RxBt", 3 + rnd() * 50)
      R:setSensor("1RSS", -rnd(120))
      R:setSensor("2RSS", -rnd(120))
      R:setSensor("RSNR", rnd(30) - 10)
      R:setSensor("Curr", rnd() * 120)
      R:setSensor("Capa", rnd(9000))
      R:setSensor("FM", FMS[rnd(#FMS)])
    end
    -- sticks and trims
    if rnd() < 0.2 then
      R:setSource(STICKS[rnd(4)], rnd(2049) - 1025)
    end
    if rnd() < 0.01 then
      local big = rnd() < 0.2
      R:setSource(TRIMS[rnd(4)], big and (rnd(8193) - 4097) or (rnd(2049) - 1025))
    end
    if rnd() < 0.002 then
      R:setTimer(rnd(3), { mode = rnd(3) - 1, value = rnd(8000) - 100, start = 0, name = "" })
    end

    -- module side
    local m = rnd()
    if m < 0.002 then fake:setArmed(rnd() < 0.5)
    elseif m < 0.004 then fake:setConnected(rnd() < 0.7)
    elseif m < 0.005 then fake:setConfig({ band = rnd(7) - 1, channel = rnd(8), power = rnd(9) - 1 })
    elseif m < 0.0058 then fake.silent = not fake.silent; events.silent = events.silent + 1
    elseif m < 0.0062 then R:setCrsfEnabled(not R.crsf.enabled); events.crsf = events.crsf + 1
    elseif m < 0.008 then fake:injectForeign(R.clock, 1 + rnd(4))
    end

    -- user side
    local u = rnd()
    if inst.fullscreen then
      local pop = R:openPopup(inst)
      if pop and rnd() < 0.3 then
        events.popup = events.popup + 1
        if pop.kind == "menu" then
          local n = #(pop.values or {})
          R:answerPopup(inst, (n > 0 and rnd() < 0.8) and rnd(n) or false)
        else
          R:answerPopup(inst, rnd() < 0.5)
        end
      elseif u < 0.08 then
        local list = R:buttons(inst, true)
        if #list > 0 then
          R:press(inst, list[rnd(#list)])
          events.press = events.press + 1
        end
      elseif u < 0.082 then
        -- the number input of the Throttle page (the mock keeps the value in min..max)
        local ne = R:objects(inst, "numberEdit", true)[1]
        if ne ~= nil then
          R:editNumber(inst, ne, rnd(121) - 1)
          events.edit = events.edit + 1
        end
      elseif u < 0.085 then
        R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
      elseif u < 0.088 then
        R:exitFullScreen(inst)
      end
    elseif u < 0.006 then
      R:enterFullScreen(inst)
      events.fs = events.fs + 1
    elseif u < 0.0075 then
      local o = {}
      local k = rnd(6)
      if k == 1 then o.vtxOff = rnd(2) - 1
      elseif k == 2 then o.hideTrims = rnd(2) - 1
      elseif k == 3 then o.darkTheme = rnd(2) - 1
      elseif k == 4 then o.transpLevel = rnd(4)
      elseif k == 5 then o.extTrims = rnd(3) - 1
      else o.rxCells = rnd(7) - 1 end
      R:setOptions(inst, o)
      events.opts = events.opts + 1
    elseif u < 0.008 then
      local z = ZONES[rnd(#ZONES)]
      R:setZone(inst, z[1], z[2])
      events.zone = events.zone + 1
    elseif u < 0.009 and frozenUntil == nil then
      frozenUntil = cyc + 20 + rnd(200)
      R:freeze(inst, true)
      events.freeze = events.freeze + 1
    end
    if inst2 ~= nil and not inst.fullscreen and rnd() < 0.003 then
      R:setVisible(inst2, not inst2.visible)
    end
    if frozenUntil ~= nil and cyc >= frozenUntil then
      frozenUntil = nil
      R:freeze(inst, false)
    end

    R:cycle(1)
    if inst.dead then break end
    if cyc % 20 == 0 then
      local probs = contract(app)
      if app2 ~= nil and not inst2.dead then
        for _, p in ipairs(contract(app2)) do probs[#probs + 1] = "instance 2: " .. p end
      end
      for _, p in ipairs(probs) do
        if not seenProblems[p] then
          seenProblems[p] = true
          check(false, tag .. " contract at cycle " .. cyc .. ": " .. p)
        end
      end
    end
    if cyc == 1000 or cyc == CYCLES then
      collectgarbage("collect")
      sizeAt[#sizeAt + 1] = entries(app)
    end
  end

  if inst.dead then
    local e = inst.err or {}
    check(false, sformat("%s instance died in %s(): %s\n%s", tag, tostring(e.phase), tostring(e.msg),
      Mock.filterTb(e.tb or "")))
    return
  end
  check(true, tag .. " instance alive after " .. CYCLES .. " cycles")
  if inst2 ~= nil then
    local e = inst2.err or {}
    check(not inst2.dead, sformat("%s second instance alive (%s: %s)", tag, tostring(e.phase), tostring(e.msg)))
    check(app2 == nil or app2.V ~= app.V, tag .. " instances do not share V")
  end

  -- settle: everything back to normal, then a plain Apply & Send must work
  if frozenUntil ~= nil then R:freeze(inst, false) end
  while R:openPopup(inst) do R:answerPopup(inst, false) end
  fake.silent = false
  fake:setArmed(false)
  fake:setConnected(true)
  R:setCrsfEnabled(true)
  R:setStreaming(true)
  if inst.fullscreen then R:exitFullScreen(inst) end
  R:setZone(inst, 480, 320)
  R:setOptions(inst, { vtxOff = 0, hideTrims = 0, darkTheme = 1, transpLevel = 4, rxCells = 0, extTrims = 0 })
  local hit = R:runUntil(60000, function() return app.V.ready and app.V.state == "ready" end)
  check(hit, sformat("%s V ready again after the soak (state %s, msg %q)", tag, app.V.state, app.V.msg))
  check(app.E.found, tag .. " ELRS module found again")
  check(app.V.band == fake.cfg.band and app.V.channel == fake.cfg.channel,
    sformat("%s V matches the module after settle: V %d/%d module %d/%d", tag, app.V.band, app.V.channel,
      fake.cfg.band, fake.cfg.channel))

  R:enterFullScreen(inst)
  R:cycle(4)
  local function btn(text)
    for _, o in ipairs(R:buttons(inst, true)) do
      if o.props.text == text then return o end
    end
    return nil
  end
  -- the tab choice is kept between visits: the random presses may have left the Throttle tab
  if btn("VTX") ~= nil then
    check(R:press(inst, btn("VTX")), tag .. " press the VTX tab")
    R:cycle(2)
  end
  local sends0 = fake.vtx.sends
  local want = (fake.cfg.band == 5) and { "A", 1, 7 } or { "R", 5, 4 }
  check(R:press(inst, btn(want[1])), tag .. " press band " .. want[1])
  R:cycle(1)
  check(R:press(inst, btn(sformat("%d", want[3]))), tag .. " press channel " .. want[3])
  R:cycle(1)
  check(R:press(inst, btn("Apply & Send")), tag .. " press Apply & Send")
  local done = R:runUntil(20000, function()
    return fake.vtx.sends > sends0 and (app.V.send == "sent" or app.V.send == "queued")
  end)
  check(done, sformat("%s Apply & Send after the soak (send %s, msg %q)", tag, app.V.send, app.V.sendMsg))
  check(fake.cfg.band == want[2] and fake.cfg.channel == want[3],
    sformat("%s module config after apply: band %d ch %d (want %d/%d)", tag, fake.cfg.band, fake.cfg.channel,
      want[2], want[3]))
  R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
  R:cycle(4)
  check(not inst.fullscreen and not inst.dead, tag .. " RTN leaves the page")
  R:cycle(40)

  -- global checks
  check(#R.globalWrites == 0, tag .. " no global writes" ..
    ((R.globalWrites[1] and (": " .. R.globalWrites[1].name)) or ""))
  local badLoad = nil
  for _, l in ipairs(R.loads) do
    if l.phase ~= "create" and l.phase ~= "load" then badLoad = l.phase .. ": " .. l.path end
  end
  check(badLoad == nil, tag .. " loadScript only in create: " .. tostring(badLoad))
  local s = R:instrStats(inst, "refresh")
  local b = R:instrStats(inst, "background")
  local u = R:instrStats(inst, "update")
  local cb = R:instrStats(inst, "callback")
  check(s.max < 14000, sformat("%s refresh max %d < 14000", tag, s.max))
  check(s.avg < 8000, sformat("%s refresh avg %d < 8000", tag, floor(s.avg)))
  check(b.max < 14000, sformat("%s background max %d < 14000", tag, b.max))
  check(u.max < 14000, sformat("%s update max %d < 14000", tag, u.max))
  check(cb.max < 2000, sformat("%s callback max %d < 2000", tag, cb.max))
  if inst2 ~= nil then
    local s2 = R:instrStats(inst2, "refresh")
    local b2 = R:instrStats(inst2, "background")
    check(s2.max < 14000 and s2.avg < 8000, sformat("%s instance 2 refresh max/avg %d/%d", tag, s2.max, floor(s2.avg)))
    check(b2.max < 14000, sformat("%s instance 2 background max %d", tag, b2.max))
    print(sformat("%s instance 2: refresh max/avg %d/%d (%d), background max %d (%d)", tag, s2.max,
      floor(s2.avg), s2.n, b2.max, b2.n))
  end
  -- no no-argument lvgl.clear() (it would delete firmware objects too), and the
  -- live objects (views, free root boxes) stay bounded
  check(inst.fullClearsAfterBuild == 0, sformat("%s no-argument lvgl.clear() calls: %d", tag, inst.fullClearsAfterBuild))
  local live = #R:objects(inst)
  check(live < 300, sformat("%s live LVGL objects bounded (%d)", tag, live))
  local viol = {}
  for _, v in ipairs(fake.violations) do viol[#viol + 1] = v.msg end
  check(#viol == 0, tag .. " ELRS protocol violations: " .. table.concat(viol, "; "))
  -- throttle cap: model writes and the mixer emulation
  local md = R.mdl
  local swaps = 0
  for _, w in ipairs(md.writes) do if w.call == "insertInput" then swaps = swaps + 1 end end
  check(md.nGlitches == 0, sformat("%s mixer glitches: %d%s", tag, md.nGlitches,
    md.glitches[1] and (" (first: " .. md.glitches[1].msg .. ")") or ""))
  check(#md.badWrites == 0, sformat("%s model writes outside refresh(): %d%s", tag, #md.badWrites,
    md.badWrites[1] and (" (first: " .. md.badWrites[1].msg .. ")") or ""))
  check(#md.floatArgs == 0, sformat("%s float arguments to the model API: %d", tag, #md.floatArgs))
  check(#md.multi == 0, sformat("%s calls with more than one swap: %d", tag, #md.multi))
  local lines = R:inputLines(2)
  check(#lines == 1 and lines[1].source == Mock.SRC.thr and lines[1].offset == lines[1].weight - 100,
    sformat("%s input 3 is one plain cap line at the end (%d lines)", tag, #lines))
  -- no visible clickable object outside full screen (checked by the mock at every cycle end)
  local ci = inst.clickIssues
  check(#ci == 0, sformat("%s visible clickable objects outside full screen in %d cycles%s", tag, inst.clickCycles,
    ci[1] and (" (first: " .. ci[1].msg .. ")") or ""))
  if inst2 ~= nil then
    check(#inst2.clickIssues == 0, sformat("%s instance 2: visible clickable objects outside full screen", tag))
  end
  -- every pressed control can be reached by a tap (LVGL-order hit test in the mock)
  local ti = inst.touchIssues
  check(#ti == 0, sformat("%s pressed controls that a tap cannot reach: %d%s", tag, #ti,
    ti[1] and (" (first: " .. ti[1].msg .. ")") or ""))
  if #sizeAt >= 2 then
    check(sizeAt[2] <= sizeAt[1] + 400, sformat("%s widget tables bounded (%d -> %d entries)", tag, sizeAt[1], sizeAt[2]))
  end
  print(sformat("%s refresh max/avg %d/%d, update max %d, background max %d, callback max %d, " ..
    "objects %d (made %d, leaked %d), table entries %s; events fs %d press %d popup %d opts %d zone %d freeze %d "
    .. "silent %d crsf %d edit %d; cap swaps %d",
    tag, s.max, floor(s.avg), u.max, b.max, cb.max, #inst.objects, inst.created, inst.leaked, table.concat(sizeAt, "->"),
    events.fs, events.press, events.popup, events.opts, events.zone, events.freeze, events.silent, events.crsf,
    events.edit, swaps))
end

for _, mode in ipairs({ "rc1", "v212x" }) do
  for i, seed in ipairs(SEEDS) do
    local version = ({ "4.1.0", "3.4.2", "3.3.2" })[i]
    local ok, e = pcall(soak, mode, seed, version, i == 2)
    check(ok, sformat("[%s seed %d] soak ran without a harness error: %s", mode, seed, tostring(e)))
  end
end

print(sformat("integ_soak_test: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
