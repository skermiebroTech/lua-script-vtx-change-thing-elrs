-- Unit test for ui/vtxpage.lua with a small strict LVGL mock.
-- Run: cd "<root>" && lua tests/unit/page_test.lua   (exit code 0 = pass)

local here = string.match(arg and arg[0] or "", "^(.*)/[^/]*$") or "."
local ROOT = here .. "/../.."
local PAGE = ROOT .. "/radio sd card/WIDGETS/FPVDASH/ui/vtxpage.lua"
local LAYOUT = ROOT .. "/radio sd card/WIDGETS/FPVDASH/ui/layout.lua"
local THRPAGE = ROOT .. "/radio sd card/WIDGETS/FPVDASH/ui/thrpage.lua"

local mock = dofile(here .. "/page_mock.lua")
local vtxmock = dofile(here .. "/page_vtxmock.lua")
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

-- Count VM instructions executed by the page and the vtx mock only
-- (on the radio the mock/LVGL side is C code).
local chunk = assert(loadfile(PAGE))
local pageSrc = "@" .. PAGE
local vtxSrc = "@" .. here .. "/page_vtxmock.lua"
local function counted(fn)
  local n = 0
  debug.sethook(function()
    local info = debug.getinfo(2, "S")
    if info ~= nil and (info.source == pageSrc or info.source == vtxSrc) then n = n + 1 end
  end, "", 1)
  local ok, e = pcall(fn)
  debug.sethook()
  if not ok then error(e, 0) end
  return n
end

local page = strict(chunk)
check(type(page) == "table" and type(page.build) == "function", "module returns table with build")
local layout = strict(assert(loadfile(LAYOUT)))
local thrpage = strict(assert(loadfile(THRPAGE)))

local PIT = { "Off", "On" }
for n = 1, 10 do
  PIT[#PIT + 1] = "AUX" .. n .. "^"
  PIT[#PIT + 1] = "AUX" .. n .. "v"
end

local function V41()
  return {
    state = "ready", msg = "VTX ready", ready = true,
    bandLabels = { "Disabled", "A", "B", "E", "F", "R", "L" },
    band = 5, bandLetter = "R", channel = 4,
    powerLabels = { "-", "1", "2", "3", "4", "5", "6", "7", "8" }, power = 2,
    pitLabels = PIT, pit = 0, freq = 5769,
    send = "idle", sendMsg = "", rev = 1,
  }
end

local function Vsearch()
  return {
    state = "search", msg = "Searching for ELRS", ready = false,
    bandLabels = {}, band = 0, bandLetter = "", channel = 0,
    powerLabels = {}, power = 0, pitLabels = {}, pit = 0, freq = 0,
    send = "idle", sendMsg = "", rev = 1,
  }
end

local function newWgt(V)
  return {
    V = V, E = { found = true, label = "TX15 4.1.0", version = "4.1.0", armed = false },
    theme = { good = C.GREEN, warn = C.YELLOW, bad = C.RED, muted = C.GREY, accent = C.COLOR_THEME_FOCUS },
    mods = { vtx = vtxmock.new(), layout = layout },
    zone = { x = 0, y = 0, w = W, h = H }, dir = "WIDGETS/FPVDASH/",
    vtxOn = true, tab = "vtx",
  }
end

-- app.lua builds the page, then (in a second root box drawn above it) the shared
-- header buttons (Back, tabs) and the page buttons
local TABS = { vtx = true, thr = false }
local function build(wgt)
  mock.reset()
  local p = strict(page.build, wgt)
  strict(thrpage.header, wgt, nil, TABS)
  strict(page.controls, p, wgt)
  strict(mock.poll)
  return p
end

local function tick(p, wgt)
  strict(p.update, wgt)
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

-- Layout rules: inside the screen, >= 3 px free around buttons (outline 2 + pad 1),
-- >= 2 px inside the parent container, finger size, labels not under buttons.
local function rectsHit(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end
local function layoutCheck(tag)
  local btns, labels = {}, {}
  local pos = {}
  mock.walk(function(o, ax, ay, vis)
    pos[o] = { ax, ay }
    if not vis then return end
    if o.type == "button" then
      btns[#btns + 1] = { o = o, x = ax, y = ay, w = o.w, h = o.h }
    elseif o.type == "label" then
      local t = mock.textOf(o)
      if t ~= nil and t ~= "" then
        local x, y, w, h = mock.labelRect(o, ax, ay)
        labels[#labels + 1] = { o = o, x = x, y = y, w = w, h = h, t = t }
      end
    end
  end)
  for _, b in ipairs(btns) do
    local name = tag .. " button '" .. tostring(mock.textOf(b.o)) .. "'"
    check(b.w ~= nil and b.h ~= nil, name .. " has w/h")
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
  for i = 1, #btns do
    for j = i + 1, #btns do
      local a, b = btns[i], btns[j]
      check(not rectsHit(a.x - 3, a.y - 3, a.w + 6, a.h + 6, b.x, b.y, b.w, b.h),
            tag .. " buttons '" .. tostring(mock.textOf(a.o)) .. "' and '" ..
            tostring(mock.textOf(b.o)) .. "' keep 3 px apart")
    end
  end
  for _, l in ipairs(labels) do
    check(l.x >= 0 and l.x + l.w <= W and l.y >= 0 and l.y + l.h <= H,
          tag .. " label '" .. l.t .. "' inside the screen")
    for _, b in ipairs(btns) do
      check(not rectsHit(l.x, l.y, l.w, l.h - 2, b.x - 2, b.y - 2, b.w + 4, b.h + 4),
            tag .. " label '" .. l.t .. "' not under button '" .. tostring(mock.textOf(b.o)) .. "'")
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

-- Optional SVG dump of the visible objects for a visual check.
local function svgDump(file)
  local out = {}
  -- square canvas so thumbnail tools do not crop it
  out[#out + 1] = string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" ' ..
    'viewBox="0 0 %d %d" font-family="Helvetica" font-size="12">', W * 2, W * 2, W, W)
  out[#out + 1] = string.format('<g><rect width="%d" height="%d" fill="#fff"/>' ..
    '<rect width="%d" height="%d" fill="#222"/>', W, W, W, H)
  -- the user's "Dark Theme" (THEMES/Dark_Theme/theme.yml)
  local function col(c)
    local map = {
      [C.COLOR_THEME_FOCUS] = "#f03c38", [C.COLOR_THEME_ACTIVE] = "#f8b038",
      [C.COLOR_THEME_PRIMARY2] = "#e0e0e0", [C.COLOR_THEME_SECONDARY1] = "#282828",
      [C.COLOR_THEME_SECONDARY3] = "#000000", [C.COLOR_THEME_PRIMARY1] = "#909490",
      [C.COLOR_THEME_WARNING] = "#e83030", [C.GREEN] = "#30d030", [C.RED] = "#e03030",
      [C.YELLOW] = "#e0e030", [C.GREY] = "#888888", [C.BLACK] = "#000000", [C.WHITE] = "#ffffff",
    }
    return map[c] or "#ff00ff"
  end
  mock.walk(function(o, ax, ay, vis)
    if not vis then return end
    local cur = o.cur or {}
    if o.type == "rectangle" then
      out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>',
        ax, ay, o.w, o.h, col(cur.color or o.p.color))
    elseif o.type == "circle" then
      out[#out + 1] = string.format('<circle cx="%d" cy="%d" r="%d" fill="%s"/>',
        ax, ay, o.p.radius or 1, col(cur.color or o.p.color))
    elseif o.type == "button" then
      local bg = cur.color or C.COLOR_THEME_PRIMARY2
      local fg = cur.textColor or C.COLOR_THEME_SECONDARY1
      out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" rx="5" fill="%s" ' ..
        'stroke="#666" stroke-width="2"/>', ax, ay, o.w, o.h, col(bg))
      out[#out + 1] = string.format('<text x="%d" y="%d" text-anchor="middle" fill="%s" font-size="%d">%s</text>',
        ax + o.w // 2, ay + o.h // 2 + 5, col(fg), (o.p.font == SMLSIZE) and 12 or 15,
        (mock.textOf(o) or ""):gsub("&", "&amp;"))
    elseif o.type == "label" then
      local font = cur.font or o.p.font or 0
      local size = ({ [SMLSIZE] = 12, [MIDSIZE] = 22, [BOLD] = 15, [STDSIZE] = 15 })[font] or 15
      local anchor, x = "start", ax
      if o.p.align == CENTER and o.w then anchor, x = "middle", ax + o.w // 2 end
      out[#out + 1] = string.format('<text x="%d" y="%d" text-anchor="%s" fill="%s" font-size="%d"%s>%s</text>',
        x, ay + size, anchor, col(cur.color or o.p.color), size, font == BOLD and ' font-weight="bold"' or "",
        (mock.textOf(o) or ""):gsub("&", "&amp;"))
    end
  end)
  out[#out + 1] = "</g></svg>"
  local f = io.open(file, "w")
  if f then f:write(table.concat(out, "\n")); f:close() end
end

local SVGDIR = os.getenv("PAGE_SVG_DIR")

---------------------------------------------------------------------------
print("T1 ready page (ELRS 4.1 labels)")
local wgt = newWgt(V41())
local p
local nBuild = counted(function() p = build(wgt) end)
tick(p, wgt)
eq(#mock.errors, 0, "no mock errors")
eq(buttonTexts(), "Back,VTX,Throttle,Reload,A,B,E,F,R,L,Off,1,2,3,4,5,6,7,8,Keep,1,2,3,4,5,6,7,8,Off,Apply & Send",
   "visible buttons")
eq(btnColor("VTX"), C.COLOR_THEME_FOCUS, "VTX tab shown (focus color)")
eq(btnColor("Throttle"), C.COLOR_THEME_PRIMARY2, "Throttle tab not shown (default color)")
check(labelWithText("Now: R4 5769 MHz, P2, Pit Off"), "header shows current setting")
check(labelWithText("VTX ready"), "header shows V.msg")
check(labelWithText("R4 5769 MHz"), "summary shows selection + MHz")
check(labelWithText("Power 2, Pit Off"), "summary second line")
check(labelWithText("5658") and labelWithText("5917"), "frequency strip for band R")
check(labelWithText("Now: Off"), "pit current")
check(not labelWithText("ARMED"), "ARMED hidden")
eq(btnColor("R"), C.COLOR_THEME_FOCUS, "current band is selected (focus)")
eq(btnColor("A"), C.COLOR_THEME_PRIMARY2, "other band default bg")
eq(select(2, btnColor("A")), C.COLOR_THEME_SECONDARY1, "other band default text")
eq(btnColor("4"), C.COLOR_THEME_FOCUS, "current channel selected")
eq(btnColor("Apply & Send"), C.COLOR_THEME_PRIMARY2, "apply default when nothing staged")
eq(wgt.rebuildRequested, nil, "no rebuild request")
layoutCheck("T1")
if SVGDIR then svgDump(SVGDIR .. "/page_ready.svg") end

local nIdle = counted(function() strict(p.update, wgt) end)
local nPoll = counted(function() strict(mock.poll) end)

---------------------------------------------------------------------------
print("T2 staging and apply")
press("F")
local nStage = counted(function() strict(p.update, wgt) end)
strict(mock.poll)
eq(p.sel.band, 4, "sel.band after F")
eq(btnColor("F"), C.COLOR_THEME_FOCUS, "F selected")
eq(btnColor("R"), C.COLOR_THEME_ACTIVE, "R current (active)")
eq(select(2, btnColor("R")), C.COLOR_THEME_PRIMARY1, "R current text")
check(labelWithText("F4 5800 MHz"), "summary F4")
check(labelWithText("5740") and labelWithText("5880"), "frequency strip for F")
check(labelWithText("Not applied yet"), "note: not applied")
eq(btnColor("Apply & Send"), C.COLOR_THEME_FOCUS, "apply highlighted when staged")
-- two '2' buttons exist (channel and power): press the channel one (first)
local ch2 = nil
for _, b in ipairs(mock.visibleButtons()) do
  if mock.textOf(b.o) == "2" and ch2 == nil then ch2 = b.o end
end
strict(mock.press, ch2)
press("Keep")
tick(p, wgt)
check(labelWithText("F2 5760 MHz"), "summary F2")
check(labelWithText("Power: keep"), "summary power keep (no pit: ELRS sends pit only with a power level)")
-- unrelated V change keeps the staged selection
wgt.V.msg = "VTX ready."; wgt.V.rev = wgt.V.rev + 1
tick(p, wgt)
eq(p.sel.band, 4, "staged band kept on V change")
eq(p.sel.channel, 2, "staged channel kept on V change")
press("Apply & Send")
eq(#wgt.mods.vtx.applied, 0, "apply deferred to update")
tick(p, wgt)
local ap = wgt.mods.vtx.applied[1]
check(ap ~= nil, "vtx.apply called")
if ap then
  eq(ap.sel.band, 4, "apply band"); eq(ap.sel.channel, 2, "apply channel")
  eq(ap.sel.power, 0, "apply power")
  eq(ap.sel.pit, nil, "apply pit: not written with power Keep (ELRS sends pit only with a power level)")
  eq(ap.send, true, "apply send")
  check(ap.sel ~= p.sel, "apply gets a copy of the selection")
end
-- module progress
wgt.V.band = 4; wgt.V.send = "writing"; wgt.V.sendMsg = "Writing..."; wgt.V.rev = wgt.V.rev + 1
tick(p, wgt)
eq(p.sel.channel, 2, "selection kept while writing")
check(mock.findButton("Writing...") ~= nil, "apply shows Writing...")
eq(btnColor("F"), C.COLOR_THEME_FOCUS, "F still selected")
wgt.V.channel = 2; wgt.V.power = 0; wgt.V.send = "sending"; wgt.V.sendMsg = "Sending..."
wgt.V.rev = wgt.V.rev + 1
tick(p, wgt)
eq(p.dirty, false, "not staged once V matches")
check(mock.findButton("Sending...") ~= nil, "apply shows Sending...")
wgt.V.send = "sent"; wgt.V.sendMsg = "Sent (not confirmed)"; wgt.V.rev = wgt.V.rev + 1
tick(p, wgt)
check(mock.findButton("Sent") ~= nil, "apply shows Sent")
check(labelWithText("Sent (not confirmed)"), "note shows V.sendMsg")
check(labelWithText("Now: F2 5760 MHz, P-"), "header now updated (no pit part with power Keep)")
-- external change while nothing staged: selection follows V
wgt.V.band = 1; wgt.V.channel = 1; wgt.V.rev = wgt.V.rev + 1
tick(p, wgt)
eq(p.sel.band, 1, "selection follows V when not staged")
eq(btnColor("A"), C.COLOR_THEME_FOCUS, "A selected after external change")
-- failed state
wgt.V.send = "failed"; wgt.V.sendMsg = "No answer"; wgt.V.rev = wgt.V.rev + 1
tick(p, wgt)
eq(btnColor("Failed - retry"), C.COLOR_THEME_WARNING, "failed shows warning color")
layoutCheck("T2")

---------------------------------------------------------------------------
print("T3 armed confirm")
wgt = newWgt(V41())
p = build(wgt); tick(p, wgt)
wgt.E.armed = true
tick(p, wgt)
check(labelWithText("ARMED"), "ARMED shown")
press("A")
tick(p, wgt)
check(labelWithText("Armed: you must confirm"), "armed note")
press("Apply & Send")
tick(p, wgt)
eq(#wgt.mods.vtx.applied, 0, "no apply before confirm")
local pop = mock.popups[#mock.popups]
check(pop ~= nil and pop.kind == "confirm", "confirm popup opened")
if pop then
  eq(pop.t.title, "Armed", "confirm title")
  strict(pop.t.confirm)
  eq(#wgt.mods.vtx.applied, 1, "apply after confirm")
  eq(wgt.mods.vtx.applied[1].sel.band, 1, "confirmed band A")
end
layoutCheck("T3")

---------------------------------------------------------------------------
print("T4 pit menu")
wgt = newWgt(V41())
p = build(wgt); tick(p, wgt)
local pitBtn = nil
for _, b in ipairs(mock.visibleButtons()) do
  if mock.textOf(b.o) == "Off" and b.w > 100 then pitBtn = b.o end
end
check(pitBtn ~= nil, "pit button found")
strict(mock.press, pitBtn)
tick(p, wgt)
pop = mock.popups[#mock.popups]
check(pop ~= nil and pop.kind == "menu", "pit menu opened")
if pop then
  eq(pop.t.values, wgt.V.pitLabels, "menu values = V.pitLabels")
  eq(pop.t.get(), 1, "menu get = pit + 1")
  local r = strict(pop.t.set, 3)
  eq(r, nil, "menu set returns nothing")
  tick(p, wgt)
  eq(p.sel.pit, 2, "sel.pit from menu")
  check(labelWithText("Power 2, Pit AUX1^"), "summary shows staged pit")
  eq(btnColor("AUX1^"), C.COLOR_THEME_FOCUS, "pit button highlighted when changed")
  eq(pop.t.get(), 3, "menu get follows sel")
end

---------------------------------------------------------------------------
print("T5 reload, back and tabs")
press("Reload")
tick(p, wgt)
eq(wgt.mods.vtx.reloads, 1, "vtx.reload called")
eq(p.sel.pit, 0, "reload drops the staged selection")
press("Back")
eq(mock.exitCalls, 1, "Back exits full screen")
press("Throttle")
eq(wgt.tab, "thr", "Throttle tab press sets wgt.tab")
press("VTX")
eq(wgt.tab, "vtx", "VTX tab press sets wgt.tab")

---------------------------------------------------------------------------
print("T6 not ready, then module found")
wgt = newWgt(Vsearch())
p = build(wgt); tick(p, wgt)
eq(#mock.errors, 0, "no mock errors")
eq(buttonTexts(), "Back,VTX,Throttle,Reload", "only Back, the tabs and Reload visible")
check(labelWithText("Searching for ELRS"), "big status text")
check(labelWithText("Looking for the ExpressLRS TX module..."), "hint text")
layoutCheck("T6")
if SVGDIR then svgDump(SVGDIR .. "/page_notready.svg") end
check(mock.findButton("Apply & Send") == nil, "Apply hidden when not ready")
-- a stale apply request while not ready is ignored
p.req = "apply"; tick(p, wgt)
eq(#wgt.mods.vtx.applied, 0, "no apply when not ready")
-- module discovered: lists change -> rebuild requested
local V = wgt.V
local R = V41()
for k2, v2 in pairs(R) do V[k2] = v2 end
V.rev = 7
tick(p, wgt)
eq(wgt.rebuildRequested, true, "rebuild requested when the lists change")
-- app.lua rebuilds
wgt.rebuildRequested = nil
p = build(wgt); tick(p, wgt)
eq(wgt.rebuildRequested, nil, "no further rebuild request")
check(mock.findButton("Apply & Send") ~= nil, "controls after rebuild")
-- lists replaced by equal copies: no rebuild
V.bandLabels = { "Disabled", "A", "B", "E", "F", "R", "L" }; V.rev = V.rev + 1
tick(p, wgt)
eq(wgt.rebuildRequested, nil, "equal lists do not request a rebuild")
-- link lost but lists kept: hidden, no rebuild
V.ready = false; V.state = "error"; V.msg = "No answer"; V.rev = V.rev + 1
tick(p, wgt)
eq(buttonTexts(), "Back,VTX,Throttle,Reload", "controls hidden when not ready")
check(labelWithText("No answer from the module. Press Reload."), "error hint")
V.ready = true; V.state = "ready"; V.msg = "VTX ready"; V.rev = V.rev + 1
tick(p, wgt)
check(mock.findButton("Apply & Send") ~= nil, "controls back when ready")

---------------------------------------------------------------------------
print("T7 no power / pit fields")
V = V41(); V.powerLabels = {}; V.pitLabels = {}; V.power = 0; V.pit = 0
wgt = newWgt(V)
p = build(wgt); tick(p, wgt)
eq(#mock.errors, 0, "no mock errors")
eq(buttonTexts(), "Back,VTX,Throttle,Reload,A,B,E,F,R,L,Off,1,2,3,4,5,6,7,8,Apply & Send", "no power/pit buttons")
check(labelWithText("Now: R4 5769 MHz"), "header without power/pit")
press("B"); tick(p, wgt)
press("Apply & Send"); tick(p, wgt)
ap = wgt.mods.vtx.applied[1]
check(ap ~= nil and ap.sel.band == 2 and ap.sel.power == nil and ap.sel.pit == nil,
      "apply without power/pit keys")
layoutCheck("T7")
if SVGDIR then svgDump(SVGDIR .. "/page_nopower.svg") end

---------------------------------------------------------------------------
print("T8 ELRS 3.x labels, band off, channel unknown")
V = V41(); V.bandLabels = { "Off", "A", "B", "E", "F", "R", "L" }; V.band = 0; V.channel = 0
V.pitLabels = { "Off", "On" }
wgt = newWgt(V)
p = build(wgt); tick(p, wgt)
eq(#mock.errors, 0, "no mock errors")
eq(btnColor("Off"), C.COLOR_THEME_FOCUS, "Off band selected")
check(labelWithText("Now: VTX off, P2, Pit Off"), "header VTX off")
check(not labelWithText("5658"), "no frequencies when band off")
press("E"); tick(p, wgt)
check(labelWithText("E?"), "summary without channel")
press("Apply & Send"); tick(p, wgt)
ap = wgt.mods.vtx.applied[1]
check(ap ~= nil and ap.sel.band == 3 and ap.sel.channel == nil, "apply without channel")
layoutCheck("T8")

---------------------------------------------------------------------------
print("T8b busy without V.ready keeps controls and staging")
wgt = newWgt(V41())
p = build(wgt); tick(p, wgt)
press("A"); tick(p, wgt)
wgt.V.ready = false; wgt.V.state = "busy"; wgt.V.send = "writing"; wgt.V.rev = wgt.V.rev + 1
tick(p, wgt)
check(mock.findButton("Writing...") ~= nil, "controls stay while busy")
eq(p.sel.band, 1, "staged band kept while busy")
wgt.V.ready = false; wgt.V.state = "error"; wgt.V.rev = wgt.V.rev + 1
tick(p, wgt)
eq(buttonTexts(), "Back,VTX,Throttle,Reload", "error hides the controls")

---------------------------------------------------------------------------
print("T9 not full screen does not crash")
mock.fullScreen = false
wgt = newWgt(V41())
local ok, e = pcall(function() p = build(wgt); tick(p, wgt) end)
check(ok, "build outside full screen: " .. tostring(e))
mock.fullScreen = true

---------------------------------------------------------------------------
print("T11 with the real lib/vtx.lua request API (if present)")
local VTXFILE = ROOT .. "/radio sd card/WIDGETS/FPVDASH/lib/vtx.lua"
local vchunk = loadfile(VTXFILE)
if vchunk == nil then
  print("  skipped: lib/vtx.lua not found")
else
  local okv, realVtx = pcall(vchunk)
  check(okv and type(realVtx) == "table", "lib/vtx.lua loads")
  if okv and type(realVtx) == "table" then
    V = realVtx.new()
    local R41 = V41()
    for k2, v2 in pairs(R41) do V[k2] = v2 end
    wgt = newWgt(V)
    wgt.mods.vtx = realVtx
    p = build(wgt); tick(p, wgt)
    eq(#mock.errors, 0, "no mock errors")
    check(labelWithText("Now: R4 5769 MHz, P2, Pit Off"), "real freqOf in header")
    check(labelWithText("5658"), "real freqOf in the strip")
    press("F")
    for _, b in ipairs(mock.visibleButtons()) do
      if mock.textOf(b.o) == "2" then strict(mock.press, b.o); break end
    end
    press("Apply & Send"); tick(p, wgt)
    local pend = V.pend
    check(pend ~= nil, "V.pend recorded by vtx.apply")
    if pend then
      eq(pend.band, 4, "pend band"); eq(pend.channel, 2, "pend channel")
      eq(pend.power, 2, "pend power"); eq(pend.pit, 0, "pend pit"); eq(pend.send, true, "pend send")
    end
    tick(p, wgt)
    check(mock.findButton("Writing...") ~= nil, "apply shows Writing... after vtx.apply")
    eq(V.state, "busy", "V busy after apply")
    check(mock.findButton("Apply & Send") == nil and mock.findButton("Writing...") ~= nil,
          "controls stay visible while busy")
    press("Reload"); tick(p, wgt)
    eq(V.reloadReq, true, "vtx.reload sets reloadReq")
    layoutCheck("T11")
  end
end

---------------------------------------------------------------------------
print("T12 pit needs a power level")
wgt = newWgt(V41())
p = build(wgt); tick(p, wgt)
check(mock.findButton("Off") ~= nil, "pit button shown with power 2")
press("Keep"); tick(p, wgt)
eq(p.pitShown, false, "power Keep: pit hidden")
local pitVisible = false
for _, b in ipairs(mock.visibleButtons()) do
  if mock.textOf(b.o) == "Off" and b.w > 100 then pitVisible = true end
end
check(not pitVisible, "power Keep: no pit button")
check(labelWithText("Needs a power level"), "power Keep: pit row hint")
check(labelWithText("Power: keep"), "power Keep: summary without pit")
p.req = "pit"; tick(p, wgt)
eq(#mock.popups, 0, "power Keep: pit menu not opened")
press("Apply & Send"); tick(p, wgt)
ap = wgt.mods.vtx.applied[1]
check(ap ~= nil and ap.sel.power == 0 and ap.sel.pit == nil, "power Keep: apply without pit")
-- current power Keep with pit On in V: not shown as active
V = V41(); V.power = 0; V.pit = 1
wgt = newWgt(V)
p = build(wgt); tick(p, wgt)
check(labelWithText("Now: R4 5769 MHz, P-"), "header: no pit with power Keep")
check(labelWithText("Now: -"), "pit row: no current pit with power Keep")
check(not labelWithText("Now: R4 5769 MHz, P-, Pit On"), "header does not claim pit On")
layoutCheck("T12")

---------------------------------------------------------------------------
print("T13 failed write stays visible while the selection is staged")
wgt = newWgt(V41())
p = build(wgt); tick(p, wgt)
press("R"); press("F"); tick(p, wgt)
eq(p.dirty, true, "F staged")
wgt.V.send = "failed"; wgt.V.sendMsg = "Write not applied"; wgt.V.rev = wgt.V.rev + 1
tick(p, wgt)
eq(p.sel.band, 4, "staged band kept after the failure")
eq(btnColor("Failed - retry"), C.COLOR_THEME_WARNING, "failed and staged: 'Failed - retry' in warning color")
check(labelWithText("Write not applied"), "failed and staged: note shows the module message")
press("Failed - retry"); tick(p, wgt)
ap = wgt.mods.vtx.applied[1]
check(ap ~= nil and ap.sel.band == 4, "retry applies the staged band")
wgt.V.send = "idle"; wgt.V.sendMsg = ""; wgt.V.rev = wgt.V.rev + 1
tick(p, wgt)
check(mock.findButton("Apply & Send") ~= nil, "after the result time: Apply & Send again")

---------------------------------------------------------------------------
print("T14 buttons made again on the next full-screen entry")
wgt = newWgt(V41())
p = build(wgt); tick(p, wgt)
press("F"); tick(p, wgt)
p.req = "apply"
mock.reset()
strict(page.controls, p, wgt)
strict(mock.poll)
tick(p, wgt)
eq(#wgt.mods.vtx.applied, 0, "a request of the old buttons is dropped")
eq(p.sel.band, 5, "new buttons start from the module values")

---------------------------------------------------------------------------
print("T15 480x272 screen")
local H0 = H
H = 272
_G.LCD_H = 272
wgt = newWgt(V41())
p = build(wgt); tick(p, wgt)
eq(#mock.errors, 0, "272: no mock errors")
eq(buttonTexts(), "Back,VTX,Throttle,Reload,A,B,E,F,R,L,Off,1,2,3,4,5,6,7,8,Keep,1,2,3,4,5,6,7,8,Off,Apply & Send",
   "272: all buttons visible")
check(labelWithText("R4 5769 MHz") and labelWithText("Power 2, Pit Off"), "272: summary")
layoutCheck("T15")
if SVGDIR then svgDump(SVGDIR .. "/page_272.svg") end
press("Keep"); tick(p, wgt)
check(labelWithText("Needs a power level"), "272: pit hint")
layoutCheck("T15 keep")
press("F"); press("2"); tick(p, wgt)
layoutCheck("T15 staged")
V = V41(); V.pitLabels = {}; V.pit = 0
wgt = newWgt(V)
p = build(wgt); tick(p, wgt)
layoutCheck("T15 no pit")
V = V41(); V.powerLabels = {}; V.power = 0
wgt = newWgt(V)
p = build(wgt); tick(p, wgt)
layoutCheck("T15 no power")
H = H0
_G.LCD_H = H0

---------------------------------------------------------------------------
print("T10 CPU (VM instructions of page + vtx mock)")
wgt = newWgt(V41())
p = build(wgt); tick(p, wgt)
local nWorst = 0
for _, t in ipairs({ "F", "Keep", "Apply & Send" }) do
  press(t)
  wgt.V.rev = wgt.V.rev + 1
  local n = counted(function() strict(p.update, wgt) end)
  if n > nWorst then nWorst = n end
  strict(mock.poll)
end
local nPoll2 = counted(function() strict(mock.poll) end)
print(string.format("  build=%d  idle update=%d  staged update=%d  worst update=%d  poll=%d/%d  objects=%d",
  nBuild, nIdle, nStage, nWorst, nPoll, nPoll2, mock.objCount))
check(nIdle < 100, "idle update is cheap")
check(nIdle + nPoll < 8000, "typical tick < 8000")
check(nWorst + nPoll2 < 14000, "worst tick < 14000")
check(nBuild < 14000, "build < 14000")

---------------------------------------------------------------------------
print("T16 text on the applied and the selected values is readable on the radio theme")
-- lcd.getColor of the firmware (api_colorlcd.cpp:969): an RGB flag, RGB565 in bits 16..31
-- and 0x8000, for a theme color. The page picks BLACK or WHITE for the text on ACTIVE (the
-- applied value), on FOCUS (the selection, the staged Apply, the shown tab) and on WARNING
-- (a failed Apply): at least 4.5:1. The staged summary is FOCUS on the page background
-- only when that gives 4.5:1.
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
  local function lumOf(th, c)
    local rgb = nil
    if c == C.BLACK then rgb = 0x000000 elseif c == C.WHITE then rgb = 0xFFFFFF end
    for k, slot in pairs(SLOT) do
      if c == slot then rgb = th[k] end
    end
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
    local w2 = newWgt(V41())
    local v2 = build(w2)
    tick(v2, w2)
    local bg, fg = btnColor("VTX")
    eq(bg, C.COLOR_THEME_FOCUS, name .. ": shown tab in the focus color")
    pair(th, "text on the shown tab", fg, bg, 4.5)
    press("F")                -- stage band F: R is then the applied (current) band
    tick(v2, w2)
    bg, fg = btnColor("R")
    eq(bg, C.COLOR_THEME_ACTIVE, name .. ": applied value in the active color")
    check(fg == C.BLACK or fg == C.WHITE, name .. ": text BLACK or WHITE")
    local r = pair(th, "text on the applied band", fg, bg, 4.5)
    bg, fg = btnColor("F")
    eq(bg, C.COLOR_THEME_FOCUS, name .. ": selected band in the focus color")
    pair(th, "text on the selected band", fg, bg, 4.5)
    bg, fg = btnColor("Apply & Send")
    eq(bg, C.COLOR_THEME_FOCUS, name .. ": staged Apply in the focus color")
    pair(th, "text on the staged Apply", fg, bg, 4.5)
    pair(th, "staged summary on the page", labelColor("F4 5800 MHz"), C.COLOR_THEME_SECONDARY3, 4.5)
    bg, fg = btnColor("A")
    eq(bg, C.COLOR_THEME_PRIMARY2, name .. ": default band background")
    eq(fg, C.COLOR_THEME_SECONDARY1, name .. ": default band text")
    if name == "Dark Theme" then
      eq(select(2, btnColor("R")), C.BLACK, name .. ": BLACK on the orange ACTIVE")
      check(r >= 7.0, string.format("Dark Theme: BLACK on ACTIVE %.2f:1 (about 11:1)", r))
      local old = ratio(lumOf(th, C.COLOR_THEME_ACTIVE), lumOf(th, C.COLOR_THEME_PRIMARY1))
      check(old < 3.0, string.format("Dark Theme: the old pair PRIMARY1 on ACTIVE is %.2f:1 (< 3:1)", old))
      local oldSel = ratio(lumOf(th, C.COLOR_THEME_FOCUS), lumOf(th, C.COLOR_THEME_PRIMARY2))
      check(oldSel < 4.5, string.format("Dark Theme: the old pair PRIMARY2 on FOCUS is %.2f:1 (< 4.5:1)", oldSel))
    end
    -- a failed Apply (WARNING background)
    w2.V.send = "failed"; w2.V.sendMsg = "No answer"; w2.V.rev = w2.V.rev + 1
    tick(v2, w2)
    bg, fg = btnColor("Failed - retry")
    eq(bg, C.COLOR_THEME_WARNING, name .. ": failed Apply in the warning color")
    pair(th, "text on the failed Apply", fg, bg, 4.5)
  end
  -- not an RGB value (or no lcd.getColor): the theme text colors, as before
  mock.lcd.getColor = function() return nil end
  local w3 = newWgt(V41())
  local v3 = build(w3)
  tick(v3, w3)
  press("F")
  tick(v3, w3)
  eq(select(2, btnColor("R")), C.COLOR_THEME_PRIMARY1, "getColor nil: PRIMARY1 text on ACTIVE")
  eq(select(2, btnColor("F")), C.COLOR_THEME_PRIMARY2, "getColor nil: PRIMARY2 text on FOCUS")
  eq(labelColor("F4 5800 MHz"), C.COLOR_THEME_FOCUS, "getColor nil: staged summary in FOCUS")
  w3.V.send = "failed"; w3.V.rev = w3.V.rev + 1
  tick(v3, w3)
  eq(select(2, btnColor("Failed - retry")), C.COLOR_THEME_PRIMARY2, "getColor nil: PRIMARY2 text on WARNING")
  mock.lcd.getColor = saved
end

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
