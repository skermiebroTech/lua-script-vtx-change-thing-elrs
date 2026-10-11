-- tests/unit/thrpage_harness_test.lua : the full-screen Throttle tab and the dashboard
-- cap line with the REAL widget in the strict harness mock (tests/edgetx_mock.lua) and
-- the fake ELRS module, in rc1 and in 2.12.x mode.
--
--   cd "<root>" && lua tests/unit/thrpage_harness_test.lua
--
-- The mock emulates the model input API and the input stage of the mixer from the
-- firmware source (default: the user's model "75", Input 3 = chn 2, one line, source Thr,
-- weight 75, offset -25). Its records fail this test too: a mixer glitch, a model write
-- outside refresh(), a float argument, two swaps in one call, and a visible clickable
-- object outside full screen.
-- Checks: tabs, layout (harness overlap checker, also for the number input), a preset
-- tap reaches the model line through lib/thrcap.lua (the other fields stay), the
-- dashboard line follows the cap, stick mode 1 moves the line to the right box, VTX
-- control off shows only the Throttle page, page visits leak only the page buttons,
-- CPU limits.
-- Writes tests/out/thr_*.svg/.txt/.json layout dumps.
-- Harness rule: no string method syntax in this file (the mock traps it).

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

local WIDGET = "/WIDGETS/FPVDASH/"

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else
    failed = failed + 1
    print("FAIL: " .. msg)
  end
  return cond
end
local function eq(a, b, msg)
  return check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

local SENSORS = {
  { name = "1RSS", value = -60 }, { name = "2RSS", value = -66 }, { name = "RQly", value = 100 },
  { name = "RSNR", value = 9 }, { name = "ANT", value = 0 }, { name = "RFMD", value = 7 },
  { name = "TPWR", value = 25 }, { name = "RxBt", value = 16.4, prec = 1 }, { name = "Curr", value = 2.3, prec = 1 },
  { name = "Capa", value = 150 }, { name = "FM", text = "ACRO" },
}

-- The throttle input of the user's models: Input 3 = chn 2.
local THR_CHN = 2

-- The lines of the throttle input (mock model data, no API call).
local function thrLines(R)
  return R:inputLines(THR_CHN)
end

local function world(mode, o)
  o = o or {}
  local fake = Fake.new({ version = "4.1.0", band = 5, channel = 4, power = 1, pit = 0 })
  local R = Mock.new({ mode = mode, module = fake, stickMode = o.stickMode, lcdW = o.lcdW, lcdH = o.lcdH,
                       model = o.model })
  R:defineSensors(SENSORS)
  R:setStreaming(true)
  local wt, err = R:loadWidget(WIDGET)
  check(wt ~= nil, mode .. ": widget loads: " .. tostring(err))
  local opts = { darkTheme = 1, transpLevel = 4, vtxOff = o.vtxOff or 0, hideTrims = 0, rxCells = 0, extTrims = 0 }
  local inst = R:createInstance({ w = o.w or 480, h = o.h or 320, appMode = true, visible = true, options = opts })
  return R, inst, fake
end

-- The records of the mock that fail every world: mixer glitches, model writes outside
-- refresh(), float arguments, two swaps in one call, visible clickable objects outside
-- full screen, the no-argument lvgl.clear() after the first build.
local function records(R, inst, tag)
  local md = R.mdl
  check(md ~= nil, tag .. ": mock model data")
  if md == nil then return end
  for _, g in ipairs(md.glitches) do check(false, tag .. ": " .. g.msg) end
  eq(md.nGlitches, 0, tag .. ": no mixer glitch")
  for _, b in ipairs(md.badWrites) do check(false, tag .. ": " .. b.msg) end
  for _, f in ipairs(md.floatArgs) do check(false, sformat("%s: model.%s got the float %s", tag, f.what, tostring(f.v))) end
  for _, m in ipairs(md.multi) do check(false, tag .. ": " .. m.msg) end
  for _, c in ipairs(inst.clickIssues or {}) do check(false, tag .. ": " .. c.msg) end
  eq(inst.clickCycles or 0, 0, tag .. ": cycles with a visible clickable object outside full screen")
  -- every pressed control can be reached by a tap (LVGL-order hit test in the mock)
  for _, c in ipairs(inst.touchIssues or {}) do check(false, tag .. ": " .. c.msg) end
  eq(inst.fullClearsAfterBuild, 0, tag .. ": no-argument lvgl.clear() after the first build")
end

local function findButton(R, inst, text)
  for _, b in ipairs(R:buttons(inst, true)) do
    if b.props.text == text then return b end
  end
  return nil
end

local function buttonTexts(R, inst)
  local t = {}
  for _, b in ipairs(R:buttons(inst, true)) do t[#t + 1] = b.props.text or "" end
  return table.concat(t, ",")
end

local function press(R, inst, text, tag)
  local b = findButton(R, inst, text)
  if not check(b ~= nil, tag .. ": button '" .. text .. "' visible (buttons: " .. buttonTexts(R, inst) .. ")") then
    return false
  end
  local ok, why = R:press(inst, b)
  return check(ok, tag .. ": press '" .. text .. "': " .. tostring(why))
end

local function hasText(R, inst, s)
  for _, t in ipairs(R:texts(inst, false)) do
    if t == s then return true end
  end
  return false
end

local function interArea(ax, ay, aw, ah, bx, by, bw, bh)
  local x1, y1 = math.max(ax, bx), math.max(ay, by)
  local x2, y2 = math.min(ax + aw, bx + bw), math.min(ay + ah, by + bh)
  if x2 <= x1 or y2 <= y1 then return 0 end
  return (x2 - x1) * (y2 - y1)
end

-- Harness layout check (severe = fail) plus: no visible label on the number input,
-- the number input does not touch a button, every control inside the screen.
local function layout(R, inst, tag)
  local n = 0
  for _, r in ipairs(R:layoutCheck(inst)) do
    n = n + 1
    if r.severe then check(false, tag .. ": layout: " .. r.msg) else print("  warn " .. tag .. ": " .. r.msg) end
  end
  local edits = R:objects(inst, "numberEdit", true)
  for _, e in ipairs(edits) do
    local ex, ey, ew, eh = R:absRect(e)
    check(ex >= 3 and ey >= 3 and ex + ew <= R.lcdW - 3 and ey + eh <= R.lcdH - 3, tag .. ": number input on the screen")
    for _, o in ipairs(R:objects(inst, "label", true)) do
      if (o.props.text or "") ~= "" then
        local lx, ly, lw, lh = R:labelInk(o)
        check(interArea(lx, ly, lw, lh, ex - 2, ey - 2, ew + 4, eh + 4) == 0,
              tag .. ": label '" .. o.props.text .. "' not on the number input")
      end
    end
    for _, b in ipairs(R:buttons(inst, true)) do
      local bx, by, bw, bh = R:absRect(b)
      check(interArea(bx - 3, by - 3, bw + 6, bh + 6, ex, ey, ew, eh) == 0,
            tag .. ": button '" .. tostring(b.props.text) .. "' keeps 3 px from the number input")
    end
  end
  return n
end

local PRESETS = "100%,90%,80%,75%,70%,60%,50%"

for _, mode in ipairs({ "rc1", "v212x" }) do
  local tag = mode
  local R, inst = world(mode)
  local app = R:app(inst)
  local line0 = thrLines(R)[1]
  R:cycle(60)
  check(not inst.dead, tag .. ": instance alive on the dashboard (" .. tostring(inst.deathMsg) .. ")")
  eq(app.T.state, "ok", tag .. ": throttle input found")
  eq(app.T.cap, 75, tag .. ": cap read from the model")
  check(R:findText(inst, "^75%%$") ~= nil, tag .. ": dashboard cap label 75%")
  local lines = R:objects(inst, "hline", true)
  local capLine = nil
  for _, o in ipairs(lines) do
    if o.props.h == 2 then capLine = o end
  end
  check(capLine ~= nil, tag .. ": dashboard cap line shown")
  local gb = {}
  for _, o in ipairs(R:objects(inst, "rectangle", true)) do
    if o.props.filled == false and o.props.thickness == 2 then gb[#gb + 1] = o end
  end
  if capLine and #gb == 2 then
    local lx = R:absRect(capLine)
    local bx1 = R:absRect(gb[1])
    eq(lx, bx1 + 2, tag .. ": mode 2: cap line on the left box")
  end
  layout(R, inst, tag .. " dashboard")

  -- full screen: VTX tab first
  R:enterFullScreen(inst)
  R:cycle(4)
  check(findButton(R, inst, "Apply & Send") ~= nil, tag .. ": VTX tab first")
  eq(buttonTexts(R, inst) ~= "" and string.sub(buttonTexts(R, inst), 1, 21), "Back,VTX,Throttle,Rel",
     tag .. ": header buttons")
  layout(R, inst, tag .. " VTX tab")
  -- Throttle tab
  local c0 = inst.created
  press(R, inst, "Throttle", tag)
  R:cycle(2)
  eq(buttonTexts(R, inst), "Back,VTX,Throttle," .. PRESETS .. ",-5,+5,Set", tag .. ": Throttle tab buttons")
  eq(#R:objects(inst, "numberEdit", true), 1, tag .. ": number input shown")
  check(inst.created - c0 <= 16, sformat("%s: Throttle tab made %d objects (its buttons only)", tag, inst.created - c0))
  check(hasText(R, inst, "75%") and hasText(R, inst, "Max throttle"), tag .. ": big cap value")
  check(hasText(R, inst, "Input 3: weight 75, offset -25"), tag .. ": input line in the header")
  check(hasText(R, inst, "Applies immediately, also when armed."), tag .. ": note")
  layout(R, inst, tag .. " Throttle tab")
  if mode == "rc1" then R:dump(inst, "thr_page") end

  -- preset 80 %: nothing changes before the debounce, then one swap
  press(R, inst, "80%", tag)
  R:cycle(1)
  eq(thrLines(R)[1].weight, 75, tag .. ": no model write in the press cycle")
  check(hasText(R, inst, "Pending: 80%"), tag .. ": pending shown")
  layout(R, inst, tag .. " pending")
  if mode == "rc1" then R:dump(inst, "thr_page_pending") end
  R:cycle(12)
  eq(#thrLines(R), 1, tag .. ": one input line after the swap")
  eq(thrLines(R)[1].weight, 80, tag .. ": model weight 80")
  eq(thrLines(R)[1].offset, -20, tag .. ": model offset -20")
  for _, k in ipairs(Mock.LINE_KEYS) do
    if k ~= "weight" and k ~= "offset" then
      eq(thrLines(R)[1][k], line0[k], tag .. ": swap keeps the field " .. k)
    end
  end
  eq(app.T.cap, 80, tag .. ": T.cap 80")
  check(hasText(R, inst, "80%"), tag .. ": big value 80%")
  -- quick taps: one swap to the last value
  press(R, inst, "-5", tag); R:cycle(1)
  press(R, inst, "-5", tag); R:cycle(1)
  press(R, inst, "-5", tag)
  R:cycle(14)
  eq(thrLines(R)[1].weight, 65, tag .. ": three -5 taps give 65")
  eq(thrLines(R)[1].offset, -35, tag .. ": offset -35")
  -- number input: staged, Set applies
  local ne = R:objects(inst, "numberEdit", true)[1]
  if check(ne ~= nil and ne.cbs.set ~= nil, tag .. ": number input set callback") then
    R:_callback(inst, "set", ne.cbs.set, 42)
    R:cycle(14)
    eq(thrLines(R)[1].weight, 65, tag .. ": editing the number does not write")
    press(R, inst, "Set", tag)
    R:cycle(14)
    eq(thrLines(R)[1].weight, 42, tag .. ": Set writes the staged value")
    eq(thrLines(R)[1].offset, -58, tag .. ": Set writes the offset -58")
  end
  -- the tab choice is kept: exit and enter again
  R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
  R:cycle(4)
  check(not inst.fullscreen, tag .. ": RTN leaves full screen")
  eq(#R:buttons(inst, false), 0, tag .. ": no buttons after the exit")
  check(R:findText(inst, "^42%%$") ~= nil, tag .. ": dashboard cap label follows the cap (42%)")
  layout(R, inst, tag .. " dashboard after")
  if mode == "rc1" then R:dump(inst, "thr_dash_42") end
  R:cycle(5)
  local live0, leaked0, created0 = #R:objects(inst), inst.leaked, inst.created
  for v = 1, 3 do
    R:enterFullScreen(inst)
    R:cycle(4)
    check(findButton(R, inst, "Set") ~= nil, sformat("%s: visit %d: Throttle tab kept", tag, v))
    R:exitFullScreen(inst)
    R:cycle(4)
  end
  eq(inst.leaked - leaked0, inst.created - created0, tag .. ": page visits leak only the page buttons")
  check((inst.created - created0) / 3 <= 40, sformat("%s: %d objects per visit", tag, (inst.created - created0) // 3))
  eq(#R:objects(inst), live0, tag .. ": live objects do not grow")
  -- 100 %: line hidden on the dashboard
  R:enterFullScreen(inst)
  R:cycle(4)
  press(R, inst, "100%", tag)
  R:cycle(14)
  eq(thrLines(R)[1].weight, 100, tag .. ": 100 % written")
  R:exitFullScreen(inst)
  R:cycle(4)
  local shown = false
  for _, o in ipairs(R:objects(inst, "hline", true)) do
    if o.props.h == 2 then shown = true end
  end
  check(not shown, tag .. ": no cap line at 100 %")

  local rs = R:instrStats(inst, "refresh")
  local us = R:instrStats(inst, "update")
  local cs = R:instrStats(inst, "callback")
  print(sformat("%s: refresh max %d avg %d (n %d); update max %d; callback max %d; objects %d (made %d, leaked %d)",
    tag, rs.max, math.floor(rs.avg), rs.n, us.max, cs.max, #inst.objects, inst.created, inst.leaked))
  check(rs.max < 14000, tag .. ": refresh max < 14000")
  check(rs.avg < 8000, tag .. ": refresh average < 8000")
  check(us.max < 14000, tag .. ": update max < 14000")
  check(not inst.dead, tag .. ": alive at the end (" .. tostring(inst.deathMsg) .. ")")
  check(#R.globalWrites == 0, tag .. ": no global writes")
  records(R, inst, tag)

  -- stick mode 1: the throttle box is the right one
  local R1, inst1 = world(mode, { stickMode = 1 })
  R1:cycle(40)
  local cl = nil
  for _, o in ipairs(R1:objects(inst1, "hline", true)) do
    if o.props.h == 2 then cl = o end
  end
  local g1 = {}
  for _, o in ipairs(R1:objects(inst1, "rectangle", true)) do
    if o.props.filled == false and o.props.thickness == 2 then g1[#g1 + 1] = o end
  end
  if check(cl ~= nil and #g1 == 2, tag .. ": mode 1: cap line and two boxes") then
    eq(R1:absRect(cl), R1:absRect(g1[2]) + 2, tag .. ": mode 1: cap line on the right box")
  end
  layout(R1, inst1, tag .. " mode 1 dashboard")
  records(R1, inst1, tag .. " mode 1")

  -- VTX control off: only the Throttle page, no CRSF traffic
  local R2, inst2 = world(mode, { vtxOff = 1 })
  R2:cycle(40)
  R2:enterFullScreen(inst2)
  R2:cycle(4)
  eq(buttonTexts(R2, inst2), "Back," .. PRESETS .. ",-5,+5,Set", tag .. ": VTX off: Throttle page only")
  check(hasText(R2, inst2, "Throttle cap"), tag .. ": VTX off: page title")
  layout(R2, inst2, tag .. " VTX off page")
  if mode == "rc1" then R2:dump(inst2, "thr_page_vtxoff") end
  R2:exitFullScreen(inst2)
  R2:cycle(4)
  eq(R2.crsf.pushCalls + R2.crsf.popCalls, 0, tag .. ": VTX off: no CRSF calls")
  records(R2, inst2, tag .. " VTX off")

  -- not supported: a switch on the line
  local bad = Mock.userModel(1, { thr = { { source = Mock.SRC.thr, weight = 75, offset = -25, switch = 5 } } })
  local R3, inst3 = world(mode, { model = bad })
  local snap3 = R3:modelSnapshot()
  R3:cycle(40)
  R3:enterFullScreen(inst3)
  R3:cycle(4)
  press(R3, inst3, "Throttle", tag)
  R3:cycle(2)
  eq(buttonTexts(R3, inst3), "Back,VTX,Throttle", tag .. ": unsupported: no cap buttons")
  check(R3:findText(inst3, "Thr input not simple") ~= nil, tag .. ": unsupported: reason shown")
  layout(R3, inst3, tag .. " unsupported")
  if mode == "rc1" then R3:dump(inst3, "thr_page_unsupported") end
  R3:exitFullScreen(inst3)
  R3:cycle(4)
  check(R3:findText(inst3, "^75%%$") == nil, tag .. ": unsupported: no cap line on the dashboard")
  eq(R3:modelSnapshot(), snap3, tag .. ": unsupported: the model is not written")
  records(R3, inst3, tag .. " unsupported")

  -- 480x272 radio
  local R4, inst4 = world(mode, { lcdW = 480, lcdH = 272, h = 272 })
  R4:cycle(40)
  layout(R4, inst4, tag .. " 272 dashboard")
  R4:enterFullScreen(inst4)
  R4:cycle(4)
  press(R4, inst4, "Throttle", tag)
  R4:cycle(2)
  eq(buttonTexts(R4, inst4), "Back,VTX,Throttle," .. PRESETS .. ",-5,+5,Set", tag .. ": 272: Throttle tab buttons")
  layout(R4, inst4, tag .. " 272 Throttle tab")
  press(R4, inst4, "VTX", tag)
  R4:cycle(2)
  layout(R4, inst4, tag .. " 272 VTX tab")
  if mode == "rc1" then R4:dump(inst4, "thr_page_272") end
  check(not inst4.dead, tag .. ": 272 alive")
  R4:exitFullScreen(inst4)
  R4:cycle(4)
  records(R4, inst4, tag .. " 272")
end

print(sformat("thrpage_harness_test: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
