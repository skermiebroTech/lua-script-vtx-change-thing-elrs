-- Dashboard unit test (desktop Lua 5.5): builds the LVGL dashboard with a strict mock.
-- Run from the project root:  lua tests/unit/dash_test.lua

local ROOT = (arg and arg[0] and string.match(arg[0], "^(.*)/tests/unit/[^/]*$")) or "."
package.path = ROOT .. "/tests/unit/?.lua;" .. package.path

local mock = require("dash_mock")
local SD = ROOT .. "/radio sd card"
mock.install(SD)

local WD = SD .. "/WIDGETS/FPVDASH/"
local theme = dofile(WD .. "ui/theme.lua")
local layout = dofile(WD .. "ui/layout.lua")
local dash = dofile(WD .. "ui/dash.lua")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. msg)
  end
end
local function eq(a, b, msg)
  check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

------------------------------------------------------------------------------------------
-- test data
------------------------------------------------------------------------------------------
local function baseS()
  return {
    connected = true, rxV = 15.4, cells = 4, cellV = 3.85, lq = 100, rssi1 = -65, rssi2 = -70,
    rssi = -65, snr = 10, rfmd = 7, rateHz = 250, tpwr = 250, curr = 12.3, capa = 1300,
    sats = nil, gps = false, fm = "ACRO", ant = 0, txV = 7.8, txState = "ok", modelName = "75",
    timers = { { sec = 0 }, { sec = 312 }, { sec = nil } }, clock = "12:34", date = "2 Oct", changed = 0,
  }
end
local function baseI()
  return { mode = 2, left = { x = 0, y = -100 }, right = { x = 0, y = 0 },
           trim = { lh = 0, lv = 0, rv = 0, rh = 0 }, trimTxt = { lh = "", lv = "", rv = "", rh = "" },
           trimExt = false }
end
local function baseE()
  return { found = true, label = "RM TX15 4.1.0", version = "4.1.0", armed = false }
end
local function baseV()
  return { state = "ready", msg = "Ready", ready = true,
           bandLabels = { "Disabled", "A", "B", "E", "F", "R", "L" }, band = 5, bandLetter = "R",
           channel = 4, powerLabels = { "-", "1", "2", "3" }, power = 2, pitLabels = { "Off", "On" },
           pit = 0, freq = 5769, send = "idle", sendMsg = "", rev = 1 }
end

-- lib/thrcap.lua state (contract fields)
local function baseT()
  return { state = "ok", msg = "Ready", cap = 75, custom = false, weight = 75, offset = -25, pending = nil,
           input = 2, rev = 1 }
end

local function newWgt(w, h, opts)
  local o = { darkTheme = 1, transpLevel = 4, vtxOff = 0, hideTrims = 0, rxCells = 0, extTrims = 0 }
  for k, v in pairs(opts or {}) do o[k] = v end
  local wgt = { zone = { x = 0, y = 0, w = w, h = h }, options = o, dir = "WIDGETS/FPVDASH/",
                S = baseS(), I = baseI(), E = baseE(), V = baseV(), T = baseT() }
  wgt.theme = theme.resolve(o)
  wgt.mods = { theme = theme, layout = layout, dash = dash }
  return wgt
end

local function build(wgt)
  mock.reset()
  local d
  local n = mock.countInstr(function()
    d = dash.build(wgt)
    d.update(wgt)                       -- app.lua calls update right after build
  end)
  mock.poll()
  mock.layout()
  return d, n
end

local function tick(d, wgt)
  local n = mock.countInstr(function()
    d.update(wgt)
    mock.poll()
  end)
  mock.layout()
  return n
end

-- object helpers
local function region(o)
  while o.parent do o = o.parent end
  return o
end
local function find(pred)
  local r = {}
  for _, o in ipairs(mock.objects) do
    if pred(o) then r[#r + 1] = o end
  end
  return r
end
local function visibleLabel(text)
  for _, o in ipairs(mock.objects) do
    if o.kind == "label" and o.avis and o.text == text and o.color ~= wgt_shadow then return o end
  end
end
local function mainLabels(text)
  -- main label = the one whose color is not the shadow color (dark theme: BLACK)
  return find(function(o) return o.kind == "label" and o.avis and o.text == text and o.color ~= BLACK end)
end
local function imagesNamed(suffix)
  return find(function(o)
    return o.kind == "image" and o.file and string.sub(o.file, -#suffix) == suffix
  end)
end
local function visibleOf(list)
  local r = {}
  for _, o in ipairs(list) do if o.avis then r[#r + 1] = o end end
  return r
end
local function overlap(a, b)
  return a.ax < b.ax + b.aw and b.ax < a.ax + a.aw and a.ay < b.ay + b.ah and b.ay < a.ay + a.ah
end
local function textRect(o)
  return { ax = o.tx, ay = o.ay, aw = o.tw, ah = o.ah }
end

------------------------------------------------------------------------------------------
-- 1. 480x320, dark, VTX on, trims on: geometry against the spec
------------------------------------------------------------------------------------------
do
  local wgt = newWgt(480, 320)
  local d, nBuild = build(wgt)
  print(string.format("480x320 build: %d objects, %d VM instructions (UI files)", #mock.objects, nBuild))
  check(#mock.objects < 150, "object count < 150 (" .. #mock.objects .. ")")
  check(nBuild < 12000, "build instructions < 12000 (" .. nBuild .. ")")
  eq(#mock.violations, 0, "no controls in the dashboard")

  -- washes
  local washes = {}
  for _, o in ipairs(mock.roots) do
    if o.kind == "rectangle" and o.p.filled == true then washes[#washes + 1] = o end
  end
  eq(#washes, 5, "5 wash rectangles")
  local want = { { 0, 0, 480, 44 }, { 0, 46, 480, 102 }, { 0, 150, 480, 106 }, { 0, 258, 480, 44 }, { 0, 304, 480, 16 } }
  for i, r in ipairs(want) do
    local o = washes[i]
    check(o and o.ax == r[1] and o.ay == r[2] and o.w == r[3] and o.h == r[4],
          string.format("wash %d at %d,%d,%d,%d", i, r[1], r[2], r[3], r[4]))
    check(o and o.p.opacity == 51 and o.p.color == BLACK, "wash " .. i .. " BLACK opacity 51 (transpLevel 4)")
  end

  -- top bar
  local name = mainLabels("75")[1]
  check(name and name.ax == 56 and name.ay == 4 and name.font == DBLSIZE, "model name at 56,4 DBLSIZE")
  local bats = find(function(o) return o.kind == "image" and region(o) == washes[1]
                    and string.find(o.file, "battery-", 1, true) end)
  eq(#bats, 5, "5 TX battery state images")
  local vb = visibleOf(bats)
  check(#vb == 1 and vb[1].ax == 293 and vb[1].ay == 6 and string.find(vb[1].file, "battery-ok", 1, true),
        "TX battery ok icon at 293,6")
  local tx = mainLabels("7.8V")[1]
  check(tx and tx.ax == 323 and tx.ay == 8 and tx.font == MIDSIZE, "TX voltage at 323,8 MIDSIZE")
  local link = visibleOf(imagesNamed("dark/link.png"))
  check(#link == 1 and link[1].ax == 386 and link[1].ay == 10, "link icon at 386,10")
  eq(#visibleOf(imagesNamed("dark/link_off.png")), 0, "link_off hidden when connected")
  local clk = mainLabels("12:34")[1]
  check(clk and clk.tx + clk.tw == 471 and clk.ay == 4, "clock right edge 471, y 4")
  local date = mainLabels("2 Oct")[1]
  check(date and date.tx + date.tw == 471 and date.ay == 17, "date right edge 471, y 17")

  -- sticks region
  local lqi = visibleOf(find(function(o) return o.kind == "image" and string.find(o.file, "connection-", 1, true) end))
  check(#lqi == 1 and lqi[1].ax == 60 and lqi[1].ay == 67 and string.find(lqi[1].file, "connection-ok", 1, true),
        "LQ ok icon at 60,67")
  local lqt = mainLabels("100%")[1]
  check(lqt and lqt.ax == 54 and lqt.ay == 107, "LQ text at 54,107")
  local rxi = visibleOf(find(function(o) return o.kind == "image" and region(o) == washes[2]
                             and string.find(o.file, "battery-", 1, true) end))
  check(#rxi == 1 and rxi[1].ax == 399 and rxi[1].ay == 66 and string.find(rxi[1].file, "battery-ok", 1, true),
        "RX battery ok icon at 399,66")
  local rxt = mainLabels("3.85V (4S)")[1]
  check(rxt and math.abs(rxt.ax + rxt.tw / 2 - 409) <= 1 and rxt.ay == 107, "RX text centred at 409, y 107")
  local boxes = find(function(o) return o.kind == "rectangle" and o.p.filled == false end)
  eq(#boxes, 2, "2 gimbal boxes")
  check(boxes[1].ax == 150 and boxes[1].ay == 51 and boxes[1].w == 80, "left gimbal box 150,51 80x80")
  check(boxes[2].ax == 250 and boxes[2].ay == 51 and boxes[2].w == 80, "right gimbal box 250,51 80x80")
  local dots = find(function(o) return o.kind == "rectangle" and o.w == 9 and o.p.pos and o.p.rounded == nil and o.p.opacity == nil end)
  eq(#dots, 2, "2 gimbal dots")
  -- left stick: x 0 (centre), y -100 (bottom); right stick centred
  check(dots[1].ax + 4 == 190 and dots[1].ay + 4 == 124, "left dot centre 190,124")
  check(dots[2].ax + 4 == 290 and dots[2].ay + 4 == 91, "right dot centre 290,91")
  local tracks = find(function(o) return o.kind == "rectangle" and o.p.filled == true and o.p.rounded == 2
                      and (o.w == 4 or o.h == 4) end)
  eq(#tracks, 4, "4 trim tracks")
  local markers = find(function(o) return o.kind == "rectangle" and o.w == 9 and o.h == 9 and o.p.rounded == 2 end)
  eq(#markers, 4, "4 trim markers")
  -- trims centred: marker centre = track centre
  for i, t in ipairs(tracks) do
    local m = markers[i]
    local tcx, tcy = t.ax + t.aw // 2, t.ay + t.ah // 2
    check(math.abs(m.ax + 4 - tcx) <= 1 and math.abs(m.ay + 4 - tcy) <= 1, "trim marker " .. i .. " centred")
  end

  -- grid
  local gridIcons = find(function(o) return o.kind == "image" and region(o) == washes[3] end)
  eq(#gridIcons, 8, "8 grid icons")
  local gx = { 23, 143, 263, 383 }
  for i, o in ipairs(gridIcons) do
    local col = (i - 1) % 4 + 1
    local y = (i <= 4) and 164 or 217
    check(o.ax == gx[col] and o.ay == y, string.format("grid icon %d at %d,%d (got %d,%d)", i, gx[col], y, o.ax, o.ay))
  end
  local texts = { "12.3A", "250Hz", "250mW", "-65dBm", "N/A", "ACRO", "10dB", "1300mAh" }
  for i, t in ipairs(texts) do
    local col = (i - 1) % 4 + 1
    local y = (i <= 4) and 168 or 221
    local o = mainLabels(t)[1]
    check(o and o.ax == gx[col] + 32 and o.ay == y, "grid text '" .. t .. "' position")
  end

  -- timers + VTX cell
  local clocks = find(function(o) return o.kind == "image" and string.find(o.file, "clock.png", 1, true) end)
  eq(#clocks, 3, "3 clock icons")
  for i, x in ipairs({ 27, 147, 267 }) do
    check(clocks[i] and clocks[i].ax == x and clocks[i].ay == 268, "timer icon " .. i .. " at " .. x .. ",268")
  end
  local t1 = mainLabels("00:00")[1]
  check(t1 and t1.ax == 59 and t1.ay == 272, "timer 1 text at 59,272")
  check(mainLabels("05:12")[1] ~= nil, "timer 2 shows 05:12")
  check(mainLabels("--:--")[1] ~= nil, "unused timer 3 shows --:--")
  local vt = find(function(o) return o.kind == "label" and o.text == "VTX" and o.color == wgt.theme.muted end)[1]
  check(vt and vt.ax == 372 and vt.ay == 262, "VTX label at 372,262")
  local vm = mainLabels("R4 5769")[1]
  check(vm and vm.ax == 372 and vm.ay == 279 and vm.font == BOLD, "VTX value 'R4 5769' at 372,279 BOLD")
  local vtag = mainLabels("P2")[1]
  check(vtag and vtag.tx + vtag.tw == 476, "VTX power tag right edge 476")
  -- the power level is data: text color (the muted color is for the header only)
  check(vtag and vtag.color == wgt.theme.text, "VTX power tag in the text color")
  -- GREY draws #404040 and DARKGREY #606060 in EdgeTX 2.12: the theme greys are RGB values
  check(wgt.theme.muted ~= GREY and wgt.theme.track ~= GREY and wgt.theme.muted ~= DARKGREY,
    "theme greys are not the swapped GREY/DARKGREY constants")

  -- footer
  local fl = mainLabels("RM TX15 4.1.0")[1]
  check(fl and fl.ax == 4 and fl.ay == 303, "footer left at 4,303")
  local fr = mainLabels("EdgeTX 2.12.0")[1]
  check(fr and fr.tx + fr.tw == 476 and fr.ay == 303, "footer right edge 476")

  -- distinct image files visible at once
  local files = {}
  local nf = 0
  for _, o in ipairs(mock.objects) do
    if o.kind == "image" and o.avis and not files[o.file] then files[o.file] = true nf = nf + 1 end
  end
  print("480x320 distinct visible image files: " .. nf)
end

------------------------------------------------------------------------------------------
-- 2. 480x320 without trims / without VTX: old geometry
------------------------------------------------------------------------------------------
do
  local wgt = newWgt(480, 320, { hideTrims = 1, vtxOff = 1 })
  build(wgt)
  local boxes = find(function(o) return o.kind == "rectangle" and o.p.filled == false end)
  check(#boxes == 2 and boxes[1].ax == 141 and boxes[1].ay == 52 and boxes[1].w == 89, "no trims: left box 141,52 89")
  check(#boxes == 2 and boxes[2].ax == 250 and boxes[2].ay == 52, "no trims: right box 250,52")
  local clocks = find(function(o) return o.kind == "image" and string.find(o.file, "clock.png", 1, true) end)
  for i, x in ipairs({ 47, 207, 367 }) do
    check(clocks[i] and clocks[i].ax == x and clocks[i].ay == 268, "3 timers: icon " .. i .. " at " .. x)
  end
  eq(#find(function(o) return o.kind == "label" and o.text == "VTX" end), 0, "no VTX cell when vtxOff = 1")
end

------------------------------------------------------------------------------------------
-- 3. data scenarios at 480x320
------------------------------------------------------------------------------------------
do
  local wgt = newWgt(480, 320)
  local d = build(wgt)
  local S, I, V = wgt.S, wgt.I, wgt.V

  -- disconnected
  S.connected = false
  tick(d, wgt)
  eq(#visibleOf(find(function(o) return o.kind == "image" and string.find(o.file, "connection-", 1, true) end)), 0,
     "LQ icon hidden when disconnected")
  eq(#mainLabels("100%"), 0, "LQ text hidden when disconnected")
  eq(#mainLabels("--"), 8, "grid shows -- in all 8 cells when disconnected")
  eq(#visibleOf(imagesNamed("dark/link_off.png")), 1, "link_off shown when disconnected")

  -- connected, all values missing
  S.connected = true
  S.rxV, S.cells, S.cellV, S.lq, S.rssi, S.snr, S.rfmd, S.rateHz, S.tpwr, S.curr, S.capa, S.fm =
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
  S.txV, S.txState = nil, "low"
  tick(d, wgt)
  check(#mainLabels("--%") == 1, "LQ --%")
  check(#mainLabels("--.--V") == 1, "RX --.--V")
  check(#mainLabels("--.-A") == 1, "current --.-A")
  check(#mainLabels("--mW") == 1, "tpwr --mW")
  check(#mainLabels("---") == 1, "FM ---")
  local txl = mainLabels("--.-V")[1]
  check(txl and txl.color == YELLOW, "TX voltage --.-V in warn color")
  local lqi = visibleOf(find(function(o) return o.kind == "image" and string.find(o.file, "connection-", 1, true) end))
  check(#lqi == 1 and string.find(lqi[1].file, "dead", 1, true), "LQ icon dead when TPWR missing")

  -- unverified rate, SNR 0, GPS, long names, hours/negative timers
  S.rfmd, S.rateHz, S.snr, S.gps, S.sats = 12, nil, 0, true, 6
  S.modelName = "100% pro gemini"
  S.timers = { { sec = 3661 }, { sec = -5 }, { sec = 59.7 } }
  S.fm = "VERY LONG FLIGHT MODE NAME"
  wgt.E.label = "RadioMaster Internal ELRS TX Module 4.1.0 extra"
  tick(d, wgt)
  check(#mainLabels("RF 12") == 1, "unknown rate shows RF 12")
  check(#mainLabels("0dB") == 1, "SNR 0 shows 0dB")
  local sat = mainLabels("6")[1]
  check(sat and sat.color == YELLOW, "6 sats in warn color")
  local satShadow = find(function(o) return o.kind == "label" and o.text == "6" and o.color == BLACK end)
  eq(#satShadow, 1, "sat shadow uses theme shadow (BLACK)")
  check(#mainLabels("1:01:01") == 1, "timer hours 1:01:01")
  check(#mainLabels("-00:05") == 1, "negative timer -00:05")
  check(#mainLabels("00:59") == 1, "fractional timer floored")
  local nm = find(function(o) return o.kind == "label" and o.font == DBLSIZE and o.color ~= BLACK end)[1]
  check(nm and nm.ax + nm.tw <= 289, "long model name truncated before the battery icon (" ..
        tostring(nm and nm.text) .. ")")
  local fm = find(function(o) return o.kind == "label" and region(o).ay == 150 and string.find(o.text, "VERY", 1, true)
                  and o.color ~= BLACK end)[1]
  check(fm and fm.ax + fm.tw <= 476, "long FM text fits its cell")
  local fl = find(function(o) return o.kind == "label" and region(o).ay == 304 and o.ax == 4 end)[1]
  local fr = mainLabels("EdgeTX 2.12.0")[1]
  check(fl and fr and fl.ax + fl.tw + 8 <= fr.tx, "long ELRS label does not reach the EdgeTX label")

  -- RX battery 12S and states
  S.rxV, S.cells, S.cellV, S.lq, S.tpwr = 39.6, 12, 3.3, 55, 25
  tick(d, wgt)
  local rxt = mainLabels("3.30V (12S)")[1]
  check(rxt ~= nil, "RX 12S text")
  local rxi = visibleOf(find(function(o) return o.kind == "image" and region(o).ay == 46
                             and string.find(o.file, "battery-", 1, true) end))
  check(#rxi == 1 and string.find(rxi[1].file, "dead", 1, true), "RX 3.30 V/cell -> dead icon")
  -- no cell count and a reading that cannot be a pack (below telem PACK_MIN 2.5 V): dead
  S.rxV, S.cells, S.cellV = 0.4, nil, nil
  tick(d, wgt)
  local rx04 = visibleOf(find(function(o) return o.kind == "image" and region(o).ay == 46
                              and string.find(o.file, "battery-", 1, true) end))
  check(#rx04 == 1 and string.find(rx04[1].file, "dead", 1, true), "RX 0.40 V without cells -> dead icon")
  S.rxV = 7.9
  tick(d, wgt)
  local rx79 = visibleOf(find(function(o) return o.kind == "image" and region(o).ay == 46
                              and string.find(o.file, "battery-", 1, true) end))
  -- a pack voltage without a cell count: neutral icon (grey outline), no charge level
  check(#rx79 == 1 and string.find(rx79[1].file, "battery-none", 1, true), "RX 7.9 V without cells -> neutral icon")
  check(mainLabels("7.90V")[1] ~= nil, "RX 7.9 V without cells -> total voltage text 7.90V")
  -- a cell count again: the neutral icon goes away
  S.rxV, S.cells, S.cellV = 16.4, 4, 4.1
  tick(d, wgt)
  local rx16 = visibleOf(find(function(o) return o.kind == "image" and region(o).ay == 46
                              and string.find(o.file, "battery-", 1, true) end))
  check(#rx16 == 1 and string.find(rx16[1].file, "battery-full", 1, true), "RX 4.10 V/cell (4S) -> full icon")
  S.rxV, S.cells, S.cellV = 39.6, 12, 3.3
  tick(d, wgt)
  local lqi2 = visibleOf(find(function(o) return o.kind == "image" and string.find(o.file, "connection-", 1, true) end))
  check(#lqi2 == 1 and string.find(lqi2[1].file, "low", 1, true), "LQ 55 -> low icon")
  -- nothing in the stick cluster may overlap the LQ or RX blocks
  local lq = mainLabels("55%")[1]
  local blocks = { textRect(rxt), textRect(lq), rxi[1], lqi2[1] }
  local cluster = find(function(o)
    return o.parent ~= nil and region(o).ay == 46 and o.avis and o.kind ~= "label" and o.kind ~= "image"
      and o.kind ~= "box"
  end)
  local bad = 0
  for _, c in ipairs(cluster) do
    for _, b in ipairs(blocks) do if overlap(c, b) then bad = bad + 1 end end
  end
  eq(bad, 0, "sticks/trims do not overlap LQ/RX blocks")

  -- trims at the extremes, extended trims
  I.trim = { lh = -100, lv = 100, rv = -30, rh = 100 }
  I.trimTxt = { lh = "100", lv = "100", rv = "30", rh = "100" }
  I.trimExt = true
  I.left = { x = 100, y = 100 }
  I.right = { x = -100, y = -100 }
  tick(d, wgt)
  local markers = find(function(o) return o.kind == "rectangle" and o.w == 9 and o.h == 9 and o.p.rounded == 2 end)
  local tracks = find(function(o) return o.kind == "rectangle" and o.p.filled == true and o.p.rounded == 2
                      and (o.w == 4 or o.h == 4) end)
  -- order: lh, lv, rv, rh
  check(markers[1].ax == tracks[1].ax, "lh at -100: marker at the left end")
  check(markers[2].ay == tracks[2].ay, "lv at +100: marker at the top")
  check(markers[4].ax + 9 == tracks[4].ax + tracks[4].aw, "rh at +100: marker at the right end")
  check(markers[1].color == COLOR_THEME_ACTIVE and markers[3].color == COLOR_THEME_ACTIVE,
        "extended trims beyond 25 % use ACTIVE")
  local tboxes = visibleOf(find(function(o) return o.kind == "rectangle" and o.p.visible and o.p.pos end))
  eq(#tboxes, 4, "4 trim value boxes visible")
  for _, b in ipairs(tboxes) do
    for _, m in ipairs(markers) do
      check(not overlap(b, m), "trim value box does not overlap a marker")
    end
  end
  local boxes = find(function(o) return o.kind == "rectangle" and o.p.filled == false end)
  local dots = find(function(o) return o.kind == "rectangle" and o.w == 9 and o.p.pos and o.p.rounded == nil and o.p.opacity == nil end)
  check(dots[1].ax == boxes[1].ax + 2 + 67 and dots[1].ay == boxes[1].ay + 2, "left dot top-right corner")
  check(dots[2].ax == boxes[2].ax + 2 and dots[2].ay == boxes[2].ay + 2 + 67, "right dot bottom-left corner")
  I.trimTxt = { lh = "", lv = "", rv = "", rh = "" }
  tick(d, wgt)
  eq(#visibleOf(find(function(o) return o.kind == "rectangle" and o.p.visible and o.p.pos end)), 0,
     "trim value boxes hidden for empty text")

  -- I.changed: no input change -> the dots keep their place
  I.changed = 7
  tick(d, wgt)
  local before = dots[1].ax
  I.left = { x = -100, y = 0 }
  tick(d, wgt)
  eq(dots[1].ax, before, "dot not moved while I.changed is the same")
  I.changed = 8
  tick(d, wgt)
  eq(dots[1].ax, boxes[1].ax + 2, "dot moved after I.changed changed")

  -- VTX states
  local function vtxMain()
    local o = find(function(x) return x.kind == "label" and x.avis and x.font == BOLD and x.color ~= BLACK end)[1]
    return o and o.text
  end
  local function vtxTag()
    local o = find(function(x) return x.kind == "label" and x.avis and x.p.align == RIGHT and region(x).ay == 258
                    and x.color ~= BLACK end)[1]
    return o and o.text, o and o.color
  end
  local dot = find(function(o) return o.kind == "rectangle" and o.w == 8 end)[1]
  eq(vtxMain(), "R4 5769", "VTX ready value")
  eq(dot.color, GREEN, "VTX ready dot good")
  V.pit, V.rev = 1, V.rev + 1
  tick(d, wgt)
  local tg, tc = vtxTag()
  eq(tg, "P2 PIT", "VTX tag with pit")
  eq(tc, YELLOW, "pit tag in warn color")
  V.pit, V.rev = 3, V.rev + 1
  tick(d, wgt)
  tg = vtxTag()
  check(tg == "P2 PIT:A1" or tg == "PIT:A1", "pit on AUX tag (" .. tostring(tg) .. ")")
  V.band, V.bandLetter, V.freq, V.rev = 0, "", 0, V.rev + 1
  tick(d, wgt)
  eq(vtxMain(), "OFF", "VTX band off")
  local states = { { "noelrs", "NO ELRS" }, { "novtx", "NO VTX" }, { "nocrsf", "NO CRSF" }, { "search", "--" },
                   { "error", "ERROR" } }
  for _, sw in ipairs(states) do
    V.ready, V.state, V.rev = false, sw[1], V.rev + 1
    tick(d, wgt)
    eq(vtxMain(), sw[2], "VTX state " .. sw[1])
  end
  eq(dot.color, RED, "error dot bad")
  V.state, V.rev = "busy", V.rev + 1
  tick(d, wgt)
  eq(dot.color, YELLOW, "busy dot warn")
  wgt.V = nil
  tick(d, wgt)
  eq(vtxMain(), "--", "no V table")
  wgt.E = nil
  tick(d, wgt)
  check(#mainLabels("ELRS") == 1, "footer ELRS when E is missing")
end

------------------------------------------------------------------------------------------
-- 4. every size and option combination builds and updates without errors
------------------------------------------------------------------------------------------
local SIZES = { { 480, 320 }, { 480, 275 }, { 480, 272 }, { 430, 225 }, { 480, 227 }, { 240, 137 },
                { 320, 240 }, { 200, 100 }, { 100, 60 }, { 60, 30 }, { 1, 1 }, { 800, 480 } }
local OPTS = {
  { darkTheme = 1, vtxOff = 0, hideTrims = 0, transpLevel = 1 },
  { darkTheme = 0, vtxOff = 0, hideTrims = 1, transpLevel = 2 },
  { darkTheme = 1, vtxOff = 1, hideTrims = 0, transpLevel = 3 },
  { darkTheme = 0, vtxOff = 1, hideTrims = 1, transpLevel = 0 },
  { darkTheme = 1 },                                       -- new options missing (nil)
}
local outside = {}
for _, sz in ipairs(SIZES) do
  for oi, opts in ipairs(OPTS) do
    local wgt = newWgt(sz[1], sz[2], opts)
    local ok, err = pcall(function()
      local d = build(wgt)
      wgt.S.connected = false
      tick(d, wgt)
      wgt.S = baseS()
      wgt.S.rxV, wgt.S.cells, wgt.S.cellV = 50.4, 12, 4.2
      tick(d, wgt)
      wgt.I.trim = { lh = 50, lv = -50, rv = 100, rh = -100 }
      wgt.I.trimTxt = { lh = "50", lv = "50", rv = "100", rh = "100" }
      wgt.V.state, wgt.V.ready, wgt.V.rev = "noelrs", false, 9
      tick(d, wgt)
    end)
    check(ok, string.format("%dx%d opts %d: %s", sz[1], sz[2], oi, tostring(err)))
    if ok then
      check(#mock.objects < 150, string.format("%dx%d opts %d: objects %d < 150", sz[1], sz[2], oi, #mock.objects))
      -- visible objects must stay inside their region
      local n = 0
      for _, o in ipairs(mock.objects) do
        if o.avis and o.parent then
          local r = region(o)
          local x, w = o.ax, o.aw
          if o.kind == "label" then x, w = o.tx, o.tw end
          if x < r.ax or o.ay < r.ay - 1 or x + w > r.ax + r.w or o.ay + o.ah > r.ay + r.h + 1 then
            n = n + 1
            if sz[1] == 480 and sz[2] == 320 then
              print(string.format("  outside region: %s '%s' at %d,%d %dx%d (region y %d h %d)", o.kind,
                    tostring(o.text or o.file), x, o.ay, w, o.ah, r.ay, r.h))
            end
          end
        end
      end
      local key = sz[1] .. "x" .. sz[2]
      outside[key] = (outside[key] or 0) + n
      if sz[1] == 480 and sz[2] == 320 then eq(n, 0, "480x320 opts " .. oi .. ": everything inside its region") end
    end
  end
end
for _, sz in ipairs(SIZES) do
  local key = sz[1] .. "x" .. sz[2]
  print(string.format("  %-8s objects outside their region (all option sets, clipped by LVGL): %d", key,
        outside[key] or 0))
end

------------------------------------------------------------------------------------------
-- 5. CPU: instructions per tick inside the UI files (update + property functions)
------------------------------------------------------------------------------------------
do
  local wgt = newWgt(480, 320)
  local d = build(wgt)
  local typ = 0
  for i = 1, 20 do
    wgt.I.left.x = (i % 7) * 10 - 30
    wgt.I.right.y = (i % 5) * 20 - 40
    typ = math.max(typ, tick(d, wgt))
  end
  local worst = 0
  local A, B = baseS(), baseS()
  B.rxV, B.cellV, B.lq, B.rssi, B.snr, B.rateHz, B.tpwr, B.curr, B.capa = 15.0, 3.75, 95, -80, -2, 500, 100, 1.5, 200
  B.fm, B.txV, B.txState, B.modelName, B.clock, B.date = "ANGL", 7.4, "warn", "Other model", "12:35", "3 Oct"
  B.timers = { { sec = 4000 }, { sec = 61 }, { sec = 5 } }
  B.gps, B.sats = true, 9
  for i = 1, 10 do
    wgt.S = (i % 2 == 0) and A or B
    wgt.S.connected = true
    wgt.I.trim = { lh = i, lv = -i, rv = 2 * i, rh = -2 * i }
    wgt.I.trimTxt = { lh = tostring(i), lv = tostring(i), rv = tostring(i), rh = tostring(i) }
    wgt.V.rev = wgt.V.rev + 1
    wgt.V.pit = i % 2
    wgt.E = { label = (i % 2 == 0) and "RM TX15 4.1.0" or "ELRS" }
    worst = math.max(worst, tick(d, wgt))
  end
  print(string.format("CPU (UI files only, desktop VM count): typical tick %d, worst tick %d, poll calls %d",
        typ, worst, mock.calls))
  check(typ < 2500, "typical UI tick < 2500 instructions (" .. typ .. ")")
  check(worst < 7000, "worst UI tick < 7000 instructions (" .. worst .. ")")
end

------------------------------------------------------------------------------------------
-- 6a. throttle cap line on the throttle gimbal box
------------------------------------------------------------------------------------------
do
  -- the cap line is the 2 px hline (the trim centre ticks are 1 px)
  local function capLine()
    return find(function(o) return o.kind == "hline" and o.h == 2 and o.avis end)[1]
  end
  local function capLabel(text)
    return find(function(o) return o.kind == "label" and o.avis and o.text == text and o.font == TINSIZE
                and o.color ~= BLACK end)[1]
  end
  local function gimbals()
    return find(function(o) return o.kind == "rectangle" and o.p.filled == false end)
  end
  local function dotsOf()
    return find(function(o) return o.kind == "rectangle" and o.w == 9 and o.p.pos and o.p.rounded == nil and o.p.opacity == nil end)
  end

  -- 480x320, mode 2: throttle = left gimbal
  local wgt = newWgt(480, 320)
  local d = build(wgt)
  local line, boxes = capLine(), gimbals()
  check(line ~= nil, "cap 75: line shown")
  local B = boxes[1].w
  if line then
    eq(line.ax, boxes[1].ax + 2, "mode 2: line on the left box")
    eq(line.w, B - 4, "line inside the box border")
    eq(line.h, 2, "line 2 px high")
    eq(line.color, YELLOW, "dark theme: line in the warn color")
  end
  -- the line is where the dot is at the stick position that gives the cap
  -- (cap 75: weight 75, offset -25; full stick = 50 % of the output range = stick +50)
  wgt.I.left = { x = 0, y = 50 }
  wgt.I.changed = 1
  tick(d, wgt)
  local dots = dotsOf()
  check(line and math.abs((dots[1].ay + 4) - (line.ay + 1)) <= 1,
        "line at the dot centre for stick +50 (cap 75 %)")
  -- before the dots: the stick dot is drawn above the line
  local iLine, iDot = 0, 0
  for i, o in ipairs(mock.objects) do
    if o == line then iLine = i end
    if o == dots[1] then iDot = i end
  end
  check(iLine > 0 and iLine < iDot, "line made before the dot (dot on top)")
  local lbl = capLabel("75%")
  check(lbl ~= nil, "label 75% shown")
  if lbl then
    check(lbl.tx >= boxes[1].ax + B and lbl.tx + lbl.tw <= boxes[2].ax, "label in the gap between the boxes")
    check(math.abs(lbl.ay + 6 - (line.ay + 1)) <= 1, "label centred on the line")
    check(lbl.ay >= boxes[1].ay and lbl.ay + lbl.ah <= boxes[1].ay + B, "label within the box height")
    -- not on a trim bar, a trim value box, a marker, the LQ or the RX block
    local others = find(function(o)
      return o.avis and o.parent ~= nil and region(o).ay == 46 and o ~= lbl and o ~= line
        and o.kind ~= "box" and not (o.kind == "label" and o.text == "75%")
    end)
    local bad = 0
    for _, o in ipairs(others) do
      local r = (o.kind == "label") and textRect(o) or o
      if overlap(textRect(lbl), r) then
        bad = bad + 1
        print("  cap label overlaps " .. o.kind .. " '" .. tostring(o.text or "") .. "'")
      end
    end
    eq(bad, 0, "cap label overlaps nothing in the sticks region")
  end
  -- cap 50: line half way
  wgt.T.cap, wgt.T.weight, wgt.T.offset, wgt.T.rev = 50, 50, -50, 2
  wgt.I.left = { x = 0, y = 0 }
  wgt.I.changed = 2
  tick(d, wgt)
  check(math.abs((dots[1].ay + 4) - (line.ay + 1)) <= 1, "cap 50: line at the centre (stick 0)")
  check(capLabel("50%") ~= nil and capLabel("75%") == nil, "label 50%")
  -- no change of T.rev: nothing is computed again
  wgt.T.cap = 60
  tick(d, wgt)
  check(capLabel("50%") ~= nil, "T.rev unchanged: line kept")
  -- hidden: 100 %, unknown, custom, unsupported, none, no T
  local hidden = {
    { "cap 100", function(T) T.cap, T.weight, T.offset = 100, 100, 0 end },
    { "cap unknown", function(T) T.cap = 0 end },
    { "custom line", function(T) T.cap, T.custom, T.weight, T.offset = 0, true, 80, -10 end },
    { "unsupported", function(T) T.state = "unsupported" end },
    { "no input", function(T) T.state, T.cap = "none", 0 end },
  }
  for _, hcase in ipairs(hidden) do
    wgt.T = baseT()
    hcase[2](wgt.T)
    wgt.T.rev = 10
    tick(d, wgt)
    check(capLine() == nil, hcase[1] .. ": line hidden")
    check(#find(function(o) return o.kind == "label" and o.avis and o.font == TINSIZE
                 and string.find(o.text, "%%") ~= nil end) == 0, hcase[1] .. ": label hidden")
  end
  wgt.T = nil
  tick(d, wgt)
  check(capLine() == nil, "no wgt.T: line hidden")
  -- busy (a request is pending): the line shows the applied cap
  wgt.T = baseT()
  wgt.T.state, wgt.T.pending, wgt.T.rev = "busy", 60, 11
  tick(d, wgt)
  check(capLine() ~= nil and capLabel("75%") ~= nil, "pending request: line at the applied cap")
  -- stick mode 1: throttle = right gimbal
  wgt.I.mode = 1
  wgt.I.changed = 3
  tick(d, wgt)
  line = capLine()
  check(line ~= nil and line.ax == boxes[2].ax + 2, "mode 1: line on the right box")
  lbl = capLabel("75%")
  check(lbl and lbl.tx >= boxes[1].ax + B and lbl.tx + lbl.tw <= boxes[2].ax, "mode 1: label in the gap")
  wgt.I.mode = 3
  tick(d, wgt)
  check(capLine() and capLine().ax == boxes[2].ax + 2, "mode 3: right box")
  wgt.I.mode = 4
  tick(d, wgt)
  check(capLine() and capLine().ax == boxes[1].ax + 2, "mode 4: left box")

  -- light theme: line and label in theme.cap, a dark amber (yellow and the yellow ACTIVE of
  -- the default theme are not readable on a light wash)
  wgt = newWgt(480, 320, { darkTheme = 0 })
  build(wgt)
  local capCol = wgt.theme.cap
  check(capCol ~= nil and capCol ~= YELLOW and capCol ~= COLOR_THEME_ACTIVE, "light theme: theme.cap is not yellow")
  check(capLine() ~= nil and capLine().color == capCol, "light theme: line in theme.cap")
  check(#find(function(o) return o.kind == "label" and o.avis and o.text == "75%" and o.color == capCol end) == 1,
        "light theme: label in theme.cap")
  -- dark theme: the line stays YELLOW
  wgt = newWgt(480, 320, { darkTheme = 1 })
  build(wgt)
  check(capLine() ~= nil and capLine().color == YELLOW, "dark theme: line in YELLOW")

  -- light theme: a trim beyond the normal range (extended trims) uses theme.extMark, a dark
  -- amber; the dark theme keeps ACTIVE (checked in section 3)
  wgt = newWgt(480, 320, { darkTheme = 0 })
  local dl = build(wgt)
  wgt.I.trim = { lh = -100, lv = 100, rv = -30, rh = 10 }
  wgt.I.trimExt = true
  wgt.I.changed = 1000
  tick(dl, wgt)
  local mk = find(function(o) return o.kind == "rectangle" and o.w == 9 and o.h == 9 and o.p.rounded == 2 end)
  local em = wgt.theme.extMark
  check(em ~= nil and em ~= COLOR_THEME_ACTIVE and em ~= YELLOW, "light theme: extMark is not yellow")
  check(#mk == 4 and mk[1].color == em and mk[2].color == em and mk[3].color == em,
        "light theme: extended trims beyond 25 % use theme.extMark")
  check(#mk == 4 and mk[4].color == COLOR_THEME_FOCUS, "light theme: a trim within 25 % keeps the focus color")

  -- no trims, and other sizes: the label stays in the gap and inside the region
  for _, c in ipairs({ { 480, 320, { hideTrims = 1 } }, { 480, 272, {} }, { 430, 225, {} }, { 240, 137, {} } }) do
    wgt = newWgt(c[1], c[2], c[3])
    wgt.T.cap, wgt.T.rev = 95, 3
    build(wgt)
    local tag = string.format("%dx%d%s", c[1], c[2], c[3].hideTrims and " no trims" or "")
    local gb = gimbals()
    local l = capLabel("95%")
    if #gb == 2 then
      check(capLine() ~= nil and l ~= nil, tag .. ": line and label shown")
      if l then
        local inGap = l.tx >= gb[1].ax + gb[1].w and l.tx + l.tw <= gb[2].ax
        local inBox = l.tx >= gb[1].ax and l.tx + l.tw <= gb[1].ax + gb[1].w
        check(inGap or inBox, tag .. ": label in the gap or inside the box")
        check(l.ay >= gb[1].ay and l.ay + l.ah <= gb[1].ay + gb[1].w, tag .. ": label within the box height")
      end
    end
  end
end

------------------------------------------------------------------------------------------
-- 6. theme
------------------------------------------------------------------------------------------
do
  local t = theme.resolve({ darkTheme = 0, transpLevel = 1 })
  check(t.dark == false and t.text == BLACK and t.shadow == WHITE and t.wash == WHITE, "light theme colors")
  eq(t.washOpa, 153, "transpLevel 1 -> 153")
  eq(theme.resolve({ transpLevel = 2 }).washOpa, 119, "transpLevel 2 -> 119")
  eq(theme.resolve({ transpLevel = 3 }).washOpa, 85, "transpLevel 3 -> 85")
  eq(theme.resolve({ transpLevel = 0 }).washOpa, 153, "VALUE option 0 -> 153")
  eq(theme.resolve({}).washOpa, 153, "missing transpLevel -> 153")
  eq(theme.resolve({ transpLevel = 9 }).washOpa, 119, "bad transpLevel -> 119")
  eq(theme.resolve(nil).iconDir, "icons/dark/", "default dark icons")
  for k, v in pairs(theme.resolve({})) do
    check(v ~= nil, "theme field " .. k)
  end

  -- light theme: the VTX pit tag in theme.warn, a dark amber (YELLOW is not readable on
  -- the light wash); the dark theme keeps YELLOW (section 3)
  local wgt = newWgt(480, 320, { darkTheme = 0 })
  local d = build(wgt)
  wgt.V.pit, wgt.V.rev = 1, wgt.V.rev + 1
  tick(d, wgt)
  local tags = find(function(o) return o.kind == "label" and o.avis and o.text == "P2 PIT" and o.color ~= WHITE end)
  eq(#tags, 1, "light theme: one pit tag")
  check(tags[1] ~= nil and tags[1].color == wgt.theme.warn and tags[1].color ~= YELLOW,
        "light theme: pit tag in theme.warn, not YELLOW")
end

------------------------------------------------------------------------------------------
-- 9. stick trail (trailOff) and update rate in the footer (showFps)
------------------------------------------------------------------------------------------
do
  local function trails()
    return find(function(o) return o.kind == "rectangle" and o.w == 9 and o.p.pos and o.p.opacity ~= nil end)
  end
  local function dots()
    return find(function(o) return o.kind == "rectangle" and o.w == 9 and o.p.pos and o.p.rounded == nil
                and o.p.opacity == nil end)
  end
  local function at(o) return o.ax .. "," .. o.ay end

  -- a model that does not store trailOff loads it as 0: trail on
  local wgt = newWgt(480, 320)
  local d = build(wgt)
  local tr, ds = trails(), dots()
  eq(#tr, 4, "trail: 2 faded squares per gimbal")
  eq(#ds, 2, "trail: still 2 dots")
  local idx = {}
  for i, o in ipairs(mock.objects) do idx[o] = i end
  check(idx[tr[1]] < idx[ds[1]] and idx[tr[2]] < idx[ds[1]], "trail of the left dot is drawn below it")
  check(idx[tr[3]] < idx[ds[2]] and idx[tr[4]] < idx[ds[2]], "trail of the right dot is drawn below it")
  check(tr[1].p.opacity < tr[2].p.opacity, "older trail square is fainter")
  local p0 = at(ds[1])
  check(at(tr[1]) == p0 and at(tr[2]) == p0, "trail starts under the dot")

  -- move the left stick twice, then hold it
  wgt.I.left = { x = 50, y = 0 }; wgt.I.changed = (wgt.I.changed or 0) + 1
  tick(d, wgt)
  local p1 = at(ds[1])
  check(p1 ~= p0, "dot moved")
  eq(at(tr[2]), p0, "move 1: newer trail square at the last position")
  eq(at(tr[1]), p0, "move 1: older trail square at the last position")
  wgt.I.left = { x = -50, y = 50 }; wgt.I.changed = (wgt.I.changed or 0) + 1
  tick(d, wgt)
  local p2 = at(ds[1])
  eq(at(tr[2]), p1, "move 2: newer trail square 1 cycle back")
  eq(at(tr[1]), p0, "move 2: older trail square 2 cycles back")
  tick(d, wgt)                         -- stick held: no input change
  eq(at(ds[1]), p2, "hold: dot stays")
  eq(at(tr[2]), p2, "hold 1: newer trail square reaches the dot")
  eq(at(tr[1]), p1, "hold 1: older trail square 1 cycle back")
  tick(d, wgt)
  eq(at(tr[1]), p2, "hold 2: older trail square reaches the dot")
  eq(at(tr[3]), at(ds[2]), "right trail stays under the right dot")

  -- trailOff = 1: no trail objects at all
  wgt = newWgt(480, 320, { trailOff = 1 })
  build(wgt)
  eq(#trails(), 0, "trailOff = 1: no trail squares")
  eq(#dots(), 2, "trailOff = 1: 2 dots")

  -- showFps: footer centre label, only when on, text changes only with the value
  wgt = newWgt(480, 320)
  d = build(wgt)
  wgt.fps = 20
  tick(d, wgt)
  check(not visibleLabel("20 Hz"), "showFps off: no rate")
  wgt.options.showFps = 1
  tick(d, wgt)
  check(visibleLabel("20 Hz"), "showFps on: '20 Hz' in the footer")
  wgt.fps = 0
  tick(d, wgt)
  check(visibleLabel("-- Hz"), "showFps on, no value yet: '-- Hz'")
  wgt.fps = 19
  tick(d, wgt)
  check(visibleLabel("19 Hz") and not visibleLabel("-- Hz"), "showFps: new value shown")
  wgt.options.showFps = 0
  tick(d, wgt)
  check(not visibleLabel("19 Hz"), "showFps turned off: rate hidden")
  -- the rate label stays clear of the ELRS label and the EdgeTX version
  wgt.options.showFps = 1
  wgt.E.label = "RM TX15 ELRS 4.1.0"
  tick(d, wgt)
  local fl = visibleLabel("19 Hz")
  local el = visibleLabel("RM TX15 ELRS 4.1.0")
  check(fl and el and el.ax + el.tw + 4 <= fl.ax + math.floor((fl.w - fl.tw) / 2), "rate label right of the ELRS label")
end

print(string.format("dash tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
