-- Stick monitor: link quality block, RX battery block, two gimbal boxes, four trim bars,
-- and the throttle cap line (wgt.T from lib/thrcap.lua) on the throttle box.

local M = {}

local floor = math.floor
local CONN = { "ok", "warn", "low", "dead" }
-- RX battery states; "none" = a pack voltage without a cell count (grey outline, no bars)
local BAT = { "full", "ok", "warn", "low", "dead", "none" }
local TRIMS = { "lh", "lv", "rv", "rh" }

-- BOOL option value is on (1 or true).
local function on(v)
  return v == true or (type(v) == "number" and v >= 0.5)
end

-- Place the RX text centred under the icon, kept right of the sticks.
-- When "3.85V (12S)" is too wide, use "3.85V(12S)", then "3.85V".
local function placeRx(st, cv, nk)
  local g, measure = st.g, st.U.measure
  local maxW = st.w - 2 - g.rxMinX
  local tw = measure(st.rx, MIDSIZE)
  if tw > maxW and cv ~= nil then
    st.rx = string.format("%.2fV(%dS)", cv, nk)
    tw = measure(st.rx, MIDSIZE)
    if tw > maxW then
      st.rx = string.format("%.2fV", cv)
      tw = measure(st.rx, MIDSIZE)
    end
  end
  local x = g.rxCx - floor(tw / 2)
  if x + tw > st.w - 2 then x = st.w - 2 - tw end
  if x < g.rxMinX then x = g.rxMinX end
  st.rxX, st.rxSX = x, x + 1
end

local function buildTrims(U, parent, g, st)
  local th = U.th
  local bw, bh = g.tbw, g.tbh
  st.tr = {}
  for i = 1, 4 do
    local t = g.trim[TRIMS[i]]
    local len = t.len
    local s = { key = TRIMS[i], horiz = t.horiz, span = len - 9, col = th.focus, on = false, txt = "" }
    if t.horiz then
      U.mk("rectangle", parent, { x = t.x, y = t.y - 2, w = len, h = 4, filled = true, rounded = 2, color = th.track })
      U.mk("vline", parent, { x = t.x + floor(len / 2), y = t.y - 4, w = 1, h = 9, color = th.tick })
      s.base = t.x
      s.mx, s.my = t.x + floor(s.span / 2 + 0.5), t.y - 4
      s.lo, s.hi = t.x, t.x + len - bw          -- text box x at the left / right end
      s.tx, s.ty = s.lo, t.y - floor(bh / 2)
    else
      U.mk("rectangle", parent, { x = t.x - 2, y = t.y, w = 4, h = len, filled = true, rounded = 2, color = th.track })
      U.mk("hline", parent, { x = t.x - 4, y = t.y + floor(len / 2), w = 9, h = 1, color = th.tick })
      s.base = t.y
      s.mx, s.my = t.x - 4, t.y + floor(s.span / 2 + 0.5)
      s.lo, s.hi = t.y, t.y + len - bh          -- text box y at the top / bottom end
      s.tx, s.ty = t.x - floor(bw / 2), s.lo
    end
    local box = U.mk("rectangle", parent, { x = s.tx, y = s.ty, w = bw, h = bh, filled = true, rounded = 2,
                                            color = th.tbox,
                                            visible = function() return s.on end,
                                            pos = function() return s.tx, s.ty end })
    U.mk("label", box, { x = 0, y = 0, w = bw, align = CENTER, font = TINSIZE, color = th.text,
                         text = function() return s.txt end })
    U.mk("rectangle", parent, { x = s.mx, y = s.my, w = 9, h = 9, filled = true, rounded = 2,
                                color = function() return s.col end,
                                pos = function() return s.mx, s.my end })
    st.tr[i] = s
  end
end

-- Throttle cap: a line across the throttle box at cap % of the stick travel from the
-- bottom (stick low gives -100 and full stick gives the cap), and an "NN%" label. The
-- label goes in the gap between the two boxes (no trim bar or LQ/RX block there), or
-- inside the box when the gap is too narrow. Drawn before the boxes: the dot stays on top.
local function buildCap(U, parent, g, st, r)
  local th = U.th
  local span = g.B - 13
  local gapX = g.boxX[1] + g.B
  local gapW = g.boxX[2] - gapX
  local lw = U.measure("95%", TINSIZE)
  local cap = {
    on = false, txt = "", rev = nil, mode = nil, T = nil,
    bottom = g.boxY + 2 + span + 4,      -- dot centre at stick -100
    span = span, gapX = gapX, gapW = gapW, lh = U.L.lineH(TINSIZE),
    inGap = lw <= gapW - 2,
    x = g.boxX[1] + 2, y = g.boxY, lx = gapX, ly = g.boxY, sx = gapX + 1, sy = g.boxY + 1,
  }
  -- theme.cap: YELLOW on the dark wash, a dark amber on the light wash (yellow is not
  -- readable there)
  local col = th.cap or th.warn
  local grp = U.mk("box", parent, { x = 0, y = 0, w = r.w, h = r.h, scrollBar = false, scrollDir = lvgl.SCROLL_OFF,
                                    visible = function() return cap.on end })
  U.mk("hline", grp, { x = cap.x, y = cap.y, w = g.B - 4, h = 2, color = col,
                       pos = function() return cap.x, cap.y end })
  U.labelPos(grp, TINSIZE, function() return cap.txt end, col,
             function() return cap.lx, cap.ly end, function() return cap.sx, cap.sy end)
  st.cap = cap
end

-- Place the cap line for T (nil = no thrcap state) and stick mode 'mode'. Hidden at
-- 100 %, when the cap is unknown, custom, or the input cannot be changed.
local function updateCap(st, T, mode)
  local cap = st.cap
  local c = 0
  if T ~= nil and T.custom ~= true and T.state ~= "none" and T.state ~= "unsupported"
     and type(T.cap) == "number" then
    c = floor(T.cap + 0.5)
  end
  if c < 1 or c > 99 then
    cap.on = false
    return
  end
  local g = st.g
  -- throttle on the right gimbal in modes 1 and 3, on the left one in modes 2 and 4
  local side = 1
  if mode == 1 or mode == 3 then side = 2 end
  local bx = g.boxX[side]
  local y = cap.bottom - floor(c * cap.span / 100 + 0.5)
  cap.x, cap.y = bx + 2, y - 1
  local txt = string.format("%d%%", c)
  cap.txt = txt
  local tw = st.U.measure(txt, TINSIZE)
  local lx, ly
  if cap.inGap then
    lx = cap.gapX + floor((cap.gapW - tw) / 2)
    ly = y - floor(cap.lh / 2)
  else
    if side == 1 then lx = bx + g.B - 3 - tw else lx = bx + 3 end
    ly = y - cap.lh - 1
  end
  if ly < g.boxY then ly = g.boxY end
  if ly > g.boxY + g.B - cap.lh then ly = g.boxY + g.B - cap.lh end
  cap.lx, cap.ly, cap.sx, cap.sy = lx, ly, lx + 1, ly + 1
  cap.on = true
end

function M.build(U, parent, r, wgt)
  local th = U.th
  local opt = wgt.options or {}
  local g = U.L.sticks(r.w, r.h, not on(opt.hideTrims))
  local T = wgt.mods and wgt.mods.telem
  local st = {
    U = U, th = th, g = g, w = r.w,
    -- trim marker beyond the normal range: ACTIVE (dark), dark amber (light)
    extCol = th.extMark or th.active,
    -- below this no pack is plausible (the same limit as the telem cell count)
    packMin = (T ~= nil and type(T.PACK_MIN) == "number") and T.PACK_MIN or 2.5,
    conn = false,
    lq = "--%", lqKey = nil, tpKey = nil, lqIc = nil,
    rx = "--.--V", rxKey = nil, cKey = nil, rxIc = nil,
    rxX = g.rxMinX, rxY = g.rxTextY, rxSX = g.rxMinX + 1, rxSY = g.rxTextY + 1,
  }
  placeRx(st)

  -- LQ and RX blocks: shown only while the link is up
  local grp = U.mk("box", parent, { x = 0, y = 0, w = r.w, h = r.h, scrollBar = false, scrollDir = lvgl.SCROLL_OFF,
                                    visible = function() return st.conn end })
  if g.lqIcon then
    st.lqVis = U.states(grp, g.lqIconX, g.lqIconY, 30, 30, CONN, U.dir .. "icons/link/connection-")
  end
  U.label(grp, g.lqTextX, g.lqTextY, MIDSIZE, function() return st.lq end, th.text)
  if g.rxIcon then
    st.rxVis = U.states(grp, g.rxIconX, g.rxIconY, 20, 33, BAT, U.dir .. "icons/battery/battery-")
  end
  U.labelPos(grp, MIDSIZE, function() return st.rx end, th.text,
             function() return st.rxX, st.rxY end, function() return st.rxSX, st.rxSY end)

  if g.boxes then buildCap(U, parent, g, st, r) end

  -- gimbal boxes: 2 px white outline, 9x9 white dot with a 7x7 dark centre.
  -- Motion trail (trailOff = 0): two faded squares at the dot positions of the last
  -- 2 cycles, made before the dot so that the dot stays on top.
  if g.boxes then
    local B = g.B
    st.span = B - 13
    st.dots = {}
    local trail = not on(opt.trailOff)
    st.trail = trail
    for i = 1, 2 do
      local bx, by = g.boxX[i], g.boxY
      U.mk("rectangle", parent, { x = bx, y = by, w = B, h = B, filled = false, thickness = 2, color = th.stick })
      local c = floor(st.span / 2 + 0.5)
      local dot = { x0 = bx + 2, y0 = by + 2, x = bx + 2 + c, y = by + 2 + c }
      if trail then
        local g1 = { x = dot.x, y = dot.y }
        local g2 = { x = dot.x, y = dot.y }
        U.mk("rectangle", parent, { x = g2.x, y = g2.y, w = 9, h = 9, filled = true, color = th.stick,
                                    opacity = 50, pos = function() return g2.x, g2.y end })
        U.mk("rectangle", parent, { x = g1.x, y = g1.y, w = 9, h = 9, filled = true, color = th.stick,
                                    opacity = 110, pos = function() return g1.x, g1.y end })
        dot.g1, dot.g2 = g1, g2
      end
      local o = U.mk("rectangle", parent, { x = dot.x, y = dot.y, w = 9, h = 9, filled = true, color = th.stick,
                                            pos = function() return dot.x, dot.y end })
      U.mk("rectangle", o, { x = 1, y = 1, w = 7, h = 7, filled = true, color = th.dotIn })
      st.dots[i] = dot
    end
  end

  if g.trims then buildTrims(U, parent, g, st) end
  return st
end

local function updateLinkBlocks(st, S)
  local lq, tp = S.lq, S.tpwr
  local lk = -1
  if lq ~= nil then lk = floor(lq + 0.5) end
  local tk = (tp ~= nil and tp > 0) and 1 or 0
  if lk ~= st.lqKey or tk ~= st.tpKey then
    st.lqKey, st.tpKey = lk, tk
    st.lq = (lq ~= nil) and string.format("%d%%", lk) or "--%"
    local ic = "ok"
    if tk == 0 then ic = "dead" elseif lk < 60 then ic = "low" elseif lk < 80 then ic = "warn" end
    if ic ~= st.lqIc then
      st.U.show(st.lqVis, st.lqIc, ic)
      st.lqIc = ic
    end
  end

  local v, n, cv = S.rxV, S.cells, S.cellV
  local vk = -1
  if v ~= nil then vk = floor(v * 100 + 0.5) end
  local nk = 0
  if n ~= nil then nk = floor(n + 0.5) end
  if vk ~= st.rxKey or nk ~= st.cKey then
    st.rxKey, st.cKey = vk, nk
    local ic = "dead"
    local p = nil
    if v == nil or v < 0 then
      st.rx = "--.--V"
    else
      if nk > 0 and cv ~= nil then
        st.rx = string.format("%.2fV (%dS)", cv, nk)
        p = cv
      else
        st.rx = string.format("%.2fV", v)
      end
      if v < 0.05 then ic = "dead"
      elseif p == nil then
        -- no cell count: a reading that cannot be a pack is shown as dead; a pack
        -- voltage gets the neutral icon (no charge level is known without a count)
        if v < st.packMin then ic = "dead" else ic = "none" end
      elseif p > 4.0 then ic = "full"
      elseif p > 3.7 then ic = "ok"
      elseif p > 3.5 then ic = "warn"
      elseif p > 3.3 then ic = "low"
      end
    end
    placeRx(st, p, nk)
    if ic ~= st.rxIc then
      st.U.show(st.rxVis, st.rxIc, ic)
      st.rxIc = ic
    end
  end
end

local function clamp(v)
  if v == nil then return 0 end
  if v > 100 then return 100 end
  if v < -100 then return -100 end
  return v
end

function M.update(st, wgt)
  local S, I = wgt.S, wgt.I
  local c = S.connected == true
  st.conn = c
  if c then updateLinkBlocks(st, S) end
  -- cap line: only when the thrcap state or the stick mode changed
  local cap = st.cap
  if cap ~= nil then
    local T = wgt.T
    local rev = -1
    if T ~= nil then rev = T.rev end
    local mode = 2
    if I ~= nil then mode = I.mode end
    if rev ~= cap.rev or mode ~= cap.mode or T ~= cap.T then
      cap.rev, cap.mode, cap.T = rev, mode, T
      updateCap(st, T, mode)
    end
  end
  if I == nil then return end
  -- trail: each cycle the faded squares take the dot positions of the last 2 cycles, also
  -- when the stick stopped (they then reach the dot after 2 cycles and hide under it)
  local dots = st.dots
  if st.trail and dots ~= nil and st.trailOn then
    for i = 1, 2 do
      local d = dots[i]
      local g1, g2 = d.g1, d.g2
      g2.x, g2.y = g1.x, g1.y
      g1.x, g1.y = d.x, d.y
    end
  end
  -- I.changed counts input changes: skip the dot and trim math when it did not move
  local ic = I.changed
  if ic ~= nil then
    if ic == st.ichg then return end
    st.ichg = ic
  end

  if dots ~= nil then
    local span = st.span
    -- the throttle dot shows the throttle output (I.thrOut, the cap applied) when it is
    -- known, so it stops at the cap line; throttle is the right gimbal in modes 1 and 3
    local out = I.thrOut
    local thrSide = 1
    if I.mode == 1 or I.mode == 3 then thrSide = 2 end
    local p, d = I.left, dots[1]
    if p ~= nil then
      local y = p.y
      if out ~= nil and thrSide == 1 then y = out end
      d.x = d.x0 + floor((clamp(p.x) + 100) * span / 200 + 0.5)
      d.y = d.y0 + floor((100 - clamp(y)) * span / 200 + 0.5)
    end
    p, d = I.right, dots[2]
    if p ~= nil then
      local y = p.y
      if out ~= nil and thrSide == 2 then y = out end
      d.x = d.x0 + floor((clamp(p.x) + 100) * span / 200 + 0.5)
      d.y = d.y0 + floor((100 - clamp(y)) * span / 200 + 0.5)
    end
    -- first update after a build: the trail starts under the dot, not at the box centre
    if st.trail and not st.trailOn then
      st.trailOn = true
      for i = 1, 2 do
        local t = dots[i]
        t.g1.x, t.g1.y, t.g2.x, t.g2.y = t.x, t.y, t.x, t.y
      end
    end
  end

  local tr = st.tr
  local val, txt = I.trim, I.trimTxt
  if tr ~= nil and val ~= nil then
    local th = st.th
    local ext = I.trimExt == true
    for i = 1, 4 do
      local s = tr[i]
      local v = clamp(val[s.key])
      if s.horiz then
        s.mx = s.base + floor((v + 100) * s.span / 200 + 0.5)
        if v < 0 then s.tx = s.hi else s.tx = s.lo end
      else
        s.my = s.base + floor((100 - v) * s.span / 200 + 0.5)
        if v > 0 then s.ty = s.hi else s.ty = s.lo end
      end
      s.col = (ext and (v > 25 or v < -25)) and st.extCol or th.focus
      local t = (txt ~= nil and txt[s.key]) or ""
      s.txt = t
      s.on = t ~= ""
    end
  end
end

return M
