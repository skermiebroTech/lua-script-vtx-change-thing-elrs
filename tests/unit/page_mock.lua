-- Small strict mock of the EdgeTX 2.12 LVGL Lua API, for the VTX page unit test.
-- Checks: valid keys per object type (2.12.0+ strictness), function-only keys,
-- property return types (never nil), controls only in full screen.
-- Keeps a tree of objects with absolute geometry for layout checks.

local M = {}

M.LCD_W, M.LCD_H = 480, 320

-- fonts: FONT(index) = index << 8
local FONTS = { STDSIZE = 0, BOLD = 256, TINSIZE = 512, SMLSIZE = 768, MIDSIZE = 1024, DBLSIZE = 1280 }
-- approximate average glyph width and line height per font (px)
local FONT_CW = { [0] = 9, [256] = 9, [512] = 5, [768] = 7, [1024] = 13, [1280] = 18 }
local FONT_LH = { [0] = 19, [256] = 19, [512] = 12, [768] = 17, [1024] = 29, [1280] = 40 }
M.FONT_LH = FONT_LH

local COLORS = {
  COLOR_THEME_PRIMARY1 = 0x00010000, COLOR_THEME_PRIMARY2 = 0x00020000,
  COLOR_THEME_PRIMARY3 = 0x00030000, COLOR_THEME_SECONDARY1 = 0x00040000,
  COLOR_THEME_SECONDARY2 = 0x00050000, COLOR_THEME_SECONDARY3 = 0x00060000,
  COLOR_THEME_FOCUS = 0x00070000, COLOR_THEME_EDIT = 0x00080000,
  COLOR_THEME_ACTIVE = 0x00090000, COLOR_THEME_WARNING = 0x000A0000,
  COLOR_THEME_DISABLED = 0x000B0000,
  BLACK = 0x00108000, WHITE = 0xFFFF8000, RED = 0xF8008000, GREEN = 0x07E08000,
  YELLOW = 0xFFE08000, GREY = 0x84108000, DARKGREY = 0x42088000, LIGHTGREY = 0xC6188000,
  ORANGE = 0xFD208000,
}
M.COLORS = COLORS

-- valid keys (lvgl_api.md 5.5)
local function set(...)
  local t = {}
  for _, l in ipairs({ ... }) do for _, k in ipairs(l) do t[k] = true end end
  return t
end
local BASE = { "x", "y", "w", "h", "color", "opacity", "visible", "size", "pos" }
local WIN = { "flexFlow", "flexPad", "active" }
local BOXK = { "align", "scrollBar", "scrollDir", "scrollTo", "scrolled" }
local VALID = {
  label = set(BASE, { "text", "font", "align" }),
  rectangle = set(BASE, WIN, BOXK, { "thickness", "filled", "rounded" }),
  box = set(BASE, WIN, BOXK),
  circle = set(BASE, WIN, BOXK, { "radius", "thickness", "filled" }),
  hline = set(BASE, { "rounded", "dashGap", "dashWidth" }),
  vline = set(BASE, { "rounded", "dashGap", "dashWidth" }),
  image = set(BASE, WIN, { "file", "fill" }),
  button = set(BASE, WIN, { "text", "font", "press", "longpress", "checked", "textColor", "cornerRadius" }),
}
local FN_ONLY = { visible = true, size = true, pos = true, active = true }
local CALLBACK = { press = true, longpress = true, scrolled = true }
-- keys whose functions are polled, and the expected return kind
local POLLED = {
  color = "number", opacity = "number", text = "string", font = "number", align = "number",
  filled = "bool", radius = "number", textColor = "number", file = "string",
  visible = "bool", active = "bool", size = "pair", pos = "pair",
}
local CONTROL = { button = true }
local FULLMETA = { rectangle = true, circle = true, box = true }

M.errors = {}
local function err(msg)
  M.errors[#M.errors + 1] = msg
  error(msg, 0)
end

M.fullScreen = true
M.exitCalls = 0
M.popups = {}
M.root = { children = {}, x = 0, y = 0, w = M.LCD_W, h = M.LCD_H, type = "root" }
M.objCount = 0
M.fnCalls = 0

local function checkRet(o, key, kind, a, b)
  if kind == "bool" then
    if type(a) ~= "boolean" and type(a) ~= "number" then
      err(string.format("%s.%s returned %s (want boolean)", o.type, key, type(a)))
    end
  elseif kind == "number" then
    if type(a) ~= "number" then
      err(string.format("%s.%s returned %s (want number)", o.type, key, type(a)))
    end
  elseif kind == "string" then
    if type(a) ~= "string" then
      err(string.format("%s.%s returned %s (want string)", o.type, key, type(a)))
    end
  elseif kind == "pair" then
    if type(a) ~= "number" or type(b) ~= "number" then
      err(string.format("%s.%s returned non numbers", o.type, key))
    end
  end
end

local function resolve(o, key)
  local v = o.p[key]
  if type(v) == "function" then
    M.fnCalls = M.fnCalls + 1
    local a, b = v()
    checkRet(o, key, POLLED[key], a, b)
    if POLLED[key] == "pair" then return { a, b } end
    return a
  end
  return v
end

-- Poll one object like callRefs: visible first; hidden -> stop (children skipped).
local function pollObj(o)
  if o.p.visible ~= nil then
    local v = resolve(o, "visible")
    o.visible = (v == true) or (type(v) == "number" and v ~= 0)
  else
    o.visible = true
  end
  if not o.visible then return end
  o.cur = o.cur or {}
  for _, k in ipairs({ "color", "opacity", "size", "pos" }) do
    if o.p[k] ~= nil then o.cur[k] = resolve(o, k) end
  end
  for _, c in ipairs(o.children) do pollObj(c) end
  for _, k in ipairs({ "active", "filled", "radius", "text", "font", "align", "textColor", "file" }) do
    if o.p[k] ~= nil then o.cur[k] = resolve(o, k) end
  end
end
M.pollObj = pollObj

function M.poll()
  for _, c in ipairs(M.root.children) do pollObj(c) end
end

local methods = {}
local function makeObj(typ, parent, params)
  if type(params) ~= "table" then err(typ .. ": params must be a table") end
  local valid = VALID[typ]
  for k, v in pairs(params) do
    if not valid[k] then err(string.format("Invalid property '%s' for %s", tostring(k), typ)) end
    if FN_ONLY[k] and type(v) ~= "function" then
      err(string.format("%s.%s must be a function (got %s)", typ, k, type(v)))
    end
    if CALLBACK[k] and type(v) ~= "function" then err(typ .. "." .. k .. " must be a function") end
  end
  if CONTROL[typ] and not M.fullScreen then return nil end
  if (typ == "hline" or typ == "vline") and (params.w == nil or params.h == nil) then
    err(typ .. " needs w and h")
  end
  if typ == "rectangle" and (params.w == nil or params.h == nil) then err("rectangle needs w and h") end
  if typ == "image" and (params.w == nil or params.h == nil) then err("image needs w and h") end
  local o = { type = typ, p = params, parent = parent or M.root, children = {} }
  o.x, o.y = params.x or 0, params.y or 0
  o.w, o.h = params.w, params.h
  table.insert(o.parent.children, o)
  M.objCount = M.objCount + 1
  setmetatable(o, { __index = methods[typ] })
  pollObj(o)
  return o
end

local CTORS = { "label", "rectangle", "box", "circle", "hline", "vline", "image", "button" }

local function simpleMethods()
  return {
    set = function(self, t) for k, v in pairs(t) do self.p[k] = v end end,
    show = function(self) end, hide = function(self) end,
  }
end
for _, typ in ipairs(CTORS) do
  local m = simpleMethods()
  if FULLMETA[typ] then
    for _, c in ipairs(CTORS) do
      m[c] = function(self, params) return makeObj(c, self, params) end
    end
  end
  methods[typ] = m
end

local lvgl = {}
for _, c in ipairs(CTORS) do
  lvgl[c] = function(a, b)
    if b ~= nil then return makeObj(c, a, b) end
    return makeObj(c, nil, a)
  end
end
function lvgl.clear() M.root.children = {} end
function lvgl.isFullScreen() return M.fullScreen end
function lvgl.isAppMode() return true end
function lvgl.exitFullScreen() M.exitCalls = M.exitCalls + 1 end
local function popup(kind, valid)
  return function(t)
    for k in pairs(t) do
      if not valid[k] then err("Invalid property '" .. k .. "' for " .. kind) end
    end
    if kind == "menu" then
      if type(t.values) ~= "table" then err("menu needs values") end
      if type(t.get) ~= "function" or type(t.set) ~= "function" then err("menu needs get/set") end
      local i = t.get()
      if math.type(i) ~= "integer" then err("menu get must return an integer") end
    end
    M.popups[#M.popups + 1] = { kind = kind, t = t }
  end
end
lvgl.menu = popup("menu", set({ "title", "values", "get", "set" }))
lvgl.confirm = popup("confirm", set({ "title", "message", "confirm", "cancel" }))
lvgl.message = popup("message", set({ "title", "message", "details" }))
lvgl.SCROLL_OFF, lvgl.SCROLL_HOR, lvgl.SCROLL_VER, lvgl.SCROLL_ALL = 0, 1, 2, 3
lvgl.PAD_OUTLINE = 2
lvgl.UI_ELEMENT_HEIGHT = 32
M.lvgl = lvgl

local lcd = {}
function lcd.sizeText(text, font)
  font = font or 0
  local cw = FONT_CW[font] or 9
  return #text * cw, FONT_LH[font] or 19
end
function lcd.RGB(r, g, b) return 0x8000 end
M.lcd = lcd

function M.install(G)
  G.lvgl = lvgl
  G.lcd = lcd
  G.LCD_W, G.LCD_H = M.LCD_W, M.LCD_H
  for k, v in pairs(FONTS) do G[k] = v end
  for k, v in pairs(COLORS) do G[k] = v end
  G.LEFT, G.VCENTER, G.CENTER, G.RIGHT = 0, 2, 4, 8
  G.EVT_VIRTUAL_EXIT = 1
  G.getTime = function() return 0 end
end

function M.reset()
  M.root.children = {}
  M.popups = {}
  M.errors = {}
  M.exitCalls = 0
  M.objCount = 0
end

-- Walk the tree; fn(o, ax, ay, effVisible)
function M.walk(fn)
  local function rec(o, px, py, vis)
    for _, c in ipairs(o.children) do
      local ax, ay = px + c.x, py + c.y
      local v = vis and (c.visible ~= false)
      fn(c, ax, ay, v)
      rec(c, ax, ay, v)
    end
  end
  rec(M.root, 0, 0, true)
end

-- Text of an object after the last poll
function M.textOf(o)
  if o.cur and o.cur.text ~= nil then return o.cur.text end
  if type(o.p.text) == "string" then return o.p.text end
  return nil
end

-- Visible buttons (after the last poll)
function M.visibleButtons()
  local list = {}
  M.walk(function(o, ax, ay, vis)
    if o.type == "button" and vis then list[#list + 1] = { o = o, x = ax, y = ay, w = o.w, h = o.h } end
  end)
  return list
end

function M.findButton(text)
  for _, b in ipairs(M.visibleButtons()) do
    if M.textOf(b.o) == text then return b.o end
  end
  return nil
end

-- Press a button: callback must return nothing (nil).
function M.press(o)
  local r = o.p.press()
  if r ~= nil then err("press callback returned a value: " .. tostring(r)) end
end

-- Label rectangle estimate (w from text when not set)
function M.labelRect(o, ax, ay)
  local font = (o.cur and o.cur.font) or o.p.font or 0
  if type(font) ~= "number" then font = 0 end
  local t = M.textOf(o) or ""
  local w = o.w
  if w == nil then w = #t * (FONT_CW[font] or 9) end
  return ax, ay, w, FONT_LH[font] or 19
end

return M
