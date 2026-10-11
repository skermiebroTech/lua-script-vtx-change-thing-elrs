-- Footer: ELRS module name and version (left), update rate when showFps is on (centre),
-- EdgeTX version (right).

local M = {}

local FPS_W = 60   -- centre label width (px)

local function edgetxVersion()
  if type(getVersion) ~= "function" then return "EdgeTX" end
  local _, _, maj, minor, rev, osname = getVersion()
  if type(maj) ~= "number" or type(minor) ~= "number" or type(rev) ~= "number" then return "EdgeTX" end
  local name = (type(osname) == "string" and osname ~= "") and osname or "EdgeTX"
  return string.format("%s %d.%d.%d", name, math.floor(maj), math.floor(minor), math.floor(rev))
end

-- BOOL option value is on (1 or true).
local function on(v)
  return v == true or (type(v) == "number" and v >= 0.5)
end

function M.build(U, parent, r, wgt)
  local th = U.th
  local ver = edgetxVersion()
  local vw = U.measure(ver, SMLSIZE)
  local lw = vw + 8
  local rx = r.w - 4 - lw                 -- right label box, text right edge at w - 4
  local fx = math.floor(r.w / 2) - math.floor(FPS_W / 2)
  -- left text: starts at x 4, keeps 8 px from the right text and from the centre label
  local maxW = r.w - vw - 16
  if fx - 12 < maxW then maxW = fx - 12 end
  local st = { U = U, src = nil, left = "ELRS", maxW = maxW, fps = "", fpsV = -1 }
  U.label(parent, 4, -1, SMLSIZE, function() return st.left end, th.text)
  U.label(parent, fx, -1, SMLSIZE, function() return st.fps end, th.text, FPS_W, CENTER)
  U.label(parent, rx, -1, SMLSIZE, ver, th.text, lw, RIGHT)
  return st
end

function M.update(st, wgt)
  local E = wgt.E
  local lab = (E ~= nil and E.label) or "ELRS"
  if lab ~= st.src then
    st.src = lab
    st.left = st.U.fit(lab, SMLSIZE, st.maxW)
  end
  -- the text changes at most once per second (wgt.fps is measured in app.lua)
  local o = wgt.options
  if o ~= nil and on(o.showFps) then
    local f = wgt.fps or 0
    if f ~= st.fpsV then
      st.fpsV = f
      if f > 0 then st.fps = string.format("%d Hz", f) else st.fps = "-- Hz" end
    end
  elseif st.fpsV ~= -1 then
    st.fpsV = -1
    st.fps = ""
  end
end

return M
