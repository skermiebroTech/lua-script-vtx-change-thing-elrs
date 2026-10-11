-- FPVDASH ui/vtxpage.lua
-- Full-screen VTX control page (the "VTX" tab of the full-screen view).
--   build(wgt, root) -> p   texts, colors and boxes of the page, inside the box root
--                           (in the widget when root is nil). Built in full screen.
--   controls(p, wgt, root)  the buttons, inside the box root. Controls exist only in
--                           full screen: app.lua makes them on each full-screen entry
--                           and deletes them on exit (a hidden button could keep the
--                           key focus). root must be drawn above the root of build.
--   p.update(wgt)           runs on every visible tick while the page is shown.
-- Back and the tab buttons are shared by both pages (ui/thrpage.lua header); this page
-- adds Reload and the status texts of the header strip (ui/layout.lua pageHeader).
-- Reads only wgt.V, wgt.E, wgt.theme, wgt.mods.vtx (apply, reload, freqOf) and
-- wgt.mods.layout. Button callbacks only set fields; requests are handled in p.update.

local M = {}

local EMPTY = {}

-- Layout for 480x320. Every control keeps >= 3 px free around it
-- (focus outline = 2 px + 1 px pad).
local HDR_H = 42      -- header strip
local BTN_H = 38      -- row button height
local ROW_H = 44      -- row pitch
local FREQ_H = 18     -- frequency strip under the channel row
local GAP = 4         -- gap between buttons in a row
local LBL_W = 54      -- row label column (buttons start here)
local MG = 3          -- margin to the screen / container edge
local APPLY_W = 196
local APPLY_H = 48
local PIT_W = 170
-- Smaller rows for screens lower than 300 px (480x272).
local SM_BTN_H = 34
local SM_ROW_H = 40
local SM_FREQ_H = 16

local HINTS = {
  off = "VTX control is off in the widget settings.",
  nocrsf = "No CRSF link to the TX module.",
  search = "Looking for the ExpressLRS TX module...",
  noelrs = "The TX module is not ExpressLRS.",
  novtx = "No VTX Administrator in the TX module.",
  load = "Reading the VTX settings...",
  error = "No answer from the module. Press Reload.",
}

local SEND_TXT = {
  idle = "Apply & Send",
  writing = "Writing...",
  sending = "Sending...",
  sent = "Sent",
  queued = "Queued (no RX)",
  notenabled = "Enable a band",
  failed = "Failed - retry",
}

local STATE_KIND = {
  ready = "good", busy = "warn", load = "warn", search = "warn",
  nocrsf = "bad", noelrs = "bad", novtx = "bad", error = "bad", off = "muted",
}

local function int(x)
  if type(x) ~= "number" then return 0 end
  return math.floor(x + 0.5)
end

local function lbl(list, v)
  local s = (list or EMPTY)[v + 1]
  if type(s) ~= "string" then return "?" end
  return s
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
-- (The same functions are in ui/thrpage.lua.)
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

-- Signature of the option lists; a change means the page must be rebuilt.
local function sigOf(V)
  return table.concat(V.bandLabels or EMPTY, ";") .. "|" ..
         table.concat(V.powerLabels or EMPTY, ";") .. "|" ..
         table.concat(V.pitLabels or EMPTY, ";")
end

-- ELRS sends the pit mode only together with a power level: with power "-" (Keep)
-- the VTX gets no power and no pit byte, and 3.6+ hides the Pitmode field.
local function pitOk(p, pw)
  return p.hasPit and (not p.hasPower or pw >= 1)
end

-- "R4 5769 MHz", "R4", or "VTX off"
local function chanText(V, vtx, b, ch)
  if b < 1 then return "VTX off" end
  local name = lbl(V.bandLabels, b)
  if ch < 1 then return name .. "?" end
  local f = int(vtx.freqOf(string.sub(name, 1, 1), ch))
  if f > 0 then return string.format("%s%d %d MHz", name, ch, f) end
  return string.format("%s%d", name, ch)
end

-- "P2, Pit Off" (short) or "Power 2, Pit Off"; no pit part with power Keep
local function extraText(p, V, pw, pit, short)
  local s = ""
  if p.hasPower then
    if pw < 1 then
      s = short and "P-" or "Power: keep"
    else
      s = (short and "P" or "Power ") .. lbl(V.powerLabels, pw)
    end
  end
  if pitOk(p, pw) then
    if s ~= "" then s = s .. ", " end
    s = s .. "Pit " .. lbl(V.pitLabels, pit)
  end
  return s
end

local function isDirty(p)
  local s, c = p.sel, p.cur
  if s.band ~= c.band or s.channel ~= c.channel then return true end
  if p.hasPower and s.power ~= c.power then return true end
  if pitOk(p, s.power) and s.pit ~= c.pit then return true end
  return false
end

-- Selected = focus color, applied (not selected) = active color, others = theme default.
local function paint(p, vals, bg, fg, s, c)
  local k = p.k
  for i = 1, #vals do
    local v = vals[i]
    if v == s then
      bg[i] = k.SEL_BG; fg[i] = k.SEL_FG
    elseif v == c then
      bg[i] = k.CUR_BG; fg[i] = k.CUR_FG
    else
      bg[i] = k.DEF_BG; fg[i] = k.DEF_FG
    end
  end
end

-- Recompute every display field. Called only when V, the selection or armed changed.
local function compute(p, wgt, armed)
  local V = wgt.V
  local vtx = p.vtx
  local k = p.k
  local vChanged = (V.rev ~= p.seenRev) or p.forceSync
  p.seenRev = V.rev
  p.seenSel = p.selRev
  p.armed = armed
  local sel, cur = p.sel, p.cur

  if vChanged then
    -- Option lists differ from the built ones: app.lua rebuilds outside callbacks.
    if sigOf(V) ~= p.sig then wgt.rebuildRequested = true end
    local ready = V.ready == true
    -- Keep the controls during writes even if V.ready drops while busy.
    if not ready and V.state == "busy" and #(V.bandLabels or EMPTY) > 0 then ready = true end
    local staged = (not p.forceSync) and p.ready and ready and isDirty(p)
    cur.band = int(V.band)
    cur.channel = int(V.channel)
    cur.power = int(V.power)
    cur.pit = int(V.pit)
    if not staged then
      sel.band = cur.band
      sel.channel = cur.channel
      sel.power = cur.power
      sel.pit = cur.pit
    end
    p.forceSync = false
    p.ready = ready
    p.notReady = not ready
    p.hasPower = #(V.powerLabels or EMPTY) > 0
    p.hasPit = #(V.pitLabels or EMPTY) > 0

    local msg = V.msg
    if type(msg) ~= "string" then msg = "" end
    p.msgRaw = msg
    p.dotCol = k.dot[STATE_KIND[V.state] or "muted"] or k.dot.muted
    if msg == "" then msg = "VTX not ready" end
    p.bigTxt = msg
    p.hintTxt = HINTS[V.state] or ""
    if ready then
      local e = extraText(p, V, cur.power, cur.pit, true)
      local t = "Now: " .. chanText(V, vtx, cur.band, cur.channel)
      if e ~= "" then t = t .. ", " .. e end
      p.nowTxt = fit(t, SMLSIZE, p.nowW)
      if pitOk(p, cur.power) then
        p.pitNowTxt = "Now: " .. lbl(V.pitLabels, cur.pit)
      else
        p.pitNowTxt = "Now: -"
      end
    else
      p.nowTxt = ""
      p.pitNowTxt = ""
    end
  end

  -- The status message ends before "ARMED" while armed.
  if vChanged or p.msgArmed ~= armed then
    p.msgArmed = armed
    p.msgTxt = fit(p.msgRaw, SMLSIZE, armed and p.msgWArmed or p.msgW)
  end

  local dirty = isDirty(p)
  p.dirty = dirty
  -- The pit button only with a power level selected (or no power field).
  p.pitShown = pitOk(p, sel.power)
  p.pitHint = p.hasPit and not p.pitShown

  paint(p, p.bandVal, p.bandBg, p.bandFg, sel.band, cur.band)
  paint(p, p.chVal, p.chBg, p.chFg, sel.channel, cur.channel)
  paint(p, p.pwrVal, p.pwrBg, p.pwrFg, sel.power, cur.power)

  -- Frequencies of the selected band under the channel buttons.
  if sel.band ~= p.freqBand or vChanged then
    p.freqBand = sel.band
    local ft = p.freqTxt
    local letter = ""
    if sel.band >= 1 then letter = string.sub(lbl(V.bandLabels, sel.band), 1, 1) end
    for ch = 1, 8 do
      local f = 0
      if letter ~= "" then f = int(vtx.freqOf(letter, ch)) end
      if f > 0 then ft[ch] = string.format("%d", f) else ft[ch] = "" end
    end
  end

  -- Summary of the selection.
  p.setTxt = chanText(V, vtx, sel.band, sel.channel)
  p.setTxt2 = extraText(p, V, sel.power, sel.pit, false)
  p.setCol = dirty and k.SEL_TXT or k.TXT

  p.pitTxt = lbl(V.pitLabels, sel.pit)
  if p.pitShown and sel.pit ~= cur.pit then
    p.pitBg = k.SEL_BG; p.pitFg = k.SEL_FG
  else
    p.pitBg = k.DEF_BG; p.pitFg = k.DEF_FG
  end

  -- Apply button and the note line follow V.send. A failed write stays visible
  -- (until the module result times out) even when the selection is still staged.
  local s = V.send
  if SEND_TXT[s] == nil then s = "idle" end
  local busy = (s == "writing") or (s == "sending")
  local sm = V.sendMsg
  if type(sm) ~= "string" then sm = "" end
  if busy then
    p.applyTxt = SEND_TXT[s]
    p.applyBg = k.DEF_BG; p.applyFg = k.DEF_FG
    p.noteTxt = sm
  elseif s == "failed" then
    p.applyTxt = SEND_TXT.failed
    p.applyBg = k.WARN_BG; p.applyFg = k.WARN_FG
    if sm == "" then sm = "Not applied" end
    if dirty and armed then sm = sm .. " - armed: confirm" end
    p.noteTxt = sm
  elseif dirty then
    p.applyTxt = SEND_TXT.idle
    p.applyBg = k.SEL_BG; p.applyFg = k.SEL_FG
    p.noteTxt = armed and "Armed: you must confirm" or "Not applied yet"
  else
    p.applyTxt = SEND_TXT[s]
    p.applyBg = k.DEF_BG; p.applyFg = k.DEF_FG
    p.noteTxt = sm
  end
end

-- Requests recorded by callbacks, handled here (outside LVGL callbacks).
local function handleRequest(p, wgt, r)
  local V = wgt.V
  local vtx = p.vtx
  if r == "apply" then
    if not p.ready then return end
    local s = p.sel
    -- New table: the pending request must not change when the user taps again.
    local req = { band = s.band }
    if s.channel >= 1 then req.channel = s.channel end
    if p.hasPower then req.power = s.power end
    if pitOk(p, s.power) then req.pit = s.pit end
    local E = wgt.E
    if E ~= nil and E.armed == true then
      if lvgl.confirm ~= nil then
        lvgl.confirm({ title = "Armed", message = "Change VTX while armed?",
                       confirm = function() vtx.apply(V, req, true) end })
      end
    else
      vtx.apply(V, req, true)
    end
  elseif r == "pit" then
    local labels = V.pitLabels or EMPTY
    local n = #labels
    if n == 0 or lvgl.menu == nil or not p.ready or not p.pitShown then return end
    local sel = p.sel
    lvgl.menu({ title = "Pit mode", values = labels,
                get = function()
                  local i = sel.pit + 1
                  if i < 1 or i > n then i = 1 end
                  return i
                end,
                set = function(i) sel.pit = i - 1; p.selRev = p.selRev + 1 end })
  elseif r == "reload" then
    vtx.reload(V)
    p.forceSync = true          -- drop the staged selection
  end
end

-- Font that fits all texts in a button of width w.
local function fitFont(texts, w)
  local size = lcd and lcd.sizeText
  if size == nil then return STDSIZE end
  for i = 1, #texts do
    local tw = size(texts[i], STDSIZE)
    if type(tw) == "number" and tw > w - 14 then return SMLSIZE end
  end
  return STDSIZE
end

-- Row geometry. All y values are relative to the body (below the header).
local function geometry(V, W, H)
  local small = H < 300
  local g = {
    W = W, H = H,
    rowH = small and SM_ROW_H or ROW_H,
    btnH = small and SM_BTN_H or BTN_H,
    bodyY = HDR_H + 2,
  }
  g.bodyH = H - g.bodyY
  g.titleY = small and 11 or 13   -- SMLSIZE row title, level with the button text
  local y = 0
  g.bandY = y
  y = y + g.rowH
  g.chY = y
  g.freqY = y + g.rowH
  y = y + g.rowH + (small and SM_FREQ_H or FREQ_H)
  g.hasPwrRow = #(V.powerLabels or EMPTY) > 0
  if g.hasPwrRow then
    g.pwrY = y
    y = y + g.rowH
  end
  g.hasPitRow = #(V.pitLabels or EMPTY) > 0
  if g.hasPitRow then
    g.pitY = y
    y = y + g.rowH
  end
  -- Summary (3 lines, 80 px) on the left and Apply on the right, under the rows.
  local by = g.bodyH - 82
  if by < y then by = y end
  g.applyX, g.applyW = W - MG - APPLY_W, APPLY_W
  if by + 80 > g.bodyH and g.hasPitRow then
    -- Not enough height (480x272): Apply right of the Pit button, and a two-line
    -- summary under the rows (the staged power and pit on the right of line 1).
    g.applyY, g.applyH = g.pitY + MG, g.btnH
    g.compact = true
    g.sumY = y + 1
  else
    g.applyY, g.applyH = by + 6, APPLY_H
    g.compact = false
    g.sumY = by + 4
  end
  return g
end

-- Title of a row of buttons.
local function rowTitle(p, parent, y, title)
  mk(parent, "label", { x = 2, y = y + p.g.titleY, font = SMLSIZE, color = p.k.TXT, text = title })
end

function M.build(wgt, root)
  local V = wgt.V
  local th = wgt.theme or EMPTY
  local W = LCD_W or 480
  local H = LCD_H or 320

  -- lcd.getColor reads each theme color once per build
  local warnBg = COLOR_THEME_WARNING or RED
  local k = {
    SEL_BG = COLOR_THEME_FOCUS, SEL_FG = textOn(COLOR_THEME_FOCUS, COLOR_THEME_PRIMARY2),
    CUR_BG = COLOR_THEME_ACTIVE, CUR_FG = textOn(COLOR_THEME_ACTIVE, COLOR_THEME_PRIMARY1),
    DEF_BG = COLOR_THEME_PRIMARY2, DEF_FG = COLOR_THEME_SECONDARY1,
    TXT = COLOR_THEME_PRIMARY1,
    SEL_TXT = textIn(COLOR_THEME_FOCUS, COLOR_THEME_SECONDARY3),   -- staged summary on the page
    WARN_BG = warnBg, WARN_FG = textOn(warnBg, COLOR_THEME_PRIMARY2),
    -- the dot is on the header strip (a theme color), not on the dashboard wash: always
    -- YELLOW for "busy" (theme.warn is a dark amber in the light dashboard mode)
    dot = { good = th.good or GREEN, warn = YELLOW,
            bad = th.bad or RED, muted = th.muted or LIGHTGREY },
  }

  -- header strip shared with the throttle page: status area textX .. textR
  local hd = wgt.mods.layout.pageHeader(W)
  local dotX = hd.textX + 6
  local msgX = hd.textX + 16
  local armedX = hd.textR - 4 - textW("ARMED", SMLSIZE)

  local p = {
    k = k, vtx = wgt.mods.vtx, g = geometry(V, W, H), hd = hd,
    nowW = hd.textR - hd.textX, msgW = hd.textR - msgX, msgWArmed = armedX - 6 - msgX,
    sel = { band = 0, channel = 0, power = 0, pit = 0 },
    cur = { band = 0, channel = 0, power = 0, pit = 0 },
    selRev = 0, seenSel = -1, seenRev = -1, armed = false, msgArmed = false,
    req = nil, forceSync = true, ready = false, notReady = true,
    hasPower = false, hasPit = false, dirty = false, pitShown = false, pitHint = false,
    sig = sigOf(V), freqBand = -1,
    msgRaw = "", msgTxt = "", nowTxt = "", bigTxt = "", hintTxt = "", pitNowTxt = "",
    setTxt = "", setTxt2 = "", noteTxt = "", pitTxt = "", applyTxt = SEND_TXT.idle,
    dotCol = k.dot.muted, setCol = k.TXT,
    pitBg = k.DEF_BG, pitFg = k.DEF_FG, applyBg = k.DEF_BG, applyFg = k.DEF_FG,
    freqTxt = { "", "", "", "", "", "", "", "" },
    bandTxt = {}, bandVal = {}, bandBg = {}, bandFg = {},
    chTxt = { "1", "2", "3", "4", "5", "6", "7", "8" },
    chVal = { 1, 2, 3, 4, 5, 6, 7, 8 }, chBg = {}, chFg = {},
    pwrTxt = {}, pwrVal = {}, pwrBg = {}, pwrFg = {},
  }
  local g = p.g

  -- Button lists from the module option lists (fixed until the next rebuild).
  local bandLabels = V.bandLabels or EMPTY
  for i = 2, #bandLabels do
    p.bandTxt[#p.bandTxt + 1] = bandLabels[i]
    p.bandVal[#p.bandVal + 1] = i - 1
  end
  if #bandLabels > 0 then
    p.bandTxt[#p.bandTxt + 1] = "Off"
    p.bandVal[#p.bandVal + 1] = 0
  end
  local powerLabels = V.powerLabels or EMPTY
  for i = 1, #powerLabels do
    local t = powerLabels[i]
    if i == 1 and t == "-" then t = "Keep" end
    p.pwrTxt[i] = t
    p.pwrVal[i] = i - 1
  end
  -- Fill every field before objects poll them.
  local E = wgt.E
  compute(p, wgt, E ~= nil and E.armed == true)

  -- Page background and header strip (Back, the tabs and Reload are controls):
  -- line 1 = state dot + V.msg (+ ARMED on the right), line 2 = the applied setting.
  mk(root, "rectangle", { x = 0, y = 0, w = W, h = H, filled = true, color = COLOR_THEME_SECONDARY3 })
  mk(root, "rectangle", { x = 0, y = 0, w = W, h = HDR_H, filled = true, color = COLOR_THEME_SECONDARY1 })
  mk(root, "circle", { x = dotX, y = 13, radius = 5, filled = true,
                       color = function() return p.dotCol end })
  mk(root, "label", { x = msgX, y = 5, font = SMLSIZE, color = COLOR_THEME_PRIMARY2,
                      text = function() return p.msgTxt end })
  mk(root, "label", { x = hd.textX, y = 23, font = SMLSIZE, color = COLOR_THEME_PRIMARY2,
                      text = function() return p.nowTxt end })
  mk(root, "label", { x = armedX, y = 5, font = SMLSIZE, color = k.dot.bad, text = "ARMED",
                      visible = function() return p.armed end })

  -- Texts of the controls area (only when V is ready).
  local body = mk(root, "box", { x = 0, y = g.bodyY, w = W, h = g.bodyH,
                                 scrollDir = lvgl.SCROLL_OFF, scrollBar = false,
                                 visible = function() return p.ready end })
  rowTitle(p, body, g.bandY, "Band")
  rowTitle(p, body, g.chY, "Ch")
  -- Frequencies of the selected band, centred under each channel button.
  local cbw = math.floor((W - MG - LBL_W - 7 * GAP) / 8)
  for ch = 1, 8 do
    mk(body, "label", { x = LBL_W + (ch - 1) * (cbw + GAP), y = g.freqY, w = cbw, align = CENTER,
                        font = SMLSIZE, color = k.TXT,
                        text = function() return p.freqTxt[ch] end })
  end
  if g.hasPwrRow then
    local row = mk(body, "box", { x = 0, y = g.pwrY, w = W, h = g.rowH,
                                  scrollDir = lvgl.SCROLL_OFF, scrollBar = false,
                                  visible = function() return p.hasPower end })
    rowTitle(p, row, 0, "Power")
  end
  if g.hasPitRow then
    local row = mk(body, "box", { x = 0, y = g.pitY, w = W, h = g.rowH,
                                  scrollDir = lvgl.SCROLL_OFF, scrollBar = false,
                                  visible = function() return p.hasPit end })
    rowTitle(p, row, 0, "Pit")
    -- in place of the Pit button while power is Keep
    mk(row, "label", { x = LBL_W + 8, y = g.titleY, font = SMLSIZE, color = k.TXT,
                       text = "Needs a power level",
                       visible = function() return p.pitHint end })
    if not g.compact then
      mk(row, "label", { x = LBL_W + PIT_W + 12, y = g.titleY, font = SMLSIZE, color = k.TXT,
                         text = function() return p.pitNowTxt end })
    end
  end

  -- Summary of the selection (Apply & Send is a control).
  local sy = g.sumY
  mk(body, "label", { x = 4, y = sy, font = MIDSIZE,
                      color = function() return p.setCol end,
                      text = function() return p.setTxt end })
  if g.compact then
    mk(body, "label", { x = 200, y = sy + 8, w = W - 204, align = RIGHT, font = SMLSIZE, color = k.TXT,
                        text = function() return p.setTxt2 end })
    mk(body, "label", { x = 4, y = sy + 30, font = SMLSIZE, color = k.TXT,
                        text = function() return p.noteTxt end })
  else
    mk(body, "label", { x = 4, y = sy + 32, font = SMLSIZE, color = k.TXT,
                        text = function() return p.setTxt2 end })
    mk(body, "label", { x = 4, y = sy + 54, font = SMLSIZE, color = k.TXT,
                        text = function() return p.noteTxt end })
  end

  -- Status when V is not ready: only Back and Reload stay usable.
  local nr = mk(root, "box", { x = 0, y = g.bodyY, w = W, h = g.bodyH,
                               scrollDir = lvgl.SCROLL_OFF, scrollBar = false,
                               visible = function() return p.notReady end })
  mk(nr, "label", { x = 8, y = 40, w = W - 16, align = CENTER, font = MIDSIZE, color = k.TXT,
                    text = function() return p.bigTxt end })
  mk(nr, "label", { x = 8, y = 84, w = W - 16, align = CENTER, font = SMLSIZE, color = k.TXT,
                    text = function() return p.hintTxt end })
  mk(nr, "label", { x = 8, y = 150, w = W - 16, align = CENTER, font = SMLSIZE, color = k.TXT,
                    text = "Reload searches again. Back returns to the dashboard." })

  function p.update(w)
    local r = p.req
    if r ~= nil then
      p.req = nil
      handleRequest(p, w, r)
    end
    local e = w.E
    local armed = e ~= nil and e.armed == true
    if w.V.rev == p.seenRev and p.selRev == p.seenSel and armed == p.armed
       and not p.forceSync then
      return
    end
    compute(p, w, armed)
  end

  return p
end

-- One row of option buttons inside box `parent` at row-relative y.
local function makeRow(p, parent, y, field, texts, vals, bg, fg)
  local n = #texts
  if n == 0 then return end
  local g = p.g
  local gap = GAP
  local avail = g.W - MG - LBL_W
  if n > 9 then gap = 2 end
  local bw = math.floor((avail - (n - 1) * gap) / n)
  local font = fitFont(texts, bw)
  local sel = p.sel
  -- bg/fg were already filled by compute() for every value in vals.
  for i = 1, n do
    local v = vals[i]
    mk(parent, "button", {
      x = LBL_W + (i - 1) * (bw + gap), y = y + MG, w = bw, h = g.btnH,
      text = texts[i], font = font,
      color = function() return bg[i] end,
      textColor = function() return fg[i] end,
      press = function() sel[field] = v; p.selRev = p.selRev + 1 end,
    })
  end
end

-- The buttons of the page, inside the box root (full screen only). A new set on each
-- full-screen entry starts from the module values (nothing staged, no old request).
function M.controls(p, wgt, root)
  local g, W, hd = p.g, p.g.W, p.hd
  p.req = nil
  p.forceSync = true
  compute(p, wgt, p.armed)

  -- Back and the tabs are in the shared header (thrpage.header)
  mk(root, "button", { x = hd.reloadX, y = hd.btnY, w = hd.reloadW, h = hd.btnH, text = "Reload",
                       press = function() p.req = "reload" end })

  local body = mk(root, "box", { x = 0, y = g.bodyY, w = W, h = g.bodyH,
                                 scrollDir = lvgl.SCROLL_OFF, scrollBar = false,
                                 visible = function() return p.ready end })
  if body == nil then return end
  makeRow(p, body, g.bandY, "band", p.bandTxt, p.bandVal, p.bandBg, p.bandFg)
  makeRow(p, body, g.chY, "channel", p.chTxt, p.chVal, p.chBg, p.chFg)
  if g.hasPwrRow then
    local row = mk(body, "box", { x = 0, y = g.pwrY, w = W, h = g.rowH,
                                  scrollDir = lvgl.SCROLL_OFF, scrollBar = false,
                                  visible = function() return p.hasPower end })
    makeRow(p, row, 0, "power", p.pwrTxt, p.pwrVal, p.pwrBg, p.pwrFg)
  end
  if g.hasPitRow then
    local row = mk(body, "box", { x = 0, y = g.pitY, w = LBL_W + PIT_W + MG, h = g.rowH,
                                  scrollDir = lvgl.SCROLL_OFF, scrollBar = false,
                                  visible = function() return p.pitShown end })
    mk(row, "button", { x = LBL_W, y = MG, w = PIT_W, h = g.btnH,
                        text = function() return p.pitTxt end,
                        color = function() return p.pitBg end,
                        textColor = function() return p.pitFg end,
                        press = function() p.req = "pit" end })
  end
  mk(body, "button", { x = g.applyX, y = g.applyY, w = g.applyW, h = g.applyH,
                       text = function() return p.applyTxt end,
                       color = function() return p.applyBg end,
                       textColor = function() return p.applyFg end,
                       press = function() p.req = "apply" end })
end

return M
