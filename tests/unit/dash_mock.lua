-- Minimal strict LVGL + EdgeTX mock for the dashboard unit tests (desktop Lua 5.5).
-- Checks: valid keys per object type, function-only keys, integer coordinates,
-- w/h >= 1 for rectangles/lines/images, image files exist, property return types.

local M = {}

M.objects = {}
M.roots = {}
M.fullscreen = false
M.violations = {}
M.calls = 0

local function keyset(...)
  local s = {}
  for _, list in ipairs({ ... }) do
    for _, k in ipairs(list) do s[k] = true end
  end
  return s
end

local BASE = { "x", "y", "w", "h", "color", "opacity", "visible", "size", "pos" }
local WIN = { "flexFlow", "flexPad", "active" }
local BOX = { "align", "scrollBar", "scrollDir", "scrollTo", "scrolled" }
local KEYS = {
  label = keyset(BASE, { "text", "font", "align" }),
  hline = keyset(BASE, { "rounded", "dashGap", "dashWidth" }),
  vline = keyset(BASE, { "rounded", "dashGap", "dashWidth" }),
  box = keyset(BASE, WIN, BOX),
  rectangle = keyset(BASE, WIN, BOX, { "thickness", "filled", "rounded" }),
  circle = keyset(BASE, WIN, BOX, { "radius", "thickness", "filled" }),
  image = keyset(BASE, WIN, { "file", "fill" }),
}
local CONTAINER = { box = true, rectangle = true, circle = true }
local FN_ONLY = { visible = true, pos = true, size = true, active = true }
local NEED_WH = { rectangle = true, hline = true, vline = true, image = true }

-- font metrics (approximation of the EdgeTX std font set)
M.FONT = { STDSIZE = 0x000, BOLD = 0x100, TINSIZE = 0x200, SMLSIZE = 0x300, MIDSIZE = 0x400,
           DBLSIZE = 0x500, XXLSIZE = 0x600 }
local SCALE = { [0] = 1.25, [1] = 1.3, [2] = 0.7, [3] = 1.0, [4] = 1.93, [5] = 2.6, [6] = 5.0 }
local LINE = { [0] = 19, [1] = 19, [2] = 12, [3] = 17, [4] = 29, [5] = 40, [6] = 78 }
local NARROW = { ["I"] = 3, ["i"] = 3, ["l"] = 3, ["j"] = 3, [":"] = 3, ["."] = 3, [","] = 3,
                 [" "] = 3, ["-"] = 4, ["("] = 4, [")"] = 4, ["/"] = 4, ["f"] = 4, ["t"] = 4,
                 ["r"] = 4, ["%"] = 9, ["m"] = 11, ["w"] = 9, ["M"] = 10, ["W"] = 11 }

local function charW(c)
  local n = NARROW[c]
  if n then return n end
  if string.match(c, "%d") then return 7 end
  if string.match(c, "%u") then return 8 end
  return 7
end

function M.sizeText(text, flags)
  text = tostring(text)
  local idx = ((flags or 0) & 0x0F00) >> 8
  local w = 0
  for i = 1, #text do w = w + charW(string.sub(text, i, i)) end
  return math.floor(w * (SCALE[idx] or 1) + 0.5), LINE[idx] or 19
end

local function fail(o, msg)
  error(string.format("%s#%d: %s", o and o.kind or "?", o and o.id or 0, msg), 0)
end

local function isInt(v)
  return math.type(v) == "integer"
end

-- Evaluate the property functions of one object (and optionally its children).
local function evalObj(o, recurse)
  local p = o.p
  if p.visible then
    M.calls = M.calls + 1
    local v = p.visible()
    if type(v) ~= "boolean" then fail(o, "visible() returned " .. type(v)) end
    o.vis = v
  else
    o.vis = true
  end
  if not o.vis then return end

  if type(p.color) == "function" then
    M.calls = M.calls + 1
    local c = p.color()
    if not isInt(c) then fail(o, "color() returned " .. tostring(c)) end
    o.color = c
  end
  if type(p.opacity) == "function" then
    M.calls = M.calls + 1
    local a = p.opacity()
    if not isInt(a) then fail(o, "opacity() returned " .. tostring(a)) end
  end
  if p.size then
    M.calls = M.calls + 1
    local w, h = p.size()
    if not isInt(w) or not isInt(h) then fail(o, "size() must return 2 integers") end
    if w < 1 or h < 1 then fail(o, "size() returned a size < 1") end
    o.w, o.h = w, h
  end
  if p.pos then
    M.calls = M.calls + 1
    local x, y = p.pos()
    if not isInt(x) or not isInt(y) then
      fail(o, "pos() must return 2 integers, got " .. tostring(x) .. "," .. tostring(y))
    end
    o.x, o.y = x, y
  end
  if recurse then
    for i = 1, #o.children do evalObj(o.children[i], true) end
  end
  if type(p.text) == "function" then
    M.calls = M.calls + 1
    local t = p.text()
    if type(t) ~= "string" then fail(o, "text() returned " .. type(t)) end
    o.text = t
  end
  if type(p.font) == "function" then
    M.calls = M.calls + 1
    local f = p.font()
    if not isInt(f) then fail(o, "font() returned " .. tostring(f)) end
    o.font = f
  end
  if type(p.filled) == "function" then
    M.calls = M.calls + 1
    local f = p.filled()
    if type(f) ~= "boolean" then fail(o, "filled() returned " .. type(f)) end
    o.filled = f
  end
  if type(p.file) == "function" then
    M.calls = M.calls + 1
    local f = p.file()
    if type(f) ~= "string" then fail(o, "file() returned " .. type(f)) end
    o.file = f
  end
end

local function fileExists(path)
  local f = io.open(M.sdRoot .. "/" .. string.gsub(path, "^/", ""), "rb")
  if f then f:close() return true end
  return false
end

local MT_SIMPLE, MT_FULL = {}, {}

local function create(kind, parent, t)
  if type(t) ~= "table" then error(kind .. ": params must be a table", 0) end
  if parent ~= nil then
    if type(parent) ~= "table" or not parent.kind then error(kind .. ": bad parent", 0) end
    if not CONTAINER[parent.kind] then error(kind .. ": parent " .. parent.kind .. " is not a container", 0) end
  end
  local o = { kind = kind, p = t, parent = parent, children = {}, id = #M.objects + 1 }
  local keys = KEYS[kind]
  for k, v in pairs(t) do
    if not keys[k] then fail(o, "invalid property '" .. tostring(k) .. "'") end
    if FN_ONLY[k] and type(v) ~= "function" then fail(o, "'" .. k .. "' must be a function") end
  end
  for _, k in ipairs({ "x", "y", "w", "h" }) do
    if t[k] ~= nil and not isInt(t[k]) then fail(o, k .. " must be an integer, got " .. tostring(t[k])) end
  end
  if NEED_WH[kind] then
    if t.w == nil or t.h == nil then fail(o, "w and h are required") end
    if t.w < 1 or t.h < 1 then fail(o, "w/h must be >= 1 (" .. t.w .. "x" .. t.h .. ")") end
  end
  if t.w ~= nil and t.w < 0 then fail(o, "negative w") end
  if t.h ~= nil and t.h < 0 then fail(o, "negative h") end
  if kind == "label" then
    local tt = type(t.text)
    if t.text ~= nil and tt ~= "string" and tt ~= "function" then fail(o, "text must be a string or function") end
    if t.align ~= nil and t.w == nil then fail(o, "align needs w") end
  end
  if kind == "image" then
    if type(t.file) == "string" then
      if string.sub(t.file, 1, 1) == "/" then fail(o, "image file with a leading slash") end
      if not fileExists(t.file) then fail(o, "image file not found: " .. t.file) end
    elseif type(t.file) ~= "function" then
      fail(o, "image needs file")
    end
  end
  if t.color ~= nil and type(t.color) ~= "function" and not isInt(t.color) then fail(o, "bad color") end
  if t.opacity ~= nil and type(t.opacity) ~= "function" and not isInt(t.opacity) then fail(o, "bad opacity") end
  if kind == "rectangle" and t.rounded ~= nil and not isInt(t.rounded) then fail(o, "rounded must be an integer") end

  o.x, o.y, o.w, o.h = t.x or 0, t.y or 0, t.w, t.h
  o.w0 = t.w
  o.font = (type(t.font) ~= "function") and t.font or 0
  o.text = (type(t.text) == "string") and t.text or ""
  o.file = (type(t.file) == "string") and t.file or nil
  o.filled = (type(t.filled) ~= "function") and t.filled or false
  o.color = (type(t.color) ~= "function") and t.color or nil
  setmetatable(o, CONTAINER[kind] and MT_FULL or MT_SIMPLE)
  M.objects[#M.objects + 1] = o
  if parent then parent.children[#parent.children + 1] = o else M.roots[#M.roots + 1] = o end
  evalObj(o, false)                                 -- firmware polls once at creation
  return o
end

local function ctor(kind)
  return function(a, b)
    if b ~= nil then return create(kind, a, b) end
    return create(kind, nil, a)
  end
end

local methods = {}
for _, k in ipairs({ "label", "rectangle", "box", "image", "hline", "vline", "circle" }) do
  methods[k] = function(self, t) return create(k, self, t) end
end
methods.set = function() end
methods.show = function() end
methods.hide = function() end
MT_FULL.__index = methods
MT_SIMPLE.__index = { set = methods.set, show = methods.show, hide = methods.hide }

function M.reset()
  M.objects, M.roots, M.violations = {}, {}, {}
end

-- Poll every property function like the firmware does each 50 ms cycle.
function M.poll()
  for i = 1, #M.roots do evalObj(M.roots[i], true) end
end

-- Absolute geometry and effective visibility (after a poll).
local function walk(o, px, py, pvis)
  o.ax, o.ay = px + o.x, py + o.y
  o.avis = pvis and (o.vis ~= false)
  if o.kind == "label" then
    local w, h = M.sizeText(o.text or "", o.font or 0)
    o.tw = w
    o.aw, o.ah = o.w0 or w, h
    if o.w0 and o.p.align then
      local a = o.p.align
      if a & 8 ~= 0 then o.tx = o.ax + o.w0 - w
      elseif a & 4 ~= 0 then o.tx = o.ax + (o.w0 - w) // 2
      else o.tx = o.ax end
    else
      o.tx = o.ax
    end
  else
    o.aw, o.ah = o.w or 0, o.h or 0
  end
  for i = 1, #o.children do walk(o.children[i], o.ax, o.ay, o.avis) end
end

function M.layout()
  for i = 1, #M.roots do walk(M.roots[i], 0, 0, true) end
end

local CONTROLS = { "button", "momentaryButton", "toggle", "textEdit", "numberEdit", "choice", "slider",
                   "verticalSlider", "page", "dialog", "setting", "font", "align", "color", "timer",
                   "switch", "source", "file" }

function M.install(sdRoot)
  M.sdRoot = sdRoot
  for k, v in pairs(M.FONT) do _G[k] = v end
  LEFT, VCENTER, CENTER, RIGHT, VTOP, VBOTTOM = 0, 2, 4, 8, 0, 0x200
  local names = { "WHITE", "BLACK", "RED", "GREEN", "YELLOW", "GREY", "DARKGREY", "LIGHTGREY", "ORANGE",
                  "BLUE", "COLOR_THEME_PRIMARY1", "COLOR_THEME_PRIMARY2", "COLOR_THEME_PRIMARY3",
                  "COLOR_THEME_SECONDARY1", "COLOR_THEME_SECONDARY2", "COLOR_THEME_SECONDARY3",
                  "COLOR_THEME_FOCUS", "COLOR_THEME_EDIT", "COLOR_THEME_ACTIVE", "COLOR_THEME_WARNING",
                  "COLOR_THEME_DISABLED" }
  M.COLOR = {}
  for i, n in ipairs(names) do
    _G[n] = 0x10000 * i
    M.COLOR[n] = 0x10000 * i
  end
  LCD_W, LCD_H = 480, 320
  lcd = {
    sizeText = M.sizeText,
    RGB = function(r, g, b) return (((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)) * 0x10000 + 0x8000 end,
  }
  getVersion = function() return "2.12.0-rc1", "tx15", 2, 12, 0, "EdgeTX" end
  loadScript = function(path)
    local p = string.gsub(path, "^/", "")
    return loadfile(sdRoot .. "/" .. p)
  end
  lvgl = {
    clear = function() M.reset() end,
    isFullScreen = function() return M.fullscreen end,
    isAppMode = function() return true end,
    exitFullScreen = function() end,
    SCROLL_OFF = 0, SCROLL_HOR = 3, SCROLL_VER = 12, SCROLL_ALL = 15,
  }
  for _, k in ipairs({ "label", "rectangle", "box", "image", "hline", "vline", "circle" }) do
    lvgl[k] = ctor(k)
  end
  for _, k in ipairs(CONTROLS) do
    lvgl[k] = function()
      M.violations[#M.violations + 1] = "control " .. k .. " used in the dashboard"
      return nil
    end
  end
end

-- Count Lua VM instructions executed inside the widget UI files while fn runs.
function M.countInstr(fn, ...)
  local n = 0
  local getinfo, find = debug.getinfo, string.find
  local function hook()
    local info = getinfo(2, "S")
    if info and find(info.source, "FPVDASH/ui/", 1, true) then n = n + 1 end
  end
  debug.sethook(hook, "", 1)
  local ok, err = pcall(fn, ...)
  debug.sethook()
  if not ok then error(err, 0) end
  return n
end

return M
