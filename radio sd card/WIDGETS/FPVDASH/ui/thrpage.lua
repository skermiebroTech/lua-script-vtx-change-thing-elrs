-- FPVDASH ui/thrpage.lua
-- Full-screen throttle cap page (the "Throttle" tab of the full-screen view) and the
-- header buttons that both full-screen pages share.
--   build(wgt, root) -> t      texts, colors and boxes of the page, inside the box root
--                              (in the widget when root is nil). Built in full screen.
--   controls(t, wgt, root)     the presets, -5/+5, the number input and Set, inside the
--                              box root (full screen only). app.lua makes them on each
--                              full-screen entry and deletes them on exit.
--   header(wgt, root, tabs)    Back, and the VTX / Throttle tab buttons when VTX control is
--                              on. tabs = { vtx = bool, thr = bool }: the shown tab (app.lua).
--                              A tab press only sets wgt.tab ("vtx" or "thr").
--   t.update(wgt)              runs on every visible tick while the page is shown.
-- lib/thrcap.lua changes the model: the callbacks only call thrcap.request (it records a
-- pending value) or change the staged number; thrcap.tick writes the model in refresh.
-- Reads wgt.T, wgt.theme, wgt.vtxOn, wgt.mods.thrcap and wgt.mods.layout.

local M = {}

local EMPTY = {}

local PRESETS = { 100, 90, 80, 75, 70, 60, 50 }

-- Layout for 480x320 (the header strip is ui/layout.lua pageHeader). Every control keeps
-- >= 3 px free around it (focus outline = 2 px + 1 px pad).
local HDR_H = 42
local MG = 3
local GAP = 4
local LBL_W = 54          -- row title column (buttons start here)
local BTN_H, ROW_H = 38, 44
local SM_BTN_H, SM_ROW_H = 34, 40   -- screens lower than 300 px (480x272)
local STEP_W = 62
local EDIT_W = 110
local SET_W = 80
local INFO_X = 250        -- caption column right of the big value

-- Used when wgt.T is missing.
local NONE_T = { state = "none", msg = "", cap = 0, custom = false, weight = 0, offset = 0,
                 input = -1, rev = -1 }

local STATE_KIND = { ok = "good", busy = "warn", error = "bad", none = "muted", unsupported = "bad" }

local HINT1 = {
  none = "The cap needs an input line that uses the Thr stick.",
  unsupported = "The throttle input must be one plain line:",
}
local HINT2 = {
  none = "Check the Inputs page of the model.",
  unsupported = "source Thr, no switch, all flight modes, no GVAR, no curve.",
}
-- Refusals that come from the mixes or from a second Thr input need other hints.
local MIX_HINT1 = "Check the Mixes page of the model:"
local MIX_HINT2 = "the throttle channel needs the Thr input, positive weight."
local MULTI_HINT1 = "Only one input may use the Thr stick."
local MULTI_HINT2 = "Check the Inputs page of the model."

-- Hint lines for a state and its message.
local function hints(st, msg)
  if st == "unsupported" then
    if string.sub(msg, 1, 2) == "CH" or msg == "Thr input not in mixes" or msg == "Mix read failed" then
      return MIX_HINT1, MIX_HINT2
    end
    if string.sub(msg, 1, 7) == "Thr in " then
      return MULTI_HINT1, MULTI_HINT2
    end
  end
  return HINT1[st] or "", HINT2[st] or ""
end

local function int(x)
  if type(x) ~= "number" then return 0 end
  return math.floor(x + 0.5)
end

-- New object in parent, or in the widget when parent is nil.
local function mk(parent, kind, t)
  if parent ~= nil then return lvgl[kind](parent, t) end
  return lvgl[kind](t)
end

-- Text width in px (lcd.sizeText works in LVGL widgets); 7 px per character without it.
local function textW(text, font)
  local size = lcd and lcd.sizeText
  if size ~= nil then
    local w = size(text, font)
    if type(w) == "number" then return w end
  end
  return #text * 7
end

-- Cut text so that it fits in maxW px (keeps whole UTF-8 characters).
local function fit(text, font, maxW)
  if textW(text, font) <= maxW then return text end
  local n = #text
  while n > 0 do
    n = n - 1
    local b = string.byte(text, n + 1)
    if b == nil or b < 128 or b >= 192 then
      local s = string.sub(text, 1, n)
      if textW(s, font) <= maxW then return s end
    end
  end
  return ""
end

-- sRGB channel 0..255 to linear light (WCAG relative luminance)
local function lin(v)
  v = v / 255
  if v <= 0.04045 then return v / 12.92 end
  return ((v + 0.055) / 1.055) ^ 2.4
end

-- Luminance of the real color of c on the radio (the radio theme sets the theme colors),
-- or nil when it cannot be read. lcd.getColor returns an RGB flag: the RGB565 value in
-- bits 16..31 and the RGB flag 0x8000.
local function lumOf(c)
  local get = lcd and lcd.getColor
  if get == nil or type(c) ~= "number" then return nil end
  local v = get(c)
  if type(v) ~= "number" or (v & 0x8000) == 0 then return nil end
  local p = (v >> 16) & 0xFFFF
  return 0.2126 * lin(((p >> 11) & 31) * 255 // 31) + 0.7152 * lin(((p >> 5) & 63) * 255 // 63)
         + 0.0722 * lin((p & 31) * 255 // 31)
end

-- Text color on a button in the color c: BLACK or WHITE, the one with more contrast. One
-- of the two always gives at least 4.5:1. The theme text colors do not: on "Dark Theme"
-- PRIMARY1 on ACTIVE is 1.65:1 and PRIMARY2 on FOCUS 2.9:1, on the default theme PRIMARY2
-- on FOCUS is 2.9:1. When the color cannot be read, the theme color 'old' is used.
-- (The same functions are in ui/vtxpage.lua.)
local function textOn(c, old)
  local L = lumOf(c)
  if L == nil then return old end
  -- contrast with black (L + 0.05) / 0.05 against white 1.05 / (L + 0.05)
  if (L + 0.05) * (L + 0.05) >= 0.0525 then return BLACK end
  return WHITE
end

-- Contrast of the luminances a and b is at least 4.5:1.
local function readable(a, b)
  if a < b then a, b = b, a end
  return a + 0.05 >= 4.5 * (b + 0.05)
end

-- Text in the color c on the background bg: c when the contrast is at least 4.5:1 (FOCUS
-- on the default theme background is only 2.5:1), else the theme text color PRIMARY1,
-- else BLACK or WHITE.
local function textIn(c, bg)
  local a, b = lumOf(c), lumOf(bg)
  if a == nil or b == nil then return c end
  if readable(a, b) then return c end
  local p = lumOf(COLOR_THEME_PRIMARY1)
  if p ~= nil and readable(p, b) then return COLOR_THEME_PRIMARY1 end
  return textOn(bg, COLOR_THEME_PRIMARY1)
end

-- Called once per build: lcd.getColor reads each theme color once.
local function colors(th)
  return {
    SEL_BG = COLOR_THEME_FOCUS, SEL_FG = textOn(COLOR_THEME_FOCUS, COLOR_THEME_PRIMARY2),
    CUR_BG = COLOR_THEME_ACTIVE, CUR_FG = textOn(COLOR_THEME_ACTIVE, COLOR_THEME_PRIMARY1),
    DEF_BG = COLOR_THEME_PRIMARY2, DEF_FG = COLOR_THEME_SECONDARY1,
    TXT = COLOR_THEME_PRIMARY1,
    PEND = textIn(COLOR_THEME_FOCUS, COLOR_THEME_SECONDARY3),   -- "Pending: NN%" on the page
    -- the dot is on the header strip (a theme color), not on the dashboard wash: always
    -- YELLOW for "busy" (theme.warn is a dark amber in the light dashboard mode)
    dot = { good = th.good or GREEN, warn = YELLOW,
            bad = th.bad or RED, muted = th.muted or LIGHTGREY },
  }
end

-- The cap that a -5/+5 step starts from: the pending value, else the applied cap.
-- nil when the cap is unknown or the line is custom.
local function stepBase(T)
  local b = T.pending
  if type(b) == "number" then return int(b) end
  if T.custom == true then return nil end
  local c = int(T.cap)
  if c > 0 then return c end
  return nil
end

-- Recompute every display field. Called only when T or the staged number changed.
local function compute(t, wgt)
  local T = wgt.T or NONE_T
  local k = t.k
  t.seenRev = T.rev
  t.seenEdit = t.edit
  local st = T.state
  local ready = wgt.T ~= nil and st ~= "none" and st ~= "unsupported"
  t.ready = ready
  t.notReady = not ready

  local cap = int(T.cap)
  local custom = T.custom == true
  local w, o = int(T.weight), int(T.offset)
  local pend = T.pending
  if type(pend) == "number" then pend = int(pend) else pend = nil end

  -- header status: dot + T.msg, then the input line
  local msg = T.msg
  if type(msg) ~= "string" then msg = "" end
  t.msgTxt = fit(msg, SMLSIZE, t.msgW)
  t.dotCol = k.dot[STATE_KIND[st] or "muted"] or k.dot.muted
  -- weight and offset only when the line was read (thrcap clears them for a refused line)
  local input = int(T.input)
  if input < 0 then
    t.infoTxt = ""
  elseif ready then
    t.infoTxt = fit(string.format("Input %d: weight %d, offset %d", input + 1, w, o), SMLSIZE, t.infoW)
  else
    t.infoTxt = string.format("Input %d", input + 1)
  end

  -- big value and its caption
  local big, cpt
  if custom then
    big = string.format("Custom %d/%d", w, o)
    cpt = "Not weight W, offset W-100"
  elseif cap > 0 then
    big = string.format("%d%%", cap)
    cpt = "Max throttle"
  else
    big = "--"
    cpt = "Cap unknown"
  end
  if big ~= t.bigTxt then
    t.bigTxt = big
    if textW(big, DBLSIZE) > INFO_X - 16 then t.bigFont = MIDSIZE else t.bigFont = DBLSIZE end
  end
  t.capTxt = cpt
  if pend ~= nil then t.pendTxt = string.format("Pending: %d%%", pend) else t.pendTxt = "" end

  -- presets: pending = focus color, applied = active color
  local cur = -1
  if cap > 0 and not custom then cur = cap end
  local bg, fg = t.preBg, t.preFg
  for i = 1, #PRESETS do
    local v = PRESETS[i]
    if pend ~= nil and v == pend then
      bg[i] = k.SEL_BG; fg[i] = k.SEL_FG
    elseif v == cur then
      bg[i] = k.CUR_BG; fg[i] = k.CUR_FG
    else
      bg[i] = k.DEF_BG; fg[i] = k.DEF_FG
    end
  end
  local base = stepBase(T)
  t.stepOk = base ~= nil
  -- Set is highlighted while the staged number differs from the cap
  if base == nil or t.edit ~= base then
    t.setBg = k.SEL_BG; t.setFg = k.SEL_FG
  else
    t.setBg = k.DEF_BG; t.setFg = k.DEF_FG
  end

  -- texts while the cap cannot be changed
  if msg == "" then msg = "Throttle cap not available" end
  t.bigMsg = msg
  t.hint1, t.hint2 = hints(st, msg)
end

-- Title of a row of buttons.
local function rowTitle(t, parent, y, title)
  mk(parent, "label", { x = 2, y = y + t.g.titleY, font = SMLSIZE, color = t.k.TXT, text = title })
end

function M.build(wgt, root)
  local W = LCD_W or 480
  local H = LCD_H or 320
  local th = wgt.theme or EMPTY
  local thr = wgt.mods.thrcap or EMPTY
  local hd = wgt.mods.layout.pageHeader(W)
  local small = H < 300

  local g = {
    W = W, H = H,
    btnH = small and SM_BTN_H or BTN_H, rowH = small and SM_ROW_H or ROW_H,
    bodyY = HDR_H + 2, capH = small and 46 or 54, titleY = small and 11 or 13,
    editX = W - MG - SET_W - GAP - EDIT_W, setX = W - MG - SET_W,
  }
  g.bodyH = H - g.bodyY
  g.preY = g.capH
  g.stepY = g.preY + g.rowH
  g.noteY = g.stepY + g.rowH + 6

  local k = colors(th)
  local dotX = hd.textX + 6
  local msgX = hd.textX + 16
  local t = {
    k = k, g = g, hd = hd,
    min = (type(thr.MIN) == "number") and thr.MIN or 20,
    max = (type(thr.MAX) == "number") and thr.MAX or 100,
    msgW = hd.textR - msgX, infoW = hd.textR - hd.textX,
    seenRev = -2, seenEdit = -1, edit = 100,
    ready = false, notReady = true, stepOk = false,
    msgTxt = "", infoTxt = "", bigTxt = "", bigFont = DBLSIZE, capTxt = "", pendTxt = "",
    bigMsg = "", hint1 = "", hint2 = "",
    dotCol = k.dot.muted, setBg = k.DEF_BG, setFg = k.DEF_FG,
    preTxt = {}, preBg = {}, preFg = {},
  }
  for i = 1, #PRESETS do
    t.preTxt[i] = string.format("%d%%", PRESETS[i])
    t.preBg[i] = k.DEF_BG
    t.preFg[i] = k.DEF_FG
  end
  -- Fill every field before objects poll them.
  compute(t, wgt)

  -- Page background and header strip (Back and the tabs are controls):
  -- line 1 = state dot + T.msg, line 2 = the input line.
  mk(root, "rectangle", { x = 0, y = 0, w = W, h = H, filled = true, color = COLOR_THEME_SECONDARY3 })
  mk(root, "rectangle", { x = 0, y = 0, w = W, h = HDR_H, filled = true, color = COLOR_THEME_SECONDARY1 })
  if not wgt.vtxOn then
    -- no tabs: the page title in their place
    mk(root, "label", { x = hd.titleX, y = 11, font = BOLD, color = COLOR_THEME_PRIMARY2, text = "Throttle cap" })
  end
  mk(root, "circle", { x = dotX, y = 13, radius = 5, filled = true,
                       color = function() return t.dotCol end })
  mk(root, "label", { x = msgX, y = 5, font = SMLSIZE, color = COLOR_THEME_PRIMARY2,
                      text = function() return t.msgTxt end })
  mk(root, "label", { x = hd.textX, y = 23, font = SMLSIZE, color = COLOR_THEME_PRIMARY2,
                      text = function() return t.infoTxt end })

  -- Texts of the controls area (only while the cap can be changed).
  local body = mk(root, "box", { x = 0, y = g.bodyY, w = W, h = g.bodyH,
                                 scrollDir = lvgl.SCROLL_OFF, scrollBar = false,
                                 visible = function() return t.ready end })
  mk(body, "label", { x = 8, y = 2, color = k.TXT,
                      font = function() return t.bigFont end,
                      text = function() return t.bigTxt end })
  mk(body, "label", { x = INFO_X, y = 6, font = SMLSIZE, color = k.TXT,
                      text = function() return t.capTxt end })
  mk(body, "label", { x = INFO_X, y = 24, font = SMLSIZE, color = k.PEND,
                      text = function() return t.pendTxt end })
  rowTitle(t, body, g.preY, "Preset")
  rowTitle(t, body, g.stepY, "Step")
  mk(body, "label", { x = LBL_W + 2 * STEP_W + GAP + 14, y = g.stepY + g.titleY, font = SMLSIZE,
                      color = k.TXT, text = "Manual" })
  mk(body, "label", { x = 8, y = g.noteY, font = SMLSIZE, color = k.TXT,
                      text = "Applies immediately, also when armed." })
  mk(body, "label", { x = 8, y = g.noteY + 18, font = SMLSIZE, color = k.TXT,
                      text = string.format("Stick low stays at -100. Range %d..%d %%.", t.min, t.max) })

  -- Status while the cap cannot be changed: only Back (and the tabs) stay usable.
  local nr = mk(root, "box", { x = 0, y = g.bodyY, w = W, h = g.bodyH,
                               scrollDir = lvgl.SCROLL_OFF, scrollBar = false,
                               visible = function() return t.notReady end })
  mk(nr, "label", { x = 8, y = 40, w = W - 16, align = CENTER, font = MIDSIZE, color = k.TXT,
                    text = function() return t.bigMsg end })
  mk(nr, "label", { x = 8, y = 84, w = W - 16, align = CENTER, font = SMLSIZE, color = k.TXT,
                    text = function() return t.hint1 end })
  mk(nr, "label", { x = 8, y = 104, w = W - 16, align = CENTER, font = SMLSIZE, color = k.TXT,
                    text = function() return t.hint2 end })

  function t.update(w)
    local T = w.T or NONE_T
    if T.rev == t.seenRev and t.edit == t.seenEdit then return end
    compute(t, w)
  end

  return t
end

-- -5 / +5 from the pending value or the applied cap (thrcap.request clamps the range).
local function step(wgt, thr, d)
  local T = wgt.T
  if T == nil then return end
  local b = stepBase(T)
  if b ~= nil then thr.request(T, b + d) end
end

-- The controls of the page, inside the box root (full screen only). A new set on each
-- full-screen entry stages the shown cap in the number input.
function M.controls(t, wgt, root)
  local g, W = t.g, t.g.W
  local thr = wgt.mods.thrcap
  local T = wgt.T or NONE_T
  local v = stepBase(T) or 100
  if v < t.min then v = t.min elseif v > t.max then v = t.max end
  t.edit = v
  compute(t, wgt)

  local body = mk(root, "box", { x = 0, y = g.bodyY, w = W, h = g.bodyH,
                                 scrollDir = lvgl.SCROLL_OFF, scrollBar = false,
                                 visible = function() return t.ready end })
  if body == nil then return end

  local n = #PRESETS
  local bw = math.floor((W - MG - LBL_W - (n - 1) * GAP) / n)
  local bg, fg = t.preBg, t.preFg
  for i = 1, n do
    local cap = PRESETS[i]
    mk(body, "button", {
      x = LBL_W + (i - 1) * (bw + GAP), y = g.preY + MG, w = bw, h = g.btnH, text = t.preTxt[i],
      color = function() return bg[i] end,
      textColor = function() return fg[i] end,
      press = function() thr.request(wgt.T, cap) end,
    })
  end

  local y = g.stepY + MG
  mk(body, "button", { x = LBL_W, y = y, w = STEP_W, h = g.btnH, text = "-5",
                       active = function() return t.stepOk end,
                       press = function() step(wgt, thr, -5) end })
  mk(body, "button", { x = LBL_W + STEP_W + GAP, y = y, w = STEP_W, h = g.btnH, text = "+5",
                       active = function() return t.stepOk end,
                       press = function() step(wgt, thr, 5) end })
  -- Manual value: staged in t.edit, Set applies it. rc1 reads get only at creation
  -- and after an edit, so the script never changes t.edit while the input exists.
  mk(body, "numberEdit", { x = g.editX, y = y, w = EDIT_W, h = g.btnH, min = t.min, max = t.max,
                           get = function() return t.edit end,
                           set = function(x) t.edit = math.floor(x) end,
                           display = function(x) return string.format("%d%%", x) end })
  mk(body, "button", { x = g.setX, y = y, w = SET_W, h = g.btnH, text = "Set",
                       color = function() return t.setBg end,
                       textColor = function() return t.setFg end,
                       press = function() thr.request(wgt.T, t.edit) end })
end

-- Back, and the VTX / Throttle tabs (only when VTX control is on), inside the box root
-- (full screen only). The shown tab has the focus color.
function M.header(wgt, root, tabs)
  local hd = wgt.mods.layout.pageHeader(LCD_W or 480)
  local k = { SEL_BG = COLOR_THEME_FOCUS, SEL_FG = textOn(COLOR_THEME_FOCUS, COLOR_THEME_PRIMARY2),
              DEF_BG = COLOR_THEME_PRIMARY2, DEF_FG = COLOR_THEME_SECONDARY1 }
  mk(root, "button", { x = hd.backX, y = hd.btnY, w = hd.backW, h = hd.btnH, text = "Back",
                       press = function() lvgl.exitFullScreen() end })
  if not wgt.vtxOn then return end
  mk(root, "button", { x = hd.tabX[1], y = hd.btnY, w = hd.tabW[1], h = hd.btnH, text = "VTX",
                       color = function() return tabs.vtx and k.SEL_BG or k.DEF_BG end,
                       textColor = function() return tabs.vtx and k.SEL_FG or k.DEF_FG end,
                       press = function() wgt.tab = "vtx" end })
  mk(root, "button", { x = hd.tabX[2], y = hd.btnY, w = hd.tabW[2], h = hd.btnH, text = "Throttle",
                       color = function() return tabs.thr and k.SEL_BG or k.DEF_BG end,
                       textColor = function() return tabs.thr and k.SEL_FG or k.DEF_FG end,
                       press = function() wgt.tab = "thr" end })
end

return M
