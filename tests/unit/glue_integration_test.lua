-- glue_integration_test.lua: smoke test of main.lua + app.lua with the REAL modules from
-- the SD card folder, a permissive LVGL mock (all constructors, property polling) and
-- tests/fake_elrs.lua as the TX module. Run: cd "<root>" && lua tests/unit/glue_integration_test.lua
-- It checks the glue (lifecycle, mode switches, vtxOff = 1 without CRSF calls) and prints
-- VM instruction counts per cycle (refresh + polling of all function properties).

local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
local mock = dofile(here .. "/glue_mock.lua")
local FakeElrs = dofile(mock.ROOT .. "/tests/fake_elrs.lua")

---------------------------------------------------------------- permissive LVGL mock
local L = { roots = {}, fs = false, exits = 0, errors = {}, count = 0 }

local CONTROLS = { button = true, momentaryButton = true, toggle = true, textEdit = true, numberEdit = true,
  choice = true, slider = true, verticalSlider = true, page = true, dialog = true, setting = true,
  font = true, align = true, color = true, timer = true, switch = true, source = true, file = true }
local CTORS = { "label", "rectangle", "box", "image", "hline", "vline", "circle", "arc", "line", "triangle",
  "qrcode", "button", "momentaryButton", "toggle", "textEdit", "numberEdit", "choice", "slider",
  "verticalSlider", "page", "dialog", "setting", "font", "align", "color", "timer", "switch", "source", "file" }
local FN_ONLY = { visible = true, pos = true, size = true, active = true }
local CALLBACKS = { press = true, longpress = true, release = true, set = true, get = true, back = true,
  menu = true, scrolled = true, confirm = true, cancel = true, edited = true, display = true }
local FIRST = { visible = 1, color = 2, opacity = 2, size = 2, pos = 2 }

local OBJ = {}
OBJ.__index = OBJ

local function report(msg)
  L.errors[#L.errors + 1] = msg
end

local function callProp(o, k, f)
  local a, b = f()
  if k == "text" or k == "title" or k == "subtitle" then
    if type(a) ~= "string" and type(a) ~= "number" then report(o.kind .. "." .. k .. " returned " .. type(a)) end
  elseif k == "visible" or k == "active" or k == "filled" or k == "checked" then
    if type(a) ~= "boolean" and type(a) ~= "number" then report(o.kind .. "." .. k .. " returned " .. type(a)) end
  elseif k == "size" or k == "pos" then
    if type(a) ~= "number" or type(b) ~= "number" then report(o.kind .. "." .. k .. " returned non-numbers") end
  elseif k == "file" then
    if type(a) ~= "string" then report(o.kind .. ".file returned " .. type(a)) end
  elseif k == "pts" then
    if type(a) ~= "table" then report(o.kind .. ".pts returned " .. type(a)) end
  else
    if type(a) ~= "number" then report(o.kind .. "." .. k .. " returned " .. type(a)) end
  end
  return a
end

-- one polling pass like callRefs: visible first; hidden objects skip their subtree
local function poll(o)
  local t = o.t
  local vis = t.visible
  if type(vis) == "function" and not callProp(o, "visible", vis) then return end
  for k, f in pairs(t) do
    if type(f) == "function" and FIRST[k] == 2 then callProp(o, k, f) end
  end
  for i = 1, #o.children do poll(o.children[i]) end
  for k, f in pairs(t) do
    if type(f) == "function" and FIRST[k] == nil and not CALLBACKS[k] then callProp(o, k, f) end
  end
end

local function newObj(kind, parent, t)
  if type(t) ~= "table" then report(kind .. ": params not a table"); t = {} end
  if CONTROLS[kind] and not L.fs then return nil end
  for k, v in pairs(t) do
    if FN_ONLY[k] and type(v) ~= "function" then report(kind .. "." .. k .. " must be a function") end
  end
  local o = setmetatable({ kind = kind, t = t, children = {} }, OBJ)
  local list = parent and parent.children or L.roots
  list[#list + 1] = o
  if type(t.children) == "table" then
    for _, c in ipairs(t.children) do newObj(c.type, o, c) end
  end
  poll(o)
  return o
end

for _, name in ipairs(CTORS) do
  OBJ[name] = function(self, t) return newObj(name, self, t) end
end
function OBJ:set(t) for k, v in pairs(t) do self.t[k] = v end end
function OBJ:show() end
function OBJ:hide() end
function OBJ:enable() end
function OBJ:disable() end
function OBJ:clear() self.children = {} end
function OBJ:build(list) for _, c in ipairs(list) do newObj(c.type, self, c) end return {} end
function OBJ:getScrollPos() return 0, 0 end
function OBJ:close() end

local function installLvgl()
  local lv = {
    clear = function(o) if o == nil then L.roots = {} else o.children = {} end end,
    build = function(a, b)
      local parent, list = nil, a
      if b ~= nil then parent, list = a, b end
      for _, c in ipairs(list) do newObj(c.type, parent, c) end
      return {}
    end,
    isFullScreen = function() return L.fs end,
    isAppMode = function() return true end,
    exitFullScreen = function() L.exits = L.exits + 1 end,
    getContext = function() return nil end,
    set = function(o, t) o:set(t) end, show = function() end, hide = function() end,
    enable = function() end, disable = function() end, close = function() end,
    confirm = function() end, message = function() end, menu = function() end,
    FLOW_ROW = 0, FLOW_COLUMN = 1, PAD_TINY = 2, PAD_SMALL = 4, PAD_MEDIUM = 6, PAD_LARGE = 8,
    PAD_OUTLINE = 2, PAD_BORDER = 2, PAGE_BODY_HEIGHT = 275, UI_ELEMENT_HEIGHT = 32, LCD_SCALE = 1.0,
    PERCENT_SIZE = 0x2000, SCROLL_OFF = 0, SCROLL_HOR = 1, SCROLL_VER = 2, SCROLL_ALL = 3,
  }
  for _, name in ipairs(CTORS) do
    lv[name] = function(a, b)
      if b ~= nil then return newObj(name, a, b) end
      return newObj(name, nil, a)
    end
  end
  lvgl = lv
end

local function pollAll()
  for i = 1, #L.roots do poll(L.roots[i]) end
end

---------------------------------------------------------------- EdgeTX globals beyond glue_mock
local fake, inbox, pushes, pops
local function installRadio(withElrs)
  mock.install()
  mock.real = true
  installLvgl()
  STDSIZE, BOLD, TINSIZE, SMLSIZE, MIDSIZE, DBLSIZE, XXLSIZE = 0, 256, 512, 768, 1024, 1280, 1536
  LEFT, VCENTER, CENTER, RIGHT, VTOP, VBOTTOM = 0, 2, 4, 8, 0, 0x200
  COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_PRIMARY3 = 0x10000, 0x20000, 0x30000
  COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2, COLOR_THEME_SECONDARY3 = 0x40000, 0x50000, 0x60000
  COLOR_THEME_FOCUS, COLOR_THEME_EDIT, COLOR_THEME_ACTIVE = 0x70000, 0x80000, 0x90000
  COLOR_THEME_WARNING, COLOR_THEME_DISABLED = 0xA0000, 0xB0000
  BLACK, WHITE, RED, GREEN, YELLOW, GREY = 0x8000, 0xFFFF8000, 0xF8008000, 0x07E08000, 0xFFE08000, 0x84108000
  DARKGREY, LIGHTGREY, ORANGE, BLUE = 0x42088000, 0xC6188000, 0xFD208000, 0x001F8000
  LCD_W, LCD_H = 480, 320
  EVT_VIRTUAL_EXIT, EVT_VIRTUAL_ENTER = 1543, 1544
  lcd.sizeText = function(text, flags)
    local idx = ((flags or 0) & 0x0F00) >> 8
    local cw = ({ [0] = 9, 9, 5, 7, 13, 18, 36 })[idx] or 9
    local lh = ({ [0] = 19, 19, 12, 17, 29, 40, 78 })[idx] or 19
    return #tostring(text) * cw, lh
  end
  lcd.RGB = function(r, g, b) return 0x8000 + (r or 0) end
  lcd.drawText = function() end
  getVersion = function() return "2.12.0-rc1", "tx15", 2, 12, 0, "EdgeTX" end
  getUsage = function() return 10 end
  playTone = function() end
  playHaptic = function() end
  playFile = function() end
  fake = withElrs and FakeElrs.new({ version = "4.1.0", band = 5, channel = 4 }) or nil
  inbox, pushes, pops = {}, 0, 0
  crossfireTelemetryPush = function(cmd, data)
    if cmd == nil then return withElrs and true or nil end
    pushes = pushes + 1
    if fake then fake:handle(getTime() * 10, cmd, data) end
    return true
  end
  crossfireTelemetryPop = function()
    pops = pops + 1
    if #inbox == 0 and fake then
      local due = fake:poll(getTime() * 10)
      for i = 1, #due do inbox[#inbox + 1] = due[i] end
    end
    local f = table.remove(inbox, 1)
    if f == nil then return nil end
    return f.cmd, f.data
  end
  -- model1 sensors
  for name, v in pairs({ ["1RSS"] = -60, ["2RSS"] = -66, RQly = 100, RSNR = 9, ANT = 0, RFMD = 7, TPWR = 25,
                         TRSS = -55, TQly = 100, TSNR = 8, FM = "ACRO", RxBt = 16.5, Curr = 2.3, Capa = 150,
                         ["Bat%"] = 90 }) do
    mock.add(name, v)
  end
end

local function zone() return { x = 0, y = 0, w = 480, h = 320, xabs = 0, yabs = 0 } end

-- one firmware cycle: refresh then polling (both share one budget)
local function cycle(W, wgt, event)
  mock.advance(5)
  W.refresh(wgt, event, nil)
  pollAll()
end

local function measuredCycle(W, wgt, event)
  mock.advance(5)
  return mock.count(function() W.refresh(wgt, event, nil); pollAll() end)
end

local function stats(list)
  local t, worst = 0, 0
  for _, n in ipairs(list) do t = t + n; if n > worst then worst = n end end
  return t // math.max(1, #list), worst
end

---------------------------------------------------------------- run with the fake ELRS module
installRadio(true)
local W = assert(loadfile(mock.WIDGET .. "main.lua"))()
local opts = { darkTheme = 1, transpLevel = 4, vtxOff = 0, hideTrims = 0, rxCells = 0, extTrims = 0 }
local wgt = W.create(zone(), opts, "/WIDGETS/FPVDASH/")
mock.eq(wgt.err, nil, "create without error")
if wgt.err then print("create error: " .. tostring(wgt.err)) end

if wgt.err == nil then
  local ok, e = pcall(W.update, wgt, opts)
  mock.check(ok, "update: " .. tostring(e))
  mock.eq(wgt.err, nil, "dashboard built without error")
  if wgt.err then print("build error: " .. tostring(wgt.err)) end
  pollAll()
  mock.eq(#L.errors, 0, "property checks after build")

  -- 30 s on the dashboard: the module is found, VTX values are read
  local dashCounts = {}
  for i = 1, 600 do
    if i % 3 == 0 then mock.set("rud", (i * 37) % 2048 - 1024); mock.set("thr", (i * 11) % 2048 - 1024) end
    if i % 20 == 0 then mock.set("1RSS", -60 - (i % 7)) end
    local ok2, n = pcall(measuredCycle, W, wgt, nil)
    if not ok2 then mock.check(false, "dashboard cycle error: " .. tostring(n)); break end
    if i > 100 then dashCounts[#dashCounts + 1] = n end
  end
  local typ, worst = stats(dashCounts)
  print(string.format("dashboard cycle: typical %d, worst %d instructions (refresh + polling)", typ, worst))
  print(string.format("E.found=%s E.label=%q V.state=%s V.msg=%q S.rateHz=%s",
    tostring(wgt.E.found), tostring(wgt.E.label), tostring(wgt.V.state), tostring(wgt.V.msg), tostring(wgt.S.rateHz)))
  mock.check(wgt.E.found == true, "ELRS module found through the glue tick")
  mock.eq(#L.errors, 0, "property checks on the dashboard")

  -- background for 2 s
  for _ = 1, 40 do mock.advance(5); W.background(wgt) end

  -- enter full screen (firmware: update), page cycles, RTN, exit without update
  L.fs = true
  local enterN = mock.count(function() W.update(wgt, opts); pollAll() end)
  local enterV12 = mock.count(function() L.fs = false; W.update(wgt, opts); L.fs = true; W.update(wgt, opts) end)
  mock.eq(wgt.err, nil, "VTX page built without error")
  if wgt.err then print("page error: " .. tostring(wgt.err)) end
  mock.eq(wgt.pageOpen, wgt.err == nil, "page open")
  local pageCounts = {}
  for _ = 1, 200 do
    local ok3, n = pcall(measuredCycle, W, wgt, 0)
    if not ok3 then mock.check(false, "page cycle error: " .. tostring(n)); break end
    pageCounts[#pageCounts + 1] = n
  end
  local ptyp, pworst = stats(pageCounts)
  print(string.format("full screen enter: rc1 (update + polling) %d, 2.12.0+ (update only, incl. exit build) %d; page cycle: typical %d, worst %d", enterN, enterV12, ptyp, pworst))
  mock.eq(#L.errors, 0, "property checks on the VTX page")
  cycle(W, wgt, EVT_VIRTUAL_EXIT)
  mock.eq(L.exits, 1, "RTN exits full screen")
  L.fs = false
  local exitN = measuredCycle(W, wgt, nil)
  print(string.format("full screen exit (dashboard shown again in refresh + polling): %d instructions", exitN))
  mock.eq(wgt.pageOpen, false, "back on the dashboard")
  mock.eq(wgt.err, nil, "no error after exit")
  for _ = 1, 20 do cycle(W, wgt, nil) end
  mock.eq(#L.errors, 0, "property checks after exit")
end

---------------------------------------------------------------- vtxOff = 1: no CRSF calls
installRadio(true)
W = assert(loadfile(mock.WIDGET .. "main.lua"))()
local opts0 = { darkTheme = 1, transpLevel = 1, vtxOff = 1, hideTrims = 1, rxCells = 4, extTrims = 0 }
wgt = W.create(zone(), opts0, "/WIDGETS/FPVDASH/")
mock.eq(wgt.err, nil, "vtxOff 1: create")
if wgt.err == nil then
  W.update(wgt, opts0)
  pollAll()
  for _ = 1, 200 do cycle(W, wgt, nil); W.background(wgt) end
  L.fs = true
  W.update(wgt, opts0)
  pollAll()
  for _ = 1, 20 do cycle(W, wgt, 0) end
  L.fs = false
  for _ = 1, 20 do cycle(W, wgt, nil) end
  mock.eq(wgt.err, nil, "vtxOff 1: no error")
  mock.eq(pushes + pops, 0, "vtxOff 1: no crossfireTelemetryPush/Pop calls")
  mock.eq(wgt.E.label, "ELRS", "vtxOff 1: footer text ELRS")
  mock.eq(wgt.S.cells, 4, "vtxOff 1: rxCells option used")
  mock.eq(#L.errors, 0, "vtxOff 1: property checks")
end

for i = 1, math.min(10, #L.errors) do print("property error: " .. L.errors[i]) end
mock.finish("glue_integration_test")
