-- Unit test for ui/thrpage.lua (full-screen throttle cap page and the shared header)
-- with the small strict LVGL mock of page_test.lua plus a strict numberEdit.
-- Run: cd "<root>" && lua tests/unit/thrpage_test.lua   (exit code 0 = pass)

local here = string.match(arg and arg[0] or "", "^(.*)/[^/]*$") or "."
local ROOT = here .. "/../.."
local WD = ROOT .. "/radio sd card/WIDGETS/FPVDASH/"
local PAGE = WD .. "ui/thrpage.lua"

local mock = dofile(here .. "/page_mock.lua")
mock.install(_G)

local W, H = mock.LCD_W, mock.LCD_H
local C = mock.COLORS

local fails, passes = 0, 0
local function check(cond, msg)
  if cond then
    passes = passes + 1
  else
    fails = fails + 1
    print("FAIL: " .. msg)
  end
end
local function eq(a, b, msg)
  check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

-- Run fn with strict globals: no global writes, no reads of undefined globals.
local function strict(fn, ...)
  local mt = getmetatable(_G)
  setmetatable(_G, {
    __newindex = function(_, k) error("global write: " .. tostring(k), 2) end,
    __index = function(_, k) error("undefined global read: " .. tostring(k), 2) end,
  })
  local ok, a = pcall(fn, ...)
  setmetatable(_G, mt)
  if not ok then error(a, 0) end
  return a
end

---------------------------------------------------------------------------
-- numberEdit (lvgl_api.md 5.4): keys get set min max display (+ base keys, active);
-- full screen only; rc1 calls get at creation (must return an integer, never nil).
local NE_KEYS = { x = 1, y = 1, w = 1, h = 1, color = 1, opacity = 1, visible = 1, size = 1, pos = 1,
                  flexFlow = 1, flexPad = 1, active = 1, get = 1, set = 1, min = 1, max = 1, display = 1 }
mock.lvgl.numberEdit = function(a, b)
  local parent, t = nil, a
  if b ~= nil then parent, t = a, b end
  for k, v in pairs(t) do
    if not NE_KEYS[k] then error("Invalid property '" .. tostring(k) .. "' for numberEdit", 0) end
    if (k == "visible" or k == "size" or k == "pos" or k == "active" or k == "get" or k == "set"
        or k == "display") and type(v) ~= "function" then
      error("numberEdit." .. k .. " must be a function", 0)
    end
  end
  if not mock.fullScreen then return nil end
  if t.get ~= nil then
    local v = t.get()
    if math.type(v) ~= "integer" then error("numberEdit get must return an integer, got " .. tostring(v), 0) end
  end
  local o = { type = "numberEdit", p = t, parent = parent or mock.root, children = {},
              x = t.x or 0, y = t.y or 0, w = t.w, h = t.h }
  table.insert(o.parent.children, o)
  mock.objCount = mock.objCount + 1
  mock.pollObj(o)
  return o
end

---------------------------------------------------------------------------
-- thrcap mock: the contract of lib/thrcap.lua (request only records a pending value)
local function newThrcap()
  local m = { MIN = 20, MAX = 100, requests = {} }
  function m.request(T, cap)
    cap = math.floor(cap + 0.5)
    if cap < m.MIN then cap = m.MIN elseif cap > m.MAX then cap = m.MAX end
    m.requests[#m.requests + 1] = cap
    T.pending = cap
    T.pendAt = 0
    T.rev = T.rev + 1
  end
  return m
end

local function newT(cap)
  return { state = "ok", msg = "Cap " .. cap .. "%", cap = cap, custom = false, weight = cap,
           offset = cap - 100, pending = nil, input = 2, rev = 1 }
end

local chunk = assert(loadfile(PAGE))
local page = strict(chunk)
check(type(page) == "table" and type(page.build) == "function" and type(page.controls) == "function"
      and type(page.header) == "function", "module returns build, controls and header")
local layout = strict(assert(loadfile(WD .. "ui/layout.lua")))

local function newWgt(T, vtxOn)
  return {
    T = T, vtxOn = vtxOn ~= false, tab = "thr",
    theme = { good = C.GREEN, warn = C.YELLOW, bad = C.RED, muted = C.GREY, accent = C.COLOR_THEME_FOCUS },
    mods = { thrcap = newThrcap(), layout = layout },
    zone = { x = 0, y = 0, w = W, h = H }, dir = "WIDGETS/FPVDASH/",
  }
end

local TABS = { vtx = false, thr = true }

-- app.lua: page texts, then the header and the controls in a root box drawn above it
local function build(wgt)
  mock.reset()
  local t = strict(page.build, wgt)
  strict(page.header, wgt, nil, TABS)
  strict(page.controls, t, wgt)
  strict(mock.poll)
  return t
end

local function tick(t, wgt)
  strict(t.update, wgt)
  strict(mock.poll)
end

local function press(text)
  local b = mock.findButton(text)
  check(b ~= nil, "visible button '" .. text .. "' exists")
  if b ~= nil then strict(mock.press, b) end
  return b
end

local function btnColor(text)
  local b = mock.findButton(text)
  if b == nil then return nil end
  return b.cur.color, b.cur.textColor
end

local function buttonTexts()
  local t = {}
  for _, b in ipairs(mock.visibleButtons()) do t[#t + 1] = mock.textOf(b.o) end
  return table.concat(t, ",")
end

local function labelWithText(s)
  local found = false
  mock.walk(function(o, ax, ay, vis)
    if o.type == "label" and vis and mock.textOf(o) == s then found = true end
  end)
  return found
end

local function labelFont(s)
  local f = nil
  mock.walk(function(o, ax, ay, vis)
    if o.type == "label" and vis and mock.textOf(o) == s then f = (o.cur and o.cur.font) or o.p.font end
  end)
  return f
end

local function numberEdit()
  local r = nil
  mock.walk(function(o, ax, ay, vis)
    if o.type == "numberEdit" and vis then r = { o = o, x = ax, y = ay } end
  end)
  return r
end

-- Layout rules (as page_test.lua; the number input counts as a control): inside the
-- screen, >= 3 px free around controls, finger size, labels not under controls,
-- labels do not overlap.
local function rectsHit(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end
local function layoutCheck(tag)
  local ctl, labels = {}, {}
  local pos = {}
  mock.walk(function(o, ax, ay, vis)
    pos[o] = { ax, ay }
    if not vis then return end
    if o.type == "button" or o.type == "numberEdit" then
      ctl[#ctl + 1] = { o = o, x = ax, y = ay, w = o.w, h = o.h, t = mock.textOf(o) or o.type }
    elseif o.type == "label" then
      local t = mock.textOf(o)
      if t ~= nil and t ~= "" then
        local x, y, w, h = mock.labelRect(o, ax, ay)
        labels[#labels + 1] = { o = o, x = x, y = y, w = w, h = h, t = t }
      end
    end
  end)
  for _, b in ipairs(ctl) do
    local name = tag .. " control '" .. b.t .. "'"
    check(b.w ~= nil and b.h ~= nil, name .. " has w/h")
    if b.w ~= nil and b.h ~= nil then
      check(b.x >= 3 and b.y >= 3 and b.x + b.w <= W - 3 and b.y + b.h <= H - 3,
            name .. " keeps 3 px from the screen edge")
      check(b.w >= 40 and b.h >= 34, name .. " is finger size (" .. b.w .. "x" .. b.h .. ")")
      local par = b.o.parent
      if par ~= nil and par.type ~= "root" then
        local px, py = pos[par][1], pos[par][2]
        check(b.x + b.w + 3 <= px + par.w and b.y + b.h + 3 <= py + par.h and b.x - 3 >= px and b.y - 3 >= py,
              name .. " outline not clipped by container")
      end
    end
  end
  for i = 1, #ctl do
    for j = i + 1, #ctl do
      local a, b = ctl[i], ctl[j]
      check(not rectsHit(a.x - 3, a.y - 3, a.w + 6, a.h + 6, b.x, b.y, b.w, b.h),
            tag .. " controls '" .. a.t .. "' and '" .. b.t .. "' keep 3 px apart")
    end
  end
  for _, l in ipairs(labels) do
    check(l.x >= 0 and l.x + l.w <= W and l.y >= 0 and l.y + l.h <= H,
          tag .. " label '" .. l.t .. "' inside the screen")
    for _, b in ipairs(ctl) do
      check(not rectsHit(l.x, l.y, l.w, l.h - 2, b.x - 2, b.y - 2, b.w + 4, b.h + 4),
            tag .. " label '" .. l.t .. "' not under control '" .. b.t .. "'")
    end
  end
  for i = 1, #labels do
    for j = i + 1, #labels do
      local a, b = labels[i], labels[j]
      check(not rectsHit(a.x, a.y, a.w, a.h - 3, b.x, b.y, b.w, b.h - 3),
            tag .. " labels '" .. a.t .. "' and '" .. b.t .. "' do not overlap")
    end
  end
end

-- Count VM instructions executed by the page only (the mock side is C on the radio).
local pageSrc = "@" .. PAGE
local function counted(fn)
  local n = 0
  debug.sethook(function()
    local info = debug.getinfo(2, "S")
    if info ~= nil and info.source == pageSrc then n = n + 1 end
  end, "", 1)
  local ok, e = pcall(fn)
  debug.sethook()
  if not ok then error(e, 0) end
  return n
end

local PRESETS = "100%,90%,80%,75%,70%,60%,50%"

---------------------------------------------------------------------------
print("T1 ready page, cap 75 %")
local wgt = newWgt(newT(75))
local t
local nBuild = counted(function() t = build(wgt) end)
tick(t, wgt)
eq(#mock.errors, 0, "no mock errors")
eq(buttonTexts(), "Back,VTX,Throttle," .. PRESETS .. ",-5,+5,Set", "visible buttons")
check(labelWithText("75%"), "big value 75%")
eq(labelFont("75%"), DBLSIZE, "big value in DBLSIZE")
check(labelWithText("Max throttle"), "caption")
check(labelWithText("Cap 75%"), "header shows T.msg")
check(labelWithText("Input 3: weight 75, offset -25"), "header shows the input line")
check(labelWithText("Applies immediately, also when armed."), "note: applies immediately")
check(labelWithText("Stick low stays at -100. Range 20..100 %."), "note: range")
check(not labelWithText("Throttle cap"), "no page title with tabs")
eq(btnColor("Throttle"), C.COLOR_THEME_FOCUS, "Throttle tab shown")
eq(btnColor("VTX"), C.COLOR_THEME_PRIMARY2, "VTX tab default color")
eq(btnColor("75%"), C.COLOR_THEME_ACTIVE, "applied preset 75% in the active color")
eq(btnColor("80%"), C.COLOR_THEME_PRIMARY2, "other preset default color")
eq(btnColor("Set"), C.COLOR_THEME_PRIMARY2, "Set not highlighted (staged = cap)")
local ne = numberEdit()
check(ne ~= nil, "number input exists")
if ne then
  eq(ne.o.p.get(), 75, "number input staged with the cap")
  eq(ne.o.p.min, 20, "number input min = thrcap.MIN")
  eq(ne.o.p.max, 100, "number input max = thrcap.MAX")
  eq(ne.o.p.display(80), "80%", "number input display")
end
local minus = mock.findButton("-5")
check(minus ~= nil and minus.cur.active == true, "-5 active")
layoutCheck("T1")
eq(#wgt.mods.thrcap.requests, 0, "no request at build")
local nIdle = counted(function() strict(t.update, wgt) end)
local nPoll = counted(function() strict(mock.poll) end)

---------------------------------------------------------------------------
print("T2 presets and steps only call thrcap.request")
press("80%")
eq(wgt.mods.thrcap.requests[1], 80, "preset 80% requested")
local nChange = counted(function() strict(t.update, wgt) end)
strict(mock.poll)
eq(btnColor("80%"), C.COLOR_THEME_FOCUS, "pending preset in the focus color")
eq(btnColor("75%"), C.COLOR_THEME_ACTIVE, "applied preset still in the active color")
check(labelWithText("Pending: 80%"), "pending text")
check(labelWithText("75%"), "big value stays the applied cap while pending")
eq(btnColor("Set"), C.COLOR_THEME_FOCUS, "Set highlighted: staged 75 differs from the pending 80")
press("-5")
eq(wgt.mods.thrcap.requests[2], 75, "-5 from the pending value")
-- two quick taps before the next tick add up (the press reads T.pending)
press("+5"); press("+5")
eq(wgt.mods.thrcap.requests[4], 85, "two quick +5 taps add up")
tick(t, wgt)
check(labelWithText("Pending: 85%"), "pending 85")
-- thrcap applied it
wgt.T.pending = nil; wgt.T.cap = 85; wgt.T.weight = 85; wgt.T.offset = -15; wgt.T.msg = "Cap 85%"
wgt.T.rev = wgt.T.rev + 1
tick(t, wgt)
check(labelWithText("85%") and labelWithText("Input 3: weight 85, offset -15"), "applied 85 shown")
check(not labelWithText("Pending: 85%"), "pending text gone")
-- limits: thrcap.request clamps
for _ = 1, 4 do press("+5") end
eq(wgt.mods.thrcap.requests[#wgt.mods.thrcap.requests], 100, "+5 stops at 100")
layoutCheck("T2")

---------------------------------------------------------------------------
print("T3 manual value: staged, Set applies")
wgt = newWgt(newT(75))
t = build(wgt); tick(t, wgt)
ne = numberEdit()
local r = strict(ne.o.p.set, 42)
eq(r, nil, "set returns nothing")
eq(#wgt.mods.thrcap.requests, 0, "editing the number does not request")
tick(t, wgt)
eq(btnColor("Set"), C.COLOR_THEME_FOCUS, "Set highlighted while the staged value differs")
eq(ne.o.p.get(), 42, "get returns the staged value")
press("Set")
eq(wgt.mods.thrcap.requests[1], 42, "Set requests the staged value")
-- a preset does not change the staged number (rc1 does not poll get)
press("90%")
eq(ne.o.p.get(), 42, "staged number kept after a preset")
-- new controls (next full-screen entry) stage the shown cap
mock.reset()
strict(page.controls, t, wgt)
strict(mock.poll)
eq(numberEdit().o.p.get(), 90, "new controls stage the pending cap")

---------------------------------------------------------------------------
print("T4 custom weight/offset")
local T = newT(80); T.offset = -10; T.custom = true; T.msg = "Custom line"
wgt = newWgt(T)
t = build(wgt); tick(t, wgt)
eq(#mock.errors, 0, "no mock errors")
check(labelWithText("Custom 80/-10"), "big text Custom 80/-10")
check(labelWithText("Not weight W, offset W-100"), "custom caption")
minus = mock.findButton("-5")
check(minus ~= nil and minus.cur.active == false, "-5 inactive for a custom line")
press("-5")
eq(#wgt.mods.thrcap.requests, 0, "a step does nothing for a custom line")
for _, b in ipairs({ "100%", "90%", "80%", "75%" }) do
  eq(btnColor(b), C.COLOR_THEME_PRIMARY2, "custom: preset " .. b .. " not shown as applied")
end
eq(numberEdit().o.p.get(), 100, "custom: number input staged at 100")
press("75%")
eq(wgt.mods.thrcap.requests[1], 75, "a preset replaces the custom line")
layoutCheck("T4")
-- a very wide custom text uses the smaller font
T.weight, T.offset, T.rev = -100, -100, T.rev + 1
tick(t, wgt)
check(labelWithText("Custom -100/-100"), "wide custom text")
eq(labelFont("Custom -100/-100"), MIDSIZE, "wide custom text in MIDSIZE")
layoutCheck("T4 wide")

---------------------------------------------------------------------------
print("T5 unsupported and no throttle input")
T = newT(75); T.state = "unsupported"; T.msg = "Thr input has a switch"
wgt = newWgt(T)
t = build(wgt); tick(t, wgt)
eq(#mock.errors, 0, "no mock errors")
eq(buttonTexts(), "Back,VTX,Throttle", "unsupported: only Back and the tabs")
check(numberEdit() == nil, "unsupported: number input hidden")
check(labelWithText("Thr input has a switch"), "unsupported: T.msg shown")
check(labelWithText("The throttle input must be one plain line:"), "unsupported: hint 1")
check(labelWithText("source Thr, no switch, all flight modes, no GVAR, no curve."), "unsupported: hint 2")
check(labelWithText("Input 3") and not labelWithText("Input 3: weight 75, offset -25"),
      "unsupported: input number without weight and offset")
layoutCheck("T5")
-- refusals from the mixes point to the Mixes page
T.msg, T.rev = "CH6 inverts the Thr input", T.rev + 1
tick(t, wgt)
check(labelWithText("Check the Mixes page of the model:"), "mix refusal: hint 1")
check(labelWithText("the throttle channel needs the Thr input, positive weight."), "mix refusal: hint 2")
check(not labelWithText("The throttle input must be one plain line:"), "mix refusal: no input hint")
layoutCheck("T5 mix")
T.msg, T.rev = "Thr input not in mixes", T.rev + 1
tick(t, wgt)
check(labelWithText("Check the Mixes page of the model:"), "not in mixes: mix hint")
-- a second Thr input points to the Inputs page
T.msg, T.rev = "Thr in 2 inputs", T.rev + 1
tick(t, wgt)
check(labelWithText("Only one input may use the Thr stick."), "two inputs: hint 1")
check(labelWithText("Check the Inputs page of the model."), "two inputs: hint 2")
layoutCheck("T5 two inputs")
T.msg, T.rev = "Thr input has a switch", T.rev + 1
tick(t, wgt)
T.state, T.msg, T.input, T.cap, T.rev = "none", "No throttle input", -1, 0, T.rev + 1
tick(t, wgt)
eq(buttonTexts(), "Back,VTX,Throttle", "none: only Back and the tabs")
check(labelWithText("The cap needs an input line that uses the Thr stick."), "none: hint")
check(not labelWithText("Input 0: weight 75, offset -25"), "none: no input line")
layoutCheck("T5 none")
-- found again
T.state, T.msg, T.input, T.cap, T.rev = "ok", "Cap 75%", 2, 75, T.rev + 1
tick(t, wgt)
eq(buttonTexts(), "Back,VTX,Throttle," .. PRESETS .. ",-5,+5,Set", "controls back")
-- busy and error keep the controls
T.state, T.msg, T.rev = "error", "Write failed", T.rev + 1
tick(t, wgt)
eq(buttonTexts(), "Back,VTX,Throttle," .. PRESETS .. ",-5,+5,Set", "error: controls stay for a retry")
check(labelWithText("Write failed"), "error message shown")
-- cap unknown
T.state, T.cap, T.rev = "ok", 0, T.rev + 1
tick(t, wgt)
check(labelWithText("--") and labelWithText("Cap unknown"), "unknown cap")
check(mock.findButton("-5").cur.active == false, "unknown cap: steps inactive")

---------------------------------------------------------------------------
print("T6 VTX control off: no tabs, page title")
wgt = newWgt(newT(60), false)
t = build(wgt); tick(t, wgt)
eq(buttonTexts(), "Back," .. PRESETS .. ",-5,+5,Set", "VTX off: Back without tabs")
check(labelWithText("Throttle cap"), "VTX off: page title")
press("Back")
eq(mock.exitCalls, 1, "Back exits full screen")
layoutCheck("T6")

---------------------------------------------------------------------------
print("T7 tabs")
wgt = newWgt(newT(75))
t = build(wgt); tick(t, wgt)
press("VTX")
eq(wgt.tab, "vtx", "VTX tab press sets wgt.tab")
press("Throttle")
eq(wgt.tab, "thr", "Throttle tab press sets wgt.tab")

---------------------------------------------------------------------------
print("T8 no wgt.T, long texts")
wgt = newWgt(nil)
t = build(wgt); tick(t, wgt)
eq(#mock.errors, 0, "no wgt.T: no mock errors")
eq(buttonTexts(), "Back,VTX,Throttle", "no wgt.T: no controls")
check(mock.findButton("80%") == nil, "no wgt.T: no preset buttons")
T = newT(75); T.msg = "A very long status message from the module text"
wgt = newWgt(T)
t = build(wgt); tick(t, wgt)
layoutCheck("T8 long message")

---------------------------------------------------------------------------
print("T9 not full screen does not crash")
mock.fullScreen = false
wgt = newWgt(newT(75))
local ok, e = pcall(function() t = build(wgt); tick(t, wgt) end)
check(ok, "build outside full screen: " .. tostring(e))
mock.fullScreen = true

---------------------------------------------------------------------------
print("T10 480x272 screen")
local H0 = H
H = 272
_G.LCD_H = 272
wgt = newWgt(newT(75))
t = build(wgt); tick(t, wgt)
eq(#mock.errors, 0, "272: no mock errors")
eq(buttonTexts(), "Back,VTX,Throttle," .. PRESETS .. ",-5,+5,Set", "272: all buttons visible")
layoutCheck("T10")
press("50%"); tick(t, wgt)
layoutCheck("T10 pending")
T = newT(80); T.offset = -10; T.custom = true
wgt = newWgt(T)
t = build(wgt); tick(t, wgt)
layoutCheck("T10 custom")
T = newT(75); T.state = "unsupported"
wgt = newWgt(T)
t = build(wgt); tick(t, wgt)
layoutCheck("T10 unsupported")
H = H0
_G.LCD_H = H0

---------------------------------------------------------------------------
print("T11 with the real lib/thrcap.lua request API (if present)")
local tchunk = loadfile(WD .. "lib/thrcap.lua")
if tchunk == nil then
  print("  skipped: lib/thrcap.lua not found")
else
  local okc, real = pcall(tchunk)
  check(okc and type(real) == "table" and type(real.new) == "function" and type(real.request) == "function",
        "lib/thrcap.lua loads with new and request")
  if okc and type(real) == "table" and type(real.new) == "function" then
    local okn, RT = pcall(real.new)
    check(okn and type(RT) == "table", "thrcap.new() returns T")
    if okn and type(RT) == "table" then
      RT.state, RT.cap, RT.weight, RT.offset, RT.input, RT.custom = "ok", 75, 75, -25, 2, false
      RT.rev = (type(RT.rev) == "number") and RT.rev + 1 or 1
      wgt = newWgt(RT)
      wgt.mods.thrcap = real
      t = build(wgt); tick(t, wgt)
      eq(#mock.errors, 0, "real thrcap: no mock errors")
      press("60%")
      eq(RT.pending, 60, "real thrcap: preset sets T.pending")
      tick(t, wgt)
      press("-5")
      eq(RT.pending, 55, "real thrcap: -5 from the pending value")
      for _ = 1, 10 do press("-5") end
      eq(RT.pending, real.MIN, "real thrcap: clamped at thrcap.MIN")
    end
  end
end

---------------------------------------------------------------------------
print("T11b text on the applied and the selected values is readable on the radio theme")
-- lcd.getColor of the firmware (api_colorlcd.cpp:969): an RGB flag, RGB565 in bits 16..31
-- and 0x8000, for a theme color. The page picks BLACK or WHITE for the text on ACTIVE
-- (applied preset) and on FOCUS (pending preset, Set, the shown tab): at least 4.5:1.
-- The "Pending: NN%" text is FOCUS on the page background only when that gives 4.5:1.
do
  local function flag565(rgb)
    local r, g, b = (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF
    return ((((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)) << 16) | 0x8000
  end
  local function rgbOf565(f)
    local p = (f >> 16) & 0xFFFF
    return ((p >> 11) & 31) * 255 // 31, ((p >> 5) & 63) * 255 // 63, (p & 31) * 255 // 31
  end
  local function lin(x)
    x = x / 255
    if x <= 0.04045 then return x / 12.92 end
    return ((x + 0.055) / 1.055) ^ 2.4
  end
  local function lum(r, g, b) return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) end
  local function ratio(a, b)
    if a < b then a, b = b, a end
    return (a + 0.05) / (b + 0.05)
  end
  -- Theme colors (THEMES/Dark_Theme/theme.yml on the SD card; the default EdgeTX theme from
  -- the firmware colors.cpp), and one theme with a dark ACTIVE and FOCUS.
  local THEMES = {
    { name = "Dark Theme", PRIMARY1 = 0x909490, PRIMARY2 = 0xE0E0E0, SECONDARY1 = 0x282828,
      SECONDARY3 = 0x000000, FOCUS = 0xF03C38, ACTIVE = 0xF8B038, WARNING = 0xE83030 },
    { name = "EdgeTX default", PRIMARY1 = 0x000000, PRIMARY2 = 0xFFFFFF, SECONDARY1 = 0x125E99,
      SECONDARY3 = 0xE4EEF2, FOCUS = 0x14A1E5, ACTIVE = 0xFFDE00, WARNING = 0xE00000 },
    { name = "dark ACTIVE", PRIMARY1 = 0xFFFFFF, PRIMARY2 = 0xFFFFFF, SECONDARY1 = 0x202020,
      SECONDARY3 = 0x101010, FOCUS = 0x1840A0, ACTIVE = 0x1840A0, WARNING = 0xA00000 },
  }
  -- and every theme on the SD card (THEMES/*/theme.yml)
  do
    local dir = ROOT .. "/radio sd card/THEMES"
    local ls = io.popen('ls "' .. dir .. '"')
    local n = 0
    if ls ~= nil then
      for folder in ls:lines() do
        local f = io.open(dir .. "/" .. folder .. "/theme.yml", "r")
        if f ~= nil then
          local th = { name = "SD card " .. folder }
          for line in f:lines() do
            local k, v = string.match(line, "^%s*(%u[%u%d]*):%s*0x(%x+)")
            if k ~= nil then th[k] = tonumber(v, 16) end
          end
          f:close()
          if th.FOCUS and th.ACTIVE and th.PRIMARY1 and th.PRIMARY2 and th.SECONDARY1 and th.SECONDARY3
             and th.WARNING then
            THEMES[#THEMES + 1] = th
            n = n + 1
          end
        end
      end
      ls:close()
    end
    check(n >= 40, "themes read from the SD card: " .. n)
  end
  local SLOT = { PRIMARY1 = C.COLOR_THEME_PRIMARY1, PRIMARY2 = C.COLOR_THEME_PRIMARY2,
                 SECONDARY1 = C.COLOR_THEME_SECONDARY1, SECONDARY3 = C.COLOR_THEME_SECONDARY3,
                 FOCUS = C.COLOR_THEME_FOCUS, ACTIVE = C.COLOR_THEME_ACTIVE, WARNING = C.COLOR_THEME_WARNING }
  -- the real RGB of a color the page uses (a theme slot, BLACK or WHITE)
  local function rgbOf(th, c)
    if c == C.BLACK then return 0x000000 end
    if c == C.WHITE then return 0xFFFFFF end
    for k, slot in pairs(SLOT) do
      if c == slot then return th[k] end
    end
    return nil
  end
  local function lumOf(th, c)
    local rgb = rgbOf(th, c)
    if rgb == nil then return nil end
    return lum(rgbOf565(flag565(rgb)))
  end
  local function pair(th, what, fg, bg, min)
    local lf, lb = lumOf(th, fg), lumOf(th, bg)
    check(lf ~= nil and lb ~= nil, th.name .. ": " .. what .. ": known colors")
    if lf == nil or lb == nil then return 0 end
    local r = ratio(lf, lb)
    check(r >= min, string.format("%s: %s %.2f:1 (>= %.1f:1)", th.name, what, r, min))
    return r
  end
  local function labelColor(s)
    local col = nil
    mock.walk(function(o, ax, ay, vis)
      if o.type == "label" and vis and mock.textOf(o) == s then col = (o.cur and o.cur.color) or o.p.color end
    end)
    return col
  end
  local saved = mock.lcd.getColor
  for _, th in ipairs(THEMES) do
    local name = th.name
    mock.lcd.getColor = function(c)
      for k, slot in pairs(SLOT) do
        if c == slot then return flag565(th[k]) end
      end
      return nil
    end
    local w2 = newWgt(newT(75))
    local v2 = build(w2)
    tick(v2, w2)
    -- applied preset (ACTIVE), the shown tab (FOCUS), a default preset
    local bg, fg = btnColor("75%")
    eq(bg, C.COLOR_THEME_ACTIVE, name .. ": applied value in the active color")
    check(fg == C.BLACK or fg == C.WHITE, name .. ": text BLACK or WHITE")
    local r = pair(th, "text on the applied preset", fg, bg, 4.5)
    bg, fg = btnColor("Throttle")
    eq(bg, C.COLOR_THEME_FOCUS, name .. ": shown tab in the focus color")
    pair(th, "text on the shown tab", fg, bg, 4.5)
    if name == "Dark Theme" then
      eq(select(2, btnColor("75%")), C.BLACK, name .. ": BLACK on the orange ACTIVE")
      check(r >= 7.0, string.format("Dark Theme: BLACK on ACTIVE %.2f:1 (about 11:1)", r))
      local old = ratio(lumOf(th, C.COLOR_THEME_ACTIVE), lumOf(th, C.COLOR_THEME_PRIMARY1))
      check(old < 3.0, string.format("Dark Theme: the old pair PRIMARY1 on ACTIVE is %.2f:1 (< 3:1)", old))
      local oldSel = ratio(lumOf(th, C.COLOR_THEME_FOCUS), lumOf(th, C.COLOR_THEME_PRIMARY2))
      check(oldSel < 4.5, string.format("Dark Theme: the old pair PRIMARY2 on FOCUS is %.2f:1 (< 4.5:1)", oldSel))
    end
    -- pending preset and Set (FOCUS), and the "Pending" text on the page background
    press("80%")
    tick(v2, w2)
    bg, fg = btnColor("80%")
    eq(bg, C.COLOR_THEME_FOCUS, name .. ": pending preset in the focus color")
    pair(th, "text on the pending preset", fg, bg, 4.5)
    bg, fg = btnColor("Set")
    eq(bg, C.COLOR_THEME_FOCUS, name .. ": Set highlighted")
    pair(th, "text on Set", fg, bg, 4.5)
    pair(th, "applied preset while a value is pending", select(2, btnColor("75%")), C.COLOR_THEME_ACTIVE, 4.5)
    pair(th, "the Pending text on the page", labelColor("Pending: 80%"), C.COLOR_THEME_SECONDARY3, 4.5)
    -- the default buttons keep the theme pair (the EdgeTX button colors)
    bg, fg = btnColor("90%")
    eq(bg, C.COLOR_THEME_PRIMARY2, name .. ": default preset background")
    eq(fg, C.COLOR_THEME_SECONDARY1, name .. ": default preset text")
  end
  -- not an RGB value (or no lcd.getColor): the theme text colors, as before
  mock.lcd.getColor = function() return nil end
  local w3 = newWgt(newT(75))
  local v3 = build(w3)
  tick(v3, w3)
  eq(select(2, btnColor("75%")), C.COLOR_THEME_PRIMARY1, "getColor nil: PRIMARY1 text on ACTIVE")
  eq(select(2, btnColor("Throttle")), C.COLOR_THEME_PRIMARY2, "getColor nil: PRIMARY2 text on the shown tab")
  press("80%")
  tick(v3, w3)
  eq(select(2, btnColor("80%")), C.COLOR_THEME_PRIMARY2, "getColor nil: PRIMARY2 text on FOCUS")
  eq(labelColor("Pending: 80%"), C.COLOR_THEME_FOCUS, "getColor nil: Pending text in FOCUS")
  mock.lcd.getColor = saved
end

---------------------------------------------------------------------------
print("T12 CPU (VM instructions of the page)")
print(string.format("  build=%d  idle update=%d  changed update=%d  poll=%d  objects=%d",
  nBuild, nIdle, nChange, nPoll, mock.objCount))
check(nIdle < 60, "idle update is cheap")
check(nIdle + nPoll < 8000, "typical tick < 8000")
check(nChange + nPoll < 14000, "worst tick < 14000")
check(nBuild < 14000, "build < 14000")

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
