-- 2x4 metric grid: current, packet rate, TX power, RSSI / satellites, flight mode, SNR, capacity.

local M = {}

local floor = math.floor
local ICONS = { "current", "rfmd", "radio", "signal", "sat", "drone", "noise", "battery" }

local function rnd(v)
  return floor(v + 0.5)
end

function M.build(U, parent, r, wgt)
  local th = U.th
  local g = U.L.grid(r.w, r.h)
  local st = { U = U, th = th, g = g, conn = nil, satCol = th.text, c = {} }
  for i = 1, 8 do
    local e = g[i]
    local cell = { t = "--", k = nil }
    st.c[i] = cell
    if e.icon then
      U.mk("image", parent, { x = e.iconX, y = e.iconY, w = 24, h = 24,
                              file = U.dir .. th.iconDir .. ICONS[i] .. ".png" })
    end
    local color = th.text
    if i == 5 then color = function() return st.satCol end end
    U.label(parent, e.textX, e.textY, SMLSIZE, function() return cell.t end, color)
  end
  return st
end

function M.update(st, wgt)
  local S = wgt.S
  local c = st.c

  if S.connected ~= true then
    if st.conn ~= false then
      st.conn = false
      for i = 1, 8 do
        c[i].t = "--"
        c[i].k = nil
      end
      st.satCol = st.th.text
    end
    return
  end
  st.conn = true

  local v, k, e

  -- current (A)
  v, e = S.curr, c[1]
  k = false
  if v ~= nil then k = rnd(v * 10) end
  if k ~= e.k then
    e.k = k
    e.t = (v ~= nil) and string.format("%.1fA", v) or "--.-A"
  end

  -- packet rate (Hz), raw RF mode when the rate is unknown
  local hz, rf = S.rateHz, S.rfmd
  e = c[2]
  k = false
  if hz ~= nil then k = rnd(hz) elseif rf ~= nil then k = -1 - rnd(rf) end
  if k ~= e.k then
    e.k = k
    if hz ~= nil then e.t = string.format("%dHz", rnd(hz))
    elseif rf ~= nil then e.t = string.format("RF %d", rnd(rf))
    else e.t = "N/A" end
  end

  -- TX power (mW)
  v, e = S.tpwr, c[3]
  k = false
  if v ~= nil then k = rnd(v) end
  if k ~= e.k then
    e.k = k
    e.t = (v ~= nil) and string.format("%dmW", k) or "--mW"
  end

  -- RSSI (dBm), best antenna
  v, e = S.rssi, c[4]
  k = false
  if v ~= nil then k = rnd(v) end
  if k ~= e.k then
    e.k = k
    e.t = (v ~= nil) and string.format("%ddBm", k) or "--"
  end

  -- satellites, colored by count
  e = c[5]
  k = false
  if S.gps == true then k = rnd(S.sats or 0) end
  if k ~= e.k then
    e.k = k
    local th = st.th
    if k ~= false then
      e.t = string.format("%d", k)
      if k < 5 then st.satCol = th.bad elseif k < 8 then st.satCol = th.warn else st.satCol = th.good end
    else
      e.t = "N/A"
      st.satCol = th.text
    end
  end

  -- flight mode
  v, e = S.fm, c[6]
  if v == "" then v = nil end
  k = v or false
  if k ~= e.k then
    e.k = k
    e.t = (v ~= nil) and st.U.fit(v, SMLSIZE, st.g[6].textW) or "---"
  end

  -- SNR (dB); 0 is a valid value
  v, e = S.snr, c[7]
  k = false
  if v ~= nil then k = rnd(v) end
  if k ~= e.k then
    e.k = k
    e.t = (v ~= nil) and string.format("%ddB", k) or "--"
  end

  -- capacity (mAh)
  v, e = S.capa, c[8]
  k = false
  if v ~= nil then k = rnd(v) end
  if k ~= e.k then
    e.k = k
    e.t = (v ~= nil) and string.format("%dmAh", k) or "N/A"
  end
end

return M
