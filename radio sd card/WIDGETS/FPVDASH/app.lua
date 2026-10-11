-- app.lua: lifecycle of the Telemetry Dashboard widget.
-- main.lua loads this file once; all instances share it, so every instance value
-- is kept in the wgt table that create() returns (never in module locals).
--
-- Modules are loaded with loadScript(path, "btd"):
--   "bt" = use the .lua or the .luac file, whichever is newer. An edited .lua is used
--          (and compiled again to .luac); after that the radio loads the .luac.
--   "d"  = keep line numbers, so error messages tell the file and the line.
-- If a copied .lua is OLDER than its .luac (file dates), delete the .luac.
--
-- Views and root boxes:
-- Every view is built inside a root box that covers the zone. The script never calls
-- the no-argument lvgl.clear(): it deletes every LVGL child of the widget, also the ones
-- that the firmware owns (the focus border in widget-select mode), and the firmware
-- then uses freed memory.
-- Outside full screen the dashboard is shown. Full screen shows the pages: the tabs
-- "VTX" and "Throttle" (only the Throttle page when VTX control is off).
-- The dashboard and the page texts are built once and are only hidden while not shown.
-- The page buttons (Back, the tabs and the controls of each page) are made on each
-- full-screen entry, in a root box above the page texts, and deleted on exit: a hidden
-- button can keep the key focus of the main view, and the main view then does not get
-- the MDL, SYS and TELE keys. The controls of a tab are made when the tab is first shown.
-- lvgl.clear(box) deletes the children of the box at once, but the firmware drops their
-- Lua references only at the next property poll of the box. So a cleared box is filled
-- again only after its visible function ran once more (slot.seen).
-- A box made in full screen stays clickable (the firmware clears the clickable flag only
-- for boxes made outside full screen). Such a box on the dashboard would take the long
-- press that opens full screen, so a free root box is used again only in the screen mode
-- that it was made in (slot.fs), and a box that is cleared is hidden at once (dropSlot).

local M = {}

local LOAD_MODE = "btd"

-- wgt.mods key and file (relative to the widget folder)
local MODS = {
  "telem", "lib/telem.lua",
  "inputs", "lib/inputs.lua",
  "crsf", "lib/crsf.lua",
  "elrs", "lib/elrs.lua",
  "vtx", "lib/vtx.lua",
  "thrcap", "lib/thrcap.lua",
  "theme", "ui/theme.lua",
  "layout", "ui/layout.lua",
  "dash", "ui/dash.lua",
  "vtxpage", "ui/vtxpage.lua",
  "thrpage", "ui/thrpage.lua",
  -- dashboard region builders (dash.lua uses them), loaded here so that no
  -- loadScript runs later in update() or refresh()
  "topbar", "ui/topbar.lua",
  "sticks", "ui/sticks.lua",
  "grid", "ui/grid.lua",
  "timers", "ui/timers.lua",
  "footer", "ui/footer.lua",
}

local function isFS()
  local f = lvgl.isFullScreen
  return f ~= nil and f() == true
end

local function exitFS()
  if lvgl.exitFullScreen ~= nil then
    lvgl.exitFullScreen()
  elseif lcd ~= nil and lcd.exitFullScreen ~= nil then
    lcd.exitFullScreen()
  end
end

-- Option value as a number (BOOL true = 1); 0 when not set.
local function optNum(o, key)
  local v = o and o[key]
  if type(v) == "number" then return v end
  if v == true then return 1 end
  return 0
end

-- Options after index 1 load as 0 on models that do not store them yet,
-- so 0 means "VTX control on" (main.lua).
local function vtxEnabled(o)
  return optNum(o, "vtxOff") < 0.5
end

-- 0-based index of the throttle input line while lib/thrcap can read it (the
-- dashboard then shows the capped throttle output), else nil (raw stick).
local function thrInput(T)
  if T == nil then return nil end
  local st, i = T.state, T.input
  if (st == "ok" or st == "busy") and type(i) == "number" and i >= 0 then return i end
  return nil
end

-- One string for the option values that need a new view (the options table is
-- changed in place by the radio). extTrims is read on every tick (inputs.read).
local function optKey(o)
  local d, t = 1, 1
  if o ~= nil and o.darkTheme ~= nil then d = optNum(o, "darkTheme") end
  if o ~= nil and o.transpLevel ~= nil then t = optNum(o, "transpLevel") end
  return tostring(d) .. "|" .. tostring(t) .. "|" .. tostring(optNum(o, "vtxOff")) .. "|"
    .. tostring(optNum(o, "hideTrims")) .. "|" .. tostring(optNum(o, "rxCells")) .. "|"
    .. tostring(optNum(o, "trailOff"))
end

-- The full-screen tab to show: wgt.tab (set by the tab buttons), always "thr" when VTX
-- control is off.
local function pageTab(wgt)
  if wgt.vtxOn and wgt.tab == "vtx" then return "vtx" end
  return "thr"
end

---------------------------------------------------------------------------
-- Root boxes (see the note at the top)

-- A root box of w x h. A free box is used again when its old children are gone
-- (seen), it was made in the same screen mode (fs) and after the box number 'after'
-- (it is then drawn above it).
local function takeSlot(wgt, w, h, after, show, fs)
  local pool = wgt.pool
  for i = 1, #pool do
    local s = pool[i]
    if s.seen and s.fs == fs and s.w == w and s.h == h and s.seq > after then
      table.remove(pool, i)
      s.show = show
      return s
    end
  end
  wgt.seq = wgt.seq + 1
  local s = { show = show, seen = false, w = w, h = h, seq = wgt.seq, fs = fs }
  s.box = lvgl.box({ x = 0, y = 0, w = w, h = h, scrollBar = false, scrollDir = lvgl.SCROLL_OFF,
                     visible = function()
                       s.seen = true
                       return s.show
                     end })
  return s
end

-- Deletes the children of a root box and keeps the box for later use.
-- The box is hidden at once: the next poll of a cleared box only drops the Lua
-- references of its children and does not call its visible function. In App mode
-- 2.12.x calls no update() when full screen ends, so that poll is the only one of
-- the exit cycle, and a box made in full screen (clickable) would stay visible on the
-- dashboard for one cycle. The visible function keeps the box hidden after that.
local function dropSlot(wgt, s)
  lvgl.hide(s.box)
  lvgl.clear(s.box)
  s.show = false
  s.seen = false
  local pool = wgt.pool
  pool[#pool + 1] = s
end

-- Page buttons (deleted when full screen ends and before a page is rebuilt).
local function dropCtl(wgt)
  local c = wgt.ctl
  if c ~= nil then
    wgt.ctl = nil
    dropSlot(wgt, c)
  end
end

-- A page view goes with the buttons: they must be drawn above every page box.
local function dropPage(wgt)
  dropCtl(wgt)
  local pv = wgt.pv
  if pv ~= nil then
    wgt.pv = nil
    dropSlot(wgt, pv.slot)
  end
end

local function dropThr(wgt)
  dropCtl(wgt)
  local tv = wgt.tv
  if tv ~= nil then
    wgt.tv = nil
    dropSlot(wgt, tv.slot)
  end
end

local function dropDash(wgt)
  local dv = wgt.dv
  if dv ~= nil then
    wgt.dv = nil
    dropSlot(wgt, dv.slot)
  end
end

---------------------------------------------------------------------------

local function showError(wgt)
  wgt.view = nil
  wgt.pageOpen = false
  wgt.vtxOpen = false
  if lvgl == nil or wgt.errShown == wgt.err then return end
  wgt.errShown = wgt.err
  if wgt.pool ~= nil then
    dropPage(wgt)
    dropThr(wgt)
    dropDash(wgt)
  end
  local z = wgt.zone or {}
  local w, h = z.w or 0, z.h or 0
  if w < 60 then w = 60 end
  if h < 40 then h = 40 end
  -- no backdrop in full screen: a rectangle made there stays clickable on the dashboard
  if not isFS() then
    lvgl.rectangle({ x = 0, y = 0, w = w, h = h, filled = true, color = BLACK, opacity = 200 })
  end
  lvgl.label({ x = 6, y = 6, w = w - 12, font = SMLSIZE, color = YELLOW,
               text = "FPVDASH error:\n" .. tostring(wgt.err) })
end

local function setError(wgt, msg)
  wgt.err = msg
  showError(wgt)
end

local function loadMods(wgt)
  local base = wgt.path
  for i = 1, #MODS, 2 do
    local file = MODS[i + 1]
    local chunk, err = loadScript(base .. file, LOAD_MODE)
    if chunk == nil then return tostring(err or (file .. ": cannot load")) end
    local ok, mod = pcall(chunk)
    if not ok then return file .. ": " .. tostring(mod) end
    if type(mod) ~= "table" then return file .. ": no module table" end
    wgt.mods[MODS[i]] = mod
  end
  return nil
end

-- CRSF dispatcher, ELRS module state and VTX controller state.
local function newLink(wgt)
  local m = wgt.mods
  wgt.C = m.crsf.new()
  wgt.E = m.elrs.new()
  wgt.V = m.vtx.new()
end

local function newState(wgt)
  local m = wgt.mods
  wgt.S = m.telem.new()
  wgt.I = m.inputs.new()
  wgt.T = m.thrcap.new()
  newLink(wgt)
  wgt.theme = m.theme.resolve(wgt.options)
  local now = getTime()
  wgt.now = now
  m.telem.read(wgt.S, now, wgt.options, wgt.E, m.elrs, false)
  m.inputs.read(wgt.I, optNum(wgt.options, "extTrims"))
end

local function checkView(v, name)
  if type(v) ~= "table" or type(v.update) ~= "function" then
    error(name .. ".build returned no view")
  end
  return v
end

-- New view record { slot, key, w, h } in a free or new root box (view is set by the caller).
local function newView(wgt, key, w, h, fs)
  return { slot = takeSlot(wgt, w, h, 0, true, fs), key = key, w = w, h = h }
end

-- Full screen: the page texts (VTX only with VTX control on), the button box above them
-- (Back and the tabs) and the controls of the shown tab. Returns the shown view.
local function buildPages(wgt, key, w, h, fs, tab)
  local m = wgt.mods
  local pv, tv = wgt.pv, wgt.tv
  if pv ~= nil and (pv.w ~= w or pv.h ~= h) then
    dropPage(wgt)
    pv = nil
  end
  if tv ~= nil and (tv.w ~= w or tv.h ~= h) then
    dropThr(wgt)
    tv = nil
  end
  -- texts of both pages before the button box, so that the buttons are drawn above them
  if tv == nil then
    dropCtl(wgt)
    tv = newView(wgt, key, w, h, fs)
    wgt.tv = tv
    tv.view = checkView(m.thrpage.build(wgt, tv.slot.box), "thrpage")
  end
  if wgt.vtxOn and pv == nil then
    dropCtl(wgt)
    pv = newView(wgt, key, w, h, fs)
    wgt.pv = pv
    pv.view = checkView(m.vtxpage.build(wgt, pv.slot.box), "vtxpage")
  end
  local tabs = wgt.tabs
  tabs.vtx = (tab == "vtx")
  tabs.thr = not tabs.vtx
  local c = wgt.ctl
  if c == nil then
    local top = tv.slot.seq
    if pv ~= nil and pv.slot.seq > top then top = pv.slot.seq end
    c = takeSlot(wgt, w, h, top, true, fs)
    c.vtxMade, c.thrMade = false, false
    wgt.ctl = c
    -- The empty box of each tab first, then Back and the tabs. LVGL gives a tap to the
    -- last child that contains the point, and a box made in full screen is clickable: a
    -- full-size tab box made after the header buttons would take every tap on them.
    -- Children added to a tab box later do not change this order.
    c.vtxBox = nil
    if wgt.vtxOn then
      c.vtxBox = lvgl.box(c.box, { x = 0, y = 0, w = w, h = h, scrollBar = false, scrollDir = lvgl.SCROLL_OFF,
                                   visible = function() return tabs.vtx end })
    end
    c.thrBox = lvgl.box(c.box, { x = 0, y = 0, w = w, h = h, scrollBar = false, scrollDir = lvgl.SCROLL_OFF,
                                 visible = function() return tabs.thr end })
    m.thrpage.header(wgt, c.box, tabs)
  end
  -- controls of a tab: made in its box when the tab is first shown in this full-screen visit
  if tabs.vtx and not c.vtxMade and c.vtxBox ~= nil then
    c.vtxMade = true
    m.vtxpage.controls(pv.view, wgt, c.vtxBox)
  elseif tabs.thr and not c.thrMade then
    c.thrMade = true
    m.thrpage.controls(tv.view, wgt, c.thrBox)
  end
  c.show = true
  tv.slot.show = tabs.thr
  if pv ~= nil then pv.slot.show = tabs.vtx end
  if wgt.dv ~= nil then wgt.dv.slot.show = false end
  wgt.pageOpen = true
  wgt.vtxOpen = tabs.vtx
  if tabs.vtx then return pv.view end
  return tv.view
end

-- Shows the view for the current mode and builds what is missing: the pages in full
-- screen, else the dashboard. Runs inside pcall (see rebuild).
local function build(wgt, key, optsChanged, fs)
  local m = wgt.mods
  if optsChanged then
    local on = vtxEnabled(wgt.options)
    if on ~= wgt.vtxOn then
      wgt.vtxOn = on
      wgt.tab = on and "vtx" or "thr"
      newLink(wgt)            -- fresh state; with VTX control off the footer shows "ELRS"
    end
    wgt.theme = m.theme.resolve(wgt.options)
  end
  local z = wgt.zone
  local w, h = z.w or 0, z.h or 0
  local tab = pageTab(wgt)
  local again = wgt.rebuildRequested
  wgt.rebuildRequested = false
  wgt.built = { fs = fs, w = w, h = h, key = key, tab = tab }
  wgt.view = nil
  wgt.pageOpen = false
  wgt.vtxOpen = false
  -- views of other option values go; the page buttons go when no page is shown
  if wgt.pv ~= nil and (wgt.pv.key ~= key or again or not wgt.vtxOn) then dropPage(wgt) end
  if wgt.tv ~= nil and wgt.tv.key ~= key then dropThr(wgt) end
  if wgt.dv ~= nil and wgt.dv.key ~= key then dropDash(wgt) end
  if not fs then dropCtl(wgt) end
  local pv, tv, dv = wgt.pv, wgt.tv, wgt.dv
  if w <= 0 or h <= 0 then
    if pv ~= nil then pv.slot.show = false end
    if tv ~= nil then tv.slot.show = false end
    if dv ~= nil then dv.slot.show = false end
    return
  end
  local v
  if fs then
    v = buildPages(wgt, key, w, h, fs, tab)
  else
    if dv ~= nil and (dv.w ~= w or dv.h ~= h) then
      dropDash(wgt)
      dv = nil
    end
    if dv == nil then
      dv = newView(wgt, key, w, h, fs)
      wgt.dv = dv
      dv.view = checkView(m.dash.build(wgt, dv.slot.box), "dash")
    end
    dv.slot.show = true
    if pv ~= nil then pv.slot.show = false end
    if tv ~= nil then tv.slot.show = false end
    v = dv.view
  end
  wgt.view = v
  v.update(wgt)
end

-- The only place that changes the views (never inside an LVGL callback).
local function rebuild(wgt, key, optsChanged, fs)
  local ok, e = pcall(build, wgt, key, optsChanged, fs)
  if not ok then setError(wgt, "build: " .. tostring(e)) end
end

-- A tab press only sets wgt.tab: the next refresh shows the tab (and makes its controls).
local function needBuild(wgt, b, fs)
  local z = wgt.zone
  return b == nil or wgt.rebuildRequested or b.fs ~= fs or b.w ~= z.w or b.h ~= z.h
    or (fs and b.tab ~= pageTab(wgt))
end

-- One cycle. visible = called from refresh. rebuilt = the view was just shown and
-- updated in this cycle, so only the protocol part runs (keeps the CPU budget); the
-- throttle cap then waits one cycle with its model write.
local function tick(wgt, visible, rebuilt)
  local now = getTime()
  wgt.now = now
  local m = wgt.mods
  if visible then
    -- update rate (showFps): refresh calls per second over about 1 s; a gap of more
    -- than 2 s (widget not shown) starts a new window
    local n = wgt.fpsN + 1
    local dt = now - wgt.fpsAt
    if dt > 200 then
      wgt.fpsN, wgt.fpsAt = 0, now
    elseif dt >= 100 then
      wgt.fps = math.floor(n * 100 / dt + 0.5)
      wgt.fpsN, wgt.fpsAt = 0, now
    else
      wgt.fpsN = n
    end
    -- sticks and trims first, so the dots use the newest values of this cycle
    if not rebuilt and not wgt.pageOpen then
      m.inputs.read(wgt.I, optNum(wgt.options, "extTrims"), thrInput(wgt.T))
    end
  end
  if wgt.vtxOn then
    local C, E = wgt.C, wgt.E
    m.crsf.beginTick(C, now)
    m.elrs.tick(E, C, now, visible)
    m.vtx.tick(wgt.V, C, E, now, visible, visible and wgt.vtxOpen)
  end
  -- model writes only from refresh (background also runs while setup pages are open)
  m.thrcap.tick(wgt.T, now, visible and not rebuilt)
  if not visible then
    m.telem.track(wgt.S, now)
  elseif not rebuilt then
    local page = wgt.pageOpen
    m.telem.read(wgt.S, now, wgt.options, wgt.E, m.elrs, page)
    local v = wgt.view
    if v ~= nil then v.update(wgt) end
  end
end

function M.create(zone, options, dir)
  local abs = dir or "/WIDGETS/FPVDASH/"
  if string.sub(abs, 1, 1) ~= "/" then abs = "/" .. abs end
  if string.sub(abs, -1) ~= "/" then abs = abs .. "/" end
  local on = vtxEnabled(options)
  local wgt = {
    zone = zone,
    options = options or {},
    dir = string.sub(abs, 2),     -- "WIDGETS/FPVDASH/" for image files
    path = abs,                   -- "/WIDGETS/FPVDASH/" for loadScript
    mods = {},
    view = nil,
    built = nil,
    pageOpen = false,             -- a full-screen page is shown
    vtxOpen = false,              -- the VTX page is shown
    rebuildRequested = false,
    vtxOn = on,
    tab = on and "vtx" or "thr",  -- full-screen tab choice, kept between visits
    tabs = { vtx = false, thr = false },   -- the shown tab (read by the tab buttons)
    now = getTime(),
    fps = 0, fpsN = 0, fpsAt = 0, -- update rate (refresh calls per second)
    err = nil,
    pool = {},                    -- free root boxes
    seq = 0,                      -- number of root boxes made
    dv = nil,                     -- dashboard view { slot, view, key, w, h }
    pv = nil,                     -- VTX page view { slot, view, key, w, h }
    tv = nil,                     -- throttle page view { slot, view, key, w, h }
    ctl = nil,                    -- root box of the page buttons (full screen only)
  }
  local err = loadMods(wgt)
  if err ~= nil then
    wgt.err = err
    return wgt
  end
  local ok, e = pcall(newState, wgt)
  if not ok then wgt.err = "init: " .. tostring(e) end
  return wgt
end

function M.update(wgt, options)
  if options ~= nil then wgt.options = options end
  if lvgl == nil then return end
  if wgt.err ~= nil then
    showError(wgt)
    return
  end
  local key = optKey(wgt.options)
  local b, fs = wgt.built, isFS()
  local optsChanged = (b == nil) or (b.key ~= key)
  if optsChanged or needBuild(wgt, b, fs) then
    rebuild(wgt, key, optsChanged, fs)
  end
end

function M.refresh(wgt, event, touchState)
  if wgt.err == nil then
    local b, fs = wgt.built, isFS()
    -- 2.12.x does not call update() when full screen ends in App mode: check here too
    if needBuild(wgt, b, fs) then
      if b ~= nil then
        rebuild(wgt, b.key, false, fs)
      else
        rebuild(wgt, optKey(wgt.options), true, fs)
      end
      if wgt.err == nil then tick(wgt, true, true) end
    else
      tick(wgt, true, false)
    end
  end
  if event ~= nil and event == EVT_VIRTUAL_EXIT and isFS() then exitFS() end
end

function M.background(wgt)
  if wgt.err == nil then tick(wgt, false, false) end
end

return M
