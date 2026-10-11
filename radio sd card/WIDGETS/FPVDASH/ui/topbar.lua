-- Top bar: model name, TX battery icon + voltage, link icon, clock and date.

local M = {}

local floor = math.floor
local BAT = { "full", "ok", "warn", "low", "dead" }
local BAT_OK = { full = true, ok = true, warn = true, low = true, dead = true }

function M.build(U, parent, r, wgt)
  local th = U.th
  local g = U.L.topbar(r.w, r.h)
  local st = {
    U = U, th = th, g = g,
    name = "", nameSrc = nil,
    tx = "--.-V", txKey = nil, txColor = th.warn,
    batSrc = nil, batKey = nil,
    link = false, nolink = true,
    clock = "--:--", date = "",
  }

  if g.nameW > 0 then
    U.label(parent, g.nameX, g.nameY, g.nameFont, function() return st.name end, th.text)
  end
  if g.batShow then
    st.batVis = U.states(parent, g.batX, g.batY, 20, 33, BAT, U.dir .. "icons/battery/battery-")
  end
  if g.txShow then
    U.label(parent, g.txX, g.txY, MIDSIZE, function() return st.tx end, function() return st.txColor end)
  end
  if g.linkShow then
    local ic = U.dir .. th.iconDir
    U.mk("image", parent, { x = g.linkX, y = g.linkY, w = 24, h = 24, file = ic .. "link.png",
                            visible = function() return st.link end })
    U.mk("image", parent, { x = g.linkX, y = g.linkY, w = 24, h = 24, file = ic .. "link_off.png",
                            visible = function() return st.nolink end })
  end
  if g.clkShow then
    U.label(parent, g.clkX, g.clkY, SMLSIZE, function() return st.clock end, th.text, g.clkW, RIGHT)
    if g.dateShow then
      U.label(parent, g.clkX, g.dateY, SMLSIZE, function() return st.date end, th.text, g.clkW, RIGHT)
    end
  end
  return st
end

function M.update(st, wgt)
  local S = wgt.S

  local name = S.modelName or "MODEL"
  if name ~= st.nameSrc then
    st.nameSrc = name
    st.name = st.U.fit(name, st.g.nameFont, st.g.nameW)
  end

  local v = S.txV
  local k = false
  if v ~= nil then k = floor(v * 10 + 0.5) end
  if k ~= st.txKey then
    st.txKey = k
    if v ~= nil then
      st.tx = string.format("%.1fV", v)
      st.txColor = st.th.text
    else
      st.tx = "--.-V"
      st.txColor = st.th.warn
    end
  end

  local bs = S.txState
  if bs ~= st.batSrc then
    st.batSrc = bs
    local key = BAT_OK[bs] and bs or "ok"
    if key ~= st.batKey then
      st.U.show(st.batVis, st.batKey, key)
      st.batKey = key
    end
  end

  local c = S.connected == true
  if c ~= st.link then
    st.link = c
    st.nolink = not c
  end

  st.clock = S.clock or "--:--"
  st.date = S.date or ""
end

return M
