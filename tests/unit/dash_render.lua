-- Renders the mock dashboard to SVG files for a visual check (desktop Lua 5.5).
-- Usage (from the project root):  lua tests/unit/dash_render.lua <out dir>

local ROOT = (arg and arg[0] and string.match(arg[0], "^(.*)/tests/unit/[^/]*$")) or "."
package.path = ROOT .. "/tests/unit/?.lua;" .. package.path
local OUT = arg[1]
if OUT == nil then
  print("usage: lua tests/unit/dash_render.lua <out dir>")
  return
end

local mock = require("dash_mock")
local SD = ROOT .. "/radio sd card"
mock.install(SD)
local WD = SD .. "/WIDGETS/FPVDASH/"
local theme = dofile(WD .. "ui/theme.lua")
local layout = dofile(WD .. "ui/layout.lua")
local dash = dofile(WD .. "ui/dash.lua")

local HEX = {
  WHITE = "#ffffff", BLACK = "#000000", RED = "#e5201e", GREEN = "#19c832", YELLOW = "#f0d010",
  GREY = "#404040", DARKGREY = "#606060", LIGHTGREY = "#c0c0c0", COLOR_THEME_FOCUS = "#f03c38",
  COLOR_THEME_ACTIVE = "#ffa000",
}
-- named constant (EdgeTX 2.12 draw values: GREY #404040, DARKGREY #606060) or lcd.RGB value
local function hex(c)
  for n, v in pairs(mock.COLOR) do
    if v == c then return HEX[n] or "#ff00ff" end
  end
  if type(c) == "number" and c % 0x10000 == 0x8000 then
    local v = c // 0x10000
    local r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
    return string.format("#%02x%02x%02x", r * 8, g * 4, b * 8)
  end
  return "#ff00ff"
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = string.byte(data, i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local s = {}
    for k = 3, 0, -1 do
      local idx = (n >> (6 * k)) & 63
      s[#s + 1] = string.sub(B64, idx + 1, idx + 1)
    end
    if not b then s[3], s[4] = "=", "=" elseif not c then s[4] = "=" end
    out[#out + 1] = table.concat(s)
  end
  return table.concat(out)
end
local imgCache = {}
local function dataUri(file)
  if not imgCache[file] then
    local f = assert(io.open(SD .. "/" .. file, "rb"))
    imgCache[file] = "data:image/png;base64," .. b64(f:read("a"))
    f:close()
  end
  return imgCache[file]
end

local FONT_PX = { [0] = { 16, "normal" }, [1] = { 16, "bold" }, [2] = { 9, "normal" }, [3] = { 13, "normal" },
                  [4] = { 24, "normal" }, [5] = { 32, "bold" } }

local function esc(s)
  return (string.gsub(s, "[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }))
end

local function svg(w, h, path)
  local o = {}
  local side = math.max(w, h)          -- square canvas (Quick Look thumbnails are square)
  o[#o + 1] = string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">',
                            side * 2, side * 2, side, side)
  o[#o + 1] = string.format('<rect x="0" y="0" width="%d" height="%d" fill="#ffffff"/>', side, side)
  o[#o + 1] = string.format('<rect x="0" y="0" width="%d" height="%d" fill="#3a4a5a"/>', w, h)
  local function draw(ob)
    if not ob.avis then return end
    local k = ob.kind
    if k == "rectangle" then
      local op = (ob.p.opacity or 255) / 255
      local rx = ob.p.rounded or 0
      if ob.filled then
        o[#o + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="%s" fill-opacity="%.2f"/>',
                                  ob.ax, ob.ay, ob.aw, ob.ah, rx, hex(ob.color), op)
      else
        local t = ob.p.thickness or 1
        o[#o + 1] = string.format('<rect x="%.1f" y="%.1f" width="%d" height="%d" fill="none" stroke="%s" stroke-width="%d"/>',
                                  ob.ax + t / 2, ob.ay + t / 2, ob.aw - t, ob.ah - t, hex(ob.color), t)
      end
    elseif k == "hline" or k == "vline" then
      o[#o + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>',
                                ob.ax, ob.ay, ob.aw, ob.ah, hex(ob.color))
    elseif k == "image" then
      o[#o + 1] = string.format('<image x="%d" y="%d" width="%d" height="%d" href="%s"/>',
                                ob.ax, ob.ay, ob.aw, ob.ah, dataUri(ob.file))
    elseif k == "label" and ob.text ~= "" then
      local idx = ((ob.font or 0) & 0x0F00) >> 8
      local f = FONT_PX[idx] or FONT_PX[0]
      local _, lh = mock.sizeText("0", ob.font or 0)
      local base = ob.ay + math.floor((lh + f[1]) / 2) - 1
      local x, anchor = ob.ax, "start"
      if ob.p.align == RIGHT then x, anchor = ob.ax + ob.aw, "end"
      elseif ob.p.align == CENTER then x, anchor = ob.ax + ob.aw / 2, "middle" end
      o[#o + 1] = string.format('<text x="%.1f" y="%d" font-family="Roboto,Helvetica,Arial" font-size="%d" font-weight="%s" text-anchor="%s" fill="%s">%s</text>',
                                x, base, f[1], f[2], anchor, hex(ob.color), esc(ob.text))
    end
    for _, c in ipairs(ob.children) do draw(c) end
  end
  for _, r in ipairs(mock.roots) do draw(r) end
  o[#o + 1] = "</svg>"
  local f = assert(io.open(path, "w"))
  f:write(table.concat(o, "\n"))
  f:close()
  print("wrote " .. path)
end

local function scene(w, h, opts, name)
  local o = { darkTheme = 1, transpLevel = 1, vtxOff = 0, hideTrims = 0 }
  for k, v in pairs(opts or {}) do o[k] = v end
  local wgt = {
    zone = { x = 0, y = 0, w = w, h = h }, options = o, dir = "WIDGETS/FPVDASH/",
    S = { connected = true, rxV = 15.4, cells = 4, cellV = 3.85, lq = 100, rssi = -65, snr = 10, rfmd = 7,
          rateHz = 250, tpwr = 250, curr = 12.3, capa = 1300, gps = true, sats = 9, fm = "ACRO", txV = 7.8,
          txState = "ok", modelName = "100% pro gemini", timers = { { sec = 125 }, { sec = 3725 }, {} },
          clock = "12:34", date = "2 Oct" },
    I = { left = { x = -40, y = -100 }, right = { x = 30, y = 55 },
          trim = { lh = -20, lv = 35, rv = 0, rh = 60 }, trimTxt = { lh = "20", lv = "35", rv = "", rh = "60" },
          trimExt = false },
    E = { label = "RadioMaster TX15 4.1.0" },
    V = { state = "ready", ready = true, band = 5, bandLetter = "R", channel = 4, freq = 5769, power = 2,
          powerLabels = { "-", "1", "2", "3" }, pit = 1, pitLabels = { "Off", "On" }, rev = 1 },
  }
  wgt.theme = theme.resolve(o)
  wgt.mods = { layout = layout }
  mock.reset()
  local d = dash.build(wgt)
  d.update(wgt)
  mock.poll()
  mock.layout()
  svg(w, h, OUT .. "/" .. name .. ".svg")
end

scene(480, 320, nil, "dash_480x320")
scene(480, 320, { hideTrims = 1, vtxOff = 1, darkTheme = 0 }, "dash_480x320_light_notrims")
scene(480, 272, nil, "dash_480x272")
scene(430, 225, nil, "dash_430x225")
scene(240, 137, nil, "dash_240x137")
