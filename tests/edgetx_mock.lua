-- edgetx_mock.lua : strict mock of the EdgeTX 2.12 (rc1 + 2.12.x) Lua environment
-- for LVGL widgets, for desktop Lua 5.5. Test harness only (never on the SD card).
--
-- Sources: research/lvgl_api.md (sections 3-8), the rc1 firmware source
-- (lua_lvgl_widget.cpp, api_colorlcd_lvgl.cpp, lua_widget.cpp, api_general.cpp),
-- research/fpvdash_spec.md (font widths), research/elrs_crsf_vtx.md (CRSF transport).
--
-- Main ideas:
--  * Every scenario makes a fresh "radio" R = Mock.new{...}. R owns a sandbox
--    global table (R.env) that looks like the EdgeTX Lua state: no os, io (only
--    a small mock), debug, coroutine, utf8, unpack, loadstring, require.
--  * The widget is loaded from the SD card copy through the mock loadScript and
--    run like the firmware does: create -> update (+ property poll) -> refresh
--    (+ property poll) every 50 ms cycle while visible, background otherwise.
--  * LVGL objects are plain tables behind proxy handles. Unknown property keys,
--    non-function visible/pos/size/active, property functions that return nil
--    or a wrong type, use of cleared handles, and similar mistakes raise errors
--    that disable the widget instance, as on the radio.
--  * Lua VM instructions of widget code are counted with a count hook (count 1).
--    Mock code is not counted (the hook is off while mock code runs), so the
--    numbers approximate the firmware budget (C calls count as one instruction).
--
-- IMPORTANT: this file (and all harness files) must not use string method syntax
-- (s:sub()), because the mock replaces the string metatable with a trap that
-- reports such use in widget code.

local M = {}

local sethook = debug.sethook
local getinfo = debug.getinfo
local dtraceback = debug.traceback
local floor = math.floor
local sformat = string.format
local tconcat = table.concat
local tunpack = table.unpack

---------------------------------------------------------------------------
-- paths
---------------------------------------------------------------------------

local MOCK_SRC = getinfo(1, "S").source
local MOCK_FILE = string.gsub(MOCK_SRC, "^@", "")
if string.sub(MOCK_FILE, 1, 1) ~= "/" then
  local pwd = os.getenv("PWD") or "."
  MOCK_FILE = pwd .. "/" .. MOCK_FILE
end
-- normalise "/a/b/./tests/x" and "/a/b/tests/../tests/x"
local function normPath(p)
  local parts = {}
  for seg in string.gmatch(p, "[^/]+") do
    if seg == ".." then
      if #parts > 0 then parts[#parts] = nil end
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return "/" .. tconcat(parts, "/")
end
MOCK_FILE = normPath(MOCK_FILE)
local TESTS_DIR = string.match(MOCK_FILE, "^(.*)/[^/]*$")
local ROOT_DIR = string.match(TESTS_DIR, "^(.*)/[^/]*$")
M.TESTS_DIR = TESTS_DIR
M.ROOT_DIR = ROOT_DIR
M.SD_ROOT = ROOT_DIR .. "/radio sd card"
M.OUT_DIR = TESTS_DIR .. "/out"

local function fileExists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end
M.fileExists = fileExists

local function readFile(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end
M.readFile = readFile

local function writeFile(p, s)
  local f, err = io.open(p, "wb")
  if not f then return nil, err end
  f:write(s)
  f:close()
  return true
end
M.writeFile = writeFile

---------------------------------------------------------------------------
-- constants (values from the rc1 firmware headers)
---------------------------------------------------------------------------

local C = {}
M.C = C

C.LCD_W, C.LCD_H = 480, 320
C.FULLSCALE = 1024

-- fonts: FONT(i) = i << 8 ; STD 0, BOLD 1, XXS 2, XS 3, L 4, XL 5, XXL 6
C.STDSIZE, C.BOLD, C.TINSIZE, C.SMLSIZE, C.MIDSIZE, C.DBLSIZE, C.XXLSIZE =
  0x000, 0x100, 0x200, 0x300, 0x400, 0x500, 0x600
-- alignment / flags (libopenui_defines.h)
C.LEFT, C.VCENTER, C.CENTER, C.RIGHT, C.VTOP, C.VBOTTOM = 0x00, 0x02, 0x04, 0x08, 0x00, 0x200
C.INVERS, C.BLINK, C.SHADOWED, C.PREC1, C.PREC2 = 0x01, 0x1000, 0x80, 0x20, 0x30
C.SOLID, C.DOTTED = 0xFF, 0x55

-- colors: COLOR2FLAGS(index) = index << 16
local COLOR_INDEX = {
  COLOR_THEME_PRIMARY1 = 0, COLOR_THEME_PRIMARY2 = 1, COLOR_THEME_PRIMARY3 = 2,
  COLOR_THEME_SECONDARY1 = 3, COLOR_THEME_SECONDARY2 = 4, COLOR_THEME_SECONDARY3 = 5,
  COLOR_THEME_FOCUS = 6, COLOR_THEME_EDIT = 7, COLOR_THEME_ACTIVE = 8, COLOR_THEME_WARNING = 9,
  COLOR_THEME_DISABLED = 10, CUSTOM_COLOR = 13,
  BLACK = 14, WHITE = 15, LIGHTWHITE = 16, LIGHTGREY = 17, GREY = 18, DARKGREY = 19,
  RED = 20, DARKRED = 21, LIGHTRED = 22, GREEN = 23, DARKGREEN = 24, BRIGHTGREEN = 25,
  BLUE = 26, DARKBLUE = 27, CYAN = 28, YELLOW = 29, LIGHTBROWN = 30, DARKBROWN = 31,
  ORANGE = 32, MAGENTA = 33,
}
C.COLOR_INDEX = COLOR_INDEX
for k, v in pairs(COLOR_INDEX) do C[k] = v * 65536 end
-- RGB values used for SVG output: user's "Dark Theme" + firmware fixed color table
local INDEX_RGB = {
  [0] = 0x909490, [1] = 0xE0E0E0, [2] = 0xB8BCB8, [3] = 0x282828, [4] = 0xF08838, [5] = 0x000000,
  [6] = 0xF03C38, [7] = 0x404440, [8] = 0xF8B038, [9] = 0xE83030, [10] = 0xA07420, [11] = 0x000000,
  [12] = 0xFFFFFF, [13] = 0xAA5500,
  [14] = 0x000000, [15] = 0xFFFFFF, [16] = 0xEAEAEA, [17] = 0xC0C0C0, [18] = 0x404040, [19] = 0x606060,
  [20] = 0xFF0000, [21] = 0xA00000, [22] = 0xFF9999, [23] = 0x00FF00, [24] = 0x00A000, [25] = 0x00B43C,
  [26] = 0x0000FF, [27] = 0x0000A0, [28] = 0x00FFFF, [29] = 0xFFFF00, [30] = 0x9C6D20, [31] = 0x6A4810,
  [32] = 0xE5641E, [33] = 0x800080,
}
local INDEX_NAME = {}
for k, v in pairs(COLOR_INDEX) do INDEX_NAME[v] = k end

-- widget option types (WidgetOption::Type; VALUE = INPUT_TYPE_VALUE = 0, SOURCE = 1)
C.VALUE, C.SOURCE, C.BOOL, C.STRING, C.TEXT_SIZE, C.TIMER, C.SWITCH, C.COLOR, C.ALIGNMENT,
  C.SLIDER, C.CHOICE, C.FILE = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
-- note: COMBO does not exist in EdgeTX 2.12

-- key events (COLORLCD masks; KEY_MENU 0, EXIT 1, ENTER 2, PAGEUP 3, PAGEDN 4, ... MODEL 11, TELE 12, SYS 13)
local K_BREAK, K_REPT, K_FIRST, K_LONG = 0x200, 0x400, 0x600, 0x800
C.EVT_VIRTUAL_EXIT = 1 + K_BREAK
C.EVT_EXIT_BREAK = 1 + K_BREAK
C.EVT_EXIT_FIRST = 1 + K_FIRST
C.EVT_EXIT_LONG = 1 + K_LONG
C.EVT_VIRTUAL_ENTER = 2 + K_BREAK
C.EVT_ENTER_BREAK = 2 + K_BREAK
C.EVT_ENTER_FIRST = 2 + K_FIRST
C.EVT_ENTER_LONG = 2 + K_LONG
C.EVT_VIRTUAL_ENTER_LONG = 2 + K_LONG
C.EVT_VIRTUAL_PREV_PAGE = 3 + K_BREAK
C.EVT_VIRTUAL_NEXT_PAGE = 4 + K_BREAK
C.EVT_PAGEUP_FIRST = 3 + K_FIRST
C.EVT_PAGEDN_FIRST = 4 + K_FIRST
C.EVT_VIRTUAL_MENU = 11 + K_BREAK
C.EVT_VIRTUAL_MENU_LONG = 11 + K_LONG
C.EVT_MODEL_FIRST = 11 + K_FIRST
C.EVT_TELEM_FIRST = 12 + K_FIRST
C.EVT_SYS_FIRST = 13 + K_FIRST
C.EVT_ROTARY_LEFT, C.EVT_ROTARY_RIGHT = 0x1003, 0x1004
C.EVT_VIRTUAL_PREV, C.EVT_VIRTUAL_NEXT = 0x1003, 0x1004
C.EVT_VIRTUAL_DEC, C.EVT_VIRTUAL_INC = 0x1003, 0x1004
local EVT_TOUCH = 0x2000 + 0x74
C.EVT_TOUCH_FIRST = EVT_TOUCH + K_FIRST
C.EVT_TOUCH_BREAK = EVT_TOUCH + K_BREAK
C.EVT_TOUCH_SLIDE = EVT_TOUCH + K_LONG
C.EVT_TOUCH_TAP = EVT_TOUCH + K_REPT

-- lvgl constants
local LV_PCT0 = 8192
local LV_SIZE_CONTENT = 8192 + 2001
local LVK = {
  FLOW_ROW = 0, FLOW_COLUMN = 1,
  PAD_TINY = 2, PAD_SMALL = 4, PAD_MEDIUM = 6, PAD_LARGE = 8, PAD_OUTLINE = 2, PAD_BORDER = 2,
  SRC_ALL = 0xFFFFFFFF, SRC_INPUT = 0x1, SRC_LUA = 0x2, SRC_STICK = 0x4, SRC_POT = 0x8, SRC_OTHER = 0x10,
  SRC_HELI = 0x20, SRC_TRIM = 0x40, SRC_SWITCH = 0x80, SRC_LOGICAL_SWITCH = 0x100, SRC_TRAINER = 0x200,
  SRC_CHANNEL = 0x400, SRC_GVAR = 0x800, SRC_TELEM = 0x1000, SRC_CLEAR = 0x2000, SRC_INVERT = 0x4000,
  SW_ALL = 0xFFFFFFFF, SW_SWITCH = 0x1, SW_TRIM = 0x2, SW_LOGICAL_SWITCH = 0x4, SW_TELEM = 0x8,
  SW_OTHER = 0x10, SW_CLEAR = 0x20,
  SCROLL_OFF = 0, SCROLL_HOR = 3, SCROLL_VER = 12, SCROLL_ALL = 15,
  PERCENT_SIZE = LV_PCT0, PAGE_BODY_HEIGHT = 275, UI_ELEMENT_HEIGHT = 32, LCD_SCALE = 1.0,
  LABEL = 1, RECTANGLE = 2, CIRCLE = 3, ARC = 4, HLINE = 5, VLINE = 6, LINE = 7, TRIANGLE = 8,
  IMAGE = 9, QRCODE = 10, BOX = 11, BUTTON = 12, MOMENTARY_BUTTON = 13, TOGGLE = 14, TEXT_EDIT = 15,
  NUMBER_EDIT = 16, SLIDER = 18, VERTICAL_SLIDER = 19, PAGE = 20, FONT = 21, ALIGN = 22,
  COLOR = 23, TIMER = 24, SWITCH = 25, SOURCE = 26, FILE = 27, SETTING = 28,
}
local TYPE_BY_NUM = {
  [1] = "label", [2] = "rectangle", [3] = "circle", [4] = "arc", [5] = "hline", [6] = "vline",
  [7] = "line", [8] = "triangle", [9] = "image", [10] = "qrcode", [11] = "box", [12] = "button",
  [13] = "momentaryButton", [14] = "toggle", [15] = "textEdit", [16] = "numberEdit", [17] = "choice",
  [18] = "slider", [19] = "verticalSlider", [20] = "page", [21] = "font", [22] = "align", [23] = "color",
  [24] = "timer", [25] = "switch", [26] = "source", [27] = "file", [28] = "setting",
}

---------------------------------------------------------------------------
-- fonts and text measurement (approximation of the 480x320 "std" font set)
---------------------------------------------------------------------------

-- per-character advance at SMLSIZE (13 px Roboto), checked against the widths
-- measured in research/fpvdash_spec.md section 3.4 (+-2 px)
local CW = {}
do
  local function set(chars, w)
    for i = 1, #chars do CW[string.byte(chars, i)] = w end
  end
  for b = 32, 126 do CW[b] = 7 end
  set("0123456789", 7)
  set(" ", 3)
  set(".,:;!|il'jI", 3)
  set("-", 4)
  set("()[]{}\"fr", 4)
  set("t", 5)
  set("/\\", 5)
  set("*?", 6)
  set("acesvxyzk_", 6)
  set("bdghnopqu+=<>$~^", 7)
  set("ELFJ", 7)
  set("ABKPRSTVXYZ#&", 8)
  set("OQGCDHNU", 9)
  set("w", 9)
  set("m", 11)
  set("%M", 11)
  set("W@", 11)
end
-- font index -> { px size, line height, width scale vs SMLSIZE }
-- (MIDSIZE and DBLSIZE scales are a little wide on purpose: the measured
-- widths of section 3.4 are matched within -4..+6 %, mostly a little wide,
-- so the overlap check errs on the safe side)
local FONTS = {
  [0] = { 16, 19, 16 / 13, "STDSIZE" },
  [1] = { 16, 19, 16 / 13 * 1.08, "BOLD" },
  [2] = { 9, 12, 9 / 13, "TINSIZE" },
  [3] = { 13, 17, 1.0, "SMLSIZE" },
  [4] = { 24, 29, 1.92, "MIDSIZE" },
  [5] = { 32, 40, 2.56, "DBLSIZE" },
  [6] = { 64, 78, 5.0, "XXLSIZE" },
}
local function fontIndex(flags)
  local i = floor(((flags or 0) % 4096) / 256)
  if not FONTS[i] then i = 0 end
  return i
end
M.fontIndex = fontIndex

local function textWidthLine(s, fi)
  local w = 0
  local n = #s
  local i = 1
  while i <= n do
    local b = string.byte(s, i)
    if b < 0x80 then
      w = w + (CW[b] or 7)
      i = i + 1
    else
      -- UTF-8 sequence (or ELRS arrow byte): count one glyph
      w = w + 8
      i = i + 1
      while i <= n do
        local c = string.byte(s, i)
        if c >= 0x80 and c < 0xC0 then i = i + 1 else break end
      end
    end
  end
  return floor(w * FONTS[fi][3] + 0.5)
end

-- width of the widest line, number of lines, line height
local function measure(s, flags)
  local fi = fontIndex(flags)
  s = tostring(s or "")
  local maxw, lines = 0, 0
  for line in string.gmatch(s .. "\n", "([^\n]*)\n") do
    lines = lines + 1
    local w = textWidthLine(line, fi)
    if w > maxw then maxw = w end
  end
  if lines == 0 then lines = 1 end
  return maxw, lines, FONTS[fi][2], FONTS[fi][1]
end
M.measure = measure

---------------------------------------------------------------------------
-- bit32 (Lua implementation, unsigned 32-bit semantics like lbitlib.c)
---------------------------------------------------------------------------

local function u32(x)
  x = floor(x)
  return x % 4294967296
end
local bit32 = {}
function bit32.band(...)
  local n = select("#", ...)
  local r = 0xFFFFFFFF
  for i = 1, n do r = r & u32((select(i, ...))) end
  return r
end
function bit32.bor(...)
  local n = select("#", ...)
  local r = 0
  for i = 1, n do r = r | u32((select(i, ...))) end
  return r
end
function bit32.bxor(...)
  local n = select("#", ...)
  local r = 0
  for i = 1, n do r = r ~ u32((select(i, ...))) end
  return r
end
function bit32.bnot(x) return (~u32(x)) & 0xFFFFFFFF end
function bit32.btest(...) return bit32.band(...) ~= 0 end
function bit32.lshift(x, n)
  n = floor(n)
  if n >= 32 or n <= -32 then return 0 end
  if n < 0 then return u32(x) >> (-n) end
  return (u32(x) << n) & 0xFFFFFFFF
end
function bit32.rshift(x, n)
  n = floor(n)
  if n >= 32 or n <= -32 then return 0 end
  if n < 0 then return (u32(x) << (-n)) & 0xFFFFFFFF end
  return u32(x) >> n
end
function bit32.arshift(x, n)
  x = u32(x)
  n = floor(n)
  if n < 0 then return bit32.lshift(x, -n) end
  if x >= 0x80000000 then
    if n >= 32 then return 0xFFFFFFFF end
    return ((x >> n) | ~(0xFFFFFFFF >> n)) & 0xFFFFFFFF
  end
  if n >= 32 then return 0 end
  return x >> n
end
function bit32.extract(x, field, width)
  width = width or 1
  return (u32(x) >> field) & ((1 << width) - 1)
end
function bit32.replace(x, v, field, width)
  width = width or 1
  local mask = ((1 << width) - 1) << field
  return ((u32(x) & ~mask) | ((u32(v) << field) & mask)) & 0xFFFFFFFF
end
function bit32.lrotate(x, n)
  n = floor(n) % 32
  x = u32(x)
  return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF
end
function bit32.rrotate(x, n) return bit32.lrotate(x, -floor(n)) end
M.bit32 = bit32

---------------------------------------------------------------------------
-- instruction meter
---------------------------------------------------------------------------

local depth = 0          -- > 0 while mock code runs (not counted)
local metering = false   -- a widget call is being measured
local icount = 0
local ilimit = 20000
local limitHit = false
local apiOverhead = 0
local cbOverhead = 0
local topOverhead = 0

local function hookfn()
  icount = icount + 1
  if icount > ilimit and not limitHit then
    limitHit = true
    error("CPU limit: more than " .. ilimit .. " Lua VM instructions in one firmware call", 0)
  end
end

local function hookOn() sethook(hookfn, "", 1) end
local function hookOff() sethook() end

local function apiFinish(ok, ...)
  local d = depth - 1
  depth = d
  if d == 0 and metering then
    icount = icount - apiOverhead
    hookOn()
  end
  if not ok then error((...), 0) end
  return ...
end

-- wrap a mock function that widget code calls: its own instructions are not counted
local function api(f)
  return function(...)
    local d = depth
    depth = d + 1
    if d == 0 and metering then hookOff() end
    return apiFinish(pcall(f, ...))
  end
end
M.api = api

local function errHandler(e)
  if type(e) == "table" then return e end
  return { msg = tostring(e), tb = dtraceback("", 2) }
end

local function cwFinish(d, ok, ...)
  if metering then
    hookOff()
    icount = icount - cbOverhead
  end
  depth = d
  return ok, ...
end

-- call widget code from mock code (property functions, callbacks); counted
local function callWidget(fn, ...)
  local d = depth
  depth = 0
  if metering then hookOn() end
  return cwFinish(d, xpcall(fn, errHandler, ...))
end

local function meterStart(limit)
  icount = 0
  ilimit = limit or 20000
  limitHit = false
  depth = 0
  metering = true
  hookOn()
end

local function meterStop()
  hookOff()
  metering = false
  depth = 0
  local n = icount - topOverhead
  if n < 0 then n = 0 end
  return n
end

-- run fn(...) from harness code with the meter on; returns ok, results..., count
local function topFinish(ok, ...)
  local n = meterStop()
  return n, ok, ...
end
local function meteredCall(limit, fn, ...)
  meterStart(limit)
  return topFinish(xpcall(fn, errHandler, ...))
end

-- measure the wrapper costs once, so they can be subtracted
do
  local function noop() end
  local wrapped = api(function() end)
  -- top-level glue (meterStart .. meterStop) around an empty function (1 instruction)
  local empty = meteredCall(1e9, function() end)
  topOverhead = empty - 1
  if topOverhead < 0 then topOverhead = 0 end
  -- a Lua call of an empty function versus a call through the api() wrapper;
  -- on the radio the wrapped function is C code: only the CALL counts
  local base = meteredCall(1e9, function() noop() end)
  local withApi = meteredCall(1e9, function() wrapped() end)
  apiOverhead = withApi - base + 1
  if apiOverhead < 0 then apiOverhead = 0 end
  -- callWidget from mock context: everything except the function body is glue
  icount, ilimit, limitHit = 0, 1e9, false
  metering, depth = true, 1
  callWidget(noop)
  local cb = icount
  metering, depth = false, 0
  cbOverhead = cb - 1
  if cbOverhead < 0 then cbOverhead = 0 end
  M.calibration = { apiOverhead = apiOverhead, cbOverhead = cbOverhead, topOverhead = topOverhead,
                    base = base, withApi = withApi, cb = cb, empty = empty }
end

-- run a measured top-level function and return (count, ok, ...)
M.meteredCall = meteredCall

---------------------------------------------------------------------------
-- string metatable trap (EdgeTX has no string metatable)
---------------------------------------------------------------------------

local STRING_MT = getmetatable("")
local ORIG_STRING_INDEX = STRING_MT.__index
function M.installStringTrap(on)
  if on then
    STRING_MT.__index = function(s, k)
      error("string method syntax used (\"" .. string.sub(tostring(s), 1, 12) .. "\"):" .. tostring(k)
        .. "(...): EdgeTX has no string metatable; write string." .. tostring(k) .. "(s, ...)", 2)
    end
  else
    STRING_MT.__index = ORIG_STRING_INDEX
  end
end

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------

local function isInt(v) return type(v) == "number" and v == floor(v) end
M.isInt = isInt

local function shortSrc(src)
  src = tostring(src or "?")
  local s = string.match(src, "(WIDGETS/.*)$")
  if s then return s end
  s = string.match(src, "(tests/.*)$")
  if s then return s end
  return src
end

-- location of the first stack frame outside this file
local function whereCaller()
  for level = 3, 40 do
    local info = getinfo(level, "Sl")
    if not info then break end
    if info.source ~= MOCK_SRC and info.what ~= "C" then
      return shortSrc(info.short_src) .. ":" .. tostring(info.currentline)
    end
  end
  return "?"
end
M.whereCaller = whereCaller

local function colorName(c)
  if type(c) ~= "number" then return tostring(c) end
  if c % 65536 >= 0x8000 then
    return sformat("RGB565(0x%04X)", floor(c / 65536) % 65536)
  end
  local idx = floor(c / 65536) % 65536
  return INDEX_NAME[idx] or sformat("0x%X", c)
end
M.colorName = colorName

local function colorHex(c)
  if type(c) ~= "number" then return "#ff00ff" end
  c = floor(c) % 4294967296
  local v = floor(c / 65536)
  if c % 65536 >= 0x8000 then
    local r = floor(v / 2048) % 32
    local g = floor(v / 32) % 64
    local b = v % 32
    return sformat("#%02x%02x%02x", r * 8 + floor(r / 4), g * 4 + floor(g / 16), b * 8 + floor(b / 4))
  end
  local rgb = INDEX_RGB[v]
  if not rgb then return "#ff00ff" end
  return sformat("#%06x", rgb)
end
M.colorHex = colorHex

local function rgbFlags(r, g, b)
  local v = ((r & 0xF8) << 8) + ((g & 0xFC) << 3) + ((b & 0xF8) >> 3)
  return v * 65536 + 0x8000
end

local function xmlEsc(s)
  s = tostring(s)
  s = string.gsub(s, "&", "&amp;")
  s = string.gsub(s, "<", "&lt;")
  s = string.gsub(s, ">", "&gt;")
  s = string.gsub(s, "\"", "&quot;")
  -- ELRS arrow bytes are not valid UTF-8
  s = string.gsub(s, "\192", "^")
  s = string.gsub(s, "\193", "v")
  return s
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = string.byte(data, i, i + 2)
    local n = (a << 16) + ((b or 0) << 8) + (c or 0)
    local c1 = (n >> 18) & 63
    local c2 = (n >> 12) & 63
    local c3 = (n >> 6) & 63
    local c4 = n & 63
    out[#out + 1] = string.sub(B64, c1 + 1, c1 + 1) .. string.sub(B64, c2 + 1, c2 + 1)
      .. (b and string.sub(B64, c3 + 1, c3 + 1) or "=") .. (c and string.sub(B64, c4 + 1, c4 + 1) or "=")
  end
  return tconcat(out)
end

local function pngSize(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local head = f:read(24)
  f:close()
  if not head or #head < 24 or string.sub(head, 2, 4) ~= "PNG" then return nil end
  local function be32(i)
    local a, b, c, d = string.byte(head, i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return be32(17), be32(21)
end
M.pngSize = pngSize

-- minimal JSON encoder (for dumps)
local function jsonEnc(v, ind)
  ind = ind or ""
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return tostring(v) end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if isInt(v) then return sformat("%d", v) end
    return sformat("%.4f", v)
  end
  if t == "string" then
    local s = string.gsub(v, "[%c\"\\\128-\255]", function(ch)
      local b = string.byte(ch)
      if ch == "\"" then return "\\\"" end
      if ch == "\\" then return "\\\\" end
      if ch == "\n" then return "\\n" end
      return sformat("\\u%04x", b)
    end)
    return "\"" .. s .. "\""
  end
  if t == "table" then
    local n = #v
    local isArr = n > 0 or next(v) == nil
    if isArr then
      for k in pairs(v) do
        if type(k) ~= "number" then isArr = false break end
      end
    end
    local parts = {}
    local ni = ind .. "  "
    if isArr then
      for i = 1, n do parts[#parts + 1] = ni .. jsonEnc(v[i], ni) end
      if #parts == 0 then return "[]" end
      return "[\n" .. tconcat(parts, ",\n") .. "\n" .. ind .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local val = v[k]
      if val == nil then val = v[tonumber(k)] end
      parts[#parts + 1] = ni .. jsonEnc(k) .. ": " .. jsonEnc(val, ni)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. tconcat(parts, ",\n") .. "\n" .. ind .. "}"
  end
  return jsonEnc(tostring(v))
end
M.jsonEnc = jsonEnc

---------------------------------------------------------------------------
-- LVGL object specifications
---------------------------------------------------------------------------

-- validator kinds:
--  int      number (static only)          numfn   number or function (polled)
--  fnonly   must be a function            bool    boolean or number (static)
--  boolfn   boolean/number or function    strfn   string/number or function
--  str      string/number (static)        cb      callback function
--  strtab   table of strings              pts     table of points or function
--  numnp    number, or function that is never polled (warning)
--  strnp    string, or function that is never polled (warning)
--  btntab   { press = fn, active = fn }   children table
local BASE_KEYS = { x = "int", y = "int", w = "int", h = "int", color = "numfn", opacity = "numfn",
                    visible = "fnonly", size = "fnonly", pos = "fnonly" }
local WINDOW_KEYS = { flexFlow = "int", flexPad = "int", active = "fnonly" }
local BOX_KEYS = { align = "numnp", scrollBar = "bool", scrollDir = "int", scrollTo = "fnonly", scrolled = "cb" }
local BANNED_KEYS = {
  floating = "'floating' exists only from v2.12.0 (rc1 ignores it, DESIGN forbids it)",
  borderPad = "'borderPad' exists only from v2.12.0 (rc1 ignores it, DESIGN forbids it)",
  edited = "'edited' (numberEdit) exists only from v2.12.0 (DESIGN forbids it)",
}

local function merge(...)
  local r = {}
  for i = 1, select("#", ...) do
    for k, v in pairs((select(i, ...))) do r[k] = v end
  end
  return r
end

local KINDS = {
  label = { meta = "simple", window = false, keys = { text = "strfn", font = "numfn", align = "numfn" },
            poll = { "text", "font", "align" } },
  hline = { meta = "simple", window = false, keys = { rounded = "bool", dashGap = "int", dashWidth = "int" }, poll = {} },
  vline = { meta = "simple", window = false, keys = { rounded = "bool", dashGap = "int", dashWidth = "int" }, poll = {} },
  line = { meta = "simple", window = false, keys = { pts = "pts", thickness = "int", rounded = "bool" }, poll = { "pts" } },
  triangle = { meta = "simple", window = false, keys = { pts = "pts" }, poll = { "pts" } },
  image = { meta = "simple", window = true, keys = { file = "strfn", fill = "bool" }, poll = { "active", "file" } },
  qrcode = { meta = "simple", window = true, keys = { data = "str", bgColor = "int" }, poll = { "active" } },
  box = { meta = "full", window = true, keys = BOX_KEYS, poll = { "active", "scrollTo" }, container = true },
  rectangle = { meta = "full", window = true, container = true,
                keys = merge(BOX_KEYS, { thickness = "int", filled = "boolfn", rounded = "int" }),
                poll = { "active", "scrollTo", "filled" } },
  circle = { meta = "full", window = true, container = true,
             keys = merge(BOX_KEYS, { thickness = "int", filled = "boolfn", radius = "numfn" }),
             poll = { "active", "scrollTo", "filled", "radius" } },
  arc = { meta = "full", window = true, container = true,
          keys = merge(BOX_KEYS, { thickness = "int", filled = "boolfn", radius = "numfn", rounded = "bool",
                                   startAngle = "numfn", endAngle = "numfn", bgStartAngle = "numfn",
                                   bgEndAngle = "numfn", bgColor = "numnp", bgOpacity = "numnp" }),
          poll = { "active", "scrollTo", "filled", "radius", "startAngle", "endAngle", "bgStartAngle", "bgEndAngle" } },
  button = { meta = "simple", window = true, control = true,
             keys = { text = "strfn", font = "numnp", press = "cb", longpress = "cb", checked = "bool",
                      textColor = "numfn", cornerRadius = "int" },
             poll = { "active", "text", "textColor" } },
  momentaryButton = { meta = "simple", window = true, control = true,
                      keys = { text = "strfn", font = "numnp", press = "cb", release = "cb", textColor = "numfn",
                               cornerRadius = "int" },
                      poll = { "active", "text", "textColor" } },
  toggle = { meta = "simple", window = true, control = true, keys = { get = "cb", set = "cb" }, poll = { "active" }, getPoll = "bool" },
  textEdit = { meta = "simple", window = true, control = true, keys = { value = "str", length = "int", set = "cb" }, poll = { "active" } },
  numberEdit = { meta = "simple", window = true, control = true,
                 keys = { get = "cb", set = "cb", min = "int", max = "int", display = "cb" }, poll = { "active" }, getOnce = true },
  choice = { meta = "simple", window = true, control = true,
             keys = { get = "cb", set = "cb", values = "strtab", title = "strnp", filter = "cb", popupWidth = "int" },
             poll = { "active" }, getPoll = "index" },
  slider = { meta = "simple", window = true, control = true, keys = { get = "cb", set = "cb", min = "int", max = "int" },
             poll = { "active" }, getPoll = "int" },
  verticalSlider = { meta = "simple", window = true, control = true, keys = { get = "cb", set = "cb", min = "int", max = "int" },
                     poll = { "active" }, getPoll = "int" },
  font = { meta = "simple", window = true, control = true, keys = { get = "cb", set = "cb" }, poll = { "active" }, getPoll = "int" },
  align = { meta = "simple", window = true, control = true, keys = { get = "cb", set = "cb" }, poll = { "active" }, getPoll = "int" },
  color = { meta = "simple", window = true, control = true, keys = { get = "cb", set = "cb" }, poll = { "active" }, getOnce = true },
  timer = { meta = "simple", window = true, control = true, keys = { get = "cb", set = "cb" }, poll = { "active" }, getPoll = "int" },
  switch = { meta = "simple", window = true, control = true, keys = { get = "cb", set = "cb", filter = "int" }, poll = { "active" }, getPoll = "int" },
  source = { meta = "simple", window = true, control = true, keys = { get = "cb", set = "cb", filter = "int" }, poll = { "active" }, getPoll = "int" },
  file = { meta = "simple", window = true, control = true,
           keys = { get = "cb", set = "cb", title = "str", folder = "str", extension = "str", maxLen = "int", hideExtension = "bool" },
           poll = { "active" } },
  setting = { meta = "full", window = true, control = true, container = true, keys = { title = "str" }, poll = { "active" } },
  page = { meta = "full", window = true, control = true, container = true,
           keys = merge(BOX_KEYS, { title = "strfn", subtitle = "strfn", icon = "str", back = "cb", menu = "cb",
                                    backButton = "bool", prevButton = "btntab", nextButton = "btntab" }),
           poll = { "active", "title", "subtitle", "scrollTo" } },
  dialog = { meta = "full", window = true, control = true, container = true, keys = { title = "str", close = "cb" }, poll = { "active" } },
}
for _, spec in pairs(KINDS) do
  local all = merge(BASE_KEYS, spec.window and WINDOW_KEYS or {}, spec.keys)
  spec.allKeys = all
end
M.KINDS = KINDS

local POPUP_KEYS = {
  confirm = merge(BASE_KEYS, WINDOW_KEYS, { title = "str", message = "str", confirm = "cb", cancel = "cb" }),
  message = merge(BASE_KEYS, WINDOW_KEYS, { title = "str", message = "str", details = "str" }),
  menu = merge(BASE_KEYS, WINDOW_KEYS, { title = "str", values = "strtab", get = "cb", set = "cb" }),
}

local CONSTRUCTORS = { "label", "rectangle", "hline", "vline", "line", "triangle", "circle", "arc", "image",
  "qrcode", "box", "button", "momentaryButton", "toggle", "textEdit", "numberEdit", "choice", "slider",
  "verticalSlider", "font", "align", "color", "timer", "switch", "source", "file", "setting" }
local FULL_ONLY_CTORS = { page = true, dialog = true }

---------------------------------------------------------------------------
-- Radio
---------------------------------------------------------------------------

local Radio = {}
Radio.__index = Radio
M.Radio = Radio

local WidgetError = {}
WidgetError.__index = WidgetError
WidgetError.__tostring = function(e) return e.msg end
local function werr(msg)
  return setmetatable({ msg = msg, tb = dtraceback("", 3) }, WidgetError)
end

-- options:
--   mode        "rc1" (default) | "v212x"   firmware behaviour to emulate
--   strict      true (default)              raise errors on contract violations
--   sdRoot      SD card copy (default <root>/radio sd card)
--   startMs     clock at start (default 5000)
--   stickMode   1..4 (default 2)
--   noLvgl      true -> lvgl global is nil (firmware < 2.11)
--   limit       instruction limit per firmware call (default 20000)
--   module      FakeElrs instance (or nil = CRSF protocol active but no module answers)
--   crsf        false -> no CRSF module configured (push returns nil)
--   model       model spec for the input/mix emulation (default M.userModel(1), the user's
--               model "75": throttle input 75 / -25); false -> no model input API at all
--   modelName   overrides the model name of the spec
function M.new(opts)
  opts = opts or {}
  local R = setmetatable({}, Radio)
  R.opts = opts
  R.mode = opts.mode or "rc1"
  R.strict = (opts.strict ~= false)
  R.sdRoot = opts.sdRoot or M.SD_ROOT
  R.clock = opts.startMs or 5000
  R.cycleMs = 50
  R.cycleNo = 0
  R.limit = opts.limit or 20000
  R.stickMode = opts.stickMode or 2
  -- screen size (480x320 TX15 by default; 480x272 for TX16S class radios)
  R.lcdW = opts.lcdW or C.LCD_W
  R.lcdH = opts.lcdH or C.LCD_H
  R.instances = {}
  R.current = nil
  R.phase = "load"
  R.warnings = {}
  R.warnCount = {}
  R.errors = {}
  R.globalWrites = {}
  R.printed = {}
  R.loads = {}
  R.lcdCalls = 0
  R.objSeq = 0
  R.handles = setmetatable({}, { __mode = "k" })
  R.sounds = {}
  R.modelName = opts.modelName or "75"
  R.version = { "2.12.0", "tx15", 2, 12, 0, "EdgeTX" }
  R.dateBase = { year = 2026, mon = 10, day = 2, hour = 14, min = 37, sec = 0 }
  R.flightMode = { 0, "" }
  R.general = { battWarn = 6.5, battMin = 6.4, battMax = 8.4, imperial = 0, language = "EN", voice = "en", gtimer = 0 }
  R.streaming = true
  R.callSeq = 0
  R:_initSources()
  R:_initCrsf(opts)
  R:_initModel(opts)
  R.env = R:_makeEnv()
  M.installStringTrap(R.strict)
  return R
end

function Radio:warn(msg, key)
  key = key or msg
  local n = (self.warnCount[key] or 0) + 1
  self.warnCount[key] = n
  if n == 1 then
    self.warnings[#self.warnings + 1] = { msg = msg, t = self.clock, phase = self.phase }
  end
end

function Radio:now() return self.clock end

-- raise a strict-mode error (contract violation) or record a warning
function Radio:violation(msg)
  msg = msg .. " [at " .. whereCaller() .. "]"
  if self.strict then
    error(werr(msg), 0)
  else
    self:warn(msg)
  end
end

---------------------------------------------------------------------------
-- sources (getValue / getFieldInfo)
---------------------------------------------------------------------------

local TELEM_BASE = 500

function Radio:_initSources()
  local S = { byName = {}, byId = {}, sensors = {} }
  self.src = S
  local function add(name, id, value, desc)
    local e = { name = name, id = id, value = value or 0, desc = desc or name }
    S.byName[name] = e
    S.byId[id] = e
    return e
  end
  add("rud", 1, 0, "Rudder"); add("ele", 2, 0, "Elevator"); add("thr", 3, -1024, "Throttle"); add("ail", 4, 0, "Aileron")
  add("s1", 5, 0, "Pot 1"); add("s2", 6, 0, "Pot 2")
  add("trim-rud", 90, 0, "Rudder trim"); add("trim-ele", 91, 0, "Elevator trim")
  add("trim-thr", 92, 0, "Throttle trim"); add("trim-ail", 93, 0, "Aileron trim")
  local sw = { "sa", "sb", "sc", "sd", "se", "sf" }
  for i = 1, #sw do add(sw[i], 100 + i - 1, -1024, "Switch " .. string.upper(string.sub(sw[i], 2))) end
  local txv = add("tx-voltage", 200, 7.8, "Transmitter battery voltage [volts]")
  txv.float = true
  add("clock", 201, 0, "RTC clock [minutes from midnight]")
  for i = 1, 3 do add("timer" .. i, 210 + i - 1, 0, "Timer " .. i .. " value [seconds]") end
  for i = 1, 32 do add("ch" .. i, 300 + i - 1, 0, "Channel CH" .. i) end
  for i = 1, 8 do add("ls" .. i, 400 + i - 1, 0, "Logical switch L" .. i) end
  -- inputs and global variables (MIXSRC ids used by the model input emulation below;
  -- every id fits the 10-bit source field of an input line)
  for i = 1, 32 do add("input" .. i, 10 + i - 1, 0, "Input " .. i) end
  for i = 1, 9 do add("gvar" .. i, 50 + i - 1, 0, "Global variable " .. i) end
  self.timers = {
    { mode = 0, value = 0, start = 0, name = "" },
    { mode = 0, value = 0, start = 0, name = "" },
    { mode = 0, value = 0, start = 0, name = "" },
  }
end

-- sensors: list of { name =, value = number, prec = n, unit = n } or { name =, text = "..." }
function Radio:defineSensors(list)
  local S = self.src
  for _, e in ipairs(S.sensors) do
    S.byName[e.name] = nil
    S.byId[e.id] = nil
  end
  S.sensors = {}
  for i, d in ipairs(list) do
    local e = { name = d.name, id = TELEM_BASE + 3 * (i - 1), value = d.value or 0, text = d.text,
                prec = d.prec or 0, unit = d.unit or 0, telem = true, desc = "", old = false }
    S.sensors[#S.sensors + 1] = e
    S.byName[d.name] = e
    S.byId[e.id] = e
  end
end

function Radio:setSensor(name, value)
  local e = self.src.byName[name]
  if not e or not e.telem then error("no such sensor: " .. tostring(name), 2) end
  if type(value) == "string" then e.text = value else e.value = value end
  e.old = false                     -- a value received now
end

-- Link loss: EdgeTX keeps every telemetry value and marks it old (telemetry.cpp
-- setOld); getValue reads 0 while not streaming and the old value again after,
-- until a new value arrives (setSensor). getSourceValue tells old values.
function Radio:setStreaming(on)
  self.streaming = on and true or false
  if not on then
    for _, e in ipairs(self.src.sensors) do e.old = true end
  end
end

function Radio:setSource(name, value)
  local e = self.src.byName[name]
  if not e then error("no such source: " .. tostring(name), 2) end
  e.value = value
end

function Radio:setTimer(i, t)
  self.timers[i] = t
  self.src.byName["timer" .. i].value = t.value or 0
end

function Radio:_lookup(src)
  local S = self.src
  if type(src) == "number" then
    local id = floor(src)
    local e = S.byId[id]
    if e then return e, 0 end
    -- telemetry "-" / "+" variants
    if id >= TELEM_BASE then
      local base = TELEM_BASE + 3 * floor((id - TELEM_BASE) / 3)
      local b = S.byId[base]
      if b then return b, id - base end
    end
    return nil
  end
  if type(src) ~= "string" then return nil end
  local e = S.byName[src]
  if e then return e, 0 end
  local last = string.sub(src, -1)
  if last == "-" or last == "+" then
    local b = S.byName[string.sub(src, 1, -2)]
    if b and b.telem then return b, (last == "-") and 1 or 2 end
  end
  return nil
end

function Radio:_getValue(src)
  if src == nil then error("bad argument #1 to 'getValue' (string expected, got no value)", 0) end
  local e = self:_lookup(src)
  if not e then return 0 end
  if e.telem then
    if not self.streaming then return 0 end
    if e.text then return e.text end
    if e.prec and e.prec > 0 then return e.value + 0.0 end
    return math.tointeger(floor(e.value)) or 0
  end
  if e.name == "clock" then
    local dt = self:_dateTime()
    return dt.hour * 60 + dt.min
  end
  -- an input source (input1 .. input32): the input stage output at the current stick
  if self.mdl ~= nil and type(e.id) == "number" and e.id >= 10 and e.id < 42 then
    return self:_inputValue(e.id - 10)
  end
  if e.float then return e.value + 0.0 end
  return math.tointeger(floor(e.value)) or 0
end

-- getSourceValue (api_general.cpp luaGetSourceValue): value, not old, fresh. For telemetry
-- it does not look at the streaming state. Nothing for an unknown source.
function Radio:_getSourceValue(src)
  if src == nil then error("bad argument #1 to 'getSourceValue' (number or string expected)", 0) end
  local e = self:_lookup(src)
  if not e then return end
  if e.telem then
    local v
    if e.text then v = e.text
    elseif e.prec and e.prec > 0 then v = e.value + 0.0
    else v = math.tointeger(floor(e.value)) or 0 end
    return v, not e.old, not e.old
  end
  local saved = self.streaming
  self.streaming = true
  local v = self:_getValue(src)
  self.streaming = saved
  return v, true, true
end

function Radio:_getFieldInfo(src)
  local e, variant = self:_lookup(src)
  if not e then return nil end
  local id = e.id + (variant or 0)
  local name = e.name
  if variant == 1 then name = name .. "-" elseif variant == 2 then name = name .. "+" end
  local r = { id = id, name = name, desc = e.desc or "" }
  if e.telem then r.unit = e.unit or 0 end
  return r
end

function Radio:_dateTime()
  local b = self.dateBase
  local total = b.sec + b.min * 60 + b.hour * 3600 + floor(self.clock / 1000)
  local day = b.day + floor(total / 86400)
  total = total % 86400
  return { year = b.year, mon = b.mon, day = day, hour = floor(total / 3600), min = floor(total / 60) % 60,
           sec = total % 60 }
end

---------------------------------------------------------------------------
-- model inputs (expo lines), mixes and the input stage of the mixer
---------------------------------------------------------------------------
-- Emulated from the firmware source (v2.12.0-rc1; v2.12.0 has no change in these parts),
-- like tests/unit/thrcap_mock.lua, but one model per radio and with the mock source ids:
--   lua/api_model.cpp      getInputsCount, getInput, insertInput, deleteInput, getMixesCount,
--                          getMix (getFirstInput; "srcRaw == 0" ends the list for Lua)
--   gui/colorlcd/model/model_inputs.cpp   insertExpo (the default line), deleteExpo (clears the
--                          input name when the input has no line left), getExposCount (64 lines)
--   mixer.cpp              applyExpos: the first active line of an input wins; an input without
--                          an active line keeps its last value; expo / DIFF curve, weight, offset
--                          with the firmware integer math
--   datastructs_private.h  ExpoData bit fields, SourceNumVal (Lua >= 1024 / <= -1024 = a source)
--   lua/api_general.cpp    getFieldInfo("inputN"/"gvarN"), defaultChannel (AETR order)
--   luaconf.h              LUA_FLOORN2I 1: luaL_checkinteger floors a float (no error)
-- The mixer task has a higher priority than Lua and can run between any two Lua instructions,
-- but not inside insertExpo/deleteExpo (they stop it). So the mock runs one mixer cycle after
-- insertExpo (the new line still has its default content), after every field store of the
-- insertInput copy loop (it runs with the mixer on, in lua_next order, which is not specified:
-- the keys are shuffled) and after deleteExpo. Each cycle evaluates every input for five
-- throttle positions (-100, -50, 0, +50, +100 %); the other sticks have fixed values.
-- Glitch check: at the end of each 50 ms radio cycle every mixer cycle seen in it must show, for
-- each input, the output from before the radio cycle (old) or the one after it (new). Anything
-- else is recorded in R.mdl.glitches. Contract checks (recorded, the scenarios fail on them):
-- model writes only from refresh() (R.mdl.badWrites), integer arguments only (R.mdl.floatArgs),
-- at most one insertInput per firmware call (R.mdl.multi).

local MAX_EXPOS, MAX_MIXERS, MAX_INPUTS, MAX_GVARS = 64, 64, 32, 9
local LEN_EXPOMIX_NAME, LEN_INPUT_NAME = 6, 4
local SRC_STICK0 = 1                  -- rud 1, ele 2, thr 3, ail 4 (stick index 0..3 = R E T A)
local SRC_THR = 3
local SRC_INPUT0 = 10                 -- input1 .. input32 = 10 .. 41 (see _initSources)
local SRC_GVAR0 = 50                  -- gvar1 .. gvar9 = 50 .. 58
local SRC_SA, SRC_SB, SRC_SC, SRC_SD, SRC_SE, SRC_SF = 100, 101, 102, 103, 104, 105
local SRC_S1, SRC_S2 = 5, 6
local PROBE = { -1024, -512, 0, 512, 1024 }        -- throttle stick positions of each mixer cycle
local PROBE_OTHER = { [1] = 100, [2] = -300, [4] = 700, [5] = 200, [6] = -200 }
local CH_ORDER_AETR = { [0] = 3, [1] = 1, [2] = 2, [3] = 0 }   -- channel -> stick index
local LINE_KEYS = { "name", "source", "scale", "weight", "offset", "switch", "curveType", "curveValue",
                    "trimSource", "side", "flightModes" }
M.SRC = { rud = 1, ele = 2, thr = SRC_THR, ail = 4, s1 = SRC_S1, s2 = SRC_S2, input1 = SRC_INPUT0,
          gvar1 = SRC_GVAR0, sa = SRC_SA, sb = SRC_SB, sc = SRC_SC, sd = SRC_SD, se = SRC_SE, sf = SRC_SF }
M.PROBE = PROBE
M.LINE_KEYS = LINE_KEYS

-- C integer division (truncates toward zero) and divRoundClosest
local function cdiv(a, b)
  local q = a // b
  if q < 0 and q * b ~= a then q = q + 1 end
  return q
end
local function divRoundClosest(n, d)
  if d == 0 then return 0 end
  if (n < 0) ~= (d < 0) then return cdiv(n - cdiv(d, 2), d) end
  return cdiv(n + cdiv(d, 2), d)
end
local function ubits(v, n) return v & ((1 << n) - 1) end
local function sbits(v, n)
  local m = 1 << n
  v = v & (m - 1)
  if v >= (m >> 1) then v = v - m end
  return v
end
local function clampi(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end
-- luaIntToSourceNumval / sourceNumValToLuaInt (11-bit field: 10-bit value + isSource bit)
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

local function emptyExpo()
  return { mode = 0, scale = 0, trimSource = 0, srcRaw = 0, weight = 0, offset = 0, swtch = 0,
           ctype = 0, cvalue = 0, chn = 0, flightModes = 0, name = "" }
end
local function emptyMix()
  return { destCh = 0, srcRaw = 0, weight = 0, offset = 0, swtch = 0, ctype = 0, cvalue = 0, mltpx = 0,
           flightModes = 0, carryTrim = false, mixWarn = 0, delayPrec = 0, delayUp = 0, delayDown = 0,
           speedPrec = 0, speedUp = 0, speedDown = 0, name = "" }
end

local function newModelData()
  local md = {
    expo = {}, mix = {}, inputNames = {}, gvars = {}, switchOn = {}, fm = 0,
    file = "model1.yml", chOrder = CH_ORDER_AETR, seed = 1,
    inj = {},              -- failure injection: insertNoop, insertError (fields stored before
                           -- the error), insertCorrupt (field name), deleteNoop / deleteError (counts)
    anas = {},             -- input values per probe position (kept between cycles, like anas[])
    prev = nil,            -- settled output per input (string per input) before this radio cycle
    states = {},           -- mixer cycles seen in this radio cycle
    dirty = false,
    writes = {},           -- every insertInput/deleteInput call { t, cycle, phase, call, chn, idx, inst }
    glitches = {}, nGlitches = 0,
    badWrites = {}, floatArgs = {}, multi = {},
    callSeq = -1, callInserts = 0,
  }
  for i = 0, MAX_EXPOS - 1 do md.expo[i] = emptyExpo() end
  for i = 0, MAX_MIXERS - 1 do md.mix[i] = emptyMix() end
  for i = 0, MAX_INPUTS - 1 do md.inputNames[i] = "" end
  for i = 0, MAX_GVARS - 1 do md.gvars[i] = 0 end
  for p = 1, #PROBE do md.anas[p] = {} end
  return md
end

local function mdSwitch(md, sw)
  if sw == 0 then return true end
  local on = md.switchOn[sw < 0 and -sw or sw] == true
  if sw < 0 then return not on end
  return on
end

local function mdSrc(md, src, thr)
  if src < 0 then return -mdSrc(md, -src, thr) end
  if src == SRC_THR then return thr end
  if src >= SRC_GVAR0 and src < SRC_GVAR0 + MAX_GVARS then return md.gvars[src - SRC_GVAR0] or 0 end
  return PROBE_OTHER[src] or 0
end

-- getSourceNumFieldValue: result in 1/10 percent
local function mdNumField(md, raw, lo, hi, thr)
  local value = sbits(raw & 0x3FF, 10)
  local result
  if (raw >> 10) & 1 == 1 then
    local a = value < 0 and -value or value
    if a >= SRC_GVAR0 and a < SRC_GVAR0 + MAX_GVARS then
      result = mdSrc(md, value, thr) * 10                        -- GVAR, precision 0
    else
      result = divRoundClosest(mdSrc(md, value, thr) * 1000, 1024)
    end
  else
    result = value * 10
  end
  return clampi(result, lo * 10, hi * 10)
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
local function expoFn(x, k)
  if k == 0 then return x end
  local neg = x < 0
  if neg then x = -x end
  if x > 1024 then x = 1024 end
  local y
  if k < 0 then y = 1024 - expou(1024 - x, -k) else y = expou(x, k) end
  if neg then return -y end
  return y
end

local function mdCurve(md, x, ctype, craw, thr)
  if ctype == 0 then                                            -- DIFF
    local cp = mdNumField(md, craw, -100, 100, thr)
    if cp > 0 and x < 0 then return cdiv(x * (1000 - cp), 1000) end
    if cp < 0 and x > 0 then return cdiv(x * (1000 + cp), 1000) end
    return x
  elseif ctype == 1 then                                        -- EXPO
    return expoFn(x, cdiv(mdNumField(md, craw, -100, 100, thr), 10))
  end
  return x          -- FUNC and CUSTOM curves are not emulated (the widget refuses them)
end

-- One line at throttle position thr: nil = not active, false = active but the side does not
-- match (the input value is 0 and a later line may still win), else the value (-1024..1024).
local function mdLine(md, ed, thr)
  if (ed.flightModes >> md.fm) & 1 == 1 then return nil end
  if not mdSwitch(md, ed.swtch) then return nil end
  local v = clampi(mdSrc(md, ed.srcRaw, thr), -1024, 1024)
  if not ((v < 0 and ed.mode & 1 ~= 0) or (v >= 0 and ed.mode & 2 ~= 0)) then return false end
  if ed.cvalue ~= 0 then v = mdCurve(md, v, ed.ctype, ed.cvalue, thr) end
  local w = mdNumField(md, ed.weight, -100, 100, thr)
  v = divRoundClosest(v * w, 1000)
  local o = mdNumField(md, ed.offset, -100, 100, thr)
  if o ~= 0 then v = v + divRoundClosest(divRoundClosest(o * 1024, 100), 10) end
  return v
end

local function mdApplyExpos(md, anas, thr)
  local cur = -1
  for i = 0, MAX_EXPOS - 1 do
    local ed = md.expo[i]
    if ed.mode == 0 then break end                              -- end of list (EXPO_VALID)
    if ed.chn ~= cur then
      local v = mdLine(md, ed, thr)
      if v == false then
        anas[ed.chn] = 0
      elseif v ~= nil then
        cur = ed.chn
        anas[cur] = v
      end
    end
  end
end

-- getValue of an input source: the input stage (mixer.cpp applyExpos) at the current
-- throttle stick; other stick sources use their probe values (PROBE_OTHER). An input
-- without an active line gives 0 here (the firmware keeps its last value).
function Radio:_inputValue(chn)
  local md = self.mdl
  if md == nil then return 0 end
  local t = self.src and self.src.byName and self.src.byName["thr"]
  local thr = 0
  if t ~= nil then thr = math.tointeger(floor(t.value)) or 0 end
  local anas = {}
  mdApplyExpos(md, anas, thr)
  return anas[chn] or 0
end

-- one mixer cycle: output of every input at the probe positions, one string per input
local function mdCycle(md)
  for p = 1, #PROBE do mdApplyExpos(md, md.anas[p], PROBE[p]) end
  local vec = {}
  local parts = {}
  for chn = 0, MAX_INPUTS - 1 do
    for p = 1, #PROBE do parts[p] = tostring(md.anas[p][chn]) end
    vec[chn] = tconcat(parts, ",")
  end
  return vec
end

local function mdFirstInput(md, chn)
  for i = 0, MAX_EXPOS - 1 do
    local e = md.expo[i]
    if e.srcRaw == 0 or e.chn >= chn then return i end
  end
  return 0
end
local function mdCountFrom(md, chn, first)
  local n = 0
  for i = first, MAX_EXPOS - 1 do
    local e = md.expo[i]
    if e.srcRaw == 0 or e.chn ~= chn then break end
    n = n + 1
  end
  return n
end
local function mdExposCount(md)
  local n = 0
  for i = MAX_EXPOS - 1, 0, -1 do
    if md.expo[i].mode ~= 0 then n = n + 1 end
  end
  return n
end
local function mdInputAvailable(md, input)
  for i = 0, MAX_EXPOS - 1 do
    local e = md.expo[i]
    if e.mode == 0 then break end
    if e.chn == input then return true end
  end
  return false
end

-- model_inputs.cpp insertExpo / deleteExpo (under mixerTaskStop: no mixer cycle inside)
local function mdInsertExpo(md, idx, input)
  for j = MAX_EXPOS - 1, idx + 1, -1 do md.expo[j] = md.expo[j - 1] end
  local ed = emptyExpo()
  if input >= 4 then
    ed.srcRaw = sbits(SRC_STICK0 + input, 10)
  else
    ed.srcRaw = SRC_STICK0 + md.chOrder[input]
  end
  ed.ctype = 1
  ed.mode = 3
  ed.chn = input
  ed.weight = 100
  md.expo[idx] = ed
end
local function mdDeleteExpo(md, idx)
  local input = md.expo[idx].chn
  for j = idx, MAX_EXPOS - 2 do md.expo[j] = md.expo[j + 1] end
  md.expo[MAX_EXPOS - 1] = emptyExpo()
  if not mdInputAvailable(md, input) then md.inputNames[input] = "" end
end

local function unsignedArg(v)
  if v < 0 then return v + 4294967296 end                      -- C "unsigned int" of a negative value
  return v
end

-- getInput table of one stored line
local function mdLineTable(md, ed, chn)
  return {
    name = ed.name, inputName = md.inputNames[chn], source = ed.srcRaw, scale = ed.scale,
    weight = fromSNV(ed.weight), offset = fromSNV(ed.offset), switch = ed.swtch,
    curveType = ed.ctype, curveValue = fromSNV(ed.cvalue), trimSource = -ed.trimSource,
    side = ed.mode, flightModes = ed.flightModes,
  }
end

-- luaL_checkinteger / luaL_checkunsigned: floors a float (LUA_FLOORN2I), which the widget
-- contract forbids: every float argument is recorded
function Radio:_mdInt(v, what)
  local t = math.type(v)
  if t == "integer" then return v end
  if t == "float" then
    if v ~= v or v == math.huge or v == -math.huge then
      error("bad argument to '" .. what .. "' (number has no integer representation)", 0)
    end
    local md = self.mdl
    md.floatArgs[#md.floatArgs + 1] = { what = what, v = v, where = whereCaller(), t = self.clock }
    return floor(v)
  end
  if type(v) == "string" and tonumber(v) ~= nil then return self:_mdInt(tonumber(v), what) end
  error("bad argument to '" .. what .. "' (number expected, got " .. type(v) .. ")", 0)
end

-- one key of the insertInput copy loop (api_model.cpp luaModelInsertInput)
function Radio:_mdSetField(ed, chn, key, v)
  local md = self.mdl
  local function str()
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    error("bad argument to 'insertInput' (string expected for " .. key .. ", got " .. type(v) .. ")", 0)
  end
  if key == "name" then ed.name = string.sub(str(), 1, LEN_EXPOMIX_NAME)
  elseif key == "inputName" then md.inputNames[chn] = string.sub(str(), 1, LEN_INPUT_NAME)
  elseif key == "source" then ed.srcRaw = sbits(self:_mdInt(v, "insertInput"), 10)
  elseif key == "scale" then ed.scale = ubits(self:_mdInt(v, "insertInput"), 14)
  elseif key == "side" then ed.mode = ubits(self:_mdInt(v, "insertInput"), 2)
  elseif key == "weight" then ed.weight = toSNV(self:_mdInt(v, "insertInput"))
  elseif key == "offset" then ed.offset = toSNV(self:_mdInt(v, "insertInput"))
  elseif key == "switch" then ed.swtch = sbits(self:_mdInt(v, "insertInput"), 10)
  elseif key == "curveType" then ed.ctype = ubits(self:_mdInt(v, "insertInput"), 5)
  elseif key == "curveValue" then ed.cvalue = toSNV(self:_mdInt(v, "insertInput"))
  elseif key == "trimSource" then ed.trimSource = sbits(-self:_mdInt(v, "insertInput"), 6)
  elseif key == "flightModes" then ed.flightModes = ubits(self:_mdInt(v, "insertInput"), 9)
  end
end

-- a mixer cycle during a model write
function Radio:_mdRecord(tag)
  local md = self.mdl
  local vec = mdCycle(md)
  local last = md.states[#md.states]
  if last then
    local same = true
    for chn = 0, MAX_INPUTS - 1 do
      if vec[chn] ~= last.vec[chn] then same = false break end
    end
    if same then return end
  end
  md.states[#md.states + 1] = { tag = tag, vec = vec, t = self.clock, where = whereCaller() }
end

function Radio:_mdNoteWrite(call, chn, idx)
  local md = self.mdl
  md.dirty = true
  local inst = self.current
  md.writes[#md.writes + 1] = { t = self.clock, cycle = self.cycleNo, phase = self.phase, call = call,
                                chn = chn, idx = idx, inst = inst and inst.id or 0 }
  if self.phase ~= "refresh" then
    md.badWrites[#md.badWrites + 1] = { t = self.clock, where = whereCaller(),
      msg = sformat("model.%s(%d, %d) called from %s() (model writes only from refresh(): background() also "
        .. "runs while the Inputs editor is open, and a callback must only record a request)", call, chn, idx,
        tostring(self.phase)) }
  end
  if call == "insertInput" then
    if md.callSeq == self.callSeq then
      md.callInserts = md.callInserts + 1
    else
      md.callSeq = self.callSeq
      md.callInserts = 1
    end
    if md.callInserts > 1 then
      md.multi[#md.multi + 1] = { t = self.clock, where = whereCaller(),
        msg = sformat("%d insertInput calls in one %s() call (one swap per refresh)", md.callInserts,
          tostring(self.phase)) }
    end
  end
end

-- end of a 50 ms radio cycle: check every mixer cycle seen since the last one
function Radio:_mdSettle()
  local md = self.mdl
  if md == nil or not md.dirty then return end
  md.dirty = false
  local new = mdCycle(md)
  local old = md.prev or new
  for _, s in ipairs(md.states) do
    for chn = 0, MAX_INPUTS - 1 do
      local v = s.vec[chn]
      if v ~= old[chn] and v ~= new[chn] then
        md.nGlitches = md.nGlitches + 1
        if #md.glitches < 20 then
          md.glitches[#md.glitches + 1] = { t = s.t, tag = s.tag, chn = chn, got = v, old = old[chn],
            new = new[chn], where = s.where,
            msg = sformat("mixer glitch at %.2f s on input %d (%s, %s): output at throttle -100/-50/0/50/100 %% "
              .. "was {%s}, before {%s}, after {%s}", s.t / 1000, chn + 1, s.tag, s.where, v, old[chn], new[chn]) }
        end
        break
      end
    end
  end
  md.prev = new
  md.states = {}
end

-- Lua API -----------------------------------------------------------------

function Radio:_mdGetInputsCount(chn)
  local md = self.mdl
  chn = unsignedArg(self:_mdInt(chn, "getInputsCount"))
  return mdCountFrom(md, chn, mdFirstInput(md, chn))
end

function Radio:_mdGetInput(chn, idx)
  local md = self.mdl
  chn = unsignedArg(self:_mdInt(chn, "getInput"))
  idx = unsignedArg(self:_mdInt(idx, "getInput"))
  local first = mdFirstInput(md, chn)
  if idx < mdCountFrom(md, chn, first) then return mdLineTable(md, md.expo[first + idx], chn) end
  return nil
end

function Radio:_mdInsertInput(chn, idx, tbl)
  local md = self.mdl
  chn = unsignedArg(self:_mdInt(chn, "insertInput"))
  idx = unsignedArg(self:_mdInt(idx, "insertInput"))
  self:_mdNoteWrite("insertInput", chn, idx)
  local first = mdFirstInput(md, chn)
  local count = mdCountFrom(md, chn, first)
  if md.inj.insertNoop then return end
  if chn < MAX_INPUTS and mdExposCount(md) < MAX_EXPOS and idx <= count then
    idx = first + idx
    mdInsertExpo(md, idx, chn)
    self:_mdRecord("insertInput: new line with the default content")
    local ed = md.expo[idx]
    if type(tbl) ~= "table" then
      error("bad argument #3 to 'insertInput' (table expected, got " .. type(tbl) .. ")", 0)
    end
    local keys = {}
    for k in pairs(tbl) do
      if type(k) ~= "string" then error("bad argument to 'insertInput' (string key expected)", 0) end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for i = #keys, 2, -1 do                                      -- lua_next order is not specified
      md.seed = (md.seed * 1103515245 + 12345) % 2147483648
      local j = md.seed % i + 1
      keys[i], keys[j] = keys[j], keys[i]
    end
    for n = 1, #keys do
      if md.inj.insertError ~= nil and n > md.inj.insertError then
        error("injected error in the insertInput field loop", 0)
      end
      self:_mdSetField(ed, chn, keys[n], tbl[keys[n]])
      self:_mdRecord("insertInput: field " .. keys[n])
    end
    if md.inj.insertError ~= nil and #keys <= md.inj.insertError then
      error("injected error after the insertInput field loop", 0)
    end
    if md.inj.insertCorrupt ~= nil then
      ed[md.inj.insertCorrupt] = ed[md.inj.insertCorrupt] + 1
      self:_mdRecord("insertInput: corrupted field " .. md.inj.insertCorrupt)
    end
  end
end

function Radio:_mdDeleteInput(chn, idx)
  local md = self.mdl
  chn = unsignedArg(self:_mdInt(chn, "deleteInput"))
  idx = unsignedArg(self:_mdInt(idx, "deleteInput"))
  self:_mdNoteWrite("deleteInput", chn, idx)
  local inj = md.inj
  if inj.deleteError ~= nil and inj.deleteError > 0 then
    inj.deleteError = inj.deleteError - 1
    error("injected error in deleteInput", 0)
  end
  if inj.deleteNoop ~= nil and inj.deleteNoop > 0 then
    inj.deleteNoop = inj.deleteNoop - 1
    return
  end
  local first = mdFirstInput(md, chn)
  if idx < mdCountFrom(md, chn, first) then
    mdDeleteExpo(md, first + idx)
    self:_mdRecord("deleteInput")
  end
end

local function mdFirstMix(md, ch)
  for i = 0, MAX_MIXERS - 1 do
    local m = md.mix[i]
    if m.srcRaw == 0 or m.destCh >= ch then return i end
  end
  return 0
end
local function mdMixCount(md, ch, first)
  local n = 0
  for i = first, MAX_MIXERS - 1 do
    local m = md.mix[i]
    if m.srcRaw == 0 or m.destCh ~= ch then break end
    n = n + 1
  end
  return n
end

function Radio:_mdGetMixesCount(ch)
  local md = self.mdl
  ch = unsignedArg(self:_mdInt(ch, "getMixesCount"))
  return mdMixCount(md, ch, mdFirstMix(md, ch))
end

function Radio:_mdGetMix(ch, idx)
  local md = self.mdl
  ch = unsignedArg(self:_mdInt(ch, "getMix"))
  idx = unsignedArg(self:_mdInt(idx, "getMix"))
  local first = mdFirstMix(md, ch)
  if idx < mdMixCount(md, ch, first) then
    local m = md.mix[first + idx]
    return { name = m.name, source = m.srcRaw, weight = fromSNV(m.weight), offset = fromSNV(m.offset),
             switch = m.swtch, curveType = m.ctype, curveValue = fromSNV(m.cvalue), multiplex = m.mltpx,
             flightModes = m.flightModes, carryTrim = m.carryTrim, mixWarn = m.mixWarn,
             delayPrec = m.delayPrec, delayUp = m.delayUp, delayDown = m.delayDown,
             speedPrec = m.speedPrec, speedUp = m.speedUp, speedDown = m.speedDown }
  end
  return nil
end

-- model building and inspection (test code) -------------------------------

-- A line with the user's defaults: one plain line (side 3, no switch, expo 0, all flight modes).
function M.line(t)
  local l = { name = "", source = SRC_THR, scale = 0, weight = 100, offset = 0, switch = 0,
              curveType = 1, curveValue = 0, trimSource = 0, side = 3, flightModes = 0 }
  for k, v in pairs(t or {}) do l[k] = v end
  return l
end

-- The user's four models (radio sd card/MODELS/model1..4.yml, read-only): inputs Rud, Ele, Thr,
-- Ail on I1..I4 (chn 0..3), one plain line each; mixes CH1 = I4, CH2 = I2, CH3 = I3, CH4 = I1,
-- CH5 = SE -100 %, CH6..CH10 = SA SB SC SD SF, CH11 = P1, CH12 = SF. Only the throttle line differs.
M.USER_MODELS = {
  { file = "model1.yml", name = "75", w = 75, o = -25 },
  { file = "model2.yml", name = "sim", w = 50, o = -50 },
  { file = "model3.yml", name = "100% pro", w = 100, o = 0 },
  { file = "model4.yml", name = "100% pro gemini", w = 100, o = 0 },
}

-- Model spec of user model i (1..4). over (optional): thr = list of lines for input 3 (chn 2,
-- replaces the plain line), extra = more lines { chn = n, <getInput keys> } (sorted in by chn),
-- mixes = replacement mix list, name, file, gvars = { [0] = v, ... }.
function M.userModel(i, over)
  local u = M.USER_MODELS[i] or M.USER_MODELS[1]
  over = over or {}
  local expos = {
    { chn = 0, source = 1 }, { chn = 1, source = 2 },
  }
  local thr = over.thr or { { source = SRC_THR, weight = u.w, offset = u.o } }
  for _, l in ipairs(thr) do
    local c = { chn = 2 }
    for k, v in pairs(l) do c[k] = v end
    expos[#expos + 1] = c
  end
  expos[#expos + 1] = { chn = 3, source = 4 }
  for _, l in ipairs(over.extra or {}) do expos[#expos + 1] = l end
  local mixes = over.mixes or {
    { destCh = 0, source = SRC_INPUT0 + 3 }, { destCh = 1, source = SRC_INPUT0 + 1 },
    { destCh = 2, source = SRC_INPUT0 + 2 }, { destCh = 3, source = SRC_INPUT0 + 0 },
    { destCh = 4, source = SRC_SE, weight = -100 }, { destCh = 5, source = SRC_SA },
    { destCh = 6, source = SRC_SB }, { destCh = 7, source = SRC_SC }, { destCh = 8, source = SRC_SD },
    { destCh = 9, source = SRC_SF }, { destCh = 10, source = SRC_S1 }, { destCh = 11, source = SRC_SF },
  }
  return { name = over.name or u.name, file = over.file or u.file, expos = expos, mixes = mixes,
           inputNames = { [0] = "Rud", [1] = "Ele", [2] = "Thr", [3] = "Ail" }, gvars = over.gvars }
end

-- Load a model (a spec from M.userModel or the same shape). The firmware keeps the lines
-- sorted by input; the loader sorts them (stable) the same way.
function Radio:loadModel(spec)
  local md = self.mdl
  if md == nil then error("loadModel: this radio has no model input API (Mock.new{ model = false })", 2) end
  -- the records of earlier models stay (a scenario checks them at the end)
  local keep = { seed = md.seed, writes = md.writes, glitches = md.glitches, nGlitches = md.nGlitches,
                 badWrites = md.badWrites, floatArgs = md.floatArgs, multi = md.multi }
  md = newModelData()
  self.mdl = md
  md.file = spec.file or "model1.yml"
  if spec.name ~= nil then self.modelName = spec.name end
  local list = {}
  for i, l in ipairs(spec.expos or {}) do list[#list + 1] = { i = i, l = l } end
  table.sort(list, function(a, b)
    if a.l.chn ~= b.l.chn then return a.l.chn < b.l.chn end
    return a.i < b.i
  end)
  for i, e in ipairs(list) do
    local ed = emptyExpo()
    ed.chn = e.l.chn
    md.expo[i - 1] = ed
    for k, v in pairs(M.line(e.l)) do
      if k ~= "chn" and k ~= "inputName" then self:_mdSetField(ed, e.l.chn, k, v) end
    end
  end
  for chn, nm in pairs(spec.inputNames or {}) do md.inputNames[chn] = nm end
  for i, m in ipairs(spec.mixes or {}) do
    local x = emptyMix()
    x.destCh, x.srcRaw = m.destCh, m.source
    x.weight, x.offset = toSNV(m.weight or 100), toSNV(m.offset or 0)
    x.swtch = m.switch or 0
    md.mix[i - 1] = x
  end
  for k, v in pairs(spec.gvars or {}) do md.gvars[k] = v end
  for k, v in pairs(spec.inj or {}) do md.inj[k] = v end
  for k, v in pairs(keep) do md[k] = v end                      -- (test values are not widget floats)
  md.prev = mdCycle(md)                                         -- the mixer has run before
  md.states = {}
  md.dirty = false
end

function Radio:_initModel(opts)
  if opts.model == false then return end
  self.mdl = newModelData()
  self:loadModel(opts.model or M.userModel(1))
  if opts.modelName then self.modelName = opts.modelName end
end

-- The lines of one input as getInput tables (no API call, no mixer cycle).
function Radio:inputLines(chn)
  local md = self.mdl
  local r = {}
  if md == nil then return r end
  local first = mdFirstInput(md, chn)
  for i = 0, mdCountFrom(md, chn, first) - 1 do r[#r + 1] = mdLineTable(md, md.expo[first + i], chn) end
  return r
end

-- Text of the whole expo table and the input names (for "the model did not change" checks).
function Radio:modelSnapshot()
  local md = self.mdl
  if md == nil then return "" end
  local out = {}
  for i = 0, MAX_EXPOS - 1 do
    local e = md.expo[i]
    if e.mode ~= 0 or e.srcRaw ~= 0 then
      out[#out + 1] = sformat("%d:%d/%d/%d/%d/%d/%d/%d/%d/%d/%d/%d/%s", i, e.chn, e.mode, e.scale, e.trimSource,
        e.srcRaw, e.weight, e.offset, e.swtch, e.ctype, e.cvalue, e.flightModes, e.name)
    end
  end
  for i = 0, MAX_INPUTS - 1 do
    if md.inputNames[i] ~= "" then out[#out + 1] = "n" .. i .. "=" .. md.inputNames[i] end
  end
  return tconcat(out, ";")
end

-- Output of input chn (-1024..1024) at throttle stick value thr (-1024..1024), with the current
-- model; nil when the input has no active line.
function Radio:modelOut(chn, thr)
  local md = self.mdl
  if md == nil then return nil end
  local anas = {}
  mdApplyExpos(md, anas, thr)
  return anas[chn]
end

---------------------------------------------------------------------------
-- CRSF transport (per-instance input queues, one shared output slot)
---------------------------------------------------------------------------

local QUEUE_CAP = 255

function Radio:_initCrsf(opts)
  self.crsf = {
    enabled = (opts.crsf ~= false),
    module = opts.module,
    outFrame = nil,
    extBusyUntil = -1,
    global = { frames = {}, bytes = 0, dropped = 0 },
    queues = {},
    pushCalls = 0, pushOk = 0, pushBusy = 0, pushNil = 0, probes = 0, popCalls = 0, popFrames = 0,
    log = {},
  }
end

function Radio:attachModule(m) self.crsf.module = m end
function Radio:setCrsfEnabled(on) self.crsf.enabled = on and true or false end
-- simulate another script holding the single output buffer for ms milliseconds
function Radio:holdOutputBuffer(ms) self.crsf.extBusyUntil = self.clock + ms end

function Radio:_queueFor(inst)
  local C = self.crsf
  if not inst then return C.global end
  local q = C.queues[inst]
  if not q then
    q = { frames = {}, bytes = 0, dropped = 0, created = self.clock }
    C.queues[inst] = q
  end
  return q
end

local function enqueue(q, cmd, data)
  local cost = #data + 2
  if q.bytes + cost > QUEUE_CAP then
    q.dropped = q.dropped + 1
    return false
  end
  q.frames[#q.frames + 1] = { cmd = cmd, data = data, cost = cost }
  q.bytes = q.bytes + cost
  return true
end

-- deliver due module frames to every registered queue (fan-out)
function Radio:_crsfDeliver()
  local C = self.crsf
  local m = C.module
  if not m or not C.enabled then return end
  local frames = m:poll(self.clock)
  for _, f in ipairs(frames) do
    local function copy()
      local d = {}
      for i = 1, #f.data do d[i] = f.data[i] end
      return d
    end
    enqueue(C.global, f.cmd, copy())
    for _, q in pairs(C.queues) do enqueue(q, f.cmd, copy()) end
  end
end

-- the frame in the output buffer goes out in the next mixer slot (a few ms)
function Radio:_crsfFlush()
  local C = self.crsf
  local f = C.outFrame
  if not f then return end
  C.outFrame = nil
  if C.module and C.enabled then
    C.module:handle(self.clock + 4, f.cmd, f.data)
  end
end

-- inject frames straight into all queues (stale traffic for other scripts)
function Radio:injectFrame(cmd, data)
  local C = self.crsf
  for _, q in pairs(C.queues) do
    local d = {}
    for i = 1, #data do d[i] = data[i] end
    enqueue(q, cmd, d)
  end
end

function Radio:_push(...)
  local C = self.crsf
  local inst = self.current
  C.pushCalls = C.pushCalls + 1
  if inst then inst.crsfPush = inst.crsfPush + 1 end
  local nargs = select("#", ...)
  if not C.enabled then
    C.pushNil = C.pushNil + 1
    return nil
  end
  -- the per-instance input queue is created on the first pop or push
  if inst then self:_queueFor(inst) end
  local available = (C.outFrame == nil) and (self.clock >= C.extBusyUntil)
  if nargs == 0 then
    C.probes = C.probes + 1
    return available
  end
  if nargs > 64 then return false end
  local cmd, data = ...
  if not available then
    -- firmware: arguments are not checked while the buffer is busy
    C.pushBusy = C.pushBusy + 1
    if inst then inst.crsfBusy = inst.crsfBusy + 1 end
    return false
  end
  if type(cmd) ~= "number" then
    error("bad argument #1 to 'crossfireTelemetryPush' (number expected, got " .. type(cmd) .. ")", 0)
  end
  if type(data) ~= "table" then
    error("bad argument #2 to 'crossfireTelemetryPush' (table expected, got " .. type(data) .. ")", 0)
  end
  local n = #data
  local bytes = {}
  for i = 1, n do
    local v = data[i]
    if type(v) ~= "number" then
      error("bad argument to 'crossfireTelemetryPush': payload[" .. i .. "] is " .. type(v) .. " (number expected)", 0)
    end
    if v ~= floor(v) then self:warn("crossfireTelemetryPush payload byte is not an integer (radio floors it)") end
    local b = floor(v) % 256
    if b ~= v then self:warn("crossfireTelemetryPush payload byte outside 0..255 (truncated to 8 bits)") end
    bytes[i] = b
  end
  if n > 61 then self:warn("crossfireTelemetryPush payload longer than the 64-byte frame (bytes dropped)") end
  C.outFrame = { cmd = floor(cmd) % 256, data = bytes }
  C.pushOk = C.pushOk + 1
  if inst then
    inst.crsfPushOk = inst.crsfPushOk + 1
    inst.pushThisCycle = inst.pushThisCycle + 1
  end
  C.log[#C.log + 1] = { t = self.clock, cmd = floor(cmd) % 256, data = bytes, inst = inst and inst.id or 0 }
  return true
end

function Radio:_pop()
  local C = self.crsf
  local inst = self.current
  C.popCalls = C.popCalls + 1
  if inst then inst.crsfPop = inst.crsfPop + 1 end
  local q = self:_queueFor(inst)
  local f = table.remove(q.frames, 1)
  if not f then return end
  q.bytes = q.bytes - f.cost
  C.popFrames = C.popFrames + 1
  local d = {}
  for i = 1, #f.data do d[i] = f.data[i] end
  return f.cmd, d
end

---------------------------------------------------------------------------
-- LVGL implementation
---------------------------------------------------------------------------

local function objDesc(obj)
  return sformat("%s#%d (created at %s)", obj.kind, obj.id, obj.createdAt or "?")
end
M.objDesc = objDesc

-- validate one key/value, store it into obj.props / obj.fns / obj.cbs
function Radio:_setParam(obj, key, val, vkind)
  local what = sformat("property '%s' of %s", key, obj.kind)
  local tv = type(val)
  if vkind == "int" then
    if tv ~= "number" then self:violation(what .. ": number expected, got " .. tv) return end
    obj.props[key] = floor(val)
  elseif vkind == "numfn" or vkind == "numnp" then
    if tv == "function" then
      obj.fns[key] = val
      if vkind == "numnp" then
        self:warn(sformat("%s is a function but the firmware never polls it", what), "np:" .. obj.kind .. key)
      end
    elseif tv == "number" then
      obj.props[key] = floor(val)
      if obj.fns[key] then
        self:warn(sformat("%s: static value given by set() while a function is bound (the function stays active)", what))
      end
    else
      self:violation(what .. ": number or function expected, got " .. tv)
    end
  elseif vkind == "fnonly" then
    if tv ~= "function" then
      self:violation(what .. " must be a function (got " .. tv .. "): the firmware calls it on the first poll and the widget dies")
      return
    end
    obj.fns[key] = val
  elseif vkind == "bool" then
    if tv == "boolean" then obj.props[key] = val
    elseif tv == "number" then obj.props[key] = (val ~= 0)
    else self:violation(what .. ": boolean expected, got " .. tv) end
  elseif vkind == "boolfn" then
    if tv == "function" then obj.fns[key] = val
    elseif tv == "boolean" then obj.props[key] = val
    elseif tv == "number" then obj.props[key] = (val ~= 0)
    else self:violation(what .. ": boolean or function expected, got " .. tv) end
  elseif vkind == "strfn" or vkind == "strnp" then
    if tv == "function" then
      obj.fns[key] = val
      if vkind == "strnp" then
        self:warn(sformat("%s is a function but the firmware never polls it", what), "np:" .. obj.kind .. key)
      end
    elseif tv == "string" or tv == "number" then
      obj.props[key] = tostring(val)
    else
      self:violation(what .. ": string expected, got " .. tv)
    end
  elseif vkind == "str" then
    if tv == "string" or tv == "number" then obj.props[key] = tostring(val)
    else self:violation(what .. ": string expected, got " .. tv) end
  elseif vkind == "cb" then
    if tv ~= "function" then self:violation(what .. ": function expected, got " .. tv) return end
    obj.cbs[key] = val
  elseif vkind == "strtab" then
    if tv ~= "table" then self:violation(what .. ": table expected, got " .. tv) return end
    local vals = {}
    for i, s in ipairs(val) do
      if type(s) ~= "string" and type(s) ~= "number" then
        self:violation(sformat("%s: entry %d is %s (string expected)", what, i, type(s)))
      end
      vals[i] = tostring(s)
    end
    obj.props[key] = vals
  elseif vkind == "pts" then
    if tv == "function" then obj.fns[key] = val
    elseif tv == "table" then obj.props[key] = val
    else self:violation(what .. ": table or function expected, got " .. tv) end
  elseif vkind == "btntab" then
    if tv ~= "table" then self:violation(what .. ": table expected, got " .. tv) return end
    obj.props[key] = val
  end
end

function Radio:_parseParams(obj, params, keyset)
  if type(params) ~= "table" then
    self:violation(sformat("lvgl.%s: parameter table expected, got %s", obj.kind, type(params)))
    return
  end
  for k, v in pairs(params) do
    if type(k) ~= "string" then
      self:violation(sformat("lvgl.%s: non-string key %s in the parameter table (Invalid property on 2.12.x)",
        obj.kind, tostring(k)))
    elseif k == "type" or k == "name" then
      -- consumed by build
    elseif k == "children" then
      if type(v) ~= "table" then self:violation("children must be a table") end
    elseif BANNED_KEYS[k] then
      self:violation(sformat("lvgl.%s: %s", obj.kind, BANNED_KEYS[k]))
    else
      local vk = keyset[k]
      if not vk then
        self:violation(sformat("Invalid property '%s' for lvgl.%s (rc1 ignores it, 2.12.x raises an error)", k, obj.kind))
      else
        self:_setParam(obj, k, v, vk)
      end
    end
  end
end

-- current parent object for geometry: an object with a window, else the root
local function geomParent(p)
  if p and p.spec and p.spec.window then return p end
  return nil
end

function Radio:_checkFresh(obj)
  local p = obj.props
  local k = obj.kind
  local hasSize = obj.fns.size ~= nil
  if k == "hline" or k == "vline" then
    if not hasSize and (p.w == nil or p.h == nil) then
      self:violation(sformat("lvgl.%s needs both w and h (unset = LV_SIZE_CONTENT, a huge line width)", k))
    end
    if k == "hline" and p.h and p.h <= 0 then self:violation("lvgl.hline: h (thickness) must be >= 1") end
    if k == "vline" and p.w and p.w <= 0 then self:violation("lvgl.vline: w (thickness) must be >= 1") end
  elseif k == "rectangle" then
    if not hasSize then
      if p.w == nil or p.h == nil then
        self:violation("lvgl.rectangle needs w and h (default is content size = 0)")
      elseif p.w <= 0 or p.h <= 0 then
        self:violation(sformat("lvgl.rectangle with w=%d h=%d (must be >= 1; 0 means content size, negative is undefined on rc1)",
          p.w, p.h))
      end
    end
  elseif k == "image" then
    if not hasSize and (p.w == nil or p.h == nil or p.w <= 0 or p.h <= 0) then
      self:violation("lvgl.image needs w and h > 0")
    end
    if p.file then self:_checkImageFile(p.file) end
  elseif k == "triangle" then
    local pts = p.pts
    if type(pts) == "table" then
      local ymin, ymax, xmin, xmax = 1e9, -1e9, 1e9, -1e9
      for _, pt in ipairs(pts) do
        if type(pt) == "table" and type(pt[1]) == "number" and type(pt[2]) == "number" then
          if pt[1] < xmin then xmin = pt[1] end
          if pt[1] > xmax then xmax = pt[1] end
          if pt[2] < ymin then ymin = pt[2] end
          if pt[2] > ymax then ymax = pt[2] end
        end
      end
      if ymax - ymin > 127 or xmax - xmin > 127 then
        self:violation("lvgl.triangle larger than 127 px (rc1 int8 overflow bug)")
      end
    end
  elseif k == "label" then
    local al = p.align or 0
    if (al % 4) >= 2 and ((p.x or 0) ~= 0 or (p.y or 0) ~= 0) and self.mode == "rc1" then
      self:warn(sformat("label with VCENTER at x=%d,y=%d: rc1 resets x/y to 0 (put it at 0,0 in a sized box) [%s]",
        p.x or 0, p.y or 0, obj.createdAt), "vcenter" .. obj.createdAt)
    end
    if p.font and not FONTS[floor((p.font % 4096) / 256)] then
      self:warn("label font flags without a valid font index: " .. tostring(p.font))
    end
  end
end

function Radio:_checkImageFile(file)
  if type(file) ~= "string" then return end
  local rel = string.gsub(file, "^/+", "")
  local full = self.sdRoot .. "/" .. rel
  if not fileExists(full) then
    self:warn("image file not found on the SD copy: " .. file)
  end
  if string.sub(file, 1, 1) == "/" then
    self:warn("image file with a leading '/' (works, but DESIGN asks for WIDGETS/FPVDASH/...): " .. file)
  end
end

function Radio:_newHandle(obj)
  local h = setmetatable({}, obj.spec.meta == "full" and self._fullMT or self._simpleMT)
  self.handles[h] = obj
  obj.handle = h
  return h
end

function Radio:_objOf(h, required)
  local obj = (type(h) == "table") and self.handles[h] or nil
  if obj and obj.valid then
    if self.current and obj.inst ~= self.current then
      self:violation(sformat("%s belongs to widget instance #%d but is used by instance #%d (shared state between instances?)",
        objDesc(obj), obj.inst.id, self.current.id))
    end
    return obj
  end
  if required then
    if obj then
      error(werr("Invalid lvgl object (it has been probably been cleared). " .. objDesc(obj)
        .. " was deleted by lvgl.clear() and used again at " .. whereCaller()), 0)
    end
    error(werr("Invalid lvgl object (it has been probably been cleared). Value: " .. tostring(h)
      .. " at " .. whereCaller()), 0)
  end
  return nil
end

-- create an object; parentObj = explicit parent (method form / lvgl.x(parent, t)) or build temp parent
function Radio:_create(kind, parentObj, params)
  local inst = self.current
  if not inst then
    self:warn("lvgl." .. kind .. "() called outside a widget call (no luaScriptManager): returns nil")
    return nil
  end
  local spec = KINDS[kind]
  if spec.control and not inst.fullscreen then
    inst.ctrlOutsideFS = inst.ctrlOutsideFS + 1
    self:warn(sformat("lvgl.%s called while not full screen: returns nil [%s]", kind, whereCaller()),
      "ctrlnil" .. kind)
    return nil
  end
  if parentObj and parentObj.clearRequest then
    self:violation(sformat("%s added to %s that was cleared in this cycle: the firmware drops the refs of "
      .. "its children at the next poll, so this new object stops updating and its handle becomes invalid "
      .. "(fill a cleared box only after it was polled once)", kind, objDesc(parentObj)))
  end
  self.objSeq = self.objSeq + 1
  inst.created = inst.created + 1
  local obj = {
    kind = kind, spec = spec, inst = inst, id = self.objSeq, createdAt = whereCaller(),
    props = {}, fns = {}, cbs = {}, children = {}, refs = {},
    shown = true, enabled = true, valid = true, changes = 0,
  }
  -- LV_OBJ_FLAG_CLICKABLE: LvglWidgetBox::build (box, rectangle, circle) clears it only when the
  -- object is made in a widget that is not full screen (rc1 lua_lvgl_widget.cpp:1501-1502, 2.12.0
  -- :1616-1617). Arcs (:1827), images (libui static.cpp:223), labels and lines are never
  -- clickable; controls always are.
  if spec.control then
    obj.clickable = true
  elseif kind == "box" or kind == "rectangle" or kind == "circle" then
    obj.clickable = inst.fullscreen and true or false
  else
    obj.clickable = false
  end
  -- defaults
  if kind ~= "button" and kind ~= "momentaryButton" then obj.props.color = C.COLOR_THEME_SECONDARY1 end
  obj.props.opacity = 255
  obj.props.x, obj.props.y = 0, 0
  if kind == "label" then obj.props.text = ""; obj.props.font = C.STDSIZE; obj.props.align = C.LEFT end
  if kind == "button" or kind == "momentaryButton" then obj.props.text = "" end
  if kind == "rectangle" or kind == "circle" or kind == "arc" then obj.props.filled = false; obj.props.thickness = 1 end
  if kind == "arc" then obj.props.startAngle = 0; obj.props.endAngle = 360 end
  self:_parseParams(obj, params, spec.allKeys)
  self:_checkFresh(obj)
  if spec.control and (kind == "toggle" or kind == "choice" or spec.getOnce) and obj.cbs.get then
    self:_callGet(obj)
  end
  -- LVGL tree
  local gp = geomParent(parentObj)
  obj.parent = gp
  if parentObj and not gp then
    self:warn(sformat("%s created as a child of %s, which has no window: it goes to the widget root",
      kind, parentObj.kind))
  end
  if gp then gp.children[#gp.children + 1] = obj else inst.tree[#inst.tree + 1] = obj end
  inst.objects[#inst.objects + 1] = obj
  -- create() polls the new object once
  self:_pollObj(obj)
  -- children
  if type(params) == "table" and type(params.children) == "table" and spec.window then
    self:_buildList(obj, params.children, nil)
  end
  -- push: save the ref in the temp parent or the instance
  if parentObj then parentObj.refs[#parentObj.refs + 1] = obj else inst.roots[#inst.roots + 1] = obj end
  return self:_newHandle(obj)
end

function Radio:_buildList(parentObj, defs, named)
  if type(defs) ~= "table" then
    self:violation("lvgl.build: table of object definitions expected")
    return
  end
  local inst = self.current
  for _, def in pairs(defs) do
    if type(def) ~= "table" then
      self:violation("lvgl.build: entry is not a table")
    else
      local t = def.type
      local kind
      if type(t) == "number" then kind = TYPE_BY_NUM[t]
      elseif type(t) == "string" then
        local lt = string.lower(t)
        for k in pairs(KINDS) do
          if string.lower(k) == lt then kind = k end
        end
        if lt == "page" or lt == "dialog" then kind = nil end
      end
      if not kind then
        self:violation("lvgl.build: missing or bad type " .. tostring(t) .. " (2.12.x raises 'Missing or bad type')")
      else
        local spec = KINDS[kind]
        if spec.control and not inst.fullscreen then
          inst.ctrlOutsideFS = inst.ctrlOutsideFS + 1
        else
          local h = self:_create(kind, parentObj, def)
          if named and type(def.name) == "string" and h then named[def.name] = h end
        end
      end
    end
  end
end

-- poll helpers ----------------------------------------------------------

function Radio:_propError(obj, key, msg)
  error(werr(sformat("property function '%s' of %s: %s", key, objDesc(obj), msg)), 0)
end

local function cwErr(r)
  if type(r) == "table" then return r.msg or tostring(r), r.tb end
  return tostring(r), nil
end

function Radio:_callFn(obj, key, f)
  self.stats_propCalls = (self.stats_propCalls or 0) + 1
  return callWidget(f)
end

function Radio:_pollBool(obj, key)
  local ok, v = self:_callFn(obj, key, obj.fns[key])
  if not ok then
    local m, tb = cwErr(v)
    error(setmetatable({ msg = sformat("property function '%s' of %s failed: %s", key, objDesc(obj), m), tb = tb }, WidgetError), 0)
  end
  local tv = type(v)
  if tv == "boolean" then return v end
  if tv == "number" then return v ~= 0 end
  if tv == "nil" then
    if self.strict then self:_propError(obj, key, "returned nil (contract: must return a boolean)") end
    return false
  end
  self:_propError(obj, key, "returned a " .. tv .. " (boolean expected)")
end

function Radio:_pollNum(obj, key)
  local ok, v = self:_callFn(obj, key, obj.fns[key])
  if not ok then
    local m, tb = cwErr(v)
    error(setmetatable({ msg = sformat("property function '%s' of %s failed: %s", key, objDesc(obj), m), tb = tb }, WidgetError), 0)
  end
  if type(v) ~= "number" then
    self:_propError(obj, key, "returned " .. (v == nil and "nil" or ("a " .. type(v))) .. " (number expected; widget dies)")
  end
  return floor(v)
end

function Radio:_pollStr(obj, key)
  local ok, v = self:_callFn(obj, key, obj.fns[key])
  if not ok then
    local m, tb = cwErr(v)
    error(setmetatable({ msg = sformat("property function '%s' of %s failed: %s", key, objDesc(obj), m), tb = tb }, WidgetError), 0)
  end
  local tv = type(v)
  if tv == "string" then return v end
  if tv == "number" then return tostring(v) end
  self:_propError(obj, key, "returned " .. (v == nil and "nil" or ("a " .. tv)) .. " (string expected; widget dies)")
end

function Radio:_poll2(obj, key)
  local ok, a, b = self:_callFn(obj, key, obj.fns[key])
  if not ok then
    local m, tb = cwErr(a)
    error(setmetatable({ msg = sformat("property function '%s' of %s failed: %s", key, objDesc(obj), m), tb = tb }, WidgetError), 0)
  end
  if type(a) ~= "number" or type(b) ~= "number" then
    self:_propError(obj, key, sformat("must return two numbers, got %s, %s", type(a), type(b)))
  end
  return floor(a), floor(b)
end

local function setProp(obj, key, v)
  if obj.props[key] ~= v then
    obj.props[key] = v
    obj.changes = obj.changes + 1
  end
end

function Radio:_invalidate(obj)
  if not obj.valid then return end
  obj.valid = false
  -- clearRefs nulls the userdata, so the C++ wrapper of the object is never deleted
  -- (lua_lvgl_widget.cpp clearRefs, api_colorlcd_lvgl.cpp luaDestroyLvglWidget)
  if obj.inst then
    obj.inst.needCompact = true
    obj.inst.leaked = obj.inst.leaked + 1
  end
  for _, c in ipairs(obj.refs) do self:_invalidate(c) end
  for _, c in ipairs(obj.children) do self:_invalidate(c) end
end

-- LvglWidgetObjectBase::callRefs and the per-class overrides
function Radio:_pollObj(obj)
  if not obj.valid then return end
  if obj.clearRequest then
    obj.clearRequest = false
    for _, c in ipairs(obj.refs) do self:_invalidate(c) end
    obj.refs = {}
    return
  end
  local fns = obj.fns
  if fns.visible then obj.shown = self:_pollBool(obj, "visible") end
  if not obj.shown then return end
  if fns.color then setProp(obj, "color", self:_pollNum(obj, "color")) end
  if fns.opacity then
    local o = self:_pollNum(obj, "opacity")
    if o < 0 or o > 255 then self:warn(sformat("opacity %d outside 0..255 (%s)", o, objDesc(obj))) end
    setProp(obj, "opacity", o)
  end
  if fns.size then
    local w, h = self:_poll2(obj, "size")
    if w < 0 or h < 0 then
      self:_propError(obj, "size", sformat("returned a negative size %d x %d (undefined on rc1)", w, h))
    end
    if (w == 0 or h == 0) and (obj.kind == "rectangle" or obj.kind == "image" or obj.kind == "box") then
      self:_propError(obj, "size", sformat("returned %d x %d: rectangles need w, h >= 1 (clamp it)", w, h))
    end
    setProp(obj, "w", w)
    setProp(obj, "h", h)
  end
  if fns.pos then
    local x, y = self:_poll2(obj, "pos")
    setProp(obj, "x", x)
    setProp(obj, "y", y)
  end
  local refs = obj.refs
  local i = 1
  while i <= #refs do
    self:_pollObj(refs[i])
    if obj.clearRequest then
      obj.clearRequest = false
      for _, c in ipairs(obj.refs) do self:_invalidate(c) end
      obj.refs = {}
      return
    end
    i = i + 1
  end
  local poll = obj.spec.poll
  for j = 1, #poll do
    local k = poll[j]
    if fns[k] then
      if k == "active" then
        obj.enabled = self:_pollBool(obj, "active")
      elseif k == "filled" then
        setProp(obj, "filled", self:_pollBool(obj, "filled"))
      elseif k == "text" or k == "file" or k == "title" or k == "subtitle" then
        local s = self:_pollStr(obj, k)
        if k == "file" and s ~= obj.props.file then self:_checkImageFile(s) end
        setProp(obj, k, s)
      elseif k == "scrollTo" then
        self:_poll2(obj, k)
      elseif k == "pts" then
        local ok, v = self:_callFn(obj, k, fns[k])
        if not ok then
          local m = cwErr(v)
          self:_propError(obj, k, "failed: " .. m)
        end
        if type(v) ~= "table" then self:_propError(obj, k, "must return a table of points") end
        obj.props.pts = v
      else
        setProp(obj, k, self:_pollNum(obj, k))
      end
    end
  end
end

-- control `get` functions (choice/toggle/slider/pickers are polled every cycle)
function Radio:_callGet(obj)
  local ok, v = callWidget(obj.cbs.get)
  if not ok then
    local m, tb = cwErr(v)
    error(setmetatable({ msg = sformat("get() of %s failed: %s", objDesc(obj), m), tb = tb }, WidgetError), 0)
  end
  if type(v) == "boolean" then return v end
  if type(v) ~= "number" then
    error(werr(sformat("get() of %s returned %s: a get must never return nil (widget dies)", objDesc(obj),
      v == nil and "nil" or type(v))), 0)
  end
  if obj.kind == "choice" and obj.props.values then
    if v < 1 or v > #obj.props.values then
      self:warn(sformat("choice get() returned %s, outside 1..%d (%s)", tostring(v), #obj.props.values, objDesc(obj)))
    end
  end
  return v
end

function Radio:_pollControls(inst)
  for _, obj in ipairs(inst.objects) do
    if obj.valid and obj.spec.getPoll and obj.cbs.get then
      obj.lastGet = self:_callGet(obj)
    end
  end
end

function Radio:_pollInstance(inst)
  local roots = inst.roots
  local i = 1
  while i <= #roots do
    self:_pollObj(roots[i])
    i = i + 1
  end
end

-- remove objects deleted by clear from the instance lists
function Radio:_compact(inst)
  local function keep(list)
    local r = {}
    for _, o in ipairs(list) do if o.valid then r[#r + 1] = o end end
    return r
  end
  inst.objects = keep(inst.objects)
  inst.roots = keep(inst.roots)
  inst.tree = keep(inst.tree)
end

function Radio:_clearInstance(inst)
  for _, o in ipairs(inst.objects) do self:_invalidate(o) end
  inst.objects, inst.roots, inst.tree = {}, {}, {}
  inst.needCompact = false
  inst.clears = inst.clears + 1
end

---------------------------------------------------------------------------
-- the lvgl table seen by the widget
---------------------------------------------------------------------------

function Radio:_makeLvgl()
  local R = self
  local L = {}
  for k, v in pairs(LVK) do L[k] = v end
  if R.mode == "rc1" then L.CHOIDE = 17 else L.CHOICE = 17 end

  local function ctor(kind)
    return api(function(a, b)
      if b ~= nil or (type(a) == "table" and R.handles[a]) then
        -- lvgl.kind(parent, params) or parent:kind(params)
        local p = R:_objOf(a, true)
        return R:_create(kind, p, b)
      end
      return R:_create(kind, nil, a)
    end)
  end
  for _, k in ipairs(CONSTRUCTORS) do L[k] = ctor(k) end

  for k in pairs(FULL_ONLY_CTORS) do
    L[k] = api(function(params, extra)
      if extra ~= nil then
        R:violation("lvgl." .. k .. " takes only a parameter table (no parent argument)")
      end
      return R:_create(k, nil, params)
    end)
  end

  local function popup(kind)
    return api(function(params)
      local inst = R.current
      if not inst then R:warn("lvgl." .. kind .. " called outside a widget call") return end
      if type(params) ~= "table" then R:violation("lvgl." .. kind .. ": table expected") return end
      local obj = { kind = kind, spec = { allKeys = POPUP_KEYS[kind] }, props = {}, fns = {}, cbs = {},
                    id = 0, createdAt = whereCaller() }
      R:_parseParams(obj, params, POPUP_KEYS[kind])
      local p = { kind = kind, title = obj.props.title or "", message = obj.props.message or "",
                  values = obj.props.values, cbs = obj.cbs, inst = inst, t = R.clock, at = obj.createdAt }
      if kind == "menu" and obj.cbs.get then
        local ok, v = callWidget(obj.cbs.get)
        if not ok then
          local m = cwErr(v)
          error(werr("menu get() failed: " .. m), 0)
        end
        if type(v) ~= "number" and type(v) ~= "boolean" then
          error(werr("menu get() returned " .. (v == nil and "nil" or type(v)) .. " (integer expected; widget dies)"), 0)
        end
        p.selected = v
      end
      inst.popups[#inst.popups + 1] = p
      inst.popupLog[#inst.popupLog + 1] = p
    end)
  end
  L.confirm = popup("confirm")
  L.message = popup("message")
  L.menu = popup("menu")

  L.clear = api(function(o)
    local inst = R.current
    if not inst then return end
    if o ~= nil then
      local obj = R:_objOf(o, true)
      if obj.spec.meta ~= "full" then
        error(werr("lvgl.clear(obj): " .. obj.kind .. " has no children to clear"), 0)
      end
      obj.clearRequest = true
      inst.objClears = inst.objClears + 1
      for _, c in ipairs(obj.children) do R:_invalidateGeom(c) end
      obj.children = {}
      return
    end
    if inst.inCallback then
      R:violation("lvgl.clear() called inside a control callback (rebuild from refresh instead): " .. whereCaller())
    end
    -- the no-argument clear also deletes the firmware's own children of the widget
    -- (focus border in widget-select mode): count the calls made after objects exist
    if #inst.objects > 0 then inst.fullClearsAfterBuild = inst.fullClearsAfterBuild + 1 end
    R:_clearInstance(inst)
  end)

  L.build = api(function(a, b)
    local parent, defs = nil, a
    if b ~= nil then parent = R:_objOf(a, true); defs = b end
    if not R.current then return nil end
    local named = {}
    R:_buildList(parent, defs, named)
    if R.mode == "rc1" then return {} end
    return named
  end)

  L.isAppMode = api(function() return R.current and R.current.appMode or false end)
  L.isFullScreen = api(function() return R.current and R.current.fullscreen or false end)
  L.exitFullScreen = api(function()
    local inst = R.current
    if inst and inst.fullscreen then inst.closeFS = true end
  end)
  L.getContext = api(function() return R.current and R.current.ctx or nil end)

  L.set = api(function(o, params)
    local obj = R:_objOf(o, true)
    R:_parseParams(obj, params, obj.spec.allKeys)
  end)
  L.show = api(function(o) R:_objOf(o, true).shown = true end)
  L.hide = api(function(o) R:_objOf(o, true).shown = false end)
  L.enable = api(function(o) R:_objOf(o, true).enabled = true end)
  L.disable = api(function(o) R:_objOf(o, true).enabled = false end)
  L.close = api(function(o)
    local obj = R:_objOf(o, true)
    if obj.kind ~= "dialog" then R:warn("lvgl.close() on a " .. obj.kind) end
    R:_invalidate(obj)
  end)
  L.getScrollPos = api(function(o) R:_objOf(o, true) return 0, 0 end)

  -- method tables
  local simple = { set = L.set, show = L.show, hide = L.hide }
  local full = { set = L.set, show = L.show, hide = L.hide, enable = L.enable, disable = L.disable,
                 close = L.close, getScrollPos = L.getScrollPos, clear = L.clear, build = L.build }
  for _, k in ipairs(CONSTRUCTORS) do full[k] = L[k] end
  local function newindex() error("attempt to index a userdata value (lvgl object)", 2) end
  self._simpleMT = { __index = simple, __newindex = newindex, __metatable = "lvgl object",
                     __tostring = function(h) local o = R.handles[h]; return "lvgl:" .. (o and o.kind or "?") end }
  self._fullMT = { __index = full, __newindex = newindex, __metatable = "lvgl object",
                   __tostring = function(h) local o = R.handles[h]; return "lvgl:" .. (o and o.kind or "?") end }
  return L
end

function Radio:_invalidateGeom(obj)
  obj.deletedLvgl = true
  for _, c in ipairs(obj.children) do self:_invalidateGeom(c) end
end

---------------------------------------------------------------------------
-- sandbox environment (the EdgeTX global table)
---------------------------------------------------------------------------

function Radio:_loadScriptFile(path, mode, env)
  if type(path) ~= "string" then return nil, "loadScript: file name expected" end
  local rel = string.gsub(path, "^/+", "")
  local full = self.sdRoot .. "/" .. rel
  local src = readFile(full)
  if not src and string.sub(full, -5) == ".luac" then
    full = string.sub(full, 1, -2)
    src = readFile(full)
  end
  self.loads[#self.loads + 1] = { path = path, phase = self.phase, inst = self.current and self.current.id or 0,
                                  ok = src ~= nil, t = self.clock }
  if not src then
    return nil, sformat("loadScript(\"%s\", \"%s\") error: File not found", path, mode or "bt")
  end
  local chunk, err = load(src, "@/" .. rel, "t", env or self.env)
  if not chunk then return nil, err end
  return chunk
end

local LCD_NOOPS = { "drawText", "drawNumber", "drawChannel", "drawSwitch", "drawSource", "drawGauge",
  "drawBitmap", "drawRectangle", "drawFilledRectangle", "drawLine", "drawPoint", "drawCircle",
  "drawFilledCircle", "drawTriangle", "drawFilledTriangle", "drawArc", "drawPie", "drawAnnulus",
  "drawTimer", "drawCombobox", "drawScreenTitle", "drawHudRectangle", "drawLineWithClipping",
  "clear", "resetBacklightTimeout", "refresh" }

function Radio:_makeEnv()
  local R = self
  local env = {}
  for _, k in ipairs({ "assert", "error", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawlen",
                       "rawset", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type",
                       "xpcall", "collectgarbage" }) do
    env[k] = _G[k]
  end
  env._VERSION = "Lua 5.3"
  env.print = api(function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    R.printed[#R.printed + 1] = tconcat(t, "\t")
    if R.opts.echoPrint then io.write("[widget print] ", tconcat(t, "\t"), "\n") end
  end)
  env.load = function(chunk, name, mode, e) return load(chunk, name, mode, e or env) end

  -- string: copy; format floors floats for integer conversions (LUA_FLOORN2I)
  local str = {}
  for k, v in pairs(string) do str[k] = v end
  local rawformat = string.format
  str.format = api(function(fmt, ...)
    local ok, r = pcall(rawformat, fmt, ...)
    if ok then return r end
    if type(r) == "string" and string.find(r, "no integer representation", 1, true) then
      R:warn("string.format: integer conversion of a non-integer float (the radio floors it): " .. tostring(fmt))
      local args = { ... }
      for i = 1, select("#", ...) do
        if type(args[i]) == "number" and args[i] ~= floor(args[i]) then args[i] = floor(args[i]) end
      end
      return rawformat(fmt, tunpack(args, 1, select("#", ...)))
    end
    error(r, 0)
  end)
  str.pack, str.unpack, str.packsize = string.pack, string.unpack, string.packsize
  env.string = str

  local tab = {}
  for k, v in pairs(table) do tab[k] = v end
  env.table = tab

  local mth = {}
  for k, v in pairs(math) do mth[k] = v end
  mth.pow = function(a, b) return a ^ b end
  mth.atan2 = math.atan
  mth.cosh = function(x) return (math.exp(x) + math.exp(-x)) / 2 end
  mth.sinh = function(x) return (math.exp(x) - math.exp(-x)) / 2 end
  mth.tanh = function(x) local a, b = math.exp(x), math.exp(-x) return (a - b) / (a + b) end
  mth.log10 = function(x) return math.log(x, 10) end
  mth.ldexp = function(m, e) return m * 2.0 ^ e end
  env.math = mth

  local b32 = {}
  for k, v in pairs(bit32) do b32[k] = api(v) end
  env.bit32 = b32

  -- io (EdgeTX subset: open/close/read/write/seek). Writes go to tests/out/sd_writes.
  local io2 = {}
  io2.open = api(function(path, mode)
    mode = mode or "r"
    local rel = string.gsub(tostring(path), "^/+", "")
    R.ioCalls = (R.ioCalls or 0) + 1
    if string.find(mode, "[wa]") then
      local flat = string.gsub(rel, "/", "__")
      R:warn("io.open for writing: " .. tostring(path) .. " (redirected to tests/out/sd_writes)")
      os.execute("mkdir -p '" .. M.OUT_DIR .. "/sd_writes'")
      return io.open(M.OUT_DIR .. "/sd_writes/" .. flat, mode)
    end
    return io.open(R.sdRoot .. "/" .. rel, "rb")
  end)
  io2.close = api(function(f) if f then f:close() end end)
  io2.read = api(function(f, n) if not f then return nil end return f:read(n or "a") end)
  io2.write = api(function(f, ...) if f then f:write(...) end end)
  io2.seek = api(function(f, n) if f then return f:seek("set", n or 0) end end)
  env.io = io2

  for k, v in pairs(C) do
    if type(v) == "number" then env[k] = v end
  end
  env.LCD_W, env.LCD_H = R.lcdW, R.lcdH
  env.CHAR_UP, env.CHAR_DOWN, env.CHAR_LEFT, env.CHAR_RIGHT = "\226\134\145", "\226\134\147", "\226\134\144", "\226\134\146"
  env.CHAR_TRIM, env.CHAR_SWITCH, env.CHAR_TELEMETRY = "\226\136\134", "\226\134\149", "\226\150\166"

  env.getTime = api(function() return floor(R.clock / 10) end)
  env.getDateTime = api(function() return R:_dateTime() end)
  env.getVersion = api(function() return tunpack(R.version) end)
  env.getGeneralSettings = api(function()
    local g = {}
    for k, v in pairs(R.general) do g[k] = v end
    return g
  end)
  env.getStickMode = api(function() return R.stickMode end)
  env.getFlightMode = api(function() return R.flightMode[1], R.flightMode[2] end)
  env.getValue = api(function(src) return R:_getValue(src) end)
  env.getSourceValue = api(function(src) return R:_getSourceValue(src) end)
  env.getFieldInfo = api(function(src) return R:_getFieldInfo(src) end)
  env.getSourceInfo = env.getFieldInfo
  env.getRSSI = api(function()
    local e = R.src.byName["RQly"]
    local v = (R.streaming and e) and floor(e.value) or 0
    if v > 99 then v = 99 end
    return v, 45, 42
  end)
  env.getOutputValue = api(function() return 0 end)
  env.getLogicalSwitchValue = api(function() return false end)
  env.getSwitchValue = api(function() return false end)
  env.getUsage = api(function() return floor((R.lastCount or 0) / 200) end)
  env.getAvailableMemory = api(function() return 180000 end)
  env.getShmVar = api(function() return 0 end)
  env.setShmVar = api(function() end)
  for _, k in ipairs({ "playTone", "playFile", "playNumber", "playHaptic", "playDuration", "killEvents" }) do
    env[k] = api(function(...) R.sounds[#R.sounds + 1] = k end)
  end
  env.loadScript = api(function(path, mode, e) return R:_loadScriptFile(path, mode, e) end)
  env.crossfireTelemetryPush = api(function(...) return R:_push(...) end)
  env.crossfireTelemetryPop = api(function() return R:_pop() end)
  env.sportTelemetryPush = api(function() return nil end)
  env.sportTelemetryPop = api(function() return nil end)

  local model = {}
  model.getInfo = api(function()
    return { name = R.modelName, extendedLimits = false, jitterFilter = 0, bitmap = "", labels = "",
             filename = R.mdl and R.mdl.file or "model1.yml" }
  end)
  -- model inputs and mixes (see "model inputs" above); absent with Mock.new{ model = false }
  if R.mdl then
    model.getInputsCount = api(function(chn) return R:_mdGetInputsCount(chn) end)
    model.getInput = api(function(chn, idx) return R:_mdGetInput(chn, idx) end)
    model.insertInput = api(function(chn, idx, t) return R:_mdInsertInput(chn, idx, t) end)
    model.deleteInput = api(function(chn, idx) return R:_mdDeleteInput(chn, idx) end)
    model.getMixesCount = api(function(ch) return R:_mdGetMixesCount(ch) end)
    model.getMix = api(function(ch, idx) return R:_mdGetMix(ch, idx) end)
    -- deleteInputs / defaultInputs clear the table without stopping the mixer: never allowed
    model.deleteInputs = api(function()
      R:_mdNoteWrite("deleteInputs", 0, 0)
      R.mdl.badWrites[#R.mdl.badWrites + 1] = { t = R.clock, where = whereCaller(),
        msg = "model.deleteInputs() called (clears every input while the mixer runs)" }
    end)
  end
  -- defaultChannel(stick): channel of a stick in the radio's channel order (AETR)
  env.defaultChannel = api(function(stick)
    if type(stick) ~= "number" then error("bad argument #1 to 'defaultChannel' (number expected)", 0) end
    local order = R.mdl and R.mdl.chOrder or CH_ORDER_AETR
    for i = 0, 3 do
      if order[i] == floor(stick) then return i end
    end
    return nil
  end)
  model.getTimer = api(function(i)
    if type(i) ~= "number" then error("bad argument #1 to 'getTimer' (number expected)", 0) end
    local t = R.timers[floor(i) + 1]
    if not t then return nil end
    return { mode = t.mode or 0, start = t.start or 0, value = t.value or 0, countdownBeep = 0,
             minuteBeep = false, persistent = 0, name = t.name or "", showElapsed = false, switch = 0,
             countdownStart = 0, extraHaptic = 0 }
  end)
  model.getModule = api(function(i)
    if i == 0 and R.crsf.enabled then
      return { Type = 5, subType = 0, modelId = 1, firstChannel = 0, channelsCount = 16 }
    end
    return { Type = 0, subType = 0, modelId = 0, firstChannel = 0, channelsCount = 8 }
  end)
  model.getFlightMode = api(function(n)
    return { name = R.flightMode[2], trimsModes = { 0, 0, 0, 0, 0, 0, 0, 0 }, fadeIn = 0, fadeOut = 0 }
  end)
  model.getSensor = api(function(i)
    local e = R.src.sensors[(i or 0) + 1]
    if not e then return nil end
    return { name = e.name, type = 0, prec = e.prec, unit = e.unit, id = 0, instance = 0 }
  end)
  model.getGlobalVariable = api(function(i)
    if R.mdl and type(i) == "number" then return R.mdl.gvars[floor(i)] or 0 end
    return 0
  end)
  env.model = model

  local lcd = {}
  lcd.RGB = api(function(r, g, b)
    if g == nil then
      local v = floor(r)
      r, g, b = (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF
    end
    return rgbFlags(floor(r), floor(g), floor(b))
  end)
  lcd.sizeText = api(function(text, flags)
    local w, lines, lh = measure(text, flags or 0)
    return w, lh * lines
  end)
  lcd.exitFullScreen = api(function()
    local inst = R.current
    if inst and inst.fullscreen then inst.closeFS = true end
  end)
  -- luaLcdGetColor (api_colorlcd.cpp:969-979, rc1 and 2.12.0): for an RGB flag or a theme
  -- color (index < THEME_COLOR_COUNT = 14) an RGB flag (RGB565 in bits 16..31, RGB_FLAG
  -- 0x8000), else nil. Theme colors are those of the user's "Dark Theme" (INDEX_RGB).
  lcd.getColor = api(function(c)
    if type(c) ~= "number" then error("bad argument #1 to 'getColor' (number expected)", 0) end
    c = floor(c) % 4294967296
    if c % 65536 >= 0x8000 then return (c - c % 65536) + 0x8000 end
    local idx = floor(c / 65536) % 256
    if idx >= 14 then return nil end
    local rgb = INDEX_RGB[idx] or 0
    return rgbFlags((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
  end)
  lcd.setColor = api(function(i, c) R.lcdSetColor = (R.lcdSetColor or 0) + 1 end)
  lcd.getLastPos = api(function() return 0 end)
  lcd.getLastRightPos = api(function() return 0 end)
  lcd.getLastLeftPos = api(function() return 0 end)
  for _, k in ipairs(LCD_NOOPS) do
    lcd[k] = api(function()
      R.lcdCalls = R.lcdCalls + 1
      if R.widget and R.widget.useLvgl then
        R:warn("lcd." .. k .. " is a no-op in an LVGL widget", "lcdnoop" .. k)
      end
    end)
  end
  env.lcd = lcd

  local bitmap = {}
  bitmap.open = api(function(path)
    local rel = string.gsub(tostring(path), "^/+", "")
    local w, h = pngSize(R.sdRoot .. "/" .. rel)
    return { path = path, w = w or 0, h = h or 0 }
  end)
  bitmap.getSize = api(function(b) if type(b) == "table" then return b.w, b.h end return 0, 0 end)
  bitmap.resize = api(function(b) return b end)
  env.Bitmap = bitmap
  env.bitmap = bitmap

  if not R.opts.noLvgl then env.lvgl = R:_makeLvgl() end

  env._G = env
  setmetatable(env, {
    __newindex = function(t, k, v)
      R.globalWrites[#R.globalWrites + 1] = { name = tostring(k), where = whereCaller(), phase = R.phase }
      rawset(t, k, v)
    end,
  })
  return env
end

---------------------------------------------------------------------------
-- widget lifecycle
---------------------------------------------------------------------------

local function filterTb(tb)
  if not tb then return "" end
  local out = {}
  for line in string.gmatch(tb, "[^\n]+") do
    if string.find(line, "WIDGETS/", 1, true) or string.find(line, "harness_dummy", 1, true) then
      out[#out + 1] = "    " .. string.gsub(line, "^%s+", "")
    end
  end
  return tconcat(out, "\n")
end
M.filterTb = filterTb

-- load main.lua the way EdgeTX registers widgets at radio start
-- dir: "/WIDGETS/FPVDASH/"
function Radio:loadWidget(dir)
  self.widgetPath = dir
  self.phase = "load"
  local chunk, err = self:_loadScriptFile(dir .. "main.lua", "bt")
  if not chunk then
    self.loadError = "cannot load " .. dir .. "main.lua: " .. tostring(err)
    return nil, self.loadError
  end
  self.current = nil
  local n, ok, wt = meteredCall(self.limit, chunk)
  self.loadCount = n
  self.phase = "idle"
  if not ok then
    local m, tb = cwErr(wt)
    self.loadError = "main.lua failed at load: " .. m .. "\n" .. filterTb(tb)
    return nil, self.loadError
  end
  if type(wt) ~= "table" then
    self.loadError = "main.lua did not return a table"
    return nil, self.loadError
  end
  self.widget = wt
  return wt
end

-- option values the firmware passes: BOOL/CHOICE/others unsigned, VALUE signed.
-- stored = nil: a newly added widget (parseOptionDefaults, the declared defaults).
-- stored = n: a model saved with an older widget that stores only options 0..n-1. The
-- layout creates the widget with WidgetFactory::create(init = false): the defaults are
-- not parsed (LuaWidgetFactory::parseOptionDefaults runs only for a new widget or the
-- settings page), and setDefault() resets each missing entry to opt->deflt, which is
-- still 0 (lua_widget_factory.cpp parseOptionDefinitions, widget.cpp setDefault).
function Radio:_defaultOptions(over, stored)
  local o = {}
  local defs = self.widget.options or {}
  for i, d in ipairs(defs) do
    if type(d) == "table" and type(d[1]) == "string" then
      local v = d[3]
      if type(v) == "boolean" then v = v and 1 or 0 end
      if type(v) == "number" then v = math.tointeger(floor(v)) end
      if d[2] == C.STRING or d[2] == C.FILE then v = d[3] or "" end
      if stored ~= nil and i > stored then
        v = (d[2] == C.STRING or d[2] == C.FILE) and "" or 0
      end
      o[d[1]] = v or 0
    end
  end
  for k, v in pairs(over or {}) do o[k] = v end
  return o
end

local function newInstanceTable(R, o)
  R.instSeq = (R.instSeq or 0) + 1
  local w, h = o.w or 480, o.h or 320
  local inst = {
    id = R.instSeq,
    zone = { x = 0, y = 0, w = w, h = h, xabs = o.xabs or 0, yabs = o.yabs or 0 },
    layoutZone = { w = w, h = h, xabs = o.xabs or 0, yabs = o.yabs or 0 },
    appMode = o.appMode or false,
    visible = (o.visible ~= false),
    fullscreen = false,
    frozen = false,
    closeFS = false,
    roots = {}, tree = {}, objects = {},
    popups = {}, popupLog = {},
    events = {},
    instr = { create = {}, update = {}, refresh = {}, background = {}, callback = {} },
    cycleInstr = {},
    refreshedLast = false,
    dead = false,
    clears = 0,
    fullClearsAfterBuild = 0,       -- no-argument lvgl.clear() calls while objects existed
    objClears = 0,                  -- lvgl.clear(obj) calls
    created = 0,                    -- LVGL objects created (each one has a C++ wrapper)
    leaked = 0,                     -- objects whose refs were cleared (wrapper never deleted)
    crsfPush = 0, crsfPushOk = 0, crsfBusy = 0, crsfPop = 0, pushThisCycle = 0, maxPushPerCycle = 0,
    ctrlOutsideFS = 0,
    updates = 0, refreshes = 0, backgrounds = 0,
    inCallback = false,
    clickIssues = {},               -- visible clickable objects seen outside full screen (first ones)
    clickSeen = {},                 -- object id -> true (each object reported once)
    clickCycles = 0,                -- radio cycles that ended with such an object
    touchIssues = {},               -- pressed controls that a finger cannot reach (Radio:press)
    touchSeen = {},                 -- object id -> true (each control reported once)
  }
  return inst
end

-- run one firmware call of a widget function; poll properties afterwards if asked
function Radio:_run(inst, phase, fn, poll, ...)
  if inst.dead then return false end
  if type(fn) ~= "function" then
    if phase == "update" or phase == "refresh" then
      if self.mode == "rc1" and self.widget and self.widget.useLvgl then
        self:_kill(inst, phase, "ERROR in " .. phase .. "(): function not defined (rc1 requires both update and refresh)")
        return false
      end
    end
    return true
  end
  local prevCur, prevPhase = self.current, self.phase
  self.current = inst
  self.phase = phase
  self.callSeq = self.callSeq + 1
  local args = table.pack(...)
  local R = self
  local function body()
    local r = table.pack(fn(tunpack(args, 1, args.n)))
    if poll then
      depth = 1
      hookOff()
      R:_pollInstance(inst)
      depth = 0
      hookOn()
    end
    return tunpack(r, 1, r.n)
  end
  local n, ok, a = meteredCall(self.limit, body)
  self.current = prevCur
  self.phase = prevPhase
  self.lastCount = n
  local list = inst.instr[phase]
  if list then list[#list + 1] = n end
  if not ok then
    local m, tb = cwErr(a)
    self:_kill(inst, phase, m, tb)
    return false
  end
  return true, a
end

function Radio:_kill(inst, phase, msg, tb)
  inst.dead = true
  inst.err = { phase = phase, msg = msg, tb = tb, t = self.clock, cycle = self.cycleNo }
  self.errors[#self.errors + 1] = { inst = inst.id, phase = phase, msg = msg, tb = filterTb(tb), t = self.clock }
end

-- o = { w, h, appMode, visible, options = {...}, storedOptions = n, xabs, yabs }
-- storedOptions = n: an existing model that stores only options 0..n-1 (see _defaultOptions)
function Radio:createInstance(o)
  o = o or {}
  if not self.widget then error("loadWidget first", 2) end
  local inst = newInstanceTable(self, o)
  inst.options = self:_defaultOptions(o.options, o.storedOptions)
  self.instances[#self.instances + 1] = inst
  local ok, ctx = self:_run(inst, "create", self.widget.create, false, inst.zone, inst.options, self.widgetPath)
  inst.ctx = ctx
  if ok and self.widget.useLvgl then
    self:_update(inst, true)
  end
  return inst
end

function Radio:_update(inst, poll)
  inst.updates = inst.updates + 1
  local onScreen = inst.visible or inst.fullscreen
  return self:_run(inst, "update", self.widget.update, poll and onScreen, inst.ctx, inst.options)
end

function Radio:_refresh(inst)
  local evt, touch = nil, nil
  if inst.fullscreen then
    local e = table.remove(inst.events, 1)
    if e then evt, touch = e.evt, e.touch else evt = 0 end
  end
  inst.refreshes = inst.refreshes + 1
  local ok = self:_run(inst, "refresh", self.widget.refresh, self.widget.useLvgl and true or false,
    inst.ctx, evt, touch)
  return ok
end

function Radio:_background(inst)
  inst.backgrounds = inst.backgrounds + 1
  if type(self.widget.background) ~= "function" then return true end
  return self:_run(inst, "background", self.widget.background, false, inst.ctx)
end

function Radio:_controlsPoll(inst)
  if inst.dead then return end
  local has = false
  for _, obj in ipairs(inst.objects) do
    if obj.valid and obj.spec.getPoll and obj.cbs.get then has = true break end
  end
  if not has then return end
  local prev = self.current
  self.current = inst
  local R = self
  local n, ok, e = meteredCall(self.limit, function()
    depth = 1
    hookOff()
    R:_pollControls(inst)
    depth = 0
    hookOn()
  end)
  self.current = prev
  inst.controlsInstr = n
  if not ok then
    local m, tb = cwErr(e)
    self:_kill(inst, "controls", m, tb)
  end
end

function Radio:_setFullscreen(inst, on)
  local z = inst.zone
  if on then
    if inst.fullscreen then return end
    inst.fullscreen = true
    z.w, z.h, z.xabs, z.yabs = self.lcdW, self.lcdH, 0, 0
    inst.events = {}
    -- rc1: update() + poll ; 2.12.x: updateWithoutRefresh()
    self:_update(inst, self.mode == "rc1")
  else
    if not inst.fullscreen then return end
    inst.fullscreen = false
    local lz = inst.layoutZone
    local changed = (z.w ~= lz.w) or (z.h ~= lz.h) or (z.xabs ~= lz.xabs) or (z.yabs ~= lz.yabs)
    z.w, z.h, z.xabs, z.yabs = lz.w, lz.h, lz.xabs, lz.yabs
    if changed then self:_update(inst, self.mode == "rc1") end
    inst.events = {}
    if self.mode == "rc1" then self:_update(inst, true) end
  end
  self:_compact(inst)
end

-- user enters full screen (long press in App mode / widget menu)
function Radio:enterFullScreen(inst)
  if self.widget and self.widget.useLvgl == nil then
    self:warn("full screen entered on a widget without useLvgl")
  end
  self:_setFullscreen(inst, true)
end

-- user long-presses RTN: firmware leaves full screen at once
function Radio:exitFullScreen(inst)
  self:_setFullscreen(inst, false)
end

function Radio:sendEvent(inst, evt, touch)
  if not inst.fullscreen then return false end
  if #inst.events >= 4 then return false end
  inst.events[#inst.events + 1] = { evt = evt, touch = touch }
  return true
end

function Radio:setVisible(inst, on) inst.visible = on and true or false end
function Radio:freeze(inst, on) inst.frozen = on and true or false end

-- widget settings closed with new option values: same table rewritten, then update()
function Radio:setOptions(inst, over)
  for k, v in pairs(over) do inst.options[k] = v end
  self:_update(inst, true)
end

-- zone size change (layout change)
function Radio:setZone(inst, w, h)
  inst.layoutZone.w, inst.layoutZone.h = w, h
  if not inst.fullscreen then
    inst.zone.w, inst.zone.h = w, h
    self:_update(inst, self.mode == "rc1")
  end
end

function Radio:_cycleInstance(inst)
  if inst.dead or inst.frozen then
    inst.refreshedLast = false
    return
  end
  inst.pushThisCycle = 0
  local onScreen = inst.visible or inst.fullscreen
  if self.mode == "rc1" then
    if onScreen then
      self:_controlsPoll(inst)
      if inst.closeFS then
        inst.closeFS = false
        self:_setFullscreen(inst, false)
      end
      if not inst.refreshedLast then self:_background(inst) end
      inst.refreshedLast = false
      if inst.visible or inst.fullscreen then
        self:_refresh(inst)
        inst.refreshedLast = true
      end
    else
      self:_background(inst)
      inst.refreshedLast = false
    end
  else
    if onScreen then
      self:_controlsPoll(inst)
      if inst.closeFS then
        inst.closeFS = false
        self:_setFullscreen(inst, false)
      end
      self:_refresh(inst)
    else
      self:_background(inst)
    end
  end
  if inst.needCompact then
    inst.needCompact = false
    self:_compact(inst)
  end
  if inst.pushThisCycle > inst.maxPushPerCycle then inst.maxPushPerCycle = inst.pushThisCycle end
  if inst.visible and not inst.fullscreen and not inst.dead then self:_checkClickable(inst) end
end

-- Visible objects of the instance that take touches (see obj.clickable in _create).
function Radio:clickables(inst)
  local r = {}
  for _, o in ipairs(inst.objects) do
    if o.clickable and o.valid and not o.deletedLvgl and M.effVisible(o) then r[#r + 1] = o end
  end
  return r
end

-- Outside full screen a visible clickable object takes the touch: the long press that opens
-- full screen (App mode) or the widget menu does not reach the widget any more.
function Radio:_checkClickable(inst)
  local list = self:clickables(inst)
  if #list == 0 then return end
  inst.clickCycles = inst.clickCycles + 1
  for _, o in ipairs(list) do
    if not inst.clickSeen[o.id] and #inst.clickIssues < 10 then
      inst.clickSeen[o.id] = true
      local x, y, w, h = self:absRect(o)
      inst.clickIssues[#inst.clickIssues + 1] = { t = self.clock, cycle = self.cycleNo,
        msg = sformat("%s at %d,%d %dx%d is visible and clickable outside full screen at %.2f s (it takes the "
          .. "long press that opens full screen; boxes made in full screen stay clickable)", objDesc(o), x, y,
          w or 0, h or 0, self.clock / 1000) }
    end
  end
end

-- an instance covered by another instance that is full screen:
-- rc1 walks only the top opaque layer (the full-screen widget), so the covered
-- instance gets no call at all; 2.12.x calls background() (inForeground false)
function Radio:_coveredInstance(inst)
  if inst.dead or inst.frozen then
    inst.refreshedLast = false
    return
  end
  inst.pushThisCycle = 0
  inst.coveredCycles = (inst.coveredCycles or 0) + 1
  if self.mode ~= "rc1" then self:_background(inst) end
  inst.refreshedLast = false
  if inst.needCompact then
    inst.needCompact = false
    self:_compact(inst)
  end
end

-- advance n cycles of 50 ms; stop early when stopFn() returns true
function Radio:cycle(n, stopFn)
  n = n or 1
  for i = 1, n do
    self.clock = self.clock + self.cycleMs
    self.cycleNo = self.cycleNo + 1
    self:_crsfDeliver()
    local fsInst = nil
    for _, inst in ipairs(self.instances) do
      if inst.fullscreen then fsInst = inst end
    end
    for _, inst in ipairs(self.instances) do
      if fsInst and inst ~= fsInst then self:_coveredInstance(inst) else self:_cycleInstance(inst) end
    end
    self:_crsfFlush()
    self:_mdSettle()
    if stopFn and stopFn() then return true, i end
  end
  return false, n
end

-- run until stopFn() is true or maxMs elapsed; returns ok, elapsed ms
function Radio:runUntil(maxMs, stopFn)
  local start = self.clock
  local cycles = floor(maxMs / self.cycleMs)
  local hit = self:cycle(cycles, stopFn)
  return hit, self.clock - start
end

---------------------------------------------------------------------------
-- instruction statistics
---------------------------------------------------------------------------

local function statsOf(list, from)
  from = from or 1
  local n, sum, max = 0, 0, 0
  for i = from, #list do
    local v = list[i]
    n = n + 1
    sum = sum + v
    if v > max then max = v end
  end
  return { n = n, max = max, avg = (n > 0) and (sum / n) or 0 }
end
M.statsOf = statsOf

function Radio:instrStats(inst, phase, from)
  return statsOf(inst.instr[phase] or {}, from)
end

---------------------------------------------------------------------------
-- UI inspection helpers for tests
---------------------------------------------------------------------------

-- effective visibility: object and all its LVGL ancestors shown, object alive
local function effVisible(obj)
  local o = obj
  while o do
    if not o.valid or not o.shown or o.deletedLvgl then return false end
    o = o.parent
  end
  return true
end
M.effVisible = effVisible

-- geometry of an object relative to its LVGL parent
function Radio:_relRect(obj)
  local p = obj.props
  local k = obj.kind
  local x, y = p.x or 0, p.y or 0
  local w, h = p.w, p.h
  local parentW, parentH
  if obj.parent then
    local _, _, pw, ph = self:_relRect(obj.parent)
    parentW, parentH = pw, ph
  else
    parentW, parentH = obj.inst.zone.w, obj.inst.zone.h
  end
  local function pct(v, ref)
    if v and v >= LV_PCT0 and v < LV_PCT0 + 1001 then return floor(ref * (v - LV_PCT0) / 100) end
    return v
  end
  w, h = pct(w, parentW), pct(h, parentH)
  if k == "circle" or k == "arc" then
    local r = p.radius or 0
    return x - r, y - r, 2 * r, 2 * r
  elseif k == "hline" then
    return x, y, w or 0, math.max(1, math.abs(h or 1))
  elseif k == "vline" then
    return x, y, math.max(1, math.abs(w or 1)), h or 0
  elseif k == "line" or k == "triangle" then
    local pts = p.pts
    if type(pts) ~= "table" or #pts == 0 then return x, y, 0, 0 end
    local x1, y1, x2, y2 = 1e9, 1e9, -1e9, -1e9
    for _, pt in ipairs(pts) do
      if type(pt) == "table" and type(pt[1]) == "number" and type(pt[2]) == "number" then
        if pt[1] < x1 then x1 = pt[1] end
        if pt[2] < y1 then y1 = pt[2] end
        if pt[1] > x2 then x2 = pt[1] end
        if pt[2] > y2 then y2 = pt[2] end
      end
    end
    if x1 > x2 then return x, y, 0, 0 end
    return x1, y1, x2 - x1, y2 - y1
  elseif k == "label" then
    local tw, lines, lh = measure(p.text or "", p.font or 0)
    local lw = w or tw
    if w and w > 0 and tw > w then lines = lines + floor((tw - 1) / w) end
    local lhh = h or lh * lines
    local al = p.align or 0
    if (al % 4) >= 2 then
      -- VCENTER: rc1 aligns the label box to the left-middle of the parent, x/y reset
      if self.mode == "rc1" then
        return 0, floor((parentH - lhh) / 2), lw, lhh
      end
      return x, floor((parentH - lhh) / 2) + y, lw, lhh
    end
    return x, y, lw, lhh
  elseif k == "button" or k == "momentaryButton" then
    local tw = measure(p.text or "", p.font or 0)
    return x, y, (w and w > 0) and w or (tw + 16), (h and h > 0) and h or 32
  elseif k == "toggle" then
    return x, y, 52, 32
  elseif k == "choice" or k == "numberEdit" or k == "textEdit" or k == "slider" then
    return x, y, (w and w > 0) and w or 100, (h and h > 0) and h or 32
  elseif k == "page" then
    return 0, 0, self.lcdW, self.lcdH
  end
  return x, y, w or 0, h or 0
end

function Radio:absRect(obj)
  local x, y, w, h = self:_relRect(obj)
  local p = obj.parent
  while p do
    local px, py = self:_relRect(p)
    x, y = x + px, y + py
    p = p.parent
  end
  return x, y, w, h
end

-- text ink box of a label (absolute): glyph height, not the full line height
function Radio:labelInk(obj)
  local x, y = self:absRect(obj)
  local p = obj.props
  local tw, lines, lh, px = measure(p.text or "", p.font or 0)
  local ink = tw
  if p.w and p.w > 0 and tw > p.w then ink = p.w; lines = lines + floor((tw - 1) / p.w) end
  local al = p.align or 0
  local ix = x
  if p.w and p.w > 0 then
    if (al % 16) >= 8 then ix = x + p.w - ink
    elseif (al % 8) >= 4 then ix = x + floor((p.w - ink) / 2) end
  end
  local top = floor((lh - px) / 2)
  return ix, y + top, ink, lh * (lines - 1) + px
end

-- list of live objects (optionally effectively visible only)
function Radio:objects(inst, kind, visibleOnly)
  local r = {}
  for _, o in ipairs(inst.objects) do
    if o.valid and not o.deletedLvgl and (kind == nil or o.kind == kind) then
      if not visibleOnly or effVisible(o) then r[#r + 1] = o end
    end
  end
  return r
end

-- visible label texts
function Radio:texts(inst, includeButtons)
  local r = {}
  for _, o in ipairs(self:objects(inst, nil, true)) do
    if o.kind == "label" or (includeButtons and (o.kind == "button" or o.kind == "momentaryButton")) then
      r[#r + 1] = o.props.text or ""
    end
  end
  return r
end

-- first visible label/button whose text matches the Lua pattern
function Radio:findText(inst, pattern, includeButtons)
  for _, o in ipairs(self:objects(inst, nil, true)) do
    if o.kind == "label" or (includeButtons and (o.kind == "button" or o.kind == "momentaryButton")) then
      local t = o.props.text or ""
      if string.find(t, pattern) then return o, t end
    end
  end
  return nil
end

function Radio:buttons(inst, visibleOnly)
  local r = {}
  for _, o in ipairs(self:objects(inst, nil, visibleOnly ~= false)) do
    if o.kind == "button" or o.kind == "momentaryButton" then r[#r + 1] = o end
  end
  return r
end

-- find a button: pattern (Lua pattern on the text) or predicate function(text, obj)
function Radio:findButton(inst, pat)
  for _, o in ipairs(self:buttons(inst, true)) do
    local t = o.props.text or ""
    if type(pat) == "function" then
      if pat(t, o) then return o end
    elseif string.find(t, pat) then
      return o
    end
  end
  return nil
end

-- run a widget callback with the instance as current context (LVGL event)
function Radio:_callback(inst, what, fn, ...)
  if inst.dead then return false, "instance is dead" end
  local prev = self.current
  self.current = inst
  inst.inCallback = true
  local prevPhase = self.phase
  self.phase = "callback"
  self.callSeq = self.callSeq + 1
  local n, ok, r = meteredCall(self.limit, fn, ...)
  self.phase = prevPhase
  inst.inCallback = false
  self.current = prev
  local list = inst.instr.callback
  list[#list + 1] = n
  if not ok then
    local m, tb = cwErr(r)
    self:_kill(inst, "callback " .. what, m, tb)
    return false, m
  end
  return true, r
end

-- Touch hit test in the LVGL 8 order (lv_indev_search_obj): a hidden object hides its
-- children; the children of an object that contains the point are searched from the last
-- one (drawn on top) to the first; when no child takes the point, the object takes it if it
-- is clickable and not disabled. The roots of the widget are searched the same way. Returns
-- the object that gets the tap at the absolute point x, y, or nil (the widget gets it).
local function hitSearch(R, obj, x, y)
  if not obj.valid or obj.deletedLvgl or not obj.shown then return nil end
  local ax, ay, w, h = R:absRect(obj)
  local inside = w ~= nil and h ~= nil and x >= ax and x < ax + w and y >= ay and y < ay + h
  if not inside then return nil end
  local ch = obj.children
  for i = #ch, 1, -1 do
    local f = hitSearch(R, ch[i], x, y)
    if f then return f end
  end
  if obj.clickable and obj.enabled ~= false then return obj end
  return nil
end

function Radio:hitTest(inst, x, y)
  local tree = inst.tree
  for i = #tree, 1, -1 do
    local f = hitSearch(self, tree[i], x, y)
    if f then return f end
  end
  return nil
end

-- the centre of an object (absolute)
function Radio:centre(obj)
  local x, y, w, h = self:absRect(obj)
  return x + floor((w or 0) / 2), y + floor((h or 0) / 2)
end

-- Visible, enabled controls whose centre a finger cannot reach: another object above it
-- takes the tap. Returns a list of { obj, hit, msg }.
function Radio:touchProblems(inst)
  local r = {}
  for _, o in ipairs(self:objects(inst, nil, true)) do
    if o.spec.control and o.enabled ~= false and o.kind ~= "page" and o.kind ~= "dialog"
       and o.kind ~= "setting" then
      local cx, cy = self:centre(o)
      local hit = self:hitTest(inst, cx, cy)
      if hit ~= o then
        r[#r + 1] = { obj = o, hit = hit, msg = sformat("%s %q at %d,%d cannot be tapped: the tap goes to %s",
          objDesc(o), tostring(o.props.text or ""), cx, cy, hit and objDesc(hit) or "the widget") }
      end
    end
  end
  return r
end

-- press (click) a button object; returns true or false, reason
-- A press that a finger could not make (another object above the centre of the button
-- takes the tap) is recorded in inst.touchIssues; the scenarios fail on it.
function Radio:press(inst, obj, long)
  if not obj then return false, "no button" end
  if not obj.valid then return false, "button was cleared" end
  if not effVisible(obj) then return false, "button is hidden" end
  if not obj.enabled then return false, "button is disabled" end
  do
    local cx, cy = self:centre(obj)
    local hit = self:hitTest(inst, cx, cy)
    if hit ~= obj and not inst.touchSeen[obj.id] then
      inst.touchSeen[obj.id] = true
      local list = inst.touchIssues
      if #list < 10 then
        list[#list + 1] = { t = self.clock, msg = sformat("%s %q at %d,%d was pressed, but a tap there goes to %s "
          .. "(an object above it takes the touch)", objDesc(obj), tostring(obj.props.text or ""), cx, cy,
          hit and objDesc(hit) or "the widget") }
      end
    end
  end
  local fn = long and obj.cbs.longpress or obj.cbs.press
  if not fn then return false, "button has no press callback" end
  local ok, r = self:_callback(inst, "press", fn)
  if not ok then return false, r end
  if r ~= nil and type(r) ~= "number" and type(r) ~= "boolean" then
    if type(r) ~= "string" or tonumber(r) == nil then
      self:_kill(inst, "callback press", "press() returned a " .. type(r) .. " (nil/number/boolean expected)")
      return false, "bad return value"
    end
  end
  if obj.kind == "momentaryButton" and obj.cbs.release then
    self:_callback(inst, "release", obj.cbs.release)
  end
  obj.props.checked = (r == true) or (type(r) == "number" and r ~= 0)
  self.presses = (self.presses or 0) + 1
  return true
end

-- edit a numberEdit like the user does: the value is kept in min..max (the firmware's
-- NumberEdit limits), set(value) runs, then the firmware reads get() again
function Radio:editNumber(inst, obj, value)
  if not obj or obj.kind ~= "numberEdit" then return false, "no number input" end
  if not obj.valid then return false, "number input was cleared" end
  if not effVisible(obj) then return false, "number input is hidden" end
  if not obj.enabled then return false, "number input is disabled" end
  local lo, hi = obj.props.min, obj.props.max
  if lo and value < lo then value = lo end
  if hi and value > hi then value = hi end
  if not obj.cbs.set then return false, "number input has no set callback" end
  local ok, r = self:_callback(inst, "numberEdit set", obj.cbs.set, math.tointeger(value) or value)
  if not ok then return false, r end
  if obj.cbs.get then
    local ok2, v = self:_callback(inst, "numberEdit get", obj.cbs.get)
    if not ok2 then return false, v end
    if type(v) ~= "number" then
      self:_kill(inst, "callback numberEdit get", "numberEdit get() returned " .. type(v) .. " (number expected)")
      return false, "bad get value"
    end
    obj.lastGet = v
  end
  return true
end

function Radio:openPopup(inst)
  return inst.popups[#inst.popups]
end

-- answer the newest popup: confirm (true/false), menu (index or label), message (any)
function Radio:answerPopup(inst, answer)
  local p = table.remove(inst.popups)
  if not p then return false, "no popup open" end
  if p.kind == "confirm" then
    local fn = answer and p.cbs.confirm or p.cbs.cancel
    if fn then return self:_callback(inst, "confirm", fn) end
    return true
  elseif p.kind == "menu" then
    if answer == nil or answer == false then return true end
    local idx = answer
    if type(answer) == "string" then
      idx = nil
      for i, v in ipairs(p.values or {}) do if v == answer then idx = i end end
      if not idx then return false, "menu has no entry " .. answer end
    end
    if p.cbs.set then return self:_callback(inst, "menu set", p.cbs.set, idx) end
    return true
  end
  return true
end

-- accessor: the per-instance app table with V/E/S/I fields
function M.appOf(ctx)
  if type(ctx) ~= "table" then return nil end
  if ctx.V ~= nil or ctx.E ~= nil or ctx.S ~= nil then return ctx end
  for _, k in ipairs({ "app", "wgt", "w", "inst", "state", "ctx" }) do
    local t = rawget(ctx, k)
    if type(t) == "table" and (t.V ~= nil or t.E ~= nil or t.S ~= nil) then return t end
  end
  for _, t in pairs(ctx) do
    if type(t) == "table" and (rawget(t, "V") ~= nil and rawget(t, "E") ~= nil) then return t end
  end
  return nil
end

function Radio:app(inst) return M.appOf(inst.ctx) end

---------------------------------------------------------------------------
-- layout dump (SVG, text, JSON) and overlap checks
---------------------------------------------------------------------------

local imgCache = {}
function Radio:_imgData(file)
  local rel = string.gsub(file, "^/+", "")
  local full = self.sdRoot .. "/" .. rel
  if imgCache[full] == nil then
    local d = readFile(full)
    imgCache[full] = d and base64(d) or false
  end
  return imgCache[full] or nil
end

function Radio:_svgObj(out, obj)
  if not obj.valid or obj.deletedLvgl or not obj.shown then return end
  local p = obj.props
  local x, y, w, h = self:absRect(obj)
  local k = obj.kind
  local col = colorHex(p.color)
  local opa = (p.opacity or 255) / 255
  local title = sformat("<title>%s#%d %s</title>", k, obj.id, xmlEsc(obj.createdAt or ""))
  if k == "rectangle" then
    local rx = p.rounded or 0
    if p.filled then
      out[#out + 1] = sformat("<rect x='%d' y='%d' width='%d' height='%d' rx='%d' fill='%s' fill-opacity='%.2f'>%s</rect>",
        x, y, math.max(w or 0, 0), math.max(h or 0, 0), rx, col, opa, title)
    else
      local t = p.thickness or 1
      out[#out + 1] = sformat("<rect x='%.1f' y='%.1f' width='%d' height='%d' rx='%d' fill='none' stroke='%s' stroke-width='%d' stroke-opacity='%.2f'>%s</rect>",
        x + t / 2, y + t / 2, math.max((w or 0) - t, 0), math.max((h or 0) - t, 0), rx, col, t, opa, title)
    end
  elseif k == "circle" then
    local r = p.radius or 0
    if p.filled then
      out[#out + 1] = sformat("<circle cx='%d' cy='%d' r='%d' fill='%s' fill-opacity='%.2f'>%s</circle>", x + r, y + r, r, col, opa, title)
    else
      out[#out + 1] = sformat("<circle cx='%d' cy='%d' r='%d' fill='none' stroke='%s' stroke-width='%d'>%s</circle>",
        x + r, y + r, r, col, p.thickness or 1, title)
    end
  elseif k == "arc" then
    local r = p.radius or 0
    local a1, a2 = math.rad(p.startAngle or 0), math.rad(p.endAngle or 360)
    local cx, cy = x + r, y + r
    local rr = r - (p.thickness or 1) / 2
    local large = (((p.endAngle or 360) - (p.startAngle or 0)) % 360 > 180) and 1 or 0
    out[#out + 1] = sformat("<path d='M %.1f %.1f A %.1f %.1f 0 %d 1 %.1f %.1f' fill='none' stroke='%s' stroke-width='%d' stroke-opacity='%.2f'>%s</path>",
      cx + rr * math.cos(a1), cy + rr * math.sin(a1), rr, rr, large, cx + rr * math.cos(a2), cy + rr * math.sin(a2),
      col, p.thickness or 1, opa, title)
  elseif k == "hline" then
    local t = math.max(1, math.abs(p.h or 1))
    out[#out + 1] = sformat("<line x1='%d' y1='%.1f' x2='%d' y2='%.1f' stroke='%s' stroke-width='%d' stroke-opacity='%.2f'>%s</line>",
      x, y + t / 2, x + (p.w or 0), y + t / 2, col, t, opa, title)
  elseif k == "vline" then
    local t = math.max(1, math.abs(p.w or 1))
    out[#out + 1] = sformat("<line x1='%.1f' y1='%d' x2='%.1f' y2='%d' stroke='%s' stroke-width='%d' stroke-opacity='%.2f'>%s</line>",
      x + t / 2, y, x + t / 2, y + (p.h or 0), col, t, opa, title)
  elseif k == "line" or k == "triangle" then
    local pts = {}
    local ox, oy = 0, 0
    if obj.parent then ox, oy = self:absRect(obj.parent) end
    for _, pt in ipairs(type(p.pts) == "table" and p.pts or {}) do
      if type(pt) == "table" then pts[#pts + 1] = sformat("%d,%d", (pt[1] or 0) + ox, (pt[2] or 0) + oy) end
    end
    if k == "line" then
      out[#out + 1] = sformat("<polyline points='%s' fill='none' stroke='%s' stroke-width='%d'>%s</polyline>",
        tconcat(pts, " "), col, p.thickness or 1, title)
    else
      out[#out + 1] = sformat("<polygon points='%s' fill='%s' fill-opacity='%.2f'>%s</polygon>", tconcat(pts, " "), col, opa, title)
    end
  elseif k == "image" then
    local data = p.file and self:_imgData(p.file)
    if data then
      out[#out + 1] = sformat("<image x='%d' y='%d' width='%d' height='%d' preserveAspectRatio='xMidYMid meet' href='data:image/png;base64,%s'>%s</image>",
        x, y, w or 0, h or 0, data, title)
    else
      out[#out + 1] = sformat("<rect x='%d' y='%d' width='%d' height='%d' fill='none' stroke='#ff00ff' stroke-dasharray='2,2'>%s</rect>",
        x, y, w or 0, h or 0, title)
      out[#out + 1] = sformat("<text x='%d' y='%d' font-size='6' fill='#ff00ff'>%s</text>", x + 1, y + 7,
        xmlEsc(string.match(tostring(p.file), "([^/]*)$") or "?"))
    end
  elseif k == "label" then
    local fi = fontIndex(p.font or 0)
    local px, lh = FONTS[fi][1], FONTS[fi][2]
    local bold = (fi == 1 or fi >= 5) and " font-weight='bold'" or ""
    local anchor, tx = "start", x
    local al = p.align or 0
    if p.w and p.w > 0 then
      if (al % 16) >= 8 then anchor, tx = "end", x + p.w
      elseif (al % 8) >= 4 then anchor, tx = "middle", x + floor(p.w / 2) end
    end
    local ly = y
    for line in string.gmatch((p.text or "") .. "\n", "([^\n]*)\n") do
      out[#out + 1] = sformat("<text x='%d' y='%.1f' font-family='Roboto,Arial,Helvetica,sans-serif' font-size='%d'%s fill='%s' text-anchor='%s' xml:space='preserve'>%s%s</text>",
        tx, ly + (lh - px) / 2 + px * 0.8, px, bold, col, anchor, xmlEsc(line), title)
      ly = ly + lh
    end
  elseif k == "button" or k == "momentaryButton" then
    local bg = p.color and colorHex(p.color) or "#505458"
    local stroke = p.checked and "#f03c38" or "#202020"
    if not obj.enabled then bg = "#303030" end
    out[#out + 1] = sformat("<rect x='%d' y='%d' width='%d' height='%d' rx='%d' fill='%s' stroke='%s'>%s</rect>",
      x, y, w, h, p.cornerRadius or 6, bg, stroke, title)
    local fi = fontIndex(p.font or 0)
    local px, lh = FONTS[fi][1], FONTS[fi][2]
    local lines = {}
    for line in string.gmatch((p.text or "") .. "\n", "([^\n]*)\n") do lines[#lines + 1] = line end
    local ty = y + floor((h - lh * #lines) / 2)
    local tcol = p.textColor and colorHex(p.textColor) or "#ffffff"
    for _, line in ipairs(lines) do
      out[#out + 1] = sformat("<text x='%d' y='%.1f' font-family='Roboto,Arial,Helvetica,sans-serif' font-size='%d' fill='%s' text-anchor='middle'>%s</text>",
        x + floor(w / 2), ty + (lh - px) / 2 + px * 0.8, px, tcol, xmlEsc(line))
      ty = ty + lh
    end
  elseif k == "box" then
    if self.svgShowBoxes then
      out[#out + 1] = sformat("<rect x='%d' y='%d' width='%d' height='%d' fill='none' stroke='#00ffff' stroke-opacity='0.3' stroke-dasharray='1,2'>%s</rect>",
        x, y, w or 0, h or 0, title)
    end
  elseif obj.spec.control then
    out[#out + 1] = sformat("<rect x='%d' y='%d' width='%d' height='%d' rx='4' fill='#404040' stroke='#a0a0a0'>%s</rect>",
      x, y, w or 0, h or 0, title)
    out[#out + 1] = sformat("<text x='%d' y='%d' font-size='10' fill='#ffffff'>%s</text>", x + 4, y + 14, k)
  end
  for _, c in ipairs(obj.children) do self:_svgObj(out, c) end
end

function Radio:svg(inst, title)
  local z = inst.zone
  local out = {}
  out[#out + 1] = sformat("<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 %d %d'>",
    z.w * 2, z.h * 2, z.w, z.h)
  out[#out + 1] = sformat("<title>%s</title>", xmlEsc(title or ""))
  out[#out + 1] = "<defs><linearGradient id='wall' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='#3b5068'/>"
    .. "<stop offset='1' stop-color='#6b5a48'/></linearGradient></defs>"
  out[#out + 1] = sformat("<rect x='0' y='0' width='%d' height='%d' fill='url(#wall)'/>", z.w, z.h)
  for _, o in ipairs(inst.tree) do self:_svgObj(out, o) end
  if #inst.popups > 0 then
    local p = inst.popups[#inst.popups]
    out[#out + 1] = sformat("<rect x='40' y='60' width='%d' height='120' fill='#202020' stroke='#f03c38'/>", z.w - 80)
    out[#out + 1] = sformat("<text x='50' y='85' font-size='16' fill='#ffffff'>%s: %s</text>", p.kind, xmlEsc(p.title))
    out[#out + 1] = sformat("<text x='50' y='110' font-size='13' fill='#e0e0e0'>%s</text>", xmlEsc(p.message or ""))
  end
  out[#out + 1] = "</svg>"
  return tconcat(out, "\n")
end

function Radio:_textTree(lines, obj, ind)
  local p = obj.props
  local x, y, w, h = self:absRect(obj)
  local flags = {}
  if not obj.shown then flags[#flags + 1] = "HIDDEN" end
  if not obj.enabled then flags[#flags + 1] = "DISABLED" end
  local fnames = {}
  for k in pairs(obj.fns) do fnames[#fnames + 1] = k end
  table.sort(fnames)
  local extra = ""
  if p.text then extra = extra .. sformat(" text=%q", p.text) end
  if p.font and obj.kind == "label" then extra = extra .. " font=" .. FONTS[fontIndex(p.font)][4] end
  if p.color then extra = extra .. " color=" .. colorName(p.color) end
  if p.opacity and p.opacity ~= 255 then extra = extra .. " opa=" .. p.opacity end
  if p.filled ~= nil and obj.kind ~= "label" then extra = extra .. " filled=" .. tostring(p.filled) end
  if p.file then extra = extra .. " file=" .. p.file end
  lines[#lines + 1] = sformat("%s%s#%d [%d,%d %dx%d]%s%s%s  @%s", ind, obj.kind, obj.id, x, y, w or 0, h or 0, extra,
    #fnames > 0 and (" fn{" .. tconcat(fnames, ",") .. "}") or "",
    #flags > 0 and (" " .. tconcat(flags, " ")) or "", obj.createdAt or "?")
  for _, c in ipairs(obj.children) do
    if c.valid and not c.deletedLvgl then self:_textTree(lines, c, ind .. "  ") end
  end
end

function Radio:textTree(inst)
  local lines = {}
  lines[#lines + 1] = sformat("instance #%d zone %dx%d fullscreen=%s appMode=%s objects=%d", inst.id, inst.zone.w,
    inst.zone.h, tostring(inst.fullscreen), tostring(inst.appMode), #inst.objects)
  for _, o in ipairs(inst.tree) do
    if o.valid and not o.deletedLvgl then self:_textTree(lines, o, "  ") end
  end
  return tconcat(lines, "\n")
end

function Radio:_jsonObj(obj)
  local x, y, w, h = self:absRect(obj)
  local props = {}
  for k, v in pairs(obj.props) do
    if type(v) ~= "table" and type(v) ~= "function" then props[k] = v end
  end
  local fns = {}
  for k in pairs(obj.fns) do fns[#fns + 1] = k end
  table.sort(fns)
  local kids = {}
  for _, c in ipairs(obj.children) do
    if c.valid and not c.deletedLvgl then kids[#kids + 1] = self:_jsonObj(c) end
  end
  return { kind = obj.kind, id = obj.id, abs = { x, y, w or 0, h or 0 }, shown = obj.shown, enabled = obj.enabled,
           props = props, functions = fns, createdAt = obj.createdAt, children = kids }
end

function Radio:jsonTree(inst)
  local roots = {}
  for _, o in ipairs(inst.tree) do
    if o.valid and not o.deletedLvgl then roots[#roots + 1] = self:_jsonObj(o) end
  end
  return jsonEnc({ zone = { w = inst.zone.w, h = inst.zone.h }, fullscreen = inst.fullscreen, objects = roots })
end

-- write tests/out/<name>.svg, .txt, .json ; returns the svg path
function Radio:dump(inst, name, outDir)
  outDir = outDir or M.OUT_DIR
  os.execute("mkdir -p '" .. outDir .. "'")
  local base = outDir .. "/" .. name
  writeFile(base .. ".svg", self:svg(inst, name))
  writeFile(base .. ".txt", self:textTree(inst))
  writeFile(base .. ".json", self:jsonTree(inst))
  return base .. ".svg"
end

local function interArea(ax, ay, aw, ah, bx, by, bw, bh)
  local x1, y1 = math.max(ax, bx), math.max(ay, by)
  local x2, y2 = math.min(ax + aw, bx + bw), math.min(ay + ah, by + bh)
  if x2 <= x1 or y2 <= y1 then return 0 end
  return (x2 - x1) * (y2 - y1)
end

-- clip rectangle of an object (intersection of its ancestors and the zone)
function Radio:_clipOf(obj)
  local cx, cy, cw, ch = 0, 0, obj.inst.zone.w, obj.inst.zone.h
  local p = obj.parent
  while p do
    local px, py, pw, ph = self:absRect(p)
    local x1, y1 = math.max(cx, px), math.max(cy, py)
    local x2, y2 = math.min(cx + cw, px + (pw or 0)), math.min(cy + ch, py + (ph or 0))
    cx, cy, cw, ch = x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1)
    p = p.parent
  end
  return cx, cy, cw, ch
end

-- returns list of { severe = bool, msg = string }
function Radio:layoutCheck(inst)
  local res = {}
  local labels, images, buttons = {}, {}, {}
  for _, o in ipairs(self:objects(inst, nil, true)) do
    if o.kind == "label" and (o.props.text or "") ~= "" and string.find(o.props.text, "%S") then
      local x, y, w, h = self:labelInk(o)
      labels[#labels + 1] = { o = o, x = x, y = y, w = w, h = h, t = o.props.text }
    elseif o.kind == "image" then
      local x, y, w, h = self:absRect(o)
      images[#images + 1] = { o = o, x = x, y = y, w = w or 0, h = h or 0 }
    elseif o.kind == "button" or o.kind == "momentaryButton" then
      local bx, by, bw, bh = self:absRect(o)
      buttons[#buttons + 1] = { o = o, x = bx, y = by, w = bw, h = bh, t = o.props.text or "" }
      local tw, lines, lh = measure(o.props.text or "", o.props.font or 0)
      if tw > bw - 4 then
        res[#res + 1] = { severe = tw > bw + 8, msg = sformat("button text %q (%d px) wider than the button (%d px) [%s]",
          o.props.text or "", tw, bw, o.createdAt) }
      end
      if lines * lh > bh then
        res[#res + 1] = { severe = false, msg = sformat("button text %q (%d lines) taller than the button (%d px) [%s]",
          o.props.text or "", lines, bh, o.createdAt) }
      end
    end
  end
  for _, L in ipairs(labels) do
    local cx, cy, cw, ch = self:_clipOf(L.o)
    local area = math.max(1, L.w * L.h)
    local outside = area - interArea(L.x, L.y, L.w, L.h, cx, cy, cw, ch)
    if outside > 0 then
      res[#res + 1] = { severe = (outside / area) > 0.5, msg = sformat("label %q is clipped: %d%% of its text is outside its parent/zone [%s]",
        L.t, floor(100 * outside / area + 0.5), L.o.createdAt) }
    end
  end
  -- a shadow is a label drawn before a twin with the same text at +-2 px
  for i = 1, #labels do
    for j = i + 1, #labels do
      local a, b = labels[i], labels[j]
      if a.t == b.t and math.abs(a.x - b.x) <= 2 and math.abs(a.y - b.y) <= 2 then a.shadow = true end
    end
  end
  for i = 1, #labels do
    for j = i + 1, #labels do
      local a, b = labels[i], labels[j]
      if not a.shadow and not b.shadow then
        local ia = interArea(a.x, a.y, a.w, a.h, b.x, b.y, b.w, b.h)
        if ia > 0 then
          local small = math.max(1, math.min(a.w * a.h, b.w * b.h))
          res[#res + 1] = { severe = ia / small > 0.4, msg = sformat("labels %q and %q overlap (%d px2, %d%% of the smaller) [%s | %s]",
            a.t, b.t, ia, floor(100 * ia / small + 0.5), a.o.createdAt, b.o.createdAt) }
        end
      end
    end
  end
  for _, L in ipairs(labels) do
    for _, I in ipairs(L.shadow and {} or images) do
      local ia = interArea(L.x, L.y, L.w, L.h, I.x, I.y, I.w, I.h)
      if ia > 0 then
        local frac = ia / math.max(1, L.w * L.h)
        if frac > 0.15 then
          res[#res + 1] = { severe = frac > 0.5, msg = sformat("label %q overlaps image %s (%d%% of the text box) [%s]",
            L.t, string.match(tostring(I.o.props.file), "([^/]*)$") or "?", floor(100 * frac + 0.5), L.o.createdAt) }
        end
      end
    end
  end
  -- a label under a button is hidden by it; buttons must not cover each other
  for _, L in ipairs(labels) do
    for _, B in ipairs(buttons) do
      local ia = interArea(L.x, L.y, L.w, L.h, B.x, B.y, B.w, B.h)
      if ia > 0 then
        local frac = ia / math.max(1, L.w * L.h)
        res[#res + 1] = { severe = frac > 0.2, msg = sformat("label %q overlaps button %q (%d%% of the text box) [%s | %s]",
          L.t, B.t, floor(100 * frac + 0.5), L.o.createdAt, B.o.createdAt) }
      end
    end
  end
  for i = 1, #buttons do
    for j = i + 1, #buttons do
      local a, b = buttons[i], buttons[j]
      local ia = interArea(a.x, a.y, a.w, a.h, b.x, b.y, b.w, b.h)
      if ia > 0 then
        res[#res + 1] = { severe = true, msg = sformat("buttons %q and %q overlap (%d px2) [%s | %s]",
          a.t, b.t, ia, a.o.createdAt, b.o.createdAt) }
      end
    end
  end
  return res
end

-- forget everything the module produced so far (fresh run)
function Radio:crsfLog()
  local m = self.crsf.module
  return m and m:logText() or ""
end

return M
