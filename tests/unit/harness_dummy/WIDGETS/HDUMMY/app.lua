-- Dummy app for the harness self-test. Small CRSF client: ping, then read
-- parameter entries one by one until "Band..." is found, parse it, and allow a
-- write + Send VTx from a full-screen page. Option "bad" makes it break rules
-- on purpose so the self-test can check that the mock catches them.

local A = {}

local TX, ME = 0xEE, 0xEA

local function newState()
  return {
    E = { found = false, label = "ELRS", version = nil, armed = false },
    V = { state = "search", msg = "searching", ready = false, band = 0, bandLetter = "", channel = 0,
          bandLabels = {}, powerLabels = {}, pitLabels = {}, power = 0, pit = 0, freq = 0,
          send = "idle", sendMsg = "", rev = 0 },
    S = { connected = false },
  }
end

function A.create(zone, opts, dir)
  local st = newState()
  local wgt = { zone = zone, options = opts, dir = dir, E = st.E, V = st.V, S = st.S,
                now = getTime(), nextPing = 0, scanId = 1, fieldCount = 0, waiting = false,
                deadline = 0, bandId = nil, sendId = nil, txt = "--", rebuild = false,
                req = nil, built = nil, wantSend = false, hog = 0 }
  if opts.vtxCtl ~= 0 then crossfireTelemetryPop() end
  return wgt
end

local function readStr(d, i)
  local t = {}
  while d[i] ~= nil and d[i] ~= 0 do
    t[#t + 1] = string.char(d[i])
    i = i + 1
  end
  if d[i] == nil then return table.concat(t), nil end
  return table.concat(t), i + 1
end

local function split(s)
  local r = {}
  for opt in string.gmatch(s .. ";", "([^;]*);") do r[#r + 1] = opt end
  return r
end

local function onFrame(wgt, cmd, d)
  if d[2] ~= TX then return end
  if cmd == 0x29 then
    local name, o = readStr(d, 3)
    if not o or d[o + 12] == nil then return end
    wgt.E.found = true
    wgt.E.version = string.format("%d.%d.%d", d[o + 9], d[o + 10], d[o + 11])
    wgt.E.label = name .. " " .. wgt.E.version
    wgt.fieldCount = d[o + 12]
    wgt.waiting = false
  elseif cmd == 0x2B then
    if wgt.req == nil or d[3] ~= wgt.req then return end
    wgt.req = nil
    wgt.waiting = false
    local name, i = readStr(d, 7)
    if not i then return end
    if string.sub(name, 1, 4) == "Band" then
      wgt.bandId = d[3]
      local opts
      opts, i = readStr(d, i)
      wgt.V.bandLabels = split(opts)
      wgt.V.band = d[i]
      wgt.V.bandLetter = (d[i] > 0) and wgt.V.bandLabels[d[i] + 1] or ""
      wgt.V.ready = true
      wgt.V.state = "ready"
      wgt.V.msg = "ready"
      wgt.V.rev = wgt.V.rev + 1
      wgt.txt = "VTX " .. wgt.V.bandLetter
    elseif name == "Send VTx" then
      wgt.sendId = d[3]
    end
    wgt.scanId = d[3] + 1
  elseif cmd == 0x2E then
    wgt.E.armed = (d[6] or 0) >= 8
  end
end

local function tick(wgt, visible)
  wgt.now = getTime()
  if wgt.options.vtxCtl == 0 then return end
  for _ = 1, 4 do
    local cmd, d = crossfireTelemetryPop()
    if cmd == nil then break end
    onFrame(wgt, cmd, d)
  end
  if not visible then return end
  if wgt.waiting and wgt.now > wgt.deadline then wgt.waiting = false end
  if wgt.waiting then return end
  if not wgt.E.found then
    if wgt.now >= wgt.nextPing then
      wgt.nextPing = wgt.now + 100
      local r = crossfireTelemetryPush(0x28, { TX, ME })
      if r == nil then wgt.V.state = "nocrsf" wgt.V.msg = "no CRSF" return end
      if r then wgt.waiting = true wgt.deadline = wgt.now + 50 end
    end
    return
  end
  if wgt.writeBand then
    if crossfireTelemetryPush(0x2D, { TX, ME, wgt.bandId, wgt.writeBand }) then
      wgt.writeBand = nil
    end
    return
  end
  if wgt.wantSend and wgt.sendId then
    if crossfireTelemetryPush(0x2D, { TX, ME, wgt.sendId, 1 }) then
      wgt.wantSend = false
      wgt.V.send = "sending"
    end
    return
  end
  if (not wgt.bandId or not wgt.sendId) and wgt.scanId <= wgt.fieldCount then
    if crossfireTelemetryPush(0x2C, { TX, ME, wgt.scanId, 0 }) then
      wgt.req = wgt.scanId
      wgt.waiting = true
      wgt.deadline = wgt.now + 50
    end
  end
end

local function bad(wgt) return wgt.options.bad or 0 end

local function buildDash(wgt)
  local w, h = wgt.zone.w, wgt.zone.h
  lvgl.rectangle({ x = 0, y = 0, w = w, h = h, filled = true, color = BLACK, opacity = 153 })
  lvgl.label({ x = 4, y = 2, font = DBLSIZE, color = WHITE, text = "DUMMY" })
  local b = bad(wgt)
  if b == 1 then
    lvgl.label({ x = 4, y = 50, text = "x", colour = RED })
  elseif b == 2 then
    lvgl.label({ x = 4, y = 50, text = "x", visible = true })
  elseif b == 3 then
    lvgl.label({ x = 4, y = 50, text = function() return wgt.missing end })
  elseif b == 4 then
    wgt.stale = lvgl.label({ x = 4, y = 50, text = "old" })
  elseif b == 5 then
    leakedGlobal = 1
  elseif b == 6 then
    local s = "abc"
    wgt.txt = s:sub(1, 1)
  elseif b == 8 then
    local btn = lvgl.button({ x = 0, y = 0, text = "no" })
    btn:set({ text = "boom" })
  elseif b == 10 then
    lvgl.hline({ x = 0, y = 60, w = 100 })
  elseif b == 11 then
    lvgl.rectangle({ x = 0, y = 60, w = 0, h = 10 })
  elseif b == 12 then
    local lbl = lvgl.label({ x = 0, y = 60, text = "l" })
    lbl:enable()
  end
  lvgl.image({ x = 4, y = 44, w = 24, h = 24, file = wgt.dir .. "icon.png" })
  lvgl.label({ x = 32, y = 44, font = MIDSIZE, color = WHITE, text = function() return wgt.txt end })
  lvgl.label({ x = 4, y = h - 18, font = SMLSIZE, color = WHITE, text = function() return wgt.E.label end })
  local box = lvgl.box({ x = 300, y = 40, w = 100, h = 40, visible = function() return wgt.V.ready end })
  box:label({ x = 0, y = 0, w = 100, text = function() return wgt.V.msg end, align = RIGHT })
end

local BANDS = { "A", "B", "E", "F", "R", "L" }

local function buildPage(wgt)
  lvgl.rectangle({ x = 0, y = 0, w = LCD_W, h = LCD_H, filled = true, color = COLOR_THEME_SECONDARY3 })
  lvgl.button({ x = 4, y = 4, w = 80, h = 36, text = "Back", press = function() lvgl.exitFullScreen() end })
  lvgl.label({ x = 100, y = 10, text = function() return wgt.V.msg end, color = WHITE })
  for i = 1, #BANDS do
    lvgl.button({ x = 4 + (i - 1) * 76, y = 60, w = 72, h = 40, text = BANDS[i],
                  press = function() wgt.sel = i end })
  end
  lvgl.button({ x = 4, y = 120, w = 200, h = 40,
                text = function() return (wgt.V.send == "idle") and "Apply & Send" or "Sending..." end,
                press = function()
                  if bad(wgt) == 9 then lvgl.clear() return end
                  if wgt.E.armed then
                    lvgl.confirm({ title = "Armed", message = "Change VTX while armed?",
                                   confirm = function() wgt.writeBand = wgt.sel wgt.wantSend = true end })
                    return
                  end
                  wgt.writeBand = wgt.sel
                  wgt.wantSend = true
                end })
  lvgl.button({ x = 220, y = 120, w = 100, h = 40, text = "Menu",
                press = function()
                  lvgl.menu({ title = "Pick", values = BANDS, get = function() return wgt.sel or 1 end,
                              set = function(i) wgt.sel = i end })
                end })
end

local function rebuild(wgt)
  lvgl.clear()
  wgt.built = { fs = lvgl.isFullScreen(), w = wgt.zone.w, h = wgt.zone.h }
  if wgt.built.fs and wgt.options.vtxCtl ~= 0 then buildPage(wgt) else buildDash(wgt) end
end

function A.update(wgt, opts)
  wgt.options = opts
  rebuild(wgt)
end

function A.refresh(wgt, event, touch)
  tick(wgt, true)
  local b = bad(wgt)
  if b == 4 and wgt.stale then
    lvgl.clear()
    wgt.stale:set({ text = "boom" })
  elseif b == 7 then
    local s = 0
    for i = 1, 30000 do s = s + i end
    wgt.hog = s
  end
  local fs = lvgl.isFullScreen()
  if wgt.built == nil or fs ~= wgt.built.fs or wgt.zone.w ~= wgt.built.w or wgt.zone.h ~= wgt.built.h then
    rebuild(wgt)
  end
  if fs and event == EVT_VIRTUAL_EXIT then lvgl.exitFullScreen() end
end

function A.background(wgt)
  tick(wgt, false)
end

return A
