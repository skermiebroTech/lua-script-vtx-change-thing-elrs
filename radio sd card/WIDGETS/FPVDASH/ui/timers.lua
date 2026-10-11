-- Timer row: timer 1..3 (clock icon + time) and, when VTX control is on, the VTX status cell.

local M = {}

local floor = math.floor

-- Short value text when the VTX values are not valid.
local STATE_TXT = {
  off = "--", nocrsf = "NO CRSF", search = "--", noelrs = "NO ELRS", novtx = "NO VTX",
  load = "--", ready = "--", busy = "--", error = "ERROR",
}

local function rnd(v)
  return floor(v + 0.5)
end

-- BOOL option value is on (1 or true).
local function on(v)
  return v == true or (type(v) == "number" and v >= 0.5)
end

local function fmtTimer(sec)
  local neg = sec < 0
  if neg then sec = -sec end
  local h = floor(sec / 3600)
  local m = floor((sec - h * 3600) / 60)
  local s = sec - h * 3600 - m * 60
  local t
  if h > 0 then
    t = string.format("%d:%02d:%02d", h, m, s)
  else
    t = string.format("%02d:%02d", m, s)
  end
  if neg then t = "-" .. t end
  return t
end

local function buildVtx(U, parent, c, st)
  local th = U.th
  local v = U.L.vtxCell(c)
  st.vg = v
  if v.two then
    U.label(parent, v.x, v.y1, SMLSIZE, "VTX", th.muted)
    if v.tagW >= 10 then
      U.label(parent, v.tagX, v.y1, SMLSIZE, function() return st.tag end,
              function() return st.tagCol end, v.tagW, RIGHT)
    end
  end
  U.mk("rectangle", parent, { x = v.dotX, y = v.dotY, w = 8, h = 8, filled = true, rounded = 4,
                              color = function() return st.dotCol end })
  U.label(parent, v.mainX, v.y2, v.font, function() return st.main end, th.text)
end

function M.build(U, parent, r, wgt)
  local th = U.th
  local opt = wgt.options or {}
  local vtxOn = wgt.vtxOn                -- set by app.lua from the vtxOff option
  if vtxOn == nil then vtxOn = not on(opt.vtxOff) end
  local n = vtxOn and 4 or 3
  local g = U.L.timers(r.w, r.h, n)
  local st = {
    U = U, th = th, c = {},
    vtx = vtxOn, vrev = nil, vstate = nil,
    main = "--", tag = "", tagCol = th.text, dotCol = th.muted,
  }
  local clock = U.dir .. th.iconDir .. "clock.png"
  for i = 1, 3 do
    local e = g[i]
    local cell = { t = "--:--", k = nil }
    st.c[i] = cell
    if e.icon then
      U.mk("image", parent, { x = e.iconX, y = e.iconY, w = 24, h = 24, file = clock })
    end
    U.label(parent, e.textX, e.textY, SMLSIZE, function() return cell.t end, th.text)
  end
  if vtxOn then buildVtx(U, parent, g[4], st) end
  return st
end

local function dotColor(th, s)
  if s == "ready" then return th.good end
  if s == "busy" or s == "search" or s == "load" then return th.warn end
  if s == "error" then return th.bad end
  return th.muted
end

local function updateVtx(st, V)
  local th, U, g = st.th, st.U, st.vg
  local s = V.state
  st.dotCol = dotColor(th, s)

  local main, tag, pitOn = nil, "", false
  local band = rnd(V.band or 0)
  if V.ready == true then
    if band <= 0 then
      main = "OFF"
    else
      local letter = V.bandLetter or ""
      local ch = rnd(V.channel or 0)
      local f = rnd(V.freq or 0)
      if ch > 0 and f > 0 then
        main = string.format("%s%d %d", letter, ch, f)
        if U.measure(main, g.font) > g.mainW then main = string.format("%s%d", letter, ch) end
      elseif ch > 0 then
        main = string.format("%s%d", letter, ch)
      else
        main = letter
      end
      local pw = rnd(V.power or 0)
      if pw > 0 then
        local lab = V.powerLabels and V.powerLabels[pw + 1]
        if type(lab) ~= "string" or lab == "" then lab = string.format("%d", pw) end
        tag = "P" .. lab
        local pit = rnd(V.pit or 0)
        if pit > 0 then
          local p = "PIT"
          if pit >= 2 then p = string.format("PIT:A%d", floor((pit - 2) / 2) + 1) end
          pitOn = true
          tag = tag .. " " .. p
          if g.tagW ~= nil and U.measure(tag, SMLSIZE) > g.tagW then tag = p end
        end
      end
    end
  else
    main = STATE_TXT[s] or "--"
  end
  st.main = U.fit(main, g.font, g.mainW)
  if g.tagW ~= nil then st.tag = U.fit(tag, SMLSIZE, g.tagW) end
  -- the power level is data: text color, not the muted header color
  st.tagCol = pitOn and th.warn or th.text
end

function M.update(st, wgt)
  local S = wgt.S
  local T = S.timers
  local c = st.c
  for i = 1, 3 do
    local e = c[i]
    local tm = T and T[i]
    local sec = tm and tm.sec
    local k = false
    if sec ~= nil then k = floor(sec) end
    if k ~= e.k then
      e.k = k
      e.t = (k ~= false) and fmtTimer(k) or "--:--"
    end
  end

  if st.vtx then
    local V = wgt.V
    if V == nil then
      if st.vrev ~= false then
        st.vrev, st.vstate = false, nil
        st.main, st.tag, st.dotCol, st.tagCol = "--", "", st.th.muted, st.th.text
      end
    elseif V.rev ~= st.vrev or V.state ~= st.vstate then
      st.vrev, st.vstate = V.rev, V.state
      updateVtx(st, V)
    end
  end
end

return M
