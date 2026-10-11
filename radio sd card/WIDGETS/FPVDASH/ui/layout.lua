-- Dashboard geometry. Pure math: no LVGL calls.
-- All rectangles of a region are relative to that region (region top-left = 0,0).

local M = {}

local floor, max, min = math.floor, math.max, math.min

local GAP = 2
local FOOTER_MIN_H = 290
local FOOTER_H = 16

-- Line heights of the std font set (480x272 / 480x320 radios).
local function lineH(font)
  if font == DBLSIZE then return 40 end
  if font == MIDSIZE then return 29 end
  if font == SMLSIZE then return 17 end
  if font == TINSIZE then return 12 end
  return 19                            -- STDSIZE and BOLD
end
M.lineH = lineH

-- Text width in px (lcd.sizeText still works in LVGL widgets).
function M.measure(text, font)
  if lcd and lcd.sizeText then
    local w = lcd.sizeText(text, font)
    if type(w) == "number" then return floor(w), lineH(font) end
  end
  local cw = 9
  if font == SMLSIZE then cw = 7
  elseif font == MIDSIZE then cw = 14
  elseif font == DBLSIZE then cw = 20
  elseif font == TINSIZE then cw = 5 end
  return #text * cw, lineH(font)
end
local measure = M.measure

local function rect(x, y, w, h)
  return { x = x, y = y, w = w, h = h }
end

local function shrink(v, minimum, deficit)
  if deficit <= 0 then return v, 0 end
  local avail = v - minimum
  if avail <= 0 then return v, deficit end
  local take = min(avail, deficit)
  return v - take, deficit - take
end

-- Five regions, same formulas as the old layout/layout.lua.
-- Returns { top, sticks, grid, timers, footer } (a region is nil when it does not fit).
function M.regions(w, h)
  if type(w) ~= "number" or type(h) ~= "number" or w < 1 or h < 1 then return nil end
  w, h = floor(w), floor(h)

  local showFooter = h >= FOOTER_MIN_H
  local footerH = showFooter and FOOTER_H or 0
  local numGaps = showFooter and 4 or 3

  local topH = max(36, floor(h * 0.14))
  local stickH = max(58, floor(h * 0.32))
  local timerH = max(20, floor(h * 0.14))
  local gridH = h - (topH + stickH + timerH + footerH + GAP * numGaps)
  if gridH < 40 then
    local deficit = 40 - gridH
    timerH, deficit = shrink(timerH, 16, deficit)
    stickH, deficit = shrink(stickH, 44, deficit)
    topH, deficit = shrink(topH, 18, deficit)
    gridH = h - (topH + stickH + timerH + footerH + GAP * numGaps)
  end

  local bottom = showFooter and (h - FOOTER_H - GAP) or h
  local r = {}
  local y = 0
  local function place(key, rh)
    if rh >= 1 and y + rh <= bottom then
      r[key] = rect(0, y, w, rh)
      y = y + rh + GAP
    end
  end
  place("top", topH)
  place("sticks", stickH)
  place("grid", gridH)
  place("timers", timerH)
  if showFooter then r.footer = rect(0, h - FOOTER_H, w, FOOTER_H) end
  return r
end

-- Top bar: model name, TX battery icon + voltage, link icon, clock + date.
function M.topbar(w, h)
  local g = {}
  local cx, cw = 46, w - 46                  -- 42 px reserve for the EdgeTX menu button + 4
  if cw < 80 then cx, cw = 2, w - 4 end
  local z1 = floor(cw * 0.45)
  local z2 = floor(cw * 0.20)
  local z3 = floor(cw * 0.10)
  local z4 = cw - z1 - z2 - z3
  local x2 = cx + z1
  local x3 = x2 + z2
  local x4 = x3 + z3

  -- clock (line 1) and date (line 2), right aligned
  local clkR = min(x4 + z4 - 9, w - 2)
  local cwid = max(measure("00:00", SMLSIZE), measure("30 Sep", SMLSIZE))
  g.clkW = cwid + 8
  g.clkX = clkR - g.clkW
  g.dateShow = h >= 34
  g.clkY = g.dateShow and 4 or max(0, floor((h - 17) / 2))
  g.dateY = 17
  g.clkShow = clkR - cwid >= cx
  local limit = g.clkShow and (clkR - cwid - 4) or w

  -- link icon 24x24
  g.linkX = x3 + 50 + floor((z3 - 24) / 2)
  g.linkY = max(0, floor((h - 24) / 2))
  g.linkShow = h >= 24 and g.linkX >= x2 and g.linkX + 24 <= limit
  if g.linkShow then limit = g.linkX - 2 end

  -- TX battery icon 20x33 and voltage text
  g.batX = x2 + 2 + 50
  g.batY = max(0, floor((h - 32) / 2))
  g.txX = g.batX + 30
  g.txY = max(0, floor((h - 12) / 2) - 8)
  local vw = measure("8.8V", MIDSIZE)
  g.txShow = g.txX + vw <= limit
  g.batShow = h >= 33 and g.batX + 20 <= limit - 2
  if not g.batShow then
    g.txX = g.batX
    g.txShow = g.txX + vw <= limit
  end
  if g.batShow then
    limit = g.batX
  elseif g.txShow then
    limit = g.txX
  end

  -- model name, font by height
  local f = SMLSIZE
  if h >= 36 then f = DBLSIZE elseif h >= 26 then f = MIDSIZE end
  g.nameFont = f
  g.nameX = cx + 10
  g.nameY = max(0, floor((h - (lineH(f) - 5)) / 2))
  g.nameW = max(0, limit - 4 - g.nameX)
  return g
end

-- Stick monitor: LQ block (left), RX battery block (right), gimbal boxes and trims.
function M.sticks(w, h, trims)
  local g = {}
  local sideW = min(max(84, floor(w * 0.19)), 116)
  local tH = lineH(MIDSIZE)

  -- link quality: 30x30 icon, text below it
  local ix = max(0, floor((sideW - 30) / 2)) + 30
  local iy = max(0, floor((h - 30) / 2) - 15)
  local ty = min(max(0, floor(h / 2) + 10), max(0, h - tH))
  g.lqIconX, g.lqIconY = ix, iy
  g.lqTextX = ix - 6
  g.lqIcon = ty >= iy + 30
  if not g.lqIcon then ty = max(0, floor((h - tH) / 2)) end
  g.lqTextY = ty
  local lqRight = g.lqTextX + measure("100%", MIDSIZE)

  -- RX battery: 20x33 icon, text centred under it
  g.rxIconX = w - sideW + 10
  g.rxIconY = max(0, floor((h - 32) / 2) - 15)
  local ry = min(max(0, floor(h / 2) + 10), max(0, h - tH))
  g.rxIcon = ry >= g.rxIconY + 33
  if not g.rxIcon then ry = max(0, floor((h - tH) / 2)) end
  g.rxTextY = ry
  g.rxCx = g.rxIconX + 10
  local rxLeft = g.rxCx - floor(measure("3.85V (4S)", MIDSIZE) / 2)

  -- free band between the two blocks
  local fx1, fx2 = lqRight + 3, rxLeft - 3
  local G = 20                           -- gap between the two boxes
  g.boxes, g.trims = false, false

  if trims then
    local tbw = measure("100", TINSIZE) + 2
    local tbh = lineH(TINSIZE)
    local col = max(9, tbw)              -- vertical trim column width
    local m = (h >= 70) and 5 or 2
    local B = min(h - 2 * m - 12, floor((fx2 - fx1 - G - 2 * (col + 2)) / 2))
    if B >= 24 then
      local W = 2 * (col + 2) + 2 * B + G
      local x0 = floor((w - W) / 2)
      if x0 + W > fx2 then x0 = fx2 - W end
      if x0 < fx1 then x0 = fx1 end
      local y0 = floor((h - (B + 12)) / 2)
      local half = floor(col / 2)
      local bx1 = x0 + col + 2
      local bx2 = bx1 + B + G
      g.trims, g.boxes = true, true
      g.B, g.boxY = B, y0
      g.boxX = { bx1, bx2 }
      g.tbw, g.tbh = tbw, tbh
      local hy = y0 + B + 3 + 4          -- centre line of the horizontal trims
      g.trim = {
        lh = { horiz = true, x = bx1, y = hy, len = B },
        rh = { horiz = true, x = bx2, y = hy, len = B },
        lv = { horiz = false, x = x0 + half, y = y0, len = B },
        rv = { horiz = false, x = bx2 + B + 2 + half, y = y0, len = B },
      }
      g.right = x0 + W
    end
  end

  if not g.boxes then
    local sx, sw = sideW + 6, w - 2 * sideW - 12
    if sw < 64 then sx, sw = 0, w - sideW - 6 end
    local B = min(h - 8, floor((sw - 28) / 2)) - 5
    B = min(B, floor((fx2 - fx1 - G) / 2))
    if B >= 16 then
      local W = 2 * B + G
      local x0 = sx + floor((sw - W) / 2)
      if x0 + W > fx2 then x0 = fx2 - W end
      if x0 < fx1 then x0 = fx1 end
      g.boxes = true
      g.B, g.boxY = B, floor((h - B) / 2)
      g.boxX = { x0, x0 + B + G }
      g.right = x0 + W
    end
  end

  g.rxMinX = g.boxes and (g.right + 3) or (lqRight + 3)
  return g
end

-- 2x4 metric grid (icon + value). Cell list in reading order.
function M.grid(w, h)
  local cells = {}
  local colW, rowH = floor(w / 4), floor(h / 2)
  local tw = measure("1300mAh", SMLSIZE)
  for row = 0, 1 do
    for c = 0, 3 do
      local cx = -4 + c * colW
      local cw = (c == 3) and (w - 3 * colW) or colW
      local cy = row * rowH
      local ch = (row == 1) and (h - rowH) or rowH
      local e = {}
      if ch >= 24 and cw >= 32 + tw then
        local sx = max(cx, cx + floor((cw - 66) / 2))
        e.icon = true
        e.iconX, e.iconY = sx, max(cy, cy + floor((ch - 24) / 2))
        e.textX, e.textY = sx + 32, max(cy, cy + floor((ch - 8) / 2) - 4)
      else
        e.icon = false
        e.textX = max(0, cx + floor((cw - tw) / 2))
        e.textY = max(cy, cy + floor((ch - 17) / 2))
      end
      e.textW = max(0, cx + cw - 1 - e.textX)
      cells[#cells + 1] = e
    end
  end
  return cells
end

-- Timer row with n equal cells (clock icon + text).
function M.timers(w, h, n)
  local cells = {}
  local colW = floor(w / n)
  local tw = measure("00:00", SMLSIZE)
  for i = 0, n - 1 do
    local cx = i * colW
    local cw = (i == n - 1) and (w - (n - 1) * colW) or colW
    local e = { x = cx, w = cw, h = h }
    if h >= 24 and cw >= 36 + tw then
      local sx = max(cx, cx + floor((cw - 66) / 2))
      e.icon = true
      e.iconX, e.iconY = sx, max(0, floor((h - 24) / 2))
      e.textX, e.textY = sx + 32, max(0, floor((h - 8) / 2) - 4)
    else
      e.icon = false
      e.textX = cx + max(0, floor((cw - tw) / 2))
      e.textY = max(0, floor((h - 17) / 2))
    end
    cells[i + 1] = e
  end
  return cells
end

-- Header strip of the full-screen pages (VTX and Throttle), for a screen W px wide:
-- Back, the two tab buttons (the page title when VTX control is off), a status area of
-- two SMLSIZE lines (textX .. textR) and the Reload button of the VTX page on the right.
-- Buttons keep 4 px between them (focus outline 2 px + 1 px).
function M.pageHeader(W)
  local m, h = 3, 42
  local g = { h = h, btnY = m, btnH = h - 2 * m }
  g.backX, g.backW = m, 56
  g.tabX = { m + 60, m + 114 }
  g.tabW = { 50, 80 }
  g.titleX = g.tabX[1] + 4                 -- page title in place of the tabs
  g.textX = g.tabX[2] + g.tabW[2] + 5      -- 202 at 480 px
  g.reloadW = 60
  g.reloadX = W - m - g.reloadW
  g.textR = g.reloadX - 4                  -- texts end here (2 px from the button outline)
  return g
end

-- VTX cell inside a timer cell: line 1 "VTX" + dot + tag, line 2 value (BOLD).
-- Low cells use one line: dot + value (SMLSIZE).
function M.vtxCell(c)
  local v = {}
  local l1, l2 = lineH(SMLSIZE), lineH(BOLD)
  local right = c.x + c.w - 4
  v.two = c.h >= l1 + l2 - 2
  if v.two then
    v.x = c.x + max(2, floor((c.w - 96) / 2))
    v.y1 = max(0, floor((c.h - (l1 + l2)) / 2))
    v.y2 = v.y1 + l1
    v.font = BOLD
    v.dotX = v.x + measure("VTX", SMLSIZE) + 5
    v.dotY = v.y1 + 5
    v.tagX = v.dotX + 12
    v.tagW = max(0, right - v.tagX)
    v.mainX = v.x
  else
    v.x = c.x + max(2, floor((c.w - 70) / 2))
    v.y2 = max(0, floor((c.h - l1) / 2))
    v.font = SMLSIZE
    v.dotX = v.x
    v.dotY = v.y2 + 5
    v.mainX = v.x + 12
  end
  v.mainW = max(0, right - v.mainX)
  return v
end

return M
